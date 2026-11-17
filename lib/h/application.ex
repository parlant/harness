defmodule H.Application do
  @moduledoc """
  OTP application entry point for `:harness`.

  Unit tests run with `--no-start` and start isolated children via `start_supervised!`.
  When `:data_dir` is configured (`Application.get_env(:harness, :data_dir)` or
  start args), `H.Supervisor` also starts `H.StoreLock`, `H.Auth`, and `H.Catalog`.
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
    runtime_sup = Keyword.get(opts_or(args), :runtime_sup, H.Session.RuntimeSupervisor)
    workspace_lease = Keyword.get(args, :workspace_lease, H.WorkspaceLease)

    base_children = [
      {Registry, keys: :unique, name: registry},
      {Registry, keys: :duplicate, name: pubsub},
      {workspace_lease_mod(), name: workspace_lease},
      {DynamicSupervisor, strategy: :one_for_one, name: runtime_sup}
    ]

    if start_daemon? and is_binary(data_dir) do
      catalog = Keyword.get(args, :catalog, H.Catalog)
      catalog_table = Keyword.get(args, :catalog_table, :h_catalog)
      auth = Keyword.get(args, :auth, H.Auth)
      auth_table = Keyword.get(args, :auth_table, :h_auth)
      store_lock = Keyword.get(args, :store_lock, H.StoreLock)

      [
        {H.StoreLock, data_dir: data_dir, name: store_lock},
        {Registry, keys: :unique, name: registry},
        {Registry, keys: :duplicate, name: pubsub},
        {H.Auth, data_dir: data_dir, name: auth, table: auth_table},
        {H.Catalog, data_dir: data_dir, name: catalog, table: catalog_table},
        {workspace_lease_mod(), name: workspace_lease},
        {DynamicSupervisor, strategy: :one_for_one, name: runtime_sup}
      ]
    else
      base_children
    end
  end

  defp opts_or(args) when is_list(args), do: args
  defp workspace_lease_mod, do: H.WorkspaceLease
end
