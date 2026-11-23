defmodule H.SubagentToolTest do
  use ExUnit.Case, async: true

  alias H.{Catalog, Daemon, Tool}
  alias H.Tools.Subagent

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
    tmp_root = Path.join(System.tmp_dir!(), "h-subagent-test-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    registry = :"H.SubTest.Registry.#{id}"
    pubsub = :"H.SubTest.PubSub.#{id}"
    catalog = :"H.SubTest.Catalog.#{id}"
    catalog_table = :"h_sub_test_catalog_#{id}"
    lease = :"H.SubTest.Lease.#{id}"
    runtime_sup = :"H.SubTest.RuntimeSup.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})

    start_supervised!(
      {Catalog, data_dir: data_dir, name: catalog, table: catalog_table, pubsub: pubsub}
    )

    start_supervised!({H.WorkspaceLease, name: lease})
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

  defp tool_messages(req) do
    Enum.filter(req.messages, &(&1.role == "tool"))
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
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end

  describe "H.Tools.Subagent schema and standalone behavior" do
    test "declares name, unsafe replay, non-mutating flag, schema validation, and standalone error" do
      assert {Subagent.name(), Subagent.replay(), Subagent.mutating?()} ==
               {"subagent", :unsafe, false}

      assert {:ok, _} = Tool.validate_args(Subagent, %{"prompt" => "Explore repo"})

      assert {:ok, _} =
               Tool.validate_args(Subagent, %{
                 "mode" => "start",
                 "prompt" => "Do lane 1",
                 "cwd" => "/tmp/work",
                 "read_only" => true,
                 "title" => "Lane 1",
                 "model" => "fake:coder",
                 "thinking" => "high"
               })

      assert {:error, _} = Tool.validate_args(Subagent, %{"mode" => "bogus"})
      assert {:error, _} = Tool.validate_args(Subagent, %{"extra" => true})
      assert {:error, _} = Tool.validate_args(Subagent, %{"session_id" => "../escape"})

      assert {:error, %{is_error: true, diagnostic: "unsupported_context"}} =
               Subagent.execute(%{"prompt" => "hi"}, %{})
    end
  end

  describe "mode: wait (zero-worker parking and step-anchored lineage)" do
    test "parks with zero Task.Supervisor workers, records step-anchored lineage, reports tool activity, and settles parent turn" do
      test_pid = self()
      child_gate = make_ref()

      handler = fn req, _emit ->
        prompt = first_user_text(req)
        tools = tool_messages(req)

        cond do
          prompt == "Parent task" and tools == [] ->
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "call_sub_1",
                   name: "subagent",
                   arguments: %{
                     "prompt" => "Inspect alpha.txt",
                     "title" => "Alpha Inspector",
                     "read_only" => true
                   }
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Inspect alpha.txt" ->
            send(test_pid, {:child_entered, child_gate, self(), Enum.map(req.tools, & &1.name)})

            receive do
              {:release, ^child_gate} -> :ok
            end

            {:ok, %{content: [%{type: "text", text: "Alpha inspection complete: OK"}]}}

          prompt == "Parent task" and length(tools) == 1 ->
            [tool_msg] = tools
            assert tool_msg.is_error == false
            assert hd(tool_msg.content).text == "Alpha inspection complete: OK"
            {:ok, %{content: [%{type: "text", text: "Parent done with child answer"}]}}
        end
      end

      env = start_env(handler)
      parent_sid = "parent-wait-#{System.unique_integer([:positive])}"
      {:ok, _} = Daemon.create_session(%{"session_id" => parent_sid, "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          parent_sid,
          cmd("req-p1", "submit", "1", %{"type" => "input", "content" => "Parent task"}),
          env.opts
        )

      assert_receive {:child_entered, ^child_gate, child_worker, child_tools}, 2_000
      assert Enum.sort(child_tools) == ["read", "search_history"]

      # Verify parent holds ZERO Task.Supervisor workers while parked waiting!
      [{task_sup_pid, _}] = Registry.lookup(env.registry, {:session_tasks, parent_sid})
      assert Task.Supervisor.children(task_sup_pid) == []

      # Verify parent catalog reports running tool: subagent
      {:ok, parent_cat} = Catalog.get_session(parent_sid, env.catalog_table)
      assert parent_cat.active == true
      assert parent_cat.attention == "running"
      assert parent_cat.activity_kind == "tool"
      assert parent_cat.activity_label == "subagent"

      # Verify parent assistant entry and child lineage in Catalog
      {:ok, %{items: parent_items}} =
        Daemon.scan_entries(parent_sid, "1", %{"order" => "asc"}, env.opts)

      assistant_entry = Enum.find(parent_items, &(&1.kind == "assistant"))
      assert assistant_entry != nil

      {:ok, parent_detail} = Daemon.get_session_detail(parent_sid, env.opts)
      tool_task = Enum.find(parent_detail.tasks, &(&1.kind == "tool_call"))
      assert tool_task.status == "waiting"

      child_entry =
        env.catalog_table
        |> Catalog.list_sessions()
        |> Enum.find(&(get_in(&1, [:parent, :session_id]) == parent_sid))

      assert child_entry != nil
      assert child_entry.role == "subagent"
      assert child_entry.title == "Alpha Inspector"

      assert child_entry.parent == %{
               session_id: parent_sid,
               conversation_id: 1,
               at_entry_id: String.to_integer(assistant_entry.id),
               task_id: String.to_integer(tool_task.id),
               depth: 1,
               env_id: "host",
               cwd: env.cwd
             }

      # Release child -> parent wakes and completes!
      send(child_worker, {:release, child_gate})

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries(parent_sid, "1", %{"order" => "asc"}, env.opts)

          if length(items) == 4, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == ["user", "assistant", "tool_result", "assistant"]
      tool_res = Enum.at(items, 2)
      assert tool_res.data["is_error"] == false
      assert tool_res.data["details"]["child_session_id"] == child_entry.session_id
      assert tool_res.data["details"]["status"] == "done"
      assert tool_res.data["details"]["at_entry_id"] == assistant_entry.id
      assert tool_res.data["details"]["read_only"] == true

      final_assistant = Enum.at(items, 3)

      assert final_assistant.data["content"] == [
               %{"type" => "text", "text" => "Parent done with child answer"}
             ]
    end
  end

  describe "concurrent fan-out" do
    test "runs 3 subagent calls in one turn concurrently (2 read_only same cwd + 1 isolated cwd) without workspace_busy" do
      test_pid = self()
      gate = make_ref()

      handler = fn req, _emit ->
        prompt = first_user_text(req)
        tools = tool_messages(req)

        cond do
          prompt == "Fan out 3" and tools == [] ->
            send(test_pid, {:parent_fanout_prompt, self()})

            receive do
              {:worktree_cwd, wt_cwd} ->
                {:ok,
                 %{
                   content: [],
                   tool_calls: [
                     %{
                       id: "c_ro_1",
                       name: "subagent",
                       arguments: %{"prompt" => "lane-ro-1", "read_only" => true}
                     },
                     %{
                       id: "c_ro_2",
                       name: "subagent",
                       arguments: %{"prompt" => "lane-ro-2", "read_only" => true}
                     },
                     %{
                       id: "c_wt_3",
                       name: "subagent",
                       arguments: %{"prompt" => "lane-wt-3", "cwd" => wt_cwd}
                     }
                   ],
                   finish_reason: "tool_calls"
                 }}
            end

          prompt in ["lane-ro-1", "lane-ro-2"] and tools == [] ->
            send(test_pid, {:lane_entered, prompt, self()})

            receive do
              {:release_lane, ^gate} -> :ok
            end

            {:ok,
             %{
               content: [],
               tool_calls: [%{id: "r1", name: "read", arguments: %{"path" => "shared.txt"}}],
               finish_reason: "tool_calls"
             }}

          prompt in ["lane-ro-1", "lane-ro-2"] and length(tools) == 1 ->
            {:ok, %{content: [%{type: "text", text: "done:#{prompt}"}]}}

          prompt == "lane-wt-3" and tools == [] ->
            send(test_pid, {:lane_entered, prompt, self()})

            receive do
              {:release_lane, ^gate} -> :ok
            end

            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "w1",
                   name: "write",
                   arguments: %{"path" => "out.txt", "content" => "from lane 3"}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "lane-wt-3" and length(tools) == 1 ->
            [w_res] = tools
            assert w_res.is_error == false
            {:ok, %{content: [%{type: "text", text: "done:lane-wt-3"}]}}

          prompt == "Fan out 3" and length(tools) == 3 ->
            texts = Enum.map(tools, fn m -> hd(m.content).text end) |> Enum.sort()
            assert texts == ["done:lane-ro-1", "done:lane-ro-2", "done:lane-wt-3"]
            assert Enum.all?(tools, &(&1.is_error == false))
            {:ok, %{content: [%{type: "text", text: "All 3 lanes joined"}]}}
        end
      end

      env = start_env(handler)
      File.write!(Path.join(env.cwd, "shared.txt"), "shared content\n")
      wt_cwd = Path.join(env.tmp_root, "worktree-3")
      File.mkdir_p!(wt_cwd)

      parent_sid = "parent-fanout-#{System.unique_integer([:positive])}"
      {:ok, _} = Daemon.create_session(%{"session_id" => parent_sid, "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          parent_sid,
          cmd("req-fo", "submit", "1", %{"type" => "input", "content" => "Fan out 3"}),
          env.opts
        )

      assert_receive {:parent_fanout_prompt, p_worker}, 2_000
      send(p_worker, {:worktree_cwd, wt_cwd})

      # All 3 child lanes must enter concurrently BEFORE we release ANY of them!
      lanes =
        for _ <- 1..3 do
          assert_receive {:lane_entered, name, worker_pid}, 2_000
          {name, worker_pid}
        end

      assert Enum.sort(Enum.map(lanes, &elem(&1, 0))) == ["lane-ro-1", "lane-ro-2", "lane-wt-3"]

      # Parent holds zero workers while all 3 are parked!
      [{task_sup_pid, _}] = Registry.lookup(env.registry, {:session_tasks, parent_sid})
      assert Task.Supervisor.children(task_sup_pid) == []

      # Neither read-only explorers nor a writer in a separate worktree needs the parent's lease.
      {:ok, origin} = H.ExecutionEnv.canonical_path(H.ExecutionEnv.Host.new(env.cwd), env.cwd)

      assert :ok =
               H.WorkspaceLease.acquire(
                 env.opts[:workspace_lease],
                 {"host", origin},
                 {"busy-parent-tree", 1},
                 self()
               )

      # Release all 3 concurrently
      Enum.each(lanes, fn {_name, pid} -> send(pid, {:release_lane, gate}) end)

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries(parent_sid, "1", %{"order" => "asc"}, env.opts)

          if length(items) == 6, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == [
               "user",
               "assistant",
               "tool_result",
               "tool_result",
               "tool_result",
               "assistant"
             ]

      assert List.last(items).data["content"] == [
               %{"type" => "text", "text" => "All 3 lanes joined"}
             ]

      assert File.read!(Path.join(wt_cwd, "out.txt")) == "from lane 3"

      {:ok, worktree} = H.ExecutionEnv.canonical_path(H.ExecutionEnv.Host.new(env.cwd), wt_cwd)

      children =
        Enum.filter(
          Catalog.list_sessions(env.catalog_table),
          &(get_in(&1, [:parent, :session_id]) == parent_sid)
        )

      assert Enum.sort(Enum.map(children, & &1.cwd)) == Enum.sort([env.cwd, env.cwd, worktree])
      assert Enum.all?(children, &(&1.parent.cwd == env.cwd and &1.parent.env_id == "host"))
    end
  end

  describe "start, steer, await, and multi-turn follow-up" do
    test "supports start -> live steer mid-tool-round -> await -> follow-up wait preserving child history" do
      test_pid = self()
      child_turn_gate = make_ref()
      child_sid_agent = start_supervised!({Agent, fn -> nil end})

      handler = fn req, _emit ->
        prompt = first_user_text(req)
        tools = tool_messages(req)

        user_texts =
          req.messages
          |> Enum.filter(&(&1.role == "user"))
          |> Enum.map(fn m -> hd(m.content).text end)

        cond do
          # Parent Turn 1: start child asynchronously
          prompt == "Coordinate child" and tools == [] ->
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_start",
                   name: "subagent",
                   arguments: %{"mode" => "start", "prompt" => "Start worker"}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          # Child Turn 1: emits a read tool call so steering can land at tool-round boundary
          prompt == "Start worker" and tools == [] ->
            send(test_pid, {:child_started, self()})

            receive do
              {:child_go_tool, ^child_turn_gate} -> :ok
            end

            {:ok,
             %{
               content: [],
               tool_calls: [%{id: "cr1", name: "read", arguments: %{"path" => "f.txt"}}],
               finish_reason: "tool_calls"
             }}

          # Parent Turn 2: after start returns child_session_id, send live steer!
          prompt == "Coordinate child" and length(tools) == 1 ->
            [start_res] = tools
            assert start_res.is_error == false
            # Extract child_session_id from start result text
            [_, child_sid] = Regex.run(~r/Started subagent (\S+)/, hd(start_res.content).text)
            Agent.update(child_sid_agent, fn _ -> child_sid end)
            send(test_pid, {:parent_ready_to_steer, child_sid})

            receive do
              :proceed_steer -> :ok
            end

            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_steer",
                   name: "subagent",
                   arguments: %{
                     "mode" => "steer",
                     "session_id" => child_sid,
                     "prompt" => "Pivot to plan B"
                   }
                 }
               ],
               finish_reason: "tool_calls"
             }}

          # Parent Turn 3: after steer returns, call await (without explicit request_id -> tracks latest steered request!)
          prompt == "Coordinate child" and length(tools) == 2 ->
            child_sid = Agent.get(child_sid_agent, & &1)
            send(test_pid, :parent_steered)

            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_await",
                   name: "subagent",
                   arguments: %{"mode" => "await", "session_id" => child_sid}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          # Child Turn 2: receives the read tool result AND the steered user message!
          prompt == "Start worker" and length(tools) == 1 and length(user_texts) == 2 ->
            assert "Pivot to plan B" in user_texts
            {:ok, %{content: [%{type: "text", text: "Executed plan B"}]}}

          # Parent Turn 4: after await finishes, send a multi-turn follow-up wait on the SAME child_sid
          prompt == "Coordinate child" and length(tools) == 3 ->
            await_res = List.last(tools)
            assert await_res.is_error == false
            assert hd(await_res.content).text == "Executed plan B"
            child_sid = Agent.get(child_sid_agent, & &1)

            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_followup",
                   name: "subagent",
                   arguments: %{
                     "mode" => "wait",
                     "session_id" => child_sid,
                     "prompt" => "Follow up on plan B"
                   }
                 }
               ],
               finish_reason: "tool_calls"
             }}

          # Child Turn 3 (follow-up): sees prior conversation history!
          prompt == "Start worker" and "Follow up on plan B" in user_texts ->
            assert "Start worker" in user_texts
            assert "Pivot to plan B" in user_texts
            {:ok, %{content: [%{type: "text", text: "Follow-up confirmed with full history"}]}}

          # Parent Turn 5: finishes
          prompt == "Coordinate child" and length(tools) == 4 ->
            followup_res = List.last(tools)
            assert followup_res.is_error == false
            assert hd(followup_res.content).text == "Follow-up confirmed with full history"
            {:ok, %{content: [%{type: "text", text: "Full lifecycle complete"}]}}
        end
      end

      env = start_env(handler)
      File.write!(Path.join(env.cwd, "f.txt"), "file body\n")
      parent_sid = "parent-coord-#{System.unique_integer([:positive])}"
      {:ok, _} = Daemon.create_session(%{"session_id" => parent_sid, "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          parent_sid,
          cmd("req-c1", "submit", "1", %{"type" => "input", "content" => "Coordinate child"}),
          env.opts
        )

      assert_receive {:child_started, child_worker}, 2_000
      assert_receive {:parent_ready_to_steer, _child_sid}, 2_000

      # Let parent steer while child is busy, then let child proceed to tool round!
      send(
        wait_until(fn ->
          [{task_sup_pid, _}] = Registry.lookup(env.registry, {:session_tasks, parent_sid})
          List.first(Task.Supervisor.children(task_sup_pid))
        end),
        :proceed_steer
      )

      assert_receive :parent_steered, 2_000
      send(child_worker, {:child_go_tool, child_turn_gate})

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries(parent_sid, "1", %{"order" => "asc"}, env.opts)

          if length(items) == 10, do: items, else: nil
        end)

      assert List.last(items).data["content"] == [
               %{"type" => "text", "text" => "Full lifecycle complete"}
             ]
    end

    test "await without explicit request_id tracks a queued follow_up after the initial child submission already settled, and ignores failed idle steer" do
      test_pid = self()
      turn1_gate = make_ref()
      turn2_gate = make_ref()
      child_sid_agent = start_supervised!({Agent, fn -> nil end})

      handler = fn req, _emit ->
        prompt = first_user_text(req)
        tools = tool_messages(req)

        user_texts =
          req.messages
          |> Enum.filter(&(&1.role == "user"))
          |> Enum.map(fn m -> hd(m.content).text end)

        cond do
          # Parent Turn 1: start child wave 1
          prompt == "Two waves" and tools == [] ->
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_w1_start",
                   name: "subagent",
                   arguments: %{"mode" => "start", "prompt" => "Wave 1 prompt"}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          # Child Wave 1: blocks until parent queues Wave 2 follow-up!
          prompt == "Wave 1 prompt" and user_texts == ["Wave 1 prompt"] ->
            send(test_pid, {:wave1_running, self()})

            receive do
              {:finish_wave1, ^turn1_gate} -> :ok
            end

            {:ok, %{content: [%{type: "text", text: "Wave 1 answer"}]}}

          # Parent Turn 2: queue a follow-up via mode: "start" on the busy child
          prompt == "Two waves" and length(tools) == 1 ->
            [start1_res] = tools
            [_, child_sid] = Regex.run(~r/Started subagent (\S+)/, hd(start1_res.content).text)
            Agent.update(child_sid_agent, fn _ -> child_sid end)

            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_w2_start",
                   name: "subagent",
                   arguments: %{
                     "mode" => "start",
                     "session_id" => child_sid,
                     "prompt" => "Wave 2 follow-up"
                   }
                 }
               ],
               finish_reason: "tool_calls"
             }}

          # Child Wave 2: runs after Wave 1 finishes and drains inbox!
          prompt == "Wave 1 prompt" and "Wave 2 follow-up" in user_texts ->
            send(test_pid, {:wave2_running, self()})

            receive do
              {:finish_wave2, ^turn2_gate} -> :ok
            end

            {:ok, %{content: [%{type: "text", text: "Wave 2 final answer"}]}}

          # Parent Turn 3: Wave 2 start returned status: queued; wait for Wave 1 to settle,
          # then call await WITHOUT request_id — it MUST wait for Wave 2, NOT return Wave 1!
          prompt == "Two waves" and length(tools) == 2 ->
            start2_res = List.last(tools)
            assert hd(start2_res.content).text =~ "status: queued"
            child_sid = Agent.get(child_sid_agent, & &1)
            send(test_pid, {:parent_queued_wave2, self()})

            receive do
              :now_await_wave2 -> :ok
            end

            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_w2_await",
                   name: "subagent",
                   arguments: %{"mode" => "await", "session_id" => child_sid}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          # Parent Turn 4: receives Wave 2 final answer! Then tries a steer on the now-idle child (fails),
          # followed by another await without request_id (ignores failed steer and still resolves Wave 2).
          prompt == "Two waves" and length(tools) == 3 ->
            await_res = List.last(tools)
            assert await_res.is_error == false
            assert hd(await_res.content).text == "Wave 2 final answer"
            child_sid = Agent.get(child_sid_agent, & &1)

            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_failed_steer",
                   name: "subagent",
                   arguments: %{
                     "mode" => "steer",
                     "session_id" => child_sid,
                     "prompt" => "Too late steer"
                   }
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Two waves" and length(tools) == 4 ->
            steer_res = List.last(tools)
            assert steer_res.is_error == true
            child_sid = Agent.get(child_sid_agent, & &1)

            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_reawait",
                   name: "subagent",
                   arguments: %{"mode" => "await", "session_id" => child_sid}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Two waves" and length(tools) == 5 ->
            reawait_res = List.last(tools)
            assert reawait_res.is_error == false
            assert hd(reawait_res.content).text == "Wave 2 final answer"
            {:ok, %{content: [%{type: "text", text: "Both waves verified"}]}}
        end
      end

      env = start_env(handler)
      parent_sid = "parent-waves-#{System.unique_integer([:positive])}"
      {:ok, _} = Daemon.create_session(%{"session_id" => parent_sid, "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          parent_sid,
          cmd("req-w1", "submit", "1", %{"type" => "input", "content" => "Two waves"}),
          env.opts
        )

      assert_receive {:wave1_running, child_w1_pid}, 2_000
      assert_receive {:parent_queued_wave2, parent_gen_pid}, 2_000

      # Finish Wave 1 so Wave 1's submission settles to "done" while Wave 2 starts running!
      send(child_w1_pid, {:finish_wave1, turn1_gate})
      assert_receive {:wave2_running, child_w2_pid}, 2_000

      # Now parent calls await(session_id: child_sid) WITHOUT request_id while Wave 1 is already "done"
      # and Wave 2 is actively running!
      send(parent_gen_pid, :now_await_wave2)

      # Parent must park waiting on Wave 2 rather than prematurely settling on Wave 1!
      wait_until(fn ->
        {:ok, detail} = Daemon.get_session_detail(parent_sid, env.opts)
        Enum.any?(detail.tasks, &(&1.kind == "tool_call" and &1.status == "waiting"))
      end)

      send(child_w2_pid, {:finish_wave2, turn2_gate})

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries(parent_sid, "1", %{"order" => "asc"}, env.opts)

          if length(items) == 12, do: items, else: nil
        end)

      await_entry = Enum.at(items, 6)
      assert await_entry.kind == "tool_result"
      assert await_entry.data["details"]["mode"] == "await"
      assert await_entry.data["content"] == [%{"type" => "text", "text" => "Wave 2 final answer"}]

      assert List.last(items).data["content"] == [
               %{"type" => "text", "text" => "Both waves verified"}
             ]
    end
  end

  describe "mixed subagent and local tool calls in one assistant turn" do
    test "executes local tools without blocking on parked subagent and finishes round once all settle" do
      test_pid = self()
      child_gate = make_ref()

      handler = fn req, _emit ->
        prompt = first_user_text(req)
        tools = tool_messages(req)

        cond do
          prompt == "Mixed turn" and tools == [] ->
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_mix_sub",
                   name: "subagent",
                   arguments: %{"prompt" => "Child slow work", "read_only" => true}
                 },
                 %{
                   id: "c_mix_read",
                   name: "read",
                   arguments: %{"path" => "local.txt"}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Child slow work" ->
            send(test_pid, {:mixed_child_running, self()})

            receive do
              {:release_mixed_child, ^child_gate} -> :ok
            end

            {:ok, %{content: [%{type: "text", text: "Child finished after local read"}]}}

          prompt == "Mixed turn" and length(tools) == 2 ->
            texts = Enum.map(tools, fn m -> hd(m.content).text end)
            assert Enum.any?(texts, &(&1 =~ "local file content"))
            assert "Child finished after local read" in texts
            {:ok, %{content: [%{type: "text", text: "Mixed turn joined cleanly"}]}}
        end
      end

      env = start_env(handler)
      File.write!(Path.join(env.cwd, "local.txt"), "local file content\n")
      parent_sid = "parent-mixed-#{System.unique_integer([:positive])}"
      {:ok, _} = Daemon.create_session(%{"session_id" => parent_sid, "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          parent_sid,
          cmd("req-mix", "submit", "1", %{"type" => "input", "content" => "Mixed turn"}),
          env.opts
        )

      assert_receive {:mixed_child_running, child_worker}, 2_000

      # Local read tool MUST complete even while the earlier subagent call is still parked waiting!
      wait_until(fn ->
        {:ok, %{items: items}} =
          Daemon.scan_entries(parent_sid, "1", %{"order" => "asc"}, env.opts)

        Enum.any?(items, &(&1.kind == "tool_result" and &1.data["name"] == "read"))
      end)

      send(child_worker, {:release_mixed_child, child_gate})

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries(parent_sid, "1", %{"order" => "asc"}, env.opts)

          if length(items) == 5, do: items, else: nil
        end)

      assert List.last(items).data["content"] == [
               %{"type" => "text", "text" => "Mixed turn joined cleanly"}
             ]
    end
  end

  describe "depth and ownership guards" do
    test "depth-1 child omits subagent tool by default and rejects subagent invocation at max depth" do
      test_pid = self()

      handler = fn req, _emit ->
        prompt = first_user_text(req)
        tools = tool_messages(req)
        offered_names = Enum.map(req.tools, & &1.name)

        cond do
          prompt == "Root spawn" and tools == [] ->
            assert "subagent" in offered_names

            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_spawn_child",
                   name: "subagent",
                   arguments: %{"prompt" => "Child tries nested spawn"}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Child tries nested spawn" and tools == [] ->
            send(test_pid, {:child_offered_tools, offered_names})
            refute "subagent" in offered_names

            # Even if model hallucinates a subagent call, server rejects it cleanly
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_nested",
                   name: "subagent",
                   arguments: %{"prompt" => "Grandchild"}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Child tries nested spawn" and length(tools) == 1 ->
            [nested_res] = tools
            assert nested_res.is_error == true
            {:ok, %{content: [%{type: "text", text: "Nested blocked as expected"}]}}

          prompt == "Root spawn" and length(tools) == 1 ->
            [res] = tools
            assert hd(res.content).text == "Nested blocked as expected"
            {:ok, %{content: [%{type: "text", text: "Root done"}]}}
        end
      end

      env = start_env(handler)
      root_sid = "root-depth-#{System.unique_integer([:positive])}"
      {:ok, _} = Daemon.create_session(%{"session_id" => root_sid, "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          root_sid,
          cmd("req-d1", "submit", "1", %{"type" => "input", "content" => "Root spawn"}),
          env.opts
        )

      assert_receive {:child_offered_tools, child_tools}, 2_000
      refute "subagent" in child_tools
      assert "read" in child_tools

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries(root_sid, "1", %{"order" => "asc"}, env.opts)

          if length(items) == 4, do: items, else: nil
        end)

      assert List.last(items).data["content"] == [%{"type" => "text", "text" => "Root done"}]
    end

    test "rejects targeting an unrelated session with diagnostic forbidden_target" do
      other_sid = "unrelated-root-#{System.unique_integer([:positive])}"

      handler = fn req, _emit ->
        prompt = first_user_text(req)
        tools = tool_messages(req)

        cond do
          prompt == "Try hijack" and tools == [] ->
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_hijack_1",
                   name: "subagent",
                   arguments: %{
                     "mode" => "steer",
                     "session_id" => other_sid,
                     "prompt" => "Hijack"
                   }
                 },
                 %{
                   id: "c_hijack_2",
                   name: "subagent",
                   arguments: %{"mode" => "abort", "session_id" => other_sid}
                 },
                 %{
                   id: "c_hijack_3",
                   name: "subagent",
                   arguments: %{
                     "mode" => "wait",
                     "session_id" => other_sid,
                     "prompt" => "Follow up hijack"
                   }
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Try hijack" and length(tools) == 3 ->
            assert Enum.all?(tools, &(&1.is_error == true))
            {:ok, %{content: [%{type: "text", text: "All hijacks blocked"}]}}
        end
      end

      env = start_env(handler)
      parent_sid = "parent-guard-#{System.unique_integer([:positive])}"
      {:ok, _} = Daemon.create_session(%{"session_id" => other_sid, "cwd" => env.cwd}, env.opts)
      {:ok, _} = Daemon.create_session(%{"session_id" => parent_sid, "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          parent_sid,
          cmd("req-g1", "submit", "1", %{"type" => "input", "content" => "Try hijack"}),
          env.opts
        )

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries(parent_sid, "1", %{"order" => "asc"}, env.opts)

          if length(items) == 6, do: items, else: nil
        end)

      tool_results = Enum.filter(items, &(&1.kind == "tool_result"))
      assert length(tool_results) == 3
      assert Enum.all?(tool_results, &(&1.data["diagnostic"] == "forbidden_target"))
    end

    test "truncates oversized child answers to 32 KiB with session pointer and handles idle steer error cleanly" do
      long_body = String.duplicate("a", 40_000)
      child_sid_agent = start_supervised!({Agent, fn -> nil end})

      handler = fn req, _emit ->
        prompt = first_user_text(req)
        tools = tool_messages(req)

        cond do
          prompt == "Long answer and idle steer" and tools == [] ->
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_long",
                   name: "subagent",
                   arguments: %{"prompt" => "Produce long text"}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Produce long text" ->
            {:ok, %{content: [%{type: "text", text: long_body}]}}

          prompt == "Long answer and idle steer" and length(tools) == 1 ->
            [long_res] = tools
            assert long_res.is_error == false
            text = hd(long_res.content).text
            assert text =~ "[Subagent output truncated — inspect full transcript in session "
            assert byte_size(text) < 34_000
            [_, child_sid] = Regex.run(~r/in session ([^\]]+)\]/, text)
            Agent.update(child_sid_agent, fn _ -> child_sid end)

            # Now child is idle — steer should return conversation_idle error
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_idle_steer",
                   name: "subagent",
                   arguments: %{
                     "mode" => "steer",
                     "session_id" => child_sid,
                     "prompt" => "Too late to steer"
                   }
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Long answer and idle steer" and length(tools) == 2 ->
            [_, steer_res] = tools
            assert steer_res.is_error == true
            assert hd(steer_res.content).text =~ "currently idle"
            {:ok, %{content: [%{type: "text", text: "Handled truncation and idle steer"}]}}
        end
      end

      env = start_env(handler)
      parent_sid = "parent-trunc-#{System.unique_integer([:positive])}"
      {:ok, _} = Daemon.create_session(%{"session_id" => parent_sid, "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          parent_sid,
          cmd("req-t1", "submit", "1", %{
            "type" => "input",
            "content" => "Long answer and idle steer"
          }),
          env.opts
        )

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries(parent_sid, "1", %{"order" => "asc"}, env.opts)

          if length(items) == 6, do: items, else: nil
        end)

      steer_entry = Enum.at(items, 4)
      assert steer_entry.kind == "tool_result"
      assert steer_entry.data["is_error"] == true
      assert steer_entry.data["diagnostic"] == "conversation_idle"

      assert List.last(items).data["content"] == [
               %{"type" => "text", "text" => "Handled truncation and idle steer"}
             ]
    end

    test "enforces max_depth_exceeded inside Subagents even when subagent tool is explicitly forced at max depth" do
      handler = fn req, _emit ->
        prompt = first_user_text(req)
        tools = tool_messages(req)

        cond do
          prompt == "Force depth error" and tools == [] ->
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_depth_err",
                   name: "subagent",
                   arguments: %{"prompt" => "Should fail depth check"}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Force depth error" and length(tools) == 1 ->
            [res] = tools
            assert res.is_error == true
            {:ok, %{content: [%{type: "text", text: "Depth check caught"}]}}
        end
      end

      env =
        start_env(handler,
          max_subagent_depth: 0,
          tools: [H.Tools.Read, H.Tools.Subagent]
        )

      root_sid = "root-zero-depth-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Daemon.create_session(
          %{
            "session_id" => root_sid,
            "cwd" => env.cwd,
            "agent" => %{"tools" => ["read", "subagent"]}
          },
          env.opts
        )

      {:ok, _} =
        Daemon.execute_command(
          root_sid,
          cmd("req-z1", "submit", "1", %{"type" => "input", "content" => "Force depth error"}),
          env.opts
        )

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries(root_sid, "1", %{"order" => "asc"}, env.opts)

          if length(items) == 4, do: items, else: nil
        end)

      tool_res = Enum.at(items, 2)
      assert tool_res.data["is_error"] == true
      assert tool_res.data["diagnostic"] == "max_depth_exceeded"
    end
  end

  describe "bottom-up abort propagation" do
    test "aborting parent conversation aborts parked subagent tool and active child session" do
      test_pid = self()
      child_gate = make_ref()

      handler = fn req, _emit ->
        prompt = first_user_text(req)

        cond do
          prompt == "Run long child" ->
            {:ok,
             %{
               content: [],
               tool_calls: [
                 %{
                   id: "c_abort_sub",
                   name: "subagent",
                   arguments: %{"prompt" => "Long child job"}
                 }
               ],
               finish_reason: "tool_calls"
             }}

          prompt == "Long child job" ->
            send(test_pid, {:child_running, child_gate})

            receive do
              :never -> :ok
            end
        end
      end

      env = start_env(handler)
      parent_sid = "parent-abort-#{System.unique_integer([:positive])}"
      {:ok, _} = Daemon.create_session(%{"session_id" => parent_sid, "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          parent_sid,
          cmd("req-a1", "submit", "1", %{"type" => "input", "content" => "Run long child"}),
          env.opts
        )

      assert_receive {:child_running, ^child_gate}, 2_000

      child_entry =
        env.catalog_table
        |> Catalog.list_sessions()
        |> Enum.find(&(get_in(&1, [:parent, :session_id]) == parent_sid))

      assert child_entry != nil
      assert child_entry.active == true

      # Abort parent conversation
      assert {:ok, %{status: "done"}} =
               Daemon.execute_command(
                 parent_sid,
                 cmd("req-a-abort", "abort", "1", %{"reason" => "user_cancelled"}),
                 env.opts
               )

      # Both parent and child become inactive and child submission is unanswered with parent_aborted
      wait_until(fn ->
        {:ok, p_cat} = Catalog.get_session(parent_sid, env.catalog_table)
        {:ok, c_cat} = Catalog.get_session(child_entry.session_id, env.catalog_table)
        not p_cat.active and not c_cat.active
      end)

      {:ok, parent_detail} = Daemon.get_session_detail(parent_sid, env.opts)
      assert Enum.all?(parent_detail.tasks, &(&1.status == "terminal"))

      {:ok, child_detail} = Daemon.get_session_detail(child_entry.session_id, env.opts)
      child_gen = Enum.find(child_detail.tasks, &(&1.kind == "generation"))
      assert child_gen.status == "terminal"
      assert child_gen.cancelled == true
      assert child_gen.abort_reason == "parent_aborted"
    end
  end
end
