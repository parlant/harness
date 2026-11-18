defmodule H.EnvRegistry do
  @moduledoc """
  Stateless resolver turning environment configurations into live `H.ExecutionEnv.t()`
  handles and plain JSON-safe environment descriptors.
  """

  alias H.ExecutionEnv
  alias H.ExecutionEnv.Host

  @type descriptor :: %{
          id: String.t(),
          kind: String.t(),
          label: String.t(),
          default_cwd: String.t()
        }

  @doc "Lists configured environment descriptors, always including `\"host\"`."
  @spec list_environments(keyword()) :: [descriptor()]
  def list_environments(opts \\ []) when is_list(opts) do
    opts
    |> resolve_specs()
    |> Map.values()
    |> Enum.map(&to_descriptor/1)
    |> Enum.sort_by(fn desc -> {desc.id != "host", desc.id} end)
  end

  @doc "Fetches the base `H.ExecutionEnv.t()` at its `default_cwd` and its descriptor."
  @spec fetch_env(term(), keyword()) ::
          {:ok, ExecutionEnv.t(), descriptor()}
          | {:error, :unknown_environment | :workspace_unavailable}
  def fetch_env(env_id, opts \\ []) when is_list(opts) do
    with id when is_binary(id) and id != "" <- env_id,
         {:ok, spec} <- Map.fetch(resolve_specs(opts), id) do
      safe_build_env(spec)
    else
      _ -> {:error, :unknown_environment}
    end
  end

  @doc """
  Resolves `{env_id, raw_cwd}` against the environment registry and binds `cwd`
  through `H.ExecutionEnv.bind_cwd/2`.
  """
  @spec resolve_workspace(nil | String.t(), nil | String.t(), keyword()) ::
          {:ok,
           %{
             env_id: String.t(),
             kind: String.t(),
             cwd: String.t(),
             env: ExecutionEnv.t()
           }}
          | {:error, term()}
  def resolve_workspace(env_id, raw_cwd_or_nil, opts \\ []) when is_list(opts) do
    target_id = if env_id in [nil, ""], do: "host", else: env_id

    with {:ok, base_env, desc} <- fetch_env(target_id, opts),
         target_cwd = if(raw_cwd_or_nil in [nil, ""], do: desc.default_cwd, else: raw_cwd_or_nil),
         {:ok, bound_env} <- ExecutionEnv.bind_cwd(base_env, target_cwd) do
      {:ok,
       %{
         env_id: desc.id,
         kind: desc.kind,
         cwd: ExecutionEnv.cwd(bound_env),
         env: bound_env
       }}
    end
  end

  # --- Internal spec normalization ---

  defp resolve_specs(opts) do
    default_host_cwd =
      case Keyword.get(opts, :default_cwd) do
        cwd when is_binary(cwd) and cwd != "" -> Path.expand(cwd)
        _ -> System.user_home!()
      end

    default_host = %{
      id: "host",
      kind: "host",
      label: "Local Host",
      default_cwd: default_host_cwd,
      build: fn cwd -> Host.new(cwd, env_id: "host") end
    }

    custom_specs =
      opts
      |> Keyword.get(:environments)
      |> normalize_environments(default_host)

    Map.put_new(custom_specs, "host", default_host)
  end

  defp normalize_environments(nil, _default_host), do: %{}

  defp normalize_environments(envs, default_host) when is_map(envs) do
    Enum.reduce(envs, %{}, fn {id, spec}, acc ->
      id_str = to_string(id)

      if id_str == "" do
        acc
      else
        Map.put(acc, id_str, normalize_spec(spec, id_str, default_host))
      end
    end)
  end

  defp normalize_environments(envs, default_host) when is_list(envs) do
    Enum.reduce(envs, %{}, fn spec, acc ->
      id = spec_get(spec, :id, "id")

      if is_binary(id) and id != "" do
        Map.put(acc, id, normalize_spec(spec, id, default_host))
      else
        acc
      end
    end)
  end

  defp normalize_spec(spec, id, default_host) when is_map(spec) do
    base = if id == "host", do: default_host, else: %{}

    kind = spec_get(spec, :kind, "kind") || Map.get(base, :kind, "host")
    label = spec_get(spec, :label, "label") || Map.get(base, :label, id)

    default_cwd =
      spec_get(spec, :default_cwd, "default_cwd") || Map.get(base, :default_cwd, "/")

    build = spec_get(spec, :build, "build") || Map.get(base, :build)
    static_env = spec_get(spec, :env, "env")

    %{
      id: id,
      kind: to_string(kind),
      label: to_string(label),
      default_cwd: to_string(default_cwd),
      build: build,
      env: static_env
    }
  end

  defp spec_get(spec, atom_key, str_key) do
    case Map.fetch(spec, atom_key) do
      {:ok, val} -> val
      :error -> Map.get(spec, str_key)
    end
  end

  defp safe_build_env(spec) do
    case build_env(spec, spec.default_cwd) do
      {mod, _state} = env when is_atom(mod) -> {:ok, env, to_descriptor(spec)}
      _ -> {:error, :workspace_unavailable}
    end
  catch
    :exit, _reason -> {:error, :workspace_unavailable}
  end

  defp build_env(%{build: build}, cwd) when is_function(build, 1), do: build.(cwd)
  defp build_env(%{build: build}, _cwd) when is_function(build, 0), do: build.()
  defp build_env(%{env: {mod, _state} = env}, _cwd) when is_atom(mod), do: env
  defp build_env(%{id: id, kind: "host"}, cwd), do: Host.new(cwd, env_id: id)
  defp build_env(_spec, _cwd), do: nil

  defp to_descriptor(spec) do
    %{
      id: spec.id,
      kind: spec.kind,
      label: spec.label,
      default_cwd: spec.default_cwd
    }
  end
end
