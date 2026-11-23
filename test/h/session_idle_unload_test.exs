defmodule H.SessionIdleUnloadTest do
  use ExUnit.Case, async: true

  alias H.{Auth, Catalog, Daemon, WorkspaceLease}
  alias H.Provider.Fake
  alias H.Session.Server

  @sid "idle-lifecycle"
  @root "1"
  @idle_ms 400
  @wait_ms 5_000

  test "catalog announces unload without a disk change, and detail wakes the saved session" do
    %{opts: opts, cwd: cwd} = start_stack()
    %{session: %{loaded: true}} = create_session(cwd, opts)
    old = session_pid!(opts)
    ref = Process.monitor(old)
    note = submit("note", "write", "Keep this history")
    assert {:ok, receipt} = Daemon.execute_command(@sid, note, opts)
    assert {:ok, %{items: [entry]}} = Daemon.scan_entries(@sid, @root, %{}, opts)

    catalog_path = Path.join(opts[:data_dir], "catalog/sessions.json")
    catalog_bytes = File.read!(catalog_path)
    catalog_inode = File.stat!(catalog_path).inode
    assert {:ok, catalog_entry} = Catalog.get_session(@sid, opts[:catalog_table])
    assert {:ok, {:snapshot, loaded_seq, bin}} = Daemon.subscribe_sessions(self(), opts)
    assert [%{"session_id" => @sid, "loaded" => true}] = JSON.decode!(bin)["sessions"]

    assert_receive {:DOWN, ^ref, :process, ^old, _}, @wait_ms
    assert_receive {:catalog_frame, unloaded_seq, bin}, @wait_ms
    assert unloaded_seq == loaded_seq + 1

    assert %{"seq" => ^unloaded_seq, "type" => "upsert", "session" => unloaded} =
             JSON.decode!(bin)

    assert %{
             "session_id" => @sid,
             "loaded" => false,
             "status" => "ok",
             "active" => false,
             "archived" => false,
             "attention" => "idle"
           } = unloaded

    await_unloaded(opts)

    assert {:ok, ^catalog_entry} = Catalog.get_session(@sid, opts[:catalog_table])

    assert [%{session_id: @sid, loaded: false, title: "Saved session"}] =
             Daemon.list_sessions(opts)

    assert {:ok, {:snapshot, ^unloaded_seq, bin}} = Daemon.subscribe_sessions(self(), opts)
    assert [^unloaded] = JSON.decode!(bin)["sessions"]
    assert [] = DynamicSupervisor.which_children(opts[:runtime_sup])
    assert File.read!(catalog_path) == catalog_bytes
    assert File.stat!(catalog_path).inode == catalog_inode

    assert {:ok, %{session: %{loaded: true, title: "Saved session"}, tasks: []}} =
             Daemon.get_session_detail(@sid, opts)

    refute session_pid!(opts) == old
    assert_receive {:catalog_frame, reloaded_seq, bin}, @wait_ms
    assert reloaded_seq == unloaded_seq + 1

    assert %{"type" => "upsert", "session" => %{"session_id" => @sid, "loaded" => true}} =
             JSON.decode!(bin)

    assert {:ok, ^receipt} = Daemon.execute_command(@sid, note, opts)
    assert {:ok, %{items: [^entry]}} = Daemon.scan_entries(@sid, @root, %{}, opts)
    assert File.read!(catalog_path) == catalog_bytes
  end

  test "an SSE request wakes a cold session and its root cursor survives a branch advancing and unloading" do
    %{opts: opts, cwd: cwd} = start_stack()
    {url, token} = start_http(opts)
    create_session(cwd, opts)
    await_unloaded(opts)

    response =
      Req.get!(url <> "/api/v1/sessions/#{@sid}/conversations/#{@root}/events",
        headers: [{"authorization", "Bearer #{token}"}],
        into: :self,
        retry: false,
        receive_timeout: 10_000
      )

    try do
      assert response.status == 200

      {{"snapshot", initial_seq, %{"seq" => initial_seq, "entries" => []}}, buffer} =
        next_sse_frame(response, "")

      old = session_pid!(opts)
      root_topic = {:conversation, @sid, 1}
      assert [{connection, _}] = Registry.lookup(opts[:pubsub], root_topic)

      assert {:ok, %{seq: root_seq}} =
               Daemon.execute_command(@sid, submit("root-note", "write", "Root note"), opts)

      {{"commit", ^root_seq, root_frame}, buffer} = next_sse_frame(response, buffer)

      assert %{"prev_seq" => ^initial_seq, "appended_entries" => [%{"id" => entry_id}]} =
               root_frame

      assert {:ok, %{conversation_id: child, seq: fork_seq}} =
               Daemon.execute_command(
                 @sid,
                 command("fork", "fork", @root, %{"at_entry_id" => entry_id}),
                 opts
               )

      assert {:ok, {:snapshot, ^fork_seq, _}} =
               Daemon.subscribe_conversation(@sid, child, self(), nil, opts)

      assert {:ok, %{seq: child_seq}} =
               Daemon.execute_command(
                 @sid,
                 submit("child-note", "write", "Child note", child),
                 opts
               )

      assert_receive {:commit_frame, ^child_seq, bin}, @wait_ms
      assert %{"conversation_id" => ^child, "prev_seq" => ^fork_seq} = JSON.decode!(bin)
      assert child_seq > root_seq
      await_unloaded(opts)
      assert Process.alive?(connection)
      assert [{^connection, _}] = Registry.lookup(opts[:pubsub], root_topic)

      assert {self(), nil} in Registry.lookup(
               opts[:pubsub],
               {:conversation, @sid, String.to_integer(child)}
             )

      # The root stream cursor is not a valid session-wide rename guard. The last
      # pre-unload *session* seq is valid for the first new write despite reopen metadata.
      assert {:error, {:conflict, "expected_seq mismatch"}} =
               Daemon.execute_command(@sid, rename("stale-root", "Wrong", root_seq), opts)

      refute session_pid!(opts) == old
      assert [%{title: "Saved session"}] = Daemon.list_sessions(opts)
      rename = rename("rename", "After wake", child_seq)
      assert {:ok, %{seq: rename_seq} = receipt} = Daemon.execute_command(@sid, rename, opts)
      assert rename_seq > child_seq
      {{"commit", ^rename_seq, frame}, _buffer} = next_sse_frame(response, buffer)
      assert %{"seq" => ^rename_seq, "prev_seq" => ^root_seq, "conversation_id" => @root} = frame
      assert [{^connection, _}] = Registry.lookup(opts[:pubsub], root_topic)

      assert {:error, {:conflict, "expected_seq mismatch"}} =
               Daemon.execute_command(@sid, rename("reuse-old-seq", "Wrong", child_seq), opts)

      assert {:ok, ^receipt} = Daemon.execute_command(@sid, rename, opts)
      assert [%{title: "After wake"}] = Daemon.list_sessions(opts)

      assert {:ok, %{seq: new_child_seq}} =
               Daemon.execute_command(
                 @sid,
                 submit("child-after", "write", "Still here", child),
                 opts
               )

      assert_receive {:commit_frame, ^new_child_seq, bin}, @wait_ms
      assert %{"conversation_id" => ^child, "prev_seq" => ^child_seq} = JSON.decode!(bin)
    after
      Req.cancel_async_response(response)
    end
  end

  test "a command queued behind the idle timeout reaches the replacement exactly once" do
    %{opts: opts, cwd: cwd} = start_stack()
    create_session(cwd, opts)
    old = session_pid!(opts)
    down = Process.monitor(old)
    note = submit("racing-note", "write", "Only once")

    :ok = :sys.suspend(old)

    caller =
      try do
        eventually(fn ->
          {:messages, messages} = Process.info(old, :messages)
          Enum.any?(messages, &match?({:idle_timeout, _}, &1))
        end)

        caller = Task.async(fn -> Daemon.execute_command(@sid, note, opts) end)

        eventually(fn ->
          {:messages, messages} = Process.info(old, :messages)

          Enum.any?(
            messages,
            &match?({:"$gen_call", _, {:command, %{request_id: "racing-note"}}}, &1)
          )
        end)

        caller
      after
        :ok = :sys.resume(old)
      end

    assert_receive {:DOWN, ^down, :process, ^old, _}, @wait_ms
    assert {:ok, %{status: "done"} = receipt} = Task.await(caller, @wait_ms)
    refute session_pid!(opts) == old
    assert {:ok, ^receipt} = Daemon.execute_command(@sid, note, opts)

    assert {:ok, %{items: [%{kind: "user", data: %{"content" => [%{"text" => "Only once"}]}}]}} =
             Daemon.scan_entries(@sid, @root, %{}, opts)
  end

  test "concurrent cold openers share one runtime and one durable receipt" do
    %{opts: opts, cwd: cwd} = start_stack()
    create_session(cwd, opts)
    await_unloaded(opts)
    note = submit("same-note", "write", "Concurrent note")
    parent = self()
    open = make_ref()

    callers =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            ^open -> Daemon.execute_command(@sid, note, opts)
          end
        end)
      end

    for %Task{pid: pid} <- callers, do: assert_receive({:ready, ^pid}, @wait_ms)
    for %Task{pid: pid} <- callers, do: send(pid, open)

    assert [{:ok, %{status: "done"}} = result | _] = results = Task.await_many(callers, @wait_ms)
    assert results == List.duplicate(result, length(callers))

    assert [{:undefined, _, :supervisor, [H.Session.Supervisor]}] =
             DynamicSupervisor.which_children(opts[:runtime_sup])

    assert {:ok, %{items: [%{data: %{"content" => [%{"text" => "Concurrent note"}]}}]}} =
             Daemon.scan_entries(@sid, @root, %{}, opts)
  end

  test "neither a running generation nor its sleeping retry is unloaded" do
    first = make_ref()
    retry_gate = make_ref()

    %{opts: opts, cwd: cwd, fake: fake} =
      start_stack(
        [
          {:gate, self(), first},
          {:gate, [], self(), retry_gate, answer("Recovered")}
        ],
        retry_backoff_ms: 1_800
      )

    create_session(cwd, opts)
    server = session_pid!(opts)
    down = Process.monitor(server)
    assert {:ok, _} = Daemon.execute_command(@sid, submit("retry", "input", "Try this"), opts)
    assert_receive {:gate_entered, ^first, worker}, @wait_ms
    assert_stays_loaded(opts, server, down)
    assert Process.alive?(worker)

    send(
      worker,
      {:release, first, {:error, %{code: "http_429", message: "Try again", retryable: true}}}
    )

    eventually(fn ->
      match?([%{attention: "retrying", active: true}], Daemon.list_sessions(opts))
    end)

    assert {:ok, %{tasks: tasks}} = Daemon.get_session_detail(@sid, opts)
    assert Enum.any?(tasks, &match?(%{kind: "generation", status: "sleeping"}, &1))
    assert_stays_loaded(opts, server, down)
    assert [%{attention: "retrying", loaded: true, active: true}] = Daemon.list_sessions(opts)
    assert length(Fake.requests(fake)) == 1

    assert_receive {:gate_entered, ^retry_gate, worker}, @wait_ms
    assert session_pid!(opts) == server
    send(worker, {:release, retry_gate})
    assert_receive {:DOWN, ^down, :process, ^server, _}, @wait_ms
    await_unloaded(opts)

    assert {:ok, %{status: "done", answer_text: "Recovered"}} =
             Daemon.get_submission(@sid, "retry", opts)

    assert length(Fake.requests(fake)) == 2
  end

  test "a tool parked on a workspace lease stays loaded without a worker" do
    %{opts: opts, cwd: cwd} =
      start_stack([
        tool_call("write", %{"path" => "note.txt", "content" => "from the tool"}),
        {:reply, [], answer("Written")}
      ])

    create_session(cwd, opts)

    assert {:ok, canonical_cwd} =
             H.ExecutionEnv.canonical_path(H.ExecutionEnv.Host.new(cwd), cwd)

    key = {"host", canonical_cwd}
    holder = {"test-lease-holder", 1}
    assert :ok = WorkspaceLease.acquire(opts[:workspace_lease], key, holder, self())
    server = session_pid!(opts)
    down = Process.monitor(server)
    assert {:ok, _} = Daemon.execute_command(@sid, submit("tool", "input", "Write a note"), opts)

    eventually(fn ->
      {:ok, {:snapshot, _, bin}} = Server.snapshot_or_replay(server, 1, nil)

      get_in(JSON.decode!(bin), ["docs", "live", "workspace_wait", "holder_session_id"]) ==
        "test-lease-holder"
    end)

    assert_no_workers(opts)
    assert_stays_loaded(opts, server, down)
    refute File.exists?(Path.join(cwd, "note.txt"))

    assert :ok = WorkspaceLease.release(opts[:workspace_lease], key, holder)
    assert_receive {:DOWN, ^down, :process, ^server, _}, @wait_ms
    await_unloaded(opts)
    assert File.read!(Path.join(cwd, "note.txt")) == "from the tool"

    assert {:ok, %{status: "done", answer_text: "Written"}} =
             Daemon.get_submission(@sid, "tool", opts)
  end

  test "a parent parked on its subagent stays loaded without a worker" do
    gate = make_ref()

    %{opts: opts, cwd: cwd} =
      start_stack([
        tool_call("subagent", %{"prompt" => "Inspect the workspace", "read_only" => true}),
        {:gate, [], self(), gate, answer("Child finished")},
        {:reply, [], answer("Parent finished")}
      ])

    create_session(cwd, opts)
    parent = session_pid!(opts)
    down = Process.monitor(parent)
    assert {:ok, _} = Daemon.execute_command(@sid, submit("delegate", "input", "Delegate"), opts)
    assert_receive {:gate_entered, ^gate, child_worker}, @wait_ms

    eventually(fn ->
      {:ok, %{tasks: tasks}} = Server.get_detail(parent)
      Enum.any?(tasks, &match?(%{kind: "tool_call", status: "waiting"}, &1))
    end)

    assert_no_workers(opts)
    assert_stays_loaded(opts, parent, down)

    send(child_worker, {:release, gate})
    assert_receive {:DOWN, ^down, :process, ^parent, _}, @wait_ms
    await_unloaded(opts)

    assert {:ok, %{status: "done", answer_text: "Parent finished"}} =
             Daemon.get_submission(@sid, "delegate", opts)
  end

  test "a removed local workspace still opens after unloading" do
    %{opts: opts, cwd: cwd, fake: fake} = start_stack()
    create_session(cwd, opts)
    assert {:ok, _} = Daemon.execute_command(@sid, submit("saved", "write", "Keep this"), opts)
    await_unloaded(opts)
    File.rmdir!(cwd)

    assert {:ok, %{session: %{loaded: true, archived: false, cwd_exists: false}}} =
             Daemon.get_session_detail(@sid, opts)

    assert {:ok, %{items: [%{kind: "user", data: %{"content" => [%{"text" => "Keep this"}]}}]}} =
             Daemon.scan_entries(@sid, @root, %{}, opts)

    assert [] = Fake.requests(fake)
  end

  test "a second idle cycle before any mutation preserves the original guard" do
    %{opts: opts, cwd: cwd} = start_stack()
    %{seq: seq} = create_session(cwd, opts)
    await_unloaded(opts)

    assert {:ok, %{seq: ^seq}} =
             Daemon.create_session(%{"session_id" => @sid, "cwd" => cwd}, opts)

    assert {:ok, {:replay, []}} = Daemon.subscribe_conversation(@sid, @root, self(), seq, opts)
    await_unloaded(opts)

    assert {:ok, %{seq: written}} =
             Daemon.execute_command(@sid, rename("new", "Same cursor", seq), opts)

    assert_receive {:commit_frame, ^written, bin}, @wait_ms
    assert %{"prev_seq" => ^seq} = JSON.decode!(bin)
  end

  test "infinity disables idle unloading for a supervised file session" do
    %{opts: opts, cwd: cwd} = start_stack([], idle_session_timeout_ms: :infinity)
    create_session(cwd, opts)
    server = session_pid!(opts)
    assert_stays_loaded(opts, server, Process.monitor(server))
  end

  test "memory-backed and standalone file sessions do not idle unload" do
    %{opts: opts, cwd: cwd} = start_stack([], storage_mod: H.Storage.Memory)
    create_session(cwd, opts)
    memory = session_pid!(opts)
    memory_ref = Process.monitor(memory)
    task_sup = start_supervised!(Task.Supervisor)

    file =
      start_supervised!(
        {Server,
         Keyword.merge(opts,
           session_id: "standalone",
           cwd: cwd,
           storage_mod: H.Storage.File,
           task_sup: task_sup,
           catalog: nil
         )}
      )

    file_ref = Process.monitor(file)
    assert_stays_loaded(opts, memory, memory_ref)
    refute_received {:DOWN, ^file_ref, :process, ^file, _}
    assert {:ok, _} = Server.get_seq(file)
  end

  defp start_stack(script \\ [], overrides \\ []) do
    id = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "h-idle-unload-#{id}")
    data_dir = Path.join(root, "data")
    cwd = Path.join(root, "work")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(root) end)

    registry = :"H.Idle.Registry.#{id}"
    pubsub = :"H.Idle.PubSub.#{id}"
    table = :"h_idle_catalog_#{id}"
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})

    catalog =
      start_supervised!(
        {Catalog, data_dir: data_dir, name: nil, table: table, registry: registry, pubsub: pubsub}
      )

    lease = start_supervised!({WorkspaceLease, name: nil})
    runtime_sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    fake = start_supervised!({Fake, script: script})

    opts =
      Keyword.merge(
        [
          registry: registry,
          pubsub: pubsub,
          catalog: catalog,
          catalog_table: table,
          workspace_lease: lease,
          runtime_sup: runtime_sup,
          data_dir: data_dir,
          provider: Fake,
          provider_config: %{server: fake},
          storage_mod: H.Storage.File,
          storage_opts: [sync: :none, snapshot_every: 2],
          default_model: "fake:chat",
          idle_session_timeout_ms: @idle_ms
        ],
        overrides
      )

    %{opts: opts, cwd: cwd, fake: fake}
  end

  defp start_http(opts) do
    assert {:ok, _} = Application.ensure_all_started(:bandit)
    assert {:ok, _} = Application.ensure_all_started(:req)
    table = :"h_idle_auth_#{System.unique_integer([:positive])}"

    auth =
      start_supervised!(
        {Auth, data_dir: Path.join(opts[:data_dir], "auth"), name: nil, table: table}
      )

    bandit =
      start_supervised!(
        {Bandit,
         plug: {H.HTTP.Router, auth_server: auth, auth_table: table, daemon_opts: opts},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [shutdown_timeout: 100]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {"http://127.0.0.1:#{port}", Auth.owner_token(table)}
  end

  defp next_sse_frame(%{body: %{ref: ref}} = response, buffer) do
    case :binary.split(buffer, "\n\n") do
      [frame, rest] ->
        ["id: " <> id, "event: " <> event, "data: " <> json] = String.split(frame, "\n", parts: 3)
        {{event, String.to_integer(id), JSON.decode!(json)}, rest}

      [_partial] ->
        receive do
          {^ref, _} = msg ->
            case Req.parse_message(response, msg) do
              {:ok, [data: chunk]} -> next_sse_frame(response, buffer <> chunk)
              other -> flunk("SSE ended before the next frame: #{inspect(other)}")
            end
        after
          @wait_ms -> flunk("timed out waiting for an SSE frame")
        end
    end
  end

  defp create_session(cwd, opts) do
    assert {:ok, created} =
             Daemon.create_session(
               %{"session_id" => @sid, "cwd" => cwd, "title" => "Saved session"},
               opts
             )

    created
  end

  defp command(id, kind, cid, args) do
    %{
      "version" => 1,
      "request_id" => id,
      "command" => kind,
      "conversation_id" => cid,
      "args" => args
    }
  end

  defp submit(id, type, text, cid \\ @root),
    do: command(id, "submit", cid, %{"type" => type, "content" => text})

  defp rename(id, title, seq),
    do: command(id, "rename", @root, %{"title" => title, "expected_seq" => seq})

  defp answer(text), do: %{content: [%{type: "text", text: text}]}

  defp tool_call(name, args) do
    {:reply, [],
     %{
       content: [],
       finish_reason: "tool_calls",
       tool_calls: [%{id: "call-1", name: name, arguments: args}]
     }}
  end

  defp session_pid!(opts) do
    assert [{pid, _}] = Registry.lookup(opts[:registry], {:session, @sid})
    pid
  end

  defp await_unloaded(opts) do
    eventually(fn ->
      Enum.all?([:session, :session_tasks, :session_supervisor], fn key ->
        Registry.lookup(opts[:registry], {key, @sid}) == []
      end)
    end)
  end

  defp assert_stays_loaded(opts, pid, ref) do
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 2 * @idle_ms
    assert session_pid!(opts) == pid
  end

  defp assert_no_workers(opts) do
    assert [{task_sup, _}] = Registry.lookup(opts[:registry], {:session_tasks, @sid})
    eventually(fn -> Task.Supervisor.children(task_sup) == [] end)
  end

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + @wait_ms) do
    unless fun.() do
      assert System.monotonic_time(:millisecond) < deadline,
             "timed out waiting for #{inspect(fun)}"

      Process.sleep(10)
      eventually(fun, deadline)
    end
  end
end
