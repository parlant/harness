defmodule H.CatalogLineageTest do
  use ExUnit.Case, async: true

  alias H.{Catalog, Daemon}
  alias H.Provider.Fake

  defp start_isolated_env do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-lineage-test-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    sub_dir = Path.join(cwd, "nested")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(sub_dir)

    registry = :"H.LineageTest.Registry.#{id}"
    pubsub = :"H.LineageTest.PubSub.#{id}"
    catalog = :"H.LineageTest.Catalog.#{id}"
    catalog_table = :"h_lineage_test_catalog_#{id}"
    lease = :"H.LineageTest.Lease.#{id}"
    runtime_sup = :"H.LineageTest.RuntimeSup.#{id}"
    fake_name = :"H.LineageTest.Fake.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})

    start_supervised!(
      {Catalog, data_dir: data_dir, name: catalog, table: catalog_table, pubsub: pubsub}
    )

    start_supervised!({H.WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})
    fake = start_supervised!({Fake, script: [], name: fake_name})

    on_exit(fn -> File.rm_rf(tmp_root) end)

    opts = [
      registry: registry,
      pubsub: pubsub,
      catalog: catalog,
      catalog_table: catalog_table,
      workspace_lease: lease,
      runtime_sup: runtime_sup,
      data_dir: data_dir,
      provider: Fake,
      provider_config: %{server: fake},
      storage_mod: H.Storage.File,
      storage_opts: [sync: :none],
      default_model: "fake:chat"
    ]

    %{
      opts: opts,
      cwd: cwd,
      sub_dir: sub_dir,
      data_dir: data_dir,
      catalog: catalog,
      table: catalog_table,
      fake: fake,
      tmp_root: tmp_root
    }
  end

  defp cmd(req_id, command, cid, args) do
    %{
      "version" => 1,
      "request_id" => req_id,
      "command" => command,
      "conversation_id" => cid,
      "args" => args
    }
  end

  describe "Catalog parent & role validation and persistence" do
    test "validates parent and role, rejects self-parent and invalid role, and preserves immutability on report_runtime" do
      env = start_isolated_env()

      assert {:ok, root} =
               Catalog.put_session(env.catalog, %{
                 session_id: "root-1",
                 cwd: env.cwd,
                 title: "Root"
               })

      assert Catalog.root_session?(root)
      assert root.parent == nil
      assert root.role == nil

      assert {:error, "parent: cannot reference self"} =
               Catalog.put_session(env.catalog, %{
                 session_id: "self-loop",
                 cwd: env.cwd,
                 parent: %{session_id: "self-loop"}
               })

      assert {:error, "role: must not contain control characters"} =
               Catalog.put_session(env.catalog, %{
                 session_id: "bad-role-ctrl",
                 cwd: env.cwd,
                 role: "sub\nagent"
               })

      assert {:error, "role: must be at most 64 characters"} =
               Catalog.put_session(env.catalog, %{
                 session_id: "bad-role-long",
                 cwd: env.cwd,
                 role: String.duplicate("a", 65)
               })

      assert {:ok, blank_role} =
               Catalog.put_session(env.catalog, %{
                 session_id: "blank-role",
                 cwd: env.cwd,
                 role: "   "
               })

      assert blank_role.role == nil

      assert {:ok, child} =
               Catalog.put_session(env.catalog, %{
                 session_id: "child-1",
                 cwd: env.cwd,
                 parent: %{
                   "session_id" => "root-1",
                   "conversation_id" => "2",
                   "at_entry_id" => "42",
                   "task_id" => 43,
                   "depth" => 1
                 },
                 role: "  subagent  "
               })

      refute Catalog.root_session?(child)

      assert child.parent == %{
               session_id: "root-1",
               conversation_id: 2,
               at_entry_id: 42,
               task_id: 43,
               depth: 1
             }

      assert child.role == "subagent"

      wired = Catalog.wire_session(child)

      assert wired.parent == %{
               session_id: "root-1",
               conversation_id: "2",
               at_entry_id: "42",
               task_id: "43",
               depth: 1
             }

      assert wired.role == "subagent"

      # report_runtime must never overwrite immutable parent or role
      assert {:ok, updated} =
               Catalog.report_runtime(env.catalog, "child-1", %{
                 "active" => true,
                 "parent" => nil,
                 "role" => "hijacked"
               })

      assert updated.parent == child.parent
      assert updated.role == "subagent"
      assert updated.active == true

      # Reloading Catalog from sessions.json round-trips parent & role cleanly
      stop_supervised!(Catalog)

      reloaded_table = :"#{env.table}_reloaded"
      reloaded_server = :"#{env.catalog}.Reloaded"

      start_supervised!(
        {Catalog,
         data_dir: env.data_dir,
         name: reloaded_server,
         table: reloaded_table,
         pubsub: env.opts[:pubsub]}
      )

      assert {:ok, reloaded_child} = Catalog.get_session("child-1", reloaded_table)
      assert reloaded_child.parent == child.parent
      assert reloaded_child.role == "subagent"

      assert {:ok, reloaded_root} = Catalog.get_session("root-1", reloaded_table)
      assert reloaded_root.parent == nil
      assert reloaded_root.role == nil
    end

    test "decodes legacy sessions.json without parent/role fields as nil" do
      id = System.unique_integer([:positive])
      tmp_dir = Path.join(System.tmp_dir!(), "h-legacy-lineage-#{id}")
      catalog_dir = Path.join(tmp_dir, "catalog")
      File.mkdir_p!(catalog_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      legacy_json =
        JSON.encode!(%{
          "version" => 1,
          "sessions" => [
            %{
              "session_id" => "legacy-root",
              "cwd" => "/tmp",
              "created_at" => 100,
              "updated_at" => 200
            }
          ]
        })

      File.write!(Path.join(catalog_dir, "sessions.json"), legacy_json)

      table = :"h_legacy_lineage_#{id}"
      server = :"H.LegacyLineage.#{id}"
      start_supervised!({Catalog, data_dir: tmp_dir, name: server, table: table, pubsub: nil})

      assert {:ok, entry} = Catalog.get_session("legacy-root", table)
      assert entry.parent == nil
      assert entry.role == nil
      assert Catalog.root_session?(entry)
    end
  end

  describe "Daemon.create_session/2 parent lineage, step anchoring, depth & attach conflicts" do
    test "rejects missing parent, self-parent, invalid depth, and invisible at_entry_id" do
      env = start_isolated_env()

      assert {:error, {:bad_request, "parent session not found: nonexistent"}} =
               Daemon.create_session(
                 %{
                   "session_id" => "orphan-1",
                   "cwd" => env.cwd,
                   "parent" => %{"session_id" => "nonexistent"}
                 },
                 env.opts
               )

      assert {:error, {:bad_request, "session cannot be its own parent"}} =
               Daemon.create_session(
                 %{
                   "session_id" => "self-1",
                   "cwd" => env.cwd,
                   "parent" => %{"session_id" => "self-1"}
                 },
                 env.opts
               )

      assert {:ok, %{session: root}} =
               Daemon.create_session(%{"session_id" => "root-a", "cwd" => env.cwd}, env.opts)

      assert root.parent == nil
      assert root.role == nil

      # When parent conversation has no entries, auto-resolved at_entry_id is nil
      assert {:ok, %{session: empty_child}} =
               Daemon.create_session(
                 %{
                   "session_id" => "child-empty",
                   "cwd" => env.cwd,
                   "parent" => %{"session_id" => "root-a"}
                 },
                 env.opts
               )

      assert empty_child.parent == %{
               session_id: "root-a",
               conversation_id: "1",
               at_entry_id: nil,
               task_id: nil,
               depth: 1
             }

      assert empty_child.role == "subagent"

      # Explicit at_entry_id that does not exist in parent conversation is rejected
      assert {:error, {:bad_request, "parent at_entry_id not visible"}} =
               Daemon.create_session(
                 %{
                   "session_id" => "child-bad-entry",
                   "cwd" => env.cwd,
                   "parent" => %{"session_id" => "root-a", "at_entry_id" => "999"}
                 },
                 env.opts
               )

      # Depth limit enforcement across multi-level chains
      opts_depth2 = Keyword.put(env.opts, :max_subagent_depth_hard, 2)

      assert {:ok, %{session: depth2}} =
               Daemon.create_session(
                 %{
                   "session_id" => "grandchild-1",
                   "cwd" => env.cwd,
                   "parent" => %{"session_id" => "child-empty"},
                   "role" => "reviewer"
                 },
                 opts_depth2
               )

      assert depth2.parent.depth == 2
      assert depth2.parent.session_id == "child-empty"
      assert depth2.role == "reviewer"

      assert {:error, {:bad_request, "subsession depth limit exceeded"}} =
               Daemon.create_session(
                 %{
                   "session_id" => "great-grandchild-1",
                   "cwd" => env.cwd,
                   "parent" => %{"session_id" => "grandchild-1"}
                 },
                 opts_depth2
               )
    end

    test "auto-resolves at_entry_id to parent's latest visible entry, validates explicit visibility, and persists in session_meta" do
      env = start_isolated_env()

      {:ok, _} = Daemon.create_session(%{"session_id" => "parent-s", "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          "parent-s",
          cmd("w-1", "submit", "1", %{"type" => "write", "content" => "first note"}),
          env.opts
        )

      {:ok, _} =
        Daemon.execute_command(
          "parent-s",
          cmd("w-2", "submit", "1", %{"type" => "write", "content" => "second note"}),
          env.opts
        )

      {:ok, %{items: [latest, first]}} =
        Daemon.scan_entries("parent-s", "1", %{"order" => "desc", "limit" => "10"}, env.opts)

      # Auto-resolved at_entry_id should match latest visible entry
      assert {:ok, %{session: auto_child}} =
               Daemon.create_session(
                 %{
                   "session_id" => "child-auto",
                   "cwd" => env.cwd,
                   "parent" => %{"session_id" => "parent-s", "task_id" => "77"}
                 },
                 env.opts
               )

      assert auto_child.parent == %{
               session_id: "parent-s",
               conversation_id: "1",
               at_entry_id: latest.id,
               task_id: "77",
               depth: 1
             }

      assert auto_child.role == "subagent"

      # Explicit earlier visible entry succeeds
      assert {:ok, %{session: explicit_child}} =
               Daemon.create_session(
                 %{
                   "session_id" => "child-explicit",
                   "cwd" => env.cwd,
                   "parent" => %{
                     "session_id" => "parent-s",
                     "conversation_id" => "1",
                     "at_entry_id" => first.id
                   }
                 },
                 env.opts
               )

      assert explicit_child.parent.at_entry_id == first.id

      # Verify parent & role persisted in session_meta inside session store AND survives reopen
      [{child_pid, _}] = Registry.lookup(env.opts[:registry], {:session, "child-auto"})
      {:ok, detail} = H.Session.Server.get_detail(child_pid)

      expected_meta_parent = %{
        session_id: "parent-s",
        conversation_id: 1,
        at_entry_id: String.to_integer(latest.id),
        task_id: 77,
        depth: 1
      }

      assert detail.session_meta.parent == expected_meta_parent
      assert detail.session_meta.role == "subagent"

      # Stop child server and reopen from disk to verify session_meta round-trip
      ref = Process.monitor(child_pid)

      for {:undefined, sup_pid, :supervisor, [H.Session.Supervisor]} <-
            DynamicSupervisor.which_children(env.opts[:runtime_sup]) do
        if is_pid(sup_pid), do: DynamicSupervisor.terminate_child(env.opts[:runtime_sup], sup_pid)
      end

      assert_receive {:DOWN, ^ref, :process, ^child_pid, _reason}

      assert {:ok, _} = Daemon.get_session_detail("child-auto", env.opts)
      [{reopened_pid, _}] = Registry.lookup(env.opts[:registry], {:session, "child-auto"})
      {:ok, reopened_detail} = H.Session.Server.get_detail(reopened_pid)
      assert reopened_detail.session_meta.parent == expected_meta_parent
      assert reopened_detail.session_meta.role == "subagent"

      # Fork parent at `first` and ensure `latest` is NOT visible in the forked conversation
      {:ok, %{conversation_id: fork_cid}} =
        Daemon.execute_command(
          "parent-s",
          cmd("f-1", "fork", "1", %{"at_entry_id" => first.id}),
          env.opts
        )

      assert {:error, {:bad_request, "parent at_entry_id not visible"}} =
               Daemon.create_session(
                 %{
                   "session_id" => "child-fork-bad",
                   "cwd" => env.cwd,
                   "parent" => %{
                     "session_id" => "parent-s",
                     "conversation_id" => fork_cid,
                     "at_entry_id" => latest.id
                   }
                 },
                 env.opts
               )

      assert {:ok, %{session: fork_child}} =
               Daemon.create_session(
                 %{
                   "session_id" => "child-fork-ok",
                   "cwd" => env.cwd,
                   "parent" => %{"session_id" => "parent-s", "conversation_id" => fork_cid}
                 },
                 env.opts
               )

      assert fork_child.parent.conversation_id == fork_cid
      assert fork_child.parent.at_entry_id == first.id
    end

    test "idempotent attach allows omitting parent or matching parent, and returns 409 conflict on mismatched parent" do
      env = start_isolated_env()

      {:ok, _} = Daemon.create_session(%{"session_id" => "root-1", "cwd" => env.cwd}, env.opts)
      {:ok, _} = Daemon.create_session(%{"session_id" => "root-2", "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          "root-1",
          cmd("w-1", "submit", "1", %{"type" => "write", "content" => "step 1"}),
          env.opts
        )

      {:ok, _} =
        Daemon.execute_command(
          "root-1",
          cmd("w-2", "submit", "1", %{"type" => "write", "content" => "step 2"}),
          env.opts
        )

      {:ok, %{items: [e2, e1]}} =
        Daemon.scan_entries("root-1", "1", %{"order" => "desc", "limit" => "10"}, env.opts)

      {:ok, %{session: child}} =
        Daemon.create_session(
          %{
            "session_id" => "sub-attach",
            "cwd" => env.cwd,
            "parent" => %{"session_id" => "root-1", "at_entry_id" => e1.id}
          },
          env.opts
        )

      # Attaching without parent key succeeds (e.g. `hi -s sub-attach`)
      assert {:ok, %{session: attached_omit}} =
               Daemon.create_session(%{"session_id" => "sub-attach", "cwd" => env.cwd}, env.opts)

      assert attached_omit.parent == child.parent

      # Attaching with matching parent succeeds
      assert {:ok, %{session: attached_same}} =
               Daemon.create_session(
                 %{
                   "session_id" => "sub-attach",
                   "cwd" => env.cwd,
                   "parent" => %{"session_id" => "root-1", "at_entry_id" => e1.id}
                 },
                 env.opts
               )

      assert attached_same.parent == child.parent

      # Attaching with explicit parent: nil conflicts
      assert {:error, {:conflict, "session already exists with different parent"}} =
               Daemon.create_session(
                 %{"session_id" => "sub-attach", "cwd" => env.cwd, "parent" => nil},
                 env.opts
               )

      # Attaching with different parent session_id conflicts
      assert {:error, {:conflict, "session already exists with different parent"}} =
               Daemon.create_session(
                 %{
                   "session_id" => "sub-attach",
                   "cwd" => env.cwd,
                   "parent" => %{"session_id" => "root-2"}
                 },
                 env.opts
               )

      # Attaching with different at_entry_id conflicts
      assert {:error, {:conflict, "session already exists with different parent"}} =
               Daemon.create_session(
                 %{
                   "session_id" => "sub-attach",
                   "cwd" => env.cwd,
                   "parent" => %{"session_id" => "root-1", "at_entry_id" => e2.id}
                 },
                 env.opts
               )

      # Attaching to a root session with an explicit non-nil parent conflicts
      assert {:error, {:conflict, "session already exists with different parent"}} =
               Daemon.create_session(
                 %{
                   "session_id" => "root-2",
                   "cwd" => env.cwd,
                   "parent" => %{"session_id" => "root-1"}
                 },
                 env.opts
               )
    end
  end

  describe "root-first filtering in annotate_directories, browse_workspace, and list_sessions" do
    test "excludes subsessions by default in annotate_directories and browse_workspace, and supports include_subsessions filter in list_sessions" do
      env = start_isolated_env()

      {:ok, _} =
        Catalog.put_session(env.catalog, %{
          session_id: "root-cwd",
          cwd: env.cwd,
          title: "Root Work",
          updated_at: 100
        })

      {:ok, _} =
        Catalog.put_session(env.catalog, %{
          session_id: "sub-cwd",
          cwd: env.cwd,
          title: "Sub Work",
          parent: %{session_id: "root-cwd", conversation_id: 1, depth: 1},
          role: "subagent",
          active: true,
          updated_at: 200
        })

      {:ok, _} =
        Catalog.put_session(env.catalog, %{
          session_id: "sub-nested",
          cwd: env.sub_dir,
          title: "Sub Nested",
          parent: %{session_id: "root-cwd", conversation_id: 1, depth: 1},
          role: "subagent",
          active: true,
          updated_at: 300
        })

      # annotate_directories excludes subsessions by default
      [nested_dir_default] =
        Catalog.annotate_directories("host", [%{name: "nested", path: env.sub_dir}],
          table: env.table
        )

      assert nested_dir_default.direct_session_count == 0
      assert nested_dir_default.subtree_session_count == 0
      assert nested_dir_default.active_session_count == 0
      assert nested_dir_default.latest_session == nil

      # annotate_directories includes subsessions when explicitly opted in
      [nested_dir_with_subs] =
        Catalog.annotate_directories("host", [%{name: "nested", path: env.sub_dir}],
          table: env.table,
          include_subsessions: true
        )

      assert nested_dir_with_subs.direct_session_count == 1
      assert nested_dir_with_subs.active_session_count == 1
      assert nested_dir_with_subs.latest_session.session_id == "sub-nested"
      assert nested_dir_with_subs.latest_session.parent.session_id == "root-cwd"
      assert nested_dir_with_subs.latest_session.role == "subagent"

      # browse_workspace excludes subsessions by default for both directories and folder sessions
      assert {:ok, browse_default} = Daemon.browse_workspace(%{"path" => env.cwd}, env.opts)
      assert Enum.map(browse_default.sessions, & &1.session_id) == ["root-cwd"]
      nested_browse = Enum.find(browse_default.directories, &(&1.name == "nested"))
      assert nested_browse.direct_session_count == 0
      assert nested_browse.latest_session == nil

      # browse_workspace with include_subsessions=true reveals subsessions
      assert {:ok, browse_all} =
               Daemon.browse_workspace(
                 %{"path" => env.cwd, "include_subsessions" => "true"},
                 env.opts
               )

      assert Enum.map(browse_all.sessions, & &1.session_id) == ["sub-cwd", "root-cwd"]
      nested_browse_all = Enum.find(browse_all.directories, &(&1.name == "nested"))
      assert nested_browse_all.direct_session_count == 1
      assert nested_browse_all.latest_session.session_id == "sub-nested"

      # list_sessions defaults to include_subsessions=true across all branches
      assert {:ok, all_default} = Daemon.list_sessions(%{}, env.opts)
      assert length(all_default) == 3

      assert {:ok, root_only_all} =
               Daemon.list_sessions(%{"include_subsessions" => "false"}, env.opts)

      assert Enum.map(root_only_all, & &1.session_id) == ["root-cwd"]

      assert {:ok, root_only_env} =
               Daemon.list_sessions(
                 %{"env_id" => "host", "include_subsessions" => "false"},
                 env.opts
               )

      assert Enum.map(root_only_env, & &1.session_id) == ["root-cwd"]

      assert {:ok, cwd_default} = Daemon.list_sessions(%{"cwd" => env.cwd}, env.opts)
      assert Enum.map(cwd_default, & &1.session_id) == ["sub-cwd", "root-cwd"]

      assert {:ok, cwd_root_only} =
               Daemon.list_sessions(
                 %{"cwd" => env.cwd, "include_subsessions" => "false"},
                 env.opts
               )

      assert Enum.map(cwd_root_only, & &1.session_id) == ["root-cwd"]
    end
  end
end
