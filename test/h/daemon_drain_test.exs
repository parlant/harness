defmodule H.DaemonDrainTest do
  use ExUnit.Case, async: false

  alias H.{Auth, Catalog, Daemon, StoreLock}
  alias H.Daemon.{Instance, Maintenance, SignalHandler}
  alias H.Provider.Fake

  defmodule SlowTool do
    @behaviour H.Tool

    @impl true
    def name, do: "slow_tool"

    @impl true
    def description, do: "Gated test tool for cooperative drain"

    @impl true
    def parameters_schema do
      %{
        "type" => "object",
        "properties" => %{
          "tag" => %{"type" => "string"},
          "timeout_ms" => %{"type" => "integer", "minimum" => 100, "maximum" => 600_000}
        },
        "required" => ["tag"]
      }
    end

    @impl true
    def replay, do: :unsafe

    @impl true
    def mutating?, do: true

    @impl true
    def execute(%{"tag" => tag}, _ctx) do
      case Application.get_env(:harness, __MODULE__) do
        %{owner: owner, gate: gate} ->
          send(owner, {:tool_entered, tag, gate, self()})

          receive do
            {:release_tool, ^gate} -> :ok
          after
            5_000 -> :timeout
          end

        %{owner: owner} ->
          send(owner, {:tool_executed, tag})

        _ ->
          :ok
      end

      {:ok, %{content: [%{"type" => "text", "text" => "tool_ok:#{tag}"}], is_error: false}}
    end
  end

  defmodule RouterProvider do
    @behaviour H.Provider

    @impl true
    def stream_turn(%{handler: handler}, request, emit) when is_function(handler, 2) do
      handler.(request, emit)
    end

    @impl true
    def list_models(_config) do
      [
        %{
          id: "fake:coder",
          provider: "fake",
          name: "Fake Coder",
          context_window: 200_000,
          max_output_tokens: 16_384,
          supports_tools: true,
          supports_reasoning: true
        }
      ]
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:harness, SlowTool)
      SignalHandler.uninstall()
    end)

    :ok
  end

  @tag :tmp_dir
  test "drains an in-flight generation with tool_calls without starting tools, then resumes on next boot",
       %{tmp_dir: dir} do
    data = Path.join(dir, "store")
    cwd = Path.join(dir, "work")
    File.mkdir!(cwd)
    on_exit(fn -> File.rm(StoreLock.socket_path(data)) end)

    gate = make_ref()
    Application.put_env(:harness, SlowTool, %{owner: self()})

    fake1 =
      start_supervised!(
        {Fake,
         script: [
           {:gate, [%{type: :text_delta, text: "Calling tool"}], self(), gate,
            %{
              content: [%{type: "text", text: "Calling tool"}],
              tool_calls: [
                %{id: "call_1", name: "slow_tool", arguments: %{"tag" => "after-reboot"}}
              ],
              finish_reason: "tool_calls"
            }}
         ]},
        id: :fake_boot_1
      )

    start_supervised!(
      {Instance,
       data_dir: data,
       provider: Fake,
       provider_config: %{server: fake1},
       default_model: "fake:coder",
       tools: [SlowTool],
       shutdown_owner: self()}
    )

    opts = Daemon.instance_options()
    assert {:ok, _} = Daemon.create_session(%{"session_id" => "drain-gen", "cwd" => cwd}, opts)
    assert {:ok, _} = Daemon.execute_command("drain-gen", submit("req-1", "Run tool"), opts)
    assert_receive {:gate_entered, ^gate, worker}, 2_000

    # Begin cooperative drain while generation is streaming
    assert {:ok, %{state: "draining"}} = Maintenance.drain_and_stop(opts)
    # Idempotent repeat returns draining without sending duplicate signals
    assert {:ok, %{state: "draining"}} = Maintenance.drain_and_stop(opts)

    assert {:ok, %{"state" => "draining", "active_workers" => 1, "shutdown_timeout_ms" => _}} =
             Maintenance.status(opts)

    # Admission gate is closed immediately
    assert {:error, :daemon_draining} =
             Daemon.execute_command("drain-gen", submit("req-2", "Blocked"), opts)

    refute_receive :shutdown_drained, 100

    # Release the streaming LLM response
    send(worker, {:release, gate})
    assert_receive :shutdown_drained, 2_000
    assert {:ok, %{state: "stopping"}} = Maintenance.drain_and_stop(opts)

    # Tool MUST NOT have executed before shutdown!
    refute_receive {:tool_executed, _}, 100

    # Session remains active in catalog with a pending tool task
    assert {:ok, %{tasks: tasks}} = Daemon.get_session_detail("drain-gen", opts)
    assert Enum.any?(tasks, &(&1.kind == "tool_call" and &1.status == "pending"))

    # Stop Instance 1 cleanly (simulating daemon exit)
    :ok = stop_supervised(Instance)

    # Boot Instance 2 on the same data_dir; recover_active_sessions runs the pending tool & finishes turn
    fake2 =
      start_supervised!(
        {Fake,
         script: [
           {:reply, [],
            %{content: [%{type: "text", text: "Completed after reboot"}], finish_reason: "stop"}}
         ]},
        id: :fake_boot_2
      )

    start_supervised!(
      {Instance,
       data_dir: data,
       provider: Fake,
       provider_config: %{server: fake2},
       default_model: "fake:coder",
       tools: [SlowTool],
       shutdown_owner: self()}
    )

    assert_receive {:tool_executed, "after-reboot"}, 3_000

    opts2 = Daemon.instance_options()

    wait_until(fn ->
      case Daemon.scan_entries("drain-gen", "1", %{}, opts2) do
        {:ok, %{items: items}} ->
          Enum.any?(items, fn e ->
            e.kind == "assistant" and
              match?([%{"text" => "Completed after reboot"}], e.data["content"])
          end)

        _ ->
          false
      end
    end)

    assert {:ok, %{items: items}} = Daemon.scan_entries("drain-gen", "1", %{}, opts2)
    assert Enum.any?(items, &(&1.kind == "tool_result" and &1.data["is_error"] == false))
    assert Enum.count(Fake.requests(fake2)) == 1
  end

  @tag :tmp_dir
  test "drains an in-flight tool to completion, preserves queued steer, does not start next tool or generation, then resumes on next boot",
       %{tmp_dir: dir} do
    data = Path.join(dir, "store")
    cwd = Path.join(dir, "work")
    File.mkdir!(cwd)
    on_exit(fn -> File.rm(StoreLock.socket_path(data)) end)

    tool_gate = make_ref()
    Application.put_env(:harness, SlowTool, %{owner: self(), gate: tool_gate})

    fake1 =
      start_supervised!(
        {Fake,
         script: [
           {:reply, [],
            %{
              content: [%{type: "text", text: "Two tools"}],
              tool_calls: [
                %{id: "call_1", name: "slow_tool", arguments: %{"tag" => "first"}},
                %{id: "call_2", name: "slow_tool", arguments: %{"tag" => "second"}}
              ],
              finish_reason: "tool_calls"
            }}
         ]},
        id: :fake_tool_1
      )

    start_supervised!(
      {Instance,
       data_dir: data,
       provider: Fake,
       provider_config: %{server: fake1},
       default_model: "fake:coder",
       tools: [SlowTool],
       shutdown_owner: self()}
    )

    opts = Daemon.instance_options()
    assert {:ok, _} = Daemon.create_session(%{"session_id" => "drain-tool", "cwd" => cwd}, opts)

    assert {:ok, _} =
             Daemon.execute_command("drain-tool", submit("req-t1", "Run two tools"), opts)

    # First tool is running and blocked on gate
    assert_receive {:tool_entered, "first", ^tool_gate, tool_pid}, 2_000

    # Queue a steer while busy (before drain starts)
    assert {:ok, _} =
             Daemon.execute_command(
               "drain-tool",
               %{
                 "version" => 1,
                 "request_id" => "steer-1",
                 "command" => "submit",
                 "conversation_id" => "1",
                 "args" => %{
                   "type" => "input",
                   "content" => "Steer message",
                   "when_busy" => "steer",
                   "when_idle" => "start"
                 }
               },
               opts
             )

    # Begin drain while tool 1 is executing
    assert {:ok, %{state: "draining"}} = Maintenance.drain_and_stop(opts)
    refute_receive :shutdown_drained, 100

    # Allow tool 1 to finish
    send(tool_pid, {:release_tool, tool_gate})
    assert_receive :shutdown_drained, 2_000

    # Tool 2 MUST NOT have started!
    refute_receive {:tool_entered, "second", _, _}, 100

    # Tool 1 result is persisted, tool 2 is still pending
    assert {:ok, %{items: items}} = Daemon.scan_entries("drain-tool", "1", %{}, opts)

    assert Enum.any?(items, fn e ->
             e.kind == "tool_result" and e.data["tool_call_id"] == "call_1" and
               e.data["is_error"] == false
           end)

    refute Enum.any?(items, &(&1.kind == "tool_result" and &1.data["tool_call_id"] == "call_2"))

    :ok = stop_supervised(Instance)

    # Next boot: ungate SlowTool and let tool 2 + steer + next generation finish!
    Application.put_env(:harness, SlowTool, %{owner: self()})

    fake2 =
      start_supervised!(
        {Fake,
         script: [
           {:reply, [],
            %{content: [%{type: "text", text: "All done with steer"}], finish_reason: "stop"}}
         ]},
        id: :fake_tool_2
      )

    start_supervised!(
      {Instance,
       data_dir: data,
       provider: Fake,
       provider_config: %{server: fake2},
       default_model: "fake:coder",
       tools: [SlowTool],
       shutdown_owner: self()}
    )

    assert_receive {:tool_executed, "second"}, 3_000
    opts2 = Daemon.instance_options()

    wait_until(fn ->
      case Daemon.scan_entries("drain-tool", "1", %{}, opts2) do
        {:ok, %{items: items}} ->
          Enum.any?(items, fn e ->
            e.kind == "assistant" and
              match?([%{"text" => "All done with steer"}], e.data["content"])
          end)

        _ ->
          false
      end
    end)

    # Verify the queued steer was included in the resumed generation request
    [req] = Fake.requests(fake2)

    assert Enum.any?(req.messages, fn m ->
             m.role == "user" and
               Enum.any?(m.content, &(Map.get(&1, :text) == "Steer message"))
           end)
  end

  @tag :tmp_dir
  test "drains an in-flight generation with dispatch_policy without interrupting it", %{
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
         script: [
           {:gate, [%{type: :text_delta, text: "Paid response"}], self(), gate,
            %{content: [%{type: "text", text: "Paid response"}], finish_reason: "stop"}}
         ]}
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
    assert {:ok, _} = Daemon.create_session(%{"session_id" => "drain-policy", "cwd" => cwd}, opts)
    assert {:ok, _} = Daemon.execute_command("drain-policy", submit("req-p1", "Hello"), opts)
    assert_receive {:gate_entered, ^gate, worker}, 2_000

    # Drain waits for the in-flight worker rather than killing it
    assert {:ok, %{state: "draining"}} = Maintenance.drain_and_stop(opts)
    assert Process.alive?(worker)
    refute_receive :shutdown_drained, 100

    send(worker, {:release, gate})
    assert_receive :shutdown_drained, 2_000

    assert {:ok, %{items: items}} = Daemon.scan_entries("drain-policy", "1", %{}, opts)

    assert Enum.any?(items, fn e ->
             e.kind == "assistant" and
               match?([%{"text" => "Paid response"}], e.data["content"]) and
               e.data["aborted"] != true
           end)

    assert {:ok, %{tasks: tasks}} = Daemon.get_session_detail("drain-policy", opts)
    assert Enum.all?(tasks, &(&1.status == "terminal"))
    refute Enum.any?(tasks, &(get_in(&1.outcome || %{}, ["reason"]) == "interrupted"))
  end

  @tag :tmp_dir
  test "drains parent parked on subagent wait while child pauses mid-turn, then resumes both on next boot",
       %{tmp_dir: dir} do
    data = Path.join(dir, "store")
    cwd = Path.join(dir, "work")
    File.mkdir!(cwd)
    on_exit(fn -> File.rm(StoreLock.socket_path(data)) end)

    owner = self()
    child_tool_gate = make_ref()
    Application.put_env(:harness, SlowTool, %{owner: owner, gate: child_tool_gate})

    handler1 = fn req, _emit ->
      first_user =
        req.messages
        |> Enum.find(&(&1.role == "user"))
        |> case do
          %{content: [%{text: text} | _]} -> text
          _ -> ""
        end

      cond do
        String.contains?(first_user, "Delegate work") ->
          {:ok,
           %{
             content: [%{type: "text", text: "Delegating"}],
             tool_calls: [
               %{
                 id: "sub_call_1",
                 name: "subagent",
                 arguments: %{"mode" => "wait", "prompt" => "Child work"}
               }
             ],
             finish_reason: "tool_calls"
           }}

        String.contains?(first_user, "Child work") ->
          {:ok,
           %{
             content: [%{type: "text", text: "Child running tool"}],
             tool_calls: [
               %{id: "child_tc_1", name: "slow_tool", arguments: %{"tag" => "child-step"}}
             ],
             finish_reason: "tool_calls"
           }}
      end
    end

    start_supervised!(
      {Instance,
       data_dir: data,
       provider: RouterProvider,
       provider_config: %{handler: handler1},
       default_model: "fake:coder",
       tools: [SlowTool, H.Tools.Subagent],
       shutdown_owner: self()}
    )

    opts = Daemon.instance_options()

    assert {:ok, _} =
             Daemon.create_session(%{"session_id" => "parent-drain", "cwd" => cwd}, opts)

    assert {:ok, _} =
             Daemon.execute_command("parent-drain", submit("parent-req", "Delegate work"), opts)

    # Wait until child is executing its tool while parent is parked on subagent wait
    assert_receive {:tool_entered, "child-step", ^child_tool_gate, tool_pid}, 3_000

    # Begin cooperative drain
    assert {:ok, %{state: "draining"}} = Maintenance.drain_and_stop(opts)
    refute_receive :shutdown_drained, 100

    # Release child's tool; child commits tool_result and moves gen_task to pending (no spawn!)
    send(tool_pid, {:release_tool, child_tool_gate})
    assert_receive :shutdown_drained, 3_000

    # Both parent and child remain active in catalog
    sessions = Catalog.list_sessions(opts[:catalog_table])
    assert Enum.any?(sessions, &(&1.session_id == "parent-drain" and &1.active))

    assert Enum.any?(
             sessions,
             &(get_in(&1, [:parent, :session_id]) == "parent-drain" and &1.active)
           )

    :ok = stop_supervised(Instance)

    # Next boot: child finishes its turn -> settles parent -> parent finishes its turn!
    handler2 = fn req, _emit ->
      first_user =
        req.messages
        |> Enum.find(&(&1.role == "user"))
        |> case do
          %{content: [%{text: text} | _]} -> text
          _ -> ""
        end

      if String.contains?(first_user, "Child work") do
        {:ok, %{content: [%{type: "text", text: "Child answer ready"}], finish_reason: "stop"}}
      else
        {:ok,
         %{content: [%{type: "text", text: "Parent saw child answer"}], finish_reason: "stop"}}
      end
    end

    start_supervised!(
      {Instance,
       data_dir: data,
       provider: RouterProvider,
       provider_config: %{handler: handler2},
       default_model: "fake:coder",
       tools: [SlowTool, H.Tools.Subagent],
       shutdown_owner: self()}
    )

    opts2 = Daemon.instance_options()

    wait_until(fn ->
      case Daemon.scan_entries("parent-drain", "1", %{}, opts2) do
        {:ok, %{items: items}} ->
          Enum.any?(items, fn e ->
            e.kind == "assistant" and
              match?([%{"text" => "Parent saw child answer"}], e.data["content"])
          end)

        _ ->
          false
      end
    end)
  end

  @tag :tmp_dir
  test "drains cleanly with sleeping retry task and workspace_wait task, then resumes both on next boot",
       %{tmp_dir: dir} do
    data = Path.join(dir, "store")
    cwd = Path.join(dir, "work")
    File.mkdir!(cwd)
    on_exit(fn -> File.rm(StoreLock.socket_path(data)) end)

    tool_gate = make_ref()
    Application.put_env(:harness, SlowTool, %{owner: self(), gate: tool_gate})

    # 1. Session A hits a retryable error -> enters sleeping with a wake timer.
    # 2. Session B holds the workspace lease in SlowTool.
    # 3. Session C queues behind B in workspace_wait (checkpoint["phase"] == "workspace_wait").
    handler1 = fn req, _emit ->
      first_user =
        req.messages
        |> Enum.find(&(&1.role == "user"))
        |> case do
          %{content: [%{text: text} | _]} -> text
          _ -> ""
        end

      cond do
        first_user == "retry-session" ->
          {:error,
           %{code: "rate_limited", message: "try later", retryable: true, retry_after_ms: 400}}

        first_user == "holder-session" ->
          {:ok,
           %{
             content: [%{type: "text", text: "Holding"}],
             tool_calls: [%{id: "hold_1", name: "slow_tool", arguments: %{"tag" => "holder"}}],
             finish_reason: "tool_calls"
           }}

        first_user == "waiter-session" ->
          {:ok,
           %{
             content: [%{type: "text", text: "Waiting"}],
             tool_calls: [%{id: "wait_1", name: "slow_tool", arguments: %{"tag" => "waiter"}}],
             finish_reason: "tool_calls"
           }}
      end
    end

    start_supervised!(
      {Instance,
       data_dir: data,
       provider: RouterProvider,
       provider_config: %{handler: handler1},
       default_model: "fake:coder",
       tools: [SlowTool],
       retry_backoff_ms: 400,
       shutdown_owner: self()}
    )

    opts = Daemon.instance_options()
    assert {:ok, _} = Daemon.create_session(%{"session_id" => "sess-retry", "cwd" => cwd}, opts)
    assert {:ok, _} = Daemon.create_session(%{"session_id" => "sess-holder", "cwd" => cwd}, opts)
    assert {:ok, _} = Daemon.create_session(%{"session_id" => "sess-waiter", "cwd" => cwd}, opts)

    assert {:ok, _} =
             Daemon.execute_command("sess-retry", submit("r1", "retry-session"), opts)

    assert {:ok, _} =
             Daemon.execute_command("sess-holder", submit("h1", "holder-session"), opts)

    assert_receive {:tool_entered, "holder", ^tool_gate, holder_pid}, 2_000

    assert {:ok, _} =
             Daemon.execute_command("sess-waiter", submit("w1", "waiter-session"), opts)

    # Wait until sess-retry is sleeping and sess-waiter is in workspace_wait
    wait_until(fn ->
      {:ok, d_retry} = Daemon.get_session_detail("sess-retry", opts)
      {:ok, d_waiter} = Daemon.get_session_detail("sess-waiter", opts)
      [{waiter_pid, _}] = Registry.lookup(opts[:registry], {:session, "sess-waiter"})
      waiter_state = :sys.get_state(waiter_pid)

      Enum.any?(d_retry.tasks, &(&1.status == "sleeping")) and
        Enum.any?(d_waiter.tasks, &(&1.kind == "tool_call" and &1.status == "pending")) and
        Enum.any?(
          Map.values(waiter_state.tasks),
          &(&1.status == "pending" and &1.checkpoint["phase"] == "workspace_wait")
        )
    end)

    # Begin drain: cancels wake timer on sess-retry; when holder finishes & releases lease,
    # sess-waiter gets lease_granted during drain and MUST release it without executing!
    assert {:ok, %{state: "draining"}} = Maintenance.drain_and_stop(opts)
    send(holder_pid, {:release_tool, tool_gate})
    assert_receive :shutdown_drained, 2_000

    # Waiter MUST NOT have executed during drain
    refute_receive {:tool_entered, "waiter", _, _}, 100

    # Verify waiter task stays pending with phase workspace_wait and retry stays sleeping
    [{waiter_pid, _}] = Registry.lookup(opts[:registry], {:session, "sess-waiter"})
    waiter_state = :sys.get_state(waiter_pid)

    assert Enum.any?(
             Map.values(waiter_state.tasks),
             &(&1.status == "pending" and &1.checkpoint["phase"] == "workspace_wait")
           )

    assert {:ok, d_retry} = Daemon.get_session_detail("sess-retry", opts)
    assert Enum.any?(d_retry.tasks, &(&1.status == "sleeping"))

    :ok = stop_supervised(Instance)

    # Boot Instance 2: ungate SlowTool, all three sessions resume and complete!
    Application.put_env(:harness, SlowTool, %{owner: self()})

    handler2 = fn _req, _emit ->
      {:ok, %{content: [%{type: "text", text: "Resumed OK"}], finish_reason: "stop"}}
    end

    start_supervised!(
      {Instance,
       data_dir: data,
       provider: RouterProvider,
       provider_config: %{handler: handler2},
       default_model: "fake:coder",
       tools: [SlowTool],
       retry_backoff_ms: 50,
       shutdown_owner: self()}
    )

    assert_receive {:tool_executed, "waiter"}, 3_000
    opts2 = Daemon.instance_options()

    for sid <- ["sess-retry", "sess-holder", "sess-waiter"] do
      wait_until(fn ->
        case Daemon.scan_entries(sid, "1", %{}, opts2) do
          {:ok, %{items: items}} ->
            Enum.any?(items, fn e ->
              e.kind == "assistant" and
                match?([%{"text" => "Resumed OK"}], e.data["content"])
            end)

          _ ->
            false
        end
      end)
    end
  end

  @tag :tmp_dir
  test "HTTP shutdown endpoint validates mode, serves status, and tears down active SSE connections in under 1 second",
       %{tmp_dir: dir} do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)

    data = Path.join(dir, "store")
    cwd = Path.join(dir, "work")
    File.mkdir!(cwd)
    on_exit(fn -> File.rm(StoreLock.socket_path(data)) end)

    start_supervised!(
      {Instance,
       data_dir: data,
       http_port: 0,
       api_socket: false,
       provider: Fake,
       provider_config: %{},
       default_model: "fake:coder",
       shutdown_owner: self()}
    )

    opts = Daemon.instance_options()
    [{port, base_url}] = H.Daemon.Runtime.http_endpoints(opts)
    token = Auth.owner_token(opts[:auth_table])
    headers = [{"authorization", "Bearer #{token}"}, {"host", "127.0.0.1:#{port}"}]

    # Status endpoint reports running with 0 active workers and default 300s shutdown timeout
    status_resp = Req.get!("#{base_url}/api/v1/daemon/status", headers: headers, retry: false)
    assert status_resp.status == 200

    assert status_resp.body == %{
             "state" => "running",
             "active_workers" => 0,
             "shutdown_timeout_ms" => 300_000
           }

    # Invalid shutdown mode returns 422
    bad_resp =
      Req.post!("#{base_url}/api/v1/daemon/shutdown",
        headers: headers,
        json: %{"mode" => "bogus"},
        retry: false
      )

    assert bad_resp.status == 422
    assert bad_resp.body == %{"error" => "invalid_shutdown_mode"}

    # Open both conversation SSE and catalog SSE streams and verify they are streaming
    assert {:ok, _} = Daemon.create_session(%{"session_id" => "sse-fast", "cwd" => cwd}, opts)

    {:ok, sock1} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    {:ok, sock2} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

    on_exit(fn ->
      :gen_tcp.close(sock1)
      :gen_tcp.close(sock2)
    end)

    for {sock, path} <- [
          {sock1, "/api/v1/sessions/sse-fast/conversations/1/events"},
          {sock2, "/api/v1/sessions/events"}
        ] do
      req =
        "GET #{path} HTTP/1.1\r\n" <>
          "Host: 127.0.0.1:#{port}\r\n" <>
          "Authorization: Bearer #{token}\r\n" <>
          "Accept: text/event-stream\r\n\r\n"

      :ok = :gen_tcp.send(sock, req)
      {:ok, chunk} = :gen_tcp.recv(sock, 0, 2_000)
      assert chunk =~ "200 OK"
      assert chunk =~ "text/event-stream"
    end

    # Request drain shutdown via HTTP
    drain_resp =
      Req.post!("#{base_url}/api/v1/daemon/shutdown",
        headers: headers,
        json: %{"mode" => "drain"},
        retry: false
      )

    assert drain_resp.status == 202
    assert drain_resp.body == %{"state" => "stopping", "shutdown_timeout_ms" => 300_000}
    assert_receive :shutdown_drained, 1_000

    # Stopping the entire Instance (including Bandit listeners with active SSE streams)
    # MUST finish well under 1 second (no 15-second ThousandIsland stall!)
    t0 = System.monotonic_time(:millisecond)
    :ok = stop_supervised(Instance)
    elapsed_ms = System.monotonic_time(:millisecond) - t0

    assert elapsed_ms < 1_000,
           "expected Instance shutdown with open SSE streams in < 1000ms, took #{elapsed_ms}ms"
  end

  describe "drain_and_stop/1" do
    @tag :tmp_dir
    test "notifies the launcher when a drain is blocked past its deadline", %{tmp_dir: dir} do
      start_supervised!(
        {Instance, data_dir: dir, shutdown_owner: self(), shutdown_timeout_ms: 200}
      )

      opts = Daemon.instance_options()
      assert :ok = GenServer.call(H.Daemon.Boot, {:admit, opts[:maintenance_table]})

      assert {:ok, %{state: "draining", shutdown_timeout_ms: 200}} =
               Maintenance.drain_and_stop(opts)

      assert {:ok, %{state: "draining", shutdown_timeout_ms: remaining}} =
               Maintenance.drain_and_stop(opts)

      assert remaining in 1..200
      assert_receive :drain_timeout, 1_000
      refute_receive :drain_timeout, 250
      refute_received :shutdown_drained
    end

    @tag :tmp_dir
    test "cancels the deadline when the drain finishes", %{tmp_dir: dir} do
      start_supervised!(
        {Instance, data_dir: dir, shutdown_owner: self(), shutdown_timeout_ms: 500}
      )

      opts = Daemon.instance_options()
      assert :ok = GenServer.call(H.Daemon.Boot, {:admit, opts[:maintenance_table]})
      assert {:ok, %{state: "draining"}} = Maintenance.drain_and_stop(opts)

      GenServer.cast(H.Daemon.Boot, {:release, self()})
      assert_receive :shutdown_drained, 1_000
      refute_receive :drain_timeout, 550
    end
  end

  @tag :tmp_dir
  test "computes dynamic shutdown_timeout_ms exceeding 300s floor for long-timeout running tools",
       %{tmp_dir: dir} do
    data = Path.join(dir, "store")
    cwd = Path.join(dir, "work")
    File.mkdir!(cwd)
    on_exit(fn -> File.rm(StoreLock.socket_path(data)) end)

    tool_gate = make_ref()
    Application.put_env(:harness, SlowTool, %{owner: self(), gate: tool_gate})

    fake =
      start_supervised!(
        {Fake,
         script: [
           {:reply, [],
            %{
              content: [%{type: "text", text: "Running long tool"}],
              tool_calls: [
                %{
                  id: "call_long_1",
                  name: "slow_tool",
                  arguments: %{"tag" => "long", "timeout_ms" => 540_000}
                }
              ],
              finish_reason: "tool_calls"
            }}
         ]},
        id: :fake_dynamic_timeout
      )

    start_supervised!(
      {Instance,
       data_dir: data,
       provider: Fake,
       provider_config: %{server: fake},
       default_model: "fake:coder",
       tools: [SlowTool],
       shutdown_owner: self()}
    )

    opts = Daemon.instance_options()

    # Idle status uses the 300_000ms default floor
    assert {:ok,
            %{
              "state" => "running",
              "active_workers" => 0,
              "shutdown_timeout_ms" => 300_000
            }} = Maintenance.status(opts)

    assert {:ok, _} = Daemon.create_session(%{"session_id" => "long-tool", "cwd" => cwd}, opts)
    assert {:ok, _} = Daemon.execute_command("long-tool", submit("req-long", "Go"), opts)
    assert_receive {:tool_entered, "long", ^tool_gate, tool_pid}, 2_000

    # Status must scale beyond 540_000ms to include remaining tool deadline + 30_000ms commit grace
    assert {:ok,
            %{
              "state" => "running",
              "active_workers" => 1,
              "shutdown_timeout_ms" => status_timeout_ms
            }} = Maintenance.status(opts)

    assert status_timeout_ms > 540_000
    assert status_timeout_ms <= 570_000

    # Beginning drain also reports the dynamic shutdown_timeout_ms
    assert {:ok, %{state: "draining", shutdown_timeout_ms: drain_timeout_ms}} =
             Maintenance.drain_and_stop(opts)

    assert drain_timeout_ms > 540_000
    assert drain_timeout_ms <= 570_000

    send(tool_pid, {:release_tool, tool_gate})
    assert_receive :shutdown_drained, 2_000
  end

  test "SignalHandler intercepts :sigterm and delivers {:os_signal, :sigterm} to owner without halting VM" do
    assert :ok = SignalHandler.install(self())
    assert SignalHandler in :gen_event.which_handlers(:erl_signal_server)

    :gen_event.notify(:erl_signal_server, :sigterm)
    assert_receive {:os_signal, :sigterm}, 1_000

    assert :ok = SignalHandler.uninstall()
    assert :erl_signal_handler in :gen_event.which_handlers(:erl_signal_server)
    refute SignalHandler in :gen_event.which_handlers(:erl_signal_server)
  end

  defp submit(id, content) do
    %{
      "version" => 1,
      "request_id" => id,
      "command" => "submit",
      "conversation_id" => "1",
      "args" => %{"type" => "input", "content" => content}
    }
  end

  defp wait_until(fun, timeout_ms \\ 4_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if res = fun.() do
      res
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for condition")
      else
        Process.sleep(15)
        do_wait_until(fun, deadline)
      end
    end
  end
end
