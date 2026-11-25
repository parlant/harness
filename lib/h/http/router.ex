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

  get "/api/v1/extensions" do
    {_daemon, opts} = daemon_config(conn)

    case H.Daemon.Maintenance.extensions_status(opts) do
      {:ok, payload} ->
        send_json(conn, 200, payload)

      {:error, _} ->
        send_json(conn, 503, %{"error" => "daemon unavailable"})
    end
  end

  get "/api/v1/harnesses" do
    {daemon, daemon_opts} = daemon_config(conn)
    harnesses = apply(daemon, :list_harnesses, [daemon_opts])
    send_json(conn, 200, %{"harnesses" => harnesses})
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

  post "/api/v1/provider-keys/remove" do
    {_daemon, opts} = daemon_config(conn)

    result =
      H.Daemon.Maintenance.admit(opts, fn ->
        H.Accounts.remove_api_key(opts[:accounts], conn.body_params)
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

  post "/api/v1/provider-accounts/remove" do
    {_daemon, opts} = daemon_config(conn)

    result =
      H.Daemon.Maintenance.admit(opts, fn ->
        H.Accounts.remove(opts[:accounts], conn.body_params)
      end)

    send_login(conn, result)
  end

  get "/api/v1/provider-catalog" do
    {_daemon, opts} = daemon_config(conn)

    case H.Accounts.provider_catalog(opts[:accounts]) do
      {:ok, catalog} ->
        running = opts |> Keyword.get(:compatible_providers, %{}) |> Map.keys() |> Enum.sort()
        send_login(conn, {:ok, Map.put(catalog, :running, running)})

      error ->
        send_login(conn, error)
    end
  end

  post "/api/v1/provider-catalog" do
    {_daemon, opts} = daemon_config(conn)

    result =
      H.Daemon.Maintenance.admit(opts, fn ->
        case H.Accounts.stage_provider(opts[:accounts], conn.body_params) do
          :ok -> {:ok, %{"ok" => true}}
          other -> other
        end
      end)

    send_login(conn, result)
  end

  post "/api/v1/workspaces/review" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :open_workspace_review, [conn.body_params, daemon_opts]) do
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

  get "/api/v1/sessions/:sid/tree" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :get_session_tree, [sid, daemon_opts]) do
      {:ok, tree_map} ->
        send_json(conn, 200, tree_map)

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

  get "/api/v1/sessions/:sid/review" do
    conn = fetch_query_params(conn)
    {daemon, daemon_opts} = daemon_config(conn)

    with {:ok, review_params} <- parse_review_query(conn.query_params),
         {:ok, payload} <- apply(daemon, :review_workspace, [sid, review_params, daemon_opts]) do
      send_json(conn, 200, wire_review_browse(payload))
    else
      {:error, reason} -> send_review_error(conn, reason)
    end
  end

  get "/api/v1/sessions/:sid/review/file" do
    conn = fetch_query_params(conn)
    {daemon, daemon_opts} = daemon_config(conn)
    path = conn.query_params["path"]
    source = Map.get(conn.query_params, "source", "working")

    if is_binary(path) and path != "" and is_binary(source) and source != "" do
      case apply(daemon, :read_review_file, [sid, path, source, daemon_opts]) do
        {:ok, file} -> send_json(conn, 200, wire_review_file(file))
        {:error, reason} -> send_review_error(conn, reason)
      end
    else
      send_review_error(conn, :invalid_path)
    end
  end

  post "/api/v1/sessions/:sid/review/file" do
    {daemon, daemon_opts} = daemon_config(conn)
    body = if is_map(conn.body_params), do: conn.body_params, else: %{}

    with path when is_binary(path) <- Map.get(body, "path"),
         revision when is_binary(revision) <- Map.get(body, "revision"),
         text when is_binary(text) <- Map.get(body, "text") do
      case apply(daemon, :save_review_file, [sid, path, revision, text, daemon_opts]) do
        {:ok, new_rev} -> send_json(conn, 200, %{"revision" => new_rev})
        {:error, reason} -> send_review_error(conn, reason)
      end
    else
      _ -> send_review_error(conn, :invalid_edit)
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

  get "/api/v1/sessions/:sid/conversations/:cid/extension-status" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :extension_status, [sid, cid, daemon_opts]) do
      {:ok, payload} ->
        send_json(conn, 200, payload)

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

  post "/api/v1/sessions/:sid/signals" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :deliver_signal, [sid, conn.body_params, daemon_opts]) do
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
    daemon = Keyword.get(opts, :daemon, H.Daemon)

    daemon_opts =
      if Keyword.get(opts, :use_live_instance_options, false) do
        live_instance_options() || Keyword.get(opts, :daemon_opts, [])
      else
        Keyword.get(opts, :daemon_opts, [])
      end

    {daemon, daemon_opts}
  end

  defp live_instance_options do
    H.Daemon.instance_options()
  catch
    :exit, _ -> nil
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

  defp parse_review_query(params) when is_map(params) do
    cond do
      Map.has_key?(params, "history") ->
        case parse_review_page(params["history"]) do
          {:ok, page} -> {:ok, %{history: page}}
          :error -> {:error, :invalid_path}
        end

      Map.has_key?(params, "commit") and not Map.has_key?(params, "dir") and
          not Map.has_key?(params, "page") ->
        commit = params["commit"]

        if is_binary(commit) do
          {:ok, %{commit: commit}}
        else
          {:error, :invalid_commit}
        end

      true ->
        dir = Map.get(params, "dir", "")
        changes? = Map.get(params, "changes") in ["true", "1"]

        with true <- is_binary(dir) || {:error, :invalid_path},
             {:ok, page} <- parse_review_page(Map.get(params, "page", "0")) do
          base = %{dir: dir, page: page}

          case Map.fetch(params, "commit") do
            {:ok, commit} when is_binary(commit) -> {:ok, Map.put(base, :commit, commit)}
            {:ok, _} -> {:error, :invalid_commit}
            :error -> {:ok, Map.put(base, :changes?, changes?)}
          end
        else
          :error -> {:error, :invalid_path}
          {:error, _} = err -> err
        end
    end
  end

  defp parse_review_page(page) when is_integer(page) and page in 0..100_000, do: {:ok, page}

  defp parse_review_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n in 0..100_000 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_review_page(_), do: :error

  defp wire_review_browse(payload) when is_map(payload) do
    Map.new(payload, fn
      {:git, :not_git} -> {"git", "not_git"}
      {:git, :git_unavailable} -> {"git", "git_unavailable"}
      {:git, :parent_unavailable} -> {"git", "parent_unavailable"}
      {k, v} -> {Atom.to_string(k), v}
    end)
  end

  defp wire_review_file(%{kind: :text, preview: preview} = file) do
    wired_preview =
      case preview do
        {mode, mime} -> %{"mode" => Atom.to_string(mode), "mime" => mime}
        nil -> nil
      end

    %{
      "kind" => "text",
      "text" => file.text,
      "revision" => file.revision,
      "preview" => wired_preview,
      "archived" => file.archived
    }
  end

  defp wire_review_file(%{kind: :media} = file) do
    %{
      "kind" => "media",
      "mode" => Atom.to_string(file.mode),
      "mime" => file.mime,
      "bytes" => Base.encode64(file.bytes),
      "revision" => file.revision,
      "archived" => file.archived
    }
  end

  defp send_review_error(conn, :not_found),
    do: send_json(conn, 404, %{"error" => "session not found", "code" => "not_found"})

  defp send_review_error(conn, reason) when reason in [:enoent, :not_in_head, :not_in_commit],
    do:
      send_json(conn, 404, %{"error" => Atom.to_string(reason), "code" => Atom.to_string(reason)})

  defp send_review_error(conn, reason)
       when reason in [:file_changed, :workspace_busy, :read_only],
       do:
         send_json(conn, 409, %{
           "error" => Atom.to_string(reason),
           "code" => Atom.to_string(reason)
         })

  defp send_review_error(conn, :symlink_not_followed),
    do:
      send_json(conn, 403, %{"error" => "symlink_not_followed", "code" => "symlink_not_followed"})

  defp send_review_error(conn, reason)
       when reason in [
              :invalid_path,
              :invalid_commit,
              :commit_unavailable,
              :tree_too_large,
              :file_too_large,
              :unsupported_binary,
              :not_text,
              :invalid_edit
            ],
       do:
         send_json(conn, 422, %{
           "error" => Atom.to_string(reason),
           "code" => Atom.to_string(reason)
         })

  defp send_review_error(conn, {:quarantined, _} = reason),
    do: send_session_error(conn, reason)

  defp send_review_error(conn, reason)
       when reason in [:daemon_draining, :workspace_unavailable, :harness_unavailable],
       do: send_session_error(conn, reason)

  defp send_review_error(conn, :git_unavailable),
    do: send_json(conn, 503, %{"error" => "git_unavailable", "code" => "git_unavailable"})

  defp send_review_error(conn, _reason),
    do: send_json(conn, 503, %{"error" => "review_unavailable", "code" => "review_unavailable"})

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(payload))
  end
end
