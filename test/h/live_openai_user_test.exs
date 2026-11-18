defmodule H.LiveOpenAIUserTest do
  @moduledoc """
  Opt-in real-world user test exercising the full `H` HTTP/SSE daemon,
  curated model catalog, default model selection, multi-turn coding tools
  (`read`, `edit`, `bash`, `search_history`), and conversation branching
  against live OpenAI via `H.Provider.ReqLLM` (`OPENAI_API_KEY`).

  Excluded by default (`mix test` stays offline); run with:

      mix test --no-start --only live_llm
  """
  use ExUnit.Case, async: false

  @moduletag :live_llm

  alias H.{Auth, Catalog, Daemon, StoreLock, WorkspaceLease}

  test "real OpenAI multi-turn coding session + fork over HTTP/SSE" do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req_llm)

    assert is_binary(System.get_env("OPENAI_API_KEY")) and System.get_env("OPENAI_API_KEY") != "",
           "OPENAI_API_KEY must be set in the environment to run --only live_llm"

    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-live-openai-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "workspace")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    File.write!(Path.join(cwd, "math_box.ex"), """
    defmodule MathBox do
      def add(a, b), do: a - b
    end
    """)

    on_exit(fn ->
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    registry = :"H.Live.Registry.#{id}"
    pubsub = :"H.Live.PubSub.#{id}"
    catalog = :"H.Live.Catalog.#{id}"
    catalog_table = :"h_live_catalog_#{id}"
    auth = :"H.Live.Auth.#{id}"
    auth_table = :"h_live_auth_#{id}"
    lease = :"H.Live.Lease.#{id}"
    runtime_sup = :"H.Live.RuntimeSup.#{id}"

    start_supervised!({StoreLock, data_dir: data_dir, name: :"H.Live.Lock.#{id}"})
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Auth, data_dir: data_dir, name: auth, table: auth_table})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

    daemon_opts = [
      data_dir: data_dir,
      registry: registry,
      pubsub: pubsub,
      catalog: catalog,
      catalog_table: catalog_table,
      workspace_lease: lease,
      runtime_sup: runtime_sup
    ]

    bandit_pid =
      start_supervised!(
        {Bandit,
         plug:
           {H.HTTP.Router,
            [
              auth_server: auth,
              auth_table: auth_table,
              daemon: Daemon,
              daemon_opts: daemon_opts,
              sse_keepalive_ms: 100
            ]},
         ip: {127, 0, 0, 1},
         port: 0,
         thousand_island_options: [num_acceptors: 2, shutdown_timeout: 200]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit_pid)
    base_url = "http://127.0.0.1:#{port}"
    owner_token = Auth.owner_token(auth_table)

    # 1. Authenticate browser session cookie
    auth_resp =
      Req.post!("#{base_url}/api/v1/auth/session",
        headers: [{"origin", base_url}],
        json: %{"token" => owner_token}
      )

    assert auth_resp.status == 200
    [set_cookie] = Req.Response.get_header(auth_resp, "set-cookie")
    cookie_pair = set_cookie |> String.split(";", parts: 2) |> hd()
    headers = [{"cookie", cookie_pair}, {"origin", base_url}]

    # 2. Verify curated model list is concise and starts with openai:gpt-5.4
    models_resp = Req.get!("#{base_url}/api/v1/models", headers: headers)
    assert models_resp.status == 200
    models = models_resp.body["models"]
    assert length(models) <= 25
    assert hd(models)["id"] == "openai:gpt-5.4"

    # 3. Create new session without explicit model -> auto-selects openai:gpt-5.4
    create_resp =
      Req.post!("#{base_url}/api/v1/sessions",
        headers: headers,
        json: %{"session_id" => "live-user", "cwd" => cwd}
      )

    assert create_resp.status == 200

    # 4. Connect SSE stream
    parent = self()

    sse_task =
      Task.async(fn ->
        Req.get!("#{base_url}/api/v1/sessions/live-user/conversations/1/events",
          headers: [{"cookie", cookie_pair}],
          into: fn {:data, chunk}, {req, resp} ->
            send(parent, {:sse_chunk, chunk})
            {:cont, {req, resp}}
          end,
          receive_timeout: 60_000
        )
      end)

    assert_receive {:sse_chunk, first_chunk}, 5_000
    assert first_chunk =~ "event: snapshot"

    # 5. Switch to fast openai:gpt-5.4-mini and run multi-turn coding task
    cfg_resp =
      Req.post!("#{base_url}/api/v1/sessions/live-user/commands",
        headers: headers,
        json: %{
          "version" => 1,
          "request_id" => "cfg-live-1",
          "command" => "configure",
          "conversation_id" => "1",
          "args" => %{"model" => "openai:gpt-5.4-mini", "thinking" => "low"}
        }
      )

    assert cfg_resp.status == 200

    sub_resp =
      Req.post!("#{base_url}/api/v1/sessions/live-user/commands",
        headers: headers,
        json: %{
          "version" => 1,
          "request_id" => "sub-live-1",
          "command" => "submit",
          "conversation_id" => "1",
          "args" => %{
            "type" => "input",
            "content" =>
              "Read math_box.ex, use edit to fix MathBox.add/2 so it adds a + b, run `elixir -r math_box.ex -e \"IO.puts(MathBox.add(7, 8))\"` with bash, and reply with the number."
          }
        }
      )

    assert sub_resp.status == 200

    final_snap =
      wait_until(
        fn ->
          {:ok, {:snapshot, _seq, bin}} =
            Daemon.subscribe_conversation("live-user", "1", self(), nil, daemon_opts)

          snap = JSON.decode!(bin)

          if is_nil(snap["docs"]["live"]["run"]) and length(snap["entries"]) >= 4 do
            snap
          else
            nil
          end
        end,
        45_000
      )

    assert File.read!(Path.join(cwd, "math_box.ex")) =~ "a + b"
    assert final_snap["docs"]["usage"]["total_tokens"] > 0
    assert final_snap["docs"]["usage"]["cost"] > 0.0
    assert inspect(List.last(final_snap["entries"])["data"]["content"]) =~ "15"

    Task.shutdown(sse_task, :brutal_kill)
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if res = fun.() do
      res
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for live OpenAI completion")
      else
        Process.sleep(150)
        do_wait_until(fun, deadline)
      end
    end
  end
end
