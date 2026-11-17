defmodule H.HTTP.SSE do
  @moduledoc """
  Chunked Server-Sent Events (`text/event-stream`) transport loop.

  Handles:
    * Optional `Last-Event-ID` header / `last_event_id` query parameter parsing.
    * Initial atomic `snapshot` or missed `commit` ring replay.
    * Zero-copy `ProcBin` `{:commit_frame, seq, bin}` and ID-less `{:ephemeral_frame, bin}` streaming.
    * Bounded slow-client backpressure via mailbox drain and fresh `snapshot` replacement.
    * Periodic `: keepalive` comments and clean exit on socket write error or `{:close_sse, reason}`.
  """

  import Plug.Conn

  @default_keepalive_ms 15_000
  @default_max_queue_len 128
  @default_max_queue_bytes 2_097_152

  @doc """
  Subscribes the current request process to `(sid, cid)` via `daemon` and streams
  SSE frames until the client disconnects or `{:close_sse, reason}` is received.
  """
  @spec stream(Plug.Conn.t(), String.t(), String.t(), keyword()) :: Plug.Conn.t()
  def stream(conn, sid, cid, opts \\ []) do
    conn = fetch_query_params(conn)
    daemon = Keyword.get(opts, :daemon, H.Daemon)
    daemon_opts = Keyword.get(opts, :daemon_opts, [])
    last_event_id = parse_last_event_id(conn)

    case apply(daemon, :subscribe_conversation, [sid, cid, self(), last_event_id, daemon_opts]) do
      {:ok, initial} ->
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)

        state = %{
          sid: sid,
          cid: cid,
          daemon: daemon,
          daemon_opts: daemon_opts,
          keepalive_ms: Keyword.get(opts, :sse_keepalive_ms, @default_keepalive_ms),
          max_queue_len: Keyword.get(opts, :sse_max_queue_len, @default_max_queue_len),
          max_queue_bytes: Keyword.get(opts, :sse_max_queue_bytes, @default_max_queue_bytes),
          last_sent_seq: last_event_id
        }

        case emit_initial(conn, initial, state.last_sent_seq) do
          {:ok, conn, last_seq} ->
            loop(conn, %{state | last_sent_seq: last_seq})

          {:error, conn} ->
            conn
        end

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "not found"})

      {:error, {:bad_request, msg}} ->
        send_json(conn, 422, %{"error" => msg})
    end
  end

  defp parse_last_event_id(conn) do
    raw =
      case get_req_header(conn, "last-event-id") do
        [val | _] -> val
        [] -> conn.query_params["last_event_id"]
      end

    parse_non_neg_int(raw)
  end

  defp parse_non_neg_int(val) when is_binary(val) do
    trimmed = String.trim(val)

    if Regex.match?(~r/^\d+$/, trimmed) do
      String.to_integer(trimmed)
    else
      nil
    end
  end

  defp parse_non_neg_int(_), do: nil

  defp emit_initial(conn, {:snapshot, seq, bin}, _last_seq) do
    case chunk(conn, snapshot_frame(seq, bin)) do
      {:ok, conn} -> {:ok, conn, seq}
      {:error, _reason} -> {:error, conn}
    end
  end

  defp emit_initial(conn, {:replay, frames}, last_seq) when is_list(frames) do
    Enum.reduce_while(frames, {:ok, conn, last_seq}, fn {seq, bin}, {:ok, acc_conn, acc_seq} ->
      if is_integer(acc_seq) and seq <= acc_seq do
        {:cont, {:ok, acc_conn, acc_seq}}
      else
        case chunk(acc_conn, commit_frame(seq, bin)) do
          {:ok, next_conn} -> {:cont, {:ok, next_conn, seq}}
          {:error, _reason} -> {:halt, {:error, acc_conn}}
        end
      end
    end)
  end

  defp loop(conn, state) do
    if queue_overflow?(state.max_queue_len, state.max_queue_bytes) do
      resnapshot(conn, state)
    else
      receive do
        {:commit_frame, seq, bin} ->
          if queue_overflow?(state.max_queue_len, state.max_queue_bytes) do
            resnapshot(conn, state)
          else
            send_commit(conn, seq, bin, state)
          end

        {:ephemeral_frame, bin} ->
          if queue_overflow?(state.max_queue_len, state.max_queue_bytes) do
            resnapshot(conn, state)
          else
            send_ephemeral(conn, bin, state)
          end

        {:close_sse, _reason} ->
          conn
      after
        state.keepalive_ms ->
          case chunk(conn, ": keepalive\n\n") do
            {:ok, conn} -> loop(conn, state)
            {:error, _reason} -> conn
          end
      end
    end
  end

  defp send_commit(conn, seq, bin, state) do
    if is_integer(state.last_sent_seq) and seq <= state.last_sent_seq do
      loop(conn, state)
    else
      case chunk(conn, commit_frame(seq, bin)) do
        {:ok, conn} -> loop(conn, %{state | last_sent_seq: seq})
        {:error, _reason} -> conn
      end
    end
  end

  defp send_ephemeral(conn, bin, state) do
    case chunk(conn, ["event: ephemeral\ndata: ", bin, "\n\n"]) do
      {:ok, conn} -> loop(conn, state)
      {:error, _reason} -> conn
    end
  end

  defp resnapshot(conn, state) do
    drain_frames(nil)

    case apply(state.daemon, :subscribe_conversation, [
           state.sid,
           state.cid,
           self(),
           nil,
           state.daemon_opts
         ]) do
      {:ok, {:snapshot, seq, _bin} = initial} ->
        drain_frames(seq)

        case emit_initial(conn, initial, state.last_sent_seq) do
          {:ok, conn, last_seq} -> loop(conn, %{state | last_sent_seq: last_seq})
          {:error, conn} -> conn
        end

      {:ok, initial} ->
        case emit_initial(conn, initial, state.last_sent_seq) do
          {:ok, conn, last_seq} -> loop(conn, %{state | last_sent_seq: last_seq})
          {:error, conn} -> conn
        end

      {:error, _reason} ->
        conn
    end
  end

  defp drain_frames(max_seq) do
    receive do
      {:commit_frame, seq, _} when is_nil(max_seq) or seq <= max_seq ->
        drain_frames(max_seq)

      {:ephemeral_frame, _} ->
        drain_frames(max_seq)
    after
      0 -> :ok
    end
  end

  defp queue_overflow?(max_len, max_bytes) do
    case Process.info(self(), [:message_queue_len, :memory]) do
      [message_queue_len: qlen, memory: mem] -> qlen > max_len or mem > max_bytes
      _ -> false
    end
  end

  defp snapshot_frame(seq, bin) do
    ["id: ", Integer.to_string(seq), "\nevent: snapshot\ndata: ", bin, "\n\n"]
  end

  defp commit_frame(seq, bin) do
    ["id: ", Integer.to_string(seq), "\nevent: commit\ndata: ", bin, "\n\n"]
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(payload))
  end
end
