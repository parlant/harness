defmodule HWeb.Transcript do
  @moduledoc """
  Thin Phoenix LiveView state wrapper around `H.Transcript`.

  Delegates frame reduction to `H.Transcript` and projects messages and activity
  summaries for `Phoenix.LiveView.stream/4`. Retains boundary activity groups
  and compact subagent metadata (not result bodies) to merge pages and update
  cards. The trailing activity group is rendered separately for live work.
  """

  alias HWeb.{Activity, ConversationComponents, SubagentCards}

  defstruct [
    :reducer,
    :head_activity,
    :tail_activity,
    subagent_events: [],
    subagent_rows: %{},
    turn_metrics: [],
    last_entry_at: nil
  ]

  @type turn_metric :: %{
          entry_id: String.t(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          duration_ms: non_neg_integer() | nil,
          tps: float() | nil
        }

  @type t :: %__MODULE__{
          reducer: H.Transcript.t(),
          head_activity: Activity.t() | nil,
          tail_activity: Activity.t() | nil,
          subagent_events: [map()],
          subagent_rows: map(),
          turn_metrics: [turn_metric()],
          last_entry_at: integer() | nil
        }

  @doc "Creates a new empty `HWeb.Transcript`."
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    %__MODULE__{reducer: H.Transcript.new(opts)}
  end

  @doc "Applies a `snapshot` payload via `H.Transcript.apply_snapshot/2`."
  @spec apply_snapshot(t(), map() | binary()) :: {:ok, [map()], t()} | {:error, term()}
  def apply_snapshot(%__MODULE__{reducer: reducer}, payload) do
    case H.Transcript.apply_snapshot(reducer, payload) do
      {:ok, next} ->
        {rows, head, tail} = project(next.entries, nil)
        {metrics, last_at} = extract_turn_metrics(next.entries, nil)

        wrapper = %__MODULE__{
          reducer: %{next | entries: []},
          head_activity: head,
          tail_activity: tail,
          turn_metrics: metrics,
          last_entry_at: last_at
        }

        {rows, wrapper} = with_subagent_rows(wrapper, rows, nil, :append)
        {:ok, rows, wrapper}

      {:error, _} = err ->
        err
    end
  end

  @doc "Applies a `commit` payload via `H.Transcript.apply_commit/2`."
  @spec apply_commit(t(), map() | binary()) ::
          {:ok, [map()], t()} | {:gap, t()} | {:stale, t()} | {:error, term()}
  def apply_commit(%__MODULE__{reducer: reducer} = wrapper, payload) do
    case H.Transcript.apply_commit(reducer, payload) do
      {:ok, next, %{appended_entries: appended}} ->
        {rows, head, tail} = project(appended, wrapper.tail_activity)

        head =
          cond do
            MapSet.size(reducer.entry_ids) == 0 ->
              head

            same_group?(wrapper.head_activity, wrapper.tail_activity) ->
              head

            is_nil(wrapper.head_activity) and not Enum.any?(rows, &ordinary_row?/1) ->
              head

            true ->
              wrapper.head_activity
          end

        previous_live = reducer.docs["live"]
        {new_metrics, last_at} = extract_turn_metrics(appended, wrapper.last_entry_at)

        wrapper = %{
          wrapper
          | reducer: %{next | entries: []},
            head_activity: head,
            tail_activity: tail,
            turn_metrics: merge_turn_metrics(wrapper.turn_metrics, new_metrics, :append),
            last_entry_at: last_at || wrapper.last_entry_at
        }

        {rows, wrapper} = with_subagent_rows(wrapper, rows, previous_live, :append)
        {:ok, rows, wrapper}

      {:gap, _next} ->
        {:gap, wrapper}

      {:stale, _next} ->
        {:stale, wrapper}

      {:error, _} = err ->
        err
    end
  end

  @doc "Applies an `ephemeral` payload via `H.Transcript.apply_ephemeral/2`."
  @spec apply_ephemeral(t(), map() | binary()) :: {:ok, t()} | :ignored | {:error, term()}
  def apply_ephemeral(%__MODULE__{reducer: reducer} = wrapper, payload) do
    case H.Transcript.apply_ephemeral(reducer, payload) do
      {:ok, next} ->
        updated =
          if SubagentCards.slots(reducer.docs["live"]) == SubagentCards.slots(next.docs["live"]) do
            %{wrapper | reducer: next}
          else
            {[], updated} =
              with_subagent_rows(%{wrapper | reducer: next}, [], reducer.docs["live"], :append)

            updated
          end

        {:ok, updated}

      :ignored ->
        :ignored

      {:error, _} = err ->
        err
    end
  end

  @doc "Prepends an older page of entries via `H.Transcript.prepend_older_page/3`."
  @spec prepend_older_page(t(), [map()], String.t() | integer() | nil) :: {[map()], t()}
  def prepend_older_page(%__MODULE__{reducer: reducer} = wrapper, items, next_cursor) do
    next = H.Transcript.prepend_older_page(reducer, items, next_cursor)
    {rows, head, tail} = project(next.entries, nil)

    {rows, head, tail} =
      cond do
        MapSet.size(reducer.entry_ids) == 0 ->
          {rows, head, tail}

        is_nil(tail) ->
          {rows, if(Enum.any?(rows, &ordinary_row?/1), do: head, else: wrapper.head_activity),
           wrapper.tail_activity}

        is_nil(wrapper.head_activity) ->
          {rows ++ [activity_row(tail)], head, wrapper.tail_activity}

        true ->
          merged = Activity.merge(wrapper.head_activity, tail)
          head = if same_group?(head, tail), do: merged, else: head

          if same_group?(wrapper.head_activity, wrapper.tail_activity) do
            {rows, head, merged}
          else
            {rows ++ [activity_row(merged)], head, wrapper.tail_activity}
          end
      end

    {older_metrics, _} = extract_turn_metrics(next.entries, nil)

    wrapper = %{
      wrapper
      | reducer: %{next | entries: []},
        head_activity: head,
        tail_activity: tail,
        turn_metrics: merge_turn_metrics(wrapper.turn_metrics, older_metrics, :prepend)
    }

    with_subagent_rows(wrapper, rows, nil, :prepend)
  end

  # Subagent rows do not close ordinary tool activity. When prose and calls share
  # an entry, the prose is still its own message before the individual cards.
  defp project(entries, tail) do
    {rows, tail, head} =
      Enum.reduce(entries, {[], tail, nil}, fn raw, {rows, pending, head} ->
        entry = normalize_entry(raw)
        calls = SubagentCards.calls(entry)

        marks = for {call, index} <- calls, do: {:subagent_call, entry["id"], call, index}

        cond do
          SubagentCards.result?(entry) ->
            {[{:subagent_result, entry} | rows], pending, head}

          ConversationComponents.message?(entry) ->
            head = if Enum.any?(rows, &ordinary_row?/1), do: head, else: pending
            rows = if pending, do: [activity_row(pending) | rows], else: rows
            {Enum.reverse(marks, [entry | rows]), Activity.after_message(entry), head}

          calls != [] ->
            {Enum.reverse(marks, rows), Activity.merge(pending, Activity.after_message(entry)),
             head}

          true ->
            {rows, Activity.merge(pending, Activity.from_entry(entry)), head}
        end
      end)

    {Enum.reverse(rows), if(Enum.any?(rows, &ordinary_row?/1), do: head, else: tail), tail}
  end

  defp ordinary_row?(row), do: is_map(row)

  defp with_subagent_rows(wrapper, rows, previous_live, direction) do
    previous_slots = SubagentCards.slots(previous_live)

    {rows, new_events} =
      Enum.map_reduce(rows, [], fn
        {:subagent_call, id, call, index}, events ->
          event = SubagentCards.call_event(id, call, index)
          {event.id, [event | events]}

        {:subagent_result, entry}, events ->
          event = SubagentCards.result_event(entry, previous_slots)
          {event.id, [event | events]}

        row, events ->
          {row, events}
      end)

    new_events = Enum.reverse(new_events)

    events =
      case direction do
        :append ->
          if new_events == [],
            do: wrapper.subagent_events,
            else: wrapper.subagent_events ++ new_events

        :prepend ->
          new_events ++ wrapper.subagent_events
      end

    slots = SubagentCards.slots(wrapper.reducer.docs["live"])

    cards =
      if new_events == [] and slots == previous_slots,
        do: wrapper.subagent_rows,
        else: SubagentCards.project(events, slots)

    rows = Enum.map(rows, fn row -> if is_binary(row), do: cards[row], else: row end)
    {Enum.reject(rows, &is_nil/1), %{wrapper | subagent_events: events, subagent_rows: cards}}
  end

  defp activity_row(activity),
    do: %{"id" => "activity-#{activity.id}", "activity" => Activity.summary(activity)}

  defp same_group?(%Activity{id: id}, %Activity{id: id}), do: true
  defp same_group?(_, _), do: false

  @doc "Extracts compact Phoenix assigns from the underlying `H.Transcript`."
  @spec compact_assigns(t()) :: map()
  def compact_assigns(%__MODULE__{reducer: r, tail_activity: tail, turn_metrics: turn_metrics}) do
    docs = r.docs || %{}
    committed = r.committed_docs || %{}
    live = Map.get(docs, "live") || %{}

    %{
      cursor_seq: r.seq,
      committed_docs: committed,
      ephemeral_live: live,
      tail_activity: tail,
      inbox: Map.get(docs, "inbox") || [],
      agent: Map.get(committed, "agent") || %{},
      usage: Map.get(committed, "usage") || %{},
      turn_metrics: turn_metrics,
      before_entry_id: r.before_entry_id,
      has_more: r.has_more,
      run_active?: run_active?(live)
    }
  end

  @doc "Returns `true` when `live` indicates active conversation work."
  @spec run_active?(map()) :: boolean()
  def run_active?(live) when is_map(live) do
    tools = Map.get(live, "tools")

    has_tools? =
      cond do
        is_list(tools) -> tools != []
        is_map(tools) -> map_size(tools) > 0
        true -> false
      end

    Enum.any?(~w(run generation compaction user_shell workspace_wait), &(not is_nil(live[&1]))) or
      has_tools?
  end

  def run_active?(_), do: false

  @doc false
  def normalize_entry(entry) do
    %{
      "id" => to_string(Map.get(entry, "id") || Map.get(entry, :id)),
      "conversation_id" =>
        to_string(Map.get(entry, "conversation_id") || Map.get(entry, :conversation_id) || "1"),
      "seq" => Map.get(entry, "seq") || Map.get(entry, :seq),
      "kind" => to_string(Map.get(entry, "kind") || Map.get(entry, :kind) || "entry"),
      "data" => stringify_top_keys(Map.get(entry, "data") || Map.get(entry, :data) || %{}),
      "created_at" => Map.get(entry, "created_at") || Map.get(entry, :created_at)
    }
  end

  defp stringify_top_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_nested(v)}
      {k, v} -> {k, stringify_nested(v)}
    end)
  end

  defp stringify_top_keys(other), do: other

  defp stringify_nested(list) when is_list(list), do: Enum.map(list, &stringify_nested/1)
  defp stringify_nested(map) when is_map(map), do: stringify_top_keys(map)
  defp stringify_nested(other), do: other

  defp extract_turn_metrics(entries, prev_at) do
    {rev_metrics, last_at} =
      Enum.reduce(entries, {[], prev_at}, fn raw, {acc, prev} ->
        entry = normalize_entry(raw)
        created_at = parse_timestamp(entry["created_at"])

        acc =
          if entry["kind"] == "assistant" do
            case build_turn_metric(entry, prev, created_at) do
              nil -> acc
              metric -> [metric | acc]
            end
          else
            acc
          end

        {acc, created_at || prev}
      end)

    {Enum.reverse(rev_metrics), last_at}
  end

  defp merge_turn_metrics(existing, [], _direction), do: existing

  defp merge_turn_metrics(existing, incoming, direction) do
    combined =
      case direction do
        :append -> existing ++ incoming
        :prepend -> incoming ++ existing
      end

    combined
    |> Enum.uniq_by(& &1.entry_id)
    |> Enum.take(-40)
  end

  defp build_turn_metric(entry, prev_at, created_at) do
    data = entry["data"] || %{}
    usage = if is_map(data["usage"]), do: data["usage"], else: %{}
    input = non_neg_int(usage["input_tokens"] || usage["input"])
    output = non_neg_int(usage["output_tokens"] || usage["output"])
    total = max(non_neg_int(usage["total_tokens"]), input + output)

    if total == 0 do
      nil
    else
      explicit_ms = positive_int(data["duration_ms"])

      fallback_ms =
        if is_integer(created_at) and is_integer(prev_at) and created_at > prev_at do
          created_at - prev_at
        end

      duration_ms = explicit_ms || fallback_ms

      tps =
        if is_integer(duration_ms) and duration_ms > 0 and output > 0 do
          Float.round(output * 1000.0 / duration_ms, 1)
        end

      %{
        entry_id: entry["id"],
        input_tokens: input,
        output_tokens: output,
        total_tokens: total,
        duration_ms: duration_ms,
        tps: tps
      }
    end
  end

  defp non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_), do: 0

  defp positive_int(n) when is_integer(n) and n > 0, do: n
  defp positive_int(_), do: nil

  defp parse_timestamp(n) when is_integer(n) and n > 0, do: n
  defp parse_timestamp(_), do: nil
end
