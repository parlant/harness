defmodule H.AccountsTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn
  alias H.{Accounts, Auth}
  alias H.Accounts.Vault
  alias H.Provider.ReqLLM, as: Adapter
  alias ReqLLM.StreamEvent

  setup do
    dir = Path.join(System.tmp_dir!(), "h-accounts-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "boot/1" do
    test "opts into named sources with one explicit active account", %{dir: dir} do
      opts = [data_dir: dir]

      assert {:ok, [accounts: Accounts, data_dir: ^dir], [{Accounts, fresh}]} =
               Accounts.boot(opts)

      assert fresh[:sources] == []
      refute File.exists?(Path.join(dir, "accounts.json"))
      path = Path.join(dir, "accounts.json")

      File.write!(
        path,
        JSON.encode!(%{
          version: 1,
          openai_codex: %{sources: ["work", "personal"], active: "personal"}
        })
      )

      assert {:ok, configured, [{Accounts, child_opts}]} = Accounts.boot(opts)
      assert configured[:accounts] == Accounts
      assert child_opts[:sources] == ["work", "personal"]
      assert child_opts[:active] == "personal"
      assert {:ok, _, [_]} = Accounts.boot([no_extensions: true] ++ opts)
      File.write!(path, ~s({"version":1,"openai_codex":{"sources":["../bad"]}}))
      assert Accounts.boot(opts) == {:error, :invalid_accounts_json}
    end
  end

  describe "stored API-key profiles" do
    test "write-only aliases, explicit selection and restart without an environment", %{dir: dir} do
      opts = [data_dir: dir, sources: []]
      server = start_supervised!({Accounts, opts})

      request = %{
        model: "openai:gpt-5.4",
        messages: [%{role: "user", content: [%{type: "text", text: "test"}]}]
      }

      test = self()

      config = %{
        accounts: server,
        credentials_opts: [env: %{}],
        stream_fn: fn model, _, opts ->
          send(test, {:credential, model.provider, opts[:api_key]})
          {:ok, [%StreamEvent{type: :text_delta, data: "fixture reply"}]}
        end
      }

      assert {:error, %{code: "missing_provider_credential", message: message, retryable: false}} =
               Adapter.stream_turn(config, request, fn _ -> :ok end)

      assert message =~ "OPENAI_API_KEY"
      assert message =~ "/key set openai"
      refute_received {:credential, _, _}

      assert {:ok, _} =
               Adapter.stream_turn(
                 put_in(config.credentials_opts, env: %{"OPENAI_API_KEY" => "fixture-env"}),
                 request,
                 fn _ -> :ok end
               )

      assert_receive {:credential, :openai, "fixture-env"}
      refute File.exists?(Path.join(dir, "accounts.json"))

      first = %{"provider" => "openai", "source" => "work", "api_key" => "fixture-work-secret"}
      second = %{first | "source" => "personal", "api_key" => "fixture-personal-secret"}
      assert {:ok, %{active: "work"}} = Accounts.put_api_key(server, first)
      assert {:ok, %{active: "work"}} = Accounts.put_api_key(server, second)

      assert {:error, :invalid_api_key_profile} =
               Accounts.put_api_key(server, %{first | "provider" => "openai_codex"})

      assert {:ok, %{active: "personal"}} =
               Accounts.use_api_key(server, Map.drop(second, ["api_key"]))

      assert {:ok, list} = Accounts.api_keys(server)

      assert %{provider: "openai", active: "personal", sources: ["personal", "work"]} in list.providers

      refute inspect(list) =~ "fixture-personal-secret"
      refute inspect(:sys.get_status(server)) =~ "fixture-work-secret"

      assert Bitwise.band(File.stat!(Path.join(dir, "credentials/api-keys.json")).mode, 0o777) ==
               0o600

      :ok = stop_supervised!(Accounts)
      reopened = start_supervised!({Accounts, opts})
      config = %{config | accounts: reopened}
      assert {:ok, _} = Adapter.stream_turn(config, request, fn _ -> :ok end)
      assert_receive {:credential, :openai, "fixture-personal-secret"}
      assert Enum.all?(Adapter.list_models(config), &(&1.provider == "openai"))
    end
  end

  describe "Vault.open/2" do
    test "rejects an insecure file, symlink, and invalid source path", %{dir: dir} do
      {:ok, vault, _} = Vault.open(dir, [])

      assert {:error, :credential_store_unavailable} =
               Vault.write(vault, "../escape", record("a"))

      assert :ok = Vault.write(vault, "primary", record("a"))
      path = Path.join(dir, "credentials/openai_codex-primary.json")
      File.chmod!(path, 0o644)
      assert {:error, :unsafe_or_invalid_credential_file} = Vault.open(dir, ["primary"])
      File.rm!(path)
      File.ln_s!("missing", path)
      assert {:error, :unsafe_or_invalid_credential_file} = Vault.open(dir, ["primary"])
    end
  end

  describe "device login via the owner API" do
    test "first login writes config before provider I/O; restart reads it without replaying login",
         %{dir: dir} do
      server =
        start_supervised!(
          {Accounts,
           data_dir: dir,
           sources: [],
           http: scripted_http(self(), access_token("a")),
           test_poll_cap: 5}
        )

      assert Accounts.configured?(server) == false
      old_attempt = Adapter.attempt_config(%{accounts: server})
      assert Adapter.dispatch_limit(old_attempt, "openai_codex:gpt-6.1-sol") == nil

      assert {:ok, %{source: "default", operation: ref}} =
               Accounts.start(server, %{"provider" => "openai_codex", "request_id" => "first"})

      assert_receive {:device_post, :request_code}, 1500
      assert_receive {:device_post, {:poll, pid}}, 1500
      assert H.Accounts.Config.read(dir) == {:ok, ["default"], "default"}
      assert Accounts.configured?(server)
      assert Adapter.dispatch_limit(old_attempt, "openai_codex:gpt-6.1-sol") == nil
      assert Adapter.dispatch_limit(%{accounts: server}, "openai_codex:gpt-6.1-sol") == 1
      send(pid, :approve)
      assert %{state: "complete"} = await_state(server, ref, "complete")
      assert {:ok, %{source: "second"}} = Accounts.add(server, %{"source" => "second"})
      assert {:ok, %{source: "second"}} = Accounts.add(server, %{"source" => "second"})
      assert :ok = stop_supervised!(Accounts)
      assert {:ok, _, [{Accounts, opts}]} = Accounts.boot(data_dir: dir)

      server =
        start_supervised!(
          {Accounts, Keyword.put(opts, :http, fn _ -> flunk("unexpected sign-in replay") end)}
        )

      assert H.Accounts.Config.read(dir) == {:ok, ["default", "second"], "default"}
      assert {:ok, %{account_id: "account-a"}} = Accounts.resolve_codex(server)

      assert {:error, :login_not_found} =
               Accounts.operation(server, :status, %{"operation" => ref})
    end

    test "owner guard, dedupe, pending, private install, late cancel, and redaction", %{dir: dir} do
      owner = self()
      access = access_token("b")
      server = start_accounts(dir, scripted_http(owner, access))
      table = Module.concat(__MODULE__, AuthTable)

      start_supervised!(
        {Auth, data_dir: dir, name: Module.concat(__MODULE__, AuthServer), table: table}
      )

      token = Auth.owner_token(table)
      router_opts = [auth_table: table, daemon_opts: [accounts: server]]
      url = "/api/v1/provider-logins"
      params = start_params("first", "backup")

      assert call_router(:post, url <> "/start", params, nil, router_opts).status == 401
      assert call_router(:get, url, nil, nil, router_opts).status == 401

      assert %{"providers" => [%{"interaction" => "device_code_v1", "sources" => sources}]} =
               api(:get, url, nil, token, router_opts)

      assert Enum.map(sources, & &1["id"]) == ["primary", "backup"]

      assert %{"operation" => ref, "state" => "starting"} =
               api(:post, url <> "/start", params, token, router_opts)

      assert_receive {:device_post, :request_code}, 1500
      assert_receive {:device_post, {:poll, poll_pid}}, 1500

      assert %{
               "operation" => ^ref,
               "state" => "pending",
               "user_code" => "ABCD-1234",
               "verification_url" => "https://auth.openai.com/codex/device"
             } =
               api(:post, url <> "/start", params, token, router_opts)

      assert call_router(
               :post,
               url <> "/start",
               %{params | "source" => "primary"},
               token,
               router_opts
             ).status == 409

      refute_receive {:device_post, :request_code}, 30
      send(poll_pid, :approve)
      assert_receive {:device_post, :exchange}, 1500

      result = await_state(server, ref, "complete")
      assert result == %{state: "complete", source: "backup", operation: ref}

      assert api(:post, url <> "/cancel", %{"operation" => ref}, token, router_opts)["state"] ==
               "complete"

      assert Accounts.resolve_codex(server) == {:error, :credential_unavailable}

      assert call_router(
               :post,
               "/api/v1/provider-accounts/activate",
               %{"source" => "backup"},
               nil,
               router_opts
             ).status == 401

      assert api(
               :post,
               "/api/v1/provider-accounts/activate",
               %{"source" => "backup"},
               token,
               router_opts
             ) == %{"active" => "backup"}

      assert Accounts.resolve_codex(server) ==
               {:ok, %{access_token: access, account_id: "account-b"}}

      assert H.Accounts.Config.read(dir) == {:ok, ["primary", "backup"], "backup"}

      vault = Path.join(dir, "credentials/openai_codex-backup.json")
      assert Bitwise.band(File.stat!(vault).mode, 0o777) == 0o600
      refute inspect(:sys.get_status(server)) =~ "fixture-refresh-credential"
      refute Jason.encode!(api(:get, url, nil, token, router_opts)) =~ "account-b"

      assert ["no-store"] =
               get_resp_header(call_router(:get, url, nil, token, router_opts), "cache-control")
    end

    test "cancel while exchange is in flight never installs a late credential", %{dir: dir} do
      owner = self()

      http = fn opts ->
        if String.ends_with?(opts[:url], "/oauth/token") do
          send(owner, {:exchange, self()})

          receive do
            :finish -> response(200, tokens(access_token("b")))
          end
        else
          scripted_http(owner, access_token("b")).(opts)
        end
      end

      server = start_accounts(dir, http)
      assert {:ok, %{operation: ref}} = Accounts.start(server, start_params("cancel", "backup"))
      assert_receive {:device_post, {:poll, poll_pid}}, 1500
      send(poll_pid, :approve)
      assert_receive {:exchange, worker}, 1500
      monitor = Process.monitor(worker)

      assert {:ok, %{state: "cancelled"}} =
               Accounts.operation(server, :cancel, %{"operation" => ref})

      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1500
      assert {:error, :credential_unavailable} = Accounts.resolve_codex(server)
      assert %{state: "cancelled"} = await_state(server, ref, "cancelled")

      assert {:ok, %{state: "cancelled"}} =
               Accounts.start(server, start_params("cancel", "backup"))
    end

    test "expiry and restart stop a pending flow; no grant is replayed", %{dir: dir} do
      server = start_accounts(dir, scripted_http(self(), access_token("b")), login_ttl: 500)
      assert {:ok, %{operation: ref}} = Accounts.start(server, start_params("expire", "primary"))
      assert_receive {:device_post, {:poll, _pid}}, 1500
      assert %{state: "expired"} = await_state(server, ref, "expired")
      assert {:ok, %{operation: ref}} = Accounts.start(server, start_params("restart", "primary"))
      assert_receive {:device_post, {:poll, _pid}}, 1500
      :ok = stop_supervised!(Accounts)
      server = start_accounts(dir, fn _ -> flunk("an auth request was replayed") end)

      assert {:error, :login_not_found} =
               Accounts.operation(server, :status, %{"operation" => ref})

      assert {:error, :credential_unavailable} = Accounts.resolve_codex(server)
    end

    test "rejects replacement by another identity and failing writes do not publish", %{dir: dir} do
      {:ok, vault, _} = Vault.open(dir, [])
      :ok = Vault.write(vault, "primary", record("a"))
      server = start_accounts(dir, scripted_http(self(), access_token("b")))
      assert {:ok, %{operation: ref}} = Accounts.start(server, start_params("wrong", "primary"))
      assert_receive {:device_post, {:poll, pid}}, 1500
      send(pid, :approve)
      assert %{reason: "identity_mismatch"} = await_state(server, ref, "failed")
      assert {:ok, %{account_id: "account-a"}} = Accounts.resolve_codex(server)

      assert {:ok, %{operation: ref}} = Accounts.start(server, start_params("write", "backup"))
      assert_receive {:device_post, {:poll, pid}}, 1500
      File.ln_s!("missing", Path.join(dir, "credentials/openai_codex-backup.json"))
      send(pid, :approve)
      assert %{reason: "credential_store_unavailable"} = await_state(server, ref, "failed")

      assert {:ok, %{providers: [%{sources: [_, %{state: "not_signed_in"}]}]}} =
               Accounts.discover(server)
    end
  end

  describe "resolve_codex/1" do
    test "single-flight refresh commits before use; cancellation cannot race replacement", %{
      dir: dir
    } do
      {:ok, vault, _} = Vault.open(dir, [])
      :ok = Vault.write(vault, "primary", %{record("a") | "expires_at_ms" => 1})
      test = self()
      fresh = access_token("a")
      server = start_accounts(dir, refresh_http(test, fresh))
      first = Task.async(fn -> Accounts.resolve_codex(server) end)
      assert_receive {:refresh, worker}, 1500
      second = Task.async(fn -> Accounts.resolve_codex(server) end)
      assert {:error, :login_busy} = Accounts.start(server, start_params("reauth", "primary"))
      assert {:ok, _, %{"primary" => %{"state" => "reauth"}}} = Vault.open(dir, ["primary"])
      send(worker, :finish)
      expected = {:ok, %{access_token: fresh, account_id: "account-a"}}
      assert Task.await(first) == expected
      assert Task.await(second) == expected
      refute_receive {:refresh, _}, 20
      :ok = stop_supervised!(Accounts)
      server = start_accounts(dir, fn _ -> flunk("refresh should be persisted") end)
      assert Accounts.resolve_codex(server) == expected
    end

    test "a lost refresh grant is never replayed and stock does not fall through",
         %{dir: dir} do
      {:ok, vault, _} = Vault.open(dir, [])
      :ok = Vault.write(vault, "primary", %{record("a") | "expires_at_ms" => 1})
      :ok = Vault.write(vault, "backup", record("b"))
      server = start_accounts(dir, refresh_http(self(), access_token("a")))
      first = Task.async(fn -> Accounts.resolve_codex(server) end)
      assert_receive {:refresh, worker}, 1500
      Process.exit(worker, :kill)
      assert {:error, :credential_unavailable} = Task.await(first)
      :ok = stop_supervised!(Accounts)
      server = start_accounts(dir, fn _ -> flunk("ambiguous refresh replayed") end)
      assert {:error, :credential_unavailable} = Accounts.resolve_codex(server)
      assert {:ok, %{active: "backup"}} = Accounts.activate(server, %{"source" => "backup"})
      assert {:ok, %{account_id: "account-b"}} = Accounts.resolve_codex(server)
    end

    test "the ReqLLM dispatch preserves ordinary tool history, not account-bound metadata, and never rotates after rejection",
         %{dir: dir} do
      {:ok, vault, _} = Vault.open(dir, [])
      :ok = Vault.write(vault, "primary", record("a"))
      :ok = Vault.write(vault, "backup", record("b"))
      server = start_accounts(dir, fn _ -> flunk("unexpected auth network request") end)
      test = self()
      emit = fn event -> send(test, {:event, event}) end

      request = %{
        model: "openai-codex:gpt-6.1-sol",
        messages: [
          %{
            role: "assistant",
            content: [
              %{type: "text", text: "checking"},
              %{type: "thinking", text: "private", signature: "opaque"}
            ],
            tool_calls: [%{id: "call-1", name: "read", arguments: %{}}]
          },
          %{role: "tool", content: [%{type: "text", text: "found"}], tool_call_id: "call-1"}
        ]
      }

      config = %{
        accounts: server,
        credentials: %{access_token: "wrong"},
        provider_options: [
          openai_stream_transport: :websocket,
          chatgpt_account_id: "wrong",
          session_id: "wrong"
        ],
        stream_fn: fn model, context, opts ->
          send(test, {:dispatch, model, context, opts})
          {:error, %{code: "quota", message: "unknown scope", retryable: true}}
        end
      }

      assert {:error, %{code: "codex_request_failed", retryable: false}} =
               Adapter.stream_turn(config, request, emit)

      assert_receive {:dispatch, %{provider: :openai_codex} = model,
                      %{messages: [assistant, tool]} = context, opts}

      assert [%{type: :text, text: "checking"}] = assistant.content
      assert assistant.reasoning_details == nil
      assert [%{id: "call-1"}] = assistant.tool_calls
      assert tool.tool_call_id == "call-1"
      assert opts[:provider_options][:chatgpt_account_id] == "account-a"
      assert opts[:provider_options][:openai_stream_transport] == :sse
      assert opts[:base_url] == "https://chatgpt.com/backend-api"
      refute Keyword.has_key?(opts[:provider_options], :session_id)
      assert opts[:max_retries] == 0

      assert {:ok, wire} =
               ReqLLM.Providers.OpenAICodex.attach_stream(model, context, opts, :unused)

      assert wire.host == "chatgpt.com" and wire.path == "/backend-api/codex/responses"
      assert {"chatgpt-account-id", "account-a"} in wire.headers
      assert %{"store" => false, "stream" => true, "input" => input} = JSON.decode!(wire.body)

      assert Enum.any?(
               input,
               &match?(%{"type" => "function_call_output", "call_id" => "call-1"}, &1)
             )

      refute wire.body =~ "opaque"
      refute_receive {:dispatch, _, _, _}, 30
      assert Enum.any?(Adapter.list_models(%{accounts: server}), &(&1.provider == "openai_codex"))

      config = %{
        config
        | stream_fn: fn _, _, _ ->
            {:ok, [%StreamEvent{type: :text_delta, data: "partial"}]}
          end
      }

      assert {:error, %{retryable: false}} = Adapter.stream_turn(config, request, emit)
    end
  end

  defp start_accounts(dir, http, additional \\ []) do
    start_supervised!(
      {Accounts,
       [data_dir: dir, sources: ["primary", "backup"], http: http, test_poll_cap: 5] ++ additional}
    )
  end

  defp start_params(id, source),
    do: %{"provider" => "openai-codex", "source" => source, "request_id" => id}

  defp await_state(server, ref, target, attempts \\ 100) do
    assert {:ok, view} = Accounts.operation(server, :status, %{"operation" => ref})

    if view.state == target do
      view
    else
      assert attempts > 0, "expected #{target}, got #{view.state}"
      Process.sleep(5)
      await_state(server, ref, target, attempts - 1)
    end
  end

  defp scripted_http(test, access) do
    fn opts ->
      assert opts[:retry] == false
      assert opts[:redirect] == false

      case opts[:url] do
        "https://auth.openai.com/api/accounts/deviceauth/usercode" ->
          send(test, {:device_post, :request_code})

          response(200, %{
            "user_code" => "ABCD-1234",
            "device_auth_id" => "secret-device-id",
            "interval" => "5"
          })

        "https://auth.openai.com/api/accounts/deviceauth/token" ->
          send(test, {:device_post, {:poll, self()}})
          assert opts[:json] == %{device_auth_id: "secret-device-id", user_code: "ABCD-1234"}

          receive do
            :approve ->
              response(200, %{
                "authorization_code" => "secret-authorization-code",
                "code_verifier" => "secret-verifier"
              })
          end

        "https://auth.openai.com/oauth/token" ->
          send(test, {:device_post, :exchange})
          assert opts[:form][:grant_type] == "authorization_code"
          assert opts[:form][:redirect_uri] == "https://auth.openai.com/deviceauth/callback"
          response(200, tokens(access))
      end
    end
  end

  defp refresh_http(test, access) do
    fn opts ->
      assert opts[:url] == "https://auth.openai.com/oauth/token"
      assert opts[:form][:grant_type] == "refresh_token"
      assert opts[:retry] == false
      send(test, {:refresh, self()})

      receive do
        :finish -> response(200, tokens(access))
      end
    end
  end

  defp access_token(id) do
    data =
      JSON.encode!(%{
        "sub" => "subject-#{id}",
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => "account-#{id}"}
      })

    "fake." <> Base.url_encode64(data, padding: false) <> ".fixture"
  end

  defp record(id) do
    %{
      "access_token" => access_token(id),
      "refresh_token" => "fixture-refresh-credential",
      "expires_at_ms" => System.system_time(:millisecond) + 120_000,
      "account_id" => "account-#{id}",
      "subject" => "subject-#{id}"
    }
  end

  defp tokens(access),
    do: %{
      "access_token" => access,
      "refresh_token" => "fixture-refresh-credential",
      "expires_in" => 120
    }

  defp response(status, body), do: {:ok, %Req.Response{status: status, body: body}}

  defp call_router(method, url, body, token, opts) do
    req = conn(method, url, if(body, do: JSON.encode!(body), else: nil))
    req = %{req | req_headers: [{"host", "127.0.0.1:80"} | req.req_headers]}
    req = if body, do: put_req_header(req, "content-type", "application/json"), else: req
    req = if token, do: put_req_header(req, "authorization", "Bearer " <> token), else: req
    H.HTTP.Router.call(req, opts)
  end

  defp api(method, url, body, token, opts) do
    res = call_router(method, url, body, token, opts)
    assert res.status == 200, res.resp_body
    refute res.resp_body =~ "secret-device-id"
    refute res.resp_body =~ "fixture-refresh-credential"
    JSON.decode!(res.resp_body)
  end
end
