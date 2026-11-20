defmodule H.Catalog do
  @moduledoc """
  Server-owned session metadata index (`<data_dir>/catalog/sessions.json`)
  backed by a `:protected` ETS table for lock-free concurrent reads.

  `H.Catalog` never opens `<data_dir>/sessions/<session_id>/` directly and
  never wakes unloaded sessions on read.
  """

  use GenServer

  alias H.Schema

  @default_table :h_catalog
  @default_registry H.Registry

  @worker_fields [
    :title,
    :active,
    :attention,
    :activity_kind,
    :activity_label,
    :queued_count,
    :next_wake_at,
    :updated_at,
    :applied_edit_rev
  ]

  @runtime_change_fields [
    :title,
    :active,
    :attention,
    :activity_kind,
    :activity_label,
    :queued_count,
    :needs_attention,
    :archived,
    :next_wake_at,
    :applied_edit_rev
  ]

  @valid_attentions ["idle", "running", "sleeping", "retrying", "error", "quarantined"]
  @valid_activity_kinds ["generation", "tool", "user_shell", "compaction", "retry"]
  @max_activity_label_length 120
  @max_role_length 64

  @doc """
  Starts the catalog process.

  Options:
    * `:data_dir` (required) - root storage directory
    * `:name` - GenServer registration name (default `H.Catalog`, pass `nil` for unnamed)
    * `:table` - ETS table name (default `:h_catalog`)
    * `:pubsub` - `Registry` name for `:catalog` topic broadcasts (default `H.PubSub`, pass `nil` to disable)
    * `:registry` - `Registry` name for live session lookup (default `H.Registry`, pass `nil` to disable)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    _data_dir = Keyword.fetch!(opts, :data_dir)
    gen_opts = if name = Keyword.get(opts, :name, __MODULE__), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Returns `true` when the catalog entry represents a root session (`parent == nil`).
  """
  @spec root_session?(map()) :: boolean()
  def root_session?(entry) when is_map(entry), do: is_nil(Map.get(entry, :parent))

  @doc """
  Formats a catalog entry into the wire-level `SessionSummary` map shared by
  `H.Daemon` and catalog SSE broadcasts.
  """
  @spec wire_session(map(), keyword()) :: map()
  def wire_session(entry, opts \\ []) when is_map(entry) and is_list(opts) do
    status = Map.get(entry, :status) || "ok"
    env_id = Map.get(entry, :env_id) || "host"
    archived = status == "archived" or Map.get(entry, :archived) == true
    registry = Keyword.get(opts, :registry, @default_registry)

    attention =
      cond do
        status == "quarantined" -> "quarantined"
        archived -> "archived"
        true -> normalize_attention(Map.get(entry, :attention), status)
      end

    needs_attention =
      if archived do
        false
      else
        case Map.fetch(entry, :needs_attention) do
          {:ok, val} when is_boolean(val) -> val
          _ -> attention not in ["running", "sleeping", "retrying"]
        end
      end

    %{
      session_id: entry.session_id,
      title: Map.get(entry, :title),
      tags: Map.get(entry, :tags, []),
      env_id: env_id,
      harness_id: Map.get(entry, :harness_id) || "coding",
      cwd: entry.cwd,
      root_conversation_id: to_string(Map.get(entry, :root_conversation_id) || 1),
      parent: wire_parent(Map.get(entry, :parent)),
      role: Map.get(entry, :role),
      created_at: entry.created_at,
      updated_at: entry.updated_at,
      active: Map.get(entry, :active) == true,
      attention: attention,
      activity_kind: normalize_activity_kind(Map.get(entry, :activity_kind)),
      activity_label: sanitize_activity_label(Map.get(entry, :activity_label)),
      queued_count: normalize_queued_count(Map.get(entry, :queued_count)),
      needs_attention: needs_attention,
      archived: archived,
      loaded: session_loaded?(registry, entry.session_id),
      cwd_exists: cwd_exists?(env_id, entry.cwd),
      next_wake_at: Map.get(entry, :next_wake_at),
      status: status
    }
  end

  @doc """
  Returns an atomic catalog snapshot (`%{seq: pos_integer(), sessions: [map()]}`)
  from the catalog GenServer without waking any sessions.
  """
  @spec snapshot(GenServer.server()) :: %{seq: pos_integer(), sessions: [map()]}
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @doc """
  Sanitizes an optional activity label to at most #{@max_activity_label_length}
  printable characters without control characters.
  """
  @spec sanitize_activity_label(term()) :: nil | String.t()
  def sanitize_activity_label(nil), do: nil

  def sanitize_activity_label(val) when is_binary(val) do
    cleaned =
      val
      |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    case cleaned do
      "" -> nil
      str -> String.slice(str, 0, @max_activity_label_length)
    end
  end

  def sanitize_activity_label(_), do: nil

  @doc """
  Lists all catalog entries directly from ETS, sorted by `updated_at` descending.
  """
  @spec list_sessions(atom()) :: [map()]
  def list_sessions(table \\ @default_table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, entry} -> entry end)
    |> Enum.sort_by(&{&1.updated_at || 0, &1.session_id}, :desc)
  end

  @doc """
  Lists catalog entries directly from ETS scoped to `{env_id, cwd}`.

  Options:
    * `:table` - ETS table name (default `:h_catalog`)
    * `:subtree` - include sessions in descendant subdirectories (default `false`)
    * `:include_subsessions` - include sessions with a non-nil `parent` (default `true`)
  """
  @spec list_sessions_for_cwd(String.t() | nil, String.t(), keyword()) :: [map()]
  def list_sessions_for_cwd(env_id, cwd, opts \\ [])
      when (is_binary(env_id) or is_nil(env_id)) and is_binary(cwd) and is_list(opts) do
    table = Keyword.get(opts, :table, @default_table)
    subtree? = Keyword.get(opts, :subtree, false)
    include_subsessions? = Keyword.get(opts, :include_subsessions, true)
    target_env = normalize_env_id(env_id)
    target_cwd = normalize_query_cwd(target_env, cwd)

    table
    |> :ets.tab2list()
    |> Enum.reduce([], fn {_id, entry}, acc ->
      entry_env = normalize_env_id(Map.get(entry, :env_id))
      entry_cwd = normalize_query_cwd(target_env, entry.cwd)

      if entry_env == target_env and cwd_matches?(entry_cwd, target_cwd, subtree?) and
           (include_subsessions? or root_session?(entry)) do
        [entry | acc]
      else
        acc
      end
    end)
    |> Enum.sort_by(&{&1.updated_at || 0, &1.session_id}, :desc)
  end

  @doc """
  Annotates a list of directory entry maps in a single pass over ETS for `env_id`.

  Each directory map is enriched with `direct_session_count`, `subtree_session_count`,
  `active_session_count`, and `latest_session` (matching atom vs. string key style of
  each input directory map). Subsessions (`parent != nil`) are excluded by default.

  Options:
    * `:table` - ETS table name (default `:h_catalog`)
    * `:parent_path` - optional base path used when a directory map only provides `:name` / `"name"`
    * `:include_subsessions` - include subsessions in directory counts/recency (default `false`)
  """
  @spec annotate_directories(String.t() | nil, [map()], keyword()) :: [map()]
  def annotate_directories(env_id, dir_entries, opts \\ [])
      when (is_binary(env_id) or is_nil(env_id)) and is_list(dir_entries) and is_list(opts) do
    if dir_entries == [] do
      []
    else
      table = Keyword.get(opts, :table, @default_table)
      parent_path = Keyword.get(opts, :parent_path)
      include_subsessions? = Keyword.get(opts, :include_subsessions, false)
      registry = Keyword.get(opts, :registry, @default_registry)
      target_env = normalize_env_id(env_id)

      resolved_dirs = Enum.map(dir_entries, &resolve_dir_path(&1, target_env, parent_path))

      wanted_paths =
        resolved_dirs
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      stats_by_path = build_dir_stats(table, target_env, wanted_paths, include_subsessions?)

      Enum.zip_with(dir_entries, resolved_dirs, fn dir, dir_path ->
        stats = Map.get(stats_by_path, dir_path, empty_dir_stats())
        merge_dir_annotations(dir, stats, registry)
      end)
    end
  end

  @doc """
  Looks up a single session entry directly from ETS.
  """
  @spec get_session(String.t(), atom()) :: {:ok, map()} | {:error, :not_found}
  def get_session(session_id, table \\ @default_table) when is_binary(session_id) do
    case :ets.lookup(table, session_id) do
      [{^session_id, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Inserts or merges server-owned session metadata after validating `session_id`
  and absolute `cwd`. Persists to ETS and disk atomically.
  """
  @spec put_session(GenServer.server(), map()) :: {:ok, map()} | {:error, String.t()}
  def put_session(server \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.call(server, {:put_session, attrs})
  end

  @doc false
  def publish_archive(server, attrs, staged_path) do
    GenServer.call(server, {:publish_archive, attrs, staged_path}, :infinity)
  end

  @doc "Creates an identity without overwriting a concurrently created session."
  def insert_session(server, attrs) when is_map(attrs) do
    GenServer.call(server, {:insert_session, attrs})
  end

  @doc """
  Applies worker-owned runtime updates (`title`, `active`, `next_wake_at`,
  `updated_at`, `applied_edit_rev`) without overwriting server-owned fields
  like `cwd` or `status`.
  """
  @spec report_runtime(GenServer.server(), String.t(), map()) ::
          {:ok, map()} | {:error, :not_found}
  def report_runtime(server \\ __MODULE__, session_id, runtime_fields)
      when is_binary(session_id) and is_map(runtime_fields) do
    GenServer.call(server, {:report_runtime, session_id, runtime_fields})
  end

  @doc """
  Marks a session as quarantined (`status: "quarantined"`, `active: false`).
  """
  @spec quarantine(GenServer.server(), String.t(), term()) ::
          {:ok, map()} | {:error, :not_found}
  def quarantine(server \\ __MODULE__, session_id, reason) when is_binary(session_id) do
    GenServer.call(server, {:quarantine, session_id, reason})
  end

  @doc """
  Updates catalog triage metadata (`needs_attention` and/or `tags`) without
  waking the session. Setting `needs_attention: true` clears the archive flag.
  """
  @spec set_triage(GenServer.server(), String.t(), map()) ::
          {:ok, map()} | {:error, :not_found | String.t()}
  def set_triage(server \\ __MODULE__, session_id, attrs)
      when is_binary(session_id) and is_map(attrs) do
    GenServer.call(server, {:set_triage, session_id, attrs})
  end

  @doc """
  Archives or unarchives a session in the catalog without waking it.
  """
  @spec set_archived(GenServer.server(), String.t(), boolean(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  def set_archived(server \\ __MODULE__, session_id, archived?, opts \\ [])
      when is_binary(session_id) and is_boolean(archived?) and is_list(opts) do
    GenServer.call(server, {:set_archived, session_id, archived?, opts})
  end

  @doc """
  Broadcasts a fresh `:catalog` upsert for `session_id` reflecting live computed
  fields (`loaded`, `cwd_exists`) without rewriting `sessions.json`.
  """
  @spec broadcast_live_state(GenServer.server(), String.t()) :: :ok
  def broadcast_live_state(server \\ __MODULE__, session_id) when is_binary(session_id) do
    GenServer.call(server, {:broadcast_live_state, session_id})
  end

  @doc """
  Deletes a session entry from ETS and disk atomically.
  """
  @spec delete_session(GenServer.server(), String.t()) :: :ok
  def delete_session(server \\ __MODULE__, session_id) when is_binary(session_id) do
    GenServer.call(server, {:delete_session, session_id})
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir) |> Path.expand()
    table_name = Keyword.get(opts, :table, @default_table)
    pubsub = Keyword.get(opts, :pubsub, H.PubSub)
    registry = Keyword.get(opts, :registry, @default_registry)

    catalog_dir = Path.join(data_dir, "catalog")
    File.mkdir_p!(data_dir)
    File.chmod!(data_dir, 0o700)
    File.mkdir_p!(catalog_dir)
    File.chmod!(catalog_dir, 0o700)

    table = :ets.new(table_name, [:set, :protected, :named_table, read_concurrency: true])
    file_path = Path.join(catalog_dir, "sessions.json")

    entries = load_sessions!(file_path)

    Enum.each(entries, fn {session_id, entry} ->
      :ets.insert(table, {session_id, entry})
    end)

    {:ok,
     %{
       table: table,
       file_path: file_path,
       entries: entries,
       pubsub: pubsub,
       registry: registry,
       seq: 1
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    sessions =
      state.entries
      |> Map.values()
      |> Enum.sort_by(&{&1.updated_at || 0, &1.session_id}, :desc)

    {:reply, %{seq: state.seq, sessions: sessions}, state}
  end

  def handle_call({:publish_archive, attrs, staged}, _from, state) do
    existing = state.entries[attrs.session_id]
    old = existing && existing.archive
    source = attrs.archive
    sid = attrs.session_id

    outcome =
      cond do
        existing && is_nil(old) ->
          {:error, {:conflict, "session ID is already in use"}}

        old && {old.source, old.source_id} != {source.source, source.source_id} ->
          {:error, {:conflict, "archive source does not match"}}

        old && {source.revision, source.size} == {old.revision, old.size} ->
          {:ok, "unchanged"}

        old && {source.revision, source.size} < {old.revision, old.size} ->
          {:ok, "stale"}

        true ->
          nil
      end

    if outcome do
      {:reply, outcome, state}
    else
      gen = if old, do: old.generation + 1, else: 1
      dir = Path.dirname(staged)
      dest = H.Archive.path(dir, sid, gen)

      with {:ok, validated} <-
             validate_put_attrs(
               Map.merge(attrs, %{
                 status: "archived",
                 archived: true,
                 needs_attention: false,
                 harness_id: source.source
               })
             ),
           :ok <- File.rename(staged, dest) do
        entry = build_entry(nil, validated, attrs.updated_at)
        tags = if existing, do: existing.tags, else: entry.tags
        entry = %{entry | archive: Map.put(source, :generation, gen), tags: tags}
        entries = Map.put(state.entries, sid, entry)
        persist_entries!(state.file_path, entries)
        :ets.insert(state.table, {sid, entry})
        if old, do: File.rm(H.Archive.path(dir, sid, old.generation))
        seq = state.seq + 1
        broadcast_upsert(state.pubsub, state.registry, seq, entry)

        {:reply, {:ok, if(old, do: "updated", else: "created")},
         %{state | entries: entries, seq: seq}}
      else
        {:error, reason} when is_binary(reason) ->
          {:reply, {:error, {:bad_request, reason}}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({operation, attrs}, _from, state)
      when operation in [:put_session, :insert_session] do
    with {:ok, validated} <- validate_put_attrs(attrs) do
      now = System.system_time(:millisecond)
      session_id = validated.session_id
      existing = Map.get(state.entries, session_id)

      if operation == :insert_session and existing do
        {:reply, {:existing, existing}, state}
      else
        entry = build_entry(existing, validated, now)
        entries = Map.put(state.entries, session_id, entry)
        persist_entries!(state.file_path, entries)
        :ets.insert(state.table, {session_id, entry})
        next_seq = state.seq + 1
        broadcast_upsert(state.pubsub, state.registry, next_seq, entry)

        {:reply, {:ok, entry}, %{state | entries: entries, seq: next_seq}}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:report_runtime, session_id, runtime_fields}, _from, state) do
    case Map.fetch(state.entries, session_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, existing} ->
        now = System.system_time(:millisecond)
        updates = extract_runtime_fields(runtime_fields, existing.status)

        candidate =
          existing
          |> Map.merge(updates)
          |> enforce_status_attention()
          |> apply_runtime_triage_transitions(existing)

        changed? = runtime_changed?(existing, candidate)

        if changed? do
          updated =
            if Map.has_key?(updates, :updated_at) do
              candidate
            else
              %{candidate | updated_at: now}
            end

          entries = Map.put(state.entries, session_id, updated)
          persist_entries!(state.file_path, entries)
          :ets.insert(state.table, {session_id, updated})
          next_seq = state.seq + 1
          broadcast_upsert(state.pubsub, state.registry, next_seq, updated)

          {:reply, {:ok, updated}, %{state | entries: entries, seq: next_seq}}
        else
          {:reply, {:ok, existing}, state}
        end
    end
  end

  def handle_call({:quarantine, session_id, reason}, _from, state) do
    case Map.fetch(state.entries, session_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, existing} ->
        now = System.system_time(:millisecond)
        normalized_reason = normalize_reason(reason)

        updated = %{
          existing
          | status: "quarantined",
            active: false,
            attention: "quarantined",
            activity_kind: nil,
            activity_label: sanitize_activity_label(normalized_reason),
            needs_attention: true,
            archived: false,
            quarantine_reason: normalized_reason,
            updated_at: now
        }

        entries = Map.put(state.entries, session_id, updated)
        persist_entries!(state.file_path, entries)
        :ets.insert(state.table, {session_id, updated})
        next_seq = state.seq + 1
        broadcast_upsert(state.pubsub, state.registry, next_seq, updated)

        {:reply, {:ok, updated}, %{state | entries: entries, seq: next_seq}}
    end
  end

  def handle_call({:set_triage, session_id, attrs}, _from, state) do
    with {:ok, updates} <-
           Schema.validate_map(attrs, [{:needs_attention, :boolean}, {:tags, :session_tags}]),
         true <- map_size(updates) > 0 || {:error, "expected needs_attention or tags"},
         {:ok, existing} <- Map.fetch(state.entries, session_id),
         false <- existing.status == "archived" and Map.has_key?(updates, :needs_attention) do
      updated =
        existing
        |> Map.merge(updates)
        |> then(fn entry ->
          if updates[:needs_attention] == true, do: %{entry | archived: false}, else: entry
        end)
        |> Map.put(:updated_at, System.system_time(:millisecond))

      entries = Map.put(state.entries, session_id, updated)
      persist_entries!(state.file_path, entries)
      :ets.insert(state.table, {session_id, updated})
      next_seq = state.seq + 1
      broadcast_upsert(state.pubsub, state.registry, next_seq, updated)

      {:reply, {:ok, updated}, %{state | entries: entries, seq: next_seq}}
    else
      :error -> {:reply, {:error, :not_found}, state}
      true -> {:reply, {:error, {:conflict, "session is archived"}}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_archived, session_id, archived?, opts}, _from, state) do
    case Map.fetch(state.entries, session_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{status: "archived"} = existing} ->
        if archived? do
          {:reply, {:ok, existing}, state}
        else
          {:reply, {:error, {:conflict, "session is archived"}}, state}
        end

      {:ok, existing} ->
        now = System.system_time(:millisecond)

        updated =
          if archived? do
            {next_attention, next_kind, next_label} =
              if existing.attention in ["running", "sleeping", "retrying"] do
                {"idle", nil, nil}
              else
                {existing.attention, existing.activity_kind, existing.activity_label}
              end

            %{
              existing
              | archived: true,
                needs_attention: false,
                active: false,
                attention: next_attention,
                activity_kind: next_kind,
                activity_label: next_label,
                updated_at: now
            }
            |> enforce_status_attention()
          else
            next_needs_attention =
              case Keyword.fetch(opts, :needs_attention) do
                {:ok, val} when is_boolean(val) -> val
                _ -> existing.needs_attention
              end

            %{
              existing
              | archived: false,
                needs_attention: next_needs_attention,
                updated_at: now
            }
          end

        entries = Map.put(state.entries, session_id, updated)
        persist_entries!(state.file_path, entries)
        :ets.insert(state.table, {session_id, updated})
        next_seq = state.seq + 1
        broadcast_upsert(state.pubsub, state.registry, next_seq, updated)

        {:reply, {:ok, updated}, %{state | entries: entries, seq: next_seq}}
    end
  end

  def handle_call({:broadcast_live_state, session_id}, _from, state) do
    case Map.fetch(state.entries, session_id) do
      {:ok, entry} ->
        next_seq = state.seq + 1
        broadcast_upsert(state.pubsub, state.registry, next_seq, entry)
        {:reply, :ok, %{state | seq: next_seq}}

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:delete_session, session_id}, _from, state) do
    entries = Map.delete(state.entries, session_id)

    if map_size(entries) != map_size(state.entries) do
      persist_entries!(state.file_path, entries)
      :ets.delete(state.table, session_id)
      next_seq = state.seq + 1
      broadcast_removed(state.pubsub, next_seq, session_id)
      {:reply, :ok, %{state | entries: entries, seq: next_seq}}
    else
      {:reply, :ok, state}
    end
  end

  defp validate_put_attrs(attrs) do
    with {:ok, base} <-
           Schema.validate_map(attrs, [
             {:session_id, :session_id, required: true},
             {:env_id, :non_empty_string, required: false, default: "host"},
             {:harness_id, :non_empty_string, required: false, default: "coding"},
             {:cwd, :string, required: true},
             {:title, :string, required: false, nullable: true},
             {:parent,
              {:map,
               [
                 {:session_id, :session_id, required: true},
                 {:conversation_id, :pos_int, required: false, default: 1},
                 {:at_entry_id, :pos_int, required: false, nullable: true, default: nil},
                 {:task_id, :pos_int, required: false, nullable: true, default: nil},
                 {:depth, :pos_int, required: false, default: 1}
               ]}, required: false, nullable: true},
             {:role, :string, required: false, nullable: true},
             {:tags, :session_tags},
             {:root_conversation_id, :pos_int, required: false},
             {:created_at, :int, required: false},
             {:updated_at, :int, required: false},
             {:active, :boolean, required: false},
             {:attention, {:enum, @valid_attentions}, required: false},
             {:activity_kind, {:enum, @valid_activity_kinds}, required: false, nullable: true},
             {:activity_label, :string, required: false, nullable: true},
             {:queued_count, {:int, min: 0}, required: false},
             {:needs_attention, :boolean, required: false},
             {:archived, :boolean, required: false},
             {:next_wake_at, :int, required: false, nullable: true},
             {:status, {:enum, ["ok", "quarantined", "archived"]}, required: false},
             {:quarantine_reason, :string, required: false, nullable: true},
             {:pending_edits, {:list, :any}, required: false},
             {:applied_edit_rev, :int, required: false}
           ]),
         :ok <- validate_parent_not_self(base),
         {:ok, normalized_cwd} <- validate_and_normalize_cwd(base.env_id, base.cwd),
         {:ok, normalized_base} <- normalize_optional_title(base),
         {:ok, normalized_base} <- normalize_optional_role(normalized_base) do
      normalized_base =
        if Map.has_key?(normalized_base, :activity_label) do
          %{
            normalized_base
            | activity_label: sanitize_activity_label(normalized_base.activity_label)
          }
        else
          normalized_base
        end

      {:ok, %{normalized_base | cwd: normalized_cwd}}
    end
  end

  defp validate_parent_not_self(%{session_id: sid, parent: %{session_id: sid}}),
    do: {:error, "parent: cannot reference self"}

  defp validate_parent_not_self(_), do: :ok

  defp normalize_optional_role(%{role: role} = map) do
    case normalize_role(role) do
      {:ok, normalized} -> {:ok, %{map | role: normalized}}
      {:error, reason} -> {:error, "role: #{reason}"}
    end
  end

  defp normalize_optional_role(map), do: {:ok, map}

  defp normalize_role(nil), do: {:ok, nil}

  defp normalize_role(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:ok, nil}

      String.contains?(value, <<0>>) or Regex.match?(~r/[\x00-\x1F\x7F]/u, value) ->
        {:error, "must not contain control characters"}

      String.length(trimmed) > @max_role_length ->
        {:error, "must be at most #{@max_role_length} characters"}

      true ->
        {:ok, trimmed}
    end
  end

  defp normalize_role(_), do: {:error, "must be a string"}

  defp normalize_optional_title(%{title: title} = map) do
    case Schema.normalize_title(title) do
      {:ok, normalized} -> {:ok, %{map | title: normalized}}
      {:error, reason} -> {:error, "title: #{reason}"}
    end
  end

  defp normalize_optional_title(map), do: {:ok, map}

  defp build_entry(nil, validated, now) do
    status = Map.get(validated, :status, "ok")
    archived = status == "archived" or Map.get(validated, :archived, false) == true

    needs_attention =
      if archived do
        false
      else
        Map.get(validated, :needs_attention, true) == true
      end

    %{
      session_id: validated.session_id,
      title: Map.get(validated, :title, nil),
      tags: Map.get(validated, :tags, []),
      env_id: Map.get(validated, :env_id, "host"),
      cwd: validated.cwd,
      harness_id: Map.get(validated, :harness_id, "coding"),
      root_conversation_id: Map.get(validated, :root_conversation_id, 1),
      parent: Map.get(validated, :parent, nil),
      role: Map.get(validated, :role, nil),
      created_at: Map.get(validated, :created_at, now),
      updated_at: Map.get(validated, :updated_at, now),
      active: Map.get(validated, :active, false),
      attention: Map.get(validated, :attention, "idle"),
      activity_kind: Map.get(validated, :activity_kind, nil),
      activity_label: Map.get(validated, :activity_label, nil),
      queued_count: Map.get(validated, :queued_count, 0),
      needs_attention: needs_attention,
      archived: archived,
      next_wake_at: Map.get(validated, :next_wake_at, nil),
      status: status,
      archive: nil,
      quarantine_reason: Map.get(validated, :quarantine_reason, nil),
      pending_edits: Map.get(validated, :pending_edits, []),
      applied_edit_rev: Map.get(validated, :applied_edit_rev, 0)
    }
    |> enforce_status_attention()
    |> enforce_archived_triage()
  end

  defp build_entry(existing, validated, now) do
    # `parent` and `role` are immutable once written on an existing entry.
    mutable_updates =
      validated
      |> Map.drop([:parent, :role])

    existing
    |> Map.put_new(:parent, nil)
    |> Map.put_new(:role, nil)
    |> Map.merge(mutable_updates)
    |> enforce_status_attention()
    |> enforce_archived_triage()
    |> then(fn entry ->
      if Map.has_key?(validated, :updated_at), do: entry, else: %{entry | updated_at: now}
    end)
  end

  defp extract_runtime_fields(input, existing_status) do
    @worker_fields
    |> extract_fields(input)
    |> Enum.reduce(%{}, fn {key, val}, acc ->
      case validate_runtime_field(key, val, existing_status) do
        {:ok, normalized} -> Map.put(acc, key, normalized)
        :ignore -> acc
      end
    end)
  end

  defp extract_fields(allowed_keys, input) do
    Enum.reduce(allowed_keys, %{}, fn key, acc ->
      key_str = Atom.to_string(key)

      case Map.fetch(input, key_str) do
        {:ok, val} ->
          Map.put(acc, key, val)

        :error ->
          case Map.fetch(input, key) do
            {:ok, val} -> Map.put(acc, key, val)
            :error -> acc
          end
      end
    end)
  end

  defp validate_runtime_field(:title, nil, _status), do: {:ok, nil}

  defp validate_runtime_field(:title, val, _status) when is_binary(val) do
    case Schema.normalize_title(val) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _} -> :ignore
    end
  end

  defp validate_runtime_field(:active, val, _status) when is_boolean(val), do: {:ok, val}

  defp validate_runtime_field(:attention, _val, "quarantined"), do: {:ok, "quarantined"}

  defp validate_runtime_field(:attention, val, _status)
       when val in ["idle", "running", "sleeping", "retrying", "error"],
       do: {:ok, val}

  defp validate_runtime_field(:activity_kind, nil, _status), do: {:ok, nil}

  defp validate_runtime_field(:activity_kind, val, _status)
       when val in @valid_activity_kinds,
       do: {:ok, val}

  defp validate_runtime_field(:activity_label, nil, _status), do: {:ok, nil}

  defp validate_runtime_field(:activity_label, val, _status) when is_binary(val),
    do: {:ok, sanitize_activity_label(val)}

  defp validate_runtime_field(:queued_count, val, _status)
       when is_integer(val) and val >= 0,
       do: {:ok, val}

  defp validate_runtime_field(:next_wake_at, nil, _status), do: {:ok, nil}

  defp validate_runtime_field(:next_wake_at, val, _status) when is_integer(val),
    do: {:ok, val}

  defp validate_runtime_field(:updated_at, val, _status) when is_integer(val),
    do: {:ok, val}

  defp validate_runtime_field(:applied_edit_rev, val, _status) when is_integer(val),
    do: {:ok, val}

  defp validate_runtime_field(_key, _val, _status), do: :ignore

  defp runtime_changed?(existing, candidate) do
    Enum.any?(@runtime_change_fields, fn key ->
      Map.get(existing, key) != Map.get(candidate, key)
    end)
  end

  defp enforce_archived_triage(%{archived: true} = entry), do: %{entry | needs_attention: false}
  defp enforce_archived_triage(entry), do: entry

  defp apply_runtime_triage_transitions(candidate, existing) do
    cond do
      candidate.attention in ["running", "sleeping", "retrying"] ->
        %{candidate | needs_attention: false, archived: false}

      existing.attention in ["running", "sleeping", "retrying"] and
          candidate.attention in ["idle", "error", "quarantined"] ->
        %{candidate | needs_attention: true, archived: false}

      existing.attention != "error" and candidate.attention == "error" ->
        %{candidate | needs_attention: true, archived: false}

      true ->
        enforce_archived_triage(candidate)
    end
  end

  defp session_loaded?(registry, session_id)
       when is_atom(registry) and not is_nil(registry) and is_binary(session_id) do
    if Process.whereis(registry) != nil do
      try do
        case Registry.lookup(registry, {:session, session_id}) do
          [{pid, _}] -> is_pid(pid) and Process.alive?(pid)
          _ -> false
        end
      catch
        _, _ -> false
      end
    else
      false
    end
  end

  defp session_loaded?(_registry, _session_id), do: false

  defp cwd_exists?("host", cwd) when is_binary(cwd), do: File.dir?(cwd)
  defp cwd_exists?(_env_id, _cwd), do: true

  defp enforce_status_attention(%{status: "quarantined"} = entry),
    do: %{entry | attention: "quarantined"}

  defp enforce_status_attention(%{status: "archived"} = entry),
    do: %{entry | attention: "archived", active: false, archived: true, needs_attention: false}

  defp enforce_status_attention(entry) do
    %{entry | attention: normalize_attention(Map.get(entry, :attention), entry.status)}
  end

  defp normalize_attention(_val, "quarantined"), do: "quarantined"
  defp normalize_attention(_val, "archived"), do: "archived"
  defp normalize_attention(val, _status) when val in @valid_attentions, do: val
  defp normalize_attention(_val, _status), do: "idle"

  defp normalize_activity_kind(val) when val in @valid_activity_kinds, do: val
  defp normalize_activity_kind(_), do: nil

  defp normalize_queued_count(val) when is_integer(val) and val >= 0, do: val
  defp normalize_queued_count(_), do: 0

  defp broadcast_upsert(pubsub, registry, seq, entry) do
    if not is_nil(pubsub) and Process.whereis(pubsub) != nil do
      payload =
        %{
          "version" => 1,
          "seq" => seq,
          "type" => "upsert",
          "session" => wire_session(entry, registry: registry)
        }
        |> JSON.encode_to_iodata!()
        |> IO.iodata_to_binary()

      Registry.dispatch(pubsub, :catalog, fn entries ->
        for {pid, _} <- entries do
          send(pid, {:catalog_frame, seq, payload})
        end
      end)
    end
  end

  defp broadcast_removed(pubsub, seq, session_id) do
    if not is_nil(pubsub) and Process.whereis(pubsub) != nil do
      payload =
        %{
          "version" => 1,
          "seq" => seq,
          "type" => "removed",
          "session_id" => session_id
        }
        |> JSON.encode_to_iodata!()
        |> IO.iodata_to_binary()

      Registry.dispatch(pubsub, :catalog, fn entries ->
        for {pid, _} <- entries do
          send(pid, {:catalog_frame, seq, payload})
        end
      end)
    end
  end

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason)

  defp load_sessions!(file_path) do
    case File.read(file_path) do
      {:ok, raw} ->
        decoded = JSON.decode!(raw)
        sessions = Map.get(decoded, "sessions", [])

        Map.new(sessions, fn raw_entry ->
          entry = decode_entry(raw_entry)
          {entry.session_id, entry}
        end)

      {:error, :enoent} ->
        %{}
    end
  end

  defp decode_entry(raw) when is_map(raw) do
    status = Map.get(raw, "status", "ok")
    attention = normalize_attention(Map.get(raw, "attention"), status)
    archived = status == "archived" or Map.get(raw, "archived", false) == true

    needs_attention =
      if archived do
        false
      else
        case Map.fetch(raw, "needs_attention") do
          {:ok, val} when is_boolean(val) -> val
          _ -> attention not in ["running", "sleeping", "retrying"]
        end
      end

    %{
      session_id: Map.fetch!(raw, "session_id"),
      title: Map.get(raw, "title"),
      tags: Map.get(raw, "tags", []),
      env_id: non_empty_or_default(Map.get(raw, "env_id"), "host"),
      cwd: Map.fetch!(raw, "cwd"),
      harness_id: non_empty_or_default(Map.get(raw, "harness_id"), "coding"),
      root_conversation_id: Map.get(raw, "root_conversation_id", 1),
      parent: decode_parent(Map.get(raw, "parent")),
      role: decode_role(Map.get(raw, "role")),
      created_at: Map.fetch!(raw, "created_at"),
      updated_at: Map.fetch!(raw, "updated_at"),
      active: Map.get(raw, "active", false),
      attention: attention,
      activity_kind: normalize_activity_kind(Map.get(raw, "activity_kind")),
      activity_label: sanitize_activity_label(Map.get(raw, "activity_label")),
      queued_count: normalize_queued_count(Map.get(raw, "queued_count")),
      needs_attention: needs_attention,
      archived: archived,
      next_wake_at: Map.get(raw, "next_wake_at"),
      status: status,
      archive: decode_archive(raw["archive"]),
      quarantine_reason: Map.get(raw, "quarantine_reason"),
      pending_edits: Map.get(raw, "pending_edits", []),
      applied_edit_rev: Map.get(raw, "applied_edit_rev", 0)
    }
  end

  defp decode_parent(nil), do: nil

  defp decode_parent(raw) when is_map(raw) do
    case Schema.validate_session_id(Map.get(raw, "session_id")) do
      {:ok, sid} ->
        %{
          session_id: sid,
          conversation_id: decode_pos_int(Map.get(raw, "conversation_id"), 1),
          at_entry_id: decode_optional_pos_int(Map.get(raw, "at_entry_id")),
          task_id: decode_optional_pos_int(Map.get(raw, "task_id")),
          depth: decode_pos_int(Map.get(raw, "depth"), 1)
        }

      {:error, _} ->
        nil
    end
  end

  defp decode_parent(_), do: nil

  defp decode_pos_int(val, default) do
    case Schema.parse_pos_int(val) do
      {:ok, n} -> n
      {:error, _} -> default
    end
  end

  defp decode_optional_pos_int(nil), do: nil

  defp decode_optional_pos_int(val) do
    case Schema.parse_pos_int(val) do
      {:ok, n} -> n
      {:error, _} -> nil
    end
  end

  defp decode_role(val) do
    case normalize_role(val) do
      {:ok, role} -> role
      {:error, _} -> nil
    end
  end

  defp wire_parent(nil), do: nil

  defp wire_parent(p) when is_map(p) do
    %{
      session_id: p.session_id,
      conversation_id: to_string(p.conversation_id || 1),
      at_entry_id: if(p.at_entry_id, do: to_string(p.at_entry_id), else: nil),
      task_id: if(p.task_id, do: to_string(p.task_id), else: nil),
      depth: p.depth || 1
    }
  end

  defp wire_parent_string_keys(nil), do: nil

  defp wire_parent_string_keys(p) when is_map(p) do
    %{
      "session_id" => p.session_id,
      "conversation_id" => to_string(p.conversation_id || 1),
      "at_entry_id" => if(p.at_entry_id, do: to_string(p.at_entry_id), else: nil),
      "task_id" => if(p.task_id, do: to_string(p.task_id), else: nil),
      "depth" => p.depth || 1
    }
  end

  defp decode_archive(%{
         "source" => source,
         "source_id" => id,
         "revision" => revision,
         "size" => size,
         "generation" => gen
       }) do
    %{source: source, source_id: id, revision: revision, size: size, generation: gen}
  end

  defp decode_archive(nil), do: nil

  defp non_empty_or_default(val, _default) when is_binary(val) and val != "", do: val
  defp non_empty_or_default(_val, default), do: default

  defp normalize_env_id(val) when is_binary(val) and val != "", do: val
  defp normalize_env_id(_), do: "host"

  defp validate_and_normalize_cwd("host", cwd) do
    cond do
      not String.starts_with?(cwd, "/") ->
        {:error, "cwd: must be an absolute path"}

      String.contains?(cwd, <<0>>) ->
        {:error, "cwd: must not contain NUL bytes"}

      true ->
        {:ok, Path.expand(cwd)}
    end
  end

  defp validate_and_normalize_cwd(_env_id, cwd) do
    cond do
      not String.starts_with?(cwd, "/") ->
        {:error, "cwd: must be an absolute path"}

      String.contains?(cwd, <<0>>) ->
        {:error, "cwd: must not contain NUL bytes"}

      true ->
        {:ok, trim_trailing_slash(cwd)}
    end
  end

  defp normalize_query_cwd("host", cwd), do: Path.expand(cwd)
  defp normalize_query_cwd(_env_id, cwd), do: trim_trailing_slash(cwd)

  defp trim_trailing_slash("/"), do: "/"

  defp trim_trailing_slash(cwd) do
    case String.trim_trailing(cwd, "/") do
      "" -> if String.starts_with?(cwd, "/"), do: "/", else: ""
      trimmed -> trimmed
    end
  end

  defp cwd_matches?(entry_cwd, target_cwd, false), do: entry_cwd == target_cwd

  defp cwd_matches?(entry_cwd, "/", true),
    do: entry_cwd == "/" or String.starts_with?(entry_cwd, "/")

  defp cwd_matches?(entry_cwd, target_cwd, true),
    do: entry_cwd == target_cwd or String.starts_with?(entry_cwd, target_cwd <> "/")

  defp resolve_dir_path(dir, target_env, parent_path) when is_map(dir) do
    cond do
      is_binary(path = Map.get(dir, :path) || Map.get(dir, "path")) ->
        normalize_query_cwd(target_env, path)

      is_binary(name = Map.get(dir, :name) || Map.get(dir, "name")) and is_binary(parent_path) ->
        join_and_normalize_cwd(target_env, parent_path, name)

      true ->
        nil
    end
  end

  defp join_and_normalize_cwd("host", parent_path, name) do
    Path.join(parent_path, name) |> Path.expand()
  end

  defp join_and_normalize_cwd(env_id, parent_path, name) do
    base = normalize_query_cwd(env_id, parent_path)
    trimmed_name = String.trim_leading(name, "/")

    joined =
      case base do
        "/" -> "/" <> trimmed_name
        _ -> base <> "/" <> trimmed_name
      end

    normalize_query_cwd(env_id, joined)
  end

  defp build_dir_stats(table, target_env, wanted_paths, include_subsessions?) do
    table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn {_id, entry}, acc ->
      if normalize_env_id(Map.get(entry, :env_id)) == target_env and
           (include_subsessions? or root_session?(entry)) do
        accumulate_session_stats(acc, entry, target_env, wanted_paths)
      else
        acc
      end
    end)
  end

  defp accumulate_session_stats(acc, entry, target_env, wanted_paths) do
    entry_cwd = normalize_query_cwd(target_env, entry.cwd)

    acc =
      if MapSet.member?(wanted_paths, entry_cwd) do
        update_dir_stat(acc, entry_cwd, entry, true)
      else
        acc
      end

    entry_cwd
    |> ancestor_paths()
    |> Enum.reduce(acc, fn anc_path, inner_acc ->
      if MapSet.member?(wanted_paths, anc_path) do
        update_dir_stat(inner_acc, anc_path, entry, false)
      else
        inner_acc
      end
    end)
  end

  defp ancestor_paths("/"), do: []

  defp ancestor_paths(path) do
    case Path.dirname(path) do
      ^path -> []
      parent -> [parent | ancestor_paths(parent)]
    end
  end

  defp update_dir_stat(acc, path, entry, direct?) do
    active_inc = if entry.active == true, do: 1, else: 0
    direct_inc = if direct?, do: 1, else: 0

    Map.update(
      acc,
      path,
      %{
        direct_session_count: direct_inc,
        subtree_session_count: 1,
        active_session_count: active_inc,
        latest_session: entry
      },
      fn stat ->
        %{
          direct_session_count: stat.direct_session_count + direct_inc,
          subtree_session_count: stat.subtree_session_count + 1,
          active_session_count: stat.active_session_count + active_inc,
          latest_session: newer_session(stat.latest_session, entry)
        }
      end
    )
  end

  defp newer_session(current, candidate) do
    if {candidate.updated_at || 0, candidate.session_id} >
         {current.updated_at || 0, current.session_id} do
      candidate
    else
      current
    end
  end

  defp empty_dir_stats do
    %{
      direct_session_count: 0,
      subtree_session_count: 0,
      active_session_count: 0,
      latest_session: nil
    }
  end

  defp merge_dir_annotations(dir, stats, registry) do
    if string_keyed_map?(dir) do
      latest =
        case stats.latest_session do
          nil ->
            nil

          s ->
            wired = wire_session(s, registry: registry)

            %{
              "session_id" => wired.session_id,
              "title" => wired.title,
              "tags" => wired.tags,
              "cwd" => wired.cwd,
              "parent" => wire_parent_string_keys(Map.get(s, :parent)),
              "role" => wired.role,
              "updated_at" => wired.updated_at,
              "active" => wired.active,
              "attention" => wired.attention,
              "activity_kind" => wired.activity_kind,
              "activity_label" => wired.activity_label,
              "queued_count" => wired.queued_count,
              "needs_attention" => wired.needs_attention,
              "archived" => wired.archived,
              "loaded" => wired.loaded,
              "cwd_exists" => wired.cwd_exists,
              "status" => wired.status
            }
        end

      Map.merge(dir, %{
        "direct_session_count" => stats.direct_session_count,
        "subtree_session_count" => stats.subtree_session_count,
        "active_session_count" => stats.active_session_count,
        "latest_session" => latest
      })
    else
      latest =
        case stats.latest_session do
          nil ->
            nil

          s ->
            wired = wire_session(s, registry: registry)

            %{
              session_id: wired.session_id,
              title: wired.title,
              tags: wired.tags,
              cwd: wired.cwd,
              parent: wired.parent,
              role: wired.role,
              updated_at: wired.updated_at,
              active: wired.active,
              attention: wired.attention,
              activity_kind: wired.activity_kind,
              activity_label: wired.activity_label,
              queued_count: wired.queued_count,
              needs_attention: wired.needs_attention,
              archived: wired.archived,
              loaded: wired.loaded,
              cwd_exists: wired.cwd_exists,
              status: wired.status
            }
        end

      Map.merge(dir, %{
        direct_session_count: stats.direct_session_count,
        subtree_session_count: stats.subtree_session_count,
        active_session_count: stats.active_session_count,
        latest_session: latest
      })
    end
  end

  defp string_keyed_map?(map) do
    keys = Map.keys(map)
    Enum.any?(keys, &is_binary/1) and not Enum.any?(keys, &is_atom/1)
  end

  defp persist_entries!(file_path, entries) do
    payload =
      %{
        "version" => 1,
        "sessions" => entries |> Map.values() |> Enum.sort_by(& &1.session_id)
      }
      |> JSON.encode_to_iodata!()
      |> IO.iodata_to_binary()

    tmp_path = "#{file_path}.tmp.#{System.unique_integer([:positive])}"
    {:ok, fd} = :file.open(tmp_path, [:write, :raw, :binary])

    try do
      :ok = :file.write(fd, payload)
      :ok = :file.sync(fd)
    after
      :ok = :file.close(fd)
    end

    File.chmod!(tmp_path, 0o600)
    File.rename!(tmp_path, file_path)
  end
end
