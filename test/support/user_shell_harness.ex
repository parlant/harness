defmodule H.Test.UserShellHarness do
  @moduledoc """
  Isolated coordinator harness for testing `H.Session.UserShell` durability,
  cancellation, leasing, and VM restart recovery before wiring into `H.Session.Server`.
  """

  use GenServer

  alias H.{Document, Storage, Submission, Task, WorkspaceLease}
  alias H.Session.UserShell

  def start_link(opts) when is_list(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  def execute_user_shell(server, req_id, raw_args, cid \\ 1) do
    GenServer.call(server, {:user_shell, cid, req_id, raw_args}, 30_000)
  end

  def cancel_user_shell(server, task_id) do
    GenServer.call(server, {:cancel_user_shell, task_id})
  end

  def abort_user_shell(server, cid \\ 1, reason \\ "aborted") do
    GenServer.call(server, {:abort_user_shell, cid, reason})
  end

  def state_snapshot(server, cid \\ 1) do
    GenServer.call(server, {:state_snapshot, cid})
  end

  def scan_entries(server, cid \\ 1, query \\ %{order: :asc, limit: 200}) do
    GenServer.call(server, {:scan_entries, cid, query})
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    storage_mod = Keyword.get(opts, :storage_mod, H.Storage.File)
    storage_opts = Keyword.get(opts, :storage_opts, [])
    {:ok, task_sup} = Elixir.Task.Supervisor.start_link()

    {:ok, store} = Storage.open(storage_mod, storage_opts)
    {:ok, bootstrap, store} = Storage.read_bootstrap(store)

    meta = bootstrap.session_meta || %{}
    cwd = Keyword.get(opts, :cwd) || Map.get(meta, :cwd) || Map.get(meta, "cwd")
    execution_env = Keyword.get(opts, :execution_env)

    env_id =
      Keyword.get(opts, :env_id) ||
        Map.get(meta, :env_id) ||
        Map.get(meta, "env_id") ||
        if(execution_env, do: H.ExecutionEnv.env_id(execution_env), else: "host")

    prev_inc = Map.get(meta, :incarnation, Map.get(meta, "incarnation", 0)) || 0
    incarnation = prev_inc + 1
    now = System.system_time(:millisecond)

    conversations =
      bootstrap.conversations || %{1 => %{id: 1, parent: nil, owner: :ownerless, entry_ids: []}}

    tasks = Map.new(bootstrap.tasks || %{}, fn {id, t} -> {id, Task.from_storage(t)} end)

    docs =
      Enum.reduce(Map.keys(conversations), %{}, fn cid, acc ->
        conv_docs = %{
          "agent" =>
            Document.unwrap(Map.get(bootstrap.docs, {:conversation, cid, "agent"}), "agent"),
          "live" =>
            Document.unwrap(Map.get(bootstrap.docs, {:conversation, cid, "live"}), "live"),
          "inbox" =>
            Document.unwrap(Map.get(bootstrap.docs, {:conversation, cid, "inbox"}), "inbox"),
          "usage" =>
            Document.unwrap(Map.get(bootstrap.docs, {:conversation, cid, "usage"}), "usage")
        }

        Map.put(acc, cid, conv_docs)
      end)

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
        Map.merge(meta, %{
          session_id: session_id,
          env_id: env_id,
          cwd: cwd,
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
      conv_last_seq: Map.new(Map.keys(conversations), fn cid -> {cid, bootstrap.seq || 0} end),
      storage_failed: false,
      pubsub: Keyword.get(opts, :pubsub),
      task_sup: task_sup,
      workspace_lease: Keyword.get(opts, :workspace_lease),
      execution_env: execution_env,
      persist_within_ms: Keyword.get(opts, :persist_within_ms, 20),
      ephemeral_interval_ms: Keyword.get(opts, :ephemeral_interval_ms, 5),
      user_shell_timeout_ms: Keyword.get(opts, :user_shell_timeout_ms, 120_000),
      user_shell_lease_ms: Keyword.get(opts, :user_shell_lease_ms)
    }

    recovery_tasks =
      state.tasks
      |> Map.values()
      |> Enum.filter(&(&1.kind == "user_shell" and &1.status in ["pending", "running"]))
      |> Enum.sort_by(& &1.id)

    {recovery_writes, state} =
      Enum.reduce(recovery_tasks, {[], state}, fn t, {acc_w, acc_s} ->
        {w, next_s} = UserShell.recover_on_open(t, acc_s, now)
        {acc_w ++ w, next_s}
      end)

    all_writes = [{:put_session_meta, state.session_meta} | recovery_writes]
    {:ok, %{seqs: [batch_seq]}, committed_store} = Storage.commit(state.store, [all_writes])

    conv_last_seq =
      Enum.reduce(Map.keys(state.conversations), state.conv_last_seq, fn cid, acc ->
        Map.put(acc, cid, batch_seq)
      end)

    {:ok, %{state | store: committed_store, seq: batch_seq, conv_last_seq: conv_last_seq}}
  end

  @impl true
  def handle_call({:user_shell, cid, req_id, raw_args}, from, state) do
    case UserShell.validate_args(raw_args) do
      {:error, reason} ->
        {:reply, {:error, {:bad_request, reason}}, state}

      {:ok, args} ->
        fp = Submission.fingerprint("user_shell", cid, args)

        case Map.fetch(state.recent_submissions, req_id) do
          {:ok, existing} ->
            if existing.fingerprint == fp do
              {:reply, {:ok, Submission.to_receipt(existing, state.seq)}, state}
            else
              {:reply, {:error, {:conflict, "request_id already used with different payload"}},
               state}
            end

          :error ->
            case UserShell.stage(from, cid, req_id, fp, args, state) do
              {:immediate, _from, reply, _effects, next_state} ->
                {:reply, reply, next_state}

              {:batch, staged, next_state} ->
                commit_staged(staged, next_state)
            end
        end
    end
  end

  def handle_call({:cancel_user_shell, task_id}, _from, state) do
    {:reply, UserShell.cancel_worker(task_id, state), state}
  end

  def handle_call({:abort_user_shell, cid, reason}, _from, state) do
    now = System.system_time(:millisecond)

    active =
      state.tasks
      |> Map.values()
      |> Enum.filter(
        &(&1.kind == "user_shell" and &1.owner == {:conversation, cid} and &1.status != "terminal")
      )

    {writes, state, effects} =
      Enum.reduce(active, {[], state, []}, fn task, {acc_w, acc_s, acc_eff} ->
        {w, next_s, eff} = UserShell.stage_abort(task, cid, reason, acc_s, now)
        {acc_w ++ w, next_s, acc_eff ++ eff}
      end)

    state =
      if writes == [] do
        state
      else
        {:ok, %{seqs: [seq]}, committed_store} = Storage.commit(state.store, [writes])
        %{state | store: committed_store, seq: seq}
      end

    state = apply_effects(effects, state)
    {:reply, :ok, state}
  end

  def handle_call({:state_snapshot, cid}, _from, state) do
    snap = %{
      seq: state.seq,
      conv_seq: Map.get(state.conv_last_seq, cid, state.seq),
      live: get_in(state.docs, [cid, "live"]),
      tasks: state.tasks,
      submissions: state.recent_submissions,
      workers: state.workers,
      held_leases: state.held_leases
    }

    {:reply, {:ok, snap}, state}
  end

  def handle_call({:scan_entries, cid, query}, _from, state) do
    {:ok, page, next_store} =
      Storage.scan_entries(state.store, Map.put(query, :conversation_id, cid))

    {:reply, {:ok, page}, %{state | store: next_store}}
  end

  @impl true
  def handle_info({:user_shell_output, inc, tid, attempt_id, cid, chunk}, state) do
    if inc == state.incarnation and Map.has_key?(state.workers, attempt_id) do
      {:noreply, UserShell.handle_output(state, cid, tid, chunk)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:emit_ephemeral, cid}, state) do
    case Map.get(state.ephemeral, cid) do
      %{pending_ops: []} = eph ->
        {:noreply, %{state | ephemeral: Map.put(state.ephemeral, cid, %{eph | emit_timer: nil})}}

      %{pending_ops: ops} = eph ->
        if pubsub = state.pubsub do
          frame = %{
            "version" => 1,
            "session_id" => state.session_id,
            "conversation_id" => to_string(cid),
            "base_seq" => Map.get(state.conv_last_seq, cid, state.seq),
            "doc_ops" => %{"live" => ops}
          }

          bin = IO.iodata_to_binary(JSON.encode_to_iodata!(frame))

          Registry.dispatch(pubsub, {:conversation, state.session_id, cid}, fn entries ->
            for {pid, _} <- entries, do: send(pid, {:ephemeral_frame, bin})
          end)
        end

        {:noreply,
         %{
           state
           | ephemeral: Map.put(state.ephemeral, cid, %{eph | pending_ops: [], emit_timer: nil})
         }}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:flush_live, cid}, state) do
    case Map.get(state.ephemeral, cid) do
      %{dirty: true} = eph ->
        next_live = UserShell.merge_ephemeral(state.docs[cid]["live"], eph)
        conv_docs = Map.put(state.docs[cid], "live", next_live)
        next_eph = %{eph | dirty: false, flush_timer: nil}

        state = %{
          state
          | docs: Map.put(state.docs, cid, conv_docs),
            ephemeral: Map.put(state.ephemeral, cid, next_eph)
        }

        {:ok, %{seqs: [seq]}, committed_store} =
          Storage.commit(state.store, [
            [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]
          ])

        {:noreply, %{state | store: committed_store, seq: seq}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:worker_done, inc, tid, attempt_id, result}, state) do
    if inc == state.incarnation and Map.has_key?(state.workers, attempt_id) do
      case UserShell.stage_done(tid, attempt_id, result, state) do
        {:skip, next_state} -> {:noreply, next_state}
        {:batch, staged, next_state} -> commit_staged(staged, next_state)
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.workers, fn {_aid, w} -> w.monitor_ref == ref end) do
      nil ->
        {:noreply, state}

      {attempt_id, worker} ->
        if reason in [:normal, :shutdown] do
          {:noreply, %{state | workers: Map.delete(state.workers, attempt_id)}}
        else
          case UserShell.stage_crashed(worker.task_id, attempt_id, reason, state) do
            {:skip, next_state} -> {:noreply, next_state}
            {:batch, staged, next_state} -> commit_staged(staged, next_state)
          end
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.workers, fn {_aid, w} ->
      Process.demonitor(w.monitor_ref, [:flush])

      if is_pid(w.pid) and Process.alive?(w.pid) do
        Elixir.Task.Supervisor.terminate_child(state.task_sup, w.pid)
      end
    end)

    if state.workspace_lease && GenServer.whereis(state.workspace_lease) do
      ws_key = {state.env_id || "host", state.cwd}

      Enum.each(state.held_leases, fn cid ->
        try do
          WorkspaceLease.release(state.workspace_lease, ws_key, {state.session_id, cid})
        catch
          :exit, _ -> :ok
        end
      end)
    end

    Storage.close(state.store)
    :ok
  end

  defp commit_staged(staged, state) do
    case Storage.commit(state.store, [staged.writes]) do
      {:ok, %{stored: 1, seqs: [batch_seq]}, committed_store} ->
        state = %{state | store: committed_store, seq: batch_seq}

        state =
          Enum.reduce(staged.submissions, state, fn sub, acc ->
            stamped = Map.put(sub, :seq, batch_seq)

            %{
              acc
              | recent_submissions: Map.put(acc.recent_submissions, stamped.request_id, stamped)
            }
          end)

        state =
          Enum.reduce(staged.conv_events, state, fn {cid, _ev}, acc ->
            %{acc | conv_last_seq: Map.put(acc.conv_last_seq, cid, batch_seq)}
          end)

        if staged.reply_from do
          GenServer.reply(staged.reply_from, {:ok, Map.put(staged.receipt, :seq, batch_seq)})
        end

        state = apply_effects(staged.effects, state)
        {:noreply, state}

      {:ok, %{stored: 0, refused: {_idx, reason}}, committed_store} ->
        if staged.reply_from do
          GenServer.reply(staged.reply_from, {:error, reason})
        end

        {:noreply, %{state | store: committed_store}}
    end
  end

  defp apply_effects([], state), do: state

  defp apply_effects([{:spawn_user_shell, cid, tid} | rest], state) do
    next_state = UserShell.spawn_worker(cid, tid, state)
    apply_effects(rest, next_state)
  end

  defp apply_effects([{:kill_worker, attempt_id, pid, ref} | rest], state) do
    Process.demonitor(ref, [:flush])

    if is_pid(pid) and Process.alive?(pid) do
      Elixir.Task.Supervisor.terminate_child(state.task_sup, pid)
    end

    apply_effects(rest, %{state | workers: Map.delete(state.workers, attempt_id)})
  end

  defp apply_effects([{:release_lease, cid} | rest], state) do
    next_state =
      if MapSet.member?(state.held_leases, cid) and not is_nil(state.workspace_lease) and
           GenServer.whereis(state.workspace_lease) != nil do
        ws_key = {state.env_id || "host", state.cwd}
        WorkspaceLease.release(state.workspace_lease, ws_key, {state.session_id, cid})
        %{state | held_leases: MapSet.delete(state.held_leases, cid)}
      else
        state
      end

    apply_effects(rest, next_state)
  end
end
