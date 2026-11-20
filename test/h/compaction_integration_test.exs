defmodule H.CompactionIntegrationTest do
  use ExUnit.Case, async: true

  alias H.{Auth, Catalog, Daemon, StoreLock, WorkspaceLease}
  alias H.HTTP.Router
  alias H.Provider.Fake

  defp start_daemon_env(script, extra_opts \\ []) do
    id = System.unique_integer([:positive, :monotonic])
    tmp_root = Path.join(System.tmp_dir!(), "h-cmp-int-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd)

    on_exit(fn -> File.rm_rf(tmp_root) end)

    registry = :"H.CmpInt.Registry.#{id}"
    pubsub = :"H.CmpInt.PubSub.#{id}"
    catalog = :"H.CmpInt.Catalog.#{id}"
    catalog_table = :"h_cmp_int_catalog_#{id}"
    lease = :"H.CmpInt.Lease.#{id}"
    runtime_sup = :"H.CmpInt.RuntimeSup.#{id}"
    fake_name = :"H.CmpInt.Fake.#{id}"

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
          default_model: "fake:coder",
          compaction_keep_recent_chars: 100
        ],
        extra_opts
      )

    %{
      opts: opts,
      cwd: cwd,
      data_dir: data_dir,
      fake: fake,
      registry: registry,
      tmp_root: tmp_root
    }
  end

  defp restart_daemon_env(data_dir, script, extra_opts) do
    id = System.unique_integer([:positive, :monotonic])
    registry = :"H.CmpInt.ReRegistry.#{id}"
    pubsub = :"H.CmpInt.RePubSub.#{id}"
    catalog = :"H.CmpInt.ReCatalog.#{id}"
    catalog_table = :"h_cmp_int_recatalog_#{id}"
    lease = :"H.CmpInt.ReLease.#{id}"
    runtime_sup = :"H.CmpInt.ReRuntimeSup.#{id}"
    fake_name = :"H.CmpInt.ReFake.#{id}"

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
          default_model: "fake:coder",
          compaction_keep_recent_chars: 100
        ],
        extra_opts
      )

    %{opts: opts, fake: fake, registry: registry}
  end

  defp build_http_req(daemon_opts, data_dir) do
    id = System.unique_integer([:positive, :monotonic])
    auth_name = :"H.CmpHttp.Auth.#{id}"
    auth_table = :"h_cmp_http_auth_#{id}"
    {:ok, _} = start_supervised({Auth, data_dir: data_dir, name: auth_name, table: auth_table})
    token = Auth.owner_token(auth_table)

    router_opts = [
      port: 4000,
      auth_server: auth_name,
      auth_table: auth_table,
      daemon: Daemon,
      daemon_opts: daemon_opts
    ]

    Req.new(
      base_url: "http://127.0.0.1:4000",
      plug: {Router, router_opts},
      headers: [{"host", "127.0.0.1:4000"}, {"authorization", "Bearer #{token}"}],
      retry: false
    )
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
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end

  defp seed_two_turns(sid, opts) do
    {:ok, _} =
      Daemon.execute_command(
        sid,
        cmd("s-t1", "submit", "1", %{"type" => "input", "content" => "Turn 1 prompt"}),
        opts
      )

    wait_until(fn ->
      {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)
      if length(items) == 2, do: items, else: nil
    end)

    {:ok, _} =
      Daemon.execute_command(
        sid,
        cmd("s-t2", "submit", "1", %{
          "type" => "input",
          "content" => String.duplicate("Recent turn 2 ", 15)
        }),
        opts
      )

    wait_until(fn ->
      {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)
      if length(items) == 4, do: items, else: nil
    end)

    {:ok, {:snapshot, seq, _bin}} = Daemon.subscribe_conversation(sid, "1", self(), nil, opts)
    seq
  end

  defp await_ready_pid_and_seq(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case String.split(String.trim(line), ":") do
          ["READY", pid, seq] -> {pid, seq}
          _ -> await_ready_pid_and_seq(port)
        end

      {^port, {:exit_status, status}} ->
        flunk("child VM exited before READY with status #{status}")
    after
      10_000 ->
        flunk("timed out waiting for child VM READY")
    end
  end

  test "a long tool result triggers one checkpoint and the original submission completes without replay" do
    call = %{id: "auto-read", name: "read", arguments: %{"path" => "large.txt"}}

    script = [
      {:reply, [], %{tool_calls: [call], content: [], finish_reason: "tool_calls"}},
      {:reply, [], %{content: [%{type: "text", text: "Keep investigating the file"}]}},
      {:reply, [], %{content: [%{type: "text", text: "Original task complete"}]}}
    ]

    %{opts: opts, cwd: cwd, fake: fake} = start_daemon_env(script)

    opts =
      Keyword.put(opts, :auto_compaction, %{
        :default => 100_000,
        {:cwd, cwd, "fake:coder"} => 2_000
      })

    File.write!(Path.join(cwd, "large.txt"), String.duplicate("detail ", 2_000))
    sid = "auto-compact"
    {:ok, _} = Daemon.create_session(%{"session_id" => sid, "cwd" => cwd}, opts)
    command = cmd("one", "submit", "1", %{"type" => "input", "content" => "Read large.txt"})
    {:ok, _} = Daemon.execute_command(sid, command, opts)

    entries =
      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)

        if Enum.any?(items, &(&1.kind == "compaction")) and List.last(items).kind == "assistant",
          do: items
      end)

    assert Enum.map(entries, & &1.kind) == [
             "user",
             "assistant",
             "tool_result",
             "compaction",
             "assistant"
           ]

    assert List.last(entries).data["content"] == [
             %{"type" => "text", "text" => "Original task complete"}
           ]

    assert [_, _, resumed] = Fake.requests(fake)

    assert Enum.any?(resumed.messages, fn message ->
             inspect(message.content) =~ "Keep investigating the file"
           end)

    assert {:ok, %{status: "done"}} = Daemon.execute_command(sid, command, opts)
  end

  test "a single prompt can run more than fifty tool rounds and finish normally" do
    rounds =
      for n <- 1..51 do
        call = %{id: "read-#{n}", name: "read", arguments: %{"path" => "small.txt"}}
        {:reply, [], %{content: [], tool_calls: [call], finish_reason: "tool_calls"}}
      end

    %{opts: opts, cwd: cwd} =
      start_daemon_env(rounds ++ [{:reply, [], %{content: [%{type: "text", text: "Finished"}]}}])

    File.write!(Path.join(cwd, "small.txt"), "ok")
    sid = "long-tool-run"
    {:ok, _} = Daemon.create_session(%{"session_id" => sid, "cwd" => cwd}, opts)
    command = cmd("one", "submit", "1", %{"type" => "input", "content" => "Start"})
    {:ok, _} = Daemon.execute_command(sid, command, opts)

    wait_until(
      fn ->
        {:ok, %{items: items}} =
          Daemon.scan_entries(sid, "1", %{"order" => "desc", "limit" => 1}, opts)

        match?([%{data: %{"content" => [%{"text" => "Finished"}]}}], items)
      end,
      10_000
    )
  end

  describe "managed attempt recovery" do
    test "worker loss leaves generation interrupted rather than dispatching again" do
      test = self()
      %{opts: opts, cwd: cwd} = start_daemon_env([], default_model: "openai_codex:gpt-6.1-sol")
      opts = managed_opts(opts, test, 0)
      {:ok, _} = Daemon.create_session(%{"session_id" => "managed-gen", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "managed-gen",
          cmd("managed", "submit", "1", %{"type" => "input", "content" => "Start"}),
          opts
        )

      assert_receive {:managed_dispatch, worker}, 3000
      Process.exit(worker, :kill)
      assert interrupted?("managed-gen", "generation", opts)
      refute_receive {:managed_dispatch, _}, 70
    end

    test "clean reopen honors the recorded compaction policy after disabling managed accounts" do
      test = self()

      %{opts: opts, cwd: cwd, data_dir: dir} =
        start_daemon_env([],
          default_model: "openai_codex:gpt-6.1-sol",
          storage_opts: [sync: :datasync]
        )

      opts = managed_opts(opts, test, 2)
      sid = "managed-compaction"
      {:ok, _} = Daemon.create_session(%{"session_id" => sid, "cwd" => cwd}, opts)
      seq = seed_two_turns(sid, opts)

      {:ok, _} =
        Daemon.execute_command(
          sid,
          cmd("managed-compact", "compact", "1", %{"expected_seq" => seq}),
          opts
        )

      assert_receive {:managed_dispatch, _}, 3000
      [{_, child, _, _}] = DynamicSupervisor.which_children(opts[:runtime_sup])
      :ok = DynamicSupervisor.terminate_child(opts[:runtime_sup], child)

      %{opts: stock, fake: fake} =
        restart_daemon_env(dir, [], default_model: "fake:coder", retry_backoff_ms: 1)

      assert :ok = Daemon.recover_active_sessions(stock)
      assert interrupted?(sid, "compaction", stock)

      assert {:ok,
              %{
                items: [
                  %{kind: "user"},
                  %{kind: "assistant"},
                  %{kind: "user"},
                  %{kind: "assistant"}
                ]
              }} =
               Daemon.scan_entries(sid, "1", %{"order" => "asc"}, stock)

      assert H.Provider.Fake.requests(fake) == []
    end
  end

  defp managed_opts(opts, test, initial_replies) do
    alias H.Accounts.Vault
    dir = opts[:data_dir]
    File.chmod!(dir, 0o700)
    {:ok, vault, _} = Vault.open(dir, [])

    :ok =
      Vault.write(vault, "fixture", %{
        "access_token" => "test-only-codex-access",
        "refresh_token" => "test-only-codex-refresh",
        "account_id" => "test-account",
        "subject" => "test-subject",
        "expires_at_ms" => System.system_time(:millisecond) + 120_000
      })

    server =
      start_supervised!(
        {H.Accounts,
         data_dir: dir, sources: ["fixture"], http: fn _ -> flunk("unexpected auth request") end}
      )

    count = :atomics.new(1, [])

    stream = fn _, _, _ ->
      if :atomics.add_get(count, 1, 1) <= initial_replies do
        {:ok,
         [
           %ReqLLM.StreamEvent{type: :text_delta, data: "Test answer"},
           %ReqLLM.StreamEvent{type: :finish, data: %{finish_reason: :stop}}
         ]}
      else
        send(test, {:managed_dispatch, self()})

        receive do
          :unreached -> {:error, "unexpected"}
        end
      end
    end

    Keyword.merge(opts,
      provider: H.Provider.ReqLLM,
      accounts: server,
      provider_config: %{stream_fn: stream},
      retry_backoff_ms: 1
    )
  end

  defp interrupted?(sid, kind, opts) do
    wait_until(fn ->
      {:ok, detail} = Daemon.get_session_detail(sid, opts)

      Enum.any?(detail.tasks, fn task ->
        task.kind == kind and task.status == "terminal" and
          task.outcome["reason"] == "interrupted"
      end)
    end)
  end

  describe "HTTP contract, idempotency, and conflict guards" do
    test "validates compact args, enforces expected_seq and idle/compactable guards, and deduplicates request_id" do
      %{opts: opts, cwd: cwd, data_dir: data_dir} =
        start_daemon_env(
          [
            {:reply, [], %{content: [%{type: "text", text: "Reply 1"}]}},
            {:reply, [], %{content: [%{type: "text", text: String.duplicate("Reply 2 ", 15)}]}},
            {:expect,
             fn req ->
               [_, %{role: "user", content: [%{text: prompt}]}] = req.messages
               assert prompt =~ "User instructions: Focus on API"
               assert prompt =~ "[User]: Turn 1 prompt"
               assert prompt =~ "[Assistant]: Reply 1"
               refute prompt =~ "Recent turn 2"
               true
             end,
             {:reply, [],
              %{
                content: [%{type: "text", text: "## Goal\nCompacted T1"}],
                usage: %{input_tokens: 20, output_tokens: 8}
              }}}
          ],
          compaction_keep_recent_chars: 150
        )

      req = build_http_req(opts, data_dir)

      {:ok, %{seq: seq0}} = Daemon.create_session(%{"session_id" => "s-http", "cwd" => cwd}, opts)

      # Invalid args -> 422
      for bad_args <- [
            %{},
            %{"expected_seq" => -1},
            %{"expected_seq" => "1"},
            %{"expected_seq" => seq0, "instructions" => 123}
          ] do
        resp =
          Req.post!(req,
            url: "/api/v1/sessions/s-http/commands",
            json: cmd("cmp-bad-#{System.unique_integer([:positive])}", "compact", "1", bad_args)
          )

        assert resp.status == 422
      end

      # Empty session -> 409 nothing_to_compact
      empty_resp =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: cmd("cmp-empty", "compact", "1", %{"expected_seq" => seq0})
        )

      assert empty_resp.status == 409
      assert empty_resp.body["error"] == "nothing_to_compact"

      seq = seed_two_turns("s-http", opts)

      # Stale expected_seq -> 409
      stale_resp =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: cmd("cmp-stale", "compact", "1", %{"expected_seq" => seq - 1})
        )

      assert stale_resp.status == 409
      assert stale_resp.body["error"] == "expected_seq mismatch"

      # Valid compact -> 200 receipt
      ok_payload =
        cmd("cmp-ok-1", "compact", "1", %{
          "expected_seq" => seq,
          "instructions" => "Focus on API"
        })

      ok_resp =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: ok_payload
        )

      assert ok_resp.status == 200
      assert ok_resp.body["version"] == 1
      assert ok_resp.body["request_id"] == "cmp-ok-1"
      assert is_binary(ok_resp.body["submission_id"])
      assert ok_resp.body["status"] == "placed"

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-http", "1", %{"order" => "asc"}, opts)
          if length(items) == 5, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == [
               "user",
               "assistant",
               "user",
               "assistant",
               "compaction"
             ]

      comp_entry = List.last(items)
      assert comp_entry.data["summary"] == "## Goal\nCompacted T1"
      assert comp_entry.data["instructions"] == "Focus on API"
      assert comp_entry.data["kept_from_id"] == String.to_integer(Enum.at(items, 2).id)

      # Idempotent retry of same request_id + payload returns done receipt without second marker
      retry_resp =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: ok_payload
        )

      assert retry_resp.status == 200
      assert retry_resp.body["submission_id"] == ok_resp.body["submission_id"]
      assert retry_resp.body["status"] == "done"

      # Reused request_id with different payload -> 409
      conflict_resp =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json:
            cmd("cmp-ok-1", "compact", "1", %{"expected_seq" => seq, "instructions" => "Other"})
        )

      assert conflict_resp.status == 409

      # Subsequent compact with updated seq right after compaction -> 409 already_compacted
      {:ok, {:snapshot, seq_after, _}} =
        Daemon.subscribe_conversation("s-http", "1", self(), nil, opts)

      again_resp =
        Req.post!(req,
          url: "/api/v1/sessions/s-http/commands",
          json: cmd("cmp-again", "compact", "1", %{"expected_seq" => seq_after})
        )

      assert again_resp.status == 409
      assert again_resp.body["error"] == "already_compacted"
    end

    test "rejects compact while generation, user_shell, or another compact is active (conversation_busy)" do
      gate_gen = make_ref()
      gate_cmp = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_daemon_env([
          {:reply, [], %{content: [%{type: "text", text: "Reply 1"}]}},
          {:reply, [], %{content: [%{type: "text", text: String.duplicate("Reply 2 ", 15)}]}},
          {:gate, [], test_pid, gate_gen, %{content: [%{type: "text", text: "Reply 3"}]}},
          {:gate, [], test_pid, gate_cmp, %{content: [%{type: "text", text: "Summary"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-busy", "cwd" => cwd}, opts)
      _seq = seed_two_turns("s-busy", opts)

      # 1. Busy due to active generation
      {:ok, _} =
        Daemon.execute_command(
          "s-busy",
          cmd("g-busy", "submit", "1", %{"type" => "input", "content" => "Turn 3"}),
          opts
        )

      assert_receive {:gate_entered, ^gate_gen, gen_worker}

      {:ok, {:snapshot, seq_gen, _}} =
        Daemon.subscribe_conversation("s-busy", "1", self(), nil, opts)

      assert {:error, {:conflict, "conversation_busy"}} =
               Daemon.execute_command(
                 "s-busy",
                 cmd("cmp-during-gen", "compact", "1", %{"expected_seq" => seq_gen}),
                 opts
               )

      send(gen_worker, {:release, gate_gen})

      wait_until(fn ->
        {:ok, detail} = Daemon.get_session_detail("s-busy", opts)
        if Enum.all?(detail.tasks, &(&1.status == "terminal")), do: true, else: nil
      end)

      # 2. Busy due to active user_shell
      {:ok, {:snapshot, seq_idle, _}} =
        Daemon.subscribe_conversation("s-busy", "1", self(), nil, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-busy",
          cmd("us-busy", "user_shell", "1", %{
            "command" => "sleep 0.4",
            "include_in_context" => false,
            "expected_seq" => seq_idle
          }),
          opts
        )

      wait_until(fn ->
        {:ok, {:snapshot, _s, bin}} =
          Daemon.subscribe_conversation("s-busy", "1", self(), nil, opts)

        if get_in(JSON.decode!(bin), ["docs", "live", "user_shell"]) != nil, do: true, else: nil
      end)

      {:ok, {:snapshot, seq_us, _}} =
        Daemon.subscribe_conversation("s-busy", "1", self(), nil, opts)

      assert {:error, {:conflict, "conversation_busy"}} =
               Daemon.execute_command(
                 "s-busy",
                 cmd("cmp-during-us", "compact", "1", %{"expected_seq" => seq_us}),
                 opts
               )

      wait_until(fn ->
        {:ok, detail} = Daemon.get_session_detail("s-busy", opts)
        if Enum.all?(detail.tasks, &(&1.status == "terminal")), do: true, else: nil
      end)

      # 3. Busy due to active compaction
      {:ok, {:snapshot, seq_ready, _}} =
        Daemon.subscribe_conversation("s-busy", "1", self(), nil, opts)

      assert {:ok, _} =
               Daemon.execute_command(
                 "s-busy",
                 cmd("cmp-1", "compact", "1", %{"expected_seq" => seq_ready}),
                 opts
               )

      assert_receive {:gate_entered, ^gate_cmp, cmp_worker}

      {:ok, {:snapshot, seq_cmp, _}} =
        Daemon.subscribe_conversation("s-busy", "1", self(), nil, opts)

      assert {:error, {:conflict, "conversation_busy"}} =
               Daemon.execute_command(
                 "s-busy",
                 cmd("cmp-2", "compact", "1", %{"expected_seq" => seq_cmp}),
                 opts
               )

      send(cmp_worker, {:release, gate_cmp})

      wait_until(fn ->
        {:ok, detail} = Daemon.get_session_detail("s-busy", opts)
        if Enum.all?(detail.tasks, &(&1.status == "terminal")), do: true, else: nil
      end)
    end
  end

  describe "context isolation, user_shell !/!!, double compaction, and fork safety" do
    test "includes ! shell, excludes !! shell, never mutates prior entries, and updates subsequent context" do
      %{opts: opts, cwd: cwd, fake: fake} =
        start_daemon_env([
          {:reply, [], %{content: [%{type: "text", text: "Turn 1 reply"}]}},
          {:expect,
           fn req ->
             [_, %{role: "user", content: [%{text: prompt}]}] = req.messages
             assert prompt =~ "Turn 1 prompt"
             assert prompt =~ "Turn 1 reply"
             assert prompt =~ "Ran `echo visible-cmd && echo visible-out`"
             assert prompt =~ "visible-out"
             refute prompt =~ "printenv"
             refute prompt =~ "HIDDEN_SECRET"
             true
           end, {:reply, [], %{content: [%{type: "text", text: "## Goal\nPhase 1 summary"}]}}},
          {:expect,
           fn req ->
             texts =
               req.messages
               |> Enum.flat_map(& &1.content)
               |> Enum.map(&Map.get(&1, :text, ""))
               |> Enum.join("\n")

             assert texts =~ "Phase 1 summary"
             assert texts =~ "Recent kept turn"
             assert texts =~ "After compaction prompt"
             refute texts =~ "Turn 1 prompt"
             refute texts =~ "HIDDEN_SECRET"
             true
           end, {:reply, [], %{content: [%{type: "text", text: "Post-compaction answer"}]}}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-iso", "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-iso",
          cmd("t1", "submit", "1", %{"type" => "input", "content" => "Turn 1 prompt"}),
          opts
        )

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-iso", "1", %{"order" => "asc"}, opts)
        if length(items) == 2, do: items, else: nil
      end)

      {:ok, {:snapshot, seq1, _}} = Daemon.subscribe_conversation("s-iso", "1", self(), nil, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-iso",
          cmd("us-inc", "user_shell", "1", %{
            "command" => "echo visible-cmd && echo visible-out",
            "include_in_context" => true,
            "expected_seq" => seq1
          }),
          opts
        )

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-iso", "1", %{"order" => "asc"}, opts)
        if length(items) == 3, do: items, else: nil
      end)

      {:ok, {:snapshot, seq2, _}} = Daemon.subscribe_conversation("s-iso", "1", self(), nil, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-iso",
          cmd("us-exc", "user_shell", "1", %{
            "command" => "echo printenv && echo HIDDEN_SECRET",
            "include_in_context" => false,
            "expected_seq" => seq2
          }),
          opts
        )

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-iso", "1", %{"order" => "asc"}, opts)
        if length(items) == 4, do: items, else: nil
      end)

      {:ok, _} =
        Daemon.execute_command(
          "s-iso",
          cmd("t2-write", "submit", "1", %{
            "type" => "write",
            "kind" => "user",
            "content" => String.duplicate("Recent kept turn ", 10)
          }),
          opts
        )

      {:ok, %{items: before_items}} =
        Daemon.scan_entries("s-iso", "1", %{"order" => "asc"}, opts)

      {:ok, {:snapshot, seq3, _}} = Daemon.subscribe_conversation("s-iso", "1", self(), nil, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-iso",
          cmd("cmp", "compact", "1", %{"expected_seq" => seq3}),
          opts
        )

      after_items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-iso", "1", %{"order" => "asc"}, opts)
          if length(items) == 6, do: items, else: nil
        end)

      # All previous entries untouched
      assert Enum.take(after_items, 5) == before_items
      assert List.last(after_items).kind == "compaction"

      # Next turn sees summary + kept entry, never dropped or !! entries
      {:ok, _} =
        Daemon.execute_command(
          "s-iso",
          cmd("t3", "submit", "1", %{"type" => "input", "content" => "After compaction prompt"}),
          opts
        )

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries("s-iso", "1", %{"order" => "asc"}, opts)
        if length(items) == 8, do: items, else: nil
      end)

      # Forked conversation compacts independently without affecting root conversation
      first_reply_id = String.to_integer(Enum.at(after_items, 1).id)

      Fake.push_step(
        fake,
        {:reply, [], %{content: [%{type: "text", text: "Branch answer"}]}}
      )

      Fake.push_step(
        fake,
        {:expect,
         fn req ->
           [_, %{role: "user", content: [%{text: prompt}]}] = req.messages
           assert prompt =~ "Turn 1 prompt"
           assert prompt =~ "Turn 1 reply"
           refute prompt =~ "Branch kept turn"
           true
         end, {:reply, [], %{content: [%{type: "text", text: "Branch summary"}]}}}
      )

      {:ok, fork_receipt} =
        Daemon.execute_command(
          "s-iso",
          cmd("fork-1", "fork_and_submit", "1", %{
            "at_entry_id" => first_reply_id,
            "content" => String.duplicate("Branch kept turn ", 10)
          }),
          opts
        )

      branch_cid = fork_receipt.conversation_id

      wait_until(fn ->
        {:ok, %{items: b_items}} =
          Daemon.scan_entries("s-iso", branch_cid, %{"order" => "asc"}, opts)

        if length(b_items) == 4, do: b_items, else: nil
      end)

      {:ok, {:snapshot, branch_seq, _}} =
        Daemon.subscribe_conversation("s-iso", branch_cid, self(), nil, opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-iso",
          cmd("cmp-branch", "compact", branch_cid, %{"expected_seq" => branch_seq}),
          opts
        )

      branch_items =
        wait_until(fn ->
          {:ok, %{items: b_items}} =
            Daemon.scan_entries("s-iso", branch_cid, %{"order" => "asc"}, opts)

          if length(b_items) == 5, do: b_items, else: nil
        end)

      assert List.last(branch_items).kind == "compaction"
      assert List.last(branch_items).data["summary"] == "Branch summary"

      # Root conversation still has its original compaction summary untouched
      {:ok, %{items: root_after_items}} =
        Daemon.scan_entries("s-iso", "1", %{"order" => "asc"}, opts)

      assert Enum.find(root_after_items, &(&1.kind == "compaction")).data["summary"] ==
               "## Goal\nPhase 1 summary"

      assert length(Fake.requests(fake)) == 5
    end
  end

  describe "failure visibility, fencing, and abort" do
    test "a prompt paused during automatic compaction identifies the phase and preserves the history" do
      %{opts: opts, cwd: cwd, fake: fake} =
        start_daemon_env(
          [
            {:reply, [], %{content: [%{type: "text", text: "First reply"}]}},
            {:error,
             %{
               code: "codex_pool_alias_mismatch",
               message: "Update the pool sources in extensions.json",
               retryable: false
             }}
          ],
          auto_compaction: %{:default => 150}
        )

      sid = "automatic-failure"
      {:ok, _} = Daemon.create_session(%{"session_id" => sid, "cwd" => cwd}, opts)

      {:ok, _} =
        Daemon.execute_command(
          sid,
          cmd("first", "submit", "1", %{"type" => "input", "content" => "First question"}),
          opts
        )

      wait_until(fn ->
        {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)
        length(items) == 2
      end)

      command =
        cmd("second", "submit", "1", %{
          "type" => "input",
          "content" => String.duplicate("x", 1_000)
        })

      assert {:ok, %{status: "placed"}} = Daemon.execute_command(sid, command, opts)

      failure =
        wait_until(fn ->
          {:ok, {:snapshot, _, bin}} = Daemon.subscribe_conversation(sid, "1", self(), nil, opts)
          get_in(JSON.decode!(bin), ["docs", "live", "compaction_failure"])
        end)

      assert %{"automatic" => true, "code" => "codex_pool_alias_mismatch", "message" => message} =
               failure

      assert message =~ "extensions.json"
      assert {:ok, %{status: "unanswered"}} = Daemon.execute_command(sid, command, opts)
      assert {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)
      assert Enum.map(items, & &1.kind) == ["user", "assistant", "user"]
      assert length(Fake.requests(fake)) == 2
    end

    test "keeps compaction_failure visible without committing marker or auto-resubmitting" do
      %{opts: opts, cwd: cwd, fake: fake} =
        start_daemon_env([
          {:reply, [], %{content: [%{type: "text", text: "Reply 1"}]}},
          {:reply, [], %{content: [%{type: "text", text: String.duplicate("Reply 2 ", 15)}]}},
          {:reply, [], %{content: [%{type: "text", text: "partial"}], finish_reason: "length"}},
          {:reply, [], %{content: [%{type: "text", text: "Recovered checkpoint"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-fail", "cwd" => cwd}, opts)
      seq = seed_two_turns("s-fail", opts)

      {:ok, receipt} =
        Daemon.execute_command(
          "s-fail",
          cmd("cmp-fail", "compact", "1", %{"expected_seq" => seq}),
          opts
        )

      assert receipt.status == "placed"

      snap =
        wait_until(fn ->
          {:ok, {:snapshot, _s, bin}} =
            Daemon.subscribe_conversation("s-fail", "1", self(), nil, opts)

          decoded = JSON.decode!(bin)

          if get_in(decoded, ["docs", "live", "compaction_failure"]) != nil do
            decoded
          else
            nil
          end
        end)

      failure = snap["docs"]["live"]["compaction_failure"]
      assert failure["code"] == "truncated_summary"
      assert failure["automatic"] == false
      assert failure["message"] =~ "token cap"
      assert snap["docs"]["live"]["compaction"] == nil

      # No compaction entry committed and no automatic resubmit
      {:ok, %{items: items}} = Daemon.scan_entries("s-fail", "1", %{"order" => "asc"}, opts)
      assert Enum.map(items, & &1.kind) == ["user", "assistant", "user", "assistant"]
      assert length(Fake.requests(fake)) == 3

      # Idempotent retry returns unanswered receipt without retrying provider
      {:ok, retry_receipt} =
        Daemon.execute_command(
          "s-fail",
          cmd("cmp-fail", "compact", "1", %{"expected_seq" => seq}),
          opts
        )

      assert retry_receipt.status == "unanswered"
      assert retry_receipt.reason == "truncated_summary"
      assert length(Fake.requests(fake)) == 3

      # A fresh /compact retries from the intact history, not the partial summary.
      assert {:ok, %{status: "placed"}} =
               Daemon.execute_command(
                 "s-fail",
                 cmd("cmp-recover", "compact", "1", %{"expected_seq" => snap["seq"]}),
                 opts
               )

      recovered =
        wait_until(fn ->
          {:ok, %{items: after_items}} =
            Daemon.scan_entries("s-fail", "1", %{"order" => "asc"}, opts)

          if List.last(after_items).kind == "compaction", do: after_items
        end)

      assert Enum.take(recovered, 4) == items
      assert List.last(recovered).data["summary"] == "Recovered checkpoint"
      assert List.last(Fake.requests(fake)).max_tokens == 16_384
    end

    test "abort cancels active compaction, keeps compaction_failure, and fences late worker result" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd, registry: registry} =
        start_daemon_env([
          {:reply, [], %{content: [%{type: "text", text: "Reply 1"}]}},
          {:reply, [], %{content: [%{type: "text", text: String.duplicate("Reply 2 ", 15)}]}},
          {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Late summary"}]}}
        ])

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-abort", "cwd" => cwd}, opts)
      seq = seed_two_turns("s-abort", opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-abort",
          cmd("cmp-ab", "compact", "1", %{"expected_seq" => seq}),
          opts
        )

      assert_receive {:gate_entered, ^gate, worker_pid}

      {:ok, _} =
        Daemon.execute_command(
          "s-abort",
          cmd("ab-1", "abort", "1", %{"reason" => "user_abort"}),
          opts
        )

      snap =
        wait_until(fn ->
          {:ok, {:snapshot, _s, bin}} =
            Daemon.subscribe_conversation("s-abort", "1", self(), nil, opts)

          decoded = JSON.decode!(bin)

          if get_in(decoded, ["docs", "live", "compaction_failure"]) != nil do
            decoded
          else
            nil
          end
        end)

      assert snap["docs"]["live"]["compaction_failure"]["reason"] == "user_abort"
      assert snap["docs"]["live"]["compaction"] == nil

      # Releasing/faking stale worker_done from old incarnation or attempt_id does nothing
      [{server_pid, _}] = Registry.lookup(registry, {:session, "s-abort"})
      {:ok, detail} = Daemon.get_session_detail("s-abort", opts)
      [comp_task] = Enum.filter(detail.tasks, &(&1.kind == "compaction"))
      assert comp_task.status == "terminal"
      assert comp_task.cancelled == true

      send(
        server_pid,
        {:worker_done, 999, String.to_integer(comp_task.id), 999,
         {:compaction_result,
          {:ok, %{summary: "Stale", kept_from_id: 3, instructions: nil, usage: %{}}}}}
      )

      refute Process.alive?(worker_pid)
      Process.sleep(30)

      {:ok, %{items: items}} = Daemon.scan_entries("s-abort", "1", %{"order" => "asc"}, opts)
      assert Enum.map(items, & &1.kind) == ["user", "assistant", "user", "assistant"]
    end
  end

  describe "worker crash recovery and real OS process SIGKILL restart" do
    test "retries after retryable provider error and commits single marker" do
      %{opts: opts, cwd: cwd} =
        start_daemon_env(
          [
            {:reply, [], %{content: [%{type: "text", text: "Reply 1"}]}},
            {:reply, [], %{content: [%{type: "text", text: String.duplicate("Reply 2 ", 15)}]}},
            {:error, %{code: "rate_limited", message: "slow down", retryable: true}},
            {:reply, [], %{content: [%{type: "text", text: "Recovered after retry"}]}}
          ],
          retry_limit: 2,
          retry_backoff_ms: 20
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-retry", "cwd" => cwd}, opts)
      seq = seed_two_turns("s-retry", opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-retry",
          cmd("cmp-retry", "compact", "1", %{"expected_seq" => seq}),
          opts
        )

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-retry", "1", %{"order" => "asc"}, opts)
          if length(items) == 5, do: items, else: nil
        end)

      assert List.last(items).kind == "compaction"
      assert List.last(items).data["summary"] == "Recovered after retry"
    end

    test "clean shutdown mid-compaction resumes on reopen and commits single marker" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd, data_dir: data_dir} =
        start_daemon_env(
          [
            {:reply, [], %{content: [%{type: "text", text: "Reply 1"}]}},
            {:reply, [], %{content: [%{type: "text", text: String.duplicate("Reply 2 ", 15)}]}},
            {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Unreached"}]}}
          ],
          storage_opts: [sync: :datasync]
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-clean", "cwd" => cwd}, opts)
      seq = seed_two_turns("s-clean", opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-clean",
          cmd("cmp-clean", "compact", "1", %{"expected_seq" => seq}),
          opts
        )

      assert_receive {:gate_entered, ^gate, _worker_pid}

      [{_, sup_pid, _, _}] = DynamicSupervisor.which_children(opts[:runtime_sup])
      :ok = DynamicSupervisor.terminate_child(opts[:runtime_sup], sup_pid)

      %{opts: opts2} =
        restart_daemon_env(
          data_dir,
          [
            {:reply, [], %{content: [%{type: "text", text: "Resumed after clean shutdown"}]}}
          ],
          storage_opts: [sync: :datasync]
        )

      assert :ok = Daemon.recover_active_sessions(opts2)

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-clean", "1", %{"order" => "asc"}, opts2)
          if length(items) == 5, do: items, else: nil
        end)

      assert List.last(items).kind == "compaction"
      assert List.last(items).data["summary"] == "Resumed after clean shutdown"
    end

    test "killed worker process recovers and commits single marker" do
      gate = make_ref()
      test_pid = self()

      %{opts: opts, cwd: cwd} =
        start_daemon_env(
          [
            {:reply, [], %{content: [%{type: "text", text: "Reply 1"}]}},
            {:reply, [], %{content: [%{type: "text", text: String.duplicate("Reply 2 ", 15)}]}},
            {:gate, [], test_pid, gate, %{content: [%{type: "text", text: "Never"}]}},
            {:reply, [], %{content: [%{type: "text", text: "Recovered after worker crash"}]}}
          ],
          retry_limit: 2,
          retry_backoff_ms: 20
        )

      {:ok, _} = Daemon.create_session(%{"session_id" => "s-wcrash", "cwd" => cwd}, opts)
      seq = seed_two_turns("s-wcrash", opts)

      {:ok, _} =
        Daemon.execute_command(
          "s-wcrash",
          cmd("cmp-wc", "compact", "1", %{"expected_seq" => seq}),
          opts
        )

      assert_receive {:gate_entered, ^gate, worker_pid}
      Process.exit(worker_pid, :kill)

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("s-wcrash", "1", %{"order" => "asc"}, opts)
          if length(items) == 5, do: items, else: nil
        end)

      assert List.last(items).kind == "compaction"
      assert List.last(items).data["summary"] == "Recovered after worker crash"
    end

    @tag timeout: 20_000
    test "SIGKILL of daemon OS process mid-compaction recovers and commits single marker without !! data" do
      id = System.unique_integer([:positive])
      tmp_root = Path.join(System.tmp_dir!(), "h-cmp-vm-#{id}")
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

      child_script = """
      Application.ensure_all_started(:logger)
      Application.ensure_all_started(:crypto)

      data_dir = System.fetch_env!("H_TEST_DATA_DIR")
      cwd = System.fetch_env!("H_TEST_CWD")

      {:ok, _} = H.StoreLock.start_link(data_dir: data_dir, name: H.StoreLock)
      {:ok, _} = Registry.start_link(keys: :unique, name: H.Registry)
      {:ok, _} = Registry.start_link(keys: :duplicate, name: H.PubSub)
      {:ok, _} = H.Catalog.start_link(data_dir: data_dir, name: H.Catalog, table: :h_catalog)
      {:ok, _} = H.WorkspaceLease.start_link(name: H.WorkspaceLease)
      {:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: H.Session.RuntimeSupervisor)

      parent = self()
      gate = make_ref()

      {:ok, fake} =
        H.Provider.Fake.start_link(
          script: [
            {:reply, [], %{content: [%{type: "text", text: "Turn 1 answer"}]}},
            {:gate, [], parent, gate, %{content: [%{type: "text", text: "Should not finish"}]}}
          ]
        )

      opts = [
        data_dir: data_dir,
        provider: H.Provider.Fake,
        provider_config: %{server: fake},
        storage_mod: H.Storage.File,
        storage_opts: [sync: :datasync],
        default_model: "fake:coder",
        compaction_keep_recent_chars: 100
      ]

      {:ok, _} = H.Daemon.create_session(%{"session_id" => "vm-cmp", "cwd" => cwd}, opts)

      {:ok, _} =
        H.Daemon.execute_command(
          "vm-cmp",
          %{
            "version" => 1,
            "request_id" => "vm-t1",
            "command" => "submit",
            "conversation_id" => "1",
            "args" => %{"type" => "input", "content" => "Turn 1 question"}
          },
          opts
        )

      wait_entries = fn wait_entries, count ->
        {:ok, %{items: items}} = H.Daemon.scan_entries("vm-cmp", "1", %{"order" => "asc"}, opts)

        if length(items) >= count do
          items
        else
          Process.sleep(10)
          wait_entries.(wait_entries, count)
        end
      end

      wait_entries.(wait_entries, 2)

      {:ok, {:snapshot, seq1, _}} =
        H.Daemon.subscribe_conversation("vm-cmp", "1", self(), nil, opts)

      {:ok, _} =
        H.Daemon.execute_command(
          "vm-cmp",
          %{
            "version" => 1,
            "request_id" => "vm-us-exc",
            "command" => "user_shell",
            "conversation_id" => "1",
            "args" => %{
              "command" => "echo TOP_SECRET_KEY",
              "include_in_context" => false,
              "expected_seq" => seq1
            }
          },
          opts
        )

      wait_entries.(wait_entries, 3)

      {:ok, _} =
        H.Daemon.execute_command(
          "vm-cmp",
          %{
            "version" => 1,
            "request_id" => "vm-t2",
            "command" => "submit",
            "conversation_id" => "1",
            "args" => %{
              "type" => "write",
              "kind" => "user",
              "content" => String.duplicate("Kept turn 2 ", 15)
            }
          },
          opts
        )

      wait_entries.(wait_entries, 4)

      {:ok, {:snapshot, seq2, _}} =
        H.Daemon.subscribe_conversation("vm-cmp", "1", self(), nil, opts)

      {:ok, _} =
        H.Daemon.execute_command(
          "vm-cmp",
          %{
            "version" => 1,
            "request_id" => "vm-cmp-req",
            "command" => "compact",
            "conversation_id" => "1",
            "args" => %{"expected_seq" => seq2, "instructions" => "Keep Turn 1 decision"}
          },
          opts
        )

      receive do
        {:gate_entered, ^gate, _worker_pid} -> :ok
      end

      IO.puts("READY:" <> System.pid() <> ":" <> Integer.to_string(seq2))

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
             {~c"H_TEST_CWD", String.to_charlist(cwd)}
           ]}
        ])

      {os_pid, cmp_seq_str} = await_ready_pid_and_seq(port)
      cmp_seq = String.to_integer(cmp_seq_str)

      on_exit(fn ->
        if Port.info(port) != nil, do: Port.close(port)
        System.cmd("kill", ["-9", os_pid], stderr_to_stdout: true)
      end)

      assert {:error, :store_locked} = StoreLock.start_link(data_dir: data_dir)

      # SIGKILL mid-compaction!
      {_out, 0} = System.cmd("kill", ["-9", os_pid])
      assert_receive {^port, {:exit_status, _status}}, 5_000

      # Boot fresh supervisor tree on same data_dir
      start_supervised!({StoreLock, data_dir: data_dir, name: :"H.CmpVmInt.Lock.#{id}"})

      %{opts: opts2, fake: fake2} =
        restart_daemon_env(
          data_dir,
          [
            {:expect,
             fn req ->
               [_, %{role: "user", content: [%{text: prompt}]}] = req.messages
               assert prompt =~ "Turn 1 question"
               assert prompt =~ "Turn 1 answer"
               assert prompt =~ "User instructions: Keep Turn 1 decision"
               refute prompt =~ "TOP_SECRET_KEY"
               true
             end,
             {:reply, [],
              %{content: [%{type: "text", text: "## Goal\nRecovered Turn 1 summary"}]}}},
            {:expect,
             fn req ->
               texts =
                 req.messages
                 |> Enum.flat_map(& &1.content)
                 |> Enum.map(&Map.get(&1, :text, ""))
                 |> Enum.join("\n")

               assert texts =~ "Recovered Turn 1 summary"
               assert texts =~ "Kept turn 2"
               assert texts =~ "Post-restart question"
               refute texts =~ "Turn 1 question"
               refute texts =~ "TOP_SECRET_KEY"
               true
             end, {:reply, [], %{content: [%{type: "text", text: "Post-restart reply"}]}}}
          ],
          storage_opts: [sync: :datasync],
          retry_backoff_ms: 20
        )

      assert :ok = Daemon.recover_active_sessions(opts2)

      items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("vm-cmp", "1", %{"order" => "asc"}, opts2)
          if length(items) == 5, do: items, else: nil
        end)

      assert Enum.map(items, & &1.kind) == [
               "user",
               "assistant",
               "user_shell",
               "user",
               "compaction"
             ]

      comp_entry = List.last(items)
      assert comp_entry.data["summary"] == "## Goal\nRecovered Turn 1 summary"
      assert comp_entry.data["instructions"] == "Keep Turn 1 decision"
      assert comp_entry.data["kept_from_id"] == String.to_integer(Enum.at(items, 3).id)

      # Idempotent retry of original compact request returns done without second compaction
      {:ok, retry_receipt} =
        Daemon.execute_command(
          "vm-cmp",
          cmd("vm-cmp-req", "compact", "1", %{
            "expected_seq" => cmp_seq,
            "instructions" => "Keep Turn 1 decision"
          }),
          opts2
        )

      assert retry_receipt.status == "done"

      # Wait a beat and confirm no second marker was committed
      Process.sleep(30)

      {:ok, %{items: stable_items}} =
        Daemon.scan_entries("vm-cmp", "1", %{"order" => "asc"}, opts2)

      assert length(stable_items) == 5

      # Subsequent turn works against compacted context
      {:ok, _} =
        Daemon.execute_command(
          "vm-cmp",
          cmd("post-restart", "submit", "1", %{
            "type" => "input",
            "content" => "Post-restart question"
          }),
          opts2
        )

      final_items =
        wait_until(fn ->
          {:ok, %{items: items}} = Daemon.scan_entries("vm-cmp", "1", %{"order" => "asc"}, opts2)
          if length(items) == 7, do: items, else: nil
        end)

      assert Enum.map(final_items, & &1.kind) == [
               "user",
               "assistant",
               "user_shell",
               "user",
               "compaction",
               "user",
               "assistant"
             ]

      assert length(Fake.requests(fake2)) == 2
    end
  end
end
