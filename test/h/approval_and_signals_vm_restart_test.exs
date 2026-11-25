defmodule H.ApprovalAndSignalsVmRestartTest do
  use ExUnit.Case, async: true

  alias H.{Catalog, Daemon, StoreLock, WorkspaceLease}
  alias H.Provider.Fake

  @tag timeout: 20_000
  test "preserves unapproved waiting tool, queued signal, and wait_signal timeout timer across SIGKILL VM restart" do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-r2-vm-restart-#{id}")
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
                 id: "c_vm_write",
                 name: "write",
                 arguments: %{"path" => "approved_after_crash.txt", "content" => "safe"}
               }
             ],
             finish_reason: "tool_calls"
           }},
          {:reply, [],
           %{
             content: [],
             tool_calls: [
               %{
                 id: "c_vm_wait",
                 name: "wait_signal",
                 arguments: %{"topic" => "after.crash", "timeout_ms" => 350}
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
      default_model: "fake:coder"
    ]

    # Session 1: parked on approval
    {:ok, _} =
      H.Daemon.create_session(
        %{"session_id" => "vm-app", "cwd" => cwd, "agent" => %{"approval_policy" => "mutating"}},
        opts
      )

    {:ok, _} =
      H.Daemon.execute_command(
        "vm-app",
        %{
          "version" => 1,
          "request_id" => "req-app",
          "command" => "submit",
          "conversation_id" => "1",
          "args" => %{"type" => "input", "content" => "Write file"}
        },
        opts
      )

    wait_app = fn wait_app ->
      {:ok, {:snapshot, _, bin}} = H.Daemon.subscribe_conversation("vm-app", "1", self(), nil, opts)
      approvals = JSON.decode!(bin)["docs"]["live"]["approvals"] || %{}
      if map_size(approvals) == 1, do: :ok, else: (Process.sleep(15); wait_app.(wait_app))
    end

    wait_app.(wait_app)

    # Deliver an unconsumed signal to vm-app before crash to test signal doc persistence
    {:ok, _} =
      H.Daemon.deliver_signal(
        "vm-app",
        %{"request_id" => "pre-sig", "topic" => "survives.crash", "payload" => %{"ok" => true}},
        opts
      )

    # Session 2: parked on wait_signal with 350ms timeout
    {:ok, _} = H.Daemon.create_session(%{"session_id" => "vm-sig", "cwd" => cwd}, opts)

    {:ok, _} =
      H.Daemon.execute_command(
        "vm-sig",
        %{
          "version" => 1,
          "request_id" => "req-sig",
          "command" => "submit",
          "conversation_id" => "1",
          "args" => %{"type" => "input", "content" => "Wait with timeout"}
        },
        opts
      )

    wait_sig = fn wait_sig ->
      {:ok, d} = H.Daemon.get_session_detail("vm-sig", opts)
      if Enum.any?(d.tasks, &(&1.kind == "tool_call" and &1.status == "waiting")),
        do: :ok,
        else: (Process.sleep(15); wait_sig.(wait_sig))
    end

    wait_sig.(wait_sig)

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

    {_out, 0} = System.cmd("kill", ["-9", os_pid])
    assert_receive {^port, {:exit_status, _status}}, 5_000

    # Boot fresh VM supervisor stack on the exact same data_dir
    start_supervised!({StoreLock, data_dir: data_dir, name: :"H.R2VmTest.Lock.#{id}"})
    registry = :"H.R2VmTest.Registry.#{id}"
    pubsub = :"H.R2VmTest.PubSub.#{id}"
    catalog = :"H.R2VmTest.Catalog.#{id}"
    catalog_table = :"h_r2_vm_test_catalog_#{id}"
    lease = :"H.R2VmTest.Lease.#{id}"
    runtime_sup = :"H.R2VmTest.RuntimeSup.#{id}"
    fake_name = :"H.R2VmTest.Fake.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

    fake2 =
      start_supervised!({Fake,
       name: fake_name,
       script: [
         # Turn 2 for vm-sig (after wait_signal timeout timer fires on recovery)
         {:expect,
          fn req ->
            tr = Enum.find(req.messages, &(&1.role == "tool" and &1.tool_call_id == "c_vm_wait"))
            assert tr != nil
            assert tr.is_error == true
            assert hd(tr.content).text =~ "Timed out"
            true
          end, {:reply, [], %{content: [%{type: "text", text: "Timed out after VM restart"}]}}},
         # Turn 2 for vm-app (after operator approves write), calls wait_signal on pre-queued survives.crash
         {:expect,
          fn req ->
            tr = Enum.find(req.messages, &(&1.role == "tool" and &1.tool_call_id == "c_vm_write"))
            assert tr != nil and tr.is_error == false
            true
          end,
          {:reply, [],
           %{
             content: [],
             tool_calls: [
               %{
                 id: "c_vm_consume_pre",
                 name: "wait_signal",
                 arguments: %{"topic" => "survives.crash"}
               }
             ],
             finish_reason: "tool_calls"
           }}},
         {:expect,
          fn req ->
            tr =
              Enum.find(
                req.messages,
                &(&1.role == "tool" and &1.tool_call_id == "c_vm_consume_pre")
              )

            assert tr != nil and tr.is_error == false
            assert hd(tr.content).text =~ "true"
            true
          end, {:reply, [], %{content: [%{type: "text", text: "Approved and consumed signal"}]}}}
       ]})

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
      default_model: "fake:coder"
    ]

    assert :ok = Daemon.recover_active_sessions(opts2)

    # 1. vm-sig re-armed its wake["until"] timer and times out without manual intervention!
    sig_out =
      wait_until(fn ->
        {:ok, o} = Daemon.get_submission("vm-sig", "req-sig", opts2)
        if o.status == "done", do: o, else: nil
      end)

    assert sig_out.answer_text == "Timed out after VM restart"

    # 2. vm-app MUST STILL be waiting for approval and MUST NOT have executed write!
    refute File.exists?(Path.join(cwd, "approved_after_crash.txt"))

    {:ok, {:snapshot, _, app_bin}} =
      Daemon.subscribe_conversation("vm-app", "1", self(), nil, opts2)

    app_snap = JSON.decode!(app_bin)
    [approval] = Map.values(app_snap["docs"]["live"]["approvals"])
    assert approval["tool_name"] == "write"

    # Idempotent retry of pre-sig after restart -> still 200 with same signal_id, no conflict
    assert {:ok, _} =
             Daemon.deliver_signal(
               "vm-app",
               %{
                 "request_id" => "pre-sig",
                 "topic" => "survives.crash",
                 "payload" => %{"ok" => true}
               },
               opts2
             )

    # Now approve write -> executes write, then immediately consumes the pre-crash queued signal!
    {:ok, _} =
      Daemon.execute_command(
        "vm-app",
        %{
          "version" => 1,
          "request_id" => "approve-after-vm",
          "command" => "approve_tool",
          "conversation_id" => "1",
          "args" => %{"task_id" => String.to_integer(approval["task_id"]), "decision" => "allow"}
        },
        opts2
      )

    app_out =
      wait_until(fn ->
        {:ok, o} = Daemon.get_submission("vm-app", "req-app", opts2)
        if o.status == "done", do: o, else: nil
      end)

    assert app_out.answer_text == "Approved and consumed signal"
    assert File.read!(Path.join(cwd, "approved_after_crash.txt")) == "safe"
  end

  defp await_ready_pid(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case String.split(line, "READY:", parts: 2) do
          [_, pid_str] -> String.trim(pid_str)
          _ -> await_ready_pid(port)
        end

      {^port, {:exit_status, status}} ->
        flunk("child BEAM exited early with status #{status}")
    after
      10_000 -> flunk("timed out waiting for child BEAM READY")
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
        Process.sleep(15)
        do_wait_until(fun, deadline)
      end
    end
  end
end
