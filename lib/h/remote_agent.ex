defmodule H.RemoteAgent do
  @moduledoc """
  In-VM cooperative remote execution agent GenServer (`H.ExecutionEnv.Remote` transport seam).

  Owns a host-backed `H.ExecutionEnv.t()` (typically `H.ExecutionEnv.Host`) and an explicit
  plain environment descriptor (`%{id: id, kind: "remote", cwd: cwd}`). This process is
  ephemeral—never durable and never storing credentials or auth secrets.

  ## Future Network Transport

  This module serves as the local in-VM RPC endpoint proving fencing, lease-TTL heartbeats,
  bounded execution output, and process-group reaping semantics. A future Slice 8 network
  adapter (authenticated mTLS WebSocket/HTTPS or SSH subsystem) will replace the `GenServer`
  call/message framing while preserving this protocol contract.
  """

  use GenServer

  alias H.ExecutionEnv

  @type server :: GenServer.server()
  @type fence :: {term(), term(), term(), term()}
  @type descriptor :: %{id: String.t(), kind: String.t(), cwd: String.t()}

  @term_wait_ms 1_500

  @doc """
  Starts a `H.RemoteAgent` process.

  ## Options
    * `:env` (required) - base `H.ExecutionEnv.t()` instance owned by the agent
    * `:id` - non-empty environment identifier string (defaults to `H.ExecutionEnv.env_id(env)`)
    * `:name` - optional GenServer registration name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc "Returns the plain JSON-safe environment descriptor (`id`, `kind: \"remote\"`, `cwd`)."
  @spec descriptor(server()) :: descriptor()
  def descriptor(agent), do: GenServer.call(agent, :descriptor)

  @doc "Returns the agent's canonical base working directory."
  @spec cwd(server()) :: String.t()
  def cwd(agent), do: GenServer.call(agent, :cwd)

  @doc "Remotely resolves `path` and verifies that it exists as a directory."
  @spec bind_cwd(server(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def bind_cwd(agent, path, opts \\ []) when is_binary(path) and is_list(opts) do
    call_agent(agent, {:bind_cwd, path, opts})
  end

  @doc "Remotely resolves `path` using target OS POSIX path semantics."
  @spec resolve_path(server(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_path(agent, path, opts \\ []) when is_binary(path) and is_list(opts) do
    call_agent(agent, {:resolve_path, path, opts})
  end

  @doc "Reads bounded UTF-8 lines from a remote file."
  @spec read_file_lines(server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_file_lines(agent, path, opts \\ []) when is_binary(path) and is_list(opts) do
    call_agent(agent, {:read_file_lines, path, opts})
  end

  @doc "Reads bounded raw bytes from a remote file."
  @spec read_file_bytes(server(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file_bytes(agent, path, opts \\ []) when is_binary(path) and is_list(opts) do
    call_agent(agent, {:read_file_bytes, path, opts})
  end

  @doc "Atomically writes `content` to a remote file, creating missing parent directories."
  @spec write_file(server(), String.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write_file(agent, path, content, opts \\ []) when is_binary(path) and is_list(opts) do
    call_agent(agent, {:write_file, path, content, opts})
  end

  @doc "Lists a remote directory with sorting, pagination, hidden/dir filters, and markers."
  @spec list_dir(server(), String.t(), keyword()) ::
          {:ok, %{entries: [map()], next_cursor: nil | non_neg_integer()}} | {:error, term()}
  def list_dir(agent, path, opts \\ []) when is_binary(path) and is_list(opts) do
    call_agent(agent, {:list_dir, path, opts})
  end

  @doc """
  Executes `command` on the remote agent under fence and optional lease semantics.

  Supports `:session_id`, `:incarnation`, `:task_id`, `:attempt_id`, `:lease_ms`, `:cwd`,
  `:timeout_ms`, `:window_bytes`, `:window_lines`, `:abort_ref`, `:on_output`, and `:env`.
  Rejects duplicate or older fences with `{:error, :stale_fence}`.
  """
  @spec exec(server(), ExecutionEnv.command(), keyword()) ::
          {:ok, ExecutionEnv.exec_result()} | {:error, term()}
  def exec(agent, command, opts \\ []) when is_list(opts) do
    abort_ref = Keyword.get(opts, :abort_ref)
    on_output = Keyword.get(opts, :on_output)

    case call_agent(agent, {:start_exec, self(), command, opts}) do
      {:ok, agent_pid, op_ref, fence} ->
        agent_mon = Process.monitor(agent_pid)

        try do
          exec_wait_loop(agent, agent_pid, agent_mon, op_ref, fence, abort_ref, on_output)
        after
          Process.demonitor(agent_mon, [:flush])
        end

      {:error, _reason} = err ->
        err
    end
  end

  @doc "Renews the lease TTL (in milliseconds) for an active fenced execution."
  @spec renew_lease(server(), fence(), pos_integer()) ::
          :ok | {:error, :not_found | :invalid_lease_ms | {:agent_down, term()}}
  def renew_lease(agent, {_session_id, _inc, _task_id, _attempt_id} = fence, lease_ms) do
    if is_integer(lease_ms) and lease_ms > 0 do
      call_agent(agent, {:renew_lease, fence, lease_ms})
    else
      {:error, :invalid_lease_ms}
    end
  end

  @doc "Aborts an active fenced execution and waits for its process group to be reaped."
  @spec abort(server(), fence()) :: :ok | {:error, :not_found | {:agent_down, term()}}
  def abort(agent, {_session_id, _inc, _task_id, _attempt_id} = fence) do
    call_agent(agent, {:abort, fence}, :infinity)
  end

  @doc "Returns the list of currently active execution fences on this agent."
  @spec active_fences(server()) :: [fence()]
  def active_fences(agent), do: GenServer.call(agent, :active_fences)

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    env =
      case Keyword.fetch(opts, :env) do
        {:ok, {mod, _env_state} = e} when is_atom(mod) ->
          e

        {:ok, other} ->
          raise ArgumentError, "expected :env to be H.ExecutionEnv.t(), got: #{inspect(other)}"

        :error ->
          raise ArgumentError, "missing required :env option"
      end

    id =
      case Keyword.get(opts, :id) do
        nil -> ExecutionEnv.env_id(env)
        val when is_binary(val) and val != "" -> val
        other -> raise ArgumentError, "expected non-empty string :id, got: #{inspect(other)}"
      end

    base_cwd = ExecutionEnv.cwd(env)

    state = %{
      id: id,
      env: env,
      cwd: base_cwd,
      active_ops: %{},
      worker_to_fence: %{},
      caller_monitors: %{},
      seen_fences: MapSet.new(),
      session_incarnations: %{},
      task_attempts: %{},
      next_auto_seq: 1
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:descriptor, _from, state) do
    {:reply, %{id: state.id, kind: "remote", cwd: state.cwd}, state}
  end

  def handle_call(:cwd, _from, state) do
    {:reply, state.cwd, state}
  end

  def handle_call(:active_fences, _from, state) do
    {:reply, Map.keys(state.active_ops), state}
  end

  def handle_call({:resolve_path, path, opts}, _from, state) do
    reply =
      with {:ok, target_env, _op_opts} <- scoped_env(state.env, opts) do
        ExecutionEnv.resolve_path(target_env, path)
      end

    {:reply, reply, state}
  end

  def handle_call({:bind_cwd, path, opts}, _from, state) do
    reply =
      with {:ok, target_env, _op_opts} <- scoped_env(state.env, opts),
           {:ok, bound_env} <- ExecutionEnv.bind_cwd(target_env, path) do
        {:ok, ExecutionEnv.cwd(bound_env)}
      end

    {:reply, reply, state}
  end

  def handle_call({:read_file_lines, path, opts}, _from, state) do
    reply =
      with {:ok, target_env, op_opts} <- scoped_env(state.env, opts) do
        ExecutionEnv.read_file_lines(target_env, path, op_opts)
      end

    {:reply, reply, state}
  end

  def handle_call({:read_file_bytes, path, opts}, _from, state) do
    reply =
      with {:ok, target_env, op_opts} <- scoped_env(state.env, opts) do
        ExecutionEnv.read_file_bytes(target_env, path, op_opts)
      end

    {:reply, reply, state}
  end

  def handle_call({:write_file, path, content, opts}, _from, state) do
    reply =
      with {:ok, target_env, _op_opts} <- scoped_env(state.env, opts) do
        ExecutionEnv.write_file(target_env, path, content)
      end

    {:reply, reply, state}
  end

  def handle_call({:list_dir, path, opts}, _from, state) do
    reply =
      with {:ok, target_env, op_opts} <- scoped_env(state.env, opts) do
        ExecutionEnv.list_dir(target_env, path, op_opts)
      end

    {:reply, reply, state}
  end

  def handle_call({:start_exec, caller_pid, command, opts}, _from, state) do
    with {:ok, lease_ms} <- validate_lease_ms(Keyword.get(opts, :lease_ms)),
         {:ok, target_env, stripped_opts} <- scoped_env(state.env, opts),
         {:ok, fence, state} <- allocate_and_validate_fence(opts, state) do
      op_ref = make_ref()
      host_abort_ref = make_ref()
      agent_pid = self()

      host_opts =
        stripped_opts
        |> Keyword.drop([
          :session_id,
          :incarnation,
          :task_id,
          :attempt_id,
          :lease_ms,
          :abort_ref,
          :on_output
        ])
        |> Keyword.put(:abort_ref, host_abort_ref)
        |> Keyword.put(:on_output, fn chunk ->
          send(caller_pid, {:remote_exec_output, op_ref, chunk})
        end)

      {:ok, worker_pid} =
        Task.start(fn ->
          result = ExecutionEnv.exec(target_env, command, host_opts)
          send(agent_pid, {:remote_worker_done, op_ref, fence, result})
        end)

      worker_mon = Process.monitor(worker_pid)
      caller_mon = Process.monitor(caller_pid)

      {lease_timer_ref, lease_token} = schedule_lease_timer(fence, lease_ms)

      op = %{
        op_ref: op_ref,
        fence: fence,
        caller_pid: caller_pid,
        caller_mon: caller_mon,
        worker_pid: worker_pid,
        worker_mon: worker_mon,
        host_abort_ref: host_abort_ref,
        lease_timer_ref: lease_timer_ref,
        lease_token: lease_token,
        abort_reason: nil,
        abort_waiters: []
      }

      next_state = %{
        state
        | active_ops: Map.put(state.active_ops, fence, op),
          worker_to_fence: Map.put(state.worker_to_fence, worker_mon, fence),
          caller_monitors: Map.put(state.caller_monitors, caller_mon, fence)
      }

      {:reply, {:ok, agent_pid, op_ref, fence}, next_state}
    else
      {:error, _reason} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:renew_lease, fence, lease_ms}, _from, state) do
    case Map.get(state.active_ops, fence) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{abort_reason: reason} when not is_nil(reason) ->
        {:reply, {:error, :not_found}, state}

      op ->
        cancel_timer_safely(op.lease_timer_ref)
        {timer_ref, token} = schedule_lease_timer(fence, lease_ms)
        updated_op = %{op | lease_timer_ref: timer_ref, lease_token: token}
        {:reply, :ok, %{state | active_ops: Map.put(state.active_ops, fence, updated_op)}}
    end
  end

  def handle_call({:abort, fence}, from, state) do
    case Map.get(state.active_ops, fence) do
      nil ->
        {:reply, {:error, :not_found}, state}

      op ->
        updated_op = trigger_abort(op, :aborted)
        updated_op = %{updated_op | abort_waiters: [from | updated_op.abort_waiters]}
        {:noreply, %{state | active_ops: Map.put(state.active_ops, fence, updated_op)}}
    end
  end

  @impl true
  def handle_info({:remote_worker_done, op_ref, fence, result}, state) do
    case Map.get(state.active_ops, fence) do
      %{op_ref: ^op_ref} = op ->
        final_result = apply_abort_reason(result, op.abort_reason)
        {:noreply, finish_op(op, final_result, :ok, state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:lease_expired, fence, lease_token}, state) do
    case Map.get(state.active_ops, fence) do
      %{lease_token: ^lease_token, abort_reason: nil} = op ->
        updated_op = trigger_abort(op, :lease_expired)
        {:noreply, %{state | active_ops: Map.put(state.active_ops, fence, updated_op)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.caller_monitors, ref) ->
        {fence, caller_monitors} = Map.pop!(state.caller_monitors, ref)
        state = %{state | caller_monitors: caller_monitors}

        case Map.get(state.active_ops, fence) do
          nil ->
            {:noreply, state}

          op ->
            updated_op = trigger_abort(op, op.abort_reason || :client_down)
            {:noreply, %{state | active_ops: Map.put(state.active_ops, fence, updated_op)}}
        end

      Map.has_key?(state.worker_to_fence, ref) ->
        {fence, worker_to_fence} = Map.pop!(state.worker_to_fence, ref)
        state = %{state | worker_to_fence: worker_to_fence}

        case Map.get(state.active_ops, fence) do
          nil ->
            {:noreply, state}

          op ->
            {:noreply, finish_op(op, {:error, {:worker_crashed, reason}}, :ok, state)}
        end

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Enum.each(state.active_ops, fn {_fence, op} ->
      cancel_timer_safely(op.lease_timer_ref)
      Process.demonitor(op.caller_mon, [:flush])
      send(op.worker_pid, {:abort_exec, op.host_abort_ref})
      send(op.caller_pid, {:remote_exec_result, op.op_ref, {:error, {:agent_down, reason}}})

      Enum.each(op.abort_waiters, fn waiter ->
        GenServer.reply(waiter, {:error, {:agent_down, reason}})
      end)
    end)

    deadline = System.monotonic_time(:millisecond) + @term_wait_ms

    Enum.each(state.active_ops, fn {_fence, op} ->
      wait_worker_down(op.worker_pid, op.worker_mon, deadline)
    end)

    :ok
  end

  # --- Client wait loop ---

  defp exec_wait_loop(agent, agent_pid, agent_mon, op_ref, fence, abort_ref, on_output) do
    receive do
      {:remote_exec_output, ^op_ref, chunk} ->
        if is_function(on_output, 1), do: on_output.(chunk)
        exec_wait_loop(agent, agent_pid, agent_mon, op_ref, fence, abort_ref, on_output)

      {:remote_exec_result, ^op_ref, result} ->
        drain_exec_output(op_ref, on_output)
        result

      {:abort_exec, ^abort_ref} when not is_nil(abort_ref) ->
        _ = safe_abort(agent, fence)
        exec_wait_loop(agent, agent_pid, agent_mon, op_ref, fence, nil, on_output)

      {:DOWN, ^agent_mon, :process, ^agent_pid, reason} ->
        drain_exec_output(op_ref, on_output)
        {:error, {:agent_down, reason}}
    end
  end

  defp drain_exec_output(op_ref, on_output) do
    receive do
      {:remote_exec_output, ^op_ref, chunk} ->
        if is_function(on_output, 1), do: on_output.(chunk)
        drain_exec_output(op_ref, on_output)
    after
      0 -> :ok
    end
  end

  defp safe_abort(agent, fence) do
    call_agent(agent, {:abort, fence}, :infinity)
  end

  defp call_agent(agent, request, timeout \\ 5_000) do
    GenServer.call(agent, request, timeout)
  catch
    :exit, reason -> {:error, {:agent_down, reason}}
  end

  # --- Fencing and scoped env helpers ---

  defp scoped_env(base_env, opts) do
    case Keyword.pop(opts, :cwd) do
      {nil, op_opts} ->
        {:ok, base_env, op_opts}

      {custom_cwd, op_opts} when is_binary(custom_cwd) ->
        if String.contains?(custom_cwd, <<0>>) or not String.starts_with?(custom_cwd, "/") do
          {:error, :einval}
        else
          with {:ok, canonical_cwd} <- canonicalize_remote_cwd(base_env, custom_cwd),
               {:ok, target_env} <- replace_env_cwd(base_env, canonical_cwd) do
            {:ok, target_env, op_opts}
          end
        end

      {_other, _op_opts} ->
        {:error, :einval}
    end
  end

  defp canonicalize_remote_cwd({mod, env_state} = base_env, custom_cwd) do
    if is_map(env_state) and Map.has_key?(env_state, :cwd) do
      ExecutionEnv.resolve_path({mod, %{env_state | cwd: "/"}}, custom_cwd)
    else
      ExecutionEnv.resolve_path(base_env, custom_cwd)
    end
  end

  defp replace_env_cwd({mod, env_state} = base_env, canonical_cwd) do
    if is_map(env_state) and Map.has_key?(env_state, :cwd) do
      {:ok, {mod, %{env_state | cwd: canonical_cwd}}}
    else
      ExecutionEnv.bind_cwd(base_env, canonical_cwd)
    end
  end

  defp validate_lease_ms(nil), do: {:ok, nil}
  defp validate_lease_ms(ms) when is_integer(ms) and ms > 0, do: {:ok, ms}
  defp validate_lease_ms(_), do: {:error, :invalid_lease_ms}

  defp allocate_and_validate_fence(opts, state) do
    session_id = Keyword.get(opts, :session_id)
    incarnation = Keyword.get(opts, :incarnation)
    task_id = Keyword.get(opts, :task_id)
    attempt_id = Keyword.get(opts, :attempt_id)

    explicit_fence? =
      not is_nil(session_id) and not is_nil(incarnation) and not is_nil(task_id) and
        not is_nil(attempt_id)

    if explicit_fence? do
      fence = {session_id, incarnation, task_id, attempt_id}

      cond do
        Map.has_key?(state.active_ops, fence) ->
          {:error, :stale_fence}

        MapSet.member?(state.seen_fences, fence) ->
          {:error, :stale_fence}

        is_integer(incarnation) and
            incarnation < Map.get(state.session_incarnations, session_id, incarnation) ->
          {:error, :stale_fence}

        is_integer(attempt_id) and
            attempt_id <= Map.get(state.task_attempts, {session_id, incarnation, task_id}, -1) ->
          {:error, :stale_fence}

        true ->
          session_incarnations =
            if is_integer(incarnation) do
              Map.update(
                state.session_incarnations,
                session_id,
                incarnation,
                &max(&1, incarnation)
              )
            else
              state.session_incarnations
            end

          task_attempts =
            if is_integer(attempt_id) do
              Map.update(
                state.task_attempts,
                {session_id, incarnation, task_id},
                attempt_id,
                &max(&1, attempt_id)
              )
            else
              state.task_attempts
            end

          next_state = %{
            state
            | seen_fences: MapSet.put(state.seen_fences, fence),
              session_incarnations: session_incarnations,
              task_attempts: task_attempts
          }

          {:ok, fence, next_state}
      end
    else
      eff_session = session_id || "anon"
      eff_inc = incarnation || 0
      eff_task = task_id || 0
      seq = state.next_auto_seq
      eff_attempt = attempt_id || {:auto, seq}
      fence = {eff_session, eff_inc, eff_task, eff_attempt}

      cond do
        is_integer(eff_inc) and
            eff_inc < Map.get(state.session_incarnations, eff_session, eff_inc) ->
          {:error, :stale_fence}

        Map.has_key?(state.active_ops, fence) ->
          {:error, :stale_fence}

        true ->
          {:ok, fence, %{state | next_auto_seq: seq + 1}}
      end
    end
  end

  # --- Operation lifecycle helpers ---

  defp schedule_lease_timer(_fence, nil), do: {nil, nil}

  defp schedule_lease_timer(fence, lease_ms) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:lease_expired, fence, token}, lease_ms)
    {timer_ref, token}
  end

  defp cancel_timer_safely(nil), do: :ok

  defp cancel_timer_safely(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp trigger_abort(op, reason) do
    cancel_timer_safely(op.lease_timer_ref)
    send(op.worker_pid, {:abort_exec, op.host_abort_ref})
    %{op | lease_timer_ref: nil, abort_reason: op.abort_reason || reason}
  end

  defp apply_abort_reason({:error, %{reason: :aborted} = err}, :lease_expired) do
    {:error, %{err | reason: :lease_expired}}
  end

  defp apply_abort_reason(result, _abort_reason), do: result

  defp finish_op(op, caller_result, waiter_reply, state) do
    cancel_timer_safely(op.lease_timer_ref)
    Process.demonitor(op.worker_mon, [:flush])
    Process.demonitor(op.caller_mon, [:flush])

    send(op.caller_pid, {:remote_exec_result, op.op_ref, caller_result})

    Enum.each(op.abort_waiters, fn waiter ->
      GenServer.reply(waiter, waiter_reply)
    end)

    %{
      state
      | active_ops: Map.delete(state.active_ops, op.fence),
        worker_to_fence: Map.delete(state.worker_to_fence, op.worker_mon),
        caller_monitors: Map.delete(state.caller_monitors, op.caller_mon)
    }
  end

  defp wait_worker_down(worker_pid, worker_mon, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:DOWN, ^worker_mon, :process, ^worker_pid, _reason} ->
        :ok
    after
      remaining ->
        Process.exit(worker_pid, :kill)
        Process.demonitor(worker_mon, [:flush])
        :ok
    end
  end
end
