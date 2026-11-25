defmodule H.ExecutionEnv.Remote do
  @moduledoc """
  Cooperative remote `H.ExecutionEnv` adapter backed by a `H.RemoteAgent` handle.

  Delegates all path resolution, directory listing (including project markers), file I/O,
  and process execution to the target remote agent without calling local `Path.expand/2`,
  `File`, or `System` directly.

  ## Local In-VM & Distributed Erlang ("Brains vs. Hands")

  `agent` can be either an in-VM `H.RemoteAgent` pid/name or a `{registered_name, node}`
  tuple targeting a `H.RemoteAgent` running on a connected remote BEAM node (for example,
  inside a Docker container or another host connected over Erlang distribution). Use
  `connect_node/3` and `env_spec_for_node/3` to isolate model/session orchestration on
  the local daemon ("brains") from sandboxed tool execution on one or more remote BEAM
  nodes ("hands"), while preserving fencing, lease-TTL heartbeats, and OS process-group
  reaping across node disconnects.

  For untrusted networks beyond Erlang distribution, a future network adapter (mTLS
  WebSocket/HTTPS or SSH subsystem) can swap into the same `H.RemoteAgent` seam without
  changing `H.Tools.*`, `H.WorkspaceLease`, or callers.
  """

  @behaviour H.ExecutionEnv

  alias H.ExecutionEnv
  alias H.RemoteAgent

  @doc """
  Connects to a remote BEAM `node` hosting a registered `H.RemoteAgent` and
  returns `{:ok, H.ExecutionEnv.t()}`.

  ## Options
    * `:agent_name` - registered `H.RemoteAgent` name on `node` (default `H.RemoteAgent`)
    * `:cookie` - optional Erlang cookie atom set for `node` via `Node.set_cookie/2`
      before connecting
    * `:env_id` - optional non-empty string override for the environment ID
    * `:default_exec_opts` - keyword list of default fence/lease/exec options
    * `:connect` - whether to call `Node.connect/1` if not already connected (default `true`)
  """
  @spec connect_node(node(), nil | String.t(), keyword()) ::
          {:ok, ExecutionEnv.t()}
          | {:error, :node_not_distributed | :node_unreachable | {:agent_down, term()} | term()}
  def connect_node(node, cwd \\ nil, opts \\ [])
      when is_atom(node) and (is_binary(cwd) or is_nil(cwd)) and is_list(opts) do
    agent_name = Keyword.get(opts, :agent_name, RemoteAgent)
    cookie = Keyword.get(opts, :cookie)
    connect? = Keyword.get(opts, :connect, true)
    remote_opts = Keyword.take(opts, [:env_id, :default_exec_opts])

    with :ok <- ensure_node_connected(node, cookie, connect?),
         agent = {agent_name, node},
         {:ok, descriptor} <- safe_descriptor(agent),
         {:ok, remote_cwd} <- resolve_initial_cwd(agent, descriptor, cwd) do
      env_id =
        case Keyword.get(remote_opts, :env_id) do
          nil ->
            descriptor.id

          id when is_binary(id) and id != "" ->
            id

          other ->
            raise ArgumentError, "expected non-empty string :env_id, got: #{inspect(other)}"
        end

      default_exec_opts =
        validate_default_exec_opts!(Keyword.get(remote_opts, :default_exec_opts, []))

      {:ok,
       ExecutionEnv.new(__MODULE__, %{
         agent: agent,
         env_id: env_id,
         cwd: remote_cwd,
         default_exec_opts: default_exec_opts
       })}
    end
  end

  @doc """
  Builds an `H.EnvRegistry` environment spec targeting a `H.RemoteAgent` on a
  remote BEAM node so one daemon (or one session + subagents) can coordinate
  multiple remote execution nodes concurrently.
  """
  @spec env_spec_for_node(String.t(), node(), keyword()) :: map()
  def env_spec_for_node(id, node, opts \\ [])
      when is_binary(id) and id != "" and is_atom(node) and is_list(opts) do
    default_cwd = Keyword.get(opts, :default_cwd, "/")
    label = Keyword.get(opts, :label, "Remote node #{node}")
    connect_opts = Keyword.put_new(opts, :env_id, id)

    %{
      id: id,
      kind: "remote",
      label: label,
      default_cwd: default_cwd,
      build: fn cwd ->
        case connect_node(node, cwd, connect_opts) do
          {:ok, env} -> env
          {:error, _reason} -> nil
        end
      end
    }
  end

  @doc """
  Creates a `H.ExecutionEnv.t()` targeting `agent` bound to `remote_cwd`.

  ## Options
    * `:env_id` - optional non-empty string override for the environment ID
      (defaults to `H.RemoteAgent.descriptor(agent).id`)
    * `:default_exec_opts` - keyword list of default fence/lease/exec options
      merged into every `exec/3` call
  """
  @spec new(RemoteAgent.server(), nil | String.t(), keyword()) :: ExecutionEnv.t()
  def new(agent, cwd \\ nil, opts \\ []) when (is_binary(cwd) or is_nil(cwd)) and is_list(opts) do
    descriptor = RemoteAgent.descriptor(agent)

    env_id =
      case Keyword.get(opts, :env_id) do
        nil -> descriptor.id
        id when is_binary(id) and id != "" -> id
        other -> raise ArgumentError, "expected non-empty string :env_id, got: #{inspect(other)}"
      end

    default_exec_opts = validate_default_exec_opts!(Keyword.get(opts, :default_exec_opts, []))

    remote_cwd =
      case resolve_initial_cwd(agent, descriptor, cwd) do
        {:ok, canonical} ->
          canonical

        {:error, :invalid_posix_cwd} ->
          raise ArgumentError, "expected absolute POSIX remote cwd, got: #{inspect(cwd)}"

        {:error, reason} ->
          raise ArgumentError, "invalid remote cwd: #{inspect(reason)}"
      end

    ExecutionEnv.new(__MODULE__, %{
      agent: agent,
      env_id: env_id,
      cwd: remote_cwd,
      default_exec_opts: default_exec_opts
    })
  end

  defp ensure_node_connected(node, _cookie, _connect?) when node == node(), do: :ok

  defp ensure_node_connected(node, cookie, connect?) do
    cond do
      not Node.alive?() ->
        {:error, :node_not_distributed}

      node in Node.list() ->
        :ok

      not connect? ->
        {:error, :node_unreachable}

      true ->
        if is_atom(cookie) and not is_nil(cookie), do: Node.set_cookie(node, cookie)

        case Node.connect(node) do
          true -> :ok
          _ -> {:error, :node_unreachable}
        end
    end
  end

  defp safe_descriptor(agent) do
    {:ok, RemoteAgent.descriptor(agent)}
  catch
    :exit, reason -> {:error, {:agent_down, reason}}
  end

  defp resolve_initial_cwd(_agent, descriptor, nil), do: {:ok, descriptor.cwd}

  defp resolve_initial_cwd(agent, _descriptor, path) when is_binary(path) do
    if String.contains?(path, <<0>>) or not String.starts_with?(path, "/") do
      {:error, :invalid_posix_cwd}
    else
      RemoteAgent.resolve_path(agent, path, cwd: "/")
    end
  end

  defp validate_default_exec_opts!(list) when is_list(list), do: list

  defp validate_default_exec_opts!(other) do
    raise ArgumentError, "expected keyword list :default_exec_opts, got: #{inspect(other)}"
  end

  @impl true
  def env_id(%{env_id: env_id}), do: env_id

  @impl true
  def kind(_state), do: "remote"

  @impl true
  def cwd(%{cwd: cwd}), do: cwd

  @impl true
  def bind_cwd(state, path) when is_binary(path) do
    with {:ok, resolved_cwd} <- RemoteAgent.bind_cwd(state.agent, path, cwd: state.cwd) do
      {:ok, %{state | cwd: resolved_cwd}}
    end
  end

  @impl true
  def resolve_path(state, path) when is_binary(path) do
    RemoteAgent.resolve_path(state.agent, path, cwd: state.cwd)
  end

  @impl true
  def canonical_path(state, path) when is_binary(path) do
    RemoteAgent.canonical_path(state.agent, path, cwd: state.cwd)
  end

  @impl true
  def read_file_lines(state, path, opts \\ []) when is_binary(path) and is_list(opts) do
    RemoteAgent.read_file_lines(state.agent, path, Keyword.put(opts, :cwd, state.cwd))
  end

  @impl true
  def read_file_bytes(state, path, opts \\ []) when is_binary(path) and is_list(opts) do
    RemoteAgent.read_file_bytes(state.agent, path, Keyword.put(opts, :cwd, state.cwd))
  end

  @impl true
  def write_file(state, path, content) when is_binary(path) do
    RemoteAgent.write_file(state.agent, path, content, cwd: state.cwd)
  end

  @impl true
  def list_dir(state, path, opts \\ []) when is_binary(path) and is_list(opts) do
    RemoteAgent.list_dir(state.agent, path, Keyword.put(opts, :cwd, state.cwd))
  end

  @impl true
  def list_files(state, path, opts \\ []) when is_binary(path) and is_list(opts) do
    RemoteAgent.list_files(state.agent, path, Keyword.put(opts, :cwd, state.cwd))
  end

  @impl true
  def exec(state, command, opts \\ []) when is_list(opts) do
    exec_opts =
      state.default_exec_opts
      |> Keyword.merge(opts)
      |> Keyword.put(:cwd, state.cwd)

    RemoteAgent.exec(state.agent, command, exec_opts)
  end
end
