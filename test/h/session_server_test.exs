defmodule H.SessionServerTest do
  use ExUnit.Case, async: true

  alias H.{Catalog, Daemon}
  alias H.Provider.Fake

  defp start_isolated_env(script \\ [], extra_opts \\ []) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-session-test-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    registry = :"H.Test.Registry.#{id}"
    pubsub = :"H.Test.PubSub.#{id}"
    catalog = :"H.Test.Catalog.#{id}"
    catalog_table = :"h_test_catalog_#{id}"
    lease = :"H.Test.Lease.#{id}"
    runtime_sup = :"H.Test.RuntimeSup.#{id}"
    fake_name = :"H.Test.Fake.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({H.WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})
    fake = start_supervised!({Fake, script: script, name: fake_name})

    on_exit(fn -> File.rm_rf(tmp_root) end)

    opts =
      [
        registry: registry,
        pubsub: pubsub,
        catalog: catalog,
        catalog_table: catalog_table,
        workspace_lease: lease,
        runtime_sup: runtime_sup,
        data_dir: data_dir,
        provider: Fake,
        provider_config: %{server: fake},
        storage_mod: H.Storage.File,
        storage_opts: [sync: :none],
        default_model: "fake:chat"
      ] ++ extra_opts

    %{opts: opts, cwd: cwd, data_dir: data_dir, fake: fake, tmp_root: tmp_root}
  end

  defp cmd(req_id, command, cid, args) do
    %{
      "version" => 1,
      "request_id" => req_id,
      "command" => command,
      "conversation_id" => cid,
      "args" => args
    }
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
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
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end

  describe "H.Daemon session & model API" do
    test "list_models, create_session idempotency vs conflict, list_sessions, get_session_detail" do
      %{opts: opts, cwd: cwd, tmp_root: tmp_root} = start_isolated_env()

      models = Daemon.list_models(opts)
      assert Enum.any?(models, &(&1.id == "fake:chat"))

      assert {:ok, %{session: s1, seq: seq1}} =
               Daemon.create_session(
                 %{"session_id" => "s1", "cwd" => cwd, "title" => "First"},
                 opts
               )

      assert s1.session_id == "s1"
      assert s1.root_conversation_id == "1"
      assert seq1 >= 1

      # Idempotent create with matching cwd
      assert {:ok, %{session: ^s1, seq: ^seq1}} =
               Daemon.create_session(%{"session_id" => "s1", "cwd" => cwd}, opts)

      # Conflict on differing cwd
      other_cwd = Path.join(tmp_root, "other")
      File.mkdir_p!(other_cwd)

      assert {:error, {:conflict, _}} =
               Daemon.create_session(%{"session_id" => "s1", "cwd" => other_cwd}, opts)

      assert [%{session_id: "s1", root_conversation_id: "1"}] = Daemon.list_sessions(opts)

      assert {:ok, detail} = Daemon.get_session_detail("s1", opts)
      assert detail.session.session_id == "s1"
      assert [%{id: "1", parent: nil, owner: "ownerless"}] = detail.conversations
      assert detail.tasks == []
    end
  end

  describe "idempotency, configure, fork, fork_and_submit, scan_entries, subscribe" do
    test "deduplicates identical request_id and rejects mismatched payload with conflict" do
      %{opts: opts, cwd: cwd} =
        start_isolated_env([
          {:reply, [],
           %{
             content: [%{type: "text", text: "Hello!"}],
             usage: %{input_tokens: 5, output_tokens: 3}
           }}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-idem", "cwd" => cwd}, opts)

      # Subscribe before submit to receive commit frames
      assert {:ok, {:snapshot, snap_seq, snap_bin}} =
               Daemon.subscribe_conversation("s-idem", "1", self(), nil, opts)

      snap = JSON.decode!(snap_bin)
      assert snap["version"] == 1
      assert snap["session_id"] == "s-idem"
      assert snap["conversation_id"] == "1"
      assert snap["seq"] == snap_seq
      assert snap["entries"] == []
      assert snap["docs"]["agent"]["model"] == "fake:chat"

      envelope =
        cmd("req-1", "submit", "1", %{
          "type" => "input",
          "content" => "Hi there"
        })

      assert {:ok, receipt1} = Daemon.execute_command("s-idem", envelope, opts)
      assert receipt1.status == "placed"

      # Retry exact same request_id + payload -> same receipt, no second LLM turn
      assert {:ok, receipt2} = Daemon.execute_command("s-idem", envelope, opts)
      assert receipt2.submission_id == receipt1.submission_id

      # Different payload with same request_id -> conflict
      bad_envelope =
        cmd("req-1", "submit", "1", %{
          "type" => "input",
          "content" => "Different prompt"
        })

      assert {:error, {:conflict, _}} = Daemon.execute_command("s-idem", bad_envelope, opts)

      # Wait for assistant reply
      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-idem", "1", %{"order" => "asc"}, opts)
        if length(items) == 2, do: items, else: nil
      end)

      # Verify commit frames arrived and replay from snap_seq works
      assert_receive {:commit_frame, c_seq1, _bin1}
      assert_receive {:commit_frame, c_seq2, _bin2}
      assert c_seq2 > c_seq1

      assert {:ok, {:replay, frames}} =
               Daemon.subscribe_conversation("s-idem", "1", self(), snap_seq, opts)

      assert length(frames) == 2
      assert Enum.map(frames, &elem(&1, 0)) == [c_seq1, c_seq2]
    end

    test "configure respects expected_seq, and fork inherits agent as_of at_entry_id" do
      %{opts: opts, cwd: cwd} =
        start_isolated_env([
          {:reply, [], %{content: [%{type: "text", text: "Answer 1"}]}},
          {:expect,
           fn req ->
             assert req.model == "model-v1"
             true
           end, {:reply, [], %{content: [%{type: "text", text: "Fork answer"}]}}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-fork", "cwd" => cwd}, opts)

      assert {:ok, cfg1} =
               Daemon.execute_command(
                 "s-fork",
                 cmd("cfg-1", "configure", "1", %{"model" => "model-v1", "thinking" => "low"}),
                 opts
               )

      # Wrong expected_seq -> conflict
      assert {:error, {:conflict, _}} =
               Daemon.execute_command(
                 "s-fork",
                 cmd("cfg-bad", "configure", "1", %{"model" => "nope", "expected_seq" => 999}),
                 opts
               )

      assert {:ok, _} =
               Daemon.execute_command(
                 "s-fork",
                 cmd("sub-1", "submit", "1", %{"type" => "input", "content" => "Turn 1"}),
                 opts
               )

      entries =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-fork", "1", %{"order" => "asc"}, opts)
          if length(items) == 2, do: items, else: nil
        end)

      answer1_id = Enum.at(entries, 1).id

      # Change model AFTER answer1_id
      assert {:ok, _} =
               Daemon.execute_command(
                 "s-fork",
                 cmd("cfg-2", "configure", "1", %{
                   "model" => "model-v2",
                   "expected_seq" => cfg1.seq
                 })
                 |> then(fn _ ->
                   {:ok, %{items: _}} = Daemon.scan_entries("s-fork", "1", %{}, opts)
                   cmd("cfg-2", "configure", "1", %{"model" => "model-v2"})
                 end),
                 opts
               )

      # fork_and_submit at answer1_id must inherit "model-v1" (as_of) and reset live/usage
      assert {:ok, fork_receipt} =
               Daemon.execute_command(
                 "s-fork",
                 cmd("fork-sub-1", "fork_and_submit", "1", %{
                   "at_entry_id" => answer1_id,
                   "content" => "Branch question"
                 }),
                 opts
               )

      child_cid = fork_receipt.conversation_id
      assert child_cid != "1"

      child_entries =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries("s-fork", child_cid, %{"order" => "asc"}, opts)

          if length(items) == 4, do: items, else: nil
        end)

      assert Enum.map(child_entries, & &1.kind) == ["user", "assistant", "user", "assistant"]

      # Invalid entry ID fork returns bad_request
      assert {:error, {:bad_request, _}} =
               Daemon.execute_command(
                 "s-fork",
                 cmd("fork-bad", "fork", "1", %{"at_entry_id" => "99999"}),
                 opts
               )
    end
  end

  describe "steering, when_idle: reject, follow_up, and abort" do
    test "when_idle: reject fails when idle, steer injects at tool boundary, and follow_up queues after completion" do
      gate1 = make_ref()
      gate2 = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_isolated_env([
          {:gate, [], test_pid, gate1,
           %{
             content: [],
             tool_calls: [%{id: "c1", name: "read", arguments: %{"path" => "a.txt"}}],
             finish_reason: "tool_calls"
           }},
          {:expect,
           fn req ->
             texts =
               Enum.flat_map(req.messages, fn m -> Enum.map(m.content, &Map.get(&1, :text)) end)

             assert "Steer this!" in texts
             refute "Follow up!" in texts
             true
           end, {:gate, [], test_pid, gate2, %{content: [%{type: "text", text: "Done steer"}]}}},
          {:expect,
           fn req ->
             texts =
               Enum.flat_map(req.messages, fn m -> Enum.map(m.content, &Map.get(&1, :text)) end)

             assert "Follow up!" in texts
             true
           end, {:reply, [], %{content: [%{type: "text", text: "Done follow up"}]}}}
        ])

      File.write!(Path.join(cwd, "a.txt"), "content\n")
      {:ok, _} = Daemon.create_session(%{"session_id" => "s-steer2", "cwd" => cwd}, opts)

      # Idle reject -> 409 conflict without writing
      assert {:error, {:conflict, "conversation_idle"}} =
               Daemon.execute_command(
                 "s-steer2",
                 cmd("idle-rej", "submit", "1", %{
                   "type" => "input",
                   "content" => "Steer too early",
                   "when_busy" => "steer",
                   "when_idle" => "reject"
                 }),
                 opts
               )

      assert {:ok, _} =
               Daemon.execute_command(
                 "s-steer2",
                 cmd("s1", "submit", "1", %{"type" => "input", "content" => "Start"}),
                 opts
               )

      assert_receive {:gate_entered, ^gate1, gpid1}

      # While busy: enqueue follow_up AND steer
      assert {:ok, %{status: "queued"}} =
               Daemon.execute_command(
                 "s-steer2",
                 cmd("f1", "submit", "1", %{
                   "type" => "input",
                   "content" => "Follow up!",
                   "when_busy" => "follow_up"
                 }),
                 opts
               )

      assert {:ok, %{status: "queued"}} =
               Daemon.execute_command(
                 "s-steer2",
                 cmd("st1", "submit", "1", %{
                   "type" => "input",
                   "content" => "Steer this!",
                   "when_busy" => "steer",
                   "when_idle" => "reject"
                 }),
                 opts
               )

      # Release gate 1 -> executes read tool -> drains steer -> enters gate 2
      send(gpid1, {:release, gate1})
      assert_receive {:gate_entered, ^gate2, gpid2}, 1_000

      # Release gate 2 -> completes run 1 -> drains follow_up -> completes run 2
      send(gpid2, {:release, gate2})

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-steer2", "1", %{"order" => "asc"}, opts)
          if length(items) == 7, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == [
               "user",
               "assistant",
               "tool_result",
               "user",
               "assistant",
               "user",
               "assistant"
             ]
    end

    test "abort cancels active stream, converts partial to aborted entry, and sets run_failure" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_isolated_env(
          [
            {:gate, [%{type: :text_delta, text: "Partial ", metadata: %{}}], test_pid, gate,
             %{content: [%{type: "text", text: "never"}]}}
          ],
          persist_within_ms: 20,
          ephemeral_interval_ms: 5
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-abort", "cwd" => cwd}, opts)

      assert {:ok, _} =
               Daemon.execute_command(
                 "s-abort",
                 cmd("a1", "submit", "1", %{"type" => "input", "content" => "Go"}),
                 opts
               )

      assert_receive {:gate_entered, ^gate, _gpid}
      Process.sleep(40)

      assert {:ok, %{status: "done"}} =
               Daemon.execute_command("s-abort", cmd("ab1", "abort", "1", %{}), opts)

      {:ok, {:snapshot, _seq, snap_bin}} =
        Daemon.subscribe_conversation("s-abort", "1", self(), nil, opts)

      snap = JSON.decode!(snap_bin)
      assert snap["docs"]["live"]["run"] == nil
      assert snap["docs"]["live"]["run_failure"] == %{"reason" => "aborted"}

      aborted_entry = Enum.find(snap["entries"], &(&1["kind"] == "assistant"))
      assert aborted_entry["data"]["aborted"] == true
      assert [%{"type" => "text", "text" => "Partial "}] = aborted_entry["data"]["content"]
    end
  end

  describe "restart_limit and per-session blast-radius isolation" do
    test "exceeding restart_limit fails task visibly with restart_limit" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_isolated_env(
          [
            {:gate, [], test_pid, gate},
            {:gate, [], test_pid, gate}
          ],
          restart_limit: 1,
          retry_limit: 2,
          retry_backoff_ms: 10
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-rlim", "cwd" => cwd}, opts)

      assert {:ok, _} =
               Daemon.execute_command(
                 "s-rlim",
                 cmd("r1", "submit", "1", %{"type" => "input", "content" => "Crash me"}),
                 opts
               )

      assert_receive {:gate_entered, ^gate, _}

      # Crash 1: restarts = 1 <= 1 -> sleeps retry -> wakes and starts attempt 2
      [{server_pid1, _}] = Registry.lookup(opts[:registry], {:session, "s-rlim"})
      Process.exit(server_pid1, :kill)

      assert_receive {:gate_entered, ^gate, _}

      # Crash 2: restarts = 2 > 1 -> fails with restart_limit!
      [{server_pid2, _}] = Registry.lookup(opts[:registry], {:session, "s-rlim"})
      Process.exit(server_pid2, :kill)

      snap =
        wait_until(fn ->
          case Registry.lookup(opts[:registry], {:session, "s-rlim"}) do
            [{pid, _}] when pid != server_pid2 ->
              try do
                {:ok, {:snapshot, _seq, bin}} =
                  Daemon.subscribe_conversation("s-rlim", "1", self(), nil, opts)

                decoded = JSON.decode!(bin)
                if decoded["docs"]["live"]["run_failure"], do: decoded, else: nil
              catch
                :exit, _ -> nil
              end

            _ ->
              nil
          end
        end)

      assert snap["docs"]["live"]["run_failure"] == %{"reason" => "restart_limit"}
    end

    test "exceeding supervisor max_restarts quarantines only the broken session" do
      %{opts: opts, cwd: cwd} =
        start_isolated_env([
          {:reply, [], %{content: [%{type: "text", text: "Healthy ok"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "broken", "cwd" => cwd}, opts)
      {:ok, _} = Daemon.create_session(%{"session_id" => "healthy", "cwd" => cwd}, opts)

      # Kill broken session 3 times (exceeds max_restarts: 2 in 5s)
      for _ <- 1..3 do
        [{pid, _}] =
          wait_until(fn ->
            case Registry.lookup(opts[:registry], {:session, "broken"}) do
              [{p, _}] = res -> if Process.alive?(p), do: res, else: nil
              _ -> nil
            end
          end)

        Process.exit(pid, :kill)
      end

      wait_until(fn ->
        case Catalog.get_session("broken", opts[:catalog_table]) do
          {:ok, %{status: "quarantined"}} -> true
          _ -> false
        end
      end)

      assert {:error, {:quarantined, _}} = Daemon.get_session_detail("broken", opts)

      # Healthy session must remain completely unaffected
      assert {:ok, _} =
               Daemon.execute_command(
                 "healthy",
                 cmd("h1", "submit", "1", %{"type" => "input", "content" => "Still alive?"}),
                 opts
               )

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("healthy", "1", %{"order" => "asc"}, opts)
          if length(items) == 2, do: items, else: nil
        end)

      assert Enum.at(items, 1).data["content"] == [%{"type" => "text", "text" => "Healthy ok"}]
    end
  end

  describe "drain-batch group commit" do
    test "concurrent commands in mailbox commit cleanly in sequence" do
      %{opts: opts, cwd: cwd} = start_isolated_env()
      {:ok, _} = Daemon.create_session(%{"session_id" => "s-batch", "cwd" => cwd}, opts)

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Daemon.execute_command(
              "s-batch",
              cmd("w-#{i}", "submit", "1", %{
                "type" => "write",
                "content" => "Note #{i}"
              }),
              opts
            )
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &match?({:ok, %{status: "done"}}, &1))

      {:ok, %{items: items}} = Daemon.scan_entries("s-batch", "1", %{"order" => "asc"}, opts)
      assert length(items) == 10
    end
  end

  describe "H.Storage.Memory and storage failure quarantine" do
    defmodule FailingCommitStorage do
      @behaviour H.Storage

      @impl true
      def open(opts), do: H.Storage.Memory.open(opts)
      @impl true
      def close(s), do: H.Storage.Memory.close(s)
      @impl true
      def mint_id(s), do: H.Storage.Memory.mint_id(s)
      @impl true
      def read_bootstrap(s), do: H.Storage.Memory.read_bootstrap(s)
      @impl true
      def get_submission(s, r), do: H.Storage.Memory.get_submission(s, r)
      @impl true
      def get_entry(s, id), do: H.Storage.Memory.get_entry(s, id)
      @impl true
      def get_doc(s, addr, opts), do: H.Storage.Memory.get_doc(s, addr, opts)
      @impl true
      def scan_entries(s, q), do: H.Storage.Memory.scan_entries(s, q)

      @impl true
      def commit(%{seq: 0} = s, batches), do: H.Storage.Memory.commit(s, batches)
      def commit(_s, _batches), do: {:error, :eio}
    end

    test "works with H.Storage.Memory backend" do
      %{opts: base_opts, cwd: cwd} =
        start_isolated_env([
          {:reply, [], %{content: [%{type: "text", text: "Memory reply"}]}}
        ])

      opts = Keyword.put(base_opts, :storage_mod, H.Storage.Memory)
      {:ok, _} = Daemon.create_session(%{"session_id" => "s-mem", "cwd" => cwd}, opts)

      assert {:ok, %{status: "placed"}} =
               Daemon.execute_command(
                 "s-mem",
                 cmd("m1", "submit", "1", %{"type" => "input", "content" => "Hello memory"}),
                 opts
               )

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-mem", "1", %{"order" => "asc"}, opts)
          if length(items) == 2, do: items, else: nil
        end)

      assert Enum.at(items, 1).data["content"] == [%{"type" => "text", "text" => "Memory reply"}]
    end

    test "storage commit I/O error fails session closed and quarantines it in catalog" do
      %{opts: base_opts, cwd: cwd} = start_isolated_env()
      opts = Keyword.put(base_opts, :storage_mod, FailingCommitStorage)

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-ioerr", "cwd" => cwd}, opts)

      assert catch_exit(
               Daemon.execute_command(
                 "s-ioerr",
                 cmd("io1", "submit", "1", %{"type" => "write", "content" => "Fail"}),
                 opts
               )
             )

      wait_until(fn ->
        case Catalog.get_session("s-ioerr", opts[:catalog_table]) do
          {:ok, %{status: "quarantined"}} -> true
          _ -> false
        end
      end)

      assert {:error, {:quarantined, _}} = Daemon.get_session_detail("s-ioerr", opts)
    end
  end
end
