defmodule H.RenameTest do
  use ExUnit.Case, async: true

  alias H.{Auth, Catalog, Daemon}
  alias H.HTTP.Router
  alias H.Provider.Fake

  defp start_isolated_env(script \\ [], extra_opts \\ []) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-rename-test-#{id}")
    data_dir = Path.join(tmp_root, "data")
    parent_dir = Path.join(tmp_root, "projects")
    cwd = Path.join(parent_dir, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    registry = :"H.RenameTest.Registry.#{id}"
    pubsub = :"H.RenameTest.PubSub.#{id}"
    catalog = :"H.RenameTest.Catalog.#{id}"
    catalog_table = :"h_rename_test_catalog_#{id}"
    lease = :"H.RenameTest.Lease.#{id}"
    runtime_sup = :"H.RenameTest.RuntimeSup.#{id}"
    fake_name = :"H.RenameTest.Fake.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({H.WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})
    fake = start_supervised!({Fake, script: script, name: fake_name})

    on_exit(fn -> File.rm_rf(tmp_root) end)

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
          default_cwd: parent_dir,
          provider: Fake,
          provider_config: %{server: fake},
          storage_mod: H.Storage.File,
          storage_opts: [sync: :none],
          default_model: "fake:chat"
        ],
        extra_opts
      )

    %{opts: opts, cwd: cwd, parent_dir: parent_dir, data_dir: data_dir, tmp_root: tmp_root}
  end

  defp restart_daemon_env(data_dir, parent_dir, script, extra_opts) do
    id = System.unique_integer([:positive])
    registry = :"H.RenameTest.ReRegistry.#{id}"
    pubsub = :"H.RenameTest.RePubSub.#{id}"
    catalog = :"H.RenameTest.ReCatalog.#{id}"
    catalog_table = :"h_rename_test_recatalog_#{id}"
    lease = :"H.RenameTest.ReLease.#{id}"
    runtime_sup = :"H.RenameTest.ReRuntimeSup.#{id}"
    fake_name = :"H.RenameTest.ReFake.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry}, id: {:re_reg, id})
    start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: {:re_pub, id})

    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table},
      id: {:re_cat, id}
    )

    start_supervised!({H.WorkspaceLease, name: lease}, id: {:re_lease, id})

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
          default_cwd: parent_dir,
          provider: Fake,
          provider_config: %{server: fake},
          storage_mod: H.Storage.File,
          storage_opts: [sync: :none],
          default_model: "fake:chat"
        ],
        extra_opts
      )

    %{opts: opts, fake: fake}
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

  defp close_session!(sid, opts) do
    case Registry.lookup(opts[:registry], {:session, sid}) do
      [{pid, _}] ->
        ref = Process.monitor(pid)

        for {:undefined, sup_pid, :supervisor, [H.Session.Supervisor]} <-
              DynamicSupervisor.which_children(opts[:runtime_sup]) do
          if is_pid(sup_pid) do
            _ = DynamicSupervisor.terminate_child(opts[:runtime_sup], sup_pid)
          end
        end

        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      [] ->
        :ok
    end
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
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
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end

  describe "boundary validation and normalization" do
    test "rejects missing/invalid title, control chars, overlong titles, and unknown session/conversation" do
      %{opts: opts, cwd: cwd} = start_isolated_env()
      {:ok, _} = Daemon.create_session(%{"session_id" => "s-val", "cwd" => cwd}, opts)

      for bad_args <- [
            %{},
            %{"title" => 123},
            %{"title" => ["a"]},
            %{"title" => "bad\0title"},
            %{"title" => "bad\e[31mtitle"},
            %{"title" => String.duplicate("x", 201)},
            %{"title" => "Ok", "expected_seq" => -1}
          ] do
        assert {:error, {:bad_request, _}} =
                 Daemon.execute_command("s-val", cmd("r-bad", "rename", "1", bad_args), opts)
      end

      assert {:error, :not_found} =
               Daemon.execute_command(
                 "missing-sid",
                 cmd("r-nosid", "rename", "1", %{"title" => "Nope"}),
                 opts
               )

      assert {:error, :not_found} =
               Daemon.execute_command(
                 "s-val",
                 cmd("r-nocid", "rename", "999", %{"title" => "Nope"}),
                 opts
               )
    end

    test "normalizes whitespace/newlines and clears title on blank string or nil" do
      %{opts: opts, cwd: cwd, parent_dir: parent_dir} = start_isolated_env()

      {:ok, created} =
        Daemon.create_session(
          %{"session_id" => "s-norm", "cwd" => cwd, "title" => "  Seed\nName\t "},
          opts
        )

      assert created.session.title == "Seed Name"

      assert {:ok, r1} =
               Daemon.execute_command(
                 "s-norm",
                 cmd("r1", "rename", "1", %{"title" => "  Alpha\r\nBeta\tGamma  "}),
                 opts
               )

      assert r1 == %{
               version: 1,
               request_id: "r1",
               seq: r1.seq,
               status: "done",
               title: "Alpha Beta Gamma"
             }

      assert [%{session_id: "s-norm", title: "Alpha Beta Gamma"}] = Daemon.list_sessions(opts)
      assert {:ok, detail1} = Daemon.get_session_detail("s-norm", opts)
      assert detail1.session.title == "Alpha Beta Gamma"

      assert {:ok, browse1} = Daemon.browse_workspace(%{"path" => parent_dir}, opts)
      [work_dir1] = browse1.directories
      assert work_dir1.latest_session.title == "Alpha Beta Gamma"

      # Blank string explicitly clears title to nil
      assert {:ok, r2} =
               Daemon.execute_command(
                 "s-norm",
                 cmd("r2", "rename", "1", %{"title" => "  \n\t "}),
                 opts
               )

      assert r2.title == nil
      assert r2.seq > r1.seq

      assert [%{session_id: "s-norm", title: nil}] = Daemon.list_sessions(opts)
      assert {:ok, detail2} = Daemon.get_session_detail("s-norm", opts)
      assert detail2.session.title == nil
      assert {:ok, browse2} = Daemon.browse_workspace(%{"path" => parent_dir}, opts)
      [work_dir2] = browse2.directories
      assert work_dir2.latest_session.title == nil

      # Explicit nil also clears title
      assert {:ok, _} =
               Daemon.execute_command(
                 "s-norm",
                 cmd("r3", "rename", "1", %{"title" => "Back"}),
                 opts
               )

      assert {:ok, r4} =
               Daemon.execute_command(
                 "s-norm",
                 cmd("r4", "rename", "1", %{"title" => nil}),
                 opts
               )

      assert r4.title == nil
      assert [%{title: nil}] = Daemon.list_sessions(opts)
    end
  end

  describe "interaction with initial prompt auto-title" do
    test "explicit rename or explicit clear prevents initial prompt from overwriting title" do
      %{opts: opts, cwd: cwd} =
        start_isolated_env([
          {:reply, [], %{content: [%{type: "text", text: "Reply 1"}]}},
          {:reply, [], %{content: [%{type: "text", text: "Reply 2"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-explicit", "cwd" => cwd}, opts)

      # Explicitly clear before first prompt
      assert {:ok, %{title: nil}} =
               Daemon.execute_command(
                 "s-explicit",
                 cmd("ren-clear", "rename", "1", %{"title" => ""}),
                 opts
               )

      assert {:ok, _} =
               Daemon.execute_command(
                 "s-explicit",
                 cmd("sub-1", "submit", "1", %{
                   "type" => "input",
                   "content" => "Should not become title"
                 }),
                 opts
               )

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-explicit", "1", %{"order" => "asc"}, opts)
        if length(items) == 2, do: items, else: nil
      end)

      assert [%{title: nil}] = Daemon.list_sessions(opts)

      # Set custom title then send another prompt
      assert {:ok, %{title: "Pinned Title"}} =
               Daemon.execute_command(
                 "s-explicit",
                 cmd("ren-set", "rename", "1", %{"title" => "Pinned Title"}),
                 opts
               )

      assert {:ok, _} =
               Daemon.execute_command(
                 "s-explicit",
                 cmd("sub-2", "submit", "1", %{"type" => "input", "content" => "Second prompt"}),
                 opts
               )

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-explicit", "1", %{"order" => "asc"}, opts)
        if length(items) == 4, do: items, else: nil
      end)

      assert [%{title: "Pinned Title"}] = Daemon.list_sessions(opts)
    end
  end

  describe "optimistic concurrency and concurrent mailbox commands/receipts" do
    test "expected_seq enforces optimistic lock and rejects stale writers with 409" do
      %{opts: opts, cwd: cwd} = start_isolated_env()
      {:ok, created} = Daemon.create_session(%{"session_id" => "s-seq", "cwd" => cwd}, opts)

      assert {:ok, r1} =
               Daemon.execute_command(
                 "s-seq",
                 cmd("r1", "rename", "1", %{"title" => "V1", "expected_seq" => created.seq}),
                 opts
               )

      # Wrong expected_seq -> conflict without changing title
      assert {:error, {:conflict, "expected_seq mismatch"}} =
               Daemon.execute_command(
                 "s-seq",
                 cmd("r-stale", "rename", "1", %{"title" => "Nope", "expected_seq" => created.seq}),
                 opts
               )

      assert [%{title: "V1"}] = Daemon.list_sessions(opts)

      # Retrying r1 with original expected_seq succeeds idempotently
      assert {:ok, ^r1} =
               Daemon.execute_command(
                 "s-seq",
                 cmd("r1", "rename", "1", %{"title" => "V1", "expected_seq" => created.seq}),
                 opts
               )
    end

    test "concurrent rename commands produce distinct durable receipts and consistent final catalog/display" do
      %{opts: opts, cwd: cwd} = start_isolated_env()
      {:ok, _} = Daemon.create_session(%{"session_id" => "s-conc", "cwd" => cwd}, opts)

      tasks =
        for i <- 1..12 do
          Task.async(fn ->
            Daemon.execute_command(
              "s-conc",
              cmd("ren-#{i}", "rename", "1", %{"title" => "Name #{i}"}),
              opts
            )
          end)
        end

      results = Task.await_many(tasks)
      receipts = Enum.map(results, fn {:ok, receipt} -> receipt end)

      seqs = Enum.map(receipts, & &1.seq)
      min_seq = Enum.min(seqs)
      assert length(Enum.uniq(seqs)) == 12
      assert Enum.sort(seqs) == Enum.to_list(min_seq..(min_seq + 11))

      winner = Enum.max_by(receipts, & &1.seq)
      assert [%{title: final_title}] = Daemon.list_sessions(opts)
      assert final_title == winner.title

      assert {:ok, detail} = Daemon.get_session_detail("s-conc", opts)
      assert detail.session.title == winner.title

      # Every concurrent request_id returns its own original receipt on retry
      for r <- receipts do
        i = String.replace_prefix(r.request_id, "ren-", "")

        assert {:ok, ^r} =
                 Daemon.execute_command(
                   "s-conc",
                   cmd(r.request_id, "rename", "1", %{"title" => "Name #{i}"}),
                   opts
                 )
      end
    end

    test "concurrent identical request_ids and concurrent expected_seq races serialize cleanly" do
      %{opts: opts, cwd: cwd} = start_isolated_env()
      {:ok, created} = Daemon.create_session(%{"session_id" => "s-race", "cwd" => cwd}, opts)

      # Same request_id + same payload racing concurrently
      same_env = cmd("same-req", "rename", "1", %{"title" => "Same Race"})
      t1 = Task.async(fn -> Daemon.execute_command("s-race", same_env, opts) end)
      t2 = Task.async(fn -> Daemon.execute_command("s-race", same_env, opts) end)

      [{:ok, r1}, {:ok, r2}] = Task.await_many([t1, t2])
      assert r1 == r2
      assert r1.title == "Same Race"

      # Different request_ids racing on the same expected_seq -> exactly one wins, others 409
      {:ok, detail} = Daemon.get_session_detail("s-race", opts)
      assert detail.session.title == "Same Race"
      cur_seq = r1.seq

      race_tasks =
        for i <- 1..4 do
          Task.async(fn ->
            Daemon.execute_command(
              "s-race",
              cmd("cas-#{i}", "rename", "1", %{
                "title" => "Winner #{i}",
                "expected_seq" => cur_seq
              }),
              opts
            )
          end)
        end

      race_results = Task.await_many(race_tasks)
      oks = Enum.filter(race_results, &match?({:ok, _}, &1))

      conflicts =
        Enum.filter(race_results, &match?({:error, {:conflict, "expected_seq mismatch"}}, &1))

      assert length(oks) == 1
      assert length(conflicts) == 3

      [{:ok, win_receipt}] = oks
      assert [%{title: persisted_title}] = Daemon.list_sessions(opts)
      assert persisted_title == win_receipt.title
      assert created.seq < win_receipt.seq
    end
  end

  describe "active run safety and persistence across restart" do
    test "renaming during an active run updates catalog/SSE cleanly without disrupting the run" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_isolated_env([
          {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Turn done"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-active", "cwd" => cwd}, opts)

      {:ok, {:snapshot, _seq, _bin}} =
        Daemon.subscribe_conversation("s-active", "1", self(), nil, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-active",
          cmd("sub-1", "submit", "1", %{"type" => "input", "content" => "Initial prompt"}),
          opts
        )

      assert_receive {:gate_entered, ^gate, gpid}

      assert {:ok, ren_receipt} =
               Daemon.execute_command(
                 "s-active",
                 cmd("ren-mid", "rename", "1", %{"title" => "Mid-Run Title"}),
                 opts
               )

      assert ren_receipt.title == "Mid-Run Title"
      assert [%{title: "Mid-Run Title", active: true}] = Daemon.list_sessions(opts)

      send(gpid, {:release, gate})

      wait_until(fn ->
        case Daemon.list_sessions(opts) do
          [%{active: false, title: "Mid-Run Title"}] -> true
          _ -> false
        end
      end)

      assert {:ok, %{items: items}} =
               Daemon.scan_entries("s-active", "1", %{"order" => "asc"}, opts)

      assert Enum.map(items, & &1.kind) == ["user", "assistant"]
    end

    test "persists title, cleared nil, and original command receipts across snapshot rotation and full daemon restart" do
      %{opts: opts, cwd: cwd, parent_dir: parent_dir, data_dir: data_dir} =
        start_isolated_env(
          [{:reply, [], %{content: [%{type: "text", text: "Answer"}]}}],
          storage_opts: [sync: :datasync, snapshot_every: 2]
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-restart", "cwd" => cwd}, opts)

      env1 = cmd("ren-1", "rename", "1", %{"title" => "First Name"})
      env2 = cmd("ren-2", "rename", "1", %{"title" => "Second Name"})
      env3 = cmd("ren-3", "rename", "1", %{"title" => ""})

      assert {:ok, r1} = Daemon.execute_command("s-restart", env1, opts)
      assert {:ok, r2} = Daemon.execute_command("s-restart", env2, opts)
      assert {:ok, r3} = Daemon.execute_command("s-restart", env3, opts)

      assert r1.title == "First Name"
      assert r2.title == "Second Name"
      assert r3.title == nil
      assert r1.seq < r2.seq and r2.seq < r3.seq

      # Now set a final non-empty name
      env4 = cmd("ren-4", "rename", "1", %{"title" => "Persisted Final"})
      assert {:ok, r4} = Daemon.execute_command("s-restart", env4, opts)

      close_session!("s-restart", opts)

      session_dir = Path.join([data_dir, "sessions", "s-restart"])
      assert Enum.any?(File.ls!(session_dir), &String.starts_with?(&1, "snapshot."))

      # Restart fresh Catalog + Daemon supervisor tree from disk
      %{opts: opts2} =
        restart_daemon_env(
          data_dir,
          parent_dir,
          [{:reply, [], %{content: [%{type: "text", text: "After restart"}]}}],
          storage_opts: [sync: :datasync, snapshot_every: 2]
        )

      # Catalog-only list & browse work BEFORE waking Session.Server
      assert [%{session_id: "s-restart", title: "Persisted Final"}] = Daemon.list_sessions(opts2)
      assert {:ok, browse} = Daemon.browse_workspace(%{"path" => parent_dir}, opts2)
      assert [%{latest_session: %{title: "Persisted Final"}}] = browse.directories

      # Retrying every historical rename command returns its exact original seq & title receipt!
      assert {:ok, ^r1} = Daemon.execute_command("s-restart", env1, opts2)
      assert {:ok, ^r2} = Daemon.execute_command("s-restart", env2, opts2)
      assert {:ok, ^r3} = Daemon.execute_command("s-restart", env3, opts2)
      assert {:ok, ^r4} = Daemon.execute_command("s-restart", env4, opts2)

      # Title remains "Persisted Final"
      assert {:ok, detail} = Daemon.get_session_detail("s-restart", opts2)
      assert detail.session.title == "Persisted Final"

      # Reusing old request_id with different title conflicts 409
      assert {:error, {:conflict, _}} =
               Daemon.execute_command(
                 "s-restart",
                 cmd("ren-1", "rename", "1", %{"title" => "Tampered"}),
                 opts2
               )

      # Clear title, restart again, and verify nil survives restart AND subsequent prompt doesn't overwrite it
      env5 = cmd("ren-5", "rename", "1", %{"title" => nil})
      assert {:ok, r5} = Daemon.execute_command("s-restart", env5, opts2)
      assert r5.title == nil

      close_session!("s-restart", opts2)

      %{opts: opts3} =
        restart_daemon_env(
          data_dir,
          parent_dir,
          [{:reply, [], %{content: [%{type: "text", text: "After clear"}]}}],
          storage_opts: [sync: :datasync, snapshot_every: 2]
        )

      assert [%{session_id: "s-restart", title: nil}] = Daemon.list_sessions(opts3)
      assert {:ok, ^r5} = Daemon.execute_command("s-restart", env5, opts3)

      assert {:ok, _} =
               Daemon.execute_command(
                 "s-restart",
                 cmd("sub-after-clear", "submit", "1", %{
                   "type" => "input",
                   "content" => "Prompt after restart clear"
                 }),
                 opts3
               )

      wait_until(fn ->
        {:ok, %{items: items}} =
          Daemon.scan_entries("s-restart", "1", %{"order" => "asc"}, opts3)

        if length(items) == 2, do: items, else: nil
      end)

      assert [%{session_id: "s-restart", title: nil}] = Daemon.list_sessions(opts3)
    end

    test "reconciles stale catalog title from durable WAL session_meta after abrupt kill" do
      %{opts: opts, cwd: cwd, parent_dir: parent_dir, data_dir: data_dir} =
        start_isolated_env([], storage_opts: [sync: :datasync, snapshot_every: 200])

      {:ok, _} =
        Daemon.create_session(
          %{"session_id" => "s-wal", "cwd" => cwd, "title" => "Old Catalog Title"},
          opts
        )

      assert {:ok, r1} =
               Daemon.execute_command(
                 "s-wal",
                 cmd("ren-wal", "rename", "1", %{"title" => ""}),
                 opts
               )

      assert r1.title == nil

      # Kill server abruptly and manually corrupt Catalog back to stale title to simulate crash window
      [{server_pid, _}] = Registry.lookup(opts[:registry], {:session, "s-wal"})
      ref = Process.monitor(server_pid)
      Process.exit(server_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^server_pid, :killed}

      {:ok, _} = Catalog.report_runtime(opts[:catalog], "s-wal", %{title: "Stale Catalog Title"})

      %{opts: opts2} =
        restart_daemon_env(data_dir, parent_dir, [],
          storage_opts: [sync: :datasync, snapshot_every: 200]
        )

      # Waking session reconciles durable session_meta (nil) over stale Catalog title!
      assert {:ok, detail} = Daemon.get_session_detail("s-wal", opts2)
      assert detail.session.title == nil
      assert [%{session_id: "s-wal", title: nil}] = Daemon.list_sessions(opts2)
    end
  end

  describe "HTTP API router integration" do
    test "POST /api/v1/sessions/:sid/commands rename updates /sessions, /fs, and /sessions/:sid" do
      Application.ensure_all_started(:req)

      %{opts: daemon_opts, cwd: cwd, parent_dir: parent_dir, tmp_root: tmp_root} =
        start_isolated_env()

      id = System.unique_integer([:positive])
      auth_table = :"h_rename_http_auth_#{id}"
      auth_server = :"H.RenameTest.Auth.#{id}"
      auth_dir = Path.join(tmp_root, "auth")
      File.mkdir_p!(auth_dir)

      start_supervised!({Auth, data_dir: auth_dir, name: auth_server, table: auth_table})
      token = Auth.owner_token(auth_table)

      router_opts = [
        port: 4000,
        auth_server: auth_server,
        auth_table: auth_table,
        daemon: H.Daemon,
        daemon_opts: daemon_opts
      ]

      req =
        Req.new(
          base_url: "http://127.0.0.1:4000",
          plug: {Router, router_opts},
          headers: [{"host", "127.0.0.1:4000"}, {"authorization", "Bearer #{token}"}],
          retry: false
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-http", "cwd" => cwd}, daemon_opts)

      # 422 on invalid args
      resp_422 =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: cmd("ren-bad", "rename", "1", %{"title" => "bad\0"})
        )

      assert resp_422.status == 422

      # 200 on rename
      body = cmd("ren-http-1", "rename", "1", %{"title" => "  HTTP\nTitle  "})

      resp_200 =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: body
        )

      assert resp_200.status == 200

      assert %{
               "version" => 1,
               "request_id" => "ren-http-1",
               "status" => "done",
               "title" => "HTTP Title",
               "seq" => seq
             } = resp_200.body

      assert is_integer(seq)

      # Idempotent retry returns exact same JSON
      resp_retry =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: body
        )

      assert resp_retry.status == 200
      assert resp_retry.body == resp_200.body

      # Mismatched payload returns 409
      resp_409 =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: cmd("ren-http-1", "rename", "1", %{"title" => "Other"})
        )

      assert resp_409.status == 409

      # Display routes reflect updated title
      sessions_body = Req.get!(req, url: "/api/v1/sessions").body
      assert [%{"session_id" => "s-http", "title" => "HTTP Title"}] = sessions_body["sessions"]

      detail_body = Req.get!(req, url: "/api/v1/sessions/s-http").body
      assert detail_body["session"]["title"] == "HTTP Title"

      fs_body = Req.get!(req, url: "/api/v1/fs", params: [path: parent_dir]).body
      assert [%{"latest_session" => %{"title" => "HTTP Title"}}] = fs_body["directories"]
    end
  end
end
