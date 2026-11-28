defmodule Extensions.Analytics.Store do
  @moduledoc """
  Supervised ETS + disk-backed analytics index store (`index.v1.etf`).

  Owns a `:public` ETS cache for fast queries, persists incremental session
  summaries keyed by `session_id` with `Scanner.fingerprint/2`, responds to
  advisory `mark_dirty/1` updates from `Extensions.Analytics.Observer`, and
  provides a read-only direct scan fallback when `Store` is not running (e.g.
  in lightweight LiveView unit tests).
  """

  use GenServer

  alias Extensions.Analytics.{Query, Scanner}

  @default_table :h_analytics_index
  @default_batch_size 25
  @default_sync_interval_ms 5_000
  @index_version 1

  def start_link(opts) when is_list(opts) do
    _data_dir = Keyword.fetch!(opts, :data_dir)
    gen_opts = if name = Keyword.get(opts, :name, __MODULE__), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Marks `session_id` dirty so the next sync pass rescans it. Safe no-op when
  `Store` is not running.
  """
  @spec mark_dirty(String.t(), GenServer.server()) :: :ok
  def mark_dirty(session_id, server \\ __MODULE__) when is_binary(session_id) do
    case resolve_pid(server) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:mark_dirty, session_id})
    end
  end

  @doc """
  Triggers a synchronous incremental index refresh against disk/catalog.
  """
  @spec sync_now(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def sync_now(server \\ __MODULE__) do
    GenServer.call(server, :sync_now, 60_000)
  end

  @doc """
  Queries analytics using `filters` (`window`, `source`, `subsessions`,
  `provider`, `model`, `cwd`, `cache`, `sort_by`, `sort_dir`).

  Uses the running `Store` ETS table when available (or reads/scans directly
  without starting `Store` when `opts[:data_dir]` is supplied and `Store` is
  not running).
  """
  @spec query(map(), keyword()) :: map()
  def query(filters \\ %{}, opts \\ []) when is_map(filters) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    table = Keyword.get(opts, :table, @default_table)
    sync? = Keyword.get(opts, :sync, false)

    summaries =
      cond do
        pid = resolve_pid(server) ->
          if sync?, do: GenServer.call(pid, :sync_now, 60_000)
          ets_table = GenServer.call(pid, :table, 5_000)
          read_ets_summaries(ets_table)

        is_atom(table) and :ets.whereis(table) != :undefined ->
          read_ets_summaries(table)

        is_binary(data_dir = Keyword.get(opts, :data_dir)) ->
          direct_scan_summaries(data_dir, opts)

        true ->
          []
      end

    Query.run(summaries, filters, opts)
  end

  @doc """
  Returns current index sync stats (`status`, `total`, `scanned`, `errors`).
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    case resolve_pid(server) do
      nil -> %{status: :offline, total: 0, cached: 0, dirty: 0, errors: 0}
      pid -> GenServer.call(pid, :stats, 5_000)
    end
  end

  @doc """
  Returns the full turn + tool waterfall for `session_id` without waking
  `H.Session.Server`.
  """
  @spec inspect_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_session(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    data_dir =
      case Keyword.get(opts, :data_dir) do
        dir when is_binary(dir) ->
          dir

        _ ->
          if pid = resolve_pid(Keyword.get(opts, :server, __MODULE__)) do
            GenServer.call(pid, :data_dir, 5_000)
          end
      end

    if is_binary(data_dir) do
      Scanner.inspect_session(data_dir, session_id, opts)
    else
      {:error, :missing_data_dir}
    end
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir) |> Path.expand()
    table_name = Keyword.get(opts, :table, @default_table)
    catalog_table = Keyword.get(opts, :catalog_table, :h_catalog)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    sync_interval_ms = Keyword.get(opts, :sync_interval_ms, @default_sync_interval_ms)
    auto_sync = Keyword.get(opts, :auto_sync, true)

    state_dir = Path.join([data_dir, "extensions_state", "analytics"])
    File.mkdir_p!(state_dir)
    index_path = Path.join(state_dir, "index.v1.etf")

    table =
      case :ets.whereis(table_name) do
        :undefined ->
          :ets.new(table_name, [:set, :public, :named_table, read_concurrency: true])

        existing ->
          :ets.delete_all_objects(existing)
          existing
      end

    cached = load_index_etf(index_path)

    Enum.each(cached, fn {sid, {fp, summary}} ->
      :ets.insert(table, {sid, fp, summary})
    end)

    state = %{
      data_dir: data_dir,
      table: table,
      table_name: table_name,
      catalog_table: catalog_table,
      index_path: index_path,
      batch_size: max(1, batch_size),
      sync_interval_ms: sync_interval_ms,
      dirty: MapSet.new(),
      last_sync_stats: %{
        status: :ready,
        total: map_size(cached),
        cached: map_size(cached),
        scanned: 0,
        pruned: 0,
        errors: 0,
        synced_at: nil
      }
    }

    if auto_sync do
      send(self(), :initial_sync)
    end

    {:ok, state}
  end

  @impl true
  def handle_cast({:mark_dirty, session_id}, state) do
    {:noreply, %{state | dirty: MapSet.put(state.dirty, session_id)}}
  end

  @impl true
  def handle_call(:table, _from, state) do
    {:reply, state.table, state}
  end

  def handle_call(:data_dir, _from, state) do
    {:reply, state.data_dir, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, Map.put(state.last_sync_stats, :dirty, MapSet.size(state.dirty)), state}
  end

  def handle_call(:sync_now, _from, state) do
    next_state = run_incremental_sync(state)
    {:reply, {:ok, next_state.last_sync_stats}, next_state}
  end

  @impl true
  def handle_info(:initial_sync, state) do
    next_state = run_incremental_sync(state)
    schedule_tick(next_state.sync_interval_ms)
    {:noreply, next_state}
  end

  def handle_info(:tick_sync, state) do
    next_state = run_incremental_sync(state)
    schedule_tick(next_state.sync_interval_ms)
    {:noreply, next_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Sync internals

  defp schedule_tick(ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :tick_sync, ms)
  end

  defp schedule_tick(_), do: :ok

  defp run_incremental_sync(state) do
    catalog_entries =
      Scanner.discover_catalog(state.data_dir, catalog_table: state.catalog_table)

    catalog_ids = MapSet.new(catalog_entries, & &1.session_id)
    pruned = prune_removed_entries(state.table, catalog_ids)

    {scanned, errors, remaining_dirty} =
      catalog_entries
      |> Enum.reduce({0, 0, state.dirty}, fn entry, {scan_acc, err_acc, dirty_acc} ->
        sid = entry.session_id
        fp = Scanner.fingerprint(state.data_dir, entry)
        dirty? = MapSet.member?(dirty_acc, sid)

        needs_scan? =
          dirty? or
            case :ets.lookup(state.table, sid) do
              [{^sid, ^fp, _summary}] -> false
              _ -> true
            end

        if needs_scan? do
          case Scanner.scan_session(state.data_dir, entry) do
            {:ok, summary} ->
              :ets.insert(state.table, {sid, fp, summary})
              {scan_acc + 1, err_acc, MapSet.delete(dirty_acc, sid)}

            {:error, _reason} ->
              {scan_acc, err_acc + 1, MapSet.delete(dirty_acc, sid)}
          end
        else
          {scan_acc, err_acc, dirty_acc}
        end
      end)

    if scanned > 0 or pruned > 0 do
      persist_index_etf(state.index_path, state.table)
    end

    stats = %{
      status: :ready,
      total: length(catalog_entries),
      cached: :ets.info(state.table, :size) || 0,
      scanned: scanned,
      pruned: pruned,
      errors: errors,
      synced_at: System.system_time(:millisecond)
    }

    %{state | dirty: remaining_dirty, last_sync_stats: stats}
  end

  defp prune_removed_entries(table, live_ids) do
    table
    |> :ets.tab2list()
    |> Enum.reduce(0, fn {sid, _fp, _summary}, acc ->
      if MapSet.member?(live_ids, sid) do
        acc
      else
        :ets.delete(table, sid)
        acc + 1
      end
    end)
  end

  defp read_ets_summaries(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_sid, _fp, summary} -> summary end)
  end

  defp direct_scan_summaries(data_dir, opts) do
    data_dir
    |> Scanner.discover_catalog(opts)
    |> Enum.reduce([], fn entry, acc ->
      case Scanner.scan_session(data_dir, entry) do
        {:ok, summary} -> [summary | acc]
        {:error, _} -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp load_index_etf(path) do
    case File.read(path) do
      {:ok, bin} ->
        try do
          case :erlang.binary_to_term(bin, [:safe]) do
            %{version: @index_version, entries: entries} when is_map(entries) -> entries
            _ -> %{}
          end
        rescue
          ArgumentError -> %{}
        end

      _ ->
        %{}
    end
  end

  defp persist_index_etf(path, table) do
    entries =
      table
      |> :ets.tab2list()
      |> Map.new(fn {sid, fp, summary} -> {sid, {fp, summary}} end)

    payload = :erlang.term_to_binary(%{version: @index_version, entries: entries})
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.dirname(path))

    with :ok <- File.write(tmp, payload),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      err ->
        File.rm(tmp)
        err
    end
  end

  defp resolve_pid(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid, else: nil)
  defp resolve_pid(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_pid({:via, _, _} = via), do: GenServer.whereis(via)
  defp resolve_pid(_), do: nil
end
