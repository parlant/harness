defmodule H.Daemon do
  @moduledoc """
  Transport-agnostic daemon API for `H` sessions, conversations, transcripts,
  SSE subscriptions, and idempotent commands.

  Every function accepts `opts \\ []` so isolated `--no-start` tests and the
  full `H.HTTP` daemon share the exact same contract.
  """

  require Logger

  alias H.{
    Catalog,
    Daemon.Validation,
    Daemon.Workspace,
    EnvRegistry,
    ExecutionEnv,
    Harness,
    Session.Server,
    Session.Supervisor
  }

  @default_registry H.Registry
  @default_pubsub H.PubSub
  @default_runtime_sup H.Session.RuntimeSupervisor
  @default_catalog H.Catalog
  @default_catalog_table :h_catalog
  @default_workspace_lease H.WorkspaceLease

  @doc "Returns the running instance's validated daemon options, or `nil` when not booted."
  @spec instance_options() :: keyword() | nil
  def instance_options do
    GenServer.call(H.Daemon.Boot, :options, :infinity)
  catch
    :exit, {:noproc, _} ->
      if Process.whereis(H.Daemon.Instance), do: exit(:daemon_not_ready), else: nil
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
    Workspace.browse(query_params, opts, &wire_session/1)
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
    |> Enum.map(&wire_session/1)
  end

  @doc "Lists sessions filtered by `env_id`, `cwd`, and optional `subtree`."
  @spec list_sessions(map(), keyword()) :: {:ok, [map()]} | {:error, {:bad_request, String.t()}}
  def list_sessions(query_params, opts) when is_map(query_params) and is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)
    raw_env_id = Validation.param_get(query_params, "env_id", :env_id)
    raw_cwd = Validation.param_get(query_params, "cwd", :cwd)

    subtree? =
      Validation.parse_bool_param(Validation.param_get(query_params, "subtree", :subtree), false)

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
          |> Catalog.list_sessions_for_cwd(canonical_cwd, table: table, subtree: subtree?)
          |> Enum.map(&wire_session/1)

        {:ok, sessions}

      is_binary(raw_env_id) and raw_env_id != "" ->
        sessions =
          table
          |> Catalog.list_sessions()
          |> Enum.filter(&((&1.env_id || "host") == raw_env_id))
          |> Enum.map(&wire_session/1)

        {:ok, sessions}

      true ->
        {:ok, list_sessions(opts)}
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
         :ok <- match_workspace(env_id, entry.cwd, params, opts) do
      session_result(entry, opts, nil)
    else
      {:error, :unknown_harness} -> {:error, :harness_unavailable}
      {:error, _} = error -> error
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
        {:ok, %{cwd: ^cwd}} -> :ok
        {:error, :unknown_environment} -> {:error, :workspace_unavailable}
        {:error, :workspace_unavailable} -> {:error, :workspace_unavailable}
        _ -> {:error, {:conflict, "session already exists with different workspace"}}
      end
    else
      {:error, {:conflict, "session already exists with different workspace"}}
    end
  end

  defp create_new_session(params, agent_opts, opts) do
    with {:ok, harness} <- resolve_harness(Map.get(params, :harness_id, "coding"), opts),
         {:ok, ws} <-
           resolve_session_workspace(Map.get(params, :env_id, "host"), params.cwd, opts),
         {:ok, bootstrapped} <- bootstrap_agent(harness, ws.env, agent_opts, opts) do
      catalog = Keyword.get(opts, :catalog, @default_catalog)
      table = Keyword.get(opts, :catalog_table, @default_catalog_table)

      attrs =
        %{
          session_id: Map.get(params, :session_id) || mint_session_id(ws.cwd, table),
          env_id: ws.env_id,
          harness_id: harness.id(),
          cwd: ws.cwd
        }
        |> maybe_put(:title, Map.get(params, :title))

      case Catalog.insert_session(catalog, attrs) do
        {:ok, entry} -> session_result(entry, opts, bootstrapped)
        {:existing, entry} -> attach_session(entry, params, opts)
        {:error, _} = error -> error
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
    with {:ok, server} <- ensure_session_started(entry, opts, initial_agent),
         {:ok, seq} <- Server.get_seq(server) do
      table = Keyword.get(opts, :catalog_table, @default_catalog_table)

      latest_entry =
        case Catalog.get_session(entry.session_id, table) do
          {:ok, latest} -> latest
          _ -> entry
        end

      {:ok, %{session: wire_session(latest_entry), seq: seq}}
    end
  end

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
      case entry.status do
        "archived" -> H.Archive.detail(entry, opts)
        _ -> live_session_detail(entry, opts, table)
      end
    end
  end

  defp live_session_detail(entry, opts, table) do
    with {:ok, server} <- ensure_session_started(entry, opts, nil),
         {:ok, detail} <- Server.get_detail(server) do
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

      {:ok,
       %{
         session: wire_session(session_entry),
         conversations: Enum.map(detail.conversations, &wire_conversation/1),
         tasks: Enum.map(detail.tasks, &H.Task.to_wire/1)
       }}
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
      case entry.status do
        "archived" -> H.Archive.scan(entry, cid, query, opts)
        _ -> scan_live_entries(entry, cid, query, opts)
      end
    end
  end

  defp scan_live_entries(entry, cid, query, opts) do
    with {:ok, server} <- ensure_session_started(entry, opts, nil),
         {:ok, %{items: items, next_cursor: next_cursor}} <-
           Server.scan_entries(server, cid, query) do
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
          "sessions" => Enum.map(entries, &wire_session/1)
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
      case entry.status do
        "archived" -> H.Archive.snapshot(entry, cid, opts)
        _ -> subscribe_live(entry, cid, subscriber_pid, last_event_id, pubsub, opts)
      end
    end
  end

  defp subscribe_live(entry, cid, subscriber_pid, last_event_id, pubsub, opts) do
    with {:ok, server} <- ensure_session_started(entry, opts, nil) do
      topic = {:conversation, entry.session_id, cid}

      already_registered? =
        subscriber_pid == self() and not is_nil(pubsub) and
          topic in Registry.keys(pubsub, self())

      if subscriber_pid == self() and not is_nil(pubsub) and not already_registered? do
        Registry.register(pubsub, topic, nil)
      end

      case Server.snapshot_or_replay(server, cid, last_event_id) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          if subscriber_pid == self() and not is_nil(pubsub) and not already_registered? do
            Registry.unregister(pubsub, topic)
          end

          {:error, reason}
      end
    end
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
         {:ok, envelope} <- Validation.validate_envelope(raw_envelope),
         {:ok, server} <- ensure_session_started(entry, opts, nil) do
      Server.execute_command(server, envelope)
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
          {:ok, _pid} ->
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
      |> Keyword.take([:accounts, :codex_account_policy])
      |> Map.new()
      |> then(&Map.merge(config, &1))
      |> Map.put(:data_dir, data_dir)
    else
      config
    end
  end

  defp ensure_session_started(entry, opts, initial_agent) do
    session_id = entry.session_id
    registry = Keyword.get(opts, :registry, @default_registry)
    runtime_sup = Keyword.get(opts, :runtime_sup, @default_runtime_sup)

    case Registry.lookup(registry, {:session, session_id}) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          Process.sleep(10)
          ensure_session_started(entry, opts, initial_agent)
        end

      [] ->
        with {:ok, sup_opts} <- build_session_sup_opts(entry, opts, initial_agent) do
          start_session(runtime_sup, registry, session_id, sup_opts)
        end
    end
  end

  defp start_session(runtime_sup, registry, session_id, sup_opts) do
    case DynamicSupervisor.start_child(runtime_sup, {Supervisor, sup_opts}) do
      {:ok, _sup_pid} ->
        lookup_started_server(registry, session_id)

      {:error, {:already_started, _}} ->
        lookup_started_server(registry, session_id)

      {:error, {:shutdown, {:failed_to_start_child, H.Session.Server, {:already_started, pid}}}} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup_started_server(registry, session_id) do
    case Registry.lookup(registry, {:session, session_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :session_start_failed}
    end
  end

  defp build_session_sup_opts(entry, opts, initial_agent) do
    registry = Keyword.get(opts, :registry, @default_registry)
    pubsub = Keyword.get(opts, :pubsub, @default_pubsub)
    catalog = Keyword.get(opts, :catalog, @default_catalog)
    workspace_lease = Keyword.get(opts, :workspace_lease, @default_workspace_lease)
    storage_mod = Keyword.get(opts, :storage_mod, H.Storage.File)
    storage_opts = Keyword.get(opts, :storage_opts, [])
    data_dir = Keyword.get(opts, :data_dir) || Application.get_env(:harness, :data_dir)
    env_id = Map.get(entry, :env_id) || "host"
    harness_id = Map.get(entry, :harness_id) || "coding"

    workspace =
      case Keyword.fetch(opts, :execution_env) do
        {:ok, env} -> {:ok, %{env: env, cwd: entry.cwd}}
        :error -> EnvRegistry.resolve_workspace(env_id, entry.cwd, opts)
      end

    with {:ok, %{env: execution_env, cwd: cwd}} when cwd == entry.cwd <- workspace,
         {:ok, harness} <- Harness.resolve(harness_id, opts) do
      tools = Keyword.get_lazy(opts, :tools, fn -> harness.tools(opts) end)

      sup_opts =
        [
          session_id: entry.session_id,
          env_id: env_id,
          cwd: entry.cwd,
          title: entry.title,
          registry: registry,
          pubsub: pubsub,
          catalog: catalog,
          workspace_lease: workspace_lease,
          storage_mod: storage_mod,
          storage_opts: storage_opts,
          data_dir: data_dir,
          execution_env: execution_env,
          tools: tools
        ]
        |> maybe_put_kw(:initial_agent, initial_agent)
        |> maybe_copy_kw(opts, :maintenance_table)
        |> maybe_copy_kw(opts, :provider)
        |> Keyword.put(:provider_config, provider_config(opts))
        |> maybe_copy_kw(opts, :default_model)
        |> maybe_copy_kw(opts, :persist_within_ms)
        |> maybe_copy_kw(opts, :ephemeral_interval_ms)
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

  # Wire formatting & misc helpers

  defp wire_session(entry), do: Catalog.wire_session(entry)

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
