defmodule H.ExecutionEnv.RemoteTest do
  use ExUnit.Case, async: false

  use H.ExecutionEnv.Conformance,
    factory: fn tmp_dir ->
      host_env = H.ExecutionEnv.Host.new(tmp_dir, env_id: "vm-conformance")

      agent =
        ExUnit.Callbacks.start_supervised!({H.RemoteAgent, env: host_env, id: "vm-conformance"})

      H.ExecutionEnv.Remote.new(agent, tmp_dir)
    end

  alias H.ExecutionEnv
  alias H.ExecutionEnv.Host
  alias H.ExecutionEnv.Remote
  alias H.RemoteAgent
  alias H.WorkspaceLease

  describe "Remote.new/3 and environment identity" do
    test "separates remote env_id and kind from Host at the exact same path", %{
      env: remote_env,
      tmp_dir: tmp_dir
    } do
      host_env = Host.new(tmp_dir)

      assert ExecutionEnv.cwd(remote_env) == tmp_dir
      assert ExecutionEnv.cwd(host_env) == tmp_dir
      assert ExecutionEnv.env_id(remote_env) == "vm-conformance"
      assert ExecutionEnv.env_id(host_env) == "host"
      assert ExecutionEnv.kind(remote_env) == "remote"
      assert ExecutionEnv.kind(host_env) == "host"

      assert {ExecutionEnv.env_id(remote_env), ExecutionEnv.cwd(remote_env)} !=
               {ExecutionEnv.env_id(host_env), ExecutionEnv.cwd(host_env)}

      lease_server = start_supervised!({WorkspaceLease, name: nil})

      assert :ok =
               WorkspaceLease.acquire(
                 lease_server,
                 {ExecutionEnv.env_id(host_env), ExecutionEnv.cwd(host_env)},
                 {:conv, 1},
                 self()
               )

      assert :ok =
               WorkspaceLease.acquire(
                 lease_server,
                 {ExecutionEnv.env_id(remote_env), ExecutionEnv.cwd(remote_env)},
                 {:conv, 2},
                 self()
               )
    end

    test "supports optional :env_id override and default cwd from agent", %{tmp_dir: tmp_dir} do
      host_env = Host.new(tmp_dir, env_id: "vm-agent-id")

      agent =
        start_supervised!({RemoteAgent, env: host_env, id: "vm-agent-id"}, id: :override_test)

      default_env = Remote.new(agent)
      assert ExecutionEnv.env_id(default_env) == "vm-agent-id"
      assert ExecutionEnv.cwd(default_env) == tmp_dir

      overridden_env = Remote.new(agent, tmp_dir, env_id: "vm-custom-override")
      assert ExecutionEnv.env_id(overridden_env) == "vm-custom-override"
      assert ExecutionEnv.kind(overridden_env) == "remote"
    end

    test "validates cwd, :env_id, and :default_exec_opts", %{tmp_dir: tmp_dir} do
      host_env = Host.new(tmp_dir)
      agent = start_supervised!({RemoteAgent, env: host_env, id: "vm-val"}, id: :val_agent)

      assert_raise ArgumentError, fn -> Remote.new(agent, "relative/path") end
      assert_raise ArgumentError, fn -> Remote.new(agent, "/bad\0cwd") end
      assert_raise ArgumentError, fn -> Remote.new(agent, tmp_dir, env_id: "") end

      assert_raise ArgumentError, fn ->
        Remote.new(agent, tmp_dir, default_exec_opts: :not_a_list)
      end
    end
  end

  describe "Remote.resolve_path/2 and Remote.bind_cwd/2" do
    test "delegates POSIX path semantics to agent without touching local Path.expand", %{
      tmp_dir: tmp_dir
    } do
      host_env = Host.new(tmp_dir)
      agent = start_supervised!({RemoteAgent, env: host_env, id: "vm-posix"}, id: :posix_agent)

      virtual_env = Remote.new(agent, "/srv/remote/../workspace/app")
      assert ExecutionEnv.cwd(virtual_env) == "/srv/workspace/app"

      assert {:ok, "/srv/workspace/app/lib/demo.ex"} ==
               ExecutionEnv.resolve_path(virtual_env, "lib/./demo.ex")

      assert {:ok, "/srv/workspace/other"} ==
               ExecutionEnv.resolve_path(virtual_env, "../other")
    end

    test "bind_cwd preserves env_id and default_exec_opts", %{tmp_dir: tmp_dir} do
      sub = Path.join(tmp_dir, "nested_ws")
      File.mkdir_p!(sub)

      host_env = Host.new(tmp_dir)
      agent = start_supervised!({RemoteAgent, env: host_env, id: "vm-bind"}, id: :bind_agent)

      env =
        Remote.new(agent, tmp_dir,
          env_id: "vm-bind-override",
          default_exec_opts: [session_id: "s-bind", incarnation: 1, lease_ms: 2_000]
        )

      assert {:ok, rebound} = ExecutionEnv.bind_cwd(env, "nested_ws")
      assert ExecutionEnv.cwd(rebound) == sub
      assert ExecutionEnv.env_id(rebound) == "vm-bind-override"

      :ok = ExecutionEnv.write_file(rebound, "marker.txt", "inside-nested")

      assert {:ok, %{exit_code: 0, output: "inside-nested"}} =
               ExecutionEnv.exec(rebound, {:shell, "cat marker.txt"})

      assert {:ok, %{exit_code: 0, output: pwd_out}} =
               ExecutionEnv.exec(rebound, {:shell, "pwd | tr -d '\\n'"})

      assert String.ends_with?(pwd_out, "/nested_ws")
    end
  end

  describe "Remote.exec/3 fencing and lease integration" do
    test "merges default_exec_opts and enforces stale fence rejection", %{tmp_dir: tmp_dir} do
      host_env = Host.new(tmp_dir)
      agent = start_supervised!({RemoteAgent, env: host_env, id: "vm-fence"}, id: :fence_agent)

      env =
        Remote.new(agent, tmp_dir,
          default_exec_opts: [session_id: "sess-r", incarnation: 1, task_id: 7, attempt_id: 1]
        )

      assert {:ok, %{exit_code: 0, output: "first"}} =
               ExecutionEnv.exec(env, {:shell, "printf first"})

      assert {:error, :stale_fence} =
               ExecutionEnv.exec(env, {:shell, "printf dup"})

      assert {:ok, %{exit_code: 0, output: "second"}} =
               ExecutionEnv.exec(env, {:shell, "printf second"}, attempt_id: 2)
    end

    test "expires lease and reaps process group through Remote.exec/3", %{tmp_dir: tmp_dir} do
      host_env = Host.new(tmp_dir)
      agent = start_supervised!({RemoteAgent, env: host_env, id: "vm-lease"}, id: :lease_agent)
      parent = self()

      env =
        Remote.new(agent, tmp_dir,
          default_exec_opts: [
            session_id: "sess-rl",
            incarnation: 1,
            task_id: 1,
            lease_ms: 150
          ]
        )

      assert {:error, %{reason: :lease_expired, output: output}} =
               ExecutionEnv.exec(
                 env,
                 {:shell, "sleep 120 & echo child_pid=$!; sleep 120"},
                 attempt_id: 1,
                 timeout_ms: 10_000,
                 on_output: fn chunk -> send(parent, {:chunk, chunk}) end
               )

      child_pid = receive_child_pid!()
      assert String.contains?(output, "child_pid=#{child_pid}")
      assert {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
      assert status != 0
    end
  end
end
