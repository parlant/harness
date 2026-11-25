defmodule HWeb.Backend.HTTP.SSEBridge do
  @moduledoc """
  Supervised SSE client bridge processes for `HWeb.Backend.HTTP`.

  Maintains one persistent HTTP/UDS `Req` SSE stream per `{:catalog, key}` or
  `{:conversation, sid, cid, key}` under `HWeb.Backend.HTTP.SSESupervisor` and
  fans out frames to subscribed LiveView processes:
    * `:catalog` -> `{:catalog_frame, seq, bin}`
    * `:conversation` -> `{:commit_frame, seq, bin}` and `{:ephemeral_frame, bin}`
  """

  use GenServer, restart: :temporary

  alias HWeb.Backend.HTTP

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Subscribes `subscriber_pid` to the catalog SSE bridge and returns the initial snapshot."
  def subscribe_catalog(cfg, subscriber_pid) when is_pid(subscriber_pid) do
    subscribe(:catalog, cfg, subscriber_pid, nil)
  end

  @doc "Unsubscribes `subscriber_pid` from the catalog SSE bridge."
  def unsubscribe_catalog(cfg, subscriber_pid) when is_pid(subscriber_pid) do
    unsubscribe({:catalog, bridge_key(cfg)}, cfg.sse_registry, subscriber_pid)
  end

  @doc "Subscribes `subscriber_pid` to a conversation SSE bridge and returns snapshot or replay."
  def subscribe_conversation(cfg, session_id, conversation_id, subscriber_pid, last_event_id)
      when is_pid(subscriber_pid) do
    subscribe(
      {:conversation, session_id, conversation_id},
      cfg,
      subscriber_pid,
      last_event_id
    )
  end

  @doc "Unsubscribes `subscriber_pid` from a conversation SSE bridge."
  def unsubscribe_conversation(cfg, session_id, conversation_id, subscriber_pid)
      when is_pid(subscriber_pid) do
    unsubscribe(
      {:conversation, session_id, conversation_id, bridge_key(cfg)},
      cfg.sse_registry,
      subscriber_pid
    )
  end

  defp subscribe(topic, cfg, subscriber_pid, last_event_id, attempts \\ 2)

  defp subscribe(topic, cfg, subscriber_pid, last_event_id, attempts) when attempts > 0 do
    reg_key =
      case topic do
        :catalog -> {:catalog, bridge_key(cfg)}
        {:conversation, sid, cid} -> {:conversation, sid, cid, bridge_key(cfg)}
      end

    with {:ok, bridge_pid} <- ensure_bridge(topic, reg_key, cfg) do
      try do
        GenServer.call(
          bridge_pid,
          {:subscribe, subscriber_pid, last_event_id},
          cfg.subscribe_timeout_ms
        )
      catch
        :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
          subscribe(topic, cfg, subscriber_pid, last_event_id, attempts - 1)

        :exit, {:timeout, _} ->
          {:error, :daemon_unavailable}

        :exit, _ ->
          {:error, :daemon_unavailable}
      end
    end
  end

  defp subscribe(_topic, _cfg, _subscriber_pid, _last_event_id, 0) do
    {:error, :daemon_unavailable}
  end

  defp unsubscribe(reg_key, registry, subscriber_pid) do
    case Registry.lookup(registry, reg_key) do
      [{bridge_pid, _}] -> GenServer.cast(bridge_pid, {:unsubscribe, subscriber_pid})
      [] -> :ok
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp ensure_bridge(topic, reg_key, cfg) do
    case Registry.lookup(cfg.sse_registry, reg_key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec =
          {__MODULE__, topic: topic, reg_key: reg_key, cfg: cfg}

        case DynamicSupervisor.start_child(cfg.sse_sup, spec) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, {:shutdown, reason}} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
    end
  catch
    :exit, _ -> {:error, :daemon_unavailable}
  end

  defp bridge_key(cfg) do
    {cfg.unix_socket || cfg.base_url, cfg.host}
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    topic = Keyword.fetch!(opts, :topic)
    reg_key = Keyword.fetch!(opts, :reg_key)
    cfg = Keyword.fetch!(opts, :cfg)

    case Registry.register(cfg.sse_registry, reg_key, nil) do
      {:ok, _owner} ->
        state = %{
          topic: topic,
          reg_key: reg_key,
          cfg: cfg,
          resp: nil,
          ref: nil,
          buffer: "",
          subscribers: %{},
          snapshot: nil,
          snapshot_seq: nil,
          last_seq: nil,
          ring: [],
          waiting_initial: nil
        }

        case open_stream(state) do
          {:ok, next_state} -> {:ok, next_state}
          {:error, reason} -> {:stop, reason}
        end

      {:error, {:already_registered, pid}} ->
        {:stop, {:already_started, pid}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.resp do
      Req.cancel_async_response(state.resp)
    end

    :ok
  end

  @impl true
  def handle_call({:subscribe, subscriber_pid, last_event_id}, from, state) do
    state = add_subscriber(state, subscriber_pid)

    case initial_payload(state, last_event_id) do
      {:ready, payload} ->
        {:reply, {:ok, payload}, state}

      :wait ->
        {:noreply, %{state | waiting_initial: {from, subscriber_pid, last_event_id}}}
    end
  end

  @impl true
  def handle_cast({:unsubscribe, subscriber_pid}, state) do
    state = drop_subscriber(state, subscriber_pid)

    if map_size(state.subscribers) == 0 do
      Registry.unregister(state.cfg.sse_registry, state.reg_key)
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, mon_ref, :process, pid, _reason}, state) do
    if Map.get(state.subscribers, pid) == mon_ref do
      state = %{state | subscribers: Map.delete(state.subscribers, pid)}

      if map_size(state.subscribers) == 0 do
        Registry.unregister(state.cfg.sse_registry, state.reg_key)
        {:stop, :normal, state}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, _} = msg, %{ref: ref, resp: resp} = state) when not is_nil(resp) do
    case Req.parse_message(resp, msg) do
      {:ok, parts} ->
        handle_stream_parts(parts, state)

      {:error, _reason} ->
        {:stop, :normal, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp open_stream(state) do
    path = stream_path(state.topic)

    req_opts =
      HTTP.build_req_opts(state.cfg, path,
        into: :self,
        receive_timeout: :infinity
      )

    case Req.get(req_opts) do
      {:ok, %Req.Response{status: 200, body: %Req.Response.Async{ref: ref}} = resp} ->
        receive_initial(%{state | resp: resp, ref: ref})

      {:ok, %Req.Response{status: 404, body: %Req.Response.Async{}} = resp} ->
        Req.cancel_async_response(resp)
        {:error, :not_found}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: 422, body: %Req.Response.Async{}} = resp} ->
        Req.cancel_async_response(resp)
        {:error, {:bad_request, "invalid stream request"}}

      {:ok, %Req.Response{status: 422, body: body}} ->
        msg = if is_map(body), do: body["error"] || "bad request", else: "bad request"
        {:error, {:bad_request, msg}}

      {:ok, %Req.Response{status: _status, body: %Req.Response.Async{}} = resp} ->
        Req.cancel_async_response(resp)
        {:error, :daemon_unavailable}

      {:ok, %Req.Response{status: _status}} ->
        {:error, :daemon_unavailable}

      {:error, _reason} ->
        {:error, :daemon_unavailable}
    end
  end

  defp receive_initial(%{ref: ref, resp: resp, cfg: cfg} = state) do
    deadline = System.monotonic_time(:millisecond) + cfg.subscribe_timeout_ms
    do_receive_initial(state, ref, resp, deadline)
  end

  defp do_receive_initial(state, ref, resp, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^ref, _} = msg ->
        case Req.parse_message(resp, msg) do
          {:ok, parts} ->
            case handle_stream_parts(parts, state) do
              {:noreply, next_state} ->
                if is_binary(next_state.snapshot) do
                  {:ok, next_state}
                else
                  do_receive_initial(next_state, ref, resp, deadline)
                end

              {:stop, _reason, _next_state} ->
                {:error, :daemon_unavailable}
            end

          {:error, _reason} ->
            {:error, :daemon_unavailable}
        end
    after
      remaining ->
        {:error, :daemon_unavailable}
    end
  end

  defp handle_stream_parts(parts, state) do
    Enum.reduce_while(parts, {:noreply, state}, fn
      {:data, chunk}, {:noreply, acc} ->
        {:cont, {:noreply, consume_chunk(acc, chunk)}}

      :done, {:noreply, acc} ->
        {:halt, {:stop, :normal, acc}}

      _other, {:noreply, acc} ->
        {:cont, {:noreply, acc}}
    end)
  end

  defp consume_chunk(state, chunk) do
    {frames, rest} = split_frames(state.buffer <> chunk, [])
    state = %{state | buffer: rest}
    Enum.reduce(frames, state, &apply_sse_frame(&2, &1))
  end

  defp split_frames(buffer, acc) do
    case :binary.split(buffer, "\n\n") do
      [raw_frame, rest] ->
        split_frames(rest, [raw_frame | acc])

      [_incomplete] ->
        {Enum.reverse(acc), buffer}
    end
  end

  defp apply_sse_frame(state, raw_frame) do
    parsed = parse_sse_frame(raw_frame)

    case parsed do
      %{event: "snapshot", id: id_str, data: bin} when is_binary(bin) and bin != "" ->
        seq = parse_int(id_str) || 0

        state = %{
          state
          | snapshot: bin,
            snapshot_seq: seq,
            last_seq: seq,
            ring: []
        }

        maybe_reply_waiting_initial(state)

      %{event: "catalog", id: id_str, data: bin}
      when state.topic == :catalog and is_binary(bin) and bin != "" ->
        seq = parse_int(id_str) || (state.last_seq || 0) + 1
        broadcast(state, {:catalog_frame, seq, bin})
        %{state | last_seq: seq}

      %{event: "commit", id: id_str, data: bin} when is_binary(bin) and bin != "" ->
        seq = parse_int(id_str) || (state.last_seq || 0) + 1
        ring = Enum.take(state.ring ++ [{seq, bin}], -64)
        broadcast(state, {:commit_frame, seq, bin})
        %{state | last_seq: seq, ring: ring}

      %{event: "ephemeral", data: bin} when is_binary(bin) and bin != "" ->
        broadcast(state, {:ephemeral_frame, bin})
        state

      _ ->
        state
    end
  end

  defp maybe_reply_waiting_initial(%{waiting_initial: nil} = state), do: state

  defp maybe_reply_waiting_initial(%{waiting_initial: {from, _pid, last_event_id}} = state) do
    case initial_payload(state, last_event_id) do
      {:ready, payload} ->
        GenServer.reply(from, {:ok, payload})
        %{state | waiting_initial: nil}

      :wait ->
        state
    end
  end

  defp initial_payload(%{snapshot: nil}, _last_event_id), do: :wait

  defp initial_payload(
         %{topic: :catalog, snapshot: bin, snapshot_seq: seq} = state,
         _last_event_id
       ) do
    if state.last_seq && state.last_seq > seq do
      case fetch_fresh_initial(state.cfg, :catalog, nil) do
        {:ok, payload} -> {:ready, payload}
        :error -> {:ready, {:snapshot, seq, bin}}
      end
    else
      {:ready, {:snapshot, seq, bin}}
    end
  end

  defp initial_payload(
         %{snapshot: bin, snapshot_seq: snap_seq, last_seq: last_seq, ring: ring} = state,
         last_event_id
       ) do
    parsed_last = parse_int(last_event_id)

    cond do
      is_integer(parsed_last) and parsed_last >= snap_seq and parsed_last <= last_seq ->
        missed = Enum.filter(ring, fn {seq, _bin} -> seq > parsed_last end)
        {:ready, {:replay, missed}}

      ring == [] ->
        {:ready, {:snapshot, snap_seq, bin}}

      true ->
        # A second subscriber joined after commits arrived on this bridge.
        # Fetch an up-to-date snapshot/replay directly from the daemon SSE endpoint
        # without disrupting existing subscribers on this bridge.
        case fetch_fresh_initial(state.cfg, state.topic, parsed_last) do
          {:ok, payload} -> {:ready, payload}
          :error -> {:ready, {:snapshot, snap_seq, bin}}
        end
    end
  end

  defp fetch_fresh_initial(cfg, topic, last_event_id) do
    path =
      if is_integer(last_event_id) do
        stream_path(topic) <> "?last_event_id=#{last_event_id}"
      else
        stream_path(topic)
      end

    req_opts = HTTP.build_req_opts(cfg, path, into: :self, receive_timeout: :infinity)

    case Req.get(req_opts) do
      {:ok, %Req.Response{status: 200, body: %Req.Response.Async{ref: ref}} = resp} ->
        try do
          read_one_initial(resp, ref, "", cfg.subscribe_timeout_ms)
        after
          Req.cancel_async_response(resp)
        end

      {:ok, %Req.Response{body: %Req.Response.Async{}} = resp} ->
        Req.cancel_async_response(resp)
        :error

      _ ->
        :error
    end
  end

  defp read_one_initial(resp, ref, buffer, timeout_ms) do
    receive do
      {^ref, _} = msg ->
        case Req.parse_message(resp, msg) do
          {:ok, parts} ->
            next_buf =
              Enum.reduce(parts, buffer, fn
                {:data, chunk}, acc -> acc <> chunk
                _, acc -> acc
              end)

            {frames, rest} = split_frames(next_buf, [])

            case extract_initial_from_frames(frames) do
              {:ok, payload} -> {:ok, payload}
              :none -> read_one_initial(resp, ref, rest, timeout_ms)
            end

          {:error, _} ->
            :error
        end
    after
      timeout_ms -> :error
    end
  end

  defp extract_initial_from_frames([]), do: :none

  defp extract_initial_from_frames(frames) do
    parsed = Enum.map(frames, &parse_sse_frame/1)

    case Enum.find(parsed, &(&1.event == "snapshot" and &1.data != "")) do
      %{id: id_str, data: bin} ->
        {:ok, {:snapshot, parse_int(id_str) || 0, bin}}

      nil ->
        commits =
          for %{event: "commit", id: id_str, data: bin} <- parsed,
              seq = parse_int(id_str),
              not is_nil(seq) and bin != "" do
            {seq, bin}
          end

        if commits != [], do: {:ok, {:replay, commits}}, else: :none
    end
  end

  defp broadcast(state, message) do
    for {pid, _ref} <- state.subscribers do
      send(pid, message)
    end
  end

  defp add_subscriber(state, pid) do
    if Map.has_key?(state.subscribers, pid) do
      state
    else
      ref = Process.monitor(pid)
      %{state | subscribers: Map.put(state.subscribers, pid, ref)}
    end
  end

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        state

      {ref, rest} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: rest}
    end
  end

  defp stream_path(:catalog), do: "/api/v1/sessions/events"

  defp stream_path({:conversation, sid, cid}) do
    "/api/v1/sessions/#{URI.encode(sid)}/conversations/#{URI.encode(to_string(cid))}/events"
  end

  defp parse_sse_frame(raw_frame) do
    lines = String.split(raw_frame, "\n")

    parsed =
      Enum.reduce(lines, %{id: nil, event: nil, data_lines: []}, fn line, acc ->
        cond do
          String.starts_with?(line, "id:") ->
            %{acc | id: line |> String.trim_leading("id:") |> String.trim_leading()}

          String.starts_with?(line, "event:") ->
            %{acc | event: line |> String.trim_leading("event:") |> String.trim_leading()}

          String.starts_with?(line, "data:") ->
            d = line |> String.trim_leading("data:") |> String.trim_leading()
            %{acc | data_lines: [d | acc.data_lines]}

          true ->
            acc
        end
      end)

    %{
      id: parsed.id,
      event: parsed.event,
      data: parsed.data_lines |> Enum.reverse() |> Enum.join("\n")
    }
  end

  defp parse_int(val) when is_integer(val) and val >= 0, do: val

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil
end
