defmodule HWeb.Endpoint do
  @moduledoc """
  Phoenix Endpoint for `:harness_web`.

  Binds loopback by default (`127.0.0.1`), enforces encrypted `HttpOnly`
  `SameSite=Strict` session cookies, LiveView CSRF/origin checks, and strict
  security response headers.
  """
  use Phoenix.Endpoint, otp_app: :harness_web

  @session_options [
    store: :cookie,
    key: "_harness_web_key",
    signing_salt: "hweb_sess_sign_8a1d",
    encryption_salt: "hweb_sess_enc_4c7e",
    http_only: true,
    same_site: "Strict"
  ]

  # Monaco positions lines with style attributes; stylesheet elements still require the nonce.
  @csp "default-src 'self'; connect-src 'self' ws: wss:; img-src 'self' data:; script-src 'self'; worker-src 'self'; style-src-attr 'unsafe-inline'; base-uri 'self'; frame-ancestors 'none'"

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.Static,
    at: "/assets",
    from: :harness_web,
    gzip: false,
    only: ~w(app.css app.js inspector.js workbench.js review.js monaco favicon.ico)
  )

  plug(Plug.Static,
    at: "/assets/vendor",
    from: {:phoenix, "priv/static"},
    gzip: false,
    only: ~w(phoenix.min.js)
  )

  plug(Plug.Static,
    at: "/assets/vendor",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false,
    only: ~w(phoenix_live_view.min.js)
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(:security_headers)
  plug(Plug.RequestId)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(HWeb.Router)

  defp security_headers(conn, _opts) do
    nonce = Base.encode64(:crypto.strong_rand_bytes(18))

    conn
    |> Plug.Conn.assign(:style_nonce, nonce)
    |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
    |> Plug.Conn.put_resp_header("x-frame-options", "DENY")
    |> Plug.Conn.put_resp_header("referrer-policy", "same-origin")
    |> Plug.Conn.put_resp_header(
      "content-security-policy",
      # Monaco positions lines with style attributes; stylesheet elements still require the nonce.
      @csp <> "; style-src 'self' 'nonce-#{nonce}'"
    )
  end
end
