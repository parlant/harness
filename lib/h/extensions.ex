defmodule H.Extensions do
  @moduledoc false

  @api_version 1
  @max_json_bytes 65_536
  @max_extensions 32
  @max_modules 256
  @max_beam_bytes 4_194_304
  @id ~r/\A[a-z][a-z0-9._-]{0,79}\z/
  @namespace ~r/\AElixir\.[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)+\z/

  def load(opts) do
    if Keyword.get(opts, :no_extensions, false) do
      {:ok, opts, []}
    else
      data_dir = Keyword.fetch!(opts, :data_dir)
      config = Path.join(data_dir, "extensions.json")

      with {:ok, entries} <- entries(config),
           {:ok, packages} <- map_ok(entries, &manifest(&1, data_dir)),
           :ok <- unique(Enum.map(packages, & &1.id), :extension_id),
           {:ok, packages} <- map_ok(packages, &read_package/1),
           :ok <- unique(Enum.flat_map(packages, &Map.keys(&1.beams)), :module),
           {:ok, opts, children} <- compose(packages, opts) do
        {:ok, opts, children}
      else
        {:error, reason} -> {:error, {:extensions, reason}}
      end
    end
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
  # from explicitly trusted BEAM files. Same code can be reused by a restarted
  # supervision tree; replacing loaded code in this VM is not supported.
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

  defp compose([], opts), do: {:ok, opts, []}

  defp compose(packages, opts) do
    harnesses =
      case opts[:harnesses] do
        nil -> %{}
        list when is_list(list) -> Map.new(list, &{&1.id(), &1})
        map when is_map(map) -> map
      end

    environments =
      case opts[:environments] do
        nil -> %{}
        list when is_list(list) -> Map.new(list, &{env_value(&1, :id), &1})
        map when is_map(map) -> Map.new(map, fn {id, spec} -> {to_string(id), spec} end)
      end

    beams =
      packages
      |> Enum.flat_map(&Map.values(&1.beams))
      |> Enum.reject(fn {mod, _, _} -> :code.is_loaded(mod) != false end)

    with :ok <- :code.atomic_load(beams),
         {:ok, {harnesses, environments, children, policy}} <-
           merge_packages(packages, opts, {harnesses, environments, [], nil}) do
      opts = Keyword.merge(opts, harnesses: harnesses, environments: environments)
      opts = if policy, do: Keyword.put(opts, :codex_account_policy, policy), else: opts
      {:ok, opts, children}
    end
  end

  defp merge_packages(packages, opts, base) do
    Enum.reduce_while(packages, {:ok, base}, fn package,
                                                {:ok, {harnesses, envs, children, policy}} ->
      {mod, _, _} = Map.fetch!(package.beams, package.root)
      context = %{id: package.id, data_dir: Keyword.fetch!(opts, :data_dir)}

      with {:ok, package_harnesses, package_envs, specs, package_policy} <-
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
             ) do
        {:cont,
         {:ok,
          {Map.merge(harnesses, Map.new(package_harnesses)),
           Map.merge(envs, Map.new(package_envs)), children ++ specs, policy || package_policy}}}
      else
        {:error, reason} -> {:halt, {:error, {package.id, reason}}}
      end
    end)
  end

  defp validate_configure(mod, settings, context, opts) do
    with true <- function_exported?(mod, :configure, 2),
         {:ok, contributions} when is_map(contributions) <- mod.configure(settings, context),
         [] <-
           Map.keys(contributions) --
             [:harnesses, :environments, :children, :codex_account_policy],
         {:ok, harnesses} <- registrations(contributions, :harnesses, &harness(&1, opts)),
         {:ok, envs} <- registrations(contributions, :environments, &environment/1),
         {:ok, specs} <- registrations(contributions, :children, &child(&1, context.id)),
         :ok <- unique(Enum.map(specs, & &1.id), :child_id),
         {:ok, policy} <- account_policy(contributions[:codex_account_policy]) do
      {:ok, harnesses, envs, specs, policy}
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
      Enum.all?(behaviour.behaviour_info(:callbacks), fn {name, arity} ->
        function_exported?(mod, name, arity)
      end)
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
