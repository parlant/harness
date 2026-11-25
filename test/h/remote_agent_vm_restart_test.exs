defmodule H.RemoteAgent.VmRestartTest do
  use ExUnit.Case, async: false

  alias H.{Catalog, Daemon, StoreLock, WorkspaceLease}
  alias H.Daemon.CLI
  alias H.ExecutionEnv.Remote
  alias H.Provider.Fake
  alias H.RemoteAgent
  alias H.RemoteAgent.Client

  setup_all do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  describe "CLI.parse_remote_agent/1 and missing token validation" do
    test "parses remote-agent flags and rejects empty/missing tokens" do
      assert {:ok, opts} =
               CLI.parse([
                 "remote-agent",
                 "--cwd",
                 "/tmp/work",
                 "--id",
                 "hands-1",
                 "--bind",
                 "127.0.0.1",
                 "--port",
                 "0",
                 "--socket",
                 "/tmp/agent.sock",
                 "--token-file",
                 "/tmp/token"
               ])

      assert opts[:subcommand] == :remote_agent
      assert opts[:cwd] == "/tmp/work"
      assert opts[:id] == "hands-1"
      assert opts[:ip] == {127, 0, 0, 1}
      assert opts[:port] == 0
      assert opts[:socket] == "/tmp/agent.sock"
      assert opts[:token_file] == "/tmp/token"

      assert {:error, :usage} = CLI.parse(["remote-agent", "--bind", "not-an-ip"])
      assert {:error, :usage} = CLI.parse(["remote-agent", "--port", "70000"])
      assert :help = CLI.parse_remote_agent(["--help"])

      elixir_exe = System.find_executable("elixir")
      assert is_binary(elixir_exe)

      pa_args =
        :code.get_path()
        |> Enum.map(&List.to_string/1)
        |> Enum.map(&Path.expand/1)
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(&["-pa", &1])

      {out, status} =
        System.cmd(
          elixir_exe,
          pa_args ++
            [
              "-e",
              "Application.put_env(:req_llm, :load_dotenv, false)\nH.Daemon.CLI.main([\"remote-agent\", \"--port\", \"0\"])"
            ],
          stderr_to_stdout: true,
          env: [{"H_REMOTE_AGENT_TOKEN", ""}]
        )

      assert status != 0
      assert out =~ "token"
    end
  end

  @tag timeout: 30_000
  test "real remote-agent subprocess + brain daemon SIGKILL mid-bash reaps remote PGID and never replays :unsafe tool" do
    id = System.unique_integer([:positive])
    tmp_root = Path.join("/private/tmp", "h-remote-vm-restart-#{id}")
    data_dir = Path.join(tmp_root, "data")
    hands_cwd = Path.join(tmp_root, "hands-work")
    token_file = Path.join(tmp_root, "remote.token")
    pid_file = Path.join(hands_cwd, "remote_child.pid")
    unsafe_counter = Path.join(hands_cwd, "unsafe-count")

    Enum.each([data_dir, hands_cwd], &File.mkdir_p!/1)

    token =
      "subproc-token-#{id}-#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"

    File.write!(token_file, token <> "\n")
    File.chmod!(token_file, 0o600)

    on_exit(fn ->
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    elixir_exe = System.find_executable("elixir")
    assert is_binary(elixir_exe)

    pa_args =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&["-pa", &1])

    # 1. Spawn standalone `h-daemon remote-agent` OS process using --token-file
    remote_port =
      Port.open({:spawn_executable, elixir_exe}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 4096},
        {:args,
         pa_args ++
           [
             "-e",
             "Application.put_env(:req_llm, :load_dotenv, false)\nH.Daemon.CLI.main(System.argv())",
             "remote-agent",
             "--cwd",
             hands_cwd,
             "--id",
             "remote.hands",
             "--bind",
             "127.0.0.1",
             "--port",
             "0",
             "--token-file",
             token_file
           ]}
      ])

    {remote_url, remote_os_pid} = await_remote_agent_ready(remote_port)

    on_exit(fn ->
      if Port.info(remote_port) != nil, do: Port.close(remote_port)
      System.cmd("kill", ["-TERM", remote_os_pid], stderr_to_stdout: true)
    end)

    # 2. Spawn brain daemon OS process targeting remote-agent via Remote.env_spec_for_http/3
    brain_script = """
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:crypto)
    Application.ensure_all_started(:req)

    data_dir = System.fetch_env!("H_TEST_DATA_DIR")
    hands_cwd = System.fetch_env!("H_TEST_HANDS_CWD")
    remote_url = System.fetch_env!("H_TEST_REMOTE_URL")
    token = System.fetch_env!("H_TEST_REMOTE_TOKEN")
    pid_file = System.fetch_env!("H_TEST_PID_FILE")
    unsafe_counter = System.fetch_env!("H_TEST_UNSAFE_COUNTER")

    {:ok, _} = H.StoreLock.start_link(data_dir: data_dir, name: H.StoreLock)
    {:ok, _} = Registry.start_link(keys: :unique, name: H.Registry)
    {:ok, _} = Registry.start_link(keys: :duplicate, name: H.PubSub)
    {:ok, _} = H.Catalog.start_link(data_dir: data_dir, name: H.Catalog, table: :h_catalog)
    {:ok, _} = H.WorkspaceLease.start_link(name: H.WorkspaceLease)
    {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: H.Session.RuntimeSupervisor)

    cmd = "printf tick >> '" <> unsafe_counter <> "'; echo $$ > '" <> pid_file <> "'; echo 'remote-partial'; sleep 60"

    {:ok, fake} =
      H.Provider.Fake.start_link(
        script: [
          {:reply, [],
           %{
             content: [],
             tool_calls: [
               %{
                 id: "call_remote_1",
                 name: "bash",
                 arguments: %{"command" => cmd}
               }
             ],
             finish_reason: "tool_calls"
           }}
        ]
      )

    env_spec =
      H.ExecutionEnv.Remote.env_spec_for_http("remote.hands", remote_url,
        token: token,
        default_cwd: hands_cwd,
        lease_ms: 20_000,
        heartbeat_ms: 1_000
      )

    opts = [
      data_dir: data_dir,
      provider: H.Provider.Fake,
      provider_config: %{server: fake},
      storage_mod: H.Storage.File,
      storage_opts: [sync: :datasync],
      persist_within_ms: 15,
      ephemeral_interval_ms: 5,
      default_model: "fake:coder",
      environments: [env_spec]
    ]

    {:ok, _} =
      H.Daemon.create_session(
        %{"session_id" => "remote-vm-rec", "env_id" => "remote.hands", "cwd" => hands_cwd},
        opts
      )

    {:ok, _} =
      H.Daemon.execute_command(
        "remote-vm-rec",
        %{
          "version" => 1,
          "request_id" => "remote-vm-req-1",
          "command" => "submit",
          "conversation_id" => "1",
          "args" => %{"type" => "input", "content" => "Run slow remote bash"}
        },
        opts
      )

    wait_flushed = fn wait_flushed ->
      {:ok, {:snapshot, _seq, bin}} =
        H.Daemon.subscribe_conversation("remote-vm-rec", "1", self(), nil, opts)

      out = JSON.decode!(bin) |> get_in(["docs", "live", "tools", "call_remote_1", "output"])

      if is_binary(out) and String.contains?(out, "remote-partial") and File.exists?(pid_file) do
        :ok
      else
        Process.sleep(15)
        wait_flushed.(wait_flushed)
      end
    end

    wait_flushed.(wait_flushed)
    IO.puts("BRAIN_READY:" <> System.pid())

    receive do
      :never -> :ok
    end
    """

    brain_port =
      Port.open({:spawn_executable, elixir_exe}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 4096},
        {:args,
         pa_args ++
           [
             "-e",
             "Application.put_env(:req_llm, :load_dotenv, false)\n" <> brain_script
           ]},
        {:env,
         [
           {~c"H_TEST_DATA_DIR", String.to_charlist(data_dir)},
           {~c"H_TEST_HANDS_CWD", String.to_charlist(hands_cwd)},
           {~c"H_TEST_REMOTE_URL", String.to_charlist(remote_url)},
           {~c"H_TEST_REMOTE_TOKEN", String.to_charlist(token)},
           {~c"H_TEST_PID_FILE", String.to_charlist(pid_file)},
           {~c"H_TEST_UNSAFE_COUNTER", String.to_charlist(unsafe_counter)}
         ]}
      ])

    brain_os_pid = await_brain_ready(brain_port)

    on_exit(fn ->
      if Port.info(brain_port) != nil, do: Port.close(brain_port)
      System.cmd("kill", ["-9", brain_os_pid], stderr_to_stdout: true)
    end)

    remote_child_pid = pid_file |> File.read!() |> String.trim()
    assert {_, 0} = System.cmd("/bin/kill", ["-0", remote_child_pid], stderr_to_stdout: true)

    # 3. SIGKILL the brain daemon mid-remote-bash!
    {_out, 0} = System.cmd("kill", ["-9", brain_os_pid])
    assert_receive {^brain_port, {:exit_status, _status}}, 5_000

    # Remote agent detects HTTP stream socket close and reaps the remote OS PGID
    client = Client.new(remote_url, token: token)

    wait_until(fn ->
      {_, code} = System.cmd("/bin/kill", ["-0", remote_child_pid], stderr_to_stdout: true)
      code != 0 and RemoteAgent.active_fences(client) == []
    end)

    # 4. Boot fresh brain supervisor tree on the exact same data_dir and verify zero :unsafe replay
    start_supervised!({StoreLock, data_dir: data_dir, name: :"H.RemoteVmTest.Lock.#{id}"})
    registry = :"H.RemoteVmTest.Registry.#{id}"
    pubsub = :"H.RemoteVmTest.PubSub.#{id}"
    catalog = :"H.RemoteVmTest.Catalog.#{id}"
    catalog_table = :"h_remote_vm_test_catalog_#{id}"
    lease = :"H.RemoteVmTest.Lease.#{id}"
    runtime_sup = :"H.RemoteVmTest.RuntimeSup.#{id}"
    fake_name = :"H.RemoteVmTest.Fake.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

    fake2 =
      start_supervised!(
        {Fake,
         name: fake_name,
         script: [
           {:expect,
            fn req ->
              tool_msg =
                Enum.find(
                  req.messages,
                  &(&1.role == "tool" and &1.tool_call_id == "call_remote_1")
                )

              assert tool_msg.is_error == true
              text = hd(tool_msg.content).text
              assert text =~ "interrupted"
              assert text =~ "remote-partial"
              true
            end, {:reply, [], %{content: [%{type: "text", text: "Recovered remote session!"}]}}}
         ]}
      )

    env_spec2 =
      Remote.env_spec_for_http("remote.hands", remote_url,
        token: token,
        default_cwd: hands_cwd
      )

    opts2 = [
      registry: registry,
      pubsub: pubsub,
      catalog: catalog,
      catalog_table: catalog_table,
      workspace_lease: lease,
      runtime_sup: runtime_sup,
      data_dir: data_dir,
      provider: Fake,
      provider_config: %{server: fake2},
      storage_mod: H.Storage.File,
      storage_opts: [sync: :datasync],
      environments: [env_spec2]
    ]

    assert :ok = Daemon.recover_active_sessions(opts2)
    wait_until(fn -> Fake.requests(fake2) != [] end)

    items =
      wait_until(fn ->
        {:ok, %{items: items}} =
          Daemon.scan_entries("remote-vm-rec", "1", %{"order" => "asc"}, opts2)

        if length(items) == 4, do: items, else: nil
      end)

    assert Enum.map(items, & &1.kind) == ["user", "assistant", "tool_result", "assistant"]
    tool_res = Enum.at(items, 2)
    assert tool_res.data["is_error"] == true
    assert tool_res.data["diagnostic"] == "interrupted"
    assert tool_res.data["details"]["partial_output"] =~ "remote-partial"

    # Exactly one execution occurred; no :unsafe replay on restart
    assert File.read!(unsafe_counter) == "tick"

    # 5. Clean SIGTERM shutdown of the standalone remote-agent process
    {_out, 0} = System.cmd("kill", ["-TERM", remote_os_pid])
    assert_receive {^remote_port, {:exit_status, 0}}, 5_000
  end

  defp await_remote_agent_ready(port, url \\ nil) do
    receive do
      {^port, {:data, {:eol, "H remote-agent HTTP listening at " <> bound_url}}} ->
        await_remote_agent_ready(port, String.trim(bound_url))

      {^port, {:data, {:eol, "READY:" <> os_pid}}} ->
        {url || flunk("missing remote-agent HTTP URL before READY"), os_pid}

      {^port, {:data, {:eol, _line}}} ->
        await_remote_agent_ready(port, url)

      {^port, {:exit_status, status}} ->
        flunk("remote-agent exited early with status #{status}")
    after
      10_000 ->
        flunk("timed out waiting for remote-agent to reach READY state")
    end
  end

  defp await_brain_ready(port) do
    receive do
      {^port, {:data, {:eol, "BRAIN_READY:" <> os_pid}}} ->
        os_pid

      {^port, {:data, {:eol, _line}}} ->
        await_brain_ready(port)

      {^port, {:exit_status, status}} ->
        flunk("brain VM exited early with status #{status}")
    after
      10_000 ->
        flunk("timed out waiting for brain VM to reach BRAIN_READY state")
    end
  end

  defp wait_until(fun, timeout_ms \\ 5_000) do
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
        Process.sleep(20)
        do_wait_until(fun, deadline)
      end
    end
  end
end
