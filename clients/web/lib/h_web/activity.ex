defmodule HWeb.Activity do
  @moduledoc "Compact transcript activity, with tool calls and their results counted once."

  defstruct [:id, calls: MapSet.new(), results: MapSet.new(), other: 0, outcome: :complete]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          calls: MapSet.t(String.t()),
          results: MapSet.t(String.t()),
          other: non_neg_integer(),
          outcome: :complete | :stopped | :interrupted | :failed
        }

  @outcomes [:failed, :interrupted, :stopped, :complete]
  @active_slots ~w(pending running waiting retrying)

  def from_entry(%{"id" => id, "kind" => kind, "data" => data}) do
    activity = %__MODULE__{id: id, outcome: outcome(data)}

    case {kind, data} do
      {"assistant", _} ->
        case call_ids(data) do
          [] -> %{activity | other: 1}
          calls -> add_calls(activity, calls)
        end

      {"tool_result", %{"tool_call_id" => id}} when is_binary(id) ->
        %{activity | results: MapSet.new([id])}

      _ ->
        %{activity | other: 1}
    end
  end

  @doc "Returns activity attached to an otherwise visible message, if any."
  def after_message(%{"kind" => "assistant", "data" => data} = entry) do
    non_subagent_calls =
      for call <- List.wrap(data["tool_calls"]),
          is_map(call),
          call["name"] != "subagent",
          do: call

    if non_subagent_calls != [] do
      from_entry(put_in(entry["data"]["tool_calls"], non_subagent_calls))
    end
  end

  def after_message(_), do: nil

  # Keep the ID of the row already in the browser when joining older pages.
  def merge(nil, activity), do: activity
  def merge(activity, nil), do: activity

  def merge(activity, added) do
    %{
      activity
      | calls: MapSet.union(activity.calls, added.calls),
        results: MapSet.union(activity.results, added.results),
        other: activity.other + added.other,
        outcome: Enum.find(@outcomes, &(&1 in [activity.outcome, added.outcome]))
    }
  end

  defp count(activity) do
    MapSet.size(MapSet.union(activity.calls, activity.results)) + activity.other
  end

  defp status(activity) do
    cond do
      activity.outcome != :complete -> activity.outcome
      MapSet.subset?(activity.calls, activity.results) -> :complete
      true -> :incomplete
    end
  end

  def summary(activity), do: %{count: count(activity), status: status(activity)}

  @doc "Adds live work to the trailing activity without including output or arguments."
  def live_summary(tail, live, message, streaming_text?) do
    calls = call_ids(message) ++ active_tools(live["tools"])
    extra = Enum.count([live["compaction"], live["user_shell"]], &is_map/1)
    activity = add_calls(tail || %__MODULE__{}, calls)
    activity = %{activity | other: activity.other + extra}
    count = count(activity)
    waiting_subagents? = active_subagents?(live["tools"])

    status =
      cond do
        live["run_failure"] || live["compaction_failure"] ->
          :paused

        live["workspace_wait"] ->
          :waiting

        wait = get_in(live, ["generation", "wait"]) || get_in(live, ["compaction", "wait"]) ->
          if wait["status"] == "waiting", do: :waiting, else: :retrying

        get_in(live, ["generation", "retry"]) || get_in(live, ["compaction", "retry"]) ->
          :retrying

        calls != [] or extra > 0 ->
          :working

        waiting_subagents? ->
          :waiting

        !streaming_text? and (live["run"] || live["generation"]) ->
          :working

        count > 0 ->
          status(activity)

        true ->
          nil
      end

    cond do
      status == :waiting and waiting_subagents? and count == 0 -> nil
      status in [:working, :retrying, :waiting] and count == 0 -> %{count: 1, status: status}
      count > 0 -> %{count: count, status: status}
      true -> nil
    end
  end

  defp outcome(data) do
    cond do
      data["aborted"] || data["cancelled"] || data["diagnostic"] == "aborted" ->
        :stopped

      data["interrupted"] || data["diagnostic"] == "interrupted" ->
        :interrupted

      data["is_error"] || data["error"] ||
        data["status"] in ~w(error failed) ||
          data["finish_reason"] in ~w(error content_filter) ->
        :failed

      is_integer(data["exit_code"]) and data["exit_code"] != 0 ->
        :failed

      true ->
        :complete
    end
  end

  defp call_ids(data) do
    for call <- List.wrap(data["tool_calls"]), is_map(call), do: call["id"]
  end

  defp add_calls(activity, calls) do
    Enum.reduce(calls, activity, fn
      id, acc when is_binary(id) -> %{acc | calls: MapSet.put(acc.calls, id)}
      _, acc -> %{acc | other: acc.other + 1}
    end)
  end

  defp active_tools(tools) when is_map(tools) do
    for {id, %{"status" => status} = slot} <- tools,
        status in @active_slots,
        slot["name"] != "subagent",
        do: id
  end

  defp active_tools(tools) when is_list(tools) do
    for %{"status" => status} = slot <- tools,
        status in @active_slots,
        slot["name"] != "subagent",
        do: slot["id"]
  end

  defp active_tools(_), do: []

  defp active_subagents?(tools) when is_map(tools) do
    Enum.any?(tools, fn {_id, slot} ->
      is_map(slot) and slot["name"] == "subagent" and slot["status"] in @active_slots
    end)
  end

  defp active_subagents?(tools) when is_list(tools) do
    Enum.any?(tools, fn slot ->
      is_map(slot) and slot["name"] == "subagent" and slot["status"] in @active_slots
    end)
  end

  defp active_subagents?(_), do: false
end
