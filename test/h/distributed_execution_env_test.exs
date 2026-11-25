defmodule H.DistributedExecutionEnvTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(
        local_tmp("/private/tmp"),
        "h-dist-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  describe "distributed Erlang brains-vs-hands execution" do
    test "reaps remote process group when brain caller crashes mid-exec", ctx do
      hands_dir = Path.join(ctx.root, "hands-reap")
      pid_file = Path.join(hands_dir, "sleep.pid")
      File.mkdir_p!(hands_dir)

      assert {output, 0} =
               launch_distributed("""
               pa_args =
                 :code.get_path()
                 |> Enum.map(&List.to_string/1)
                 |> Enum.map(&Path.expand/1)
                 |> Enum.filter(&File.dir?/1)
                 |> Enum.flat_map(&[~c"-pa", String.to_charlist(&1)])

               uniq = System.unique_integer([:positive])

               {:ok, peer_pid, peer_node} =
                 :peer.start_link(%{
                   name: String.to_atom("hands_reap_\#{uniq}"),
                   host: ~c"127.0.0.1",
                   args: pa_args ++ [~c"+S", ~c"2:2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
                 })

               {:ok, _} =
                 :erpc.call(peer_node, fn ->
                   host_env = H.ExecutionEnv.Host.new(#{inspect(hands_dir)}, env_id: "node.reap")
                   GenServer.start(H.RemoteAgent, [env: host_env, id: "node.reap"], name: H.RemoteAgent)
                 end)

               {:ok, env} = H.ExecutionEnv.Remote.connect_node(peer_node, #{inspect(hands_dir)}, env_id: "node.reap")
               pid_file = #{inspect(pid_file)}

               caller =
                 spawn(fn ->
                   H.ExecutionEnv.exec(
                     env,
                     {:shell, "echo $$ > " <> pid_file <> " && sleep 30"},
                     timeout_ms: 25_000,
                     lease_ms: 10_000
                   )
                 end)

               wait_file = fn wait_file, n ->
                 case File.read(pid_file) do
                   {:ok, raw} when byte_size(raw) > 0 ->
                     raw |> String.trim() |> String.to_integer()

                   _ when n > 0 ->
                     Process.sleep(25)
                     wait_file.(wait_file, n - 1)

                   _ ->
                     raise "remote command never started"
                 end
               end

               os_pid = wait_file.(wait_file, 120)
               Process.exit(caller, :kill)

               wait_reaped = fn wait_reaped, n ->
                 case :erpc.call(peer_node, fn ->
                        {_, code} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
                        code
                      end) do
                   code when code != 0 -> :ok
                   _ when n > 0 ->
                     Process.sleep(40)
                     wait_reaped.(wait_reaped, n - 1)
                   _ ->
                     raise "remote OS process was not reaped after brain caller died"
                 end
               end

               :ok = wait_reaped.(wait_reaped, 100)
               [] = H.RemoteAgent.active_fences({H.RemoteAgent, peer_node})
               :peer.stop(peer_pid)
               IO.puts("REAP_OK")
               """)

      assert output =~ "REAP_OK"
    end

    test "local brain daemon coordinates tools across two separate BEAM hands nodes and reaps on disconnect",
         ctx do
      data_dir = Path.join(ctx.root, "brain-data")
      hands_a_dir = Path.join(ctx.root, "hands-a")
      hands_b_dir = Path.join(ctx.root, "hands-b")
      Enum.each([data_dir, hands_a_dir, hands_b_dir], &File.mkdir_p!/1)

      File.write!(Path.join(hands_a_dir, "marker.txt"), "from-hands-node-a\n")
      File.write!(Path.join(hands_b_dir, "marker.txt"), "from-hands-node-b\n")

      assert {output, 0} =
               launch_distributed("""
               brain_node = node()
               brain_pid = System.pid()

               pa_args =
                 :code.get_path()
                 |> Enum.map(&List.to_string/1)
                 |> Enum.map(&Path.expand/1)
                 |> Enum.filter(&File.dir?/1)
                 |> Enum.flat_map(&[~c"-pa", String.to_charlist(&1)])

               start_hands = fn short_name, workdir, env_id ->
                 {:ok, peer_pid, peer_node} =
                   :peer.start_link(%{
                     name: String.to_atom(short_name),
                     host: ~c"127.0.0.1",
                     args: pa_args ++ [~c"+S", ~c"2:2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
                   })

                 {:ok, _agent_pid} =
                   :erpc.call(peer_node, fn ->
                     host_env = H.ExecutionEnv.Host.new(workdir, env_id: env_id)
                     GenServer.start(H.RemoteAgent, [env: host_env, id: env_id], name: H.RemoteAgent)
                   end)

                 {peer_pid, peer_node}
               end

               uniq = System.unique_integer([:positive])
               {peer_a, node_a} = start_hands.("hands_a_\#{uniq}", #{inspect(hands_a_dir)}, "node.a")
               {peer_b, node_b} = start_hands.("hands_b_\#{uniq}", #{inspect(hands_b_dir)}, "node.b")

               # Verify hands nodes are genuinely separate OS processes / BEAM VMs
               pid_a = :erpc.call(node_a, System, :pid, [])
               pid_b = :erpc.call(node_b, System, :pid, [])
               true = brain_pid != pid_a and brain_pid != pid_b and pid_a != pid_b

               # Connect brain directly via H.ExecutionEnv.Remote.connect_node/3
               {:ok, env_a} = H.ExecutionEnv.Remote.connect_node(node_a, #{inspect(hands_a_dir)}, env_id: "node.a")
               {:ok, env_b} = H.ExecutionEnv.Remote.connect_node(node_b, #{inspect(hands_b_dir)}, env_id: "node.b")

               {:ok, %{lines: ["from-hands-node-a"]}} = H.ExecutionEnv.read_file_lines(env_a, "marker.txt")
               {:ok, %{lines: ["from-hands-node-b"]}} = H.ExecutionEnv.read_file_lines(env_b, "marker.txt")

               # Start brain H.Daemon with BOTH remote hands nodes registered in H.EnvRegistry
               {:ok, _} = H.Provider.Fake.start_link(name: H.Provider.Fake, script: [
                 {:reply, [], %{tool_calls: [%{id: "t-a", name: "bash", arguments: %{"command" => "cat marker.txt && echo NODE_A_OK"}}], finish_reason: "tool_calls"}},
                 {:reply, [], %{content: [%{type: "text", text: "Done on node A"}]}},
                 {:reply, [], %{tool_calls: [%{id: "t-b", name: "bash", arguments: %{"command" => "cat marker.txt && echo NODE_B_OK"}}], finish_reason: "tool_calls"}},
                 {:reply, [], %{content: [%{type: "text", text: "Done on node B"}]}}
               ])

               {:ok, _} = H.serve(
                 data_dir: #{inspect(data_dir)},
                 port: 0,
                 api_socket: false,
                 provider: H.Provider.Fake,
                 default_model: "fake:coder",
                 environments: [
                   H.ExecutionEnv.Remote.env_spec_for_node("node.a", node_a, default_cwd: #{inspect(hands_a_dir)}),
                   H.ExecutionEnv.Remote.env_spec_for_node("node.b", node_b, default_cwd: #{inspect(hands_b_dir)})
                 ]
               )

               opts = H.Daemon.instance_options()
               envs = H.Daemon.list_environments(opts)
               true = Enum.any?(envs, &(&1.id == "node.a" and &1.kind == "remote"))
               true = Enum.any?(envs, &(&1.id == "node.b" and &1.kind == "remote"))

               # Run sessions on node A and node B coordinated by the single brain daemon
               {:ok, _} = H.Daemon.create_session(%{"session_id" => "s-a", "env_id" => "node.a", "cwd" => #{inspect(hands_a_dir)}}, opts)
               {:ok, _} = H.Daemon.execute_command("s-a", %{
                 "version" => 1, "request_id" => "req-a", "command" => "submit",
                 "conversation_id" => "1", "args" => %{"type" => "input", "content" => "inspect A"}
               }, opts)

               poll = fn poll, sid, needle, n ->
                 {:ok, page} = H.Daemon.scan_entries(sid, "1", %{}, opts)
                 if Enum.any?(page.items, &String.contains?(JSON.encode!(&1), needle)) do
                   page.items
                 else
                   if n == 0, do: raise("timed out waiting for " <> needle)
                   Process.sleep(20)
                   poll.(poll, sid, needle, n - 1)
                 end
               end

               items_a = poll.(poll, "s-a", "Done on node A", 150)
               true = Enum.any?(items_a, &String.contains?(JSON.encode!(&1), "from-hands-node-a"))
               true = Enum.any?(items_a, &String.contains?(JSON.encode!(&1), "NODE_A_OK"))

               {:ok, _} = H.Daemon.create_session(%{"session_id" => "s-b", "env_id" => "node.b", "cwd" => #{inspect(hands_b_dir)}}, opts)
               {:ok, _} = H.Daemon.execute_command("s-b", %{
                 "version" => 1, "request_id" => "req-b", "command" => "submit",
                 "conversation_id" => "1", "args" => %{"type" => "input", "content" => "inspect B"}
               }, opts)

               items_b = poll.(poll, "s-b", "Done on node B", 150)
               true = Enum.any?(items_b, &String.contains?(JSON.encode!(&1), "from-hands-node-b"))
               true = Enum.any?(items_b, &String.contains?(JSON.encode!(&1), "NODE_B_OK"))

               # Disconnect / stop hands node A -> exec reports agent_down cleanly, never crashes brain!
               :peer.stop(peer_a)
               {:error, {:agent_down, _}} = H.ExecutionEnv.read_file_lines(env_a, "marker.txt")
               # Meanwhile hands node B continues working unaffected
               {:ok, %{lines: ["from-hands-node-b"]}} = H.ExecutionEnv.read_file_lines(env_b, "marker.txt")
               :peer.stop(peer_b)

               true = is_atom(brain_node)
               IO.puts("DISTRIBUTED_OK")
               """)

      assert output =~ "DISTRIBUTED_OK"
    end
  end

  defp local_tmp(path), do: if(File.dir?(path), do: path, else: System.tmp_dir!())

  defp launch_distributed(script) do
    pa_args =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&["-pa", &1])

    uniq = System.unique_integer([:positive])

    System.cmd(
      System.find_executable("elixir"),
      [
        "--name",
        "h_brain_#{uniq}@127.0.0.1",
        "--cookie",
        "h_test_cookie_#{uniq}"
      ] ++
        pa_args ++
        [
          "--erl",
          "+S 2:2",
          "-e",
          "Application.put_env(:req_llm, :load_dotenv, false)\n" <> script
        ],
      stderr_to_stdout: true,
      env: [{"H_DATA_DIR", nil}]
    )
  end
end
