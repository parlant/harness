defmodule H.Session.UserShellTest do
  use ExUnit.Case, async: true

  alias H.{Context, RemoteAgent, Storage, StoreLock, WorkspaceLease}
  alias H.ExecutionEnv.{Host, Remote}
  alias H.Session.UserShell
  alias H.Test.UserShellHarness
  alias H.Tools.SearchHistory

  defp start_harness_env(extra_opts \\ []) do
    id = System.unique_integer([:positive, :monotonic])
    tmp_root = Path.join(System.tmp_dir!(), "h-user-shell-test-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    session_dir = Path.join([data_dir, "sessions", "sess-#{id}"])
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)
    File.mkdir_p!(session_dir)

    on_exit(fn -> File.rm_rf(tmp_root) end)

    lease = :"H.UserShellTest.Lease.#{id}"
    pubsub = :"H.UserShellTest.PubSub.#{id}"

    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})

    env = Keyword.get_lazy(extra_opts, :execution_env, fn -> Host.new(cwd) end)

    harness_opts =
      [
        session_id: "sess-#{id}",
        cwd: cwd,
        execution_env: env,
        workspace_lease: lease,
        pubsub: pubsub,
        storage_mod: H.Storage.File,
        storage_opts: [dir: session_dir, sync: :none]
      ]
      |> Keyword.merge(extra_opts)

    server = start_supervised!({UserShellHarness, harness_opts})

    %{
      server: server,
      session_id: "sess-#{id}",
      cwd: cwd,
      data_dir: data_dir,
      session_dir: session_dir,
      lease: lease,
      pubsub: pubsub,
      env: env,
      tmp_root: tmp_root
    }
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

  describe "validate_args/1" do
    test "requires command, boolean include_in_context, and non-negative integer expected_seq" do
      assert {:ok,
              %{
                command: "ls -la",
                include_in_context: true,
                expected_seq: 0
              }} =
               UserShell.validate_args(%{
                 "command" => "ls -la",
                 "include_in_context" => true,
                 "expected_seq" => 0
               })

      assert {:ok, %{include_in_context: false}} =
               UserShell.validate_args(%{
                 "command" => "pwd",
                 "include_in_context" => false,
                 "expected_seq" => 7
               })

      for bad <- [
            %{},
            %{"command" => "", "include_in_context" => true, "expected_seq" => 0},
            %{"command" => "   ", "include_in_context" => true, "expected_seq" => 0},
            %{"command" => "ls", "expected_seq" => 0},
            %{"command" => "ls", "include_in_context" => "true", "expected_seq" => 0},
            %{"command" => "ls", "include_in_context" => true},
            %{"command" => "ls", "include_in_context" => true, "expected_seq" => -1},
            %{"command" => "ls", "include_in_context" => true, "expected_seq" => "1"}
          ] do
        assert {:error, _reason} = UserShell.validate_args(bad)
      end
    end
  end

  describe "stage/7 guards" do
    test "rejects expected_seq mismatch and busy conversation" do
      %{server: server} = start_harness_env()
      {:ok, snap} = UserShellHarness.state_snapshot(server)

      assert {:error, {:conflict, "expected_seq mismatch"}} =
               UserShellHarness.execute_user_shell(server, "req-bad-seq", %{
                 "command" => "echo hi",
                 "include_in_context" => true,
                 "expected_seq" => snap.conv_seq + 1
               })

      # Start a running command, then reject second concurrent user_shell
      assert {:ok, _receipt} =
               UserShellHarness.execute_user_shell(server, "req-slow", %{
                 "command" => "sleep 1",
                 "include_in_context" => true,
                 "expected_seq" => snap.conv_seq
               })

      {:ok, busy_snap} = UserShellHarness.state_snapshot(server)

      assert {:error, {:conflict, "conversation_busy"}} =
               UserShellHarness.execute_user_shell(server, "req-while-busy", %{
                 "command" => "echo second",
                 "include_in_context" => true,
                 "expected_seq" => busy_snap.conv_seq
               })
    end
  end

  describe "durable execution, context projection, and search protection" do
    test "executes ! and !! commands, persists intent before spawn, and isolates excluded output from provider and search" do
      %{server: server, session_id: sid, pubsub: pubsub, cwd: cwd} = start_harness_env()
      Registry.register(pubsub, {:conversation, sid, 1}, nil)

      {:ok, snap0} = UserShellHarness.state_snapshot(server)

      assert {:ok, r1} =
               UserShellHarness.execute_user_shell(server, "req-inc", %{
                 "command" => "printf 'public-line'",
                 "include_in_context" => true,
                 "expected_seq" => snap0.conv_seq
               })

      assert r1.status == "placed"

      entries1 =
        wait_until(fn ->
          {:ok, %{items: items}} = UserShellHarness.scan_entries(server)
          if length(items) == 1, do: items, else: nil
        end)

      [e1] = entries1
      assert e1.kind == "user_shell"
      assert e1.data["command"] == "printf 'public-line'"
      assert e1.data["output"] == "public-line"
      assert e1.data["exit_code"] == 0
      assert e1.data["cancelled"] == false
      assert e1.data["include_in_context"] == true
      assert e1.data["is_error"] == false
      assert e1.data["diagnostic"] == nil

      # Run !! (excluded from provider context)
      {:ok, snap1} = UserShellHarness.state_snapshot(server)

      assert {:ok, _r2} =
               UserShellHarness.execute_user_shell(server, "req-exc", %{
                 "command" => "echo private-secret-token; exit 3",
                 "include_in_context" => false,
                 "expected_seq" => snap1.conv_seq
               })

      entries2 =
        wait_until(fn ->
          {:ok, %{items: items}} = UserShellHarness.scan_entries(server)
          if length(items) == 2, do: items, else: nil
        end)

      [_e1, e2] = entries2
      assert e2.kind == "user_shell"
      assert e2.data["exit_code"] == 3
      assert e2.data["is_error"] == true
      assert e2.data["diagnostic"] == "exit_code"
      assert e2.data["include_in_context"] == false
      assert e2.data["output"] =~ "private-secret-token"

      # Context projection includes e1 and strictly excludes e2
      req = Context.build_request(entries2, %{model: "fake:m"})
      assert [%{role: "user", content: [%{type: "text", text: projected}]}] = req.messages
      assert projected =~ "public-line"
      refute projected =~ "private-secret-token"

      # SearchHistory finds e1 and strictly hides e2
      scan_fn = fn q -> UserShellHarness.scan_entries(server, 1, q) end
      ctx = %{env: Host.new(cwd), scan_entries: scan_fn}

      assert {:ok, found} = SearchHistory.execute(%{"query" => "public"}, ctx)
      assert found.details["count"] == 1

      assert {:ok, hidden} = SearchHistory.execute(%{"query" => "private-secret-token"}, ctx)
      assert hidden.details["count"] == 0

      # Idempotent retry of req-inc returns receipt without re-running
      assert {:ok, r1_retry} =
               UserShellHarness.execute_user_shell(server, "req-inc", %{
                 "command" => "printf 'public-line'",
                 "include_in_context" => true,
                 "expected_seq" => snap0.conv_seq
               })

      assert r1_retry.submission_id == r1.submission_id
    end

    test "persists running intent before spawning and refuses local fallback when execution_env is nil" do
      %{server: server} = start_harness_env(execution_env: nil)
      {:ok, snap0} = UserShellHarness.state_snapshot(server)

      assert {:ok, _receipt} =
               UserShellHarness.execute_user_shell(server, "req-no-env", %{
                 "command" => "echo should_never_run",
                 "include_in_context" => true,
                 "expected_seq" => snap0.conv_seq
               })

      snap =
        wait_until(fn ->
          {:ok, s} = UserShellHarness.state_snapshot(server)
          if s.live["run_failure"], do: s, else: nil
        end)

      assert snap.live["run_failure"]["reason"] == "missing_execution_env"
      assert {:ok, %{items: []}} = UserShellHarness.scan_entries(server)
    end
  end

  describe "bound remote env, workspace lease, and cancellation" do
    test "runs on bound H.ExecutionEnv.Remote with separate lease namespace and never falls back to host" do
      id = System.unique_integer([:positive, :monotonic])
      tmp_root = Path.join(System.tmp_dir!(), "h-us-remote-#{id}")
      remote_cwd = Path.join(tmp_root, "remote_work")
      File.mkdir_p!(remote_cwd)
      on_exit(fn -> File.rm_rf(tmp_root) end)

      host_backing = Host.new(remote_cwd, env_id: "remote-box-1")
      agent = start_supervised!({RemoteAgent, env: host_backing, id: "remote-box-1"})
      remote_env = Remote.new(agent, remote_cwd)

      %{server: server, lease: lease} =
        start_harness_env(cwd: remote_cwd, env_id: "remote-box-1", execution_env: remote_env)

      # Acquiring host lease at the exact same path must NOT block remote-box-1
      assert :ok = WorkspaceLease.acquire(lease, {"host", remote_cwd}, {"other", 1}, self())

      {:ok, snap0} = UserShellHarness.state_snapshot(server)

      assert {:ok, _} =
               UserShellHarness.execute_user_shell(server, "req-remote", %{
                 "command" => "printf 'from-remote'",
                 "include_in_context" => true,
                 "expected_seq" => snap0.conv_seq
               })

      entries =
        wait_until(fn ->
          {:ok, %{items: items}} = UserShellHarness.scan_entries(server)
          if length(items) == 1, do: items, else: nil
        end)

      assert hd(entries).data["output"] == "from-remote"
      assert RemoteAgent.active_fences(agent) == []
    end

    test "waits without spawning and resumes on workspace lease release" do
      %{server: server, cwd: cwd, lease: lease} = start_harness_env()
      marker = Path.join(cwd, "ran.txt")

      # Another session holds the lease on {"host", cwd}
      assert :ok = WorkspaceLease.acquire(lease, {"host", cwd}, {"other-session", 1}, self())

      {:ok, snap0} = UserShellHarness.state_snapshot(server)

      assert {:ok, _} =
               UserShellHarness.execute_user_shell(server, "req-busy-ws", %{
                 "command" => "touch #{marker}",
                 "include_in_context" => true,
                 "expected_seq" => snap0.conv_seq
               })

      snap =
        wait_until(fn ->
          {:ok, s} = UserShellHarness.state_snapshot(server)
          if s.live["workspace_wait"], do: s, else: nil
        end)

      assert snap.live["workspace_wait"]["holder_session_id"] == "other-session"
      assert snap.live["user_shell"]["status"] == "waiting"
      refute File.exists?(marker)
      assert {:ok, %{items: []}} = UserShellHarness.scan_entries(server)
      :ok = WorkspaceLease.release(lease, {"host", cwd}, {"other-session", 1})

      wait_until(fn ->
        {:ok, %{items: items}} = UserShellHarness.scan_entries(server)
        if length(items) == 1, do: items, else: nil
      end)

      assert File.exists?(marker)
      {:ok, resumed} = UserShellHarness.state_snapshot(server)
      refute resumed.live["workspace_wait"]
    end

    test "supports cooperative abort_ref cancellation, PGID reaping, and immediate abort" do
      %{server: server, cwd: cwd, lease: lease} = start_harness_env()
      {:ok, snap0} = UserShellHarness.state_snapshot(server)

      assert {:ok, _} =
               UserShellHarness.execute_user_shell(server, "req-cancel", %{
                 "command" => "sleep 120 & echo child_pid=$!; echo partial-out; sleep 120",
                 "include_in_context" => true,
                 "expected_seq" => snap0.conv_seq
               })

      {task_id, _partial} =
        wait_until(fn ->
          {:ok, s} = UserShellHarness.state_snapshot(server)
          task = s.tasks |> Map.values() |> Enum.find(&(&1.kind == "user_shell"))
          out = get_in(s.live, ["user_shell", "output"]) || ""

          if task && task.status == "running" && String.contains?(out, "partial-out") do
            {task.id, out}
          else
            nil
          end
        end)

      assert :ok = UserShellHarness.cancel_user_shell(server, task_id)

      [entry] =
        wait_until(fn ->
          {:ok, %{items: items}} = UserShellHarness.scan_entries(server)
          if length(items) == 1, do: items, else: nil
        end)

      assert entry.data["cancelled"] == true
      assert entry.data["diagnostic"] == "aborted"
      assert entry.data["is_error"] == true
      assert entry.data["exit_code"] == nil
      assert entry.data["output"] =~ "partial-out"

      [_, child_pid] = Regex.run(~r/child_pid=(\d+)/, entry.data["output"])
      assert {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
      assert status != 0

      # Lease must be released after cancellation
      assert :ok = WorkspaceLease.acquire(lease, {"host", cwd}, {"after-cancel", 1}, self())
      :ok = WorkspaceLease.release(lease, {"host", cwd}, {"after-cancel", 1})

      # Immediate abort_user_shell also cancels and releases lease
      {:ok, snap1} = UserShellHarness.state_snapshot(server)

      assert {:ok, _} =
               UserShellHarness.execute_user_shell(server, "req-abort", %{
                 "command" => "echo abort-partial; sleep 120",
                 "include_in_context" => false,
                 "expected_seq" => snap1.conv_seq
               })

      wait_until(fn ->
        {:ok, s} = UserShellHarness.state_snapshot(server)
        out = get_in(s.live, ["user_shell", "output"]) || ""
        if String.contains?(out, "abort-partial"), do: true, else: nil
      end)

      assert :ok = UserShellHarness.abort_user_shell(server, 1, "aborted")

      entries =
        wait_until(fn ->
          {:ok, %{items: items}} = UserShellHarness.scan_entries(server)
          if length(items) == 2, do: items, else: nil
        end)

      aborted_entry = List.last(entries)
      assert aborted_entry.data["cancelled"] == true
      assert aborted_entry.data["diagnostic"] == "aborted"
      assert aborted_entry.data["include_in_context"] == false
      assert aborted_entry.data["output"] =~ "abort-partial"
    end
  end

  describe "unsafe no-replay on worker crash and real VM SIGKILL restart" do
    test "worker crash marks user_shell interrupted with partial output and never replays" do
      %{server: server, cwd: cwd} = start_harness_env(persist_within_ms: 10)
      count_file = Path.join(cwd, "exec_count.txt")
      {:ok, snap0} = UserShellHarness.state_snapshot(server)

      assert {:ok, _} =
               UserShellHarness.execute_user_shell(server, "req-crash", %{
                 "command" => "echo tick >> #{count_file}; echo crash-partial; sleep 30",
                 "include_in_context" => true,
                 "expected_seq" => snap0.conv_seq
               })

      worker_pid =
        wait_until(fn ->
          {:ok, s} = UserShellHarness.state_snapshot(server)
          out = get_in(s.live, ["user_shell", "output"]) || ""

          if String.contains?(out, "crash-partial") and map_size(s.workers) == 1 do
            [{_aid, w}] = Map.to_list(s.workers)
            w.pid
          else
            nil
          end
        end)

      Process.exit(worker_pid, :kill)

      [entry] =
        wait_until(fn ->
          {:ok, %{items: items}} = UserShellHarness.scan_entries(server)
          if length(items) == 1, do: items, else: nil
        end)

      assert entry.data["diagnostic"] == "interrupted"
      assert entry.data["is_error"] == true
      assert entry.data["output"] =~ "crash-partial"
      assert File.read!(count_file) == "tick\n"
    end

    test "recover_on_open marks both pending and running unsafe user_shell tasks interrupted without replay" do
      id = System.unique_integer([:positive, :monotonic])
      tmp_root = Path.join(System.tmp_dir!(), "h-us-pending-rec-#{id}")
      session_dir = Path.join(tmp_root, "session")
      cwd = Path.join(tmp_root, "work")
      File.mkdir_p!(session_dir)
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(tmp_root) end)

      count_file = Path.join(cwd, "pending_exec.txt")

      {:ok, store} = Storage.open(H.Storage.File, dir: session_dir, sync: :datasync)
      {:ok, store} = Storage.read_bootstrap(store) |> then(fn {:ok, _, s} -> {:ok, s} end)

      # Stage a pending task directly to storage (simulating crash right after stage commit, before spawn)
      task =
        H.Task.new(%{
          id: 10,
          kind: "user_shell",
          owner: {:conversation, 1},
          status: "pending",
          checkpoint: %{
            "conversation_id" => 1,
            "command" => "echo ran >> #{count_file}",
            "include_in_context" => true,
            "phase" => "pending",
            "replay" => "unsafe",
            "submission_ids" => []
          }
        })

      {:ok, _res, store} = Storage.commit(store, [[{:put_task, task}]])
      :ok = Storage.close(store)

      lease = :"H.UserShellTest.PendLease.#{id}"
      start_supervised!({WorkspaceLease, name: lease})

      server =
        start_supervised!(
          {UserShellHarness,
           session_id: "sess-pend-#{id}",
           cwd: cwd,
           execution_env: Host.new(cwd),
           workspace_lease: lease,
           storage_mod: H.Storage.File,
           storage_opts: [dir: session_dir, sync: :datasync]}
        )

      {:ok, %{items: [entry]}} = UserShellHarness.scan_entries(server)
      assert entry.kind == "user_shell"
      assert entry.data["diagnostic"] == "interrupted"
      assert entry.data["is_error"] == true
      refute File.exists?(count_file)
    end

    @tag timeout: 20_000
    test "recovers interrupted user_shell after SIGKILL of daemon OS process without replaying side effect" do
      id = System.unique_integer([:positive])
      tmp_root = Path.join(System.tmp_dir!(), "h-us-vm-restart-#{id}")
      data_dir = Path.join(tmp_root, "data")
      cwd = Path.join(tmp_root, "work")
      session_dir = Path.join([data_dir, "sessions", "vm-shell"])
      File.mkdir_p!(data_dir)
      File.mkdir_p!(cwd)
      File.mkdir_p!(session_dir)

      on_exit(fn ->
        File.rm(StoreLock.socket_path(data_dir))
        File.rm_rf(tmp_root)
      end)

      elixir_exe = System.find_executable("elixir")
      assert is_binary(elixir_exe)

      pa_args =
        :code.get_path()
        |> Enum.map(&List.to_string/1)
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(fn dir -> ["-pa", dir] end)

      count_file = Path.join(cwd, "vm_exec_count.txt")

      child_script = """
      Application.ensure_all_started(:logger)
      Application.ensure_all_started(:crypto)

      data_dir = System.fetch_env!("H_TEST_DATA_DIR")
      cwd = System.fetch_env!("H_TEST_CWD")
      session_dir = System.fetch_env!("H_TEST_SESSION_DIR")
      count_file = System.fetch_env!("H_TEST_COUNT_FILE")

      {:ok, _} = H.StoreLock.start_link(data_dir: data_dir, name: H.StoreLock)
      {:ok, _} = H.WorkspaceLease.start_link(name: H.WorkspaceLease)

      {:ok, server} =
        H.Test.UserShellHarness.start_link(
          session_id: "vm-shell",
          cwd: cwd,
          execution_env: H.ExecutionEnv.Host.new(cwd),
          workspace_lease: H.WorkspaceLease,
          storage_mod: H.Storage.File,
          storage_opts: [dir: session_dir, sync: :datasync],
          persist_within_ms: 15,
          ephemeral_interval_ms: 5
        )

      {:ok, snap0} = H.Test.UserShellHarness.state_snapshot(server)

      {:ok, _} =
        H.Test.UserShellHarness.execute_user_shell(server, "vm-sh-1", %{
          "command" => "echo ran >> \#{count_file}; echo vm-shell-partial; sleep 5",
          "include_in_context" => false,
          "expected_seq" => snap0.conv_seq
        })

      wait_flushed = fn wait_flushed ->
        {:ok, s} = H.Test.UserShellHarness.state_snapshot(server)
        out = get_in(s.live, ["user_shell", "output"]) || ""

        if String.contains?(out, "vm-shell-partial") do
          # Ensure flush_live committed to H.Storage.File
          {:ok, st} = H.Storage.open(H.Storage.File, dir: session_dir, sync: :none)
          {:ok, boot, st} = H.Storage.read_bootstrap(st)
          :ok = H.Storage.close(st)
          persisted_out = get_in(boot.docs[{:conversation, 1, "live"}], ["value", "user_shell", "output"]) || ""

          if String.contains?(persisted_out, "vm-shell-partial") do
            :ok
          else
            Process.sleep(15)
            wait_flushed.(wait_flushed)
          end
        else
          Process.sleep(15)
          wait_flushed.(wait_flushed)
        end
      end

      wait_flushed.(wait_flushed)
      IO.puts("READY:" <> System.pid())

      receive do
        :never -> :ok
      end
      """

      port =
        Port.open({:spawn_executable, elixir_exe}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:line, 4096},
          {:args, pa_args ++ ["-e", child_script]},
          {:env,
           [
             {~c"H_TEST_DATA_DIR", String.to_charlist(data_dir)},
             {~c"H_TEST_CWD", String.to_charlist(cwd)},
             {~c"H_TEST_SESSION_DIR", String.to_charlist(session_dir)},
             {~c"H_TEST_COUNT_FILE", String.to_charlist(count_file)}
           ]}
        ])

      os_pid = await_ready_pid(port)

      on_exit(fn ->
        if Port.info(port) != nil, do: Port.close(port)
        System.cmd("kill", ["-9", os_pid], stderr_to_stdout: true)
      end)

      assert {:error, :store_locked} = StoreLock.start_link(data_dir: data_dir)

      # SIGKILL the child BEAM OS process mid-command!
      {_out, 0} = System.cmd("kill", ["-9", os_pid])
      assert_receive {^port, {:exit_status, _status}}, 5_000

      # Boot fresh supervisor tree in this VM on the exact same data_dir / session_dir
      start_supervised!({StoreLock, data_dir: data_dir, name: :"H.UsVm.Lock.#{id}"})
      lease2 = :"H.UsVm.Lease.#{id}"
      start_supervised!({WorkspaceLease, name: lease2})

      server2 =
        start_supervised!(
          {UserShellHarness,
           session_id: "vm-shell",
           cwd: cwd,
           execution_env: Host.new(cwd),
           workspace_lease: lease2,
           storage_mod: H.Storage.File,
           storage_opts: [dir: session_dir, sync: :datasync]}
        )

      # Verify task settled interrupted with persisted partial output and NEVER replayed
      {:ok, %{items: [entry]}} = UserShellHarness.scan_entries(server2)
      assert entry.kind == "user_shell"
      assert entry.data["diagnostic"] == "interrupted"
      assert entry.data["is_error"] == true
      assert entry.data["include_in_context"] == false
      assert entry.data["output"] =~ "vm-shell-partial"

      # Command ran EXACTLY ONCE across the SIGKILL + VM restart
      assert File.read!(count_file) == "ran\n"

      # Excluded entry remains hidden from Context and SearchHistory after recovery
      req = Context.build_request([entry], %{model: "fake:m"})
      assert req.messages == []

      scan_fn = fn q -> UserShellHarness.scan_entries(server2, 1, q) end
      ctx = %{env: Host.new(cwd), scan_entries: scan_fn}

      assert {:ok, %{details: %{"count" => 0}}} =
               SearchHistory.execute(%{"query" => "vm-shell-partial"}, ctx)

      # Lease is cleanly available on restart
      assert :ok = WorkspaceLease.acquire(lease2, {"host", cwd}, {"post-restart", 1}, self())
    end
  end

  defp await_ready_pid(port) do
    receive do
      {^port, {:data, {:eol, "READY:" <> os_pid}}} ->
        os_pid

      {^port, {:data, {:eol, _line}}} ->
        await_ready_pid(port)

      {^port, {:exit_status, status}} ->
        flunk("child VM exited early with status #{status}")
    after
      10_000 ->
        flunk("timed out waiting for child VM to reach READY state")
    end
  end
end
