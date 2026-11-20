defmodule H.Provider.ReqLLMTest do
  use ExUnit.Case, async: true

  alias H.Context
  alias H.Provider.ReqLLM, as: Adapter
  alias ReqLLM.{StreamChunk, StreamEvent, StreamResponse}
  alias ReqLLM.StreamResponse.MetadataHandle

  describe "stream_turn/3" do
    test "projects StreamResponse chunks, tool calls, usage, and closes stream_resp" do
      test_pid = self()
      closed_ref = make_ref()

      request =
        Context.build_request(
          [%{id: 1, kind: "user", data: %{text: "Read mix.exs"}}],
          %{model: "anthropic:claude-sonnet-4-5", system_prompt: "Sys", thinking: "high"},
          [%{name: "read", description: "Read", parameters_schema: %{"type" => "object"}}]
        )

      stream_fn = fn model, %ReqLLM.Context{} = ctx, opts ->
        send(test_pid, {:stream_called, model, ctx, opts})

        {:ok, metadata_handle} =
          MetadataHandle.start_link(fn ->
            %{
              finish_reason: :tool_calls,
              usage: %{input_tokens: 12, output_tokens: 8, total_tokens: 20}
            }
          end)

        chunks = [
          StreamChunk.thinking("Checking...", %{thought_signature: "tsig-1"}),
          StreamChunk.text("Opening file. "),
          StreamChunk.tool_call("read", %{}, %{id: "call_1", index: 0, start: true}),
          StreamChunk.meta(%{tool_call_args: %{index: 0, fragment: ~s({"path":"mix.exs"})}})
        ]

        {:ok,
         %StreamResponse{
           stream: chunks,
           metadata_handle: metadata_handle,
           cancel: fn ->
             send(test_pid, {:closed, closed_ref})
             :ok
           end,
           model: model,
           context: ctx
         }}
      end

      collector = start_supervised!({Agent, fn -> [] end})
      emit = fn ev -> Agent.update(collector, &(&1 ++ [ev])) end

      assert {:ok, response} =
               Adapter.stream_turn(
                 %{
                   stream_fn: stream_fn,
                   credentials_opts: [api_key: "sk-test-123"]
                 },
                 request,
                 emit
               )

      assert_receive {:stream_called, %LLMDB.Model{provider: :anthropic}, %ReqLLM.Context{}, opts}
      assert opts[:api_key] == "sk-test-123"
      assert opts[:reasoning_effort] == :high
      assert [%ReqLLM.Tool{name: "read"}] = opts[:tools]
      assert_receive {:closed, ^closed_ref}

      events = Agent.get(collector, & &1)
      assert Enum.any?(events, &match?(%{type: :start, provider: "anthropic"}, &1))

      assert Enum.any?(
               events,
               &match?(
                 %{
                   type: :thinking_delta,
                   text: "Checking...",
                   metadata: %{thought_signature: "tsig-1"}
                 },
                 &1
               )
             )

      assert Enum.any?(events, &match?(%{type: :text_delta, text: "Opening file. "}, &1))

      assert Enum.any?(
               events,
               &match?(
                 %{type: :tool_call_delta, id: "call_1", args_delta: ~s({"path":"mix.exs"})},
                 &1
               )
             )

      assert Enum.any?(
               events,
               &match?(%{type: :usage, usage: %{input_tokens: 12, output_tokens: 8}}, &1)
             )

      assert response.finish_reason == "tool_calls"

      assert response.content == [
               %{
                 type: "thinking",
                 text: "Checking...",
                 signature: "tsig-1",
                 metadata: %{thought_signature: "tsig-1"}
               },
               %{type: "text", text: "Opening file. "}
             ]

      assert response.tool_calls == [
               %{id: "call_1", name: "read", arguments: %{"path" => "mix.exs"}}
             ]

      assert response.usage.total_tokens == 20
    end

    test "a quiet OpenAI stream gets a five-minute idle budget and returns a retryable timeout" do
      request = Context.build_request([], %{model: "openai:gpt-5.4"})
      owner = self()

      stream_fn = fn model, ctx, opts ->
        send(owner, {:budgets, opts[:receive_timeout], opts[:max_retries]})
        {:ok, metadata} = MetadataHandle.start_link(fn -> %{} end)

        {:ok,
         %StreamResponse{
           model: model,
           context: ctx,
           metadata_handle: metadata,
           stream:
             Stream.map([:timeout], fn cause ->
               raise %ReqLLM.Error.API.Stream{reason: "Stream failed: :timeout", cause: cause}
             end),
           cancel: fn -> send(owner, :closed) end
         }}
      end

      assert {:error, %{code: "provider_timeout", retryable: true}} =
               Adapter.stream_turn(%{stream_fn: stream_fn}, request, fn _ -> :ok end)

      assert_received {:budgets, 300_000, 0}
      assert_received :closed
    end

    test "injects google_vertex provider_options from H.Credentials" do
      test_pid = self()

      request =
        Context.build_request(
          [%{id: 1, kind: "user", data: %{text: "Hi"}}],
          %{model: "google_vertex:gemini-2.5-flash"}
        )

      stream_fn = fn model, _ctx, opts ->
        send(test_pid, {:vertex_opts, opts})

        {:ok,
         [
           StreamEvent.new(:start, %{model: %{id: model.id, provider: model.provider}}),
           StreamEvent.new(:text_delta, "Hi!"),
           StreamEvent.new(:finish, %{finish_reason: :stop})
         ]}
      end

      assert {:ok, %{content: [%{type: "text", text: "Hi!"}], finish_reason: "stop"}} =
               Adapter.stream_turn(
                 %{
                   stream_fn: stream_fn,
                   credentials_opts: [
                     fetcher: fn -> {:ok, "ya29.vertex-tok"} end,
                     cache: false,
                     project_id: "gcp-proj",
                     region: "us-east5"
                   ]
                 },
                 request,
                 fn _ -> :ok end
               )

      assert_receive {:vertex_opts, opts}

      assert opts[:provider_options] == [
               access_token: "ya29.vertex-tok",
               project_id: "gcp-proj",
               region: "us-east5"
             ]
    end

    @tag :tmp_dir
    test "builds a Codex OAuth stream request and preserves reasoning for the next turn", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "providers.json")

      File.write!(
        path,
        JSON.encode!(%{
          version: 1,
          default_model: "openai_codex:gpt-6.1-sol",
          openai_codex: %{
            access_token: "fake-oauth",
            account_id: "account-test",
            expires_at_ms: 1000,
            transport: "websocket"
          }
        })
      )

      File.chmod!(path, 0o600)

      config = %{data_dir: dir, credentials_opts: [env: %{}, now_fn: fn -> 100 end]}
      assert Adapter.default_model(config) == "openai_codex:gpt-6.1-sol"

      models = H.Daemon.list_models(data_dir: dir, provider_config: Map.delete(config, :data_dir))
      assert [%{id: "openai_codex:gpt-6.1-sol"} | _] = models
      assert Enum.all?(models, &(&1.provider == "openai_codex"))

      detail = %ReqLLM.Message.ReasoningDetails{
        provider: :openai_codex,
        format: "openai-responses-v1",
        encrypted?: true,
        signature: "opaque-reasoning-item",
        index: 0,
        provider_data: %{"id" => "rs_demo"}
      }

      stream_fn = fn model, ctx, opts ->
        assert %LLMDB.Model{provider: :openai_codex, id: "gpt-6.1-sol"} = model
        assert opts[:provider_options][:openai_stream_transport] == :websocket
        assert {:ok, wire} = ReqLLM.Providers.OpenAICodex.attach_stream(model, ctx, opts, nil)
        assert wire.host == "chatgpt.com"
        assert wire.path == "/backend-api/codex/responses"
        assert {"authorization", "Bearer fake-oauth"} in wire.headers
        assert {"chatgpt-account-id", "account-test"} in wire.headers

        assert {:ok, websocket} =
                 ReqLLM.Providers.OpenAICodex.attach_websocket_stream(model, ctx, opts)

        assert websocket.url == "wss://chatgpt.com/backend-api/codex/responses"
        assert {"authorization", "Bearer fake-oauth"} in websocket.headers

        assert %{"model" => "gpt-6.1-sol", "store" => false, "stream" => true} =
                 JSON.decode!(IO.iodata_to_binary(wire.body))

        {:ok, handle} =
          MetadataHandle.start_link(fn ->
            %{finish_reason: :stop, reasoning_details: [detail]}
          end)

        {:ok,
         %StreamResponse{
           model: model,
           stream: [StreamChunk.text("Done")],
           metadata_handle: handle,
           context: ctx,
           cancel: fn -> :ok end
         }}
      end

      request =
        Context.build_request([%{id: 1, kind: "user", data: %{text: "Hi"}}], %{
          model: "openai-codex:gpt-6.1-sol",
          thinking: "high"
        })

      assert {:ok,
              %{
                content: [%{text: "Done"}],
                reasoning_details: [%{signature: "opaque-reasoning-item"}]
              }} =
               Adapter.stream_turn(
                 Map.put(config, :stream_fn, stream_fn),
                 request,
                 fn _ -> :ok end
               )
    end

    test "builds Codex GPT-6.2 Responses Lite requests with OAuth and function tools" do
      for {provider, id} <- [
            {"openai_codex", "gpt-6.2-sol"},
            {"openai-codex", "gpt-6.2-astra"}
          ] do
        owner = self()

        request =
          Context.build_request(
            [%{id: 1, kind: "user", data: %{text: "Read a file"}}],
            %{model: "#{provider}:#{id}", system_prompt: "Be brief", thinking: "high"},
            [
              %{
                name: "read",
                description: "Read a file",
                parameters_schema: %{"type" => "object"}
              }
            ]
          )

        config = %{
          credentials: %{access_token: "fixture-oauth", account_id: "fixture-account"},
          stream_fn: fn model, ctx, opts ->
            send(owner, {:codex_request, model, ctx, opts})
            {:ok, [%StreamEvent{type: :text_delta, data: "Done"}]}
          end
        }

        assert {:ok, %{content: [%{text: "Done"}]}} =
                 Adapter.stream_turn(config, request, fn _ -> :ok end)

        assert_receive {:codex_request, %LLMDB.Model{provider: :openai_codex, id: ^id} = model,
                        ctx, opts}

        codex = ReqLLM.Providers.OpenAICodex
        assert {:ok, sse} = codex.attach_stream(model, ctx, opts, nil)
        assert sse.host == "chatgpt.com"
        assert sse.path == "/backend-api/codex/responses"
        assert {:ok, websocket} = codex.attach_websocket_stream(model, ctx, opts)
        assert websocket.url == "wss://chatgpt.com/backend-api/codex/responses"

        for headers <- [sse.headers, websocket.headers] do
          assert {"authorization", "Bearer fixture-oauth"} in headers
          assert {"chatgpt-account-id", "fixture-account"} in headers
          assert {"x-openai-internal-codex-responses-lite", "true"} in headers
        end

        sse_body = JSON.decode!(IO.iodata_to_binary(sse.body))
        assert [websocket_message] = websocket.initial_messages
        assert JSON.decode!(websocket_message) == Map.put(sse_body, "type", "response.create")

        assert sse_body["model"] == id
        assert sse_body["store"] == false
        assert sse_body["stream"] == true
        assert sse_body["parallel_tool_calls"] == false
        assert sse_body["reasoning"] == %{"effort" => "high", "context" => "all_turns"}

        assert [
                 %{
                   "type" => "additional_tools",
                   "role" => "developer",
                   "tools" => [%{"type" => "function", "name" => "read"}]
                 },
                 %{
                   "type" => "message",
                   "role" => "developer",
                   "content" => [%{"type" => "input_text", "text" => "Be brief"}]
                 },
                 %{
                   "role" => "user",
                   "content" => [%{"type" => "input_text", "text" => "Read a file"}]
                 }
               ] = sse_body["input"]

        refute Map.has_key?(sse_body, "tools")
        refute Map.has_key?(sse_body, "instructions")
      end
    end

    test "builds Gemini 4 requests against both Vertex endpoints, never AI Studio" do
      for id <- ~w(gemini-4-hydrogen gemini-4-argon gemini-4-carbon), mode <- [:adc, :key] do
        request =
          Context.build_request(
            [%{id: 1, kind: "user", data: %{text: "Hi"}}],
            %{model: "google-vertex:" <> id, thinking: "high"},
            [
              %{
                name: "read",
                description: "Read",
                parameters_schema: %{
                  "type" => "object",
                  "properties" => %{"path" => %{"type" => "string"}}
                }
              }
            ]
          )

        {assembler, credentials_opts, host, path, auth} =
          case mode do
            :adc ->
              {ReqLLM.Providers.GoogleVertex,
               [
                 access_token: "test-adc-token",
                 project_id: "test-project",
                 region: "us-east5",
                 env: %{}
               ], "us-east5-aiplatform.googleapis.com",
               "/v1/projects/test-project/locations/us-east5/publishers/google/models/",
               {"authorization", "Bearer test-adc-token"}}

            :key ->
              {H.Provider.VertexExpress, [env: %{"GOOGLE_VERTEX_API_KEY" => "test-vertex-key"}],
               "aiplatform.googleapis.com", "/v1/publishers/google/models/",
               {"x-goog-api-key", "test-vertex-key"}}
          end

        stream_fn = fn model, ctx, opts ->
          assert %LLMDB.Model{provider: :google_vertex, id: ^id, limits: %{output: 65536}} = model
          assert {:ok, wire} = assembler.attach_stream(model, ctx, opts, nil)
          assert wire.host == host
          assert wire.path == path <> id <> ":streamGenerateContent"
          headers = Map.new(wire.headers, fn {k, v} -> {String.downcase(k), v} end)
          assert Map.get(headers, elem(auth, 0)) == elem(auth, 1)

          if mode == :key do
            refute Map.has_key?(headers, "authorization")
            assert wire.query == "alt=sse"
          end

          assert %{
                   "contents" => [%{"role" => "user", "parts" => [%{"text" => "Hi"}]}],
                   "tools" => [%{"functionDeclarations" => [%{"name" => "read"}]}],
                   "generationConfig" => %{
                     "maxOutputTokens" => 65536,
                     "thinkingConfig" => %{"thinkingLevel" => "high"}
                   }
                 } = JSON.decode!(IO.iodata_to_binary(wire.body))

          {:ok,
           [
             StreamEvent.new(:text_delta, "Done"),
             StreamEvent.new(:finish, %{finish_reason: :stop})
           ]}
        end

        assert {:ok, %{content: [%{text: "Done"}]}} =
                 Adapter.stream_turn(
                   %{stream_fn: stream_fn, credentials_opts: credentials_opts},
                   request,
                   fn _ -> :ok end
                 )
      end
    end

    test "handles cancelled streams and closes StreamResponse" do
      test_pid = self()
      closed_ref = make_ref()

      request = %{
        model: %{provider: :openai, id: "gpt-4o-mini"},
        messages: [%{role: "user", content: [%{type: "text", text: "Cancel me"}]}],
        tools: []
      }

      stream_fn = fn model, ctx, _opts ->
        {:ok, metadata_handle} =
          MetadataHandle.start_link(fn ->
            %{finish_reason: :cancelled, usage: %{input_tokens: 5, output_tokens: 2}}
          end)

        {:ok,
         %StreamResponse{
           stream: [StreamChunk.text("Half")],
           metadata_handle: metadata_handle,
           cancel: fn ->
             send(test_pid, {:closed, closed_ref})
             :ok
           end,
           model: model,
           context: ctx
         }}
      end

      assert {:cancelled, %{partial_content: [%{type: "text", text: "Half"}], usage: usage}} =
               Adapter.stream_turn(%{stream_fn: stream_fn}, request, fn _ -> :ok end)

      assert usage.input_tokens == 5
      assert_receive {:closed, ^closed_ref}
    end

    test "normalizes and redacts errors and closes StreamResponse" do
      test_pid = self()
      closed_ref = make_ref()

      request = %{
        model: %{provider: :anthropic, id: "claude-sonnet-4-5"},
        messages: [%{role: "user", content: [%{type: "text", text: "Fail"}]}],
        tools: []
      }

      stream_fn = fn model, ctx, _opts ->
        {:ok, metadata_handle} =
          MetadataHandle.start_link(fn ->
            %{
              error:
                ReqLLM.Error.API.Request.exception(
                  status: 429,
                  reason: "Rate limit for Bearer secret-tok-999",
                  retryable: true
                )
            }
          end)

        {:ok,
         %StreamResponse{
           stream: [],
           metadata_handle: metadata_handle,
           cancel: fn ->
             send(test_pid, {:closed, closed_ref})
             :ok
           end,
           model: model,
           context: ctx
         }}
      end

      assert {:error, %{code: "http_429", message: msg, retryable: true}} =
               Adapter.stream_turn(%{stream_fn: stream_fn}, request, fn _ -> :ok end)

      refute msg =~ "secret-tok-999"
      assert msg =~ "[REDACTED]"
      assert_receive {:closed, ^closed_ref}
    end

    test "closes StreamResponse when worker exits mid-stream on abort" do
      test_pid = self()
      closed_ref = make_ref()
      gate_ref = make_ref()

      request = %{
        model: %{provider: :openai, id: "gpt-4o-mini"},
        messages: [%{role: "user", content: [%{type: "text", text: "Kill mid-stream"}]}],
        tools: []
      }

      stream_fn = fn model, ctx, _opts ->
        {:ok, metadata_handle} = MetadataHandle.start_link(fn -> %{} end)

        gated_stream =
          Stream.resource(
            fn -> :start end,
            fn
              :start ->
                {[StreamChunk.text("chunk1")], :gate}

              :gate ->
                send(test_pid, {:stream_gated, gate_ref})

                receive do
                  :never -> {:halt, :done}
                end
            end,
            fn _ -> :ok end
          )

        {:ok,
         %StreamResponse{
           stream: gated_stream,
           metadata_handle: metadata_handle,
           cancel: fn ->
             send(test_pid, {:closed_on_kill, closed_ref})
             :ok
           end,
           model: model,
           context: ctx
         }}
      end

      {worker_pid, monitor_ref} =
        spawn_monitor(fn ->
          Adapter.stream_turn(%{stream_fn: stream_fn}, request, fn _ -> :ok end)
        end)

      assert_receive {:stream_gated, ^gate_ref}, 1_000
      # Untrappable :kill still closes StreamResponse via monitor watcher
      Process.exit(worker_pid, :kill)
      assert_receive {:DOWN, ^monitor_ref, :process, ^worker_pid, :killed}, 1_000
      assert_receive {:closed_on_kill, ^closed_ref}, 1_000
    end
  end

  describe "list_models/1" do
    test "returns curated JSON-serializable catalog maps from LLMDB" do
      models = Adapter.list_models(%{provider: :anthropic})

      assert models != []
      assert length(models) <= 10
      first = hd(models)

      assert Map.keys(first) |> Enum.sort() == [
               :context_window,
               :id,
               :max_output_tokens,
               :name,
               :provider,
               :supports_reasoning,
               :supports_tools
             ]

      assert first.id == "anthropic:claude-sonnet-5-5"
      assert first.provider == "anthropic"
      assert first.supports_tools == true
      assert first.supports_reasoning == true
      assert is_binary(JSON.encode!(models))
    end

    test "lists bundled GPT-6.2 Codex models with Codex limits and capabilities" do
      assert [
               %{id: "openai_codex:gpt-6.1-sol"},
               %{
                 id: "openai_codex:gpt-6.2-sol",
                 provider: "openai_codex",
                 context_window: 500_000,
                 max_output_tokens: 128_000,
                 supports_tools: true,
                 supports_reasoning: true
               },
               %{
                 id: "openai_codex:gpt-6.2-astra",
                 provider: "openai_codex",
                 context_window: 272_000,
                 max_output_tokens: 128_000,
                 supports_tools: true,
                 supports_reasoning: true
               }
               | _
             ] = Adapter.list_models(%{provider: "openai-codex", credentials_opts: [env: %{}]})
    end

    test "lists all three Gemini 4 Vertex models" do
      models = Adapter.list_models(%{provider: "google-vertex"})

      assert Enum.map(Enum.take(models, 3), & &1.id) ==
               ~w(google_vertex:gemini-4-hydrogen google_vertex:gemini-4-carbon google_vertex:gemini-4-argon)

      assert Enum.all?(Enum.take(models, 3), &(&1.supports_tools and &1.supports_reasoning))
    end

    test "filters model list to configured providers and selects default_model/1" do
      models =
        Adapter.list_models(%{
          credentials_opts: [env: %{"OPENAI_API_KEY" => "sk-test-openai"}]
        })

      assert Enum.all?(models, &(&1.provider == "openai"))
      assert hd(models).id == "openai:gpt-5.4"

      assert Adapter.default_model(%{
               credentials_opts: [env: %{"OPENAI_API_KEY" => "sk-test-openai"}]
             }) == "openai:gpt-5.4"
    end
  end
end
