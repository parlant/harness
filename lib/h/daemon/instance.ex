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
        {H.Catalog,
         data_dir: opts[:data_dir],
         name: opts[:catalog],
         table: opts[:catalog_table],
         pubsub: opts[:pubsub],
         registry: opts[:registry]},
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
         {:ok, opts} <- H.Provider.Compatible.load(opts),
         {:ok, opts, account_children} <- H.Accounts.boot(opts) do
      Supervisor.start_link(__MODULE__, {opts, account_children ++ extension_children})
    end
  end

  @impl true
  def init({opts, service_children}) do
    table = :ets.new(:h_daemon_admission, [:set, :public, read_concurrency: true])

    :ets.insert(table, [
      {:open, true},
      {:draining, false},
      {:managed, is_pid(opts[:shutdown_owner])}
    ])

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
        for {ip, index} <- Enum.with_index(opts[:bind_addresses] || [{127, 0, 0, 1}]) do
          name = http_listener(index)

          Supervisor.child_spec(
            {Bandit,
             plug: {H.HTTP.Router, Keyword.put(router, :bind_address, ip)},
             ip: ip,
             port: port,
             thousand_island_options: [
               shutdown_timeout: 2_000,
               supervisor_options: [name: name]
             ]},
            id: name
          )
        end
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
    urls = Enum.map(http_endpoints(opts), &elem(&1, 1))
    H.write_daemon_manifest!(opts[:data_dir], urls, socket)
    :ignore
  end

  def http_endpoints(opts) do
    if opts[:http_port] do
      opts[:bind_addresses]
      |> Kernel.||([{127, 0, 0, 1}])
      |> Enum.with_index()
      |> Enum.map(fn {_, index} ->
        {:ok, {ip, port}} = ThousandIsland.listener_info(http_listener(index))
        {port, "http://#{:inet.ntoa(ip)}:#{port}"}
      end)
    else
      []
    end
  end

  defp http_listener(0), do: H.Daemon.HTTP
  defp http_listener(index), do: {:global, {H.Daemon.HTTP, index}}
end

