defmodule HWeb.ConnCase do
  @moduledoc """
  Isolated test helper starting `HWeb.Endpoint` (with `server: false`) and
  per-test `H` supervision children (`StoreLock`, `Registry`, `Auth`, `Catalog`,
  `WorkspaceLease`, `DynamicSupervisor`, and `H.Provider.Fake`).
  """
  use ExUnit.CaseTemplate

  @endpoint HWeb.Endpoint

  import Phoenix.ConnTest

  alias H.{Auth, Catalog, StoreLock, WorkspaceLease}
  alias H.Provider.Fake

  using do
    quote do
      @endpoint HWeb.Endpoint

      use HWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import HWeb.ConnCase
    end
  end

  setup tags do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "hweb-test-#{id}")
    data_dir = Path.join(tmp_root, "data")
    projects_dir = Path.join(tmp_root, "projects")

    File.mkdir_p!(data_dir)
    File.mkdir_p!(projects_dir)

    registry = :"HWeb.Test.Reg.#{id}"
    pubsub = :"HWeb.Test.Pub.#{id}"
    catalog = :"HWeb.Test.Cat.#{id}"
    catalog_table = :"hweb_test_cat_#{id}"
    auth = :"HWeb.Test.Auth.#{id}"
    auth_table = :"hweb_test_auth_#{id}"
    lease = :"HWeb.Test.Lease.#{id}"
    runtime_sup = :"HWeb.Test.Sup.#{id}"
    store_lock = :"HWeb.Test.Lock.#{id}"
    fake_name = :"HWeb.Test.Fake.#{id}"

    start_supervised!({StoreLock, data_dir: data_dir, name: store_lock})
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Auth, data_dir: data_dir, name: auth, table: auth_table})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

    script = Map.get(tags, :fake_script, [])
    fake = start_supervised!({Fake, name: fake_name, script: script})

    daemon_opts = [
      data_dir: data_dir,
      default_cwd: projects_dir,
      stop_dir: projects_dir,
      registry: registry,
      pubsub: pubsub,
      catalog: catalog,
      catalog_table: catalog_table,
      auth_server: auth,
      auth_table: auth_table,
      workspace_lease: lease,
      runtime_sup: runtime_sup,
      provider: Fake,
      provider_config: %{server: fake},
      storage_mod: H.Storage.File,
      storage_opts: [sync: :none],
      default_model: "fake:coder",
      ephemeral_interval_ms: 10
    ]

    prev_daemon_opts = Application.get_env(:harness_web, :daemon_opts)
    prev_backend = Application.get_env(:harness_web, :backend)

    Application.put_env(:harness_web, :backend, HWeb.Backend.InVM)
    Application.put_env(:harness_web, :daemon_opts, daemon_opts)

    start_supervised!(HWeb.Endpoint)

    on_exit(fn ->
      if is_nil(prev_daemon_opts) do
        Application.delete_env(:harness_web, :daemon_opts)
      else
        Application.put_env(:harness_web, :daemon_opts, prev_daemon_opts)
      end

      if is_nil(prev_backend) do
        Application.delete_env(:harness_web, :backend)
      else
        Application.put_env(:harness_web, :backend, prev_backend)
      end

      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    owner_token = Auth.owner_token(auth_table)

    {:ok,
     conn: Phoenix.ConnTest.build_conn(),
     tmp_root: tmp_root,
     data_dir: data_dir,
     projects_dir: projects_dir,
     daemon_opts: daemon_opts,
     pubsub: pubsub,
     fake: fake,
     owner_token: owner_token,
     auth_server: auth,
     auth_table: auth_table}
  end

  @doc "Authenticates `conn` through `POST /login` using CSRF token and `owner_token`."
  def log_in_owner(conn, owner_token) do
    login_conn = get(conn, "/login")
    csrf = extract_csrf_token(login_conn.resp_body)

    post(login_conn, "/login", %{
      "_csrf_token" => csrf,
      "token" => owner_token
    })
    |> recycle()
  end

  defp extract_csrf_token(html) do
    case Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, html) do
      [_, token] -> token
      _ -> raise "CSRF token not found in login HTML"
    end
  end
end
