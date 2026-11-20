defmodule H.CatalogTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias H.Catalog

  setup context do
    id = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "h-catalog-test-#{id}")
    table = :"h_catalog_test_#{id}"
    name = :"H.Catalog.Test.#{id}"

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, data_dir: tmp_dir, table: table, server: name, test_name: context.test}
  end

  describe "put_session/2" do
    test "validates session_id and absolute cwd, inserts into ETS, and persists atomically", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})

      assert {:ok, entry} =
               Catalog.put_session(server, %{
                 "session_id" => "demo",
                 "cwd" => "/work/project/../project",
                 "title" => "Demo"
               })

      assert entry.session_id == "demo"
      assert entry.env_id == "host"
      assert entry.harness_id == "coding"
      assert entry.cwd == "/work/project"
      assert entry.title == "Demo"
      assert entry.root_conversation_id == 1
      assert entry.active == false
      assert entry.next_wake_at == nil
      assert entry.status == "ok"
      assert entry.quarantine_reason == nil
      assert entry.pending_edits == []
      assert is_integer(entry.created_at)
      assert is_integer(entry.updated_at)

      sessions_file = Path.join([data_dir, "catalog", "sessions.json"])
      {:ok, stat} = File.stat(sessions_file)
      assert (stat.mode &&& 0o777) == 0o600
      assert {:ok, ^entry} = Catalog.get_session("demo", table)
    end

    test "rejects invalid session_id and relative cwd", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})

      assert {:error, _} = Catalog.put_session(server, %{session_id: "../bad", cwd: "/tmp/work"})
      assert {:error, _} = Catalog.put_session(server, %{session_id: "ok", cwd: "relative/path"})
      assert {:error, _} = Catalog.put_session(server, %{session_id: "ok", cwd: "/tmp/bad\0path"})

      assert {:error, _} =
               Catalog.put_session(server, %{session_id: "ok", cwd: "/tmp/work", env_id: ""})

      assert {:error, _} =
               Catalog.put_session(server, %{session_id: "ok", cwd: "/tmp/work", harness_id: ""})

      assert {:error, _} =
               Catalog.put_session(server, %{
                 session_id: "ok",
                 env_id: "vm-1",
                 cwd: "/home/bad\0path"
               })
    end

    test "reloads persisted sessions across restart", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      pid = start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})

      {:ok, created} =
        Catalog.put_session(server, %{
          session_id: "persisted",
          cwd: "/tmp/persisted",
          title: "Initial",
          created_at: 100,
          updated_at: 200
        })

      stop_supervised!(Catalog)
      refute Process.alive?(pid)

      table2 = :"#{table}_reloaded"
      server2 = :"#{server}.Reloaded"
      start_supervised!({Catalog, data_dir: data_dir, name: server2, table: table2})

      assert {:ok, ^created} = Catalog.get_session("persisted", table2)
    end
  end

  describe "set_triage/3" do
    test "persists and broadcasts validated tags without changing attention or archive state", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      pubsub = Module.concat(server, PubSub)
      start_supervised!({Registry, keys: :duplicate, name: pubsub})
      opts = [data_dir: data_dir, name: server, table: table, pubsub: pubsub]
      start_supervised!({Catalog, opts})
      Registry.register(pubsub, :catalog, nil)

      assert {:ok, %{tags: []}} =
               Catalog.put_session(server, %{session_id: "tagged", cwd: data_dir, archived: true})

      assert_receive {:catalog_frame, seq, _}

      assert {:error, "expected needs_attention or tags"} =
               Catalog.set_triage(server, "tagged", %{})

      assert {:error, _} = Catalog.set_triage(server, "tagged", %{tags: ["bad,tag"]})
      assert {:error, _} = Catalog.set_triage(server, "tagged", %{tags: [42]})

      assert {:error, _} =
               Catalog.set_triage(server, "tagged", %{tags: List.duplicate("tag", 33)})

      assert %{seq: ^seq} = Catalog.snapshot(server)

      assert {:ok, %{tags: ["ops", "on call"], archived: true, needs_attention: false}} =
               Catalog.set_triage(server, "tagged", %{"tags" => [" ops ", "on call", "ops"]})

      assert_receive {:catalog_frame, next_seq, json}
      assert next_seq == seq + 1

      assert %{
               "type" => "upsert",
               "session" => %{"tags" => ["ops", "on call"], "loaded" => false}
             } =
               JSON.decode!(json)

      stop_supervised!(Catalog)
      start_supervised!({Catalog, opts})
      assert {:ok, %{tags: ["ops", "on call"]}} = Catalog.get_session("tagged", table)

      assert {:ok, %{tags: ["ops", "on call"]}} =
               Catalog.report_runtime(server, "tagged", %{title: "Changed", tags: ["ignored"]})

      assert {:ok, %{tags: [], archived: true, needs_attention: false}} =
               Catalog.set_triage(server, "tagged", %{tags: []})
    end
  end

  describe "list_sessions/1" do
    test "returns entries directly from ETS sorted by updated_at descending", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})

      {:ok, _} =
        Catalog.put_session(server, %{session_id: "s1", cwd: "/tmp/s1", updated_at: 100})

      {:ok, _} =
        Catalog.put_session(server, %{session_id: "s2", cwd: "/tmp/s2", updated_at: 300})

      {:ok, _} =
        Catalog.put_session(server, %{session_id: "s3", cwd: "/tmp/s3", updated_at: 200})

      assert ["s2", "s3", "s1"] ==
               table |> Catalog.list_sessions() |> Enum.map(& &1.session_id)
    end
  end

  describe "get_session/2" do
    test "returns {:error, :not_found} when missing", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})
      assert {:error, :not_found} = Catalog.get_session("missing", table)
    end
  end

  describe "report_runtime/3" do
    test "updates worker-owned fields without clobbering server-owned cwd or status", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})
      {:ok, _} = Catalog.put_session(server, %{session_id: "s1", cwd: "/tmp/real"})

      assert {:ok, updated} =
               Catalog.report_runtime(server, "s1", %{
                 "title" => "Running",
                 "active" => true,
                 "next_wake_at" => 9_999,
                 "updated_at" => 500,
                 "applied_edit_rev" => 3,
                 "cwd" => "/tmp/clobber",
                 "status" => "quarantined"
               })

      assert updated.title == "Running"
      assert updated.active == true
      assert updated.next_wake_at == 9_999
      assert updated.updated_at == 500
      assert updated.applied_edit_rev == 3
      assert updated.cwd == "/tmp/real"
      assert updated.status == "ok"
      assert {:ok, ^updated} = Catalog.get_session("s1", table)
    end

    test "persists explicit title clearing to nil across restart", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})
      {:ok, _} = Catalog.put_session(server, %{session_id: "s1", cwd: "/tmp/s1", title: "Named"})

      assert {:ok, cleared} = Catalog.report_runtime(server, "s1", %{title: nil, updated_at: 900})
      assert cleared.title == nil
      assert {:ok, %{title: nil}} = Catalog.get_session("s1", table)

      stop_supervised!(Catalog)

      table2 = :"#{table}_cleared"
      server2 = :"#{server}.Cleared"
      start_supervised!({Catalog, data_dir: data_dir, name: server2, table: table2})

      assert {:ok, ^cleared} = Catalog.get_session("s1", table2)
    end

    test "returns {:error, :not_found} for unknown session", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})
      assert {:error, :not_found} = Catalog.report_runtime(server, "unknown", %{active: true})
    end
  end

  describe "quarantine/3" do
    test "marks session quarantined and inactive", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})
      {:ok, _} = Catalog.put_session(server, %{session_id: "s1", cwd: "/tmp/s1", active: true})

      assert {:ok, updated} = Catalog.quarantine(server, "s1", :corrupt_log)
      assert updated.status == "quarantined"
      assert updated.active == false
      assert updated.quarantine_reason == "corrupt_log"
      assert {:ok, ^updated} = Catalog.get_session("s1", table)
    end
  end

  describe "delete_session/2" do
    test "removes session from ETS and disk", %{
      data_dir: data_dir,
      table: table,
      server: server
    } do
      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})
      {:ok, _} = Catalog.put_session(server, %{session_id: "s1", cwd: "/tmp/s1"})

      assert :ok = Catalog.delete_session(server, "s1")
      assert {:error, :not_found} = Catalog.get_session("s1", table)
      assert [] == Catalog.list_sessions(table)
      assert :ok = Catalog.delete_session(server, "s1")
    end
  end
end
