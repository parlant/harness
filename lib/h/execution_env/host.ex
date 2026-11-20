defmodule H.ExecutionEnv.Host do
  @moduledoc """
  Local host filesystem and OTP `Port` process-group execution environment (`H.ExecutionEnv`).
  """

  @behaviour H.ExecutionEnv

  alias H.ExecutionEnv.Host.{Exec, Fs}

  @spec new(String.t(), keyword()) :: H.ExecutionEnv.t()
  def new(cwd \\ System.user_home!(), opts \\ []) when is_binary(cwd) and is_list(opts) do
    if Path.type(cwd) != :absolute do
      raise ArgumentError, "expected absolute cwd, got: #{inspect(cwd)}"
    end

    env_id =
      case Keyword.get(opts, :env_id) do
        id when is_binary(id) and id != "" -> id
        nil -> "host"
        other -> raise ArgumentError, "expected non-empty string :env_id, got: #{inspect(other)}"
      end

    env_overrides =
      opts
      |> Keyword.get(:env_overrides, %{})
      |> Exec.normalize_env_overrides()

    H.ExecutionEnv.new(__MODULE__, %{
      env_id: env_id,
      cwd: Path.expand(cwd),
      env_overrides: env_overrides
    })
  end

  @impl true
  def env_id(%{env_id: env_id}), do: env_id

  @impl true
  def kind(_state), do: "host"

  @impl true
  def cwd(%{cwd: cwd}), do: cwd

  @impl true
  def bind_cwd(state, path) when is_binary(path) do
    with {:ok, resolved} <- resolve_path(state, path) do
      case File.stat(resolved) do
        {:ok, %File.Stat{type: :directory}} -> {:ok, %{state | cwd: resolved}}
        {:ok, _other} -> {:error, :enotdir}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def resolve_path(%{cwd: cwd}, path) when is_binary(path) do
    Fs.resolve_path(cwd, path)
  end

  @impl true
  def canonical_path(%{cwd: cwd}, path) when is_binary(path) do
    Fs.canonical_path(cwd, path)
  end

  @impl true
  def read_file_lines(%{cwd: cwd}, path, opts \\ []) when is_binary(path) and is_list(opts) do
    Fs.read_file_lines(cwd, path, opts)
  end

  @impl true
  def read_file_bytes(%{cwd: cwd}, path, opts \\ []) when is_binary(path) and is_list(opts) do
    Fs.read_file_bytes(cwd, path, opts)
  end

  @impl true
  def write_file(%{cwd: cwd}, path, content) when is_binary(path) do
    Fs.write_file(cwd, path, content)
  end

  @impl true
  def list_dir(%{cwd: cwd}, path, opts \\ []) when is_binary(path) and is_list(opts) do
    Fs.list_dir(cwd, path, opts)
  end

  @impl true
  def list_files(%{cwd: cwd}, path, opts \\ []) when is_binary(path) and is_list(opts) do
    Fs.list_files(cwd, path, opts)
  end

  @impl true
  def exec(state, command, opts \\ []) when is_list(opts) do
    Exec.exec(state, command, opts)
  end
end
