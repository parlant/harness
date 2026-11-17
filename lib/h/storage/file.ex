defmodule H.Storage.File do
  @moduledoc """
  Durable local file backend implementing `H.Storage` with a CRC32-framed
  binary WAL (`commit.log`) and atomic JSON snapshots (`snapshot.<seq>.json`).
  """

  @behaviour H.Storage

  @magic 0x484C4F47
  @frame_version 1
  @header_bytes 13

  @session_meta_keys %{
    "session_id" => :session_id,
    "cwd" => :cwd,
    "title" => :title,
    "root_conversation_id" => :root_conversation_id,
    "incarnation" => :incarnation,
    "clean_close" => :clean_close,
    "created_at" => :created_at,
    "updated_at" => :updated_at,
    "active" => :active,
    "next_wake_at" => :next_wake_at,
    "status" => :status
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

  defstruct [
    :dir,
    :fd,
    :sync,
    :snapshot_every,
    commits_since_snapshot: 0,
    seq: 0,
    next_id: 2,
    session_meta: %{},
    conversations: %{1 => %{id: 1, parent: nil, owner: :ownerless, entry_ids: []}},
    entries: %{},
    submissions: %{},
    tasks: %{},
    doc_histories: %{}
  ]

  @impl true
  def open(opts) when is_list(opts) do
    with {:ok, dir} <- fetch_dir(opts),
         {:ok, sync} <- fetch_sync(opts),
         {:ok, snapshot_every} <- fetch_snapshot_every(opts),
         :ok <- ensure_dir(dir),
         {:ok, base_state, snapshot_seq} <- load_highest_snapshot(dir),
         log_path = Path.join(dir, "commit.log"),
         {:ok, fd} <- :file.open(log_path, [:raw, :binary, :read, :append]) do
      case replay_log(fd, base_state, snapshot_seq, sync) do
        {:ok, replayed_state, replayed_commits} ->
          session_meta =
            replayed_state.session_meta
            |> maybe_put_new(:session_id, Keyword.get(opts, :session_id))
            |> maybe_put_new(:cwd, Keyword.get(opts, :cwd))

          next_id =
            max(
              2,
              max(replayed_state.next_id, max_seen_id(replayed_state) + 1)
            )

          {:ok,
           %{
             replayed_state
             | dir: dir,
               fd: fd,
               sync: sync,
               snapshot_every: snapshot_every,
               commits_since_snapshot: replayed_commits,
               session_meta: session_meta,
               next_id: next_id
           }}

        {:error, reason} ->
          :file.close(fd)
          {:error, reason}
      end
    end
  end

  @impl true
  def close(%__MODULE__{fd: fd}) do
    case :file.close(fd) do
      :ok -> :ok
      {:error, :einval} -> :ok
      {:error, _} -> :ok
    end
  end

  @impl true
  def mint_id(%__MODULE__{next_id: id} = state) do
    {:ok, id, %{state | next_id: id + 1}}
  end

  @impl true
  def commit(%__MODULE__{} = state, []), do: {:ok, %{stored: 0, seqs: [], refused: nil}, state}

  def commit(%__MODULE__{} = state, batches) when is_list(batches) do
    {provisional_state, accepted_rev, refused} = run_batches(batches, 0, state, [])
    accepted = Enum.reverse(accepted_rev)
    seqs = Enum.map(accepted, fn {seq, _writes} -> seq end)

    result = %{
      stored: length(accepted),
      seqs: seqs,
      refused: refused
    }

    if accepted == [] do
      {:ok, result, state}
    else
      frame_bytes = encode_frame(provisional_state.next_id, accepted)

      with :ok <- :file.write(state.fd, frame_bytes),
           :ok <- sync_fd(state.fd, state.sync) do
        next_state = %{
          provisional_state
          | commits_since_snapshot: state.commits_since_snapshot + 1
        }

        if next_state.commits_since_snapshot >= next_state.snapshot_every do
          with {:ok, rotated_state} <- rotate_snapshot(next_state) do
            {:ok, result, rotated_state}
          end
        else
          {:ok, result, next_state}
        end
      end
    end
  end

  @impl true
  def read_bootstrap(%__MODULE__{} = state) do
    docs = latest_docs(state.doc_histories)

    data = %{
      seq: state.seq,
      next_id: state.next_id,
      session_meta: state.session_meta,
      conversations: state.conversations,
      tasks: state.tasks,
      submissions: state.submissions,
      docs: docs
    }

    {:ok, data, state}
  end

  @impl true
  def get_submission(%__MODULE__{} = state, request_id) when is_binary(request_id) do
    {:ok, Map.get(state.submissions, request_id), state}
  end

  @impl true
  def get_entry(%__MODULE__{} = state, entry_id) when is_integer(entry_id) and entry_id > 0 do
    {:ok, Map.get(state.entries, entry_id), state}
  end

  @impl true
  def get_doc(%__MODULE__{} = state, address, opts \\ []) do
    as_of_seq = Keyword.get(opts, :as_of_seq)
    {:ok, lookup_doc(state.doc_histories, address, as_of_seq), state}
  end

  @impl true
  def scan_entries(%__MODULE__{} = state, query) when is_map(query) do
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
        {:ok, %{items: items, next_cursor: next_cursor}, state}
    end
  end

  # Option validation & directory setup

  defp fetch_dir(opts) do
    case Keyword.fetch(opts, :dir) do
      {:ok, dir} when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> {:error, :missing_dir}
    end
  end

  defp fetch_sync(opts) do
    sync = Keyword.get(opts, :sync, :datasync)

    if sync in [:datasync, :sync, :none] do
      {:ok, sync}
    else
      {:error, {:invalid_sync, sync}}
    end
  end

  defp fetch_snapshot_every(opts) do
    n = Keyword.get(opts, :snapshot_every, 200)

    if is_integer(n) and n > 0 do
      {:ok, n}
    else
      {:error, {:invalid_snapshot_every, n}}
    end
  end

  defp ensure_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- File.mkdir_p(dir) do
        File.chmod(dir, 0o700)
      end
    end
  end

  # Snapshots

  defp load_highest_snapshot(dir) do
    with {:ok, entries} <- File.ls(dir) do
      candidates =
        entries
        |> Enum.flat_map(fn name ->
          case Regex.run(~r/^snapshot\.(\d+)\.json$/, name) do
            [_, seq_str] -> [{String.to_integer(seq_str), Path.join(dir, name)}]
            _ -> []
          end
        end)
        |> Enum.sort_by(&elem(&1, 0), :desc)

      find_valid_snapshot(candidates)
    end
  end

  defp find_valid_snapshot([]), do: {:ok, %__MODULE__{}, 0}

  defp find_valid_snapshot([{seq, path} | rest]) do
    with {:ok, bin} <- File.read(path),
         {:ok, decoded} <- JSON.decode(bin),
         {:ok, state} <- decode_snapshot(decoded, seq) do
      {:ok, state, seq}
    else
      _ -> find_valid_snapshot(rest)
    end
  end

  defp rotate_snapshot(%__MODULE__{} = state) do
    tmp_path = Path.join(state.dir, "snapshot.#{state.seq}.tmp")
    final_path = Path.join(state.dir, "snapshot.#{state.seq}.json")
    json_iodata = JSON.encode_to_iodata!(encode_snapshot(state))

    with {:ok, snap_fd} <- :file.open(tmp_path, [:raw, :binary, :write]),
         write_res = write_and_sync_snapshot(snap_fd, json_iodata),
         :ok <- :file.close(snap_fd),
         :ok <- write_res,
         :ok <- File.rename(tmp_path, final_path),
         {:ok, 0} <- :file.position(state.fd, 0),
         :ok <- :file.truncate(state.fd),
         :ok <- sync_fd(state.fd, state.sync) do
      cleanup_old_snapshots(state.dir, state.seq)
      {:ok, %{state | commits_since_snapshot: 0}}
    else
      {:error, _} = err ->
        File.rm(tmp_path)
        err
    end
  end

  defp write_and_sync_snapshot(snap_fd, json_iodata) do
    with :ok <- :file.write(snap_fd, json_iodata) do
      :file.sync(snap_fd)
    end
  end

  defp cleanup_old_snapshots(dir, keep_seq) do
    keep_name = "snapshot.#{keep_seq}.json"

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.each(entries, fn name ->
          if (Regex.match?(~r/^snapshot\.\d+\.json$/, name) and name != keep_name) or
               Regex.match?(~r/^snapshot\.\d+\.tmp$/, name) do
            File.rm(Path.join(dir, name))
          end
        end)

      _ ->
        :ok
    end
  end

  # WAL replay & torn-tail recovery

  defp replay_log(fd, state, snapshot_seq, sync) do
    with {:ok, file_size} <- :file.position(fd, :eof),
         {:ok, bin} <- read_log_bytes(fd, file_size) do
      {next_state, valid_offset, replayed_commits} =
        scan_frames(bin, 0, state, snapshot_seq, 0)

      if valid_offset < file_size do
        with {:ok, ^valid_offset} <- :file.position(fd, valid_offset),
             :ok <- :file.truncate(fd),
             :ok <- sync_fd(fd, sync) do
          {:ok, next_state, replayed_commits}
        end
      else
        {:ok, next_state, replayed_commits}
      end
    end
  end

  defp read_log_bytes(_fd, 0), do: {:ok, <<>>}

  defp read_log_bytes(fd, file_size) do
    with {:ok, 0} <- :file.position(fd, 0) do
      read_exact(fd, file_size, [])
    end
  end

  defp read_exact(_fd, 0, acc), do: {:ok, IO.iodata_to_binary(Enum.reverse(acc))}

  defp read_exact(fd, remaining, acc) do
    case :file.read(fd, remaining) do
      {:ok, data} when byte_size(data) > 0 ->
        read_exact(fd, remaining - byte_size(data), [data | acc])

      :eof ->
        {:ok, IO.iodata_to_binary(Enum.reverse(acc))}

      {:error, _} = err ->
        err
    end
  end

  defp scan_frames(
         <<@magic::32, @frame_version::8, len::unsigned-big-32, crc32::unsigned-big-32,
           rest::binary>>,
         offset,
         state,
         snapshot_seq,
         replayed_commits
       )
       when byte_size(rest) >= len do
    <<payload::binary-size(^len), tail::binary>> = rest

    if :erlang.crc32(payload) == crc32 do
      with {:ok, frame_next_id, batches} <- decode_frame_payload(payload),
           {:ok, next_state, applied_any?} <- replay_batches(batches, state, snapshot_seq, false) do
        next_state = %{
          next_state
          | next_id: max(next_state.next_id, frame_next_id)
        }

        commits = if applied_any?, do: replayed_commits + 1, else: replayed_commits

        scan_frames(
          tail,
          offset + @header_bytes + len,
          next_state,
          snapshot_seq,
          commits
        )
      else
        _ -> {state, offset, replayed_commits}
      end
    else
      {state, offset, replayed_commits}
    end
  end

  defp scan_frames(_incomplete_or_corrupt, offset, state, _snapshot_seq, replayed_commits) do
    {state, offset, replayed_commits}
  end

  defp replay_batches([], state, _snapshot_seq, applied_any?),
    do: {:ok, state, applied_any?}

  defp replay_batches([{batch_seq, writes} | rest], state, snapshot_seq, applied_any?) do
    if batch_seq > snapshot_seq do
      case apply_batch(writes, batch_seq, %{state | seq: batch_seq}) do
        {:ok, next_state} -> replay_batches(rest, next_state, snapshot_seq, true)
        {:error, _} -> :error
      end
    else
      replay_batches(rest, state, snapshot_seq, applied_any?)
    end
  end

  defp encode_frame(next_id, accepted_batches) do
    frame = %{
      "v" => @frame_version,
      "next_id" => next_id,
      "batches" =>
        Enum.map(accepted_batches, fn {batch_seq, writes} ->
          %{
            "seq" => batch_seq,
            "writes" => encode_writes(writes)
          }
        end)
    }

    payload = IO.iodata_to_binary(JSON.encode_to_iodata!(frame))
    len = byte_size(payload)
    crc32 = :erlang.crc32(payload)

    <<@magic::32, @frame_version::8, len::unsigned-big-32, crc32::unsigned-big-32,
      payload::binary>>
  end

  defp decode_frame_payload(payload) do
    with {:ok, %{"v" => @frame_version, "next_id" => next_id, "batches" => raw_batches}}
         when is_integer(next_id) and is_list(raw_batches) <- JSON.decode(payload),
         {:ok, batches} <- decode_batches(raw_batches, []) do
      {:ok, next_id, batches}
    else
      _ -> :error
    end
  end

  defp decode_batches([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_batches([%{"seq" => seq, "writes" => raw_writes} | rest], acc)
       when is_integer(seq) and is_list(raw_writes) do
    with {:ok, writes} <- decode_writes(raw_writes, []) do
      decode_batches(rest, [{seq, writes} | acc])
    end
  end

  defp decode_batches(_, _), do: :error

  defp encode_writes(writes) do
    Enum.flat_map(writes, fn
      {:check, _} -> []
      write -> [encode_write(write)]
    end)
  end

  defp encode_write({:put_session_meta, meta}) do
    %{"op" => "put_session_meta", "meta" => meta}
  end

  defp encode_write({:put_conversation, conv}) do
    %{"op" => "put_conversation", "conversation" => encode_conversation(conv)}
  end

  defp encode_write({:append_entry, entry}) do
    %{"op" => "append_entry", "entry" => encode_entry(entry)}
  end

  defp encode_write({:put_submission, sub}) do
    %{"op" => "put_submission", "submission" => encode_submission(sub)}
  end

  defp encode_write({:put_task, task}) do
    %{"op" => "put_task", "task" => encode_task(task)}
  end

  defp encode_write({:put_doc, address, doc_record}) do
    %{
      "op" => "put_doc",
      "address" => encode_doc_address(address),
      "doc" => doc_record
    }
  end

  defp encode_write({:retire_doc, address}) do
    %{"op" => "retire_doc", "address" => encode_doc_address(address)}
  end

  defp decode_writes([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_writes([raw | rest], acc) do
    case decode_write(raw) do
      {:ok, write} -> decode_writes(rest, [write | acc])
      :error -> :error
    end
  end

  defp decode_write(%{"op" => "put_session_meta", "meta" => meta}) when is_map(meta) do
    {:ok, {:put_session_meta, meta}}
  end

  defp decode_write(%{"op" => "put_conversation", "conversation" => conv}) when is_map(conv) do
    {:ok, {:put_conversation, conv}}
  end

  defp decode_write(%{"op" => "append_entry", "entry" => entry}) when is_map(entry) do
    {:ok, {:append_entry, entry}}
  end

  defp decode_write(%{"op" => "put_submission", "submission" => sub}) when is_map(sub) do
    {:ok, {:put_submission, decode_submission_tuples(sub)}}
  end

  defp decode_write(%{"op" => "put_task", "task" => task}) when is_map(task) do
    {:ok, {:put_task, task}}
  end

  defp decode_write(%{"op" => "put_doc", "address" => raw_addr, "doc" => doc}) when is_map(doc) do
    with {:ok, addr} <- decode_doc_address(raw_addr) do
      {:ok, {:put_doc, addr, doc}}
    end
  end

  defp decode_write(%{"op" => "retire_doc", "address" => raw_addr}) do
    with {:ok, addr} <- decode_doc_address(raw_addr) do
      {:ok, {:retire_doc, addr}}
    end
  end

  defp decode_write(_), do: :error

  # Snapshot JSON encoding / decoding

  defp encode_snapshot(%__MODULE__{} = state) do
    %{
      "v" => @frame_version,
      "seq" => state.seq,
      "next_id" => state.next_id,
      "session_meta" => state.session_meta,
      "conversations" =>
        state.conversations
        |> Map.values()
        |> Enum.map(&encode_conversation/1),
      "entries" =>
        state.entries
        |> Map.values()
        |> Enum.map(&encode_entry/1),
      "submissions" =>
        state.submissions
        |> Map.values()
        |> Enum.map(&encode_submission/1),
      "tasks" =>
        state.tasks
        |> Map.values()
        |> Enum.map(&encode_task/1),
      "docs" =>
        Enum.map(state.doc_histories, fn {address, revisions} ->
          %{
            "address" => encode_doc_address(address),
            "revisions" => Enum.map(revisions, &encode_revision/1)
          }
        end)
    }
  end

  defp decode_snapshot(
         %{
           "v" => @frame_version,
           "seq" => seq,
           "next_id" => next_id,
           "session_meta" => raw_meta,
           "conversations" => raw_convs,
           "entries" => raw_entries,
           "submissions" => raw_subs,
           "tasks" => raw_tasks,
           "docs" => raw_docs
         },
         expected_seq
       )
       when seq == expected_seq and is_integer(next_id) and is_map(raw_meta) and
              is_list(raw_convs) and is_list(raw_entries) and is_list(raw_subs) and
              is_list(raw_tasks) and is_list(raw_docs) do
    with {:ok, doc_histories} <- decode_doc_histories(raw_docs, %{}) do
      conversations =
        Map.new(raw_convs, fn raw_c ->
          conv = normalize_conversation(raw_c, %{})
          {conv.id, conv}
        end)

      entries =
        Map.new(raw_entries, fn raw_e ->
          entry = normalize_map(raw_e, @entry_keys)
          {entry.id, entry}
        end)

      submissions =
        Map.new(raw_subs, fn raw_s ->
          sub = raw_s |> decode_submission_tuples() |> normalize_map(@submission_keys)
          {sub.request_id, sub}
        end)

      tasks =
        Map.new(raw_tasks, fn raw_t ->
          task = normalize_task(raw_t)
          {task.id, task}
        end)

      {:ok,
       %__MODULE__{
         seq: seq,
         next_id: next_id,
         session_meta: normalize_map(raw_meta, @session_meta_keys),
         conversations: conversations,
         entries: entries,
         submissions: submissions,
         tasks: tasks,
         doc_histories: doc_histories
       }}
    end
  end

  defp decode_snapshot(_, _), do: :error

  defp encode_revision(%{seq: seq, value: value}), do: %{"seq" => seq, "value" => value}
  defp encode_revision(%{seq: seq, retired: true}), do: %{"seq" => seq, "retired" => true}

  defp decode_doc_histories([], acc), do: {:ok, acc}

  defp decode_doc_histories([%{"address" => raw_addr, "revisions" => raw_revs} | rest], acc)
       when is_list(raw_revs) do
    with {:ok, addr} <- decode_doc_address(raw_addr),
         {:ok, revs} <- decode_revisions(raw_revs, []) do
      decode_doc_histories(rest, Map.put(acc, addr, revs))
    else
      _ -> :error
    end
  end

  defp decode_doc_histories(_, _), do: :error

  defp decode_revisions([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_revisions([%{"seq" => seq, "value" => val} | rest], acc)
       when is_integer(seq) and is_map(val) do
    decode_revisions(rest, [%{seq: seq, value: val} | acc])
  end

  defp decode_revisions([%{"seq" => seq, "retired" => true} | rest], acc)
       when is_integer(seq) do
    decode_revisions(rest, [%{seq: seq, retired: true} | acc])
  end

  defp decode_revisions(_, _), do: :error

  # Record JSON helpers (no String.to_atom/1)

  defp encode_doc_address({:session, kind}) when is_binary(kind) do
    %{"scope" => "session", "kind" => kind}
  end

  defp encode_doc_address({:conversation, cid, kind}) when is_integer(cid) and is_binary(kind) do
    %{"scope" => "conversation", "id" => cid, "kind" => kind}
  end

  defp encode_doc_address({:task, tid, kind}) when is_integer(tid) and is_binary(kind) do
    %{"scope" => "task", "id" => tid, "kind" => kind}
  end

  defp decode_doc_address(%{"scope" => "session", "kind" => kind}) when is_binary(kind) do
    {:ok, {:session, kind}}
  end

  defp decode_doc_address(%{"scope" => "conversation", "id" => cid, "kind" => kind})
       when is_integer(cid) and is_binary(kind) do
    {:ok, {:conversation, cid, kind}}
  end

  defp decode_doc_address(%{"scope" => "task", "id" => tid, "kind" => kind})
       when is_integer(tid) and is_binary(kind) do
    {:ok, {:task, tid, kind}}
  end

  defp decode_doc_address(_), do: :error

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

  defp encode_conversation(conv) do
    base = normalize_map(conv, @conversation_keys)

    base
    |> Map.put(:owner, encode_owner(Map.get(base, :owner, :ownerless)))
  end

  defp encode_entry(entry) do
    normalize_map(entry, @entry_keys)
  end

  defp encode_submission(sub) do
    base = normalize_map(sub, @submission_keys)

    case Map.get(base, :notify) do
      {task_id, key} when is_integer(task_id) and is_binary(key) ->
        Map.put(base, :notify, %{"__tuple__" => "notify", "task_id" => task_id, "key" => key})

      _ ->
        base
    end
  end

  defp decode_submission_tuples(sub) when is_map(sub) do
    case Map.get(sub, "notify") do
      %{"__tuple__" => "notify", "task_id" => task_id, "key" => key} ->
        Map.put(sub, "notify", {task_id, key})

      _ ->
        sub
    end
  end

  defp encode_task(task) do
    base = normalize_map(task, @task_keys)

    if Map.has_key?(base, :owner) do
      Map.put(base, :owner, encode_owner(base.owner))
    else
      base
    end
  end

  # Domain batch evaluation & state transitions

  defp run_batches([], _idx, state, seqs), do: {state, seqs, nil}

  defp run_batches([batch | rest], idx, state, seqs) do
    batch_seq = state.seq + 1

    case apply_batch(batch, batch_seq, %{state | seq: batch_seq}) do
      {:ok, next_state} ->
        run_batches(rest, idx + 1, next_state, [{batch_seq, batch} | seqs])

      {:error, reason} ->
        {state, seqs, {idx, reason}}
    end
  end

  defp apply_batch([], _batch_seq, state), do: {:ok, state}

  defp apply_batch([write | rest], batch_seq, state) do
    case apply_write(write, batch_seq, state) do
      {:ok, next_state} -> apply_batch(rest, batch_seq, next_state)
      {:error, _} = err -> err
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
    normalized = normalize_map(meta, @session_meta_keys)
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
      |> normalize_map(@entry_keys)
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

  defp apply_write({:put_submission, sub}, _seq, state) when is_map(sub) do
    normalized = normalize_map(sub, @submission_keys)
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

  defp normalize_conversation(conv, existing_conversations) do
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

  defp normalize_task(task) do
    base = normalize_map(task, @task_keys)

    if Map.has_key?(base, :owner) do
      Map.put(base, :owner, normalize_owner(base.owner))
    else
      base
    end
  end

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

  defp max_seen_id(state) do
    [
      Map.keys(state.conversations),
      Map.keys(state.entries),
      Map.keys(state.tasks)
    ]
    |> Enum.concat()
    |> Enum.max(fn -> 1 end)
  end

  defp maybe_put_new(map, _key, nil), do: map
  defp maybe_put_new(map, key, val), do: Map.put_new(map, key, val)

  defp sync_fd(_fd, :none), do: :ok
  defp sync_fd(fd, :datasync), do: :file.datasync(fd)
  defp sync_fd(fd, :sync), do: :file.sync(fd)
end
