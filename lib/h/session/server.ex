defmodule H.Session.Server do
  @moduledoc """
  Single mutation authority and durable coordinator for one `H` session.

  Never blocks on LLM calls, tool execution, or slow SSE consumers. Groups
  ready mailbox mutations via drain-batch commits (`H.Storage.commit/2`),
  fences effect workers by `{incarnation, task_id, attempt_id}`, and broadcasts
  single-encoded `ProcBin` commit and ephemeral frames via `H.PubSub`.
  """

  use GenServer

  require Logger

  alias H.Storage
  alias H.Session.{Subagents, UserShell}

  alias H.Session.Server.{
    Commands,
    Generation,
    Recovery,
    State,
    Stream,
    Submissions,
    Tools,
    WorkspaceWait
  }

  @max_drain 31

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @spec get_detail(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def get_detail(server) do
    GenServer.call(server, :get_detail)
  end

  @spec get_seq(GenServer.server()) :: {:ok, non_neg_integer()}
  def get_seq(server) do
    GenServer.call(server, :get_seq)
  end

  @spec scan_entries(GenServer.server(), pos_integer(), map()) ::
          {:ok, %{items: [map()], next_cursor: nil | pos_integer()}} | {:error, term()}
  def scan_entries(server, cid, query \\ %{}) when is_integer(cid) and is_map(query) do
    GenServer.call(server, {:scan_entries, cid, query})
  end

  @spec snapshot_or_replay(GenServer.server(), pos_integer(), nil | non_neg_integer()) ::
          {:ok,
           {:snapshot, non_neg_integer(), binary()} | {:replay, [{non_neg_integer(), binary()}]}}
          | {:error, term()}
  def snapshot_or_replay(server, cid, last_event_id) when is_integer(cid) do
    GenServer.call(server, {:snapshot_or_replay, cid, last_event_id})
  end

  @spec get_submission_outcome(GenServer.server(), String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_submission_outcome(server, request_id) when is_binary(request_id) do
    GenServer.call(server, {:get_submission_outcome, request_id})
  end

  @spec verify_visible_entry(GenServer.server(), pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, :not_found | :entry_not_visible}
  def verify_visible_entry(server, cid, entry_id)
      when is_integer(cid) and is_integer(entry_id) do
    GenServer.call(server, {:verify_visible_entry, cid, entry_id})
  end

  @spec execute_command(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def execute_command(server, cmd) when is_map(cmd) do
    GenServer.call(server, {:command, cmd}, 30_000)
  end

  @spec abort_all(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def abort_all(server, reason \\ "stopped") when is_binary(reason) do
    GenServer.call(server, {:abort_all, reason}, 30_000)
  end

  @spec export_branch(GenServer.server(), pos_integer(), nil | pos_integer()) ::
          {:ok, %{entries: [map()], agent: map()}} | {:error, term()}
  def export_branch(server, cid, at_entry_id \\ nil)
      when is_integer(cid) and (is_nil(at_entry_id) or is_integer(at_entry_id)) do
    GenServer.call(server, {:export_branch, cid, at_entry_id}, 30_000)
  end

  @spec seed_entries(GenServer.server(), [map()], pos_integer()) ::
          {:ok, %{seeded: non_neg_integer(), seq: non_neg_integer()}} | {:error, term()}
  def seed_entries(server, entries, cid \\ 1) when is_list(entries) and is_integer(cid) do
    GenServer.call(server, {:seed_entries, cid, entries}, 30_000)
  end

  @spec close(GenServer.server(), term()) :: :ok
  def close(server, reason \\ :shutdown) do
    GenServer.stop(server, reason)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    # OTP shutdown must pass through terminate/2 to persist the clean-close policy.
    Process.flag(:trap_exit, true)
    session_id = Keyword.fetch!(opts, :session_id)
    storage_mod = Keyword.get(opts, :storage_mod, H.Storage.File)
    storage_opts = Recovery.build_storage_opts(opts, session_id)

    case Storage.open(storage_mod, storage_opts) do
      {:error, reason} ->
        {:stop, {:shutdown, {:storage_failed, reason}}}

      {:ok, store} ->
        case Recovery.init_from_store(store, opts, session_id) do
          {:ok, state, effects} ->
            state = apply_effects_list(effects, state)
            State.report_catalog_active(state)
            {:ok, state}

          {:error, reason} ->
            Storage.close(store)
            {:stop, {:shutdown, {:storage_failed, reason}}}
        end
    end
  end

  @impl true
  def handle_call(:get_detail, _from, state) do
    detail = %{
      session_meta: state.session_meta,
      seq: state.seq,
      cwd_exists: State.cwd_available?(state),
      conversations: state.conversations |> Map.values() |> Enum.sort_by(& &1.id),
      tasks: state.tasks |> Map.values() |> Enum.sort_by(& &1.id)
    }

    {:reply, {:ok, detail}, state}
  end

  def handle_call(:idle, _from, state), do: {:reply, not State.session_active?(state), state}

  def handle_call(:drained, _from, state), do: {:reply, map_size(state.workers) == 0, state}

  def handle_call(:active_worker_count, _from, state),
    do: {:reply, map_size(state.workers), state}

  def handle_call(:max_worker_remaining_ms, _from, state) do
    now_mono = System.monotonic_time(:millisecond)

    remaining =
      state.workers
      |> Map.values()
      |> Enum.reduce(0, fn worker, acc ->
        case Map.get(worker, :deadline_mono_ms) do
          deadline when is_integer(deadline) -> max(acc, max(0, deadline - now_mono))
          _ -> acc
        end
      end)

    {:reply, remaining, state}
  end

  def handle_call(:get_seq, _from, state) do
    {:reply, {:ok, state.seq}, state}
  end

  def handle_call({:scan_entries, cid, query}, _from, state) do
    if Map.has_key?(state.conversations, cid) do
      full_query = Map.put(query, :conversation_id, cid)

      case Storage.scan_entries(state.store, full_query) do
        {:ok, page, next_store} ->
          {:reply, {:ok, page}, %{state | store: next_store}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:snapshot_or_replay, cid, last_event_id}, _from, state) do
    if Map.has_key?(state.conversations, cid) do
      case Stream.snapshot_or_replay(state, cid, last_event_id) do
        {:ok, payload, next_state} -> {:reply, {:ok, payload}, next_state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get_submission_outcome, request_id}, _from, state) do
    case Submissions.lookup(state, request_id) do
      {:not_found, next_state} ->
        {:reply, {:error, :not_found}, next_state}

      {:ok, sub, next_state} ->
        {outcome, final_state} = Stream.build_submission_outcome(next_state, sub)
        {:reply, {:ok, outcome}, final_state}
    end
  end

  def handle_call({:verify_visible_entry, cid, entry_id}, _from, state) do
    if Map.has_key?(state.conversations, cid) do
      case State.verify_visible_entry(state, cid, entry_id) do
        {:ok, entry, next_state} ->
          {:reply, {:ok, entry}, next_state}

        {:error, :entry_not_visible, next_state} ->
          {:reply, {:error, :entry_not_visible}, next_state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:command, cmd}, from, state) do
    process_with_drain({:command, from, cmd}, state)
  end

  def handle_call({:abort_all, reason}, from, state) do
    process_with_drain({:abort_all, from, reason}, state)
  end

  def handle_call({:seed_entries, cid, entries}, from, state) do
    process_with_drain({:seed_entries, from, cid, entries}, state)
  end

  def handle_call({:export_branch, cid, at_entry_id}, _from, state) do
    if Map.has_key?(state.conversations, cid) do
      case do_export_branch(state, cid, at_entry_id) do
        {:ok, payload, next_state} -> {:reply, {:ok, payload}, next_state}
        {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:worker_done, inc, tid, attempt_id, result}, state) do
    if inc == state.incarnation and Map.has_key?(state.workers, attempt_id) do
      process_with_drain({:worker_done, tid, attempt_id, result}, state)
    else
      {:noreply, state}
    end
  end

  def handle_info({:gen_chunk, inc, tid, attempt_id, cid, event}, state) do
    if inc == state.incarnation and Map.has_key?(state.workers, attempt_id) do
      {:noreply, Stream.handle_gen_chunk(state, cid, tid, event)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:tool_output, inc, tid, attempt_id, cid, call_id, chunk}, state) do
    if inc == state.incarnation and Map.has_key?(state.workers, attempt_id) do
      {:noreply, Stream.handle_tool_output(state, cid, tid, call_id, chunk)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:user_shell_output, inc, tid, attempt_id, cid, chunk}, state) do
    if inc == state.incarnation and Map.has_key?(state.workers, attempt_id) do
      {:noreply, UserShell.handle_output(state, cid, tid, chunk)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:emit_ephemeral, cid}, state) do
    {:noreply, Stream.flush_ephemeral_broadcast(state, cid)}
  end

  def handle_info({:flush_live, cid}, state) do
    process_with_drain({:flush_live, cid}, state)
  end

  def handle_info({:wake_task, tid}, state) do
    process_with_drain({:wake_task, tid}, state)
  end

  def handle_info({:wait_signal, topic}, state) when is_binary(topic) do
    process_with_drain({:wait_signal, topic}, state)
  end

  def handle_info({:submission_settled, outcome}, state) do
    process_with_drain({:submission_settled, outcome}, state)
  end

  def handle_info({:subagent_failed, tid, reason}, state) do
    process_with_drain({:subagent_failed, tid, reason}, state)
  end

  def handle_info({:workspace_lease_granted, token}, state) do
    {effects, state} = WorkspaceWait.granted(token, state)
    {:noreply, apply_effects_list(effects, state)}
  end

  def handle_info({:workspace_lease_blocked, token, holder, lease_id}, state) do
    {:noreply, WorkspaceWait.blocked(token, holder, lease_id, state)}
  end

  def handle_info({:stop_workspace_holder, cwd, holder, lease_id}, state) do
    process_with_drain({:stop_workspace_holder, cwd, holder, lease_id}, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case State.find_worker_by_monitor(state.workers, ref) do
      nil ->
        {:noreply, state}

      {attempt_id, worker} ->
        if reason in [:normal, :shutdown] do
          {:noreply, %{state | workers: Map.delete(state.workers, attempt_id)}}
        else
          process_with_drain({:worker_crashed, worker.task_id, attempt_id, reason}, state)
        end
    end
  end

  def handle_info(:enter_drain, state) do
    Enum.each(state.wake_timers, fn {_tid, ref} -> Process.cancel_timer(ref) end)
    {:noreply, %{state | wake_timers: %{}}}
  end

  def handle_info({:stop_storage_failed, io_err}, state) do
    {:stop, {:shutdown, {:storage_failed, io_err}}, %{state | storage_failed: true}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    State.terminate_all_workers(state)
    State.release_all_leases(state)

    if Recovery.clean_shutdown_reason?(reason) and not state.storage_failed do
      Recovery.persist_clean_close(state)
    end

    Storage.close(state.store)
    :ok
  end

  # Drain-batch execution loop

  defp process_with_drain(first_item, state) do
    items = [first_item | drain_mailbox(@max_drain, [])]
    run_items(items, state)
  end

  defp drain_mailbox(0, acc), do: Enum.reverse(acc)

  defp drain_mailbox(remaining, acc) do
    receive do
      {:"$gen_call", from, {:command, cmd}} ->
        drain_mailbox(remaining - 1, [{:command, from, cmd} | acc])

      {:worker_done, inc, tid, attempt_id, result} ->
        drain_mailbox(remaining - 1, [{:worker_done_fenced, inc, tid, attempt_id, result} | acc])

      {:flush_live, cid} ->
        drain_mailbox(remaining - 1, [{:flush_live, cid} | acc])

      {:wake_task, tid} ->
        drain_mailbox(remaining - 1, [{:wake_task, tid} | acc])

      {:wait_signal, topic} when is_binary(topic) ->
        drain_mailbox(remaining - 1, [{:wait_signal, topic} | acc])

      {:submission_settled, outcome} ->
        drain_mailbox(remaining - 1, [{:submission_settled, outcome} | acc])

      {:subagent_failed, tid, reason} ->
        drain_mailbox(remaining - 1, [{:subagent_failed, tid, reason} | acc])
    after
      0 ->
        Enum.reverse(acc)
    end
  end

  defp run_items([], state), do: {:noreply, state}

  defp run_items(items, state) do
    {staged_items, immediate_replies, post_effects, working_state, deferred_items} =
      stage_items(items, state, [], [], [])

    batches = Enum.map(staged_items, & &1.writes)

    if batches == [] do
      Enum.each(immediate_replies, fn {from, reply} -> GenServer.reply(from, reply) end)
      final_state = apply_effects_list(post_effects, working_state)
      {:noreply, final_state}
    else
      case Storage.commit(working_state.store, batches) do
        {:error, io_err} ->
          Logger.error("Session #{state.session_id} storage commit failed: #{inspect(io_err)}")
          {:stop, {:shutdown, {:storage_failed, io_err}}, %{state | storage_failed: true}}

        {:ok, %{stored: stored, seqs: seqs, refused: refused}, committed_store} ->
          {accepted_staged, rest_staged} = Enum.split(staged_items, stored)

          state_after_accepted =
            Stream.apply_committed_batches(accepted_staged, seqs, %{
              working_state
              | store: committed_store
            })

          if accepted_staged != [] and is_nil(refused) do
            State.maybe_report_catalog_runtime(state, state_after_accepted)
          end

          Stream.reply_committed_batches(accepted_staged, seqs)
          Enum.each(immediate_replies, fn {from, reply} -> GenServer.reply(from, reply) end)

          accepted_effects = Enum.flat_map(accepted_staged, & &1.effects) ++ post_effects
          state_after_effects = apply_effects_list(accepted_effects, state_after_accepted)

          if accepted_staged == [] or not is_nil(refused) do
            State.maybe_report_catalog_runtime(state, state_after_effects)
          else
            State.maybe_report_catalog_runtime(state_after_accepted, state_after_effects)
          end

          case refused do
            nil ->
              run_items(deferred_items, state_after_effects)

            {_idx, reason} ->
              [refused_item | remaining_staged] = rest_staged

              if refused_item.reply_from do
                GenServer.reply(
                  refused_item.reply_from,
                  {:error, Submissions.map_storage_refusal(reason)}
                )
              end

              remaining_items = Enum.map(remaining_staged, & &1.raw_item) ++ deferred_items
              run_items(remaining_items, state_after_effects)
          end
      end
    end
  end

  defp stage_items([], state, staged_rev, replies_rev, effects_rev) do
    {Enum.reverse(staged_rev), Enum.reverse(replies_rev), Enum.reverse(effects_rev), state, []}
  end

  defp stage_items(
         [{:command, _from, %{request_id: req_id, args: args}} = item | rest] = all,
         state,
         staged_rev,
         replies_rev,
         effects_rev
       ) do
    if staged_request_id?(staged_rev, req_id) or
         (staged_rev != [] and Map.get(args, :expected_seq) != nil) do
      {Enum.reverse(staged_rev), Enum.reverse(replies_rev), Enum.reverse(effects_rev), state, all}
    else
      stage_next_item(item, rest, state, staged_rev, replies_rev, effects_rev)
    end
  end

  defp stage_items([item | rest], state, staged_rev, replies_rev, effects_rev) do
    stage_next_item(item, rest, state, staged_rev, replies_rev, effects_rev)
  end

  defp stage_next_item(item, rest, state, staged_rev, replies_rev, effects_rev) do
    case stage_single_item(item, state, staged_rev) do
      {:skip, next_state} ->
        stage_items(rest, next_state, staged_rev, replies_rev, effects_rev)

      {:immediate, reply_from, reply_val, effects, next_state} ->
        replies = if reply_from, do: [{reply_from, reply_val} | replies_rev], else: replies_rev
        stage_items(rest, next_state, staged_rev, replies, effects_rev ++ effects)

      {:batch, staged, next_state} ->
        stage_items(rest, next_state, [staged | staged_rev], replies_rev, effects_rev)
    end
  end

  defp staged_request_id?(staged_rev, req_id) do
    Enum.any?(staged_rev, fn staged ->
      Enum.any?(staged.submissions, &(&1.request_id == req_id))
    end)
  end

  defp stage_single_item({:worker_done_fenced, inc, tid, attempt_id, result}, state, staged_rev) do
    if inc == state.incarnation and Map.has_key?(state.workers, attempt_id) do
      stage_single_item({:worker_done, tid, attempt_id, result}, state, staged_rev)
    else
      {:skip, state}
    end
  end

  defp stage_single_item({:command, from, cmd}, state, staged_rev) do
    if state.maintenance_table &&
         not :ets.lookup_element(state.maintenance_table, :open, 2, false) do
      {:immediate, from, {:error, :daemon_draining}, [], state}
    else
      Commands.stage(from, cmd, state, staged_rev)
    end
  end

  defp stage_single_item({:stop_workspace_holder, cwd, holder, lease_id}, state, _staged_rev) do
    Commands.stage_stop_workspace_holder(cwd, holder, lease_id, state)
  end

  defp stage_single_item({:abort_all, from, reason}, state, _staged_rev) do
    if state.maintenance_table &&
         not :ets.lookup_element(state.maintenance_table, :open, 2, false) do
      {:immediate, from, {:error, :daemon_draining}, [], state}
    else
      Commands.stage_abort_all(from, reason, state)
    end
  end

  defp stage_single_item({:seed_entries, from, cid, entries}, state, _staged_rev) do
    if state.maintenance_table &&
         not :ets.lookup_element(state.maintenance_table, :open, 2, false) do
      {:immediate, from, {:error, :daemon_draining}, [], state}
    else
      Commands.stage_seed_entries(from, cid, entries, state)
    end
  end

  defp stage_single_item(
         {:worker_done, tid, attempt_id, {:generation_result, _} = result},
         state,
         _staged_rev
       ) do
    Generation.stage_done(tid, attempt_id, result, state)
  end

  defp stage_single_item(
         {:worker_done, tid, attempt_id, {:compaction_result, _} = result},
         state,
         _staged_rev
       ) do
    Generation.stage_done(tid, attempt_id, result, state)
  end

  defp stage_single_item(
         {:worker_done, tid, attempt_id, {:tool_result, _, _} = result},
         state,
         _staged_rev
       ) do
    Tools.stage_done(tid, attempt_id, result, state)
  end

  defp stage_single_item(
         {:worker_done, tid, attempt_id, {:user_shell_result, _, _} = result},
         state,
         _staged_rev
       ) do
    Commands.stage_user_shell_done(tid, attempt_id, result, state)
  end

  defp stage_single_item({:worker_crashed, tid, attempt_id, reason}, state, _staged_rev) do
    Recovery.stage_worker_crashed(tid, attempt_id, reason, state)
  end

  defp stage_single_item({:flush_live, cid}, state, _staged_rev) do
    Stream.stage_flush_live(cid, state)
  end

  defp stage_single_item({:wake_task, tid}, state, _staged_rev) do
    if State.draining?(state) do
      {:skip, state}
    else
      Generation.stage_wake(tid, state)
    end
  end

  defp stage_single_item({:wait_signal, topic}, state, _staged_rev) do
    if State.draining?(state) do
      {:skip, state}
    else
      Generation.stage_wait_signal(topic, state)
    end
  end

  defp stage_single_item({:submission_settled, outcome}, state, _staged_rev) do
    Subagents.stage_settled(outcome, state)
  end

  defp stage_single_item({:subagent_failed, tid, reason}, state, _staged_rev) do
    Subagents.stage_failed(tid, reason, state)
  end

  # Effect execution (runs AFTER commit succeeds!)

  defp apply_effects_list([], state), do: state

  defp apply_effects_list([effect | rest], state) do
    next_state = apply_effect(effect, state)
    apply_effects_list(rest, next_state)
  end

  defp apply_effect({:spawn_generation, cid, tid}, state) do
    if State.draining?(state),
      do: state,
      else: Generation.spawn_generation_worker(cid, tid, state)
  end

  defp apply_effect({:spawn_tool, cid, tid}, state) do
    if State.draining?(state),
      do: state,
      else: Tools.spawn_worker(cid, tid, state, &apply_effects_list/2)
  end

  defp apply_effect({:spawn_user_shell, cid, tid}, state) do
    case Map.get(state.tasks, tid) do
      %{checkpoint: %{"phase" => "workspace_wait"}} ->
        if State.draining?(state), do: state, else: UserShell.spawn_worker(cid, tid, state)

      _ ->
        UserShell.spawn_worker(cid, tid, state)
    end
  end

  defp apply_effect({:spawn_compaction, cid, tid}, state) do
    if State.draining?(state),
      do: state,
      else: Generation.spawn_compaction_worker(cid, tid, state)
  end

  defp apply_effect({:arm_wake_timer, tid, delay_ms}, state) do
    if State.draining?(state) do
      cancel_wake_timer(tid, state)
    else
      state = cancel_wake_timer(tid, state)
      ref = Process.send_after(self(), {:wake_task, tid}, delay_ms)
      %{state | wake_timers: Map.put(state.wake_timers, tid, ref)}
    end
  end

  defp apply_effect({:cancel_wake_timer, tid}, state) do
    cancel_wake_timer(tid, state)
  end

  defp apply_effect({:watch_wait_signal, topic}, state) do
    if Generation.valid_wait_topic?(topic) do
      if MapSet.member?(state.wait_watches, topic) do
        state
      else
        if state.pubsub && Process.whereis(state.pubsub) do
          Registry.register(state.pubsub, {:wait_signal, topic}, nil)
        end

        state = %{state | wait_watches: MapSet.put(state.wait_watches, topic)}
        maybe_wake_if_wait_signal_ready(topic, state)
        state
      end
    else
      state
    end
  end

  defp apply_effect({:maybe_unwatch_wait_signal, topic}, state) do
    if is_binary(topic) and MapSet.member?(state.wait_watches, topic) and
         not has_wait_task?(state, topic) do
      if state.pubsub && Process.whereis(state.pubsub) do
        Registry.unregister(state.pubsub, {:wait_signal, topic})
      end

      %{state | wait_watches: MapSet.delete(state.wait_watches, topic)}
    else
      state
    end
  end

  defp apply_effect({:kill_worker, attempt_id, pid, ref}, state) do
    Process.demonitor(ref, [:flush])
    worker = state.workers[attempt_id]
    if worker && worker[:abort_ref], do: send(pid, {:abort_exec, worker.abort_ref})
    State.terminate_worker_pid(state.task_sup, pid)
    %{state | workers: Map.delete(state.workers, attempt_id)}
  end

  defp apply_effect({:stop_workspace_holder, cid, task_id, lease_id}, state) do
    WorkspaceWait.stop_holder(cid, task_id, lease_id, state)
  end

  defp apply_effect({:release_lease, cid}, state) do
    State.release_lease(cid, state)
  end

  defp apply_effect({:resume_subagent, cid, tid}, state) do
    Subagents.resume_waiting(cid, tid, state)
  end

  defp apply_effect({:unwatch_subagent, child_sid, child_req_id}, state) do
    Subagents.unwatch(child_sid, child_req_id, state)
  end

  defp apply_effect({:abort_subagent, child_sid, child_cid, reason}, state) do
    Subagents.abort_child(child_sid, child_cid, reason, state)
  end

  defp cancel_wake_timer(tid, state) do
    case Map.pop(state.wake_timers, tid) do
      {nil, _timers} ->
        state

      {ref, timers} ->
        Process.cancel_timer(ref)
        %{state | wake_timers: timers}
    end
  end

  defp has_wait_task?(state, topic) do
    Enum.any?(state.tasks, fn {_id, task} ->
      task.status == "sleeping" and
        get_in(task.wake, ["reason"]) == "wait" and
        get_in(task.wake, ["topic"]) == topic
    end)
  end

  defp maybe_wake_if_wait_signal_ready("account_policy:openai_codex" = topic, state) do
    case state.provider_config[:codex_account_policy] do
      %{module: mod, sources: sources} when is_atom(mod) and is_list(sources) ->
        model = state.default_model || "openai_codex:gpt-6.2-sol"

        ordered =
          try do
            mod.order(model, sources)
          rescue
            _ -> []
          catch
            _, _ -> []
          end

        if is_list(ordered) and ordered != [] do
          send(self(), {:wait_signal, topic})
        end

      _ ->
        :ok
    end
  end

  defp maybe_wake_if_wait_signal_ready(_topic, _state), do: :ok

  defp do_export_branch(state, cid, nil) do
    {:ok, entries, state} = State.load_visible_entries(state, cid)
    agent = get_in(state.docs, [cid, "agent"]) || %{}
    {:ok, %{entries: entries, agent: agent}, state}
  end

  defp do_export_branch(state, cid, at_entry_id) do
    case State.verify_visible_entry(state, cid, at_entry_id) do
      {:ok, at_entry, state} ->
        {:ok, all_entries, state} = State.load_visible_entries(state, cid)
        prefix = Enum.filter(all_entries, &(&1.id <= at_entry_id))

        case H.Document.fork_docs(state.store, cid, at_entry.seq,
               default_model: state.default_model
             ) do
          {:ok, fork_docs, next_store} ->
            {:ok, %{entries: prefix, agent: fork_docs["agent"]}, %{state | store: next_store}}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, :entry_not_visible, state} ->
        {:error, {:bad_request, "entry_not_visible"}, state}
    end
  end
end
