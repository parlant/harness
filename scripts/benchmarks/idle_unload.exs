# Synthetic idle-unload benchmark; see docs/hi/session-performance.md.
defmodule IdleAcceptance do
  alias H.{Catalog, Daemon, WorkspaceLease}
  alias H.Provider.Fake
  alias H.Session.Supervisor, as: SessionSupervisor
  alias H.Storage.File, as: Store

  @registry IdleAcceptance.Registry
  @pubsub IdleAcceptance.PubSub
  @catalog IdleAcceptance.Catalog
  @table :idle_acceptance_catalog
  @runtime IdleAcceptance.Runtime
  @lease IdleAcceptance.Lease
  @mib 1_048_576
  @epoch 1_760_000_000_000
  @entries 160

  def main(["seed", root]) do
    [] = File.ls!(root)
    {opts, _fake} = start_stack(root)
    File.write!(Path.join(root, "fixture.json"), JSON.encode!(Enum.map(1..55, &seed(&1, opts))))
  end

  def main(["measure", root, policy]) do
    false = File.exists?(Path.join(root, "result.json"))
    timeout = if policy == "default", do: 300_000, else: String.to_integer(policy)
    {opts, fake} = start_stack(root)

    opts =
      if policy == "default", do: opts, else: Keyword.put(opts, :idle_session_timeout_ms, timeout)

    fixture = root |> Path.join("fixture.json") |> File.read!() |> JSON.decode!()
    55 = length(fixture)
    [] = Fake.requests(fake)
    target = fixture |> List.last() |> Map.fetch!("sid")
    {sub_pid, sub_ref} = subscriber(target, opts)

    metadata = %{
      "policy" => policy,
      "expected_timeout_ms" => timeout,
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "erts" => to_string(:erlang.system_info(:version)),
      "online_schedulers" => :erlang.system_info(:schedulers_online),
      "fixture_wal_bytes" => Enum.sum_by(fixture, & &1["wal_bytes"]),
      "fixture_entries" => length(fixture) * @entries,
      "started_apps" => Enum.map(Application.started_applications(), fn {app, _, _} -> app end),
      "utc_started" => DateTime.to_iso8601(DateTime.utc_now()),
      "os_pid" => System.pid()
    }

    emit("metadata", metadata)
    baseline = memory("catalog_only", opts, 0)

    # Read and write cohorts use disjoint sessions; the target subscriber registers once.
    starts = Enum.map(fixture, &open_and_monitor(&1, target, sub_pid, sub_ref, opts))
    loaded = memory("all_loaded", opts, 55)
    down = retirements(starts, timeout)
    await_no_wrappers!()
    unloaded = memory("all_unloaded", opts, 0)
    emit("automatic_retirement_ms", stats(Enum.map(down, & &1["quiet_to_down_ms"])))
    Process.sleep(5_000)
    settled = memory("all_unloaded_plus_5s", opts, 0)

    wakes = Enum.map(starts, &wake(&1, opts))
    [] = Fake.requests(fake)

    latencies =
      Map.new(["read", "write"], fn kind ->
        group = Enum.filter(wakes, &(&1["kind"] == kind))

        {kind,
         %{
           "first_wake_ms" => stats(Enum.map(group, & &1["wake_ms"])),
           "already_loaded_ms" => stats(Enum.map(group, & &1["warm_ms"]))
         }}
      end)

    emit("latency", latencies)

    result =
      Map.merge(metadata, %{
        "checkpoints" => [baseline, loaded, unloaded, settled],
        "retirements" => down,
        "wake_samples" => wakes,
        "latency" => latencies,
        "fake_provider_requests" => 0,
        "subscription_continuity_verified" => true,
        "utc_finished" => DateTime.to_iso8601(DateTime.utc_now())
      })

    path = Path.join(root, "result.json")
    File.write!(path <> ".tmp", JSON.encode!(result))
    File.rename!(path <> ".tmp", path)
  end

  defp start_stack(root) do
    root = Path.expand(root)

    unless Path.basename(root) |> String.starts_with?("h-idle-bench.") do
      raise ArgumentError, "use a fresh directory named h-idle-bench.*"
    end

    data = Path.join(root, "data")
    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)
    File.mkdir_p!(data)

    children = [
      Supervisor.child_spec({Registry, keys: :unique, name: @registry}, id: @registry),
      Supervisor.child_spec({Registry, keys: :duplicate, name: @pubsub}, id: @pubsub),
      {Catalog,
       data_dir: data, name: @catalog, table: @table, pubsub: @pubsub, registry: @registry},
      {WorkspaceLease, name: @lease},
      {DynamicSupervisor, strategy: :one_for_one, name: @runtime},
      {Fake, name: IdleAcceptance.Fake, script: []}
    ]

    {:ok, _sup} = Supervisor.start_link(children, strategy: :one_for_one)
    false = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :harness))
    fake = Process.whereis(IdleAcceptance.Fake)

    opts = [
      data_dir: data,
      default_cwd: cwd,
      registry: @registry,
      pubsub: @pubsub,
      catalog: @catalog,
      catalog_table: @table,
      workspace_lease: @lease,
      runtime_sup: @runtime,
      provider: Fake,
      provider_config: %{server: fake},
      storage_mod: Store,
      storage_opts: [sync: :datasync],
      default_model: "fake:chat",
      tools: []
    ]

    {opts, fake}
  end

  defp seed(i, opts) do
    sid = "synth-" <> String.pad_leading(Integer.to_string(i), 2, "0")

    total =
      cond do
        i <= 20 -> 1 * @mib
        i <= 35 -> 2 * @mib
        i <= 45 -> 4 * @mib
        i <= 51 -> 8 * @mib
        true -> 15 * @mib + div(@mib, 2)
      end

    text_bytes = div(total, div(@entries, 2))
    cwd = opts[:default_cwd]

    {:ok, _} =
      Catalog.put_session(@catalog, %{session_id: sid, cwd: cwd, env_id: "host", title: sid})

    dir = Path.join([opts[:data_dir], "sessions", sid])
    {:ok, store} = Store.open(dir: dir, session_id: sid, cwd: cwd, sync: :datasync)

    {:ok, %{stored: 1, refused: nil}, store} =
      Store.commit(
        store,
        [
          [
            {:put_session_meta,
             %{session_id: sid, cwd: cwd, env_id: "host", title: sid, clean_close: true}}
          ]
        ]
      )

    store =
      1..@entries
      |> Enum.chunk_every(16)
      |> Enum.reduce(store, fn numbers, acc ->
        writes =
          for n <- numbers do
            kind = if rem(n, 2) == 1, do: "user", else: "assistant"
            prefix = "Synthetic #{sid} entry #{n}: "

            text =
              if kind == "assistant",
                do: prefix <> :binary.copy("x", text_bytes - byte_size(prefix)),
                else: prefix <> "fixture question"

            entry = %{
              id: n + 1,
              conversation_id: 1,
              kind: kind,
              data: %{"content" => [%{"type" => "text", "text" => text}]},
              created_at: @epoch + n * 1_000
            }

            {:append_entry, entry}
          end

        {:ok, %{stored: 1, refused: nil}, next} = Store.commit(acc, [writes])
        next
      end)

    :ok = Store.close(store)

    %{
      "sid" => sid,
      "index" => i,
      "wal_bytes" => File.stat!(Path.join(dir, "commit.log")).size,
      "last_entry_text_bytes" => text_bytes
    }
  end

  defp open_and_monitor(fixture, target, sub_pid, sub_ref, opts) do
    %{"sid" => sid, "index" => i} = fixture
    t0 = now()

    {:ok, %{session: %{loaded: true, status: "ok", active: false}}} =
      Daemon.get_session_detail(sid, opts)

    opened = now()
    [{pid, marker}] = Registry.lookup(@registry, {:session, sid})
    ref = Process.monitor(pid)

    cursor =
      if sid == target do
        send(sub_pid, {:subscribe, sub_ref})

        receive do
          {:subscribed, ^sub_ref, cursor} -> cursor
        after
          5_000 -> raise "subscriber setup timed out"
        end
      end

    Map.merge(fixture, %{
      "kind" => if(rem(i, 2) == 0, do: "read", else: "write"),
      "first_open_ms" => ms(opened - t0),
      "quiet_from" => if(cursor, do: now(), else: opened),
      "pid" => pid,
      "monitor" => ref,
      "marker" => marker,
      "subscriber_cursor" => cursor,
      "subscriber_pid" => if(cursor, do: sub_pid),
      "subscriber_ref" => if(cursor, do: sub_ref)
    })
  end

  defp retirements(starts, timeout) do
    pending = Map.new(starts, &{&1["monitor"], &1})
    deadline = now() + (timeout + 30_000) * 1_000
    collect_down(pending, deadline, []) |> Enum.sort_by(& &1["sid"])
  end

  defp collect_down(pending, _deadline, done) when map_size(pending) == 0, do: done

  defp collect_down(pending, deadline, done) do
    receive do
      {:DOWN, ref, :process, _pid, {:shutdown, :idle_unload}} when is_map_key(pending, ref) ->
        observed = now()
        {item, pending} = Map.pop!(pending, ref)
        true = SessionSupervisor.idly_retired?(item["marker"])

        result = %{
          "sid" => item["sid"],
          "quiet_to_down_ms" => ms(observed - item["quiet_from"]),
          "down_reason" => "shutdown:idle_unload",
          "retired_marker" => true
        }

        collect_down(pending, deadline, [result | done])

      {:DOWN, ref, :process, _pid, reason} when is_map_key(pending, ref) ->
        raise "unexpected shutdown for #{pending[ref]["sid"]}: #{inspect(reason)}"
    after
      max(div(deadline - now(), 1_000), 0) ->
        raise "missing retirements: #{inspect(Enum.map(pending, fn {_, x} -> x["sid"] end))}"
    end
  end

  defp await_no_wrappers! do
    1..250
    |> Enum.reduce_while(nil, fn _, _ ->
      if DynamicSupervisor.count_children(@runtime).active == 0 do
        {:halt, :ok}
      else
        Process.sleep(5)
        {:cont, nil}
      end
    end)
    |> then(fn :ok -> :ok end)
  end

  defp memory(label, opts, expected_loaded) do
    m = :erlang.memory() |> Map.new()
    processes = :erlang.system_info(:process_count)
    {rss, 0} = System.cmd("/bin/ps", ["-o", "rss=", "-p", System.pid()])
    list = Daemon.list_sessions(opts)
    55 = length(list)
    true = Enum.all?(list, &(&1.status == "ok" and &1.active == false and &1.archived == false))
    ^expected_loaded = Enum.count(list, & &1.loaded)

    ^expected_loaded =
      Enum.count(list, &(Registry.lookup(@registry, {:session, &1.session_id}) != []))

    ^expected_loaded =
      Enum.count(list, &(Registry.lookup(@registry, {:session_supervisor, &1.session_id}) != []))

    ^expected_loaded = DynamicSupervisor.count_children(@runtime).active

    result = %{
      "label" => label,
      "beam_bytes" => m.total,
      "beam_binary_bytes" => m.binary,
      "rss_bytes" => String.to_integer(String.trim(rss)) * 1_024,
      "beam_processes" => processes,
      "loaded" => expected_loaded,
      "runtime_wrappers" => expected_loaded,
      "catalog_rows" => length(list),
      "utc" => DateTime.to_iso8601(DateTime.utc_now())
    }

    emit("memory", result)
    result
  end

  defp wake(item, opts) do
    %{"sid" => sid, "pid" => old, "kind" => kind} = item
    [] = Registry.lookup(@registry, {:session, sid})
    [] = Registry.lookup(@registry, {:session_supervisor, sid})

    result =
      case kind do
        "read" ->
          wake_ms = read_last(item, opts)
          %{"wake_ms" => wake_ms, "warm_ms" => read_last(item, opts)}

        "write" ->
          {wake_ms, seq} = write_note(sid, "cold-note", opts)
          verify_existing_subscriber(item, seq)
          {warm_ms, warm_seq} = write_note(sid, "warm-note", opts)
          true = warm_seq > seq

          {:ok, %{items: [warm, cold, old_last]}} =
            Daemon.scan_entries(sid, "1", %{"limit" => "3"}, opts)

          %{"content" => [%{"text" => "cold-note"}]} = cold.data
          %{"content" => [%{"text" => "warm-note"}]} = warm.data
          verify_last(old_last, item)
          %{"wake_ms" => wake_ms, "warm_ms" => warm_ms, "committed_seq" => seq}
      end

    [{pid, _}] = Registry.lookup(@registry, {:session, sid})
    true = Process.alive?(pid) and pid != old
    item |> Map.take(["sid", "kind", "wal_bytes", "first_open_ms"]) |> Map.merge(result)
  end

  defp read_last(item, opts) do
    t0 = now()
    {:ok, %{items: [entry]}} = Daemon.scan_entries(item["sid"], "1", %{"limit" => "1"}, opts)
    elapsed = now() - t0
    verify_last(entry, item)
    ms(elapsed)
  end

  defp verify_last(entry, item) do
    %{id: "161", kind: "assistant", data: %{"content" => [%{"text" => text}]}} = entry
    true = byte_size(text) == item["last_entry_text_bytes"]
    true = String.starts_with?(text, "Synthetic #{item["sid"]} entry 160: ")
  end

  defp write_note(sid, text, opts) do
    command = %{
      "version" => 1,
      "request_id" => text <> "-" <> sid,
      "command" => "submit",
      "conversation_id" => "1",
      "args" => %{"type" => "write", "content" => text}
    }

    t0 = now()
    {:ok, %{seq: seq}} = Daemon.execute_command(sid, command, opts)
    {ms(now() - t0), seq}
  end

  defp subscriber(sid, opts) do
    parent = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        receive do
          {:subscribe, ^ref} ->
            {:ok, {:snapshot, cursor, _bin}} =
              Daemon.subscribe_conversation(sid, "1", self(), nil, opts)

            send(parent, {:subscribed, ref, cursor})

            receive do
              {:commit_frame, seq, bin} ->
                %{
                  "prev_seq" => ^cursor,
                  "seq" => ^seq,
                  "appended_entries" => [%{"data" => %{"content" => [%{"text" => "cold-note"}]}}]
                } = JSON.decode!(bin)

                send(parent, {:subscriber_commit, ref, seq})
            end
        end
      end)

    {pid, ref}
  end

  defp verify_existing_subscriber(%{"subscriber_pid" => nil}, _seq), do: :ok

  defp verify_existing_subscriber(item, seq) do
    ref = item["subscriber_ref"]
    true = seq > item["subscriber_cursor"]

    receive do
      {:subscriber_commit, ^ref, ^seq} -> :ok
    after
      3_000 -> raise "existing subscriber did not receive the wake commit"
    end
  end

  defp stats(values) do
    xs = Enum.sort(values)
    n = length(xs)
    p = &Enum.at(xs, ceil(n * &1) - 1)
    %{"count" => n, "min" => hd(xs), "p50" => p.(0.5), "p95" => p.(0.95), "max" => List.last(xs)}
  end

  defp emit(name, data), do: IO.puts(name <> " " <> JSON.encode!(data))
  defp now, do: System.monotonic_time(:microsecond)
  defp ms(us), do: us / 1_000
end

IdleAcceptance.main(System.argv())
