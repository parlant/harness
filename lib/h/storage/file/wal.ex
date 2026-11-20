defmodule H.Storage.File.Wal do
  @moduledoc """
  CRC32-framed binary write-ahead log (`commit.log`) encoding, appending,
  replay, and torn-tail recovery for `H.Storage.File`.
  """

  alias H.Storage.Engine

  @magic 0x484C4F47
  @frame_version 1
  @header_bytes 13

  def sync_fd(_fd, :none), do: :ok
  def sync_fd(fd, :datasync), do: :file.datasync(fd)
  def sync_fd(fd, :sync), do: :file.sync(fd)

  def append_frame(fd, sync, next_id, accepted_batches) do
    frame_bytes = encode_frame(next_id, accepted_batches)

    with :ok <- :file.write(fd, frame_bytes) do
      sync_fd(fd, sync)
    end
  end

  def replay(fd, state, snapshot_seq, sync) do
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

  def replay_read_only(fd, state, snapshot_seq) do
    with {:ok, file_size} <- :file.position(fd, :eof),
         {:ok, bin} <- read_log_bytes(fd, file_size) do
      {next_state, _valid_offset, _replayed_commits} =
        scan_frames(bin, 0, state, snapshot_seq, 0)

      {:ok, next_state}
    end
  end

  def encode_frame(next_id, accepted_batches) do
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

  # Internal replay & frame decoding

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
      case Engine.apply_batch(writes, batch_seq, %{state | seq: batch_seq}) do
        {:ok, next_state} -> replay_batches(rest, next_state, snapshot_seq, true)
        {:error, _} -> :error
      end
    else
      replay_batches(rest, state, snapshot_seq, applied_any?)
    end
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
    %{"op" => "put_conversation", "conversation" => Engine.encode_conversation(conv)}
  end

  defp encode_write({:append_entry, entry}) do
    %{"op" => "append_entry", "entry" => Engine.encode_entry(entry)}
  end

  defp encode_write({:put_submission, sub}) do
    %{"op" => "put_submission", "submission" => Engine.encode_submission(sub)}
  end

  defp encode_write({:put_task, task}) do
    %{"op" => "put_task", "task" => Engine.encode_task(task)}
  end

  defp encode_write({:put_doc, address, doc_record}) do
    %{
      "op" => "put_doc",
      "address" => Engine.encode_doc_address(address),
      "doc" => doc_record
    }
  end

  defp encode_write({:retire_doc, address}) do
    %{"op" => "retire_doc", "address" => Engine.encode_doc_address(address)}
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
    {:ok, {:put_submission, Engine.decode_submission_tuples(sub)}}
  end

  defp decode_write(%{"op" => "put_task", "task" => task}) when is_map(task) do
    {:ok, {:put_task, task}}
  end

  defp decode_write(%{"op" => "put_doc", "address" => raw_addr, "doc" => doc}) when is_map(doc) do
    with {:ok, addr} <- Engine.decode_doc_address(raw_addr) do
      {:ok, {:put_doc, addr, doc}}
    end
  end

  defp decode_write(%{"op" => "retire_doc", "address" => raw_addr}) do
    with {:ok, addr} <- Engine.decode_doc_address(raw_addr) do
      {:ok, {:retire_doc, addr}}
    end
  end

  defp decode_write(_), do: :error
end
