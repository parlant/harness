defmodule H.WorkspaceLeaseTest do
  use ExUnit.Case, async: true

  alias H.WorkspaceLease

  setup do
    server = start_supervised!({WorkspaceLease, name: nil})
    {:ok, server: server}
  end

  describe "acquire/4" do
    test "grants a lease on an unheld workspace and allows same holder re-entry", %{
      server: server
    } do
      assert :ok = WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 1}, self())
      assert :ok = WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 1}, self())
    end

    test "canonicalizes cwd so equivalent paths contend on the same lease", %{server: server} do
      assert :ok = WorkspaceLease.acquire(server, "/tmp/work/a/../repo/", {:conv, 1}, self())

      assert {:error, {:workspace_busy, {:conv, 1}}} =
               WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 2}, self())
    end

    test "allows distinct canonical cwds concurrently", %{server: server} do
      assert :ok = WorkspaceLease.acquire(server, "/tmp/work/repo-a", {:conv, 1}, self())
      assert :ok = WorkspaceLease.acquire(server, "/tmp/work/repo-b", {:conv, 2}, self())
    end

    test "isolates identical cwds across different env_ids", %{server: server} do
      assert :ok =
               WorkspaceLease.acquire(server, {"host", "/workspace/app"}, {:conv, 1}, self())

      assert :ok =
               WorkspaceLease.acquire(server, {"vm-1", "/workspace/app"}, {:conv, 2}, self())

      assert :ok =
               WorkspaceLease.acquire(server, {"vm-2", "/workspace/app"}, {:conv, 3}, self())
    end

    test "contends on same non-host env_id and canonicalizes trailing slashes without host Path.expand",
         %{server: server} do
      assert :ok =
               WorkspaceLease.acquire(server, {"vm-1", "/workspace/app/"}, {:conv, 1}, self())

      assert {:error, {:workspace_busy, {:conv, 1}}} =
               WorkspaceLease.acquire(server, {"vm-1", "/workspace/app"}, {:conv, 2}, self())

      # Non-host environments do not collapse ".." using local Path.expand/1
      assert :ok =
               WorkspaceLease.acquire(
                 server,
                 {"vm-1", "/workspace/a/../app"},
                 {:conv, 3},
                 self()
               )

      assert :ok = WorkspaceLease.acquire(server, {"vm-1", "/"}, {:conv, 4}, self())

      assert {:error, {:workspace_busy, {:conv, 4}}} =
               WorkspaceLease.acquire(server, {"vm-1", "/"}, {:conv, 5}, self())
    end

    test "treats bare cwd string and {\"host\", cwd} as the exact same lease", %{server: server} do
      assert :ok = WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 1}, self())

      assert {:error, {:workspace_busy, {:conv, 1}}} =
               WorkspaceLease.acquire(
                 server,
                 {"host", "/tmp/work/a/../repo/"},
                 {:conv, 2},
                 self()
               )
    end

    test "auto-releases non-host {env_id, cwd} lease on holder :DOWN", %{server: server} do
      parent = self()

      holder =
        spawn(fn ->
          send(parent, {:ready, self()})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:ready, ^holder}
      assert :ok = WorkspaceLease.acquire(server, {"vm-1", "/workspace/app"}, {:conv, 1}, holder)

      assert {:error, {:workspace_busy, {:conv, 1}}} =
               WorkspaceLease.acquire(server, {"vm-1", "/workspace/app"}, {:conv, 2}, self())

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

      assert :ok = WorkspaceLease.acquire(server, {"vm-1", "/workspace/app"}, {:conv, 2}, self())
    end

    test "automatically releases the lease when the holder process exits", %{server: server} do
      parent = self()

      holder =
        spawn(fn ->
          send(parent, {:ready, self()})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:ready, ^holder}
      assert :ok = WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 1}, holder)

      assert {:error, {:workspace_busy, {:conv, 1}}} =
               WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 2}, self())

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

      assert :ok = WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 2}, self())
    end

    test "replaces monitor cleanly when same holder_key re-acquires from a new pid", %{
      server: server
    } do
      holder1 = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(holder1, :kill) end)

      assert :ok = WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 1}, holder1)
      assert :ok = WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 1}, self())

      ref = Process.monitor(holder1)
      Process.exit(holder1, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder1, :killed}

      # Old pid dying must not release the new pid's lease for the same holder_key.
      assert {:error, {:workspace_busy, {:conv, 1}}} =
               WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 2}, self())
    end
  end

  describe "release/3" do
    test "frees the lease only when called by the current holder_key", %{server: server} do
      assert :ok = WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 1}, self())

      assert :ok = WorkspaceLease.release(server, "/tmp/work/repo", {:conv, 2})

      assert {:error, {:workspace_busy, {:conv, 1}}} =
               WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 2}, self())

      assert :ok = WorkspaceLease.release(server, "/tmp/work/repo/", {:conv, 1})
      assert :ok = WorkspaceLease.acquire(server, "/tmp/work/repo", {:conv, 2}, self())
    end

    test "releases {env_id, cwd} across normalized forms without affecting other envs", %{
      server: server
    } do
      assert :ok = WorkspaceLease.acquire(server, {"host", "/workspace/app"}, {:conv, 1}, self())
      assert :ok = WorkspaceLease.acquire(server, {"vm-1", "/workspace/app/"}, {:conv, 2}, self())

      assert :ok = WorkspaceLease.release(server, {"vm-1", "/workspace/app"}, {:conv, 2})
      assert :ok = WorkspaceLease.acquire(server, {"vm-1", "/workspace/app"}, {:conv, 3}, self())

      # Host lease must still be held.
      assert {:error, {:workspace_busy, {:conv, 1}}} =
               WorkspaceLease.acquire(server, "/workspace/app", {:conv, 4}, self())

      assert :ok = WorkspaceLease.release(server, "/workspace/app", {:conv, 1})
      assert :ok = WorkspaceLease.acquire(server, {"host", "/workspace/app"}, {:conv, 4}, self())
    end
  end
end
