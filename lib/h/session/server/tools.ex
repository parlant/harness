defmodule H.Session.Server.Tools do
  @moduledoc """
  Tool worker spawning, argument validation, mutating workspace lease handling,
  sequential tool-round advancement, and interrupted/aborted tool settlement
  for `H.Session.Server`.
  """

  alias H.{Document, Storage, Task, Tool}
  alias H.Session.{LiveOutput, Subagents}
  alias H.Session.Server.{State, Stream, Submissions}

  @doc """
  Computes the next `{:spawn_tool, cid, tid}` effects for a generation's tool round.

  Regular worker tools execute sequentially one at a time, whereas consecutive
  pending `"subagent"` tool calls dispatch and park concurrently without holding
  `Task.Supervisor` workers.
  """
  def next_tool_spawn_effects(cid, child_ids, state) when is_list(child_ids) do
    children =
      child_ids
      |> Enum.map(&Map.get(state.tasks, &1))
      |> Enum.reject(&is_nil/1)

    non_subagent_running? =
      Enum.any?(children, fn t ->
        t.status == "running" and t.checkpoint["name"] != "subagent"
      end)

    if non_subagent_running? do
      []
    else
      case Enum.find(children, &(&1.status == "pending")) do
        nil ->
          []

        %{checkpoint: %{"name" => "subagent"}} ->
          children
          |> Enum.filter(&(&1.status == "pending" and &1.checkpoint["name"] == "subagent"))
          |> Enum.map(&{:spawn_tool, cid, &1.id})

        first_pending ->
          [{:spawn_tool, cid, first_pending.id}]
      end
    end
  end

  def spawn_worker(cid, tool_task_id, state, apply_effects_fn) do
    case Map.get(state.tasks, tool_task_id) do
      %{status: "pending"} = tool_task ->
        now = System.system_time(:millisecond)
        cp = tool_task.checkpoint
        call_id = cp["call_id"]
        name = cp["name"]
        args = cp["arguments"] || %{}

        tool = if Tool.selected?(name, state.docs[cid]["agent"]["tools"]), do: state.tools[name]

        case tool do
          nil ->
            commit_immediate_error(
              cid,
              tool_task,
              call_id,
              name,
              "Tool not available: #{name}",
              "unknown_tool",
              state,
              now,
              apply_effects_fn
            )

          tool_mod ->
            case Tool.validate_args(tool_mod, args) do
              {:error, reason} ->
                commit_immediate_error(
                  cid,
                  tool_task,
                  call_id,
                  name,
                  "Invalid arguments for #{name}: #{reason}",
                  "invalid_arguments",
                  state,
                  now,
                  apply_effects_fn
                )

              {:ok, validated_args} ->
                if tool_mod == H.Tools.Subagent do
                  Subagents.spawn_or_dispatch(
                    cid,
                    tool_task,
                    validated_args,
                    state,
                    apply_effects_fn
                  )
                else
                  case maybe_acquire_tool_lease(tool_mod, cid, state) do
                    {:error, {:workspace_busy, holder_key}} ->
                      commit_immediate_error(
                        cid,
                        tool_task,
                        call_id,
                        name,
                        "Workspace #{state.cwd} is currently busy with mutating work by #{inspect(holder_key)}.",
                        "workspace_busy",
                        state,
                        now,
                        apply_effects_fn
                      )

                    {:ok, state} ->
                      {:ok, attempt_id, store} = Storage.mint_id(state.store)
                      state = %{state | store: store}

                      running_task =
                        Task.start_running(tool_task, attempt_id, now, %{
                          "phase" => "execute",
                          "replay" => Atom.to_string(tool_mod.replay())
                        })

                      live = State.put_tool_status(state.docs[cid]["live"], call_id, "running")

                      state =
                        state
                        |> State.put_task(running_task)
                        |> State.put_doc(cid, "live", live)

                      case Storage.commit(state.store, [
                             [
                               {:put_task, running_task},
                               {:put_doc, {:conversation, cid, "live"},
                                Document.wrap("live", live)}
                             ]
                           ]) do
                        {:error, _io_err} ->
                          State.release_lease(cid, state)

                        {:ok, %{seqs: [batch_seq]}, committed_store} ->
                          state = %{state | store: committed_store, seq: batch_seq}

                          state =
                            Stream.broadcast_commit_frame(state, cid, batch_seq, [], %{
                              "live" => [["set", ["tools", call_id, "status"], "running"]]
                            })

                          server_pid = self()
                          inc = state.incarnation
                          env = state.execution_env
                          sid = state.session_id

                          output_preview =
                            LiveOutput.limit(fn chunk ->
                              send(
                                server_pid,
                                {:tool_output, inc, tool_task_id, attempt_id, cid, call_id, chunk}
                              )
                            end)

                          tool_ctx = %{
                            env: env,
                            session_id: sid,
                            conversation_id: cid,
                            task_id: tool_task_id,
                            scan_entries: fn q ->
                              H.Session.Server.scan_entries(server_pid, cid, q)
                            end,
                            on_output: fn chunk, _total -> output_preview.(chunk) end
                          }

                          {:ok, worker_pid} =
                            Elixir.Task.Supervisor.start_child(state.task_sup, fn ->
                              t0 = System.monotonic_time(:millisecond)
                              res = tool_mod.execute(validated_args, tool_ctx)
                              dur = max(0, System.monotonic_time(:millisecond) - t0)

                              send(
                                server_pid,
                                {:worker_done, inc, tool_task_id, attempt_id,
                                 {:tool_result, dur, res}}
                              )
                            end)

                          ref = Process.monitor(worker_pid)

                          worker_info = %{
                            task_id: tool_task_id,
                            conv_id: cid,
                            kind: :tool_call,
                            pid: worker_pid,
                            monitor_ref: ref,
                            started_at: now
                          }

                          %{state | workers: Map.put(state.workers, attempt_id, worker_info)}
                      end
                  end
                end
            end
        end

      _ ->
        state
    end
  end

  def stage_done(tid, attempt_id, {:tool_result, duration_ms, tool_res}, state) do
    {worker, workers} = Map.pop(state.workers, attempt_id)
    Process.demonitor(worker.monitor_ref, [:flush])
    state = %{state | workers: workers}

    case Map.get(state.tasks, tid) do
      nil ->
        {:skip, state}

      %{status: "terminal"} ->
        {:skip, state}

      tool_task ->
        now = System.system_time(:millisecond)
        cid = tool_task.checkpoint["conversation_id"]
        call_id = tool_task.checkpoint["call_id"]
        name = tool_task.checkpoint["name"]

        eph = Map.get(state.ephemeral, cid)
        live = Stream.merge_ephemeral_into_live(state.docs[cid]["live"], eph)
        state = Stream.clear_ephemeral_for_conv(state, cid)

        out_map =
          case tool_res do
            {:ok, m} -> m
            {:error, m} -> m
          end

        {:ok, entry_id, store} = Storage.mint_id(state.store)
        state = %{state | store: store}

        entry_data = %{
          "tool_call_id" => call_id,
          "name" => name,
          "content" => State.stringify_json(Map.get(out_map, :content, [])),
          "details" => State.stringify_json(Map.get(out_map, :details, %{})),
          "is_error" => Map.get(out_map, :is_error, false) == true,
          "diagnostic" => Map.get(out_map, :diagnostic),
          "duration_ms" => duration_ms
        }

        entry = State.build_entry(entry_id, cid, "tool_result", entry_data, now)
        state = State.record_entry(state, cid, entry_id)

        done_task =
          Task.complete(
            tool_task,
            %{"entry_id" => entry_id, "is_error" => entry_data["is_error"]},
            now
          )

        live = State.put_tool_status(live, call_id, "done")
        state = state |> State.put_task(done_task) |> State.put_doc(cid, "live", live)

        stage_after_tool_settled(cid, done_task, entry, live, state, now, [{:release_lease, cid}])
    end
  end

  def stage_after_tool_settled(cid, done_tool_task, entry, live, state, now, base_effects) do
    {:task, gen_task_id} = done_tool_task.owner
    gen_task = Map.fetch!(state.tasks, gen_task_id)
    child_ids = gen_task.checkpoint["tool_task_ids"] || []

    children =
      child_ids
      |> Enum.map(&Map.get(state.tasks, &1))
      |> Enum.reject(&is_nil/1)

    next_spawn_effects = next_tool_spawn_effects(cid, child_ids, state)
    all_terminal? = Enum.all?(children, &(&1.status == "terminal"))

    cond do
      next_spawn_effects != [] ->
        writes = [
          {:append_entry, entry},
          {:put_task, done_tool_task},
          {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", live)}
        ]

        staged = %{
          raw_item: {:worker_done, done_tool_task.id, :none, :settled},
          writes: writes,
          conv_events: %{cid => %{entries: [entry], doc_ops: %{"live" => [["replace", live]]}}},
          submissions: [],
          effects: base_effects ++ next_spawn_effects,
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}

      not all_terminal? ->
        writes = [
          {:append_entry, entry},
          {:put_task, done_tool_task},
          {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", live)}
        ]

        staged = %{
          raw_item: {:worker_done, done_tool_task.id, :none, :settled},
          writes: writes,
          conv_events: %{cid => %{entries: [entry], doc_ops: %{"live" => [["replace", live]]}}},
          submissions: [],
          effects: base_effects,
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}

      true ->
        {round_writes, state, round_effects} = finish_tool_round_stage(gen_task, state, now)
        next_live = state.docs[cid]["live"]

        appended =
          [entry] ++
            Enum.flat_map(round_writes, fn
              {:append_entry, e} -> [e]
              _ -> []
            end)

        inbox_ops =
          Enum.flat_map(round_writes, fn
            {:put_doc, {:conversation, ^cid, "inbox"}, _} ->
              [["replace", state.docs[cid]["inbox"]]]

            _ ->
              []
          end)

        doc_ops =
          %{"live" => [["replace", next_live]]}
          |> then(fn m -> if inbox_ops == [], do: m, else: Map.put(m, "inbox", inbox_ops) end)

        writes = [{:append_entry, entry}, {:put_task, done_tool_task}] ++ round_writes

        staged = %{
          raw_item: {:worker_done, done_tool_task.id, :none, :settled},
          writes: writes,
          conv_events: %{cid => %{entries: appended, doc_ops: doc_ops}},
          submissions: [],
          effects: base_effects ++ round_effects,
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}
    end
  end

  def finish_tool_round_stage(gen_task, state, now) do
    cid = gen_task.checkpoint["conversation_id"]
    turns = gen_task.checkpoint["turns"] || 1

    {steer_entries, steer_sub_writes, steer_sub_ids, inbox_ops, state} =
      Submissions.drain_inbox(cid, state, now, "steer")

    next_turns = turns + 1
    existing_sub_ids = gen_task.checkpoint["submission_ids"] || []

    next_gen = %{
      gen_task
      | status: "pending",
        restarts: 0,
        checkpoint:
          gen_task.checkpoint
          |> Map.merge(%{
            "turns" => next_turns,
            "retry_count" => 0,
            "phase" => "stream",
            "submission_ids" => existing_sub_ids ++ steer_sub_ids
          })
          |> Map.delete("tool_task_ids"),
        updated_at: now
    }

    next_live = Submissions.initial_generation_live(next_gen.id, next_turns)

    state =
      state
      |> State.put_task(next_gen)
      |> State.put_doc(cid, "live", next_live)

    writes =
      Enum.map(steer_entries, &{:append_entry, &1}) ++
        steer_sub_writes ++
        [
          {:put_task, next_gen},
          {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
        ] ++
        if(inbox_ops == [],
          do: [],
          else: [
            {:put_doc, {:conversation, cid, "inbox"},
             Document.wrap("inbox", state.docs[cid]["inbox"])}
          ]
        )

    {writes, state, [{:spawn_generation, cid, next_gen.id}]}
  end

  def recover_unclean_tool_call(tool_task, state, now) do
    cp = tool_task.checkpoint
    cid = cp["conversation_id"]
    call_id = cp["call_id"]
    name = cp["name"]

    if cp["replay"] == "safe" and State.tool_replay_string(state.tools, name) == "safe" do
      pending_task = %{tool_task | status: "pending", updated_at: now}
      live = State.put_tool_status(state.docs[cid]["live"], call_id, "pending")

      state =
        state
        |> State.put_task(pending_task)
        |> State.put_doc(cid, "live", live)

      {
        [
          {:put_task, pending_task},
          {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", live)}
        ],
        state
      }
    else
      partial_output = get_in(state.docs[cid]["live"], ["tools", call_id, "output"]) || ""
      {:ok, entry_id, store} = Storage.mint_id(state.store)
      state = %{state | store: store}

      entry_data = %{
        "tool_call_id" => call_id,
        "name" => name,
        "content" => [
          %{"type" => "text", "text" => interrupted_tool_message(name, partial_output)}
        ],
        "details" => %{"interrupted" => true, "partial_output" => partial_output},
        "is_error" => true,
        "diagnostic" => "interrupted"
      }

      entry = State.build_entry(entry_id, cid, "tool_result", entry_data, now)
      state = State.record_entry(state, cid, entry_id)

      done_task =
        Task.complete(
          tool_task,
          %{"entry_id" => entry_id, "is_error" => true, "diagnostic" => "interrupted"},
          now
        )

      live = State.put_tool_status(state.docs[cid]["live"], call_id, "done")

      state =
        state
        |> State.put_task(done_task)
        |> State.put_doc(cid, "live", live)

      {
        [
          {:append_entry, entry},
          {:put_task, done_task},
          {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", live)}
        ],
        state
      }
    end
  end

  def abort_child_tools(child_ids, cid, live, reason, state, now) do
    Enum.reduce(child_ids, {[], state, []}, fn tid, {acc_w, acc_s, acc_k} ->
      case Map.get(acc_s.tasks, tid) do
        nil ->
          {acc_w, acc_s, acc_k}

        %{status: "terminal"} ->
          {acc_w, acc_s, acc_k}

        tool_task ->
          call_id = tool_task.checkpoint["call_id"]
          name = tool_task.checkpoint["name"]
          partial_out = get_in(live, ["tools", call_id, "output"]) || ""

          {:ok, entry_id, store} = Storage.mint_id(acc_s.store)
          acc_s = %{acc_s | store: store}

          entry_data = %{
            "tool_call_id" => call_id,
            "name" => name,
            "content" => [
              %{"type" => "text", "text" => aborted_tool_message(name, partial_out)}
            ],
            "details" => %{"aborted" => true, "partial_output" => partial_out},
            "is_error" => true,
            "diagnostic" => "aborted"
          }

          entry = State.build_entry(entry_id, cid, "tool_result", entry_data, now)
          acc_s = State.record_entry(acc_s, cid, entry_id)
          aborted_tool = Task.abort(tool_task, reason, now)
          acc_s = State.put_task(acc_s, aborted_tool)

          {acc_s, subagent_effects} =
            case tool_task.memos do
              %{"child_session_id" => child_sid, "mode" => mode} = memos
              when is_binary(child_sid) and mode in ["wait", "await"] ->
                child_cid = memos["child_conversation_id"] || 1
                child_req_id = memos["child_request_id"]

                acc_s =
                  if is_binary(child_req_id),
                    do: Subagents.remove_watch(acc_s, child_sid, child_req_id, tid),
                    else: acc_s

                unwatch_eff =
                  if is_binary(child_req_id),
                    do: [{:unwatch_subagent, child_sid, child_req_id}],
                    else: []

                {acc_s,
                 unwatch_eff ++ [{:abort_subagent, child_sid, child_cid, "parent_aborted"}]}

              _ ->
                {acc_s, []}
            end

          kill_eff =
            State.worker_kill_effects(acc_s, tid) ++
              [{:release_lease, cid}] ++ subagent_effects

          {acc_w ++ [{:append_entry, entry}, {:put_task, aborted_tool}], acc_s, acc_k ++ kill_eff}
      end
    end)
  end

  def unsafe_running_tool?(task),
    do: task.kind == "tool_call" and task.checkpoint["replay"] != "safe"

  # Internal helpers

  defp maybe_acquire_tool_lease(tool_mod, cid, state) do
    if tool_mod.mutating?() do
      State.acquire_lease(cid, state)
    else
      {:ok, state}
    end
  end

  defp commit_immediate_error(
         cid,
         tool_task,
         call_id,
         name,
         message,
         diagnostic,
         state,
         now,
         apply_effects_fn
       ) do
    {:ok, entry_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}

    entry_data = %{
      "tool_call_id" => call_id,
      "name" => name,
      "content" => [%{"type" => "text", "text" => message}],
      "details" => %{"diagnostic" => diagnostic},
      "is_error" => true,
      "diagnostic" => diagnostic
    }

    entry = State.build_entry(entry_id, cid, "tool_result", entry_data, now)
    state = State.record_entry(state, cid, entry_id)

    done_task =
      Task.complete(
        tool_task,
        %{"entry_id" => entry_id, "is_error" => true, "diagnostic" => diagnostic},
        now
      )

    live = State.put_tool_status(state.docs[cid]["live"], call_id, "done")
    state = state |> State.put_task(done_task) |> State.put_doc(cid, "live", live)

    {:batch, staged, state} =
      stage_after_tool_settled(cid, done_task, entry, live, state, now, [])

    case Storage.commit(state.store, [staged.writes]) do
      {:ok, %{seqs: [batch_seq]}, committed_store} ->
        state =
          Stream.apply_committed_batches([staged], [batch_seq], %{state | store: committed_store})

        apply_effects_fn.(staged.effects, state)

      {:error, _} ->
        state
    end
  end

  defp interrupted_tool_message(name, "") do
    "Tool '#{name}' was interrupted by daemon crash before completing; it was not re-executed because replay is unsafe."
  end

  defp interrupted_tool_message(name, partial) do
    "Tool '#{name}' was interrupted by daemon crash before completing (not re-executed).\n\nPartial output:\n#{partial}"
  end

  defp aborted_tool_message(name, "") do
    "Tool '#{name}' was aborted."
  end

  defp aborted_tool_message(name, partial) do
    "Tool '#{name}' was aborted.\n\nPartial output:\n#{partial}"
  end
end
