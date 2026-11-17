defmodule H.Daemon do
  @moduledoc """
  Transport-agnostic daemon API for `H` sessions, conversations, transcripts,
  SSE subscriptions, and idempotent commands.

  Every function accepts `opts \\ []` so isolated `--no-start` tests and the
  full `H.HTTP` daemon share the exact same contract.
  """

  alias H.{Catalog, Schema, Session.Server, Session.Supervisor}

  @default_registry H.Registry
  @default_pubsub H.PubSub
  @default_runtime_sup H.Session.RuntimeSupervisor
  @default_catalog H.Catalog
  @default_catalog_table :h_catalog
  @default_workspace_lease H.WorkspaceLease

  @doc "Lists models from the configured `H.Provider`."
  @spec list_models(keyword()) :: [map()]
  def list_models(opts \\ []) when is_list(opts) do
    provider_mod = Keyword.get(opts, :provider, H.Provider.ReqLLM)
    provider_config = Keyword.get(opts, :provider_config, %{})
    provider_mod.list_models(provider_config)
  end

  @doc "Lists sessions directly from `H.Catalog` ETS without waking unloaded sessions."
  @spec list_sessions(keyword()) :: [map()]
  def list_sessions(opts \\ []) when is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    table
    |> Catalog.list_sessions()
    |> Enum.map(&wire_session/1)
  end

  @doc """
  Idempotently creates (or attaches to) a session, persists it in `H.Catalog`,
  and starts its supervised `H.Session.Server`.
  """
  @spec create_session(map(), keyword()) ::
          {:ok, %{session: map(), seq: non_neg_integer()}}
          | {:error, {:bad_request, String.t()} | {:conflict, String.t()} | term()}
  def create_session(params, opts \\ [])

  def create_session(params, opts) when is_map(params) and is_list(opts) do
    with {:ok, validated} <-
           Schema.validate_map(params, [
             {:session_id, :session_id, required: true},
             {:cwd, :abs_path, required: true},
             {:title, :string, required: false, nullable: true},
             {:agent, :map, required: false},
             {:request_id, :non_empty_string, required: false}
           ]),
         {:ok, agent_opts} <- validate_optional_agent(Map.get(validated, :agent)) do
      expanded_cwd = Path.expand(validated.cwd)
      catalog = Keyword.get(opts, :catalog, @default_catalog)
      table = Keyword.get(opts, :catalog_table, @default_catalog_table)

      case Catalog.get_session(validated.session_id, table) do
        {:ok, existing} ->
          cond do
            existing.status == "quarantined" ->
              {:error, {:quarantined, existing.quarantine_reason || "quarantined"}}

            Path.expand(existing.cwd) != expanded_cwd ->
              {:error, {:conflict, "session already exists with different cwd"}}

            true ->
              with {:ok, server} <- ensure_session_started(existing, opts, nil),
                   {:ok, seq} <- Server.get_seq(server) do
                {:ok, %{session: wire_session(existing), seq: seq}}
              end
          end

        {:error, :not_found} ->
          attrs =
            %{session_id: validated.session_id, cwd: expanded_cwd}
            |> maybe_put(:title, Map.get(validated, :title))

          with {:ok, entry} <- Catalog.put_session(catalog, attrs),
               {:ok, server} <- ensure_session_started(entry, opts, agent_opts),
               {:ok, seq} <- Server.get_seq(server) do
            latest_entry =
              case Catalog.get_session(validated.session_id, table) do
                {:ok, e} -> e
                _ -> entry
              end

            {:ok, %{session: wire_session(latest_entry), seq: seq}}
          end
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, {:bad_request, reason}}
      {:error, _} = err -> err
    end
  end

  def create_session(_params, _opts), do: {:error, {:bad_request, "expected a map"}}

  @doc "Returns session detail, conversation ancestry forest, and live tasks."
  @spec get_session_detail(String.t(), keyword()) ::
          {:ok, %{session: map(), conversations: [map()], tasks: [map()]}}
          | {:error, :not_found | {:quarantined, String.t()} | term()}
  def get_session_detail(session_id, opts \\ [])
      when is_binary(session_id) and is_list(opts) do
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    with {:ok, _sid} <- validate_sid_or_not_found(session_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- ensure_not_quarantined(entry),
         {:ok, server} <- ensure_session_started(entry, opts, nil),
         {:ok, detail} <- Server.get_detail(server) do
      {:ok,
       %{
         session: wire_session(entry),
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

    with {:ok, _sid} <- validate_sid_or_not_found(session_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- ensure_not_quarantined(entry),
         {:ok, cid} <- parse_cid(conversation_id),
         {:ok, query} <- parse_scan_query(query_params),
         {:ok, server} <- ensure_session_started(entry, opts, nil),
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

    with {:ok, _sid} <- validate_sid_or_not_found(session_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- ensure_not_quarantined(entry),
         {:ok, cid} <- parse_cid(conversation_id),
         {:ok, last_event_id} <- parse_last_event_id(last_event_id_or_nil),
         {:ok, server} <- ensure_session_started(entry, opts, nil) do
      topic = {:conversation, session_id, cid}

      if subscriber_pid == self() and not is_nil(pubsub) do
        Registry.register(pubsub, topic, nil)
      end

      case Server.snapshot_or_replay(server, cid, last_event_id) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          if subscriber_pid == self() and not is_nil(pubsub) do
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
    table = Keyword.get(opts, :catalog_table, @default_catalog_table)

    with {:ok, _sid} <- validate_sid_or_not_found(session_id),
         {:ok, entry} <- Catalog.get_session(session_id, table),
         :ok <- ensure_not_quarantined(entry),
         {:ok, envelope} <- validate_envelope(raw_envelope),
         {:ok, server} <- ensure_session_started(entry, opts, nil) do
      Server.execute_command(server, envelope)
    end
  end

  def execute_command(_session_id, _raw_envelope, _opts) do
    {:error, {:bad_request, "command envelope must be a map"}}
  end

  # Session supervision lookup / startup

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
        sup_opts = build_session_sup_opts(entry, opts, initial_agent)

        case DynamicSupervisor.start_child(runtime_sup, {Supervisor, sup_opts}) do
          {:ok, _sup_pid} ->
            lookup_started_server(registry, session_id)

          {:error, {:already_started, _}} ->
            lookup_started_server(registry, session_id)

          {:error,
           {:shutdown, {:failed_to_start_child, H.Session.Server, {:already_started, pid}}}} ->
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end
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

    [
      session_id: entry.session_id,
      cwd: entry.cwd,
      registry: registry,
      pubsub: pubsub,
      catalog: catalog,
      workspace_lease: workspace_lease,
      storage_mod: storage_mod,
      storage_opts: storage_opts,
      data_dir: data_dir
    ]
    |> maybe_put_kw(:initial_agent, initial_agent)
    |> maybe_copy_kw(opts, :provider)
    |> maybe_copy_kw(opts, :provider_config)
    |> maybe_copy_kw(opts, :execution_env)
    |> maybe_copy_kw(opts, :tools)
    |> maybe_copy_kw(opts, :default_model)
    |> maybe_copy_kw(opts, :persist_within_ms)
    |> maybe_copy_kw(opts, :ephemeral_interval_ms)
    |> maybe_copy_kw(opts, :retry_limit)
    |> maybe_copy_kw(opts, :retry_backoff_ms)
    |> maybe_copy_kw(opts, :restart_limit)
    |> maybe_copy_kw(opts, :max_restarts)
    |> maybe_copy_kw(opts, :max_seconds)
  end

  # Boundary Validation

  defp validate_sid_or_not_found(session_id) do
    case Schema.validate_session_id(session_id) do
      {:ok, sid} -> {:ok, sid}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp ensure_not_quarantined(%{status: "quarantined"} = entry) do
    {:error, {:quarantined, entry.quarantine_reason || "quarantined"}}
  end

  defp ensure_not_quarantined(_entry), do: :ok

  defp parse_cid(cid) do
    case Schema.parse_pos_int(cid) do
      {:ok, id} -> {:ok, id}
      {:error, reason} -> {:error, {:bad_request, "conversation_id: #{reason}"}}
    end
  end

  defp parse_last_event_id(nil), do: {:ok, nil}
  defp parse_last_event_id(""), do: {:ok, nil}

  defp parse_last_event_id(val) when is_integer(val) and val >= 0, do: {:ok, val}

  defp parse_last_event_id(val) when is_binary(val) do
    if Regex.match?(~r/^\d+$/, val) do
      {:ok, String.to_integer(val)}
    else
      {:error, {:bad_request, "last_event_id must be a non-negative integer"}}
    end
  end

  defp parse_last_event_id(_),
    do: {:error, {:bad_request, "last_event_id must be a non-negative integer"}}

  defp parse_scan_query(params) do
    with {:ok, order} <- parse_order(param_get(params, "order", :order)),
         {:ok, cursor} <- parse_optional_pos_int(param_get(params, "cursor", :cursor), "cursor"),
         {:ok, limit} <- parse_limit(param_get(params, "limit", :limit)) do
      query =
        %{order: order, limit: limit}
        |> maybe_put(:cursor, cursor)

      {:ok, query}
    end
  end

  defp parse_order(nil), do: {:ok, :desc}
  defp parse_order("desc"), do: {:ok, :desc}
  defp parse_order(:desc), do: {:ok, :desc}
  defp parse_order("asc"), do: {:ok, :asc}
  defp parse_order(:asc), do: {:ok, :asc}
  defp parse_order(_), do: {:error, {:bad_request, "order must be \"asc\" or \"desc\""}}

  defp parse_optional_pos_int(nil, _field), do: {:ok, nil}
  defp parse_optional_pos_int("", _field), do: {:ok, nil}

  defp parse_optional_pos_int(val, field) do
    case Schema.parse_pos_int(val) do
      {:ok, n} -> {:ok, n}
      {:error, reason} -> {:error, {:bad_request, "#{field}: #{reason}"}}
    end
  end

  defp parse_limit(nil), do: {:ok, 50}
  defp parse_limit(""), do: {:ok, 50}

  defp parse_limit(val) do
    case Schema.parse_pos_int(val) do
      {:ok, n} when n >= 1 and n <= 200 -> {:ok, n}
      {:ok, _} -> {:error, {:bad_request, "limit must be between 1 and 200"}}
      {:error, reason} -> {:error, {:bad_request, "limit: #{reason}"}}
    end
  end

  defp validate_optional_agent(nil), do: {:ok, nil}

  defp validate_optional_agent(agent) when is_map(agent) do
    Schema.validate_map(agent, [
      {:model, :string, required: false, nullable: true},
      {:thinking, :string, required: false, nullable: true},
      {:system_prompt, :string, required: false, nullable: true},
      {:instructions, :string, required: false, nullable: true},
      {:tools, {:list, :string}, required: false},
      {:max_turns, {:int, min: 1, max: 1000}, required: false}
    ])
  end

  defp validate_envelope(raw) do
    with {:ok, env} <-
           Schema.validate_map(raw, [
             {:version, {:literal, 1}, required: true},
             {:request_id, :non_empty_string, required: true},
             {:command, {:enum, ["submit", "fork", "fork_and_submit", "configure", "abort"]},
              required: true},
             {:conversation_id, :pos_int, required: true},
             {:args, :map, default: %{}}
           ]),
         {:ok, validated_args} <- validate_command_args(env.command, env.args) do
      {:ok, %{env | args: validated_args}}
    else
      {:error, reason} when is_binary(reason) -> {:error, {:bad_request, reason}}
    end
  end

  defp validate_command_args("submit", raw_args) do
    with {:ok, base} <-
           Schema.validate_map(raw_args, [
             {:type, {:enum, ["input", "continue", "write"]}, required: true}
           ]) do
      case base.type do
        "input" ->
          with {:ok, args} <-
                 Schema.validate_map(raw_args, [
                   {:type, {:literal, "input"}, required: true},
                   {:content, :any, required: true},
                   {:when_busy, {:enum, ["follow_up", "steer", "reject"]}, default: "follow_up"},
                   {:when_idle, {:enum, ["start", "reject"]}, default: "start"}
                 ]),
               :ok <- validate_content(args.content) do
            {:ok, args}
          end

        "continue" ->
          {:ok, %{type: "continue"}}

        "write" ->
          Schema.validate_map(raw_args, [
            {:type, {:literal, "write"}, required: true},
            {:kind, :non_empty_string, default: "user"},
            {:content, :any, required: false},
            {:data, :map, required: false}
          ])
      end
    end
  end

  defp validate_command_args("fork", raw_args) do
    Schema.validate_map(raw_args, [
      {:at_entry_id, :pos_int, required: true}
    ])
  end

  defp validate_command_args("fork_and_submit", raw_args) do
    with {:ok, args} <-
           Schema.validate_map(raw_args, [
             {:at_entry_id, :pos_int, required: true},
             {:content, :any, required: true},
             {:when_busy, {:enum, ["follow_up", "steer", "reject"]}, default: "follow_up"},
             {:when_idle, {:enum, ["start", "reject"]}, default: "start"}
           ]),
         :ok <- validate_content(args.content) do
      {:ok, args}
    end
  end

  defp validate_command_args("configure", raw_args) do
    Schema.validate_map(raw_args, [
      {:model, :string, required: false, nullable: true},
      {:thinking, :string, required: false, nullable: true},
      {:system_prompt, :string, required: false, nullable: true},
      {:instructions, :string, required: false, nullable: true},
      {:tools, {:list, :string}, required: false},
      {:max_turns, {:int, min: 1, max: 1000}, required: false},
      {:expected_seq, {:int, min: 0}, required: false, nullable: true}
    ])
  end

  defp validate_command_args("abort", raw_args) do
    Schema.validate_map(raw_args, [
      {:task_id, :pos_int, required: false, nullable: true},
      {:reason, :string, required: false, nullable: true}
    ])
  end

  defp validate_content(text) when is_binary(text) and byte_size(text) > 0, do: :ok

  defp validate_content(blocks) when is_list(blocks) and blocks != [] do
    if Enum.all?(blocks, &(is_map(&1) or is_binary(&1))) do
      :ok
    else
      {:error, "content items must be maps or strings"}
    end
  end

  defp validate_content(_), do: {:error, "content must be a non-empty string or block list"}

  # Wire formatting

  defp wire_session(entry) do
    %{
      session_id: entry.session_id,
      title: entry.title,
      cwd: entry.cwd,
      root_conversation_id: to_string(entry.root_conversation_id || 1),
      created_at: entry.created_at,
      updated_at: entry.updated_at,
      active: entry.active == true,
      next_wake_at: entry.next_wake_at,
      status: entry.status || "ok"
    }
  end

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

  defp param_get(map, str_key, atom_key) do
    case Map.fetch(map, str_key) do
      {:ok, val} -> val
      :error -> Map.get(map, atom_key)
    end
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
end
