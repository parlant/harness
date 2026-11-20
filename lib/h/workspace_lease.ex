defmodule H.WorkspaceLease do
  @moduledoc """
  Coordinates per-workspace mutating tool leases by `{env_id, canonical_cwd}`
  so concurrent coding runs do not clobber the same working tree while keeping
  separate execution environments isolated.
  """

  use GenServer

  @type server :: GenServer.server()
  @type workspace_key :: {env_id :: String.t(), cwd :: String.t()} | String.t()
  # Normal holders are {session_id, conversation_id}. A review save briefly
  # holds {session_id, :file_review, ref} and cannot be stopped as a conversation.
  @type holder_key :: term()

  defguardp is_valid_workspace_key(key)
            when is_binary(key) or
                   (is_tuple(key) and tuple_size(key) == 2 and is_binary(elem(key, 0)) and
                      elem(key, 0) != "" and is_binary(elem(key, 1)))

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @spec acquire(server(), workspace_key(), holder_key(), pid()) ::
          :ok | {:error, {:workspace_busy, holder_key()}}
  def acquire(server \\ __MODULE__, workspace_key, holder_key, holder_pid)
      when is_valid_workspace_key(workspace_key) and is_pid(holder_pid) do
    GenServer.call(
      server,
      {:acquire, normalize_workspace_key(workspace_key), holder_key, holder_pid}
    )
  end

  @doc "Acquires immediately or queues a monitored waiter for a reserved, signalled handoff."
  @spec acquire_or_wait(server(), workspace_key(), holder_key(), pid(), reference()) ::
          :ok | {:waiting, holder_key(), String.t()}
  def acquire_or_wait(server, workspace_key, holder_key, holder_pid, token)
      when is_valid_workspace_key(workspace_key) and is_pid(holder_pid) and is_reference(token) do
    GenServer.call(
      server,
      {:acquire_or_wait, normalize_workspace_key(workspace_key), holder_key, holder_pid, token}
    )
  end

  @doc "Requests cancellation by the current owner; never forcibly clears a live lease."
  def stop_holder(server, workspace_key, holder_key, token, lease_id) do
    GenServer.call(
      server,
      {:stop_holder, normalize_workspace_key(workspace_key), holder_key, token, lease_id}
    )
  end

  def current?(server, workspace_key, holder_key, lease_id) do
    GenServer.call(
      server,
      {:current?, normalize_workspace_key(workspace_key), holder_key, lease_id}
    )
  end

  @spec release(server(), workspace_key(), holder_key()) :: :ok
  def release(server \\ __MODULE__, workspace_key, holder_key)
      when is_valid_workspace_key(workspace_key) do
    GenServer.call(server, {:release, normalize_workspace_key(workspace_key), holder_key})
  end

  @impl true
  def init(_opts) do
    {:ok, %{leases: %{}, monitors: %{}, waiters: %{}}}
  end

  @impl true
  def handle_call({:acquire, canonical_cwd, holder_key, holder_pid}, from, state) do
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
            |> handoff(canonical_cwd)

          handle_call({:acquire, canonical_cwd, holder_key, holder_pid}, from, state)
        end
    end
  end

  def handle_call({:acquire_or_wait, cwd, holder_key, pid, token}, from, state) do
    case handle_call({:acquire, cwd, holder_key, pid}, from, state) do
      {:reply, :ok, state} ->
        {:reply, :ok, state}

      {:reply, {:error, {:workspace_busy, owner}}, state} ->
        state = remove_waiters(state, cwd, &(&1.holder_key == holder_key))
        ref = Process.monitor(pid)
        waiter = %{holder_key: holder_key, pid: pid, token: token, ref: ref}

        state = %{
          state
          | waiters: Map.update(state.waiters, cwd, [waiter], &(&1 ++ [waiter])),
            monitors: Map.put(state.monitors, ref, {:waiter, cwd})
        }

        {:reply, {:waiting, owner, state.leases[cwd].id}, state}
    end
  end

  def handle_call({:stop_holder, cwd, holder_key, token, lease_id}, _from, state) do
    waiters = Map.get(state.waiters, cwd, [])
    waiter = Enum.find(waiters, &(&1.holder_key == holder_key and &1.token == token))

    case {Map.get(state.leases, cwd), waiter} do
      {%{id: ^lease_id, holder_key: owner, pid: pid}, %{} = waiter} ->
        unless match?({_, :file_review, _}, owner) do
          send(pid, {:stop_workspace_holder, cwd, owner, lease_id})
        end

        {:reply, :ok,
         %{state | waiters: Map.put(state.waiters, cwd, [waiter | List.delete(waiters, waiter)])}}

      _ ->
        {:reply, {:error, :stale_wait}, state}
    end
  end

  def handle_call({:current?, cwd, holder_key, lease_id}, _from, state) do
    current = match?(%{holder_key: ^holder_key, id: ^lease_id}, Map.get(state.leases, cwd))
    {:reply, current, state}
  end

  def handle_call({:release, canonical_cwd, holder_key}, _from, state) do
    state = remove_waiters(state, canonical_cwd, &(&1.holder_key == holder_key))

    case Map.get(state.leases, canonical_cwd) do
      %{holder_key: ^holder_key, ref: ref} ->
        state = state |> revoke_lease(canonical_cwd, ref) |> handoff(canonical_cwd)
        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {{:waiter, cwd}, monitors} ->
        {:noreply, remove_waiters(%{state | monitors: monitors}, cwd, &(&1.ref == ref))}

      {canonical_cwd, monitors} ->
        case Map.get(state.leases, canonical_cwd) do
          %{ref: ^ref} ->
            state = %{state | leases: Map.delete(state.leases, canonical_cwd), monitors: monitors}
            {:noreply, handoff(state, canonical_cwd)}

          _ ->
            {:noreply, %{state | monitors: monitors}}
        end
    end
  end

  defp grant_lease(state, canonical_cwd, holder_key, holder_pid) do
    ref = Process.monitor(holder_pid)

    lease = %{
      holder_key: holder_key,
      pid: holder_pid,
      ref: ref,
      id: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }

    Enum.each(Map.get(state.waiters, canonical_cwd, []), fn waiter ->
      send(waiter.pid, {:workspace_lease_blocked, waiter.token, holder_key, lease.id})
    end)

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

  defp remove_waiters(state, cwd, predicate) do
    {removed, kept} = Enum.split_with(Map.get(state.waiters, cwd, []), predicate)

    monitors =
      Enum.reduce(removed, state.monitors, fn waiter, acc ->
        Process.demonitor(waiter.ref, [:flush])
        Map.delete(acc, waiter.ref)
      end)

    waiters =
      if kept == [], do: Map.delete(state.waiters, cwd), else: Map.put(state.waiters, cwd, kept)

    %{state | waiters: waiters, monitors: monitors}
  end

  defp handoff(state, cwd) do
    case Map.get(state.waiters, cwd, []) do
      [] ->
        state

      [waiter | _] ->
        state = remove_waiters(state, cwd, &(&1.ref == waiter.ref))

        if Process.alive?(waiter.pid) do
          state = grant_lease(state, cwd, waiter.holder_key, waiter.pid)
          send(waiter.pid, {:workspace_lease_granted, waiter.token})
          state
        else
          handoff(state, cwd)
        end
    end
  end

  defp normalize_workspace_key(cwd) when is_binary(cwd), do: {"host", Path.expand(cwd)}
  defp normalize_workspace_key({"host", cwd}) when is_binary(cwd), do: {"host", Path.expand(cwd)}
  defp normalize_workspace_key({env_id, cwd}), do: {env_id, normalize_remote_cwd(cwd)}

  defp normalize_remote_cwd("/"), do: "/"

  defp normalize_remote_cwd(cwd) do
    case String.trim_trailing(cwd, "/") do
      "" -> if String.starts_with?(cwd, "/"), do: "/", else: ""
      trimmed -> trimmed
    end
  end
end