defmodule H.Daemon.Boot do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @drain_poll_ms 100
  @default_shutdown_timeout_ms 300_000
  @shutdown_commit_grace_ms 30_000
  @account_refresh_timeout_ms 14_000

  @impl true
  def init(opts) do
    {:ok,
     %{
       opts: opts,
       reservations: %{},
       phase: :running,
       drain_timer: nil,
       recovery_ref: nil
     }, {:continue, :recover_sessions}}
  end

  @impl true
  def handle_continue(:recover_sessions, state) do
    # Run boot recovery outside Boot's GenServer mailbox so recovered sessions
    # (such as a parent subagent re-attaching/submitting to its child via
    # H.Daemon.Maintenance.admit/2) cannot deadlock calling back into Boot.
    opts = state.opts
    {_pid, ref} = spawn_monitor(fn -> H.Daemon.recover_active_sessions(opts) end)
    {:noreply, %{state | recovery_ref: ref}}
  end

  @impl true
  def handle_call(:options, _from, state), do: {:reply, state.opts, state}

  def handle_call(:status, _from, state) do
    workers = count_active_workers(state.opts)
    timeout_ms = compute_shutdown_timeout_ms(state.opts)

    payload = %{
      "state" => phase_string(state.phase),
      "active_workers" => workers,
      "shutdown_timeout_ms" => timeout_ms
    }

    {:reply, {:ok, payload}, state}
  end

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

      state.phase != :running or not is_nil(state.recovery_ref) or map_size(reservations) != 0 or
          not :ets.lookup_element(table, :open, 2, false) ->
        {:reply, {:error, :daemon_busy}, state}

      true ->
        :ets.insert(table, {:open, false})

        if idle?(opts) do
          close_all_sse_subscribers(opts)
          {:reply, {:ok, %{state: "stopping"}}, %{state | phase: :stopping}}
        else
          :ets.insert(table, {:open, true})
          {:reply, {:error, :daemon_busy}, state}
        end
    end
  end

  def handle_call(:begin_drain, _from, %{opts: opts} = state) do
    table = opts[:maintenance_table]

    cond do
      not is_pid(opts[:shutdown_owner]) or not Process.alive?(opts[:shutdown_owner]) ->
        {:reply, {:error, :shutdown_not_supported}, state}

      state.phase in [:draining, :stopping] ->
        timeout_ms = compute_shutdown_timeout_ms(opts)

        {:reply, {:ok, %{state: phase_string(state.phase), shutdown_timeout_ms: timeout_ms}},
         state}

      true ->
        :ets.insert(table, [{:open, false}, {:draining, true}])
        notify_sessions_enter_drain(opts)
        state = %{state | phase: :draining}
        state = maybe_finish_drain(state)
        timeout_ms = compute_shutdown_timeout_ms(opts)

        {:reply, {:ok, %{state: phase_string(state.phase), shutdown_timeout_ms: timeout_ms}},
         state}
    end
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    {ref, reservations} = Map.pop(state.reservations, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    state = %{state | reservations: reservations}

    state =
      if state.phase == :draining and map_size(reservations) == 0 do
        maybe_finish_drain(state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{recovery_ref: ref} = state) do
    state = %{state | recovery_ref: nil}

    state =
      if state.phase == :draining and map_size(state.reservations) == 0 do
        maybe_finish_drain(state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    reservations =
      if state.reservations[pid] == ref,
        do: Map.delete(state.reservations, pid),
        else: state.reservations

    state = %{state | reservations: reservations}

    state =
      if state.phase == :draining and map_size(reservations) == 0 do
        maybe_finish_drain(state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(:check_drain, %{phase: :draining} = state) do
    state = %{state | drain_timer: nil}
    {:noreply, maybe_finish_drain(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_finish_drain(
         %{phase: :draining, opts: opts, reservations: reservations, recovery_ref: recovery_ref} =
           state
       ) do
    if is_nil(recovery_ref) and map_size(reservations) == 0 and drained?(opts) do
      if state.drain_timer, do: Process.cancel_timer(state.drain_timer)
      close_all_sse_subscribers(opts)
      send(opts[:shutdown_owner], :shutdown_drained)
      %{state | phase: :stopping, drain_timer: nil}
    else
      arm_drain_poll(state)
    end
  end

  defp close_all_sse_subscribers(opts) do
    pubsub = opts[:pubsub]

    if not is_nil(pubsub) and Process.whereis(pubsub) != nil do
      for pid <-
            Registry.select(pubsub, [
              {{:catalog, :"$1", :_}, [], [:"$1"]},
              {{{:conversation, :_, :_}, :"$1", :_}, [], [:"$1"]}
            ]) do
        send(pid, {:close_sse, :shutdown})
      end
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp arm_drain_poll(%{drain_timer: nil} = state) do
    %{state | drain_timer: Process.send_after(self(), :check_drain, @drain_poll_ms)}
  end

  defp arm_drain_poll(state), do: state

  defp notify_sessions_enter_drain(opts) do
    for pid <- live_session_pids(opts) do
      send(pid, :enter_drain)
    end

    :ok
  end

  defp live_session_pids(opts) do
    Registry.select(opts[:registry], [{{{:session, :_}, :"$1", :_}, [], [:"$1"]}])
  catch
    :exit, _ -> []
  end

  defp drained?(opts) do
    sessions_drained? =
      Enum.all?(live_session_pids(opts), fn pid ->
        try do
          GenServer.call(pid, :drained, 5_000) == true
        catch
          :exit, {:noproc, _} -> true
          :exit, _ -> false
        end
      end)

    sessions_drained? and accounts_drained?(opts[:accounts])
  end

  defp accounts_drained?(nil), do: true

  defp accounts_drained?(accounts) do
    try do
      GenServer.call(accounts, :drained, 5_000) == true
    catch
      :exit, {:noproc, _} -> true
      :exit, _ -> false
    end
  end

  defp count_active_workers(opts) do
    session_workers =
      Enum.reduce(live_session_pids(opts), 0, fn pid, acc ->
        try do
          acc + GenServer.call(pid, :active_worker_count, 2_000)
        catch
          :exit, _ -> acc
        end
      end)

    account_refreshes =
      case opts[:accounts] do
        nil ->
          0

        accounts ->
          try do
            GenServer.call(accounts, :active_refresh_count, 2_000)
          catch
            :exit, _ -> 0
          end
      end

    session_workers + account_refreshes
  end

  @doc false
  def compute_shutdown_timeout_ms(opts) do
    base_floor_ms = env_or_opt_shutdown_timeout_ms(opts)

    session_remaining_ms =
      Enum.reduce(live_session_pids(opts), 0, fn pid, acc ->
        try do
          max(acc, GenServer.call(pid, :max_worker_remaining_ms, 2_000))
        catch
          :exit, _ -> acc
        end
      end)

    account_remaining_ms =
      case opts[:accounts] do
        nil ->
          0

        accounts ->
          try do
            if GenServer.call(accounts, :active_refresh_count, 2_000) > 0 do
              @account_refresh_timeout_ms
            else
              0
            end
          catch
            :exit, _ -> 0
          end
      end

    max_remaining_ms = max(session_remaining_ms, account_remaining_ms)

    dynamic_required_ms =
      if max_remaining_ms > 0, do: max_remaining_ms + @shutdown_commit_grace_ms, else: 0

    max(base_floor_ms, dynamic_required_ms)
  end

  defp env_or_opt_shutdown_timeout_ms(opts) do
    case Keyword.get(opts, :shutdown_timeout_ms) do
      ms when is_integer(ms) and ms > 0 ->
        ms

      _ ->
        case System.get_env("H_SHUTDOWN_TIMEOUT_MS") do
          nil ->
            @default_shutdown_timeout_ms

          raw ->
            case Integer.parse(String.trim(raw)) do
              {ms, ""} when ms > 0 -> ms
              _ -> @default_shutdown_timeout_ms
            end
        end
    end
  end

  defp phase_string(:running), do: "running"
  defp phase_string(:draining), do: "draining"
  defp phase_string(:stopping), do: "stopping"

  defp idle?(opts) do
    # A canceled caller may already be past the gate in a coordinator.
    # Synchronize once with each live session before trusting the catalog.
    deadline = System.monotonic_time(:millisecond) + 1500
    servers = live_session_pids(opts)

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
