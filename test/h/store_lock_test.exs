defmodule H.StoreLockTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias H.StoreLock

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "h-store-lock-test-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm(StoreLock.socket_path(tmp_dir))
      File.rm_rf(tmp_dir)
    end)

    {:ok, data_dir: tmp_dir}
  end

  describe "socket_path/1" do
    test "returns a deterministic Unix socket path within macOS sun_path limits", %{
      data_dir: data_dir
    } do
      sock = StoreLock.socket_path(data_dir)
      assert byte_size(sock) <= 100
      assert String.starts_with?(sock, "/tmp/h-")
      assert String.ends_with?(sock, ".lock.sock")
      assert sock == StoreLock.socket_path(Path.join(data_dir, "../" <> Path.basename(data_dir)))
    end
  end

  describe "start_link/1" do
    test "creates data_dir (0700), lock.json (0600), and cleans up on stop", %{
      data_dir: data_dir
    } do
      assert {:ok, pid} = StoreLock.start_link(data_dir: data_dir)

      {:ok, dir_stat} = File.stat(data_dir)
      assert (dir_stat.mode &&& 0o777) == 0o700

      lock_path = Path.join(data_dir, "lock.json")
      {:ok, lock_stat} = File.stat(lock_path)
      assert (lock_stat.mode &&& 0o777) == 0o600

      lock_data = lock_path |> File.read!() |> JSON.decode!()
      assert lock_data["os_pid"] == System.pid()
      assert lock_data["sock_path"] == StoreLock.socket_path(data_dir)
      assert is_integer(lock_data["started_at"])

      refute File.exists?(Path.join(data_dir, ".claim"))
      assert File.exists?(StoreLock.socket_path(data_dir))

      assert :ok = GenServer.stop(pid)
      refute File.exists?(StoreLock.socket_path(data_dir))
      refute File.exists?(lock_path)
    end

    test "refuses a second in-VM lock contender even across repeated probes", %{
      data_dir: data_dir
    } do
      pid = start_supervised!({StoreLock, data_dir: data_dir})
      assert Process.alive?(pid)

      for _ <- 1..12 do
        assert {:error, :store_locked} = StoreLock.start_link(data_dir: data_dir)
      end
    end

    test "cleans up a stale .claim directory (> 10s) and acquires the lock", %{
      data_dir: data_dir
    } do
      File.mkdir_p!(data_dir)
      claim_dir = Path.join(data_dir, ".claim")
      File.mkdir!(claim_dir)
      stale_time = System.os_time(:second) - 30
      File.touch!(claim_dir, stale_time)

      assert {:ok, pid} = StoreLock.start_link(data_dir: data_dir)
      assert Process.alive?(pid)
      refute File.exists?(claim_dir)
      assert :ok = GenServer.stop(pid)
    end

    test "recovers immediately after SIGKILL of another BEAM OS process holding the lock", %{
      data_dir: data_dir
    } do
      ebin_dir = :code.which(StoreLock) |> List.to_string() |> Path.dirname()
      elixir_exe = System.find_executable("elixir")
      assert is_binary(elixir_exe)

      script = """
      {:ok, _pid} = H.StoreLock.start_link(data_dir: System.fetch_env!("H_LOCK_DIR"))
      IO.puts("LOCKED:" <> System.pid())
      receive do
        :never -> :ok
      end
      """

      port =
        Port.open({:spawn_executable, elixir_exe}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:line, 1024},
          {:args, ["-pa", ebin_dir, "-e", script]},
          {:env, [{~c"H_LOCK_DIR", String.to_charlist(data_dir)}]}
        ])

      os_pid = await_locked_pid(port)

      on_exit(fn ->
        if port_open?(port), do: Port.close(port)
        System.cmd("kill", ["-9", os_pid], stderr_to_stdout: true)
      end)

      assert {:error, :store_locked} = StoreLock.start_link(data_dir: data_dir)

      {_out, 0} = System.cmd("kill", ["-9", os_pid])
      assert_receive {^port, {:exit_status, _status}}, 5_000

      assert {:ok, pid} = StoreLock.start_link(data_dir: data_dir)
      assert Process.alive?(pid)
      assert :ok = GenServer.stop(pid)
    end
  end

  defp await_locked_pid(port) do
    receive do
      {^port, {:data, {:eol, "LOCKED:" <> os_pid}}} ->
        os_pid

      {^port, {:data, {:eol, other}}} ->
        flunk("unexpected child output before lock: #{inspect(other)}")

      {^port, {:exit_status, status}} ->
        flunk("child exited early with status #{status}")
    after
      5_000 ->
        flunk("timed out waiting for child H.StoreLock process")
    end
  end

  defp port_open?(port) do
    Port.info(port) != nil
  end
end
