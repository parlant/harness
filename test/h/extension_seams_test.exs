defmodule H.ExtensionSeamsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias H.{Auth, Catalog, Daemon, ExecutionEnv, StoreLock}
  alias H.HTTP.Router
  alias H.Provider.Fake
  alias H.Session.Server

  defmodule PreparedHarness do
    @behaviour H.Harness

    @impl true
    def id, do: "prepared"

    @impl true
    def descriptor, do: %{id: "prepared", name: "Prepared", description: "Prepare & annotate"}

    @impl true
    def tools(_opts \\ []), do: [H.Tools.Read]

    @impl true
    def bootstrap_agent(_env, overrides \\ %{}, _opts \\ []), do: {:ok, overrides}

    @impl true
    def prepare_context(projection, opts) do
      cfg = :persistent_term.get({__MODULE__, :opts}, opts)

      if notify = Keyword.get(cfg, :test_pid) do
        send(notify, {:prepare_context_called, self(), projection.purpose, projection.session_id})
      end

      case Keyword.get(cfg, :prepare_mode, :ok) do
        :ok ->
          {:ok,
           %{
             prepend_system: "PREPENDED SYSTEM",
             append_system: "APPENDED SYSTEM",
             ephemeral_context: "EPHEMERAL CONTEXT"
           }}

        :error ->
          {:error, :policy_denied}

        :oversized ->
          {:ok, %{ephemeral_context: String.duplicate("x", 40_000)}}

        :sleep ->
          Process.sleep(500)
          {:ok, %{}}
      end
    end

    @impl true
    def project_response(response, scope) do
      case scope.finish_reason do
        "error_ann" ->
          raise "boom"

        "ignore_ann" ->
          :ignore

        "oversized_ann" ->
          {:ok, %{"huge" => String.duplicate("a", 5_000)}}

        _ ->
          {:ok,
           %{
             "summary" => "annotated",
             "model" => scope.model,
             "has_content" => is_list(response[:content]),
             "secret" => "sk-ant-secret1234567890"
           }}
      end
    end
  end

  defmodule FailingObserver do
    @behaviour H.Extension.Observer

    @impl true
    def command_committed(_event), do: raise("observer crash")

    @impl true
    def work_settled(_event), do: throw(:observer_throw)
  end

  defmodule RecordingObserver do
    @behaviour H.Extension.Observer

    def set_target(pid), do: :persistent_term.put({__MODULE__, :target}, pid)
    def clear_target, do: :persistent_term.erase({__MODULE__, :target})

    @impl true
    def command_committed(event) do
      if pid = :persistent_term.get({__MODULE__, :target}, nil) do
        send(pid, {:observer, :command_committed, event})
      end
    end

    @impl true
    def work_settled(event) do
      if pid = :persistent_term.get({__MODULE__, :target}, nil) do
        send(pid, {:observer, :work_settled, event})
      end
    end
  end

  defmodule FakeStatusProjection do
    @behaviour H.Extension.StatusProjection

    @impl true
    def project(%{model: "fake:coder"}) do
      {:ok, %{"state" => "ready", "eligible_sources" => 2, "secret" => "sk-test-abcdef123456"},
       3_210}
    end

    def project(_scope), do: :omit
  end

  defmodule ExplodingStatusProjection do
    @behaviour H.Extension.StatusProjection

    @impl true
    def project(_scope), do: raise("projection boom")
  end

  defmodule PolicyHostEnv do
    @behaviour H.ExecutionEnv

    def new(cwd, test_pid) do
      ExecutionEnv.new(__MODULE__, %{host: H.ExecutionEnv.Host.new(cwd), test_pid: test_pid})
    end

    @impl true
    def env_id(_), do: "policy-host"

    @impl true
    def kind(_), do: "host"

    @impl true
    def cwd(%{host: {_m, s}}), do: H.ExecutionEnv.Host.cwd(s)

    @impl true
    def resolve_path(%{host: {_m, s}}, path), do: H.ExecutionEnv.Host.resolve_path(s, path)

    @impl true
    def read_file_lines(%{host: {_m, s}}, path, opts),
      do: H.ExecutionEnv.Host.read_file_lines(s, path, opts)

    @impl true
    def read_file_bytes(%{host: {_m, s}}, path, opts),
      do: H.ExecutionEnv.Host.read_file_bytes(s, path, opts)

    @impl true
    def write_file(%{host: {_m, s}}, path, content),
      do: H.ExecutionEnv.Host.write_file(s, path, content)

    @impl true
    def list_dir(%{host: {_m, s}}, path, opts),
      do: H.ExecutionEnv.Host.list_dir(s, path, opts)

    @impl true
    def exec(%{host: {_m, s}}, cmd, opts), do: H.ExecutionEnv.Host.exec(s, cmd, opts)

    @impl true
    def admit_exec(_state, %{kind: :shell} = _plan), do: {:deny, :shell_disabled}

    def admit_exec(_state, %{kind: :argv} = _plan),
      do: {:allow, [timeout_ms: 500, spill_output: false]}

    @impl true
    def operation_finished(%{test_pid: pid}, telemetry) do
      send(pid, {:env_telemetry, telemetry})
    end
  end

  setup do
    id = System.unique_integer([:positive, :monotonic])
    tmp_dir = Path.join(System.tmp_dir!(), "h-ext-seams-#{id}")
    data_dir = Path.join(tmp_dir, "data")
    cwd = Path.join(tmp_dir, "work")
    Enum.each([data_dir, cwd], &File.mkdir_p!/1)

    on_exit(fn ->
      RecordingObserver.clear_target()
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, data_dir: data_dir, cwd: cwd, id: id}
  end

  describe "GET /api/v1/harnesses and GET /api/v1/sessions/:sid/conversations/:cid/extension-status" do
    test "lists harnesses and projects read-only extension status over HTTP", ctx do
      auth = :"H.ExtSeams.Auth.#{ctx.id}"
      auth_table = :"h_ext_seams_auth_#{ctx.id}"
      registry = :"h_ext_seams_reg_#{ctx.id}"
      pubsub = :"h_ext_seams_pub_#{ctx.id}"
      catalog = :"h_ext_seams_cat_#{ctx.id}"
      catalog_table = :"h_ext_seams_cat_tbl_#{ctx.id}"
      lease = :"h_ext_seams_lease_#{ctx.id}"
      rt_sup = :"h_ext_seams_rt_#{ctx.id}"

      start_supervised!({Auth, data_dir: ctx.data_dir, name: auth, table: auth_table})
      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({Registry, keys: :duplicate, name: pubsub})
      start_supervised!({H.WorkspaceLease, name: lease})
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: rt_sup})

      start_supervised!(
        {Catalog,
         name: catalog,
         table: catalog_table,
         registry: registry,
         pubsub: pubsub,
         data_dir: ctx.data_dir}
      )

      token = Auth.owner_token(auth_table)

      daemon_opts = [
        data_dir: ctx.data_dir,
        registry: registry,
        pubsub: pubsub,
        catalog: catalog,
        catalog_table: catalog_table,
        workspace_lease: lease,
        runtime_sup: rt_sup,
        provider: Fake,
        default_model: "fake:coder",
        harnesses: [PreparedHarness],
        status_projections: [
          %{namespace: "account_pool", module: FakeStatusProjection},
          %{namespace: "broken", module: ExplodingStatusProjection}
        ]
      ]

      router_opts = [
        port: 4000,
        auth_server: auth,
        auth_table: auth_table,
        daemon: Daemon,
        daemon_opts: daemon_opts
      ]

      # POST /api/v1/extensions/reload is removed
      reload_conn =
        conn(:post, "/api/v1/extensions/reload", "{}")
        |> then(&%{&1 | req_headers: [{"host", "127.0.0.1:4000"} | &1.req_headers]})
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init(router_opts))

      assert reload_conn.status == 404

      # GET /api/v1/harnesses requires auth and lists "coding" first + custom harnesses
      assert conn(:get, "/api/v1/harnesses")
             |> then(&%{&1 | req_headers: [{"host", "127.0.0.1:4000"} | &1.req_headers]})
             |> Router.call(Router.init(router_opts))
             |> Map.fetch!(:status) == 401

      harnesses_conn =
        conn(:get, "/api/v1/harnesses")
        |> then(&%{&1 | req_headers: [{"host", "127.0.0.1:4000"} | &1.req_headers]})
        |> put_req_header("authorization", "Bearer " <> token)
        |> Router.call(Router.init(router_opts))

      assert harnesses_conn.status == 200
      %{"harnesses" => harnesses} = JSON.decode!(harnesses_conn.resp_body)
      assert Enum.map(harnesses, & &1["id"]) == ["coding", "prepared"]
      assert Enum.find(harnesses, &(&1["id"] == "coding"))["aliases"] == ["pi"]

      assert {:ok, _} =
               Daemon.create_session(
                 %{"session_id" => "status-sess", "cwd" => ctx.cwd, "harness_id" => "prepared"},
                 daemon_opts
               )

      status_conn =
        conn(:get, "/api/v1/sessions/status-sess/conversations/1/extension-status")
        |> then(&%{&1 | req_headers: [{"host", "127.0.0.1:4000"} | &1.req_headers]})
        |> put_req_header("authorization", "Bearer " <> token)
        |> Router.call(Router.init(router_opts))

      assert status_conn.status == 200
      body = JSON.decode!(status_conn.resp_body)
      assert body["version"] == 1
      assert body["session_id"] == "status-sess"
      assert body["conversation_id"] == "1"
      assert body["model"] == "fake:coder"
      assert body["max_age_ms"] == 3_210

      assert body["extensions"] == %{
               "account_pool" => %{
                 "state" => "ready",
                 "eligible_sources" => 2,
                 "secret" => "[REDACTED]"
               }
             }

      # Unknown conversation -> 404
      missing_conv =
        conn(:get, "/api/v1/sessions/status-sess/conversations/99/extension-status")
        |> then(&%{&1 | req_headers: [{"host", "127.0.0.1:4000"} | &1.req_headers]})
        |> put_req_header("authorization", "Bearer " <> token)
        |> Router.call(Router.init(router_opts))

      assert missing_conv.status == 404
    end
  end

  describe "H.Harness prepare_context/2 and project_response/2" do
    test "runs prepare_context off single writer, persists sanitized harness_annotation, and omits invalid annotations",
         ctx do
      fake =
        start_supervised!(
          {Fake,
           script: [
             {:expect,
              fn req ->
                [sys | rest] = req.messages
                [sys_part] = sys.content
                assert sys_part.text =~ "PREPENDED SYSTEM"
                assert sys_part.text =~ "APPENDED SYSTEM"
                last = List.last(rest)
                assert last.role == "user"
                assert Enum.any?(last.content, &(&1.text == "EPHEMERAL CONTEXT"))
                true
              end,
              {:reply, [], %{content: [%{type: "text", text: "ok-1"}], finish_reason: "stop"}}},
             {:reply, [],
              %{content: [%{type: "text", text: "ok-2"}], finish_reason: "error_ann"}},
             {:reply, [],
              %{content: [%{type: "text", text: "ok-3"}], finish_reason: "ignore_ann"}},
             {:reply, [],
              %{content: [%{type: "text", text: "ok-4"}], finish_reason: "oversized_ann"}}
           ]}
        )

      {server, _rt_sup} = start_session_server(ctx, fake, prepare_mode: :ok)

      for {req_id, content} <- [
            {"r1", "hello 1"},
            {"r2", "hello 2"},
            {"r3", "hello 3"},
            {"r4", "hello 4"}
          ] do
        assert {:ok, _} = submit(server, req_id, content)

        assert_receive {:prepare_context_called, caller_pid, :generation, "sess-seams"}, 2_000
        # Must execute off the H.Session.Server single writer process
        assert caller_pid != server

        wait_until(fn ->
          {:ok, %{items: items}} = Server.scan_entries(server, 1, %{})

          Enum.any?(
            items,
            &(&1.kind == "assistant" and &1.data["content"] != nil and
                Enum.any?(&1.data["content"], fn b -> b["text"] == "ok-#{String.last(req_id)}" end))
          )
        end)
      end

      {:ok, %{items: items}} = Server.scan_entries(server, 1, %{order: :asc})
      assistants = Enum.filter(items, &(&1.kind == "assistant"))
      assert length(assistants) == 4

      [a1, a2, a3, a4] = assistants

      assert a1.data["harness_annotation"] == %{
               "summary" => "annotated",
               "model" => "fake:coder",
               "has_content" => true,
               "secret" => "[REDACTED]"
             }

      refute Map.has_key?(a2.data, "harness_annotation")
      refute Map.has_key?(a3.data, "harness_annotation")
      refute Map.has_key?(a4.data, "harness_annotation")
    end

    test "fails closed with context_preparation_failed on callback error, budget overflow, or timeout",
         ctx do
      for mode <- [:error, :oversized, :sleep] do
        fake = start_supervised!({Fake, script: []}, id: {Fake, mode})

        sub_dir = Path.join(ctx.tmp_dir, "fail-#{mode}")
        File.mkdir_p!(sub_dir)
        sub_ctx = %{ctx | data_dir: sub_dir, id: "#{ctx.id}-#{mode}"}

        {server, _rt_sup} =
          start_session_server(sub_ctx, fake,
            prepare_mode: mode,
            prepare_context_timeout_ms: 50
          )

        assert {:ok, _} = submit(server, "fail-#{mode}", "hi")

        wait_until(fn ->
          {:ok, outcome} = Server.get_submission_outcome(server, "fail-#{mode}")
          outcome.status == "unanswered"
        end)

        {:ok, detail} = Server.get_detail(server)
        conv = hd(detail.conversations)
        assert conv.id == 1

        {:ok, {:snapshot, _seq, json_bin}} = Server.snapshot_or_replay(server, 1, nil)
        snap = JSON.decode!(json_bin)
        assert snap["docs"]["live"]["run_failure"]["code"] == "context_preparation_failed"
        assert Fake.requests(fake) == []

        stop_supervised!({Fake, mode})
      end
    end
  end

  describe "H.Extensions.Observers post-commit dispatch" do
    test "dispatches command_committed and work_settled strictly after commit and isolates observer crashes",
         ctx do
      RecordingObserver.set_target(self())
      observers_name = :"H.ExtSeams.Observers.#{ctx.id}"

      start_supervised!(
        {H.Extensions.Observers,
         name: observers_name, observers: [FailingObserver, RecordingObserver]}
      )

      fake =
        start_supervised!(
          {Fake, script: [{:reply, [], %{content: [%{type: "text", text: "observed"}]}}]}
        )

      {server, _rt_sup} = start_session_server(ctx, fake, observers_server: observers_name)
      assert {:ok, _} = submit(server, "obs-1", "hi sk-ant-secret1234567890")

      assert_receive {:observer, :command_committed, cmd_ev}, 2_000
      assert cmd_ev.session_id == "sess-seams"
      assert cmd_ev.conversation_id == "1"
      assert cmd_ev.command == "submit"
      assert cmd_ev.seq > 0
      # Advisory payload contains no raw prompt text
      refute inspect(cmd_ev) =~ "secret1234567890"

      assert_receive {:observer, :work_settled, work_ev}, 2_000
      assert work_ev.session_id == "sess-seams"
      assert work_ev.task_kind == "generation"
      assert work_ev.outcome["status"] == "done"
      assert work_ev.seq > cmd_ev.seq
      assert Process.alive?(Process.whereis(observers_name))
    end
  end

  describe "H.ExecutionEnv admit_exec/2 and operation_finished/2" do
    test "denies shell exec, tightens argv exec opts, and emits bounded telemetry", ctx do
      env = PolicyHostEnv.new(ctx.cwd, self())

      assert {:error, {:exec_denied, :shell_disabled}} =
               ExecutionEnv.exec(env, {:shell, "echo hi"}, timeout_ms: 5_000)

      assert_receive {:env_telemetry,
                      %{env_id: "policy-host", kind: :exec, result_class: :denied}}

      assert {:ok, %{exit_code: 0, output: "ok\n"}} =
               ExecutionEnv.exec(env, {:argv, ["echo", "ok"]},
                 timeout_ms: 5_000,
                 spill_output: true
               )

      assert_receive {:env_telemetry, %{env_id: "policy-host", kind: :exec, result_class: :ok}}
    end
  end

  defp start_session_server(ctx, fake, extra_opts) do
    registry = :"h_ext_seams_srv_reg_#{ctx.id}_#{System.unique_integer([:positive])}"
    pubsub = :"h_ext_seams_srv_pub_#{ctx.id}_#{System.unique_integer([:positive])}"
    task_sup = :"h_ext_seams_srv_tsup_#{ctx.id}_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry}, id: {:reg, registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: {:pub, pubsub})
    start_supervised!({Task.Supervisor, name: task_sup}, id: {:tsup, task_sup})

    prepare_mode = Keyword.get(extra_opts, :prepare_mode, :ok)
    timeout_ms = Keyword.get(extra_opts, :prepare_context_timeout_ms, 5_000)

    opts =
      [
        session_id: "sess-seams",
        data_dir: ctx.data_dir,
        cwd: ctx.cwd,
        harness_id: "prepared",
        harnesses: [PreparedHarness],
        registry: registry,
        pubsub: pubsub,
        task_sup: task_sup,
        provider: Fake,
        provider_config: %{server: fake},
        default_model: "fake:coder",
        tools: PreparedHarness.tools(),
        prepare_context_timeout_ms: timeout_ms
      ] ++ Keyword.take(extra_opts, [:observers_server])

    :persistent_term.put({PreparedHarness, :opts},
      test_pid: self(),
      prepare_mode: prepare_mode,
      prepare_context_timeout_ms: timeout_ms
    )

    on_exit(fn -> :persistent_term.erase({PreparedHarness, :opts}) end)

    server = start_supervised!({Server, opts}, id: {:srv, task_sup})
    {server, task_sup}
  end

  defp submit(server, req_id, content) do
    Server.execute_command(server, %{
      command: "submit",
      conversation_id: 1,
      request_id: req_id,
      args: %{type: "input", content: content}
    })
  end

  defp wait_until(fun, tries \\ 100) do
    if fun.() or tries == 0 do
      assert fun.()
    else
      Process.sleep(15)
      wait_until(fun, tries - 1)
    end
  end
end
