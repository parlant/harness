defmodule H.StoreLock do
  @moduledoc """
  OS-level single-daemon ownership lock for `data_dir`.

  Uses a short-lived `.claim` spin directory to serialize lock acquisition,
  then binds a Unix domain socket under `/tmp` (kept within macOS `sun_path`
  limits) and writes `<data_dir>/lock.json`. Surviving a `SIGKILL` of a prior
  daemon triggers `:econnrefused` on the stale socket probe, allowing immediate
  takeover without manual cleanup.
  """

  use GenServer

  @claim_timeout_ms 1_000
  @claim_retry_ms 10
  @claim_stale_seconds 10
  @connect_timeout_ms 100

  @doc """
  Starts the store lock process for `:data_dir`.

  Returns `{:error, :store_locked}` if another live OS process holds the lock.
  Accepts an optional `:name` to register the `GenServer`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    _data_dir = Keyword.fetch!(opts, :data_dir)
    gen_opts = if name = Keyword.get(opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, [{:parent, self()} | opts], gen_opts)
  end

  @doc """
  Computes the deterministic Unix domain socket path (`<= 100` bytes) for `data_dir`.
  """
  @spec socket_path(String.t()) :: String.t()
  def socket_path(data_dir) when is_binary(data_dir) do
    expanded = Path.expand(data_dir)

    hash =
      :crypto.hash(:sha256, expanded)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "/tmp/h-#{current_uid()}-#{hash}.lock.sock"
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir) |> Path.expand()
    File.mkdir_p!(data_dir)
    File.chmod!(data_dir, 0o700)

    sock_path = socket_path(data_dir)
    claim_dir = Path.join(data_dir, ".claim")
    lock_path = Path.join(data_dir, "lock.json")

    parent = Keyword.get(opts, :parent)

    case acquire_claim(claim_dir) do
      :ok ->
        try do
          probe_and_bind(sock_path, lock_path, data_dir, parent)
        after
          File.rmdir(claim_dir)
        end

      {:error, reason} ->
        if parent, do: Process.unlink(parent)
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen_socket)
    File.rm(state.sock_path)
    File.rm(state.lock_path)
    :ok
  end

  defp probe_and_bind(sock_path, lock_path, data_dir, parent) do
    case :gen_tcp.connect({:local, sock_path}, 0, [:binary, active: false], @connect_timeout_ms) do
      {:ok, conn} ->
        :gen_tcp.close(conn)
        if parent, do: Process.unlink(parent)
        {:stop, :store_locked}

      {:error, reason} when reason in [:enoent, :econnrefused] ->
        File.rm(sock_path)

        case :gen_tcp.listen(0, [:binary, {:ip, {:local, sock_path}}, active: false, backlog: 128]) do
          {:ok, listen_socket} ->
            _ = File.chmod(sock_path, 0o600)
            write_lock_json!(lock_path, sock_path)
            acceptor = spawn_acceptor(listen_socket)

            {:ok,
             %{
               data_dir: data_dir,
               sock_path: sock_path,
               lock_path: lock_path,
               listen_socket: listen_socket,
               acceptor: acceptor
             }}

          {:error, listen_err} ->
            if parent, do: Process.unlink(parent)
            {:stop, {:listen_failed, listen_err}}
        end

      {:error, err} ->
        if parent, do: Process.unlink(parent)
        {:stop, {:probe_failed, err}}
    end
  end

  # Drain incoming lock probes so macOS/BSD accept queues never fill and
  # return false :econnrefused to future contenders while the owner is alive.
  defp spawn_acceptor(listen_socket) do
    spawn_link(fn -> accept_loop(listen_socket) end)
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, conn} ->
        :gen_tcp.close(conn)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, _other} ->
        :ok
    end
  end

  defp acquire_claim(claim_dir) do
    deadline = System.monotonic_time(:millisecond) + @claim_timeout_ms
    do_acquire_claim(claim_dir, deadline)
  end

  defp do_acquire_claim(claim_dir, deadline) do
    case File.mkdir(claim_dir) do
      :ok ->
        :ok

      {:error, :eexist} ->
        if stale_claim?(claim_dir) do
          _ = File.rmdir(claim_dir)
          do_acquire_claim(claim_dir, deadline)
        else
          if System.monotonic_time(:millisecond) >= deadline do
            {:error, :store_locked}
          else
            Process.sleep(@claim_retry_ms)
            do_acquire_claim(claim_dir, deadline)
          end
        end

      {:error, reason} ->
        {:error, {:claim_failed, reason}}
    end
  end

  defp stale_claim?(claim_dir) do
    case File.stat(claim_dir, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        System.os_time(:second) - mtime > @claim_stale_seconds

      {:error, _} ->
        false
    end
  end

  defp write_lock_json!(lock_path, sock_path) do
    payload =
      %{
        "os_pid" => System.pid(),
        "sock_path" => sock_path,
        "started_at" => System.system_time(:millisecond)
      }
      |> JSON.encode_to_iodata!()
      |> IO.iodata_to_binary()

    tmp_path = lock_path <> ".tmp"
    File.write!(tmp_path, payload)
    File.chmod!(tmp_path, 0o600)
    File.rename!(tmp_path, lock_path)
  end

  defp current_uid do
    case :os.cmd(~c"id -u") |> List.to_string() |> String.trim() do
      "" -> System.get_env("UID") || "0"
      uid -> uid
    end
  end
end
