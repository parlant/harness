defmodule H.RunBudgetAndTaskAbortTest do
  use ExUnit.Case, async: true

  alias H.{Catalog, Daemon, WorkspaceLease}
  alias H.Provider.Fake

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

  defp start_env(provider_mod, provider_config, extra_opts \\ []) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-r1-test-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    registry = :"H.R1Test.Registry.#{id}"
    pubsub = :"H.R1Test.PubSub.#{id}"
    catalog = :"H.R1Test.Catalog.#{id}"
    catalog_table = :"h_r1_test_catalog_#{id}"
    lease = :"H.R1Test.Lease.#{id}"
    runtime_sup = :"H.R1Test.RuntimeSup.#{id}"

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
        provider: provider_mod,
        provider_config: provider_config,
        storage_mod: H.Storage.File,
        storage_opts: [sync: :none],
        default_model: "fake:coder"
      ] ++ extra_opts

    %{
      opts: opts,
      cwd: cwd,
      data_dir: data_dir,
      registry: registry,
      pubsub: pubsub,
      catalog: catalog,
      catalog_table: catalog_table,
      lease: lease
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

  describe "R1a Guarded run budgets" do
    test "pauses on max_turns after tool round, sets needs_attention, and resumes cleanly on continue" do
      fake =
        start_supervised!(
          {Fake,
           script: [
             {:reply, [],
              %{
                content: [],
                tool_calls: [%{id: "c_turn1", name: "read", arguments: %{"path" => "a.txt"}}],
                finish_reason: "tool_calls",
                usage: %{input_tokens: 10, output_tokens: 5, cost: 0.01}
              }},
             {:reply, [],
              %{
                content: [%{type: "text", text: "Resumed after turn budget!"}],
                finish_reason: "stop",
                usage: %{input_tokens: 20, output_tokens: 10, cost: 0.02}
              }}
           ]}
        )

      env = start_env(Fake, %{server: fake})
      File.write!(Path.join(env.cwd, "a.txt"), "hello budget")

      {:ok, _} =
        Daemon.create_session(
          %{
            "session_id" => "s-budget-turns",
            "cwd" => env.cwd,
            "agent" => %{"budget" => %{"max_turns" => 1}}
          },
          env.opts
        )

      {:ok, _} =
        Daemon.execute_command(
          "s-budget-turns",
          cmd("sub-t1", "submit", "1", %{"type" => "input", "content" => "Read a.txt"}),
          env.opts
        )

      outcome =
        wait_until(fn ->
          {:ok, out} = Daemon.get_submission("s-budget-turns", "sub-t1", env.opts)
          if out.status in ["done", "unanswered"], do: out, else: nil
        end)

      assert outcome.status == "unanswered"
      assert outcome.reason == "budget_exceeded"

      {:ok, {:snapshot, _seq, bin}} =
        Daemon.subscribe_conversation("s-budget-turns", "1", self(), nil, env.opts)

      snap = JSON.decode!(bin)
      assert snap["docs"]["live"]["run_failure"]["reason"] == "budget_exceeded"
      assert snap["docs"]["live"]["run_failure"]["limit"] == "max_turns"
      assert snap["docs"]["live"]["run_failure"]["turns"] == 1

      summary =
        wait_until(fn ->
          {:ok, %{session: s}} = Daemon.get_session_detail("s-budget-turns", env.opts)
          if s.attention == "error", do: s, else: nil
        end)

      assert summary.needs_attention == true

      # Continue resumes for another turn (with max_turns: 1 budget per run)
      {:ok, _} =
        Daemon.execute_command(
          "s-budget-turns",
          cmd("sub-t2", "submit", "1", %{"type" => "continue"}),
          env.opts
        )

      cont_outcome =
        wait_until(fn ->
          {:ok, out} = Daemon.get_submission("s-budget-turns", "sub-t2", env.opts)
          if out.status in ["done", "unanswered"], do: out, else: nil
        end)

      assert cont_outcome.status == "done"
      assert cont_outcome.answer_text == "Resumed after turn budget!"
    end

    test "pauses on max_cost_usd before running requested tools, injects valid tool_result pairing, and continues cleanly" do
      fake =
        start_supervised!(
          {Fake,
           script: [
             {:reply, [],
              %{
                content: [],
                tool_calls: [
                  %{
                    id: "c_cost_1",
                    name: "write",
                    arguments: %{"path" => "should_not_exist.txt", "content" => "nope"}
                  }
                ],
                finish_reason: "tool_calls",
                usage: %{input_tokens: 100, output_tokens: 50, cost: 0.25}
              }},
             {:expect,
              fn req ->
                tr =
                  Enum.find(req.messages, &(&1.role == "tool" and &1.tool_call_id == "c_cost_1"))

                assert tr != nil
                assert tr.is_error == true
                assert hd(tr.content).text =~ "cost budget"
                true
              end,
              {:reply, [], %{content: [%{type: "text", text: "Continued after cost pause"}]}}}
           ]}
        )

      env = start_env(Fake, %{server: fake})

      {:ok, _} =
        Daemon.create_session(
          %{
            "session_id" => "s-budget-cost",
            "cwd" => env.cwd,
            "agent" => %{"budget" => %{"max_cost_usd" => 0.10}}
          },
          env.opts
        )

      {:ok, _} =
        Daemon.execute_command(
          "s-budget-cost",
          cmd("sub-c1", "submit", "1", %{"type" => "input", "content" => "Write file"}),
          env.opts
        )

      outcome =
        wait_until(fn ->
          {:ok, out} = Daemon.get_submission("s-budget-cost", "sub-c1", env.opts)
          if out.status == "unanswered", do: out, else: nil
        end)

      assert outcome.reason == "budget_exceeded"
      # Write tool MUST NOT have executed because cost budget was already exceeded on turn 1
      refute File.exists?(Path.join(env.cwd, "should_not_exist.txt"))

      {:ok, {:snapshot, _seq, bin}} =
        Daemon.subscribe_conversation("s-budget-cost", "1", self(), nil, env.opts)

      snap = JSON.decode!(bin)
      assert snap["docs"]["live"]["run_failure"]["reason"] == "budget_exceeded"
      assert snap["docs"]["live"]["run_failure"]["limit"] == "max_cost_usd"

      {:ok, %{items: entries}} =
        Daemon.scan_entries("s-budget-cost", "1", %{"order" => "asc"}, env.opts)

      assert Enum.map(entries, & &1.kind) == ["user", "assistant", "tool_result"]
      assert List.last(entries).data["diagnostic"] == "budget_exceeded"

      # Clear budget and continue -> valid tool_result pairing allows clean continuation
      {:ok, _} =
        Daemon.execute_command(
          "s-budget-cost",
          cmd("cfg-clear", "configure", "1", %{"budget" => %{}}),
          env.opts
        )

      {:ok, _} =
        Daemon.execute_command(
          "s-budget-cost",
          cmd("sub-c2", "submit", "1", %{"type" => "continue"}),
          env.opts
        )

      done_out =
        wait_until(fn ->
          {:ok, out} = Daemon.get_submission("s-budget-cost", "sub-c2", env.opts)
          if out.status == "done", do: out, else: nil
        end)

      assert done_out.answer_text == "Continued after cost pause"
    end

    test "pauses on max_elapsed_ms after slow tool round" do
      fake =
        start_supervised!(
          {Fake,
           script: [
             {:reply, [],
              %{
                content: [],
                tool_calls: [
                  %{id: "c_time_1", name: "bash", arguments: %{"command" => "sleep 0.08"}}
                ],
                finish_reason: "tool_calls",
                usage: %{input_tokens: 10, output_tokens: 5, cost: 0.001}
              }}
           ]}
        )

      env = start_env(Fake, %{server: fake})

      {:ok, _} =
        Daemon.create_session(
          %{
            "session_id" => "s-budget-time",
            "cwd" => env.cwd,
            "agent" => %{"budget" => %{"max_elapsed_ms" => 30}}
          },
          env.opts
        )

      {:ok, _} =
        Daemon.execute_command(
          "s-budget-time",
          cmd("sub-time-1", "submit", "1", %{"type" => "input", "content" => "Sleep"}),
          env.opts
        )

      outcome =
        wait_until(fn ->
          {:ok, out} = Daemon.get_submission("s-budget-time", "sub-time-1", env.opts)
          if out.status == "unanswered", do: out, else: nil
        end)

      assert outcome.reason == "budget_exceeded"

      {:ok, {:snapshot, _seq, bin}} =
        Daemon.subscribe_conversation("s-budget-time", "1", self(), nil, env.opts)

      snap = JSON.decode!(bin)
      assert snap["docs"]["live"]["run_failure"]["limit"] == "max_elapsed_ms"
    end
  end

  describe "R1b Task-scoped abort" do
    test "aborts only the targeted subagent tool_call task while letting sibling subagent complete" do
      test_pid = self()
      gate_a = make_ref()
      gate_b = make_ref()

      handler = fn req, _emit ->
        user_text =
          req.messages
          |> Enum.find(&(&1.role == "user"))
          |> Map.get(:content, [])
          |> Enum.map(&Map.get(&1, :text, ""))
          |> Enum.join("")

        tools = Enum.filter(req.messages, &(&1.role == "tool"))

        cond do
          user_text == "Run two lanes" and tools == [] ->
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "call_a",
                   name: "subagent",
                   arguments: %{"prompt" => "Lane A", "read_only" => true}
                 },
                 %{
                   id: "call_b",
                   name: "subagent",
                   arguments: %{"prompt" => "Lane B", "read_only" => true}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          user_text == "Lane A" ->
            send(test_pid, {:lane_entered, :a, self()})

            receive do
              {:release, ^gate_a} -> {:ok, %{content: [%{type: "text", text: "A finished"}]}}
            end

          user_text == "Lane B" ->
            send(test_pid, {:lane_entered, :b, self()})

            receive do
              {:release, ^gate_b} -> {:ok, %{content: [%{type: "text", text: "B finished"}]}}
            end

          user_text == "Run two lanes" and length(tools) == 2 ->
            a_res = Enum.find(tools, &(&1.tool_call_id == "call_a"))
            b_res = Enum.find(tools, &(&1.tool_call_id == "call_b"))
            assert a_res.is_error == true
            assert hd(a_res.content).text =~ "aborted"
            assert b_res.is_error == false
            assert hd(b_res.content).text == "B finished"
            {:ok, %{content: [%{type: "text", text: "Parent finished with B"}]}}
        end
      end

      env = start_env(RouterProvider, %{handler: handler})

      {:ok, _} =
        Daemon.create_session(%{"session_id" => "s-task-abort", "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-task-abort",
          cmd("sub-1", "submit", "1", %{"type" => "input", "content" => "Run two lanes"}),
          env.opts
        )

      assert_receive {:lane_entered, :a, _pid_a}, 2_000
      assert_receive {:lane_entered, :b, pid_b}, 2_000

      {:ok, detail} = Daemon.get_session_detail("s-task-abort", env.opts)

      lane_a_task =
        Enum.find(detail.tasks, fn t ->
          t.kind == "tool_call" and t.status == "waiting" and t.wake["on"] == "submission_settled"
        end)

      # Identify exact task for Lane A via child session prompt/title or order (smaller task id is call_a)
      waiting_tools =
        detail.tasks
        |> Enum.filter(&(&1.kind == "tool_call" and &1.status == "waiting"))
        |> Enum.sort_by(&String.to_integer(&1.id))

      assert length(waiting_tools) == 2
      task_a = hd(waiting_tools)
      assert lane_a_task != nil

      # Unknown task_id -> 404, wrong conversation -> 404
      assert {:error, :not_found} =
               Daemon.execute_command(
                 "s-task-abort",
                 cmd("bad-abort", "abort", "1", %{"task_id" => 999_999}),
                 env.opts
               )

      # Task-scoped abort for task_a ONLY
      {:ok, _} =
        Daemon.execute_command(
          "s-task-abort",
          cmd("abort-a", "abort", "1", %{
            "task_id" => String.to_integer(task_a.id),
            "reason" => "drop_a"
          }),
          env.opts
        )

      # Re-aborting terminal task_a -> 409 task_not_active
      assert {:error, {:conflict, "task_not_active"}} =
               Daemon.execute_command(
                 "s-task-abort",
                 cmd("abort-a-again", "abort", "1", %{"task_id" => String.to_integer(task_a.id)}),
                 env.opts
               )

      # Child A was aborted, while Lane B is still alive and can finish!
      child_a_sid = task_a.wake["session_id"]

      wait_until(fn ->
        {:ok, out} = Daemon.get_submission(child_a_sid, task_a.wake["request_id"], env.opts)
        if out.status == "unanswered", do: out, else: nil
      end)

      send(pid_b, {:release, gate_b})

      parent_out =
        wait_until(fn ->
          {:ok, out} = Daemon.get_submission("s-task-abort", "sub-1", env.opts)
          if out.status == "done", do: out, else: nil
        end)

      assert parent_out.answer_text == "Parent finished with B"
    end

    test "aborts a running bash tool_call task and advances to next generation turn" do
      fake =
        start_supervised!(
          {Fake,
           script: [
             {:reply, [],
              %{
                content: [],
                tool_calls: [
                  %{id: "c_slow", name: "bash", arguments: %{"command" => "sleep 30"}}
                ],
                finish_reason: "tool_calls"
              }},
             {:expect,
              fn req ->
                tr = Enum.find(req.messages, &(&1.role == "tool" and &1.tool_call_id == "c_slow"))
                assert tr != nil
                assert tr.is_error == true
                assert hd(tr.content).text =~ "aborted"
                true
              end,
              {:reply, [], %{content: [%{type: "text", text: "Recovered after task abort"}]}}}
           ]}
        )

      env = start_env(Fake, %{server: fake})

      {:ok, _} =
        Daemon.create_session(%{"session_id" => "s-bash-abort", "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-bash-abort",
          cmd("sub-b1", "submit", "1", %{"type" => "input", "content" => "Run slow"}),
          env.opts
        )

      running_tool =
        wait_until(fn ->
          {:ok, detail} = Daemon.get_session_detail("s-bash-abort", env.opts)
          Enum.find(detail.tasks, &(&1.kind == "tool_call" and &1.status == "running"))
        end)

      {:ok, _} =
        Daemon.execute_command(
          "s-bash-abort",
          cmd("abort-slow", "abort", "1", %{"task_id" => String.to_integer(running_tool.id)}),
          env.opts
        )

      done_out =
        wait_until(fn ->
          {:ok, out} = Daemon.get_submission("s-bash-abort", "sub-b1", env.opts)
          if out.status == "done", do: out, else: nil
        end)

      assert done_out.answer_text == "Recovered after task abort"
    end
  end
end
