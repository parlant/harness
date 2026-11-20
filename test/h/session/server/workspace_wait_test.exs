defmodule H.Session.Server.WorkspaceWaitTest do
  use ExUnit.Case, async: true

  alias H.{Task, WorkspaceLease}
  alias H.Session.Server.WorkspaceWait

  defmodule FailedStorage do
    def commit(_state, _batches), do: {:error, :eio}
  end

  test "failed wait checkpoint cannot execute when a grant races the storage failure" do
    lease = start_supervised!({WorkspaceLease, name: nil})
    cwd = "/tmp/workspace-wait"
    :ok = WorkspaceLease.acquire(lease, {"host", cwd}, {"holder", 1}, self())

    task =
      Task.new(%{
        id: 1,
        kind: "user_shell",
        owner: {:conversation, 1},
        checkpoint: %{"conversation_id" => 1}
      })

    state = %{
      session_id: "waiter",
      env_id: "host",
      cwd: cwd,
      workspace_lease: lease,
      held_leases: MapSet.new(),
      workspace_waits: %{},
      storage_failed: false,
      tasks: %{1 => task},
      docs: %{1 => %{"live" => %{"user_shell" => %{"status" => "pending"}}}},
      store: {FailedStorage, nil}
    }

    {:waiting, state} = WorkspaceWait.acquire(1, task, state)
    assert state.storage_failed
    assert_receive {:stop_storage_failed, :eio}
    token = state.workspace_waits[1].token
    :ok = WorkspaceLease.release(lease, {"host", cwd}, {"holder", 1})
    assert_receive {:workspace_lease_granted, ^token}
    assert {[], state} = WorkspaceWait.granted(token, state)
    assert state.workspace_waits == %{}
    assert state.held_leases == MapSet.new()
    assert :ok = WorkspaceLease.acquire(lease, {"host", cwd}, {"probe", 1}, self())
  end
end
