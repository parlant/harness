defmodule H.GenerationRecoveryTest do
  use ExUnit.Case, async: true

  alias H.{Catalog, Daemon}
  alias H.Provider.Fake

  defp start_env(script, extra_opts \\ []) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-gen-rec-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    registry = :"H.GenTest.Registry.#{id}"
    pubsub = :"H.GenTest.PubSub.#{id}"
    catalog = :"H.GenTest.Catalog.#{id}"
    catalog_table = :"h_gen_test_catalog_#{id}"
    lease = :"H.GenTest.Lease.#{id}"
    runtime_sup = :"H.GenTest.RuntimeSup.#{id}"
    fake_name = :"H.GenTest.Fake.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({H.WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})
    fake = start_supervised!({Fake, script: script, name: fake_name})

    on_exit(fn -> File.rm_rf(tmp_root) end)

    opts =
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
      ] ++ extra_opts

    %{opts: opts, cwd: cwd, fake: fake}
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

  describe "ephemeral streaming and deferred persist_within_ms flush" do
    test "emits ephemeral frames at base_seq then flushes live durably at persist_within_ms" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_env(
          [
            {:gate,
             [
               %{type: :thinking_delta, text: "hmm ", metadata: %{}},
               %{type: :text_delta, text: "hello ", metadata: %{}}
             ], test_pid, gate, %{content: [%{type: "text", text: "hello world"}]}}
          ],
          ephemeral_interval_ms: 5,
          persist_within_ms: 40
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-eph", "cwd" => cwd}, opts)

      {:ok, {:snapshot, snap_seq, _}} =
        Daemon.subscribe_conversation("s-eph", "1", self(), nil, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-eph",
          cmd("sub-1", "submit", "1", %{"type" => "input", "content" => "Stream it"}),
          opts
        )

      # Structural commit for user input + run start
      assert_receive {:commit_frame, run_seq, _}
      assert run_seq > snap_seq

      # Ephemeral progress carries base_seq == run_seq
      assert_receive {:ephemeral_frame, eph_bin}, 1_000
      eph = JSON.decode!(eph_bin)
      assert eph["base_seq"] == run_seq
      assert is_list(eph["doc_ops"]["live"])

      # Deferred flush commits durably after persist_within_ms
      assert_receive {:commit_frame, flush_seq, flush_bin}, 1_000
      assert flush_seq > run_seq
      flush = JSON.decode!(flush_bin)
      assert [["replace", flushed_live]] = flush["doc_ops"]["live"]
      assert flushed_live["generation"]["message"]["text"] == "hello "
      assert flushed_live["generation"]["message"]["thinking"] == "hmm "

      assert_receive {:gate_entered, ^gate, gpid}
      send(gpid, {:release, gate})

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-eph", "1", %{"order" => "asc"}, opts)
          if length(items) == 2, do: items, else: nil
        end)

      assert Enum.at(items, 1).data["content"] == [%{"type" => "text", "text" => "hello world"}]
    end
  end

  describe "mid-stream crash recovery, retry accounting, and continue" do
    test "converts flushed partial to aborted entry, retries with backoff, sets interrupted, and resumes via continue" do
      gate1 = make_ref()
      gate2 = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_env(
          [
            {:gate, [%{type: :text_delta, text: "Partial one", metadata: %{}}], test_pid, gate1},
            {:gate, [%{type: :text_delta, text: "Partial two", metadata: %{}}], test_pid, gate2},
            {:expect,
             fn req ->
               # Aborted partial entries must be excluded from model context
               assistant_msgs = Enum.filter(req.messages, &(&1.role == "assistant"))
               assert assistant_msgs == []
               true
             end, {:reply, [], %{content: [%{type: "text", text: "Clean recovery!"}]}}}
          ],
          ephemeral_interval_ms: 5,
          persist_within_ms: 15,
          retry_limit: 1,
          retry_backoff_ms: 20,
          restart_limit: 5
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-crash", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.subscribe_conversation("s-crash", "1", self(), nil, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-crash",
          cmd("c1", "submit", "1", %{"type" => "input", "content" => "Recover me"}),
          opts
        )

      assert_receive {:gate_entered, ^gate1, _}

      # Wait for deferred flush of "Partial one"
      assert_receive {:commit_frame, _seq1, _bin1}
      assert_receive {:commit_frame, _seq2, flush_bin1}, 1_000

      assert JSON.decode!(flush_bin1)["doc_ops"]["live"]
             |> hd()
             |> Enum.at(1)
             |> get_in(["generation", "message", "text"]) == "Partial one"

      # Unclean crash 1 -> restarts=1, retry_count=1 <= 1 -> sleeps -> wakes -> gate2
      [{pid1, _}] = Registry.lookup(opts[:registry], {:session, "s-crash"})
      Process.exit(pid1, :kill)

      assert_receive {:gate_entered, ^gate2, _}, 2_000

      # Wait for deferred flush of "Partial two"
      wait_until(fn ->
        case Registry.lookup(opts[:registry], {:session, "s-crash"}) do
          [{p, _}] when p != pid1 ->
            try do
              {:ok, {:snapshot, _, bin}} =
                Daemon.subscribe_conversation("s-crash", "1", self(), nil, opts)

              live = JSON.decode!(bin)["docs"]["live"]

              if get_in(live, ["generation", "message", "text"]) == "Partial two",
                do: true,
                else: nil
            catch
              :exit, _ -> nil
            end

          _ ->
            nil
        end
      end)

      # Unclean crash 2 -> retry_count=2 > retry_limit=1 -> exhausted -> run_failure: interrupted
      [{pid2, _}] = Registry.lookup(opts[:registry], {:session, "s-crash"})
      Process.exit(pid2, :kill)

      snap =
        wait_until(fn ->
          case Registry.lookup(opts[:registry], {:session, "s-crash"}) do
            [{p, _}] when p != pid2 ->
              try do
                {:ok, {:snapshot, _, bin}} =
                  Daemon.subscribe_conversation("s-crash", "1", self(), nil, opts)

                decoded = JSON.decode!(bin)
                if decoded["docs"]["live"]["run_failure"], do: decoded, else: nil
              catch
                :exit, _ -> nil
              end

            _ ->
              nil
          end
        end)

      assert snap["docs"]["live"]["run_failure"] == %{"reason" => "interrupted"}

      aborted_entries =
        Enum.filter(
          snap["entries"],
          &(&1["kind"] == "assistant" and &1["data"]["aborted"] == true)
        )

      assert length(aborted_entries) == 2

      # Cannot continue while busy? No, it's idle now. Continue resumes cleanly!
      assert {:ok, cont_receipt} =
               Daemon.execute_command(
                 "s-crash",
                 cmd("cont-1", "submit", "1", %{"type" => "continue"}),
                 opts
               )

      assert cont_receipt.status == "placed"

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-crash", "1", %{"order" => "asc"}, opts)
          if length(items) == 4, do: items, else: nil
        end)

      last = List.last(items)
      assert last.kind == "assistant"
      refute Map.get(last.data, "aborted")
      assert last.data["content"] == [%{"type" => "text", "text" => "Clean recovery!"}]
    end
  end

  describe "provider error retries" do
    test "keeps 429 retries active, explains the error, and increases the durable backoff" do
      gate2 = make_ref()
      gate3 = make_ref()
      error = %{code: "http_429", message: "Monthly spending cap reached", retryable: true}

      %{opts: opts, cwd: cwd, fake: fake} =
        start_env(
          [
            {:error, error},
            {:gate, [], self(), gate2},
            {:gate, [], self(), gate3, %{content: [%{type: "text", text: "Recovered"}]}}
          ],
          retry_limit: 2,
          retry_backoff_ms: 200
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-429", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-429",
          cmd("rate", "submit", "1", %{"type" => "input", "content" => "Work"}),
          opts
        )

      retry1 = wait_for_retry("s-429", opts, 1)
      assert retry1["code"] == "http_429"
      assert retry1["message"] == error.message
      assert retry1["delay_ms"] == 200
      assert retry1["max_attempts"] == 2
      assert retry1["status"] == "waiting"

      assert {:ok,
              %{
                session: %{
                  active: true,
                  attention: "retrying",
                  activity_kind: "retry",
                  needs_attention: false
                }
              }} =
               Daemon.get_session_detail("s-429", opts)

      assert_receive {:gate_entered, ^gate2, pid2}, 2_000

      assert {:ok, {:snapshot, _, bin}} =
               Daemon.subscribe_conversation("s-429", "1", self(), nil, opts)

      assert get_in(JSON.decode!(bin), ["docs", "live", "generation", "retry", "status"]) ==
               "running"

      send(pid2, {:release, gate2, {:error, error}})

      retry2 = wait_for_retry("s-429", opts, 2)
      assert retry2["delay_ms"] == 400
      assert retry2["until"] > retry1["until"]
      assert_receive {:gate_entered, ^gate3, pid3}, 2_000
      send(pid3, {:release, gate3})

      wait_until(fn ->
        {:ok, %{session: session}} = Daemon.get_session_detail("s-429", opts)
        session.attention == "idle" and session.needs_attention
      end)

      assert {:ok, {:snapshot, _, bin}} =
               Daemon.subscribe_conversation("s-429", "1", self(), nil, opts)

      refute JSON.decode!(bin)["docs"]["live"]["generation"]
      assert length(Fake.requests(fake)) == 3
    end

    test "honors provider delay and restores the same pending retry across reopen" do
      gate = make_ref()
      error = %{code: "http_429", message: "Rate limited", retryable: true, retry_after_ms: 500}

      %{opts: opts, cwd: cwd, fake: fake} =
        start_env(
          [
            fn _, _ -> {:error, error} end,
            {:gate, [], self(), gate, %{content: [%{type: "text", text: "Recovered"}]}}
          ],
          retry_backoff_ms: 20
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-reopen-retry", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-reopen-retry",
          cmd("rate", "submit", "1", %{"type" => "input", "content" => "Work"}),
          opts
        )

      retry = wait_for_retry("s-reopen-retry", opts, 1)
      assert retry["delay_ms"] == 500
      [sup] = DynamicSupervisor.which_children(opts[:runtime_sup]) |> Enum.map(&elem(&1, 1))
      :ok = DynamicSupervisor.terminate_child(opts[:runtime_sup], sup)

      assert {:ok, %{session: %{active: true, attention: "retrying", next_wake_at: deadline}}} =
               Daemon.get_session_detail("s-reopen-retry", opts)

      assert deadline == retry["until"]
      assert wait_for_retry("s-reopen-retry", opts, 1) == retry
      assert length(Fake.requests(fake)) == 1
      assert_receive {:gate_entered, ^gate, pid}, 2_000
      send(pid, {:release, gate})
    end

    test "exponential delay is capped" do
      assert H.Session.Server.Generation.retry_delay_ms(%{retry_backoff_ms: 2_000}, 1) == 2_000
      assert H.Session.Server.Generation.retry_delay_ms(%{retry_backoff_ms: 2_000}, 2) == 4_000
      assert H.Session.Server.Generation.retry_delay_ms(%{retry_backoff_ms: 2_000}, 100) == 60_000
    end

    test "exhausts its retry budget with the provider explanation intact" do
      error = %{code: "http_429", message: "Monthly spending cap reached", retryable: true}

      %{opts: opts, cwd: cwd, fake: fake} =
        start_env(List.duplicate({:error, error}, 3), retry_limit: 2, retry_backoff_ms: 10)

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-exhaust", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-exhaust",
          cmd("rate", "submit", "1", %{"type" => "input", "content" => "Work"}),
          opts
        )

      failure =
        wait_until(fn ->
          {:ok, {:snapshot, _, bin}} =
            Daemon.subscribe_conversation("s-exhaust", "1", self(), nil, opts)

          get_in(JSON.decode!(bin), ["docs", "live", "run_failure"])
        end)

      assert failure["message"] =~ error.message
      assert failure["message"] =~ "Automatic retries exhausted"
      assert failure["retry_count"] == 2

      assert {:ok, %{session: %{active: false, attention: "error", needs_attention: true}}} =
               Daemon.get_session_detail("s-exhaust", opts)

      assert length(Fake.requests(fake)) == 3
    end

    test "abort during backoff prevents another provider dispatch" do
      %{opts: opts, cwd: cwd, fake: fake} =
        start_env([{:error, %{code: "http_429", message: "Rate limited", retryable: true}}],
          retry_backoff_ms: 60_000
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-abort-retry", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-abort-retry",
          cmd("rate", "submit", "1", %{"type" => "input", "content" => "Work"}),
          opts
        )

      wait_for_retry("s-abort-retry", opts, 1)
      {:ok, _} = Daemon.execute_command("s-abort-retry", cmd("abort", "abort", "1", %{}), opts)
      [{server, _}] = Registry.lookup(opts[:registry], {:session, "s-abort-retry"})
      state = :sys.get_state(server)
      [task] = Map.values(state.tasks)
      send(server, {:wake_task, task.id})

      assert {:ok, %{session: %{active: false}}} =
               Daemon.get_session_detail("s-abort-retry", opts)

      assert length(Fake.requests(fake)) == 1
    end
  end

  defp wait_for_retry(sid, opts, attempt) do
    wait_until(fn ->
      {:ok, {:snapshot, _, bin}} = Daemon.subscribe_conversation(sid, "1", self(), nil, opts)
      retry = get_in(JSON.decode!(bin), ["docs", "live", "generation", "retry"])
      if retry && retry["attempt"] == attempt && retry["status"] == "waiting", do: retry
    end)
  end

  describe "clean close vs continue edge cases" do
    test "clean close resets running task to pending without charging restarts or retries" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_env([
          {:gate, [%{type: :text_delta, text: "discarded unpersisted", metadata: %{}}], test_pid,
           gate},
          {:reply, [], %{content: [%{type: "text", text: "Resumed cleanly!"}]}}
        ])

      # Hold unclean recovery in backoff so this test distinguishes it from a clean reset.
      opts = Keyword.put(opts, :retry_backoff_ms, 60_000)

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-clean", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-clean",
          cmd("c1", "submit", "1", %{"type" => "input", "content" => "Clean close"}),
          opts
        )

      assert_receive {:gate_entered, ^gate, _}

      # Cleanly stop the session supervisor child
      [sup_pid] =
        DynamicSupervisor.which_children(opts[:runtime_sup])
        |> Enum.map(&elem(&1, 1))

      :ok = DynamicSupervisor.terminate_child(opts[:runtime_sup], sup_pid)

      # Reopen session via get_session_detail -> auto-resumes pending task without aborted entry!
      {:ok, detail} = Daemon.get_session_detail("s-clean", opts)
      assert detail.session.status == "ok"
      assert [%{kind: "generation", restarts: 0}] = detail.tasks

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-clean", "1", %{"order" => "asc"}, opts)
          if length(items) == 2, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == ["user", "assistant"]

      assert Enum.at(items, 1).data["content"] == [
               %{"type" => "text", "text" => "Resumed cleanly!"}
             ]
    end

    test "continue rejects when busy and fails with nothing_to_answer when idle with no prompt" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_env([
          {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Done"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-cont", "cwd" => cwd}, opts)

      # Empty conversation -> nothing_to_answer
      assert {:ok, %{status: "unanswered", reason: "nothing_to_answer"}} =
               Daemon.execute_command(
                 "s-cont",
                 cmd("c-empty", "submit", "1", %{"type" => "continue"}),
                 opts
               )

      # Start active run -> continue returns conversation_busy
      {:ok, _} =
        Daemon.execute_command(
          "s-cont",
          cmd("s1", "submit", "1", %{"type" => "input", "content" => "Busy"}),
          opts
        )

      assert_receive {:gate_entered, ^gate, gpid}

      assert {:error, {:conflict, "conversation_busy"}} =
               Daemon.execute_command(
                 "s-cont",
                 cmd("c-busy", "submit", "1", %{"type" => "continue"}),
                 opts
               )

      send(gpid, {:release, gate})

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-cont", "1", %{"order" => "asc"}, opts)
        if length(items) == 2, do: items, else: nil
      end)
    end

    test "continue recovers a historical conversation ending in an empty content-filtered assistant entry" do
      %{opts: opts, cwd: cwd} =
        start_env([
          {:reply, [], %{content: [%{type: "text", text: "Recovered after historical filter"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-hist-empty", "cwd" => cwd}, opts)
      [{server, _}] = Registry.lookup(opts[:registry], {:session, "s-hist-empty"})

      {:ok, _} =
        H.Session.Server.seed_entries(server, [
          %{kind: "user", data: %{"content" => [%{"type" => "text", "text" => "Do work"}]}},
          %{
            kind: "assistant",
            data: %{
              "content" => [],
              "tool_calls" => [],
              "finish_reason" => "content_filter",
              "provider_meta" => %{"finish_reason_raw" => "PROHIBITED_CONTENT"}
            }
          }
        ])

      assert {:ok, %{status: "placed"}} =
               Daemon.execute_command(
                 "s-hist-empty",
                 cmd("c-hist-rec", "submit", "1", %{"type" => "continue"}),
                 opts
               )

      items =
        wait_until(fn ->
          {:ok, %{items: items}} =
            Daemon.scan_entries("s-hist-empty", "1", %{"order" => "asc"}, opts)

          if length(items) == 3, do: items, else: nil
        end)

      assert List.last(items).data["content"] == [
               %{"type" => "text", "text" => "Recovered after historical filter"}
             ]
    end
  end
end
