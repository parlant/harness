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
          output: binary(),
          truncated: boolean(),
          skipped_bytes: non_neg_integer(),
          full_output_path: nil | String.t()
        }

  @type t :: {module(), state :: term()}

  @type exec_plan :: %{
          required(:cwd) => String.t(),
          required(:kind) => :shell | :argv,
          required(:opts) => keyword()
        }

  @type operation_telemetry :: %{
          required(:env_id) => String.t(),
          required(:kind) => :read | :write | :list | :path | :bind | :exec,
          required(:duration_ms) => non_neg_integer(),
          required(:result_class) => :ok | :error | :denied | :timeout | :aborted
        }

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
  @callback admit_exec(state :: term(), plan :: exec_plan()) ::
              :allow | {:allow, keyword()} | {:deny, term()}
  @callback operation_finished(state :: term(), telemetry :: operation_telemetry()) :: any()

  @optional_callbacks [
    env_id: 1,
    kind: 1,
    bind_cwd: 2,
    list_files: 3,
    canonical_path: 2,
    admit_exec: 2,
    operation_finished: 2
  ]

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
    t0 = System.monotonic_time(:millisecond)

    res =
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

    emit_telemetry(env, :bind, t0, res)
    res
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
  def resolve_path({mod, state} = env, path) when is_binary(path) do
    t0 = System.monotonic_time(:millisecond)
    res = mod.resolve_path(state, path)
    emit_telemetry(env, :path, t0, res)
    res
  end

  @spec read_file_lines(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_file_lines({mod, state} = env, path, opts \\ []) do
    t0 = System.monotonic_time(:millisecond)
    res = mod.read_file_lines(state, path, opts)
    emit_telemetry(env, :read, t0, res)
    res
  end

  @spec read_file_bytes(t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file_bytes({mod, state} = env, path, opts \\ []) do
    t0 = System.monotonic_time(:millisecond)
    res = mod.read_file_bytes(state, path, opts)
    emit_telemetry(env, :read, t0, res)
    res
  end

  @spec write_file(t(), String.t(), iodata()) :: :ok | {:error, term()}
  def write_file({mod, state} = env, path, content) do
    t0 = System.monotonic_time(:millisecond)
    res = mod.write_file(state, path, content)
    emit_telemetry(env, :write, t0, res)
    res
  end

  @spec list_dir(t(), String.t(), keyword()) ::
          {:ok, %{entries: [map()], next_cursor: nil | non_neg_integer()}} | {:error, term()}
  def list_dir({mod, state} = env, path, opts \\ []) do
    t0 = System.monotonic_time(:millisecond)
    res = mod.list_dir(state, path, opts)
    emit_telemetry(env, :list, t0, res)
    res
  end

  @spec list_files(t(), String.t(), keyword()) ::
          {:ok, %{entries: [map()], truncated: boolean()}} | {:error, term()}
  def list_files({mod, state} = env, path, opts \\ []) when is_binary(path) and is_list(opts) do
    t0 = System.monotonic_time(:millisecond)

    res =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :list_files, 3) do
        mod.list_files(state, path, opts)
      else
        {:error, :unsupported}
      end

    emit_telemetry(env, :list, t0, res)
    res
  end

  @spec canonical_path(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def canonical_path({mod, state} = env, path) when is_binary(path) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :canonical_path, 2) do
      t0 = System.monotonic_time(:millisecond)
      res = mod.canonical_path(state, path)
      emit_telemetry(env, :path, t0, res)
      res
    else
      resolve_path(env, path)
    end
  end

  @doc """
  Runs a command in the bound environment. Host and Remote accept
  `raw_output: true` to preserve bytes and `spill_output: false` to retain
  only the bounded output window without persisting an overflow file.
  """
  @spec exec(t(), command(), keyword()) :: {:ok, exec_result()} | {:error, term()}
  def exec({mod, state} = env, command, opts \\ []) when is_list(opts) do
    t0 = System.monotonic_time(:millisecond)

    res =
      case check_admit_exec(env, command, opts) do
        {:ok, admitted_opts} -> mod.exec(state, command, admitted_opts)
        {:error, _} = denied -> denied
      end

    emit_telemetry(env, :exec, t0, res)
    res
  end

  @tightenable_exec_keys [:timeout_ms, :window_bytes, :window_lines, :spill_output]

  defp check_admit_exec({mod, state} = env, command, opts) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :admit_exec, 2) do
      plan = %{
        cwd: safe_cwd(env),
        kind: command_kind(command),
        opts: Keyword.take(opts, @tightenable_exec_keys)
      }

      try do
        case mod.admit_exec(state, plan) do
          :allow ->
            {:ok, opts}

          {:allow, tighter_opts} when is_list(tighter_opts) ->
            tighten_exec_opts(opts, tighter_opts)

          {:deny, reason} ->
            {:error, {:exec_denied, reason}}

          other ->
            {:error, {:exec_denied, {:invalid_admission, other}}}
        end
      rescue
        e -> {:error, {:exec_denied, {:exception, Exception.message(e)}}}
      catch
        kind, reason -> {:error, {:exec_denied, {kind, reason}}}
      end
    else
      {:ok, opts}
    end
  end

  defp tighten_exec_opts(base_opts, tighter_opts) do
    if Keyword.keyword?(tighter_opts) and
         Keyword.keys(tighter_opts) -- @tightenable_exec_keys == [] do
      updated =
        Enum.reduce_while(tighter_opts, {:ok, base_opts}, fn
          {:timeout_ms, ms}, {:ok, acc} when is_integer(ms) and ms > 0 ->
            next =
              case Keyword.get(acc, :timeout_ms) do
                cur when is_integer(cur) and cur > 0 -> min(cur, ms)
                _ -> ms
              end

            {:cont, {:ok, Keyword.put(acc, :timeout_ms, next)}}

          {:window_bytes, bytes}, {:ok, acc} when is_integer(bytes) and bytes > 0 ->
            next =
              case Keyword.get(acc, :window_bytes) do
                cur when is_integer(cur) and cur > 0 -> min(cur, bytes)
                _ -> bytes
              end

            {:cont, {:ok, Keyword.put(acc, :window_bytes, next)}}

          {:window_lines, lines}, {:ok, acc} when is_integer(lines) and lines > 0 ->
            next =
              case Keyword.get(acc, :window_lines) do
                cur when is_integer(cur) and cur > 0 -> min(cur, lines)
                _ -> lines
              end

            {:cont, {:ok, Keyword.put(acc, :window_lines, next)}}

          {:spill_output, false}, {:ok, acc} ->
            {:cont, {:ok, Keyword.put(acc, :spill_output, false)}}

          {:spill_output, true}, {:ok, acc} ->
            case Keyword.get(acc, :spill_output) do
              false -> {:halt, {:error, {:exec_denied, :cannot_loosen_spill_output}}}
              _ -> {:cont, {:ok, Keyword.put(acc, :spill_output, true)}}
            end

          other, _acc ->
            {:halt, {:error, {:exec_denied, {:invalid_tighter_opt, other}}}}
        end)

      updated
    else
      {:error, {:exec_denied, :invalid_admission_opts}}
    end
  end

  defp command_kind({:shell, _}), do: :shell
  defp command_kind({:argv, _}), do: :argv
  defp command_kind(_), do: :unknown

  defp safe_cwd({mod, state}) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :cwd, 1) do
      mod.cwd(state)
    else
      nil
    end
  end

  defp emit_telemetry({mod, state} = env, kind, t0_mono_ms, result) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :operation_finished, 2) do
      duration_ms = max(0, System.monotonic_time(:millisecond) - t0_mono_ms)

      telemetry = %{
        env_id: safe_env_id(env),
        kind: kind,
        duration_ms: duration_ms,
        result_class: classify_result(result)
      }

      try do
        mod.operation_finished(state, telemetry)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp safe_env_id(env) do
    env_id(env)
  rescue
    _ -> "unknown"
  catch
    _, _ -> "unknown"
  end

  defp classify_result(:ok), do: :ok
  defp classify_result({:ok, _}), do: :ok
  defp classify_result({:error, {:exec_denied, _}}), do: :denied
  defp classify_result({:error, %{reason: :timeout}}), do: :timeout
  defp classify_result({:error, :timeout}), do: :timeout
  defp classify_result({:error, %{reason: :aborted}}), do: :aborted
  defp classify_result({:error, :aborted}), do: :aborted
  defp classify_result({:error, _}), do: :error
  defp classify_result(_), do: :error
end
