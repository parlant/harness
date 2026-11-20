defmodule H.CatalogCwdTest do
  use ExUnit.Case, async: true

  alias H.Catalog

  setup do
    id = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "h-catalog-cwd-test-#{id}")
    table = :"h_catalog_cwd_test_#{id}"
    name = :"H.Catalog.CwdTest.#{id}"

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, data_dir: tmp_dir, table: table, server: name}
  end

  describe "env_id and harness_id persistence and legacy migration" do
    test "defaults env_id to \"host\" and harness_id to \"coding\" when loading legacy sessions.json",
         %{
           data_dir: data_dir,
           table: table,
           server: server
         } do
      catalog_dir = Path.join(data_dir, "catalog")
      File.mkdir_p!(catalog_dir)

      legacy_json =
        JSON.encode!(%{
          "version" => 1,
          "sessions" => [
            %{
              "session_id" => "legacy-1",
              "title" => "Old Session",
              "cwd" => "/Users/me/app",
              "created_at" => 1000,
              "updated_at" => 2000,
              "active" => true
            }
          ]
        })

      File.write!(Path.join(catalog_dir, "sessions.json"), legacy_json)

      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})

      assert {:ok, entry} = Catalog.get_session("legacy-1", table)
      assert entry.env_id == "host"
      assert entry.harness_id == "coding"
      assert entry.cwd == "/Users/me/app"
      assert entry.active == true

      assert [%{session_id: "legacy-1"}] =
               Catalog.list_sessions_for_cwd("host", "/Users/me/app", table: table)
    end

    test "persists custom env_id and harness_id and normalizes non-host cwd without host Path.expand",
         %{
           data_dir: data_dir,
           table: table,
           server: server
         } do
      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})

      assert {:ok, root_entry} =
               Catalog.put_session(server, %{
                 session_id: "remote-root",
                 env_id: "vm-eu-1",
                 harness_id: "audit",
                 cwd: "/"
               })

      assert root_entry.env_id == "vm-eu-1"
      assert root_entry.harness_id == "audit"
      assert root_entry.cwd == "/"

      assert {:ok, remote_entry} =
               Catalog.put_session(server, %{
                 session_id: "remote-app",
                 env_id: "vm-eu-1",
                 harness_id: "research",
                 cwd: "/home/ubuntu/../app/"
               })

      assert remote_entry.env_id == "vm-eu-1"
      assert remote_entry.harness_id == "research"
      assert remote_entry.cwd == "/home/ubuntu/../app"

      stop_supervised!(Catalog)

      table2 = :"#{table}_reloaded"
      server2 = :"#{server}.Reloaded"
      start_supervised!({Catalog, data_dir: data_dir, name: server2, table: table2})

      assert {:ok, ^root_entry} = Catalog.get_session("remote-root", table2)
      assert {:ok, ^remote_entry} = Catalog.get_session("remote-app", table2)
    end
  end

  describe "list_sessions_for_cwd/3" do
    setup %{data_dir: data_dir, table: table, server: server} do
      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})

      {:ok, _} =
        Catalog.put_session(server, %{
          session_id: "host-root",
          cwd: "/",
          updated_at: 50
        })

      {:ok, _} =
        Catalog.put_session(server, %{
          session_id: "host-app-1",
          cwd: "/Users/me/app",
          updated_at: 100
        })

      {:ok, _} =
        Catalog.put_session(server, %{
          session_id: "host-app-2",
          cwd: "/Users/me/app",
          updated_at: 300
        })

      {:ok, _} =
        Catalog.put_session(server, %{
          session_id: "host-app-sub",
          cwd: "/Users/me/app/packages/core",
          updated_at: 200
        })

      {:ok, _} =
        Catalog.put_session(server, %{
          session_id: "host-app-v2",
          cwd: "/Users/me/app-v2",
          updated_at: 400
        })

      {:ok, _} =
        Catalog.put_session(server, %{
          session_id: "vm-app",
          env_id: "vm-eu-1",
          cwd: "/Users/me/app",
          updated_at: 500
        })

      {:ok, _} =
        Catalog.put_session(server, %{
          session_id: "vm-app-sub",
          env_id: "vm-eu-1",
          cwd: "/Users/me/app/sub",
          updated_at: 600
        })

      :ok
    end

    test "filters exact cwd matches and normalizes trailing slashes and nil env_id", %{
      table: table
    } do
      assert ["host-app-2", "host-app-1"] ==
               "host"
               |> Catalog.list_sessions_for_cwd("/Users/me/app/", table: table)
               |> Enum.map(& &1.session_id)

      assert ["host-app-2", "host-app-1"] ==
               nil
               |> Catalog.list_sessions_for_cwd("/Users/me/a/../app", table: table)
               |> Enum.map(& &1.session_id)
    end

    test "enforces prefix-boundary safety so /Users/me/app never matches /Users/me/app-v2", %{
      table: table
    } do
      ids =
        "host"
        |> Catalog.list_sessions_for_cwd("/Users/me/app", table: table, subtree: true)
        |> Enum.map(& &1.session_id)

      assert ids == ["host-app-2", "host-app-sub", "host-app-1"]
      refute "host-app-v2" in ids
    end

    test "handles root \"/\" for both exact and subtree queries", %{table: table} do
      assert ["host-root"] ==
               "host"
               |> Catalog.list_sessions_for_cwd("/", table: table)
               |> Enum.map(& &1.session_id)

      assert ["host-app-v2", "host-app-2", "host-app-sub", "host-app-1", "host-root"] ==
               "host"
               |> Catalog.list_sessions_for_cwd("/", table: table, subtree: true)
               |> Enum.map(& &1.session_id)
    end

    test "isolates sessions across environments", %{table: table} do
      assert ["vm-app"] ==
               "vm-eu-1"
               |> Catalog.list_sessions_for_cwd("/Users/me/app/", table: table)
               |> Enum.map(& &1.session_id)

      assert ["vm-app-sub", "vm-app"] ==
               "vm-eu-1"
               |> Catalog.list_sessions_for_cwd("/Users/me/app", table: table, subtree: true)
               |> Enum.map(& &1.session_id)
    end
  end

  describe "annotate_directories/3" do
    setup %{data_dir: data_dir, table: table, server: server} do
      start_supervised!({Catalog, data_dir: data_dir, name: server, table: table})

      {:ok, _} =
        Catalog.put_session(server, %{
          session_id: "app-direct-1",
          cwd: "/path/app",
          title: "Older Direct",
          updated_at: 100,
          active: false
        })

      {:ok, _} =
        Catalog.put_session(server, %{
          session_id: "app-direct-2",
          cwd: "/path/app",
          title: "Active Direct",
          updated_at: 200,
          active: true
        })

      {:ok, _} =
        Catalog.put_session(server, %{
          session_id: "app-nested",
          cwd: "/path/app/packages/ui",
          title: "Latest Nested",
          updated_at: 350,
          active: true,
          status: "ok"
        })

      {:ok, _} =
        Catalog.put_session(server, %{
          session_id: "app-2-session",
          cwd: "/path/app-2",
          title: "Sibling App 2",
          updated_at: 500,
          active: true
        })

      {:ok, _} =
        Catalog.put_session(server, %{
          session_id: "vm-only-session",
          env_id: "vm-eu-1",
          cwd: "/path/app",
          title: "VM Session",
          updated_at: 999,
          active: true
        })

      :ok
    end

    test "computes direct counts, nested subtree rollups, active counts, and latest_session without prefix leakage",
         %{table: table} do
      dirs = [
        %{name: "app", path: "/path/app", markers: [".git"]},
        %{name: "app-2", path: "/path/app-2"},
        %{name: "empty", path: "/path/empty"}
      ]

      annotated = Catalog.annotate_directories("host", dirs, table: table)

      assert [app, app_2, empty] = annotated

      assert app.name == "app"
      assert app.markers == [".git"]
      assert app.direct_session_count == 2
      assert app.subtree_session_count == 3
      assert app.active_session_count == 2

      assert app.latest_session == %{
               session_id: "app-nested",
               title: "Latest Nested",
               tags: [],
               cwd: "/path/app/packages/ui",
               updated_at: 350,
               active: true,
               attention: "idle",
               activity_kind: nil,
               activity_label: nil,
               queued_count: 0,
               needs_attention: true,
               archived: false,
               loaded: false,
               cwd_exists: false,
               status: "ok"
             }

      assert app_2.direct_session_count == 1
      assert app_2.subtree_session_count == 1
      assert app_2.active_session_count == 1
      assert app_2.latest_session.session_id == "app-2-session"

      assert empty.direct_session_count == 0
      assert empty.subtree_session_count == 0
      assert empty.active_session_count == 0
      assert empty.latest_session == nil
    end

    test "resolves :name using :parent_path and preserves string keys when input uses string keys",
         %{table: table} do
      atom_dirs = [%{name: "app"}, %{name: "empty"}]

      assert [atom_app, atom_empty] =
               Catalog.annotate_directories("host", atom_dirs,
                 table: table,
                 parent_path: "/path"
               )

      assert atom_app.direct_session_count == 2
      assert atom_app.subtree_session_count == 3
      assert atom_empty.subtree_session_count == 0

      string_dirs = [%{"name" => "app"}, %{"path" => "/path/empty"}]

      assert [str_app, str_empty] =
               Catalog.annotate_directories("vm-eu-1", string_dirs,
                 table: table,
                 parent_path: "/path/"
               )

      assert str_app["name"] == "app"
      assert str_app["direct_session_count"] == 1
      assert str_app["subtree_session_count"] == 1
      assert str_app["active_session_count"] == 1

      assert str_app["latest_session"] == %{
               "session_id" => "vm-only-session",
               "title" => "VM Session",
               "tags" => [],
               "cwd" => "/path/app",
               "updated_at" => 999,
               "active" => true,
               "attention" => "idle",
               "activity_kind" => nil,
               "activity_label" => nil,
               "queued_count" => 0,
               "needs_attention" => true,
               "archived" => false,
               "loaded" => false,
               "cwd_exists" => true,
               "status" => "ok"
             }

      assert str_empty["direct_session_count"] == 0
      assert str_empty["subtree_session_count"] == 0
      assert str_empty["active_session_count"] == 0
      assert str_empty["latest_session"] == nil
    end

    test "returns empty list for empty dir_entries", %{table: table} do
      assert [] == Catalog.annotate_directories("host", [], table: table)
    end
  end
end
