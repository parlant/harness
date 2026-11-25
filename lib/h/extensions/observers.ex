defmodule H.Extensions.Observers do
  @moduledoc """
  Bounded, non-blocking supervised consumer for post-commit advisory
  `H.Extension.Observer` callbacks (`command_committed/1`, `work_settled/1`).

  All invocations are strictly asynchronous (`GenServer.cast/2`), occur only
  after `H.Storage.commit/2` succeeds, drop newest events once the bounded
  queue reaches 256 items, and wrap observer callbacks in
  `try/rescue/catch` so observer errors never crash the consumer or block
  `H.Session.Server`.
  """

  use GenServer

  @max_queue_len 256
  @max_string_bytes 512

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    observers = Keyword.get(opts, :observers, [])
    {name, _rest} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, observers, gen_opts)
  end

  @doc """
  Asynchronously dispatches an advisory `:command_committed` or `:work_settled`
  event to `server` when running. Never blocks callers.
  """
  @spec notify(GenServer.server() | nil, :command_committed | :work_settled, map()) :: :ok
  def notify(nil, _kind, _payload), do: :ok

  def notify(server, kind, payload)
      when kind in [:command_committed, :work_settled] and is_map(payload) do
    case resolve_target(server) do
      nil ->
        :ok

      target ->
        GenServer.cast(target, {:event, kind, sanitize_event(kind, payload)})
    end
  end

  @doc "Returns the maximum queue depth enforced by `H.Extensions.Observers`."
  @spec max_queue_len() :: pos_integer()
  def max_queue_len, do: @max_queue_len

  @impl true
  def init(observers) when is_list(observers) do
    valid = Enum.filter(observers, &is_atom/1)
    {:ok, %{observers: valid, queue: :queue.new(), queue_len: 0, scheduled: false}}
  end

  @impl true
  def handle_cast({:event, _kind, _payload}, %{observers: []} = state) do
    {:noreply, state}
  end

  def handle_cast({:event, kind, payload}, state) do
    if state.queue_len >= @max_queue_len do
      {:noreply, state}
    else
      queue = :queue.in({kind, payload}, state.queue)
      state = %{state | queue: queue, queue_len: state.queue_len + 1}
      {:noreply, maybe_schedule_drain(state)}
    end
  end

  @impl true
  def handle_info(:drain, state) do
    state = %{state | scheduled: false}

    case :queue.out(state.queue) do
      {{:value, {kind, payload}}, rest} ->
        dispatch_to_observers(state.observers, kind, payload)
        next_state = %{state | queue: rest, queue_len: state.queue_len - 1}
        {:noreply, maybe_schedule_drain(next_state)}

      {:empty, _} ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_schedule_drain(%{queue_len: len, scheduled: false} = state) when len > 0 do
    send(self(), :drain)
    %{state | scheduled: true}
  end

  defp maybe_schedule_drain(state), do: state

  defp dispatch_to_observers(observers, kind, payload) do
    Enum.each(observers, fn mod ->
      if Code.ensure_loaded?(mod) and function_exported?(mod, kind, 1) do
        try do
          apply(mod, kind, [payload])
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end
    end)
  end

  defp resolve_target(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid, else: nil
  end

  defp resolve_target(name) when is_atom(name) do
    Process.whereis(name)
  end

  defp resolve_target({:via, _, _} = via) do
    GenServer.whereis(via)
  end

  defp resolve_target(_), do: nil

  defp sanitize_event(:command_committed, payload) do
    %{
      session_id: to_string(Map.get(payload, :session_id, "")),
      conversation_id: to_string(Map.get(payload, :conversation_id, "")),
      seq: Map.get(payload, :seq, 0),
      command: sanitize_string(Map.get(payload, :command)),
      receipt: sanitize_receipt(Map.get(payload, :receipt))
    }
  end

  defp sanitize_event(:work_settled, payload) do
    %{
      session_id: to_string(Map.get(payload, :session_id, "")),
      conversation_id: to_string(Map.get(payload, :conversation_id, "")),
      seq: Map.get(payload, :seq, 0),
      task_id: to_string(Map.get(payload, :task_id, "")),
      task_kind: sanitize_string(Map.get(payload, :task_kind)),
      outcome: sanitize_outcome(Map.get(payload, :outcome))
    }
  end

  defp sanitize_receipt(receipt) when is_map(receipt) do
    receipt
    |> take_keys([
      :version,
      "version",
      :request_id,
      "request_id",
      :conversation_id,
      "conversation_id",
      :submission_id,
      "submission_id",
      :status,
      "status",
      :reason,
      "reason",
      :seq,
      "seq"
    ])
    |> sanitize_map()
  end

  defp sanitize_receipt(_), do: %{}

  defp sanitize_outcome(outcome) when is_map(outcome) do
    outcome
    |> take_keys([
      :status,
      "status",
      :reason,
      "reason",
      :entry_id,
      "entry_id",
      :answer_entry_id,
      "answer_entry_id",
      :is_error,
      "is_error",
      :diagnostic,
      "diagnostic",
      :kept_from_id,
      "kept_from_id"
    ])
    |> sanitize_map()
  end

  defp sanitize_outcome(_), do: %{}

  defp take_keys(map, keys) do
    Enum.reduce(keys, %{}, fn k, acc ->
      case Map.fetch(map, k) do
        {:ok, val} -> Map.put(acc, to_string(k), val)
        :error -> acc
      end
    end)
  end

  defp sanitize_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      case sanitize_scalar(v) do
        {:ok, clean} -> Map.put(acc, k, clean)
        :drop -> acc
      end
    end)
  end

  defp sanitize_scalar(v) when is_boolean(v) or is_integer(v) or is_float(v) or is_nil(v),
    do: {:ok, v}

  defp sanitize_scalar(v) when is_atom(v), do: {:ok, Atom.to_string(v)}
  defp sanitize_scalar(v) when is_binary(v), do: {:ok, sanitize_string(v)}
  defp sanitize_scalar(_), do: :drop

  defp sanitize_string(nil), do: ""

  defp sanitize_string(val) do
    val
    |> to_string()
    |> H.Credentials.sanitize()
    |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
    |> String.slice(0, @max_string_bytes)
  end
end
