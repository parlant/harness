defmodule H.ExecutionEnv.Remote do
  @moduledoc """
  Cooperative remote `H.ExecutionEnv` adapter backed by a `H.RemoteAgent` handle.

  Delegates all path resolution, directory listing (including project markers), file I/O,
  and process execution to the target remote agent without calling local `Path.expand/2`,
  `File`, or `System` directly.

  ## Future Network Transport

  Today `agent` is a local in-VM `H.RemoteAgent` GenServer proving interface, identity
  separation (`env_id`, `kind: "remote"`), fencing, and lease-expiry reaping semantics.
  A future Slice 8 network adapter (mTLS WebSocket/HTTPS or SSH subsystem) will swap into
  the remote agent handle seam without changing `H.Tools.*`, `H.WorkspaceLease`, or callers.
  """

  @behaviour H.ExecutionEnv

  alias H.ExecutionEnv
  alias H.RemoteAgent

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

    default_exec_opts =
      case Keyword.get(opts, :default_exec_opts, []) do
        list when is_list(list) ->
          list

        other ->
          raise ArgumentError,
                "expected keyword list :default_exec_opts, got: #{inspect(other)}"
      end

    remote_cwd =
      case cwd do
        nil ->
          descriptor.cwd

        path when is_binary(path) ->
          if String.contains?(path, <<0>>) or not String.starts_with?(path, "/") do
            raise ArgumentError, "expected absolute POSIX remote cwd, got: #{inspect(path)}"
          end

          case RemoteAgent.resolve_path(agent, path, cwd: "/") do
            {:ok, canonical} -> canonical
            {:error, reason} -> raise ArgumentError, "invalid remote cwd: #{inspect(reason)}"
          end
      end

    ExecutionEnv.new(__MODULE__, %{
      agent: agent,
      env_id: env_id,
      cwd: remote_cwd,
      default_exec_opts: default_exec_opts
    })
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
