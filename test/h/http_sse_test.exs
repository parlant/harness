defmodule H.HTTP.SSETest do
  use ExUnit.Case, async: true

  alias H.Auth
  alias H.HTTP.Router

  defmodule FakeDaemon do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    def subscribe_conversation(sid, cid, pid, last_event_id, opts) do
      server = Keyword.fetch!(opts, :server)
      GenServer.call(server, {:subscribe, sid, cid, pid, last_event_id})
    end

    def subscribe_sessions(pid, opts) do
      server = Keyword.fetch!(opts, :server)
      GenServer.call(server, {:subscribe_sessions, pid})
    end

    def emit_catalog_burst(server, count) do
      GenServer.call(server, {:emit_catalog_burst, count})
    end

    def emit_catalog_upsert(server, sid, attrs) do
      GenServer.call(server, {:emit_catalog_upsert, sid, attrs})
    end

    def emit_commit(server, sid, cid, data_map) do
      GenServer.call(server, {:emit_commit, sid, cid, data_map})
    end

    def emit_ephemeral(server, sid, cid, data_map) do
      GenServer.call(server, {:emit_ephemeral, sid, cid, data_map})
    end

    def emit_burst(server, sid, cid, count) do
      GenServer.call(server, {:emit_burst, sid, cid, count})
    end

    def close_subscribers(server, sid, cid, reason \\ :shutdown) do
      GenServer.call(server, {:close_subscribers, sid, cid, reason})
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         seq: 1,
         ring: [],
         subscribers: %{},
         monitors: %{},
         notify_pid: Keyword.get(opts, :notify_pid)
       }}
    end

    def subscriber_count(server, sid, cid) do
      GenServer.call(server, {:subscriber_count, sid, cid})
    end

    @impl true
    def handle_call({:subscriber_count, sid, cid}, _from, state) do
      {:reply, state.subscribers |> Map.get({sid, cid}, MapSet.new()) |> MapSet.size(), state}
    end

    def handle_call({:subscribe, "missing", _cid, _pid, _last_id}, _from, state) do
      {:reply, {:error, :not_found}, state}
    end

    def handle_call({:subscribe, _sid, "bad", _pid, _last_id}, _from, state) do
      {:reply, {:error, {:bad_request, "invalid conversation_id"}}, state}
    end

    def handle_call({:subscribe, sid, cid, pid, last_event_id}, _from, state) do
      if notify_pid = state[:notify_pid] do
        send(notify_pid, {:subscribed, sid, cid, pid, last_event_id})
      end

      key = {sid, cid}
      subs = Map.get(state.subscribers, key, MapSet.new())

      {subs, monitors} =
        if MapSet.member?(subs, pid) do
          {subs, state.monitors}
        else
          ref = Process.monitor(pid)
          {MapSet.put(subs, pid), Map.put(state.monitors, ref, {key, pid})}
        end

      state = %{
        state
        | subscribers: Map.put(state.subscribers, key, subs),
          monitors: monitors
      }

      min_ring_seq =
        case state.ring do
          [{first_seq, _} | _] -> first_seq
          [] -> state.seq + 1
        end

      reply =
        if is_integer(last_event_id) and last_event_id >= min_ring_seq - 1 and
             last_event_id <= state.seq do
          missed = Enum.filter(state.ring, fn {seq, _bin} -> seq > last_event_id end)
          {:ok, {:replay, missed}}
        else
          {:ok, {:snapshot, state.seq, encode_snapshot(sid, cid, state.seq)}}
        end

      {:reply, reply, state}
    end

    def handle_call({:subscribe_sessions, pid}, _from, state) do
      key = :catalog
      subs = Map.get(state.subscribers, key, MapSet.new())

      {subs, monitors} =
        if MapSet.member?(subs, pid) do
          {subs, state.monitors}
        else
          ref = Process.monitor(pid)
          {MapSet.put(subs, pid), Map.put(state.monitors, ref, {key, pid})}
        end

      state = %{
        state
        | subscribers: Map.put(state.subscribers, key, subs),
          monitors: monitors
      }

      snap =
        JSON.encode!(%{
          "version" => 1,
          "seq" => state.seq,
          "sessions" => []
        })

      {:reply, {:ok, {:snapshot, state.seq, snap}}, state}
    end

    def handle_call({:emit_catalog_burst, count}, _from, state) do
      subs = Map.get(state.subscribers, :catalog, MapSet.new())

      seq =
        Enum.reduce(1..count, state.seq, fn i, acc_seq ->
          next_seq = acc_seq + 1

          bin =
            JSON.encode!(%{
              "version" => 1,
              "seq" => next_seq,
              "type" => "upsert",
              "session" => %{"session_id" => "s-#{i}", "attention" => "running"}
            })

          for pid <- subs do
            send(pid, {:catalog_frame, next_seq, bin})
          end

          next_seq
        end)

      {:reply, {:ok, seq}, %{state | seq: seq}}
    end

    def handle_call({:emit_catalog_upsert, sid, attrs}, _from, state) do
      seq = state.seq + 1

      bin =
        JSON.encode!(%{
          "version" => 1,
          "seq" => seq,
          "type" => "upsert",
          "session" => Map.put(attrs, "session_id", sid)
        })

      for pid <- Map.get(state.subscribers, :catalog, MapSet.new()) do
        send(pid, {:catalog_frame, seq, bin})
      end

      {:reply, {:ok, seq}, %{state | seq: seq}}
    end

    def handle_call({:emit_commit, sid, cid, data_map}, _from, state) do
      seq = state.seq + 1
      bin = encode_commit(sid, cid, seq, data_map)
      ring = Enum.take(state.ring ++ [{seq, bin}], -32)

      for pid <- Map.get(state.subscribers, {sid, cid}, MapSet.new()) do
        send(pid, {:commit_frame, seq, bin})
      end

      {:reply, {:ok, seq}, %{state | seq: seq, ring: ring}}
    end

    def handle_call({:emit_ephemeral, sid, cid, data_map}, _from, state) do
      bin = encode_ephemeral(state.seq, data_map)

      for pid <- Map.get(state.subscribers, {sid, cid}, MapSet.new()) do
        send(pid, {:ephemeral_frame, bin})
      end

      {:reply, :ok, state}
    end

    def handle_call({:emit_burst, sid, cid, count}, _from, state) do
      subs = Map.get(state.subscribers, {sid, cid}, MapSet.new())

      {seq, ring} =
        Enum.reduce(1..count, {state.seq, state.ring}, fn i, {acc_seq, acc_ring} ->
          next_seq = acc_seq + 1

          bin =
            encode_commit(sid, cid, next_seq, %{
              "burst" => i,
              "pad" => String.duplicate("x", 80)
            })

          for pid <- subs do
            send(pid, {:commit_frame, next_seq, bin})
          end

          {next_seq, Enum.take(acc_ring ++ [{next_seq, bin}], -32)}
        end)

      {:reply, {:ok, seq}, %{state | seq: seq, ring: ring}}
    end

    def handle_call({:close_subscribers, sid, cid, reason}, _from, state) do
      for pid <- Map.get(state.subscribers, {sid, cid}, MapSet.new()) do
        send(pid, {:close_sse, reason})
      end

      {:reply, :ok, state}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
      case Map.pop(state.monitors, ref) do
        {nil, monitors} ->
          {:noreply, %{state | monitors: monitors}}

        {{key, pid}, monitors} ->
          subs =
            state.subscribers
            |> Map.get(key, MapSet.new())
            |> MapSet.delete(pid)

          {:noreply,
           %{state | subscribers: Map.put(state.subscribers, key, subs), monitors: monitors}}
      end
    end

    defp encode_snapshot(sid, cid, seq) do
      JSON.encode!(%{
        "version" => 1,
        "session_id" => sid,
        "conversation_id" => cid,
        "seq" => seq,
        "before_entry_id" => nil,
        "entries" => [%{"id" => "1", "conversation_id" => cid, "kind" => "user", "data" => %{}}],
        "docs" => %{
          "live" => %{},
          "inbox" => [],
          "agent" => %{"model" => "fake"},
          "usage" => %{}
        }
      })
    end

    defp encode_commit(sid, cid, seq, data_map) do
      JSON.encode!(%{
        "version" => 1,
        "session_id" => sid,
        "conversation_id" => cid,
        "seq" => seq,
        "appended_entries" => [
          %{
            "id" => Integer.to_string(seq),
            "conversation_id" => cid,
            "kind" => "assistant",
            "data" => data_map
          }
        ],
        "doc_ops" => %{}
      })
    end

    defp encode_ephemeral(base_seq, data_map) do
      JSON.encode!(%{
        "version" => 1,
        "base_seq" => base_seq,
        "doc_ops" => %{
          "live" => [["append_text", ["generation", "message", "text"], data_map["delta"]]]
        }
      })
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  defp start_bandit_daemon(router_overrides \\ []) do
    id = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "h-http-sse-test-#{id}")
    table = :"h_http_sse_auth_#{id}"
    auth_server = :"H.HTTP.SSETest.Auth.#{id}"

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    start_supervised!({Auth, data_dir: tmp_dir, name: auth_server, table: table})
    daemon = start_supervised!({FakeDaemon, notify_pid: self()})
    token = Auth.owner_token(table)

    router_opts =
      Keyword.merge(
        [
          auth_server: auth_server,
          auth_table: table,
          daemon: FakeDaemon,
          daemon_opts: [server: daemon]
        ],
        router_overrides
      )

    bandit =
      start_supervised!(
        {Bandit,
         plug: {Router, router_opts},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [shutdown_timeout: 50]}
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(bandit)
    base_url = "http://127.0.0.1:#{port}"

    %{
      base_url: base_url,
      port: port,
      token: token,
      daemon: daemon
    }
  end

  defp next_sse_event(resp, buffer \\ "", timeout \\ 2_000) do
    case extract_sse_frame(buffer) do
      {:ok, raw_frame, rest} ->
        {:ok, parse_sse_frame(raw_frame), rest}

      :more ->
        receive_sse_chunk(resp, buffer, timeout)
    end
  end

  defp receive_sse_chunk(%{body: %Req.Response.Async{ref: ref}} = resp, buffer, timeout) do
    receive do
      {^ref, _} = msg ->
        case Req.parse_message(resp, msg) do
          {:ok, [data: chunk]} ->
            next_sse_event(resp, buffer <> chunk, timeout)

          {:ok, [:done]} ->
            {:done, buffer}

          {:ok, [_other]} ->
            receive_sse_chunk(resp, buffer, timeout)

          {:error, reason} ->
            {:error, reason}
        end
    after
      timeout -> :timeout
    end
  end

  defp extract_sse_frame(buffer) do
    case :binary.split(buffer, "\n\n") do
      [raw_frame, rest] -> {:ok, raw_frame, rest}
      [_incomplete] -> :more
    end
  end

  defp parse_sse_frame(raw_frame) do
    if String.starts_with?(raw_frame, ":") do
      %{raw: raw_frame, comment: true, id: nil, event: nil, data: nil}
    else
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

      data_str = parsed.data_lines |> Enum.reverse() |> Enum.join("\n")

      %{
        raw: raw_frame,
        comment: false,
        id: parsed.id,
        event: parsed.event,
        data: JSON.decode!(data_str)
      }
    end
  end

  describe "HTTP/SSE subscription and streaming" do
    test "returns 404/422 JSON before chunking on missing session or bad conversation" do
      ctx = start_bandit_daemon()
      headers = [{"authorization", "Bearer #{ctx.token}"}]

      r404 =
        Req.get!("#{ctx.base_url}/api/v1/sessions/missing/conversations/1/events",
          headers: headers,
          retry: false
        )

      assert r404.status == 404
      assert r404.body == %{"error" => "not found"}

      r422 =
        Req.get!("#{ctx.base_url}/api/v1/sessions/demo/conversations/bad/events",
          headers: headers,
          retry: false
        )

      assert r422.status == 422
      assert r422.body == %{"error" => "invalid conversation_id"}
    end

    test "streams snapshot, shared commit frames, and ID-less ephemeral frames to two concurrent clients" do
      ctx = start_bandit_daemon()
      bearer_headers = [{"authorization", "Bearer #{ctx.token}"}]

      cookie_resp =
        Req.post!("#{ctx.base_url}/api/v1/auth/session",
          json: %{"token" => ctx.token}
        )

      [set_cookie] = Req.Response.get_header(cookie_resp, "set-cookie")
      cookie_pair = set_cookie |> String.split(";", parts: 2) |> hd()
      cookie_headers = [{"cookie", cookie_pair}]

      url = "#{ctx.base_url}/api/v1/sessions/demo/conversations/1/events"
      resp1 = Req.get!(url, headers: bearer_headers, into: :self, retry: false)
      resp2 = Req.get!(url, headers: cookie_headers, into: :self, retry: false)

      assert resp1.status == 200

      assert Req.Response.get_header(resp1, "content-type") == [
               "text/event-stream; charset=utf-8"
             ]

      assert Req.Response.get_header(resp1, "cache-control") == ["no-cache"]
      assert Req.Response.get_header(resp1, "x-accel-buffering") == ["no"]
      assert resp2.status == 200

      {:ok, snap1, buf1} = next_sse_event(resp1)
      {:ok, snap2, buf2} = next_sse_event(resp2)
      assert snap1.event == "snapshot"
      assert snap1.id == "1"
      assert snap1.data["seq"] == 1
      assert snap2.event == "snapshot"
      assert snap2.id == "1"

      # Ephemeral frame must NOT carry an id: line
      :ok = FakeDaemon.emit_ephemeral(ctx.daemon, "demo", "1", %{"delta" => "Hel"})
      {:ok, eph1, buf1} = next_sse_event(resp1, buf1)
      {:ok, eph2, buf2} = next_sse_event(resp2, buf2)

      assert eph1.event == "ephemeral"
      assert eph1.id == nil
      refute eph1.raw =~ ~r/^id:/m
      assert eph1.data["base_seq"] == 1
      assert eph2.event == "ephemeral"
      assert eph2.id == nil

      # Commit frame carries id: <seq> and >64-byte ProcBin payload
      {:ok, 2} =
        FakeDaemon.emit_commit(ctx.daemon, "demo", "1", %{
          "text" => String.duplicate("hello ", 20)
        })

      {:ok, c1, buf1} = next_sse_event(resp1, buf1)
      {:ok, c2, buf2} = next_sse_event(resp2, buf2)

      assert c1.event == "commit"
      assert c1.id == "2"
      assert c1.data["seq"] == 2
      assert c2 == c1

      # Clean server close delivers :done
      :ok = FakeDaemon.close_subscribers(ctx.daemon, "demo", "1", :shutdown)
      assert {:done, _} = next_sse_event(resp1, buf1)
      assert {:done, _} = next_sse_event(resp2, buf2)

      Req.cancel_async_response(resp1)
      Req.cancel_async_response(resp2)
    end

    test "replays missed commits via Last-Event-ID header and query param" do
      ctx = start_bandit_daemon()
      {:ok, 2} = FakeDaemon.emit_commit(ctx.daemon, "demo", "1", %{"n" => 2})
      {:ok, 3} = FakeDaemon.emit_commit(ctx.daemon, "demo", "1", %{"n" => 3})
      {:ok, 4} = FakeDaemon.emit_commit(ctx.daemon, "demo", "1", %{"n" => 4})

      url = "#{ctx.base_url}/api/v1/sessions/demo/conversations/1/events"

      resp_hdr =
        Req.get!(url,
          headers: [{"authorization", "Bearer #{ctx.token}"}, {"last-event-id", "2"}],
          into: :self,
          retry: false
        )

      {:ok, f3, buf} = next_sse_event(resp_hdr)
      {:ok, f4, _buf} = next_sse_event(resp_hdr, buf)
      assert f3.event == "commit"
      assert f3.id == "3"
      assert f4.event == "commit"
      assert f4.id == "4"
      Req.cancel_async_response(resp_hdr)

      # Invalid Last-Event-ID falls back to full snapshot
      resp_bad =
        Req.get!("#{url}?last_event_id=not-a-number",
          headers: [{"authorization", "Bearer #{ctx.token}"}],
          into: :self,
          retry: false
        )

      assert_receive {:subscribed, "demo", "1", _pid, nil}
      {:ok, snap, _buf} = next_sse_event(resp_bad)
      assert snap.event == "snapshot"
      assert snap.id == "4"
      Req.cancel_async_response(resp_bad)

      # Query param ?last_event_id=0 parses as integer 0
      resp_zero =
        Req.get!("#{url}?last_event_id=0",
          headers: [{"authorization", "Bearer #{ctx.token}"}],
          into: :self,
          retry: false
        )

      assert_receive {:subscribed, "demo", "1", _pid, 0}
      {:ok, snap_zero, _buf} = next_sse_event(resp_zero)
      assert snap_zero.event == "snapshot"
      Req.cancel_async_response(resp_zero)
    end

    test "exits cleanly when client closes socket and chunk fails" do
      ctx = start_bandit_daemon(sse_keepalive_ms: 20)
      url = "#{ctx.base_url}/api/v1/sessions/demo/conversations/1/events"

      resp =
        Req.get!(url,
          headers: [{"authorization", "Bearer #{ctx.token}"}],
          into: :self,
          retry: false
        )

      {:ok, _snap, _buf} = next_sse_event(resp)
      assert_receive {:subscribed, "demo", "1", connection, nil}
      ref = Process.monitor(connection)
      assert FakeDaemon.subscriber_count(ctx.daemon, "demo", "1") == 1

      Req.cancel_async_response(resp)
      assert_receive {:DOWN, ^ref, :process, ^connection, _}, 1_000
    end

    test "emits periodic : keepalive comments" do
      ctx = start_bandit_daemon(sse_keepalive_ms: 40)
      url = "#{ctx.base_url}/api/v1/sessions/demo/conversations/1/events"

      resp =
        Req.get!(url,
          headers: [{"authorization", "Bearer #{ctx.token}"}],
          into: :self,
          retry: false
        )

      {:ok, snap, buf} = next_sse_event(resp)
      assert snap.event == "snapshot"

      {:ok, ka, _buf} = next_sse_event(resp, buf, 1_000)
      assert ka.comment
      assert ka.raw == ": keepalive"
      Req.cancel_async_response(resp)
    end

    test "recovers from slow-client queue overflow with a fresh snapshot frame" do
      ctx = start_bandit_daemon(sse_max_queue_len: 5)
      url = "#{ctx.base_url}/api/v1/sessions/demo/conversations/1/events"

      resp =
        Req.get!(url,
          headers: [{"authorization", "Bearer #{ctx.token}"}],
          into: :self,
          retry: false
        )

      {:ok, snap1, buf} = next_sse_event(resp)
      assert snap1.event == "snapshot"
      assert snap1.id == "1"

      # Burst 40 frames in one FakeDaemon GenServer call to overflow the 5-frame queue
      {:ok, 41} = FakeDaemon.emit_burst(ctx.daemon, "demo", "1", 40)

      {events, buf} = drain_until_snapshot(resp, buf, 41, [])
      snapshot_events = Enum.filter(events, &(&1.event == "snapshot"))
      assert [%{id: "41", data: %{"seq" => 41}}] = snapshot_events
      assert length(events) < 40

      # Subsequent commit after recovery still arrives cleanly at seq 42
      {:ok, 42} = FakeDaemon.emit_commit(ctx.daemon, "demo", "1", %{"after" => "recovery"})
      {:ok, c42, _buf} = next_sse_event(resp, buf)
      assert c42.event == "commit"
      assert c42.id == "42"

      Req.cancel_async_response(resp)
    end

    test "recovers from slow-client queue overflow on /api/v1/sessions/events with a fresh snapshot frame" do
      ctx = start_bandit_daemon(sse_max_queue_len: 5)
      url = "#{ctx.base_url}/api/v1/sessions/events"

      resp =
        Req.get!(url,
          headers: [{"authorization", "Bearer #{ctx.token}"}],
          into: :self,
          retry: false
        )

      {:ok, snap1, buf} = next_sse_event(resp)
      assert snap1.event == "snapshot"
      assert snap1.id == "1"

      {:ok, 41} = FakeDaemon.emit_catalog_burst(ctx.daemon, 40)

      {events, buf} = drain_until_snapshot(resp, buf, 41, [])
      snapshot_events = Enum.filter(events, &(&1.event == "snapshot"))
      assert [%{id: "41", data: %{"seq" => 41}}] = snapshot_events
      assert length(events) < 40

      {:ok, 42} = FakeDaemon.emit_catalog_upsert(ctx.daemon, "after", %{"attention" => "idle"})
      {:ok, c42, _buf} = next_sse_event(resp, buf)
      assert c42.event == "catalog"
      assert c42.id == "42"
      assert c42.data["type"] == "upsert"
      assert c42.data["session"]["session_id"] == "after"

      Req.cancel_async_response(resp)
    end
  end

  defp drain_until_snapshot(resp, buf, target_seq, acc) do
    {:ok, ev, next_buf} = next_sse_event(resp, buf)
    acc = acc ++ [ev]

    if ev.event == "snapshot" and ev.id == Integer.to_string(target_seq) do
      {acc, next_buf}
    else
      drain_until_snapshot(resp, next_buf, target_seq, acc)
    end
  end
end
