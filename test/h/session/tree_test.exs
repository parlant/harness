defmodule H.Session.TreeTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias H.{Auth, Catalog, Daemon, StoreLock, WorkspaceLease}
  alias H.HTTP.Router
  alias H.Provider.Fake
  alias H.Session.Tree

  defp start_isolated_env(script \\ [], extra_opts \\ []) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-session-tree-test-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "workspace")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    on_exit(fn ->
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    registry = :"H.TreeTest.Registry.#{id}"
    pubsub = :"H.TreeTest.PubSub.#{id}"
    catalog = :"H.TreeTest.Catalog.#{id}"
    catalog_table = :"h_tree_test_catalog_#{id}"
    auth = :"H.TreeTest.Auth.#{id}"
    auth_table = :"h_tree_test_auth_#{id}"
    lease = :"H.TreeTest.Lease.#{id}"
    runtime_sup = :"H.TreeTest.RuntimeSup.#{id}"
    fake_name = :"H.TreeTest.Fake.#{id}"

    start_supervised!({StoreLock, data_dir: data_dir, name: :"H.TreeTest.Lock.#{id}"})
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Auth, data_dir: data_dir, name: auth, table: auth_table})

    start_supervised!(
      {Catalog,
       data_dir: data_dir, name: catalog, table: catalog_table, pubsub: pubsub, registry: registry}
    )

    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})
    fake = start_supervised!({Fake, name: fake_name, script: script})

    opts =
      [
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
        default_model: "fake:chat"
      ]
      |> Keyword.merge(extra_opts)

    router_opts = [
      auth_server: auth,
      auth_table: auth_table,
      daemon: Daemon,
      daemon_opts: opts
    ]

    %{
      opts: opts,
      router_opts: router_opts,
      token: Auth.owner_token(auth_table),
      cwd: cwd,
      data_dir: data_dir,
      fake: fake
    }
  end

  defp cmd(req_id, command, cid, args) do
    %{
      "version" => 1,
      "request_id" => req_id,
      "conversation_id" => to_string(cid),
      "command" => command,
      "args" => args
    }
  end

  defp wait_until(fun, attempts \\ 200)

  defp wait_until(_fun, 0), do: flunk("timed out waiting for condition")

  defp wait_until(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(15)
        wait_until(fun, attempts - 1)

      false ->
        Process.sleep(15)
        wait_until(fun, attempts - 1)

      val ->
        val
    end
  end

  defp authed_get(path, router_opts, token) do
    %{conn(:get, path) | req_headers: [{"host", "127.0.0.1:80"}]}
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(Router.init(router_opts))
  end

  describe "Tree.build_native/3 preview formatting and bounds" do
    test "formats previews, flags, tool call linkage, sanitization, and truncation cleanly" do
      conversations = %{
        1 => %{id: 1, parent: nil, owner: :ownerless, entry_ids: [10, 9, 8, 7, 6, 5, 4, 3, 2]},
        20 => %{id: 20, parent: %{conversation_id: 1, at: 3}, owner: :ownerless, entry_ids: []}
      }

      huge_b64 = String.duplicate("A", 1_000)

      entries = [
        %{
          id: 2,
          conversation_id: 1,
          kind: "user",
          data: %{
            "content" => [
              %{"type" => "image", "mime_type" => "image/png", "data" => huge_b64}
            ]
          },
          created_at: 1002
        },
        %{
          id: 3,
          conversation_id: 1,
          kind: "assistant",
          data: %{
            "content" => [],
            "tool_calls" => [
              %{"id" => "call_read", "name" => "read", "arguments" => %{"path" => "lib/foo.ex"}}
            ]
          },
          created_at: 1003
        },
        %{
          id: 4,
          conversation_id: 1,
          kind: "tool_result",
          data: %{
            "tool_call_id" => "call_read",
            "name" => "read",
            "content" => [%{"type" => "text", "text" => String.duplicate("x", 5000)}],
            "is_error" => false
          },
          created_at: 1004
        },
        %{
          id: 5,
          conversation_id: 1,
          kind: "assistant",
          data: %{
            "content" => [],
            "tool_calls" => [
              %{"id" => "call_bash", "name" => "bash", "arguments" => %{"command" => "mix test"}},
              %{
                "id" => "call_sub",
                "name" => "subagent",
                "arguments" => %{"title" => "Investigate"}
              }
            ]
          },
          created_at: 1005
        },
        %{
          id: 6,
          conversation_id: 1,
          kind: "tool_result",
          data: %{
            "tool_call_id" => "call_bash",
            "name" => "bash",
            "content" => [%{"type" => "text", "text" => "failed"}],
            "is_error" => true
          },
          created_at: 1006
        },
        %{
          id: 7,
          conversation_id: 1,
          kind: "tool_result",
          data: %{
            "tool_call_id" => "call_sub",
            "name" => "subagent",
            "content" => [%{"type" => "text", "text" => "ok"}],
            "is_error" => false
          },
          created_at: 1007
        },
        %{
          id: 8,
          conversation_id: 1,
          kind: "assistant",
          data: %{
            "content" => [],
            "aborted" => true,
            "finish_reason" => "aborted"
          },
          created_at: 1008
        },
        %{
          id: 9,
          conversation_id: 1,
          kind: "user_shell",
          data: %{
            "command" => "git status\n--short",
            "include_in_context" => false,
            "is_error" => false
          },
          created_at: 1009
        },
        %{
          id: 10,
          conversation_id: 1,
          kind: "compaction",
          data: %{
            "summary" => "Summary line 1\n\tSummary line 2\x00with control chars"
          },
          created_at: 1010
        }
      ]

      {convs, nodes, truncated} = Tree.build_native(conversations, entries)
      assert truncated == false

      assert [
               %{id: "1", parent: nil, owner: "ownerless", leaf_entry_id: "10"},
               %{
                 id: "20",
                 parent: %{conversation_id: "1", at: "3"},
                 owner: "ownerless",
                 leaf_entry_id: "3"
               }
             ] = convs

      by_id = Map.new(nodes, &{&1.id, &1})

      # Attachment-only user message has no base64 leaked
      assert by_id["2"].parent_id == nil
      assert by_id["2"].preview == "[attachment]"
      assert by_id["2"].has_text == false
      refute String.contains?(by_id["2"].preview, "AAAA")

      # Tool-call-only assistant entry
      assert by_id["3"].parent_id == "2"
      assert by_id["3"].preview == "[tool: read lib/foo.ex]"
      assert by_id["3"].has_text == false
      assert by_id["3"].aborted == false
      assert by_id["3"].is_error == false

      # Tool result linked to read call
      assert by_id["4"].parent_id == "3"
      assert by_id["4"].preview == "[read: lib/foo.ex]"
      assert by_id["4"].tool_name == "read"
      assert by_id["4"].is_error == false

      # Multi-tool assistant entry
      assert by_id["5"].preview == "[tools: bash, subagent]"
      assert by_id["5"].has_text == false

      # Bash error tool result
      assert by_id["6"].preview == "[bash: mix test]"
      assert by_id["6"].tool_name == "bash"
      assert by_id["6"].is_error == true

      # Subagent tool result
      assert by_id["7"].preview == "[subagent: Investigate]"
      assert by_id["7"].tool_name == "subagent"
      assert by_id["7"].is_error == false

      # Aborted assistant entry
      assert by_id["8"].preview == "(aborted)"
      assert by_id["8"].has_text == false
      assert by_id["8"].aborted == true

      # Excluded user_shell (!!) with newline collapsed
      assert by_id["9"].preview == "!!git status --short"

      # Compaction with control chars stripped and whitespace collapsed
      assert by_id["10"].preview == "Summary line 1 Summary line 2with control chars"
      refute String.contains?(by_id["10"].preview, "\x00")

      # Truncation keeps latest N nodes in ascending order
      {_convs, capped_nodes, capped?} = Tree.build_native(conversations, entries, max_nodes: 3)
      assert capped? == true
      assert Enum.map(capped_nodes, & &1.id) == ["8", "9", "10"]
    end
  end

  describe "live, multi-branch, cold-archived native, and HTTP GET /api/v1/sessions/:sid/tree" do
    test "returns full branch ancestry, empty fork leaf, tool calls, user_shell, and survives cold archive without waking" do
      %{opts: opts, router_opts: router_opts, token: token, cwd: cwd} =
        start_isolated_env([
          {:reply, [],
           %{
             content: [],
             tool_calls: [
               %{id: "tc_1", name: "read", arguments: %{path: "hello.txt"}}
             ]
           }},
          {:reply, [], %{content: [%{type: "text", text: "Read complete on main."}]}},
          {:reply, [], %{content: [%{type: "text", text: "Answer on branch 2."}]}}
        ])

      File.write!(Path.join(cwd, "hello.txt"), "hello world\n")

      {:ok, %{session: %{session_id: sid}}} =
        Daemon.create_session(
          %{"session_id" => "tree-live-1", "cwd" => cwd, "title" => "Tree Demo"},
          opts
        )

      # 1. Submit input that triggers tool call -> tool result -> assistant reply
      assert {:ok, %{status: "placed"}} =
               Daemon.execute_command(
                 sid,
                 cmd("r1", "submit", "1", %{"type" => "input", "content" => "Inspect hello.txt"}),
                 opts
               )

      main_entries =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)
          if length(items) == 4, do: items, else: nil
        end)

      [e_user1, e_asst_tc, e_tool_res, e_asst_final] = main_entries

      # 2. Run a user_shell (!) command on main
      {:ok, %{session: _}} = Daemon.get_session_detail(sid, opts)
      {:ok, %{items: _}} = Daemon.scan_entries(sid, "1", %{}, opts)
      [{server_pid, _}] = Registry.lookup(opts[:registry], {:session, sid})
      {:ok, seq_before_shell} = H.Session.Server.get_seq(server_pid)

      assert {:ok, %{status: "placed"}} =
               Daemon.execute_command(
                 sid,
                 cmd("r_shell", "user_shell", "1", %{
                   "command" => "echo hi",
                   "include_in_context" => true,
                   "expected_seq" => seq_before_shell
                 }),
                 opts
               )

      [_, _, _, _, e_shell] =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)
          if length(items) == 5, do: items, else: nil
        end)

      # 3. Fork from e_user1 and submit a branch message
      assert {:ok, %{conversation_id: branch_cid}} =
               Daemon.execute_command(
                 sid,
                 cmd("r_fork_submit", "fork_and_submit", "1", %{
                   "at_entry_id" => e_user1.id,
                   "content" => "Take alternate branch"
                 }),
                 opts
               )

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries(sid, branch_cid, %{"order" => "asc"}, opts)
        # e_user1 + branch user + branch assistant = 3 visible entries
        if length(items) == 3, do: items, else: nil
      end)

      # 4. Fork an EMPTY branch from e_asst_final (no own entries -> leaf_entry_id == parent.at)
      assert {:ok, %{conversation_id: empty_fork_cid}} =
               Daemon.execute_command(
                 sid,
                 cmd("r_empty_fork", "fork", "1", %{"at_entry_id" => e_asst_final.id}),
                 opts
               )

      # Query live tree via H.Daemon
      assert {:ok, tree} = Daemon.get_session_tree(sid, opts)
      assert tree.truncated == false
      assert tree.session.session_id == sid
      assert tree.session.title == "Tree Demo"
      assert tree.session.loaded == true

      conv_by_id = Map.new(tree.conversations, &{&1.id, &1})
      assert conv_by_id["1"].parent == nil
      assert conv_by_id["1"].leaf_entry_id == e_shell.id

      assert conv_by_id[branch_cid].parent == %{conversation_id: "1", at: e_user1.id}
      assert conv_by_id[branch_cid].leaf_entry_id != e_user1.id

      assert conv_by_id[empty_fork_cid].parent == %{conversation_id: "1", at: e_asst_final.id}
      assert conv_by_id[empty_fork_cid].leaf_entry_id == e_asst_final.id

      node_by_id = Map.new(tree.nodes, &{&1.id, &1})

      # Main chain parent pointers
      assert node_by_id[e_user1.id].parent_id == nil
      assert node_by_id[e_user1.id].preview == "Inspect hello.txt"
      assert node_by_id[e_user1.id].has_text == true

      assert node_by_id[e_asst_tc.id].parent_id == e_user1.id
      assert node_by_id[e_asst_tc.id].preview == "[tool: read hello.txt]"
      assert node_by_id[e_asst_tc.id].has_text == false

      assert node_by_id[e_tool_res.id].parent_id == e_asst_tc.id
      assert node_by_id[e_tool_res.id].preview == "[read: hello.txt]"
      assert node_by_id[e_tool_res.id].tool_name == "read"
      assert node_by_id[e_tool_res.id].is_error == false

      assert node_by_id[e_asst_final.id].parent_id == e_tool_res.id
      assert node_by_id[e_asst_final.id].preview == "Read complete on main."
      assert node_by_id[e_asst_final.id].has_text == true

      assert node_by_id[e_shell.id].parent_id == e_asst_final.id
      assert node_by_id[e_shell.id].kind == "user_shell"
      assert node_by_id[e_shell.id].preview == "!echo hi"

      # Branch entries point back to e_user1
      branch_nodes = Enum.filter(tree.nodes, &(&1.conversation_id == branch_cid))
      assert [b_user, b_asst] = branch_nodes
      assert b_user.parent_id == e_user1.id
      assert b_user.preview == "Take alternate branch"
      assert b_asst.parent_id == b_user.id
      assert b_asst.preview == "Answer on branch 2."
      assert conv_by_id[branch_cid].leaf_entry_id == b_asst.id

      # Verify HTTP GET /api/v1/sessions/:sid/tree returns 200 JSON matching wire shape
      conn = authed_get("/api/v1/sessions/#{sid}/tree", router_opts, token)
      assert conn.status == 200
      body = JSON.decode!(conn.resp_body)
      assert body["session"]["session_id"] == sid
      assert body["truncated"] == false
      assert length(body["conversations"]) == 3
      assert length(body["nodes"]) == 7

      # Missing session returns 404
      missing_conn = authed_get("/api/v1/sessions/does-not-exist/tree", router_opts, token)
      assert missing_conn.status == 404

      # 5. Archive the session -> unloads OTP process -> get_session_tree reads cold storage without waking!
      assert {:ok, %{session: archived_session}} =
               Daemon.archive_session(sid, %{"archived" => true}, opts)

      assert archived_session.archived == true
      assert archived_session.loaded == false
      assert Registry.lookup(opts[:registry], {:session, sid}) == []

      assert {:ok, cold_tree} = Daemon.get_session_tree(sid, opts)
      assert cold_tree.session.archived == true
      assert cold_tree.session.loaded == false
      assert Registry.lookup(opts[:registry], {:session, sid}) == []

      assert cold_tree.conversations == tree.conversations
      assert cold_tree.nodes == tree.nodes
      assert cold_tree.truncated == false

      # HTTP route also serves cold archived session without waking
      cold_conn = authed_get("/api/v1/sessions/#{sid}/tree", router_opts, token)
      assert cold_conn.status == 200
      cold_body = JSON.decode!(cold_conn.resp_body)
      assert cold_body["session"]["loaded"] == false
      assert length(cold_body["nodes"]) == 7
      assert Registry.lookup(opts[:registry], {:session, sid}) == []
    end
  end

  describe "imported H.Archive session tree" do
    test "returns full tree with parent pointers and previews without starting OTP processes" do
      %{opts: opts, router_opts: router_opts, token: token, cwd: cwd} = start_isolated_env()

      header = %{
        "source" => "pi",
        "source_id" => "pi-tree-demo",
        "cwd" => cwd,
        "created_at" => 1_700_000_000_000,
        "revision" => 1,
        "size" => 100
      }

      rows = [
        %{
          "parent" => nil,
          "kind" => "user",
          "data" => %{"content" => [%{"type" => "text", "text" => "Root prompt"}]},
          "title" => "Pi Tree",
          "created_at" => 1_700_000_000_001
        },
        %{
          "parent" => 2,
          "kind" => "assistant",
          "data" => %{
            "content" => [],
            "tool_calls" => [
              %{"id" => "pi_call_1", "name" => "edit", "arguments" => %{"path" => "README.md"}}
            ]
          },
          "created_at" => 1_700_000_000_002
        },
        %{
          "parent" => 4,
          "kind" => "tool_result",
          "data" => %{
            "tool_call_id" => "pi_call_1",
            "tool_name" => "edit",
            "content" => [%{"type" => "text", "text" => "edited"}],
            "is_error" => false
          },
          "created_at" => 1_700_000_000_003
        },
        %{
          "parent" => 2,
          "kind" => "assistant",
          "data" => %{"content" => [%{"type" => "text", "text" => "Forked answer"}]},
          "created_at" => 1_700_000_000_004
        }
      ]

      ndjson =
        ([header] ++ rows ++ [%{"end" => length(rows)}])
        |> Enum.map_join("", &(JSON.encode!(&1) <> "\n"))

      upload_conn =
        %{conn(:post, "/api/v1/archives", ndjson) | req_headers: [{"host", "127.0.0.1:80"}]}
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/x-ndjson")
        |> Router.call(Router.init(router_opts))

      assert upload_conn.status == 200
      %{"session_id" => sid} = JSON.decode!(upload_conn.resp_body)

      assert {:ok, tree} = Daemon.get_session_tree(sid, opts)
      assert tree.truncated == false
      assert tree.session.status == "archived"
      assert tree.session.loaded == false
      assert Registry.lookup(opts[:registry], {:session, sid}) == []

      assert [
               %{id: "1", parent: nil, owner: "ownerless", leaf_entry_id: "6"},
               %{
                 id: "9",
                 parent: %{conversation_id: "1", at: "2"},
                 owner: "ownerless",
                 leaf_entry_id: "8"
               }
             ] = tree.conversations

      assert [
               %{
                 id: "2",
                 parent_id: nil,
                 conversation_id: "1",
                 kind: "user",
                 preview: "Root prompt"
               },
               %{
                 id: "4",
                 parent_id: "2",
                 conversation_id: "1",
                 kind: "assistant",
                 preview: "[tool: edit README.md]",
                 has_text: false
               },
               %{
                 id: "6",
                 parent_id: "4",
                 conversation_id: "1",
                 kind: "tool_result",
                 preview: "[edit: README.md]",
                 tool_name: "edit",
                 is_error: false
               },
               %{
                 id: "8",
                 parent_id: "2",
                 conversation_id: "9",
                 kind: "assistant",
                 preview: "Forked answer",
                 has_text: true
               }
             ] = tree.nodes

      http_conn = authed_get("/api/v1/sessions/#{sid}/tree", router_opts, token)
      assert http_conn.status == 200
      decoded = JSON.decode!(http_conn.resp_body)
      assert length(decoded["nodes"]) == 4
      assert length(decoded["conversations"]) == 2
    end
  end
end
