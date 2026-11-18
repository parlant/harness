defmodule HWeb.BackendInVMTest do
  use ExUnit.Case, async: false

  alias H.{Auth, Catalog, StoreLock, WorkspaceLease}
  alias H.Provider.Fake
  alias HWeb.Backend.InVM

  setup do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "hweb-invm-#{id}")
    data_dir = Path.join(tmp_root, "data")
    projects_dir = Path.join(tmp_root, "projects")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(projects_dir)

    registry = :"HWeb.InVM.Reg.#{id}"
    pubsub = :"HWeb.InVM.Pub.#{id}"
    catalog = :"HWeb.InVM.Cat.#{id}"
    catalog_table = :"hweb_invm_cat_#{id}"
    auth = :"HWeb.InVM.Auth.#{id}"
    auth_table = :"hweb_invm_auth_#{id}"
    lease = :"HWeb.InVM.Lease.#{id}"
    runtime_sup = :"HWeb.InVM.Sup.#{id}"

    start_supervised!({StoreLock, data_dir: data_dir, name: :"HWeb.InVM.Lock.#{id}"})
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Auth, data_dir: data_dir, name: auth, table: auth_table})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

    fake = start_supervised!({Fake, name: :"HWeb.InVM.Fake.#{id}", script: []})

    daemon_opts = [
      data_dir: data_dir,
      default_cwd: projects_dir,
      stop_dir: projects_dir,
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

    prev = Application.get_env(:harness_web, :daemon_opts)
    Application.put_env(:harness_web, :daemon_opts, daemon_opts)

    on_exit(fn ->
      if is_nil(prev) do
        Application.delete_env(:harness_web, :daemon_opts)
      else
        Application.put_env(:harness_web, :daemon_opts, prev)
      end

      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    {:ok, projects_dir: projects_dir, pubsub: pubsub}
  end

  test "reads :daemon_opts, delegates to H.Daemon, and registers/unregisters PubSub", %{
    projects_dir: projects_dir,
    pubsub: pubsub
  } do
    assert [%{id: "host"} | _] = InVM.list_environments()
    assert [%{id: "fake:chat"} | _] = InVM.list_models()

    assert {:ok, %{path: resolved_path}} = InVM.browse_workspace(%{"path" => projects_dir})
    assert resolved_path == Path.expand(projects_dir)

    assert {:ok, %{session: session}} = InVM.create_session(%{"cwd" => projects_dir})
    sid = session.session_id

    assert {:ok, [listed]} = InVM.list_sessions(%{"cwd" => projects_dir})
    assert listed.session_id == sid

    assert {:ok, %{session: ^listed, conversations: [%{id: "1"}]}} =
             InVM.get_session_detail(sid)

    assert {:ok, %{items: [], next_cursor: nil}} = InVM.scan_entries(sid, "1", %{})

    assert {:ok, {:snapshot, _seq, _bin}} =
             InVM.subscribe_conversation(sid, "1", self(), nil)

    assert {:conversation, sid, 1} in Registry.keys(pubsub, self())

    assert :ok = InVM.unsubscribe_conversation(sid, "1")
    refute {:conversation, sid, 1} in Registry.keys(pubsub, self())
  end
end
