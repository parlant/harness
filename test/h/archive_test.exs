defmodule H.ArchiveTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    suffix = System.unique_integer([:positive])
    catalog = :"archive_catalog_#{suffix}"
    table = :"archive_table_#{suffix}"
    auth_table = :"archive_auth_#{suffix}"
    start_supervised!({H.Catalog, data_dir: dir, name: catalog, table: table, pubsub: nil})
    start_supervised!({H.Auth, data_dir: dir, name: nil, table: auth_table})
    opts = [data_dir: dir, catalog: catalog, catalog_table: table, pubsub: nil]

    %{
      opts: opts,
      router: [daemon_opts: opts, auth_table: auth_table],
      token: H.Auth.owner_token(auth_table)
    }
  end

  test "upserts one archived session, keeps branch history, rejects commands and stale uploads",
       ctx do
    rows = [entry(nil, "root"), entry(2, "main"), entry(2, "fork")]
    assert %{"status" => "created", "session_id" => sid} = upload(ctx, 1, rows)
    assert %{"status" => "unchanged", "session_id" => ^sid} = upload(ctx, 1, rows)

    assert {:ok,
            %{session: %{status: "archived", active: false}, tasks: [], conversations: [_, fork]}} =
             H.Daemon.get_session_detail(sid, ctx.opts)

    assert {:ok, %{items: items}} =
             H.Daemon.scan_entries(sid, fork.id, %{"order" => "asc"}, ctx.opts)

    assert Enum.map(items, & &1["data"]["text"]) == ["root", "fork"]

    assert {:error, {:conflict, "session is archived"}} =
             H.Daemon.execute_command(sid, %{}, ctx.opts)

    assert %{"status" => "updated", "session_id" => ^sid} =
             upload(ctx, 2, rows ++ [entry(4, "new")])

    assert %{"status" => "stale"} = upload(ctx, 1, rows)
    assert request(ctx, 3, rows, ctx.token, false).status == 422

    assert [
             %{
               session_id: ^sid,
               title: "Example",
               attention: "archived",
               archived: true,
               needs_attention: false,
               loaded: false
             }
           ] = H.Daemon.list_sessions(ctx.opts)

    assert {:error, {:conflict, "session is archived"}} =
             H.Daemon.triage_session(sid, %{"needs_attention" => true}, ctx.opts)

    assert {:error, {:conflict, "session is archived"}} =
             H.Daemon.archive_session(sid, %{"archived" => false}, ctx.opts)

    assert {:error, {:conflict, "session is archived"}} =
             H.Daemon.stop_session(sid, %{}, ctx.opts)

    # Forking an imported archive into an existing cwd creates a live native session
    fork_cwd = Path.join(ctx.opts[:data_dir], "forked-work")
    File.mkdir_p!(fork_cwd)

    fork_opts =
      Keyword.merge(ctx.opts,
        registry: :"archive_reg_#{System.unique_integer([:positive])}",
        workspace_lease: :"archive_lease_#{System.unique_integer([:positive])}",
        runtime_sup: :"archive_sup_#{System.unique_integer([:positive])}",
        provider: H.Provider.Fake,
        provider_config: %{server: start_supervised!(H.Provider.Fake)},
        storage_mod: H.Storage.Memory
      )

    start_supervised!({Registry, keys: :unique, name: fork_opts[:registry]})
    start_supervised!({H.WorkspaceLease, name: fork_opts[:workspace_lease]})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: fork_opts[:runtime_sup]})

    assert {:ok, %{session: forked}} =
             H.Daemon.fork_session(
               sid,
               %{"cwd" => fork_cwd, "conversation_id" => fork.id},
               fork_opts
             )

    assert forked.status == "ok"
    assert forked.archived == false
    assert forked.loaded == true
    assert forked.needs_attention == true

    assert {:ok, %{items: forked_items}} =
             H.Daemon.scan_entries(forked.session_id, "1", %{"order" => "asc"}, fork_opts)

    assert Enum.map(forked_items, & &1.data["text"]) == ["root", "fork"]

    assert {:ok, %{items: [%{"id" => "8"}], next_cursor: "8"}} =
             H.Daemon.scan_entries(sid, "1", %{"limit" => "1"}, ctx.opts)

    assert {:ok, %{items: [%{"id" => "4"}, %{"id" => "2"}], next_cursor: nil}} =
             H.Daemon.scan_entries(sid, "1", %{"cursor" => "8"}, ctx.opts)

    assert {:ok, {:snapshot, 2, payload}} =
             H.Daemon.subscribe_conversation(sid, "1", self(), nil, ctx.opts)

    assert Enum.map(JSON.decode!(payload)["entries"], & &1["data"]["text"]) == [
             "root",
             "main",
             "new"
           ]
  end

  test "rejects unauthenticated or broken uploads and does not publish a partial archive", ctx do
    assert request(ctx, 1, [entry(nil, "root")], "bad token").status == 401
    assert request(ctx, 1, [entry(20, "unknown parent")], ctx.token).status == 422
    assert H.Daemon.list_sessions(ctx.opts) == []
  end

  test "a fork continues from stored pi calls without carrying pi IDs onto the wire", ctx do
    alias H.Daemon
    alias H.Provider.Fake
    alias ReqLLM.Providers.OpenAI.ResponsesAPI

    raw_id = "call_" <> String.duplicate("a", 39) <> "|fc_" <> String.duplicate("b", 43)

    rows = [
      entry(nil, "Find the file"),
      %{
        parent: 2,
        kind: "assistant",
        created_at: 103,
        data: %{
          role: "assistant",
          api: "openai-codex-responses",
          tool_calls: [%{id: raw_id, name: "read", arguments: %{path: "old.txt"}}]
        }
      },
      %{
        parent: 4,
        kind: "system",
        created_at: 104,
        data: %{text: "pi: model_change", source_data: %{type: "model_change"}}
      },
      %{
        parent: 6,
        kind: "tool_result",
        created_at: 105,
        data: %{tool_call_id: raw_id, name: "read", content: "historical file contents"}
      },
      %{
        parent: 8,
        kind: "system",
        created_at: 106,
        data: %{text: "pi: session_info", source_data: %{type: "session_info"}}
      }
    ]

    assert %{"session_id" => archive_id} = upload(ctx, 1, rows)
    owner = self()

    fake =
      start_supervised!(
        {Fake,
         script: [
           fn request, _emit ->
             {context, _tools} = H.Context.to_req_llm(request)
             wire = ResponsesAPI.encode_input_items(context, "gpt-6.1-sol", :openai_codex, true)
             send(owner, {:provider_wire, wire})
             {:ok, %{content: [%{type: "text", text: "I can continue."}], finish_reason: "stop"}}
           end
         ]}
      )

    id = System.unique_integer([:positive])
    registry = :"archive_resume_reg_#{id}"
    pubsub = :"archive_resume_pubsub_#{id}"
    start_supervised!({Registry, keys: :unique, name: registry})

    start_supervised!(
      Supervisor.child_spec({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
    )

    runtime = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    lease = start_supervised!({H.WorkspaceLease, name: nil})

    opts =
      Keyword.merge(ctx.opts,
        registry: registry,
        pubsub: pubsub,
        runtime_sup: runtime,
        workspace_lease: lease,
        provider: Fake,
        default_model: "fake:coder",
        provider_config: %{server: fake},
        storage_mod: H.Storage.File
      )

    assert {:ok, %{session: %{session_id: session_id}}} =
             Daemon.fork_session(archive_id, %{"cwd" => ctx.opts[:data_dir]}, opts)

    assert Fake.requests(fake) == []
    Registry.register(pubsub, {:submission, session_id, "resume"}, nil)

    assert {:ok, _} =
             Daemon.execute_command(
               session_id,
               %{
                 "version" => 1,
                 "request_id" => "resume",
                 "conversation_id" => "1",
                 "command" => "submit",
                 "args" => %{"type" => "continue"}
               },
               opts
             )

    assert_receive {:provider_wire, wire}, 2_000
    assert_receive {:submission_settled, %{status: "done", answer_text: "I can continue."}}, 2_000
    assert [_] = Fake.requests(fake)

    assert [
             %{"type" => "function_call", "call_id" => call_id},
             %{
               "type" => "function_call_output",
               "call_id" => call_id,
               "output" => "historical file contents"
             }
           ] = Enum.filter(wire, &Map.has_key?(&1, "call_id"))

    assert byte_size(call_id) <= 64
    refute call_id == raw_id

    assert {:ok, %{items: items}} = Daemon.scan_entries(session_id, "1", %{}, opts)

    assert [%{data: %{"tool_call_id" => ^raw_id}}] =
             Enum.filter(items, &(&1.kind == "tool_result"))
  end

  defp upload(ctx, rev, rows) do
    response = request(ctx, rev, rows, ctx.token)
    assert response.status == 200, response.resp_body
    JSON.decode!(response.resp_body)
  end

  test "never replaces a native session even on an ID collision", ctx do
    sid = "archive-" <> Base.encode16(:crypto.hash(:sha256, "pi\0pi-id"), case: :lower)

    assert {:ok, _} =
             H.Catalog.insert_session(ctx.opts[:catalog], %{session_id: sid, cwd: "/native"})

    assert request(ctx, 1, [entry(nil, "root")], ctx.token).status == 409
    assert [%{session_id: ^sid, cwd: "/native", status: "ok"}] = H.Daemon.list_sessions(ctx.opts)
  end

  defp request(ctx, revision, rows, token, complete? \\ true) do
    header = %{
      source: "pi",
      source_id: "pi-id",
      cwd: "/does/not/exist",
      created_at: 100,
      revision: revision,
      size: length(rows)
    }

    body =
      Enum.map_join(
        [header | rows] ++ if(complete?, do: [%{"end" => length(rows)}], else: []),
        "",
        &(JSON.encode!(&1) <> "\n")
      )

    %{conn(:post, "/api/v1/archives", body) | req_headers: [{"host", "127.0.0.1:80"}]}
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/x-ndjson")
    |> H.HTTP.Router.call(ctx.router)
  end

  defp entry(parent, text),
    do: %{parent: parent, kind: "user", data: %{text: text}, title: "Example", created_at: 102}
end
