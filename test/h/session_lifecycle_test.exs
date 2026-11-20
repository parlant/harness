defmodule H.SessionLifecycleTest do
  use ExUnit.Case, async: true

  alias H.{Auth, Catalog, Daemon, StoreLock, WorkspaceLease}
  alias H.HTTP.Router
  alias H.Provider.Fake
  alias H.Session.{Server, Supervisor}

  defmodule GatedBashTool do
    @behaviour H.Tool

    @impl true
    def name, do: "bash"

    @impl true
    def description, do: "Gated bash tool for lifecycle tests"

    @impl true
    def parameters_schema do
      %{"type" => "object", "properties" => %{"command" => %{"type" => "string"}}}
    end

    @impl true
    def replay, do: :unsafe

    @impl true
    def mutating?, do: true

    @impl true
    def execute(_args, ctx) do
      if gate_pid = :persistent_term.get({__MODULE__, ctx.session_id}, nil) do
        ref = make_ref()
        send(gate_pid, {:tool_entered, ctx.session_id, ctx.conversation_id, self(), ref})

        receive do
          {:release_tool, ^ref} -> :ok
        after
          5_000 -> :ok
        end
      end

      {:ok, %{content: [%{type: "text", text: "bash done"}], details: %{}, is_error: false}}
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  defp start_daemon_stack(opts) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-session-lifecycle-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd_a = Path.join(tmp_root, "workspace-a")
    cwd_b = Path.join(tmp_root, "workspace-b")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd_a)
    File.mkdir_p!(cwd_b)

    on_exit(fn ->
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    registry = :"H.LifecycleTest.Registry.#{id}"
    pubsub = :"H.LifecycleTest.PubSub.#{id}"
    catalog = :"H.LifecycleTest.Catalog.#{id}"
    catalog_table = :"h_lifecycle_test_catalog_#{id}"
    auth = :"H.LifecycleTest.Auth.#{id}"
    auth_table = :"h_lifecycle_test_auth_#{id}"
    lease = :"H.LifecycleTest.Lease.#{id}"
    runtime_sup = :"H.LifecycleTest.RuntimeSup.#{id}"
    fake_name = :"H.LifecycleTest.Fake.#{id}"

    start_supervised!({StoreLock, data_dir: data_dir, name: :"H.LifecycleTest.Lock.#{id}"})
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Auth, data_dir: data_dir, name: auth, table: auth_table})

    start_supervised!(
      {Catalog,
       data_dir: data_dir, name: catalog, table: catalog_table, pubsub: pubsub, registry: registry}
    )

    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

    fake =
      start_supervised!({Fake, name: fake_name, script: Keyword.get(opts, :script, [])})

    daemon_opts =
      [
        data_dir: data_dir,
        registry: registry,
        pubsub: pubsub,
        catalog: catalog,
        catalog_table: catalog_table,
        workspace_lease: lease,
        runtime_sup: runtime_sup,
        provider: Fake,
        provider_config: %{server: fake},
        storage_mod: H.Storage.File,
        storage_opts: [sync: :none],
        default_model: "fake:chat"
      ]
      |> Keyword.merge(Keyword.get(opts, :daemon_opts, []))

    router_opts =
      Keyword.merge(
        [
          auth_server: auth,
          auth_table: auth_table,
          daemon: Daemon,
          daemon_opts: daemon_opts,
          sse_keepalive_ms: 15_000
        ],
        Keyword.get(opts, :router_opts, [])
      )

    bandit =
      start_supervised!(
        {Bandit,
         plug: {Router, router_opts},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [num_acceptors: 2, shutdown_timeout: 100]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    token = Auth.owner_token(auth_table)

    %{
      id: id,
      tmp_root: tmp_root,
      data_dir: data_dir,
      cwd_a: cwd_a,
      cwd_b: cwd_b,
      registry: registry,
      pubsub: pubsub,
      catalog: catalog,
      catalog_table: catalog_table,
      runtime_sup: runtime_sup,
      fake: fake,
      daemon_opts: daemon_opts,
      base_url: "http://127.0.0.1:#{port}",
      headers: [{"authorization", "Bearer #{token}"}]
    }
  end

  defp cmd(req_id, command, cid, args) do
    %{
      "version" => 1,
      "request_id" => req_id,
      "conversation_id" => cid,
      "command" => command,
      "args" => args
    }
  end

  defp next_sse_event(resp, buffer \\ "", timeout \\ 3_000) do
    case :binary.split(buffer, "\n\n") do
      [raw_frame, rest] ->
        {:ok, parse_sse_frame(raw_frame), rest}

      [_incomplete] ->
        receive_sse_chunk(resp, buffer, timeout)
    end
  end

  defp receive_sse_chunk(%{body: %Req.Response.Async{ref: ref}} = resp, buffer, timeout) do
    receive do
      {^ref, _} = msg ->
        case Req.parse_message(resp, msg) do
          {:ok, [data: chunk]} ->
            next_sse_event(resp, buffer <> chunk, timeout)

          {:ok, [:done]} ->
            {:done, buffer}

          {:ok, [_other]} ->
            receive_sse_chunk(resp, buffer, timeout)

          {:error, reason} ->
            {:error, reason}
        end
    after
      timeout -> :timeout
    end
  end

  defp parse_sse_frame(raw_frame) do
    if String.starts_with?(raw_frame, ":") do
      %{raw: raw_frame, comment: true, id: nil, event: nil, data: nil}
    else
      parsed =
        raw_frame
        |> String.split("\n")
        |> Enum.reduce(%{id: nil, event: nil, data_lines: []}, fn line, acc ->
          cond do
            String.starts_with?(line, "id:") ->
              %{acc | id: line |> String.trim_leading("id:") |> String.trim_leading()}

            String.starts_with?(line, "event:") ->
              %{acc | event: line |> String.trim_leading("event:") |> String.trim_leading()}

            String.starts_with?(line, "data:") ->
              d = line |> String.trim_leading("data:") |> String.trim_leading()
              %{acc | data_lines: [d | acc.data_lines]}

            true ->
              acc
          end
        end)

      data_str = parsed.data_lines |> Enum.reverse() |> Enum.join("\n")

      %{
        raw: raw_frame,
        comment: false,
        id: parsed.id,
        event: parsed.event,
        data: JSON.decode!(data_str)
      }
    end
  end

  defp wait_for_catalog_event(resp, buf, pred, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_catalog_event(resp, buf, pred, deadline)
  end

  defp do_wait_for_catalog_event(resp, buf, pred, deadline) do
    remaining = max(1, deadline - System.monotonic_time(:millisecond))

    case next_sse_event(resp, buf, remaining) do
      {:ok, ev, next_buf} ->
        if pred.(ev) do
          {ev, next_buf}
        else
          do_wait_for_catalog_event(resp, next_buf, pred, deadline)
        end

      other ->
        flunk("expected matching SSE event before timeout, got: #{inspect(other)}")
    end
  end

  defp wait_until(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if res = fun.() do
      res
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for condition")
      else
        Process.sleep(15)
        do_wait_until(fun, deadline)
      end
    end
  end

  describe "triage_session/3" do
    test "tracks needs_attention transitions, manual triage, and restart persistence" do
      gen_gate = make_ref()
      test_pid = self()

      ctx =
        start_daemon_stack(
          script: [
            # Turn 1: gated generation -> idle
            {:gate, [], test_pid, gen_gate,
             %{content: [%{type: "text", text: "done 1"}], finish_reason: "stop"}},
            # Turn 2: retryable error (sleeping) -> non-retryable error (error)
            {:error, %{code: "rate_limit", message: "slow down", retryable: true}},
            {:error, %{code: "fatal_err", message: "boom", retryable: false}}
          ],
          daemon_opts: [retry_limit: 1, retry_backoff_ms: 80]
        )

      # Seed an unloaded session directly in catalog
      {:ok, dormant} =
        Catalog.put_session(ctx.catalog, %{
          session_id: "dormant-1",
          cwd: ctx.cwd_a,
          title: "Dormant"
        })

      assert dormant.needs_attention == true
      assert dormant.archived == false
      assert [] == Registry.lookup(ctx.registry, {:session, "dormant-1"})

      sse =
        Req.get!("#{ctx.base_url}/api/v1/sessions/events",
          headers: ctx.headers,
          into: :self,
          retry: false
        )

      {:ok, snap, buf} = next_sse_event(sse)
      assert [snap_dormant] = snap.data["sessions"]
      assert snap_dormant["session_id"] == "dormant-1"
      assert snap_dormant["needs_attention"] == true
      assert snap_dormant["archived"] == false
      assert snap_dormant["loaded"] == false
      assert snap_dormant["cwd_exists"] == true

      # Manual triage toggle via HTTP on unloaded session MUST NOT wake it!
      bad_triage =
        Req.post!("#{ctx.base_url}/api/v1/sessions/dormant-1/triage",
          headers: ctx.headers,
          json: %{"needs_attention" => "nope"},
          retry: false
        )

      assert bad_triage.status == 422

      missing_triage =
        Req.post!("#{ctx.base_url}/api/v1/sessions/missing-sid/triage",
          headers: ctx.headers,
          json: %{"needs_attention" => false},
          retry: false
        )

      assert missing_triage.status == 404

      triage_off =
        Req.post!("#{ctx.base_url}/api/v1/sessions/dormant-1/triage",
          headers: ctx.headers,
          json: %{"needs_attention" => false},
          retry: false
        )

      assert triage_off.status == 200
      assert triage_off.body["session"]["needs_attention"] == false
      assert triage_off.body["session"]["loaded"] == false
      assert [] == Registry.lookup(ctx.registry, {:session, "dormant-1"})

      {ev_triage_off, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "dormant-1" and
            ev.data["session"]["needs_attention"] == false
        end)

      assert ev_triage_off.data["session"]["loaded"] == false

      # Create live session -> needs_attention: true, loaded: true
      create_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions",
          headers: ctx.headers,
          json: %{"session_id" => "live-1", "cwd" => ctx.cwd_a}
        )

      assert create_resp.status == 200
      assert create_resp.body["session"]["needs_attention"] == true
      assert create_resp.body["session"]["loaded"] == true
      assert create_resp.body["session"]["archived"] == false
      assert create_resp.body["session"]["cwd_exists"] == true

      {_ev_created, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "live-1" and
            ev.data["session"]["loaded"] == true
        end)

      # Submit prompt -> running automatically clears needs_attention: false
      assert {:ok, _} =
               Daemon.execute_command(
                 "live-1",
                 cmd("r-1", "submit", "1", %{"type" => "input", "content" => "Hello"}),
                 ctx.daemon_opts
               )

      assert_receive {:gate_entered, ^gen_gate, worker_pid}, 2_000

      {ev_running, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "live-1" and
            ev.data["session"]["attention"] == "running"
        end)

      assert ev_running.data["session"]["needs_attention"] == false

      # Release gate -> settles to idle and auto-flips needs_attention: true!
      send(worker_pid, {:release, gen_gate})

      {ev_settled, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "live-1" and
            ev.data["session"]["attention"] == "idle"
        end)

      assert ev_settled.data["session"]["needs_attention"] == true

      # Dismiss attention, then retrying work stays cleared until it fails.
      assert {:ok, %{session: %{needs_attention: false}}} =
               Daemon.triage_session("live-1", %{"needs_attention" => false}, ctx.daemon_opts)

      assert {:ok, _} =
               Daemon.execute_command(
                 "live-1",
                 cmd("r-2", "submit", "1", %{"type" => "input", "content" => "Fail please"}),
                 ctx.daemon_opts
               )

      {ev_retrying, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "live-1" and
            ev.data["session"]["attention"] == "retrying"
        end)

      assert ev_retrying.data["session"]["needs_attention"] == false

      {ev_error, _buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "live-1" and
            ev.data["session"]["attention"] == "error"
        end)

      assert ev_error.data["session"]["needs_attention"] == true

      # Quarantine dormant-1 -> sets needs_attention: true, and user can still dismiss it!
      {:ok, q_entry} = Catalog.quarantine(ctx.catalog, "dormant-1", :corrupt_wal)
      assert q_entry.needs_attention == true

      dismiss_q =
        Req.post!("#{ctx.base_url}/api/v1/sessions/dormant-1/triage",
          headers: ctx.headers,
          json: %{"needs_attention" => false}
        )

      assert dismiss_q.status == 200
      assert dismiss_q.body["session"]["status"] == "quarantined"
      assert dismiss_q.body["session"]["needs_attention"] == false

      # Verify persistence across Catalog restart
      Req.cancel_async_response(sse)
      stop_supervised!(Catalog)

      cat2 = :"H.LifecycleTest.CatalogReloaded.#{ctx.id}"
      tab2 = :"h_lifecycle_test_catalog_reloaded_#{ctx.id}"

      start_supervised!(
        {Catalog,
         data_dir: ctx.data_dir,
         name: cat2,
         table: tab2,
         pubsub: ctx.pubsub,
         registry: ctx.registry}
      )

      assert {:ok, %{needs_attention: false, status: "quarantined"}} =
               Catalog.get_session("dormant-1", tab2)

      assert {:ok, %{needs_attention: true, attention: "error"}} =
               Catalog.get_session("live-1", tab2)
    end
  end

  describe "stop_session/3" do
    test "aborts active generation, tool, and user_shell tasks across conversations" do
      gen_gate = make_ref()
      test_pid = self()

      ctx =
        start_daemon_stack(
          script: [
            # Initial turn to create entry 1+2 for forking
            {:reply, [],
             %{content: [%{type: "text", text: "root reply"}], finish_reason: "stop"}},
            # Conv 1: calls gated bash tool
            {:reply, [],
             %{
               content: [],
               tool_calls: [%{id: "tc_stop", name: "bash", arguments: %{"command" => "sleep 10"}}],
               finish_reason: "tool_calls"
             }},
            # Conv 2 (fork): gated generation
            {:gate, [%{type: :text_delta, text: "partial stream", metadata: %{}}], test_pid,
             gen_gate, %{content: [%{type: "text", text: "never"}], finish_reason: "stop"}}
          ],
          daemon_opts: [tools: [GatedBashTool]]
        )

      :persistent_term.put({GatedBashTool, "multi-stop"}, test_pid)
      on_exit(fn -> :persistent_term.erase({GatedBashTool, "multi-stop"}) end)

      {:ok, _} =
        Daemon.create_session(
          %{"session_id" => "multi-stop", "cwd" => ctx.cwd_a},
          ctx.daemon_opts
        )

      # Seed initial turn
      {:ok, _} =
        Daemon.execute_command(
          "multi-stop",
          cmd("m-1", "submit", "1", %{"type" => "input", "content" => "Init"}),
          ctx.daemon_opts
        )

      wait_until(fn ->
        {:ok, detail} = Daemon.get_session_detail("multi-stop", ctx.daemon_opts)
        detail.session.attention == "idle"
      end)

      {:ok, %{items: [first_entry | _]}} =
        Daemon.scan_entries("multi-stop", "1", %{"order" => "asc"}, ctx.daemon_opts)

      # Fork conversation 2 and conversation 3
      {:ok, fork2} =
        Daemon.execute_command(
          "multi-stop",
          cmd("m-fork-2", "fork", "1", %{"at_entry_id" => first_entry.id}),
          ctx.daemon_opts
        )

      cid2 = fork2.conversation_id

      {:ok, fork3} =
        Daemon.execute_command(
          "multi-stop",
          cmd("m-fork-3", "fork", "1", %{"at_entry_id" => first_entry.id}),
          ctx.daemon_opts
        )

      cid3 = fork3.conversation_id

      # Start tool run in Conv 1 (uses cwd_a lease; user_shell in Conv 3 would contend on same workspace lease if started concurrently, so let's verify generation in Conv 2 + tool in Conv 1, or user_shell in another session!)
      # Actually GatedBashTool is mutating? == true, so it acquires workspace lease for {host, cwd_a} under {multi-stop, 1}.
      # Let's start tool in Conv 1 and gated generation in Conv 2!
      {:ok, _} =
        Daemon.execute_command(
          "multi-stop",
          cmd("m-c1", "submit", "1", %{"type" => "input", "content" => "Run tool"}),
          ctx.daemon_opts
        )

      assert_receive {:tool_entered, "multi-stop", 1, tool_pid, tool_ref}, 2_000

      {:ok, _} =
        Daemon.execute_command(
          "multi-stop",
          cmd("m-c2", "submit", cid2, %{"type" => "input", "content" => "Stream gen"}),
          ctx.daemon_opts
        )

      assert_receive {:gate_entered, ^gen_gate, gen_pid}, 2_000

      # Verify session is active and running
      {:ok, before_stop} = Daemon.get_session_detail("multi-stop", ctx.daemon_opts)
      assert before_stop.session.active == true
      assert before_stop.session.attention == "running"

      # Stop entire session via HTTP endpoint
      stop_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/multi-stop/stop",
          headers: ctx.headers,
          json: %{"reason" => "user_stopped_all"}
        )

      assert stop_resp.status == 200
      assert stop_resp.body["session"]["active"] == false
      assert stop_resp.body["session"]["attention"] == "error"
      assert stop_resp.body["session"]["needs_attention"] == true

      # Clean up blocked test processes just in case
      send(tool_pid, {:release_tool, tool_ref})
      send(gen_pid, {:release, gen_gate})

      # Both conversations have all tasks settled to terminal
      {:ok, after_stop} = Daemon.get_session_detail("multi-stop", ctx.daemon_opts)
      assert Enum.all?(after_stop.tasks, &(&1.status == "terminal"))

      # Also verify user_shell stop in Conv 3 now that workspace lease was released!
      {:ok, %{seq: seq_now}} =
        Server.get_detail(elem(hd(Registry.lookup(ctx.registry, {:session, "multi-stop"})), 0))

      {:ok, _} =
        Daemon.execute_command(
          "multi-stop",
          cmd("m-c3-shell", "user_shell", cid3, %{
            "command" => "sleep 30",
            "include_in_context" => false,
            "expected_seq" => seq_now
          }),
          ctx.daemon_opts
        )

      wait_until(fn ->
        {:ok, d} = Daemon.get_session_detail("multi-stop", ctx.daemon_opts)
        d.session.activity_kind == "user_shell"
      end)

      stop_shell_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/multi-stop/stop",
          headers: ctx.headers,
          json: %{}
        )

      assert stop_shell_resp.status == 200
      assert stop_shell_resp.body["session"]["active"] == false

      {:ok, shell_entries} =
        Daemon.scan_entries("multi-stop", cid3, %{"order" => "desc"}, ctx.daemon_opts)

      assert Enum.any?(
               shell_entries.items,
               &(&1.kind == "user_shell" and &1.data["cancelled"] == true)
             )
    end
  end

  describe "archive_session/3" do
    test "enforces session_busy unless stop, unloads cleanly without quarantine, and auto-unarchives on reopen" do
      gen_gate = make_ref()
      test_pid = self()

      ctx =
        start_daemon_stack(
          script: [
            {:gate, [], test_pid, gen_gate,
             %{content: [%{type: "text", text: "never"}], finish_reason: "stop"}},
            {:reply, [],
             %{content: [%{type: "text", text: "reopened reply"}], finish_reason: "stop"}}
          ]
        )

      {:ok, _} =
        Daemon.create_session(%{"session_id" => "arch-busy", "cwd" => ctx.cwd_a}, ctx.daemon_opts)

      {:ok, _} =
        Daemon.create_session(%{"session_id" => "arch-idle", "cwd" => ctx.cwd_b}, ctx.daemon_opts)

      # Verify both are registered in both {:session, sid} and {:session_supervisor, sid}
      assert [{_, _}] = Registry.lookup(ctx.registry, {:session, "arch-idle"})
      assert [{_, _}] = Registry.lookup(ctx.registry, {:session_supervisor, "arch-idle"})

      # 1. Unload/archive idle session cleanly -> status stays "ok", loaded: false, archived: true, needs_attention: false
      idle_arch =
        Req.post!("#{ctx.base_url}/api/v1/sessions/arch-idle/archive",
          headers: ctx.headers,
          json: %{}
        )

      assert idle_arch.status == 200
      assert idle_arch.body["session"]["status"] == "ok"
      assert idle_arch.body["session"]["archived"] == true
      assert idle_arch.body["session"]["needs_attention"] == false
      assert idle_arch.body["session"]["loaded"] == false
      assert [] == Registry.lookup(ctx.registry, {:session, "arch-idle"})
      assert [] == Registry.lookup(ctx.registry, {:session_supervisor, "arch-idle"})

      # 2. Start turn on arch-busy -> archive without stop returns 409 "session_busy"
      {:ok, _} =
        Daemon.execute_command(
          "arch-busy",
          cmd("ab-1", "submit", "1", %{"type" => "input", "content" => "Hold busy"}),
          ctx.daemon_opts
        )

      assert_receive {:gate_entered, ^gen_gate, worker_pid}, 2_000

      conflict_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/arch-busy/archive",
          headers: ctx.headers,
          json: %{},
          retry: false
        )

      assert conflict_resp.status == 409
      assert conflict_resp.body == %{"error" => "session_busy"}
      assert [{_, _}] = Registry.lookup(ctx.registry, {:session, "arch-busy"})

      # 3. Archive busy session WITH stop: true -> aborts work, persists clean_close, unloads OTP processes without quarantine!
      force_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/arch-busy/archive",
          headers: ctx.headers,
          json: %{"stop" => true}
        )

      send(worker_pid, {:release, gen_gate})

      assert force_resp.status == 200
      assert force_resp.body["session"]["status"] == "ok"
      assert force_resp.body["session"]["archived"] == true
      assert force_resp.body["session"]["active"] == false
      assert force_resp.body["session"]["needs_attention"] == false
      assert force_resp.body["session"]["loaded"] == false
      assert [] == Registry.lookup(ctx.registry, {:session, "arch-busy"})
      assert [] == Registry.lookup(ctx.registry, {:session_supervisor, "arch-busy"})

      # Verify GET /api/v1/sessions optional archived query filter (without waking!)
      all_s = Req.get!("#{ctx.base_url}/api/v1/sessions", headers: ctx.headers).body["sessions"]
      assert length(all_s) == 2

      active_only =
        Req.get!("#{ctx.base_url}/api/v1/sessions?archived=false", headers: ctx.headers).body[
          "sessions"
        ]

      assert active_only == []

      archived_only =
        Req.get!("#{ctx.base_url}/api/v1/sessions?archived=true", headers: ctx.headers).body[
          "sessions"
        ]

      assert length(archived_only) == 2
      assert [] == Registry.lookup(ctx.registry, {:session, "arch-idle"})

      # 4. Explicit unarchive via archived: false keeps session unloaded until opened
      unarch_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/arch-idle/archive",
          headers: ctx.headers,
          json: %{"archived" => false}
        )

      assert unarch_resp.status == 200
      assert unarch_resp.body["session"]["archived"] == false
      assert unarch_resp.body["session"]["needs_attention"] == true
      assert unarch_resp.body["session"]["loaded"] == false
      assert [] == Registry.lookup(ctx.registry, {:session, "arch-idle"})

      # Re-archive arch-idle, then attach via POST /api/v1/sessions -> auto-unarchives and loads!
      assert {:ok, %{session: %{archived: true, loaded: false}}} =
               Daemon.archive_session("arch-idle", %{}, ctx.daemon_opts)

      attach_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions",
          headers: ctx.headers,
          json: %{"session_id" => "arch-idle", "cwd" => ctx.cwd_b}
        )

      assert attach_resp.status == 200
      assert attach_resp.body["session"]["archived"] == false
      assert attach_resp.body["session"]["loaded"] == true

      # 5. Inspecting an archived session (detail, entries, SSE snapshot) reads cold from disk
      #    WITHOUT unarchiving or booting H.Session.Server!
      detail_resp =
        Req.get!("#{ctx.base_url}/api/v1/sessions/arch-busy", headers: ctx.headers)

      assert detail_resp.status == 200
      assert detail_resp.body["session"]["archived"] == true
      assert detail_resp.body["session"]["attention"] == "archived"
      assert detail_resp.body["session"]["loaded"] == false
      assert detail_resp.body["session"]["status"] == "ok"
      assert detail_resp.body["session"]["session_id"] == "arch-busy"
      assert [] == Registry.lookup(ctx.registry, {:session, "arch-busy"})

      cold_entries_resp =
        Req.get!(
          "#{ctx.base_url}/api/v1/sessions/arch-busy/conversations/1/entries?order=asc",
          headers: ctx.headers
        )

      assert cold_entries_resp.status == 200
      assert [_ | _] = cold_entries_resp.body["items"]
      assert [] == Registry.lookup(ctx.registry, {:session, "arch-busy"})

      assert {:ok, {:snapshot, cold_seq, cold_snap_bin}} =
               Daemon.subscribe_conversation("arch-busy", "1", self(), nil, ctx.daemon_opts)

      assert is_integer(cold_seq) and cold_seq > 0
      assert [_ | _] = JSON.decode!(cold_snap_bin)["entries"]
      assert [] == Registry.lookup(ctx.registry, {:session, "arch-busy"})

      # 6. Sending a command to an archived native session auto-unarchives, boots OTP, and streams commits!
      {:ok, _} =
        Daemon.execute_command(
          "arch-busy",
          cmd("ab-2", "submit", "1", %{"type" => "input", "content" => "Back to work"}),
          ctx.daemon_opts
        )

      assert [{_, _}] = Registry.lookup(ctx.registry, {:session, "arch-busy"})
      assert_receive {:commit_frame, resumed_seq, _resumed_bin}, 2_000
      assert resumed_seq > cold_seq

      wait_until(fn ->
        {:ok, d} = Daemon.get_session_detail("arch-busy", ctx.daemon_opts)
        d.session.archived == false and d.session.loaded == true and d.session.attention == "idle"
      end)

      # Quarantined sessions can be archived (dismissed out of active Inbox), but not unarchived
      {:ok, _} = Catalog.put_session(ctx.catalog, %{session_id: "arch-quar", cwd: ctx.cwd_a})
      {:ok, _} = Catalog.quarantine(ctx.catalog, "arch-quar", "storage_corrupt")

      quar_arch =
        Req.post!("#{ctx.base_url}/api/v1/sessions/arch-quar/archive",
          headers: ctx.headers,
          json: %{"archived" => true},
          retry: false
        )

      assert quar_arch.status == 200
      assert quar_arch.body["session"]["archived"] == true
      assert quar_arch.body["session"]["needs_attention"] == false
      assert quar_arch.body["session"]["status"] == "quarantined"

      quar_unarch =
        Req.post!("#{ctx.base_url}/api/v1/sessions/arch-quar/archive",
          headers: ctx.headers,
          json: %{"archived" => false},
          retry: false
        )

      assert quar_unarch.status == 503
    end
  end

  describe "fork_session/3" do
    test "serves deleted cwd sessions read-only, returns 409 cwd_missing on work commands, and forks to existing cwd" do
      ephemeral_cwd =
        Path.join(
          System.tmp_dir!(),
          "h-ephemeral-worktree-#{System.unique_integer([:positive])}"
        )

      target_cwd =
        Path.join(
          System.tmp_dir!(),
          "h-recovered-worktree-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(ephemeral_cwd)
      File.mkdir_p!(target_cwd)
      File.write!(Path.join(target_cwd, "AGENTS.md"), "Target directory instructions.")

      on_exit(fn ->
        File.rm_rf(ephemeral_cwd)
        File.rm_rf(target_cwd)
      end)

      ctx =
        start_daemon_stack(
          script: [
            {:reply, [],
             %{content: [%{type: "text", text: "Worktree answer 1"}], finish_reason: "stop"}},
            {:expect,
             fn req ->
               # Forked session should carry prior user + assistant history AND new target_cwd AGENTS.md!
               sys = hd(req.messages)
               assert sys.role == "system"
               assert hd(sys.content).text =~ "Target directory instructions."

               roles = Enum.map(tl(req.messages), & &1.role)
               assert roles == ["user", "assistant", "user"]
               true
             end,
             {:reply, [],
              %{content: [%{type: "text", text: "Continued in new cwd!"}], finish_reason: "stop"}}}
          ],
          daemon_opts: [stop_dir: target_cwd]
        )

      # 1. Create session in ephemeral_cwd and run a turn
      {:ok, _} =
        Daemon.create_session(
          %{
            "session_id" => "dead-cwd-sess",
            "cwd" => ephemeral_cwd,
            "title" => "Subagent Worktree",
            "agent" => %{"thinking" => "high"}
          },
          ctx.daemon_opts
        )

      {:ok, _} =
        Daemon.execute_command(
          "dead-cwd-sess",
          cmd("dc-1", "submit", "1", %{"type" => "input", "content" => "Investigate bug"}),
          ctx.daemon_opts
        )

      wait_until(fn ->
        {:ok, d} = Daemon.get_session_detail("dead-cwd-sess", ctx.daemon_opts)
        d.session.attention == "idle"
      end)

      # Unload session from RAM first, THEN delete ephemeral_cwd (simulating subagent worktree cleanup or daemon restart!)
      :ok = Supervisor.stop_session(ctx.registry, ctx.runtime_sup, "dead-cwd-sess")
      assert [] == Registry.lookup(ctx.registry, {:session, "dead-cwd-sess"})
      File.rm_rf!(ephemeral_cwd)
      refute File.dir?(ephemeral_cwd)

      # Catalog list immediately reflects cwd_exists: false without waking
      [listed] = Daemon.list_sessions(ctx.daemon_opts)
      assert listed.session_id == "dead-cwd-sess"
      assert listed.cwd_exists == false
      assert listed.loaded == false

      # 2. Reading detail, scanning entries, and subscribing to SSE SUCCEED with cwd_exists: false!
      detail_resp =
        Req.get!("#{ctx.base_url}/api/v1/sessions/dead-cwd-sess", headers: ctx.headers)

      assert detail_resp.status == 200
      assert detail_resp.body["session"]["cwd_exists"] == false
      assert detail_resp.body["session"]["loaded"] == true

      entries_resp =
        Req.get!(
          "#{ctx.base_url}/api/v1/sessions/dead-cwd-sess/conversations/1/entries?order=asc",
          headers: ctx.headers
        )

      assert entries_resp.status == 200
      assert length(entries_resp.body["items"]) == 2
      first_entry_id = hd(entries_resp.body["items"])["id"]

      assert {:ok, {:snapshot, seq_now, _snap_bin}} =
               Daemon.subscribe_conversation("dead-cwd-sess", "1", self(), nil, ctx.daemon_opts)

      # 3. Work-starting commands return 409 "cwd_missing"
      for {name, args} <- [
            {"submit", %{"type" => "input", "content" => "Try input"}},
            {"submit", %{"type" => "continue"}},
            {"fork_and_submit", %{"at_entry_id" => first_entry_id, "content" => "Try fork+sub"}},
            {"user_shell",
             %{"command" => "ls", "include_in_context" => false, "expected_seq" => seq_now}},
            {"compact", %{"expected_seq" => seq_now}}
          ] do
        r =
          Req.post!("#{ctx.base_url}/api/v1/sessions/dead-cwd-sess/commands",
            headers: ctx.headers,
            json: cmd("blocked-#{name}-#{System.unique_integer([:positive])}", name, "1", args),
            retry: false
          )

        assert r.status == 409, "expected 409 for #{name}, got #{r.status}: #{inspect(r.body)}"
        assert r.body == %{"error" => "cwd_missing"}
      end

      # Safe management commands (rename, configure, in-session fork) AND attach via create_session still work!
      attach_missing =
        Req.post!("#{ctx.base_url}/api/v1/sessions",
          headers: ctx.headers,
          json: %{"session_id" => "dead-cwd-sess", "cwd" => ephemeral_cwd},
          retry: false
        )

      assert attach_missing.status == 200
      assert attach_missing.body["session"]["cwd_exists"] == false

      ren_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/dead-cwd-sess/commands",
          headers: ctx.headers,
          json: cmd("safe-ren", "rename", "1", %{"title" => "Deleted Worktree (Archived)"}),
          retry: false
        )

      assert ren_resp.status == 200

      # 4. Remote/unknown environment non-fallback invariant MUST hold!
      {:ok, _} =
        Catalog.put_session(ctx.catalog, %{
          session_id: "offline-remote-vm",
          cwd: target_cwd,
          env_id: "missing-vm"
        })

      offline_resp =
        Req.get!("#{ctx.base_url}/api/v1/sessions/offline-remote-vm",
          headers: ctx.headers,
          retry: false
        )

      assert offline_resp.status == 503
      assert offline_resp.body == %{"error" => "workspace_unavailable"}

      # 5. Forking to a non-existent directory fails with 422
      bad_fork =
        Req.post!("#{ctx.base_url}/api/v1/sessions/dead-cwd-sess/fork",
          headers: ctx.headers,
          json: %{"cwd" => ephemeral_cwd},
          retry: false
        )

      assert bad_fork.status == 422

      # 6. Cross-directory fork via POST /api/v1/sessions/:sid/fork to existing target_cwd!
      fork_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/dead-cwd-sess/fork",
          headers: ctx.headers,
          json: %{
            "cwd" => target_cwd,
            "session_id" => "recovered-sess",
            "title" => "Recovered Worktree"
          }
        )

      assert fork_resp.status == 200
      new_sess = fork_resp.body["session"]
      assert new_sess["session_id"] == "recovered-sess"
      assert new_sess["cwd"] == Path.expand(target_cwd)
      assert new_sess["cwd_exists"] == true
      assert new_sess["loaded"] == true
      assert new_sess["title"] == "Recovered Worktree"

      # Verify visible entries and agent settings (e.g. thinking: "high") were copied into recovered-sess
      {:ok, %{items: copied_items}} =
        Daemon.scan_entries("recovered-sess", "1", %{"order" => "asc"}, ctx.daemon_opts)

      assert Enum.map(copied_items, & &1.kind) == ["user", "assistant"]

      {:ok, {:snapshot, _, rec_snap}} =
        Daemon.subscribe_conversation("recovered-sess", "1", self(), nil, ctx.daemon_opts)

      assert JSON.decode!(rec_snap)["docs"]["agent"]["thinking"] == "high"

      # Submit immediately works in the forked session!
      sub_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/recovered-sess/commands",
          headers: ctx.headers,
          json: cmd("rec-1", "submit", "1", %{"type" => "input", "content" => "Continue here"})
        )

      assert sub_resp.status == 200

      wait_until(fn ->
        {:ok, %{items: items}} =
          Daemon.scan_entries("recovered-sess", "1", %{"order" => "asc"}, ctx.daemon_opts)

        length(items) == 4
      end)
    end

    test "fork_session with at_entry_id copies only prefix up through at_entry_id" do
      ctx =
        start_daemon_stack(
          script: [
            {:reply, [], %{content: [%{type: "text", text: "Answer 1"}], finish_reason: "stop"}},
            {:reply, [], %{content: [%{type: "text", text: "Answer 2"}], finish_reason: "stop"}}
          ]
        )

      {:ok, _} =
        Daemon.create_session(
          %{"session_id" => "src-prefix", "cwd" => ctx.cwd_a},
          ctx.daemon_opts
        )

      {:ok, _} =
        Daemon.execute_command(
          "src-prefix",
          cmd("p-1", "submit", "1", %{"type" => "input", "content" => "Turn 1"}),
          ctx.daemon_opts
        )

      wait_until(fn ->
        {:ok, d} = Daemon.get_session_detail("src-prefix", ctx.daemon_opts)
        d.session.attention == "idle"
      end)

      {:ok, _} =
        Daemon.execute_command(
          "src-prefix",
          cmd("p-2", "submit", "1", %{"type" => "input", "content" => "Turn 2"}),
          ctx.daemon_opts
        )

      wait_until(fn ->
        {:ok, %{items: items}} =
          Daemon.scan_entries("src-prefix", "1", %{"order" => "asc"}, ctx.daemon_opts)

        length(items) == 4
      end)

      {:ok, %{items: [_u1, a1, _u2, _a2]}} =
        Daemon.scan_entries("src-prefix", "1", %{"order" => "asc"}, ctx.daemon_opts)

      # Fork at entry a1 into cwd_b
      {:ok, %{session: forked}} =
        Daemon.fork_session(
          "src-prefix",
          %{"cwd" => ctx.cwd_b, "at_entry_id" => a1.id},
          ctx.daemon_opts
        )

      {:ok, %{items: forked_items}} =
        Daemon.scan_entries(forked.session_id, "1", %{"order" => "asc"}, ctx.daemon_opts)

      assert length(forked_items) == 2
      assert Enum.map(forked_items, & &1.kind) == ["user", "assistant"]
    end
  end
end
