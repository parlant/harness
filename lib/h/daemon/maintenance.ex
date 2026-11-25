defmodule H.Daemon.Maintenance do
  @moduledoc false

  # Boot monitors callers so an exited HTTP handler cannot leak a reservation.
  # Session coordinators also check this gate when staging a command: a caller
  # that died or timed out may still have an unprocessed call in their mailbox.
  def admit(opts, fun) do
    case opts[:maintenance_table] do
      nil ->
        fun.()

      table ->
        with :ok <- GenServer.call(H.Daemon.Boot, {:admit, table}) do
          try do
            fun.()
          after
            GenServer.cast(H.Daemon.Boot, {:release, self()})
          end
        end
    end
  end

  def stop_if_idle(opts) do
    with table when is_reference(table) <- opts[:maintenance_table],
         true <- :ets.lookup_element(table, :managed, 2, false) do
      GenServer.call(H.Daemon.Boot, :stop_if_idle, 10_000)
    else
      _ -> {:error, :shutdown_not_supported}
    end
  catch
    :exit, _ -> {:error, :daemon_unavailable}
  end

  def drain_and_stop(opts) do
    with table when is_reference(table) <- opts[:maintenance_table],
         true <- :ets.lookup_element(table, :managed, 2, false) do
      GenServer.call(H.Daemon.Boot, :begin_drain, 15_000)
    else
      _ -> {:error, :shutdown_not_supported}
    end
  catch
    :exit, _ -> {:error, :daemon_unavailable}
  end

  def extensions_status(opts) do
    case opts[:maintenance_table] do
      table when is_reference(table) ->
        GenServer.call(H.Daemon.Boot, :extensions_status, 5_000)

      _ ->
        {:ok,
         H.Extensions.summarize(
           H.Extensions.empty_state(Keyword.get(opts, :no_extensions, false), 1)
         )}
    end
  catch
    :exit, _ -> {:error, :daemon_unavailable}
  end

  def reload_extensions(opts) do
    case opts[:maintenance_table] do
      table when is_reference(table) ->
        GenServer.call(H.Daemon.Boot, :reload_extensions, 30_000)

      _ ->
        {:error, :reload_not_supported}
    end
  catch
    :exit, _ -> {:error, :daemon_unavailable}
  end

  def status(opts) do
    case opts[:maintenance_table] do
      table when is_reference(table) ->
        GenServer.call(H.Daemon.Boot, :status, 5_000)

      _ ->
        {:ok,
         %{
           "state" => "running",
           "active_workers" => 0,
           "shutdown_timeout_ms" => H.Daemon.Boot.compute_shutdown_timeout_ms(opts)
         }}
    end
  catch
    :exit, _ -> {:error, :daemon_unavailable}
  end
end
