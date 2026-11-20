defmodule H.VmRestartTest do
  use ExUnit.Case, async: true

  alias H.{Catalog, Daemon, StoreLock, WorkspaceLease}
  alias H.Provider.Fake

  @tag timeout: 20_000
  test "recovers durable session state automatically after SIGKILL of daemon OS process mid-tool" do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-vm-restart-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

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

    child_script = """
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:crypto)

    data_dir = System.fetch_env!("H_TEST_DATA_DIR")
    cwd = System.fetch_env!("H_TEST_CWD")

    {:ok, _} = H.StoreLock.start_link(data_dir: data_dir, name: H.StoreLock)
    {:ok, _} = Registry.start_link(keys: :unique, name: H.Registry)
    {:ok, _} = Registry.start_link(keys: :duplicate, name: H.PubSub)
    {:ok, _} = H.Catalog.start_link(data_dir: data_dir, name: H.Catalog, table: :h_catalog)
    {:ok, _} = H.WorkspaceLease.start_link(name: H.WorkspaceLease)
    {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: H.Session.RuntimeSupervisor)

    {:ok, fake} =
      H.Provider.Fake.start_link(
        script: [
          {:reply, [],
           %{
             content: [],
             tool_calls: [
               %{
                 id: "call_vm_1",
                 name: "bash",
                 arguments: %{"command" => "echo 'vm-partial'; sleep 2"}
               }
             ],
             finish_reason: "tool_calls"
           }}
        ]
      )

    opts = [
      data_dir: data_dir,
      provider: H.Provider.Fake,
      provider_config: %{server: fake},
      storage_mod: H.Storage.File,
      storage_opts: [sync: :datasync],
      persist_within_ms: 15,
      ephemeral_interval_ms: 5,
      default_model: "fake:coder"
    ]

    {:ok, _} = H.Daemon.create_session(%{"session_id" => "vm-rec", "cwd" => cwd}, opts)

    {:ok, _} =
      H.Daemon.execute_command(
        "vm-rec",
        %{
          "version" => 1,
          "request_id" => "vm-req-1",
          "command" => "submit",
          "conversation_id" => "1",
          "args" => %{"type" => "input", "content" => "Run slow bash"}
        },
        opts
      )

    wait_flushed = fn wait_flushed ->
      {:ok, {:snapshot, _seq, bin}} =
        H.Daemon.subscribe_conversation("vm-rec", "1", self(), nil, opts)

      out = JSON.decode!(bin) |> get_in(["docs", "live", "tools", "call_vm_1", "output"])

      if is_binary(out) and String.contains?(out, "vm-partial") do
        :ok
      else
        Process.sleep(15)
        wait_flushed.(wait_flushed)
      end
    end

    wait_flushed.(wait_flushed)

    {:ok, %{seq: wait_seq}} = H.Daemon.create_session(%{"session_id" => "vm-wait", "cwd" => cwd}, opts)
    {:ok, _} = H.Daemon.execute_command("vm-wait", %{
      "version" => 1, "request_id" => "queued-shell", "command" => "user_shell", "conversation_id" => "1",
      "args" => %{"command" => "printf tick >> wait-count", "include_in_context" => true, "expected_seq" => wait_seq}
    }, opts)
    {:ok, {:snapshot, _, wait_bin}} = H.Daemon.subscribe_conversation("vm-wait", "1", self(), nil, opts)
    true = is_map(JSON.decode!(wait_bin)["docs"]["live"]["workspace_wait"])
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
           {~c"H_TEST_CWD", String.to_charlist(cwd)}
         ]}
      ])

    os_pid = await_ready_pid(port)

    on_exit(fn ->
      if Port.info(port) != nil, do: Port.close(port)
      System.cmd("kill", ["-9", os_pid], stderr_to_stdout: true)
    end)

    # Confirm lock is actively held by child OS process
    assert {:error, :store_locked} = StoreLock.start_link(data_dir: data_dir)

    # SIGKILL the child BEAM OS process mid-bash-execution!
    {_out, 0} = System.cmd("kill", ["-9", os_pid])
    assert_receive {^port, {:exit_status, _status}}, 5_000

    # Boot a fresh isolated supervisor tree in this VM on the exact same data_dir
    start_supervised!({StoreLock, data_dir: data_dir, name: :"H.VmTest.Lock.#{id}"})
    registry = :"H.VmTest.Registry.#{id}"
    pubsub = :"H.VmTest.PubSub.#{id}"
    catalog = :"H.VmTest.Catalog.#{id}"
    catalog_table = :"h_vm_test_catalog_#{id}"
    lease = :"H.VmTest.Lease.#{id}"
    runtime_sup = :"H.VmTest.RuntimeSup.#{id}"
    fake_name = :"H.VmTest.Fake.#{id}"

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
              tool_msg = Enum.find(req.messages, &(&1.role == "tool"))
              assert tool_msg.is_error == true
              text = hd(tool_msg.content).text
              assert text =~ "interrupted"
              assert text =~ "vm-partial"
              true
            end, {:reply, [], %{content: [%{type: "text", text: "Recovered after SIGKILL!"}]}}}
         ]}
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
      storage_opts: [sync: :datasync]
    ]

    # Boot recovery pass automatically wakes and reconciles unfinished active sessions
    # BEFORE any client reconnects or calls get_session_detail!
    assert :ok = Daemon.recover_active_sessions(opts2)
    assert length(Fake.requests(fake2)) >= 0

    wait_until(fn ->
      Fake.requests(fake2) != []
    end)

    assert {:ok, detail} = Daemon.get_session_detail("vm-rec", opts2)
    assert detail.session.session_id == "vm-rec"

    items =
      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("vm-rec", "1", %{"order" => "asc"}, opts2)
        if length(items) == 4, do: items, else: nil
      end)

    assert Enum.map(items, & &1.kind) == ["user", "assistant", "tool_result", "assistant"]
    tool_res = Enum.at(items, 2)
    assert tool_res.data["is_error"] == true
    assert tool_res.data["diagnostic"] == "interrupted"
    assert tool_res.data["details"]["partial_output"] =~ "vm-partial"

    [queued_result] =
      wait_until(fn ->
        {:ok, %{items: queued}} = Daemon.scan_entries("vm-wait", "1", %{"order" => "asc"}, opts2)
        if length(queued) == 1, do: queued, else: nil
      end)

    assert queued_result.data["is_error"] == false
    assert File.read!(Path.join(cwd, "wait-count")) == "tick"

    final_assistant = Enum.at(items, 3)

    assert final_assistant.data["content"] == [
             %{"type" => "text", "text" => "Recovered after SIGKILL!"}
           ]
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
end
