defmodule H.HTTP.AuthTest do
  use ExUnit.Case, async: true

  alias H.Auth
  alias H.HTTP.Router

  defmodule StubDaemon do
    def list_models(_opts), do: [%{"id" => "fake-model", "provider" => "fake"}]

    def list_sessions(_opts), do: [%{"session_id" => "demo", "cwd" => "/tmp/demo"}]

    def create_session(%{"session_id" => "conflict"}, _opts),
      do: {:error, {:conflict, "request_id conflict"}}

    def create_session(%{"session_id" => sid, "cwd" => cwd}, _opts)
        when is_binary(sid) and is_binary(cwd),
        do: {:ok, %{session: %{"session_id" => sid, "cwd" => cwd}, seq: 1}}

    def create_session(_body, _opts), do: {:error, {:bad_request, "invalid session payload"}}

    def get_session_detail("missing", _opts), do: {:error, :not_found}
    def get_session_detail("broken", _opts), do: {:error, {:quarantined, "corrupt log"}}

    def get_session_detail(sid, _opts),
      do: {:ok, %{"session" => %{"session_id" => sid}, "conversations" => [%{"id" => "1"}]}}

    def scan_entries("missing", _cid, _params, _opts), do: {:error, :not_found}

    def scan_entries(_sid, _cid, %{"limit" => "bad"}, _opts),
      do: {:error, {:bad_request, "bad limit"}}

    def scan_entries(_sid, _cid, params, _opts) do
      {:ok, %{items: [%{"id" => "1", "order" => params["order"] || "desc"}], next_cursor: nil}}
    end

    def execute_command("missing", _body, _opts), do: {:error, :not_found}

    def execute_command(_sid, %{"request_id" => "dup"}, _opts),
      do: {:error, {:conflict, "payload mismatch"}}

    def execute_command(_sid, %{"command" => "submit"} = body, _opts) do
      {:ok,
       %{
         "version" => 1,
         "request_id" => body["request_id"],
         "seq" => 42,
         "submission_id" => "17",
         "status" => "queued"
       }}
    end

    def execute_command(_sid, _body, _opts), do: {:error, {:bad_request, "invalid command"}}
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  setup do
    id = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "h-http-auth-test-#{id}")
    table = :"h_http_auth_test_#{id}"
    server = :"H.HTTP.AuthTest.Auth.#{id}"

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    start_supervised!({Auth, data_dir: tmp_dir, name: server, table: table})
    token = Auth.owner_token(table)

    router_opts = [
      port: 4000,
      auth_server: server,
      auth_table: table,
      daemon: StubDaemon,
      daemon_opts: []
    ]

    req =
      Req.new(
        base_url: "http://127.0.0.1:4000",
        plug: {Router, router_opts},
        headers: [{"host", "127.0.0.1:4000"}],
        retry: false
      )

    {:ok,
     req: req, token: token, router_opts: router_opts, auth_server: server, auth_table: table}
  end

  describe "Host guard (anti-DNS-rebinding)" do
    test "rejects missing, mismatched-port, and non-loopback Host headers with 421", %{
      token: token,
      router_opts: router_opts
    } do
      base_req =
        Req.new(
          base_url: "http://127.0.0.1:4000",
          plug: {Router, router_opts},
          retry: false
        )

      for bad_headers <- [
            [],
            [{"host", "evil.example:4000"}],
            [{"host", "127.0.0.1:4001"}],
            [{"host", "localhost:4000"}]
          ] do
        resp = Req.get!(base_req, url: "/", headers: bad_headers)
        assert resp.status == 421
        assert resp.body == %{"error" => "invalid host header"}

        api_resp =
          Req.get!(base_req,
            url: "/api/v1/sessions",
            headers: [{"authorization", "Bearer #{token}"} | bad_headers]
          )

        assert api_resp.status == 421
        assert api_resp.body == %{"error" => "invalid host header"}
      end
    end

    test "accepts [::1]:<port> and gates localhost:<port> behind allow_localhost", %{
      req: req,
      token: token,
      router_opts: router_opts
    } do
      auth = {"authorization", "Bearer #{token}"}
      resp = Req.get!(req, url: "/api/v1/sessions", headers: [{"host", "[::1]:4000"}, auth])
      assert resp.status == 200

      localhost_req =
        Req.new(
          base_url: "http://localhost:4000",
          plug: {Router, Keyword.put(router_opts, :allow_localhost, true)},
          headers: [{"host", "localhost:4000"}],
          retry: false
        )

      assert Req.get!(localhost_req, url: "/api/v1/sessions", headers: [auth]).status == 200
    end
  end

  test "the standalone daemon does not serve a web UI", %{req: req} do
    for path <- ["/", "/index.html", "/app.js", "/app.css", "/transcript.js", "/assets/app.js"] do
      resp = Req.get!(req, url: path)
      assert resp.status == 404
      assert resp.body == %{"error" => "not found"}
    end
  end

  describe "POST /api/v1/auth/session" do
    test "exchanges valid owner token for HttpOnly SameSite=Strict cookie", %{
      req: req,
      token: token
    } do
      bad_origin =
        Req.post!(req,
          url: "/api/v1/auth/session",
          headers: [{"origin", "http://evil.example:4000"}],
          json: %{"token" => token}
        )

      assert bad_origin.status == 403
      assert bad_origin.body == %{"error" => "forbidden origin"}

      bad_ct =
        Req.post!(req,
          url: "/api/v1/auth/session",
          headers: [{"content-type", "text/plain"}],
          body: JSON.encode!(%{"token" => token})
        )

      assert bad_ct.status == 415
      assert bad_ct.body == %{"error" => "expected application/json"}

      bad_token =
        Req.post!(req,
          url: "/api/v1/auth/session",
          json: %{"token" => "wrong-token"}
        )

      assert bad_token.status == 401
      assert bad_token.body == %{"error" => "invalid token"}

      ok_resp =
        Req.post!(req,
          url: "/api/v1/auth/session",
          headers: [{"origin", "http://127.0.0.1:4000"}],
          json: %{"token" => token}
        )

      assert ok_resp.status == 200
      assert ok_resp.body == %{"ok" => true}

      [set_cookie] = Req.Response.get_header(ok_resp, "set-cookie")
      assert set_cookie =~ "h_owner="
      assert set_cookie =~ "HttpOnly"
      assert set_cookie =~ "SameSite=Strict"
      assert set_cookie =~ "path=/api"
    end
  end

  describe "Bearer and cookie + Origin CSRF guards on /api/v1/*" do
    test "rejects unauthenticated requests and invalid bearer tokens with 401", %{req: req} do
      assert Req.get!(req, url: "/api/v1/sessions").status == 401

      assert Req.get!(req,
               url: "/api/v1/sessions",
               headers: [{"authorization", "Bearer invalid"}]
             ).status == 401

      assert Req.post!(req,
               url: "/api/v1/sessions",
               json: %{"session_id" => "demo", "cwd" => "/tmp/demo"}
             ).status == 401
    end

    test "allows Bearer GET and POST while enforcing application/json on POST", %{
      req: req,
      token: token
    } do
      auth = [{"authorization", "Bearer #{token}"}]

      models = Req.get!(req, url: "/api/v1/models", headers: auth)
      assert models.status == 200
      assert models.body == %{"models" => [%{"id" => "fake-model", "provider" => "fake"}]}

      created =
        Req.post!(req,
          url: "/api/v1/sessions",
          headers: auth,
          json: %{"session_id" => "demo", "cwd" => "/tmp/demo"}
        )

      assert created.status == 200

      assert created.body == %{
               "session" => %{"session_id" => "demo", "cwd" => "/tmp/demo"},
               "seq" => 1
             }

      bad_ct =
        Req.post!(req,
          url: "/api/v1/sessions",
          headers: [{"content-type", "text/plain"} | auth],
          body: ~s({"session_id":"demo","cwd":"/tmp/demo"})
        )

      assert bad_ct.status == 415
      assert bad_ct.body == %{"error" => "expected application/json"}
    end

    test "cookie allows GET without Origin, requires valid Origin and application/json on POST",
         %{
           req: req,
           token: token
         } do
      auth_resp = Req.post!(req, url: "/api/v1/auth/session", json: %{"token" => token})
      [set_cookie] = Req.Response.get_header(auth_resp, "set-cookie")
      cookie_pair = set_cookie |> String.split(";", parts: 2) |> hd()
      cookie_hdr = [{"cookie", cookie_pair}]

      get_resp = Req.get!(req, url: "/api/v1/sessions", headers: cookie_hdr)
      assert get_resp.status == 200
      assert get_resp.body == %{"sessions" => [%{"session_id" => "demo", "cwd" => "/tmp/demo"}]}

      missing_origin =
        Req.post!(req,
          url: "/api/v1/sessions",
          headers: cookie_hdr,
          json: %{"session_id" => "demo", "cwd" => "/tmp/demo"}
        )

      assert missing_origin.status == 403
      assert missing_origin.body == %{"error" => "forbidden origin"}

      cross_origin =
        Req.post!(req,
          url: "/api/v1/sessions",
          headers: [{"origin", "https://evil.example"} | cookie_hdr],
          json: %{"session_id" => "demo", "cwd" => "/tmp/demo"}
        )

      assert cross_origin.status == 403
      assert cross_origin.body == %{"error" => "forbidden origin"}

      wrong_ct =
        Req.post!(req,
          url: "/api/v1/sessions",
          headers: [
            {"origin", "http://127.0.0.1:4000"},
            {"content-type", "text/plain"}
            | cookie_hdr
          ],
          body: ~s({"session_id":"demo","cwd":"/tmp/demo"})
        )

      assert wrong_ct.status == 415
      assert wrong_ct.body == %{"error" => "expected application/json"}

      valid_post =
        Req.post!(req,
          url: "/api/v1/sessions",
          headers: [{"origin", "http://127.0.0.1:4000"} | cookie_hdr],
          json: %{"session_id" => "demo", "cwd" => "/tmp/demo"}
        )

      assert valid_post.status == 200
      assert valid_post.body["seq"] == 1
    end
  end

  describe "body parser bounds and router status mapping" do
    test "returns 413 for oversized JSON bodies and 400 for malformed JSON", %{
      token: token,
      router_opts: router_opts
    } do
      opts = Router.init(router_opts)
      oversized = ~s({"pad":") <> String.duplicate("a", 4_000_050) <> ~s("})

      conn_413 =
        Plug.Test.conn(:post, "http://127.0.0.1:4000/api/v1/sessions", oversized)
        |> then(&%{&1 | req_headers: [{"host", "127.0.0.1:4000"} | &1.req_headers]})
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Router.call(opts)

      assert conn_413.status == 413
      assert JSON.decode!(conn_413.resp_body) == %{"error" => "request too large"}

      conn_400 =
        Plug.Test.conn(:post, "http://127.0.0.1:4000/api/v1/sessions", "{malformed")
        |> then(&%{&1 | req_headers: [{"host", "127.0.0.1:4000"} | &1.req_headers]})
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Router.call(opts)

      assert conn_400.status == 400
      assert JSON.decode!(conn_400.resp_body) == %{"error" => "invalid json"}
    end

    test "maps daemon ok/error tuples across session, scan, and command endpoints", %{
      req: req,
      token: token
    } do
      auth = [{"authorization", "Bearer #{token}"}]

      assert Req.post!(req,
               url: "/api/v1/sessions",
               headers: auth,
               json: %{"session_id" => "conflict", "cwd" => "/tmp/demo"}
             ).status == 409

      assert Req.post!(req, url: "/api/v1/sessions", headers: auth, json: %{}).status == 422

      assert Req.get!(req, url: "/api/v1/sessions/demo", headers: auth).status == 200
      assert Req.get!(req, url: "/api/v1/sessions/missing", headers: auth).status == 404

      quarantined = Req.get!(req, url: "/api/v1/sessions/broken", headers: auth)
      assert quarantined.status == 503
      assert quarantined.body == %{"error" => "session quarantined", "reason" => "corrupt log"}

      scan_ok =
        Req.get!(req,
          url: "/api/v1/sessions/demo/conversations/1/entries?order=asc",
          headers: auth
        )

      assert scan_ok.status == 200

      assert scan_ok.body == %{
               "items" => [%{"id" => "1", "order" => "asc"}],
               "next_cursor" => nil
             }

      assert Req.get!(req,
               url: "/api/v1/sessions/missing/conversations/1/entries",
               headers: auth
             ).status == 404

      assert Req.get!(req,
               url: "/api/v1/sessions/demo/conversations/1/entries?limit=bad",
               headers: auth
             ).status == 422

      cmd_ok =
        Req.post!(req,
          url: "/api/v1/sessions/demo/commands",
          headers: auth,
          json: %{"command" => "submit", "request_id" => "r1"}
        )

      assert cmd_ok.status == 200
      assert cmd_ok.body["seq"] == 42

      assert Req.post!(req,
               url: "/api/v1/sessions/missing/commands",
               headers: auth,
               json: %{"command" => "submit", "request_id" => "r1"}
             ).status == 404

      assert Req.post!(req,
               url: "/api/v1/sessions/demo/commands",
               headers: auth,
               json: %{"request_id" => "dup"}
             ).status == 409

      assert Req.post!(req,
               url: "/api/v1/sessions/demo/commands",
               headers: auth,
               json: %{}
             ).status == 422
    end
  end
end
