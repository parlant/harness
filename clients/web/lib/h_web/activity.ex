defmodule HWeb.Activity do
  @moduledoc "Compact transcript activity with references for on-demand tool inspection."

  defstruct [:id, tools: %{}, other: 0]

  @type t :: %__MODULE__{id: String.t() | nil, tools: map(), other: non_neg_integer()}

  @active_slots ~w(pending running waiting retrying)

  def from_entry(%{"id" => id, "kind" => kind, "data" => data}) do
    activity = %__MODULE__{id: id}

    case kind do
      "assistant" ->
        after_message(%{"id" => id, "kind" => kind, "data" => data}) || %{activity | other: 1}

      "tool_result" ->
        tool = %{tool_ref(data) | result_entry: id, name: data["tool_name"] || data["name"]}
        %{activity | tools: %{(data["tool_call_id"] || {:result, id}) => tool}}

      _ ->
        %{activity | other: 1}
    end
  end

  @doc "Returns tool activity attached to an otherwise visible message, if any."
  def after_message(%{"kind" => "assistant", "id" => id, "data" => data}) do
    tools =
      for {call, index} <- Enum.with_index(List.wrap(data["tool_calls"])),
          is_map(call),
          call["name"] != "subagent",
          into: %{} do
        {call["id"] || {:call, id, index}, %{tool_ref(call) | call_entry: id, call_index: index}}
      end

    if map_size(tools) > 0, do: %__MODULE__{id: id, tools: tools}
  end

  def after_message(_), do: nil

  # Keep the ID of the row already in the browser when joining older pages.
  def merge(nil, activity), do: activity
  def merge(activity, nil), do: activity

  def merge(activity, added) do
    %{
      activity
      | tools: merge_tools(activity.tools, added.tools),
        other: activity.other + added.other
    }
  end

  def summary(activity) do
    tools =
      activity.tools
      |> Map.values()
      |> Enum.sort_by(fn tool ->
        id = tool.call_entry || tool.result_entry
        {is_nil(id), id && String.to_integer(id), tool.call_index, tool.live_id}
      end)

    %{
      id: activity.id,
      count: if(tools == [], do: activity.other, else: length(tools)),
      tools: tools
    }
  end

  @doc "Adds streaming calls and active tool slots to the trailing activity."
  def live_summary(tail, live, message, streaming_text?) do
    slots = live_slots(live["tools"])
    active_slots = Enum.filter(slots, fn {_id, slot} -> slot["status"] in @active_slots end)
    waiting_subagents? = Enum.any?(active_slots, fn {_id, slot} -> slot["name"] == "subagent" end)

    streaming =
      for %{"id" => id} = call <- List.wrap(message["tool_calls"]),
          is_binary(id),
          call["name"] != "subagent",
          do: {id, call}

    active = Enum.reject(active_slots, fn {_id, slot} -> slot["name"] == "subagent" end)

    live_tools =
      for {id, call} <- streaming ++ active, into: %{}, do: {id, %{tool_ref(call) | live_id: id}}

    extra = Enum.count([live["compaction"], live["user_shell"]], &is_map/1)
    activity = tail || %__MODULE__{}

    activity = %{
      activity
      | tools: merge_tools(activity.tools, live_tools),
        other: activity.other + extra
    }

    summary = summary(activity)

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

        map_size(live_tools) > 0 or extra > 0 ->
          :working

        waiting_subagents? ->
          :waiting

        !streaming_text? and (live["run"] || live["generation"]) ->
          :working

        true ->
          nil
      end

    if summary.count > 0 or (status in [:working, :retrying, :waiting] and not waiting_subagents?) do
      Map.put(summary, :status, status)
    end
  end

  @doc "Resolves a tool from the selected conversation's entries and its live document."
  def inspect_tool(params, live, fetch_entry) do
    call =
      with index when is_binary(index) <- params["call_index"],
           {index, ""} when index >= 0 <- Integer.parse(index),
           %{"kind" => "assistant", "data" => data} <- fetch_entry.(params["call_entry"]),
           %{} = call <- Enum.at(List.wrap(data["tool_calls"]), index) do
        call
      else
        _ -> nil
      end

    result =
      case fetch_entry.(params["result_entry"]) do
        %{"kind" => "tool_result", "data" => data} -> data
        _ -> nil
      end

    live_id = params["live_id"]
    generation = live["generation"] || %{}
    message = generation["message"] || generation

    streaming =
      live_id && Enum.find(List.wrap(message["tool_calls"]), &match?(%{"id" => ^live_id}, &1))

    slot = live_id && List.keyfind(live_slots(live["tools"]), live_id, 0)
    slot = if slot, do: elem(slot, 1)
    source = call || streaming || result || slot

    ids = Enum.reject([call && call["id"], result && result["tool_call_id"], live_id], &is_nil/1)

    if source && length(Enum.uniq(ids)) <= 1 do
      %{
        name: source["name"] || source["tool_name"] || "Tool call",
        arguments: (call || streaming || %{})["arguments"],
        result: result,
        output: slot && slot["output"],
        live?: not is_nil(streaming || slot)
      }
    end
  end

  defp tool_ref(data) do
    %{name: data["name"], call_entry: nil, call_index: nil, result_entry: nil, live_id: nil}
  end

  defp merge_tools(first, second) do
    Map.merge(first, second, fn _, a, b ->
      Map.merge(a, b, fn _, left, right -> left || right end)
    end)
  end

  defp live_slots(tools) when is_map(tools) do
    for {id, %{} = slot} <- tools, is_binary(id), do: {id, slot}
  end

  defp live_slots(tools) when is_list(tools) do
    for %{"id" => id} = slot <- tools, is_binary(id), do: {id, slot}
  end

  defp live_slots(_), do: []
end
