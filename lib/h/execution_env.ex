defmodule H.ExecutionEnv do
  @moduledoc """
  Pluggable filesystem and process execution boundary for `H` tools.

  Tools (`read`, `write`, `edit`, `bash`) interact exclusively through `H.ExecutionEnv`
  rather than calling `File` or `System.cmd` directly, allowing local workspaces,
  disposable test directories, and later remote/sandbox environments to share one
  tool implementation and conformance suite.
  """

  @type command :: {:shell, String.t()} | {:argv, [String.t()]}

  @type exec_result :: %{
          exit_code: integer(),
          output: String.t(),
          truncated: boolean(),
          skipped_bytes: non_neg_integer(),
          full_output_path: nil | String.t()
        }

  @type t :: {module(), state :: term()}

  @callback cwd(state :: term()) :: String.t()
  @callback resolve_path(state :: term(), path :: String.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback read_file_lines(state :: term(), path :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback read_file_bytes(state :: term(), path :: String.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}
  @callback write_file(state :: term(), path :: String.t(), content :: iodata()) ::
              :ok | {:error, term()}
  @callback list_dir(state :: term(), path :: String.t(), opts :: keyword()) ::
              {:ok, %{entries: [map()], next_cursor: nil | non_neg_integer()}} | {:error, term()}
  @callback exec(state :: term(), command(), opts :: keyword()) ::
              {:ok, exec_result()} | {:error, term()}

  @spec new(module(), term()) :: t()
  def new(mod, state) when is_atom(mod), do: {mod, state}

  @spec cwd(t()) :: String.t()
  def cwd({mod, state}), do: mod.cwd(state)

  @spec resolve_path(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_path({mod, state}, path) when is_binary(path), do: mod.resolve_path(state, path)

  @spec read_file_lines(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_file_lines({mod, state}, path, opts \\ []), do: mod.read_file_lines(state, path, opts)

  @spec read_file_bytes(t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file_bytes({mod, state}, path, opts \\ []), do: mod.read_file_bytes(state, path, opts)

  @spec write_file(t(), String.t(), iodata()) :: :ok | {:error, term()}
  def write_file({mod, state}, path, content), do: mod.write_file(state, path, content)

  @spec list_dir(t(), String.t(), keyword()) ::
          {:ok, %{entries: [map()], next_cursor: nil | non_neg_integer()}} | {:error, term()}
  def list_dir({mod, state}, path, opts \\ []), do: mod.list_dir(state, path, opts)

  @spec exec(t(), command(), keyword()) :: {:ok, exec_result()} | {:error, term()}
  def exec({mod, state}, command, opts \\ []), do: mod.exec(state, command, opts)
end
