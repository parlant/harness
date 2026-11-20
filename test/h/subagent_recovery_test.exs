defmodule H.SubagentRecoveryTest do
  use ExUnit.Case, async: true

  alias H.{Catalog, Daemon, StoreLock, WorkspaceLease}

  defmodule RouterProvider do
    @moduledoc false
    @behaviour H.Provider

    @impl true
    def stream_turn(%{handler: handler}, request, emit) when is_function(handler, 2) do
      handler.(request, emit)
    end

    @impl true
    def list_models(_config) do
      [
        %{
          id: "fake:coder",
          provider: "fake",
          name: "Fake Coder",
          context_window: 200_000,
          max_output_tokens: 16_384,
          supports_tools: true,
          supports_reasoning: true
        }
      ]
    end
  end

  defp start_env(handler, extra_opts \\ []) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-subagent-rec-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    registry = :"H.SubRec.Registry.#{id}"
    pubsub = :"H.SubRec.PubSub.#{id}"
    catalog = :"H.SubRec.Catalog.#{id}"
    catalog_table = :"h_sub_rec_catalog_#{id}"
    lease = :"H.SubRec.Lease.#{id}"
    runtime_sup = :"H.SubRec.RuntimeSup.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})

    start_supervised!(
      {Catalog, data_dir: data_dir, name: catalog, table: catalog_table, pubsub: pubsub}
    )

    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

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
        provider: RouterProvider,
        provider_config: %{handler: handler},
        storage_mod: H.Storage.File,
        storage_opts: [sync: :none],
        default_model: "fake:coder"
      ] ++ extra_opts

    %{
      opts: opts,
      cwd: cwd,
      data_dir: data_dir,
      tmp_root: tmp_root,
      registry: registry,
      pubsub: pubsub,
      catalog_table: catalog_table
    }
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

  defp first_user_text(req) do
    req.messages
    |> Enum.find(&(&1.role == "user"))
    |> case do
      %{content: [%{text: text} | _]} -> text
      _ -> ""
    end
  end

  defp tool_messages(req), do: Enum.filter(req.messages, &(&1.role == "tool"))

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

  describe "coordinator crash recovery while parked waiting on subagent" do
    test "restarts parent coordinator, re-watches via idempotent memos without duplicating child session, and completes when child finishes" do
      test_pid = self()
      child_gate = make_ref()
      child_calls = start_supervised!({Agent, fn -> 0 end})

      handler = fn req, _emit ->
        prompt = first_user_text(req)
        tools = tool_messages(req)

        cond do
          prompt == "Crash parent while child runs" and tools == [] ->
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_rec_1",
                   name: "subagent",
                   arguments: %{"prompt" => "Slow child task"}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Slow child task" ->
            Agent.update(child_calls, &(&1 + 1))
            send(test_pid, {:child_entered, child_gate, self()})

            receive do
              {:release, ^child_gate} -> :ok
            end

            {:ok, %{content: [%{type: "text", text: "Child succeeded across parent crash"}]}}

          prompt == "Crash parent while child runs" and length(tools) == 1 ->
            [res] = tools
            assert res.is_error == false
            assert hd(res.content).text == "Child succeeded across parent crash"
            {:ok, %{content: [%{type: "text", text: "Parent recovered cleanly"}]}}
        end
      end

      env = start_env(handler)
      parent_sid = "parent-crash-#{System.unique_integer([:positive])}"
      {:ok, _} = Daemon.create_session(%{"session_id" => parent_sid, "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          parent_sid,
          cmd("req-rc1", "submit", "1", %{
            "type" => "input",
            "content" => "Crash parent while child runs"
          }),
          env.opts
        )

      assert_receive {:child_entered, ^child_gate, child_worker}, 2_000

      # Kill parent coordinator while parked waiting!
      [{parent_pid1, _}] = Registry.lookup(env.registry, {:session, parent_sid})
      Process.exit(parent_pid1, :kill)

      # Wait for parent supervisor to restart parent coordinator with a new PID
      parent_pid2 =
        wait_until(fn ->
          case Registry.lookup(env.registry, {:session, parent_sid}) do
            [{p, _}] when p != parent_pid1 -> p
            _ -> nil
          end
        end)

      assert Process.alive?(parent_pid2)

      # Verify only ONE child session exists (idempotent memos, no duplicate spawn!)
      children =
        env.catalog_table
        |> Catalog.list_sessions()
        |> Enum.filter(&(get_in(&1, [:parent, :session_id]) == parent_sid))

      assert length(children) == 1
      assert Agent.get(child_calls, & &1) == 1

      # Now release the child worker -> restarted parent wakes on :submission_settled and finishes!
      send(child_worker, {:release, child_gate})

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries(parent_sid, "1", %{"order" => "asc"}, env.opts)

          if length(items) == 4, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == ["user", "assistant", "tool_result", "assistant"]
      assert Agent.get(child_calls, & &1) == 1

      assert List.last(items).data["content"] == [
               %{"type" => "text", "text" => "Parent recovered cleanly"}
             ]
    end

    test "picks up {:settled, outcome} immediately when child finishes while parent is stopped" do
      test_pid = self()
      child_gate = make_ref()

      handler = fn req, _emit ->
        prompt = first_user_text(req)
        tools = tool_messages(req)

        cond do
          prompt == "Parent stops while child finishes" and tools == [] ->
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_rec_2",
                   name: "subagent",
                   arguments: %{"prompt" => "Child finishes while parent down"}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Child finishes while parent down" ->
            send(test_pid, {:child_entered, child_gate, self()})

            receive do
              {:release, ^child_gate} -> :ok
            end

            {:ok, %{content: [%{type: "text", text: "Finished during parent downtime"}]}}

          prompt == "Parent stops while child finishes" and length(tools) == 1 ->
            [res] = tools
            assert res.is_error == false
            assert hd(res.content).text == "Finished during parent downtime"
            {:ok, %{content: [%{type: "text", text: "Caught settled child on reopen"}]}}
        end
      end

      env = start_env(handler)
      parent_sid = "parent-down-#{System.unique_integer([:positive])}"
      {:ok, _} = Daemon.create_session(%{"session_id" => parent_sid, "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          parent_sid,
          cmd("req-rc2", "submit", "1", %{
            "type" => "input",
            "content" => "Parent stops while child finishes"
          }),
          env.opts
        )

      assert_receive {:child_entered, ^child_gate, child_worker}, 2_000

      child_entry =
        env.catalog_table
        |> Catalog.list_sessions()
        |> Enum.find(&(get_in(&1, [:parent, :session_id]) == parent_sid))

      assert child_entry != nil

      # Stop parent supervisor cleanly so parent is completely DOWN while child settles
      parent_sup =
        DynamicSupervisor.which_children(env.opts[:runtime_sup])
        |> Enum.find_value(fn {_, sup_pid, _, _} ->
          case Registry.lookup(env.registry, {:session, parent_sid}) do
            [{p, _}] ->
              {:links, links} = Process.info(p, :links)

              if Enum.any?(links, fn l -> is_pid(l) and l != self() end) do
                # Check if sup_pid owns parent_sid via state/process tree
                children_of_sup = :sys.get_state(sup_pid)
                if children_of_sup.session_id == parent_sid, do: sup_pid, else: nil
              end

            _ ->
              nil
          end
        end)

      assert is_pid(parent_sup)
      :ok = DynamicSupervisor.terminate_child(env.opts[:runtime_sup], parent_sup)
      wait_until(fn -> Registry.lookup(env.registry, {:session, parent_sid}) == [] end)

      # Now let child finish completely while parent is NOT running!
      send(child_worker, {:release, child_gate})

      wait_until(fn ->
        {:ok, c_cat} = Catalog.get_session(child_entry.session_id, env.catalog_table)
        not c_cat.active
      end)

      # Re-open parent via recover_active_sessions -> immediately sees {:settled, outcome} and completes!
      assert :ok = Daemon.recover_active_sessions(env.opts)

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries(parent_sid, "1", %{"order" => "asc"}, env.opts)

          if length(items) == 4, do: items, else: nil
        end)

      assert List.last(items).data["content"] == [
               %{"type" => "text", "text" => "Caught settled child on reopen"}
             ]
    end
  end

  describe "OS SIGKILL VM-restart recovery" do
    @tag timeout: 25_000
    test "recovers parked parent and child subagent across SIGKILL of BEAM VM without duplicate child session" do
      id = System.unique_integer([:positive])
      tmp_root = Path.join(System.tmp_dir!(), "h-sub-vm-restart-#{id}")
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
      {:ok, _} = H.Catalog.start_link(data_dir: data_dir, name: H.Catalog, table: :h_catalog, pubsub: H.PubSub)
      {:ok, _} = H.WorkspaceLease.start_link(name: H.WorkspaceLease)
      {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: H.Session.RuntimeSupervisor)

      defmodule VmSubProvider do
        @behaviour H.Provider
        def list_models(_), do: [%{id: "fake:coder", provider: "fake", name: "Fake", context_window: 100_000, max_output_tokens: 8_192, supports_tools: true, supports_reasoning: true}]
        def stream_turn(_cfg, req, _emit) do
          user_text =
            req.messages
            |> Enum.find(&(&1.role == "user"))
            |> then(fn %{content: [%{text: t} | _]} -> t end)

          if user_text == "Delegate across SIGKILL" do
            {:ok, %{
              content: [],
              tool_calls: [%{id: "call_vm_sub", name: "subagent", arguments: %{"prompt" => "Child work across SIGKILL"}}],
              finish_reason: "tool_calls"
            }}
          else
            # Block inside child generation so SIGKILL hits while parent is waiting & child is running!
            IO.puts("CHILD_RUNNING")
            receive do
              :never -> :ok
            end
          end
        end
      end

      opts = [
        data_dir: data_dir,
        provider: VmSubProvider,
        provider_config: %{},
        storage_mod: H.Storage.File,
        storage_opts: [sync: :datasync],
        retry_backoff_ms: 20,
        default_model: "fake:coder"
      ]

      {:ok, _} = H.Daemon.create_session(%{"session_id" => "vm-parent", "cwd" => cwd}, opts)

      {:ok, _} =
        H.Daemon.execute_command(
          "vm-parent",
          %{
            "version" => 1,
            "request_id" => "vm-sub-req-1",
            "command" => "submit",
            "conversation_id" => "1",
            "args" => %{"type" => "input", "content" => "Delegate across SIGKILL"}
          },
          opts
        )

      wait_both_active = fn loop ->
        sessions = H.Catalog.list_sessions(:h_catalog)
        child = Enum.find(sessions, &(get_in(&1, [:parent, :session_id]) == "vm-parent"))
        {:ok, parent} = H.Catalog.get_session("vm-parent", :h_catalog)

        if child != nil and child.active and parent.active and parent.activity_label == "subagent" do
          :ok
        else
          Process.sleep(15)
          loop.(loop)
        end
      end

      wait_both_active.(wait_both_active)
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

      # SIGKILL the BEAM VM while parent is parked waiting and child is running!
      {_out, 0} = System.cmd("kill", ["-9", os_pid])
      assert_receive {^port, {:exit_status, _status}}, 5_000

      # Boot fresh supervisor tree on the exact same data_dir
      start_supervised!({StoreLock, data_dir: data_dir, name: :"H.SubVm.Lock.#{id}"})
      registry = :"H.SubVm.Registry.#{id}"
      pubsub = :"H.SubVm.PubSub.#{id}"
      catalog = :"H.SubVm.Catalog.#{id}"
      catalog_table = :"h_sub_vm_catalog_#{id}"
      lease = :"H.SubVm.Lease.#{id}"
      runtime_sup = :"H.SubVm.RuntimeSup.#{id}"

      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({Registry, keys: :duplicate, name: pubsub})

      start_supervised!(
        {Catalog, data_dir: data_dir, name: catalog, table: catalog_table, pubsub: pubsub}
      )

      start_supervised!({WorkspaceLease, name: lease})
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

      handler2 = fn req, _emit ->
        prompt = first_user_text(req)
        tools = tool_messages(req)

        cond do
          prompt == "Child work across SIGKILL" ->
            {:ok, %{content: [%{type: "text", text: "Child survived SIGKILL"}]}}

          prompt == "Delegate across SIGKILL" and length(tools) == 1 ->
            [res] = tools
            assert res.is_error == false
            assert hd(res.content).text == "Child survived SIGKILL"
            {:ok, %{content: [%{type: "text", text: "Parent woke after SIGKILL"}]}}
        end
      end

      opts2 = [
        registry: registry,
        pubsub: pubsub,
        catalog: catalog,
        catalog_table: catalog_table,
        workspace_lease: lease,
        runtime_sup: runtime_sup,
        data_dir: data_dir,
        provider: RouterProvider,
        provider_config: %{handler: handler2},
        storage_mod: H.Storage.File,
        storage_opts: [sync: :datasync],
        retry_backoff_ms: 20,
        default_model: "fake:coder"
      ]

      # Boot recovery wakes both parent (waiting) and child (sleeping retry -> completes)
      assert :ok = Daemon.recover_active_sessions(opts2)

      items =
        wait_until(
          fn ->
            {:ok, %{items: items}} =
              Daemon.scan_entries("vm-parent", "1", %{"order" => "asc"}, opts2)

            if length(items) == 4, do: items, else: nil
          end,
          5_000
        )

      assert Enum.map(items, & &1.kind) == ["user", "assistant", "tool_result", "assistant"]

      assert List.last(items).data["content"] == [
               %{"type" => "text", "text" => "Parent woke after SIGKILL"}
             ]

      # Exactly ONE child session exists (zero duplicate spawns across SIGKILL!)
      children =
        catalog_table
        |> Catalog.list_sessions()
        |> Enum.filter(&(get_in(&1, [:parent, :session_id]) == "vm-parent"))

      assert length(children) == 1
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
