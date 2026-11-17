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
    * `:sse_keepalive_ms` - SSE `: keepalive` interval in ms (default `15_000`)
    * `:sse_max_queue_len` - max mailbox messages before SSE snapshot reset (default `128`)
    * `:sse_max_queue_bytes` - max process memory bytes before SSE snapshot reset (default `2_097_152`)
  """

  use Plug.Router, copy_opts_to_assign: :h_opts

  plug(:security_plug)
  plug(Plug.Head)

  plug(Plug.Static,
    at: "/",
    from: {:harness, "priv/static"},
    only: ~w(index.html app.js transcript.js app.css)
  )

  plug(Plug.Static,
    at: "/assets",
    from: {:harness, "priv/static"}
  )

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:harness, "priv/static/index.html"))
  end

  get "/api/v1/models" do
    {daemon, daemon_opts} = daemon_config(conn)
    models = apply(daemon, :list_models, [daemon_opts])
    send_json(conn, 200, %{"models" => models})
  end

  get "/api/v1/sessions" do
    {daemon, daemon_opts} = daemon_config(conn)
    sessions = apply(daemon, :list_sessions, [daemon_opts])
    send_json(conn, 200, %{"sessions" => sessions})
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
    end
  end

  get "/api/v1/sessions/:sid" do
    {daemon, daemon_opts} = daemon_config(conn)

    case apply(daemon, :get_session_detail, [sid, daemon_opts]) do
      {:ok, detail_map} ->
        send_json(conn, 200, detail_map)

      {:error, :not_found} ->
        send_json(conn, 404, %{"error" => "session not found"})

      {:error, {:quarantined, reason}} ->
        send_json(conn, 503, %{
          "error" => "session quarantined",
          "reason" => normalize_reason(reason)
        })
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

  defp normalize_reason(reason)
       when is_binary(reason) or is_atom(reason) or is_number(reason) or is_map(reason) or
              is_list(reason),
       do: reason

  defp normalize_reason(reason), do: inspect(reason)

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(payload))
  end
end
