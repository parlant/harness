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

  get "/api/v1/daemon/status" do
    {_daemon, opts} = daemon_config(conn)

    case H.Daemon.Maintenance.status(opts) do
      {:ok, payload} ->
        send_json(conn, 200, payload)

      {:error, _} ->
        send_json(conn, 503, %{"error" => "daemon unavailable"})
    end
  end

  post "/api/v1/daemon/shutdown" do
    {_daemon, opts} = daemon_config(conn)
    body = if is_map(conn.body_params), do: conn.body_params, else: %{}

    case Map.get(body, "mode") do
      mode when mode in [nil, "idle"] ->
        case H.Daemon.Maintenance.stop_if_idle(opts) do
          {:ok, payload} ->
            try do
              send_json(conn, 202, payload)
            after
              send(opts[:shutdown_owner], :shutdown_when_idle)
            end

          {:error, reason} when reason in [:daemon_busy, :shutdown_not_supported] ->
            send_json(conn, 409, %{"error" => Atom.to_string(reason)})

          {:error, _} ->
            send_json(conn, 503, %{"error" => "daemon unavailable"})
        end

      "drain" ->
        case H.Daemon.Maintenance.drain_and_stop(opts) do
          {:ok, payload} ->
            send_json(conn, 202, payload)

          {:error, :shutdown_not_supported} ->
            send_json(conn, 409, %{"error" => "shutdown_not_supported"})

          {:error, _} ->
            send_json(conn, 503, %{"error" => "daemon unavailable"})
        end

      _other ->
        send_json(conn, 422, %{"error" => "invalid_shutdown_mode"})
    end
  end

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

  get "/api/v1/provider-keys" do
    {_daemon, opts} = daemon_config(conn)
    send_login(conn, H.Accounts.api_keys(opts[:accounts]))
  end

  post "/api/v1/provider-keys/set" do
    {_daemon, opts} = daemon_config(conn)

    result =
      H.Daemon.Maintenance.admit(opts, fn ->
        H.Accounts.put_api_key(opts[:accounts], conn.body_params)
      end)

    send_login(conn, result)
  end

  post "/api/v1/provider-keys/use" do
    {_daemon, opts} = daemon_config(conn)

    result =
      H.Daemon.Maintenance.admit(opts, fn ->
        H.Accounts.use_api_key(opts[:accounts], conn.body_params)
      end)

    send_login(conn, result)
  end

  get "/api/v1/provider-logins" do
    {_daemon, opts} = daemon_config(conn)
    send_login(conn, H.Accounts.discover(opts[:accounts], opts[:codex_account_policy]))
  end

  post "/api/v1/provider-logins/start" do
    {_daemon, opts} = daemon_config(conn)

    result =
      H.Daemon.Maintenance.admit(opts, fn ->
        H.Accounts.start(opts[:accounts], conn.body_params)
      end)

    send_login(conn, result)
  end

  post "/api/v1/provider-logins/status" do
    {_daemon, opts} = daemon_config(conn)
    send_login(conn, H.Accounts.operation(opts[:accounts], :status, conn.body_params))
  end

  post "/api/v1/provider-logins/cancel" do
    {_daemon, opts} = daemon_config(conn)
    send_login(conn, H.Accounts.operation(opts[:accounts], :cancel, conn.body_params))
  end

  post "/api/v1/provider-accounts/add" do
    {_daemon, opts} = daemon_config(conn)

    result =
      H.Daemon.Maintenance.admit(opts, fn -> H.Accounts.add(opts[:accounts], conn.body_params) end)

    send_login(conn, result)
  end

  post "/api/v1/provider-accounts/activate" do
    {_daemon, opts} = daemon_config(conn)

    result =
      H.Daemon.Maintenance.admit(opts, fn ->
        H.Accounts.activate(opts[:accounts], conn.body_params)
      end)

    send_login(conn, result)
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

  get "/api/v1/archives" do
    {_daemon, opts} = daemon_config(conn)

    archives =
      (opts[:catalog_table] || :h_catalog)
      |> H.Catalog.list_sessions()
      |> Enum.flat_map(fn entry ->
        if entry.archive, do: [Map.put(entry.archive, :session_id, entry.session_id)], else: []
      end)

    send_json(conn, 200, %{archives: archives})
  end

  post "/api/v1/archives" do
    {_daemon, opts} = daemon_config(conn)

    case H.HTTP.Archive.upload(conn, opts) do
      {:ok, receipt, conn} ->
        send_json(conn, 200, receipt)

      {:error, {:bad_request, reason}} ->
        send_json(conn, 422, %{error: reason})

      {:error, {:conflict, reason}} ->
        send_json(conn, 409, %{error: reason})

      {:error, :archive_too_large} ->
        send_json(conn, 413, %{error: "archive upload exceeds limits"})

      {:error, reason} ->
        send_session_error(conn, reason)
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

  get "/api/v1/sessions/events" do
    H.HTTP.SSE.stream_sessions(conn, router_opts(conn))
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

  get "/api/v1/sessions/:sid/submissions/:request_id" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :get_submission, [sid, request_id, daemon_opts]) do
      {:ok, outcome} ->
        send_json(conn, 200, H.Daemon.wire_submission_outcome(outcome))

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "not found"})

      {:error, {:bad_request, msg}} ->
        send_json(conn, 422, %{"error" => msg})

      {:error, reason} ->
        send_session_error(conn, reason)
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

  post "/api/v1/sessions/:sid/triage" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :triage_session, [sid, conn.body_params, daemon_opts]) do
      {:ok, %{session: session}} ->
        send_json(conn, 200, %{"session" => session})

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "session not found"})

      {:error, {:bad_request, msg}} ->
        send_json(conn, 422, %{"error" => msg})

      {:error, {:conflict, msg}} ->
        send_json(conn, 409, %{"error" => msg})

      {:error, reason} ->
        send_session_error(conn, reason)
    end
  end

  post "/api/v1/sessions/:sid/stop" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :stop_session, [sid, conn.body_params, daemon_opts]) do
      {:ok, %{session: session}} ->
        send_json(conn, 200, %{"session" => session})

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "session not found"})

      {:error, {:bad_request, msg}} ->
        send_json(conn, 422, %{"error" => msg})

      {:error, {:conflict, msg}} ->
        send_json(conn, 409, %{"error" => msg})

      {:error, reason} ->
        send_session_error(conn, reason)
    end
  end

  post "/api/v1/sessions/:sid/archive" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :archive_session, [sid, conn.body_params, daemon_opts]) do
      {:ok, %{session: session}} ->
        send_json(conn, 200, %{"session" => session})

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "session not found"})

      {:error, {:bad_request, msg}} ->
        send_json(conn, 422, %{"error" => msg})

      {:error, {:conflict, msg}} ->
        send_json(conn, 409, %{"error" => msg})

      {:error, reason} ->
        send_session_error(conn, reason)
    end
  end

  post "/api/v1/sessions/:sid/fork" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :fork_session, [sid, conn.body_params, daemon_opts]) do
      {:ok, %{session: session, seq: seq}} ->
        send_json(conn, 200, %{"session" => session, "seq" => seq})

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

  defp send_login(conn, result) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case result do
      {:ok, payload} ->
        send_json(conn, 200, payload)

      {:error, reason} ->
        status =
          case reason do
            reason when reason in [:login_unavailable, :login_not_found] ->
              404

            reason when reason in [:login_busy, :login_request_conflict] ->
              409

            :login_rate_limited ->
              429

            reason
            when reason in [:accounts_unavailable, :account_config_unavailable, :daemon_draining] ->
              503

            _ ->
              422
          end

        send_json(conn, status, %{"error" => Atom.to_string(reason)})
    end
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

  defp send_session_error(conn, :daemon_draining),
    do: send_json(conn, 503, %{"error" => "daemon is shutting down; retry after restart"})

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
