defmodule H.Task do
  @moduledoc """
  Versioned durable task record (`generation`, `tool_call`) and pure state
  transitions (`pending`, `running`, `waiting`, `sleeping`, `terminal`).
  """

  @doc "Constructs a new durable task map."
  @spec new(map()) :: map()
  def new(attrs) when is_map(attrs) do
    now = Map.get(attrs, :created_at) || System.system_time(:millisecond)

    %{
      id: Map.fetch!(attrs, :id),
      kind: Map.fetch!(attrs, :kind),
      version: Map.get(attrs, :version, 1),
      status: Map.get(attrs, :status, "pending"),
      owner: Map.fetch!(attrs, :owner),
      checkpoint: Map.get(attrs, :checkpoint, %{}),
      outcome: Map.get(attrs, :outcome),
      restarts: Map.get(attrs, :restarts, 0),
      memos: Map.get(attrs, :memos, %{}),
      cancel: Map.get(attrs, :cancel),
      cancelled: Map.get(attrs, :cancelled, false),
      abort_reason: Map.get(attrs, :abort_reason),
      wake: Map.get(attrs, :wake),
      started_at: Map.get(attrs, :started_at),
      ended_at: Map.get(attrs, :ended_at),
      created_at: now,
      updated_at: Map.get(attrs, :updated_at, now),
      blocked: Map.get(attrs, :blocked)
    }
  end

  @doc "Normalizes a task loaded from storage."
  @spec from_storage(map()) :: map()
  def from_storage(raw) when is_map(raw) do
    %{
      id: Map.fetch!(raw, :id),
      kind: Map.fetch!(raw, :kind),
      version: Map.get(raw, :version, 1),
      status: Map.get(raw, :status, "pending"),
      owner: Map.get(raw, :owner, :ownerless),
      checkpoint: Map.get(raw, :checkpoint) || %{},
      outcome: Map.get(raw, :outcome),
      restarts: Map.get(raw, :restarts, 0),
      memos: Map.get(raw, :memos) || %{},
      cancel: Map.get(raw, :cancel),
      cancelled: Map.get(raw, :cancelled, false) == true,
      abort_reason: Map.get(raw, :abort_reason),
      wake: Map.get(raw, :wake),
      started_at: Map.get(raw, :started_at),
      ended_at: Map.get(raw, :ended_at),
      created_at: Map.get(raw, :created_at),
      updated_at: Map.get(raw, :updated_at),
      blocked: Map.get(raw, :blocked)
    }
  end

  @doc "Transitions a task to `running` with a new `attempt_id`."
  @spec start_running(map(), pos_integer(), integer(), map()) :: map()
  def start_running(task, attempt_id, now, checkpoint_updates \\ %{}) do
    checkpoint =
      (task.checkpoint || %{})
      |> Map.merge(checkpoint_updates)
      |> Map.put("attempt_id", attempt_id)

    %{
      task
      | status: "running",
        checkpoint: checkpoint,
        wake: nil,
        started_at: task.started_at || now,
        updated_at: now
    }
  end

  @doc "Transitions a task to `waiting` (e.g. generation waiting on child tool calls)."
  @spec start_waiting(map(), integer(), map()) :: map()
  def start_waiting(task, now, checkpoint_updates \\ %{}) do
    %{
      task
      | status: "waiting",
        checkpoint: Map.merge(task.checkpoint || %{}, checkpoint_updates),
        updated_at: now
    }
  end

  @doc "Transitions a task to `sleeping` until `until_ms`."
  @spec sleep_until(map(), integer(), String.t(), integer(), map()) :: map()
  def sleep_until(task, until_ms, wake_reason, now, checkpoint_updates \\ %{}) do
    %{
      task
      | status: "sleeping",
        wake: %{"until" => until_ms, "reason" => wake_reason},
        checkpoint: Map.merge(task.checkpoint || %{}, checkpoint_updates),
        updated_at: now
    }
  end

  @doc "Transitions a task to `terminal` with an outcome map."
  @spec complete(map(), map(), integer()) :: map()
  def complete(task, outcome, now) do
    %{
      task
      | status: "terminal",
        outcome: outcome,
        wake: nil,
        ended_at: now,
        updated_at: now
    }
  end

  @doc "Transitions a task to `terminal` due to cancellation/abort."
  @spec abort(map(), String.t(), integer()) :: map()
  def abort(task, reason, now) do
    %{
      task
      | status: "terminal",
        cancelled: true,
        abort_reason: reason,
        outcome: %{"status" => "aborted", "reason" => reason},
        wake: nil,
        ended_at: now,
        updated_at: now
    }
  end

  @doc "Resets a `running` task back to `pending` on clean shutdown without incrementing restarts."
  @spec reset_clean(map(), integer()) :: map()
  def reset_clean(task, now) do
    %{
      task
      | status: "pending",
        updated_at: now
    }
  end

  @doc "Increments `restarts` on unclean crash recovery."
  @spec increment_restart(map(), integer()) :: map()
  def increment_restart(task, now) do
    %{
      task
      | restarts: (task.restarts || 0) + 1,
        updated_at: now
    }
  end

  @doc "Formats a task for `H.Daemon.get_session_detail/2`."
  @spec to_wire(map()) :: map()
  def to_wire(task) when is_map(task) do
    %{
      id: to_string(task.id),
      kind: task.kind,
      version: task.version,
      status: task.status,
      owner: wire_owner(task.owner),
      restarts: task.restarts || 0,
      cancelled: task.cancelled == true,
      abort_reason: task.abort_reason,
      wake: task.wake,
      outcome: task.outcome,
      created_at: task.created_at,
      updated_at: task.updated_at
    }
  end

  defp wire_owner(:ownerless), do: "ownerless"
  defp wire_owner({:conversation, cid}), do: "conversation:#{cid}"
  defp wire_owner({:task, tid}), do: "task:#{tid}"
  defp wire_owner(other) when is_binary(other), do: other
  defp wire_owner(_), do: "ownerless"
end
