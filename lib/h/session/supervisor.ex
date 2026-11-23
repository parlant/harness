defmodule H.Session.Supervisor do
  @moduledoc """
  Per-session `:one_for_all` supervision boundary (`Task.Supervisor` + `H.Session.Server`).

  Started under `DynamicSupervisor` with `restart: :temporary` so a failing
  session never consumes the shared `DynamicSupervisor` restart budget or
  cascades across healthy sessions. Exceeding the internal restart budget
  (`max_restarts: 2, max_seconds: 5`) or hitting an unrecoverable storage error
  quarantines the session in `H.Catalog` and stops cleanly.
  """

  use GenServer

  @doc "Returns a `:temporary` supervisor child spec for `DynamicSupervisor`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :supervisor
    }
  end

  @doc "Starts the per-session supervisor wrapper."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    registry = Keyword.get(opts, :registry, H.Registry)
    idle_exit = :atomics.new(1, [])

    gen_opts =
      if is_atom(registry) and not is_nil(registry) and Process.whereis(registry) != nil do
        [name: {:via, Registry, {registry, {:session_supervisor, session_id}}}]
      else
        []
      end

    GenServer.start_link(__MODULE__, {opts, idle_exit}, gen_opts)
  end

  @doc """
  Cleanly stops and unloads the per-session supervisor and its children from RAM
  without quarantining the session in `H.Catalog`.
  """
  @spec stop_session(atom(), Supervisor.supervisor(), String.t()) :: :ok
  def stop_session(registry, runtime_sup, session_id)
      when is_atom(registry) and is_binary(session_id) do
    if not is_nil(registry) and Process.whereis(registry) != nil do
      server_pid =
        case Registry.lookup(registry, {:session, session_id}) do
          [{pid, _}] -> pid
          [] -> nil
        end

      case Registry.lookup(registry, {:session_supervisor, session_id}) do
        [{sup_pid, _}] when is_pid(sup_pid) ->
          sup_ref = Process.monitor(sup_pid)
          srv_ref = if is_pid(server_pid), do: Process.monitor(server_pid)

          try do
            DynamicSupervisor.terminate_child(runtime_sup, sup_pid)
          catch
            :exit, _ -> :ok
          end

          receive do
            {:DOWN, ^sup_ref, :process, ^sup_pid, _} -> :ok
          after
            5_500 -> Process.demonitor(sup_ref, [:flush])
          end

          if srv_ref do
            receive do
              {:DOWN, ^srv_ref, :process, ^server_pid, _} -> :ok
            after
              1_000 -> Process.demonitor(srv_ref, [:flush])
            end
          end

          await_registry_cleanup(registry, session_id, 50)

        [] ->
          if is_pid(server_pid) and Process.alive?(server_pid) do
            srv_ref = Process.monitor(server_pid)

            try do
              H.Session.Server.close(server_pid, :shutdown)
            catch
              :exit, _ -> :ok
            end

            receive do
              {:DOWN, ^srv_ref, :process, ^server_pid, _} -> :ok
            after
              5_500 -> Process.demonitor(srv_ref, [:flush])
            end

            await_registry_cleanup(registry, session_id, 50)
          else
            :ok
          end
      end
    else
      :ok
    end
  end

  defp await_registry_cleanup(_registry, _session_id, 0), do: :ok

  defp await_registry_cleanup(registry, session_id, attempts) do
    if Registry.lookup(registry, {:session, session_id}) == [] and
         Registry.lookup(registry, {:session_supervisor, session_id}) == [] do
      :ok
    else
      Process.sleep(5)
      await_registry_cleanup(registry, session_id, attempts - 1)
    end
  end

  @impl true
  def init({opts, idle_exit}) do
    Process.flag(:trap_exit, true)

    session_id = Keyword.fetch!(opts, :session_id)
    registry = Keyword.get(opts, :registry, H.Registry)
    catalog = Keyword.get(opts, :catalog, H.Catalog)
    max_restarts = Keyword.get(opts, :max_restarts, 2)
    max_seconds = Keyword.get(opts, :max_seconds, 5)

    task_sup_name = {:via, Registry, {registry, {:session_tasks, session_id}}}

    # OTP uses :shutdown both for significant-child exit and exhausted restarts.
    # Only the coordinator can mark a successfully checkpointed idle exit. The
    # Registry value lets a caller distinguish a retired PID from a crashed one.
    server_name = {:via, Registry, {registry, {:session, session_id}, idle_exit}}

    server_opts =
      opts
      |> Keyword.put(:name, server_name)
      |> Keyword.put(:task_sup, task_sup_name)
      |> Keyword.put(:idle_exit, idle_exit)

    children = [
      %{
        id: :task_sup,
        start: {Task.Supervisor, :start_link, [[name: task_sup_name]]},
        restart: :permanent,
        type: :supervisor
      },
      %{
        id: H.Session.Server,
        start: {H.Session.Server, :start_link, [server_opts]},
        restart: :transient,
        significant: true,
        type: :worker
      }
    ]

    sup_opts = [
      strategy: :one_for_all,
      auto_shutdown: :any_significant,
      max_restarts: max_restarts,
      max_seconds: max_seconds
    ]

    case Supervisor.start_link(children, sup_opts) do
      {:ok, sup_pid} ->
        {:ok, %{sup: sup_pid, session_id: session_id, catalog: catalog, idle_exit: idle_exit}}

      {:error, reason} ->
        quarantine_reason = unwrap_start_error(reason)
        safe_quarantine(catalog, session_id, quarantine_reason)
        {:stop, quarantine_reason}
    end
  end

  @doc false
  def idly_retired?(marker) when is_reference(marker), do: :atomics.get(marker, 1) == 1
  def idly_retired?(_marker), do: false

  @impl true
  def handle_info({:EXIT, sup_pid, reason}, %{sup: sup_pid} = state) do
    cond do
      reason == :shutdown and idly_retired?(state.idle_exit) ->
        broadcast_unloaded(state.catalog, state.session_id)

      reason != :normal ->
        quarantine_reason = unwrap_exit_reason(reason)
        safe_quarantine(state.catalog, state.session_id, quarantine_reason)

      true ->
        :ok
    end

    {:stop, :normal, %{state | sup: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{sup: sup_pid}) when is_pid(sup_pid) do
    if Process.alive?(sup_pid) do
      try do
        Supervisor.stop(sup_pid, :shutdown, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp unwrap_start_error({:shutdown, {:failed_to_start_child, H.Session.Server, reason}}),
    do: reason

  defp unwrap_start_error(reason), do: reason

  defp unwrap_exit_reason(:shutdown), do: "max_restarts_exceeded"
  defp unwrap_exit_reason({:shutdown, reason}), do: reason
  defp unwrap_exit_reason(reason), do: reason

  defp broadcast_unloaded(nil, _session_id), do: :ok

  defp broadcast_unloaded(catalog, session_id) do
    # The coordinator is gone, but this wrapper still owns its name. A new
    # coordinator cannot register until the unloaded event has been published.
    H.Catalog.broadcast_live_state(catalog, session_id)
  catch
    :exit, _ -> :ok
  end

  defp safe_quarantine(nil, _session_id, _reason), do: :ok

  defp safe_quarantine(catalog, session_id, reason) do
    if GenServer.whereis(catalog) do
      try do
        H.Catalog.quarantine(catalog, session_id, reason)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end
end
