defmodule H.ExecutionEnv do
  @moduledoc """
  Pluggable filesystem and process execution boundary for `H` tools.

  Tools (`read`, `write`, `edit`, `bash`) interact exclusively through `H.ExecutionEnv`
  rather than calling `File` or `System.cmd` directly, allowing local workspaces,
  disposable test directories, and later remote/sandbox environments to share one
  tool implementation and conformance suite.
  """

  @default_markers [
    ".git",
    "mix.exs",
    "Cargo.toml",
    "package.json",
    "pyproject.toml",
    "go.mod",
    "AGENTS.md"
  ]

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
  @callback list_files(state :: term(), path :: String.t(), opts :: keyword()) ::
              {:ok, %{entries: [map()], truncated: boolean()}} | {:error, term()}
  @callback canonical_path(state :: term(), path :: String.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback exec(state :: term(), command(), opts :: keyword()) ::
              {:ok, exec_result()} | {:error, term()}
  @callback env_id(state :: term()) :: String.t()
  @callback kind(state :: term()) :: String.t()
  @callback bind_cwd(state :: term(), cwd :: String.t()) ::
              {:ok, state :: term()} | {:error, term()}

  @optional_callbacks [env_id: 1, kind: 1, bind_cwd: 2, list_files: 3, canonical_path: 2]

  @doc "Standardized project marker filenames used when browsing directories."
  @spec default_markers() :: [String.t()]
  def default_markers, do: @default_markers

  @spec new(module(), term()) :: t()
  def new(mod, state) when is_atom(mod), do: {mod, state}

  @spec env_id(t()) :: String.t()
  def env_id({mod, state}) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :env_id, 1) do
      mod.env_id(state)
    else
      "host"
    end
  end

  @spec kind(t()) :: String.t()
  def kind({mod, state}) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :kind, 1) do
      mod.kind(state)
    else
      "host"
    end
  end

  @spec bind_cwd(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def bind_cwd({mod, state} = env, cwd) when is_binary(cwd) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :bind_cwd, 2) do
      case mod.bind_cwd(state, cwd) do
        {:ok, new_state} -> {:ok, {mod, new_state}}
        {:error, _} = err -> err
      end
    else
      with {:ok, resolved} <- resolve_path(env, cwd) do
        cond do
          function_exported?(mod, :new, 2) -> {:ok, mod.new(resolved, [])}
          function_exported?(mod, :new, 1) -> {:ok, mod.new(resolved)}
          true -> {:error, :unsupported}
        end
      end
    end
  end

  @doc "Binds to an existing directory. With `exact: true`, rejects changes to its previously resolved canonical path."
  @spec bind_canonical_cwd(t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def bind_canonical_cwd(env, path, opts \\ []) do
    if String.valid?(path) and not String.contains?(path, <<0>>) do
      with {:ok, canonical} <- canonical_path(env, path) do
        if Keyword.get(opts, :exact, false) and canonical != path do
          {:error, :cwd_changed}
        else
          bind_cwd(env, canonical)
        end
      end
    else
      {:error, :einval}
    end
  end

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

  @spec list_files(t(), String.t(), keyword()) ::
          {:ok, %{entries: [map()], truncated: boolean()}} | {:error, term()}
  def list_files({mod, state}, path, opts \\ []) when is_binary(path) and is_list(opts) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :list_files, 3) do
      mod.list_files(state, path, opts)
    else
      {:error, :unsupported}
    end
  end

  @spec canonical_path(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def canonical_path({mod, state} = env, path) when is_binary(path) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :canonical_path, 2) do
      mod.canonical_path(state, path)
    else
      resolve_path(env, path)
    end
  end

  @spec exec(t(), command(), keyword()) :: {:ok, exec_result()} | {:error, term()}
  def exec({mod, state}, command, opts \\ []), do: mod.exec(state, command, opts)
end
