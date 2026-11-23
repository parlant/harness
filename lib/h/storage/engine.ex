defmodule H.Storage.Engine do
  @moduledoc """
  Shared in-memory domain projection, batch evaluation, entry scanning,
  revisioned document lookup, and safe string-key normalization for `H.Storage`
  backends.
  """

  @session_meta_keys %{
    "session_id" => :session_id,
    "env_id" => :env_id,
    "cwd" => :cwd,
    "title" => :title,
    "title_explicit" => :title_explicit,
    "parent" => :parent,
    "role" => :role,
    "root_conversation_id" => :root_conversation_id,
    "incarnation" => :incarnation,
    "clean_close" => :clean_close,
    "created_at" => :created_at,
    "updated_at" => :updated_at,
    "active" => :active,
    "next_wake_at" => :next_wake_at,
    "status" => :status
  }

  @session_parent_keys %{
    "session_id" => :session_id,
    "conversation_id" => :conversation_id,
    "at_entry_id" => :at_entry_id,
    "task_id" => :task_id,
    "depth" => :depth,
    "env_id" => :env_id,
    "cwd" => :cwd
  }

  @conversation_keys %{
    "id" => :id,
    "parent" => :parent,
    "owner" => :owner,
    "entry_ids" => :entry_ids
  }

  @parent_keys %{
    "conversation_id" => :conversation_id,
    "at" => :at
  }

  @entry_keys %{
    "id" => :id,
    "conversation_id" => :conversation_id,
    "seq" => :seq,
    "kind" => :kind,
    "data" => :data,
    "created_at" => :created_at
  }

  @submission_keys %{
    "id" => :id,
    "request_id" => :request_id,
    "fingerprint" => :fingerprint,
    "kind" => :kind,
    "status" => :status,
    "conversation_id" => :conversation_id,
    "entry_id" => :entry_id,
    "answer_entry_id" => :answer_entry_id,
    "reason" => :reason,
    "notify" => :notify,
    "when_busy" => :when_busy,
    "when_idle" => :when_idle,
    "title" => :title,
    "withdrawn" => :withdrawn,
    "seq" => :seq,
    "created_at" => :created_at,
    "updated_at" => :updated_at
  }

  @task_keys %{
    "id" => :id,
    "kind" => :kind,
    "version" => :version,
    "status" => :status,
    "owner" => :owner,
    "checkpoint" => :checkpoint,
    "outcome" => :outcome,
    "restarts" => :restarts,
    "memos" => :memos,
    "cancel" => :cancel,
    "cancelled" => :cancelled,
    "abort_reason" => :abort_reason,
    "wake" => :wake,
    "signals" => :signals,
    "background" => :background,
    "abandon_on_restart" => :abandon_on_restart,
    "started_at" => :started_at,
    "ended_at" => :ended_at,
    "created_at" => :created_at,
    "updated_at" => :updated_at,
    "blocked" => :blocked
  }

  def run_batches(batches, state) when is_list(batches) do
    do_run_batches(batches, 0, state, [])
  end

  def apply_batch([], _batch_seq, state), do: {:ok, state}

  def apply_batch([write | rest], batch_seq, state) do
    case apply_write(write, batch_seq, state) do
      {:ok, next_state} -> apply_batch(rest, batch_seq, next_state)
      {:error, _} = err -> err
    end
  end

  def read_bootstrap(state) do
    %{
      seq: state.seq,
      next_id: state.next_id,
      session_meta: state.session_meta,
      conversations: state.conversations,
      tasks: state.tasks,
      submissions: state.submissions,
      docs: latest_docs(state.doc_histories)
    }
  end

  def get_doc(state, address, opts \\ []) do
    lookup_doc(state.doc_histories, address, Keyword.get(opts, :as_of_seq))
  end

  def scan_entries(state, query) when is_map(query) do
    cid = Map.fetch!(query, :conversation_id)
    cutoff = Map.get(query, :cutoff)
    order = Map.get(query, :order, :desc)
    cursor = Map.get(query, :cursor)
    limit = Map.get(query, :limit, 50)

    case Map.fetch(state.conversations, cid) do
      :error ->
        {:error, {:conversation_not_found, cid}}

      {:ok, conversation} ->
        visible =
          collect_visible_entries(state, conversation, cutoff, [])
          |> Enum.sort_by(& &1.id, order)
          |> filter_cursor(order, cursor)

        {items, rest} = Enum.split(visible, limit)
        next_cursor = if rest == [], do: nil, else: List.last(items).id
        {:ok, %{items: items, next_cursor: next_cursor}}
    end
  end

  def list_entries(state) do
    state.entries
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  def max_seen_id(state) do
    [
      Map.keys(state.conversations),
      Map.keys(state.entries),
      Map.keys(state.tasks)
    ]
    |> Enum.concat()
    |> Enum.max(fn -> 1 end)
  end

  # Normalization & JSON-safe record helpers

  def normalize_session_meta(meta) do
    base = normalize_map(meta, @session_meta_keys)

    case Map.fetch(base, :parent) do
      {:ok, p} when is_map(p) ->
        Map.put(base, :parent, normalize_map(p, @session_parent_keys))

      _ ->
        base
    end
  end

  def normalize_entry(entry), do: normalize_map(entry, @entry_keys)

  def normalize_submission(sub) do
    sub
    |> decode_submission_tuples()
    |> normalize_map(@submission_keys)
  end

  def normalize_conversation(conv, existing_conversations) do
    base = normalize_map(conv, @conversation_keys)
    id = Map.fetch!(base, :id)

    parent =
      case Map.get(base, :parent) do
        nil -> nil
        p when is_map(p) -> normalize_map(p, @parent_keys)
      end

    owner = normalize_owner(Map.get(base, :owner, :ownerless))

    entry_ids =
      case Map.fetch(base, :entry_ids) do
        {:ok, ids} when is_list(ids) ->
          ids

        :error ->
          case Map.get(existing_conversations, id) do
            %{entry_ids: existing_ids} -> existing_ids
            nil -> []
          end
      end

    base
    |> Map.put(:parent, parent)
    |> Map.put(:owner, owner)
    |> Map.put(:entry_ids, entry_ids)
  end

  def normalize_task(task) do
    base = normalize_map(task, @task_keys)

    if Map.has_key?(base, :owner) do
      Map.put(base, :owner, normalize_owner(base.owner))
    else
      base
    end
  end

  def encode_doc_address({:session, kind}) when is_binary(kind) do
    %{"scope" => "session", "kind" => kind}
  end

  def encode_doc_address({:conversation, cid, kind}) when is_integer(cid) and is_binary(kind) do
    %{"scope" => "conversation", "id" => cid, "kind" => kind}
  end

  def encode_doc_address({:task, tid, kind}) when is_integer(tid) and is_binary(kind) do
    %{"scope" => "task", "id" => tid, "kind" => kind}
  end

  def decode_doc_address(%{"scope" => "session", "kind" => kind}) when is_binary(kind) do
    {:ok, {:session, kind}}
  end

  def decode_doc_address(%{"scope" => "conversation", "id" => cid, "kind" => kind})
      when is_integer(cid) and is_binary(kind) do
    {:ok, {:conversation, cid, kind}}
  end

  def decode_doc_address(%{"scope" => "task", "id" => tid, "kind" => kind})
      when is_integer(tid) and is_binary(kind) do
    {:ok, {:task, tid, kind}}
  end

  def decode_doc_address(_), do: :error

  def encode_conversation(conv) do
    base = normalize_map(conv, @conversation_keys)
    Map.put(base, :owner, encode_owner(Map.get(base, :owner, :ownerless)))
  end

  def encode_entry(entry), do: normalize_map(entry, @entry_keys)

  def encode_submission(sub) do
    base = normalize_map(sub, @submission_keys)

    case Map.get(base, :notify) do
      {task_id, key} when is_integer(task_id) and is_binary(key) ->
        Map.put(base, :notify, %{"__tuple__" => "notify", "task_id" => task_id, "key" => key})

      _ ->
        base
    end
  end

  def decode_submission_tuples(sub) when is_map(sub) do
    case Map.get(sub, "notify") do
      %{"__tuple__" => "notify", "task_id" => task_id, "key" => key} ->
        Map.put(sub, "notify", {task_id, key})

      _ ->
        sub
    end
  end

  def encode_task(task) do
    base = normalize_map(task, @task_keys)

    if Map.has_key?(base, :owner) do
      Map.put(base, :owner, encode_owner(base.owner))
    else
      base
    end
  end

  # Internal batch & query mechanics

  defp do_run_batches([], _idx, state, accepted_rev),
    do: {state, Enum.reverse(accepted_rev), nil}

  defp do_run_batches([batch | rest], idx, state, accepted_rev) do
    batch_seq = state.seq + 1

    case apply_batch(batch, batch_seq, %{state | seq: batch_seq}) do
      {:ok, next_state} ->
        do_run_batches(rest, idx + 1, next_state, [{batch_seq, batch} | accepted_rev])

      {:error, reason} ->
        {state, Enum.reverse(accepted_rev), {idx, reason}}
    end
  end

  defp apply_write({:check, {:unique_request_id, req_id, fingerprint}}, _seq, state) do
    case Map.fetch(state.submissions, req_id) do
      :error ->
        {:ok, state}

      {:ok, existing} ->
        if existing.fingerprint == fingerprint do
          {:error, {:duplicate_request_id, existing}}
        else
          {:error, {:conflict_request_id, existing}}
        end
    end
  end

  defp apply_write({:check, {:conversation_exists, cid}}, _seq, state) do
    if Map.has_key?(state.conversations, cid) do
      {:ok, state}
    else
      {:error, {:conversation_not_found, cid}}
    end
  end

  defp apply_write({:put_session_meta, meta}, _seq, state) when is_map(meta) do
    normalized = normalize_session_meta(meta)
    {:ok, %{state | session_meta: Map.merge(state.session_meta, normalized)}}
  end

  defp apply_write({:put_conversation, conv}, _seq, state) when is_map(conv) do
    normalized = normalize_conversation(conv, state.conversations)
    next_id = max(state.next_id, normalized.id + 1)

    {:ok,
     %{
       state
       | conversations: Map.put(state.conversations, normalized.id, normalized),
         next_id: next_id
     }}
  end

  defp apply_write({:append_entry, entry}, batch_seq, state) when is_map(entry) do
    normalized =
      entry
      |> normalize_entry()
      |> Map.put(:seq, batch_seq)

    cid = normalized.conversation_id

    case Map.fetch(state.conversations, cid) do
      :error ->
        {:error, {:conversation_not_found, cid}}

      {:ok, conv} ->
        entry_ids =
          if Map.has_key?(state.entries, normalized.id) do
            conv.entry_ids
          else
            [normalized.id | conv.entry_ids]
          end

        updated_conv = %{conv | entry_ids: entry_ids}
        next_id = max(state.next_id, normalized.id + 1)

        {:ok,
         %{
           state
           | conversations: Map.put(state.conversations, cid, updated_conv),
             entries: Map.put(state.entries, normalized.id, normalized),
             next_id: next_id
         }}
    end
  end

  defp apply_write({:put_submission, sub}, batch_seq, state) when is_map(sub) do
    normalized =
      sub
      |> normalize_submission()
      |> Map.update(:seq, batch_seq, &(&1 || batch_seq))

    {:ok, %{state | submissions: Map.put(state.submissions, normalized.request_id, normalized)}}
  end

  defp apply_write({:put_task, task}, _seq, state) when is_map(task) do
    normalized = normalize_task(task)
    next_id = max(state.next_id, normalized.id + 1)

    {:ok,
     %{
       state
       | tasks: Map.put(state.tasks, normalized.id, normalized),
         next_id: next_id
     }}
  end

  defp apply_write({:put_doc, address, doc_record}, batch_seq, state) when is_map(doc_record) do
    revisions =
      state.doc_histories
      |> Map.get(address, [])
      |> put_revision(%{seq: batch_seq, value: doc_record})

    {:ok, %{state | doc_histories: Map.put(state.doc_histories, address, revisions)}}
  end

  defp apply_write({:retire_doc, address}, batch_seq, state) do
    revisions =
      state.doc_histories
      |> Map.get(address, [])
      |> put_revision(%{seq: batch_seq, retired: true})

    {:ok, %{state | doc_histories: Map.put(state.doc_histories, address, revisions)}}
  end

  defp put_revision([%{seq: seq} | rest], %{seq: seq} = rev), do: [rev | rest]
  defp put_revision(revisions, rev), do: [rev | revisions]

  defp latest_docs(doc_histories) do
    Enum.reduce(doc_histories, %{}, fn {address, revisions}, acc ->
      case revisions do
        [%{value: value} | _] -> Map.put(acc, address, value)
        _ -> acc
      end
    end)
  end

  defp lookup_doc(doc_histories, address, nil) do
    case Map.get(doc_histories, address) do
      [%{value: value} | _] -> value
      _ -> nil
    end
  end

  defp lookup_doc(doc_histories, address, as_of_seq) when is_integer(as_of_seq) do
    doc_histories
    |> Map.get(address, [])
    |> Enum.find(&(&1.seq <= as_of_seq))
    |> case do
      %{value: value} -> value
      _ -> nil
    end
  end

  defp collect_visible_entries(state, conversation, cutoff, tail) do
    entries =
      Enum.reduce(conversation.entry_ids, tail, fn id, acc ->
        if is_nil(cutoff) or id <= cutoff do
          [Map.fetch!(state.entries, id) | acc]
        else
          acc
        end
      end)

    case conversation.parent do
      nil ->
        entries

      %{conversation_id: parent_id, at: at} ->
        next_cutoff = if is_nil(cutoff), do: at, else: min(at, cutoff)
        parent = Map.fetch!(state.conversations, parent_id)
        collect_visible_entries(state, parent, next_cutoff, entries)
    end
  end

  defp filter_cursor(entries, _order, nil), do: entries
  defp filter_cursor(entries, :desc, cursor), do: Enum.filter(entries, &(&1.id < cursor))
  defp filter_cursor(entries, :asc, cursor), do: Enum.filter(entries, &(&1.id > cursor))

  defp encode_owner(:ownerless), do: %{"kind" => "ownerless"}
  defp encode_owner("ownerless"), do: %{"kind" => "ownerless"}
  defp encode_owner(nil), do: %{"kind" => "ownerless"}

  defp encode_owner({:conversation, cid}) when is_integer(cid),
    do: %{"kind" => "conversation", "id" => cid}

  defp encode_owner({:task, tid}) when is_integer(tid),
    do: %{"kind" => "task", "id" => tid}

  defp encode_owner(%{"kind" => _} = map), do: map

  defp normalize_owner(:ownerless), do: :ownerless
  defp normalize_owner("ownerless"), do: :ownerless
  defp normalize_owner(nil), do: :ownerless
  defp normalize_owner(%{"kind" => "ownerless"}), do: :ownerless
  defp normalize_owner({:conversation, cid}) when is_integer(cid), do: {:conversation, cid}

  defp normalize_owner(%{"kind" => "conversation", "id" => cid}) when is_integer(cid),
    do: {:conversation, cid}

  defp normalize_owner({:task, tid}) when is_integer(tid), do: {:task, tid}
  defp normalize_owner(%{"kind" => "task", "id" => tid}) when is_integer(tid), do: {:task, tid}

  defp normalize_map(struct, key_map) when is_struct(struct) do
    struct
    |> Map.from_struct()
    |> normalize_map(key_map)
  end

  defp normalize_map(map, key_map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: Map.get(key_map, k, k), else: k
      {key, v}
    end)
  end
end
