defmodule H.DaemonMaintenanceTest do
  use ExUnit.Case, async: false

  alias H.{Daemon, StoreLock}
  alias H.Daemon.{Instance, Maintenance}
  alias H.Provider.Fake

  @tag :tmp_dir
  test "does not approve shutdown until accepted work finishes; fences later commands", %{
    tmp_dir: dir
  } do
    data = Path.join(dir, "store")
    cwd = Path.join(dir, "work")
    File.mkdir!(cwd)
    on_exit(fn -> File.rm(StoreLock.socket_path(data)) end)
    gate = make_ref()

    fake =
      start_supervised!(
        {Fake,
         script: [{:gate, [], self(), gate, %{content: [%{type: "text", text: "Finished"}]}}]}
      )

    start_supervised!(
      {Instance,
       data_dir: data,
       provider: Fake,
       provider_config: %{server: fake},
       default_model: "fake:coder",
       shutdown_owner: self()}
    )

    opts = Daemon.instance_options()
    assert {:ok, _} = Daemon.create_session(%{"session_id" => "idle-guard", "cwd" => cwd}, opts)
    assert {:ok, _} = Daemon.execute_command("idle-guard", submit("original"), opts)
    assert_receive {:gate_entered, ^gate, worker}, 2_000
    assert {:error, :daemon_busy} = Maintenance.stop_if_idle(opts)
    assert Process.alive?(worker)
    send(worker, {:release, gate})
    await_shutdown(opts, 100)

    assert {:error, :daemon_draining} =
             Daemon.execute_command("idle-guard", submit("later"), opts)

    assert {:error, :daemon_draining} = Daemon.create_session(%{"cwd" => cwd}, opts)
    assert {:ok, %{items: entries}} = Daemon.scan_entries("idle-guard", "1", %{}, opts)
    assert Enum.any?(entries, &(&1.kind == "assistant"))
    assert Fake.requests(fake) |> length() == 1
  end

  defp submit(id) do
    %{
      "version" => 1,
      "request_id" => id,
      "command" => "submit",
      "conversation_id" => "1",
      "args" => %{"type" => "input", "content" => "Build candidate"}
    }
  end

  defp await_shutdown(opts, attempts) do
    case Maintenance.stop_if_idle(opts) do
      {:ok, %{state: "stopping"}} ->
        :ok

      {:error, :daemon_busy} when attempts > 0 ->
        Process.sleep(10)
        await_shutdown(opts, attempts - 1)

      other ->
        flunk("expected idle shutdown, got #{inspect(other)}")
    end
  end
end
