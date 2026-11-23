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

  def cwd_available?(state) when is_map(state) do
    env = Map.get(state, :execution_env)
    cwd = workspace_cwd(env, state)

    cond do
      not is_binary(cwd) or cwd == "" ->
        false

      is_nil(env) ->
        File.dir?(cwd)

      ExecutionEnv.kind(env) == "host" ->
        File.dir?(cwd)

      true ->
        match?({:ok, _}, ExecutionEnv.bind_cwd(env, cwd))
    end
  end

  def workspace_cwd(env, state) do
    Map.get(state, :cwd) || if(env, do: ExecutionEnv.cwd(env), else: nil)
  end

  def release_lease(cid, state) do
    {held_key, held} = Map.pop(state.held_leases, cid)
    {wait, waits} = Map.pop(state.workspace_waits, cid)
    key = held_key || (wait && wait.key)

    if key && state.workspace_lease && GenServer.whereis(state.workspace_lease) do
      WorkspaceLease.release(state.workspace_lease, key, {state.session_id, cid})
    end

    %{state | held_leases: held, workspace_waits: waits}
  end

  def release_all_leases(state) do
    keys =
      Map.merge(
        Map.new(state.workspace_waits, fn {cid, wait} -> {cid, wait.key} end),
        state.held_leases
      )

    if state.workspace_lease && GenServer.whereis(state.workspace_lease) do
      Enum.each(keys, fn {cid, key} ->
        try do
          WorkspaceLease.release(state.workspace_lease, key, {state.session_id, cid})
        catch
          :exit, _ -> :ok
        end
      end)
    end
  end

  # Catalog runtime reporting

  @doc """
  Computes the catalog runtime summary (`title`, `active`, `attention`,
  `activity_kind`, `activity_label`, `queued_count`) from coordinator state.
  """
  @spec derive_catalog_runtime(map()) :: map()
  def derive_catalog_runtime(state) when is_map(state) do
    tasks = Map.get(state, :tasks, %{}) |> Map.values()
    docs = Map.get(state, :docs, %{})

    active_tasks = Enum.filter(tasks, &(&1.status in ["pending", "running", "waiting"]))
    sleeping_tasks = Enum.filter(tasks, &(&1.status == "sleeping"))

    {attention, activity_kind, activity_label} =
      cond do
        active_tasks != [] ->
          derive_active_activity(active_tasks)

        sleeping_tasks != [] ->
          task = Enum.min_by(sleeping_tasks, & &1.id)
          {"retrying", "retry", retry_label(task, true)}

        true ->
          case find_conversation_failure(docs) do
            {:ok, label} -> {"error", nil, label}
            :none -> {"idle", nil, nil}
          end
      end

    queued_count =
      Enum.reduce(docs, 0, fn {_cid, conv_docs}, acc ->
        case Map.get(conv_docs, "inbox") do
          inbox when is_list(inbox) -> acc + length(inbox)
          _ -> acc
        end
      end)

    %{
      title: Map.get(state, :session_meta, %{})[:title],
      active: active_tasks != [] or sleeping_tasks != [],
      attention: attention,
      activity_kind: activity_kind,
      activity_label: Catalog.sanitize_activity_label(activity_label),
      queued_count: queued_count,
      next_wake_at:
        sleeping_tasks
        |> Enum.map(&get_in(&1, [Access.key(:wake, %{}), "until"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.min(fn -> nil end)
    }
  end

  def maybe_report_catalog_runtime(prev_state, next_state) do
    if derive_catalog_runtime(prev_state) != derive_catalog_runtime(next_state) do
      report_catalog_active(next_state)
    end
  end

  def report_catalog_active(state) do
    if not is_nil(state.catalog) and GenServer.whereis(state.catalog) != nil do
      try do
        fields =
          state
          |> derive_catalog_runtime()
          |> Map.put(:updated_at, System.system_time(:millisecond))

        Catalog.report_runtime(state.catalog, state.session_id, fields)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp derive_active_activity(active_tasks) do
    sorted = Enum.sort_by(active_tasks, &{status_priority(&1.status), &1.id})

    tool_task =
      Enum.find(sorted, fn t ->
        t.kind == "tool_call" and t.status in ["running", "pending", "waiting"]
      end)

    user_shell_task = Enum.find(sorted, &(&1.kind == "user_shell"))

    compaction_task =
      Enum.find(sorted, fn t ->
        t.kind == "compaction" and t.status in ["running", "pending"]
      end)

    retry_task =
      Enum.find(sorted, fn task ->
        task.kind in ["generation", "compaction"] and task.status in ["pending", "running"] and
          ((task.checkpoint["retry_count"] || 0) > 0 or
             is_map(task.checkpoint["wait"]))
      end)

    cond do
      tool_task != nil ->
        label =
          case get_in(tool_task, [:checkpoint, "name"]) do
            name when is_binary(name) and name != "" -> name
            _ -> "tool"
          end

        {"running", "tool", label}

      user_shell_task != nil ->
        {"running", "user_shell", "shell"}

      retry_task != nil ->
        {"retrying", "retry", retry_label(retry_task, false)}

      compaction_task != nil ->
        {"running", "compaction", "compact"}

      true ->
        {"running", "generation", nil}
    end
  end

  defp retry_label(task, waiting?) do
    case {task.checkpoint["wait"], task.checkpoint["retry"]} do
      {%{} = wait, _} ->
        title = wait["title"] || "Waiting"
        code = wait["code"]
        phase = if waiting?, do: "waiting", else: "checking"

        if is_binary(code) and code != "",
          do: "#{title} · #{code} · #{phase}",
          else: "#{title} · #{phase}"

      {_, %{"attempt" => attempt, "max_attempts" => limit, "code" => code, "delay_ms" => delay}} ->
        phase = if waiting?, do: "waiting #{ceil(delay / 1_000)}s", else: "requesting"
        "Retry #{attempt}/#{limit} · #{code} · #{phase}"

      _ ->
        "retrying"
    end
  end

  defp status_priority("running"), do: 0
  defp status_priority("pending"), do: 1
  defp status_priority("waiting"), do: 2
  defp status_priority(_), do: 3

  defp find_conversation_failure(docs) do
    docs
    |> Enum.sort_by(fn {cid, _} -> cid end)
    |> Enum.find_value(:none, fn {_cid, conv_docs} ->
      live = Map.get(conv_docs, "live") || %{}

      case Map.get(live, "run_failure") || Map.get(live, "compaction_failure") do
        failure when is_map(failure) ->
          raw =
            Map.get(failure, "code") ||
              Map.get(failure, "reason") ||
              "error"

          {:ok, Catalog.sanitize_activity_label(to_string(raw)) || "error"}

        _ ->
          nil
      end
    end)
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
      if worker[:abort_ref], do: send(worker.pid, {:abort_exec, worker.abort_ref})
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
