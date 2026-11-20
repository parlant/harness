defmodule H.Session.Server.WorkspaceWait do
  @moduledoc "Signal-driven workspace admission. Waiting work has no execution attempt to replay."

  alias H.{Document, Storage, WorkspaceLease}
  alias H.Session.Server.{State, Stream}

  def acquire(cid, task, key, state) do
    lease = state.workspace_lease
    token = make_ref()

    result =
      if lease && GenServer.whereis(lease) do
        WorkspaceLease.acquire_or_wait(lease, key, {state.session_id, cid}, self(), token)
      else
        :unmanaged
      end

    case result do
      {:waiting, holder, lease_id} ->
        wait = %{token: token, task_id: task.id, key: key}
        state = put_in(state.workspace_waits[cid], wait)
        {:waiting, persist(cid, task, holder, lease_id, state)}

      granted when granted in [:ok, :unmanaged] ->
        state = if granted == :ok, do: put_in(state.held_leases[cid], key), else: state
        live = Map.delete(state.docs[cid]["live"], "workspace_wait")
        {:ok, State.put_doc(state, cid, "live", live)}
    end
  end

  def blocked(_token, _holder, _lease_id, %{storage_failed: true} = state), do: state

  def blocked(token, holder, lease_id, state) do
    case Enum.find(state.workspace_waits, fn {_cid, wait} -> wait.token == token end) do
      {cid, wait} -> persist(cid, state.tasks[wait.task_id], holder, lease_id, state)
      nil -> state
    end
  end

  def granted(token, state) do
    case Enum.find(state.workspace_waits, fn {_cid, wait} -> wait.token == token end) do
      {cid, wait} ->
        state = %{
          state
          | workspace_waits: Map.delete(state.workspace_waits, cid),
            held_leases: Map.put(state.held_leases, cid, wait.key)
        }

        task = state.tasks[wait.task_id]

        if (not state.storage_failed and task) && task.status == "pending" do
          effect = if task.kind == "user_shell", do: :spawn_user_shell, else: :spawn_tool
          {[{effect, cid, task.id}], state}
        else
          {[], State.release_lease(cid, state)}
        end

      nil ->
        {[], state}
    end
  end

  def stop_holder(cid, task_id, lease_id, state) do
    case Map.get(state.workspace_waits, cid) do
      %{task_id: ^task_id, token: token, key: key} ->
        WorkspaceLease.stop_holder(
          state.workspace_lease,
          key,
          {state.session_id, cid},
          token,
          lease_id
        )

      _ ->
        :ok
    end

    state
  end

  defp persist(cid, task, {sid, owner_cid}, lease_id, state) do
    now = System.system_time(:millisecond)

    task = %{
      task
      | checkpoint: Map.put(task.checkpoint, "phase", "workspace_wait"),
        updated_at: now
    }

    {env_id, cwd} = state.workspace_waits[cid].key

    wait = %{
      "env_id" => env_id,
      "cwd" => cwd,
      "task_id" => to_string(task.id),
      "holder_session_id" => sid,
      "holder_conversation_id" => to_string(owner_cid),
      "lease_id" => lease_id
    }

    live = Map.put(state.docs[cid]["live"], "workspace_wait", wait)

    live =
      if task.kind == "user_shell",
        do: put_in(live, ["user_shell", "status"], "waiting"),
        else: State.put_tool_status(live, task.checkpoint["call_id"], "waiting")

    state = state |> State.put_task(task) |> State.put_doc(cid, "live", live)

    case Storage.commit(state.store, [
           [
             {:put_task, task},
             {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", live)}
           ]
         ]) do
      {:ok, %{seqs: [seq]}, store} ->
        Stream.broadcast_commit_frame(%{state | store: store, seq: seq}, cid, seq, [], %{
          "live" => [["replace", live]]
        })

      {:error, reason} ->
        send(self(), {:stop_storage_failed, reason})
        %{state | storage_failed: true}
    end
  end
end
