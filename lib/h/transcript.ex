defmodule H.Transcript do
  @moduledoc """
  Pure Elixir reducer for conversation transcript SSE/PubSub frames.
  Applies document deltas with `H.Document.apply_ops/2`.
  """

  alias H.Document

  @unsafe_doc_keys MapSet.new(["__proto__", "constructor", "prototype"])

  @enforce_keys []
  defstruct session_id: nil,
            conversation_id: nil,
            seq: nil,
            entries: [],
            entry_ids: MapSet.new(),
            has_more: false,
            before_entry_id: nil,
            committed_docs: %{
              "live" => %{},
              "inbox" => [],
              "agent" => %{},
              "usage" => %{}
            },
            docs: %{
              "live" => %{},
              "inbox" => [],
              "agent" => %{},
              "usage" => %{}
            }

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          conversation_id: String.t() | nil,
          seq: non_neg_integer() | nil,
          entries: [map()],
          entry_ids: MapSet.t(String.t()),
          has_more: boolean(),
          before_entry_id: String.t() | nil,
          committed_docs: map(),
          docs: map()
        }

  @doc "Creates a new empty `H.Transcript` reducer state."
  @spec new(keyword() | map()) :: t()
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    %__MODULE__{
      session_id: normalize_opt_string(Keyword.get(opts, :session_id)),
      conversation_id: normalize_opt_string(Keyword.get(opts, :conversation_id))
    }
  end

  def new(opts) when is_map(opts) do
    %__MODULE__{
      session_id: normalize_opt_string(frame_field(opts, "session_id", :session_id)),
      conversation_id:
        normalize_opt_string(frame_field(opts, "conversation_id", :conversation_id))
    }
  end

  @doc """
  Applies a `snapshot` payload (decoded map or JSON binary).

  Sets `seq`, deduplicates and orders `entries`, updates `before_entry_id` and
  `has_more`, and resets both `committed_docs` and `docs`.
  """
  @spec apply_snapshot(t(), map() | binary()) :: {:ok, t()} | {:error, term()}
  def apply_snapshot(%__MODULE__{} = transcript, payload) do
    with {:ok, frame} <- decode_frame(payload, :invalid_snapshot),
         {:ok, seq} <- fetch_seq(frame, "seq", :seq, :invalid_snapshot),
         {:ok, raw_entries} <- fetch_entries_list(frame, "entries", :entries, :invalid_snapshot) do
      entries = normalize_entries(raw_entries)
      entry_ids = MapSet.new(entries, &entry_id_key/1)
      before_entry_id = normalize_cursor(frame_field(frame, "before_entry_id", :before_entry_id))

      has_more =
        case frame_field(frame, "has_more", :has_more) do
          val when is_boolean(val) -> val
          _ -> before_entry_id != nil
        end

      docs = normalize_docs(frame_field(frame, "docs", :docs))

      updated = %{
        transcript
        | session_id:
            normalize_opt_string(frame_field(frame, "session_id", :session_id)) ||
              transcript.session_id,
          conversation_id:
            normalize_opt_string(frame_field(frame, "conversation_id", :conversation_id)) ||
              transcript.conversation_id,
          seq: seq,
          entries: entries,
          entry_ids: entry_ids,
          has_more: has_more,
          before_entry_id: before_entry_id,
          committed_docs: docs,
          docs: docs
      }

      {:ok, updated}
    end
  end

  @doc """
  Applies a `commit` payload (decoded map or JSON binary).

  Returns:
    * `{:gap, t}` when `t.seq` is `nil` or `frame_seq > t.seq + 1` (caller should resnapshot)
    * `{:stale, t}` when `frame_seq <= t.seq`
    * `{:ok, updated, %{appended_entries: new_entries}}` when `frame_seq == t.seq + 1`
  """
  @spec apply_commit(t(), map() | binary()) ::
          {:ok, t(), %{appended_entries: [map()]}}
          | {:gap, t()}
          | {:stale, t()}
          | {:error, term()}
  def apply_commit(%__MODULE__{} = transcript, payload) do
    with {:ok, frame} <- decode_frame(payload, :invalid_commit),
         {:ok, frame_seq} <- fetch_seq(frame, "seq", :seq, :invalid_commit) do
      prev_seq = frame_field(frame, "prev_seq", :prev_seq)

      cond do
        is_nil(transcript.seq) ->
          {:gap, transcript}

        frame_seq <= transcript.seq ->
          {:stale, transcript}

        is_integer(prev_seq) and prev_seq != transcript.seq ->
          {:gap, transcript}

        is_nil(prev_seq) and frame_seq > transcript.seq + 1 ->
          {:gap, transcript}

        true ->
          apply_next_commit(transcript, frame, frame_seq)
      end
    end
  end

  @doc """
  Applies an `ephemeral` payload (decoded map or JSON binary) to `docs["live"]`
  without advancing `seq` or mutating `committed_docs`.

  Returns `:ignored` when `t.seq == nil` or `base_seq != t.seq`.
  """
  @spec apply_ephemeral(t(), map() | binary()) :: {:ok, t()} | :ignored | {:error, term()}
  def apply_ephemeral(%__MODULE__{} = transcript, payload) do
    with {:ok, frame} <- decode_frame(payload, :invalid_ephemeral),
         {:ok, base_seq} <- fetch_seq(frame, "base_seq", :base_seq, :invalid_ephemeral) do
      if is_nil(transcript.seq) or base_seq != transcript.seq do
        :ignored
      else
        apply_ephemeral_ops(transcript, frame)
      end
    end
  end

  @doc """
  Prepends an older page of entries in ascending order without duplicates and
  updates `before_entry_id` and `has_more`.
  """
  @spec prepend_older_page(t(), [map()], String.t() | integer() | nil) :: t()
  def prepend_older_page(%__MODULE__{} = transcript, items, next_cursor) when is_list(items) do
    unique_older =
      items
      |> normalize_entries()
      |> Enum.reject(&MapSet.member?(transcript.entry_ids, entry_id_key(&1)))

    next_entries =
      if unique_older == [] do
        transcript.entries
      else
        unique_older ++ transcript.entries
      end

    next_entry_ids =
      Enum.reduce(unique_older, transcript.entry_ids, fn entry, acc ->
        MapSet.put(acc, entry_id_key(entry))
      end)

    cursor = normalize_cursor(next_cursor)

    %{
      transcript
      | entries: next_entries,
        entry_ids: next_entry_ids,
        before_entry_id: cursor,
        has_more: cursor != nil
    }
  end

  defp apply_next_commit(transcript, frame, frame_seq) do
    with {:ok, raw_entries} <-
           fetch_entries_list(frame, "appended_entries", :appended_entries, :invalid_commit),
         {:ok, doc_ops} <- fetch_doc_ops(frame) do
      new_entries =
        raw_entries
        |> normalize_entries()
        |> Enum.reject(&MapSet.member?(transcript.entry_ids, entry_id_key(&1)))

      next_entries =
        if new_entries == [] do
          transcript.entries
        else
          transcript.entries ++ new_entries
        end

      next_entry_ids =
        Enum.reduce(new_entries, transcript.entry_ids, fn entry, acc ->
          MapSet.put(acc, entry_id_key(entry))
        end)

      next_committed_docs = apply_doc_ops_map(transcript.committed_docs, doc_ops)

      updated = %{
        transcript
        | seq: frame_seq,
          entries: next_entries,
          entry_ids: next_entry_ids,
          committed_docs: next_committed_docs,
          docs: next_committed_docs
      }

      {:ok, updated, %{appended_entries: new_entries}}
    end
  end

  defp apply_ephemeral_ops(transcript, frame) do
    doc_ops = frame_field(frame, "doc_ops", :doc_ops)
    ops = frame_field(frame, "ops", :ops)

    cond do
      is_map(doc_ops) ->
        {:ok, %{transcript | docs: apply_doc_ops_map(transcript.docs, doc_ops)}}

      is_list(ops) ->
        {:ok, %{transcript | docs: apply_doc_ops_map(transcript.docs, %{"live" => ops})}}

      is_nil(doc_ops) and is_nil(ops) ->
        {:ok, transcript}

      true ->
        {:error, :invalid_ephemeral}
    end
  end

  defp decode_frame(payload, _err) when is_map(payload), do: {:ok, payload}

  defp decode_frame(payload, err) when is_binary(payload) do
    case JSON.decode(payload) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, err}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_frame(_payload, err), do: {:error, err}

  defp fetch_seq(frame, str_key, atom_key, err) do
    case frame_field(frame, str_key, atom_key) do
      seq when is_integer(seq) and seq >= 0 -> {:ok, seq}
      _ -> {:error, err}
    end
  end

  defp fetch_entries_list(frame, str_key, atom_key, err) do
    case frame_field(frame, str_key, atom_key) do
      nil -> {:ok, []}
      list when is_list(list) -> {:ok, list}
      _ -> {:error, err}
    end
  end

  defp fetch_doc_ops(frame) do
    case frame_field(frame, "doc_ops", :doc_ops) do
      nil -> {:ok, %{}}
      map when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_commit}
    end
  end

  defp normalize_entries(entries) do
    entries
    |> Enum.reduce(%{}, fn entry, acc ->
      case entry_id_key(entry) do
        nil -> acc
        id_key -> Map.put(acc, id_key, entry)
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&entry_sort_key(entry_id_key(&1)))
  end

  defp entry_id_key(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp entry_id_key(%{id: id}) when not is_nil(id), do: to_string(id)
  defp entry_id_key(_), do: nil

  defp entry_sort_key(id) when is_binary(id) do
    case Integer.parse(id) do
      {num, ""} -> {0, num}
      _ -> {1, id}
    end
  end

  defp normalize_docs(docs) when is_map(docs) do
    base = default_docs()

    Enum.reduce(docs, base, fn {k, v}, acc ->
      key = to_string(k)

      cond do
        MapSet.member?(@unsafe_doc_keys, key) ->
          acc

        key in ["live", "agent", "usage"] ->
          Map.put(acc, key, if(is_map(v), do: v, else: %{}))

        key == "inbox" ->
          Map.put(acc, key, if(is_list(v), do: v, else: []))

        true ->
          Map.put(acc, key, v)
      end
    end)
  end

  defp normalize_docs(_), do: default_docs()

  defp default_docs do
    %{
      "live" => %{},
      "inbox" => [],
      "agent" => %{},
      "usage" => %{}
    }
  end

  defp apply_doc_ops_map(docs, doc_ops) when is_map(doc_ops) do
    Enum.reduce(doc_ops, docs, fn {doc_name, ops}, acc ->
      key = to_string(doc_name)

      if is_list(ops) and ops != [] and not MapSet.member?(@unsafe_doc_keys, key) do
        Map.put(acc, key, Document.apply_ops(Map.get(acc, key), ops))
      else
        acc
      end
    end)
  end

  defp frame_field(map, str_key, atom_key) do
    case Map.fetch(map, str_key) do
      {:ok, val} -> val
      :error -> Map.get(map, atom_key)
    end
  end

  defp normalize_cursor(nil), do: nil
  defp normalize_cursor(""), do: nil
  defp normalize_cursor(val) when is_binary(val), do: val
  defp normalize_cursor(val) when is_integer(val), do: Integer.to_string(val)
  defp normalize_cursor(val), do: to_string(val)

  defp normalize_opt_string(nil), do: nil
  defp normalize_opt_string(val) when is_binary(val), do: val
  defp normalize_opt_string(val) when is_integer(val), do: Integer.to_string(val)
  defp normalize_opt_string(val), do: to_string(val)
end
