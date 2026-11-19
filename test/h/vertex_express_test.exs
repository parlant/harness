defmodule H.Provider.VertexExpressTest do
  use ExUnit.Case, async: false

  alias H.Provider.ReqLLM, as: Adapter

  describe "stream/3" do
    @tag :tmp_dir
    test "streams Vertex Express SSE using H credentials and preserves tool signatures", %{
      tmp_dir: dir
    } do
      {:ok, _} = Application.ensure_all_started(:bandit)
      {:ok, _} = Application.ensure_all_started(:finch)
      start_supervised!({Finch, ReqLLM.Application.get_finch_config()})
      start_supervised!({Task.Supervisor, name: ReqLLM.TaskSupervisor})
      owner = self()

      server =
        start_supervised!(
          {Bandit,
           ip: {127, 0, 0, 1},
           port: 0,
           plug: {__MODULE__, owner},
           thousand_island_options: [num_acceptors: 1, shutdown_timeout: 200]}
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)

      for {app, key, value} <- [
            {:harness, __MODULE__, port},
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

      path = Path.join(dir, "providers.json")

      File.write!(
        path,
        JSON.encode!(%{version: 1, google_vertex: %{api_key: "fixture-vertex-key"}})
      )

      File.chmod!(path, 0o600)
      config = %{data_dir: dir, credentials_opts: [env: %{}]}

      request = %{
        model: "google_vertex:gemini-4-argon",
        messages: [%{role: "user", content: [%{type: "text", text: "Hi"}]}]
      }

      assert {:ok, response} = Adapter.stream_turn(config, request, fn _ -> :ok end)
      assert response.content == [%{type: "text", text: "Checking"}]

      assert [%{name: "read", arguments: %{"path" => "mix.exs"}, metadata: metadata}] =
               response.tool_calls

      assert metadata.thought_signature == "fixture-signature"

      assert_receive {:request,
                      "/v1/publishers/google/models/gemini-4-argon:streamGenerateContent",
                      "alt=sse", ["fixture-vertex-key"], []}
    end
  end

  def call(%Finch.Request{} = wire) do
    %{wire | scheme: :http, host: "127.0.0.1", port: Application.fetch_env!(:harness, __MODULE__)}
  end

  def init(owner), do: owner

  def call(conn, owner) do
    send(owner, {
      :request,
      conn.request_path,
      conn.query_string,
      Plug.Conn.get_req_header(conn, "x-goog-api-key"),
      Plug.Conn.get_req_header(conn, "authorization")
    })

    data = %{
      "candidates" => [
        %{
          "content" => %{
            "role" => "model",
            "parts" => [
              %{"text" => "Checking"},
              %{
                "functionCall" => %{"name" => "read", "args" => %{"path" => "mix.exs"}},
                "thoughtSignature" => "fixture-signature"
              }
            ]
          },
          "finishReason" => "STOP"
        }
      ]
    }

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, "data: #{JSON.encode!(data)}\n\n")
  end
end
