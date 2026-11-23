defmodule HWeb.Transcript do
  @moduledoc """
  Thin Phoenix LiveView state wrapper around `H.Transcript`.

  Delegates frame reduction to `H.Transcript` and projects messages and activity
  summaries for `Phoenix.LiveView.stream/4`. Only the boundary groups are kept
  for merging commits and older pages; the trailing group is rendered separately
  so its status can change with live docs without re-rendering committed messages.
  """

  alias HWeb.{Activity, ConversationComponents}

  defstruct [:reducer, :head_activity, :tail_activity]

  @type t :: %__MODULE__{
          reducer: H.Transcript.t(),
          head_activity: Activity.t() | nil,
          tail_activity: Activity.t() | nil
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

        {:ok, rows,
         %__MODULE__{reducer: %{next | entries: []}, head_activity: head, tail_activity: tail}}

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

            is_nil(wrapper.head_activity) and not Enum.any?(rows, &(not subagent_result?(&1))) ->
              head

            true ->
              wrapper.head_activity
          end

        {:ok, rows,
         %{wrapper | reducer: %{next | entries: []}, head_activity: head, tail_activity: tail}}

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
      {:ok, next} -> {:ok, %{wrapper | reducer: next}}
      :ignored -> :ignored
      {:error, _} = err -> err
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
          non_subagent_rows? = Enum.any?(rows, &(not subagent_result?(&1)))

          {rows, if(not non_subagent_rows?, do: wrapper.head_activity, else: head),
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

    {rows, %{wrapper | reducer: %{next | entries: []}, head_activity: head, tail_activity: tail}}
  end

  # Fold one page or commit into display rows. A visible message closes the
  # preceding group and may start a new one if it also contains tool calls.
  defp project(entries, tail) do
    {rows, tail, head} =
      Enum.reduce(entries, {[], tail, nil}, fn raw, {rows, pending, head} ->
        entry = normalize_entry(raw)

        cond do
          subagent_result?(entry) ->
            {[entry | rows], pending, head}

          ConversationComponents.message?(entry) ->
            head = if rows == [], do: pending, else: head
            rows = if pending, do: [activity_row(pending) | rows], else: rows
            {[entry | rows], Activity.after_message(entry), head}

          true ->
            {rows, Activity.merge(pending, Activity.from_entry(entry)), head}
        end
      end)

    {Enum.reverse(rows), if(Enum.any?(rows, &(not subagent_result?(&1))), do: head, else: tail),
     tail}
  end

  defp subagent_result?(%{"kind" => "tool_result", "data" => data}) when is_map(data) do
    (data["tool_name"] || data["name"]) == "subagent"
  end

  defp subagent_result?(_), do: false

  defp activity_row(activity),
    do: %{"id" => "activity-#{activity.id}", "activity" => Activity.summary(activity)}

  defp same_group?(%Activity{id: id}, %Activity{id: id}), do: true
  defp same_group?(_, _), do: false

  @doc "Extracts compact Phoenix assigns from the underlying `H.Transcript`."
  @spec compact_assigns(t()) :: map()
  def compact_assigns(%__MODULE__{reducer: r, tail_activity: tail}) do
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

  defp normalize_entry(entry) do
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
end
