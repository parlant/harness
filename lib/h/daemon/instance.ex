defmodule H.Daemon.Instance do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    data_dir = opts |> Keyword.fetch!(:data_dir) |> Path.expand()

    opts =
      Keyword.merge(
        [
          registry: H.Registry,
          pubsub: H.PubSub,
          catalog: H.Catalog,
          catalog_table: :h_catalog,
          workspace_lease: H.WorkspaceLease,
          runtime_sup: H.Session.RuntimeSupervisor,
          store_lock: H.StoreLock,
          auth_server: H.Auth,
          auth_table: :h_auth
        ],
        opts
      )
      |> Keyword.put(:data_dir, data_dir)
      |> Keyword.update(:auto_compaction, %{}, &H.Session.Compaction.validate_limits!/1)

    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Supervisor.init(
      [
        {H.StoreLock, data_dir: opts[:data_dir], name: opts[:store_lock]},
        {H.Auth, data_dir: opts[:data_dir], name: opts[:auth_server], table: opts[:auth_table]},
        {H.Catalog, data_dir: opts[:data_dir], name: opts[:catalog], table: opts[:catalog_table]},
        {H.Daemon.Runtime, opts}
      ],
      # Losing the instance/lock is a failed boot, not permission to reread
      # config and rebind already recorded identities in the same VM.
      strategy: :rest_for_one,
      max_restarts: 0
    )
  end
end

defmodule H.Daemon.Runtime do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    with {:ok, opts, extension_children} <- H.Extensions.load(opts),
         {:ok, opts, account_children} <- H.Accounts.boot(opts) do
      Supervisor.start_link(__MODULE__, {opts, account_children ++ extension_children})
    end
  end

  @impl true
  def init({opts, service_children}) do
    table = :ets.new(:h_daemon_admission, [:set, :public, read_concurrency: true])
    :ets.insert(table, [{:open, true}, {:managed, is_pid(opts[:shutdown_owner])}])
    opts = Keyword.put(opts, :maintenance_table, table)

    router = [
      auth_server: opts[:auth_server],
      auth_table: opts[:auth_table],
      daemon_opts: opts,
      port: opts[:http_port]
    ]

    socket = if opts[:api_socket], do: H.api_socket_path(opts[:data_dir])

    tcp =
      if port = opts[:http_port] do
        [
          {Bandit,
           plug: {H.HTTP.Router, router},
           ip: {127, 0, 0, 1},
           port: port,
           thousand_island_options: [supervisor_options: [name: H.Daemon.HTTP]]}
        ]
      else
        []
      end

    unix = if socket, do: [{H.HTTP.UnixListener, {socket, router}}], else: []

    services =
      if service_children == [] do
        []
      else
        [
          %{
            id: :instance_services,
            start: {Supervisor, :start_link, [service_children, [strategy: :one_for_one]]},
            type: :supervisor
          }
        ]
      end

    Supervisor.init(
      services ++
        [
          {Registry, keys: :unique, name: opts[:registry]},
          Supervisor.child_spec({Registry, keys: :duplicate, name: opts[:pubsub]}, id: :pubsub),
          {H.WorkspaceLease, name: opts[:workspace_lease]},
          {DynamicSupervisor, strategy: :one_for_one, name: opts[:runtime_sup]},
          {H.Daemon.Boot, opts}
        ] ++
        tcp ++
        unix ++
        [
          %{
            id: :daemon_manifest,
            start: {__MODULE__, :publish_manifest, [opts, socket]}
          }
        ],
      strategy: :rest_for_one
    )
  end

  @doc false
  def publish_manifest(opts, socket) do
    port =
      if opts[:http_port] do
        {:ok, {_ip, port}} = ThousandIsland.listener_info(H.Daemon.HTTP)
        port
      end

    H.write_daemon_manifest!(opts[:data_dir], port, socket)
    :ignore
  end
end

defmodule H.Daemon.Boot do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    :ok = H.Daemon.recover_active_sessions(opts)
    {:ok, %{opts: opts, reservations: %{}}}
  end

  @impl true
  def handle_call(:options, _from, state), do: {:reply, state.opts, state}

  def handle_call({:admit, table}, {pid, _}, state) do
    if table == state.opts[:maintenance_table] and :ets.lookup_element(table, :open, 2, false) do
      ref = state.reservations[pid] || Process.monitor(pid)
      {:reply, :ok, put_in(state.reservations[pid], ref)}
    else
      {:reply, {:error, :daemon_draining}, state}
    end
  end

  def handle_call(:stop_if_idle, _from, %{opts: opts, reservations: reservations} = state) do
    table = opts[:maintenance_table]

    cond do
      not is_pid(opts[:shutdown_owner]) or not Process.alive?(opts[:shutdown_owner]) ->
        {:reply, {:error, :shutdown_not_supported}, state}

      map_size(reservations) != 0 or not :ets.lookup_element(table, :open, 2, false) ->
        {:reply, {:error, :daemon_busy}, state}

      true ->
        :ets.insert(table, {:open, false})

        if idle?(opts) do
          {:reply, {:ok, %{state: "stopping"}}, state}
        else
          :ets.insert(table, {:open, true})
          {:reply, {:error, :daemon_busy}, state}
        end
    end
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    {ref, reservations} = Map.pop(state.reservations, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | reservations: reservations}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    reservations =
      if state.reservations[pid] == ref,
        do: Map.delete(state.reservations, pid),
        else: state.reservations

    {:noreply, %{state | reservations: reservations}}
  end

  defp idle?(opts) do
    # A canceled caller may already be past the gate in a coordinator.
    # Synchronize once with each live session before trusting the catalog.
    deadline = System.monotonic_time(:millisecond) + 1500
    servers = Registry.select(opts[:registry], [{{{:session, :_}, :"$1", :_}, [], [:"$1"]}])

    Enum.all?(servers, fn pid ->
      remaining = max(1, deadline - System.monotonic_time(:millisecond))
      GenServer.call(pid, :idle, remaining)
    end) and not Enum.any?(H.Catalog.list_sessions(opts[:catalog_table]), & &1.active) and
      GenServer.call(
        opts[:accounts],
        :idle,
        max(1, deadline - System.monotonic_time(:millisecond))
      )
  catch
    :exit, _ -> false
  end
end
