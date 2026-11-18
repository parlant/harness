defmodule H.RemoteAgentTest do
  use ExUnit.Case, async: false

  alias H.ExecutionEnv
  alias H.ExecutionEnv.Host
  alias H.RemoteAgent

  setup do
    rand = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "h-remote-agent-#{System.unique_integer([:positive, :monotonic])}-#{rand}"
      )
      |> Path.expand()

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    host_env = Host.new(tmp_dir, env_id: "vm-host-base")
    agent = start_supervised!({RemoteAgent, env: host_env, id: "vm-test"})

    {:ok, tmp_dir: tmp_dir, host_env: host_env, agent: agent}
  end

  describe "start_link/1 and descriptor/1" do
    test "returns plain descriptor with kind \"remote\" and defaults id from env", %{
      tmp_dir: tmp_dir,
      host_env: host_env,
      agent: agent
    } do
      assert RemoteAgent.descriptor(agent) == %{
               id: "vm-test",
               kind: "remote",
               cwd: tmp_dir
             }

      default_id_agent = start_supervised!({RemoteAgent, env: host_env}, id: :default_id_agent)

      assert RemoteAgent.descriptor(default_id_agent) == %{
               id: "vm-host-base",
               kind: "remote",
               cwd: tmp_dir
             }
    end

    test "rejects missing :env and empty :id", %{host_env: host_env} do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{}, _}} = RemoteAgent.start_link([])
      assert {:error, {%ArgumentError{}, _}} = RemoteAgent.start_link(env: host_env, id: "")
    end
  end

  describe "cwd/1, resolve_path/3, bind_cwd/3, and filesystem ops" do
    test "resolves paths and supports :cwd scoping without mutating agent base cwd", %{
      tmp_dir: tmp_dir,
      agent: agent
    } do
      assert RemoteAgent.cwd(agent) == tmp_dir
      assert {:ok, Path.join(tmp_dir, "a/b.txt")} == RemoteAgent.resolve_path(agent, "a/b.txt")

      assert {:ok, "/virtual/remote/src/app.ex"} ==
               RemoteAgent.resolve_path(agent, "src/../src/app.ex", cwd: "/virtual/remote")

      assert {:error, :einval} = RemoteAgent.resolve_path(agent, "bad\0path")

      sub_dir = Path.join(tmp_dir, "workspace")
      File.mkdir_p!(sub_dir)
      :ok = RemoteAgent.write_file(agent, "notes.txt", "hello\nworld\n", cwd: sub_dir)

      assert {:ok, ^sub_dir} = RemoteAgent.bind_cwd(agent, "workspace")
      assert RemoteAgent.cwd(agent) == tmp_dir

      assert {:error, :enotdir} = RemoteAgent.bind_cwd(agent, "notes.txt", cwd: sub_dir)
      assert {:error, :enoent} = RemoteAgent.bind_cwd(agent, "missing_dir")

      assert {:ok, %{lines: ["hello", "world"], has_more: false}} =
               RemoteAgent.read_file_lines(agent, "notes.txt", cwd: sub_dir)

      assert {:ok, "hello\nworld\n"} =
               RemoteAgent.read_file_bytes(agent, "notes.txt", cwd: sub_dir)

      :ok = RemoteAgent.write_file(agent, "mix.exs", "defmodule W do end", cwd: sub_dir)

      assert {:ok, %{entries: [%{name: "workspace", type: "dir", markers: ["mix.exs"]}]}} =
               RemoteAgent.list_dir(agent, ".",
                 only_dirs: true,
                 markers: ExecutionEnv.default_markers()
               )
    end
  end

  describe "exec/3 fencing" do
    test "rejects duplicate active and completed fences with :stale_fence", %{agent: agent} do
      fence_opts = [session_id: "sess-1", incarnation: 1, task_id: 10, attempt_id: 1]
      fence = {"sess-1", 1, 10, 1}
      parent = self()

      task =
        Task.async(fn ->
          RemoteAgent.exec(
            agent,
            {:shell, "echo started; sleep 10"},
            fence_opts ++ [on_output: fn chunk -> send(parent, {:chunk, chunk}) end]
          )
        end)

      assert_receive {:chunk, "started\n"}, 2_000

      assert {:error, :stale_fence} =
               RemoteAgent.exec(agent, {:shell, "echo dup"}, fence_opts)

      assert :ok = RemoteAgent.abort(agent, fence)
      assert {:error, %{reason: :aborted}} = Task.await(task, 5_000)

      # Completed fence cannot be replayed either
      assert {:error, :stale_fence} =
               RemoteAgent.exec(agent, {:shell, "echo replay"}, fence_opts)
    end

    test "rejects older attempt or older incarnation and accepts newer fences", %{agent: agent} do
      assert {:ok, %{exit_code: 0, output: "ok1"}} =
               RemoteAgent.exec(agent, {:shell, "printf ok1"},
                 session_id: "sess-2",
                 incarnation: 2,
                 task_id: 5,
                 attempt_id: 2
               )

      # Older attempt for same task
      assert {:error, :stale_fence} =
               RemoteAgent.exec(agent, {:shell, "printf old_att"},
                 session_id: "sess-2",
                 incarnation: 2,
                 task_id: 5,
                 attempt_id: 1
               )

      # Older incarnation for same session (even with new task_id)
      assert {:error, :stale_fence} =
               RemoteAgent.exec(agent, {:shell, "printf old_inc"},
                 session_id: "sess-2",
                 incarnation: 1,
                 task_id: 99,
                 attempt_id: 1
               )

      # Newer attempt succeeds
      assert {:ok, %{exit_code: 0, output: "ok2"}} =
               RemoteAgent.exec(agent, {:shell, "printf ok2"},
                 session_id: "sess-2",
                 incarnation: 2,
                 task_id: 5,
                 attempt_id: 3
               )

      # New task in same incarnation succeeds
      assert {:ok, %{exit_code: 0, output: "ok3"}} =
               RemoteAgent.exec(agent, {:shell, "printf ok3"},
                 session_id: "sess-2",
                 incarnation: 2,
                 task_id: 6,
                 attempt_id: 1
               )

      # Newer incarnation succeeds
      assert {:ok, %{exit_code: 0, output: "ok4"}} =
               RemoteAgent.exec(agent, {:shell, "printf ok4"},
                 session_id: "sess-2",
                 incarnation: 3,
                 task_id: 1,
                 attempt_id: 1
               )

      # Distinct session with incarnation 1 succeeds
      assert {:ok, %{exit_code: 0, output: "ok5"}} =
               RemoteAgent.exec(agent, {:shell, "printf ok5"},
                 session_id: "sess-other",
                 incarnation: 1,
                 task_id: 1,
                 attempt_id: 1
               )
    end
  end

  describe "renew_lease/3 and lease expiry" do
    test "validates lease_ms and fence presence", %{agent: agent} do
      assert {:error, :invalid_lease_ms} =
               RemoteAgent.exec(agent, {:shell, "echo hi"}, lease_ms: 0)

      assert {:error, :invalid_lease_ms} =
               RemoteAgent.renew_lease(agent, {"s", 1, 1, 1}, -5)

      assert {:error, :not_found} =
               RemoteAgent.renew_lease(agent, {"s", 1, 1, 1}, 500)
    end

    test "expires lease and reaps grandchild PGID when not renewed", %{agent: agent} do
      parent = self()

      assert {:error, %{reason: :lease_expired, output: output}} =
               RemoteAgent.exec(
                 agent,
                 {:shell, "sleep 120 & echo child_pid=$!; sleep 120"},
                 session_id: "sess-lease",
                 incarnation: 1,
                 task_id: 1,
                 attempt_id: 1,
                 lease_ms: 150,
                 timeout_ms: 10_000,
                 on_output: fn chunk -> send(parent, {:chunk, chunk}) end
               )

      child_pid = receive_child_pid!()
      assert String.contains?(output, "child_pid=#{child_pid}")
      assert {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
      assert status != 0
      assert RemoteAgent.active_fences(agent) == []
    end

    test "renew_lease/3 keeps command alive past initial lease TTL", %{agent: agent} do
      fence = {"sess-renew", 1, 1, 1}
      parent = self()

      task =
        Task.async(fn ->
          RemoteAgent.exec(
            agent,
            {:shell, "echo ready; sleep 0.25; printf done"},
            session_id: "sess-renew",
            incarnation: 1,
            task_id: 1,
            attempt_id: 1,
            lease_ms: 140,
            timeout_ms: 5_000,
            on_output: fn chunk -> send(parent, {:chunk, chunk}) end
          )
        end)

      assert_receive {:chunk, "ready\n"}, 2_000
      assert :ok = RemoteAgent.renew_lease(agent, fence, 600)

      assert {:ok, %{exit_code: 0, output: output}} = Task.await(task, 5_000)
      assert String.ends_with?(output, "done")
      assert RemoteAgent.active_fences(agent) == []
    end
  end

  describe "abort/2 and caller/agent termination cleanup" do
    test "abort/2 stops active exec, reaps grandchild PGID, and returns :not_found when absent",
         %{agent: agent} do
      assert {:error, :not_found} = RemoteAgent.abort(agent, {"missing", 1, 1, 1})

      fence = {"sess-abort", 1, 1, 1}
      parent = self()

      task =
        Task.async(fn ->
          RemoteAgent.exec(
            agent,
            {:shell, "sleep 120 & echo child_pid=$!; sleep 120"},
            session_id: "sess-abort",
            incarnation: 1,
            task_id: 1,
            attempt_id: 1,
            timeout_ms: 10_000,
            on_output: fn chunk -> send(parent, {:chunk, chunk}) end
          )
        end)

      child_pid = receive_child_pid!()
      assert [^fence] = RemoteAgent.active_fences(agent)

      assert :ok = RemoteAgent.abort(agent, fence)
      assert {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
      assert status != 0

      assert {:error, %{reason: :aborted, output: output}} = Task.await(task, 5_000)
      assert String.contains?(output, "child_pid=#{child_pid}")
      assert RemoteAgent.active_fences(agent) == []
    end

    test "reaps grandchild PGID when caller process crashes", %{agent: agent} do
      parent = self()

      caller =
        spawn(fn ->
          RemoteAgent.exec(
            agent,
            {:shell, "sleep 120 & echo child_pid=$!; sleep 120"},
            session_id: "sess-crash",
            incarnation: 1,
            task_id: 1,
            attempt_id: 1,
            timeout_ms: 10_000,
            on_output: fn chunk -> send(parent, {:chunk, chunk}) end
          )
        end)

      child_pid = receive_child_pid!()
      caller_mon = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_mon, :process, ^caller, :killed}, 2_000

      wait_until(fn -> RemoteAgent.active_fences(agent) == [] end, 3_000)
      assert {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
      assert status != 0
    end

    test "reaps grandchild PGID when agent stops while exec is active", %{host_env: host_env} do
      {:ok, ephemeral_agent} = RemoteAgent.start_link(env: host_env, id: "vm-ephemeral")
      parent = self()

      task =
        Task.async(fn ->
          RemoteAgent.exec(
            ephemeral_agent,
            {:shell, "sleep 120 & echo child_pid=$!; sleep 120"},
            timeout_ms: 10_000,
            on_output: fn chunk -> send(parent, {:chunk, chunk}) end
          )
        end)

      child_pid = receive_child_pid!()
      :ok = GenServer.stop(ephemeral_agent)

      assert {:error, {:agent_down, :normal}} = Task.await(task, 5_000)
      assert {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
      assert status != 0
    end
  end

  defp receive_child_pid!(acc \\ "") do
    receive do
      {:chunk, chunk} ->
        combined = acc <> chunk

        case Regex.run(~r/child_pid=(\d+)/, combined) do
          [_, pid] -> pid
          nil -> receive_child_pid!(combined)
        end
    after
      2_000 ->
        flunk("did not receive child_pid within timeout, got: #{inspect(acc)}")
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met before timeout")
      else
        Process.sleep(15)
        do_wait_until(fun, deadline)
      end
    end
  end
end
