defmodule H.CompatibleProviderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias H.{Accounts, Auth}
  alias H.Provider.{Compatible, ReqLLM, ReqLLM.Catalog}
  alias H.Session.Compaction

  @moduletag :tmp_dir
  @example Path.expand("../../examples/providers/openai-compatible.json", __DIR__)
  @gpt "example-router:gpt-5-example"
  @slash "example-router:vendor/Example-Vision"
  @secret "fixture-router-secret+not-an-openai-key"

  setup %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    dest = Path.join(dir, "openai-compatible.json")
    File.cp!(@example, dest)
    File.chmod!(dest, 0o600)
    assert {:ok, opts} = Compatible.load(data_dir: dir)
    assert {:ok, _, [{Accounts, child}]} = Accounts.boot(opts)
    accounts = start_supervised!({Accounts, Keyword.delete(child, :name)})

    config = %{
      accounts: accounts,
      compatible_providers: opts[:compatible_providers],
      receive_timeout: 3_000,
      credentials_opts: [
        env: %{"OPENAI_API_KEY" => "fixture-stock", "EXAMPLE_ROUTER_API_KEY" => "ignored"}
      ]
    }

    %{
      config: config,
      accounts: accounts,
      account_opts: Keyword.delete(child, :name),
      daemon_opts: Keyword.put(opts, :accounts, accounts)
    }
  end

  describe "load/1 and daemon catalog" do
    test "registers exact IDs, metadata, and leaves the stock default untouched", %{
      config: config,
      daemon_opts: opts
    } do
      auth =
        start_supervised!(
          {Auth, data_dir: opts[:data_dir], name: __MODULE__.Auth, table: __MODULE__.Token}
        )

      assert is_pid(auth)
      router = [auth_table: __MODULE__.Token, daemon_opts: opts]
      token = Auth.owner_token(__MODULE__.Token)
      assert %{"models" => models} = api(:get, "/api/v1/models", nil, router, token)
      assert length(Enum.filter(models, &(&1["provider"] == "example-router"))) == 2

      assert %{
               "provider_name" => "Example Model Router",
               "context_window" => 128_000,
               "max_output_tokens" => 16_384,
               "supports_images" => true,
               "supports_tools" => true,
               "supports_reasoning" => false,
               "unavailable_reason" => reason,
               "price_per_million_tokens" => %{
                 "input" => 0,
                 "output" => 0,
                 "cache_read" => 0,
                 "cache_write" => 0
               }
             } = Enum.find(models, &(&1["id"] == @slash))

      assert reason =~ "/key set example-router"
      assert Catalog.context_window("example-router:gpt-5-example", config) == 1_000_000
      assert ReqLLM.dispatch_limit(config, @slash) == 1
      assert Enum.any?(models, &(&1["provider"] == "openai"))

      assert Catalog.default_model(config) ==
               Catalog.default_model(Map.delete(config, :compatible_providers))

      assert %{"provider" => "example-router", "active" => "work"} =
               api(:post, "/api/v1/provider-keys/set", profile(), router, token)

      assert %{"providers" => list} = api(:get, "/api/v1/provider-keys", nil, router, token)
      assert %{"provider" => "example-router", "active" => "work", "sources" => ["work"]} in list
      assert %{"models" => models} = api(:get, "/api/v1/models", nil, router, token)
      refute Map.has_key?(Enum.find(models, &(&1["id"] == @slash)), "unavailable_reason")
      refute inspect(models) =~ "base_url"
    end

    test "rejects invalid config without echoing it or creating atoms", %{tmp_dir: dir} do
      path = Path.join(dir, "openai-compatible.json")
      data = JSON.decode!(File.read!(path))
      provider = data["providers"]["example-router"]
      id = "fixture-router-#{System.unique_integer([:positive])}"
      File.write!(path, JSON.encode!(%{data | "providers" => %{id => provider}}))
      assert {:ok, opts} = Compatible.load(data_dir: dir)
      assert Map.has_key?(opts[:compatible_providers], id)
      assert_raise ArgumentError, fn -> String.to_existing_atom(id) end

      for {id, value} <- [
            {"openai", provider},
            {"openai-codex", provider},
            {"../router", provider},
            {"example-router", Map.put(provider, "api_key", @secret)},
            {"example-router",
             %{provider | "base_url" => "https://user:#{@secret}@example.invalid/v1"}},
            {"example-router", %{provider | "base_url" => "http://example.invalid/v1"}}
          ] do
        File.write!(path, JSON.encode!(%{data | "providers" => %{id => value}}))
        assert {:error, :invalid_openai_compatible_json} = Compatible.load(data_dir: dir)
      end

      File.rm!(path)

      assert {:ok, opts} = Compatible.load(data_dir: dir)
      assert opts[:compatible_providers] == %{}
    end
  end

  describe "stream_turn/3 over local HTTP/SSE" do
    setup %{config: config} do
      {:ok, _} = Application.ensure_all_started(:bandit)
      {:ok, _} = Application.ensure_all_started(:finch)
      start_supervised!({Finch, Elixir.ReqLLM.Application.get_finch_config()})
      start_supervised!({Task.Supervisor, name: Elixir.ReqLLM.TaskSupervisor})
      %{config: config}
    end

    test "streams tool arguments and usage using exact IDs; sends tool results and image parts",
         %{config: config, accounts: accounts} do
      assert {:ok, _} = Accounts.put_api_key(accounts, profile())

      config =
        local(config, fn conn ->
          conn
          |> sse([
            choice(%{reasoning_content: "checking"}),
            choice(%{
              tool_calls: [
                %{
                  index: 0,
                  id: "call_1",
                  type: "function",
                  function: %{name: "read", arguments: "{\"path\":"}
                }
              ]
            }),
            choice(
              %{tool_calls: [%{index: 0, function: %{arguments: "\"fixture.txt\"}"}}]},
              "tool_calls"
            ),
            %{choices: [], usage: %{prompt_tokens: 12, completion_tokens: 4, total_tokens: 16}}
          ])
        end)

      owner = self()
      emit = &send(owner, {:event, &1})

      tools = [
        %{name: "read", description: "Read a fixture", parameters_schema: %{"type" => "object"}}
      ]

      messages = [
        %{
          role: "user",
          content: [
            %{type: "text", text: "hi"},
            %{type: "image", encoding: "base64", data: "AQID", mime_type: "image/png"}
          ]
        },
        %{
          role: "assistant",
          content: [],
          tool_calls: [%{id: "prior", name: "read", arguments: %{"path" => "prior.txt"}}]
        },
        %{
          role: "tool",
          tool_call_id: "prior",
          name: "read",
          content: [%{type: "text", text: "fixture result"}]
        }
      ]

      assert {:ok, response} =
               ReqLLM.stream_turn(
                 config,
                 %{
                   model: @gpt,
                   thinking: "high",
                   max_tokens: 311,
                   messages: messages,
                   tools: tools
                 },
                 emit
               )

      assert %{
               finish_reason: "tool_calls",
               usage: %{input_tokens: 12, output_tokens: 4, total_cost: total}
             } = response

      assert_in_delta total, 0.0000024, 0.000001

      assert [%{id: "call_1", name: "read", arguments: %{"path" => "fixture.txt"}}] =
               response.tool_calls

      assert_receive {:event, %{type: :start, provider: "example-router", model: "gpt-5-example"}}
      assert_receive {:event, %{type: :thinking_delta, text: "checking"}}

      assert_receive {:event,
                      %{type: :tool_call_delta, id: "call_1", args_delta: "\"fixture.txt\"}"}}

      assert_receive {:request, "POST", "/v1/chat/completions", ["Bearer " <> @secret], body}

      assert %{
               "model" => "gpt-5-example",
               "reasoning_effort" => "high",
               "max_tokens" => 311,
               "stream" => true,
               "stream_options" => %{"include_usage" => true},
               "messages" => msgs,
               "tools" => [%{"type" => "function", "function" => %{"name" => "read"}}]
             } = body

      refute Map.has_key?(body, "max_completion_tokens")

      assert [
               %{
                 "content" => [
                   _,
                   %{
                     "type" => "image_url",
                     "image_url" => %{"url" => "data:image/png;base64,AQID"}
                   }
                 ]
               },
               %{"tool_calls" => [%{"id" => "prior"}]},
               %{"role" => "tool", "tool_call_id" => "prior"} = tool
             ] = msgs

      assert inspect(tool["content"]) =~ "fixture result"
    end

    test "compaction uses the same named route and caps max_tokens; no effort for unsupported models",
         %{config: config, accounts: accounts} do
      assert {:ok, _} = Accounts.put_api_key(accounts, profile())
      config = local(config, &sse(&1, [choice(%{content: "fixture summary"}, "stop"), "[DONE]"]))
      prep = %{previous_summary: nil, projected_messages: [], kept_from_id: 2, max_tokens: 99_000}

      assert {:ok, %{summary: "fixture summary", kept_from_id: 2}} =
               Compaction.summarize(prep, %{model: @slash, thinking: "high"}, ReqLLM, config,
                 max_tokens: 99_000
               )

      assert_receive {:request, "POST", "/v1/chat/completions", ["Bearer " <> @secret], body}
      assert %{"model" => "vendor/Example-Vision", "max_tokens" => 16_384} = body
      refute Map.has_key?(body, "reasoning_effort")
      refute Map.has_key?(body, "tools")
    end

    test "missing configuration, unknown model and missing key cannot use a stock identity", %{
      config: config,
      accounts: accounts
    } do
      assert {:ok, _} = Accounts.put_api_key(accounts, %{profile() | "provider" => "openai"})

      assert {:error, :invalid_api_key_profile} =
               Accounts.put_api_key(accounts, %{profile() | "provider" => "other-router"})

      config = local(config, fn _ -> flunk("unexpected dispatch") end)
      config = Map.put(config, :stream_fn, fn _, _, _ -> flunk("stock transport invoked") end)

      assert {:error, %{code: "missing_provider_credential", retryable: false}} =
               turn(config, @slash)

      assert {:error, %{code: "invalid_model", retryable: false}} =
               turn(config, "example-router:not-listed")

      assert {:error, _} = turn(Map.delete(config, :compatible_providers), @slash)
      refute_received {:request, _, _, _, _}
    end

    test "write-only profiles survive account restart but cannot be used without registration", %{
      accounts: accounts,
      account_opts: opts
    } do
      assert {:ok, %{active: "work"}} = Accounts.put_api_key(accounts, profile())

      assert {:ok, %{active: "work"}} =
               Accounts.put_api_key(accounts, %{
                 profile()
                 | "source" => "other",
                   "api_key" => "second-key"
               })

      assert {:ok, %{active: "other"}} =
               Accounts.use_api_key(accounts, %{
                 "provider" => "example-router",
                 "source" => "other"
               })

      :ok = stop_supervised!(Accounts)
      accounts = start_supervised!({Accounts, opts})

      assert {:ok, %{api_key: "second-key"}} =
               Accounts.resolve_api_key(accounts, "example-router")

      :ok = stop_supervised!(Accounts)
      accounts = start_supervised!({Accounts, Keyword.delete(opts, :compatible_providers)})
      assert :not_configured = Accounts.resolve_api_key(accounts, "example-router")
      assert {:ok, %{providers: providers}} = Accounts.api_keys(accounts)
      refute Enum.any?(providers, &(&1.provider == "example-router"))
    end

    test "does not expose upstream errors, follow redirects or retry", %{
      config: config,
      accounts: accounts
    } do
      assert {:ok, _} = Accounts.put_api_key(accounts, profile())

      for status <- [302, 401, 429, 503, :sse, :truncated] do
        config =
          local(
            config,
            fn conn ->
              case status do
                :sse ->
                  sse(conn, [%{error: %{message: @secret, code: @secret}}])

                :truncated ->
                  sse(conn, [choice(%{content: "partial"})])

                _ ->
                  conn
                  |> put_resp_header("location", "/other")
                  |> send_resp(status, JSON.encode!(%{error: %{message: @secret, code: @secret}}))
              end
            end,
            status
          )

        log =
          capture_log(fn ->
            assert {:error, %{code: code, message: message, retryable: false}} =
                     turn(config, @slash)

            if is_integer(status), do: assert(code == "http_#{status}")
            refute code =~ @secret
            refute message =~ @secret
          end)

        refute log =~ @secret
        assert_receive {:request, "POST", "/v1/chat/completions", [_], _}
        refute_receive {:request, _, _, _, _}, 20
      end
    end

    test "killing the generation worker closes an unfinished stream", %{
      config: config,
      accounts: accounts
    } do
      assert {:ok, _} = Accounts.put_api_key(accounts, profile())
      owner = self()

      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, port} = :inet.port(listener)
      config = with_local_url(config, port)

      worker =
        start_supervised!(
          {Task,
           fn ->
             ReqLLM.stream_turn(config, request(@slash), &send(owner, {:event, &1}))
           end},
          restart: :temporary
        )

      ref = Process.monitor(worker)
      {:ok, socket} = :gen_tcp.accept(listener, 1_000)
      :ok = :inet.setopts(socket, packet: :http_bin)
      assert {:ok, {:http_request, :POST, _, {1, 1}}} = :gen_tcp.recv(socket, 0, 1_000)
      length = request_length(socket)
      :ok = :inet.setopts(socket, packet: :raw)
      assert {:ok, _} = :gen_tcp.recv(socket, length, 1_000)

      event = frame(choice(%{content: "partial"}))

      :ok =
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n",
          Integer.to_string(byte_size(event), 16),
          "\r\n",
          event,
          "\r\n"
        ])

      assert_receive {:event, %{type: :text_delta, text: "partial"}}, 1_000

      log =
        capture_log(fn ->
          Process.exit(worker, :kill)
          assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
        end)

      refute log =~ @secret
    end

    test "marks compatible provider transport failures and timeouts as retryable without leaking secrets",
         %{config: config, accounts: accounts} do
      assert {:ok, _} = Accounts.put_api_key(accounts, profile())

      # Connection refused on a closed loopback port -> retryable provider_transport_error
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, closed_port} = :inet.port(listener)
      :ok = :gen_tcp.close(listener)

      refused_config = with_local_url(config, closed_port)

      assert {:error, %{code: "provider_transport_error", message: msg, retryable: true}} =
               turn(refused_config, @slash)

      refute msg =~ @secret

      # Receive timeout -> retryable provider_timeout
      {:ok, stall_listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(stall_listener) end)
      {:ok, stall_port} = :inet.port(stall_listener)

      timeout_config =
        config
        |> with_local_url(stall_port)
        |> Map.put(:receive_timeout, 50)

      assert {:error, %{code: "provider_timeout", message: timeout_msg, retryable: true}} =
               turn(timeout_config, @slash)

      refute timeout_msg =~ @secret
    end
  end

  defp local(config, respond, child_id \\ :default) do
    owner = self()

    server =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           ip: {127, 0, 0, 1},
           port: 0,
           plug: {__MODULE__, {owner, respond}},
           thousand_island_options: [num_acceptors: 1, shutdown_timeout: 100]},
          id: {Bandit, child_id}
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    with_local_url(config, port)
  end

  defp request_length(socket, length \\ nil) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, {:http_header, _, :"Content-Length", _, value}} ->
        request_length(socket, String.to_integer(value))

      {:ok, {:http_header, _, _, _, _}} ->
        request_length(socket, length)

      {:ok, :http_eoh} when is_integer(length) ->
        length
    end
  end

  defp with_local_url(config, port) do
    # Tests substitute a loopback endpoint after parsing the real HTTPS example.
    put_in(config.compatible_providers["example-router"].base_url, "http://127.0.0.1:#{port}/v1")
  end

  def init(opts), do: opts

  def call(conn, {owner, respond}) do
    {:ok, body, conn} = read_body(conn)

    send(
      owner,
      {:request, conn.method, conn.request_path, get_req_header(conn, "authorization"),
       JSON.decode!(body)}
    )

    respond.(conn)
  end

  defp api(method, path, params, opts, token) do
    req =
      conn(method, "http://127.0.0.1" <> path, if(params, do: JSON.encode!(params), else: nil))

    response =
      %{req | req_headers: [{"host", "127.0.0.1:80"} | req.req_headers]}
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> H.HTTP.Router.call(H.HTTP.Router.init(opts))

    assert response.status == 200, response.resp_body
    refute response.resp_body =~ @secret
    JSON.decode!(response.resp_body)
  end

  defp profile, do: %{"provider" => "example-router", "source" => "work", "api_key" => @secret}

  defp request(model),
    do: %{model: model, messages: [%{role: "user", content: [%{type: "text", text: "Hi"}]}]}

  defp turn(config, model), do: ReqLLM.stream_turn(config, request(model), fn _ -> :ok end)

  defp choice(delta, reason \\ nil),
    do: %{choices: [%{index: 0, delta: delta, finish_reason: reason}]}

  defp sse(conn, frames),
    do:
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, Enum.map_join(frames, &frame/1))

  defp frame("[DONE]"), do: "data: [DONE]\n\n"
  defp frame(map), do: "data: #{JSON.encode!(map)}\n\n"
end
