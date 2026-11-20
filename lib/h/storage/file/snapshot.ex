defmodule H.Storage.File.Snapshot do
  @moduledoc """
  Atomic JSON snapshot persistence (`snapshot.<seq>.json`), WAL truncation,
  and snapshot recovery for `H.Storage.File`.
  """

  alias H.Storage.{Engine, File.Wal}

  @snapshot_version 1

  def load_highest(dir, empty_state) do
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

      find_valid(candidates, empty_state)
    end
  end

  def rotate(state) do
    tmp_path = Path.join(state.dir, "snapshot.#{state.seq}.tmp")
    final_path = Path.join(state.dir, "snapshot.#{state.seq}.json")
    json_iodata = JSON.encode_to_iodata!(encode(state))

    with {:ok, snap_fd} <- :file.open(tmp_path, [:raw, :binary, :write]),
         write_res = write_and_sync(snap_fd, json_iodata),
         :ok <- :file.close(snap_fd),
         :ok <- write_res,
         :ok <- File.rename(tmp_path, final_path),
         {:ok, 0} <- :file.position(state.fd, 0),
         :ok <- :file.truncate(state.fd),
         :ok <- Wal.sync_fd(state.fd, state.sync) do
      cleanup_old(state.dir, state.seq)
      {:ok, %{state | commits_since_snapshot: 0}}
    else
      {:error, _} = err ->
        File.rm(tmp_path)
        err
    end
  end

  # Internal helpers

  defp find_valid([], empty_state), do: {:ok, empty_state, 0}

  defp find_valid([{seq, path} | rest], empty_state) do
    with {:ok, bin} <- File.read(path),
         {:ok, decoded} <- JSON.decode(bin),
         {:ok, state} <- decode(decoded, seq, empty_state) do
      {:ok, state, seq}
    else
      _ -> find_valid(rest, empty_state)
    end
  end

  defp write_and_sync(snap_fd, json_iodata) do
    with :ok <- :file.write(snap_fd, json_iodata) do
      :file.sync(snap_fd)
    end
  end

  defp cleanup_old(dir, keep_seq) do
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

  defp encode(state) do
    %{
      "v" => @snapshot_version,
      "seq" => state.seq,
      "next_id" => state.next_id,
      "session_meta" => state.session_meta,
      "conversations" =>
        state.conversations
        |> Map.values()
        |> Enum.map(&Engine.encode_conversation/1),
      "entries" =>
        state.entries
        |> Map.values()
        |> Enum.map(&Engine.encode_entry/1),
      "submissions" =>
        state.submissions
        |> Map.values()
        |> Enum.map(&Engine.encode_submission/1),
      "tasks" =>
        state.tasks
        |> Map.values()
        |> Enum.map(&Engine.encode_task/1),
      "docs" =>
        Enum.map(state.doc_histories, fn {address, revisions} ->
          %{
            "address" => Engine.encode_doc_address(address),
            "revisions" => Enum.map(revisions, &encode_revision/1)
          }
        end)
    }
  end

  defp decode(
         %{
           "v" => @snapshot_version,
           "seq" => seq,
           "next_id" => next_id,
           "session_meta" => raw_meta,
           "conversations" => raw_convs,
           "entries" => raw_entries,
           "submissions" => raw_subs,
           "tasks" => raw_tasks,
           "docs" => raw_docs
         },
         expected_seq,
         empty_state
       )
       when seq == expected_seq and is_integer(next_id) and is_map(raw_meta) and
              is_list(raw_convs) and is_list(raw_entries) and is_list(raw_subs) and
              is_list(raw_tasks) and is_list(raw_docs) do
    with {:ok, doc_histories} <- decode_doc_histories(raw_docs, %{}) do
      conversations =
        Map.new(raw_convs, fn raw_c ->
          conv = Engine.normalize_conversation(raw_c, %{})
          {conv.id, conv}
        end)

      entries =
        Map.new(raw_entries, fn raw_e ->
          entry = Engine.normalize_entry(raw_e)
          {entry.id, entry}
        end)

      submissions =
        Map.new(raw_subs, fn raw_s ->
          sub = Engine.normalize_submission(raw_s)
          {sub.request_id, sub}
        end)

      tasks =
        Map.new(raw_tasks, fn raw_t ->
          task = Engine.normalize_task(raw_t)
          {task.id, task}
        end)

      {:ok,
       %{
         empty_state
         | seq: seq,
           next_id: next_id,
           session_meta: Engine.normalize_session_meta(raw_meta),
           conversations: conversations,
           entries: entries,
           submissions: submissions,
           tasks: tasks,
           doc_histories: doc_histories
       }}
    end
  end

  defp decode(_, _, _), do: :error

  defp encode_revision(%{seq: seq, value: value}), do: %{"seq" => seq, "value" => value}
  defp encode_revision(%{seq: seq, retired: true}), do: %{"seq" => seq, "retired" => true}

  defp decode_doc_histories([], acc), do: {:ok, acc}

  defp decode_doc_histories([%{"address" => raw_addr, "revisions" => raw_revs} | rest], acc)
       when is_list(raw_revs) do
    with {:ok, addr} <- Engine.decode_doc_address(raw_addr),
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
end
