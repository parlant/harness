defmodule H.Session.Server.Recovery do
  @moduledoc """
  Session store bootstrap, open-time checkpoint reconciliation, worker crash
  recovery, restart-budget enforcement, and clean-shutdown persistence for
  `H.Session.Server`.
  """

  alias H.{Document, Storage, Submission, Task}
  alias H.Session.UserShell
  alias H.Session.Server.{Generation, State, Stream, Submissions, Tools}

  @default_persist_within_ms 1_000
  @default_ephemeral_interval_ms 50
  @default_retry_limit 3
  @default_retry_backoff_ms 2_000
  @default_restart_limit 5

  @default_tools [
    H.Tools.Read,
    H.Tools.Write,
    H.Tools.Edit,
    H.Tools.Bash,
    H.Tools.SearchHistory
  ]

  @default_max_subagent_depth 1

  def build_storage_opts(opts, session_id) do
    storage_mod = Keyword.get(opts, :storage_mod, H.Storage.File)
    base_opts = Keyword.get(opts, :storage_opts, [])

    base_opts =
      if storage_mod == H.Storage.File and not Keyword.has_key?(base_opts, :dir) do
        data_dir = Keyword.fetch!(opts, :data_dir)
        Keyword.put(base_opts, :dir, Path.join([Path.expand(data_dir), "sessions", session_id]))
      else
        base_opts
      end

    base_opts = Keyword.put_new(base_opts, :session_id, session_id)

    case Keyword.get(opts, :cwd) do
      nil -> base_opts
      cwd -> Keyword.put(base_opts, :cwd, cwd)
    end
  end

  def init_from_store(store, opts, session_id) do
    with {:ok, bootstrap, store} <- Storage.read_bootstrap(store) do
      meta = bootstrap.session_meta || %{}
      cwd = Keyword.get(opts, :cwd) || Map.get(meta, :cwd) || Map.get(meta, "cwd")
      execution_env = Keyword.get(opts, :execution_env) || H.ExecutionEnv.Local.new(cwd)

      env_id =
        Keyword.get(opts, :env_id) ||
          Map.get(meta, :env_id) ||
          Map.get(meta, "env_id") ||
          H.ExecutionEnv.env_id(execution_env)

      initial_title =
        cond do
          Map.has_key?(meta, :title) -> Map.get(meta, :title)
          Map.has_key?(meta, "title") -> Map.get(meta, "title")
          true -> Keyword.get(opts, :title)
        end

      title_explicit =
        Map.get(meta, :title_explicit, Map.get(meta, "title_explicit", false)) == true

      parent =
        cond do
          Map.has_key?(meta, :parent) -> Map.get(meta, :parent)
          Map.has_key?(meta, "parent") -> Map.get(meta, "parent")
          true -> Keyword.get(opts, :parent)
        end

      role =
        cond do
          Map.has_key?(meta, :role) -> Map.get(meta, :role)
          Map.has_key?(meta, "role") -> Map.get(meta, "role")
          true -> Keyword.get(opts, :role)
        end

      prev_clean = Map.get(meta, :clean_close, Map.get(meta, "clean_close"))
      prev_inc = Map.get(meta, :incarnation, Map.get(meta, "incarnation", 0)) || 0
      incarnation = prev_inc + 1
      now = System.system_time(:millisecond)

      depth = get_in(parent, [:depth]) || get_in(parent, ["depth"]) || 0
      max_subagent_depth = Keyword.get(opts, :max_subagent_depth, @default_max_subagent_depth)

      default_tools =
        if depth < max_subagent_depth do
          @default_tools ++ [H.Tools.Subagent]
        else
          @default_tools
        end

      tools = State.resolve_tools(Keyword.get(opts, :tools, default_tools))
      provider_mod = Keyword.get(opts, :provider, H.Provider.ReqLLM)
      provider_config = Keyword.get(opts, :provider_config, %{})

      daemon_opts =
        opts
        |> Keyword.take([
          :registry,
          :pubsub,
          :catalog,
          :catalog_table,
          :workspace_lease,
          :runtime_sup,
          :storage_mod,
          :storage_opts,
          :data_dir,
          :maintenance_table,
          :provider,
          :provider_config,
          :default_model,
          :environments,
          :harnesses,
          :max_subagent_depth,
          :max_subagent_depth_hard,
          :explicit_tools,
          :persist_within_ms,
          :ephemeral_interval_ms,
          :retry_limit,
          :retry_backoff_ms,
          :restart_limit,
          :auto_compaction,
          :compaction_keep_recent_chars,
          :compaction_max_tokens,
          :max_restarts,
          :max_seconds
        ])

      default_model =
        resolve_default_model(Keyword.get(opts, :default_model), provider_mod, provider_config)

      initial_agent = Keyword.get(opts, :initial_agent)

      conversations =
        bootstrap.conversations || %{1 => %{id: 1, parent: nil, owner: :ownerless, entry_ids: []}}

      tasks = Map.new(bootstrap.tasks || %{}, fn {id, t} -> {id, Task.from_storage(t)} end)
      docs = build_docs_map(conversations, bootstrap.docs || %{}, default_model)

      {docs, init_doc_writes} =
        ensure_initial_docs_writes(
          conversations,
          bootstrap.docs || %{},
          docs,
          initial_agent,
          default_model
        )

      recent_subs =
        Map.new(bootstrap.submissions || %{}, fn {rid, s} -> {rid, Submission.from_storage(s)} end)

      state = %{
        session_id: session_id,
        env_id: env_id,
        cwd: cwd,
        store: store,
        seq: bootstrap.seq || 0,
        incarnation: incarnation,
        session_meta:
          meta
          |> Map.delete("title")
          |> Map.delete("title_explicit")
          |> Map.delete("env_id")
          |> Map.delete("parent")
          |> Map.delete("role")
          |> Map.merge(%{
            session_id: session_id,
            env_id: env_id,
            cwd: cwd,
            title: initial_title,
            title_explicit: title_explicit,
            parent: parent,
            role: role,
            incarnation: incarnation,
            clean_close: false
          }),
        conversations: conversations,
        tasks: tasks,
        docs: docs,
        recent_submissions: recent_subs,
        workers: %{},
        subagent_watches: %{},
        pool_watches: MapSet.new(),
        wake_timers: %{},
        ephemeral: %{},
        held_leases: %{},
        workspace_waits: %{},
        replay_rings: %{},
        ring_base_seq: %{},
        conv_last_seq: Map.new(Map.keys(conversations), fn cid -> {cid, bootstrap.seq || 0} end),
        storage_failed: false,
        registry: Keyword.get(opts, :registry, H.Registry),
        pubsub: Keyword.get(opts, :pubsub, H.PubSub),
        catalog: Keyword.get(opts, :catalog, H.Catalog),
        catalog_table: Keyword.get(opts, :catalog_table, :h_catalog),
        runtime_sup: Keyword.get(opts, :runtime_sup, H.Session.RuntimeSupervisor),
        task_sup: Keyword.fetch!(opts, :task_sup),
        workspace_lease: Keyword.get(opts, :workspace_lease, H.WorkspaceLease),
        provider_mod: provider_mod,
        provider_config: provider_config,
        execution_env: execution_env,
        tools: tools,
        max_subagent_depth: max_subagent_depth,
        daemon_opts: daemon_opts,
        default_model: default_model,
        persist_within_ms: Keyword.get(opts, :persist_within_ms, @default_persist_within_ms),
        ephemeral_interval_ms:
          Keyword.get(opts, :ephemeral_interval_ms, @default_ephemeral_interval_ms),
        maintenance_table: opts[:maintenance_table],
        retry_limit: Keyword.get(opts, :retry_limit, @default_retry_limit),
        retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, @default_retry_backoff_ms),
        restart_limit: Keyword.get(opts, :restart_limit, @default_restart_limit),
        auto_compaction: Keyword.get(opts, :auto_compaction, %{}),
        compaction_keep_recent_chars: Keyword.get(opts, :compaction_keep_recent_chars, 20_000),
        compaction_max_tokens: Keyword.get(opts, :compaction_max_tokens, 16_384)
      }

      base_meta_write = {:put_session_meta, state.session_meta}

      {recovery_writes, recovered_state, recovery_effects} =
        reconcile_on_open(state, prev_clean, now)

      all_writes = [base_meta_write | init_doc_writes] ++ recovery_writes

      case Storage.commit(recovered_state.store, [all_writes]) do
        {:ok, %{seqs: [batch_seq]}, committed_store} ->
          conv_last_seq =
            Enum.reduce(
              Map.keys(recovered_state.conversations),
              recovered_state.conv_last_seq,
              fn cid, acc ->
                if Map.get(acc, cid, 0) == 0, do: Map.put(acc, cid, batch_seq), else: acc
              end
            )

          final_state = %{
            recovered_state
            | store: committed_store,
              seq: batch_seq,
              conv_last_seq: conv_last_seq,
              ring_base_seq: conv_last_seq
          }

          final_state =
            Stream.broadcast_settled_submissions(final_state, recovery_writes, batch_seq)

          {:ok, final_state, recovery_effects}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def reconcile_on_open(state, clean?, now) do
    # Clean close leaves only potentially interrupted unsafe tools/user_shell running.
    # Do not charge those attempts against the restart budget.
    running_tasks =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn t ->
        t.status == "running" or
          (UserShell.unsafe_task?(t) and t.status == "pending" and
             t.checkpoint["phase"] != "workspace_wait")
      end)
      |> Enum.sort_by(& &1.id)

    {writes, next_state} =
      Enum.reduce(running_tasks, {[], state}, fn task, {acc_writes, acc_state} ->
        {w, st} =
          cond do
            UserShell.unsafe_task?(task) ->
              UserShell.recover_on_open(task, acc_state, now)

            clean? == true and Tools.unsafe_running_tool?(task) ->
              Tools.recover_unclean_tool_call(task, acc_state, now)

            true ->
              recover_unclean_task(task, acc_state, now)
          end

        {acc_writes ++ w, st}
      end)

    {round_writes, final_state, round_effects} = advance_ready_tool_rounds(next_state, now)
    effects = round_effects ++ collect_resume_effects(final_state)
    {writes ++ round_writes, final_state, effects}
  end

  def recover_unclean_task(task, state, now) do
    incremented = Task.increment_restart(task, now)

    if incremented.restarts > state.restart_limit do
      fail_task_restart_limit(incremented, state, now)
    else
      case incremented.kind do
        "generation" -> recover_unclean_generation(incremented, state, now)
        "compaction" -> recover_unclean_compaction(incremented, state, now)
        "tool_call" -> Tools.recover_unclean_tool_call(incremented, state, now)
        _ -> {[{:put_task, incremented}], State.put_task(state, incremented)}
      end
    end
  end

  def fail_task_restart_limit(task, state, now) do
    cid = task_conv_id(task, state)
    failed_task = Task.complete(task, %{"status" => "failed", "reason" => "restart_limit"}, now)
    state = State.put_task(state, failed_task)

    {parent_writes, state} =
      case task.owner do
        {:task, parent_id} ->
          case Map.get(state.tasks, parent_id) do
            nil ->
              {[], state}

            parent ->
              failed_parent =
                Task.complete(
                  parent,
                  %{"status" => "unanswered", "reason" => "restart_limit"},
                  now
                )

              {[{:put_task, failed_parent}], State.put_task(state, failed_parent)}
          end

        _ ->
          {[], state}
      end

    sub_ids = collect_run_submission_ids(task, state)
    {sub_writes, state} = Submissions.settle(sub_ids, :unanswered, "restart_limit", state, now)

    {live_writes, state} =
      if cid do
        live =
          if task.kind == "compaction" do
            Generation.compaction_failure(
              state.docs[cid]["live"],
              task,
              "restart_limit",
              "Compaction exceeded restart limit"
            )
          else
            state.docs[cid]["live"]
            |> Map.delete("run")
            |> Map.delete("generation")
            |> Map.delete("tools")
            |> Map.put("run_failure", %{"reason" => "restart_limit"})
          end

        state = State.put_doc(state, cid, "live", live)
        {[{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", live)}], state}
      else
        {[], state}
      end

    writes = [{:put_task, failed_task}] ++ parent_writes ++ sub_writes ++ live_writes
    {writes, state}
  end

  def advance_ready_tool_rounds(state, now) do
    waiting_gens =
      state.tasks
      |> Map.values()
      |> Enum.filter(&(&1.kind == "generation" and &1.status == "waiting"))
      |> Enum.sort_by(& &1.id)

    Enum.reduce(waiting_gens, {[], state, []}, fn gen_task, {acc_w, acc_s, acc_eff} ->
      child_ids = gen_task.checkpoint["tool_task_ids"] || []
      children = Enum.map(child_ids, &Map.get(acc_s.tasks, &1)) |> Enum.reject(&is_nil/1)

      if Enum.all?(children, &(&1.status == "terminal")) do
        {w, next_s, eff} = Tools.finish_tool_round_stage(gen_task, acc_s, now)
        {acc_w ++ w, next_s, acc_eff ++ eff}
      else
        {acc_w, acc_s, acc_eff}
      end
    end)
  end

  def collect_resume_effects(state) do
    now = System.system_time(:millisecond)
    tasks = Map.values(state.tasks)

    inference_effects =
      tasks
      |> Enum.filter(&(&1.kind in ["generation", "compaction"]))
      |> Enum.flat_map(&task_resume_effect(&1, now))

    tool_effects =
      tasks
      |> Enum.filter(&(&1.kind == "generation" and &1.status == "waiting"))
      |> Enum.flat_map(fn gen_task ->
        cid = gen_task.checkpoint["conversation_id"]
        child_ids = gen_task.checkpoint["tool_task_ids"] || []

        waiting_subagent_effects =
          child_ids
          |> Enum.map(&Map.get(state.tasks, &1))
          |> Enum.filter(fn t ->
            t != nil and t.status == "waiting" and t.checkpoint["name"] == "subagent"
          end)
          |> Enum.map(&{:resume_subagent, cid, &1.id})

        waiting_subagent_effects ++ Tools.next_tool_spawn_effects(cid, child_ids, state)
      end)

    shell_effects =
      tasks
      |> Enum.filter(
        &(&1.kind == "user_shell" and &1.status == "pending" and
            &1.checkpoint["phase"] == "workspace_wait")
      )
      |> Enum.map(&{:spawn_user_shell, &1.checkpoint["conversation_id"], &1.id})

    inference_effects ++ tool_effects ++ shell_effects
  end

  def stage_worker_crashed(tid, attempt_id, reason, state) do
    if UserShell.unsafe_task?(Map.get(state.tasks, tid)) do
      UserShell.stage_crashed(tid, attempt_id, reason, state)
    else
      do_stage_worker_crashed(tid, attempt_id, reason, state)
    end
  end

  def clean_shutdown_reason?(:normal), do: true
  def clean_shutdown_reason?(:shutdown), do: true
  def clean_shutdown_reason?({:shutdown, :storage_failed}), do: false
  def clean_shutdown_reason?({:shutdown, {:storage_failed, _}}), do: false
  def clean_shutdown_reason?({:shutdown, _}), do: true
  def clean_shutdown_reason?(_), do: false

  def persist_clean_close(state) do
    now = System.system_time(:millisecond)

    reset_writes =
      state.tasks
      |> Map.values()
      |> Enum.filter(
        &(&1.status == "running" and Generation.replay_inference?(&1) and
            not Tools.unsafe_running_tool?(&1) and not UserShell.unsafe_task?(&1))
      )
      |> Enum.map(&{:put_task, Task.reset_clean(&1, now)})

    meta_write = {:put_session_meta, Map.put(state.session_meta, :clean_close, true)}

    try do
      Storage.commit(state.store, [[meta_write | reset_writes]])
    catch
      _, _ -> :ok
    end
  end

  # Internal recovery helpers

  defp do_stage_worker_crashed(tid, attempt_id, _reason, state) do
    {worker, workers} = Map.pop(state.workers, attempt_id)
    if worker, do: Process.demonitor(worker.monitor_ref, [:flush])
    state = %{state | workers: workers}

    case Map.get(state.tasks, tid) do
      nil ->
        {:skip, state}

      %{status: "terminal"} ->
        {:skip, state}

      task ->
        now = System.system_time(:millisecond)
        cid = task.checkpoint["conversation_id"]
        eph = Map.get(state.ephemeral, cid)
        live = Stream.merge_ephemeral_into_live(state.docs[cid]["live"], eph)
        state = state |> Stream.clear_ephemeral_for_conv(cid) |> State.put_doc(cid, "live", live)

        {writes, state} = recover_unclean_task(task, state, now)

        {round_writes, state, round_effects} =
          if task.kind == "tool_call" do
            advance_ready_tool_rounds(state, now)
          else
            {[], state, []}
          end

        effects = [{:release_lease, cid}] ++ round_effects ++ collect_task_effect(state, tid)
        all_writes = writes ++ round_writes

        appended =
          Enum.flat_map(all_writes, fn
            {:append_entry, e} -> [e]
            _ -> []
          end)

        next_live = state.docs[cid]["live"]

        staged = %{
          raw_item: {:worker_crashed, tid, attempt_id, :crash},
          writes: all_writes,
          conv_events: %{
            cid => %{entries: appended, doc_ops: %{"live" => [["replace", next_live]]}}
          },
          submissions: [],
          effects: effects,
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}
    end
  end

  defp recover_unclean_generation(gen_task, state, now) do
    cid = gen_task.checkpoint["conversation_id"]
    live = state.docs[cid]["live"]

    {partial_entry_writes, state} = Generation.maybe_append_aborted_partial(cid, live, state, now)
    retry_count = (gen_task.checkpoint["retry_count"] || 0) + 1

    if Generation.replay_inference?(gen_task) and retry_count <= state.retry_limit do
      {retry_writes, _next_live, _delay_ms, state} =
        Generation.schedule_inference_retry(gen_task, cid, live, retry_count, state, now)

      {partial_entry_writes ++ retry_writes, state}
    else
      failed_task =
        Task.complete(gen_task, %{"status" => "unanswered", "reason" => "interrupted"}, now)

      sub_ids = gen_task.checkpoint["submission_ids"] || []
      {sub_writes, state} = Submissions.settle(sub_ids, :unanswered, "interrupted", state, now)

      next_live =
        live
        |> Map.delete("run")
        |> Map.delete("generation")
        |> Map.delete("tools")
        |> Map.put("run_failure", %{"reason" => "interrupted"})

      state =
        state
        |> State.put_task(failed_task)
        |> State.put_doc(cid, "live", next_live)

      writes =
        partial_entry_writes ++
          [{:put_task, failed_task}] ++
          sub_writes ++
          [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

      {writes, state}
    end
  end

  defp recover_unclean_compaction(comp_task, state, now) do
    cid = comp_task.checkpoint["conversation_id"]
    live = state.docs[cid]["live"] || %{}
    retry_count = (comp_task.checkpoint["retry_count"] || 0) + 1

    if Generation.replay_inference?(comp_task) and retry_count <= state.retry_limit do
      {writes, _next_live, _delay_ms, state} =
        Generation.schedule_inference_retry(comp_task, cid, live, retry_count, state, now)

      {writes, state}
    else
      failed_task =
        Task.complete(comp_task, %{"status" => "unanswered", "reason" => "interrupted"}, now)

      sub_ids = comp_task.checkpoint["submission_ids"] || []
      {sub_writes, state} = Submissions.settle(sub_ids, :unanswered, "interrupted", state, now)

      next_live =
        Generation.compaction_failure(
          live,
          comp_task,
          "interrupted",
          "Compaction interrupted across restart"
        )

      state =
        state
        |> State.put_task(failed_task)
        |> State.put_doc(cid, "live", next_live)

      writes =
        [{:put_task, failed_task}] ++
          sub_writes ++
          [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

      {writes, state}
    end
  end

  def build_docs_map(conversations, raw_docs, default_model) do
    Enum.reduce(Map.keys(conversations), %{}, fn cid, acc ->
      conv_docs = %{
        "agent" =>
          Document.unwrap(Map.get(raw_docs, {:conversation, cid, "agent"}), "agent",
            default_model: default_model
          ),
        "live" => Document.unwrap(Map.get(raw_docs, {:conversation, cid, "live"}), "live"),
        "inbox" => Document.unwrap(Map.get(raw_docs, {:conversation, cid, "inbox"}), "inbox"),
        "usage" => Document.unwrap(Map.get(raw_docs, {:conversation, cid, "usage"}), "usage")
      }

      Map.put(acc, cid, conv_docs)
    end)
  end

  defp ensure_initial_docs_writes(conversations, raw_docs, docs, initial_agent, default_model) do
    Enum.reduce(Map.keys(conversations), {docs, []}, fn cid, {acc_docs, acc_writes} ->
      writes_for_cid =
        Enum.flat_map(["agent", "live", "inbox", "usage"], fn kind ->
          addr = {:conversation, cid, kind}

          if Map.has_key?(raw_docs, addr) do
            []
          else
            val =
              if kind == "agent" and cid == 1 and is_map(initial_agent) do
                {updated_agent, _ops} =
                  Document.configure_agent(
                    Document.initial("agent", default_model: default_model),
                    initial_agent
                  )

                updated_agent
              else
                get_in(acc_docs, [cid, kind])
              end

            [{:put_doc, addr, Document.wrap(kind, val)}]
          end
        end)

      updated_conv_docs =
        if cid == 1 and is_map(initial_agent) and
             not Map.has_key?(raw_docs, {:conversation, 1, "agent"}) do
          {updated_agent, _} =
            Document.configure_agent(
              Document.initial("agent", default_model: default_model),
              initial_agent
            )

          put_in(acc_docs, [1, "agent"], updated_agent)
        else
          acc_docs
        end

      {updated_conv_docs, acc_writes ++ writes_for_cid}
    end)
  end

  def resolve_default_model(model, _provider_mod, _provider_config)
      when is_binary(model) and model != "" do
    model
  end

  def resolve_default_model(_nil, provider_mod, provider_config) do
    cond do
      function_exported?(provider_mod, :default_model, 1) ->
        provider_mod.default_model(provider_config)

      function_exported?(provider_mod, :list_models, 1) ->
        case provider_mod.list_models(provider_config) do
          [%{id: id} | _] when is_binary(id) -> id
          _ -> "openai:gpt-5.4"
        end

      true ->
        "openai:gpt-5.4"
    end
  end

  defp task_conv_id(task, state) do
    Map.get(task.checkpoint, "conversation_id") ||
      case task.owner do
        {:conversation, cid} -> cid
        {:task, pid} -> get_in(state.tasks, [pid, Access.key(:checkpoint), "conversation_id"])
        _ -> nil
      end
  end

  defp collect_run_submission_ids(task, state) do
    case Map.get(task.checkpoint, "submission_ids") do
      ids when is_list(ids) ->
        ids

      _ ->
        case task.owner do
          {:task, pid} ->
            get_in(state.tasks, [pid, Access.key(:checkpoint), "submission_ids"]) || []

          _ ->
            []
        end
    end
  end

  defp collect_task_effect(state, tid) do
    task_resume_effect(Map.get(state.tasks, tid), System.system_time(:millisecond))
  end

  defp task_resume_effect(
         %{
           id: tid,
           kind: "generation",
           status: "pending",
           checkpoint: %{"conversation_id" => cid}
         },
         _now
       ),
       do: [{:spawn_generation, cid, tid}]

  defp task_resume_effect(
         %{
           id: tid,
           kind: "compaction",
           status: "pending",
           checkpoint: %{"conversation_id" => cid}
         },
         _now
       ),
       do: [{:spawn_compaction, cid, tid}]

  defp task_resume_effect(
         %{
           id: tid,
           kind: "tool_call",
           status: "pending",
           checkpoint: %{"conversation_id" => cid}
         },
         _now
       ),
       do: [{:spawn_tool, cid, tid}]

  defp task_resume_effect(
         %{
           id: tid,
           kind: kind,
           status: "sleeping",
           wake: %{"reason" => "pool_wait", "provider" => provider} = wake
         },
         now
       )
       when kind in ["generation", "compaction"] do
    until_ms = get_in(wake, ["until"]) || now
    [{:watch_account_pool, provider}, {:arm_wake_timer, tid, max(0, until_ms - now)}]
  end

  defp task_resume_effect(%{id: tid, kind: kind, status: "sleeping", wake: wake}, now)
       when kind in ["generation", "compaction"] do
    until_ms = get_in(wake, ["until"]) || now
    [{:arm_wake_timer, tid, max(0, until_ms - now)}]
  end

  defp task_resume_effect(_, _now), do: []
end
