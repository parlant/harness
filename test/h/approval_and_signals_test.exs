defmodule H.ApprovalAndSignalsTest do
  use ExUnit.Case, async: true

  alias H.{Auth, Catalog, Daemon, StoreLock, WorkspaceLease}
  alias H.HTTP.Router
  alias H.Provider.Fake

  setup_all do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  defp start_stack(script, extra_opts \\ []) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-r2-test-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    on_exit(fn ->
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    registry = :"H.R2Test.Registry.#{id}"
    pubsub = :"H.R2Test.PubSub.#{id}"
    catalog = :"H.R2Test.Catalog.#{id}"
    catalog_table = :"h_r2_test_catalog_#{id}"
    auth = :"H.R2Test.Auth.#{id}"
    auth_table = :"h_r2_test_auth_#{id}"
    lease = :"H.R2Test.Lease.#{id}"
    runtime_sup = :"H.R2Test.RuntimeSup.#{id}"
    fake_name = :"H.R2Test.Fake.#{id}"

    start_supervised!({StoreLock, data_dir: data_dir, name: :"H.R2Test.Lock.#{id}"})
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Auth, data_dir: data_dir, name: auth, table: auth_table})

    start_supervised!(
      {Catalog,
       data_dir: data_dir, name: catalog, table: catalog_table, pubsub: pubsub, registry: registry}
    )

    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})
    fake = start_supervised!({Fake, name: fake_name, script: script})

    daemon_opts =
      [
        data_dir: data_dir,
        registry: registry,
        pubsub: pubsub,
        catalog: catalog,
        catalog_table: catalog_table,
        workspace_lease: lease,
        runtime_sup: runtime_sup,
        provider: Fake,
        provider_config: %{server: fake},
        storage_mod: H.Storage.File,
        storage_opts: [sync: :none],
        default_model: "fake:coder"
      ] ++ extra_opts

    router_opts = [
      auth_server: auth,
      auth_table: auth_table,
      daemon: Daemon,
      daemon_opts: daemon_opts,
      sse_keepalive_ms: 15_000
    ]

    bandit =
      start_supervised!(
        {Bandit, plug: {Router, router_opts}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    token = Auth.owner_token(auth_table)
    headers = [{"authorization", "Bearer #{token}"}]

    %{
      base_url: "http://127.0.0.1:#{port}",
      headers: headers,
      daemon_opts: daemon_opts,
      cwd: cwd,
      data_dir: data_dir,
      registry: registry,
      pubsub: pubsub,
      lease: lease
    }
  end

  defp cmd(req_id, command, cid, args) do
    %{
      "version" => 1,
      "request_id" => req_id,
      "command" => command,
      "conversation_id" => cid,
      "args" => args
    }
  end

  defp wait_until(fun, timeout_ms \\ 3_000) do
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

  describe "R2a Owner tool approval" do
    test "parks mutating tool with zero workers/leases, surfaces needs_attention + activity_label, and executes on allow / errors on deny" do
      ctx =
        start_stack([
          {:reply, [],
           %{
             content: [],
             tool_calls: [
               %{id: "c_read", name: "read", arguments: %{"path" => "input.txt"}},
               %{
                 id: "c_write",
                 name: "write",
                 arguments: %{"path" => "out.txt", "content" => "approved content"}
               },
               %{
                 id: "c_bash",
                 name: "bash",
                 arguments: %{"command" => "echo should_not_run > denied.txt"}
               }
             ],
             finish_reason: "tool_calls"
           }},
          {:expect,
           fn req ->
             tools = Enum.filter(req.messages, &(&1.role == "tool"))
             assert length(tools) == 3

             r = Enum.find(tools, &(&1.tool_call_id == "c_read"))
             w = Enum.find(tools, &(&1.tool_call_id == "c_write"))
             b = Enum.find(tools, &(&1.tool_call_id == "c_bash"))

             assert r.is_error == false
             assert w.is_error == false
             assert b.is_error == true
             assert hd(b.content).text =~ "denied"
             true
           end, {:reply, [], %{content: [%{type: "text", text: "Completed with allow + deny"}]}}}
        ])

      File.write!(Path.join(ctx.cwd, "input.txt"), "hello approval\n")

      {:ok, _} =
        Daemon.create_session(
          %{
            "session_id" => "s-approval",
            "cwd" => ctx.cwd,
            "agent" => %{"approval_policy" => "mutating"}
          },
          ctx.daemon_opts
        )

      {:ok, _} =
        Daemon.execute_command(
          "s-approval",
          cmd("sub-app-1", "submit", "1", %{"type" => "input", "content" => "Do tools"}),
          ctx.daemon_opts
        )

      # read executes immediately (non-mutating), then write parks for approval!
      snap_write =
        wait_until(fn ->
          {:ok, {:snapshot, _seq, bin}} =
            Daemon.subscribe_conversation("s-approval", "1", self(), nil, ctx.daemon_opts)

          snap = JSON.decode!(bin)
          approvals = get_in(snap, ["docs", "live", "approvals"]) || %{}
          if map_size(approvals) == 1, do: snap, else: nil
        end)

      assert snap_write["docs"]["live"]["tools"]["c_read"]["status"] == "done"
      assert snap_write["docs"]["live"]["tools"]["c_write"]["status"] == "awaiting_approval"
      # Sequential non-subagent tool c_bash MUST wait behind awaiting_approval c_write!
      assert snap_write["docs"]["live"]["tools"]["c_bash"]["status"] == "pending"

      [{_, approval}] = Map.to_list(snap_write["docs"]["live"]["approvals"])
      assert approval["tool_name"] == "write"
      assert approval["call_id"] == "c_write"
      write_tid = String.to_integer(approval["task_id"])

      # Zero workers and zero workspace leases held while waiting on approval!
      [{task_sup_pid, _}] = Registry.lookup(ctx.registry, {:session_tasks, "s-approval"})
      assert Task.Supervisor.children(task_sup_pid) == []

      {:ok, canonical_cwd} =
        H.ExecutionEnv.canonical_path(H.ExecutionEnv.Host.new(ctx.cwd), ctx.cwd)

      assert :ok =
               WorkspaceLease.acquire(
                 ctx.lease,
                 {"host", canonical_cwd},
                 {"probe", 1},
                 self()
               )

      WorkspaceLease.release(ctx.lease, {"host", canonical_cwd}, {"probe", 1})

      # Catalog surfaces needs_attention: true and activity_label: "approval · write"
      {:ok, %{session: summary}} = Daemon.get_session_detail("s-approval", ctx.daemon_opts)
      assert summary.needs_attention == true
      assert summary.activity_label == "approval · write"

      refute File.exists?(Path.join(ctx.cwd, "out.txt"))

      # Approve write -> executes write, then parks c_bash for approval
      {:ok, _} =
        Daemon.execute_command(
          "s-approval",
          cmd("app-write", "approve_tool", "1", %{"task_id" => write_tid, "decision" => "allow"}),
          ctx.daemon_opts
        )

      # Re-approving with different request_id -> 409 task_not_awaiting_approval
      wait_until(fn -> File.exists?(Path.join(ctx.cwd, "out.txt")) end)
      assert File.read!(Path.join(ctx.cwd, "out.txt")) == "approved content"

      snap_bash =
        wait_until(fn ->
          {:ok, {:snapshot, _seq, bin}} =
            Daemon.subscribe_conversation("s-approval", "1", self(), nil, ctx.daemon_opts)

          snap = JSON.decode!(bin)
          approvals = get_in(snap, ["docs", "live", "approvals"]) || %{}

          case Map.values(approvals) do
            [%{"tool_name" => "bash"} = app] -> app
            _ -> nil
          end
        end)

      bash_tid = String.to_integer(snap_bash["task_id"])

      assert {:error, {:conflict, "task_not_awaiting_approval"}} =
               Daemon.execute_command(
                 "s-approval",
                 cmd("dup-write-diff", "approve_tool", "1", %{
                   "task_id" => write_tid,
                   "decision" => "allow"
                 }),
                 ctx.daemon_opts
               )

      # Deny bash -> writes error tool_result without executing, advances generation
      {:ok, _} =
        Daemon.execute_command(
          "s-approval",
          cmd("deny-bash", "approve_tool", "1", %{
            "task_id" => bash_tid,
            "decision" => "deny",
            "reason" => "no shell allowed"
          }),
          ctx.daemon_opts
        )

      done_out =
        wait_until(fn ->
          {:ok, out} = Daemon.get_submission("s-approval", "sub-app-1", ctx.daemon_opts)
          if out.status == "done", do: out, else: nil
        end)

      assert done_out.answer_text == "Completed with allow + deny"
      refute File.exists?(Path.join(ctx.cwd, "denied.txt"))
    end

    test "supports explicit tool list approval_policy" do
      ctx =
        start_stack([
          {:reply, [],
           %{
             content: [],
             tool_calls: [
               %{id: "c_r1", name: "read", arguments: %{"path" => "f.txt"}}
             ],
             finish_reason: "tool_calls"
           }},
          {:reply, [], %{content: [%{type: "text", text: "Read allowed"}]}}
        ])

      File.write!(Path.join(ctx.cwd, "f.txt"), "secret")

      {:ok, _} =
        Daemon.create_session(
          %{
            "session_id" => "s-list-policy",
            "cwd" => ctx.cwd,
            "agent" => %{"approval_policy" => ["read"]}
          },
          ctx.daemon_opts
        )

      {:ok, _} =
        Daemon.execute_command(
          "s-list-policy",
          cmd("sub-lp", "submit", "1", %{"type" => "input", "content" => "Read f"}),
          ctx.daemon_opts
        )

      app =
        wait_until(fn ->
          {:ok, {:snapshot, _seq, bin}} =
            Daemon.subscribe_conversation("s-list-policy", "1", self(), nil, ctx.daemon_opts)

          snap = JSON.decode!(bin)

          case Map.values(get_in(snap, ["docs", "live", "approvals"]) || %{}) do
            [a] -> a
            _ -> nil
          end
        end)

      assert app["tool_name"] == "read"

      {:ok, _} =
        Daemon.execute_command(
          "s-list-policy",
          cmd("app-r1", "approve_tool", "1", %{
            "task_id" => String.to_integer(app["task_id"]),
            "decision" => "allow"
          }),
          ctx.daemon_opts
        )

      out =
        wait_until(fn ->
          {:ok, o} = Daemon.get_submission("s-list-policy", "sub-lp", ctx.daemon_opts)
          if o.status == "done", do: o, else: nil
        end)

      assert out.answer_text == "Read allowed"
    end
  end

  describe "R2b External wake signals & wait_signal" do
    test "delivers HTTP signal to parked wait_signal, enforces idempotency/conflict, queues unconsumed signals, and handles timeouts" do
      ctx =
        start_stack([
          # Turn 1: wait_signal on "deploy.ready"
          {:reply, [],
           %{
             content: [],
             tool_calls: [
               %{
                 id: "c_wait_1",
                 name: "wait_signal",
                 arguments: %{"topic" => "deploy.ready", "timeout_ms" => 5_000}
               }
             ],
             finish_reason: "tool_calls"
           }},
          # Turn 2: verify payload delivered, then wait_signal on "prequeued.topic" (already delivered!)
          {:expect,
           fn req ->
             tr = Enum.find(req.messages, &(&1.role == "tool" and &1.tool_call_id == "c_wait_1"))
             assert tr != nil
             assert tr.is_error == false
             assert hd(tr.content).text =~ "v2.0"
             true
           end,
           {:reply, [],
            %{
              content: [],
              tool_calls: [
                %{
                  id: "c_wait_2",
                  name: "wait_signal",
                  arguments: %{"topic" => "prequeued.topic"}
                }
              ],
              finish_reason: "tool_calls"
            }}},
          # Turn 3: verify prequeued consumed immediately, then wait_signal that times out
          {:expect,
           fn req ->
             tr = Enum.find(req.messages, &(&1.role == "tool" and &1.tool_call_id == "c_wait_2"))
             assert tr != nil
             assert tr.is_error == false
             assert hd(tr.content).text =~ "early-bird"
             true
           end,
           {:reply, [],
            %{
              content: [],
              tool_calls: [
                %{
                  id: "c_wait_timeout",
                  name: "wait_signal",
                  arguments: %{"topic" => "never.arrives", "timeout_ms" => 100}
                }
              ],
              finish_reason: "tool_calls"
            }}},
          # Turn 4: verify timeout error
          {:expect,
           fn req ->
             tr =
               Enum.find(
                 req.messages,
                 &(&1.role == "tool" and &1.tool_call_id == "c_wait_timeout")
               )

             assert tr != nil
             assert tr.is_error == true
             assert hd(tr.content).text =~ "Timed out"
             true
           end, {:reply, [], %{content: [%{type: "text", text: "All signal modes verified"}]}}}
        ])

      {:ok, _} =
        Daemon.create_session(%{"session_id" => "s-signals", "cwd" => ctx.cwd}, ctx.daemon_opts)

      # Pre-queue a signal BEFORE wait_signal for "prequeued.topic" is called
      pre_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/s-signals/signals",
          headers: ctx.headers,
          json: %{
            "request_id" => "sig-pre-1",
            "topic" => "prequeued.topic",
            "payload" => %{"tag" => "early-bird"}
          },
          retry: false
        )

      assert pre_resp.status == 200
      assert pre_resp.body["status"] == "queued"

      # Idempotent duplicate request_id + same payload -> 200
      dup_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/s-signals/signals",
          headers: ctx.headers,
          json: %{
            "request_id" => "sig-pre-1",
            "topic" => "prequeued.topic",
            "payload" => %{"tag" => "early-bird"}
          },
          retry: false
        )

      assert dup_resp.status == 200
      assert dup_resp.body["signal_id"] == pre_resp.body["signal_id"]

      # Mismatched payload with same request_id -> 409
      conflict_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/s-signals/signals",
          headers: ctx.headers,
          json: %{
            "request_id" => "sig-pre-1",
            "topic" => "prequeued.topic",
            "payload" => %{"tag" => "mutated"}
          },
          retry: false
        )

      assert conflict_resp.status == 409

      # Invalid topic -> 422
      bad_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/s-signals/signals",
          headers: ctx.headers,
          json: %{"request_id" => "sig-bad", "topic" => "bad topic!"},
          retry: false
        )

      assert bad_resp.status == 422

      # Start run -> parks on wait_signal "deploy.ready"
      {:ok, _} =
        Daemon.execute_command(
          "s-signals",
          cmd("sub-sig", "submit", "1", %{"type" => "input", "content" => "Wait for signals"}),
          ctx.daemon_opts
        )

      wait_until(fn ->
        {:ok, detail} = Daemon.get_session_detail("s-signals", ctx.daemon_opts)

        Enum.find(
          detail.tasks,
          &(&1.kind == "tool_call" and &1.status == "waiting" and &1.wake["on"] == "signal")
        )
      end)

      # Zero Task.Supervisor workers while parked!
      [{task_sup_pid, _}] = Registry.lookup(ctx.registry, {:session_tasks, "s-signals"})
      assert Task.Supervisor.children(task_sup_pid) == []

      # Deliver deploy.ready signal via HTTP -> wakes parked wait_signal -> consumes prequeued -> times out on never.arrives
      deliv_resp =
        Req.post!("#{ctx.base_url}/api/v1/sessions/s-signals/signals",
          headers: ctx.headers,
          json: %{
            "request_id" => "sig-deploy-1",
            "topic" => "deploy.ready",
            "payload" => %{"version" => "v2.0"}
          },
          retry: false
        )

      assert deliv_resp.status == 200
      assert deliv_resp.body["status"] == "delivered"

      out =
        wait_until(fn ->
          {:ok, o} = Daemon.get_submission("s-signals", "sub-sig", ctx.daemon_opts)
          if o.status == "done", do: o, else: nil
        end)

      assert out.answer_text == "All signal modes verified"
    end
  end
end
