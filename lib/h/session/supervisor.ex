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
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    session_id = Keyword.fetch!(opts, :session_id)
    registry = Keyword.get(opts, :registry, H.Registry)
    catalog = Keyword.get(opts, :catalog, H.Catalog)
    max_restarts = Keyword.get(opts, :max_restarts, 2)
    max_seconds = Keyword.get(opts, :max_seconds, 5)

    task_sup_name = {:via, Registry, {registry, {:session_tasks, session_id}}}
    server_name = {:via, Registry, {registry, {:session, session_id}}}

    server_opts =
      opts
      |> Keyword.put(:name, server_name)
      |> Keyword.put(:task_sup, task_sup_name)

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
        {:ok, %{sup: sup_pid, session_id: session_id, catalog: catalog}}

      {:error, reason} ->
        quarantine_reason = unwrap_start_error(reason)
        safe_quarantine(catalog, session_id, quarantine_reason)
        {:stop, quarantine_reason}
    end
  end

  @impl true
  def handle_info({:EXIT, sup_pid, reason}, %{sup: sup_pid} = state) do
    if reason != :normal do
      quarantine_reason = unwrap_exit_reason(reason)
      safe_quarantine(state.catalog, state.session_id, quarantine_reason)
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
