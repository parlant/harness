defmodule H.Extensions do
  @moduledoc false

  @api_version 1
  @max_json_bytes 65_536
  @max_extensions 32
  @max_modules 256
  @max_beam_bytes 4_194_304
  @id ~r/\A[a-z][a-z0-9._-]{0,79}\z/
  @namespace ~r/\AElixir\.[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)+\z/

  @type loaded_state :: %{
          no_extensions: boolean(),
          packages: [map()],
          harnesses: %{String.t() => module()},
          environments: %{String.t() => map()},
          codex_account_policy: nil | map(),
          observers: [module()],
          status_projections: [map()],
          children: [Supervisor.child_spec()]
        }

  @doc false
  def load(opts) do
    case load_state(opts) do
      {:ok, opts, ext_state} -> {:ok, opts, ext_state.children}
      {:error, _} = err -> err
    end
  end

  @doc false
  def load_state(opts) do
    base_harnesses = normalize_base_harnesses(opts[:harnesses])
    base_environments = normalize_base_environments(opts[:environments])

    if Keyword.get(opts, :no_extensions, false) do
      ext_state = empty_state(true, base_harnesses, base_environments)
      {:ok, opts, ext_state}
    else
      data_dir = Keyword.fetch!(opts, :data_dir)
      config = Path.join(data_dir, "extensions.json")

      with {:ok, entries} <- entries(config),
           {:ok, packages} <- map_ok(entries, &manifest(&1, data_dir)),
           :ok <- unique(Enum.map(packages, & &1.id), :extension_id),
           {:ok, packages} <- map_ok(packages, &read_package/1),
           :ok <- unique(Enum.flat_map(packages, &Map.keys(&1.beams)), :module),
           {:ok, opts, ext_state} <-
             compose(packages, opts, base_harnesses, base_environments) do
        {:ok, opts, ext_state}
      else
        {:error, reason} -> {:error, {:extensions, reason}}
      end
    end
  end

  @doc false
  def summarize(ext_state) when is_map(ext_state) do
    %{
      "no_extensions" => ext_state.no_extensions,
      "extensions" =>
        Enum.map(ext_state.packages, fn pkg ->
          %{
            "id" => pkg.id,
            "path" => pkg.path,
            "module" => pkg.root,
            "module_count" => map_size(pkg.beams),
            "harnesses" => pkg.harness_ids,
            "environments" => pkg.environment_ids,
            "children" => length(pkg.child_ids),
            "observers" => pkg.observer_count,
            "status_projections" => pkg.status_namespaces,
            "codex_account_policy" => pkg.has_codex_account_policy
          }
        end)
    }
  end

  @doc false
  def empty_state(no_extensions, base_harnesses \\ %{}, base_environments \\ %{}) do
    %{
      no_extensions: no_extensions,
      packages: [],
      harnesses: base_harnesses,
      environments: base_environments,
      codex_account_policy: nil,
      observers: [],
      status_projections: [],
      children: []
    }
  end

  defp entries(path) do
    case read_json(path) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, %{"version" => 1, "extensions" => list} = config}
      when map_size(config) == 2 and is_list(list) and length(list) <= @max_extensions ->
        with {:ok, entries} <- map_ok(list, &entry/1) do
          {:ok, Enum.filter(entries, & &1.enabled)}
        end

      _ ->
        {:error, :invalid_extensions_json}
    end
  end

  defp entry(%{"path" => path} = entry) do
    enabled = Map.get(entry, "enabled", true)
    settings = Map.get(entry, "settings", %{})

    if path?(path) and is_boolean(enabled) and is_map(settings) and
         Map.keys(entry) -- ["path", "enabled", "settings"] == [] do
      {:ok, %{path: path, enabled: enabled, settings: settings}}
    else
      {:error, :invalid_extension_entry}
    end
  end

  defp entry(_), do: {:error, :invalid_extension_entry}

  defp manifest(entry, data_dir) do
    path = Path.expand(entry.path, data_dir)

    case read_json(Path.join(path, "extension.json")) do
      {:ok, %{"api_version" => version}} when version != @api_version ->
        {:error, {path, :incompatible_extension_api}}

      {:ok, %{"id" => id, "api_version" => @api_version, "module" => root} = manifest}
      when map_size(manifest) == 3 and is_binary(root) ->
        if id?(id) and Regex.match?(@namespace, root) and
             not String.starts_with?(root, "Elixir.H.") do
          {:ok, %{id: id, path: path, root: root, settings: entry.settings}}
        else
          {:error, {path, :invalid_manifest}}
        end

      {:ok, _} ->
        {:error, {path, :invalid_manifest}}

      {:error, reason} ->
        {:error, {path, {:manifest, reason}}}
    end
  end

  defp read_package(package) do
    ebin = Path.join(package.path, "ebin")

    with {:ok, files} <- File.ls(ebin),
         files = Enum.filter(files, &String.ends_with?(&1, ".beam")),
         true <- length(files) in 1..@max_modules,
         {:ok, beams} <- map_ok(Enum.sort(files), &beam(&1, ebin, package.root)),
         beams = Map.new(beams),
         true <- Map.has_key?(beams, package.root) do
      {:ok, Map.put(package, :beams, beams)}
    else
      false -> {:error, {package.id, :missing_entry_module_or_invalid_beam_count}}
      {:error, reason} -> {:error, {package.id, {:ebin, reason}}}
    end
  end

  defp beam(file, ebin, root) do
    name = Path.rootname(file, ".beam")
    path = Path.join(ebin, file)

    with true <- name == root or String.starts_with?(name, root <> "."),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_beam_bytes <-
           File.lstat(path),
         {:ok, binary} when byte_size(binary) <= @max_beam_bytes <- File.read(path),
         {:ok, {module, md5}} <- :beam_lib.md5(binary),
         true <- Atom.to_string(module) == name,
         true <- compatible_module?(module, path, md5) do
      {:ok, {name, {module, String.to_charlist(path), binary}}}
    else
      _ -> {:error, {:invalid_or_conflicting_beam, file}}
    end
  end

  # No code path mutation or loading by a string-derived atom. Modules come
  # from explicitly trusted BEAM files and are loaded once at boot.
  defp compatible_module?(module, path, md5) do
    case :code.which(module) do
      :non_existing ->
        true

      loaded when is_list(loaded) ->
        loaded == String.to_charlist(path) and :code.is_loaded(module) != false and
          module.module_info(:md5) == md5

      _ ->
        false
    end
  end

  defp compose([], opts, base_harnesses, base_environments) do
    {:ok, opts, empty_state(false, base_harnesses, base_environments)}
  end

  defp compose(packages, opts, base_harnesses, base_environments) do
    beams =
      packages
      |> Enum.flat_map(&Map.values(&1.beams))
      |> Enum.reject(fn {mod, _, _} -> :code.is_loaded(mod) != false end)

    base_observers = List.wrap(opts[:observers])
    base_projections = List.wrap(opts[:status_projections])

    with :ok <- load_beams(beams),
         {:ok, {harnesses, environments, children, policy, observers, projections, pkg_summaries}} <-
           merge_packages(
             packages,
             opts,
             {base_harnesses, base_environments, [], nil, base_observers, base_projections, []}
           ) do
      opts =
        opts
        |> Keyword.merge(
          harnesses: harnesses,
          environments: environments,
          observers: Enum.uniq(observers),
          status_projections: projections
        )
        |> then(fn o ->
          if policy, do: Keyword.put(o, :codex_account_policy, policy), else: o
        end)

      ext_state = %{
        no_extensions: false,
        packages: pkg_summaries,
        harnesses: harnesses,
        environments: environments,
        codex_account_policy: policy,
        observers: Enum.uniq(observers),
        status_projections: projections,
        children: children
      }

      {:ok, opts, ext_state}
    end
  end

  defp load_beams([]), do: :ok
  defp load_beams(beams), do: :code.atomic_load(beams)

  defp normalize_base_harnesses(nil), do: %{}
  defp normalize_base_harnesses(list) when is_list(list), do: Map.new(list, &{&1.id(), &1})
  defp normalize_base_harnesses(map) when is_map(map), do: map

  defp normalize_base_environments(nil), do: %{}

  defp normalize_base_environments(list) when is_list(list),
    do: Map.new(list, &{env_value(&1, :id), &1})

  defp normalize_base_environments(map) when is_map(map),
    do: Map.new(map, fn {id, spec} -> {to_string(id), spec} end)

  defp merge_packages(packages, opts, base) do
    Enum.reduce_while(packages, {:ok, base}, fn package,
                                                {:ok,
                                                 {harnesses, envs, children, policy, observers,
                                                  projections, pkgs}} ->
      {mod, _, _} = Map.fetch!(package.beams, package.root)

      context = %{
        id: package.id,
        data_dir: Keyword.fetch!(opts, :data_dir),
        pubsub: Keyword.get(opts, :pubsub, H.PubSub)
      }

      with {:ok, package_harnesses, package_envs, specs, package_policy, package_observers,
            package_projections} <-
             validate_configure(mod, package.settings, context, opts),
           :ok <-
             if(policy && package_policy,
               do: {:error, :duplicate_codex_account_policy},
               else: :ok
             ),
           :ok <-
             unique(
               ["coding", "pi"] ++
                 Map.keys(harnesses) ++ Enum.map(package_harnesses, &elem(&1, 0)),
               :harness_id
             ),
           :ok <-
             unique(
               ["host"] ++ Map.keys(envs) ++ Enum.map(package_envs, &elem(&1, 0)),
               :environment_id
             ),
           :ok <-
             unique(
               Enum.map(projections ++ package_projections, & &1.namespace),
               :status_projection_namespace
             ) do
        pkg_summary =
          Map.merge(package, %{
            harness_ids: Enum.map(package_harnesses, &elem(&1, 0)),
            environment_ids: Enum.map(package_envs, &elem(&1, 0)),
            child_ids: Enum.map(specs, & &1.id),
            observer_count: length(package_observers),
            status_namespaces: Enum.map(package_projections, & &1.namespace),
            has_codex_account_policy: not is_nil(package_policy)
          })

        {:cont,
         {:ok,
          {Map.merge(harnesses, Map.new(package_harnesses)),
           Map.merge(envs, Map.new(package_envs)), children ++ specs, policy || package_policy,
           observers ++ package_observers, projections ++ package_projections,
           pkgs ++ [pkg_summary]}}}
      else
        {:error, reason} -> {:halt, {:error, {package.id, reason}}}
      end
    end)
  end

  defp validate_configure(mod, settings, context, opts) do
    allowed_keys = [
      :harnesses,
      :environments,
      :children,
      :codex_account_policy,
      :observers,
      :status_projections
    ]

    with true <- function_exported?(mod, :configure, 2),
         {:ok, contributions} when is_map(contributions) <- mod.configure(settings, context),
         [] <- Map.keys(contributions) -- allowed_keys,
         {:ok, harnesses} <- registrations(contributions, :harnesses, &harness(&1, opts)),
         {:ok, envs} <- registrations(contributions, :environments, &environment/1),
         {:ok, specs} <- registrations(contributions, :children, &child(&1, context.id)),
         :ok <- unique(Enum.map(specs, & &1.id), :child_id),
         {:ok, policy} <- account_policy(contributions[:codex_account_policy]),
         {:ok, observers} <- registrations(contributions, :observers, &observer/1),
         {:ok, projections} <-
           registrations(contributions, :status_projections, &status_projection/1) do
      {:ok, harnesses, envs, specs, policy, observers, projections}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_contributions}
    end
  rescue
    _ -> {:error, :configuration_failed}
  catch
    _, _ -> {:error, :configuration_failed}
  end

  defp account_policy(nil), do: {:ok, nil}

  defp account_policy(%{module: mod, sources: sources} = spec) when map_size(spec) == 2 do
    with {:ok, [_, _ | _], _} <- H.Accounts.Config.parse(%{"sources" => sources}),
         true <- implements?(mod, H.Provider.AccountPolicy) do
      {:ok, spec}
    else
      _ -> {:error, :invalid_codex_account_policy}
    end
  end

  defp account_policy(_), do: {:error, :invalid_codex_account_policy}

  defp observer(mod) when is_atom(mod) do
    if Code.ensure_loaded?(mod) and
         (function_exported?(mod, :command_committed, 1) or
            function_exported?(mod, :work_settled, 1)) do
      {:ok, mod}
    else
      {:error, :invalid_observer}
    end
  end

  defp observer(_), do: {:error, :invalid_observer}

  defp status_projection(spec) do
    if H.Extensions.Status.valid_spec?(spec) do
      {:ok, spec}
    else
      {:error, :invalid_status_projection}
    end
  end

  defp registrations(contributions, key, fun) do
    case Map.get(contributions, key, []) do
      list when is_list(list) -> map_ok(list, fun)
      _ -> {:error, :invalid_contributions}
    end
  end

  defp harness(mod, opts) do
    with true <- implements?(mod, H.Harness),
         id when is_binary(id) <- mod.id(),
         true <- id?(id),
         %{id: ^id, name: name, description: desc} when is_binary(name) and is_binary(desc) <-
           mod.descriptor(),
         tools when is_list(tools) <- mod.tools(opts),
         {:ok, names} <- map_ok(tools, &tool/1),
         :ok <- unique(names, :tool_name) do
      {:ok, {id, mod}}
    else
      _ -> {:error, :invalid_harness}
    end
  end

  defp tool(mod) do
    with true <- implements?(mod, H.Tool),
         name when is_binary(name) and name != "" <- mod.name(),
         true <-
           is_binary(mod.description()) and is_boolean(mod.mutating?()) and
             mod.replay() in [:safe, :unsafe],
         schema when is_map(schema) <- mod.parameters_schema(),
         {:ok, _} <- JSV.build(schema) do
      {:ok, name}
    else
      _ -> {:error, :invalid_tool}
    end
  end

  defp environment(spec) when is_map(spec) do
    id = env_value(spec, :id)
    cwd = env_value(spec, :default_cwd)
    build = env_value(spec, :build)
    env = env_value(spec, :env)

    if id?(id) and path?(cwd) and Path.type(cwd) == :absolute and
         is_binary(env_value(spec, :label)) and is_binary(env_value(spec, :kind)) and
         (is_function(build, 0) or is_function(build, 1) or
            match?({mod, _} when is_atom(mod), env)) do
      {:ok, {id, spec}}
    else
      {:error, :invalid_environment}
    end
  end

  defp environment(_), do: {:error, :invalid_environment}

  defp env_value(spec, key), do: Map.get(spec, key, Map.get(spec, Atom.to_string(key)))

  defp child(spec, package_id) do
    case Supervisor.child_spec(spec, []) do
      %{id: id, start: {mod, fun, args}} = normalized
      when is_atom(mod) and is_atom(fun) and is_list(args) ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)),
          do: {:ok, %{normalized | id: {:extension, package_id, id}}},
          else: {:error, :invalid_extension_child}

      _ ->
        {:error, :invalid_extension_child}
    end
  end

  defp implements?(mod, behaviour) do
    is_atom(mod) and Code.ensure_loaded?(mod) and
      Enum.all?(
        behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks),
        fn {name, arity} -> function_exported?(mod, name, arity) end
      )
  end

  defp id?(id), do: is_binary(id) and Regex.match?(@id, id)

  defp path?(path),
    do:
      is_binary(path) and byte_size(path) in 1..4096 and String.valid?(path) and
        not String.contains?(path, <<0>>)

  defp read_json(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_json_bytes <-
           File.lstat(path),
         {:ok, json} when byte_size(json) <= @max_json_bytes <- File.read(path),
         {:ok, value} <- JSON.decode(json) do
      {:ok, value}
    else
      {:error, :enoent} -> {:error, :enoent}
      _ -> {:error, :unreadable_or_invalid_json}
    end
  end

  defp unique(items, kind) do
    case Enum.frequencies(items) |> Enum.find(fn {_item, count} -> count > 1 end) do
      nil -> :ok
      {item, _} -> {:error, {:duplicate, kind, item}}
    end
  end

  defp map_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _} = err -> err
    end
  end
end
