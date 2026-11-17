defmodule H.FullStackIntegrationTest do
  use ExUnit.Case, async: true

  alias H.{Auth, Catalog, Daemon, StoreLock, WorkspaceLease}
  alias H.Provider.Fake

  test "end-to-end Bandit + Plug + SSE + Daemon + Session.Server + File storage + coding tools + fork" do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-fullstack-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "workspace")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    on_exit(fn ->
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    registry = :"H.FS.Registry.#{id}"
    pubsub = :"H.FS.PubSub.#{id}"
    catalog = :"H.FS.Catalog.#{id}"
    catalog_table = :"h_fs_catalog_#{id}"
    auth = :"H.FS.Auth.#{id}"
    auth_table = :"h_fs_auth_#{id}"
    lease = :"H.FS.Lease.#{id}"
    runtime_sup = :"H.FS.RuntimeSup.#{id}"
    fake_name = :"H.FS.Fake.#{id}"

    start_supervised!({StoreLock, data_dir: data_dir, name: :"H.FS.Lock.#{id}"})
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Auth, data_dir: data_dir, name: auth, table: auth_table})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

    fake =
      start_supervised!({Fake,
       name: fake_name,
       script: [
         # Turn 1: write hello.txt
         {:reply, [%{type: :thinking_delta, text: "Writing file...", metadata: %{}}],
          %{
            content: [],
            tool_calls: [
              %{
                id: "tc_write",
                name: "write",
                arguments: %{"path" => "hello.txt", "content" => "line one\nline two\n"}
              }
            ],
            finish_reason: "tool_calls"
          }},
         # Turn 2: edit hello.txt and run bash
         {:reply, [],
          %{
            content: [],
            tool_calls: [
              %{
                id: "tc_edit",
                name: "edit",
                arguments: %{
                  "path" => "hello.txt",
                  "edits" => [%{"old_text" => "line two", "new_text" => "line TWO"}]
                }
              },
              %{
                id: "tc_bash",
                name: "bash",
                arguments: %{"command" => "cat hello.txt"}
              }
            ],
            finish_reason: "tool_calls"
          }},
         # Turn 3: final answer
         {:expect,
          fn req ->
            bash_res =
              Enum.find(req.messages, fn m ->
                m.role == "tool" and m[:tool_call_id] == "tc_bash"
              end)

            assert hd(bash_res.content).text =~ "line TWO"
            true
          end,
          {:reply, [%{type: :text_delta, text: "Updated hello.txt!", metadata: %{}}],
           %{content: [%{type: "text", text: "Updated hello.txt!"}], finish_reason: "stop"}}},
         # Turn 4 (on forked branch): search_history
         {:reply, [],
          %{
            content: [],
            tool_calls: [
              %{
                id: "tc_hist",
                name: "search_history",
                arguments: %{"query" => "Create and update"}
              }
            ],
            finish_reason: "tool_calls"
          }},
         {:reply, [], %{content: [%{type: "text", text: "Found history on fork!"}]}}
       ]})

    daemon_opts = [
      data_dir: data_dir,
      registry: registry,
      pubsub: pubsub,
      catalog: catalog,
      catalog_table: catalog_table,
      workspace_lease: lease,
      runtime_sup: runtime_sup,
      provider: Fake,
      provider_config: %{server: fake},
      storage_mod: H.Storage.File,
      storage_opts: [sync: :none],
      default_model: "fake:coder"
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

    # 1. Exchange owner token for HttpOnly SameSite=Strict browser session cookie
    auth_resp =
      Req.post!("#{base_url}/api/v1/auth/session",
        headers: [{"origin", base_url}],
        json: %{"token" => owner_token}
      )

    assert auth_resp.status == 200
    [set_cookie] = Req.Response.get_header(auth_resp, "set-cookie")
    assert set_cookie =~ "HttpOnly"
    assert set_cookie =~ "SameSite=Strict"
    cookie_pair = set_cookie |> String.split(";", parts: 2) |> hd()

    browser_headers = [
      {"cookie", cookie_pair},
      {"origin", base_url}
    ]

    # 2. Create session over HTTP with cookie + Origin
    create_resp =
      Req.post!("#{base_url}/api/v1/sessions",
        headers: browser_headers,
        json: %{"session_id" => "selfhost", "cwd" => cwd}
      )

    assert create_resp.status == 200
    assert create_resp.body["session"]["session_id"] == "selfhost"

    # 3. Connect SSE stream in background task
    parent = self()

    sse_task =
      Task.async(fn ->
        Req.get!("#{base_url}/api/v1/sessions/selfhost/conversations/1/events",
          headers: [{"cookie", cookie_pair}],
          into: fn {:data, chunk}, {req, resp} ->
            send(parent, {:sse_chunk, chunk})
            {:cont, {req, resp}}
          end,
          receive_timeout: 5_000
        )
      end)

    assert_receive {:sse_chunk, initial_sse}, 1_000
    assert initial_sse =~ "event: snapshot"

    # 4. Submit coding prompt over HTTP
    sub_resp =
      Req.post!("#{base_url}/api/v1/sessions/selfhost/commands",
        headers: browser_headers,
        json: %{
          "version" => 1,
          "request_id" => "req-coding-1",
          "command" => "submit",
          "conversation_id" => "1",
          "args" => %{
            "type" => "input",
            "content" => [%{"type" => "text", "text" => "Create and update hello.txt"}]
          }
        }
      )

    assert sub_resp.status == 200
    assert sub_resp.body["request_id"] == "req-coding-1"

    # Idempotent retry of same request_id returns exact receipt
    dup_resp =
      Req.post!("#{base_url}/api/v1/sessions/selfhost/commands",
        headers: browser_headers,
        json: %{
          "version" => 1,
          "request_id" => "req-coding-1",
          "command" => "submit",
          "conversation_id" => "1",
          "args" => %{
            "type" => "input",
            "content" => [%{"type" => "text", "text" => "Create and update hello.txt"}]
          }
        }
      )

    assert dup_resp.status == 200
    assert dup_resp.body["submission_id"] == sub_resp.body["submission_id"]

    # Wait until hello.txt is written & edited and final assistant turn commits
    entries =
      wait_until(fn ->
        resp =
          Req.get!("#{base_url}/api/v1/sessions/selfhost/conversations/1/entries?order=asc",
            headers: [{"cookie", cookie_pair}]
          )

        items = resp.body["items"]

        if List.last(items)["kind"] == "assistant" and
             inspect(List.last(items)["data"]) =~ "Updated hello.txt!" do
          items
        else
          nil
        end
      end)

    assert File.read!(Path.join(cwd, "hello.txt")) == "line one\nline TWO\n"
    first_user_id = hd(entries)["id"]

    # 5. Fork from first user entry and submit on the branch
    fork_resp =
      Req.post!("#{base_url}/api/v1/sessions/selfhost/commands",
        headers: browser_headers,
        json: %{
          "version" => 1,
          "request_id" => "req-fork-1",
          "command" => "fork_and_submit",
          "conversation_id" => "1",
          "args" => %{
            "at_entry_id" => first_user_id,
            "content" => [%{"type" => "text", "text" => "Search history on branch"}]
          }
        }
      )

    assert fork_resp.status == 200
    branch_cid = fork_resp.body["conversation_id"]
    assert branch_cid != "1"

    branch_entries =
      wait_until(fn ->
        resp =
          Req.get!(
            "#{base_url}/api/v1/sessions/selfhost/conversations/#{branch_cid}/entries?order=asc",
            headers: [{"cookie", cookie_pair}]
          )

        items = resp.body["items"]

        if List.last(items)["kind"] == "assistant" and
             inspect(List.last(items)["data"]) =~ "Found history on fork!" do
          items
        else
          nil
        end
      end)

    # Branch inherited only entry 1 (`first_user_id`), not later main-branch entries!
    assert hd(branch_entries)["id"] == first_user_id
    assert length(branch_entries) == 5

    Task.shutdown(sse_task, :brutal_kill)
  end

  defp wait_until(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if res = fun.() do
      res
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for condition")
      else
        Process.sleep(15)
        do_wait_until(fun, deadline)
      end
    end
  end
end
