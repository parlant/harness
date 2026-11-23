defmodule H.SubmissionSignalTest do
  use ExUnit.Case, async: true

  alias H.{Auth, Catalog, Daemon}
  alias H.HTTP.Router
  alias H.Provider.Fake

  defp start_isolated_env(script) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-sub-signal-test-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    registry = :"H.SubSignalTest.Registry.#{id}"
    pubsub = :"H.SubSignalTest.PubSub.#{id}"
    catalog = :"H.SubSignalTest.Catalog.#{id}"
    catalog_table = :"h_sub_signal_test_catalog_#{id}"
    lease = :"H.SubSignalTest.Lease.#{id}"
    runtime_sup = :"H.SubSignalTest.RuntimeSup.#{id}"
    fake_name = :"H.SubSignalTest.Fake.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})

    start_supervised!(
      {Catalog, data_dir: data_dir, name: catalog, table: catalog_table, pubsub: pubsub}
    )

    start_supervised!({H.WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})
    fake = start_supervised!({Fake, script: script, name: fake_name})

    on_exit(fn -> File.rm_rf(tmp_root) end)

    opts = [
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
      default_model: "fake:chat"
    ]

    %{
      opts: opts,
      cwd: cwd,
      data_dir: data_dir,
      tmp_root: tmp_root,
      pubsub: pubsub,
      fake: fake
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

  describe "Daemon.watch_submission/4 and settlement signals" do
    test "delivers {:submission_settled, outcome} with status done and answer_text after multi-turn tool + generation completion" do
      gate = make_ref()
      test_pid = self()

      env =
        start_isolated_env([
          {:gate, [], test_pid, gate,
           %{
             content: [%{type: "text", text: "Let me read the file."}],
             tool_calls: [%{id: "call_1", name: "read", arguments: %{"path" => "note.txt"}}],
             finish_reason: "tool_calls"
           }},
          {:reply, [],
           %{
             content: [
               %{type: "text", text: "Found: "},
               %{type: "text", text: "hello signal!"}
             ]
           }}
        ])

      File.write!(Path.join(env.cwd, "note.txt"), "hello signal!\n")
      {:ok, _} = Daemon.create_session(%{"session_id" => "s-multi", "cwd" => env.cwd}, env.opts)

      # Also subscribe to {:session_signals, "s-multi"} to verify fan-out
      Registry.register(env.pubsub, {:session_signals, "s-multi"}, nil)

      {:ok, receipt} =
        Daemon.execute_command(
          "s-multi",
          cmd("req-multi", "submit", "1", %{"type" => "input", "content" => "Read note.txt"}),
          env.opts
        )

      assert receipt.status == "placed"
      assert_receive {:gate_entered, ^gate, gpid}

      # Register race-free watcher while submission is placed / running
      assert {:ok, {:pending, pending_outcome}} =
               Daemon.watch_submission("s-multi", "req-multi", self(), env.opts)

      assert pending_outcome.status == "placed"
      assert pending_outcome.request_id == "req-multi"
      assert pending_outcome.answer_text == nil
      assert {:submission, "s-multi", "req-multi"} in Registry.keys(env.pubsub, self())

      # Release gate -> tool executes -> second turn completes -> settlement signal fires
      send(gpid, {:release, gate})

      assert_receive {:submission_settled, outcome}, 2_000
      assert outcome.session_id == "s-multi"
      assert outcome.conversation_id == 1
      assert outcome.request_id == "req-multi"
      assert outcome.submission_id == String.to_integer(receipt.submission_id)
      assert outcome.kind == "input"
      assert outcome.status == "done"
      assert is_integer(outcome.entry_id)
      assert is_integer(outcome.answer_entry_id)
      assert outcome.answer_text == "Found: hello signal!"
      assert outcome.reason == nil
      assert is_integer(outcome.seq)

      # Second delivery from {:session_signals, "s-multi"} registration
      assert_receive {:submission_settled, ^outcome}, 2_000

      assert :ok = Daemon.unwatch_submission("s-multi", "req-multi", env.opts)
      refute {:submission, "s-multi", "req-multi"} in Registry.keys(env.pubsub, self())
    end

    test "returns {:ok, {:settled, outcome}} immediately for already-settled submission without leaking registration" do
      env =
        start_isolated_env([
          {:reply, [], %{content: [%{type: "text", text: "Instant reply"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-settled", "cwd" => env.cwd}, env.opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-settled",
          cmd("req-write", "submit", "1", %{"type" => "write", "content" => "Recorded note"}),
          env.opts
        )

      # Write command settles synchronously to "done"
      assert {:ok, {:settled, write_outcome}} =
               Daemon.watch_submission("s-settled", "req-write", self(), env.opts)

      assert write_outcome.status == "done"
      assert write_outcome.kind == "write"
      assert write_outcome.answer_entry_id == nil
      assert write_outcome.answer_text == nil
      refute {:submission, "s-settled", "req-write"} in Registry.keys(env.pubsub, self())

      # Unknown request_id returns :not_found without leaking registration
      assert {:error, :not_found} =
               Daemon.watch_submission("s-settled", "req-missing", self(), env.opts)

      refute {:submission, "s-settled", "req-missing"} in Registry.keys(env.pubsub, self())

      # Completed generation submission also returns {:settled, outcome} with answer_text
      {:ok, _} =
        Daemon.execute_command(
          "s-settled",
          cmd("req-done", "submit", "1", %{"type" => "input", "content" => "Hi"}),
          env.opts
        )

      outcome =
        case Daemon.watch_submission("s-settled", "req-done", self(), env.opts) do
          {:ok, {:settled, out}} ->
            out

          {:ok, {:pending, _}} ->
            assert_receive {:submission_settled, out}, 2_000
            Daemon.unwatch_submission("s-settled", "req-done", env.opts)
            out
        end

      assert outcome.status == "done"
      assert outcome.answer_text == "Instant reply"

      # Subsequent watch_submission immediately returns {:settled, _} with no leaked registration
      assert {:ok, {:settled, again}} =
               Daemon.watch_submission("s-settled", "req-done", self(), env.opts)

      assert again.status == "done"
      assert again.answer_text == "Instant reply"
      refute {:submission, "s-settled", "req-done"} in Registry.keys(env.pubsub, self())
    end

    test "emits {:submission_settled, outcome} for abort, model_error, nothing_to_answer, and withdraw" do
      gate_abort = make_ref()
      gate_withdraw = make_ref()
      test_pid = self()

      env =
        start_isolated_env([
          {:gate, [], test_pid, gate_abort, %{content: [%{type: "text", text: "never"}]}},
          {:error, %{code: "bad_request", message: "boom", retryable: false}},
          {:gate, [], test_pid, gate_withdraw, %{content: [%{type: "text", text: "Done"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-edges", "cwd" => env.cwd}, env.opts)

      # 1. nothing_to_answer on empty conversation
      Registry.register(env.pubsub, {:submission, "s-edges", "req-empty-cont"}, nil)

      assert {:ok, %{status: "unanswered", reason: "nothing_to_answer"}} =
               Daemon.execute_command(
                 "s-edges",
                 cmd("req-empty-cont", "submit", "1", %{"type" => "continue"}),
                 env.opts
               )

      assert_receive {:submission_settled, empty_out}, 1_000
      assert empty_out.request_id == "req-empty-cont"
      assert empty_out.status == "unanswered"
      assert empty_out.reason == "nothing_to_answer"
      assert empty_out.answer_text == nil

      # 2. abort settlement
      {:ok, _} =
        Daemon.execute_command(
          "s-edges",
          cmd("req-abort-me", "submit", "1", %{"type" => "input", "content" => "Will abort"}),
          env.opts
        )

      assert_receive {:gate_entered, ^gate_abort, _gpid}

      assert {:ok, {:pending, _}} =
               Daemon.watch_submission("s-edges", "req-abort-me", self(), env.opts)

      assert {:ok, %{status: "done"}} =
               Daemon.execute_command(
                 "s-edges",
                 cmd("cmd-abort", "abort", "1", %{"reason" => "user_cancelled"}),
                 env.opts
               )

      assert_receive {:submission_settled, abort_out}, 1_000
      assert abort_out.request_id == "req-abort-me"
      assert abort_out.status == "unanswered"
      assert abort_out.reason == "user_cancelled"
      assert abort_out.answer_text == nil

      # 3. model_error settlement
      Registry.register(env.pubsub, {:submission, "s-edges", "req-err"}, nil)

      {:ok, _} =
        Daemon.execute_command(
          "s-edges",
          cmd("req-err", "submit", "1", %{"type" => "input", "content" => "Trigger error"}),
          env.opts
        )

      assert_receive {:submission_settled, err_out}, 2_000
      assert err_out.request_id == "req-err"
      assert err_out.status == "unanswered"
      assert err_out.reason == "model_error"
      assert err_out.answer_text == nil

      # 4. withdraw settlement
      {:ok, _} =
        Daemon.execute_command(
          "s-edges",
          cmd("req-hold", "submit", "1", %{"type" => "input", "content" => "Hold busy"}),
          env.opts
        )

      assert_receive {:gate_entered, ^gate_withdraw, gpid_w}

      {:ok, queued_receipt} =
        Daemon.execute_command(
          "s-edges",
          cmd("req-queued", "submit", "1", %{"type" => "input", "content" => "Withdraw me"}),
          env.opts
        )

      assert queued_receipt.status == "queued"

      assert {:ok, {:pending, queued_pending}} =
               Daemon.watch_submission("s-edges", "req-queued", self(), env.opts)

      assert queued_pending.status == "queued"

      assert {:ok, %{status: "done"}} =
               Daemon.execute_command(
                 "s-edges",
                 cmd("cmd-withdraw", "withdraw", "1", %{
                   "submission_ids" => [queued_receipt.submission_id]
                 }),
                 env.opts
               )

      assert_receive {:submission_settled, withdraw_out}, 1_000
      assert withdraw_out.request_id == "req-queued"
      assert withdraw_out.status == "withdrawn"
      assert withdraw_out.answer_text == nil

      send(gpid_w, {:release, gate_withdraw})
    end

    test "settles placed submission and reloads non-colliding IDs even when recent_submissions LRU cache overflows and session store reopens" do
      gate = make_ref()
      test_pid = self()

      env =
        start_isolated_env([
          {:gate, [], test_pid, gate,
           %{content: [%{type: "text", text: "Settled after 300 writes"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-lru", "cwd" => env.cwd}, env.opts)

      {:ok, receipt} =
        Daemon.execute_command(
          "s-lru",
          cmd("req-initial", "submit", "1", %{"type" => "input", "content" => "Long turn"}),
          env.opts
        )

      assert receipt.status == "placed"
      assert_receive {:gate_entered, ^gate, gpid}

      assert {:ok, {:pending, _}} =
               Daemon.watch_submission("s-lru", "req-initial", self(), env.opts)

      # Flood > 256 immediate terminal configure submissions while generation is running
      for i <- 1..270 do
        {:ok, _} =
          Daemon.execute_command(
            "s-lru",
            cmd("req-cfg-#{i}", "configure", "1", %{"thinking" => "high"}),
            env.opts
          )
      end

      # Also corrupt/evict in-memory recent_submissions to simulate any cache miss on settle,
      # proving Submissions.settle/5 falls back to Storage cleanly!
      [{server_pid, _}] = Registry.lookup(env.opts[:registry], {:session, "s-lru"})

      :sys.replace_state(server_pid, fn st ->
        %{st | recent_submissions: Map.delete(st.recent_submissions, "req-initial")}
      end)

      send(gpid, {:release, gate})

      assert_receive {:submission_settled, outcome}, 2_000
      assert outcome.request_id == "req-initial"
      assert outcome.status == "done"
      assert outcome.answer_text == "Settled after 300 writes"

      # Verify max_seen_id accounts for submission IDs on reopen without ID collisions
      dir = Path.join([env.data_dir, "sessions", "s-lru"])
      {:ok, ro_store} = H.Storage.File.open_read_only(dir: dir, session_id: "s-lru")
      {:ok, bs, _} = H.Storage.read_bootstrap(ro_store)

      max_sub_id =
        bs.submissions
        |> Map.values()
        |> Enum.map(&(&1[:id] || &1["id"]))
        |> Enum.max()

      assert bs.next_id > max_sub_id
    end
  end

  describe "GET /api/v1/sessions/:sid/submissions/:request_id" do
    test "returns 200 wire-formatted submission outcome and 404 when missing" do
      Application.ensure_all_started(:req)

      env =
        start_isolated_env([
          {:reply, [], %{content: [%{type: "text", text: "HTTP answer body"}]}}
        ])

      id = System.unique_integer([:positive])
      auth_table = :"h_sub_signal_http_auth_#{id}"
      auth_server = :"H.SubSignalTest.Auth.#{id}"
      auth_dir = Path.join(env.tmp_root, "auth")
      File.mkdir_p!(auth_dir)

      start_supervised!({Auth, data_dir: auth_dir, name: auth_server, table: auth_table})
      token = Auth.owner_token(auth_table)

      router_opts = [
        port: 4000,
        auth_server: auth_server,
        auth_table: auth_table,
        daemon: H.Daemon,
        daemon_opts: env.opts
      ]

      req =
        Req.new(
          base_url: "http://127.0.0.1:4000",
          plug: {Router, router_opts},
          headers: [{"host", "127.0.0.1:4000"}, {"authorization", "Bearer #{token}"}],
          retry: false
        )

      {:ok, _} =
        Daemon.create_session(%{"session_id" => "s-http-sub", "cwd" => env.cwd}, env.opts)

      # Unknown submission -> 404
      resp_404 = Req.get!(req, url: "/api/v1/sessions/s-http-sub/submissions/does-not-exist")
      assert resp_404.status == 404

      # Unknown session -> 404
      resp_missing_sid = Req.get!(req, url: "/api/v1/sessions/no-such-session/submissions/r1")
      assert resp_missing_sid.status == 404

      # Submit and wait for settlement
      Registry.register(env.pubsub, {:submission, "s-http-sub", "req-http-1"}, nil)

      {:ok, receipt} =
        Daemon.execute_command(
          "s-http-sub",
          cmd("req-http-1", "submit", "1", %{"type" => "input", "content" => "Hello via HTTP"}),
          env.opts
        )

      assert_receive {:submission_settled, settled}, 2_000
      assert settled.status == "done"

      resp_200 = Req.get!(req, url: "/api/v1/sessions/s-http-sub/submissions/req-http-1")
      assert resp_200.status == 200

      assert %{
               "session_id" => "s-http-sub",
               "conversation_id" => "1",
               "submission_id" => sub_id,
               "request_id" => "req-http-1",
               "kind" => "input",
               "status" => "done",
               "entry_id" => entry_id,
               "answer_entry_id" => answer_entry_id,
               "answer_text" => "HTTP answer body",
               "reason" => nil,
               "seq" => seq
             } = resp_200.body

      assert sub_id == receipt.submission_id
      assert is_binary(entry_id)
      assert is_binary(answer_entry_id)
      assert is_integer(seq)
    end
  end
end
