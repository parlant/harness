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
