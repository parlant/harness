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

  alias H.{Context, Document, Storage, Submission, Task, WorkspaceLease}
  alias H.Session.{Compaction, LiveOutput, UserShell}

  @max_drain 31
  @max_replay_ring 64
  @max_recent_submissions 256
  @default_persist_within_ms 1_000
  @default_ephemeral_interval_ms 50
  @default_retry_limit 3
  @default_retry_backoff_ms 2_000
  @max_retry_backoff_ms 60_000
  @default_restart_limit 5

  @default_tools [
    H.Tools.Read,
    H.Tools.Write,
    H.Tools.Edit,
    H.Tools.Bash,
    H.Tools.SearchHistory
  ]

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

  @spec execute_command(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def execute_command(server, cmd) when is_map(cmd) do
    GenServer.call(server, {:command, cmd}, 30_000)
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
    storage_opts = build_storage_opts(opts, session_id)

    case Storage.open(storage_mod, storage_opts) do
      {:error, reason} ->
        {:stop, {:shutdown, {:storage_failed, reason}}}

      {:ok, store} ->
        case init_from_store(store, opts, session_id) do
          {:ok, state, effects} ->
            state = apply_effects_list(effects, state)
            report_catalog_active(state)
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
      conversations: state.conversations |> Map.values() |> Enum.sort_by(& &1.id),
      tasks: state.tasks |> Map.values() |> Enum.sort_by(& &1.id)
    }

    {:reply, {:ok, detail}, state}
  end

  def handle_call(:idle, _from, state), do: {:reply, not session_active?(state), state}

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
      conv_seq = Map.get(state.conv_last_seq, cid, 0)
      ring = Map.get(state.replay_rings, cid, [])
      ring_base = Map.get(state.ring_base_seq, cid, conv_seq)

      cond do
        not is_nil(last_event_id) and last_event_id == conv_seq ->
          {:reply, {:ok, {:replay, []}}, state}

        not is_nil(last_event_id) and ring != [] and last_event_id >= ring_base and
            last_event_id < conv_seq ->
          frames = Enum.filter(ring, fn {seq, _bin} -> seq > last_event_id end)
          {:reply, {:ok, {:replay, frames}}, state}

        true ->
          case build_snapshot_payload(state, cid, conv_seq) do
            {:ok, json_bin, next_state} ->
              {:reply, {:ok, {:snapshot, conv_seq, json_bin}}, next_state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:command, cmd}, from, state) do
    process_with_drain({:command, from, cmd}, state)
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
      {:noreply, handle_gen_chunk(state, cid, tid, event)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:tool_output, inc, tid, attempt_id, cid, call_id, chunk}, state) do
    if inc == state.incarnation and Map.has_key?(state.workers, attempt_id) do
      {:noreply, handle_tool_output(state, cid, tid, call_id, chunk)}
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
    {:noreply, flush_ephemeral_broadcast(state, cid)}
  end

  def handle_info({:flush_live, cid}, state) do
    process_with_drain({:flush_live, cid}, state)
  end

  def handle_info({:wake_task, tid}, state) do
    process_with_drain({:wake_task, tid}, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_worker_by_monitor(state.workers, ref) do
      nil ->
        {:noreply, state}

      {attempt_id, worker} ->
        if reason in [:normal, :shutdown] do
          workers = Map.delete(state.workers, attempt_id)
          {:noreply, %{state | workers: workers}}
        else
          process_with_drain({:worker_crashed, worker.task_id, attempt_id, reason}, state)
        end
    end
  end

  def handle_info({:stop_storage_failed, io_err}, state) do
    {:stop, {:shutdown, {:storage_failed, io_err}}, %{state | storage_failed: true}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    terminate_all_workers(state)
    release_all_leases(state)

    if clean_shutdown_reason?(reason) and not state.storage_failed do
      persist_clean_close(state)
    end

    Storage.close(state.store)
    :ok
  end

  # Initialization & Recovery

  defp build_storage_opts(opts, session_id) do
    storage_mod = Keyword.get(opts, :storage_mod, H.Storage.File)
    base_opts = Keyword.get(opts, :storage_opts, [])

    base_opts =
      if storage_mod == H.Storage.File and not Keyword.has_key?(base_opts, :dir) do
        data_dir = Keyword.fetch!(opts, :data_dir)
        Keyword.put(base_opts, :dir, Path.join([Path.expand(data_dir), "sessions", session_id]))
      else
        base_opts
      end

    base_opts
    |> Keyword.put_new(:session_id, session_id)
    |> maybe_put_kw(:cwd, Keyword.get(opts, :cwd))
  end

  defp init_from_store(store, opts, session_id) do
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

      prev_clean = Map.get(meta, :clean_close, Map.get(meta, "clean_close"))
      prev_inc = Map.get(meta, :incarnation, Map.get(meta, "incarnation", 0)) || 0
      incarnation = prev_inc + 1
      now = System.system_time(:millisecond)

      tools = resolve_tools(Keyword.get(opts, :tools, @default_tools))
      provider_mod = Keyword.get(opts, :provider, H.Provider.ReqLLM)
      provider_config = Keyword.get(opts, :provider_config, %{})

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
          |> Map.merge(%{
            session_id: session_id,
            env_id: env_id,
            cwd: cwd,
            title: initial_title,
            title_explicit: title_explicit,
            incarnation: incarnation,
            clean_close: false
          }),
        conversations: conversations,
        tasks: tasks,
        docs: docs,
        recent_submissions: recent_subs,
        workers: %{},
        ephemeral: %{},
        held_leases: MapSet.new(),
        replay_rings: %{},
        ring_base_seq: %{},
        conv_last_seq: init_conv_last_seq(conversations, bootstrap.seq || 0),
        storage_failed: false,
        registry: Keyword.get(opts, :registry, H.Registry),
        pubsub: Keyword.get(opts, :pubsub, H.PubSub),
        catalog: Keyword.get(opts, :catalog, H.Catalog),
        task_sup: Keyword.fetch!(opts, :task_sup),
        workspace_lease: Keyword.get(opts, :workspace_lease, H.WorkspaceLease),
        provider_mod: provider_mod,
        provider_config: provider_config,
        execution_env: execution_env,
        tools: tools,
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
        compaction_max_tokens: Keyword.get(opts, :compaction_max_tokens, 4_096)
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

          {:ok, final_state, recovery_effects}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_docs_map(conversations, raw_docs, default_model) do
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

  defp init_conv_last_seq(conversations, seq) do
    Map.new(Map.keys(conversations), fn cid -> {cid, seq} end)
  end

  defp resolve_default_model(model, _provider_mod, _provider_config)
       when is_binary(model) and model != "" do
    model
  end

  defp resolve_default_model(_nil, provider_mod, provider_config) do
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

  defp reconcile_on_open(state, clean?, now) do
    # Clean close leaves only potentially interrupted unsafe tools/user_shell running.
    # Do not charge those attempts against the restart budget.
    running_tasks =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn t ->
        t.status == "running" or (UserShell.unsafe_task?(t) and t.status == "pending")
      end)
      |> Enum.sort_by(& &1.id)

    {writes, next_state} =
      Enum.reduce(running_tasks, {[], state}, fn task, {acc_writes, acc_state} ->
        {w, st} =
          cond do
            UserShell.unsafe_task?(task) ->
              UserShell.recover_on_open(task, acc_state, now)

            clean? == true and unsafe_running_tool?(task) ->
              recover_unclean_tool_call(task, acc_state, now)

            true ->
              recover_unclean_task(task, acc_state, now)
          end

        {acc_writes ++ w, st}
      end)

    # Check waiting generation tasks whose tool calls all finished (e.g. unsafe tool just marked interrupted)
    {round_writes, final_state, round_effects} =
      advance_ready_tool_rounds(next_state, now)

    effects = round_effects ++ collect_resume_effects(final_state)
    {writes ++ round_writes, final_state, effects}
  end

  defp recover_unclean_task(task, state, now) do
    incremented = Task.increment_restart(task, now)

    if incremented.restarts > state.restart_limit do
      fail_task_restart_limit(incremented, state, now)
    else
      case incremented.kind do
        "generation" -> recover_unclean_generation(incremented, state, now)
        "compaction" -> recover_unclean_compaction(incremented, state, now)
        "tool_call" -> recover_unclean_tool_call(incremented, state, now)
        _ -> {[{:put_task, incremented}], put_task_in_state(state, incremented)}
      end
    end
  end

  defp fail_task_restart_limit(task, state, now) do
    cid = task_conv_id(task, state)
    failed_task = Task.complete(task, %{"status" => "failed", "reason" => "restart_limit"}, now)
    state = put_task_in_state(state, failed_task)

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

              {[{:put_task, failed_parent}], put_task_in_state(state, failed_parent)}
          end

        _ ->
          {[], state}
      end

    sub_ids = collect_run_submission_ids(task, state)
    {sub_writes, state} = settle_submissions(sub_ids, :unanswered, "restart_limit", state, now)

    {live_writes, state} =
      if cid do
        live =
          if task.kind == "compaction" do
            compaction_failure(
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

        state = put_doc_in_state(state, cid, "live", live)
        {[{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", live)}], state}
      else
        {[], state}
      end

    writes = [{:put_task, failed_task}] ++ parent_writes ++ sub_writes ++ live_writes
    {writes, state}
  end

  defp inference_config(%{provider_mod: H.Provider.ReqLLM, provider_config: config}),
    do: H.Provider.ReqLLM.attempt_config(config)

  defp inference_config(state), do: state.provider_config

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

  defp replay_inference?(task), do: is_nil(task.checkpoint["dispatch_policy"])

  defp retry_delay_ms(state, attempt) do
    min(state.retry_backoff_ms * Integer.pow(2, min(attempt - 1, 16)), @max_retry_backoff_ms)
  end

  defp recover_unclean_generation(gen_task, state, now) do
    cid = gen_task.checkpoint["conversation_id"]
    live = state.docs[cid]["live"]

    {partial_entry_writes, state} = maybe_append_aborted_partial(cid, live, state, now)

    retry_count = (gen_task.checkpoint["retry_count"] || 0) + 1

    if replay_inference?(gen_task) and retry_count <= state.retry_limit do
      until_ms = now + retry_delay_ms(state, retry_count)

      sleeping_task =
        Task.sleep_until(gen_task, until_ms, "retry", now, %{
          "retry_count" => retry_count
        })

      next_live =
        Map.put(live, "generation", %{
          "message" => %{"thinking" => "", "text" => "", "tool_calls" => []},
          "retry" => %{"attempt" => retry_count, "until" => until_ms}
        })

      state =
        state
        |> put_task_in_state(sleeping_task)
        |> put_doc_in_state(cid, "live", next_live)

      writes =
        partial_entry_writes ++
          [
            {:put_task, sleeping_task},
            {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
          ]

      {writes, state}
    else
      failed_task =
        Task.complete(gen_task, %{"status" => "unanswered", "reason" => "interrupted"}, now)

      sub_ids = gen_task.checkpoint["submission_ids"] || []
      {sub_writes, state} = settle_submissions(sub_ids, :unanswered, "interrupted", state, now)

      next_live =
        live
        |> Map.delete("run")
        |> Map.delete("generation")
        |> Map.delete("tools")
        |> Map.put("run_failure", %{"reason" => "interrupted"})

      state =
        state
        |> put_task_in_state(failed_task)
        |> put_doc_in_state(cid, "live", next_live)

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

    if replay_inference?(comp_task) and retry_count <= state.retry_limit do
      until_ms = now + retry_delay_ms(state, retry_count)

      sleeping_task =
        Task.sleep_until(comp_task, until_ms, "retry", now, %{
          "retry_count" => retry_count
        })

      comp_live =
        (Map.get(live, "compaction") || %{})
        |> Map.put("task_id", to_string(comp_task.id))
        |> Map.put("kept_from_id", comp_task.checkpoint["kept_from_id"])
        |> Map.put("status", "retrying")
        |> Map.put("retry", %{"attempt" => retry_count, "until" => until_ms})

      next_live = Map.put(live, "compaction", comp_live)

      state =
        state
        |> put_task_in_state(sleeping_task)
        |> put_doc_in_state(cid, "live", next_live)

      writes = [
        {:put_task, sleeping_task},
        {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
      ]

      {writes, state}
    else
      failed_task =
        Task.complete(comp_task, %{"status" => "unanswered", "reason" => "interrupted"}, now)

      sub_ids = comp_task.checkpoint["submission_ids"] || []
      {sub_writes, state} = settle_submissions(sub_ids, :unanswered, "interrupted", state, now)

      next_live =
        compaction_failure(
          live,
          comp_task,
          "interrupted",
          "Compaction interrupted across restart"
        )

      state =
        state
        |> put_task_in_state(failed_task)
        |> put_doc_in_state(cid, "live", next_live)

      writes =
        [{:put_task, failed_task}] ++
          sub_writes ++
          [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

      {writes, state}
    end
  end

  defp recover_unclean_tool_call(tool_task, state, now) do
    cp = tool_task.checkpoint
    cid = cp["conversation_id"]
    call_id = cp["call_id"]
    name = cp["name"]

    if cp["replay"] == "safe" and tool_replay_string(state.tools, name) == "safe" do
      pending_task = %{tool_task | status: "pending", updated_at: now}
      live = put_in_tool_status(state.docs[cid]["live"], call_id, "pending")

      state =
        state
        |> put_task_in_state(pending_task)
        |> put_doc_in_state(cid, "live", live)

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

      entry = build_entry_record(entry_id, cid, "tool_result", entry_data, now)
      state = record_entry_in_conv(state, cid, entry_id)

      done_task =
        Task.complete(
          tool_task,
          %{"entry_id" => entry_id, "is_error" => true, "diagnostic" => "interrupted"},
          now
        )

      live = put_in_tool_status(state.docs[cid]["live"], call_id, "done")

      state =
        state
        |> put_task_in_state(done_task)
        |> put_doc_in_state(cid, "live", live)

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

  defp advance_ready_tool_rounds(state, now) do
    waiting_gens =
      state.tasks
      |> Map.values()
      |> Enum.filter(&(&1.kind == "generation" and &1.status == "waiting"))
      |> Enum.sort_by(& &1.id)

    Enum.reduce(waiting_gens, {[], state, []}, fn gen_task, {acc_w, acc_s, acc_eff} ->
      child_ids = gen_task.checkpoint["tool_task_ids"] || []
      children = Enum.map(child_ids, &Map.get(acc_s.tasks, &1)) |> Enum.reject(&is_nil/1)

      if Enum.all?(children, &(&1.status == "terminal")) do
        {w, next_s, eff} = finish_tool_round_stage(gen_task, acc_s, now)
        {acc_w ++ w, next_s, acc_eff ++ eff}
      else
        {acc_w, acc_s, acc_eff}
      end
    end)
  end

  defp collect_resume_effects(state) do
    now = System.system_time(:millisecond)

    gen_effects =
      state.tasks
      |> Map.values()
      |> Enum.filter(&(&1.kind == "generation" and &1.status in ["pending", "sleeping"]))
      |> Enum.flat_map(fn t ->
        cid = t.checkpoint["conversation_id"]

        case t.status do
          "pending" ->
            [{:spawn_generation, cid, t.id}]

          "sleeping" ->
            until_ms = get_in(t.wake, ["until"]) || now
            delay = max(0, until_ms - now)
            [{:arm_wake_timer, t.id, delay}]
        end
      end)

    tool_effects =
      state.tasks
      |> Map.values()
      |> Enum.filter(&(&1.kind == "generation" and &1.status == "waiting"))
      |> Enum.flat_map(fn gen_task ->
        cid = gen_task.checkpoint["conversation_id"]
        child_ids = gen_task.checkpoint["tool_task_ids"] || []

        next_pending =
          child_ids
          |> Enum.map(&Map.get(state.tasks, &1))
          |> Enum.find(&(&1 != nil and &1.status == "pending"))

        if next_pending do
          [{:spawn_tool, cid, next_pending.id}]
        else
          []
        end
      end)

    comp_effects =
      state.tasks
      |> Map.values()
      |> Enum.filter(&(&1.kind == "compaction" and &1.status in ["pending", "sleeping"]))
      |> Enum.flat_map(fn t ->
        cid = t.checkpoint["conversation_id"]

        case t.status do
          "pending" ->
            [{:spawn_compaction, cid, t.id}]

          "sleeping" ->
            until_ms = get_in(t.wake, ["until"]) || now
            delay = max(0, until_ms - now)
            [{:arm_wake_timer, t.id, delay}]
        end
      end)

    gen_effects ++ comp_effects ++ tool_effects
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
            apply_committed_batches(accepted_staged, seqs, %{
              working_state
              | store: committed_store
            })

          if accepted_staged != [] and is_nil(refused) do
            maybe_report_catalog_runtime(state, state_after_accepted)
          end

          reply_committed_batches(accepted_staged, seqs)

          # Send immediate replies that belonged before any refused batch
          Enum.each(immediate_replies, fn {from, reply} -> GenServer.reply(from, reply) end)

          accepted_effects = Enum.flat_map(accepted_staged, & &1.effects) ++ post_effects
          state_after_effects = apply_effects_list(accepted_effects, state_after_accepted)

          if accepted_staged == [] or not is_nil(refused) do
            maybe_report_catalog_runtime(state, state_after_effects)
          else
            maybe_report_catalog_runtime(state_after_accepted, state_after_effects)
          end

          case refused do
            nil ->
              run_items(deferred_items, state_after_effects)

            {_idx, reason} ->
              [refused_item | remaining_staged] = rest_staged

              if refused_item.reply_from do
                GenServer.reply(refused_item.reply_from, {:error, map_storage_refusal(reason)})
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
      stage_command(from, cmd, state, staged_rev)
    end
  end

  defp stage_single_item({:worker_done, tid, attempt_id, result}, state, _staged_rev) do
    stage_worker_done(tid, attempt_id, result, state)
  end

  defp stage_single_item({:worker_crashed, tid, attempt_id, reason}, state, _staged_rev) do
    stage_worker_crashed(tid, attempt_id, reason, state)
  end

  defp stage_single_item({:flush_live, cid}, state, _staged_rev) do
    stage_flush_live(cid, state)
  end

  defp stage_single_item({:wake_task, tid}, state, _staged_rev) do
    stage_wake_task(tid, state)
  end

  # Command staging

  defp stage_command(from, cmd, state, staged_rev) do
    req_id = cmd.request_id
    cid = cmd.conversation_id
    command = cmd.command
    args = cmd.args
    fingerprint = Submission.fingerprint(command, cid, args)

    case lookup_submission(state, req_id) do
      {:ok, existing, next_state} ->
        if existing.fingerprint == fingerprint do
          {:immediate, from, {:ok, Submission.to_receipt(existing, next_state.seq)}, [],
           next_state}
        else
          {:immediate, from,
           {:error, {:conflict, "request_id already used with different payload"}}, [],
           next_state}
        end

      {:not_found, next_state} ->
        if Map.has_key?(next_state.conversations, cid) do
          dispatch_command_stage(
            from,
            command,
            cid,
            req_id,
            fingerprint,
            args,
            next_state,
            staged_rev
          )
        else
          {:immediate, from, {:error, :not_found}, [], next_state}
        end
    end
  end

  defp dispatch_command_stage(from, "submit", cid, req_id, fp, args, state, _staged_rev) do
    now = System.system_time(:millisecond)

    case args.type do
      "write" ->
        stage_submit_write(from, cid, req_id, fp, args, state, now)

      "continue" ->
        stage_submit_continue(from, cid, req_id, fp, state, now)

      "input" ->
        stage_submit_input(from, cid, req_id, fp, args, state, now)
    end
  end

  defp dispatch_command_stage(from, "fork", cid, req_id, fp, args, state, _staged_rev) do
    stage_fork(from, cid, req_id, fp, args, state, false)
  end

  defp dispatch_command_stage(from, "fork_and_submit", cid, req_id, fp, args, state, _staged_rev) do
    stage_fork(from, cid, req_id, fp, args, state, true)
  end

  defp dispatch_command_stage(from, "configure", cid, req_id, fp, args, state, _staged_rev) do
    stage_configure(from, cid, req_id, fp, args, state)
  end

  defp dispatch_command_stage(from, "abort", cid, req_id, fp, args, state, _staged_rev) do
    stage_abort(from, cid, req_id, fp, args, state)
  end

  defp dispatch_command_stage(from, "withdraw", cid, req_id, fp, args, state, staged_rev) do
    stage_withdraw(from, cid, req_id, fp, args, state, staged_rev)
  end

  defp dispatch_command_stage(from, "rename", cid, req_id, fp, args, state, _staged_rev) do
    stage_rename(from, cid, req_id, fp, args, state)
  end

  defp dispatch_command_stage(from, "user_shell", cid, req_id, fp, args, state, _staged_rev) do
    UserShell.stage(from, cid, req_id, fp, args, state)
  end

  defp dispatch_command_stage(from, "compact", cid, req_id, fp, args, state, _staged_rev) do
    stage_compact(from, cid, req_id, fp, args, state)
  end

  defp stage_submit_write(from, cid, req_id, fp, args, state, now) do
    {:ok, entry_id, store} = Storage.mint_id(state.store)
    {:ok, sub_id, store} = Storage.mint_id(store)
    state = %{state | store: store}

    entry_kind = Map.get(args, :kind) || "user"

    entry_data =
      Map.get(args, :data) || %{"content" => normalize_content(Map.get(args, :content, ""))}

    entry = build_entry_record(entry_id, cid, entry_kind, entry_data, now)
    state = record_entry_in_conv(state, cid, entry_id)

    sub =
      Submission.new(%{
        id: sub_id,
        request_id: req_id,
        fingerprint: fp,
        kind: "write",
        status: "done",
        conversation_id: cid,
        entry_id: entry_id,
        created_at: now
      })

    writes = [
      {:check, {:unique_request_id, req_id, fp}},
      {:append_entry, entry},
      {:put_submission, sub}
    ]

    staged = %{
      raw_item:
        {:command, from,
         %{command: "submit", conversation_id: cid, request_id: req_id, args: args}},
      writes: writes,
      conv_events: %{cid => %{entries: [entry], doc_ops: %{}}},
      submissions: [sub],
      effects: [],
      reply_from: from,
      receipt: Submission.to_receipt(sub, state.seq)
    }

    {:batch, staged, state}
  end

  defp stage_submit_input(from, cid, req_id, fp, args, state, now) do
    when_busy = Map.get(args, :when_busy, "follow_up")
    when_idle = Map.get(args, :when_idle, "start")
    content = normalize_content(args.content)

    if conversation_busy?(state, cid) do
      if when_busy == "reject" do
        {:immediate, from, {:error, {:conflict, "conversation_busy"}}, [], state}
      else
        {:ok, sub_id, store} = Storage.mint_id(state.store)
        state = %{state | store: store}

        sub =
          Submission.new(%{
            id: sub_id,
            request_id: req_id,
            fingerprint: fp,
            kind: "input",
            status: "queued",
            conversation_id: cid,
            when_busy: when_busy,
            when_idle: when_idle,
            created_at: now
          })

        inbox_item = %{
          "submission_id" => to_string(sub_id),
          "request_id" => req_id,
          "when_busy" => when_busy,
          "content" => content
        }

        prev_inbox = state.docs[cid]["inbox"]
        next_inbox = prev_inbox ++ [inbox_item]
        doc_op = ["set", [length(prev_inbox)], inbox_item]
        state = put_doc_in_state(state, cid, "inbox", next_inbox)

        writes = [
          {:check, {:unique_request_id, req_id, fp}},
          {:put_submission, sub},
          {:put_doc, {:conversation, cid, "inbox"}, Document.wrap("inbox", next_inbox)}
        ]

        staged = %{
          raw_item:
            {:command, from,
             %{command: "submit", conversation_id: cid, request_id: req_id, args: args}},
          writes: writes,
          conv_events: %{cid => %{entries: [], doc_ops: %{"inbox" => [doc_op]}}},
          submissions: [sub],
          effects: [],
          reply_from: from,
          receipt: Submission.to_receipt(sub, state.seq)
        }

        {:batch, staged, state}
      end
    else
      if when_idle == "reject" do
        {:immediate, from, {:error, {:conflict, "conversation_idle"}}, [], state}
      else
        {:ok, entry_id, store} = Storage.mint_id(state.store)
        {:ok, sub_id, store} = Storage.mint_id(store)
        {:ok, gen_task_id, store} = Storage.mint_id(store)
        state = %{state | store: store}

        entry = build_entry_record(entry_id, cid, "user", %{"content" => content}, now)
        state = record_entry_in_conv(state, cid, entry_id)

        sub =
          Submission.new(%{
            id: sub_id,
            request_id: req_id,
            fingerprint: fp,
            kind: "input",
            status: "placed",
            conversation_id: cid,
            entry_id: entry_id,
            when_busy: when_busy,
            when_idle: when_idle,
            created_at: now
          })

        {drained_entries, drained_sub_writes, drained_sub_ids, inbox_ops, state} =
          drain_inbox_items(cid, state, now, nil)

        all_sub_ids = drained_sub_ids ++ [sub_id]

        gen_task =
          Task.new(%{
            id: gen_task_id,
            kind: "generation",
            owner: {:conversation, cid},
            status: "pending",
            checkpoint: %{
              "conversation_id" => cid,
              "turns" => 1,
              "retry_count" => 0,
              "phase" => "stream",
              "submission_ids" => all_sub_ids
            },
            created_at: now
          })

        next_live = %{
          "run" => %{"task_id" => to_string(gen_task_id), "turns" => 1},
          "generation" => %{"message" => %{"thinking" => "", "text" => "", "tool_calls" => []}}
        }

        state =
          state
          |> put_task_in_state(gen_task)
          |> put_doc_in_state(cid, "live", next_live)

        all_entries = drained_entries ++ [entry]

        {title_writes, state} = maybe_derive_initial_title(content, state)

        writes =
          [{:check, {:unique_request_id, req_id, fp}}] ++
            title_writes ++
            Enum.map(all_entries, &{:append_entry, &1}) ++
            drained_sub_writes ++
            [
              {:put_submission, sub},
              {:put_task, gen_task},
              {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
            ] ++
            if(inbox_ops == [],
              do: [],
              else: [{:put_doc, {:conversation, cid, "inbox"}, Document.wrap("inbox", [])}]
            )

        doc_ops =
          %{"live" => [["replace", next_live]]}
          |> then(fn m -> if inbox_ops == [], do: m, else: Map.put(m, "inbox", inbox_ops) end)

        staged = %{
          raw_item:
            {:command, from,
             %{command: "submit", conversation_id: cid, request_id: req_id, args: args}},
          writes: writes,
          conv_events: %{cid => %{entries: all_entries, doc_ops: doc_ops}},
          submissions: [sub],
          effects: [{:spawn_generation, cid, gen_task_id}],
          reply_from: from,
          receipt: Submission.to_receipt(sub, state.seq)
        }

        {:batch, staged, state}
      end
    end
  end

  defp stage_submit_continue(from, cid, req_id, fp, state, now) do
    if conversation_busy?(state, cid) do
      {:immediate, from, {:error, {:conflict, "conversation_busy"}}, [], state}
    else
      {:ok, sub_id, store} = Storage.mint_id(state.store)
      state = %{state | store: store}

      {drained_entries, drained_sub_writes, drained_sub_ids, inbox_ops, state} =
        drain_inbox_items(cid, state, now, nil)

      all_sub_ids = drained_sub_ids ++ [sub_id]

      {:ok, has_target, state} = has_answerable_context?(cid, drained_entries, state)

      if has_target do
        {:ok, gen_task_id, store} = Storage.mint_id(state.store)
        state = %{state | store: store}

        sub =
          Submission.new(%{
            id: sub_id,
            request_id: req_id,
            fingerprint: fp,
            kind: "continue",
            status: "placed",
            conversation_id: cid,
            created_at: now
          })

        gen_task =
          Task.new(%{
            id: gen_task_id,
            kind: "generation",
            owner: {:conversation, cid},
            status: "pending",
            checkpoint: %{
              "conversation_id" => cid,
              "turns" => 1,
              "retry_count" => 0,
              "phase" => "stream",
              "submission_ids" => all_sub_ids
            },
            created_at: now
          })

        next_live = %{
          "run" => %{"task_id" => to_string(gen_task_id), "turns" => 1},
          "generation" => %{"message" => %{"thinking" => "", "text" => "", "tool_calls" => []}}
        }

        state =
          state
          |> put_task_in_state(gen_task)
          |> put_doc_in_state(cid, "live", next_live)

        writes =
          [{:check, {:unique_request_id, req_id, fp}}] ++
            Enum.map(drained_entries, &{:append_entry, &1}) ++
            drained_sub_writes ++
            [
              {:put_submission, sub},
              {:put_task, gen_task},
              {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
            ] ++
            if(inbox_ops == [],
              do: [],
              else: [{:put_doc, {:conversation, cid, "inbox"}, Document.wrap("inbox", [])}]
            )

        doc_ops =
          %{"live" => [["replace", next_live]]}
          |> then(fn m -> if inbox_ops == [], do: m, else: Map.put(m, "inbox", inbox_ops) end)

        staged = %{
          raw_item:
            {:command, from,
             %{
               command: "submit",
               conversation_id: cid,
               request_id: req_id,
               args: %{type: "continue"}
             }},
          writes: writes,
          conv_events: %{cid => %{entries: drained_entries, doc_ops: doc_ops}},
          submissions: [sub],
          effects: [{:spawn_generation, cid, gen_task_id}],
          reply_from: from,
          receipt: Submission.to_receipt(sub, state.seq)
        }

        {:batch, staged, state}
      else
        sub =
          Submission.new(%{
            id: sub_id,
            request_id: req_id,
            fingerprint: fp,
            kind: "continue",
            status: "unanswered",
            conversation_id: cid,
            reason: "nothing_to_answer",
            created_at: now
          })

        next_live = %{"run_failure" => %{"reason" => "nothing_to_answer"}}
        state = put_doc_in_state(state, cid, "live", next_live)

        writes =
          [{:check, {:unique_request_id, req_id, fp}}] ++
            [
              {:put_submission, sub},
              {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
            ]

        staged = %{
          raw_item:
            {:command, from,
             %{
               command: "submit",
               conversation_id: cid,
               request_id: req_id,
               args: %{type: "continue"}
             }},
          writes: writes,
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [sub],
          effects: [],
          reply_from: from,
          receipt: Submission.to_receipt(sub, state.seq)
        }

        {:batch, staged, state}
      end
    end
  end

  defp stage_fork(from, parent_cid, req_id, fp, args, state, submit?) do
    at_entry_id = args.at_entry_id
    now = System.system_time(:millisecond)

    case verify_visible_entry(state, parent_cid, at_entry_id) do
      {:ok, at_entry, state} ->
        {:ok, fork_docs, store} =
          Document.fork_docs(state.store, parent_cid, at_entry.seq,
            default_model: state.default_model
          )

        {:ok, child_cid, store} = Storage.mint_id(store)
        state = %{state | store: store}

        child_conv = %{
          id: child_cid,
          parent: %{conversation_id: parent_cid, at: at_entry_id},
          owner: :ownerless,
          entry_ids: []
        }

        state = %{
          state
          | conversations: Map.put(state.conversations, child_cid, child_conv),
            docs: Map.put(state.docs, child_cid, fork_docs)
        }

        base_writes = [
          {:check, {:unique_request_id, req_id, fp}},
          {:put_conversation, child_conv},
          {:put_doc, {:conversation, child_cid, "agent"},
           Document.wrap("agent", fork_docs["agent"])},
          {:put_doc, {:conversation, child_cid, "live"},
           Document.wrap("live", fork_docs["live"])},
          {:put_doc, {:conversation, child_cid, "inbox"},
           Document.wrap("inbox", fork_docs["inbox"])},
          {:put_doc, {:conversation, child_cid, "usage"},
           Document.wrap("usage", fork_docs["usage"])}
        ]

        if submit? do
          {:ok, entry_id, store} = Storage.mint_id(state.store)
          {:ok, sub_id, store} = Storage.mint_id(store)
          {:ok, gen_task_id, store} = Storage.mint_id(store)
          state = %{state | store: store}

          content = normalize_content(args.content)
          entry = build_entry_record(entry_id, child_cid, "user", %{"content" => content}, now)
          state = record_entry_in_conv(state, child_cid, entry_id)

          sub =
            Submission.new(%{
              id: sub_id,
              request_id: req_id,
              fingerprint: fp,
              kind: "fork_and_submit",
              status: "placed",
              conversation_id: child_cid,
              entry_id: entry_id,
              when_busy: Map.get(args, :when_busy, "follow_up"),
              when_idle: Map.get(args, :when_idle, "start"),
              created_at: now
            })

          gen_task =
            Task.new(%{
              id: gen_task_id,
              kind: "generation",
              owner: {:conversation, child_cid},
              status: "pending",
              checkpoint: %{
                "conversation_id" => child_cid,
                "turns" => 1,
                "retry_count" => 0,
                "phase" => "stream",
                "submission_ids" => [sub_id]
              },
              created_at: now
            })

          next_live = %{
            "run" => %{"task_id" => to_string(gen_task_id), "turns" => 1},
            "generation" => %{"message" => %{"thinking" => "", "text" => "", "tool_calls" => []}}
          }

          state =
            state
            |> put_task_in_state(gen_task)
            |> put_doc_in_state(child_cid, "live", next_live)

          writes =
            base_writes ++
              [
                {:append_entry, entry},
                {:put_submission, sub},
                {:put_task, gen_task},
                {:put_doc, {:conversation, child_cid, "live"}, Document.wrap("live", next_live)}
              ]

          doc_ops = %{
            "agent" => [["replace", fork_docs["agent"]]],
            "live" => [["replace", next_live]],
            "inbox" => [["replace", fork_docs["inbox"]]],
            "usage" => [["replace", fork_docs["usage"]]]
          }

          staged = %{
            raw_item:
              {:command, from,
               %{
                 command: "fork_and_submit",
                 conversation_id: parent_cid,
                 request_id: req_id,
                 args: args
               }},
            writes: writes,
            conv_events: %{child_cid => %{entries: [entry], doc_ops: doc_ops}},
            submissions: [sub],
            effects: [{:spawn_generation, child_cid, gen_task_id}],
            reply_from: from,
            receipt: Submission.to_receipt(sub, state.seq)
          }

          {:batch, staged, state}
        else
          {:ok, sub_id, store} = Storage.mint_id(state.store)
          state = %{state | store: store}

          sub =
            Submission.new(%{
              id: sub_id,
              request_id: req_id,
              fingerprint: fp,
              kind: "fork",
              status: "done",
              conversation_id: child_cid,
              entry_id: at_entry_id,
              created_at: now
            })

          writes = base_writes ++ [{:put_submission, sub}]

          doc_ops = %{
            "agent" => [["replace", fork_docs["agent"]]],
            "live" => [["replace", fork_docs["live"]]],
            "inbox" => [["replace", fork_docs["inbox"]]],
            "usage" => [["replace", fork_docs["usage"]]]
          }

          staged = %{
            raw_item:
              {:command, from,
               %{command: "fork", conversation_id: parent_cid, request_id: req_id, args: args}},
            writes: writes,
            conv_events: %{child_cid => %{entries: [], doc_ops: doc_ops}},
            submissions: [sub],
            effects: [],
            reply_from: from,
            receipt: Submission.to_receipt(sub, state.seq)
          }

          {:batch, staged, state}
        end

      {:error, :entry_not_visible, state} ->
        {:immediate, from, {:error, {:bad_request, "entry_not_visible"}}, [], state}
    end
  end

  defp stage_configure(from, cid, req_id, fp, args, state) do
    expected_seq = Map.get(args, :expected_seq)
    conv_seq = Map.get(state.conv_last_seq, cid, state.seq)

    if not is_nil(expected_seq) and expected_seq != conv_seq and expected_seq != state.seq do
      {:immediate, from, {:error, {:conflict, "expected_seq mismatch"}}, [], state}
    else
      now = System.system_time(:millisecond)
      {:ok, sub_id, store} = Storage.mint_id(state.store)
      state = %{state | store: store}

      prev_agent = state.docs[cid]["agent"]
      {next_agent, doc_ops} = Document.configure_agent(prev_agent, args)
      state = put_doc_in_state(state, cid, "agent", next_agent)

      sub =
        Submission.new(%{
          id: sub_id,
          request_id: req_id,
          fingerprint: fp,
          kind: "configure",
          status: "done",
          conversation_id: cid,
          created_at: now
        })

      writes = [
        {:check, {:unique_request_id, req_id, fp}},
        {:put_submission, sub},
        {:put_doc, {:conversation, cid, "agent"}, Document.wrap("agent", next_agent)}
      ]

      staged = %{
        raw_item:
          {:command, from,
           %{command: "configure", conversation_id: cid, request_id: req_id, args: args}},
        writes: writes,
        conv_events: %{cid => %{entries: [], doc_ops: %{"agent" => doc_ops}}},
        submissions: [sub],
        effects: [],
        reply_from: from,
        receipt: Submission.to_receipt(sub, state.seq)
      }

      {:batch, staged, state}
    end
  end

  defp stage_abort(from, cid, req_id, fp, args, state) do
    now = System.system_time(:millisecond)
    reason = Map.get(args, :reason) || "aborted"
    {:ok, sub_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}

    active_gens =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn t ->
        t.kind == "generation" and t.owner == {:conversation, cid} and t.status != "terminal"
      end)

    active_shells =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn t ->
        t.kind == "user_shell" and t.owner == {:conversation, cid} and t.status != "terminal"
      end)

    active_compactions =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn t ->
        t.kind == "compaction" and t.owner == {:conversation, cid} and t.status != "terminal"
      end)

    {abort_writes, state, kill_effects} =
      Enum.reduce(active_gens, {[], state, []}, fn gen_task, {acc_w, acc_s, acc_eff} ->
        {w, st, eff} = abort_generation_run(gen_task, cid, reason, acc_s, now)
        {acc_w ++ w, st, acc_eff ++ eff}
      end)

    {shell_writes, state, shell_kills} =
      Enum.reduce(active_shells, {[], state, []}, fn shell_task, {acc_w, acc_s, acc_eff} ->
        {w, st, eff} = UserShell.stage_abort(shell_task, cid, reason, acc_s, now)
        {acc_w ++ w, st, acc_eff ++ eff}
      end)

    {comp_writes, state, comp_kills} =
      Enum.reduce(active_compactions, {[], state, []}, fn comp_task, {acc_w, acc_s, acc_eff} ->
        {w, st, eff} = abort_compaction_run(comp_task, cid, reason, acc_s, now)
        {acc_w ++ w, st, acc_eff ++ eff}
      end)

    all_abort_writes = abort_writes ++ shell_writes ++ comp_writes
    all_kill_effects = kill_effects ++ shell_kills ++ comp_kills

    sub =
      Submission.new(%{
        id: sub_id,
        request_id: req_id,
        fingerprint: fp,
        kind: "abort",
        status: "done",
        conversation_id: cid,
        reason: reason,
        created_at: now
      })

    writes =
      [{:check, {:unique_request_id, req_id, fp}}, {:put_submission, sub}] ++ all_abort_writes

    next_live = state.docs[cid]["live"]

    doc_ops =
      if active_gens == [] and active_shells == [] and active_compactions == [],
        do: %{},
        else: %{"live" => [["replace", next_live]]}

    appended =
      Enum.flat_map(all_abort_writes, fn
        {:append_entry, e} -> [e]
        _ -> []
      end)

    staged = %{
      raw_item:
        {:command, from,
         %{command: "abort", conversation_id: cid, request_id: req_id, args: args}},
      writes: writes,
      conv_events: %{cid => %{entries: appended, doc_ops: doc_ops}},
      submissions: [sub],
      effects: all_kill_effects,
      reply_from: from,
      receipt: Submission.to_receipt(sub, state.seq)
    }

    {:batch, staged, state}
  end

  defp stage_withdraw(from, cid, req_id, fp, args, state, staged_rev) do
    inbox = state.docs[cid]["inbox"] || []
    requested_ids = MapSet.new(args.submission_ids, &to_string/1)

    {withdrawn_items, remaining_inbox} =
      Enum.split_with(inbox, fn item ->
        MapSet.member?(requested_ids, Map.get(item, "submission_id"))
      end)

    found_ids = MapSet.new(withdrawn_items, &Map.get(&1, "submission_id"))

    if MapSet.size(found_ids) != MapSet.size(requested_ids) do
      {:immediate, from, {:error, {:conflict, "submission_not_queued"}}, [], state}
    else
      now = System.system_time(:millisecond)
      {:ok, sub_id, store} = Storage.mint_id(state.store)
      state = %{state | store: store}

      pending_subs =
        staged_rev
        |> Enum.flat_map(& &1.submissions)
        |> Map.new(&{&1.request_id, &1})

      {orig_sub_writes, state} =
        Enum.reduce(withdrawn_items, {[], state}, fn item, {acc_w, acc_st} ->
          orig_req_id = Map.get(item, "request_id")

          case lookup_submission_with_pending(acc_st, orig_req_id, pending_subs) do
            {:ok, orig_sub, next_st} ->
              withdrawn_orig = Submission.mark_withdrawn(orig_sub, now)
              next_st = cache_submissions(next_st, [withdrawn_orig], withdrawn_orig.seq)
              {acc_w ++ [{:put_submission, withdrawn_orig}], next_st}

            {:not_found, next_st} ->
              {acc_w, next_st}
          end
        end)

      sub =
        Submission.new(%{
          id: sub_id,
          request_id: req_id,
          fingerprint: fp,
          kind: "withdraw",
          status: "done",
          conversation_id: cid,
          withdrawn: withdrawn_items,
          created_at: now
        })

      state = put_doc_in_state(state, cid, "inbox", remaining_inbox)

      writes =
        [{:check, {:unique_request_id, req_id, fp}}] ++
          orig_sub_writes ++
          [
            {:put_submission, sub},
            {:put_doc, {:conversation, cid, "inbox"}, Document.wrap("inbox", remaining_inbox)}
          ]

      staged = %{
        raw_item:
          {:command, from,
           %{command: "withdraw", conversation_id: cid, request_id: req_id, args: args}},
        writes: writes,
        conv_events: %{
          cid => %{entries: [], doc_ops: %{"inbox" => [["replace", remaining_inbox]]}}
        },
        submissions: [sub],
        effects: [],
        reply_from: from,
        receipt: Submission.to_receipt(sub, state.seq)
      }

      {:batch, staged, state}
    end
  end

  defp stage_rename(from, cid, req_id, fp, args, state) do
    expected_seq = Map.get(args, :expected_seq)

    if not is_nil(expected_seq) and expected_seq != state.seq do
      {:immediate, from, {:error, {:conflict, "expected_seq mismatch"}}, [], state}
    else
      now = System.system_time(:millisecond)
      {:ok, sub_id, store} = Storage.mint_id(state.store)
      state = %{state | store: store}

      next_title = Map.get(args, :title)

      next_meta =
        state.session_meta
        |> Map.put(:title, next_title)
        |> Map.put(:title_explicit, true)

      state = %{state | session_meta: next_meta}

      sub =
        Submission.new(%{
          id: sub_id,
          request_id: req_id,
          fingerprint: fp,
          kind: "rename",
          status: "done",
          conversation_id: cid,
          title: next_title,
          created_at: now
        })

      writes = [
        {:check, {:unique_request_id, req_id, fp}},
        {:put_session_meta, next_meta},
        {:put_submission, sub}
      ]

      staged = %{
        raw_item:
          {:command, from,
           %{command: "rename", conversation_id: cid, request_id: req_id, args: args}},
        writes: writes,
        conv_events: %{cid => %{entries: [], doc_ops: %{}}},
        submissions: [sub],
        effects: [],
        reply_from: from,
        receipt: Submission.to_receipt(sub, state.seq)
      }

      {:batch, staged, state}
    end
  end

  defp stage_compact(from, cid, req_id, fp, args, state) do
    expected_seq = Map.get(args, :expected_seq)
    conv_seq = Map.get(state.conv_last_seq, cid, state.seq)
    inbox = get_in(state.docs, [cid, "inbox"]) || []

    cond do
      not (is_integer(expected_seq) and expected_seq >= 0) ->
        {:immediate, from,
         {:error, {:bad_request, "expected_seq must be a non-negative integer"}}, [], state}

      expected_seq != conv_seq and expected_seq != state.seq ->
        {:immediate, from, {:error, {:conflict, "expected_seq mismatch"}}, [], state}

      conversation_busy?(state, cid) or inbox != [] ->
        {:immediate, from, {:error, {:conflict, "conversation_busy"}}, [], state}

      true ->
        {:ok, entries, state} = load_visible_entries(state, cid)

        prep_opts = [
          keep_recent_chars: state.compaction_keep_recent_chars,
          max_tokens: state.compaction_max_tokens
        ]

        case Compaction.prepare(entries, prep_opts) do
          {:error, reason} ->
            {:immediate, from, {:error, {:conflict, Atom.to_string(reason)}}, [], state}

          {:ok, prep} ->
            now = System.system_time(:millisecond)
            {:ok, sub_id, store} = Storage.mint_id(state.store)
            {:ok, task_id, store} = Storage.mint_id(store)
            state = %{state | store: store}

            instructions = Map.get(args, :instructions)

            sub =
              Submission.new(%{
                id: sub_id,
                request_id: req_id,
                fingerprint: fp,
                kind: "compact",
                status: "placed",
                conversation_id: cid,
                created_at: now
              })

            task =
              Task.new(%{
                id: task_id,
                kind: "compaction",
                owner: {:conversation, cid},
                status: "pending",
                checkpoint: %{
                  "conversation_id" => cid,
                  "kept_from_id" => prep.kept_from_id,
                  "instructions" => instructions,
                  "max_tokens" => prep.max_tokens,
                  "retry_count" => 0,
                  "phase" => "summarize",
                  "submission_ids" => [sub_id]
                },
                created_at: now
              })

            next_live = %{
              "compaction" => %{
                "task_id" => to_string(task_id),
                "kept_from_id" => prep.kept_from_id,
                "status" => "pending"
              }
            }

            state =
              state
              |> put_task_in_state(task)
              |> put_doc_in_state(cid, "live", next_live)

            writes = [
              {:check, {:unique_request_id, req_id, fp}},
              {:put_submission, sub},
              {:put_task, task},
              {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
            ]

            staged = %{
              raw_item:
                {:command, from,
                 %{command: "compact", conversation_id: cid, request_id: req_id, args: args}},
              writes: writes,
              conv_events: %{
                cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}
              },
              submissions: [sub],
              effects: [{:spawn_compaction, cid, task_id}],
              reply_from: from,
              receipt: Submission.to_receipt(sub, state.seq)
            }

            {:batch, staged, state}
        end
    end
  end

  defp abort_compaction_run(comp_task, cid, reason, state, now) do
    aborted_task = Task.abort(comp_task, reason, now)
    state = put_task_in_state(state, aborted_task)

    sub_ids = comp_task.checkpoint["submission_ids"] || []
    {sub_writes, state} = settle_submissions(sub_ids, :unanswered, reason, state, now)

    next_live =
      compaction_failure(state.docs[cid]["live"], comp_task, reason, "Compaction aborted")

    state = put_doc_in_state(state, cid, "live", next_live)

    writes =
      [{:put_task, aborted_task}] ++
        sub_writes ++
        [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

    {writes, state, worker_kill_effects(state, comp_task.id)}
  end

  defp abort_generation_run(gen_task, cid, reason, state, now) do
    eph = Map.get(state.ephemeral, cid)
    live = merge_ephemeral_into_live(state.docs[cid]["live"], eph)
    state = clear_ephemeral_for_conv(state, cid)

    {partial_writes, state} = maybe_append_aborted_partial(cid, live, state, now)

    child_ids = gen_task.checkpoint["tool_task_ids"] || []

    {tool_writes, state, tool_kills} =
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

            entry = build_entry_record(entry_id, cid, "tool_result", entry_data, now)
            acc_s = record_entry_in_conv(acc_s, cid, entry_id)
            aborted_tool = Task.abort(tool_task, reason, now)
            acc_s = put_task_in_state(acc_s, aborted_tool)

            kill_eff = worker_kill_effects(acc_s, tid) ++ [{:release_lease, cid}]

            {acc_w ++ [{:append_entry, entry}, {:put_task, aborted_tool}], acc_s,
             acc_k ++ kill_eff}
        end
      end)

    aborted_gen = Task.abort(gen_task, reason, now)
    state = put_task_in_state(state, aborted_gen)

    sub_ids = gen_task.checkpoint["submission_ids"] || []
    {sub_writes, state} = settle_submissions(sub_ids, :unanswered, reason, state, now)

    next_live =
      live
      |> Map.delete("run")
      |> Map.delete("generation")
      |> Map.delete("tools")
      |> Map.put("run_failure", %{"reason" => reason})

    state = put_doc_in_state(state, cid, "live", next_live)

    writes =
      partial_writes ++
        tool_writes ++
        [{:put_task, aborted_gen}] ++
        sub_writes ++
        [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

    effects = worker_kill_effects(state, gen_task.id) ++ tool_kills
    {writes, state, effects}
  end

  # Worker completions, crashes, flush, wake

  defp stage_worker_done(tid, attempt_id, {:generation_result, gen_result}, state) do
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
        state = clear_ephemeral_for_conv(state, cid)

        case gen_result do
          {:ok, resp} ->
            stage_generation_success(gen_task, cid, resp, state, now)

          {:cancelled, partial} ->
            stage_generation_cancelled(gen_task, cid, partial, state, now)

          {:error, err} ->
            stage_generation_error(gen_task, cid, err, state, now)
        end
    end
  end

  defp stage_worker_done(tid, attempt_id, {:user_shell_result, _dur, _res} = result, state) do
    case UserShell.stage_done(tid, attempt_id, result, state) do
      {:skip, next_state} ->
        {:skip, next_state}

      {:batch, staged, next_state} ->
        maybe_drain_inbox_after_user_shell(tid, staged, next_state)
    end
  end

  defp stage_worker_done(tid, attempt_id, {:compaction_result, comp_res}, state) do
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
          {:ok, result} ->
            stage_compaction_success(comp_task, cid, result, state, now)

          {:error, err} ->
            stage_compaction_error(comp_task, cid, err, state, now)
        end
    end
  end

  defp stage_worker_done(tid, attempt_id, {:tool_result, duration_ms, tool_res}, state) do
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
        live = merge_ephemeral_into_live(state.docs[cid]["live"], eph)
        state = clear_ephemeral_for_conv(state, cid)

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
          "content" => stringify_json(Map.get(out_map, :content, [])),
          "details" => stringify_json(Map.get(out_map, :details, %{})),
          "is_error" => Map.get(out_map, :is_error, false) == true,
          "diagnostic" => Map.get(out_map, :diagnostic),
          "duration_ms" => duration_ms
        }

        entry = build_entry_record(entry_id, cid, "tool_result", entry_data, now)
        state = record_entry_in_conv(state, cid, entry_id)

        done_task =
          Task.complete(
            tool_task,
            %{"entry_id" => entry_id, "is_error" => entry_data["is_error"]},
            now
          )

        live = put_in_tool_status(live, call_id, "done")
        state = state |> put_task_in_state(done_task) |> put_doc_in_state(cid, "live", live)

        stage_after_tool_settled(cid, done_task, entry, live, state, now, [{:release_lease, cid}])
    end
  end

  defp maybe_drain_inbox_after_user_shell(tid, staged, state) do
    task = Map.get(state.tasks, tid)
    cid = task && task.checkpoint["conversation_id"]
    inbox = (cid && get_in(state.docs, [cid, "inbox"])) || []

    if is_nil(task) or task.cancelled == true or inbox == [] do
      {:batch, staged, state}
    else
      now = System.system_time(:millisecond)

      {drained_entries, drained_sub_writes, next_sub_ids, inbox_ops, state} =
        drain_inbox_items(cid, state, now, nil)

      {:ok, next_gen_id, store} = Storage.mint_id(state.store)
      state = %{state | store: store}

      next_gen =
        Task.new(%{
          id: next_gen_id,
          kind: "generation",
          owner: {:conversation, cid},
          status: "pending",
          checkpoint: %{
            "conversation_id" => cid,
            "turns" => 1,
            "retry_count" => 0,
            "phase" => "stream",
            "submission_ids" => next_sub_ids
          },
          created_at: now
        })

      next_live = %{
        "run" => %{"task_id" => to_string(next_gen_id), "turns" => 1},
        "generation" => %{"message" => %{"thinking" => "", "text" => "", "tool_calls" => []}}
      }

      state =
        state
        |> put_task_in_state(next_gen)
        |> put_doc_in_state(cid, "live", next_live)

      base_writes =
        Enum.reject(staged.writes, fn
          {:put_doc, {:conversation, ^cid, "live"}, _} -> true
          _ -> false
        end)

      next_writes =
        base_writes ++
          Enum.map(drained_entries, &{:append_entry, &1}) ++
          drained_sub_writes ++
          [
            {:put_task, next_gen},
            {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)},
            {:put_doc, {:conversation, cid, "inbox"}, Document.wrap("inbox", [])}
          ]

      prev_ev = Map.get(staged.conv_events, cid, %{entries: [], doc_ops: %{}})

      next_doc_ops =
        prev_ev.doc_ops
        |> Map.put("live", [["replace", next_live]])
        |> Map.put("inbox", inbox_ops)

      next_staged = %{
        staged
        | writes: next_writes,
          conv_events:
            Map.put(staged.conv_events, cid, %{
              entries: prev_ev.entries ++ drained_entries,
              doc_ops: next_doc_ops
            }),
          effects: staged.effects ++ [{:spawn_generation, cid, next_gen_id}]
      }

      {:batch, next_staged, state}
    end
  end

  defp stage_worker_crashed(tid, attempt_id, reason, state) do
    if UserShell.unsafe_task?(Map.get(state.tasks, tid)) do
      UserShell.stage_crashed(tid, attempt_id, reason, state)
    else
      do_stage_worker_crashed(tid, attempt_id, reason, state)
    end
  end

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
        live = merge_ephemeral_into_live(state.docs[cid]["live"], eph)
        state = state |> clear_ephemeral_for_conv(cid) |> put_doc_in_state(cid, "live", live)

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

  defp stage_generation_success(gen_task, cid, resp, state, now) do
    {:ok, entry_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}

    tool_calls = stringify_tool_calls(Map.get(resp, :tool_calls, []))
    usage_map = stringify_json(Map.get(resp, :usage, %{}))

    entry_data = %{
      "content" => stringify_json(Map.get(resp, :content, [])),
      "tool_calls" => tool_calls,
      "finish_reason" => to_string(Map.get(resp, :finish_reason) || "stop"),
      "usage" => usage_map,
      "provider_meta" => stringify_json(Map.get(resp, :provider_meta, %{}))
    }

    entry_data =
      case Map.get(resp, :reasoning_details) do
        [_ | _] = details -> Map.put(entry_data, "reasoning_details", stringify_json(details))
        _ -> entry_data
      end

    entry = build_entry_record(entry_id, cid, "assistant", entry_data, now)
    state = record_entry_in_conv(state, cid, entry_id)

    {next_usage, usage_ops} = Document.accumulate_usage(state.docs[cid]["usage"], usage_map)
    state = put_doc_in_state(state, cid, "usage", next_usage)

    usage_writes =
      if usage_ops == [],
        do: [],
        else: [{:put_doc, {:conversation, cid, "usage"}, Document.wrap("usage", next_usage)}]

    if tool_calls == [] do
      done_gen =
        Task.complete(gen_task, %{"status" => "done", "answer_entry_id" => entry_id}, now)

      sub_ids = gen_task.checkpoint["submission_ids"] || []
      {sub_writes, state} = settle_submissions(sub_ids, :done, entry_id, state, now)

      # Check inbox for follow_up / steer items to start next run
      {drained_entries, drained_sub_writes, next_sub_ids, inbox_ops, state} =
        drain_inbox_items(cid, state, now, nil)

      {next_run_writes, next_live, next_effects, state} =
        if drained_entries == [] do
          live = %{}
          state = state |> put_task_in_state(done_gen) |> put_doc_in_state(cid, "live", live)
          {[], live, [], state}
        else
          {:ok, next_gen_id, store} = Storage.mint_id(state.store)
          state = %{state | store: store}

          next_gen =
            Task.new(%{
              id: next_gen_id,
              kind: "generation",
              owner: {:conversation, cid},
              status: "pending",
              checkpoint: %{
                "conversation_id" => cid,
                "turns" => 1,
                "retry_count" => 0,
                "phase" => "stream",
                "submission_ids" => next_sub_ids
              },
              created_at: now
            })

          live = %{
            "run" => %{"task_id" => to_string(next_gen_id), "turns" => 1},
            "generation" => %{"message" => %{"thinking" => "", "text" => "", "tool_calls" => []}}
          }

          state =
            state
            |> put_task_in_state(done_gen)
            |> put_task_in_state(next_gen)
            |> put_doc_in_state(cid, "live", live)

          {[{:put_task, next_gen}], live, [{:spawn_generation, cid, next_gen_id}], state}
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
      # Schedule tool calls sequentially
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
                "call_id" => call_id,
                "name" => name,
                "arguments" => tc["arguments"] || %{},
                "index" => idx,
                "phase" => "pending",
                "replay" => tool_replay_string(state.tools, name)
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
        Enum.reduce(tool_tasks, state, &put_task_in_state(&2, &1))
        |> put_task_in_state(waiting_gen)
        |> put_doc_in_state(cid, "live", next_live)

      first_tool = hd(tool_tasks)

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
        effects: [{:spawn_tool, cid, first_tool.id}],
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

    if retryable and replay_inference?(gen_task) and retry_count <= state.retry_limit do
      delay_ms = retry_delay_ms(state, retry_count)
      until_ms = now + delay_ms

      sleeping_task =
        Task.sleep_until(gen_task, until_ms, "retry", now, %{
          "retry_count" => retry_count
        })

      next_live =
        Map.put(state.docs[cid]["live"], "generation", %{
          "message" => %{"thinking" => "", "text" => "", "tool_calls" => []},
          "retry" => %{"attempt" => retry_count, "until" => until_ms}
        })

      state =
        state
        |> put_task_in_state(sleeping_task)
        |> put_doc_in_state(cid, "live", next_live)

      staged = %{
        raw_item: {:worker_done, gen_task.id, :none, {:generation_result, {:error, err}}},
        writes: [
          {:put_task, sleeping_task},
          {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
        ],
        conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
        submissions: [],
        effects: [{:arm_wake_timer, gen_task.id, delay_ms}],
        reply_from: nil,
        receipt: nil
      }

      {:batch, staged, state}
    else
      code = Map.get(err, :code, "model_error")
      message = Map.get(err, :message, "Model error")

      done_task =
        Task.complete(gen_task, %{"status" => "unanswered", "reason" => "model_error"}, now)

      sub_ids = gen_task.checkpoint["submission_ids"] || []
      {sub_writes, state} = settle_submissions(sub_ids, :unanswered, "model_error", state, now)

      next_live = %{
        "run_failure" => %{"reason" => "model_error", "code" => code, "message" => message}
      }

      state =
        state
        |> put_task_in_state(done_task)
        |> put_doc_in_state(cid, "live", next_live)

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
    {:ok, entries, state} = load_visible_entries(state, cid)

    case List.last(entries) do
      %{kind: "compaction", id: existing_entry_id} ->
        done_task =
          Task.complete(
            comp_task,
            %{"status" => "done", "entry_id" => existing_entry_id},
            now
          )

        sub_ids = comp_task.checkpoint["submission_ids"] || []
        {sub_writes, state} = settle_submissions(sub_ids, :done, existing_entry_id, state, now)

        next_live = Map.delete(state.docs[cid]["live"] || %{}, "compaction")

        state =
          state
          |> put_task_in_state(done_task)
          |> put_doc_in_state(cid, "live", next_live)

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
        entry = build_entry_record(entry_id, cid, "compaction", entry_data, now)
        state = record_entry_in_conv(state, cid, entry_id)

        usage_map = stringify_json(Map.get(result, :usage, %{}))
        {next_usage, usage_ops} = Document.accumulate_usage(state.docs[cid]["usage"], usage_map)
        state = put_doc_in_state(state, cid, "usage", next_usage)

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
            else: settle_submissions(sub_ids, :done, entry_id, state, now)

        {drained_entries, drained_sub_writes, next_sub_ids, inbox_ops, state} =
          drain_inbox_items(cid, state, now, if(automatic?, do: "steer", else: nil))

        next_sub_ids = if automatic?, do: sub_ids ++ next_sub_ids, else: next_sub_ids

        {next_run_writes, next_live, next_effects, state} =
          if drained_entries == [] and not automatic? do
            live = Map.delete(state.docs[cid]["live"] || %{}, "compaction")
            state = state |> put_task_in_state(done_task) |> put_doc_in_state(cid, "live", live)
            {[], live, [], state}
          else
            {:ok, next_gen_id, store} = Storage.mint_id(state.store)
            state = %{state | store: store}

            next_gen =
              Task.new(%{
                id: next_gen_id,
                kind: "generation",
                owner: {:conversation, cid},
                status: "pending",
                checkpoint: %{
                  "conversation_id" => cid,
                  "turns" => 1,
                  "retry_count" => 0,
                  "phase" => "stream",
                  "submission_ids" => next_sub_ids
                },
                created_at: now
              })

            live = %{
              "run" => %{"task_id" => to_string(next_gen_id), "turns" => 1},
              "generation" => %{
                "message" => %{"thinking" => "", "text" => "", "tool_calls" => []}
              }
            }

            state =
              state
              |> put_task_in_state(done_task)
              |> put_task_in_state(next_gen)
              |> put_doc_in_state(cid, "live", live)

            {[{:put_task, next_gen}], live, [{:spawn_generation, cid, next_gen_id}], state}
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

  defp stage_compaction_error(comp_task, cid, err, state, now) do
    retryable = Map.get(err, :retryable, false) == true
    retry_count = (comp_task.checkpoint["retry_count"] || 0) + 1
    live = state.docs[cid]["live"] || %{}

    if retryable and replay_inference?(comp_task) and retry_count <= state.retry_limit do
      delay_ms = retry_delay_ms(state, retry_count)
      until_ms = now + delay_ms

      sleeping_task =
        Task.sleep_until(comp_task, until_ms, "retry", now, %{
          "retry_count" => retry_count
        })

      comp_live =
        (Map.get(live, "compaction") || %{})
        |> Map.put("task_id", to_string(comp_task.id))
        |> Map.put("kept_from_id", comp_task.checkpoint["kept_from_id"])
        |> Map.put("status", "retrying")
        |> Map.put("retry", %{"attempt" => retry_count, "until" => until_ms})

      next_live = Map.put(live, "compaction", comp_live)

      state =
        state
        |> put_task_in_state(sleeping_task)
        |> put_doc_in_state(cid, "live", next_live)

      staged = %{
        raw_item: {:worker_done, comp_task.id, :none, {:compaction_result, {:error, err}}},
        writes: [
          {:put_task, sleeping_task},
          {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
        ],
        conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
        submissions: [],
        effects: [{:arm_wake_timer, comp_task.id, delay_ms}],
        reply_from: nil,
        receipt: nil
      }

      {:batch, staged, state}
    else
      code = to_string(Map.get(err, :code, "compaction_error"))
      message = to_string(Map.get(err, :message, "Compaction failed"))

      done_task =
        Task.complete(comp_task, %{"status" => "unanswered", "reason" => code}, now)

      sub_ids = comp_task.checkpoint["submission_ids"] || []
      {sub_writes, state} = settle_submissions(sub_ids, :unanswered, code, state, now)

      next_live = compaction_failure(live, comp_task, code, message)

      state =
        state
        |> put_task_in_state(done_task)
        |> put_doc_in_state(cid, "live", next_live)

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

  defp compaction_failure(live, task, code, message) do
    (live || %{})
    |> Map.delete("compaction")
    |> Map.put("compaction_failure", %{
      "reason" => code,
      "code" => code,
      "message" => message,
      "automatic" => task.checkpoint["automatic"] == true
    })
  end

  defp stage_after_tool_settled(cid, done_tool_task, entry, live, state, now, base_effects) do
    {:task, gen_task_id} = done_tool_task.owner
    gen_task = Map.fetch!(state.tasks, gen_task_id)
    child_ids = gen_task.checkpoint["tool_task_ids"] || []

    next_pending =
      child_ids
      |> Enum.map(&Map.get(state.tasks, &1))
      |> Enum.find(&(&1 != nil and &1.status == "pending"))

    if next_pending do
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
        effects: base_effects ++ [{:spawn_tool, cid, next_pending.id}],
        reply_from: nil,
        receipt: nil
      }

      {:batch, staged, state}
    else
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
          {:put_doc, {:conversation, ^cid, "inbox"}, _} -> [["replace", state.docs[cid]["inbox"]]]
          _ -> []
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

  defp finish_tool_round_stage(gen_task, state, now) do
    cid = gen_task.checkpoint["conversation_id"]
    turns = gen_task.checkpoint["turns"] || 1

    {steer_entries, steer_sub_writes, steer_sub_ids, inbox_ops, state} =
      drain_inbox_items(cid, state, now, "steer")

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

    next_live = %{
      "run" => %{"task_id" => to_string(next_gen.id), "turns" => next_turns},
      "generation" => %{"message" => %{"thinking" => "", "text" => "", "tool_calls" => []}}
    }

    state =
      state
      |> put_task_in_state(next_gen)
      |> put_doc_in_state(cid, "live", next_live)

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

  defp stage_flush_live(cid, state) do
    case Map.get(state.ephemeral, cid) do
      %{dirty: true} = eph ->
        next_live = merge_ephemeral_into_live(state.docs[cid]["live"], eph)
        state = put_doc_in_state(state, cid, "live", next_live)

        next_eph = %{eph | dirty: false, flush_timer: nil}
        state = %{state | ephemeral: Map.put(state.ephemeral, cid, next_eph)}

        staged = %{
          raw_item: {:flush_live, cid},
          writes: [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}],
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [],
          effects: [],
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}

      _ ->
        {:skip, state}
    end
  end

  defp stage_wake_task(tid, state) do
    case Map.get(state.tasks, tid) do
      %{status: "sleeping", kind: "generation"} = gen_task ->
        now = System.system_time(:millisecond)
        cid = gen_task.checkpoint["conversation_id"]
        pending_task = %{gen_task | status: "pending", wake: nil, updated_at: now}

        next_live =
          Map.put(state.docs[cid]["live"], "generation", %{
            "message" => %{"thinking" => "", "text" => "", "tool_calls" => []}
          })

        state =
          state
          |> put_task_in_state(pending_task)
          |> put_doc_in_state(cid, "live", next_live)

        staged = %{
          raw_item: {:wake_task, tid},
          writes: [
            {:put_task, pending_task},
            {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
          ],
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [],
          effects: [{:spawn_generation, cid, tid}],
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}

      %{status: "sleeping", kind: "compaction"} = comp_task ->
        now = System.system_time(:millisecond)
        cid = comp_task.checkpoint["conversation_id"]
        pending_task = %{comp_task | status: "pending", wake: nil, updated_at: now}
        live = state.docs[cid]["live"] || %{}

        comp_live =
          (Map.get(live, "compaction") || %{})
          |> Map.put("task_id", to_string(comp_task.id))
          |> Map.put("kept_from_id", comp_task.checkpoint["kept_from_id"])
          |> Map.put("status", "pending")
          |> Map.delete("retry")

        next_live = Map.put(live, "compaction", comp_live)

        state =
          state
          |> put_task_in_state(pending_task)
          |> put_doc_in_state(cid, "live", next_live)

        staged = %{
          raw_item: {:wake_task, tid},
          writes: [
            {:put_task, pending_task},
            {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
          ],
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [],
          effects: [{:spawn_compaction, cid, tid}],
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}

      _ ->
        {:skip, state}
    end
  end

  # Effect execution (runs AFTER commit succeeds!)

  defp spawn_generation_worker(cid, gen_task_id, state) do
    case Map.get(state.tasks, gen_task_id) do
      %{kind: "generation", status: status} = gen_task when status in ["pending", "sleeping"] ->
        {:ok, entries, state} = load_visible_entries(state, cid)

        request =
          Context.build_request(entries, state.docs[cid]["agent"], build_tool_specs(state.tools))

        case Compaction.auto_boundary(
               entries,
               request,
               state.cwd,
               state.auto_compaction,
               state.compaction_keep_recent_chars,
               state.provider_mod
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
            spawn_compaction_worker(cid, task.id, put_task_in_state(state, task))
        end

      _ ->
        state
    end
  end

  defp start_generation_attempt(cid, gen_task, state, request) do
    gen_task_id = gen_task.id
    now = System.system_time(:millisecond)
    {:ok, attempt_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}

    config = inference_config(state)
    policy = dispatch_policy(state.provider_mod, config, request[:model])
    running_task = Task.start_running(gen_task, attempt_id, now, policy)

    state = put_task_in_state(state, running_task)

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
          started_at: now
        }

        %{state | workers: Map.put(state.workers, attempt_id, worker_info)}
    end
  end

  defp spawn_compaction_worker(cid, comp_task_id, state) do
    case Map.get(state.tasks, comp_task_id) do
      %{kind: "compaction", status: status} = comp_task when status in ["pending", "sleeping"] ->
        now = System.system_time(:millisecond)
        cp = comp_task.checkpoint
        kept_from_id = cp["kept_from_id"]
        max_tokens = cp["max_tokens"] || state.compaction_max_tokens
        instructions = cp["instructions"]

        {:ok, entries, state} = load_visible_entries(state, cid)

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
              |> Map.delete("retry")

            next_live =
              live |> Map.drop(["run", "generation"]) |> Map.put("compaction", comp_live)

            state =
              state
              |> put_task_in_state(running_task)
              |> put_doc_in_state(cid, "live", next_live)

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
                  broadcast_commit_frame(state, cid, batch_seq, [], %{
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
                  started_at: now
                }

                %{state | workers: Map.put(state.workers, attempt_id, worker_info)}
            end
        end

      _ ->
        state
    end
  end

  defp commit_immediate_compaction_failure(cid, comp_task, code, message, state, now) do
    done_task = Task.complete(comp_task, %{"status" => "unanswered", "reason" => code}, now)
    sub_ids = comp_task.checkpoint["submission_ids"] || []
    {sub_writes, state} = settle_submissions(sub_ids, :unanswered, code, state, now)

    next_live = compaction_failure(state.docs[cid]["live"], comp_task, code, message)

    state =
      state
      |> put_task_in_state(done_task)
      |> put_doc_in_state(cid, "live", next_live)

    writes =
      [{:put_task, done_task}] ++
        sub_writes ++
        [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

    case Storage.commit(state.store, [writes]) do
      {:ok, %{seqs: [batch_seq]}, committed_store} ->
        state = %{state | store: committed_store, seq: batch_seq}

        broadcast_commit_frame(state, cid, batch_seq, [], %{
          "live" => [["replace", next_live]]
        })

      {:error, io_err} ->
        send(self(), {:stop_storage_failed, io_err})
        %{state | storage_failed: true}
    end
  end

  defp spawn_tool_worker(cid, tool_task_id, state) do
    case Map.get(state.tasks, tool_task_id) do
      %{status: "pending"} = tool_task ->
        now = System.system_time(:millisecond)
        cp = tool_task.checkpoint
        call_id = cp["call_id"]
        name = cp["name"]
        args = cp["arguments"] || %{}

        tool = if H.Tool.selected?(name, state.docs[cid]["agent"]["tools"]), do: state.tools[name]

        case tool do
          nil ->
            commit_immediate_tool_error(
              cid,
              tool_task,
              call_id,
              name,
              "Tool not available: #{name}",
              "unknown_tool",
              state,
              now
            )

          tool_mod ->
            case H.Tool.validate_args(tool_mod, args) do
              {:error, reason} ->
                commit_immediate_tool_error(
                  cid,
                  tool_task,
                  call_id,
                  name,
                  "Invalid arguments for #{name}: #{reason}",
                  "invalid_arguments",
                  state,
                  now
                )

              {:ok, validated_args} ->
                case maybe_acquire_lease(tool_mod, cid, state) do
                  {:error, {:workspace_busy, holder_key}} ->
                    commit_immediate_tool_error(
                      cid,
                      tool_task,
                      call_id,
                      name,
                      "Workspace #{state.cwd} is currently busy with mutating work by #{inspect(holder_key)}.",
                      "workspace_busy",
                      state,
                      now
                    )

                  {:ok, state} ->
                    {:ok, attempt_id, store} = Storage.mint_id(state.store)
                    state = %{state | store: store}

                    running_task =
                      Task.start_running(tool_task, attempt_id, now, %{
                        "phase" => "execute",
                        "replay" => Atom.to_string(tool_mod.replay())
                      })

                    live = put_in_tool_status(state.docs[cid]["live"], call_id, "running")

                    state =
                      state
                      |> put_task_in_state(running_task)
                      |> put_doc_in_state(cid, "live", live)

                    case Storage.commit(state.store, [
                           [
                             {:put_task, running_task},
                             {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", live)}
                           ]
                         ]) do
                      {:error, _io_err} ->
                        maybe_release_lease(cid, state)

                      {:ok, %{seqs: [batch_seq]}, committed_store} ->
                        state = %{state | store: committed_store, seq: batch_seq}

                        broadcast_commit_frame(state, cid, batch_seq, [], %{
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
                          scan_entries: fn q -> scan_entries(server_pid, cid, q) end,
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

      _ ->
        state
    end
  end

  defp commit_immediate_tool_error(cid, tool_task, call_id, name, message, diagnostic, state, now) do
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

    entry = build_entry_record(entry_id, cid, "tool_result", entry_data, now)
    state = record_entry_in_conv(state, cid, entry_id)

    done_task =
      Task.complete(
        tool_task,
        %{"entry_id" => entry_id, "is_error" => true, "diagnostic" => diagnostic},
        now
      )

    live = put_in_tool_status(state.docs[cid]["live"], call_id, "done")
    state = state |> put_task_in_state(done_task) |> put_doc_in_state(cid, "live", live)

    {:batch, staged, state} =
      stage_after_tool_settled(cid, done_task, entry, live, state, now, [])

    case Storage.commit(state.store, [staged.writes]) do
      {:ok, %{seqs: [batch_seq]}, committed_store} ->
        state = apply_committed_batches([staged], [batch_seq], %{state | store: committed_store})
        apply_effects_list(staged.effects, state)

      {:error, _} ->
        state
    end
  end

  # Helpers (to be replaced/wired cleanly - see apply_effects_list below)

  # Ephemeral streaming buffers

  defp handle_gen_chunk(state, cid, _tid, event) do
    eph = get_or_init_ephemeral(state, cid)

    {next_eph, new_ops} =
      case event do
        %{type: :thinking_delta, text: delta} when is_binary(delta) and delta != "" ->
          {
            %{eph | thinking: eph.thinking <> delta, dirty: true},
            [["append_text", ["generation", "message", "thinking"], delta]]
          }

        %{type: :text_delta, text: delta} when is_binary(delta) and delta != "" ->
          {
            %{eph | text: eph.text <> delta, dirty: true},
            [["append_text", ["generation", "message", "text"], delta]]
          }

        %{type: :tool_call_delta, id: id, name: name, args_delta: args_delta} ->
          prev_tc =
            Map.get(eph.tool_calls, id, %{"id" => id, "name" => name || "", "arguments" => ""})

          updated_tc = %{
            prev_tc
            | "name" => name || prev_tc["name"],
              "arguments" => (prev_tc["arguments"] || "") <> (args_delta || "")
          }

          tool_order = if id in eph.tool_order, do: eph.tool_order, else: eph.tool_order ++ [id]
          tool_calls_map = Map.put(eph.tool_calls, id, updated_tc)
          tc_list = Enum.map(tool_order, &Map.fetch!(tool_calls_map, &1))

          {
            %{eph | tool_calls: tool_calls_map, tool_order: tool_order, dirty: true},
            [["set", ["generation", "message", "tool_calls"], tc_list]]
          }

        _ ->
          {eph, []}
      end

    if new_ops == [] do
      state
    else
      next_eph =
        %{next_eph | pending_ops: next_eph.pending_ops ++ new_ops}
        |> arm_ephemeral_timers(cid, state.ephemeral_interval_ms, state.persist_within_ms)

      %{state | ephemeral: Map.put(state.ephemeral, cid, next_eph)}
    end
  end

  defp handle_tool_output(state, cid, _tid, call_id, chunk)
       when is_binary(chunk) and chunk != "" do
    eph = get_or_init_ephemeral(state, cid)

    prev_out =
      Map.get(eph.tool_outputs, call_id) ||
        get_in(state.docs[cid]["live"], ["tools", call_id, "output"]) || ""

    next_out = prev_out <> chunk

    next_eph =
      %{
        eph
        | tool_outputs: Map.put(eph.tool_outputs, call_id, next_out),
          dirty: true,
          pending_ops: eph.pending_ops ++ [["append_text", ["tools", call_id, "output"], chunk]]
      }
      |> arm_ephemeral_timers(cid, state.ephemeral_interval_ms, state.persist_within_ms)

    %{state | ephemeral: Map.put(state.ephemeral, cid, next_eph)}
  end

  defp handle_tool_output(state, _cid, _tid, _call_id, _chunk), do: state

  defp get_or_init_ephemeral(state, cid) do
    case Map.get(state.ephemeral, cid) do
      nil ->
        live_msg = get_in(state.docs[cid]["live"], ["generation", "message"]) || %{}

        %{
          thinking: Map.get(live_msg, "thinking", ""),
          text: Map.get(live_msg, "text", ""),
          tool_calls: %{},
          tool_order: [],
          tool_outputs: %{},
          user_shell_output: nil,
          dirty: false,
          pending_ops: [],
          emit_timer: nil,
          flush_timer: nil
        }

      eph ->
        eph
    end
  end

  defp arm_ephemeral_timers(eph, cid, emit_ms, flush_ms) do
    eph =
      if is_nil(eph.emit_timer) do
        ref = Process.send_after(self(), {:emit_ephemeral, cid}, emit_ms)
        %{eph | emit_timer: ref}
      else
        eph
      end

    if is_nil(eph.flush_timer) do
      ref = Process.send_after(self(), {:flush_live, cid}, flush_ms)
      %{eph | flush_timer: ref}
    else
      eph
    end
  end

  defp flush_ephemeral_broadcast(state, cid) do
    case Map.get(state.ephemeral, cid) do
      %{pending_ops: []} = eph ->
        %{state | ephemeral: Map.put(state.ephemeral, cid, %{eph | emit_timer: nil})}

      %{pending_ops: ops} = eph ->
        base_seq = Map.get(state.conv_last_seq, cid, state.seq)

        frame = %{
          "version" => 1,
          "session_id" => state.session_id,
          "conversation_id" => to_string(cid),
          "base_seq" => base_seq,
          "doc_ops" => %{"live" => ops}
        }

        bin = IO.iodata_to_binary(JSON.encode_to_iodata!(frame))
        dispatch_pubsub(state.pubsub, state.session_id, cid, {:ephemeral_frame, bin})

        %{
          state
          | ephemeral: Map.put(state.ephemeral, cid, %{eph | pending_ops: [], emit_timer: nil})
        }

      nil ->
        state
    end
  end

  defp clear_ephemeral_for_conv(state, cid) do
    case Map.pop(state.ephemeral, cid) do
      {nil, _} ->
        state

      {eph, rest} ->
        if eph.emit_timer, do: Process.cancel_timer(eph.emit_timer)
        if eph.flush_timer, do: Process.cancel_timer(eph.flush_timer)
        %{state | ephemeral: rest}
    end
  end

  defp merge_ephemeral_into_live(live, nil), do: live

  defp merge_ephemeral_into_live(live, eph) do
    live =
      if Map.has_key?(live, "generation") do
        tc_list = Enum.map(eph.tool_order, &Map.fetch!(eph.tool_calls, &1))

        gen_msg = %{
          "thinking" => eph.thinking,
          "text" => eph.text,
          "tool_calls" => tc_list
        }

        put_in(live, ["generation", "message"], gen_msg)
      else
        live
      end

    live
    |> then(fn acc ->
      Enum.reduce(eph.tool_outputs, acc, fn {call_id, output}, inner_acc ->
        if get_in(inner_acc, ["tools", call_id]) do
          put_in(inner_acc, ["tools", call_id, "output"], output)
        else
          inner_acc
        end
      end)
    end)
    |> UserShell.merge_ephemeral(eph)
  end

  # Commit broadcasting & replay ring

  defp apply_committed_batches([], [], state), do: state

  defp apply_committed_batches([staged | rest_s], [batch_seq | rest_q], state) do
    state = %{state | seq: batch_seq}
    state = cache_submissions(state, staged.submissions, batch_seq)

    state =
      Enum.reduce(staged.conv_events, state, fn {cid, ev}, acc_state ->
        wire_entries = Enum.map(ev.entries, &wire_entry(&1, batch_seq))
        broadcast_commit_frame(acc_state, cid, batch_seq, wire_entries, ev.doc_ops)
      end)

    apply_committed_batches(rest_s, rest_q, state)
  end

  defp reply_committed_batches([], []), do: :ok

  defp reply_committed_batches([staged | rest_s], [batch_seq | rest_q]) do
    if staged.reply_from do
      GenServer.reply(staged.reply_from, {:ok, Map.put(staged.receipt, :seq, batch_seq)})
    end

    reply_committed_batches(rest_s, rest_q)
  end

  defp broadcast_commit_frame(state, cid, batch_seq, wire_entries, doc_ops) do
    prev_conv_seq = Map.get(state.conv_last_seq, cid, 0)

    frame = %{
      "version" => 1,
      "session_id" => state.session_id,
      "conversation_id" => to_string(cid),
      "prev_seq" => prev_conv_seq,
      "seq" => batch_seq,
      "appended_entries" => wire_entries,
      "doc_ops" => doc_ops
    }

    commit_bin = IO.iodata_to_binary(JSON.encode_to_iodata!(frame))
    dispatch_pubsub(state.pubsub, state.session_id, cid, {:commit_frame, batch_seq, commit_bin})

    ring = Map.get(state.replay_rings, cid, []) ++ [{batch_seq, commit_bin}]

    {ring, ring_base_seq} =
      if length(ring) > @max_replay_ring do
        [{evicted_seq, _} | trimmed] = ring
        {trimmed, Map.put(state.ring_base_seq, cid, evicted_seq)}
      else
        {ring, Map.put_new(state.ring_base_seq, cid, Map.get(state.conv_last_seq, cid, 0))}
      end

    %{
      state
      | replay_rings: Map.put(state.replay_rings, cid, ring),
        ring_base_seq: ring_base_seq,
        conv_last_seq: Map.put(state.conv_last_seq, cid, batch_seq)
    }
  end

  defp dispatch_pubsub(nil, _sid, _cid, _msg), do: :ok

  defp dispatch_pubsub(pubsub, sid, cid, msg) do
    Registry.dispatch(pubsub, {:conversation, sid, cid}, fn entries ->
      for {pid, _val} <- entries, do: send(pid, msg)
    end)
  end

  defp build_snapshot_payload(state, cid, conv_seq) do
    case Storage.scan_entries(state.store, %{conversation_id: cid, order: :desc, limit: 50}) do
      {:ok, %{items: newest_first, next_cursor: next_cursor}, next_store} ->
        entries_oldest_first =
          newest_first
          |> Enum.reverse()
          |> Enum.map(&wire_entry(&1, &1.seq))

        conv_docs = state.docs[cid]

        payload = %{
          "version" => 1,
          "session_id" => state.session_id,
          "conversation_id" => to_string(cid),
          "seq" => conv_seq,
          "before_entry_id" => if(next_cursor, do: to_string(next_cursor), else: nil),
          "entries" => entries_oldest_first,
          "docs" => %{
            "live" => conv_docs["live"],
            "inbox" => conv_docs["inbox"],
            "agent" => conv_docs["agent"],
            "usage" => conv_docs["usage"]
          }
        }

        {:ok, IO.iodata_to_binary(JSON.encode_to_iodata!(payload)), %{state | store: next_store}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Override run_effects / run_effect cleanly via apply_effects_list:
  # Wait: we called run_effects(effects, state) in init and run_items!
  # Wait: in run_items we wrote:
  #   run_effects(accepted_effects, state_after_accepted)
  #   {:noreply, state_after_accepted}
  # That didn't capture the updated `workers` / `store` from `spawn_generation_worker`!
  # GOOD CATCH! Let's replace `run_effects` and `run_effect` and update `init` and `run_items` to thread `state`!
  # Wait — we are writing the whole file now, so let's make `apply_effects/2` return `next_state` cleanly and use it in `init` and `run_items`!
  # Let's finish reviewing before writing, and fix lines around `init`, `run_items`, and `run_effects` right now before saving.

  # Submission, context, visibility & workspace lease helpers

  defp lookup_submission_with_pending(state, req_id, _pending_subs)
       when not is_binary(req_id) do
    {:not_found, state}
  end

  defp lookup_submission_with_pending(state, req_id, pending_subs) do
    case Map.fetch(pending_subs, req_id) do
      {:ok, sub} -> {:ok, sub, state}
      :error -> lookup_submission(state, req_id)
    end
  end

  defp lookup_submission(state, req_id) do
    case Map.fetch(state.recent_submissions, req_id) do
      {:ok, sub} ->
        {:ok, sub, state}

      :error ->
        case Storage.get_submission(state.store, req_id) do
          {:ok, nil, next_store} ->
            {:not_found, %{state | store: next_store}}

          {:ok, raw, next_store} ->
            sub = Submission.from_storage(raw)
            next_state = cache_submissions(%{state | store: next_store}, [sub], sub.seq)
            {:ok, sub, next_state}
        end
    end
  end

  defp cache_submissions(state, subs, batch_seq) do
    updated =
      Enum.reduce(subs, state.recent_submissions, fn sub, acc ->
        stamped = if batch_seq, do: Map.put(sub, :seq, batch_seq), else: sub
        Map.put(acc, stamped.request_id, stamped)
      end)

    trimmed =
      if map_size(updated) > @max_recent_submissions do
        updated
        |> Enum.sort_by(fn {_k, v} -> v.updated_at || 0 end, :desc)
        |> Enum.take(@max_recent_submissions)
        |> Map.new()
      else
        updated
      end

    %{state | recent_submissions: trimmed}
  end

  defp settle_submissions([], _mode, _val, state, _now), do: {[], state}

  defp settle_submissions(sub_ids, mode, val, state, now) do
    by_id =
      Map.new(state.recent_submissions, fn {_rid, s} -> {s.id, s} end)

    Enum.reduce(sub_ids, {[], state}, fn sid, {acc_w, acc_s} ->
      case Map.get(by_id, sid) do
        nil ->
          {acc_w, acc_s}

        sub ->
          updated =
            case mode do
              :done -> Submission.mark_done(sub, val, now)
              :unanswered -> Submission.mark_unanswered(sub, val, now)
            end

          next_cache = Map.put(acc_s.recent_submissions, updated.request_id, updated)
          {acc_w ++ [{:put_submission, updated}], %{acc_s | recent_submissions: next_cache}}
      end
    end)
  end

  defp drain_inbox_items(cid, state, now, filter_mode) do
    inbox = state.docs[cid]["inbox"] || []

    {matching, remaining} =
      if is_nil(filter_mode) do
        {inbox, []}
      else
        Enum.split_with(inbox, &(Map.get(&1, "when_busy") == filter_mode))
      end

    if matching == [] do
      {[], [], [], [], state}
    else
      {entries, sub_writes, sub_ids, state} =
        Enum.reduce(matching, {[], [], [], state}, fn item, {acc_e, acc_sw, acc_sids, acc_st} ->
          {:ok, entry_id, store} = Storage.mint_id(acc_st.store)
          acc_st = %{acc_st | store: store}

          entry =
            build_entry_record(
              entry_id,
              cid,
              "user",
              %{"content" => Map.get(item, "content", [])},
              now
            )

          acc_st = record_entry_in_conv(acc_st, cid, entry_id)

          req_id = Map.get(item, "request_id")

          {sw, sids, acc_st} =
            case lookup_submission(acc_st, req_id) do
              {:ok, sub, acc_st} ->
                placed = Submission.mark_placed(sub, entry_id, now)
                acc_st = cache_submissions(acc_st, [placed], placed.seq)
                {[{:put_submission, placed}], [placed.id], acc_st}

              {:not_found, acc_st} ->
                {[], [], acc_st}
            end

          {acc_e ++ [entry], acc_sw ++ sw, acc_sids ++ sids, acc_st}
        end)

      state = put_doc_in_state(state, cid, "inbox", remaining)
      {entries, sub_writes, sub_ids, [["replace", remaining]], state}
    end
  end

  defp has_answerable_context?(cid, newly_placed_entries, state) do
    if newly_placed_entries != [] do
      {:ok, true, state}
    else
      {:ok, entries, state} = load_visible_entries(state, cid)

      last_non_aborted =
        entries
        |> Enum.reverse()
        |> Enum.find(fn e ->
          cond do
            e.kind == "assistant" ->
              Map.get(e.data, "aborted", Map.get(e.data, :aborted)) != true

            e.kind == "user_shell" ->
              Map.get(e.data, "include_in_context", Map.get(e.data, :include_in_context)) == true

            true ->
              true
          end
        end)

      answerable? =
        case last_non_aborted do
          %{kind: kind}
          when kind in ["user", "user_shell", "tool_result", "compaction", "reset"] ->
            true

          _ ->
            false
        end

      {:ok, answerable?, state}
    end
  end

  defp load_visible_entries(state, cid) do
    collect_all_pages(state, cid, nil, [])
  end

  defp collect_all_pages(state, cid, cursor, acc) do
    query =
      %{conversation_id: cid, order: :asc, limit: 200}
      |> then(fn q -> if cursor, do: Map.put(q, :cursor, cursor), else: q end)

    case Storage.scan_entries(state.store, query) do
      {:ok, %{items: items, next_cursor: nil}, next_store} ->
        {:ok, acc ++ items, %{state | store: next_store}}

      {:ok, %{items: items, next_cursor: next_cursor}, next_store} ->
        collect_all_pages(%{state | store: next_store}, cid, next_cursor, acc ++ items)
    end
  end

  defp verify_visible_entry(state, cid, entry_id) do
    case Storage.get_entry(state.store, entry_id) do
      {:ok, nil, next_store} ->
        {:error, :entry_not_visible, %{state | store: next_store}}

      {:ok, entry, next_store} ->
        state = %{state | store: next_store}

        if entry_visible_in_conv?(state.conversations, cid, nil, entry) do
          {:ok, entry, state}
        else
          {:error, :entry_not_visible, state}
        end
    end
  end

  defp entry_visible_in_conv?(conversations, cid, cutoff, entry) do
    case Map.get(conversations, cid) do
      nil ->
        false

      conv ->
        if entry.conversation_id == cid and (is_nil(cutoff) or entry.id <= cutoff) do
          true
        else
          case conv.parent do
            nil ->
              false

            %{conversation_id: parent_id, at: at} ->
              next_cutoff = if is_nil(cutoff), do: at, else: min(at, cutoff)
              entry_visible_in_conv?(conversations, parent_id, next_cutoff, entry)
          end
        end
    end
  end

  defp conversation_busy?(state, cid) do
    UserShell.busy?(state, cid)
  end

  defp maybe_append_aborted_partial(cid, live, state, now) do
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
        "tool_calls" => stringify_tool_calls(tool_calls),
        "aborted" => true,
        "finish_reason" => "aborted"
      }

      entry = build_entry_record(entry_id, cid, "assistant", entry_data, now)
      state = record_entry_in_conv(state, cid, entry_id)
      {[{:append_entry, entry}], state}
    else
      {[], state}
    end
  end

  defp maybe_acquire_lease(tool_mod, cid, state) do
    if tool_mod.mutating?() and not is_nil(state.workspace_lease) and
         GenServer.whereis(state.workspace_lease) != nil do
      holder_key = {state.session_id, cid}
      ws_key = {state.env_id || "host", state.cwd}

      case WorkspaceLease.acquire(state.workspace_lease, ws_key, holder_key, self()) do
        :ok -> {:ok, %{state | held_leases: MapSet.put(state.held_leases, cid)}}
        {:error, _} = err -> err
      end
    else
      {:ok, state}
    end
  end

  defp maybe_release_lease(cid, state) do
    if MapSet.member?(state.held_leases, cid) and not is_nil(state.workspace_lease) and
         GenServer.whereis(state.workspace_lease) != nil do
      ws_key = {state.env_id || "host", state.cwd}
      WorkspaceLease.release(state.workspace_lease, ws_key, {state.session_id, cid})
      %{state | held_leases: MapSet.delete(state.held_leases, cid)}
    else
      state
    end
  end

  defp release_all_leases(state) do
    ws_key = {state.env_id || "host", state.cwd}

    Enum.each(state.held_leases, fn cid ->
      if not is_nil(state.workspace_lease) and GenServer.whereis(state.workspace_lease) != nil do
        try do
          WorkspaceLease.release(state.workspace_lease, ws_key, {state.session_id, cid})
        catch
          :exit, _ -> :ok
        end
      end
    end)
  end

  defp terminate_all_workers(state) do
    Enum.each(state.workers, fn {_attempt_id, worker} ->
      Process.demonitor(worker.monitor_ref, [:flush])
      terminate_worker_pid(state.task_sup, worker.pid)
    end)
  end

  defp terminate_worker_pid(task_sup, pid) do
    if is_pid(pid) and Process.alive?(pid) do
      try do
        Elixir.Task.Supervisor.terminate_child(task_sup, pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp persist_clean_close(state) do
    now = System.system_time(:millisecond)

    reset_writes =
      state.tasks
      |> Map.values()
      |> Enum.filter(
        &(&1.status == "running" and replay_inference?(&1) and not unsafe_running_tool?(&1) and
            not UserShell.unsafe_task?(&1))
      )
      |> Enum.map(&{:put_task, Task.reset_clean(&1, now)})

    meta_write = {:put_session_meta, Map.put(state.session_meta, :clean_close, true)}

    try do
      Storage.commit(state.store, [[meta_write | reset_writes]])
    catch
      _, _ -> :ok
    end
  end

  defp unsafe_running_tool?(task),
    do: task.kind == "tool_call" and task.checkpoint["replay"] != "safe"

  defp clean_shutdown_reason?(:normal), do: true
  defp clean_shutdown_reason?(:shutdown), do: true
  defp clean_shutdown_reason?({:shutdown, :storage_failed}), do: false
  defp clean_shutdown_reason?({:shutdown, {:storage_failed, _}}), do: false
  defp clean_shutdown_reason?({:shutdown, _}), do: true
  defp clean_shutdown_reason?(_), do: false

  defp maybe_report_catalog_runtime(prev_state, next_state) do
    if session_active?(prev_state) != session_active?(next_state) or
         prev_state.session_meta[:title] != next_state.session_meta[:title] do
      report_catalog_active(next_state)
    end
  end

  defp report_catalog_active(state) do
    if not is_nil(state.catalog) and GenServer.whereis(state.catalog) != nil do
      try do
        fields = %{
          title: state.session_meta[:title],
          active: session_active?(state),
          updated_at: System.system_time(:millisecond)
        }

        H.Catalog.report_runtime(state.catalog, state.session_id, fields)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp maybe_derive_initial_title(content, state) do
    current = state.session_meta[:title]
    explicit? = state.session_meta[:title_explicit] == true

    if explicit? or (is_binary(current) and String.trim(current) != "") do
      {[], state}
    else
      case extract_prompt_title(content) do
        nil ->
          {[], state}

        derived ->
          next_meta = Map.put(state.session_meta, :title, derived)
          {[{:put_session_meta, next_meta}], %{state | session_meta: next_meta}}
      end
    end
  end

  defp extract_prompt_title(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => t} when is_binary(t) -> [t]
      %{type: "text", text: t} when is_binary(t) -> [t]
      t when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join(" ")
    |> format_title_line()
  end

  defp extract_prompt_title(text) when is_binary(text), do: format_title_line(text)
  defp extract_prompt_title(_), do: nil

  defp format_title_line(raw) do
    line =
      raw
      |> String.split(~r/\R/, parts: 2)
      |> hd()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      line == "" -> nil
      String.length(line) <= 72 -> line
      true -> String.slice(line, 0, 69) <> "..."
    end
  end

  defp session_active?(state) do
    Enum.any?(state.tasks, fn {_id, t} -> t.status != "terminal" end)
  end

  # Pure state updaters & formatters

  defp put_task_in_state(state, task) do
    %{state | tasks: Map.put(state.tasks, task.id, task)}
  end

  defp put_doc_in_state(state, cid, kind, value) do
    conv_docs = state.docs |> Map.get(cid, %{}) |> Map.put(kind, value)
    %{state | docs: Map.put(state.docs, cid, conv_docs)}
  end

  defp put_in_tool_status(live, call_id, status) do
    if get_in(live, ["tools", call_id]) do
      put_in(live, ["tools", call_id, "status"], status)
    else
      live
    end
  end

  defp record_entry_in_conv(state, cid, entry_id) do
    conv = Map.fetch!(state.conversations, cid)
    updated_conv = %{conv | entry_ids: [entry_id | conv.entry_ids]}
    %{state | conversations: Map.put(state.conversations, cid, updated_conv)}
  end

  defp build_entry_record(id, cid, kind, data, now) do
    %{
      id: id,
      conversation_id: cid,
      kind: kind,
      data: data,
      created_at: now
    }
  end

  defp wire_entry(entry, fallback_seq) do
    %{
      "id" => to_string(entry.id),
      "conversation_id" => to_string(entry.conversation_id),
      "seq" => Map.get(entry, :seq) || fallback_seq,
      "kind" => entry.kind,
      "data" => entry.data,
      "created_at" => Map.get(entry, :created_at)
    }
  end

  defp resolve_tools(list) when is_list(list) do
    Map.new(list, fn mod -> {mod.name(), mod} end)
  end

  defp resolve_tools(map) when is_map(map), do: map

  defp build_tool_specs(tools_map) do
    tools_map
    |> Map.values()
    |> Enum.sort_by(& &1.name())
    |> Enum.map(fn mod ->
      %{
        name: mod.name(),
        description: mod.description(),
        parameters_schema: mod.parameters_schema()
      }
    end)
  end

  defp tool_replay_string(tools_map, name) do
    case Map.get(tools_map, name) do
      nil -> "unsafe"
      mod -> Atom.to_string(mod.replay())
    end
  end

  defp normalize_content(text) when is_binary(text) do
    [%{"type" => "text", "text" => text}]
  end

  defp normalize_content(blocks) when is_list(blocks), do: stringify_json(blocks)
  defp normalize_content(_), do: []

  defp stringify_tool_calls(list) when is_list(list) do
    Enum.map(list, fn tc ->
      %{
        "id" => Map.get(tc, :id) || Map.get(tc, "id"),
        "name" => Map.get(tc, :name) || Map.get(tc, "name"),
        "arguments" => stringify_json(Map.get(tc, :arguments) || Map.get(tc, "arguments") || %{})
      }
    end)
  end

  defp stringify_tool_calls(_), do: []

  defp stringify_json(val) when is_struct(val), do: val |> Map.from_struct() |> stringify_json()

  defp stringify_json(val) when is_map(val) do
    Map.new(val, fn {k, v} -> {to_string(k), stringify_json(v)} end)
  end

  defp stringify_json(val) when is_list(val), do: Enum.map(val, &stringify_json/1)

  defp stringify_json(val) when is_atom(val) and val not in [nil, true, false],
    do: Atom.to_string(val)

  defp stringify_json(val), do: val

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
    case Map.get(state.tasks, tid) do
      %{kind: "generation", status: "pending", checkpoint: %{"conversation_id" => cid}} ->
        [{:spawn_generation, cid, tid}]

      %{kind: "generation", status: "sleeping", wake: %{"until" => until_ms}} ->
        delay = max(0, until_ms - System.system_time(:millisecond))
        [{:arm_wake_timer, tid, delay}]

      %{kind: "compaction", status: "pending", checkpoint: %{"conversation_id" => cid}} ->
        [{:spawn_compaction, cid, tid}]

      %{kind: "compaction", status: "sleeping", wake: %{"until" => until_ms}} ->
        delay = max(0, until_ms - System.system_time(:millisecond))
        [{:arm_wake_timer, tid, delay}]

      %{kind: "tool_call", status: "pending", checkpoint: %{"conversation_id" => cid}} ->
        [{:spawn_tool, cid, tid}]

      _ ->
        []
    end
  end

  defp worker_kill_effects(state, tid) do
    state.workers
    |> Enum.filter(fn {_attempt_id, w} -> w.task_id == tid end)
    |> Enum.map(fn {attempt_id, w} -> {:kill_worker, attempt_id, w.pid, w.monitor_ref} end)
  end

  defp find_worker_by_monitor(workers, ref) do
    Enum.find(workers, fn {_attempt_id, w} -> w.monitor_ref == ref end)
  end

  defp map_storage_refusal({:duplicate_request_id, existing}) do
    {:duplicate, Submission.to_receipt(existing, 0)}
  end

  defp map_storage_refusal({:conflict_request_id, _existing}) do
    {:conflict, "request_id already used with different payload"}
  end

  defp map_storage_refusal({:conversation_not_found, _cid}), do: :not_found
  defp map_storage_refusal(other), do: other

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, val), do: Keyword.put(opts, key, val)

  defp apply_effects_list([], state), do: state

  defp apply_effects_list([effect | rest], state) do
    next_state = apply_effect(effect, state)
    apply_effects_list(rest, next_state)
  end

  defp apply_effect({:spawn_generation, cid, tid}, state) do
    spawn_generation_worker(cid, tid, state)
  end

  defp apply_effect({:spawn_tool, cid, tid}, state) do
    spawn_tool_worker(cid, tid, state)
  end

  defp apply_effect({:spawn_user_shell, cid, tid}, state) do
    UserShell.spawn_worker(cid, tid, state)
  end

  defp apply_effect({:spawn_compaction, cid, tid}, state) do
    spawn_compaction_worker(cid, tid, state)
  end

  defp apply_effect({:arm_wake_timer, tid, delay_ms}, state) do
    Process.send_after(self(), {:wake_task, tid}, delay_ms)
    state
  end

  defp apply_effect({:kill_worker, attempt_id, pid, ref}, state) do
    Process.demonitor(ref, [:flush])
    terminate_worker_pid(state.task_sup, pid)
    %{state | workers: Map.delete(state.workers, attempt_id)}
  end

  defp apply_effect({:release_lease, cid}, state) do
    maybe_release_lease(cid, state)
  end
end
