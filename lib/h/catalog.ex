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
  def handle_call({:put_session, attrs}, _from, state) do
    with {:ok, validated} <- validate_put_attrs(attrs) do
      now = System.system_time(:millisecond)
      session_id = validated.session_id
      existing = Map.get(state.entries, session_id)

      entry = build_entry(existing, validated, now)
      entries = Map.put(state.entries, session_id, entry)
      persist_entries!(state.file_path, entries)
      :ets.insert(state.table, {session_id, entry})

      {:reply, {:ok, entry}, %{state | entries: entries}}
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
             {:cwd, :abs_path, required: true},
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
           ]) do
      {:ok, %{base | cwd: Path.expand(base.cwd)}}
    end
  end

  defp build_entry(nil, validated, now) do
    %{
      session_id: validated.session_id,
      title: Map.get(validated, :title, nil),
      cwd: validated.cwd,
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
      cwd: Map.fetch!(raw, "cwd"),
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
