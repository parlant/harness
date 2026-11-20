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

  @worker_fields [:title, :active, :next_wake_at, :updated_at, :applied_edit_rev]

  @doc """
  Starts the catalog process.

  Options:
    * `:data_dir` (required) - root storage directory
    * `:name` - GenServer registration name (default `H.Catalog`, pass `nil` for unnamed)
    * `:table` - ETS table name (default `:h_catalog`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    _data_dir = Keyword.fetch!(opts, :data_dir)
    gen_opts = if name = Keyword.get(opts, :name, __MODULE__), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

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
  """
  @spec list_sessions_for_cwd(String.t() | nil, String.t(), keyword()) :: [map()]
  def list_sessions_for_cwd(env_id, cwd, opts \\ [])
      when (is_binary(env_id) or is_nil(env_id)) and is_binary(cwd) and is_list(opts) do
    table = Keyword.get(opts, :table, @default_table)
    subtree? = Keyword.get(opts, :subtree, false)
    target_env = normalize_env_id(env_id)
    target_cwd = normalize_query_cwd(target_env, cwd)

    table
    |> :ets.tab2list()
    |> Enum.reduce([], fn {_id, entry}, acc ->
      entry_env = normalize_env_id(Map.get(entry, :env_id))
      entry_cwd = normalize_query_cwd(target_env, entry.cwd)

      if entry_env == target_env and cwd_matches?(entry_cwd, target_cwd, subtree?) do
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
  each input directory map).

  Options:
    * `:table` - ETS table name (default `:h_catalog`)
    * `:parent_path` - optional base path used when a directory map only provides `:name` / `"name"`
  """
  @spec annotate_directories(String.t() | nil, [map()], keyword()) :: [map()]
  def annotate_directories(env_id, dir_entries, opts \\ [])
      when (is_binary(env_id) or is_nil(env_id)) and is_list(dir_entries) and is_list(opts) do
    if dir_entries == [] do
      []
    else
      table = Keyword.get(opts, :table, @default_table)
      parent_path = Keyword.get(opts, :parent_path)
      target_env = normalize_env_id(env_id)

      resolved_dirs = Enum.map(dir_entries, &resolve_dir_path(&1, target_env, parent_path))

      wanted_paths =
        resolved_dirs
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      stats_by_path = build_dir_stats(table, target_env, wanted_paths)

      Enum.zip_with(dir_entries, resolved_dirs, fn dir, dir_path ->
        stats = Map.get(stats_by_path, dir_path, empty_dir_stats())
        merge_dir_annotations(dir, stats)
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

    {:ok, %{table: table, file_path: file_path, entries: entries}}
  end

  @impl true
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

        {:reply, {:ok, entry}, %{state | entries: entries}}
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
        updates = extract_fields(runtime_fields, @worker_fields)

        updated =
          existing
          |> Map.merge(updates)
          |> Map.put_new(:updated_at, now)
          |> then(fn entry ->
            if Map.has_key?(updates, :updated_at), do: entry, else: %{entry | updated_at: now}
          end)

        entries = Map.put(state.entries, session_id, updated)
        persist_entries!(state.file_path, entries)
        :ets.insert(state.table, {session_id, updated})

        {:reply, {:ok, updated}, %{state | entries: entries}}
    end
  end

  def handle_call({:quarantine, session_id, reason}, _from, state) do
    case Map.fetch(state.entries, session_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, existing} ->
        now = System.system_time(:millisecond)

        updated = %{
          existing
          | status: "quarantined",
            active: false,
            quarantine_reason: normalize_reason(reason),
            updated_at: now
        }

        entries = Map.put(state.entries, session_id, updated)
        persist_entries!(state.file_path, entries)
        :ets.insert(state.table, {session_id, updated})

        {:reply, {:ok, updated}, %{state | entries: entries}}
    end
  end

  def handle_call({:delete_session, session_id}, _from, state) do
    entries = Map.delete(state.entries, session_id)

    if map_size(entries) != map_size(state.entries) do
      persist_entries!(state.file_path, entries)
      :ets.delete(state.table, session_id)
    end

    {:reply, :ok, %{state | entries: entries}}
  end

  defp validate_put_attrs(attrs) do
    with {:ok, base} <-
           Schema.validate_map(attrs, [
             {:session_id, :session_id, required: true},
             {:env_id, :non_empty_string, required: false, default: "host"},
             {:harness_id, :non_empty_string, required: false, default: "coding"},
             {:cwd, :string, required: true},
             {:title, :string, required: false, nullable: true},
             {:root_conversation_id, :pos_int, required: false},
             {:created_at, :int, required: false},
             {:updated_at, :int, required: false},
             {:active, :boolean, required: false},
             {:next_wake_at, :int, required: false, nullable: true},
             {:status, {:enum, ["ok", "quarantined"]}, required: false},
             {:quarantine_reason, :string, required: false, nullable: true},
             {:pending_edits, {:list, :any}, required: false},
             {:applied_edit_rev, :int, required: false}
           ]),
         {:ok, normalized_cwd} <- validate_and_normalize_cwd(base.env_id, base.cwd),
         {:ok, normalized_base} <- normalize_optional_title(base) do
      {:ok, %{normalized_base | cwd: normalized_cwd}}
    end
  end

  defp normalize_optional_title(%{title: title} = map) do
    case Schema.normalize_title(title) do
      {:ok, normalized} -> {:ok, %{map | title: normalized}}
      {:error, reason} -> {:error, "title: #{reason}"}
    end
  end

  defp normalize_optional_title(map), do: {:ok, map}

  defp build_entry(nil, validated, now) do
    %{
      session_id: validated.session_id,
      title: Map.get(validated, :title, nil),
      env_id: Map.get(validated, :env_id, "host"),
      cwd: validated.cwd,
      harness_id: Map.get(validated, :harness_id, "coding"),
      root_conversation_id: Map.get(validated, :root_conversation_id, 1),
      created_at: Map.get(validated, :created_at, now),
      updated_at: Map.get(validated, :updated_at, now),
      active: Map.get(validated, :active, false),
      next_wake_at: Map.get(validated, :next_wake_at, nil),
      status: Map.get(validated, :status, "ok"),
      quarantine_reason: Map.get(validated, :quarantine_reason, nil),
      pending_edits: Map.get(validated, :pending_edits, []),
      applied_edit_rev: Map.get(validated, :applied_edit_rev, 0)
    }
  end

  defp build_entry(existing, validated, now) do
    existing
    |> Map.merge(validated)
    |> then(fn entry ->
      if Map.has_key?(validated, :updated_at), do: entry, else: %{entry | updated_at: now}
    end)
  end

  defp extract_fields(input, allowed_keys) do
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
    %{
      session_id: Map.fetch!(raw, "session_id"),
      title: Map.get(raw, "title"),
      env_id: non_empty_or_default(Map.get(raw, "env_id"), "host"),
      cwd: Map.fetch!(raw, "cwd"),
      harness_id: non_empty_or_default(Map.get(raw, "harness_id"), "coding"),
      root_conversation_id: Map.get(raw, "root_conversation_id", 1),
      created_at: Map.fetch!(raw, "created_at"),
      updated_at: Map.fetch!(raw, "updated_at"),
      active: Map.get(raw, "active", false),
      next_wake_at: Map.get(raw, "next_wake_at"),
      status: Map.get(raw, "status", "ok"),
      quarantine_reason: Map.get(raw, "quarantine_reason"),
      pending_edits: Map.get(raw, "pending_edits", []),
      applied_edit_rev: Map.get(raw, "applied_edit_rev", 0)
    }
  end

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

  defp build_dir_stats(table, target_env, wanted_paths) do
    table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn {_id, entry}, acc ->
      if normalize_env_id(Map.get(entry, :env_id)) == target_env do
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

  defp merge_dir_annotations(dir, stats) do
    if string_keyed_map?(dir) do
      latest =
        case stats.latest_session do
          nil ->
            nil

          s ->
            %{
              "session_id" => s.session_id,
              "title" => s.title,
              "cwd" => s.cwd,
              "updated_at" => s.updated_at,
              "active" => s.active == true,
              "status" => s.status || "ok"
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
            %{
              session_id: s.session_id,
              title: s.title,
              cwd: s.cwd,
              updated_at: s.updated_at,
              active: s.active == true,
              status: s.status || "ok"
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

    tmp_path = file_path <> ".tmp"
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
