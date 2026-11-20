defmodule H.Daemon.Workspace do
  @moduledoc """
  Workspace directory browsing, bounded recursive file discovery, UTF-8 file
  reading, and lexical + canonical symlink containment checks for `H.Daemon`.
  """

  alias H.{Catalog, Daemon.Validation, EnvRegistry, ExecutionEnv}

  @default_catalog_table :h_catalog
  @max_discovery_bytes 262_144
  @max_discovery_scanned 20_000
  @max_discovery_timeout_ms 2_000

  def browse(query_params, opts, wire_session_fn)
      when is_map(query_params) and is_list(opts) and is_function(wire_session_fn, 1) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)
    raw_env_id = Validation.param_get(query_params, "env_id", :env_id)
    env_id = if raw_env_id in [nil, ""], do: "host", else: raw_env_id
    raw_path = Validation.param_get(query_params, "path", :path)

    include_hidden =
      Validation.parse_bool_param(
        Validation.param_get(query_params, "include_hidden", :include_hidden),
        false
      )

    include_subsessions =
      Validation.parse_bool_param(
        Validation.param_get(query_params, "include_subsessions", :include_subsessions),
        Keyword.get(opts, :include_subsessions, false)
      )

    if not is_binary(env_id) do
      {:error, {:bad_request, "env_id must be a string"}}
    else
      with {:ok, base_env, desc} <- EnvRegistry.fetch_env(env_id, opts),
           target_path = if(raw_path in [nil, ""], do: desc.default_cwd, else: raw_path),
           :ok <- ensure_string_path(target_path),
           {:ok, bound_env} <- bind_browse_cwd(base_env, target_path),
           canonical_path = ExecutionEnv.cwd(bound_env),
           {:ok, %{entries: raw_dirs}} <-
             ExecutionEnv.list_dir(bound_env, canonical_path,
               only_dirs: true,
               include_hidden: include_hidden,
               markers: ExecutionEnv.default_markers(),
               limit: 500
             ) do
        annotated =
          Catalog.annotate_directories(desc.id, raw_dirs,
            table: table,
            parent_path: canonical_path,
            include_subsessions: include_subsessions,
            registry: Keyword.get(opts, :registry, H.Registry)
          )

        directories =
          Enum.map(annotated, fn dir ->
            dir_path = Map.get(dir, :path) || Path.join(canonical_path, dir.name)

            %{
              name: dir.name,
              path: dir_path,
              type: dir.type,
              markers: Map.get(dir, :markers, []),
              direct_session_count: Map.get(dir, :direct_session_count, 0),
              subtree_session_count: Map.get(dir, :subtree_session_count, 0),
              active_session_count: Map.get(dir, :active_session_count, 0),
              latest_session: Map.get(dir, :latest_session)
            }
          end)

        sessions =
          desc.id
          |> Catalog.list_sessions_for_cwd(canonical_path,
            table: table,
            subtree: false,
            include_subsessions: include_subsessions
          )
          |> Enum.map(wire_session_fn)

        parent_path = if canonical_path == "/", do: nil, else: Path.dirname(canonical_path)

        {:ok,
         %{
           env_id: desc.id,
           path: canonical_path,
           parent_path: parent_path,
           directories: directories,
           sessions: sessions
         }}
      else
        {:error, {:agent_down, _}} -> {:error, :workspace_unavailable}
        {:error, _} = err -> err
      end
    end
  end

  def list_files(query_params, opts) when is_map(query_params) and is_list(opts) do
    with {:ok, params} <- Validation.parse_list_files_params(query_params),
         {:ok, base_env, desc} <- EnvRegistry.fetch_env(params.env_id, opts),
         {:ok, bound_env} <- bind_workspace_cwd(base_env, params.cwd),
         canonical_cwd = ExecutionEnv.cwd(bound_env),
         {:ok, %{entries: entries, truncated: truncated}} <-
           ExecutionEnv.list_files(bound_env, canonical_cwd,
             include_hidden: params.include_hidden,
             include_dirs: params.include_dirs,
             exclude: params.exclude,
             query: params.query,
             limit: params.limit,
             max_bytes: @max_discovery_bytes,
             max_depth: params.max_depth,
             max_scanned: @max_discovery_scanned,
             timeout_ms: @max_discovery_timeout_ms
           ) do
      {:ok,
       %{
         env_id: desc.id,
         cwd: canonical_cwd,
         entries: entries,
         truncated: truncated
       }}
    else
      {:error, {:agent_down, _}} -> {:error, :workspace_unavailable}
      {:error, :unsupported} -> {:error, :workspace_unavailable}
      {:error, :enoent} -> {:error, :not_found}
      {:error, :enotdir} -> {:error, {:bad_request, "cwd is not a directory"}}
      {:error, :eacces} -> {:error, {:forbidden, "permission denied"}}
      {:error, _} = err -> err
    end
  end

  def read_file(query_params, opts) when is_map(query_params) and is_list(opts) do
    with {:ok, params} <- Validation.parse_read_file_params(query_params),
         {:ok, base_env, desc} <- EnvRegistry.fetch_env(params.env_id, opts),
         {:ok, bound_env} <- bind_workspace_cwd(base_env, params.cwd),
         canonical_cwd = ExecutionEnv.cwd(bound_env),
         {:ok, resolved_path} <- resolve_target_path(bound_env, params.path),
         :ok <- verify_lexical_containment(canonical_cwd, resolved_path),
         {:ok, canonical_root} <- fetch_canonical_root(bound_env, canonical_cwd),
         :ok <-
           verify_canonical_containment(bound_env, canonical_cwd, canonical_root, resolved_path),
         {:ok, result} <-
           ExecutionEnv.read_file_lines(bound_env, resolved_path,
             offset: params.offset,
             limit: params.limit,
             max_bytes: params.max_bytes,
             no_follow: true
           ) do
      {:ok,
       %{
         env_id: desc.id,
         cwd: canonical_cwd,
         path: relative_display_path(canonical_cwd, resolved_path),
         resolved_path: resolved_path,
         lines: result.lines,
         start_line: result.start_line,
         total_lines_read: result.total_lines_read,
         has_more: result.has_more,
         truncated_by_bytes: result.truncated_by_bytes
       }}
    else
      {:error, {:agent_down, _}} -> {:error, :workspace_unavailable}
      {:error, :symlink_not_followed} -> {:error, {:forbidden, "symlinks are not followed"}}
      {:error, :enoent} -> {:error, :not_found}
      {:error, :enotdir} -> {:error, {:bad_request, "parent path is not a directory"}}
      {:error, :eacces} -> {:error, {:forbidden, "permission denied"}}
      {:error, :eisdir} -> {:error, {:bad_request, "path is a directory"}}
      {:error, :not_regular_file} -> {:error, {:bad_request, "path is not a regular file"}}
      {:error, :binary_file} -> {:error, {:bad_request, "binary or invalid UTF-8 file"}}
      {:error, :einval} -> {:error, {:bad_request, "invalid path"}}
      {:error, _} = err -> err
    end
  end

  # Internal path binding & containment helpers

  defp bind_browse_cwd(base_env, target_path) do
    case ExecutionEnv.bind_cwd(base_env, target_path) do
      {:ok, bound} -> {:ok, bound}
      {:error, {:agent_down, _}} -> {:error, :workspace_unavailable}
      {:error, :enoent} -> {:error, :not_found}
      {:error, :enotdir} -> {:error, {:bad_request, "path is not a directory"}}
      {:error, reason} -> {:error, {:bad_request, "invalid path: #{inspect(reason)}"}}
    end
  end

  defp bind_workspace_cwd(base_env, cwd) do
    case ExecutionEnv.bind_cwd(base_env, cwd) do
      {:ok, bound} -> {:ok, bound}
      {:error, {:agent_down, _}} -> {:error, :workspace_unavailable}
      {:error, :enoent} -> {:error, :not_found}
      {:error, :enotdir} -> {:error, {:bad_request, "cwd is not a directory"}}
      {:error, :einval} -> {:error, {:bad_request, "invalid cwd"}}
      {:error, reason} -> {:error, {:bad_request, "invalid cwd: #{inspect(reason)}"}}
    end
  end

  defp resolve_target_path(env, path) do
    case ExecutionEnv.resolve_path(env, path) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, {:agent_down, _}} -> {:error, :workspace_unavailable}
      {:error, :einval} -> {:error, {:bad_request, "invalid path"}}
      {:error, reason} -> {:error, {:bad_request, "invalid path: #{inspect(reason)}"}}
    end
  end

  defp verify_lexical_containment(canonical_cwd, resolved_path) do
    cond do
      resolved_path == canonical_cwd -> {:error, {:bad_request, "path is a directory"}}
      within_workspace?(canonical_cwd, resolved_path) -> :ok
      true -> {:error, {:forbidden, "path outside workspace"}}
    end
  end

  defp fetch_canonical_root(env, canonical_cwd) do
    case ExecutionEnv.canonical_path(env, ".") do
      {:ok, root} -> {:ok, root}
      {:error, {:agent_down, _}} -> {:error, :workspace_unavailable}
      {:error, _} -> {:ok, canonical_cwd}
    end
  end

  defp verify_canonical_containment(env, canonical_cwd, canonical_root, resolved_path) do
    case ExecutionEnv.canonical_path(env, resolved_path) do
      {:ok, real_target} ->
        cond do
          real_target == canonical_root -> {:error, {:bad_request, "path is a directory"}}
          within_workspace?(canonical_root, real_target) -> :ok
          true -> {:error, {:forbidden, "path outside workspace"}}
        end

      {:error, :enoent} ->
        verify_ancestor_containment(
          env,
          canonical_cwd,
          canonical_root,
          Path.dirname(resolved_path)
        )

      {:error, :eloop} ->
        {:error, {:forbidden, "symlink loop detected"}}

      {:error, :eacces} ->
        {:error, {:forbidden, "permission denied"}}

      {:error, {:agent_down, _}} ->
        {:error, :workspace_unavailable}

      {:error, _reason} ->
        :ok
    end
  end

  defp verify_ancestor_containment(env, canonical_cwd, canonical_root, dir) do
    if not within_workspace?(canonical_cwd, dir) do
      {:error, {:forbidden, "path outside workspace"}}
    else
      case ExecutionEnv.canonical_path(env, dir) do
        {:ok, real_dir} ->
          if within_workspace?(canonical_root, real_dir) do
            :ok
          else
            {:error, {:forbidden, "path outside workspace"}}
          end

        {:error, :enoent} when dir != canonical_cwd ->
          verify_ancestor_containment(env, canonical_cwd, canonical_root, Path.dirname(dir))

        {:error, :eloop} ->
          {:error, {:forbidden, "symlink loop detected"}}

        {:error, :eacces} ->
          {:error, {:forbidden, "permission denied"}}

        {:error, {:agent_down, _}} ->
          {:error, :workspace_unavailable}

        {:error, _reason} ->
          :ok
      end
    end
  end

  defp within_workspace?(root, target) do
    normalized_root = if root == "/", do: "/", else: String.trim_trailing(root, "/")

    cond do
      normalized_root == "/" -> String.starts_with?(target, "/")
      target == normalized_root -> true
      true -> String.starts_with?(target, normalized_root <> "/")
    end
  end

  defp relative_display_path("/", resolved_path), do: String.trim_leading(resolved_path, "/")

  defp relative_display_path(canonical_cwd, resolved_path) do
    prefix = String.trim_trailing(canonical_cwd, "/") <> "/"
    String.replace_prefix(resolved_path, prefix, "")
  end

  defp ensure_string_path(p) when is_binary(p), do: :ok
  defp ensure_string_path(_), do: {:error, {:bad_request, "path must be a string"}}
end
