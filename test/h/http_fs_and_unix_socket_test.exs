defmodule H.HTTP.FsAndUnixSocketTest do
  use ExUnit.Case, async: true

  alias H.Auth
  alias H.HTTP.{Router, SecurityPlug}

  defmodule FakeEnvDaemon do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    def list_environments(_opts) do
      [
        %{
          "id" => "host",
          "kind" => "host",
          "label" => "Local Host",
          "default_cwd" => "/tmp/work"
        }
      ]
    end

    def browse_workspace(%{"env_id" => "unknown"}, _opts), do: {:error, :unknown_environment}
    def browse_workspace(%{"path" => "/missing"}, _opts), do: {:error, :not_found}

    def browse_workspace(%{"include_hidden" => "invalid"}, _opts),
      do: {:error, {:bad_request, "invalid include_hidden"}}

    def browse_workspace(params, _opts) do
      {:ok,
       %{
         "env_id" => params["env_id"] || "host",
         "path" => params["path"] || "/tmp/work",
         "parent" => "/tmp",
         "entries" => [
           %{"name" => "proj", "path" => "/tmp/work/proj", "markers" => [".git", "mix.exs"]}
         ],
         "sessions" => []
       }}
    end

    def list_sessions(_opts) do
      [%{"session_id" => "all-1", "env_id" => "host", "cwd" => "/tmp/other"}]
    end

    def list_sessions(%{"limit" => "bad"}, _opts),
      do: {:error, {:bad_request, "invalid limit"}}

    def list_sessions(%{"env_id" => env_id, "cwd" => cwd}, _opts) do
      {:ok, [%{"session_id" => "filtered-1", "env_id" => env_id, "cwd" => cwd}]}
    end

    def list_sessions(%{"bare" => "true"}, _opts) do
      [%{"session_id" => "bare-1", "env_id" => "host", "cwd" => "/tmp/bare"}]
    end

    def subscribe_conversation(sid, cid, pid, _last_event_id, opts) do
      server = Keyword.fetch!(opts, :server)
      GenServer.call(server, {:subscribe, sid, cid, pid})
    end

    def emit_commit(server, sid, cid, data_map) do
      GenServer.call(server, {:emit_commit, sid, cid, data_map})
    end

    @impl true
    def init(_opts) do
      {:ok, %{seq: 1, subscribers: %{}, monitors: %{}}}
    end

    @impl true
    def handle_call({:subscribe, sid, cid, pid}, _from, state) do
      key = {sid, cid}
      subs = Map.get(state.subscribers, key, MapSet.new())

      {subs, monitors} =
        if MapSet.member?(subs, pid) do
          {subs, state.monitors}
        else
          ref = Process.monitor(pid)
          {MapSet.put(subs, pid), Map.put(state.monitors, ref, {key, pid})}
        end

      snap =
        JSON.encode!(%{
          "version" => 1,
          "session_id" => sid,
          "conversation_id" => cid,
          "seq" => state.seq,
          "before_entry_id" => nil,
          "entries" => [
            %{"id" => "1", "conversation_id" => cid, "kind" => "user", "data" => %{}}
          ],
          "docs" => %{"live" => %{}, "inbox" => [], "agent" => %{}, "usage" => %{}}
        })

      {:reply, {:ok, {:snapshot, state.seq, snap}},
       %{state | subscribers: Map.put(state.subscribers, key, subs), monitors: monitors}}
    end

    def handle_call({:emit_commit, sid, cid, data_map}, _from, state) do
      seq = state.seq + 1

      bin =
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

      for pid <- Map.get(state.subscribers, {sid, cid}, MapSet.new()) do
        send(pid, {:commit_frame, seq, bin})
      end

      {:reply, {:ok, seq}, %{state | seq: seq}}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
      case Map.pop(state.monitors, ref) do
        {nil, monitors} ->
          {:noreply, %{state | monitors: monitors}}

        {{key, pid}, monitors} ->
          subs = state.subscribers |> Map.get(key, MapSet.new()) |> MapSet.delete(pid)

          {:noreply,
           %{state | subscribers: Map.put(state.subscribers, key, subs), monitors: monitors}}
      end
    end
  end

  defmodule Arity1SessionsDaemon do
    def list_sessions(_opts), do: [%{"session_id" => "legacy-1"}]
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  defp start_unix_daemon do
    id = System.unique_integer([:positive])
    tmp_dir = Path.join("/private/tmp", "h-unix-#{id}")
    File.mkdir_p!(tmp_dir)
    File.chmod!(tmp_dir, 0o700)
    socket_path = Path.join(tmp_dir, "api.sock")
    table = :"h_unix_auth_#{id}"
    auth_server = :"H.HTTP.UnixTest.Auth.#{id}"

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    start_supervised!({Auth, data_dir: tmp_dir, name: auth_server, table: table})
    daemon = start_supervised!(FakeEnvDaemon)
    token = Auth.owner_token(table)

    router_opts = [
      auth_server: auth_server,
      auth_table: table,
      daemon: FakeEnvDaemon,
      daemon_opts: [server: daemon]
    ]

    start_supervised!(
      {Bandit,
       plug: {Router, router_opts},
       ip: {:local, socket_path},
       port: 0,
       startup_log: false,
       thousand_island_options: [shutdown_timeout: 50]}
    )

    %{socket_path: socket_path, token: token, daemon: daemon, router_opts: router_opts}
  end

  defp start_tcp_daemon do
    id = System.unique_integer([:positive])
    tmp_dir = Path.join("/private/tmp", "h-tcp-#{id}")
    table = :"h_tcp_auth_#{id}"
    auth_server = :"H.HTTP.TcpTest.Auth.#{id}"

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    start_supervised!({Auth, data_dir: tmp_dir, name: auth_server, table: table})
    daemon = start_supervised!(FakeEnvDaemon)
    token = Auth.owner_token(table)

    router_opts = [
      auth_server: auth_server,
      auth_table: table,
      daemon: FakeEnvDaemon,
      daemon_opts: [server: daemon]
    ]

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
    %{base_url: "http://127.0.0.1:#{port}", port: port, token: token}
  end

  defp next_sse_event(resp, buffer \\ "", timeout \\ 2_000) do
    case :binary.split(buffer, "\n\n") do
      [raw_frame, rest] ->
        {:ok, parse_sse_frame(raw_frame), rest}

      [_incomplete] ->
        receive_sse_chunk(resp, buffer, timeout)
    end
  end

  defp receive_sse_chunk(%{body: %Req.Response.Async{ref: ref}} = resp, buffer, timeout) do
    receive do
      {^ref, _} = msg ->
        case Req.parse_message(resp, msg) do
          {:ok, [data: chunk]} -> next_sse_event(resp, buffer <> chunk, timeout)
          {:ok, [:done]} -> {:done, buffer}
          {:ok, [_other]} -> receive_sse_chunk(resp, buffer, timeout)
          {:error, reason} -> {:error, reason}
        end
    after
      timeout -> :timeout
    end
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

    data_str = parsed.data_lines |> Enum.reverse() |> Enum.join("\n")
    %{id: parsed.id, event: parsed.event, data: JSON.decode!(data_str)}
  end

  describe "SecurityPlug.unix_socket_conn?/2" do
    test "detects unix socket remote_ip shapes and explicit option" do
      tcp_conn = Plug.Test.conn(:get, "/")
      refute SecurityPlug.unix_socket_conn?(tcp_conn, [])
      assert SecurityPlug.unix_socket_conn?(tcp_conn, unix_socket: true)

      for remote_ip <- [
            {:local, ""},
            {:local, "/tmp/api.sock"},
            :unspec,
            {:unspec, <<>>},
            {:undefined, :u}
          ] do
        conn = %{tcp_conn | remote_ip: remote_ip}
        assert SecurityPlug.unix_socket_conn?(conn, [])
      end
    end
  end

  describe "Unix domain socket Bandit server" do
    test "allows single non-empty Host, enforces Bearer auth, and serves /environments, /fs, and /sessions" do
      ctx = start_unix_daemon()
      auth = [{"authorization", "Bearer #{ctx.token}"}]

      # Unauthenticated requests are rejected with 401
      unauth =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://localhost/api/v1/environments",
          retry: false
        )

      assert unauth.status == 401

      bad_auth =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://localhost/api/v1/environments",
          headers: [{"authorization", "Bearer wrong"}],
          retry: false
        )

      assert bad_auth.status == 401

      # Empty Host header still gets 421 even over Unix socket
      opts = Router.init(ctx.router_opts)

      empty_host_conn =
        Plug.Test.conn(:get, "http://localhost/api/v1/environments")
        |> Map.put(:remote_ip, {:local, ""})
        |> Map.put(:req_headers, [
          {"host", "   "},
          {"authorization", "Bearer #{ctx.token}"}
        ])
        |> Router.call(opts)

      assert empty_host_conn.status == 421

      missing_host_conn =
        Plug.Test.conn(:get, "http://localhost/api/v1/environments")
        |> Map.put(:remote_ip, {:local, ""})
        |> Map.put(:req_headers, [{"authorization", "Bearer #{ctx.token}"}])
        |> Router.call(opts)

      assert missing_host_conn.status == 421

      # GET /api/v1/environments with Host: localhost and Host: h.local
      envs =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://localhost/api/v1/environments",
          headers: auth,
          retry: false
        )

      assert envs.status == 200
      assert %{"environments" => [%{"id" => "host", "kind" => "host"}]} = envs.body

      envs_hlocal =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://h.local/api/v1/environments",
          headers: [{"host", "h.local"} | auth],
          retry: false
        )

      assert envs_hlocal.status == 200

      # GET /api/v1/fs ok & error mappings
      fs_ok =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://localhost/api/v1/fs?env_id=host&path=/tmp/work",
          headers: auth,
          retry: false
        )

      assert fs_ok.status == 200
      assert fs_ok.body["env_id"] == "host"
      assert fs_ok.body["path"] == "/tmp/work"
      assert [%{"name" => "proj", "markers" => [".git", "mix.exs"]}] = fs_ok.body["entries"]

      fs_missing =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://localhost/api/v1/fs?path=/missing",
          headers: auth,
          retry: false
        )

      assert fs_missing.status == 404
      assert fs_missing.body == %{"error" => "path not found"}

      fs_unknown_env =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://localhost/api/v1/fs?env_id=unknown",
          headers: auth,
          retry: false
        )

      assert fs_unknown_env.status == 404
      assert fs_unknown_env.body == %{"error" => "unknown environment"}

      fs_bad =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://localhost/api/v1/fs?include_hidden=invalid",
          headers: auth,
          retry: false
        )

      assert fs_bad.status == 422
      assert fs_bad.body == %{"error" => "invalid include_hidden"}

      # GET /api/v1/sessions without params and with query params
      sessions_all =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://localhost/api/v1/sessions",
          headers: auth,
          retry: false
        )

      assert sessions_all.status == 200

      assert sessions_all.body == %{
               "sessions" => [
                 %{"session_id" => "all-1", "env_id" => "host", "cwd" => "/tmp/other"}
               ]
             }

      sessions_filtered =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://localhost/api/v1/sessions?env_id=host&cwd=/tmp/app",
          headers: auth,
          retry: false
        )

      assert sessions_filtered.status == 200

      assert sessions_filtered.body == %{
               "sessions" => [
                 %{"session_id" => "filtered-1", "env_id" => "host", "cwd" => "/tmp/app"}
               ]
             }

      sessions_bare =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://localhost/api/v1/sessions?bare=true",
          headers: auth,
          retry: false
        )

      assert sessions_bare.status == 200

      assert sessions_bare.body == %{
               "sessions" => [
                 %{"session_id" => "bare-1", "env_id" => "host", "cwd" => "/tmp/bare"}
               ]
             }

      sessions_bad =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://localhost/api/v1/sessions?limit=bad",
          headers: auth,
          retry: false
        )

      assert sessions_bad.status == 422
      assert sessions_bad.body == %{"error" => "invalid limit"}
    end

    test "streams SSE events over the Unix domain socket" do
      ctx = start_unix_daemon()
      auth = [{"authorization", "Bearer #{ctx.token}"}]

      resp =
        Req.get!(
          unix_socket: ctx.socket_path,
          url: "http://localhost/api/v1/sessions/demo/conversations/1/events",
          headers: auth,
          into: :self,
          retry: false
        )

      assert resp.status == 200
      {:ok, snap, buf} = next_sse_event(resp)
      assert snap.event == "snapshot"
      assert snap.id == "1"
      assert snap.data["seq"] == 1

      {:ok, 2} = FakeEnvDaemon.emit_commit(ctx.daemon, "demo", "1", %{"text" => "via unix"})
      {:ok, commit, _buf} = next_sse_event(resp, buf)
      assert commit.event == "commit"
      assert commit.id == "2"
      assert commit.data["seq"] == 2

      Req.cancel_async_response(resp)
    end

    test "falls back to arity-1 list_sessions/1 even when query params are passed to legacy mock daemons" do
      id = System.unique_integer([:positive])
      tmp_dir = Path.join("/private/tmp", "h-legacy-#{id}")
      table = :"h_legacy_auth_#{id}"
      auth_server = :"H.HTTP.LegacyTest.Auth.#{id}"
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      start_supervised!({Auth, data_dir: tmp_dir, name: auth_server, table: table})
      token = Auth.owner_token(table)

      opts =
        Router.init(
          port: 4000,
          auth_server: auth_server,
          auth_table: table,
          daemon: Arity1SessionsDaemon,
          daemon_opts: []
        )

      conn =
        Plug.Test.conn(:get, "http://127.0.0.1:4000/api/v1/sessions?env_id=host")
        |> Map.put(:req_headers, [
          {"host", "127.0.0.1:4000"},
          {"authorization", "Bearer #{token}"}
        ])
        |> Router.call(opts)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"sessions" => [%{"session_id" => "legacy-1"}]}
    end
  end

  describe "TCP loopback Bandit host guard" do
    test "still rejects Host: evil.example with 421 on TCP loopback" do
      ctx = start_tcp_daemon()
      auth = [{"authorization", "Bearer #{ctx.token}"}]

      resp1 =
        Req.get!("#{ctx.base_url}/api/v1/environments",
          headers: [{"host", "evil.example"} | auth],
          retry: false
        )

      assert resp1.status == 421
      assert resp1.body == %{"error" => "invalid host header"}

      resp2 =
        Req.get!("#{ctx.base_url}/api/v1/environments",
          headers: [{"host", "evil.example:#{ctx.port}"} | auth],
          retry: false
        )

      assert resp2.status == 421
      assert resp2.body == %{"error" => "invalid host header"}

      ok =
        Req.get!("#{ctx.base_url}/api/v1/environments",
          headers: auth,
          retry: false
        )

      assert ok.status == 200
    end
  end
end
