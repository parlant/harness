defmodule H.HTTP.SecurityPlug do
  @moduledoc """
  HTTP security boundary:

    * Rejects DNS rebinding via strict `Host` allowlist (`421`).
    * Handles `POST /api/v1/auth/session` owner-token to `HttpOnly; SameSite=Strict` cookie exchange.
    * Enforces `Bearer` token or cookie + `Origin` + `application/json` auth on `/api/v1/*`.
    * Parses bounded JSON bodies (`4_000_000` bytes) via `Plug.Parsers`.
  """

  @behaviour Plug

  import Plug.Conn

  @mutating_methods ~w(POST PUT PATCH DELETE)
  @json_parser Plug.Parsers.init(
                 parsers: [:json],
                 pass: ["application/json"],
                 json_decoder: JSON,
                 length: 4_000_000
               )

  @impl true
  def init(opts) when is_list(opts), do: opts

  @impl true
  def call(conn, opts) do
    unix_socket? = unix_socket_conn?(conn, opts)
    port = effective_port(conn, opts)

    with :ok <- check_host(conn, port, opts, unix_socket?) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> enforce_route_security(opts, port)
    else
      {:error, status, msg} -> send_json_halt(conn, status, %{"error" => msg})
    end
  end

  @doc """
  Returns `true` when the request arrived over a local Unix domain socket
  (or `:unix_socket` is explicitly set in `opts`).
  """
  @spec unix_socket_conn?(Plug.Conn.t(), keyword()) :: boolean()
  def unix_socket_conn?(conn, opts \\ []) when is_list(opts) do
    Keyword.get(opts, :unix_socket, false) == true or
      match?({:local, _}, conn.remote_ip) or
      conn.remote_ip == :unspec or
      match?({:unspec, _}, conn.remote_ip) or
      match?({:undefined, _}, conn.remote_ip)
  end

  defp effective_port(conn, opts) do
    case {opts[:port], opts[:bind_address]} do
      {p, _} when is_integer(p) and p > 0 -> p
      {0, ip} when not is_nil(ip) -> get_sock_data(conn).port
      _ -> conn.port
    end
  end

  defp check_host(conn, _port, _opts, true) do
    case get_req_header(conn, "host") do
      [host] when is_binary(host) ->
        if String.trim(host) != "" do
          :ok
        else
          {:error, 421, "invalid host header"}
        end

      _ ->
        {:error, 421, "invalid host header"}
    end
  end

  defp check_host(conn, port, opts, false) do
    case get_req_header(conn, "host") do
      [host] ->
        if H.Auth.allowed_host?(host, port, opts) do
          :ok
        else
          {:error, 421, "invalid host header"}
        end

      _ ->
        {:error, 421, "invalid host header"}
    end
  end

  defp enforce_route_security(
         %Plug.Conn{method: "POST", path_info: ["api", "v1", "auth", "session"]} = conn,
         opts,
         port
       ) do
    auth_server = Keyword.get(opts, :auth_server, H.Auth)
    auth_table = Keyword.get(opts, :auth_table, :h_auth)

    with :ok <- check_optional_origin(conn, port, opts),
         :ok <- require_json_content_type(conn),
         {:ok, conn} <- parse_json_body(conn) do
      case H.Auth.create_browser_session(conn.body_params["token"], auth_server, auth_table) do
        {:ok, cookie} ->
          conn
          |> put_resp_cookie("h_owner", cookie,
            http_only: true,
            same_site: "Strict",
            path: "/api"
          )
          |> send_json_halt(200, %{"ok" => true})

        {:error, :unauthorized} ->
          send_json_halt(conn, 401, %{"error" => "invalid token"})
      end
    else
      {:error, status, msg} -> send_json_halt(conn, status, %{"error" => msg})
    end
  end

  defp enforce_route_security(
         %Plug.Conn{path_info: ["api", "v1" | _]} = conn,
         opts,
         port
       ) do
    auth_table = Keyword.get(opts, :auth_table, :h_auth)

    if bearer_authorized?(conn, auth_table) do
      enforce_bearer_body(conn)
    else
      enforce_cookie_auth(conn, auth_table, port, opts)
    end
  end

  defp enforce_route_security(conn, _opts, _port), do: conn

  defp enforce_bearer_body(%Plug.Conn{method: method} = conn) when method in @mutating_methods do
    case get_req_header(conn, "content-type") do
      [ct | _] ->
        if json_media_type?(ct) do
          parse_or_halt(conn)
        else
          send_json_halt(conn, 415, %{"error" => "expected application/json"})
        end

      [] ->
        enforce_no_body_without_json_ct(conn)
    end
  end

  defp enforce_bearer_body(conn), do: conn

  defp enforce_no_body_without_json_ct(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case read_body(conn, length: 1) do
      {:ok, "", conn} -> %{conn | body_params: %{}}
      _ -> send_json_halt(conn, 415, %{"error" => "expected application/json"})
    end
  end

  defp enforce_no_body_without_json_ct(conn) do
    has_raw_body? =
      case conn.adapter do
        {_, %{raw_body: raw}} when is_binary(raw) and byte_size(raw) > 0 -> true
        _ -> false
      end

    if has_raw_body? or conn.body_params != %{} or
         match?([len | _] when len not in ["", "0"], get_req_header(conn, "content-length")) do
      send_json_halt(conn, 415, %{"error" => "expected application/json"})
    else
      conn
    end
  end

  defp enforce_cookie_auth(conn, auth_table, port, opts) do
    conn = fetch_cookies(conn)
    cookie = conn.req_cookies["h_owner"]

    cond do
      not H.Auth.verify_cookie(cookie, auth_table) ->
        send_json_halt(conn, 401, %{"error" => "unauthorized"})

      conn.method in ["GET", "HEAD"] ->
        conn

      conn.method in @mutating_methods ->
        with :ok <- require_allowed_origin(conn, port, opts),
             :ok <- require_json_content_type(conn),
             {:ok, conn} <- parse_json_body(conn) do
          conn
        else
          {:error, status, msg} -> send_json_halt(conn, status, %{"error" => msg})
        end

      true ->
        send_json_halt(conn, 403, %{"error" => "forbidden origin"})
    end
  end

  defp bearer_authorized?(conn, auth_table) do
    case get_req_header(conn, "authorization") do
      [header] ->
        case String.split(header, " ", parts: 2) do
          [scheme, token] when byte_size(token) > 0 ->
            String.downcase(scheme) == "bearer" and H.Auth.verify_bearer(token, auth_table)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp check_optional_origin(conn, port, opts) do
    case get_req_header(conn, "origin") do
      [] -> :ok
      [origin] -> validate_origin(origin, port, opts)
      _ -> {:error, 403, "forbidden origin"}
    end
  end

  defp require_allowed_origin(conn, port, opts) do
    case get_req_header(conn, "origin") do
      [origin] -> validate_origin(origin, port, opts)
      _ -> {:error, 403, "forbidden origin"}
    end
  end

  defp validate_origin(origin, port, opts) do
    if H.Auth.allowed_origin?(origin, port, opts) do
      :ok
    else
      {:error, 403, "forbidden origin"}
    end
  end

  defp require_json_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [ct | _] ->
        if json_media_type?(ct) do
          :ok
        else
          {:error, 415, "expected application/json"}
        end

      [] ->
        {:error, 415, "expected application/json"}
    end
  end

  defp json_media_type?(ct) when is_binary(ct) do
    case Plug.Conn.Utils.content_type(ct) do
      {:ok, "application", "json", _params} -> true
      _ -> false
    end
  end

  defp parse_or_halt(conn) do
    case parse_json_body(conn) do
      {:ok, conn} -> conn
      {:error, status, msg} -> send_json_halt(conn, status, %{"error" => msg})
    end
  end

  defp parse_json_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    try do
      {:ok, Plug.Parsers.call(conn, @json_parser)}
    rescue
      Plug.Parsers.RequestTooLargeError ->
        {:error, 413, "request too large"}

      Plug.Parsers.ParseError ->
        {:error, 400, "invalid json"}

      Plug.Parsers.BadEncodingError ->
        {:error, 400, "invalid utf-8 encoding"}

      Plug.Parsers.UnsupportedMediaTypeError ->
        {:error, 415, "expected application/json"}

      Plug.BadRequestError ->
        {:error, 400, "bad request"}

      Plug.TimeoutError ->
        {:error, 408, "request timeout"}
    end
  end

  defp parse_json_body(conn), do: {:ok, conn}

  defp send_json_halt(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode_to_iodata!(payload))
    |> halt()
  end
end
