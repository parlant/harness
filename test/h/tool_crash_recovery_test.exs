defmodule H.ToolCrashRecoveryTest do
  use ExUnit.Case, async: true

  alias H.{Catalog, Daemon}
  alias H.Provider.Fake

  @test_ets :h_tool_crash_recovery_test_state

  setup_all do
    if :ets.whereis(@test_ets) == :undefined do
      :ets.new(@test_ets, [:named_table, :public, :set])
    end

    :ok
  end

  defmodule GatedSafeTool do
    @behaviour H.Tool
    @test_ets :h_tool_crash_recovery_test_state

    @impl true
    def name, do: "gated_safe"

    @impl true
    def description, do: "Deterministic gated replay: :safe test tool"

    @impl true
    def parameters_schema do
      %{
        "type" => "object",
        "properties" => %{"label" => %{"type" => "string"}},
        "required" => ["label"],
        "additionalProperties" => false
      }
    end

    @impl true
    def replay, do: :safe

    @impl true
    def mutating?, do: false

    @impl true
    def execute(%{"label" => label}, context) do
      [{_, notify}] = :ets.lookup(@test_ets, {:gate_pid, context.session_id})
      [{_, counter}] = :ets.lookup(@test_ets, {:counter, context.session_id})

      attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

      if attempt == 1 and is_pid(notify) do
        send(notify, {:safe_tool_entered, self()})

        receive do
          :proceed -> :ok
        end
      end

      {:ok,
       %{
         content: [%{"type" => "text", "text" => "safe:#{label}:attempt=#{attempt}"}],
         details: %{attempt: attempt},
         is_error: false,
         diagnostic: nil
       }}
    end
  end

  defmodule GatedUnsafeTool do
    @behaviour H.Tool
    @test_ets :h_tool_crash_recovery_test_state

    @impl true
    def name, do: "gated_unsafe"

    @impl true
    def description, do: "Deterministic gated replay: :unsafe test tool"

    @impl true
    def parameters_schema do
      %{
        "type" => "object",
        "properties" => %{"action" => %{"type" => "string"}},
        "required" => ["action"],
        "additionalProperties" => false
      }
    end

    @impl true
    def replay, do: :unsafe

    @impl true
    def mutating?, do: true

    @impl true
    def execute(%{"action" => action}, context) do
      [{_, notify}] = :ets.lookup(@test_ets, {:gate_pid, context.session_id})
      [{_, counter}] = :ets.lookup(@test_ets, {:counter, context.session_id})

      count = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

      if is_function(context[:on_output], 2) do
        context.on_output.("partial-out-#{action}", 10)
      end

      if is_pid(notify) do
        send(notify, {:unsafe_tool_entered, self(), count})

        receive do
          :proceed -> :ok
        end
      end

      {:ok,
       %{
         content: [%{"type" => "text", "text" => "ran:#{action}:count=#{count}"}],
         details: %{count: count},
         is_error: false,
         diagnostic: nil
       }}
    end
  end

  defp start_env(script, extra_opts \\ []) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-tool-rec-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    registry = :"H.ToolTest.Registry.#{id}"
    pubsub = :"H.ToolTest.PubSub.#{id}"
    catalog = :"H.ToolTest.Catalog.#{id}"
    catalog_table = :"h_tool_test_catalog_#{id}"
    lease = :"H.ToolTest.Lease.#{id}"
    runtime_sup = :"H.ToolTest.RuntimeSup.#{id}"
    fake_name = :"H.ToolTest.Fake.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({H.WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})
    fake = start_supervised!({Fake, script: script, name: fake_name})

    on_exit(fn -> File.rm_rf(tmp_root) end)

    tools = [
      H.Tools.Read,
      H.Tools.Write,
      H.Tools.Edit,
      H.Tools.Bash,
      H.Tools.SearchHistory,
      GatedSafeTool,
      GatedUnsafeTool
    ]

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
        tools: tools,
        default_model: "fake:coder"
      ] ++ extra_opts

    %{opts: opts, cwd: cwd, fake: fake}
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

  describe "tool crash recovery" do
    test "replay: :safe tool auto-replays after crash and completes generation" do
      sid = "s-safe-#{System.unique_integer([:positive])}"
      counter = start_supervised!({Agent, fn -> 0 end})
      :ets.insert(@test_ets, {{:gate_pid, sid}, self()})
      :ets.insert(@test_ets, {{:counter, sid}, counter})

      on_exit(fn ->
        :ets.delete(@test_ets, {:gate_pid, sid})
        :ets.delete(@test_ets, {:counter, sid})
      end)

      %{opts: opts, cwd: cwd} =
        start_env([
          {:reply, [],
           %{
             content: [],
             tool_calls: [%{id: "c1", name: "gated_safe", arguments: %{"label" => "x"}}],
             finish_reason: "tool_calls"
           }},
          {:expect,
           fn req ->
             tool_msg = Enum.find(req.messages, &(&1.role == "tool"))
             assert hd(tool_msg.content).text == "safe:x:attempt=2"
             assert tool_msg.is_error == false
             true
           end, {:reply, [], %{content: [%{type: "text", text: "Safe replay done"}]}}}
        ])

      {:ok, _} =
        Daemon.create_session(
          %{"session_id" => sid, "cwd" => cwd, "agent" => %{"tools" => ["gated_safe"]}},
          opts
        )

      {:ok, _} =
        Daemon.execute_command(
          sid,
          cmd("s1", "submit", "1", %{"type" => "input", "content" => "Run safe tool"}),
          opts
        )

      assert_receive {:safe_tool_entered, _worker_pid}, 1_000

      # Crash Session.Server mid-tool-execution
      [{pid1, _}] = Registry.lookup(opts[:registry], {:session, sid})
      Process.exit(pid1, :kill)

      # Replayed automatically (attempt=2) and finished!
      items =
        wait_until(fn ->
          case Registry.lookup(opts[:registry], {:session, sid}) do
            [{p, _}] when p != pid1 ->
              try do
                {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)
                if length(items) == 4, do: items, else: nil
              catch
                :exit, _ -> nil
              end

            _ ->
              nil
          end
        end)

      assert Enum.map(items, & &1.kind) == ["user", "assistant", "tool_result", "assistant"]
      assert Agent.get(counter, & &1) == 2
    end

    @tag close_reason: :kill
    test "unsafe tool is interrupted on crash", context do
      assert_unsafe_tool_interruption(context.close_reason)
    end

    @tag close_reason: :shutdown
    test "unsafe tool is interrupted on clean shutdown", context do
      assert_unsafe_tool_interruption(context.close_reason)
    end

    defp assert_unsafe_tool_interruption(close_reason) do
      sid = "s-unsafe-#{System.unique_integer([:positive])}"
      counter = start_supervised!({Agent, fn -> 0 end})
      :ets.insert(@test_ets, {{:gate_pid, sid}, self()})
      :ets.insert(@test_ets, {{:counter, sid}, counter})

      on_exit(fn ->
        :ets.delete(@test_ets, {:gate_pid, sid})
        :ets.delete(@test_ets, {:counter, sid})
      end)

      %{opts: opts, cwd: cwd} =
        start_env(
          [
            {:reply, [],
             %{
               content: [],
               tool_calls: [
                 %{id: "cu1", name: "gated_unsafe", arguments: %{"action" => "deploy"}}
               ],
               finish_reason: "tool_calls"
             }},
            {:expect,
             fn req ->
               tool_msg = Enum.find(req.messages, &(&1.role == "tool"))
               assert tool_msg.is_error == true
               text = hd(tool_msg.content).text
               assert text =~ "interrupted"
               assert text =~ "partial-out-deploy"
               true
             end, {:reply, [], %{content: [%{type: "text", text: "Handled interruption"}]}}}
          ],
          ephemeral_interval_ms: 5,
          persist_within_ms: 15
        )

      {:ok, _} =
        Daemon.create_session(
          %{"session_id" => sid, "cwd" => cwd, "agent" => %{"tools" => ["gated_unsafe"]}},
          opts
        )

      {:ok, _} = Daemon.subscribe_conversation(sid, "1", self(), nil, opts)

      {:ok, _} =
        Daemon.execute_command(
          sid,
          cmd("u1", "submit", "1", %{"type" => "input", "content" => "Run unsafe"}),
          opts
        )

      assert_receive {:unsafe_tool_entered, _worker_pid, 1}, 1_000

      # Wait for deferred flush of tool partial output
      wait_until(fn ->
        {:ok, {:snapshot, _, bin}} = Daemon.subscribe_conversation(sid, "1", self(), nil, opts)
        out = JSON.decode!(bin) |> get_in(["docs", "live", "tools", "cu1", "output"])
        if out == "partial-out-deploy", do: true, else: nil
      end)

      [{pid1, _}] = Registry.lookup(opts[:registry], {:session, sid})

      case close_reason do
        :kill ->
          Process.exit(pid1, :kill)

        :shutdown ->
          [{_, sup_pid, _, _}] = DynamicSupervisor.which_children(opts[:runtime_sup])
          :ok = DynamicSupervisor.terminate_child(opts[:runtime_sup], sup_pid)
          assert {:ok, _} = Daemon.get_session_detail(sid, opts)
      end

      items =
        wait_until(fn ->
          case Registry.lookup(opts[:registry], {:session, sid}) do
            [{p, _}] when p != pid1 ->
              try do
                {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)
                if length(items) == 4, do: items, else: nil
              catch
                :exit, _ -> nil
              end

            _ ->
              nil
          end
        end)

      tool_result = Enum.at(items, 2)
      assert tool_result.kind == "tool_result"
      assert tool_result.data["is_error"] == true
      assert tool_result.data["diagnostic"] == "interrupted"
      assert tool_result.data["details"]["partial_output"] == "partial-out-deploy"
      # Crucial invariant: unsafe tool was executed ONLY ONCE!
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "tool validation, workspace lease, and max_turns" do
    test "rejects invalid arguments, enforces workspace lease, and stops at max_turns" do
      sid1 = "s-lease-1-#{System.unique_integer([:positive])}"
      sid2 = "s-lease-2-#{System.unique_integer([:positive])}"
      counter1 = start_supervised!({Agent, fn -> 0 end}, id: :c1)
      :ets.insert(@test_ets, {{:gate_pid, sid1}, self()})
      :ets.insert(@test_ets, {{:counter, sid1}, counter1})

      on_exit(fn ->
        :ets.delete(@test_ets, {:gate_pid, sid1})
        :ets.delete(@test_ets, {:counter, sid1})
      end)

      %{opts: opts, cwd: cwd} =
        start_env([
          # sid1 turn 1: starts gated_unsafe holding workspace lease
          {:reply, [],
           %{
             content: [],
             tool_calls: [%{id: "t1", name: "gated_unsafe", arguments: %{"action" => "hold"}}],
             finish_reason: "tool_calls"
           }},
          # sid2 turn 1: tries to run mutating write while sid1 holds lease -> workspace_busy
          {:reply, [],
           %{
             content: [],
             tool_calls: [
               %{id: "t2", name: "write", arguments: %{"path" => "x.txt", "content" => "hi"}}
             ],
             finish_reason: "tool_calls"
           }},
          # sid2 turn 2: tries invalid args on read -> invalid_arguments, hits max_turns: 2 -> turn_limit!
          {:reply, [],
           %{
             content: [],
             tool_calls: [%{id: "t3", name: "read", arguments: %{"offset" => "not_an_int"}}],
             finish_reason: "tool_calls"
           }},
          # sid1 turn 2: finishes after release
          {:reply, [], %{content: [%{type: "text", text: "sid1 done"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => sid1, "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.create_session(
          %{"session_id" => sid2, "cwd" => cwd, "agent" => %{"max_turns" => 2}},
          opts
        )

      # Start sid1 -> holds lease on cwd
      {:ok, _} =
        Daemon.execute_command(
          sid1,
          cmd("1", "submit", "1", %{"type" => "input", "content" => "Hold lease"}),
          opts
        )

      assert_receive {:unsafe_tool_entered, tool_pid1, 1}, 1_000

      # Start sid2 -> write fails workspace_busy, next turn read fails invalid_arguments, hits max_turns=2
      {:ok, _} =
        Daemon.execute_command(
          sid2,
          cmd("2", "submit", "1", %{"type" => "input", "content" => "Contend"}),
          opts
        )

      snap2 =
        wait_until(fn ->
          {:ok, {:snapshot, _, bin}} = Daemon.subscribe_conversation(sid2, "1", self(), nil, opts)
          decoded = JSON.decode!(bin)
          if decoded["docs"]["live"]["run_failure"], do: decoded, else: nil
        end)

      assert snap2["docs"]["live"]["run_failure"] == %{"reason" => "turn_limit"}
      tool_results2 = Enum.filter(snap2["entries"], &(&1["kind"] == "tool_result"))
      assert Enum.at(tool_results2, 0)["data"]["diagnostic"] == "workspace_busy"
      assert Enum.at(tool_results2, 1)["data"]["diagnostic"] == "invalid_arguments"

      # Release sid1
      send(tool_pid1, :proceed)

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries(sid1, "1", %{"order" => "asc"}, opts)
        if length(items) == 4, do: items, else: nil
      end)
    end
  end
end
