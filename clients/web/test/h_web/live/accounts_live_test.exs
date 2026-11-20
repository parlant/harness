defmodule HWeb.AccountsLiveTest do
  use HWeb.ConnCase, async: false

  test "owner adds an alias and starts and cancels sign-in without a session", ctx do
    assert {:error, {:redirect, %{to: "/login"}}} = live(ctx.conn, "/settings/accounts")
    owner = self()

    http = fn opts ->
      send(owner, {:auth_post, opts[:url]})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "device_auth_id" => "fixture-private-id",
           "user_code" => "ABCD-1234",
           "interval" => 5
         }
       }}
    end

    accounts = start_supervised!({H.Accounts, data_dir: ctx.data_dir, sources: [], http: http})

    Application.put_env(
      :harness_web,
      :daemon_opts,
      Keyword.put(ctx.daemon_opts, :accounts, accounts)
    )

    conn = log_in_owner(ctx.conn, ctx.owner_token)
    {:ok, view, _} = live(conn, "/settings/accounts")

    assert view |> form("#add-account", %{source: "work"}) |> render_submit() =~ "stock active"
    assert H.Accounts.Config.read(ctx.data_dir) == {:ok, ["work"], "work"}
    render_click(element(view, "#account-work button", "Sign in"))
    assert_receive {:auth_post, "https://auth.openai.com/api/accounts/deviceauth/usercode"}
    assert render_click(element(view, "#device-flow button", "Cancel login")) =~ "cancelled"
    refute render(view) =~ "fixture-private-id"
    assert H.Daemon.list_sessions(ctx.daemon_opts) == []
  end

  test "owner writes API keys using a normal POST and no secret is echoed", ctx do
    accounts = start_supervised!({H.Accounts, data_dir: ctx.data_dir, sources: []})

    Application.put_env(
      :harness_web,
      :daemon_opts,
      Keyword.put(ctx.daemon_opts, :accounts, accounts)
    )

    conn = ctx.conn |> log_in_owner(ctx.owner_token) |> get("/settings/accounts")
    [_, csrf] = Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, conn.resp_body)
    secret = "fixture-key-not-for-output"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        out =
          post(recycle(conn), "/settings/accounts/keys", %{
            "_csrf_token" => csrf,
            "provider" => "openai",
            "source" => "work",
            "api_key" => secret
          })

        assert redirected_to(out) == "/settings/accounts"
        page = get(recycle(out), "/settings/accounts")
        assert page.resp_body =~ "work"
        refute page.resp_body =~ secret
      end)

    refute log =~ secret
    assert {:ok, %{api_key: ^secret}} = H.Accounts.resolve_api_key(accounts, :openai)
  end
end
