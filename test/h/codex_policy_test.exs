defmodule H.CodexPolicyTest do
  use ExUnit.Case, async: false
  import Plug.Conn

  @behaviour H.Provider.AccountPolicy
  @impl true
  def order(_model, sources), do: sources

  @impl true
  def rejected(_model, source, reason) do
    send(Application.fetch_env!(:harness, __MODULE__)[:owner], {:rejected, source, reason})
    :ok
  end

  @tag :tmp_dir
  test "pinned SSE transport distinguishes an explicit HTTP auth rejection from generic quota and post-output failures",
       %{tmp_dir: dir} do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:finch)
    ReqLLM.Providers.initialize()
    start_supervised!({Finch, ReqLLM.Application.get_finch_config()})
    start_supervised!({Task.Supervisor, name: ReqLLM.TaskSupervisor})
    owner = self()
    mode = :atomics.new(1, [])

    server =
      start_supervised!({Bandit, ip: {127, 0, 0, 1}, port: 0, plug: {__MODULE__, {owner, mode}}})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    for {app, key, value} <- [
          {:harness, __MODULE__, [port: port, owner: owner]},
          {:req_llm, :finch_request_adapter, __MODULE__}
        ] do
      previous = Application.fetch_env(app, key)
      Application.put_env(app, key, value)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end)
    end

    File.chmod!(dir, 0o700)
    sources = ["first", "second"]
    {:ok, vault, _} = H.Accounts.Vault.open(dir, [])

    for id <- sources do
      :ok =
        H.Accounts.Vault.write(vault, id, %{
          "access_token" => "test-#{id}",
          "account_id" => id,
          "subject" => id,
          "refresh_token" => "test-grant-#{id}",
          "expires_at_ms" => System.system_time(:millisecond) + 120_000
        })
    end

    accounts =
      start_supervised!(
        {H.Accounts,
         data_dir: dir, sources: sources, http: fn _ -> flunk("unexpected token refresh") end}
      )

    config = %{accounts: accounts, codex_account_policy: %{module: __MODULE__, sources: sources}}

    request = %{
      model: "openai_codex:gpt-6.1-sol",
      messages: [%{role: "user", content: [%{type: "text", text: "Hi"}]}]
    }

    emit = &send(owner, {:delta, &1})
    assert H.Provider.ReqLLM.dispatch_limit(config, request.model) == 2

    assert {:ok, %{content: [%{type: "text", text: "OK"}]}} =
             H.Provider.ReqLLM.stream_turn(config, request, emit)

    assert_receive {:dispatch, "first"}
    assert_receive {:rejected, "first", :invalid_token}
    assert_receive {:dispatch, "second"}
    assert_receive {:delta, %{type: :text_delta, text: "OK"}}
    refute_receive {:delta, %{type: :start}}, 20

    for case_id <- [1, 2, 3, 4] do
      :atomics.put(mode, 1, case_id)

      assert {:error, %{code: code, retryable: false}} =
               H.Provider.ReqLLM.stream_turn(config, request, emit)

      assert code == if(case_id == 1, do: "rate_limited", else: "codex_request_failed")
      assert_receive {:dispatch, "first"}
      refute_receive {:dispatch, "second"}, 20
      if case_id == 1, do: assert_receive({:rejected, "first", :rate_limited})
      refute_receive {:rejected, _, _}, 20
    end

    :atomics.put(mode, 1, 5)

    assert {:error, %{code: "invalid_token", retryable: false}} =
             H.Provider.ReqLLM.stream_turn(config, request, emit)

    assert_receive {:dispatch, "first"}
    assert_receive {:rejected, "first", :invalid_token}
    assert_receive {:dispatch, "second"}
    assert_receive {:rejected, "second", :invalid_token}
    refute_receive {:dispatch, _}, 20

    :atomics.put(mode, 1, 0)
    stock = Map.delete(config, :codex_account_policy)

    assert {:error, %{code: "invalid_token", retryable: false}} =
             H.Provider.ReqLLM.stream_turn(stock, request, emit)

    assert_receive {:dispatch, "first"}
    refute_receive {:dispatch, "second"}, 20
  end

  def call(%Finch.Request{} = wire) do
    %{
      wire
      | scheme: :http,
        host: "127.0.0.1",
        port: Application.fetch_env!(:harness, __MODULE__)[:port]
    }
  end

  def init(state), do: state

  def call(conn, {owner, mode}) do
    [account] = get_req_header(conn, "chatgpt-account-id")
    ["Bearer test-" <> ^account] = get_req_header(conn, "authorization")
    send(owner, {:dispatch, account})

    case {account, :atomics.get(mode, 1)} do
      {_, 5} ->
        http_error(conn, 401, "invalid_token")

      {"second", _} ->
        sse(conn, [
          {"response.output_text.delta", %{"delta" => "OK"}},
          {"response.completed", %{"response" => %{"status" => "completed", "output" => []}}}
        ])

      {"first", 0} ->
        http_error(conn, 401, "invalid_token")

      {"first", 1} ->
        http_error(conn, 429, "usage_limit_reached")

      {"first", 2} ->
        http_error(conn, 401, "other_auth_error")

      {"first", 3} ->
        sse(conn, [
          {"response.output_text.delta", %{"delta" => "partial"}},
          {"response.failed",
           %{"response" => %{"error" => %{"code" => "invalid_token", "message" => "example"}}}}
        ])

      {"first", 4} ->
        sse(conn, [{"response.output_text.delta", %{"delta" => "partial"}}])
    end
  end

  defp http_error(conn, status, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{error: %{code: code, message: "example"}}))
  end

  defp sse(conn, events) do
    body =
      Enum.map_join(events, fn {type, data} ->
        "event: #{type}\ndata: #{JSON.encode!(Map.put(data, "type", type))}\n\n"
      end)

    conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)
  end
end
