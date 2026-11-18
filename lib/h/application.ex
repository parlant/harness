defmodule H.Application do
  @moduledoc """
  OTP application entry point for `:harness`.

  Unit tests run with `--no-start` and start isolated children via `start_supervised!`.
  When `:data_dir` is configured (`Application.get_env(:harness, :data_dir)` or
  start args), `H.Supervisor` starts `H.StoreLock`, `H.Auth`, `H.Catalog`,
  runs a boot recovery pass for unfinished active sessions, and optionally binds
  the loopback `Bandit` HTTP/SSE server when `:http_port` is configured.
  """
  use Application

  @impl true
  def start(_type, args) do
    Supervisor.start_link(children(args), strategy: :rest_for_one, name: H.Supervisor)
  end

  @doc "Builds the supervision tree child list for `H.Application`."
  @spec children(keyword()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(args \\ []) when is_list(args) do
    data_dir = Keyword.get(args, :data_dir) || Application.get_env(:harness, :data_dir)

    start_daemon? =
      Keyword.get(
        args,
        :daemon,
        Application.get_env(:harness, :start_daemon, not is_nil(data_dir))
      )

    registry = Keyword.get(args, :registry, H.Registry)
    pubsub = Keyword.get(args, :pubsub, H.PubSub)
    runtime_sup = Keyword.get(args, :runtime_sup, H.Session.RuntimeSupervisor)
    workspace_lease = Keyword.get(args, :workspace_lease, H.WorkspaceLease)

    if start_daemon? and is_binary(data_dir) do
      catalog = Keyword.get(args, :catalog, H.Catalog)
      catalog_table = Keyword.get(args, :catalog_table, :h_catalog)
      auth = Keyword.get(args, :auth, H.Auth)
      auth_table = Keyword.get(args, :auth_table, :h_auth)
      store_lock = Keyword.get(args, :store_lock, H.StoreLock)
      http_port = Keyword.get(args, :http_port, Application.get_env(:harness, :http_port))

      api_socket? =
        Keyword.get(args, :api_socket, Application.get_env(:harness, :api_socket, false))

      daemon_opts = [
        data_dir: data_dir,
        registry: registry,
        pubsub: pubsub,
        catalog: catalog,
        catalog_table: catalog_table,
        workspace_lease: workspace_lease,
        runtime_sup: runtime_sup
      ]

      recovery_child =
        Supervisor.child_spec(
          {Task, fn -> H.Daemon.recover_active_sessions(daemon_opts) end},
          id: :boot_recovery,
          restart: :temporary
        )

      base_router_opts = [
        auth_server: auth,
        auth_table: auth_table,
        daemon: H.Daemon,
        daemon_opts: daemon_opts
      ]

      http_children =
        if is_integer(http_port) and http_port >= 0 do
          router_opts = Keyword.put(base_router_opts, :port, http_port)

          [
            Supervisor.child_spec(
              {Bandit, plug: {H.HTTP.Router, router_opts}, ip: {127, 0, 0, 1}, port: http_port},
              id: :h_http_tcp
            )
          ]
        else
          []
        end

      unix_children =
        if api_socket? do
          sock_path = H.api_socket_path(data_dir)
          [{H.HTTP.UnixListener, {sock_path, base_router_opts}}]
        else
          []
        end

      [
        {H.StoreLock, data_dir: data_dir, name: store_lock},
        {Registry, keys: :unique, name: registry},
        {Registry, keys: :duplicate, name: pubsub},
        {H.Auth, data_dir: data_dir, name: auth, table: auth_table},
        {H.Catalog, data_dir: data_dir, name: catalog, table: catalog_table},
        {H.WorkspaceLease, name: workspace_lease},
        {DynamicSupervisor, strategy: :one_for_one, name: runtime_sup},
        recovery_child
      ] ++ http_children ++ unix_children
    else
      [
        {Registry, keys: :unique, name: registry},
        {Registry, keys: :duplicate, name: pubsub},
        {H.WorkspaceLease, name: workspace_lease},
        {DynamicSupervisor, strategy: :one_for_one, name: runtime_sup}
      ]
    end
  end
end
