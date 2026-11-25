defmodule HWeb.BackendHTTPTest do
  use ExUnit.Case, async: false

  alias H.{Accounts, Auth, Catalog, Daemon, StoreLock, WorkspaceLease}
  alias H.HTTP.{Router, UnixListener}
  alias H.Provider.Fake
  alias HWeb.Backend.{HTTP, InVM}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  setup do
    id = System.unique_integer([:positive, :monotonic])
    tmp_root = Path.join("/private/tmp", "hweb-http-#{id}")
    data_dir = Path.join(tmp_root, "data")
    projects_dir = Path.join(tmp_root, "projects")
    File.mkdir_p!(data_dir)
    File.mkdir_p!(projects_dir)

    registry = :"HWeb.HTTP.Reg.#{id}"
    pubsub = :"HWeb.HTTP.Pub.#{id}"
    catalog = :"HWeb.HTTP.Cat.#{id}"
    catalog_table = :"hweb_http_cat_#{id}"
    auth = :"HWeb.HTTP.Auth.#{id}"
    auth_table = :"hweb_http_auth_#{id}"
    lease = :"HWeb.HTTP.Lease.#{id}"
    runtime_sup = :"HWeb.HTTP.Sup.#{id}"
    fake_name = :"HWeb.HTTP.Fake.#{id}"
    sse_reg = :"HWeb.HTTP.SSEReg.#{id}"
    sse_sup = :"HWeb.HTTP.SSESup.#{id}"

    start_supervised!({StoreLock, data_dir: data_dir, name: :"HWeb.HTTP.Lock.#{id}"})
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Auth, data_dir: data_dir, name: auth, table: auth_table})

    start_supervised!(
      {Catalog,
       data_dir: data_dir, name: catalog, table: catalog_table, pubsub: pubsub, registry: registry}
    )

    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

    start_supervised!({Registry, keys: :unique, name: sse_reg})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sse_sup})

    fake =
      start_supervised!(
        {Fake,
         name: fake_name,
         script: [
           fn _req, emit ->
             emit.(%{type: :text_delta, text: "HTTP ", metadata: %{}})
             Process.sleep(25)
             emit.(%{type: :text_delta, text: "reply!", metadata: %{}})
             {:ok, %{content: [%{type: "text", text: "HTTP reply!"}], finish_reason: "stop"}}
           end
         ]}
      )

    accounts =
      start_supervised!(
        {Accounts,
         data_dir: data_dir,
         sources: ["work"],
         http: fn _ ->
           {:ok,
            %Req.Response{
              status: 200,
              body: %{
                "device_auth_id" => "dev-1",
                "user_code" => "ABCD-9999",
                "interval" => 5
              }
            }}
         end}
      )

    daemon_opts = [
      data_dir: data_dir,
      default_cwd: projects_dir,
      stop_dir: projects_dir,
      registry: registry,
      pubsub: pubsub,
      catalog: catalog,
      catalog_table: catalog_table,
      auth_server: auth,
      auth_table: auth_table,
      workspace_lease: lease,
      runtime_sup: runtime_sup,
      accounts: accounts,
      provider: Fake,
      provider_config: %{server: fake},
      storage_mod: H.Storage.File,
      storage_opts: [sync: :none],
      default_model: "fake:chat",
      ephemeral_interval_ms: 5
    ]

    router_opts = [
      auth_server: auth,
      auth_table: auth_table,
      daemon: Daemon,
      daemon_opts: daemon_opts,
      sse_keepalive_ms: 100
    ]

    bandit =
      start_supervised!(
        {Bandit,
         plug: {Router, router_opts},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [shutdown_timeout: 100]}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    daemon_url = "http://127.0.0.1:#{port}"

    sock_path = H.api_socket_path(data_dir)
    start_supervised!({UnixListener, {sock_path, router_opts}})

    prev_invm = Application.get_env(:harness_web, :daemon_opts)
    prev_http = Application.get_env(:harness_web, :http_backend)
    prev_backend = Application.get_env(:harness_web, :backend)
    Application.put_env(:harness_web, :daemon_opts, daemon_opts)

    on_exit(fn ->
      restore_env(:daemon_opts, prev_invm)
      restore_env(:http_backend, prev_http)
      restore_env(:backend, prev_backend)
      File.rm(sock_path)
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    token = Auth.owner_token(auth_table)

    http_opts = [
      daemon_url: daemon_url,
      token: token,
      sse_sup: sse_sup,
      sse_registry: sse_reg
    ]

    uds_opts = [
      data_dir: data_dir,
      unix_socket: sock_path,
      sse_sup: sse_sup,
      sse_registry: sse_reg
    ]

    {:ok,
     data_dir: data_dir,
     projects_dir: projects_dir,
     token: token,
     http_opts: http_opts,
     uds_opts: uds_opts,
     daemon_opts: daemon_opts,
     sse_reg: sse_reg}
  end

  defp restore_env(key, nil), do: Application.delete_env(:harness_web, key)
  defp restore_env(key, val), do: Application.put_env(:harness_web, key, val)

  test "redacts owner token in HTTP config and matches InVM shapes across HTTP & api.sock",
       ctx do
    {:ok, cfg} = HTTP.config(ctx.uds_opts)
    assert %H.Credentials.Redacted{} = cfg.token
    refute inspect(cfg) =~ ctx.token

    assert HTTP.list_environments(ctx.http_opts) == InVM.list_environments()
    assert HTTP.list_harnesses(ctx.http_opts) == InVM.list_harnesses()
    assert HTTP.list_models(ctx.http_opts) == InVM.list_models()

    # Compare browse_workspace, session creation, detail, tree, files, entries, extension status
    assert {:ok, invm_browse} = InVM.browse_workspace(%{"path" => ctx.projects_dir})

    assert {:ok, ^invm_browse} =
             HTTP.browse_workspace(%{"path" => ctx.projects_dir}, ctx.uds_opts)

    File.write!(Path.join(ctx.projects_dir, "hello.txt"), "hello world\n")
    File.write!(Path.join(ctx.projects_dir, "pixel.png"), <<137, 80, 78, 71, 13, 10, 26, 10>>)

    assert {:ok, %{session: session, seq: _}} =
             HTTP.create_session(
               %{"cwd" => ctx.projects_dir, "title" => "HTTP Sync"},
               ctx.http_opts
             )

    sid = session.session_id
    assert is_binary(sid)

    assert {:ok, [invm_session]} = InVM.list_sessions(%{"cwd" => ctx.projects_dir})

    assert {:ok, [^invm_session]} =
             HTTP.list_sessions(%{"cwd" => ctx.projects_dir}, ctx.http_opts)

    assert {:ok, invm_detail} = InVM.get_session_detail(sid)
    assert {:ok, ^invm_detail} = HTTP.get_session_detail(sid, ctx.http_opts)

    assert {:ok, invm_tree} = InVM.get_session_tree(sid)
    assert {:ok, ^invm_tree} = HTTP.get_session_tree(sid, ctx.http_opts)

    assert {:ok, invm_files} = InVM.list_files(%{"env_id" => "host", "cwd" => ctx.projects_dir})

    assert {:ok, ^invm_files} =
             HTTP.list_files(%{"env_id" => "host", "cwd" => ctx.projects_dir}, ctx.uds_opts)

    assert {:ok, invm_sfiles} = InVM.list_session_files(sid, %{})
    assert {:ok, ^invm_sfiles} = HTTP.list_session_files(sid, %{}, ctx.http_opts)

    assert {:ok, invm_ext} = InVM.get_extension_status(sid, "1")
    assert {:ok, ^invm_ext} = HTTP.get_extension_status(sid, "1", ctx.http_opts)

    # Browser auth exchange & verify
    assert {:error, :unauthorized} = HTTP.create_browser_session("wrong", ctx.http_opts)
    assert {:ok, cookie} = HTTP.create_browser_session(ctx.token, ctx.http_opts)
    assert HTTP.verify_browser_session(cookie, ctx.http_opts)
    refute HTTP.verify_browser_session("bad-cookie", ctx.http_opts)
  end

  test "supports review routes, media base64 roundtrip, and save conflict codes over HTTP", ctx do
    File.write!(Path.join(ctx.projects_dir, "notes.txt"), "before\n")
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>
    File.write!(Path.join(ctx.projects_dir, "img.png"), png)

    assert {:ok, %{session: review_sess}} =
             HTTP.open_workspace_review(%{"cwd" => ctx.projects_dir}, ctx.http_opts)

    sid = review_sess.session_id

    assert {:ok, invm_browse} =
             InVM.review_workspace(sid, %{dir: "", page: 0, changes?: true})

    assert {:ok, ^invm_browse} =
             HTTP.review_workspace(sid, %{dir: "", page: 0, changes?: true}, ctx.http_opts)

    assert {:ok, invm_text} = InVM.read_review_file(sid, "notes.txt", :working)
    assert {:ok, ^invm_text} = HTTP.read_review_file(sid, "notes.txt", :working, ctx.http_opts)

    assert {:ok, invm_media} = InVM.read_review_file(sid, "img.png", :working)
    assert {:ok, ^invm_media} = HTTP.read_review_file(sid, "img.png", :working, ctx.http_opts)

    assert {:ok, new_rev} =
             HTTP.save_review_file(sid, "notes.txt", invm_text.revision, "after\n", ctx.http_opts)

    assert is_binary(new_rev)

    assert {:error, :file_changed} =
             HTTP.save_review_file(sid, "notes.txt", invm_text.revision, "stale\n", ctx.http_opts)
  end

  test "supports accounts, API keys, provider catalog, commands, signals, and triage over HTTP",
       ctx do
    # API keys CRUD
    assert {:ok, _} =
             HTTP.put_api_key(
               %{"provider" => "openai", "source" => "primary", "api_key" => "sk-http-1"},
               ctx.http_opts
             )

    assert {:ok, _} =
             HTTP.put_api_key(
               %{"provider" => "openai", "source" => "backup", "api_key" => "sk-http-2"},
               ctx.http_opts
             )

    assert {:ok, %{active: "backup"}} =
             HTTP.use_api_key(%{"provider" => "openai", "source" => "backup"}, ctx.http_opts)

    assert {:ok, invm_keys} = InVM.api_keys()
    assert {:ok, ^invm_keys} = HTTP.api_keys(ctx.http_opts)

    assert {:ok, %{removed: "backup", active: "primary"}} =
             HTTP.remove_api_key(%{"provider" => "openai", "source" => "backup"}, ctx.http_opts)

    # Accounts add/discover/activate/remove & login flow
    assert {:ok, %{source: "personal"}} =
             HTTP.add_account(%{"source" => "personal"}, ctx.http_opts)

    assert {:ok, invm_disc} = InVM.discover_logins()
    assert {:ok, ^invm_disc} = HTTP.discover_logins(ctx.http_opts)

    assert {:ok, flow} =
             HTTP.start_login(
               %{
                 "provider" => "openai_codex",
                 "request_id" => "http-login-1",
                 "source" => "personal"
               },
               ctx.http_opts
             )

    assert {:ok, %{operation: op, state: "cancelled"}} =
             HTTP.login_operation(:cancel, %{"operation" => flow.operation}, ctx.http_opts)

    assert op == flow.operation

    assert {:ok, %{removed: "personal"}} =
             HTTP.remove_account(%{"source" => "personal"}, ctx.http_opts)

    # Provider catalog & staging
    assert {:ok, invm_cat} = InVM.provider_catalog()
    assert {:ok, ^invm_cat} = HTTP.provider_catalog(ctx.http_opts)

    models_json =
      JSON.encode!(%{
        "vendor/m1" => %{
          "name" => "M1",
          "context_window" => 32_000,
          "max_output_tokens" => 4_096,
          "supports_reasoning" => false,
          "supports_images" => false,
          "price_per_million_tokens" => %{
            "input" => 0,
            "output" => 0,
            "cache_read" => 0,
            "cache_write" => 0
          }
        }
      })

    assert :ok =
             HTTP.stage_provider(
               %{
                 "id" => "custom-http",
                 "name" => "Custom HTTP",
                 "base_url" => "https://custom.example.invalid/v1",
                 "models" => models_json,
                 "revision" => invm_cat.revision
               },
               ctx.http_opts
             )

    assert {:ok, %{pending?: true}} = HTTP.provider_catalog(ctx.http_opts)

    # Commands, triage, stop, archive, fork, deliver_signal
    assert {:ok, %{session: sess}} =
             HTTP.create_session(%{"cwd" => ctx.projects_dir}, ctx.http_opts)

    sid = sess.session_id

    assert {:ok, receipt} =
             HTTP.execute_command(
               sid,
               %{
                 "version" => 1,
                 "conversation_id" => 1,
                 "request_id" => "http-cmd-1",
                 "command" => "submit",
                 "args" => %{"type" => "write", "content" => "Hello HTTP"}
               },
               ctx.http_opts
             )

    assert receipt.status == "done"

    assert {:ok, sig_receipt} =
             HTTP.deliver_signal(
               sid,
               %{"request_id" => "sig-1", "topic" => "build", "payload" => %{"ok" => true}},
               ctx.http_opts
             )

    assert sig_receipt.topic == "build"

    assert {:ok, invm_entries} = InVM.scan_entries(sid, "1", %{"limit" => 10})
    assert {:ok, ^invm_entries} = HTTP.scan_entries(sid, "1", %{"limit" => 10}, ctx.http_opts)

    assert {:ok, %{session: triaged}} =
             HTTP.triage_session(sid, %{"needs_attention" => false}, ctx.http_opts)

    assert triaged.needs_attention == false

    assert {:ok, %{session: stopped}} = HTTP.stop_session(sid, %{}, ctx.http_opts)
    assert stopped.session_id == sid

    assert {:ok, %{session: forked}} =
             HTTP.fork_session(
               sid,
               %{"cwd" => ctx.projects_dir, "conversation_id" => "1"},
               ctx.http_opts
             )

    refute forked.session_id == sid

    assert {:ok, %{session: archived}} =
             HTTP.archive_session(sid, %{"archived" => true}, ctx.http_opts)

    assert archived.archived == true
  end

  test "SSE bridge streams catalog frames, conversation commits, and ephemeral deltas", ctx do
    assert {:ok, {:snapshot, cat_seq, cat_bin}} = HTTP.subscribe_sessions(self(), ctx.http_opts)
    assert is_integer(cat_seq)
    assert %{"sessions" => []} = JSON.decode!(cat_bin)

    assert {:ok, %{session: sess}} =
             HTTP.create_session(
               %{"cwd" => ctx.projects_dir, "title" => "SSE Demo"},
               ctx.http_opts
             )

    sid = sess.session_id
    assert_receive {:catalog_frame, _seq, frame_bin}, 2_000
    assert %{"type" => "upsert", "session" => %{"session_id" => ^sid}} = JSON.decode!(frame_bin)

    assert {:ok, {:snapshot, conv_seq, conv_bin}} =
             HTTP.subscribe_conversation(sid, "1", self(), nil, ctx.http_opts)

    assert is_integer(conv_seq)
    assert %{"session_id" => ^sid} = JSON.decode!(conv_bin)

    assert {:ok, _} =
             HTTP.execute_command(
               sid,
               %{
                 "version" => 1,
                 "conversation_id" => 1,
                 "request_id" => "sse-turn-1",
                 "command" => "submit",
                 "args" => %{"type" => "input", "content" => "Say hi"}
               },
               ctx.http_opts
             )

    assert_receive {:ephemeral_frame, eph_bin}, 2_000
    assert is_binary(eph_bin) and byte_size(eph_bin) > 0
    assert is_map(JSON.decode!(eph_bin))

    assert_receive {:commit_frame, commit_seq, commit_bin}, 2_000
    assert commit_seq > conv_seq
    assert JSON.decode!(commit_bin)["session_id"] == sid

    # Verify replay when re-subscribing with last_event_id
    assert :ok = HTTP.unsubscribe_conversation(sid, "1", ctx.http_opts)

    assert {:ok, {:replay, []}} =
             HTTP.subscribe_conversation(sid, "1", self(), commit_seq, ctx.http_opts)

    # Also verify replay when a new subscriber joins with an older seq
    assert {:ok, _} =
             HTTP.execute_command(
               sid,
               %{
                 "version" => 1,
                 "conversation_id" => 1,
                 "request_id" => "sse-turn-2",
                 "command" => "submit",
                 "args" => %{"type" => "write", "content" => "Note"}
               },
               ctx.http_opts
             )

    assert_receive {:commit_frame, commit_seq_2, _}, 2_000
    assert commit_seq_2 > commit_seq

    assert :ok = HTTP.unsubscribe_conversation(sid, "1", ctx.http_opts)
    assert :ok = HTTP.unsubscribe_sessions(ctx.http_opts)
  end
end
