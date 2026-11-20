defmodule H.Session.Server.State do
  @moduledoc """
  Shared session coordinator state transitions, conversation entry/visibility
  queries, workspace lease coordination, worker termination, and `H.Catalog`
  runtime reporting.
  """

  alias H.{Catalog, ExecutionEnv, Storage, WorkspaceLease}

  def put_task(state, task) do
    %{state | tasks: Map.put(state.tasks, task.id, task)}
  end

  def put_doc(state, cid, kind, value) do
    conv_docs = state.docs |> Map.get(cid, %{}) |> Map.put(kind, value)
    %{state | docs: Map.put(state.docs, cid, conv_docs)}
  end

  def put_tool_status(live, call_id, status) do
    if get_in(live, ["tools", call_id]) do
      put_in(live, ["tools", call_id, "status"], status)
    else
      live
    end
  end

  def record_entry(state, cid, entry_id) do
    conv = Map.fetch!(state.conversations, cid)
    updated_conv = %{conv | entry_ids: [entry_id | conv.entry_ids]}
    %{state | conversations: Map.put(state.conversations, cid, updated_conv)}
  end

  def build_entry(id, cid, kind, data, now) do
    %{
      id: id,
      conversation_id: cid,
      kind: kind,
      data: data,
      created_at: now
    }
  end

  def wire_entry(entry, fallback_seq) do
    %{
      "id" => to_string(entry.id),
      "conversation_id" => to_string(entry.conversation_id),
      "seq" => Map.get(entry, :seq) || fallback_seq,
      "kind" => entry.kind,
      "data" => entry.data,
      "created_at" => Map.get(entry, :created_at)
    }
  end

  def session_active?(state) do
    Enum.any?(state.tasks, fn {_id, t} -> t.status != "terminal" end)
  end

  def conversation_busy?(state, cid) when is_map(state) and is_integer(cid) do
    live = get_in(state, [:docs, cid, "live"]) || %{}

    Map.get(live, "run") != nil or
      Map.get(live, "user_shell") != nil or
      Map.get(live, "compaction") != nil or
      Enum.any?(Map.get(state, :tasks, %{}), fn {_id, t} ->
        t.kind in ["generation", "user_shell", "compaction"] and
          t.owner == {:conversation, cid} and
          t.status != "terminal"
      end)
  end

  def load_visible_entries(state, cid) do
    collect_all_pages(state, cid, nil, [])
  end

  def verify_visible_entry(state, cid, entry_id) do
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

  # Workspace leases

  def workspace_cwd(env, state) do
    Map.get(state, :cwd) || if(env, do: ExecutionEnv.cwd(env), else: nil)
  end

  def acquire_lease(cid, state, env \\ nil) do
    lease_server = Map.get(state, :workspace_lease)

    if not is_nil(lease_server) and GenServer.whereis(lease_server) != nil do
      env = env || Map.get(state, :execution_env)
      env_id = Map.get(state, :env_id) || if(env, do: ExecutionEnv.env_id(env), else: "host")
      cwd = workspace_cwd(env, state)
      ws_key = {env_id, cwd}
      holder_key = {state.session_id, cid}

      case WorkspaceLease.acquire(lease_server, ws_key, holder_key, self()) do
        :ok ->
          held = Map.get(state, :held_leases, MapSet.new())
          {:ok, Map.put(state, :held_leases, MapSet.put(held, cid))}

        {:error, _} = err ->
          err
      end
    else
      {:ok, state}
    end
  end

  def release_lease(cid, state, env \\ nil) do
    lease_server = Map.get(state, :workspace_lease)
    held = Map.get(state, :held_leases, MapSet.new())

    if MapSet.member?(held, cid) and not is_nil(lease_server) and
         GenServer.whereis(lease_server) != nil do
      env = env || Map.get(state, :execution_env)
      env_id = Map.get(state, :env_id) || if(env, do: ExecutionEnv.env_id(env), else: "host")
      cwd = workspace_cwd(env, state)
      WorkspaceLease.release(lease_server, {env_id, cwd}, {state.session_id, cid})
      %{state | held_leases: MapSet.delete(held, cid)}
    else
      state
    end
  end

  def release_all_leases(state) do
    lease_server = Map.get(state, :workspace_lease)
    held = Map.get(state, :held_leases, MapSet.new())

    if not is_nil(lease_server) and GenServer.whereis(lease_server) != nil do
      env = Map.get(state, :execution_env)
      env_id = Map.get(state, :env_id) || if(env, do: ExecutionEnv.env_id(env), else: "host")
      ws_key = {env_id, workspace_cwd(env, state)}

      Enum.each(held, fn cid ->
        try do
          WorkspaceLease.release(lease_server, ws_key, {state.session_id, cid})
        catch
          :exit, _ -> :ok
        end
      end)
    end
  end

  # Catalog runtime reporting

  def maybe_report_catalog_runtime(prev_state, next_state) do
    if session_active?(prev_state) != session_active?(next_state) or
         prev_state.session_meta[:title] != next_state.session_meta[:title] do
      report_catalog_active(next_state)
    end
  end

  def report_catalog_active(state) do
    if not is_nil(state.catalog) and GenServer.whereis(state.catalog) != nil do
      try do
        fields = %{
          title: state.session_meta[:title],
          active: session_active?(state),
          updated_at: System.system_time(:millisecond)
        }

        Catalog.report_runtime(state.catalog, state.session_id, fields)
      catch
        :exit, _ -> :ok
      end
    end
  end

  # Worker management & JSON/tool helpers

  def worker_kill_effects(state, tid) do
    state.workers
    |> Enum.filter(fn {_attempt_id, w} -> w.task_id == tid end)
    |> Enum.map(fn {attempt_id, w} -> {:kill_worker, attempt_id, w.pid, w.monitor_ref} end)
  end

  def find_worker_by_monitor(workers, ref) do
    Enum.find(workers, fn {_attempt_id, w} -> w.monitor_ref == ref end)
  end

  def terminate_all_workers(state) do
    Enum.each(state.workers, fn {_attempt_id, worker} ->
      Process.demonitor(worker.monitor_ref, [:flush])
      terminate_worker_pid(state.task_sup, worker.pid)
    end)
  end

  def terminate_worker_pid(task_sup, pid) do
    if is_pid(pid) and Process.alive?(pid) do
      try do
        Elixir.Task.Supervisor.terminate_child(task_sup, pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  def resolve_tools(list) when is_list(list), do: Map.new(list, fn mod -> {mod.name(), mod} end)
  def resolve_tools(map) when is_map(map), do: map

  def build_tool_specs(tools_map) do
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

  def tool_replay_string(tools_map, name) do
    case Map.get(tools_map, name) do
      nil -> "unsafe"
      mod -> Atom.to_string(mod.replay())
    end
  end

  def normalize_content(text) when is_binary(text) do
    [%{"type" => "text", "text" => text}]
  end

  def normalize_content(blocks) when is_list(blocks), do: stringify_json(blocks)
  def normalize_content(_), do: []

  def stringify_tool_calls(list) when is_list(list) do
    Enum.map(list, fn tc ->
      %{
        "id" => Map.get(tc, :id) || Map.get(tc, "id"),
        "name" => Map.get(tc, :name) || Map.get(tc, "name"),
        "arguments" => stringify_json(Map.get(tc, :arguments) || Map.get(tc, "arguments") || %{})
      }
    end)
  end

  def stringify_tool_calls(_), do: []

  def stringify_json(val) when is_struct(val), do: val |> Map.from_struct() |> stringify_json()

  def stringify_json(val) when is_map(val) do
    Map.new(val, fn {k, v} -> {to_string(k), stringify_json(v)} end)
  end

  def stringify_json(val) when is_list(val), do: Enum.map(val, &stringify_json/1)

  def stringify_json(val) when is_atom(val) and val not in [nil, true, false],
    do: Atom.to_string(val)

  def stringify_json(val), do: val

  # Internal pagination & ancestry helpers

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
end
