defmodule H.AccountsRemoveTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias H.{Accounts, Auth}
  alias H.Accounts.{Config, Vault}
  alias H.HTTP.Router

  setup do
    id = System.unique_integer([:positive, :monotonic])
    dir = Path.join(System.tmp_dir!(), "h-acct-rm-#{id}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, id: id}
  end

  describe "POST /api/v1/provider-accounts/remove" do
    test "removes Codex account source, reassigns active, deletes last accounts.json, and enforces auth & busy guard",
         %{dir: dir, id: id} do
      {:ok, vault, _} = Vault.open(dir, [])

      for {src, tok} <- [{"alpha", "tok-a"}, {"beta", "tok-b"}] do
        :ok =
          Vault.write(vault, src, %{
            "account_id" => "acct-#{src}",
            "subject" => "sub-#{src}",
            "access_token" => tok,
            "refresh_token" => "ref-#{src}",
            "expires_at_ms" => System.system_time(:millisecond) + 120_000
          })
      end

      :ok = Config.write(dir, ["alpha", "beta"], "alpha")

      accounts =
        start_supervised!(
          {Accounts,
           data_dir: dir,
           sources: ["alpha", "beta"],
           active: "alpha",
           http: fn _ -> flunk("unexpected HTTP call") end}
        )

      auth_name = :"H.AcctRemove.Auth.#{id}"
      auth_table = :"h_acct_rm_auth_#{id}"
      start_supervised!({Auth, data_dir: dir, name: auth_name, table: auth_table})
      token = Auth.owner_token(auth_table)

      router_opts = [
        port: 4000,
        auth_server: auth_name,
        auth_table: auth_table,
        daemon_opts: [accounts: accounts]
      ]

      # Requires owner auth
      assert post_json(
               "/api/v1/provider-accounts/remove",
               %{"source" => "alpha"},
               nil,
               router_opts
             ).status ==
               401

      # Invalid payload -> 422
      assert post_json(
               "/api/v1/provider-accounts/remove",
               %{"source" => "../bad"},
               token,
               router_opts
             ).status ==
               422

      # Removing active "alpha" reassigns active to "beta" and deletes its vault file
      resp1 =
        post_json("/api/v1/provider-accounts/remove", %{"source" => "alpha"}, token, router_opts)

      assert resp1.status == 200
      assert JSON.decode!(resp1.resp_body) == %{"removed" => "alpha", "active" => "beta"}
      refute File.exists?(Path.join(dir, "credentials/openai_codex-alpha.json"))
      assert Config.read(dir) == {:ok, ["beta"], "beta"}

      assert {:ok, %{access_token: "tok-b", account_id: "acct-beta"}} =
               Accounts.resolve_codex(accounts)

      # Unknown source -> 422
      resp_missing =
        post_json("/api/v1/provider-accounts/remove", %{"source" => "alpha"}, token, router_opts)

      assert resp_missing.status == 422
      assert JSON.decode!(resp_missing.resp_body) == %{"error" => "unknown_account_source"}

      # Removing last source deletes accounts.json and clears configured?
      resp2 =
        post_json("/api/v1/provider-accounts/remove", %{"source" => "beta"}, token, router_opts)

      assert resp2.status == 200
      assert JSON.decode!(resp2.resp_body) == %{"removed" => "beta", "active" => nil}
      refute File.exists?(Path.join(dir, "accounts.json"))
      refute File.exists?(Path.join(dir, "credentials/openai_codex-beta.json"))
      assert Accounts.configured?(accounts) == false
    end

    test "rejects removal with 409 login_busy while a login for that source is active", %{
      dir: dir,
      id: id
    } do
      owner = self()

      http = fn opts ->
        case opts[:url] do
          "https://auth.openai.com/api/accounts/deviceauth/usercode" ->
            send(owner, :device_code_requested)

            {:ok,
             %Req.Response{
               status: 200,
               body: %{
                 "device_auth_id" => "device-auth-1",
                 "user_code" => "ABCD-1234",
                 "interval" => "5"
               }
             }}

          "https://auth.openai.com/api/accounts/deviceauth/token" ->
            send(owner, {:poll_wait, self()})

            receive do
              :stop -> {:ok, %Req.Response{status: 403, body: %{}}}
            end
        end
      end

      accounts =
        start_supervised!(
          {Accounts, data_dir: dir, sources: ["work"], http: http, test_poll_cap: 5}
        )

      auth_name = :"H.AcctRemoveBusy.Auth.#{id}"
      auth_table = :"h_acct_rm_busy_auth_#{id}"
      start_supervised!({Auth, data_dir: dir, name: auth_name, table: auth_table})
      token = Auth.owner_token(auth_table)

      router_opts = [
        port: 4000,
        auth_server: auth_name,
        auth_table: auth_table,
        daemon_opts: [accounts: accounts]
      ]

      assert {:ok, _} =
               Accounts.start(accounts, %{
                 "provider" => "openai_codex",
                 "source" => "work",
                 "request_id" => "req-busy-1"
               })

      assert_receive :device_code_requested, 1_500
      assert_receive {:poll_wait, poll_pid}, 1_500

      resp =
        post_json("/api/v1/provider-accounts/remove", %{"source" => "work"}, token, router_opts)

      assert resp.status == 409
      assert JSON.decode!(resp.resp_body) == %{"error" => "login_busy"}
      send(poll_pid, :stop)
    end
  end

  describe "POST /api/v1/provider-keys/remove" do
    test "removes API key aliases, reassigns active sorted key, and deletes api-keys.json when empty",
         %{dir: dir, id: id} do
      accounts =
        start_supervised!(
          {Accounts, data_dir: dir, sources: [], http: fn _ -> flunk("unexpected HTTP call") end}
        )

      auth_name = :"H.KeyRemove.Auth.#{id}"
      auth_table = :"h_key_rm_auth_#{id}"
      start_supervised!({Auth, data_dir: dir, name: auth_name, table: auth_table})
      token = Auth.owner_token(auth_table)

      router_opts = [
        port: 4000,
        auth_server: auth_name,
        auth_table: auth_table,
        daemon_opts: [accounts: accounts]
      ]

      assert {:ok, _} =
               Accounts.put_api_key(accounts, %{
                 "provider" => "openrouter",
                 "source" => "team",
                 "api_key" => "sk-or-team-123"
               })

      assert {:ok, _} =
               Accounts.put_api_key(accounts, %{
                 "provider" => "openrouter",
                 "source" => "personal",
                 "api_key" => "sk-or-personal-456"
               })

      assert {:ok, _} =
               Accounts.use_api_key(accounts, %{
                 "provider" => "openrouter",
                 "source" => "personal"
               })

      assert {:ok, %{api_key: "sk-or-personal-456"}} =
               Accounts.resolve_api_key(accounts, "openrouter")

      # Requires auth
      assert post_json(
               "/api/v1/provider-keys/remove",
               %{"provider" => "openrouter", "source" => "personal"},
               nil,
               router_opts
             ).status == 401

      # Remove active "personal" -> reassigns to "team"
      resp1 =
        post_json(
          "/api/v1/provider-keys/remove",
          %{"provider" => "openrouter", "source" => "personal"},
          token,
          router_opts
        )

      assert resp1.status == 200

      assert JSON.decode!(resp1.resp_body) == %{
               "removed" => "personal",
               "provider" => "openrouter",
               "active" => "team"
             }

      assert {:ok, %{api_key: "sk-or-team-123"}} =
               Accounts.resolve_api_key(accounts, "openrouter")

      # Remove last key -> active is nil, api-keys.json deleted
      resp2 =
        post_json(
          "/api/v1/provider-keys/remove",
          %{"provider" => "openrouter", "source" => "team"},
          token,
          router_opts
        )

      assert resp2.status == 200

      assert JSON.decode!(resp2.resp_body) == %{
               "removed" => "team",
               "provider" => "openrouter",
               "active" => nil
             }

      assert :not_configured = Accounts.resolve_api_key(accounts, "openrouter")
      refute File.exists?(Path.join(dir, "credentials/api-keys.json"))

      # Removing unknown key -> 422
      resp_unknown =
        post_json(
          "/api/v1/provider-keys/remove",
          %{"provider" => "openrouter", "source" => "team"},
          token,
          router_opts
        )

      assert resp_unknown.status == 422
      assert JSON.decode!(resp_unknown.resp_body) == %{"error" => "unknown_account_source"}
    end
  end

  defp post_json(path, body, token, router_opts) do
    conn(:post, path, JSON.encode!(body))
    |> then(&%{&1 | req_headers: [{"host", "127.0.0.1:4000"} | &1.req_headers]})
    |> put_req_header("content-type", "application/json")
    |> then(fn c ->
      if token, do: put_req_header(c, "authorization", "Bearer " <> token), else: c
    end)
    |> Router.call(Router.init(router_opts))
  end
end
