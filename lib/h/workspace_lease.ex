defmodule H.WorkspaceLease do
  @moduledoc """
  Coordinates per-workspace mutating tool leases by canonical `cwd` so
  concurrent coding runs do not clobber the same working tree.
  """

  use GenServer

  @type server :: GenServer.server()
  @type holder_key :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @spec acquire(server(), String.t(), holder_key(), pid()) ::
          :ok | {:error, {:workspace_busy, holder_key()}}
  def acquire(server \\ __MODULE__, cwd, holder_key, holder_pid)
      when is_binary(cwd) and is_pid(holder_pid) do
    GenServer.call(server, {:acquire, Path.expand(cwd), holder_key, holder_pid})
  end

  @spec release(server(), String.t(), holder_key()) :: :ok
  def release(server \\ __MODULE__, cwd, holder_key) when is_binary(cwd) do
    GenServer.call(server, {:release, Path.expand(cwd), holder_key})
  end

  @impl true
  def init(_opts) do
    {:ok, %{leases: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:acquire, canonical_cwd, holder_key, holder_pid}, _from, state) do
    case Map.get(state.leases, canonical_cwd) do
      nil ->
        state = grant_lease(state, canonical_cwd, holder_key, holder_pid)
        {:reply, :ok, state}

      %{holder_key: ^holder_key, pid: ^holder_pid} ->
        {:reply, :ok, state}

      %{holder_key: ^holder_key, ref: old_ref} ->
        state =
          state
          |> revoke_lease(canonical_cwd, old_ref)
          |> grant_lease(canonical_cwd, holder_key, holder_pid)

        {:reply, :ok, state}

      %{holder_key: existing_key, pid: existing_pid, ref: old_ref} ->
        if Process.alive?(existing_pid) do
          {:reply, {:error, {:workspace_busy, existing_key}}, state}
        else
          state =
            state
            |> revoke_lease(canonical_cwd, old_ref)
            |> grant_lease(canonical_cwd, holder_key, holder_pid)

          {:reply, :ok, state}
        end
    end
  end

  def handle_call({:release, canonical_cwd, holder_key}, _from, state) do
    case Map.get(state.leases, canonical_cwd) do
      %{holder_key: ^holder_key, ref: ref} ->
        {:reply, :ok, revoke_lease(state, canonical_cwd, ref)}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {canonical_cwd, monitors} ->
        leases =
          case Map.get(state.leases, canonical_cwd) do
            %{ref: ^ref} -> Map.delete(state.leases, canonical_cwd)
            _ -> state.leases
          end

        {:noreply, %{state | leases: leases, monitors: monitors}}
    end
  end

  defp grant_lease(state, canonical_cwd, holder_key, holder_pid) do
    ref = Process.monitor(holder_pid)
    lease = %{holder_key: holder_key, pid: holder_pid, ref: ref}

    %{
      state
      | leases: Map.put(state.leases, canonical_cwd, lease),
        monitors: Map.put(state.monitors, ref, canonical_cwd)
    }
  end

  defp revoke_lease(state, canonical_cwd, ref) do
    Process.demonitor(ref, [:flush])

    %{
      state
      | leases: Map.delete(state.leases, canonical_cwd),
        monitors: Map.delete(state.monitors, ref)
    }
  end
end
