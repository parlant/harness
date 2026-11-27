defmodule HWeb.AuthAndSecurityTest do
  use HWeb.ConnCase, async: false

  describe "owner authentication and CSRF/origin protections" do
    test "redirects unauthenticated browsing and LiveView mounts to /login", %{conn: conn} do
      for path <- [
            "/",
            "/workspaces",
            "/inbox",
            "/sessions/demo",
            "/sessions/demo/review",
            "/sessions/demo/conversations/1"
          ] do
        resp_conn = get(conn, path)
        assert redirected_to(resp_conn) == "/login"

        assert {:error, {:redirect, %{to: "/login"}}} = live(conn, path)
      end
    end

    test "fails closed when H.Auth ETS table is missing" do
      prev = Application.get_env(:harness_web, :daemon_opts)

      Application.put_env(:harness_web, :daemon_opts,
        auth_server: :nonexistent_auth_server,
        auth_table: :nonexistent_auth_table
      )

      try do
        refute HWeb.Auth.verify_session_token("anything-when-down")
        assert {:error, :auth_unavailable} = HWeb.Auth.create_browser_session("token")
      after
        Application.put_env(:harness_web, :daemon_opts, prev)
      end
    end

    test "rejects POST /login without valid CSRF token", %{conn: conn, owner_token: owner_token} do
      csrf_enforced_conn = Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        post(csrf_enforced_conn, "/login", %{"token" => owner_token})
      end
    end

    test "rejects invalid owner token and accepts valid owner token with HttpOnly cookie", %{
      conn: conn,
      owner_token: owner_token
    } do
      login_conn = get(conn, "/login")
      assert html_response(login_conn, 200) =~ "Owner Sign In"
      [_, csrf] = Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, login_conn.resp_body)

      bad_conn = post(login_conn, "/login", %{"_csrf_token" => csrf, "token" => "wrong-token"})
      assert html_response(bad_conn, 401) =~ "Invalid owner token"

      ok_conn = post(login_conn, "/login", %{"_csrf_token" => csrf, "token" => owner_token})
      assert redirected_to(ok_conn) == "/"

      cookie_opts = ok_conn.resp_cookies["_harness_web_key"]
      assert cookie_opts.http_only == true
      assert cookie_opts.same_site == "Strict"

      authed_conn = get(recycle(ok_conn), "/")
      assert html_response(authed_conn, 200) =~ "Workspace Browser"
    end

    test "GET /login/link redeems a single-use sign-in code, sets session cookie, and redirects",
         %{
           conn: conn,
           owner_token: owner_token
         } do
      daemon_opts = HWeb.Backend.InVM.daemon_opts()
      server = Keyword.get(daemon_opts, :auth_server, H.Auth)
      table = Keyword.get(daemon_opts, :auth_table, :h_auth)

      assert {:ok, code} = H.Auth.create_sign_in_code(owner_token, server, table)

      link_conn = get(conn, "/login/link?code=#{URI.encode_www_form(code)}&next=%2Fworkspaces")
      assert redirected_to(link_conn) == "/workspaces"
      assert Plug.Conn.get_resp_header(link_conn, "cache-control") == ["no-store"]

      cookie_opts = link_conn.resp_cookies["_harness_web_key"]
      assert cookie_opts.http_only == true
      assert cookie_opts.same_site == "Strict"

      authed_conn = get(recycle(link_conn), "/workspaces")
      assert html_response(authed_conn, 200) =~ "Workspace Browser"

      # Replaying the consumed code without a session fails closed with 401.
      replay_conn = get(build_conn(), "/login/link?code=#{URI.encode_www_form(code)}")
      assert html_response(replay_conn, 401) =~ "Sign-in link is invalid or expired"

      # Re-opening a consumed link in an already signed-in browser still redirects cleanly.
      reopen_conn =
        get(recycle(link_conn), "/login/link?code=#{URI.encode_www_form(code)}&next=%2Finbox")

      assert redirected_to(reopen_conn) == "/inbox"
    end

    test "GET /login/link rejects external or protocol-relative redirect targets", %{
      conn: conn,
      owner_token: owner_token
    } do
      daemon_opts = HWeb.Backend.InVM.daemon_opts()
      server = Keyword.get(daemon_opts, :auth_server, H.Auth)
      table = Keyword.get(daemon_opts, :auth_table, :h_auth)

      for bad_next <- ["https://evil.example", "//evil.example/path", "/\\evil.example"] do
        assert {:ok, code} = H.Auth.create_sign_in_code(owner_token, server, table)

        resp_conn =
          get(
            conn,
            "/login/link?code=#{URI.encode_www_form(code)}&next=#{URI.encode_www_form(bad_next)}"
          )

        assert redirected_to(resp_conn) == "/"
      end
    end

    test "endpoint binds loopback only and check_origin rejects non-loopback websocket upgrades" do
      http_conf = HWeb.Endpoint.config(:http)
      assert Keyword.get(http_conf, :ip) == {127, 0, 0, 1}

      check_origin = HWeb.Endpoint.config(:check_origin)
      assert is_list(check_origin)
      assert "//127.0.0.1" in check_origin
      assert "//localhost" in check_origin
      assert "//[::1]" in check_origin

      evil_conn =
        build_conn(:get, "/live/websocket")
        |> put_req_header("origin", "https://evil.example")

      rejected =
        Phoenix.Socket.Transport.check_origin(
          evil_conn,
          Phoenix.LiveView.Socket,
          HWeb.Endpoint,
          []
        )

      assert rejected.halted == true
      assert rejected.status == 403

      ok_conn =
        build_conn(:get, "/live/websocket")
        |> put_req_header("origin", "http://127.0.0.1:4002")

      allowed =
        Phoenix.Socket.Transport.check_origin(
          ok_conn,
          Phoenix.LiveView.Socket,
          HWeb.Endpoint,
          []
        )

      assert allowed.halted == false
    end
  end
end
