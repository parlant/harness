defmodule H.Storage.File do
  @moduledoc """
  Durable local file backend implementing `H.Storage` with a CRC32-framed
  binary WAL (`commit.log`) and atomic JSON snapshots (`snapshot.<seq>.json`).
  """

  @behaviour H.Storage

  alias H.Storage.{Engine, File.Snapshot, File.Wal}

  defstruct [
    :dir,
    :fd,
    :sync,
    :snapshot_every,
    commits_since_snapshot: 0,
    seq: 0,
    next_id: 2,
    session_meta: %{},
    conversations: %{1 => %{id: 1, parent: nil, owner: :ownerless, entry_ids: []}},
    entries: %{},
    submissions: %{},
    tasks: %{},
    doc_histories: %{}
  ]

  @impl true
  def open(opts) when is_list(opts) do
    with {:ok, dir} <- fetch_dir(opts),
         {:ok, sync} <- fetch_sync(opts),
         {:ok, snapshot_every} <- fetch_snapshot_every(opts),
         :ok <- ensure_dir(dir),
         {:ok, base_state, snapshot_seq} <- Snapshot.load_highest(dir, %__MODULE__{}),
         log_path = Path.join(dir, "commit.log"),
         {:ok, fd} <- :file.open(log_path, [:raw, :binary, :read, :append]) do
      case Wal.replay(fd, base_state, snapshot_seq, sync) do
        {:ok, replayed_state, replayed_commits} ->
          session_meta =
            replayed_state.session_meta
            |> maybe_put_new(:session_id, Keyword.get(opts, :session_id))
            |> maybe_put_new(:cwd, Keyword.get(opts, :cwd))

          next_id =
            max(
              2,
              max(replayed_state.next_id, Engine.max_seen_id(replayed_state) + 1)
            )

          {:ok,
           %{
             replayed_state
             | dir: dir,
               fd: fd,
               sync: sync,
               snapshot_every: snapshot_every,
               commits_since_snapshot: replayed_commits,
               session_meta: session_meta,
               next_id: next_id
           }}

        {:error, reason} ->
          :file.close(fd)
          {:error, reason}
      end
    end
  end

  @doc """
  Opens a session directory in side-effect-free read-only mode without creating
  directories, holding open file descriptors, or truncating `commit.log`.
  """
  @spec open_read_only(keyword()) :: {:ok, H.Storage.t()} | {:error, term()}
  def open_read_only(opts) when is_list(opts) do
    with {:ok, dir} <- fetch_dir(opts) do
      if File.dir?(dir) do
        with {:ok, base_state, snapshot_seq} <- Snapshot.load_highest(dir, %__MODULE__{}),
             {:ok, replayed_state} <- replay_log_if_present(dir, base_state, snapshot_seq) do
          session_meta =
            replayed_state.session_meta
            |> maybe_put_new(:session_id, Keyword.get(opts, :session_id))
            |> maybe_put_new(:cwd, Keyword.get(opts, :cwd))

          next_id = max(2, max(replayed_state.next_id, Engine.max_seen_id(replayed_state) + 1))

          {:ok,
           {__MODULE__,
            %{replayed_state | dir: dir, fd: nil, session_meta: session_meta, next_id: next_id}}}
        end
      else
        session_meta =
          %{}
          |> maybe_put_new(:session_id, Keyword.get(opts, :session_id))
          |> maybe_put_new(:cwd, Keyword.get(opts, :cwd))

        {:ok, {__MODULE__, %__MODULE__{dir: dir, fd: nil, session_meta: session_meta}}}
      end
    end
  end

  @impl true
  def close(%__MODULE__{fd: nil}), do: :ok

  def close(%__MODULE__{fd: fd}) do
    case :file.close(fd) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  @impl true
  def mint_id(%__MODULE__{next_id: id} = state) do
    {:ok, id, %{state | next_id: id + 1}}
  end

  @impl true
  def commit(%__MODULE__{} = state, []), do: {:ok, %{stored: 0, seqs: [], refused: nil}, state}

  def commit(%__MODULE__{} = state, batches) when is_list(batches) do
    {provisional_state, accepted, refused} = Engine.run_batches(batches, state)
    seqs = Enum.map(accepted, fn {seq, _writes} -> seq end)
    result = %{stored: length(accepted), seqs: seqs, refused: refused}

    if accepted == [] do
      {:ok, result, state}
    else
      with :ok <- Wal.append_frame(state.fd, state.sync, provisional_state.next_id, accepted) do
        next_state = %{
          provisional_state
          | commits_since_snapshot: state.commits_since_snapshot + 1
        }

        if next_state.commits_since_snapshot >= next_state.snapshot_every do
          with {:ok, rotated_state} <- Snapshot.rotate(next_state) do
            {:ok, result, rotated_state}
          end
        else
          {:ok, result, next_state}
        end
      end
    end
  end

  @impl true
  def read_bootstrap(%__MODULE__{} = state) do
    {:ok, Engine.read_bootstrap(state), state}
  end

  @impl true
  def get_submission(%__MODULE__{} = state, request_id) when is_binary(request_id) do
    {:ok, Map.get(state.submissions, request_id), state}
  end

  @impl true
  def get_entry(%__MODULE__{} = state, entry_id) when is_integer(entry_id) and entry_id > 0 do
    {:ok, Map.get(state.entries, entry_id), state}
  end

  @impl true
  def get_doc(%__MODULE__{} = state, address, opts \\ []) do
    {:ok, Engine.get_doc(state, address, opts), state}
  end

  @impl true
  def scan_entries(%__MODULE__{} = state, query) when is_map(query) do
    with {:ok, page} <- Engine.scan_entries(state, query) do
      {:ok, page, state}
    end
  end

  # Option validation & directory setup

  defp fetch_dir(opts) do
    case Keyword.fetch(opts, :dir) do
      {:ok, dir} when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> {:error, :missing_dir}
    end
  end

  defp fetch_sync(opts) do
    sync = Keyword.get(opts, :sync, :datasync)

    if sync in [:datasync, :sync, :none] do
      {:ok, sync}
    else
      {:error, {:invalid_sync, sync}}
    end
  end

  defp fetch_snapshot_every(opts) do
    n = Keyword.get(opts, :snapshot_every, 200)

    if is_integer(n) and n > 0 do
      {:ok, n}
    else
      {:error, {:invalid_snapshot_every, n}}
    end
  end

  defp ensure_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- File.mkdir_p(dir) do
        File.chmod(dir, 0o700)
      end
    end
  end

  defp replay_log_if_present(dir, base_state, snapshot_seq) do
    log_path = Path.join(dir, "commit.log")

    case :file.open(log_path, [:raw, :binary, :read]) do
      {:ok, fd} ->
        try do
          Wal.replay_read_only(fd, base_state, snapshot_seq)
        after
          :file.close(fd)
        end

      {:error, :enoent} ->
        {:ok, base_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_new(map, _key, nil), do: map
  defp maybe_put_new(map, key, val), do: Map.put_new(map, key, val)
end
