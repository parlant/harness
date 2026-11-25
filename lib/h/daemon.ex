defmodule H.Daemon do
  @moduledoc """
  Transport-agnostic daemon API for `H` sessions, conversations, transcripts,
  SSE subscriptions, and idempotent commands.

  Every function accepts `opts \\ []` so isolated `--no-start` tests and the
  full `H.HTTP` daemon share the exact same contract. Read
  [Local HTTP and SSE API on hiness.dev](https://hiness.dev/docs/protocol/) for
  wire formats, idempotent `request_id` retries, and SSE cursor rules.
  """

  require Logger

  alias H.{
    Catalog,
    Daemon.ColdSession,
    Daemon.Validation,
    Daemon.Workspace,
    EnvRegistry,
    ExecutionEnv,
    Harness,
    Session.Server,
    Session.Server.Recovery,
    Session.Supervisor
  }

  @default_registry H.Registry
  @default_pubsub H.PubSub
  @default_runtime_sup H.Session.RuntimeSupervisor
  @default_catalog H.Catalog
  @default_catalog_table :h_catalog
  @default_workspace_lease H.WorkspaceLease
  @default_max_subagent_depth 1
  @default_max_subagent_depth_hard 8
  @terminal_submission_statuses ["done", "unanswered", "withdrawn"]

  @doc "Returns the running instance's validated daemon options, or `nil` when not booted."
  @spec instance_options() :: keyword() | nil
  def instance_options do
    GenServer.call(H.Daemon.Boot, :options, :infinity)
  catch
    :exit, {:noproc, _} ->
      if Process.whereis(H.Daemon.Instance), do: exit(:daemon_not_ready), else: nil
  end

  @doc "Lists startup-loaded extensions for the running daemon."
  @spec list_extensions(keyword()) :: {:ok, map()} | {:error, term()}
  def list_extensions(opts \\ []) when is_list(opts) do
    opts = if opts == [], do: instance_options() || [], else: opts
    H.Daemon.Maintenance.extensions_status(opts)
  end

  @doc "Lists configured harness profile descriptors (`\"coding\"` first)."
  @spec list_harnesses(keyword()) :: [map()]
  def list_harnesses(opts \\ []) when is_list(opts) do
    Harness.list_harnesses(opts)
  end

  @doc "Lists configured execution environments (`\"host\"` plus any custom/remote environments)."
  @spec list_environments(keyword()) :: [map()]
  def list_environments(opts \\ []) when is_list(opts) do
    EnvRegistry.list_environments(opts)
  end

  @doc """
  Browses directories in an execution environment (`GET /api/v1/fs`), enriching
  each child directory with `H.Catalog` session counts/recency and listing
  sessions rooted directly at `path`.
  """
  @spec browse_workspace(map(), keyword()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :unknown_environment
             | :workspace_unavailable
             | {:bad_request, String.t()}}
  def browse_workspace(query_params \\ %{}, opts \\ [])
      when is_map(query_params) and is_list(opts) do
    Workspace.browse(query_params, opts, &wire_session(&1, opts))
  end

  @doc """
  Environment-scoped bounded recursive file discovery (`GET /api/v1/fs/files`).

  Requires explicit `env_id` and absolute `cwd` and never falls back to the
  daemon's local process `cwd`.
  """
  @spec list_files(map(), keyword()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :unknown_environment
             | :workspace_unavailable
             | {:forbidden, String.t()}
             | {:bad_request, String.t()}}
  def list_files(query_params \\ %{}, opts \\ [])

  def list_files(query_params, opts) when is_map(query_params) and is_list(opts) do
    Workspace.list_files(query_params, opts)
  end

  def list_files(_query_params, _opts), do: {:error, {:bad_request, "expected a map"}}

  @doc """
  Environment-scoped bounded read-only UTF-8 file reader (`GET /api/v1/fs/file`).

  Requires explicit `env_id`, absolute `cwd`, and `path`. Enforces workspace
  boundary containment (lexical + canonical symlink checks) and `no_follow: true`.
  """
  @spec read_file(map(), keyword()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :unknown_environment
             | :workspace_unavailable
             | {:forbidden, String.t()}
             | {:bad_request, String.t()}}
  def read_file(query_params \\ %{}, opts \\ [])

  def read_file(query_params, opts) when is_map(query_params) and is_list(opts) do
    Workspace.read_file(query_params, opts)
  end

  def read_file(_query_params, _opts), do: {:error, {:bad_request, "expected a map"}}

  @doc """
  Session-scoped bounded recursive file discovery (`GET /api/v1/sessions/:sid/files`).

  Resolves `{env_id, cwd}` strictly from the session's `H.Catalog` record.
  """
  @spec list_session_files(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_session_files(session_id, query_params \\ %{}, opts \\ [])

  def list_session_files(session_id, query_params, opts)
      when is_binary(session_id) and is_map(query_params) and is_list(opts) do
    with {:ok, entry} <- lookup_active_session_entry(session_id, opts) do
      scoped_params =
        query_params
        |> Map.drop(["env_id", :env_id, "cwd", :cwd])
        |> Map.put("env_id", Map.get(entry, :env_id) || "host")
        |> Map.put("cwd", entry.cwd)

      case list_files(scoped_params, opts) do
        {:error, :unknown_environment} -> {:error, :workspace_unavailable}
        other -> other
      end
    end
  end

  def list_session_files(_session_id, _query_params, _opts),
    do: {:error, {:bad_request, "expected a map"}}

  @doc """
  Session-scoped bounded read-only UTF-8 file reader (`GET /api/v1/sessions/:sid/file`).

  Resolves `{env_id, cwd}` strictly from the session's `H.Catalog` record.
  """
  @spec read_session_file(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_session_file(session_id, query_params \\ %{}, opts \\ [])

  def read_session_file(session_id, query_params, opts)
      when is_binary(session_id) and is_map(query_params) and is_list(opts) do
    with {:ok, entry} <- lookup_active_session_entry(session_id, opts) do
      scoped_params =
        query_params
        |> Map.drop(["env_id", :env_id, "cwd", :cwd])
        |> Map.put("env_id", Map.get(entry, :env_id) || "host")
        |> Map.put("cwd", entry.cwd)

      case read_file(scoped_params, opts) do
        {:error, :unknown_environment} -> {:error, :workspace_unavailable}
        other -> other
      end
    end
  end

  def read_session_file(_session_id, _query_params, _opts),
    do: {:error, {:bad_request, "expected a map"}}

  @doc "Browses workspace directories, Git history, or a commit in the session's execution environment."
  def review_workspace(session_id, params, opts \\ []) do
    with {:ok, workspace} <- review_workspace_binding(session_id, opts),
         {:ok, browser} <- H.Daemon.Review.browse(workspace, params) do
      {:ok, Map.put(browser, :archived, workspace.archived)}
    end
  end

  @doc "Reads a bounded review file from the worktree, HEAD, or a pinned commit."
  def read_review_file(session_id, path, source, opts \\ []) do
    with {:ok, workspace} <- review_workspace_binding(session_id, opts),
         {:ok, file} <- H.Daemon.Review.read(workspace, path, source) do
      {:ok, Map.put(file, :archived, workspace.archived)}
    end
  end

  @doc "Saves an existing text file if its revision still matches, under the workspace lease."
  def save_review_file(session_id, path, revision, text, opts \\ []) do
    H.Daemon.Maintenance.admit(opts, fn ->
      with {:ok, %{archived: false} = workspace} <- review_workspace_binding(session_id, opts) do
        H.Daemon.Review.save(
          workspace,
          path,
          revision,
          text,
          {Keyword.get(opts, :workspace_lease, @default_workspace_lease),
           {session_id, :file_review, make_ref()}}
        )
      else
        {:ok, _} -> {:error, :read_only}
        {:error, _} = error -> error
      end
    end)
  end

  defp review_workspace_binding(session_id, opts) do
    with {:ok, entry} <- lookup_active_session_entry(session_id, opts),
         {:ok, workspace} <-
           EnvRegistry.resolve_workspace(entry.env_id || "host", entry.cwd, opts),
         {:ok, env} <- ExecutionEnv.bind_canonical_cwd(workspace.env, workspace.cwd) do
      {:ok,
       %{workspace | env: env, cwd: ExecutionEnv.cwd(env)}
       |> Map.put(:archived, entry.status == "archived" or entry.archived == true)}
    end
  end

  @doc "Opens a dedicated review session, reusing the last one for this workspace while empty."
  def open_workspace_review(params, opts \\ []) when is_map(params) do
    H.Daemon.Maintenance.admit(opts, fn ->
      with {:ok, validated, agent} <- Validation.validate_create_session_params(params),
           {:ok, workspace} <-
             resolve_session_workspace(Map.get(validated, :env_id, "host"), validated.cwd, opts) do
        table = Keyword.get(opts, :catalog_table, @default_catalog_table)
        key = {workspace.env_id, workspace.cwd}
        digest = H.Daemon.Review.revision(:erlang.term_to_binary(key))
        prefix = "review-" <> binary_part(digest, 0, 24) <> "-"

        # Serialize only the open/reuse decision for this workspace in this VM.
        :global.trans(
          {{__MODULE__, table, key}, self()},
          fn ->
            latest =
              workspace.env_id
              |> Catalog.list_sessions_for_cwd(workspace.cwd,
                table: table,
                include_subsessions: false
              )
              |> Enum.reduce(0, fn entry, latest ->
                with true <- String.starts_with?(entry.session_id, prefix),
                     {n, ""} <- Integer.parse(String.replace_prefix(entry.session_id, prefix, "")) do
                  max(n, latest)
                else
                  _ -> latest
                end
              end)

            sid = prefix <> Integer.to_string(latest)

            with {:ok, %{archived: false, status: "ok", active: false} = entry} <-
                   Catalog.get_session(sid, table),
                 {:ok, %{items: []}} <-
                   scan_entries(sid, entry.root_conversation_id, %{limit: 1}, opts) do
              session_result(entry, opts, nil)
            else
              {:error, error} when error != :not_found ->
                {:error, error}

              _ ->
                do_create_session(
                  %{
                    "session_id" => prefix <> Integer.to_string(latest + 1),
                    "title" => "File review",
                    "env_id" => workspace.env_id,
                    "cwd" => workspace.cwd
                  }
                  |> maybe_put("agent", agent),
                  opts
                )
            end
          end,
          [node()]
        )
      end
    end)
  end

  @doc "Lists models from the configured `H.Provider`."
  @spec list_models(keyword()) :: [map()]
  def list_models(opts \\ []) when is_list(opts) do
    provider_mod = Keyword.get(opts, :provider, H.Provider.ReqLLM)
    provider_mod.list_models(provider_config(opts))
  end

  @doc "Lists sessions directly from `H.Catalog` ETS without waking unloaded sessions."
  @spec list_sessions(keyword()) :: [map()]
  def list_sessions(opts \\ [])

  def list_sessions(opts) when is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    table
    |> Catalog.list_sessions()
    |> Enum.map(&wire_session(&1, opts))
  end

  @doc "Lists sessions filtered by `env_id`, `cwd`, optional `subtree`, `archived`, and `include_subsessions`."
  @spec list_sessions(map(), keyword()) :: {:ok, [map()]} | {:error, {:bad_request, String.t()}}
  def list_sessions(query_params, opts) when is_map(query_params) and is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)
    raw_env_id = Validation.param_get(query_params, "env_id", :env_id)
    raw_cwd = Validation.param_get(query_params, "cwd", :cwd)
    raw_archived = Validation.param_get(query_params, "archived", :archived)

    subtree? =
      Validation.parse_bool_param(Validation.param_get(query_params, "subtree", :subtree), false)

    include_subsessions? =
      Validation.parse_bool_param(
        Validation.param_get(query_params, "include_subsessions", :include_subsessions),
        true
      )

    with {:ok, archived_filter} <- parse_archived_filter(raw_archived) do
      cond do
        not (is_nil(raw_env_id) or is_binary(raw_env_id)) ->
          {:error, {:bad_request, "env_id must be a string"}}

        not (is_nil(raw_cwd) or is_binary(raw_cwd)) ->
          {:error, {:bad_request, "cwd must be a string"}}

        is_binary(raw_cwd) and raw_cwd != "" ->
          env_id = if raw_env_id in [nil, ""], do: "host", else: raw_env_id

          canonical_cwd =
            case EnvRegistry.fetch_env(env_id, opts) do
              {:ok, base_env, _desc} ->
                case ExecutionEnv.resolve_path(base_env, raw_cwd) do
                  {:ok, resolved} -> resolved
                  _ -> raw_cwd
                end

              _ ->
                raw_cwd
            end

          sessions =
            env_id
            |> Catalog.list_sessions_for_cwd(canonical_cwd,
              table: table,
              subtree: subtree?,
              include_subsessions: include_subsessions?
            )
            |> filter_archived(archived_filter)
            |> Enum.map(&wire_session(&1, opts))

          {:ok, sessions}

        is_binary(raw_env_id) and raw_env_id != "" ->
          sessions =
            table
            |> Catalog.list_sessions()
            |> Enum.filter(fn entry ->
              (entry.env_id || "host") == raw_env_id and
                (include_subsessions? or Catalog.root_session?(entry))
            end)
            |> filter_archived(archived_filter)
            |> Enum.map(&wire_session(&1, opts))

          {:ok, sessions}

        true ->
          sessions =
            table
            |> Catalog.list_sessions()
            |> Enum.filter(&(include_subsessions? or Catalog.root_session?(&1)))
            |> filter_archived(archived_filter)
            |> Enum.map(&wire_session(&1, opts))

          {:ok, sessions}
      end
    end
  end

  @doc """
  Idempotently creates (or attaches to) a session, persists it in `H.Catalog`,
  and starts its supervised `H.Session.Server`.

  When `session_id` is omitted or empty, a unique `<folder-slug>-<hex>` ID is
  minted automatically.
  """
  @spec create_session(map(), keyword()) ::
          {:ok, %{session: map(), seq: non_neg_integer()}}
          | {:error, {:bad_request, String.t()} | {:conflict, String.t()} | term()}
  def create_session(params, opts \\ [])

  def create_session(params, opts) when is_map(params) and is_list(opts) do
    H.Daemon.Maintenance.admit(opts, fn -> do_create_session(params, opts) end)
  end

  def create_session(_params, _opts), do: {:error, {:bad_request, "expected a map"}}

  defp do_create_session(params, opts) do
    with {:ok, validated, agent_opts} <- Validation.validate_create_session_params(params) do
      table = Keyword.get(opts, :catalog_table, @default_catalog_table)

      case Map.get(validated, :session_id) && Catalog.get_session(validated.session_id, table) do
        {:ok, existing} -> attach_session(existing, validated, opts)
        _ -> create_new_session(validated, agent_opts || %{}, opts)
      end
    end
  end

  defp attach_session(%{status: "archived"}, _params, _opts),
    do: {:error, {:conflict, "session is archived"}}

  defp attach_session(entry, params, opts) do
    harness_id = Map.get(entry, :harness_id) || "coding"
    env_id = Map.get(entry, :env_id) || "host"

    with :ok <- Validation.ensure_not_quarantined(entry),
         {:ok, harness} <- Harness.resolve(harness_id, opts),
         :ok <- match_harness(Map.get(params, :harness_id), harness_id, harness, opts),
         :ok <- match_workspace(env_id, entry.cwd, params, opts),
         :ok <- match_parent(params, Map.get(entry, :parent)) do
      session_result(entry, opts, nil)
    else
      {:error, :unknown_harness} -> {:error, :harness_unavailable}
      {:error, _} = error -> error
    end
  end

  defp match_parent(params, recorded_parent) do
    if not Map.has_key?(params, :parent) do
      :ok
    else
      case {Map.get(params, :parent), recorded_parent} do
        {nil, nil} ->
          :ok

        {nil, _non_nil} ->
          {:error, {:conflict, "session already exists with different parent"}}

        {_req_parent, nil} ->
          {:error, {:conflict, "session already exists with different parent"}}

        {req_parent, rec_parent} ->
          same_sid? = req_parent.session_id == rec_parent.session_id

          same_cid? =
            is_nil(Map.get(req_parent, :conversation_id)) or
              req_parent.conversation_id == rec_parent.conversation_id

          same_entry? =
            not Map.has_key?(req_parent, :at_entry_id) or
              is_nil(Map.get(req_parent, :at_entry_id)) or
              req_parent.at_entry_id == rec_parent.at_entry_id

          if same_sid? and same_cid? and same_entry? do
            :ok
          else
            {:error, {:conflict, "session already exists with different parent"}}
          end
      end
    end
  end

  defp match_harness(id, recorded, _harness, _opts) when id in [nil, recorded], do: :ok

  defp match_harness(requested, recorded, harness, opts) do
    case Harness.resolve(requested, opts) do
      {:ok, ^harness} ->
        if harness.id() == recorded,
          do: :ok,
          else: {:error, {:conflict, "session already exists with different harness"}}

      _ ->
        {:error, {:conflict, "session already exists with different harness"}}
    end
  end

  defp match_workspace(env_id, cwd, params, opts) do
    if Map.get(params, :env_id, env_id) == env_id do
      case EnvRegistry.resolve_workspace(env_id, params.cwd, opts) do
        {:ok, %{cwd: ^cwd}} ->
          :ok

        {:error, :unknown_environment} ->
          {:error, :workspace_unavailable}

        {:error, :workspace_unavailable} ->
          {:error, :workspace_unavailable}

        {:error, reason} when reason in [:enoent, :enotdir] ->
          with {:ok, base_env, _desc} <- EnvRegistry.fetch_env(env_id, opts),
               {:ok, ^cwd} <- ExecutionEnv.resolve_path(base_env, params.cwd) do
            :ok
          else
            {:error, :unknown_environment} -> {:error, :workspace_unavailable}
            {:error, :workspace_unavailable} -> {:error, :workspace_unavailable}
            _ -> {:error, {:conflict, "session already exists with different workspace"}}
          end

        _ ->
          {:error, {:conflict, "session already exists with different workspace"}}
      end
    else
      {:error, {:conflict, "session already exists with different workspace"}}
    end
  end

  defp create_new_session(params, agent_opts, opts) do
    catalog = Keyword.get(opts, :catalog, @default_catalog)
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    with {:ok, harness} <- resolve_harness(Map.get(params, :harness_id, "coding"), opts),
         {:ok, ws} <-
           resolve_session_workspace(Map.get(params, :env_id, "host"), params.cwd, opts),
         candidate_sid = Map.get(params, :session_id) || mint_session_id(ws.cwd, table),
         {:ok, resolved_parent, resolved_role} <-
           resolve_parent_lineage(candidate_sid, params, table, opts),
         session_depth = get_in(resolved_parent, [:depth]) || 0,
         bootstrap_opts =
           opts
           |> Keyword.put(:session_depth, session_depth)
           |> Keyword.put_new(:max_subagent_depth, @default_max_subagent_depth),
         {:ok, bootstrapped} <- bootstrap_agent(harness, ws.env, agent_opts, bootstrap_opts) do
      attrs =
        %{
          session_id: candidate_sid,
          env_id: ws.env_id,
          harness_id: harness.id(),
          cwd: ws.cwd
        }
        |> maybe_put(:title, Map.get(params, :title))
        |> maybe_put(:parent, resolved_parent)
        |> maybe_put(:role, resolved_role)
        |> maybe_put(:tags, Map.get(params, :tags))

      case Catalog.insert_session(catalog, attrs) do
        {:ok, entry} -> session_result(entry, opts, bootstrapped)
        {:existing, entry} -> attach_session(entry, params, opts)
        {:error, _} = error -> error
      end
    end
  end

  defp resolve_parent_lineage(candidate_sid, params, table, opts) do
    case Map.get(params, :parent) do
      nil ->
        {:ok, nil, Map.get(params, :role)}

      %{session_id: ^candidate_sid} ->
        {:error, {:bad_request, "session cannot be its own parent"}}

      parent_req ->
        max_depth = Keyword.get(opts, :max_subagent_depth_hard, @default_max_subagent_depth_hard)

        case Catalog.get_session(parent_req.session_id, table) do
          {:error, :not_found} ->
            {:error, {:bad_request, "parent session not found: #{parent_req.session_id}"}}

          {:ok, parent_entry} ->
            depth = (get_in(parent_entry, [:parent, :depth]) || 0) + 1

            if depth > max_depth do
              {:error, {:bad_request, "subsession depth limit exceeded"}}
            else
              parent_cid =
                Map.get(parent_req, :conversation_id) ||
                  Map.get(parent_entry, :root_conversation_id) || 1

              with {:ok, at_entry_id} <-
                     resolve_parent_step(
                       parent_entry,
                       parent_cid,
                       Map.get(parent_req, :at_entry_id),
                       opts
                     ) do
                resolved_parent = %{
                  session_id: parent_entry.session_id,
                  conversation_id: parent_cid,
                  at_entry_id: at_entry_id,
                  task_id: Map.get(parent_req, :task_id),
                  depth: depth,
                  env_id: parent_entry.env_id,
                  cwd: parent_entry.cwd
                }

                resolved_role =
                  if Map.has_key?(params, :role) and not is_nil(Map.get(params, :role)) do
                    Map.get(params, :role)
                  else
                    if Map.has_key?(params, :role), do: Map.get(params, :role), else: "subagent"
                  end

                {:ok, resolved_parent, resolved_role}
              end
            end
        end
    end
  end

  defp resolve_parent_step(parent_entry, parent_cid, requested_at_entry_id, opts) do
    if Keyword.get(opts, :parent_verified, false) == true do
      {:ok, requested_at_entry_id}
    else
      case Validation.ensure_not_quarantined(parent_entry) do
        {:error, _} ->
          {:ok, requested_at_entry_id}

        :ok ->
          call_session(parent_entry, opts, fn server ->
            cond do
              server == self() ->
                {:ok, requested_at_entry_id}

              is_nil(requested_at_entry_id) ->
                case Server.scan_entries(server, parent_cid, %{order: :desc, limit: 1}) do
                  {:ok, %{items: [latest | _]}} ->
                    {:ok, latest.id}

                  {:error, :not_found} ->
                    {:error, {:bad_request, "parent conversation not found: #{parent_cid}"}}

                  _ ->
                    {:ok, nil}
                end

              true ->
                case Server.verify_visible_entry(server, parent_cid, requested_at_entry_id) do
                  {:error, :not_found} ->
                    {:error, {:bad_request, "parent conversation not found: #{parent_cid}"}}

                  {:error, :entry_not_visible} ->
                    {:error, {:bad_request, "parent at_entry_id not visible"}}

                  _ ->
                    {:ok, requested_at_entry_id}
                end
            end
          end)
          |> case do
            {:error, {:bad_request, _}} = error -> error
            {:error, _} -> {:ok, requested_at_entry_id}
            result -> result
          end
      end
    end
  end

  defp bootstrap_agent(harness, env, agent_opts, opts) do
    with {:ok, agent} when is_map(agent) <- harness.bootstrap_agent(env, agent_opts, opts),
         {:ok, validated} <- Validation.validate_optional_agent(agent) do
      {:ok, validated}
    else
      _ -> {:error, :harness_unavailable}
    end
  rescue
    _ -> {:error, :harness_unavailable}
  catch
    :exit, _ -> {:error, :harness_unavailable}
  end

  defp session_result(entry, opts, initial_agent) do
    with {:ok, seq} <- call_session(entry, opts, &Server.get_seq/1, initial_agent: initial_agent) do
      table = Keyword.get(opts, :catalog_table, @default_catalog_table)

      latest_entry =
        case Catalog.get_session(entry.session_id, table) do
          {:ok, latest} -> latest
          _ -> entry
        end

      {:ok, %{session: wire_session(latest_entry, opts), seq: seq}}
    end
  end

  @doc "Updates a session's `needs_attention` flag or `tags` without waking it."
  @spec triage_session(String.t(), map(), keyword()) ::
          {:ok, %{session: map()}}
          | {:error, :not_found | {:bad_request, String.t()} | term()}
  def triage_session(session_id, params, opts \\ [])

  def triage_session(session_id, params, opts)
      when is_binary(session_id) and is_map(params) and is_list(opts) do
    H.Daemon.Maintenance.admit(opts, fn -> do_triage_session(session_id, params, opts) end)
  end

  def triage_session(_session_id, _params, _opts),
    do: {:error, {:bad_request, "expected a map"}}

  defp do_triage_session(session_id, params, opts) do
    catalog = Keyword.get(opts, :catalog, @default_catalog)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         {:ok, updated} <- Catalog.set_triage(catalog, session_id, params) do
      {:ok, %{session: wire_session(updated, opts)}}
    else
      {:error, msg} when is_binary(msg) -> {:error, {:bad_request, msg}}
      {:error, _} = err -> err
    end
  end

  @doc "Stops all active runs across all conversations in a session."
  @spec stop_session(String.t(), map(), keyword()) ::
          {:ok, %{session: map()}}
          | {:error,
             :not_found | {:bad_request, String.t()} | {:quarantined, String.t()} | term()}
  def stop_session(session_id, params \\ %{}, opts \\ [])

  def stop_session(session_id, params, opts)
      when is_binary(session_id) and is_map(params) and is_list(opts) do
    H.Daemon.Maintenance.admit(opts, fn -> do_stop_session(session_id, params, opts) end)
  end

  def stop_session(_session_id, _params, _opts),
    do: {:error, {:bad_request, "expected a map"}}

  defp do_stop_session(session_id, params, opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)
    catalog = Keyword.get(opts, :catalog, @default_catalog)
    registry = Keyword.get(opts, :registry, @default_registry)
    raw_reason = Validation.param_get(params, "reason", :reason)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         {:ok, reason} <- parse_stop_reason(raw_reason),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- Validation.ensure_not_quarantined(entry),
         :ok <-
           if(entry.status == "archived",
             do: {:error, {:conflict, "session is archived"}},
             else: :ok
           ),
         :ok <- stop_runtime(lookup_live_server(registry, session_id), entry, reason, catalog) do
      latest =
        case Catalog.get_session(session_id, table) do
          {:ok, cur} -> cur
          _ -> entry
        end

      {:ok, %{session: wire_session(latest, opts)}}
    end
  end

  defp stop_runtime({:ok, pid, marker}, _entry, reason, _catalog) do
    case call_live(pid, marker, &Server.abort_all(&1, reason)) do
      {:ok, _} -> :ok
      :idle_unload -> :ok
      {:error, _} = error -> error
    end
  end

  defp stop_runtime(:not_running, entry, _reason, catalog) do
    if entry.active or entry.attention in ["running", "sleeping", "retrying"] do
      Catalog.report_runtime(catalog, entry.session_id, %{
        active: false,
        attention: "idle",
        activity_kind: nil,
        activity_label: nil
      })
    end

    :ok
  end

  @doc "Archives (and unloads from RAM) or unarchives a session."
  @spec archive_session(String.t(), map(), keyword()) ::
          {:ok, %{session: map()}}
          | {:error,
             :not_found
             | {:bad_request, String.t()}
             | {:conflict, String.t()}
             | {:quarantined, String.t()}
             | term()}
  def archive_session(session_id, params \\ %{}, opts \\ [])

  def archive_session(session_id, params, opts)
      when is_binary(session_id) and is_map(params) and is_list(opts) do
    H.Daemon.Maintenance.admit(opts, fn -> do_archive_session(session_id, params, opts) end)
  end

  def archive_session(_session_id, _params, _opts),
    do: {:error, {:bad_request, "expected a map"}}

  defp do_archive_session(session_id, params, opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)
    catalog = Keyword.get(opts, :catalog, @default_catalog)
    registry = Keyword.get(opts, :registry, @default_registry)
    runtime_sup = Keyword.get(opts, :runtime_sup, @default_runtime_sup)

    raw_archived = Validation.param_get(params, "archived", :archived)

    raw_stop =
      case Validation.param_get(params, "stop", :stop) do
        nil -> Validation.param_get(params, "force", :force)
        val -> val
      end

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         {:ok, archived?} <- Validation.parse_optional_strict_bool(raw_archived, true, "archived"),
         {:ok, stop?} <- Validation.parse_optional_strict_bool(raw_stop, false, "stop"),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- if(archived?, do: :ok, else: Validation.ensure_not_quarantined(entry)) do
      if archived? do
        live_server = lookup_live_server(registry, session_id)

        busy? =
          case live_server do
            {:ok, pid, _marker} ->
              try do
                not GenServer.call(pid, :idle)
              catch
                :exit, _ -> false
              end

            :not_running ->
              entry.active == true
          end

        cond do
          busy? and not stop? ->
            {:error, {:conflict, "session_busy"}}

          true ->
            if busy? do
              case live_server do
                {:ok, pid, _marker} ->
                  {:ok, _} = Server.abort_all(pid, "archived")

                :not_running ->
                  :ok
              end
            end

            :ok = Supervisor.stop_session(registry, runtime_sup, session_id)
            {:ok, updated} = Catalog.set_archived(catalog, session_id, true)
            {:ok, %{session: wire_session(updated, opts)}}
        end
      else
        needs_attention =
          case Map.fetch(params, "needs_attention") do
            {:ok, v} when is_boolean(v) ->
              v

            _ ->
              case Map.fetch(params, :needs_attention) do
                {:ok, v} when is_boolean(v) -> v
                _ -> true
              end
          end

        case Catalog.set_archived(catalog, session_id, false, needs_attention: needs_attention) do
          {:ok, updated} -> {:ok, %{session: wire_session(updated, opts)}}
          {:error, _} = err -> err
        end
      end
    end
  end

  @doc """
  Forks a session's visible conversation history into a brand-new session bound
  to an existing target `cwd` (allowing recovery/continuation when the original
  `cwd` was deleted or moved).
  """
  @spec fork_session(String.t(), map(), keyword()) ::
          {:ok, %{session: map(), seq: non_neg_integer()}}
          | {:error,
             :not_found
             | {:bad_request, String.t()}
             | {:conflict, String.t()}
             | {:quarantined, String.t()}
             | term()}
  def fork_session(source_session_id, params, opts \\ [])

  def fork_session(source_session_id, params, opts)
      when is_binary(source_session_id) and is_map(params) and is_list(opts) do
    H.Daemon.Maintenance.admit(opts, fn -> do_fork_session(source_session_id, params, opts) end)
  end

  def fork_session(_source_session_id, _params, _opts),
    do: {:error, {:bad_request, "expected a map"}}

  defp do_fork_session(source_session_id, params, opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)
    catalog = Keyword.get(opts, :catalog, @default_catalog)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(source_session_id),
         {:ok, validated} <- Validation.validate_fork_session_params(params),
         {:ok, source_entry} <- Catalog.get_session(source_session_id, table),
         :ok <- Validation.ensure_not_quarantined(source_entry),
         target_env_id = Map.get(validated, :env_id) || Map.get(source_entry, :env_id) || "host",
         harness_id =
           if(source_entry.status == "archived",
             do: "coding",
             else: Map.get(source_entry, :harness_id) || "coding"
           ),
         {:ok, harness} <- resolve_harness(harness_id, opts),
         {:ok, ws} <- resolve_session_workspace(target_env_id, validated.cwd, opts),
         source_cid =
           Map.get(validated, :conversation_id) || Map.get(source_entry, :root_conversation_id) ||
             1,
         {:ok, %{entries: exported_entries, agent: source_agent}} <-
           export_source_branch(
             source_entry,
             source_cid,
             Map.get(validated, :at_entry_id),
             opts
           ),
         agent_overrides = build_fork_agent_overrides(source_agent),
         {:ok, bootstrapped} <- bootstrap_agent(harness, ws.env, agent_overrides, opts) do
      new_sid = Map.get(validated, :session_id) || mint_session_id(ws.cwd, table)

      new_title =
        if Map.has_key?(validated, :title) do
          validated.title
        else
          source_entry.title
        end

      attrs =
        %{
          session_id: new_sid,
          env_id: ws.env_id,
          harness_id: harness.id(),
          cwd: ws.cwd,
          tags: source_entry.tags
        }
        |> maybe_put(:title, new_title)

      case Catalog.insert_session(catalog, attrs) do
        {:ok, new_entry} ->
          with {:ok, %{seq: seq}} <-
                 call_session(new_entry, opts, &Server.seed_entries(&1, exported_entries, 1),
                   initial_agent: bootstrapped
                 ) do
            latest_new_entry =
              case Catalog.get_session(new_entry.session_id, table) do
                {:ok, latest} -> latest
                _ -> new_entry
              end

            {:ok, %{session: wire_session(latest_new_entry, opts), seq: seq}}
          end

        {:existing, _} ->
          {:error, {:conflict, "session already exists"}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp export_source_branch(%{status: "archived"} = source_entry, cid, at_entry_id, opts) do
    H.Archive.export_branch(source_entry, cid, at_entry_id, opts)
  end

  defp export_source_branch(source_entry, cid, at_entry_id, opts) do
    registry = Keyword.get(opts, :registry, @default_registry)

    if Map.get(source_entry, :archived) == true and
         lookup_live_server(registry, source_entry.session_id) == :not_running do
      ColdSession.export_branch(
        source_entry,
        cid,
        at_entry_id,
        opts,
        cold_default_model(opts)
      )
    else
      call_session(source_entry, opts, &Server.export_branch(&1, cid, at_entry_id),
        preserve_archive: true
      )
    end
  end

  defp build_fork_agent_overrides(source_agent) when is_map(source_agent) do
    ["model", "thinking", "system_prompt", "tools", "budget", "approval_policy"]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.fetch(source_agent, key) do
        {:ok, val} -> Map.put(acc, key, val)
        :error -> acc
      end
    end)
  end

  defp build_fork_agent_overrides(_), do: %{}

  @doc "Returns session detail, conversation ancestry forest, and live tasks."
  @spec get_session_detail(String.t(), keyword()) ::
          {:ok, %{session: map(), conversations: [map()], tasks: [map()]}}
          | {:error, :not_found | {:quarantined, String.t()} | term()}
  def get_session_detail(session_id, opts \\ [])
      when is_binary(session_id) and is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- Validation.ensure_not_quarantined(entry) do
      registry = Keyword.get(opts, :registry, @default_registry)

      cond do
        entry.status == "archived" ->
          H.Archive.detail(entry, opts)

        Map.get(entry, :archived) == true and
            lookup_live_server(registry, session_id) == :not_running ->
          ColdSession.detail(entry, opts, &wire_session(&1, opts), &wire_conversation/1)

        true ->
          live_session_detail(entry, opts, table)
      end
    end
  end

  defp live_session_detail(entry, opts, table) do
    with {:ok, detail} <- call_session(entry, opts, &Server.get_detail/1, preserve_archive: true) do
      session_id = entry.session_id

      session_entry =
        case Catalog.get_session(session_id, table) do
          {:ok, latest} -> latest
          _ -> entry
        end
        |> then(fn current ->
          if is_map(detail.session_meta) and Map.has_key?(detail.session_meta, :title) do
            %{current | title: detail.session_meta.title}
          else
            current
          end
        end)

      wired_session =
        session_entry
        |> wire_session(opts)
        |> Map.put(:cwd_exists, Map.get(detail, :cwd_exists, true))

      {:ok,
       %{
         session: wired_session,
         conversations: Enum.map(detail.conversations, &wire_conversation/1),
         tasks: Enum.map(detail.tasks, &H.Task.to_wire/1)
       }}
    end
  end

  @doc """
  Returns a bounded, read-only session-wide entry tree across all conversations
  and branches without waking unloaded archived sessions.
  """
  @spec get_session_tree(String.t(), keyword()) ::
          {:ok, %{session: map(), conversations: [map()], nodes: [map()], truncated: boolean()}}
          | {:error, :not_found | {:quarantined, String.t()} | term()}
  def get_session_tree(session_id, opts \\ [])
      when is_binary(session_id) and is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- Validation.ensure_not_quarantined(entry) do
      registry = Keyword.get(opts, :registry, @default_registry)

      cond do
        entry.status == "archived" ->
          H.Archive.tree(entry, opts)

        Map.get(entry, :archived) == true and
            lookup_live_server(registry, session_id) == :not_running ->
          ColdSession.tree(entry, opts, &wire_session(&1, opts))

        true ->
          live_session_tree(entry, opts, table)
      end
    end
  end

  defp live_session_tree(entry, opts, table) do
    with {:ok, tree} <- call_session(entry, opts, &Server.get_tree/1, preserve_archive: true) do
      session_id = entry.session_id

      session_entry =
        case Catalog.get_session(session_id, table) do
          {:ok, latest} -> latest
          _ -> entry
        end
        |> then(fn current ->
          if is_map(tree.session_meta) and Map.has_key?(tree.session_meta, :title) do
            %{current | title: tree.session_meta.title}
          else
            current
          end
        end)

      wired_session =
        session_entry
        |> wire_session(opts)
        |> Map.put(:cwd_exists, Map.get(tree, :cwd_exists, true))

      {:ok,
       %{
         session: wired_session,
         conversations: tree.conversations,
         nodes: tree.nodes,
         truncated: tree.truncated
       }}
    end
  end

  @doc "Returns the read-only extension status projection for a conversation's configured model."
  @spec extension_status(String.t(), term(), keyword()) ::
          {:ok, map()}
          | {:error,
             :not_found | {:bad_request, String.t()} | {:quarantined, String.t()} | term()}
  def extension_status(session_id, conversation_id, opts \\ [])
      when is_binary(session_id) and is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- Validation.ensure_not_quarantined(entry),
         {:ok, cid} <- Validation.parse_cid(conversation_id),
         {:ok, model} <- resolve_conversation_model(entry, cid, opts) do
      scope = %{
        session_id: entry.session_id,
        conversation_id: to_string(cid),
        model: model
      }

      projections = Keyword.get(opts, :status_projections, [])
      {:ok, H.Extensions.Status.project(scope, projections)}
    end
  end

  defp resolve_conversation_model(entry, cid, opts) do
    registry = Keyword.get(opts, :registry, @default_registry)

    cond do
      entry.status == "archived" ->
        {:ok, nil}

      Map.get(entry, :archived) == true and
          lookup_live_server(registry, entry.session_id) == :not_running ->
        table = Keyword.get(opts, :catalog_table, @default_catalog_table)

        case ColdSession.snapshot(entry, cid, opts, cold_default_model(opts)) do
          {:ok, {:snapshot, _seq, json_bin}} ->
            model =
              case JSON.decode(json_bin) do
                {:ok, %{"docs" => %{"agent" => %{"model" => m}}}} -> m
                _ -> nil
              end

            {:ok, model}

          {:error, _} = err ->
            _ = table
            err
        end

      true ->
        call_session(entry, opts, &Server.get_conversation_model(&1, cid), preserve_archive: true)
    end
  end

  @doc "Scans cursor-paged raw transcript entries for a conversation."
  @spec scan_entries(String.t(), term(), map(), keyword()) ::
          {:ok, %{items: [map()], next_cursor: nil | String.t()}}
          | {:error, :not_found | {:bad_request, String.t()} | term()}
  def scan_entries(session_id, conversation_id, query_params \\ %{}, opts \\ [])
      when is_binary(session_id) and is_map(query_params) and is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- Validation.ensure_not_quarantined(entry),
         {:ok, cid} <- Validation.parse_cid(conversation_id),
         {:ok, query} <- Validation.parse_scan_query(query_params) do
      registry = Keyword.get(opts, :registry, @default_registry)

      cond do
        entry.status == "archived" ->
          H.Archive.scan(entry, cid, query, opts)

        Map.get(entry, :archived) == true and
            lookup_live_server(registry, session_id) == :not_running ->
          ColdSession.scan(entry, cid, query, opts, &wire_entry/1)

        true ->
          scan_live_entries(entry, cid, query, opts)
      end
    end
  end

  defp scan_live_entries(entry, cid, query, opts) do
    with {:ok, %{items: items, next_cursor: next_cursor}} <-
           call_session(entry, opts, &Server.scan_entries(&1, cid, query), preserve_archive: true) do
      {:ok,
       %{
         items: Enum.map(items, &wire_entry/1),
         next_cursor: if(next_cursor, do: to_string(next_cursor), else: nil)
       }}
    end
  end

  @doc """
  Subscribes `subscriber_pid` (must equal `self()`) to `H.PubSub` for `:catalog`
  events and returns an atomic `{:snapshot, seq, snapshot_json_bin}` directly
  from `H.Catalog` without waking any unloaded sessions.
  """
  @spec subscribe_sessions(pid(), keyword()) ::
          {:ok, {:snapshot, non_neg_integer(), binary()}} | {:error, term()}
  def subscribe_sessions(subscriber_pid, opts \\ [])
      when is_pid(subscriber_pid) and is_list(opts) do
    catalog = Keyword.get(opts, :catalog, @default_catalog)
    pubsub = Keyword.get(opts, :pubsub, @default_pubsub)

    already_registered? =
      subscriber_pid == self() and not is_nil(pubsub) and
        Process.whereis(pubsub) != nil and
        :catalog in Registry.keys(pubsub, self())

    if subscriber_pid == self() and not is_nil(pubsub) and
         Process.whereis(pubsub) != nil and not already_registered? do
      Registry.register(pubsub, :catalog, nil)
    end

    try do
      %{seq: seq, sessions: entries} = Catalog.snapshot(catalog)

      snapshot_json =
        %{
          "version" => 1,
          "seq" => seq,
          "sessions" => Enum.map(entries, &wire_session(&1, opts))
        }
        |> JSON.encode_to_iodata!()
        |> IO.iodata_to_binary()

      {:ok, {:snapshot, seq, snapshot_json}}
    catch
      :exit, _ ->
        if subscriber_pid == self() and not is_nil(pubsub) and
             Process.whereis(pubsub) != nil and not already_registered? do
          Registry.unregister(pubsub, :catalog)
        end

        {:error, :catalog_unavailable}
    end
  end

  @doc """
  Subscribes `subscriber_pid` (must equal `self()`) to `H.PubSub` for
  `{:conversation, session_id, cid}` and atomically returns either a `snapshot`
  JSON binary or missed `replay` frames from the 64-entry commit ring.
  """
  @spec subscribe_conversation(String.t(), term(), pid(), term(), keyword()) ::
          {:ok,
           {:snapshot, non_neg_integer(), binary()}
           | {:replay, [{non_neg_integer(), binary()}]}}
          | {:error, :not_found | {:bad_request, String.t()} | term()}
  def subscribe_conversation(
        session_id,
        conversation_id,
        subscriber_pid,
        last_event_id_or_nil,
        opts \\ []
      )
      when is_binary(session_id) and is_pid(subscriber_pid) and is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)
    pubsub = Keyword.get(opts, :pubsub, @default_pubsub)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- Validation.ensure_not_quarantined(entry),
         {:ok, cid} <- Validation.parse_cid(conversation_id),
         {:ok, last_event_id} <- Validation.parse_last_event_id(last_event_id_or_nil) do
      registry = Keyword.get(opts, :registry, @default_registry)

      cond do
        entry.status == "archived" ->
          H.Archive.snapshot(entry, cid, opts)

        Map.get(entry, :archived) == true and
            lookup_live_server(registry, session_id) == :not_running ->
          subscribe_cold_archived(entry, cid, subscriber_pid, pubsub, opts)

        true ->
          subscribe_live(entry, cid, subscriber_pid, last_event_id, pubsub, opts)
      end
    end
  end

  defp subscribe_cold_archived(entry, cid, subscriber_pid, pubsub, opts) do
    topic = {:conversation, entry.session_id, cid}

    already_registered? =
      subscriber_pid == self() and not is_nil(pubsub) and
        Process.whereis(pubsub) != nil and
        topic in Registry.keys(pubsub, self())

    if subscriber_pid == self() and not is_nil(pubsub) and
         Process.whereis(pubsub) != nil and not already_registered? do
      Registry.register(pubsub, topic, nil)
    end

    case ColdSession.snapshot(entry, cid, opts, cold_default_model(opts)) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        if subscriber_pid == self() and not is_nil(pubsub) and
             Process.whereis(pubsub) != nil and not already_registered? do
          Registry.unregister(pubsub, topic)
        end

        {:error, reason}
    end
  end

  defp subscribe_live(entry, cid, subscriber_pid, last_event_id, pubsub, opts) do
    topic = {:conversation, entry.session_id, cid}

    newly_registered? =
      subscriber_pid == self() and not is_nil(pubsub) and
        topic not in Registry.keys(pubsub, self())

    if newly_registered?, do: Registry.register(pubsub, topic, nil)

    case call_session(entry, opts, &Server.snapshot_or_replay(&1, cid, last_event_id),
           preserve_archive: true
         ) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        if newly_registered?, do: Registry.unregister(pubsub, topic)
        {:error, reason}
    end
  end

  @doc """
  Looks up the durable outcome/status of a submission by `request_id`.
  """
  @spec get_submission(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | {:bad_request, String.t()} | term()}
  def get_submission(session_id, request_id, opts \\ [])
      when is_binary(session_id) and is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         :ok <- validate_request_id(request_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- Validation.ensure_not_quarantined(entry) do
      call_session(entry, opts, &Server.get_submission_outcome(&1, request_id))
    end
  end

  @doc """
  Race-free submission settlement watcher.

  Registers `subscriber_pid` (when `subscriber_pid == self()`) on `H.PubSub` topic
  `{:submission, session_id, request_id}` *before* querying `H.Session.Server`.

    * Returns `{:ok, {:settled, outcome}}` immediately (and unregisters any new
      registration) if the submission is already terminal (`"done"`, `"unanswered"`,
      `"withdrawn"`).
    * Returns `{:ok, {:pending, outcome}}` while keeping the registration active so
      `subscriber_pid` deterministically receives `{:submission_settled, outcome}`
      after the durable commit succeeds.
  """
  @spec watch_submission(String.t(), String.t(), pid(), keyword()) ::
          {:ok, {:settled, map()} | {:pending, map()}}
          | {:error, :not_found | {:bad_request, String.t()} | term()}
  def watch_submission(session_id, request_id, subscriber_pid \\ self(), opts \\ [])
      when is_binary(session_id) and is_pid(subscriber_pid) and is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)
    pubsub = Keyword.get(opts, :pubsub, @default_pubsub)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         :ok <- validate_request_id(request_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- Validation.ensure_not_quarantined(entry) do
      topic = {:submission, session_id, request_id}

      can_register? =
        subscriber_pid == self() and not is_nil(pubsub) and Process.whereis(pubsub) != nil

      already_registered? = can_register? and topic in Registry.keys(pubsub, self())
      newly_registered? = can_register? and not already_registered?

      if newly_registered? do
        Registry.register(pubsub, topic, nil)
      end

      case call_session(entry, opts, &Server.get_submission_outcome(&1, request_id)) do
        {:ok, %{status: status} = outcome} when status in @terminal_submission_statuses ->
          if newly_registered?, do: Registry.unregister(pubsub, topic)
          {:ok, {:settled, outcome}}

        {:ok, pending_outcome} ->
          {:ok, {:pending, pending_outcome}}

        {:error, reason} ->
          if newly_registered?, do: Registry.unregister(pubsub, topic)
          {:error, reason}
      end
    end
  end

  @doc """
  Unregisters `self()` from `H.PubSub` topic `{:submission, session_id, request_id}`.
  """
  @spec unwatch_submission(String.t(), String.t(), keyword()) :: :ok
  def unwatch_submission(session_id, request_id, opts \\ [])
      when is_binary(session_id) and is_binary(request_id) and is_list(opts) do
    pubsub = Keyword.get(opts, :pubsub, @default_pubsub)

    if not is_nil(pubsub) and Process.whereis(pubsub) != nil do
      Registry.unregister(pubsub, {:submission, session_id, request_id})
    end

    :ok
  end

  @doc "Formats a submission outcome map into its JSON wire representation."
  @spec wire_submission_outcome(map()) :: map()
  def wire_submission_outcome(outcome) when is_map(outcome) do
    %{
      session_id: outcome.session_id,
      conversation_id: to_string(outcome.conversation_id),
      submission_id: to_string(outcome.submission_id),
      request_id: outcome.request_id,
      kind: outcome.kind,
      status: outcome.status,
      entry_id: if(outcome.entry_id, do: to_string(outcome.entry_id), else: nil),
      answer_entry_id:
        if(outcome.answer_entry_id, do: to_string(outcome.answer_entry_id), else: nil),
      answer_text: outcome.answer_text,
      reason: outcome.reason,
      seq: outcome.seq
    }
  end

  @doc "Validates and dispatches a command envelope to `H.Session.Server`."
  @spec execute_command(String.t(), map(), keyword()) ::
          {:ok, map()}
          | {:error, :not_found | {:bad_request, String.t()} | {:conflict, String.t()} | term()}
  def execute_command(session_id, raw_envelope, opts \\ [])

  def execute_command(session_id, raw_envelope, opts)
      when is_binary(session_id) and is_map(raw_envelope) and is_list(opts) do
    H.Daemon.Maintenance.admit(opts, fn -> dispatch_command(session_id, raw_envelope, opts) end)
  end

  def execute_command(_session_id, _raw_envelope, _opts) do
    {:error, {:bad_request, "command envelope must be a map"}}
  end

  @doc "Validates and delivers an external wake signal to `H.Session.Server`."
  @spec deliver_signal(String.t(), map(), keyword()) ::
          {:ok, map()}
          | {:error, :not_found | {:bad_request, String.t()} | {:conflict, String.t()} | term()}
  def deliver_signal(session_id, params, opts \\ [])

  def deliver_signal(session_id, params, opts)
      when is_binary(session_id) and is_map(params) and is_list(opts) do
    H.Daemon.Maintenance.admit(opts, fn -> do_deliver_signal(session_id, params, opts) end)
  end

  def deliver_signal(_session_id, _params, _opts) do
    {:error, {:bad_request, "expected a map"}}
  end

  defp do_deliver_signal(session_id, params, opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- Validation.ensure_not_quarantined(entry),
         :ok <-
           if(entry.status == "archived",
             do: {:error, {:conflict, "session is archived"}},
             else: :ok
           ),
         {:ok, validated} <- Validation.validate_signal_params(params) do
      call_session(entry, opts, &Server.deliver_signal(&1, validated))
    end
  end

  defp dispatch_command(session_id, raw_envelope, opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- Validation.ensure_not_quarantined(entry),
         :ok <-
           if(entry.status == "archived",
             do: {:error, {:conflict, "session is archived"}},
             else: :ok
           ),
         {:ok, envelope} <- Validation.validate_envelope(raw_envelope) do
      call_session(entry, opts, &Server.execute_command(&1, envelope))
    end
  end

  @doc """
  Boot recovery pass: starts supervised session runtimes for every unquarantined
  session that was `active: true` in `H.Catalog` when the previous VM stopped,
  reconciling unfinished work without waiting for a client reconnect.
  """
  @spec recover_active_sessions(keyword()) :: :ok
  def recover_active_sessions(opts \\ []) when is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    table
    |> Catalog.list_sessions()
    |> Enum.each(fn entry ->
      if entry.active and entry.status == "ok" do
        case ensure_session_started(entry, opts, nil) do
          {:ok, _pid, _marker} ->
            :ok

          {:error, reason} ->
            kind =
              if reason in [:harness_unavailable, :workspace_unavailable],
                do: reason,
                else: :session_start_failed

            Logger.warning("Session #{entry.session_id}: boot recovery unavailable (#{kind})")
        end
      end
    end)

    :ok
  end

  # Session supervision lookup / startup

  defp provider_config(opts) do
    config = Keyword.get(opts, :provider_config, %{})

    if Keyword.get(opts, :provider, H.Provider.ReqLLM) == H.Provider.ReqLLM do
      data_dir = Keyword.get(opts, :data_dir) || Application.get_env(:harness, :data_dir)

      opts
      |> Keyword.take([:accounts, :codex_account_policy, :compatible_providers])
      |> Map.new()
      |> then(&Map.merge(config, &1))
      |> Map.put(:data_dir, data_dir)
    else
      config
    end
  end

  # Retry only a coordinator's explicit idle retirement. A call that timed out
  # or lost its server to a crash may have committed (or already run an effect).
  defp call_session(entry, opts, fun, call_opts \\ [], retries \\ 2) do
    initial_agent = call_opts[:initial_agent]

    started =
      if call_opts[:preserve_archive] do
        ensure_session_started_preserving_archive(entry, opts, initial_agent)
      else
        ensure_session_started(entry, opts, initial_agent)
      end

    with {:ok, pid, marker} <- started do
      case call_live(pid, marker, fun) do
        :idle_unload when retries > 0 ->
          table = Keyword.get(opts, :catalog_table, @default_catalog_table)

          with :ok <- ensure_runtime_open(opts),
               {:ok, current} <- Catalog.get_session(entry.session_id, table),
               :ok <- Validation.ensure_not_quarantined(current),
               :ok <- ensure_archive_unchanged(retry_origin(entry, call_opts), current) do
            call_session(current, opts, fun, call_opts, retries - 1)
          end

        :idle_unload ->
          {:error, :session_start_failed}

        result ->
          result
      end
    end
  end

  defp retry_origin(entry, call_opts) do
    if call_opts[:preserve_archive], do: entry, else: %{entry | archived: false}
  end

  defp call_live(pid, marker, fun) do
    fun.(pid)
  catch
    :exit, {{:shutdown, :idle_unload}, {GenServer, :call, [^pid | _]}} ->
      :idle_unload

    :exit, {:noproc, {GenServer, :call, [^pid | _]}} = reason ->
      if Supervisor.idly_retired?(marker), do: :idle_unload, else: exit(reason)
  end

  defp ensure_runtime_open(opts) do
    if opts[:maintenance_table] &&
         not :ets.lookup_element(opts[:maintenance_table], :open, 2, false),
       do: {:error, :daemon_draining},
       else: :ok
  end

  defp ensure_archive_unchanged(%{archived: archived}, %{archived: archived}), do: :ok

  defp ensure_archive_unchanged(_before, _after),
    do: {:error, {:conflict, "session archive changed"}}

  defp ensure_session_started(entry, opts, initial_agent) do
    catalog = Keyword.get(opts, :catalog, @default_catalog)

    if Map.get(entry, :archived) == true and not is_nil(catalog) and
         GenServer.whereis(catalog) != nil do
      try do
        Catalog.set_archived(catalog, entry.session_id, false, needs_attention: true)
      catch
        :exit, _ -> :ok
      end
    end

    ensure_session_started_preserving_archive(%{entry | archived: false}, opts, initial_agent)
  end

  defp cold_default_model(opts) do
    provider_mod = Keyword.get(opts, :provider, H.Provider.ReqLLM)
    Recovery.resolve_default_model(opts[:default_model], provider_mod, provider_config(opts))
  end

  defp ensure_session_started_preserving_archive(entry, opts, initial_agent) do
    ensure_runtime(entry, opts, initial_agent, System.monotonic_time(:millisecond) + 5_000)
  end

  defp ensure_runtime(entry, opts, initial_agent, deadline) do
    sid = entry.session_id
    registry = Keyword.get(opts, :registry, @default_registry)

    case lookup_live_server(registry, sid) do
      {:ok, _pid, _marker} = live ->
        live

      :not_running ->
        # Wait for the old wrapper to finish its exit notification, or for a
        # coordinator that is starting under an already-registered wrapper.
        wrapper = GenServer.whereis({:via, Registry, {registry, {:session_supervisor, sid}}})

        if is_pid(wrapper) and Process.alive?(wrapper) do
          await_runtime(entry, opts, initial_agent, deadline)
        else
          start_runtime(entry, opts, initial_agent, deadline)
        end
    end
  end

  defp start_runtime(entry, opts, initial_agent, deadline) do
    runtime_sup = Keyword.get(opts, :runtime_sup, @default_runtime_sup)
    registry = Keyword.get(opts, :registry, @default_registry)

    with :ok <- ensure_runtime_open(opts),
         {:ok, sup_opts} <- build_session_sup_opts(entry, opts, initial_agent) do
      case DynamicSupervisor.start_child(runtime_sup, {Supervisor, sup_opts}) do
        {:ok, _sup_pid} ->
          case lookup_live_server(registry, entry.session_id) do
            {:ok, _pid, _marker} = live ->
              broadcast_loaded(opts, entry.session_id)
              live

            :not_running ->
              await_runtime(entry, opts, initial_agent, deadline)
          end

        {:error, {:already_started, _}} ->
          await_runtime(entry, opts, initial_agent, deadline)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp await_runtime(entry, opts, initial_agent, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(5)
      table = Keyword.get(opts, :catalog_table, @default_catalog_table)

      with {:ok, current} <- Catalog.get_session(entry.session_id, table),
           :ok <- Validation.ensure_not_quarantined(current),
           :ok <- ensure_archive_unchanged(entry, current) do
        ensure_runtime(current, opts, initial_agent, deadline)
      end
    else
      {:error, :session_start_failed}
    end
  end

  defp broadcast_loaded(opts, sid) do
    if catalog = Keyword.get(opts, :catalog, @default_catalog) do
      Catalog.broadcast_live_state(catalog, sid)
    end
  catch
    :exit, _ -> :ok
  end

  defp lookup_live_server(registry, session_id) do
    if is_atom(registry) and not is_nil(registry) and Process.whereis(registry) != nil do
      case Registry.lookup(registry, {:session, session_id}) do
        [{pid, marker}] when is_pid(pid) ->
          if Process.alive?(pid) and not Supervisor.idly_retired?(marker),
            do: {:ok, pid, marker},
            else: :not_running

        _ ->
          :not_running
      end
    else
      :not_running
    end
  end

  defp build_session_sup_opts(entry, opts, initial_agent) do
    registry = Keyword.get(opts, :registry, @default_registry)
    pubsub = Keyword.get(opts, :pubsub, @default_pubsub)
    catalog = Keyword.get(opts, :catalog, @default_catalog)
    catalog_table = Keyword.get(opts, :catalog_table, @default_catalog_table)
    runtime_sup = Keyword.get(opts, :runtime_sup, @default_runtime_sup)
    workspace_lease = Keyword.get(opts, :workspace_lease, @default_workspace_lease)
    storage_mod = Keyword.get(opts, :storage_mod, H.Storage.File)
    storage_opts = Keyword.get(opts, :storage_opts, [])
    data_dir = Keyword.get(opts, :data_dir) || Application.get_env(:harness, :data_dir)
    env_id = Map.get(entry, :env_id) || "host"
    harness_id = Map.get(entry, :harness_id) || "coding"
    session_depth = get_in(entry, [:parent, :depth]) || 0
    max_subagent_depth = Keyword.get(opts, :max_subagent_depth, @default_max_subagent_depth)

    workspace =
      case Keyword.fetch(opts, :execution_env) do
        {:ok, env} ->
          {:ok, %{env: env, cwd: entry.cwd}}

        :error ->
          resolve_existing_session_workspace(env_id, entry.cwd, opts)
      end

    with {:ok, %{env: execution_env, cwd: cwd}} when cwd == entry.cwd <- workspace,
         {:ok, harness} <- Harness.resolve(harness_id, opts) do
      harness_opts =
        opts
        |> Keyword.put(:session_depth, session_depth)
        |> Keyword.put(:max_subagent_depth, max_subagent_depth)

      tools = Keyword.get_lazy(opts, :tools, fn -> harness.tools(harness_opts) end)
      explicit_tools = Keyword.get(opts, :tools)

      sup_opts =
        [
          session_id: entry.session_id,
          env_id: env_id,
          harness_id: harness_id,
          cwd: entry.cwd,
          title: entry.title,
          parent: Map.get(entry, :parent),
          role: Map.get(entry, :role),
          registry: registry,
          pubsub: pubsub,
          catalog: catalog,
          catalog_table: catalog_table,
          runtime_sup: runtime_sup,
          workspace_lease: workspace_lease,
          storage_mod: storage_mod,
          storage_opts: storage_opts,
          data_dir: data_dir,
          execution_env: execution_env,
          tools: tools,
          max_subagent_depth: max_subagent_depth
        ]
        |> maybe_put_kw(:explicit_tools, explicit_tools)
        |> maybe_put_kw(:initial_agent, initial_agent)
        |> maybe_copy_kw(opts, :environments)
        |> maybe_copy_kw(opts, :harnesses)
        |> maybe_copy_kw(opts, :observers_server)
        |> maybe_copy_kw(opts, :max_subagent_depth_hard)
        |> maybe_copy_kw(opts, :maintenance_table)
        |> maybe_copy_kw(opts, :provider)
        |> Keyword.put(:provider_config, provider_config(opts))
        |> maybe_copy_kw(opts, :default_model)
        |> maybe_copy_kw(opts, :persist_within_ms)
        |> maybe_copy_kw(opts, :ephemeral_interval_ms)
        |> maybe_copy_kw(opts, :idle_session_timeout_ms)
        |> maybe_copy_kw(opts, :retry_limit)
        |> maybe_copy_kw(opts, :retry_backoff_ms)
        |> maybe_copy_kw(opts, :restart_limit)
        |> maybe_copy_kw(opts, :auto_compaction)
        |> maybe_copy_kw(opts, :compaction_keep_recent_chars)
        |> maybe_copy_kw(opts, :compaction_max_tokens)
        |> maybe_copy_kw(opts, :max_restarts)
        |> maybe_copy_kw(opts, :max_seconds)

      {:ok, sup_opts}
    else
      {:error, :unknown_harness} -> {:error, :harness_unavailable}
      _ -> {:error, :workspace_unavailable}
    end
  end

  defp validate_request_id(req_id) when is_binary(req_id) do
    if byte_size(String.trim(req_id)) > 0 do
      :ok
    else
      {:error, {:bad_request, "request_id must be a non-empty string"}}
    end
  end

  defp validate_request_id(_),
    do: {:error, {:bad_request, "request_id must be a non-empty string"}}

  defp lookup_active_session_entry(session_id, opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    with {:ok, _sid} <- Validation.validate_sid_or_not_found(session_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- Validation.ensure_not_quarantined(entry) do
      {:ok, entry}
    end
  end

  defp resolve_harness(harness_id, opts) do
    case Harness.resolve(harness_id, opts) do
      {:ok, mod} -> {:ok, mod}
      {:error, :unknown_harness} -> {:error, {:bad_request, "unknown harness: #{harness_id}"}}
    end
  end

  defp resolve_session_workspace(env_id, raw_cwd, opts) do
    case EnvRegistry.resolve_workspace(env_id, raw_cwd, opts) do
      {:ok, ws} ->
        {:ok, ws}

      {:error, :unknown_environment} ->
        {:error, {:bad_request, "unknown environment: #{env_id}"}}

      {:error, :enoent} ->
        {:error, {:bad_request, "working directory does not exist: #{raw_cwd}"}}

      {:error, :enotdir} ->
        {:error, {:bad_request, "working directory is not a directory: #{raw_cwd}"}}

      {:error, reason} ->
        {:error, {:bad_request, "invalid workspace: #{inspect(reason)}"}}
    end
  end

  defp resolve_existing_session_workspace(env_id, cwd, opts) do
    case EnvRegistry.resolve_workspace(env_id, cwd, opts) do
      {:ok, ws} ->
        {:ok, ws}

      {:error, reason} when reason in [:enoent, :enotdir] ->
        with {:ok, base_env, desc} <- EnvRegistry.fetch_env(env_id, opts),
             {:ok, fallback_env} <- build_missing_cwd_env(base_env, desc, cwd) do
          {:ok, %{env: fallback_env, cwd: cwd}}
        else
          _ -> {:error, :workspace_unavailable}
        end

      {:error, _} ->
        {:error, :workspace_unavailable}
    end
  end

  defp build_missing_cwd_env({mod, state} = base_env, desc, cwd) do
    cond do
      desc.kind == "host" ->
        {:ok, H.ExecutionEnv.Host.new(cwd, env_id: desc.id)}

      is_map(state) and Map.has_key?(state, :cwd) ->
        case ExecutionEnv.resolve_path(base_env, cwd) do
          {:ok, resolved} -> {:ok, {mod, %{state | cwd: resolved}}}
          _ -> {:error, :workspace_unavailable}
        end

      true ->
        {:ok, base_env}
    end
  rescue
    _ -> {:error, :workspace_unavailable}
  catch
    :exit, _ -> {:error, :workspace_unavailable}
  end

  defp parse_archived_filter(nil), do: {:ok, :all}
  defp parse_archived_filter(""), do: {:ok, :all}

  defp parse_archived_filter(val) do
    case Validation.parse_optional_strict_bool(val, false, "archived") do
      {:ok, bool} -> {:ok, bool}
      {:error, _} = err -> err
    end
  end

  defp filter_archived(entries, :all), do: entries

  defp filter_archived(entries, archived?) when is_boolean(archived?) do
    Enum.filter(entries, &(Map.get(&1, :archived, false) == archived?))
  end

  defp parse_stop_reason(nil), do: {:ok, "stopped"}
  defp parse_stop_reason(""), do: {:ok, "stopped"}

  defp parse_stop_reason(val) when is_binary(val) do
    if String.contains?(val, <<0>>) do
      {:error, {:bad_request, "invalid reason"}}
    else
      {:ok, val}
    end
  end

  defp parse_stop_reason(_), do: {:error, {:bad_request, "reason must be a string"}}

  # Wire formatting & misc helpers

  defp wire_session(entry, opts), do: Catalog.wire_session(entry, opts)

  defp wire_conversation(conv) do
    parent =
      case conv.parent do
        nil ->
          nil

        %{conversation_id: pid, at: at} ->
          %{conversation_id: to_string(pid), at: to_string(at)}
      end

    owner =
      case Map.get(conv, :owner, :ownerless) do
        :ownerless -> "ownerless"
        {:conversation, cid} -> "conversation:#{cid}"
        {:task, tid} -> "task:#{tid}"
        other when is_binary(other) -> other
      end

    %{
      id: to_string(conv.id),
      parent: parent,
      owner: owner
    }
  end

  defp wire_entry(entry) do
    %{
      id: to_string(entry.id),
      conversation_id: to_string(entry.conversation_id),
      seq: entry.seq,
      kind: entry.kind,
      data: entry.data,
      created_at: Map.get(entry, :created_at)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, val), do: Keyword.put(opts, key, val)

  defp maybe_copy_kw(dst, src, key) do
    case Keyword.fetch(src, key) do
      {:ok, val} -> Keyword.put(dst, key, val)
      :error -> dst
    end
  end

  defp mint_session_id(cwd, table) do
    base =
      cwd
      |> Path.basename()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "session"
        slug -> String.slice(slug, 0, 32)
      end

    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    candidate = "#{base}-#{suffix}"

    case Catalog.get_session(candidate, table) do
      {:error, :not_found} -> candidate
      {:ok, _} -> mint_session_id(cwd, table)
    end
  end
end
