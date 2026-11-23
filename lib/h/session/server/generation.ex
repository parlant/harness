defmodule H.Session.Server.Generation do
  @moduledoc """
  Generation and compaction worker spawning, auto-compaction promotion,
  retry/wake staging, and completion/cancellation/abort settlement for
  `H.Session.Server`.
  """

  require Logger

  alias H.{Context, Document, Storage, Task}
  alias H.Session.Compaction
  alias H.Session.Server.{State, Stream, Submissions, Tools}

  @max_retry_backoff_ms 60_000
  @wait_topic_regex ~r/\A[a-z0-9:._-]+\z/

  def valid_wait_topic?(topic) when is_binary(topic) do
    byte_size(topic) in 1..80 and Regex.match?(@wait_topic_regex, topic)
  end

  def valid_wait_topic?(_), do: false

  def replay_inference?(task), do: is_nil(task.checkpoint["dispatch_policy"])

  def retry_delay_ms(state, attempt) do
    min(state.retry_backoff_ms * Integer.pow(2, min(attempt - 1, 16)), @max_retry_backoff_ms)
  end

  def spawn_generation_worker(cid, gen_task_id, state) do
    case Map.get(state.tasks, gen_task_id) do
      %{kind: "generation", status: status} = gen_task when status in ["pending", "sleeping"] ->
        {:ok, entries, state} = State.load_visible_entries(state, cid)

        request =
          Context.build_request(
            entries,
            state.docs[cid]["agent"],
            State.build_tool_specs(state.tools),
            cwd: state.cwd
          )

        case Compaction.auto_boundary(
               entries,
               request,
               state.cwd,
               state.auto_compaction,
               state.compaction_keep_recent_chars,
               state.provider_mod,
               state.provider_config
             ) do
          nil ->
            start_generation_attempt(cid, gen_task, state, request)

          kept_from_id ->
            checkpoint =
              Map.merge(gen_task.checkpoint, %{
                "automatic" => true,
                "phase" => "summarize",
                "kept_from_id" => kept_from_id,
                "max_tokens" => state.compaction_max_tokens,
                "retry_count" => 0
              })

            task = %{gen_task | kind: "compaction", checkpoint: checkpoint}

            # spawn_compaction_worker persists the new kind, boundary and live doc before calling the provider.
            spawn_compaction_worker(cid, task.id, State.put_task(state, task))
        end

      _ ->
        state
    end
  end

  def spawn_compaction_worker(cid, comp_task_id, state) do
    case Map.get(state.tasks, comp_task_id) do
      %{kind: "compaction", status: status} = comp_task when status in ["pending", "sleeping"] ->
        now = System.system_time(:millisecond)
        cp = comp_task.checkpoint
        kept_from_id = cp["kept_from_id"]
        max_tokens = cp["max_tokens"] || state.compaction_max_tokens
        instructions = cp["instructions"]

        {:ok, entries, state} = State.load_visible_entries(state, cid)

        case Compaction.prepare(entries, kept_from_id: kept_from_id, max_tokens: max_tokens) do
          {:error, reason} ->
            commit_immediate_compaction_failure(
              cid,
              comp_task,
              Atom.to_string(reason),
              "Compaction boundary is no longer valid (#{reason})",
              state,
              now
            )

          {:ok, prep} ->
            {:ok, attempt_id, store} = Storage.mint_id(state.store)
            state = %{state | store: store}

            config = inference_config(state)

            policy =
              dispatch_policy(state.provider_mod, config, state.docs[cid]["agent"]["model"])

            running_task = Task.start_running(comp_task, attempt_id, now, policy)
            live = state.docs[cid]["live"] || %{}

            comp_live =
              (Map.get(live, "compaction") || %{})
              |> Map.put("task_id", to_string(comp_task_id))
              |> Map.put("kept_from_id", kept_from_id)
              |> Map.put("status", "running")
              |> mark_retry_running()
              |> mark_wait_running()

            next_live =
              live |> Map.drop(["run", "generation"]) |> Map.put("compaction", comp_live)

            state =
              state
              |> State.put_task(running_task)
              |> State.put_doc(cid, "live", next_live)

            # Persist running intent before spawning worker!
            case Storage.commit(state.store, [
                   [
                     {:put_task, running_task},
                     {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
                   ]
                 ]) do
              {:error, io_err} ->
                Logger.error(
                  "Session #{state.session_id} compaction intent commit failed: #{inspect(io_err)}"
                )

                send(self(), {:stop_storage_failed, io_err})
                %{state | storage_failed: true}

              {:ok, %{seqs: [batch_seq]}, committed_store} ->
                state = %{state | store: committed_store, seq: batch_seq}

                state =
                  Stream.broadcast_commit_frame(state, cid, batch_seq, [], %{
                    "live" => [["replace", next_live]]
                  })

                server_pid = self()
                inc = state.incarnation
                agent = state.docs[cid]["agent"]
                provider_mod = state.provider_mod

                {:ok, worker_pid} =
                  Elixir.Task.Supervisor.start_child(state.task_sup, fn ->
                    res =
                      Compaction.summarize(prep, agent, provider_mod, config,
                        instructions: instructions
                      )

                    send(
                      server_pid,
                      {:worker_done, inc, comp_task_id, attempt_id, {:compaction_result, res}}
                    )
                  end)

                ref = Process.monitor(worker_pid)

                worker_info = %{
                  task_id: comp_task_id,
                  conv_id: cid,
                  kind: :compaction,
                  pid: worker_pid,
                  monitor_ref: ref,
                  started_at: now,
                  deadline_mono_ms:
                    System.monotonic_time(:millisecond) + stream_timeout_ms(config)
                }

                %{state | workers: Map.put(state.workers, attempt_id, worker_info)}
            end
        end

      _ ->
        state
    end
  end

  def stage_done(tid, attempt_id, {:generation_result, gen_result}, state) do
    {worker, workers} = Map.pop(state.workers, attempt_id)
    Process.demonitor(worker.monitor_ref, [:flush])
    state = %{state | workers: workers}

    case Map.get(state.tasks, tid) do
      nil ->
        {:skip, state}

      %{status: "terminal"} ->
        {:skip, state}

      gen_task ->
        now = System.system_time(:millisecond)
        cid = gen_task.checkpoint["conversation_id"]
        state = Stream.clear_ephemeral_for_conv(state, cid)

        case gen_result do
          {:ok, resp} -> stage_generation_success(gen_task, cid, resp, state, now)
          {:cancelled, partial} -> stage_generation_cancelled(gen_task, cid, partial, state, now)
          {:error, err} -> stage_generation_error(gen_task, cid, err, state, now)
        end
    end
  end

  def stage_done(tid, attempt_id, {:compaction_result, comp_res}, state) do
    {worker, workers} = Map.pop(state.workers, attempt_id)
    if worker, do: Process.demonitor(worker.monitor_ref, [:flush])
    state = %{state | workers: workers}

    case Map.get(state.tasks, tid) do
      nil ->
        {:skip, state}

      %{status: "terminal"} ->
        {:skip, state}

      comp_task ->
        now = System.system_time(:millisecond)
        cid = comp_task.checkpoint["conversation_id"]

        case comp_res do
          {:ok, result} -> stage_compaction_success(comp_task, cid, result, state, now)
          {:error, err} -> stage_compaction_error(comp_task, cid, err, state, now)
        end
    end
  end

  def stage_wake(tid, state) do
    case Map.get(state.tasks, tid) do
      %{status: "sleeping", kind: kind} = task when kind in ["generation", "compaction"] ->
        now = System.system_time(:millisecond)
        {writes, conv_events, effects, state} = wake_sleeping_task(task, state, now)

        staged = %{
          raw_item: {:wake_task, tid},
          writes: writes,
          conv_events: conv_events,
          submissions: [],
          effects: effects,
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}

      _ ->
        {:skip, state}
    end
  end

  def stage_wait_signal(topic, state) when is_binary(topic) do
    waiting_tasks =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn t ->
        t.status == "sleeping" and t.kind in ["generation", "compaction"] and
          get_in(t.wake, ["reason"]) == "wait" and
          get_in(t.wake, ["topic"]) == topic
      end)
      |> Enum.sort_by(& &1.id)

    if waiting_tasks == [] do
      {:immediate, nil, nil, [{:maybe_unwatch_wait_signal, topic}], state}
    else
      now = System.system_time(:millisecond)

      {writes, conv_events, effects, state} =
        Enum.reduce(waiting_tasks, {[], %{}, [], state}, fn task,
                                                            {acc_w, acc_ev, acc_eff, acc_st} ->
          {w, ev, eff, next_st} = wake_sleeping_task(task, acc_st, now)
          {acc_w ++ w, Map.merge(acc_ev, ev), acc_eff ++ eff, next_st}
        end)

      staged = %{
        raw_item: {:wait_signal, topic},
        writes: writes,
        conv_events: conv_events,
        submissions: [],
        effects: effects ++ [{:maybe_unwatch_wait_signal, topic}],
        reply_from: nil,
        receipt: nil
      }

      {:batch, staged, state}
    end
  end

  def stage_wait_signal(_topic, state), do: {:skip, state}

  def abort_compaction_run(comp_task, cid, reason, state, now) do
    aborted_task = Task.abort(comp_task, reason, now)
    state = State.put_task(state, aborted_task)

    sub_ids = comp_task.checkpoint["submission_ids"] || []
    {sub_writes, state} = Submissions.settle(sub_ids, :unanswered, reason, state, now)

    next_live =
      compaction_failure(state.docs[cid]["live"], comp_task, reason, "Compaction aborted")

    state = State.put_doc(state, cid, "live", next_live)

    writes =
      [{:put_task, aborted_task}] ++
        sub_writes ++
        [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

    effects =
      State.worker_kill_effects(state, comp_task.id) ++
        [{:cancel_wake_timer, comp_task.id}] ++
        wait_unwatch_effect(comp_task)

    {writes, state, effects}
  end

  def abort_generation_run(gen_task, cid, reason, state, now) do
    eph = Map.get(state.ephemeral, cid)
    live = Stream.merge_ephemeral_into_live(state.docs[cid]["live"], eph)
    state = Stream.clear_ephemeral_for_conv(state, cid)

    {partial_writes, state} = maybe_append_aborted_partial(cid, live, state, now)

    child_ids = gen_task.checkpoint["tool_task_ids"] || []

    {tool_writes, state, tool_kills} =
      Tools.abort_child_tools(child_ids, cid, live, reason, state, now)

    aborted_gen = Task.abort(gen_task, reason, now)
    state = State.put_task(state, aborted_gen)

    sub_ids = gen_task.checkpoint["submission_ids"] || []
    {sub_writes, state} = Submissions.settle(sub_ids, :unanswered, reason, state, now)

    next_live =
      live
      |> Map.delete("run")
      |> Map.delete("generation")
      |> Map.delete("tools")
      |> Map.delete("workspace_wait")
      |> Map.put("run_failure", %{"reason" => reason})

    state = State.put_doc(state, cid, "live", next_live)

    writes =
      partial_writes ++
        tool_writes ++
        [{:put_task, aborted_gen}] ++
        sub_writes ++
        [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

    effects =
      State.worker_kill_effects(state, gen_task.id) ++
        tool_kills ++
        [{:release_lease, cid}, {:cancel_wake_timer, gen_task.id}] ++
        wait_unwatch_effect(gen_task)

    {writes, state, effects}
  end

  def maybe_append_aborted_partial(cid, live, state, now) do
    msg = Map.get(live, "generation", %{}) |> Map.get("message", %{})
    thinking = Map.get(msg, "thinking", "")
    text = Map.get(msg, "text", "")
    tool_calls = Map.get(msg, "tool_calls", [])

    blocks =
      []
      |> then(fn acc ->
        if is_binary(thinking) and thinking != "",
          do: acc ++ [%{"type" => "thinking", "text" => thinking}],
          else: acc
      end)
      |> then(fn acc ->
        if is_binary(text) and text != "",
          do: acc ++ [%{"type" => "text", "text" => text}],
          else: acc
      end)

    if blocks != [] or (is_list(tool_calls) and tool_calls != []) do
      {:ok, entry_id, store} = Storage.mint_id(state.store)
      state = %{state | store: store}

      entry_data = %{
        "content" => blocks,
        "tool_calls" => State.stringify_tool_calls(tool_calls),
        "aborted" => true,
        "finish_reason" => "aborted"
      }

      entry = State.build_entry(entry_id, cid, "assistant", entry_data, now)
      state = State.record_entry(state, cid, entry_id)
      {[{:append_entry, entry}], state}
    else
      {[], state}
    end
  end

  def compaction_failure(live, task, code, message) do
    (live || %{})
    |> Map.delete("compaction")
    |> Map.put("compaction_failure", %{
      "reason" => code,
      "code" => code,
      "message" => message,
      "automatic" => task.checkpoint["automatic"] == true
    })
  end

  def schedule_inference_retry(task, cid, live, retry_count, state, now, error \\ %{}) do
    delay_ms = max(retry_delay_ms(state, retry_count), Map.get(error, :retry_after_ms, 0))
    until_ms = now + delay_ms

    retry = %{
      "attempt" => retry_count,
      "max_attempts" => state.retry_limit,
      "delay_ms" => delay_ms,
      "until" => until_ms,
      "status" => "waiting",
      "code" => to_string(Map.get(error, :code, "interrupted")),
      "message" =>
        H.Credentials.sanitize(
          to_string(Map.get(error, :message, "Inference interrupted; retrying"))
        )
    }

    sleeping_task =
      Task.sleep_until(task, until_ms, "retry", now, %{
        "retry_count" => retry_count,
        "retry" => retry
      })
      |> then(fn t -> %{t | checkpoint: Map.delete(t.checkpoint, "wait")} end)

    next_live =
      case task.kind do
        "generation" ->
          Map.put(live, "generation", %{
            "message" => %{"thinking" => "", "text" => "", "tool_calls" => []},
            "retry" => retry
          })

        "compaction" ->
          comp_live =
            (Map.get(live, "compaction") || %{})
            |> Map.put("task_id", to_string(task.id))
            |> Map.put("kept_from_id", task.checkpoint["kept_from_id"])
            |> Map.put("status", "retrying")
            |> Map.delete("wait")
            |> Map.put("retry", retry)

          Map.put(live, "compaction", comp_live)
      end

    state =
      state
      |> State.put_task(sleeping_task)
      |> State.put_doc(cid, "live", next_live)

    writes = [
      {:put_task, sleeping_task},
      {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
    ]

    {writes, next_live, delay_ms, state}
  end

  def schedule_inference_wait(task, cid, live, state, now, error) do
    wait_spec = Map.get(error, :wait) || %{}

    delay_ms =
      case Map.get(error, :retry_after_ms) do
        ms when is_integer(ms) -> max(1_000, ms)
        _ -> 60_000
      end

    until_ms = now + delay_ms

    topic =
      case Map.get(wait_spec, :topic) do
        t when is_binary(t) -> if valid_wait_topic?(t), do: t, else: nil
        _ -> nil
      end

    code = sanitize_bounded_string(Map.get(error, :code), 80) || "waiting"
    title = sanitize_bounded_string(Map.get(wait_spec, :title), 120) || "Waiting to continue"

    message =
      sanitize_bounded_string(Map.get(error, :message), 500) ||
        "Temporarily waiting to continue."

    detail = sanitize_bounded_string(Map.get(wait_spec, :detail), 240)

    resumes_at =
      case Map.get(wait_spec, :resumes_at) do
        ts when is_integer(ts) and ts > 0 -> ts
        _ -> nil
      end

    wait_doc =
      %{
        "status" => "waiting",
        "code" => code,
        "title" => title,
        "message" => message,
        "until" => until_ms
      }
      |> maybe_put_string("detail", detail)
      |> maybe_put_int("resumes_at", resumes_at)

    wake =
      %{"until" => until_ms, "reason" => "wait"}
      |> maybe_put_string("topic", topic)

    base_checkpoint =
      (task.checkpoint || %{})
      |> Map.delete("attempt_id")
      |> Map.delete("retry")

    sleeping_task = %{
      task
      | status: "sleeping",
        wake: wake,
        checkpoint: Map.put(base_checkpoint, "wait", wait_doc),
        updated_at: now
    }

    next_live =
      case task.kind do
        "generation" ->
          Map.put(live || %{}, "generation", %{
            "message" => %{"thinking" => "", "text" => "", "tool_calls" => []},
            "wait" => wait_doc
          })

        "compaction" ->
          comp_live =
            (Map.get(live || %{}, "compaction") || %{})
            |> Map.put("task_id", to_string(task.id))
            |> Map.put("kept_from_id", task.checkpoint["kept_from_id"])
            |> Map.put("status", "waiting")
            |> Map.delete("retry")
            |> Map.put("wait", wait_doc)

          Map.put(live || %{}, "compaction", comp_live)
      end

    state =
      state
      |> State.put_task(sleeping_task)
      |> State.put_doc(cid, "live", next_live)

    writes = [
      {:put_task, sleeping_task},
      {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
    ]

    watch_effects = if topic, do: [{:watch_wait_signal, topic}], else: []
    effects = watch_effects ++ [{:arm_wake_timer, task.id, delay_ms}]
    {writes, next_live, effects, state}
  end

  # Internal worker & stage helpers

  defp wake_sleeping_task(%{kind: "generation", id: tid} = gen_task, state, now) do
    cid = gen_task.checkpoint["conversation_id"]
    pending_task = %{gen_task | status: "pending", wake: nil, updated_at: now}

    generation =
      (get_in(state.docs, [cid, "live", "generation"]) || %{})
      |> Map.put("message", %{"thinking" => "", "text" => "", "tool_calls" => []})
      |> mark_retry_running()
      |> mark_wait_running()

    next_live = Map.put(state.docs[cid]["live"] || %{}, "generation", generation)

    state =
      state
      |> State.put_task(pending_task)
      |> State.put_doc(cid, "live", next_live)

    writes = [
      {:put_task, pending_task},
      {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
    ]

    conv_events = %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}}

    effects =
      [{:cancel_wake_timer, tid}] ++
        wait_unwatch_effect(gen_task) ++ [{:spawn_generation, cid, tid}]

    {writes, conv_events, effects, state}
  end

  defp wake_sleeping_task(%{kind: "compaction", id: tid} = comp_task, state, now) do
    cid = comp_task.checkpoint["conversation_id"]
    pending_task = %{comp_task | status: "pending", wake: nil, updated_at: now}
    live = state.docs[cid]["live"] || %{}

    comp_live =
      (Map.get(live, "compaction") || %{})
      |> Map.put("task_id", to_string(comp_task.id))
      |> Map.put("kept_from_id", comp_task.checkpoint["kept_from_id"])
      |> Map.put("status", "pending")
      |> mark_retry_running()
      |> mark_wait_running()

    next_live = Map.put(live, "compaction", comp_live)

    state =
      state
      |> State.put_task(pending_task)
      |> State.put_doc(cid, "live", next_live)

    writes = [
      {:put_task, pending_task},
      {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
    ]

    conv_events = %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}}

    effects =
      [{:cancel_wake_timer, tid}] ++
        wait_unwatch_effect(comp_task) ++ [{:spawn_compaction, cid, tid}]

    {writes, conv_events, effects, state}
  end

  defp wait_unwatch_effect(%{wake: %{"reason" => "wait", "topic" => topic}})
       when is_binary(topic),
       do: [{:maybe_unwatch_wait_signal, topic}]

  defp wait_unwatch_effect(_task), do: []

  defp valid_wait_error?(%{wait: %{} = _wait}), do: true
  defp valid_wait_error?(_), do: false

  defp sanitize_bounded_string(nil, _max), do: nil

  defp sanitize_bounded_string(val, max_len) do
    cleaned =
      val
      |> to_string()
      |> H.Credentials.sanitize()
      |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    case cleaned do
      "" -> nil
      str -> String.slice(str, 0, max_len)
    end
  end

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, val) when is_binary(val), do: Map.put(map, key, val)

  defp maybe_put_int(map, _key, nil), do: map
  defp maybe_put_int(map, key, val) when is_integer(val), do: Map.put(map, key, val)

  defp mark_retry_running(activity) do
    case activity["retry"] do
      %{} = retry -> Map.put(activity, "retry", Map.put(retry, "status", "running"))
      _ -> Map.delete(activity, "retry")
    end
  end

  defp mark_wait_running(activity) do
    case activity["wait"] do
      %{} = wait -> Map.put(activity, "wait", Map.put(wait, "status", "running"))
      _ -> Map.delete(activity, "wait")
    end
  end

  defp inference_config(%{provider_mod: H.Provider.ReqLLM, provider_config: config}),
    do: H.Provider.ReqLLM.attempt_config(config)

  defp inference_config(state), do: state.provider_config

  defp stream_timeout_ms(config) when is_map(config) do
    case Map.get(config, :receive_timeout) || Map.get(config, "receive_timeout") do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 300_000
    end
  end

  defp stream_timeout_ms(config) when is_list(config) do
    case Keyword.get(config, :receive_timeout) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> 300_000
    end
  end

  defp stream_timeout_ms(_), do: 300_000

  defp dispatch_policy(H.Provider.ReqLLM, config, model) do
    case H.Provider.ReqLLM.dispatch_limit(config, model || config[:model]) do
      nil ->
        %{}

      limit ->
        %{
          "dispatch_policy" => %{
            "version" => 1,
            "max_dispatches" => limit,
            "on_loss" => "interrupt"
          }
        }
    end
  end

  defp dispatch_policy(_, _, _), do: %{}

  defp start_generation_attempt(cid, gen_task, state, request) do
    gen_task_id = gen_task.id
    now = System.system_time(:millisecond)
    {:ok, attempt_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}

    config = inference_config(state)
    policy = dispatch_policy(state.provider_mod, config, request[:model])
    running_task = Task.start_running(gen_task, attempt_id, now, policy)

    state = State.put_task(state, running_task)

    # Persist running intent before spawning worker!
    case Storage.commit(state.store, [[{:put_task, running_task}]]) do
      {:error, io_err} ->
        Logger.error("Session #{state.session_id} intent commit failed: #{inspect(io_err)}")
        send(self(), {:stop_storage_failed, io_err})
        %{state | storage_failed: true}

      {:ok, %{seqs: [batch_seq]}, committed_store} ->
        state = %{state | store: committed_store, seq: batch_seq}

        server_pid = self()
        inc = state.incarnation
        provider_mod = state.provider_mod

        {:ok, worker_pid} =
          Elixir.Task.Supervisor.start_child(state.task_sup, fn ->
            emit = fn ev ->
              send(server_pid, {:gen_chunk, inc, gen_task_id, attempt_id, cid, ev})
            end

            res = provider_mod.stream_turn(config, request, emit)

            send(
              server_pid,
              {:worker_done, inc, gen_task_id, attempt_id, {:generation_result, res}}
            )
          end)

        ref = Process.monitor(worker_pid)

        worker_info = %{
          task_id: gen_task_id,
          conv_id: cid,
          kind: :generation,
          pid: worker_pid,
          monitor_ref: ref,
          started_at: now,
          deadline_mono_ms: System.monotonic_time(:millisecond) + stream_timeout_ms(config)
        }

        %{state | workers: Map.put(state.workers, attempt_id, worker_info)}
    end
  end

  defp commit_immediate_compaction_failure(cid, comp_task, code, message, state, now) do
    done_task = Task.complete(comp_task, %{"status" => "unanswered", "reason" => code}, now)
    sub_ids = comp_task.checkpoint["submission_ids"] || []
    {sub_writes, state} = Submissions.settle(sub_ids, :unanswered, code, state, now)

    next_live = compaction_failure(state.docs[cid]["live"], comp_task, code, message)

    state =
      state
      |> State.put_task(done_task)
      |> State.put_doc(cid, "live", next_live)

    writes =
      [{:put_task, done_task}] ++
        sub_writes ++
        [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

    case Storage.commit(state.store, [writes]) do
      {:ok, %{seqs: [batch_seq]}, committed_store} ->
        state = %{state | store: committed_store, seq: batch_seq}

        state =
          Stream.broadcast_commit_frame(state, cid, batch_seq, [], %{
            "live" => [["replace", next_live]]
          })

        Stream.broadcast_settled_submissions(state, writes, batch_seq)

      {:error, io_err} ->
        send(self(), {:stop_storage_failed, io_err})
        %{state | storage_failed: true}
    end
  end

  defp stage_generation_success(gen_task, cid, resp, state, now) do
    {:ok, entry_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}

    tool_calls = State.stringify_tool_calls(Map.get(resp, :tool_calls, []))
    usage_map = State.stringify_json(Map.get(resp, :usage, %{}))

    entry_data = %{
      "content" => State.stringify_json(Map.get(resp, :content, [])),
      "tool_calls" => tool_calls,
      "finish_reason" => to_string(Map.get(resp, :finish_reason) || "stop"),
      "usage" => usage_map,
      "provider_meta" => State.stringify_json(Map.get(resp, :provider_meta, %{}))
    }

    entry_data =
      case Map.get(resp, :reasoning_details) do
        [_ | _] = details ->
          Map.put(entry_data, "reasoning_details", State.stringify_json(details))

        _ ->
          entry_data
      end

    entry = State.build_entry(entry_id, cid, "assistant", entry_data, now)
    state = State.record_entry(state, cid, entry_id)

    {next_usage, usage_ops} = Document.accumulate_usage(state.docs[cid]["usage"], usage_map)
    state = State.put_doc(state, cid, "usage", next_usage)

    usage_writes =
      if usage_ops == [],
        do: [],
        else: [{:put_doc, {:conversation, cid, "usage"}, Document.wrap("usage", next_usage)}]

    if tool_calls == [] do
      done_gen =
        Task.complete(gen_task, %{"status" => "done", "answer_entry_id" => entry_id}, now)

      sub_ids = gen_task.checkpoint["submission_ids"] || []
      {sub_writes, state} = Submissions.settle(sub_ids, :done, entry_id, state, now)
      state = State.put_task(state, done_gen)

      {drained_entries, drained_sub_writes, next_sub_ids, inbox_ops, state} =
        Submissions.drain_inbox(cid, state, now, nil)

      {next_run_writes, next_live, next_effects, state} =
        if drained_entries == [] do
          live = %{}
          {[], live, [], State.put_doc(state, cid, "live", live)}
        else
          {next_gen, live, state} =
            Submissions.start_pending_generation(cid, next_sub_ids, state, now)

          {[{:put_task, next_gen}], live, [{:spawn_generation, cid, next_gen.id}], state}
        end

      all_entries = [entry | drained_entries]

      writes =
        Enum.map(all_entries, &{:append_entry, &1}) ++
          usage_writes ++
          sub_writes ++
          drained_sub_writes ++
          [{:put_task, done_gen}] ++
          next_run_writes ++
          [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}] ++
          if(inbox_ops == [],
            do: [],
            else: [{:put_doc, {:conversation, cid, "inbox"}, Document.wrap("inbox", [])}]
          )

      doc_ops =
        %{"live" => [["replace", next_live]]}
        |> then(fn m -> if usage_ops == [], do: m, else: Map.put(m, "usage", usage_ops) end)
        |> then(fn m -> if inbox_ops == [], do: m, else: Map.put(m, "inbox", inbox_ops) end)

      staged = %{
        raw_item: {:worker_done, gen_task.id, :none, {:generation_result, {:ok, resp}}},
        writes: writes,
        conv_events: %{cid => %{entries: all_entries, doc_ops: doc_ops}},
        submissions: [],
        effects: next_effects,
        reply_from: nil,
        receipt: nil
      }

      {:batch, staged, state}
    else
      {tool_tasks, live_tools, store} =
        tool_calls
        |> Enum.with_index()
        |> Enum.reduce({[], %{}, state.store}, fn {tc, idx}, {acc_t, acc_lt, acc_store} ->
          {:ok, tid, next_store} = Storage.mint_id(acc_store)
          call_id = tc["id"] || "call_#{tid}"
          name = tc["name"]

          t =
            Task.new(%{
              id: tid,
              kind: "tool_call",
              owner: {:task, gen_task.id},
              status: "pending",
              checkpoint: %{
                "conversation_id" => cid,
                "assistant_entry_id" => entry_id,
                "call_id" => call_id,
                "name" => name,
                "arguments" => tc["arguments"] || %{},
                "index" => idx,
                "phase" => "pending",
                "replay" => State.tool_replay_string(state.tools, name)
              },
              created_at: now
            })

          slot = %{"id" => call_id, "name" => name, "status" => "pending", "output" => ""}
          {[t | acc_t], Map.put(acc_lt, call_id, slot), next_store}
        end)

      tool_tasks = Enum.reverse(tool_tasks)
      tool_task_ids = Enum.map(tool_tasks, & &1.id)
      state = %{state | store: store}

      waiting_gen =
        Task.start_waiting(gen_task, now, %{
          "phase" => "tools",
          "tool_task_ids" => tool_task_ids
        })

      next_live =
        state.docs[cid]["live"]
        |> Map.delete("generation")
        |> Map.put("tools", live_tools)

      state =
        Enum.reduce(tool_tasks, state, &State.put_task(&2, &1))
        |> State.put_task(waiting_gen)
        |> State.put_doc(cid, "live", next_live)

      spawn_effects = Tools.next_tool_spawn_effects(cid, tool_task_ids, state)

      writes =
        [{:append_entry, entry}] ++
          usage_writes ++
          [{:put_task, waiting_gen}] ++
          Enum.map(tool_tasks, &{:put_task, &1}) ++
          [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

      doc_ops =
        %{"live" => [["replace", next_live]]}
        |> then(fn m -> if usage_ops == [], do: m, else: Map.put(m, "usage", usage_ops) end)

      staged = %{
        raw_item: {:worker_done, gen_task.id, :none, {:generation_result, {:ok, resp}}},
        writes: writes,
        conv_events: %{cid => %{entries: [entry], doc_ops: doc_ops}},
        submissions: [],
        effects: spawn_effects,
        reply_from: nil,
        receipt: nil
      }

      {:batch, staged, state}
    end
  end

  defp stage_generation_cancelled(gen_task, cid, _partial, state, now) do
    {writes, state, effects} = abort_generation_run(gen_task, cid, "aborted", state, now)
    next_live = state.docs[cid]["live"]

    appended =
      Enum.flat_map(writes, fn
        {:append_entry, e} -> [e]
        _ -> []
      end)

    staged = %{
      raw_item: {:worker_done, gen_task.id, :none, {:generation_result, {:cancelled, %{}}}},
      writes: writes,
      conv_events: %{cid => %{entries: appended, doc_ops: %{"live" => [["replace", next_live]]}}},
      submissions: [],
      effects: effects,
      reply_from: nil,
      receipt: nil
    }

    {:batch, staged, state}
  end

  defp stage_generation_error(gen_task, cid, err, state, now) do
    retryable = Map.get(err, :retryable, false) == true
    retry_count = (gen_task.checkpoint["retry_count"] || 0) + 1

    cond do
      valid_wait_error?(err) ->
        {writes, next_live, effects, state} =
          schedule_inference_wait(gen_task, cid, state.docs[cid]["live"], state, now, err)

        staged = %{
          raw_item: {:worker_done, gen_task.id, :none, {:generation_result, {:error, err}}},
          writes: writes,
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [],
          effects: effects,
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}

      retryable and replay_inference?(gen_task) and retry_count <= state.retry_limit ->
        {writes, next_live, delay_ms, state} =
          schedule_inference_retry(
            gen_task,
            cid,
            state.docs[cid]["live"],
            retry_count,
            state,
            now,
            err
          )

        staged = %{
          raw_item: {:worker_done, gen_task.id, :none, {:generation_result, {:error, err}}},
          writes: writes,
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [],
          effects: [{:arm_wake_timer, gen_task.id, delay_ms}],
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}

      true ->
        failure = inference_failure(err, gen_task, state)

        done_task =
          Task.complete(gen_task, %{"status" => "unanswered", "reason" => "model_error"}, now)

        sub_ids = gen_task.checkpoint["submission_ids"] || []
        {sub_writes, state} = Submissions.settle(sub_ids, :unanswered, "model_error", state, now)

        next_live = %{
          "run_failure" => Map.put(failure, "reason", "model_error")
        }

        state =
          state
          |> State.put_task(done_task)
          |> State.put_doc(cid, "live", next_live)

        staged = %{
          raw_item: {:worker_done, gen_task.id, :none, {:generation_result, {:error, err}}},
          writes:
            [{:put_task, done_task}] ++
              sub_writes ++
              [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}],
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [],
          effects: [],
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}
    end
  end

  defp stage_compaction_success(comp_task, cid, result, state, now) do
    {:ok, entries, state} = State.load_visible_entries(state, cid)

    case List.last(entries) do
      %{kind: "compaction", id: existing_entry_id} ->
        done_task =
          Task.complete(
            comp_task,
            %{"status" => "done", "entry_id" => existing_entry_id},
            now
          )

        sub_ids = comp_task.checkpoint["submission_ids"] || []
        {sub_writes, state} = Submissions.settle(sub_ids, :done, existing_entry_id, state, now)

        next_live = Map.delete(state.docs[cid]["live"] || %{}, "compaction")

        state =
          state
          |> State.put_task(done_task)
          |> State.put_doc(cid, "live", next_live)

        writes =
          [{:put_task, done_task}] ++
            sub_writes ++
            [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

        staged = %{
          raw_item: {:worker_done, comp_task.id, :none, {:compaction_result, {:ok, result}}},
          writes: writes,
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [],
          effects: [],
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}

      _ ->
        {:ok, entry_id, store} = Storage.mint_id(state.store)
        state = %{state | store: store}

        entry_data = Compaction.entry_data(result)
        entry = State.build_entry(entry_id, cid, "compaction", entry_data, now)
        state = State.record_entry(state, cid, entry_id)

        usage_map = State.stringify_json(Map.get(result, :usage, %{}))
        {next_usage, usage_ops} = Document.accumulate_usage(state.docs[cid]["usage"], usage_map)
        state = State.put_doc(state, cid, "usage", next_usage)

        usage_writes =
          if usage_ops == [],
            do: [],
            else: [{:put_doc, {:conversation, cid, "usage"}, Document.wrap("usage", next_usage)}]

        done_task =
          Task.complete(
            comp_task,
            %{
              "status" => "done",
              "entry_id" => entry_id,
              "kept_from_id" => result.kept_from_id
            },
            now
          )

        sub_ids = comp_task.checkpoint["submission_ids"] || []
        automatic? = comp_task.checkpoint["automatic"] == true

        {sub_writes, state} =
          if automatic?,
            do: {[], state},
            else: Submissions.settle(sub_ids, :done, entry_id, state, now)

        state = State.put_task(state, done_task)

        {drained_entries, drained_sub_writes, next_sub_ids, inbox_ops, state} =
          Submissions.drain_inbox(cid, state, now, if(automatic?, do: "steer", else: nil))

        next_sub_ids = if automatic?, do: sub_ids ++ next_sub_ids, else: next_sub_ids

        {next_run_writes, next_live, next_effects, state} =
          if drained_entries == [] and not automatic? do
            live = Map.delete(state.docs[cid]["live"] || %{}, "compaction")
            {[], live, [], State.put_doc(state, cid, "live", live)}
          else
            {next_gen, live, state} =
              Submissions.start_pending_generation(cid, next_sub_ids, state, now)

            {[{:put_task, next_gen}], live, [{:spawn_generation, cid, next_gen.id}], state}
          end

        all_entries = [entry | drained_entries]

        writes =
          Enum.map(all_entries, &{:append_entry, &1}) ++
            usage_writes ++
            sub_writes ++
            drained_sub_writes ++
            [{:put_task, done_task}] ++
            next_run_writes ++
            [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}] ++
            if(inbox_ops == [],
              do: [],
              else: [
                {:put_doc, {:conversation, cid, "inbox"},
                 Document.wrap("inbox", state.docs[cid]["inbox"])}
              ]
            )

        doc_ops =
          %{"live" => [["replace", next_live]]}
          |> then(fn m -> if usage_ops == [], do: m, else: Map.put(m, "usage", usage_ops) end)
          |> then(fn m -> if inbox_ops == [], do: m, else: Map.put(m, "inbox", inbox_ops) end)

        staged = %{
          raw_item: {:worker_done, comp_task.id, :none, {:compaction_result, {:ok, result}}},
          writes: writes,
          conv_events: %{cid => %{entries: all_entries, doc_ops: doc_ops}},
          submissions: [],
          effects: next_effects,
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}
    end
  end

  defp inference_failure(error, task, state) do
    count = task.checkpoint["retry_count"] || 0

    {default_code, default_message} =
      if task.kind == "compaction",
        do: {"compaction_error", "Compaction failed"},
        else: {"model_error", "Model error"}

    message = H.Credentials.sanitize(to_string(Map.get(error, :message, default_message)))

    message =
      if error[:retryable] == true and replay_inference?(task) and count >= state.retry_limit do
        action =
          if task.kind == "compaction" and task.checkpoint["automatic"] != true,
            do: "retry /compact",
            else: "continue"

        message <>
          " Automatic retries exhausted (#{count}/#{state.retry_limit}). Resolve the provider restriction, then #{action}; history is preserved."
      else
        message
      end

    %{
      "code" => to_string(Map.get(error, :code, default_code)),
      "message" => message,
      "retry_count" => count
    }
  end

  defp stage_compaction_error(comp_task, cid, err, state, now) do
    retryable = Map.get(err, :retryable, false) == true
    retry_count = (comp_task.checkpoint["retry_count"] || 0) + 1
    live = state.docs[cid]["live"] || %{}

    cond do
      valid_wait_error?(err) ->
        {writes, next_live, effects, state} =
          schedule_inference_wait(comp_task, cid, live, state, now, err)

        staged = %{
          raw_item: {:worker_done, comp_task.id, :none, {:compaction_result, {:error, err}}},
          writes: writes,
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [],
          effects: effects,
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}

      retryable and replay_inference?(comp_task) and retry_count <= state.retry_limit ->
        {writes, next_live, delay_ms, state} =
          schedule_inference_retry(comp_task, cid, live, retry_count, state, now, err)

        staged = %{
          raw_item: {:worker_done, comp_task.id, :none, {:compaction_result, {:error, err}}},
          writes: writes,
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [],
          effects: [{:arm_wake_timer, comp_task.id, delay_ms}],
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}

      true ->
        failure = inference_failure(err, comp_task, state)
        code = failure["code"]
        message = failure["message"]

        done_task =
          Task.complete(comp_task, %{"status" => "unanswered", "reason" => code}, now)

        sub_ids = comp_task.checkpoint["submission_ids"] || []
        {sub_writes, state} = Submissions.settle(sub_ids, :unanswered, code, state, now)

        next_live =
          compaction_failure(live, comp_task, code, message)
          |> update_in(["compaction_failure"], &Map.merge(&1, failure))

        state =
          state
          |> State.put_task(done_task)
          |> State.put_doc(cid, "live", next_live)

        staged = %{
          raw_item: {:worker_done, comp_task.id, :none, {:compaction_result, {:error, err}}},
          writes:
            [{:put_task, done_task}] ++
              sub_writes ++
              [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}],
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [],
          effects: [],
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}
    end
  end
end
