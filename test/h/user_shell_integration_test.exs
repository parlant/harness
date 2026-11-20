defmodule H.UserShellIntegrationTest do
  use ExUnit.Case, async: true

  alias H.{Auth, Catalog, Daemon, RemoteAgent, StoreLock, WorkspaceLease}
  alias H.ExecutionEnv.{Host, Remote}
  alias H.HTTP.Router
  alias H.Provider.Fake

  defp start_daemon_env(script \\ [], extra_opts \\ []) do
    id = System.unique_integer([:positive, :monotonic])
    tmp_root = Path.join(System.tmp_dir!(), "h-us-int-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    on_exit(fn -> File.rm_rf(tmp_root) end)

    registry = :"H.UsInt.Registry.#{id}"
    pubsub = :"H.UsInt.PubSub.#{id}"
    catalog = :"H.UsInt.Catalog.#{id}"
    catalog_table = :"h_us_int_catalog_#{id}"
    lease = :"H.UsInt.Lease.#{id}"
    runtime_sup = :"H.UsInt.RuntimeSup.#{id}"
    fake_name = :"H.UsInt.Fake.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})
    fake = start_supervised!({Fake, script: script, name: fake_name})

    opts =
      Keyword.merge(
        [
          registry: registry,
          pubsub: pubsub,
          catalog: catalog,
          catalog_table: catalog_table,
          workspace_lease: lease,
          runtime_sup: runtime_sup,
          data_dir: data_dir,
          provider: Fake,
          provider_config: %{server: fake},
          storage_mod: H.Storage.File,
          storage_opts: [sync: :none],
          default_model: "fake:coder"
        ],
        extra_opts
      )

    %{opts: opts, cwd: cwd, data_dir: data_dir, fake: fake, lease: lease, tmp_root: tmp_root}
  end

  defp restart_daemon_env(data_dir, script, extra_opts) do
    id = System.unique_integer([:positive, :monotonic])
    registry = :"H.UsInt.ReRegistry.#{id}"
    pubsub = :"H.UsInt.RePubSub.#{id}"
    catalog = :"H.UsInt.ReCatalog.#{id}"
    catalog_table = :"h_us_int_recatalog_#{id}"
    lease = :"H.UsInt.ReLease.#{id}"
    runtime_sup = :"H.UsInt.ReRuntimeSup.#{id}"
    fake_name = :"H.UsInt.ReFake.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry}, id: {:re_reg, id})
    start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: {:re_pub, id})

    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table},
      id: {:re_cat, id}
    )

    start_supervised!({WorkspaceLease, name: lease}, id: {:re_lease, id})

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup},
      id: {:re_sup, id}
    )

    fake = start_supervised!({Fake, script: script, name: fake_name}, id: {:re_fake, id})

    opts =
      Keyword.merge(
        [
          registry: registry,
          pubsub: pubsub,
          catalog: catalog,
          catalog_table: catalog_table,
          workspace_lease: lease,
          runtime_sup: runtime_sup,
          data_dir: data_dir,
          provider: Fake,
          provider_config: %{server: fake},
          storage_mod: H.Storage.File,
          storage_opts: [sync: :none],
          default_model: "fake:coder"
        ],
        extra_opts
      )

    %{opts: opts, fake: fake, lease: lease}
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

  defp await_ready_pid(port) do
    receive do
      {^port, {:data, {:eol, "READY:" <> os_pid}}} ->
        os_pid

      {^port, {:data, {:eol, _line}}} ->
        await_ready_pid(port)

      {^port, {:exit_status, status}} ->
        flunk("child VM exited early with status #{status}")
    after
      10_000 ->
        flunk("timed out waiting for child VM to reach READY state")
    end
  end

  describe "HTTP router + Daemon boundary validation, conflicts, and idempotency" do
    test "validates required args (422), expected_seq conflicts (409), busy conflicts (409), and idempotent retries (200/409)" do
      Application.ensure_all_started(:req)
      %{opts: opts, cwd: cwd, tmp_root: tmp_root} = start_daemon_env()

      id = System.unique_integer([:positive, :monotonic])
      auth_table = :"h_us_http_auth_#{id}"
      auth_server = :"H.UsInt.Auth.#{id}"
      auth_dir = Path.join(tmp_root, "auth")
      File.mkdir_p!(auth_dir)

      start_supervised!({Auth, data_dir: auth_dir, name: auth_server, table: auth_table})
      token = Auth.owner_token(auth_table)

      router_opts = [
        port: 4000,
        auth_server: auth_server,
        auth_table: auth_table,
        daemon: H.Daemon,
        daemon_opts: opts
      ]

      req =
        Req.new(
          base_url: "http://127.0.0.1:4000",
          plug: {Router, router_opts},
          headers: [{"host", "127.0.0.1:4000"}, {"authorization", "Bearer #{token}"}],
          retry: false
        )

      {:ok, %{seq: seq0}} =
        Daemon.create_session(%{"session_id" => "s-http-us", "cwd" => cwd}, opts)

      # 422 on invalid/missing command, include_in_context, or expected_seq
      for bad_args <- [
            %{},
            %{"command" => "", "include_in_context" => true, "expected_seq" => seq0},
            %{"command" => "echo hi", "expected_seq" => seq0},
            %{"command" => "echo hi", "include_in_context" => "true", "expected_seq" => seq0},
            %{"command" => "echo hi", "include_in_context" => true},
            %{"command" => "echo hi", "include_in_context" => true, "expected_seq" => -1}
          ] do
        resp =
          Req.post!(req,
            url: "/api/v1/sessions/s-http-us/commands",
            json: cmd("us-bad-#{System.unique_integer([:positive])}", "user_shell", "1", bad_args)
          )

        assert resp.status == 422
      end

      # 409 on expected_seq mismatch
      resp_stale =
        Req.post!(req,
          url: "/api/v1/sessions/s-http-us/commands",
          json:
            cmd("us-stale", "user_shell", "1", %{
              "command" => "echo nope",
              "include_in_context" => true,
              "expected_seq" => seq0 + 5
            })
        )

      assert resp_stale.status == 409
      assert resp_stale.body == %{"error" => "expected_seq mismatch"}

      # 200 on valid user_shell
      valid_body =
        cmd("us-ok-1", "user_shell", "1", %{
          "command" => "printf 'hello-http'",
          "include_in_context" => true,
          "expected_seq" => seq0
        })

      resp_ok = Req.post!(req, url: "/api/v1/sessions/s-http-us/commands", json: valid_body)
      assert resp_ok.status == 200

      assert %{
               "version" => 1,
               "request_id" => "us-ok-1",
               "status" => "placed",
               "seq" => placed_seq,
               "submission_id" => sub_id
             } = resp_ok.body

      assert is_integer(placed_seq)
      assert is_binary(sub_id)

      # Wait for completion
      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-http-us", "1", %{"order" => "asc"}, opts)
        if length(items) == 1, do: items, else: nil
      end)

      # Idempotent retry returns completed receipt without re-running
      resp_retry = Req.post!(req, url: "/api/v1/sessions/s-http-us/commands", json: valid_body)
      assert resp_retry.status == 200
      assert resp_retry.body["submission_id"] == sub_id
      assert resp_retry.body["status"] == "done"

      {:ok, %{items: items}} = Daemon.scan_entries("s-http-us", "1", %{"order" => "asc"}, opts)
      assert length(items) == 1

      # 409 on request_id reuse with ambiguous/different payload
      resp_ambig =
        Req.post!(req,
          url: "/api/v1/sessions/s-http-us/commands",
          json:
            cmd("us-ok-1", "user_shell", "1", %{
              "command" => "printf 'different'",
              "include_in_context" => true,
              "expected_seq" => seq0
            })
        )

      assert resp_ambig.status == 409

      # Same-batch racing commands with identical expected_seq -> one succeeds, one fails 409
      {:ok, {:snapshot, latest_seq, _}} =
        Daemon.subscribe_conversation("s-http-us", "1", self(), nil, opts)

      t1 =
        Task.async(fn ->
          Daemon.execute_command(
            "s-http-us",
            cmd("us-race-1", "user_shell", "1", %{
              "command" => "sleep 0.2",
              "include_in_context" => false,
              "expected_seq" => latest_seq
            }),
            opts
          )
        end)

      t2 =
        Task.async(fn ->
          Daemon.execute_command(
            "s-http-us",
            cmd("us-race-2", "user_shell", "1", %{
              "command" => "sleep 0.2",
              "include_in_context" => false,
              "expected_seq" => latest_seq
            }),
            opts
          )
        end)

      results = Task.await_many([t1, t2])
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1

      assert Enum.count(
               results,
               &match?({:error, {:conflict, "expected_seq mismatch"}}, &1)
             ) == 1
    end

    test "rejects user_shell when generation is active (conversation_busy)" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_daemon_env([
          {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Done"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-gen-busy", "cwd" => cwd}, opts)

      {:ok, %{seq: seq1}} =
        Daemon.execute_command(
          "s-gen-busy",
          cmd("r1", "submit", "1", %{"type" => "input", "content" => "Run"}),
          opts
        )

      assert_receive {:gate_entered, ^gate, gpid}

      assert {:error, {:conflict, "conversation_busy"}} =
               Daemon.execute_command(
                 "s-gen-busy",
                 cmd("us-busy", "user_shell", "1", %{
                   "command" => "echo blocked",
                   "include_in_context" => true,
                   "expected_seq" => seq1
                 }),
                 opts
               )

      send(gpid, {:release, gate})
    end
  end

  describe "included (!) vs excluded (!!) context, continue, search_history, and follow_up drain" do
    test "never exposes excluded user_shell to provider or search_history, while included enters context and continues" do
      %{opts: opts, cwd: cwd, fake: fake} =
        start_daemon_env([
          # 1. Model answers initial prompt
          {:reply, [], %{content: [%{type: "text", text: "Ack 1"}]}},
          # 2. Model answers continue after ! (included user_shell) and calls search_history
          {:expect,
           fn req ->
             texts =
               req.messages
               |> Enum.flat_map(& &1.content)
               |> Enum.map(&Map.get(&1, :text, ""))
               |> Enum.join("\n")

             assert texts =~ "included_cmd_output"
             refute texts =~ "EXCLUDED_SECRET_CMD"
             refute texts =~ "EXCLUDED_SECRET_OUT"
             true
           end,
           {:reply, [],
            %{
              content: [],
              tool_calls: [
                %{
                  id: "call_sh",
                  name: "search_history",
                  arguments: %{"query" => "EXCLUDED_SECRET"}
                }
              ],
              finish_reason: "tool_calls"
            }}},
          # 3. search_history never returns excluded user_shell entry (even when searching its query)
          {:expect,
           fn req ->
             tool_msg = Enum.find(req.messages, &(&1.role == "tool"))
             text = hd(tool_msg.content).text
             refute text =~ "user_shell"
             refute text =~ "EXCLUDED_SECRET_OUT"
             refute text =~ "EXCLUDED_SECRET_CMD"
             true
           end, {:reply, [], %{content: [%{type: "text", text: "Nothing secret found"}]}}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-ctx", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-ctx",
          cmd("sub-1", "submit", "1", %{"type" => "input", "content" => "Hello"}),
          opts
        )

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-ctx", "1", %{"order" => "asc"}, opts)
        if length(items) == 2, do: items, else: nil
      end)

      # Run !! (exclude from context)
      {:ok, {:snapshot, seq_after_turn1, _}} =
        Daemon.subscribe_conversation("s-ctx", "1", self(), nil, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-ctx",
          cmd("us-exc", "user_shell", "1", %{
            "command" => "echo EXCLUDED_SECRET_OUT # EXCLUDED_SECRET_CMD",
            "include_in_context" => false,
            "expected_seq" => seq_after_turn1
          }),
          opts
        )

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-ctx", "1", %{"order" => "asc"}, opts)
        if length(items) == 3, do: items, else: nil
      end)

      # submit(continue) after !! must NOT run model (last visible entry is assistant!)
      {:ok, cont_unanswered} =
        Daemon.execute_command(
          "s-ctx",
          cmd("cont-after-exc", "submit", "1", %{"type" => "continue"}),
          opts
        )

      assert cont_unanswered.status == "unanswered"
      assert cont_unanswered.reason == "nothing_to_answer"
      assert length(Fake.requests(fake)) == 1

      # Run ! (include in context)
      {:ok, {:snapshot, seq_after_exc, _}} =
        Daemon.subscribe_conversation("s-ctx", "1", self(), nil, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-ctx",
          cmd("us-inc", "user_shell", "1", %{
            "command" => "printf 'included_cmd_output'",
            "include_in_context" => true,
            "expected_seq" => seq_after_exc
          }),
          opts
        )

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-ctx", "1", %{"order" => "asc"}, opts)
        if length(items) == 4, do: items, else: nil
      end)

      # submit(continue) after ! triggers model turn + search_history check
      {:ok, cont_placed} =
        Daemon.execute_command(
          "s-ctx",
          cmd("cont-after-inc", "submit", "1", %{"type" => "continue"}),
          opts
        )

      assert cont_placed.status == "placed"

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-ctx", "1", %{"order" => "asc"}, opts)
          if length(items) == 7, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == [
               "user",
               "assistant",
               "user_shell",
               "user_shell",
               "assistant",
               "tool_result",
               "assistant"
             ]

      assert List.last(items).data["content"] == [
               %{"type" => "text", "text" => "Nothing secret found"}
             ]
    end

    test "drains follow_up inbox queued while user_shell was running" do
      %{opts: opts, cwd: cwd, fake: fake} =
        start_daemon_env([
          {:expect,
           fn req ->
             texts =
               req.messages
               |> Enum.flat_map(& &1.content)
               |> Enum.map(&Map.get(&1, :text, ""))
               |> Enum.join("\n")

             assert texts =~ "shell-done-first"
             assert texts =~ "Follow up after shell"
             true
           end, {:reply, [], %{content: [%{type: "text", text: "Answered follow up"}]}}}
        ])

      {:ok, %{seq: seq0}} =
        Daemon.create_session(%{"session_id" => "s-drain", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-drain",
          cmd("us-1", "user_shell", "1", %{
            "command" => "sleep 0.15; echo shell-done-first",
            "include_in_context" => true,
            "expected_seq" => seq0
          }),
          opts
        )

      {:ok, queued} =
        Daemon.execute_command(
          "s-drain",
          cmd("fu-1", "submit", "1", %{
            "type" => "input",
            "content" => "Follow up after shell",
            "when_busy" => "follow_up"
          }),
          opts
        )

      assert queued.status == "queued"

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-drain", "1", %{"order" => "asc"}, opts)
          if length(items) == 3, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == ["user_shell", "user", "assistant"]
      assert length(Fake.requests(fake)) == 1
    end
  end

  describe "bound remote env, workspace lease, and abort cancellation" do
    test "executes on bound Remote env and enforces cross-session workspace lease" do
      id = System.unique_integer([:positive, :monotonic])
      tmp_root = Path.join(System.tmp_dir!(), "h-us-int-rem-#{id}")
      remote_cwd = Path.join(tmp_root, "remote_ws")
      File.mkdir_p!(remote_cwd)
      on_exit(fn -> File.rm_rf(tmp_root) end)

      host_backing = Host.new(remote_cwd, env_id: "remote-vm-#{id}")
      agent = start_supervised!({RemoteAgent, env: host_backing, id: "remote-vm-#{id}"})

      %{opts: base_opts} =
        start_daemon_env([],
          environments: [
            %{
              id: "remote-vm-#{id}",
              kind: "remote",
              default_cwd: remote_cwd,
              build: fn cwd -> Remote.new(agent, cwd) end
            }
          ]
        )

      {:ok, %{seq: r_seq0}} =
        Daemon.create_session(
          %{"session_id" => "s-rem", "env_id" => "remote-vm-#{id}", "cwd" => remote_cwd},
          base_opts
        )

      {:ok, %{seq: h_seq0}} =
        Daemon.create_session(
          %{"session_id" => "s-host-1", "cwd" => remote_cwd},
          base_opts
        )

      {:ok, %{seq: h_seq2}} =
        Daemon.create_session(
          %{"session_id" => "s-host-2", "cwd" => remote_cwd},
          base_opts
        )

      # s-host-1 runs slow user_shell holding {"host", remote_cwd} lease
      {:ok, _} =
        Daemon.execute_command(
          "s-host-1",
          cmd("h1-us", "user_shell", "1", %{
            "command" => "echo holding-lease; sleep 0.4",
            "include_in_context" => true,
            "expected_seq" => h_seq0
          }),
          base_opts
        )

      # Wait until s-host-1 has acquired lease and started running
      wait_until(fn ->
        {:ok, {:snapshot, _, bin}} =
          Daemon.subscribe_conversation("s-host-1", "1", self(), nil, base_opts)

        status = JSON.decode!(bin) |> get_in(["docs", "live", "user_shell", "status"])
        if status == "running", do: true, else: nil
      end)

      # s-host-2 waits at the same {"host", remote_cwd} without spawning
      marker = Path.join(remote_cwd, "should_not_exist.txt")

      {:ok, _} =
        Daemon.execute_command(
          "s-host-2",
          cmd("h2-us", "user_shell", "1", %{
            "command" => "touch #{marker}",
            "include_in_context" => true,
            "expected_seq" => h_seq2
          }),
          base_opts
        )

      wait_until(fn ->
        {:ok, {:snapshot, _, bin}} =
          Daemon.subscribe_conversation("s-host-2", "1", self(), nil, base_opts)

        JSON.decode!(bin) |> get_in(["docs", "live", "workspace_wait"])
      end)

      refute File.exists?(marker)

      # Meanwhile s-rem on {"remote-vm-#{id}", remote_cwd} succeeds concurrently!
      {:ok, _} =
        Daemon.execute_command(
          "s-rem",
          cmd("r-us", "user_shell", "1", %{
            "command" => "printf 'remote-ok'",
            "include_in_context" => true,
            "expected_seq" => r_seq0
          }),
          base_opts
        )

      rem_items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries("s-rem", "1", %{"order" => "asc"}, base_opts)

          if length(items) == 1, do: items, else: nil
        end)

      assert hd(rem_items).data["output"] == "remote-ok"

      wait_until(fn ->
        {:ok, %{items: items}} =
          Daemon.scan_entries("s-host-2", "1", %{"order" => "asc"}, base_opts)

        if length(items) == 1, do: items, else: nil
      end)

      assert File.exists?(marker)

      wait_until(fn ->
        {:ok, %{items: items}} =
          Daemon.scan_entries("s-host-1", "1", %{"order" => "asc"}, base_opts)

        if length(items) == 1, do: items, else: nil
      end)
    end

    test "cancel wait removes queued work without stopping the holder" do
      %{opts: opts, cwd: cwd, lease: lease} = start_daemon_env()
      :ok = WorkspaceLease.acquire(lease, {"host", cwd}, {"holder", 1}, self())
      {:ok, %{seq: seq}} = Daemon.create_session(%{"session_id" => "waiter", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "waiter",
          cmd("wait", "user_shell", "1", %{
            "command" => "printf ran > marker",
            "include_in_context" => true,
            "expected_seq" => seq
          }),
          opts
        )

      wait =
        wait_until(fn ->
          {:ok, {:snapshot, _, bin}} =
            Daemon.subscribe_conversation("waiter", "1", self(), nil, opts)

          JSON.decode!(bin)["docs"]["live"]["workspace_wait"]
        end)

      args = %{"action" => "cancel", "task_id" => wait["task_id"], "lease_id" => wait["lease_id"]}
      replacement = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(replacement, :kill) end)
      :ok = WorkspaceLease.acquire(lease, {"host", cwd}, {"holder", 1}, replacement)

      wait_until(fn ->
        {:ok, {:snapshot, _, bin}} =
          Daemon.subscribe_conversation("waiter", "1", self(), nil, opts)

        JSON.decode!(bin)["docs"]["live"]["workspace_wait"]["lease_id"] != wait["lease_id"]
      end)

      {:ok, receipt} =
        Daemon.execute_command("waiter", cmd("cancel", "workspace_wait", "1", args), opts)

      assert {:ok, ^receipt} =
               Daemon.execute_command("waiter", cmd("cancel", "workspace_wait", "1", args), opts)

      assert {:error, {:workspace_busy, {"holder", 1}}} =
               WorkspaceLease.acquire(lease, {"host", cwd}, {"probe", 1}, self())

      :ok = WorkspaceLease.release(lease, {"host", cwd}, {"holder", 1})
      {:ok, {:snapshot, _, bin}} = Daemon.subscribe_conversation("waiter", "1", self(), nil, opts)
      snap = JSON.decode!(bin)
      refute snap["docs"]["live"]["workspace_wait"]
      assert hd(snap["entries"])["data"]["diagnostic"] == "aborted"
      refute File.exists?(Path.join(cwd, "marker"))
      assert :ok = WorkspaceLease.acquire(lease, {"host", cwd}, {"probe", 1}, self())
    end

    test "stop holder and acquire waits for process-group cleanup and rejects stale actions" do
      %{opts: opts, cwd: cwd} = start_daemon_env([], ephemeral_interval_ms: 5)

      {:ok, %{seq: owner_seq}} =
        Daemon.create_session(%{"session_id" => "holder", "cwd" => cwd}, opts)

      {:ok, %{seq: seq}} = Daemon.create_session(%{"session_id" => "waiter", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "holder",
          cmd("hold", "user_shell", "1", %{
            "command" => "sleep 120 & echo child_pid=$!; wait",
            "include_in_context" => true,
            "expected_seq" => owner_seq
          }),
          opts
        )

      child_pid =
        wait_until(fn ->
          {:ok, {:snapshot, _, bin}} =
            Daemon.subscribe_conversation("holder", "1", self(), nil, opts)

          out = JSON.decode!(bin)["docs"]["live"]["user_shell"]["output"] || ""

          case Regex.run(~r/child_pid=(\d+)/, out) do
            [_, pid] -> pid
            nil -> nil
          end
        end)

      command =
        "if kill -0 #{child_pid} 2>/dev/null; then printf overlap; else printf acquired; fi"

      {:ok, _} =
        Daemon.execute_command(
          "waiter",
          cmd("wait", "user_shell", "1", %{
            "command" => command,
            "include_in_context" => true,
            "expected_seq" => seq
          }),
          opts
        )

      wait =
        wait_until(fn ->
          {:ok, {:snapshot, _, bin}} =
            Daemon.subscribe_conversation("waiter", "1", self(), nil, opts)

          JSON.decode!(bin)["docs"]["live"]["workspace_wait"]
        end)

      args = %{
        "action" => "stop_holder",
        "task_id" => wait["task_id"],
        "lease_id" => wait["lease_id"]
      }

      {:ok, receipt} =
        Daemon.execute_command("waiter", cmd("take", "workspace_wait", "1", args), opts)

      result =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("waiter", "1", %{"order" => "asc"}, opts)
          List.first(items)
        end)

      assert result.data["output"] == "acquired"

      {:ok, %{items: [holder_result]}} =
        Daemon.scan_entries("holder", "1", %{"order" => "asc"}, opts)

      assert holder_result.data["diagnostic"] == "aborted"

      assert {:ok, ^receipt} =
               Daemon.execute_command("waiter", cmd("take", "workspace_wait", "1", args), opts)

      assert {:error, {:conflict, "stale_workspace_wait"}} =
               Daemon.execute_command("waiter", cmd("stale", "workspace_wait", "1", args), opts)
    end

    test "pending lease wait resumes after coordinator restart without replaying an execution" do
      %{opts: opts, cwd: cwd, lease: lease} = start_daemon_env()
      :ok = WorkspaceLease.acquire(lease, {"host", cwd}, {"holder", 1}, self())
      {:ok, %{seq: seq}} = Daemon.create_session(%{"session_id" => "waiter", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "waiter",
          cmd("wait", "user_shell", "1", %{
            "command" => "printf tick >> count",
            "include_in_context" => true,
            "expected_seq" => seq
          }),
          opts
        )

      wait_until(fn ->
        {:ok, {:snapshot, _, bin}} =
          Daemon.subscribe_conversation("waiter", "1", self(), nil, opts)

        JSON.decode!(bin)["docs"]["live"]["workspace_wait"]
      end)

      :ok = H.Session.Supervisor.stop_session(opts[:registry], opts[:runtime_sup], "waiter")
      {:ok, _} = Daemon.get_session_detail("waiter", opts)
      :ok = WorkspaceLease.release(lease, {"host", cwd}, {"holder", 1})

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("waiter", "1", %{"order" => "asc"}, opts)
        List.first(items)
      end)

      assert File.read!(Path.join(cwd, "count")) == "tick"
    end

    test "abort command cancels running user_shell, captures partial output, reaps PGID, and releases lease" do
      %{opts: opts, cwd: cwd, lease: lease} =
        start_daemon_env([], ephemeral_interval_ms: 5, persist_within_ms: 15)

      {:ok, %{seq: seq0}} = Daemon.create_session(%{"session_id" => "s-ab", "cwd" => cwd}, opts)

      {:ok, us_receipt} =
        Daemon.execute_command(
          "s-ab",
          cmd("us-ab", "user_shell", "1", %{
            "command" => "sleep 120 & echo child_pid=$!; echo abort-partial; sleep 120",
            "include_in_context" => false,
            "expected_seq" => seq0
          }),
          opts
        )

      wait_until(fn ->
        {:ok, {:snapshot, _, bin}} =
          Daemon.subscribe_conversation("s-ab", "1", self(), nil, opts)

        out = JSON.decode!(bin) |> get_in(["docs", "live", "user_shell", "output"]) || ""

        if String.contains?(out, "abort-partial") and String.contains?(out, "child_pid="),
          do: out,
          else: nil
      end)

      assert {:ok, %{status: "done"}} =
               Daemon.execute_command("s-ab", cmd("ab-1", "abort", "1", %{}), opts)

      {:ok, %{items: [entry]}} = Daemon.scan_entries("s-ab", "1", %{"order" => "asc"}, opts)
      assert entry.kind == "user_shell"
      assert entry.data["cancelled"] == true
      assert entry.data["diagnostic"] == "aborted"
      assert entry.data["is_error"] == true
      assert entry.data["include_in_context"] == false
      assert entry.data["output"] =~ "abort-partial"

      # Reaped PGID
      [_, child_pid] = Regex.run(~r/child_pid=(\d+)/, entry.data["output"])

      wait_until(fn ->
        {_, status} = System.cmd("/bin/kill", ["-0", child_pid], stderr_to_stdout: true)
        status != 0
      end)

      # Lease released
      assert :ok = WorkspaceLease.acquire(lease, {"host", cwd}, {"after-abort", 1}, self())
      :ok = WorkspaceLease.release(lease, {"host", cwd}, {"after-abort", 1})

      # Retry of aborted user_shell submission returns unanswered without re-running
      {:ok, retry_receipt} =
        Daemon.execute_command(
          "s-ab",
          cmd("us-ab", "user_shell", "1", %{
            "command" => "sleep 120 & echo child_pid=$!; echo abort-partial; sleep 120",
            "include_in_context" => false,
            "expected_seq" => seq0
          }),
          opts
        )

      assert retry_receipt.submission_id == us_receipt.submission_id
      assert retry_receipt.status == "unanswered"
      assert retry_receipt.reason == "aborted"
    end
  end

  describe "clean shutdown and real SIGKILL VM restart (no replay)" do
    test "clean shutdown mid-user_shell recovers interrupted without replay" do
      %{opts: opts, cwd: cwd, data_dir: data_dir} =
        start_daemon_env([],
          storage_opts: [sync: :datasync],
          ephemeral_interval_ms: 5,
          persist_within_ms: 15
        )

      count_file = Path.join(cwd, "clean_count.txt")

      {:ok, %{seq: seq0}} =
        Daemon.create_session(%{"session_id" => "s-clean", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-clean",
          cmd("us-clean", "user_shell", "1", %{
            "command" => "echo ran >> #{count_file}; echo clean-partial; sleep 5",
            "include_in_context" => true,
            "expected_seq" => seq0
          }),
          opts
        )

      wait_until(fn ->
        {:ok, {:snapshot, _, bin}} =
          Daemon.subscribe_conversation("s-clean", "1", self(), nil, opts)

        out = JSON.decode!(bin) |> get_in(["docs", "live", "user_shell", "output"]) || ""
        if String.contains?(out, "clean-partial"), do: true, else: nil
      end)

      # Cleanly stop Session.Supervisor
      [{_, sup_pid, _, _}] = DynamicSupervisor.which_children(opts[:runtime_sup])
      :ok = DynamicSupervisor.terminate_child(opts[:runtime_sup], sup_pid)

      %{opts: opts2} = restart_daemon_env(data_dir, [], storage_opts: [sync: :datasync])
      assert :ok = Daemon.recover_active_sessions(opts2)

      {:ok, %{items: [entry]}} = Daemon.scan_entries("s-clean", "1", %{"order" => "asc"}, opts2)
      assert entry.kind == "user_shell"
      assert entry.data["diagnostic"] == "interrupted"
      assert entry.data["is_error"] == true
      assert entry.data["output"] =~ "clean-partial"
      assert File.read!(count_file) == "ran\n"
    end

    @tag timeout: 20_000
    test "SIGKILL of daemon OS process mid-user_shell recovers interrupted with no replay, idempotency, and context isolation" do
      id = System.unique_integer([:positive])
      tmp_root = Path.join(System.tmp_dir!(), "h-us-int-vm-#{id}")
      data_dir = Path.join(tmp_root, "data")
      cwd = Path.join(tmp_root, "work")
      File.mkdir_p!(data_dir)
      File.mkdir_p!(cwd)

      on_exit(fn ->
        File.rm(StoreLock.socket_path(data_dir))
        File.rm_rf(tmp_root)
      end)

      elixir_exe = System.find_executable("elixir")
      assert is_binary(elixir_exe)

      pa_args =
        :code.get_path()
        |> Enum.map(&List.to_string/1)
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(fn dir -> ["-pa", dir] end)

      count_file = Path.join(cwd, "vm_daemon_count.txt")

      child_script = """
      Application.ensure_all_started(:logger)
      Application.ensure_all_started(:crypto)

      data_dir = System.fetch_env!("H_TEST_DATA_DIR")
      cwd = System.fetch_env!("H_TEST_CWD")
      count_file = System.fetch_env!("H_TEST_COUNT_FILE")

      {:ok, _} = H.StoreLock.start_link(data_dir: data_dir, name: H.StoreLock)
      {:ok, _} = Registry.start_link(keys: :unique, name: H.Registry)
      {:ok, _} = Registry.start_link(keys: :duplicate, name: H.PubSub)
      {:ok, _} = H.Catalog.start_link(data_dir: data_dir, name: H.Catalog, table: :h_catalog)
      {:ok, _} = H.WorkspaceLease.start_link(name: H.WorkspaceLease)
      {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: H.Session.RuntimeSupervisor)

      {:ok, fake} = H.Provider.Fake.start_link(script: [])

      opts = [
        data_dir: data_dir,
        provider: H.Provider.Fake,
        provider_config: %{server: fake},
        storage_mod: H.Storage.File,
        storage_opts: [sync: :datasync],
        persist_within_ms: 15,
        ephemeral_interval_ms: 5,
        default_model: "fake:coder"
      ]

      {:ok, %{seq: seq0}} = H.Daemon.create_session(%{"session_id" => "vm-us", "cwd" => cwd}, opts)

      {:ok, _} =
        H.Daemon.execute_command(
          "vm-us",
          %{
            "version" => 1,
            "request_id" => "vm-us-req",
            "command" => "user_shell",
            "conversation_id" => "1",
            "args" => %{
              "command" => "echo ran >> \#{count_file}; echo vm-daemon-partial; sleep 5",
              "include_in_context" => false,
              "expected_seq" => seq0
            }
          },
          opts
        )

      wait_flushed = fn wait_flushed ->
        {:ok, {:snapshot, _seq, bin}} =
          H.Daemon.subscribe_conversation("vm-us", "1", self(), nil, opts)

        out = JSON.decode!(bin) |> get_in(["docs", "live", "user_shell", "output"]) || ""

        if String.contains?(out, "vm-daemon-partial") do
          :ok
        else
          Process.sleep(15)
          wait_flushed.(wait_flushed)
        end
      end

      wait_flushed.(wait_flushed)
      IO.puts("READY:" <> System.pid())

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
          {:line, 4096},
          {:args, pa_args ++ ["-e", child_script]},
          {:env,
           [
             {~c"H_TEST_DATA_DIR", String.to_charlist(data_dir)},
             {~c"H_TEST_CWD", String.to_charlist(cwd)},
             {~c"H_TEST_COUNT_FILE", String.to_charlist(count_file)}
           ]}
        ])

      os_pid = await_ready_pid(port)

      on_exit(fn ->
        if Port.info(port) != nil, do: Port.close(port)
        System.cmd("kill", ["-9", os_pid], stderr_to_stdout: true)
      end)

      assert {:error, :store_locked} = StoreLock.start_link(data_dir: data_dir)

      # SIGKILL mid-user_shell!
      {_out, 0} = System.cmd("kill", ["-9", os_pid])
      assert_receive {^port, {:exit_status, _status}}, 5_000

      # Boot fresh supervisor tree on the exact same data_dir
      start_supervised!({StoreLock, data_dir: data_dir, name: :"H.UsVmInt.Lock.#{id}"})

      %{opts: opts2, fake: fake2, lease: lease2} =
        restart_daemon_env(
          data_dir,
          [
            {:expect,
             fn req ->
               texts =
                 req.messages
                 |> Enum.flat_map(& &1.content)
                 |> Enum.map(&Map.get(&1, :text, ""))
                 |> Enum.join("\n")

               refute texts =~ "vm-daemon-partial"
               refute texts =~ "vm_daemon_count"
               assert texts =~ "After recovery"
               true
             end, {:reply, [], %{content: [%{type: "text", text: "Clean post-crash reply"}]}}}
          ],
          storage_opts: [sync: :datasync]
        )

      # Boot recovery reconciles interrupted user_shell BEFORE client attach
      assert :ok = Daemon.recover_active_sessions(opts2)

      {:ok, %{items: [entry]}} = Daemon.scan_entries("vm-us", "1", %{"order" => "asc"}, opts2)
      assert entry.kind == "user_shell"
      assert entry.data["diagnostic"] == "interrupted"
      assert entry.data["is_error"] == true
      assert entry.data["include_in_context"] == false
      assert entry.data["output"] =~ "vm-daemon-partial"

      # Executed EXACTLY ONCE (never replayed on VM restart!)
      assert File.read!(count_file) == "ran\n"

      # Idempotent retry of original request_id returns unanswered/interrupted without re-executing
      {:ok, retry_receipt} =
        Daemon.execute_command(
          "vm-us",
          cmd("vm-us-req", "user_shell", "1", %{
            "command" => "echo ran >> #{count_file}; echo vm-daemon-partial; sleep 5",
            "include_in_context" => false,
            "expected_seq" => 1
          }),
          opts2
        )

      assert retry_receipt.status == "unanswered"
      assert retry_receipt.reason == "interrupted"
      assert File.read!(count_file) == "ran\n"

      # Lease available and subsequent turn never sees excluded interrupted output
      assert :ok = WorkspaceLease.acquire(lease2, {"host", cwd}, {"check", 1}, self())
      :ok = WorkspaceLease.release(lease2, {"host", cwd}, {"check", 1})

      {:ok, _} =
        Daemon.execute_command(
          "vm-us",
          cmd("post-crash", "submit", "1", %{"type" => "input", "content" => "After recovery"}),
          opts2
        )

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("vm-us", "1", %{"order" => "asc"}, opts2)
          if length(items) == 3, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == ["user_shell", "user", "assistant"]
      assert length(Fake.requests(fake2)) == 1
    end
  end
end
