defmodule H.CatalogInboxTest do
  use ExUnit.Case, async: true

  alias H.{Auth, Catalog, Daemon, StoreLock, WorkspaceLease}
  alias H.HTTP.Router
  alias H.Provider.Fake
  alias H.Session.Server.State

  defmodule GatedBashTool do
    @behaviour H.Tool

    @impl true
    def name, do: "bash"

    @impl true
    def description, do: "Gated bash tool for inbox transition tests"

    @impl true
    def parameters_schema do
      %{"type" => "object", "properties" => %{"command" => %{"type" => "string"}}}
    end

    @impl true
    def replay, do: :unsafe

    @impl true
    def mutating?, do: true

    @impl true
    def execute(_args, ctx) do
      if gate_pid = :persistent_term.get({__MODULE__, ctx.session_id}, nil) do
        ref = make_ref()
        send(gate_pid, {:tool_entered, ctx.session_id, self(), ref})

        receive do
          {:release_tool, ^ref} -> :ok
        after
          5_000 -> :ok
        end
      end

      {:ok, %{content: [%{type: "text", text: "bash done"}], details: %{}, is_error: false}}
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  defp start_daemon_stack(opts) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-catalog-inbox-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd_a = Path.join(tmp_root, "workspace-a")
    cwd_b = Path.join(tmp_root, "workspace-b")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(cwd_a)
    File.mkdir_p!(cwd_b)

    on_exit(fn ->
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    registry = :"H.InboxTest.Registry.#{id}"
    pubsub = :"H.InboxTest.PubSub.#{id}"
    catalog = :"H.InboxTest.Catalog.#{id}"
    catalog_table = :"h_inbox_test_catalog_#{id}"
    auth = :"H.InboxTest.Auth.#{id}"
    auth_table = :"h_inbox_test_auth_#{id}"
    lease = :"H.InboxTest.Lease.#{id}"
    runtime_sup = :"H.InboxTest.RuntimeSup.#{id}"
    fake_name = :"H.InboxTest.Fake.#{id}"

    start_supervised!({StoreLock, data_dir: data_dir, name: :"H.InboxTest.Lock.#{id}"})
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Auth, data_dir: data_dir, name: auth, table: auth_table})

    start_supervised!(
      {Catalog,
       data_dir: data_dir, name: catalog, table: catalog_table, pubsub: pubsub, registry: registry}
    )

    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

    fake =
      start_supervised!({Fake, name: fake_name, script: Keyword.get(opts, :script, [])})

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
        default_model: "fake:chat"
      ]
      |> Keyword.merge(Keyword.get(opts, :daemon_opts, []))

    router_opts =
      Keyword.merge(
        [
          auth_server: auth,
          auth_table: auth_table,
          daemon: Daemon,
          daemon_opts: daemon_opts,
          sse_keepalive_ms: 15_000
        ],
        Keyword.get(opts, :router_opts, [])
      )

    bandit =
      start_supervised!(
        {Bandit,
         plug: {Router, router_opts},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [num_acceptors: 2, shutdown_timeout: 100]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    token = Auth.owner_token(auth_table)

    %{
      id: id,
      data_dir: data_dir,
      cwd_a: cwd_a,
      cwd_b: cwd_b,
      registry: registry,
      pubsub: pubsub,
      catalog: catalog,
      catalog_table: catalog_table,
      daemon_opts: daemon_opts,
      base_url: "http://127.0.0.1:#{port}",
      headers: [{"authorization", "Bearer #{token}"}]
    }
  end

  defp cmd(req_id, command, cid, args) do
    %{
      "version" => 1,
      "request_id" => req_id,
      "conversation_id" => cid,
      "command" => command,
      "args" => args
    }
  end

  defp next_sse_event(resp, buffer \\ "", timeout \\ 3_000) do
    case :binary.split(buffer, "\n\n") do
      [raw_frame, rest] ->
        {:ok, parse_sse_frame(raw_frame), rest}

      [_incomplete] ->
        receive_sse_chunk(resp, buffer, timeout)
    end
  end

  defp receive_sse_chunk(%{body: %Req.Response.Async{ref: ref}} = resp, buffer, timeout) do
    receive do
      {^ref, _} = msg ->
        case Req.parse_message(resp, msg) do
          {:ok, [data: chunk]} ->
            next_sse_event(resp, buffer <> chunk, timeout)

          {:ok, [:done]} ->
            {:done, buffer}

          {:ok, [_other]} ->
            receive_sse_chunk(resp, buffer, timeout)

          {:error, reason} ->
            {:error, reason}
        end
    after
      timeout -> :timeout
    end
  end

  defp parse_sse_frame(raw_frame) do
    if String.starts_with?(raw_frame, ":") do
      %{raw: raw_frame, comment: true, id: nil, event: nil, data: nil}
    else
      parsed =
        raw_frame
        |> String.split("\n")
        |> Enum.reduce(%{id: nil, event: nil, data_lines: []}, fn line, acc ->
          cond do
            String.starts_with?(line, "id:") ->
              %{acc | id: line |> String.trim_leading("id:") |> String.trim_leading()}

            String.starts_with?(line, "event:") ->
              %{acc | event: line |> String.trim_leading("event:") |> String.trim_leading()}

            String.starts_with?(line, "data:") ->
              d = line |> String.trim_leading("data:") |> String.trim_leading()
              %{acc | data_lines: [d | acc.data_lines]}

            true ->
              acc
          end
        end)

      data_str = parsed.data_lines |> Enum.reverse() |> Enum.join("\n")

      %{
        raw: raw_frame,
        comment: false,
        id: parsed.id,
        event: parsed.event,
        data: JSON.decode!(data_str)
      }
    end
  end

  defp wait_for_catalog_event(resp, buf, pred, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_catalog_event(resp, buf, pred, deadline)
  end

  defp do_wait_for_catalog_event(resp, buf, pred, deadline) do
    remaining = max(1, deadline - System.monotonic_time(:millisecond))

    case next_sse_event(resp, buf, remaining) do
      {:ok, ev, next_buf} ->
        if pred.(ev) do
          {ev, next_buf}
        else
          do_wait_for_catalog_event(resp, next_buf, pred, deadline)
        end

      other ->
        flunk("expected matching SSE event before timeout, got: #{inspect(other)}")
    end
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

  describe "H.Session.Server.State.derive_catalog_runtime/1" do
    test "classifies running tool, user_shell, compaction, generation, sleeping, error, idle, and queued_count" do
      base = %{
        session_meta: %{title: "T"},
        tasks: %{},
        docs: %{1 => %{"live" => %{}, "inbox" => []}}
      }

      assert %{
               title: "T",
               active: false,
               attention: "idle",
               activity_kind: nil,
               activity_label: nil,
               queued_count: 0,
               next_wake_at: nil
             } == State.derive_catalog_runtime(base)

      # Running tool_call takes precedence over waiting generation
      tool_state = %{
        base
        | tasks: %{
            1 => %{id: 1, kind: "generation", status: "waiting", checkpoint: %{}},
            2 => %{id: 2, kind: "tool_call", status: "running", checkpoint: %{"name" => "bash"}}
          },
          docs: %{1 => %{"live" => %{}, "inbox" => [%{"submission_id" => "s1"}]}}
      }

      assert %{
               active: true,
               attention: "running",
               activity_kind: "tool",
               activity_label: "bash",
               queued_count: 1
             } = State.derive_catalog_runtime(tool_state)

      # user_shell
      shell_state = %{
        base
        | tasks: %{3 => %{id: 3, kind: "user_shell", status: "running", checkpoint: %{}}}
      }

      assert %{
               active: true,
               attention: "running",
               activity_kind: "user_shell",
               activity_label: "shell"
             } = State.derive_catalog_runtime(shell_state)

      # compaction
      compact_state = %{
        base
        | tasks: %{4 => %{id: 4, kind: "compaction", status: "running", checkpoint: %{}}}
      }

      assert %{
               active: true,
               attention: "running",
               activity_kind: "compaction",
               activity_label: "compact"
             } = State.derive_catalog_runtime(compact_state)

      # sleeping retry
      sleep_state = %{
        base
        | tasks: %{5 => %{id: 5, kind: "generation", status: "sleeping", checkpoint: %{}}}
      }

      assert %{
               active: true,
               attention: "retrying",
               activity_kind: "retry",
               activity_label: "retrying"
             } = State.derive_catalog_runtime(sleep_state)

      # idle with run_failure / compaction_failure -> error with sanitized label
      err_state = %{
        base
        | docs: %{
            1 => %{
              "live" => %{"run_failure" => %{"reason" => "model_error\n\x07boom"}},
              "inbox" => []
            }
          }
      }

      assert %{
               active: false,
               attention: "error",
               activity_kind: nil,
               activity_label: "model_error boom"
             } = State.derive_catalog_runtime(err_state)

      comp_err_state = %{
        base
        | docs: %{
            1 => %{
              "live" => %{"compaction_failure" => %{"code" => "compaction_failed"}},
              "inbox" => []
            }
          }
      }

      assert %{
               active: false,
               attention: "error",
               activity_kind: nil,
               activity_label: "compaction_failed"
             } = State.derive_catalog_runtime(comp_err_state)
    end
  end

  describe "H.Catalog attention persistence, validation, and backward compatibility" do
    test "persists attention, activity_kind, activity_label, queued_count across restart and loads legacy sessions.json" do
      id = System.unique_integer([:positive])
      tmp_dir = Path.join(System.tmp_dir!(), "h-cat-inbox-persist-#{id}")
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      catalog_dir = Path.join(tmp_dir, "catalog")
      File.mkdir_p!(catalog_dir)

      # Legacy sessions.json without attention/activity/queued_count fields
      legacy =
        JSON.encode!(%{
          "version" => 1,
          "sessions" => [
            %{
              "session_id" => "legacy-ok",
              "cwd" => "/tmp/legacy-ok",
              "created_at" => 10,
              "updated_at" => 20,
              "active" => false,
              "status" => "ok"
            },
            %{
              "session_id" => "legacy-q",
              "cwd" => "/tmp/legacy-q",
              "created_at" => 10,
              "updated_at" => 25,
              "active" => false,
              "status" => "quarantined"
            }
          ]
        })

      File.write!(Path.join(catalog_dir, "sessions.json"), legacy)

      pubsub = :"H.CatPersist.PubSub.#{id}"
      table1 = :"h_cat_persist_1_#{id}"
      srv1 = :"H.CatPersist.1.#{id}"
      start_supervised!({Registry, keys: :duplicate, name: pubsub})
      start_supervised!({Catalog, data_dir: tmp_dir, name: srv1, table: table1, pubsub: pubsub})

      assert {:ok, legacy_ok} = Catalog.get_session("legacy-ok", table1)
      assert legacy_ok.attention == "idle"
      assert legacy_ok.activity_kind == nil
      assert legacy_ok.activity_label == nil
      assert legacy_ok.queued_count == 0

      assert {:ok, legacy_q} = Catalog.get_session("legacy-q", table1)
      assert legacy_q.attention == "quarantined"

      # Update with attention + sanitized label + queued_count, ignoring invalid untrusted values
      long_label = "model_error:\n\t\x00" <> String.duplicate("x", 200)

      assert {:ok, updated} =
               Catalog.report_runtime(srv1, "legacy-ok", %{
                 "attention" => "error",
                 "activity_kind" => "not_an_atom_attack",
                 "activity_label" => long_label,
                 "queued_count" => 3
               })

      assert updated.attention == "error"
      assert updated.activity_kind == nil
      assert String.length(updated.activity_label) == 120
      refute Regex.match?(~r/[\x00-\x1F\x7F]/u, updated.activity_label)
      assert updated.queued_count == 3

      # No-op report_runtime does not advance seq or broadcast
      Registry.register(pubsub, :catalog, nil)
      seq_before = Catalog.snapshot(srv1).seq

      assert {:ok, ^updated} =
               Catalog.report_runtime(srv1, "legacy-ok", %{
                 attention: "error",
                 activity_kind: nil,
                 activity_label: updated.activity_label,
                 queued_count: 3,
                 updated_at: updated.updated_at + 9_999
               })

      assert Catalog.snapshot(srv1).seq == seq_before
      refute_receive {:catalog_frame, _, _}, 50

      # Quarantined session keeps attention == "quarantined" even if report_runtime tries to set "idle"
      assert {:ok, still_q} =
               Catalog.report_runtime(srv1, "legacy-q", %{attention: "idle", active: false})

      assert still_q.attention == "quarantined"

      # Restart catalog and verify attention + activity_label + queued_count persisted
      stop_supervised!(Catalog)
      table2 = :"h_cat_persist_2_#{id}"
      srv2 = :"H.CatPersist.2.#{id}"
      start_supervised!({Catalog, data_dir: tmp_dir, name: srv2, table: table2, pubsub: pubsub})

      assert {:ok, reloaded} = Catalog.get_session("legacy-ok", table2)
      assert reloaded.attention == "error"
      assert reloaded.activity_label == updated.activity_label
      assert reloaded.queued_count == 3
    end
  end

  describe "live session attention transitions and GET /api/v1/sessions/events" do
    test "tracks idle -> running (generation) -> running (tool: bash) -> idle, error (model_error), quarantined, and streams multi-cwd SSE without waking unloaded sessions" do
      gen_gate = make_ref()
      test_pid = self()

      ctx =
        start_daemon_stack(
          script: [
            # Session A Turn 1: gated generation -> calls bash tool
            {:gate, [], test_pid, gen_gate,
             %{
               content: [],
               tool_calls: [%{id: "tc_1", name: "bash", arguments: %{"command" => "echo hi"}}],
               finish_reason: "tool_calls"
             }},
            # Session A Turn 2: final answer
            {:reply, [], %{content: [%{type: "text", text: "all done"}], finish_reason: "stop"}},
            # Session B Turn 1: non-retryable model_error
            {:error, %{code: "bad_request", message: "boom", retryable: false}}
          ],
          daemon_opts: [tools: [GatedBashTool]]
        )

      :persistent_term.put({GatedBashTool, "sess-a"}, test_pid)
      on_exit(fn -> :persistent_term.erase({GatedBashTool, "sess-a"}) end)

      # Seed an unloaded session directly in catalog (no Session.Server started!)
      {:ok, _} =
        Catalog.put_session(ctx.catalog, %{
          session_id: "unloaded-dormant",
          cwd: ctx.cwd_b,
          title: "Dormant"
        })

      assert [] == Registry.lookup(ctx.registry, {:session, "unloaded-dormant"})

      # 1. GET /api/v1/sessions/events requires auth
      unauth = Req.get!("#{ctx.base_url}/api/v1/sessions/events", retry: false)
      assert unauth.status == 401

      # 2. Subscribe to GET /api/v1/sessions/events
      sse =
        Req.get!("#{ctx.base_url}/api/v1/sessions/events",
          headers: ctx.headers,
          into: :self,
          retry: false
        )

      assert sse.status == 200
      assert Req.Response.get_header(sse, "content-type") == ["text/event-stream; charset=utf-8"]

      {:ok, snap, buf} = next_sse_event(sse)
      assert snap.event == "snapshot"
      assert snap.data["version"] == 1
      assert is_integer(snap.data["seq"])
      assert [dormant] = snap.data["sessions"]
      assert dormant["session_id"] == "unloaded-dormant"
      assert dormant["attention"] == "idle"
      assert dormant["activity_kind"] == nil
      assert dormant["activity_label"] == nil
      assert dormant["queued_count"] == 0

      # Snapshot and GET /api/v1/sessions must NOT wake unloaded sessions
      list_resp = Req.get!("#{ctx.base_url}/api/v1/sessions", headers: ctx.headers)
      assert list_resp.status == 200

      assert [%{"session_id" => "unloaded-dormant", "attention" => "idle"}] =
               list_resp.body["sessions"]

      assert [] == Registry.lookup(ctx.registry, {:session, "unloaded-dormant"})

      # 3. Create Session A in workspace A -> upsert SSE frame with attention: "idle"
      assert {:ok, _} =
               Daemon.create_session(
                 %{"session_id" => "sess-a", "cwd" => ctx.cwd_a},
                 ctx.daemon_opts
               )

      {ev_create_a, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "sess-a"
        end)

      assert ev_create_a.data["session"]["cwd"] == Path.expand(ctx.cwd_a)
      assert ev_create_a.data["session"]["attention"] == "idle"

      # 4. Submit prompt on Session A -> transitions to running/generation
      assert {:ok, _} =
               Daemon.execute_command(
                 "sess-a",
                 cmd("a-1", "submit", "1", %{"type" => "input", "content" => "Run bash"}),
                 ctx.daemon_opts
               )

      assert_receive {:gate_entered, ^gen_gate, gen_worker}, 2_000

      {ev_gen, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "sess-a" and
            ev.data["session"]["attention"] == "running" and
            ev.data["session"]["activity_kind"] == "generation"
        end)

      assert ev_gen.data["session"]["active"] == true
      assert ev_gen.data["session"]["activity_label"] == nil

      # Queue a follow-up item while running -> queued_count increments
      assert {:ok, _} =
               Daemon.execute_command(
                 "sess-a",
                 cmd("a-q", "submit", "1", %{"type" => "input", "content" => "Queued item"}),
                 ctx.daemon_opts
               )

      {ev_queued, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "sess-a" and
            ev.data["session"]["queued_count"] == 1
        end)

      assert ev_queued.data["session"]["queued_count"] == 1

      # Withdraw queued item so sess-a finishes cleanly after bash
      {:ok, {:snapshot, _, conv_snap_bin}} =
        Daemon.subscribe_conversation("sess-a", "1", self(), nil, ctx.daemon_opts)

      [queued_item] = JSON.decode!(conv_snap_bin)["docs"]["inbox"]

      assert {:ok, _} =
               Daemon.execute_command(
                 "sess-a",
                 cmd("a-w", "withdraw", "1", %{"submission_ids" => [queued_item["submission_id"]]}),
                 ctx.daemon_opts
               )

      # Release generation -> transitions to running / tool / "bash"
      send(gen_worker, {:release, gen_gate})
      assert_receive {:tool_entered, "sess-a", tool_pid, tool_ref}, 2_000

      {ev_tool, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "sess-a" and
            ev.data["session"]["attention"] == "running" and
            ev.data["session"]["activity_kind"] == "tool" and
            ev.data["session"]["activity_label"] == "bash"
        end)

      assert ev_tool.data["session"]["queued_count"] == 0

      # Release bash tool -> finishes turn 2 -> settles back to idle
      send(tool_pid, {:release_tool, tool_ref})

      {ev_idle, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "sess-a" and
            ev.data["session"]["attention"] == "idle" and
            ev.data["session"]["active"] == false
        end)

      assert ev_idle.data["session"]["activity_kind"] == nil
      assert ev_idle.data["session"]["activity_label"] == nil

      # Rename Session A -> emits catalog upsert with updated title
      assert {:ok, _} =
               Daemon.execute_command(
                 "sess-a",
                 cmd("a-ren", "rename", "1", %{"title" => "Alpha Renamed"}),
                 ctx.daemon_opts
               )

      {ev_ren, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "sess-a" and
            ev.data["session"]["title"] == "Alpha Renamed"
        end)

      assert ev_ren.data["session"]["title"] == "Alpha Renamed"

      # 5. Provider failures expose their specific code in the catalog label.
      assert {:ok, _} =
               Daemon.create_session(
                 %{"session_id" => "sess-b", "cwd" => ctx.cwd_b},
                 ctx.daemon_opts
               )

      assert {:ok, _} =
               Daemon.execute_command(
                 "sess-b",
                 cmd("b-1", "submit", "1", %{"type" => "input", "content" => "Trigger error"}),
                 ctx.daemon_opts
               )

      {ev_err, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "sess-b" and
            ev.data["session"]["attention"] == "error"
        end)

      assert ev_err.data["session"]["cwd"] == Path.expand(ctx.cwd_b)
      assert ev_err.data["session"]["active"] == false
      assert ev_err.data["session"]["activity_kind"] == nil
      assert ev_err.data["session"]["activity_label"] == "bad_request"

      # 6. Quarantine dormant session -> attention: "quarantined"
      assert {:ok, _} = Catalog.quarantine(ctx.catalog, "unloaded-dormant", :corrupt_wal)

      {ev_q, buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "upsert" and
            ev.data["session"]["session_id"] == "unloaded-dormant" and
            ev.data["session"]["attention"] == "quarantined"
        end)

      assert ev_q.data["session"]["status"] == "quarantined"
      assert ev_q.data["session"]["activity_label"] == "corrupt_wal"

      # 7. Delete dormant session -> emits catalog removed frame
      assert :ok = Catalog.delete_session(ctx.catalog, "unloaded-dormant")

      {ev_rm, _buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event == "catalog" and ev.data["type"] == "removed" and
            ev.data["session_id"] == "unloaded-dormant"
        end)

      assert ev_rm.data["session_id"] == "unloaded-dormant"

      # Final GET /api/v1/sessions reflects exact attention summaries across both workspaces
      sessions =
        Req.get!("#{ctx.base_url}/api/v1/sessions", headers: ctx.headers).body["sessions"]
        |> Map.new(&{&1["session_id"], &1})

      assert sessions["sess-a"]["attention"] == "idle"
      assert sessions["sess-a"]["title"] == "Alpha Renamed"
      assert sessions["sess-b"]["attention"] == "error"
      assert sessions["sess-b"]["activity_label"] == "bad_request"
      refute Map.has_key?(sessions, "unloaded-dormant")

      Req.cancel_async_response(sse)
    end

    test "emits keepalive and resnapshots cleanly on mailbox overflow for /api/v1/sessions/events" do
      ctx =
        start_daemon_stack(router_opts: [sse_keepalive_ms: 40, sse_max_queue_len: 3])

      sse =
        Req.get!("#{ctx.base_url}/api/v1/sessions/events",
          headers: ctx.headers,
          into: :self,
          retry: false
        )

      {:ok, snap1, buf} = next_sse_event(sse)
      assert snap1.event == "snapshot"

      {:ok, ka, buf} = next_sse_event(sse, buf, 1_000)
      assert ka.comment
      assert ka.raw == ": keepalive"

      # Burst updates into Catalog to verify seq monotonicity and clean delivery/resnapshot
      for i <- 1..15 do
        {:ok, _} =
          Catalog.put_session(ctx.catalog, %{
            session_id: "burst-#{i}",
            cwd: ctx.cwd_a,
            title: "Burst #{i}"
          })
      end

      wait_until(fn ->
        length(Catalog.list_sessions(ctx.catalog_table)) == 15
      end)

      # Receive at least one subsequent event carrying seq > snap1 seq
      {ev, _buf} =
        wait_for_catalog_event(sse, buf, fn ev ->
          ev.event in ["catalog", "snapshot"] and String.to_integer(ev.id) > snap1.data["seq"]
        end)

      assert String.to_integer(ev.id) > snap1.data["seq"]

      Req.cancel_async_response(sse)
    end
  end
end
