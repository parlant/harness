defmodule HWeb.SubagentCards do
  @moduledoc "Compact transcript projection for subagent calls and their subsessions."

  def calls(%{"kind" => "assistant", "data" => data}) do
    for {%{"name" => "subagent"} = call, index} <- Enum.with_index(List.wrap(data["tool_calls"])),
        do: {call, index}
  end

  def calls(_), do: []

  def result?(%{"kind" => "tool_result", "data" => data}) when is_map(data) do
    (data["tool_name"] || data["name"]) == "subagent"
  end

  def result?(_), do: false

  def call_event(entry_id, call, index) do
    args = call["arguments"] || call["args"] || call["input"]
    args = if is_map(args), do: args, else: %{}

    %{
      id: "subagent-call-#{entry_id}-#{index}",
      entry_id: entry_id,
      call_id: call["id"],
      child_id: present(args["session_id"]),
      title: present(args["title"]),
      prompt: present(args["prompt"]),
      status: nil
    }
  end

  def result_event(%{"id" => id, "data" => data}, previous_slots) do
    details = if is_map(data["details"]), do: data["details"], else: %{}
    call_id = data["tool_call_id"]

    %{
      id: "subagent-result-#{id}",
      entry_id: id,
      call_id: call_id,
      child_id:
        present(details["child_session_id"]) ||
          present(data["child_session_id"]) ||
          get_in(previous_slots, [call_id, :child_id]),
      title: present(details["title"]),
      prompt: present(details["prompt"]),
      status:
        cond do
          details["aborted"] == true or details["status"] == "aborted" -> "aborted"
          data["is_error"] == true or data["error"] != nil -> "failed"
          true -> present(details["status"]) || "done"
        end
    }
  end

  def slots(%{"tools" => tools}) when is_map(tools), do: subagent_slots(tools)

  def slots(%{"tools" => tools}) when is_list(tools) do
    subagent_slots(for(%{"id" => id} = slot <- tools, do: {id, slot}))
  end

  def slots(_), do: %{}

  defp subagent_slots(tools) do
    for {id, %{"name" => "subagent"} = slot} <- tools, is_binary(id), into: %{} do
      {id, %{child_id: present(slot["child_session_id"]), status: present(slot["status"])}}
    end
  end

  @doc "Pairs invocations in entry order, then consolidates them by child session."
  def project(events, slots) do
    # Match results to pending calls in order: providers can reuse a call ID
    # in a later round.
    {pending, pairs, matched_results} =
      Enum.reduce(events, {%{}, %{}, MapSet.new()}, fn event, {pending, pairs, matched} ->
        case event do
          %{status: nil, call_id: id} when is_binary(id) ->
            {Map.put(pending, id, event.id), pairs, matched}

          %{status: status, call_id: id} when not is_nil(status) ->
            case Map.pop(pending, id) do
              {nil, _} -> {pending, pairs, matched}
              {call, next} -> {next, Map.put(pairs, call, event), MapSet.put(matched, event.id)}
            end

          _ ->
            {pending, pairs, matched}
        end
      end)

    events
    |> Enum.reject(&MapSet.member?(matched_results, &1.id))
    |> Enum.reduce(%{}, fn event, cards ->
      result = pairs[event.id]
      slot = if pending[event.call_id] == event.id, do: slots[event.call_id]

      card = %{
        id: event.id,
        entry_id: (result && result.entry_id) || event.entry_id,
        child_id: (result && result.child_id) || (slot && slot.child_id) || event.child_id,
        title: event.title || (result && result.title),
        prompt: event.prompt || (result && result.prompt),
        status:
          (result && result.status) || event.status || (slot && slot.status) || "interrupted"
      }

      key = card.child_id || card.id

      Map.update(cards, key, card, fn first ->
        %{
          first
          | title: first.title || card.title,
            prompt: first.prompt || card.prompt,
            status: card.status
        }
      end)
    end)
    |> Map.new(fn {_, card} -> {card.id, %{"id" => card.id, "subagent" => card}} end)
  end

  defp present(value) when is_binary(value) do
    if String.trim(value) != "", do: value
  end

  defp present(_), do: nil
end
