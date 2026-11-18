defmodule H.WithdrawTest do
  use ExUnit.Case, async: true

  alias H.{Auth, Catalog, Daemon, Storage}
  alias H.HTTP.Router
  alias H.Provider.Fake

  defp start_isolated_env(script \\ [], extra_opts \\ []) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-withdraw-test-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    registry = :"H.WithdrawTest.Registry.#{id}"
    pubsub = :"H.WithdrawTest.PubSub.#{id}"
    catalog = :"H.WithdrawTest.Catalog.#{id}"
    catalog_table = :"h_withdraw_test_catalog_#{id}"
    lease = :"H.WithdrawTest.Lease.#{id}"
    runtime_sup = :"H.WithdrawTest.RuntimeSup.#{id}"
    fake_name = :"H.WithdrawTest.Fake.#{id}"

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
          provider: Fake,
          provider_config: %{server: fake},
          storage_mod: H.Storage.File,
          storage_opts: [sync: :none],
          default_model: "fake:chat"
        ],
        extra_opts
      )

    %{opts: opts, cwd: cwd, data_dir: data_dir, fake: fake, tmp_root: tmp_root}
  end

  defp restart_daemon_env(data_dir, script, extra_opts) do
    id = System.unique_integer([:positive])
    registry = :"H.WithdrawTest.ReRegistry.#{id}"
    pubsub = :"H.WithdrawTest.RePubSub.#{id}"
    catalog = :"H.WithdrawTest.ReCatalog.#{id}"
    catalog_table = :"h_withdraw_test_recatalog_#{id}"
    lease = :"H.WithdrawTest.ReLease.#{id}"
    runtime_sup = :"H.WithdrawTest.ReRuntimeSup.#{id}"
    fake_name = :"H.WithdrawTest.ReFake.#{id}"

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

  describe "boundary validation for withdraw" do
    test "rejects missing, empty, or invalid submission_ids with bad_request" do
      %{opts: opts, cwd: cwd} = start_isolated_env()
      {:ok, _} = Daemon.create_session(%{"session_id" => "s-val", "cwd" => cwd}, opts)

      for bad_args <- [
            %{},
            %{"submission_ids" => []},
            %{"submission_ids" => "4"},
            %{"submission_ids" => [0]},
            %{"submission_ids" => [-1]},
            %{"submission_ids" => ["not-an-id"]},
            %{"submission_ids" => [nil]}
          ] do
        assert {:error, {:bad_request, _}} =
                 Daemon.execute_command("s-val", cmd("w-bad", "withdraw", "1", bad_args), opts)
      end

      assert {:error, :not_found} =
               Daemon.execute_command(
                 "s-val",
                 cmd("w-nocid", "withdraw", "999", %{"submission_ids" => ["2"]}),
                 opts
               )
    end
  end

  describe "guarded withdrawal ordering and SSE commit ops" do
    test "withdraws subset in original inbox order, preserves remaining items, and emits inbox replace doc_op" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd, fake: fake} =
        start_isolated_env([
          {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Turn 1 done"}]}},
          {:reply, [], %{content: [%{type: "text", text: "Kept reply"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-order", "cwd" => cwd}, opts)

      {:ok, {:snapshot, _s, _bin}} =
        Daemon.subscribe_conversation("s-order", "1", self(), nil, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-order",
          cmd("r1", "submit", "1", %{"type" => "input", "content" => "Initial"}),
          opts
        )

      assert_receive {:gate_entered, ^gate, gpid}

      {:ok, q1} =
        Daemon.execute_command(
          "s-order",
          cmd("q1", "submit", "1", %{
            "type" => "input",
            "content" => "First queued",
            "when_busy" => "steer"
          }),
          opts
        )

      {:ok, q2} =
        Daemon.execute_command(
          "s-order",
          cmd("q2", "submit", "1", %{
            "type" => "input",
            "content" => "Second kept",
            "when_busy" => "follow_up"
          }),
          opts
        )

      {:ok, q3} =
        Daemon.execute_command(
          "s-order",
          cmd("q3", "submit", "1", %{
            "type" => "input",
            "content" => "Third queued",
            "when_busy" => "follow_up"
          }),
          opts
        )

      # Drain prior commit frames
      flush_mailbox()

      # Request in reverse order [q3, q1] -> receipt must preserve original inbox order [q1, q3]
      assert {:ok, receipt} =
               Daemon.execute_command(
                 "s-order",
                 cmd("w-1", "withdraw", "1", %{
                   "submission_ids" => [q3.submission_id, q1.submission_id]
                 }),
                 opts
               )

      assert receipt.version == 1
      assert receipt.request_id == "w-1"
      assert is_integer(receipt.seq)
      assert receipt.status == "done"

      assert receipt.withdrawn == [
               %{
                 "submission_id" => q1.submission_id,
                 "request_id" => "q1",
                 "when_busy" => "steer",
                 "content" => [%{"type" => "text", "text" => "First queued"}]
               },
               %{
                 "submission_id" => q3.submission_id,
                 "request_id" => "q3",
                 "when_busy" => "follow_up",
                 "content" => [%{"type" => "text", "text" => "Third queued"}]
               }
             ]

      # Verify SSE commit frame updated inbox to contain only q2
      assert_receive {:commit_frame, commit_seq, commit_bin}
      assert commit_seq == receipt.seq
      frame = JSON.decode!(commit_bin)
      assert frame["appended_entries"] == []

      assert frame["doc_ops"] == %{
               "inbox" => [
                 [
                   "replace",
                   [
                     %{
                       "submission_id" => q2.submission_id,
                       "request_id" => "q2",
                       "when_busy" => "follow_up",
                       "content" => [%{"type" => "text", "text" => "Second kept"}]
                     }
                   ]
                 ]
               ]
             }

      # Release gate -> only q2 should run; withdrawn q1 & q3 must never enter transcript
      send(gpid, {:release, gate})

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-order", "1", %{"order" => "asc"}, opts)
          if length(items) == 4, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == ["user", "assistant", "user", "assistant"]
      assert Enum.at(items, 2).data["content"] == [%{"type" => "text", "text" => "Second kept"}]

      # Confirm Fake provider never saw withdrawn prompts
      all_texts =
        fake
        |> Fake.requests()
        |> Enum.flat_map(& &1.messages)
        |> Enum.flat_map(& &1.content)
        |> Enum.map(&Map.get(&1, :text))

      assert "Second kept" in all_texts
      refute "First queued" in all_texts
      refute "Third queued" in all_texts
    end

    test "withdraw works on leftover inbox items after abort while idle" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd, fake: fake} =
        start_isolated_env([
          {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "never"}]}},
          {:reply, [], %{content: [%{type: "text", text: "Continued"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-abort-q", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-abort-q",
          cmd("r1", "submit", "1", %{"type" => "input", "content" => "Run"}),
          opts
        )

      assert_receive {:gate_entered, ^gate, _gpid}

      {:ok, q1} =
        Daemon.execute_command(
          "s-abort-q",
          cmd("q1", "submit", "1", %{"type" => "input", "content" => "Pending after abort"}),
          opts
        )

      assert {:ok, %{status: "done"}} =
               Daemon.execute_command("s-abort-q", cmd("ab1", "abort", "1", %{}), opts)

      assert {:ok, w_receipt} =
               Daemon.execute_command(
                 "s-abort-q",
                 cmd("w-after-abort", "withdraw", "1", %{"submission_ids" => [q1.submission_id]}),
                 opts
               )

      assert [
               %{
                 "submission_id" => _,
                 "request_id" => "q1",
                 "content" => [%{"type" => "text", "text" => "Pending after abort"}]
               }
             ] = w_receipt.withdrawn

      # Subsequent continue answers "Run" and must NOT restore or run withdrawn input
      assert {:ok, %{status: "placed"}} =
               Daemon.execute_command(
                 "s-abort-q",
                 cmd("cont1", "submit", "1", %{"type" => "continue"}),
                 opts
               )

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries("s-abort-q", "1", %{"order" => "asc"}, opts)

          if length(items) == 2, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == ["user", "assistant"]

      all_texts =
        fake
        |> Fake.requests()
        |> Enum.flat_map(& &1.messages)
        |> Enum.flat_map(& &1.content)
        |> Enum.map(&Map.get(&1, :text))

      refute "Pending after abort" in all_texts
    end
  end

  describe "all-or-conflict (409) and no restore of already consumed text" do
    test "returns 409 when steer item is consumed at tool boundary, and partial overlap leaves follow_up untouched" do
      gate1 = make_ref()
      gate2 = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_isolated_env([
          {:gate, [], test_pid, gate1,
           %{
             content: [],
             tool_calls: [%{id: "c1", name: "read", arguments: %{"path" => "a.txt"}}],
             finish_reason: "tool_calls"
           }},
          {:gate, [], test_pid, gate2, %{content: [%{type: "text", text: "After steer"}]}},
          {:reply, [], %{content: [%{type: "text", text: "After follow_up"}]}}
        ])

      File.write!(Path.join(cwd, "a.txt"), "hello\n")
      {:ok, _} = Daemon.create_session(%{"session_id" => "s-consumed", "cwd" => cwd}, opts)

      {:ok, placed_sub} =
        Daemon.execute_command(
          "s-consumed",
          cmd("p1", "submit", "1", %{"type" => "input", "content" => "Initial"}),
          opts
        )

      assert placed_sub.status == "placed"
      assert_receive {:gate_entered, ^gate1, gpid1}

      # Immediately placed submission cannot be withdrawn
      assert {:error, {:conflict, "submission_not_queued"}} =
               Daemon.execute_command(
                 "s-consumed",
                 cmd("w-placed", "withdraw", "1", %{
                   "submission_ids" => [placed_sub.submission_id]
                 }),
                 opts
               )

      {:ok, steer_sub} =
        Daemon.execute_command(
          "s-consumed",
          cmd("st1", "submit", "1", %{
            "type" => "input",
            "content" => "Steer consumed",
            "when_busy" => "steer"
          }),
          opts
        )

      {:ok, follow_sub} =
        Daemon.execute_command(
          "s-consumed",
          cmd("fu1", "submit", "1", %{
            "type" => "input",
            "content" => "Follow up kept",
            "when_busy" => "follow_up"
          }),
          opts
        )

      # Release gate 1 -> tool executes -> steer_sub is consumed into user entry -> gate 2 entered
      send(gpid1, {:release, gate1})
      assert_receive {:gate_entered, ^gate2, gpid2}

      # All-or-conflict: requesting [steer_sub, follow_sub] MUST fail 409 without withdrawing follow_sub!
      assert {:error, {:conflict, "submission_not_queued"}} =
               Daemon.execute_command(
                 "s-consumed",
                 cmd("w-partial", "withdraw", "1", %{
                   "submission_ids" => [steer_sub.submission_id, follow_sub.submission_id]
                 }),
                 opts
               )

      # Consumed steer_sub alone MUST fail 409 (no restore of consumed text)
      assert {:error, {:conflict, "submission_not_queued"}} =
               Daemon.execute_command(
                 "s-consumed",
                 cmd("w-steer-only", "withdraw", "1", %{
                   "submission_ids" => [steer_sub.submission_id]
                 }),
                 opts
               )

      # follow_sub is STILL queued in inbox because w-partial was all-or-conflict!
      {:ok, {:snapshot, _seq, snap_bin}} =
        Daemon.subscribe_conversation("s-consumed", "1", self(), nil, opts)

      snap = JSON.decode!(snap_bin)
      assert [%{"submission_id" => follow_id}] = snap["docs"]["inbox"]
      assert follow_id == follow_sub.submission_id

      # Now withdraw follow_sub alone succeeds
      assert {:ok, w_follow} =
               Daemon.execute_command(
                 "s-consumed",
                 cmd("w-follow", "withdraw", "1", %{
                   "submission_ids" => [follow_sub.submission_id]
                 }),
                 opts
               )

      assert [%{"request_id" => "fu1"}] = w_follow.withdrawn

      # Second withdraw with a NEW request_id for already-withdrawn follow_sub fails 409
      assert {:error, {:conflict, "submission_not_queued"}} =
               Daemon.execute_command(
                 "s-consumed",
                 cmd("w-follow-again", "withdraw", "1", %{
                   "submission_ids" => [follow_sub.submission_id]
                 }),
                 opts
               )

      send(gpid2, {:release, gate2})

      wait_until(fn ->
        {:ok, %{items: items}} =
          Daemon.scan_entries("s-consumed", "1", %{"order" => "asc"}, opts)

        if length(items) == 5, do: items, else: nil
      end)
    end

    test "cross-conversation withdraw returns 409 and leaves parent inbox untouched" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_isolated_env([
          {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Done"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-xconv", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-xconv",
          cmd("r1", "submit", "1", %{"type" => "input", "content" => "Root turn"}),
          opts
        )

      assert_receive {:gate_entered, ^gate, gpid}

      {:ok, %{items: [first_entry]}} =
        Daemon.scan_entries("s-xconv", "1", %{"order" => "asc"}, opts)

      {:ok, q1} =
        Daemon.execute_command(
          "s-xconv",
          cmd("q-parent", "submit", "1", %{"type" => "input", "content" => "Parent queued"}),
          opts
        )

      {:ok, fork_receipt} =
        Daemon.execute_command(
          "s-xconv",
          cmd("f1", "fork", "1", %{"at_entry_id" => first_entry.id}),
          opts
        )

      # Withdrawing parent's submission from child conversation MUST conflict
      assert {:error, {:conflict, "submission_not_queued"}} =
               Daemon.execute_command(
                 "s-xconv",
                 cmd("w-wrong-conv", "withdraw", fork_receipt.conversation_id, %{
                   "submission_ids" => [q1.submission_id]
                 }),
                 opts
               )

      # Parent still has it queued and can withdraw it
      assert {:ok, %{withdrawn: [%{"request_id" => "q-parent"}]}} =
               Daemon.execute_command(
                 "s-xconv",
                 cmd("w-right-conv", "withdraw", "1", %{"submission_ids" => [q1.submission_id]}),
                 opts
               )

      send(gpid, {:release, gate})
    end
  end

  describe "idempotent retries and payload conflict" do
    test "retry returns stored withdrawn input even after queue changes, and mismatched payload returns 409" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_isolated_env([
          {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Done"}]}},
          {:reply, [], %{content: [%{type: "text", text: "Turn 2"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-retry", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-retry",
          cmd("r1", "submit", "1", %{"type" => "input", "content" => "Start"}),
          opts
        )

      assert_receive {:gate_entered, ^gate, gpid}

      {:ok, q1} =
        Daemon.execute_command(
          "s-retry",
          cmd("q1", "submit", "1", %{
            "type" => "input",
            "content" => "To withdraw",
            "when_busy" => "steer"
          }),
          opts
        )

      {:ok, q2} =
        Daemon.execute_command(
          "s-retry",
          cmd("q2", "submit", "1", %{"type" => "input", "content" => "Stays queued"}),
          opts
        )

      w_env = cmd("w-idem", "withdraw", "1", %{"submission_ids" => [q1.submission_id]})
      assert {:ok, r1} = Daemon.execute_command("s-retry", w_env, opts)

      # Enqueue another item and finish the turn so inbox is completely empty
      {:ok, _q3} =
        Daemon.execute_command(
          "s-retry",
          cmd("q3", "submit", "1", %{"type" => "input", "content" => "Another"}),
          opts
        )

      send(gpid, {:release, gate})

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-retry", "1", %{"order" => "asc"}, opts)
        if length(items) >= 4, do: items, else: nil
      end)

      # Retrying w-idem returns the exact stored receipt including original withdrawn input & seq
      assert {:ok, r2} = Daemon.execute_command("s-retry", w_env, opts)
      assert r2 == r1

      # Reusing w-idem with different submission_ids returns 409 payload conflict
      bad_env = cmd("w-idem", "withdraw", "1", %{"submission_ids" => [q2.submission_id]})
      assert {:error, {:conflict, _}} = Daemon.execute_command("s-retry", bad_env, opts)

      # Retrying original queued submit request_id "q1" reflects withdrawn status without re-queuing
      assert {:ok, q1_retry} =
               Daemon.execute_command(
                 "s-retry",
                 cmd("q1", "submit", "1", %{
                   "type" => "input",
                   "content" => "To withdraw",
                   "when_busy" => "steer"
                 }),
                 opts
               )

      assert q1_retry.submission_id == q1.submission_id
      assert q1_retry.status == "withdrawn"
    end

    test "concurrent identical withdraw retries in the same mailbox batch both return receipt" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_isolated_env([
          {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Done"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-same-batch", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-same-batch",
          cmd("r1", "submit", "1", %{"type" => "input", "content" => "Start"}),
          opts
        )

      assert_receive {:gate_entered, ^gate, gpid}

      {:ok, q1} =
        Daemon.execute_command(
          "s-same-batch",
          cmd("q1", "submit", "1", %{"type" => "input", "content" => "Same batch"}),
          opts
        )

      env = cmd("w-dup-batch", "withdraw", "1", %{"submission_ids" => [q1.submission_id]})

      t1 = Task.async(fn -> Daemon.execute_command("s-same-batch", env, opts) end)
      t2 = Task.async(fn -> Daemon.execute_command("s-same-batch", env, opts) end)

      [{:ok, r1}, {:ok, r2}] = Task.await_many([t1, t2])
      assert r1 == r2
      assert [%{"request_id" => "q1"}] = r1.withdrawn

      send(gpid, {:release, gate})
    end
  end

  describe "real H.Storage.File persistence, snapshot rotation, and reopen" do
    test "persists withdrawn items across WAL replay and snapshot rotation; retry works and consumed text is never restored" do
      gate = make_ref()
      test_pid = self()

      # snapshot_every: 2 forces snapshot rotation during the test!
      %{opts: opts, cwd: cwd, data_dir: data_dir} =
        start_isolated_env(
          [
            {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Turn 1"}]}},
            {:reply, [], %{content: [%{type: "text", text: "Turn 2"}]}}
          ],
          storage_opts: [sync: :datasync, snapshot_every: 2]
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-persist", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-persist",
          cmd("r1", "submit", "1", %{"type" => "input", "content" => "First"}),
          opts
        )

      assert_receive {:gate_entered, ^gate, gpid}

      {:ok, q1} =
        Daemon.execute_command(
          "s-persist",
          cmd("q1", "submit", "1", %{
            "type" => "input",
            "content" => "Withdrawn before restart",
            "when_busy" => "steer"
          }),
          opts
        )

      {:ok, q2} =
        Daemon.execute_command(
          "s-persist",
          cmd("q2", "submit", "1", %{
            "type" => "input",
            "content" => "Kept for turn 2",
            "when_busy" => "follow_up"
          }),
          opts
        )

      w_env = cmd("w-persist", "withdraw", "1", %{"submission_ids" => [q1.submission_id]})
      assert {:ok, w_receipt} = Daemon.execute_command("s-persist", w_env, opts)

      # Release gate so q2 is consumed and finished before closing
      send(gpid, {:release, gate})

      wait_until(fn ->
        {:ok, %{items: items}} =
          Daemon.scan_entries("s-persist", "1", %{"order" => "asc"}, opts)

        if length(items) == 4, do: items, else: nil
      end)

      # Cleanly stop the session server and inspect REAL H.Storage.File persistence on disk
      close_session!("s-persist", opts)

      session_dir = Path.join([data_dir, "sessions", "s-persist"])
      assert File.ls!(session_dir) |> Enum.any?(&String.starts_with?(&1, "snapshot."))

      {:ok, raw_store} = Storage.open(H.Storage.File, dir: session_dir, sync: :none)
      {:ok, bootstrap, raw_store} = Storage.read_bootstrap(raw_store)

      # Inspect persisted docs & submissions directly
      persisted_inbox = bootstrap.docs[{:conversation, 1, "inbox"}]
      assert persisted_inbox["value"] == []

      {:ok, persisted_w, raw_store} = Storage.get_submission(raw_store, "w-persist")
      assert persisted_w.kind == "withdraw"
      assert persisted_w.status == "done"

      assert (persisted_w[:withdrawn] || persisted_w["withdrawn"]) == [
               %{
                 "submission_id" => q1.submission_id,
                 "request_id" => "q1",
                 "when_busy" => "steer",
                 "content" => [%{"type" => "text", "text" => "Withdrawn before restart"}]
               }
             ]

      {:ok, persisted_q1, raw_store} = Storage.get_submission(raw_store, "q1")
      assert persisted_q1.status == "withdrawn"

      {:ok, persisted_q2, raw_store} = Storage.get_submission(raw_store, "q2")
      assert persisted_q2.status == "done"

      :ok = Storage.close(raw_store)

      # Reopen session in a fresh supervisor tree on the exact same data_dir
      %{opts: opts2} =
        restart_daemon_env(data_dir, [], storage_opts: [sync: :datasync, snapshot_every: 2])

      # Snapshot shows empty inbox and only the 4 real entries (no withdrawn text)
      {:ok, {:snapshot, _seq, snap_bin}} =
        Daemon.subscribe_conversation("s-persist", "1", self(), nil, opts2)

      snap = JSON.decode!(snap_bin)
      assert snap["docs"]["inbox"] == []
      assert length(snap["entries"]) == 4

      # Idempotent retry of w-persist after reopen returns stored withdrawn items
      assert {:ok, w_retry} = Daemon.execute_command("s-persist", w_env, opts2)
      assert w_retry.status == "done"
      assert w_retry.withdrawn == w_receipt.withdrawn

      # Attempting to withdraw already-consumed q2 after reopen fails 409 (no restore of consumed text)
      assert {:error, {:conflict, "submission_not_queued"}} =
               Daemon.execute_command(
                 "s-persist",
                 cmd("w-consumed-reopen", "withdraw", "1", %{
                   "submission_ids" => [q2.submission_id]
                 }),
                 opts2
               )

      # Attempting to withdraw already-withdrawn q1 with new request_id fails 409
      assert {:error, {:conflict, "submission_not_queued"}} =
               Daemon.execute_command(
                 "s-persist",
                 cmd("w-withdrawn-reopen", "withdraw", "1", %{
                   "submission_ids" => [q1.submission_id]
                 }),
                 opts2
               )
    end

    test "WAL-only crash recovery preserves withdrawn items and never restores withdrawn or consumed input" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd, data_dir: data_dir} =
        start_isolated_env(
          [
            {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Turn 1"}]}},
            {:reply, [], %{content: [%{type: "text", text: "Recovered reply"}]}}
          ],
          storage_opts: [sync: :datasync, snapshot_every: 200],
          retry_backoff_ms: 10
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-crash", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-crash",
          cmd("r1", "submit", "1", %{"type" => "input", "content" => "Initial"}),
          opts
        )

      assert_receive {:gate_entered, ^gate, _gpid}

      {:ok, q1} =
        Daemon.execute_command(
          "s-crash",
          cmd("q1", "submit", "1", %{"type" => "input", "content" => "Crash withdrawn"}),
          opts
        )

      {:ok, q2} =
        Daemon.execute_command(
          "s-crash",
          cmd("q2", "submit", "1", %{"type" => "input", "content" => "Crash kept"}),
          opts
        )

      w_env = cmd("w-crash", "withdraw", "1", %{"submission_ids" => [q1.submission_id]})
      assert {:ok, w_receipt} = Daemon.execute_command("s-crash", w_env, opts)

      # Crash the session server abruptly (no clean close, WAL replay only)
      [{server_pid, _}] = Registry.lookup(opts[:registry], {:session, "s-crash"})
      ref = Process.monitor(server_pid)
      Process.exit(server_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^server_pid, :killed}

      # Reopen from WAL on fresh supervisor tree
      %{opts: opts2, fake: fake2} =
        restart_daemon_env(
          data_dir,
          [
            {:reply, [], %{content: [%{type: "text", text: "Retry initial"}]}},
            {:reply, [], %{content: [%{type: "text", text: "After kept"}]}}
          ],
          storage_opts: [sync: :datasync, snapshot_every: 200],
          retry_backoff_ms: 10
        )

      assert :ok = Daemon.recover_active_sessions(opts2)

      # Wait for recovered initial run + kept q2 to finish
      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-crash", "1", %{"order" => "asc"}, opts2)
          if length(items) == 4, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == ["user", "assistant", "user", "assistant"]
      assert Enum.at(items, 2).data["content"] == [%{"type" => "text", "text" => "Crash kept"}]

      # Confirm Fake provider never saw withdrawn q1 after WAL crash recovery
      all_texts =
        fake2
        |> Fake.requests()
        |> Enum.flat_map(& &1.messages)
        |> Enum.flat_map(& &1.content)
        |> Enum.map(&Map.get(&1, :text))

      assert "Crash kept" in all_texts
      refute "Crash withdrawn" in all_texts

      # Retry w-crash after WAL recovery returns stored withdrawn receipt
      assert {:ok, w_retry} = Daemon.execute_command("s-crash", w_env, opts2)
      assert w_retry.withdrawn == w_receipt.withdrawn

      # Consumed q2 cannot be withdrawn
      assert {:error, {:conflict, "submission_not_queued"}} =
               Daemon.execute_command(
                 "s-crash",
                 cmd("w-crash-q2", "withdraw", "1", %{"submission_ids" => [q2.submission_id]}),
                 opts2
               )
    end
  end

  describe "concurrent races" do
    test "two clients racing withdraw for the same submission_id yield exactly one success and one 409" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_isolated_env([
          {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Done"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-race-ww", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-race-ww",
          cmd("r1", "submit", "1", %{"type" => "input", "content" => "Start"}),
          opts
        )

      assert_receive {:gate_entered, ^gate, gpid}

      {:ok, q1} =
        Daemon.execute_command(
          "s-race-ww",
          cmd("q1", "submit", "1", %{"type" => "input", "content" => "Contested"}),
          opts
        )

      t1 =
        Task.async(fn ->
          Daemon.execute_command(
            "s-race-ww",
            cmd("w-client-a", "withdraw", "1", %{"submission_ids" => [q1.submission_id]}),
            opts
          )
        end)

      t2 =
        Task.async(fn ->
          Daemon.execute_command(
            "s-race-ww",
            cmd("w-client-b", "withdraw", "1", %{"submission_ids" => [q1.submission_id]}),
            opts
          )
        end)

      results = Task.await_many([t1, t2])
      oks = Enum.filter(results, &match?({:ok, _}, &1))

      conflicts =
        Enum.filter(results, &match?({:error, {:conflict, "submission_not_queued"}}, &1))

      assert length(oks) == 1
      assert length(conflicts) == 1

      [{:ok, win_receipt}] = oks
      assert [%{"request_id" => "q1"}] = win_receipt.withdrawn

      send(gpid, {:release, gate})
    end

    test "client racing withdraw against turn consumption produces exactly one outcome without duplicate input" do
      test_pid = self()

      %{opts: base_opts, cwd: cwd} = start_isolated_env([])

      for round <- 1..10 do
        gate = make_ref()
        fake_name = :"H.WithdrawTest.RaceFake.#{System.unique_integer([:positive])}"

        fake =
          start_supervised!(
            {Fake,
             script: [
               {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Turn 1"}]}},
               {:reply, [], %{content: [%{type: "text", text: "Turn 2"}]}}
             ],
             name: fake_name},
            id: {:race_fake, round}
          )

        opts = Keyword.put(base_opts, :provider_config, %{server: fake})

        sid = "s-race-wc-#{round}"
        {:ok, _} = Daemon.create_session(%{"session_id" => sid, "cwd" => cwd}, opts)

        {:ok, _} =
          Daemon.execute_command(
            sid,
            cmd("r1", "submit", "1", %{"type" => "input", "content" => "Start #{round}"}),
            opts
          )

        assert_receive {:gate_entered, ^gate, gpid}

        prompt = "Race prompt #{round}"

        {:ok, q1} =
          Daemon.execute_command(
            sid,
            cmd("q1", "submit", "1", %{"type" => "input", "content" => prompt}),
            opts
          )

        withdraw_task =
          Task.async(fn ->
            Daemon.execute_command(
              sid,
              cmd("w-race", "withdraw", "1", %{"submission_ids" => [q1.submission_id]}),
              opts
            )
          end)

        send(gpid, {:release, gate})
        withdraw_res = Task.await(withdraw_task)

        # Wait for session to settle idle
        wait_until(fn ->
          {:ok, detail} = Daemon.get_session_detail(sid, opts)
          if Enum.all?(detail.tasks, &(&1.status == "terminal")), do: true, else: nil
        end)

        {:ok, %{items: entries}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)

        race_prompt_count =
          Enum.count(entries, fn e ->
            e.kind == "user" and
              e.data["content"] == [%{"type" => "text", "text" => prompt}]
          end)

        provider_count =
          fake
          |> Fake.requests()
          |> Enum.count(fn req ->
            Enum.any?(req.messages, fn m ->
              m.role == "user" and Enum.any?(m.content, &(Map.get(&1, :text) == prompt))
            end)
          end)

        case withdraw_res do
          {:ok, receipt} ->
            assert [%{"request_id" => "q1"}] = receipt.withdrawn
            assert race_prompt_count == 0
            assert provider_count == 0

          {:error, {:conflict, "submission_not_queued"}} ->
            assert race_prompt_count == 1
            assert provider_count >= 1
        end
      end
    end
  end

  describe "HTTP API router integration" do
    test "POST /api/v1/sessions/:sid/commands handles withdraw 200, retry 200, 422, and 409" do
      Application.ensure_all_started(:req)

      gate = make_ref()
      test_pid = self()

      %{opts: daemon_opts, cwd: cwd, tmp_root: tmp_root} =
        start_isolated_env([
          {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Done"}]}}
        ])

      id = System.unique_integer([:positive])
      auth_table = :"h_withdraw_http_auth_#{id}"
      auth_server = :"H.WithdrawTest.Auth.#{id}"
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

      {:ok, _} =
        Daemon.execute_command(
          "s-http",
          cmd("r1", "submit", "1", %{"type" => "input", "content" => "Start"}),
          daemon_opts
        )

      assert_receive {:gate_entered, ^gate, gpid}

      {:ok, q1} =
        Daemon.execute_command(
          "s-http",
          cmd("q1", "submit", "1", %{"type" => "input", "content" => "Via HTTP"}),
          daemon_opts
        )

      # 422 on invalid args
      resp_422 =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: cmd("w-bad", "withdraw", "1", %{"submission_ids" => []})
        )

      assert resp_422.status == 422

      # 200 on withdraw
      w_body = cmd("w-http-1", "withdraw", "1", %{"submission_ids" => [q1.submission_id]})

      resp_200 =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: w_body
        )

      assert resp_200.status == 200

      assert %{
               "version" => 1,
               "request_id" => "w-http-1",
               "status" => "done",
               "seq" => seq,
               "withdrawn" => [
                 %{
                   "submission_id" => sub_id,
                   "request_id" => "q1",
                   "when_busy" => "follow_up",
                   "content" => [%{"type" => "text", "text" => "Via HTTP"}]
                 }
               ]
             } = resp_200.body

      assert is_integer(seq)
      assert sub_id == q1.submission_id

      # 200 idempotent retry
      resp_retry =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: w_body
        )

      assert resp_retry.status == 200
      assert resp_retry.body == resp_200.body

      # 409 on second withdraw with new request_id
      resp_409 =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: cmd("w-http-2", "withdraw", "1", %{"submission_ids" => [q1.submission_id]})
        )

      assert resp_409.status == 409
      assert resp_409.body == %{"error" => "submission_not_queued"}

      send(gpid, {:release, gate})
    end
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
