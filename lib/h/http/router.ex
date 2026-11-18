defmodule H.HTTP.Router do
  @moduledoc """
  `Plug.Router` for the local `H` HTTP/JSON and SSE daemon.

  Runtime options:
    * `:port` - expected HTTP port for `Host` / `Origin` checks (defaults to `conn.port` when omitted or `0`)
    * `:auth_server` - `H.Auth` GenServer name/pid (default `H.Auth`)
    * `:auth_table` - `H.Auth` ETS table name (default `:h_auth`)
    * `:daemon` - transport-agnostic backend module (default `H.Daemon`)
    * `:daemon_opts` - keyword list forwarded to `daemon` calls (default `[]`)
    * `:allow_localhost` - allow `localhost:<port>` in `Host`/`Origin` checks (default `false`)
    * `:unix_socket` - treat connections as Unix domain socket requests (default `false`; also auto-detected via `conn.remote_ip`)
    * `:sse_keepalive_ms` - SSE `: keepalive` interval in ms (default `15_000`)
    * `:sse_max_queue_len` - max mailbox messages before SSE snapshot reset (default `128`)
    * `:sse_max_queue_bytes` - max process memory bytes before SSE snapshot reset (default `2_097_152`)
  """

  use Plug.Router, copy_opts_to_assign: :h_opts

  plug(:security_plug)
  plug(Plug.Head)

  plug(:match)
  plug(:dispatch)

  get "/api/v1/environments" do
    {daemon, daemon_opts} = daemon_config(conn)
    envs = apply(daemon, :list_environments, [daemon_opts])
    send_json(conn, 200, %{"environments" => envs})
  end

  get "/api/v1/fs" do
    conn = fetch_query_params(conn)
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :browse_workspace, [conn.query_params, daemon_opts]) do
      {:ok, payload_map} -> send_json(conn, 200, payload_map)
      {:error, reason} -> send_fs_error(conn, reason)
    end
  end

  get "/api/v1/fs/files" do
    conn = fetch_query_params(conn)
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :list_files, [conn.query_params, daemon_opts]) do
      {:ok, payload_map} -> send_json(conn, 200, payload_map)
      {:error, reason} -> send_fs_error(conn, reason)
    end
  end

  get "/api/v1/fs/file" do
    conn = fetch_query_params(conn)
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :read_file, [conn.query_params, daemon_opts]) do
      {:ok, payload_map} -> send_json(conn, 200, payload_map)
      {:error, reason} -> send_fs_error(conn, reason)
    end
  end

  get "/api/v1/models" do
    {daemon, daemon_opts} = daemon_config(conn)
    models = apply(daemon, :list_models, [daemon_opts])
    send_json(conn, 200, %{"models" => models})
  end

  get "/api/v1/sessions" do
    conn = fetch_query_params(conn)
    {daemon, daemon_opts} = daemon_config(conn)

    if conn.query_params != %{} and Code.ensure_loaded?(daemon) and
         function_exported?(daemon, :list_sessions, 2) do
      case apply(daemon, :list_sessions, [conn.query_params, daemon_opts]) do
        {:ok, sessions} ->
          send_json(conn, 200, %{"sessions" => sessions})

        sessions when is_list(sessions) ->
          send_json(conn, 200, %{"sessions" => sessions})

        {:error, {:bad_request, msg}} ->
          send_json(conn, 422, %{"error" => msg})
      end
    else
      sessions = apply(daemon, :list_sessions, [daemon_opts])
      send_json(conn, 200, %{"sessions" => sessions})
    end
  end

  post "/api/v1/sessions" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :create_session, [conn.body_params, daemon_opts]) do
      {:ok, %{session: session, seq: seq}} ->
        send_json(conn, 200, %{"session" => session, "seq" => seq})

      {:error, {:bad_request, msg}} ->
        send_json(conn, 422, %{"error" => msg})

      {:error, {:conflict, msg}} ->
        send_json(conn, 409, %{"error" => msg})

      {:error, reason} ->
        send_session_error(conn, reason)
    end
  end

  get "/api/v1/sessions/:sid" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :get_session_detail, [sid, daemon_opts]) do
      {:ok, detail_map} ->
        send_json(conn, 200, detail_map)

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "session not found"})

      {:error, reason} ->
        send_session_error(conn, reason)
    end
  end

  get "/api/v1/sessions/:sid/files" do
    conn = fetch_query_params(conn)
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :list_session_files, [sid, conn.query_params, daemon_opts]) do
      {:ok, payload_map} -> send_json(conn, 200, payload_map)
      {:error, reason} -> send_fs_error(conn, reason)
    end
  end

  get "/api/v1/sessions/:sid/file" do
    conn = fetch_query_params(conn)
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :read_session_file, [sid, conn.query_params, daemon_opts]) do
      {:ok, payload_map} -> send_json(conn, 200, payload_map)
      {:error, reason} -> send_fs_error(conn, reason)
    end
  end

  get "/api/v1/sessions/:sid/conversations/:cid/entries" do
    conn = fetch_query_params(conn)
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :scan_entries, [sid, cid, conn.query_params, daemon_opts]) do
      {:ok, %{items: items, next_cursor: next_cursor}} ->
        send_json(conn, 200, %{"items" => items, "next_cursor" => next_cursor})

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "not found"})

      {:error, {:bad_request, msg}} ->
        send_json(conn, 422, %{"error" => msg})

      {:error, reason} ->
        send_session_error(conn, reason)
    end
  end

  get "/api/v1/sessions/:sid/conversations/:cid/events" do
    H.HTTP.SSE.stream(conn, sid, cid, router_opts(conn))
  end

  post "/api/v1/sessions/:sid/commands" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :execute_command, [sid, conn.body_params, daemon_opts]) do
      {:ok, receipt_map} ->
        send_json(conn, 200, receipt_map)

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "not found"})

      {:error, {:bad_request, msg}} ->
        send_json(conn, 422, %{"error" => msg})

      {:error, {:conflict, msg}} ->
        send_json(conn, 409, %{"error" => msg})

      {:error, reason} ->
        send_session_error(conn, reason)
    end
  end

  match _ do
    send_json(conn, 404, %{"error" => "not found"})
  end

  defp security_plug(conn, _opts) do
    H.HTTP.SecurityPlug.call(conn, router_opts(conn))
  end

  defp router_opts(conn) do
    conn.assigns[:h_opts] || []
  end

  defp daemon_config(conn) do
    opts = router_opts(conn)
    {Keyword.get(opts, :daemon, H.Daemon), Keyword.get(opts, :daemon_opts, [])}
  end

  defp send_fs_error(conn, :not_found),
    do: send_json(conn, 404, %{"error" => "path not found"})

  defp send_fs_error(conn, :unknown_environment),
    do: send_json(conn, 404, %{"error" => "unknown environment"})

  defp send_fs_error(conn, {:forbidden, msg}),
    do: send_json(conn, 403, %{"error" => msg})

  defp send_fs_error(conn, {:bad_request, msg}),
    do: send_json(conn, 422, %{"error" => msg})

  defp send_fs_error(conn, reason),
    do: send_session_error(conn, reason)

  defp send_session_error(conn, {:quarantined, reason}),
    do: send_json(conn, 503, %{"error" => "session quarantined", "reason" => reason})

  defp send_session_error(conn, reason)
       when reason in [:workspace_unavailable, :harness_unavailable],
       do: send_json(conn, 503, %{"error" => Atom.to_string(reason)})

  defp send_session_error(conn, _reason),
    do: send_json(conn, 503, %{"error" => "session unavailable"})

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(payload))
  end
end
