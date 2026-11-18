defmodule HWeb.Transcript do
  @moduledoc """
  Thin Phoenix LiveView state wrapper around `H.Transcript`.

  Delegates all frame reduction (`apply_snapshot/2`, `apply_commit/2`,
  `apply_ephemeral/2`, `prepend_older_page/3`) to `H.Transcript`, emits entry
  lists for `Phoenix.LiveView.stream/4`, and clears committed entry bodies from
  the retained struct so the LiveView process only keeps compact doc/cursor state.
  """

  defstruct [:reducer]

  @type t :: %__MODULE__{
          reducer: H.Transcript.t()
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
        entries = Enum.map(next.entries, &normalize_entry/1)
        {:ok, entries, %__MODULE__{reducer: %{next | entries: []}}}

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
        entries = Enum.map(appended, &normalize_entry/1)
        {:ok, entries, %__MODULE__{reducer: %{next | entries: []}}}

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
  def apply_ephemeral(%__MODULE__{reducer: reducer}, payload) do
    case H.Transcript.apply_ephemeral(reducer, payload) do
      {:ok, next} -> {:ok, %__MODULE__{reducer: %{next | entries: []}}}
      :ignored -> :ignored
      {:error, _} = err -> err
    end
  end

  @doc "Prepends an older page of entries via `H.Transcript.prepend_older_page/3`."
  @spec prepend_older_page(t(), [map()], String.t() | integer() | nil) :: {[map()], t()}
  def prepend_older_page(%__MODULE__{reducer: reducer}, items, next_cursor) when is_list(items) do
    next = H.Transcript.prepend_older_page(reducer, items, next_cursor)
    entries = Enum.map(next.entries, &normalize_entry/1)
    {entries, %__MODULE__{reducer: %{next | entries: []}}}
  end

  @doc "Extracts compact Phoenix assigns from the underlying `H.Transcript`."
  @spec compact_assigns(t()) :: map()
  def compact_assigns(%__MODULE__{reducer: r}) do
    docs = r.docs || %{}
    committed = r.committed_docs || %{}
    live = Map.get(docs, "live") || %{}

    %{
      cursor_seq: r.seq,
      committed_docs: committed,
      ephemeral_live: live,
      inbox: Map.get(docs, "inbox") || [],
      agent: Map.get(committed, "agent") || %{},
      usage: Map.get(committed, "usage") || %{},
      before_entry_id: r.before_entry_id,
      has_more: r.has_more,
      run_active?: run_active?(live)
    }
  end

  @doc "Returns `true` when `live` indicates an active run or generation."
  @spec run_active?(map()) :: boolean()
  def run_active?(live) when is_map(live) do
    tools = Map.get(live, "tools")

    has_tools? =
      cond do
        is_list(tools) -> tools != []
        is_map(tools) -> map_size(tools) > 0
        true -> false
      end

    not is_nil(Map.get(live, "run")) or not is_nil(Map.get(live, "generation")) or has_tools?
  end

  def run_active?(_), do: false

  @doc "Normalizes a raw entry map (atom or string keys) into string-keyed display shape."
  @spec normalize_entry(map()) :: map()
  def normalize_entry(entry) when is_map(entry) do
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
