defmodule Extensions.Analytics.LiveTest do
  use ExUnit.Case, async: false

  @endpoint HWeb.Endpoint

  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Extensions.Analytics
  alias Extensions.Analytics.Store
  alias H.{Archive, Auth, Catalog, Document, Storage, StoreLock, WorkspaceLease}
  alias H.Provider.Fake

  setup do
    id = System.unique_integer([:positive])
    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    tmp_root = Path.join(base, "h-analytics-live-test-#{id}")
    data_dir = Path.join(tmp_root, "data")
    projects_dir = Path.join(tmp_root, "projects")
    proj_alpha = Path.join(projects_dir, "alpha")
    proj_beta = Path.join(projects_dir, "beta")

    File.mkdir_p!(data_dir)
    File.mkdir_p!(proj_alpha)
    File.mkdir_p!(proj_beta)

    registry = :"Analytics.LiveTest.Reg.#{id}"
    pubsub = :"Analytics.LiveTest.Pub.#{id}"
    catalog = :"Analytics.LiveTest.Cat.#{id}"
    catalog_table = :"analytics_live_cat_#{id}"
    auth = :"Analytics.LiveTest.Auth.#{id}"
    auth_table = :"analytics_live_auth_#{id}"
    lease = :"Analytics.LiveTest.Lease.#{id}"
    runtime_sup = :"Analytics.LiveTest.Sup.#{id}"
    store_lock = :"Analytics.LiveTest.Lock.#{id}"
    fake_name = :"Analytics.LiveTest.Fake.#{id}"
    store_name = :"Analytics.LiveTest.Store.#{id}"
    store_table = :"analytics_live_store_#{id}"

    start_supervised!({StoreLock, data_dir: data_dir, name: store_lock})
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Auth, data_dir: data_dir, name: auth, table: auth_table})

    start_supervised!(
      {Catalog,
       data_dir: data_dir, name: catalog, table: catalog_table, pubsub: pubsub, registry: registry}
    )

    start_supervised!({WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})
    fake = start_supervised!({Fake, name: fake_name, script: []})

    now = System.system_time(:millisecond)
    recent_ts = now - 2 * 3_600_000
    old_ts = now - 20 * 86_400_000

    # 1) Native active session (recent, within 7d)
    seed_native_session(data_dir, catalog, "sess-active-1",
      title: "Active Alpha",
      cwd: proj_alpha,
      base_ts: recent_ts,
      archived: false
    )

    # 2) Native archived session (older, 20d ago - outside 7d window)
    seed_native_session(data_dir, catalog, "sess-arch-1",
      title: "Archived Alpha",
      cwd: proj_alpha,
      base_ts: old_ts,
      archived: true
    )

    # 3) Imported Pi archive (recent, within 7d)
    archive_sid =
      seed_pi_archive(data_dir, catalog, "pi-live-1", cwd: proj_beta, base_ts: recent_ts)

    # Start Store and perform synchronous sync
    store_pid =
      start_supervised!(
        {Store,
         data_dir: data_dir,
         name: store_name,
         table: store_table,
         catalog_table: catalog_table,
         sync_interval_ms: 0,
         auto_sync: false}
      )

    {:ok, _stats} = Store.sync_now(store_pid)

    ext_root = Path.expand("..", __DIR__)
    {:ok, contrib} = Analytics.configure(%{}, %{data_dir: data_dir})
    {:ok, web_ext} = H.Extensions.Web.validate(contrib.web, %{id: "analytics", path: ext_root})

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
      provider: Fake,
      provider_config: %{server: fake},
      storage_mod: H.Storage.File,
      storage_opts: [sync: :none],
      default_model: "fake:coder",
      ephemeral_interval_ms: 10,
      analytics_store: store_pid,
      web_extensions: [web_ext]
    ]

    prev_daemon_opts = Application.get_env(:harness_web, :daemon_opts)
    prev_backend = Application.get_env(:harness_web, :backend)
    prev_endpoint_cfg = Application.get_env(:harness_web, HWeb.Endpoint)

    Application.put_env(:harness_web, :backend, HWeb.Backend.InVM)
    Application.put_env(:harness_web, :daemon_opts, daemon_opts)

    Application.put_env(
      :harness_web,
      HWeb.Endpoint,
      Keyword.merge(prev_endpoint_cfg || [],
        url: [host: "localhost"],
        adapter: Bandit.PhoenixAdapter,
        http: [ip: {127, 0, 0, 1}, port: 4002],
        server: false,
        pubsub_server: HWeb.PubSub,
        check_origin: ["//127.0.0.1", "//localhost", "//[::1]"],
        live_view: [signing_salt: "hweb_lv_salt_9f2a4c"],
        secret_key_base:
          "test_only_secret_key_base_hweb_0123456789abcdef0123456789abcdef0123456789abcdef"
      )
    )

    start_supervised!({Phoenix.PubSub, name: HWeb.PubSub})
    start_supervised!(HWeb.Endpoint)

    on_exit(fn ->
      restore_env(:harness_web, :daemon_opts, prev_daemon_opts)
      restore_env(:harness_web, :backend, prev_backend)
      restore_env(:harness_web, HWeb.Endpoint, prev_endpoint_cfg)
      File.rm(StoreLock.socket_path(data_dir))
      File.rm_rf(tmp_root)
    end)

    %{
      conn: build_conn(),
      owner_token: Auth.owner_token(auth_table),
      proj_alpha: proj_alpha,
      proj_beta: proj_beta,
      archive_sid: archive_sid,
      store_pid: store_pid
    }
  end

  test "redirects unauthenticated /ext/analytics to /login", %{conn: conn} do
    resp_conn = get(conn, "/ext/analytics")
    assert redirected_to(resp_conn) == "/login"
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/ext/analytics")
  end

  test "renders analytics dashboard, Vega-Lite specs, KPIs, and static assets", %{
    conn: conn,
    owner_token: owner_token,
    archive_sid: archive_sid
  } do
    conn = log_in_owner(conn, owner_token)

    # Static assets + root.html.heex injection
    page_conn = get(conn, "/ext/analytics")
    html = html_response(page_conn, 200)
    assert html =~ ~s(<link rel="stylesheet" href="/ext-assets/analytics/analytics.css">)
    assert html =~ ~s(name="h-ext-scripts")
    assert html =~ "/ext-assets/analytics/analytics.js"

    css_conn = get(conn, "/ext-assets/analytics/analytics.css")
    assert css_conn.status == 200
    assert get_resp_header(css_conn, "x-content-type-options") == ["nosniff"]
    assert css_conn.resp_body =~ ".analytics-kpis"

    js_conn = get(conn, "/ext-assets/analytics/analytics.js")
    assert js_conn.status == 200
    assert get_resp_header(js_conn, "x-content-type-options") == ["nosniff"]
    assert js_conn.resp_body =~ "AnalyticsVegaChart"

    # LiveView mount & KPI verification across all 3 session classes
    {:ok, view, rendered} = live(conn, "/ext/analytics")

    assert has_element?(
             view,
             ~s(#app-menu a[href="/ext/analytics"][aria-current="page"]),
             "Analytics"
           )

    assert has_element?(view, "#analytics-index-badge", "Indexed 3 sessions")
    assert has_element?(view, "#analytics-kpis", "3")
    assert has_element?(view, "#analytics-kpis", "1 active · 1 archived · 1 imported")

    # Verify all 4 Vega-Lite chart hosts carry valid inline JSON specs
    for chart_id <- ~w(chart-daily-spend chart-model-speed chart-context-band chart-tool-volume) do
      assert has_element?(view, "##{chart_id}[phx-hook='AnalyticsVegaChart']")
      spec = extract_chart_spec!(rendered, chart_id)
      assert is_map(spec["data"])
      assert is_list(spec["data"]["values"])
      refute Map.has_key?(spec["data"], "url")
    end

    # Sessions table shows all 3 sessions + Open links
    assert has_element?(view, "#analytics-sessions-table", "Active Alpha")
    assert has_element?(view, "#analytics-sessions-table", "Archived Alpha")
    assert has_element?(view, "#analytics-sessions-table", archive_sid)
    assert has_element?(view, ~s(a[href="/sessions/sess-active-1"]), "Open →")

    # Sort sessions by cost
    view |> element(~s(button[phx-click="sort_sessions"][phx-value-col="cost"])) |> render_click()
    sort_path = assert_patch(view)
    assert_same_query(sort_path, "/ext/analytics?sort_by=cost")

    # Reset filters
    view |> element("#analytics-reset-filters-btn") |> render_click()
    assert_patch(view, "/ext/analytics")
    assert has_element?(view, "#analytics-kpis", "1 active · 1 archived · 1 imported")

    # Refresh button works
    view |> element("#analytics-refresh-btn") |> render_click()
    assert has_element?(view, "#analytics-index-badge", "Indexed 3 sessions")
  end

  test "supports filter push_patch across source, window, cache, and cwd", %{
    conn: conn,
    owner_token: owner_token,
    proj_beta: proj_beta,
    archive_sid: archive_sid
  } do
    conn = log_in_owner(conn, owner_token)
    {:ok, view, _html} = live(conn, "/ext/analytics")

    # Switch window to 7d (excludes 20d-old archived session, leaves 2 sessions)
    view |> element("#analytics-window-7d") |> render_click()
    assert_patch(view, "/ext/analytics?window=7d")
    assert has_element?(view, "#analytics-kpis", "1 active · 0 archived · 1 imported")

    # Filter source to imported_archive + cache=hit
    view
    |> element("#analytics-filter-form")
    |> render_change(%{"source" => "imported_archive", "cache" => "hit"})

    patched_path = assert_patch(view)
    assert_same_query(patched_path, "/ext/analytics?cache=hit&source=imported_archive&window=7d")
    assert has_element?(view, "#analytics-kpis", "0 active · 0 archived · 1 imported")
    assert has_element?(view, "#analytics-sessions-table", archive_sid)
    refute has_element?(view, "#analytics-sessions-table", "Active Alpha")

    # Filter by cwd
    view
    |> element("#analytics-filter-form")
    |> render_change(%{"cwd" => proj_beta})

    cwd_path = assert_patch(view)

    assert_same_query(
      cwd_path,
      "/ext/analytics?" <>
        URI.encode_query([
          {"cwd", proj_beta},
          {"cache", "hit"},
          {"source", "imported_archive"},
          {"window", "7d"}
        ])
    )

    # Reset filters
    view |> element("#analytics-reset-filters-btn") |> render_click()
    assert_patch(view, "/ext/analytics")
    assert has_element?(view, "#analytics-kpis", "1 active · 1 archived · 1 imported")
  end

  test "navigates Models, Tools, Workspaces, and Session Waterfall drill-downs", %{
    conn: conn,
    owner_token: owner_token,
    proj_beta: proj_beta
  } do
    conn = log_in_owner(conn, owner_token)

    # Models tab + model focus drill-down
    {:ok, models_view, _html} = live(conn, "/ext/analytics/models")
    assert has_element?(models_view, "#analytics-models-table", "claude-opus-5-5")
    assert has_element?(models_view, "#chart-models-tab[phx-hook='AnalyticsVegaChart']")

    models_view
    |> element(~s(#analytics-models-table tr[phx-value-model="claude-opus-5-5"]))
    |> render_click()

    assert_patch(models_view, "/ext/analytics/models?focus_model=claude-opus-5-5")
    assert has_element?(models_view, "#analytics-focused-model", "By Thinking Level")
    assert has_element?(models_view, "#analytics-focused-model", "high")

    # Tools tab + tool focus drill-down
    {:ok, tools_view, _html} = live(conn, "/ext/analytics/tools")
    assert has_element?(tools_view, "#analytics-tools-table", "edit")
    assert has_element?(tools_view, "#chart-tools-tab[phx-hook='AnalyticsVegaChart']")

    tools_view
    |> element(~s(#analytics-tools-table tr[phx-value-tool="edit"]))
    |> render_click()

    assert_patch(tools_view, "/ext/analytics/tools?focus_tool=edit")
    assert has_element?(tools_view, "#analytics-focused-tool", "Top Failing Sessions")
    assert has_element?(tools_view, "#analytics-focused-tool", "Active Alpha")

    # Workspaces tab + drill-down
    {:ok, ws_view, _html} = live(conn, "/ext/analytics/workspaces")
    assert has_element?(ws_view, "#analytics-workspaces-table", proj_beta)

    ws_view
    |> element(~s(button[phx-click="drill_workspace"][phx-value-cwd="#{proj_beta}"]))
    |> render_click()

    ws_drill_path = assert_patch(ws_view)

    assert_same_query(
      ws_drill_path,
      "/ext/analytics/workspaces?" <> URI.encode_query([{"cwd", proj_beta}])
    )

    assert has_element?(ws_view, "#analytics-focused-workspace", proj_beta)

    # Session waterfall drill-down
    {:ok, sess_view, sess_html} = live(conn, "/ext/analytics/sessions/sess-active-1")
    assert has_element?(sess_view, "#analytics-session-detail", "Active Alpha")
    assert has_element?(sess_view, ~s(a[href="/sessions/sess-active-1"]), "Open Session")
    assert has_element?(sess_view, "#chart-session-waterfall[phx-hook='AnalyticsVegaChart']")
    waterfall_spec = extract_chart_spec!(sess_html, "chart-session-waterfall")
    assert length(waterfall_spec["data"]["values"]) > 0
    assert has_element?(sess_view, "#analytics-waterfall-table", "bash")
    assert has_element?(sess_view, "#analytics-waterfall-table", "mismatch")
  end

  # Helpers

  defp assert_same_query(actual, expected) do
    actual_uri = URI.parse(actual)
    expected_uri = URI.parse(expected)
    assert actual_uri.path == expected_uri.path
    assert URI.decode_query(actual_uri.query || "") == URI.decode_query(expected_uri.query || "")
  end

  defp extract_chart_spec!(html, id) do
    html
    |> extract_data_spec_attr!(id)
    |> Jason.decode!()
  end

  defp extract_data_spec_attr!(html, id) do
    pattern = ~r/id="#{Regex.escape(id)}"[^>]*data-spec="([^"]+)"/

    case Regex.run(pattern, html) do
      [_, encoded] ->
        encoded
        |> String.replace("&quot;", "\"")
        |> String.replace("&amp;", "&")
        |> String.replace("&#39;", "'")
        |> String.replace("&lt;", "<")
        |> String.replace("&gt;", ">")

      _ ->
        flunk("Expected data-spec on ##{id}")
    end
  end

  defp log_in_owner(conn, owner_token) do
    login_conn = get(conn, "/login")
    [_, csrf] = Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, login_conn.resp_body)

    post(login_conn, "/login", %{"_csrf_token" => csrf, "token" => owner_token})
    |> recycle()
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, val), do: Application.put_env(app, key, val)

  defp seed_native_session(data_dir, catalog, sid, opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    base_ts = Keyword.fetch!(opts, :base_ts)
    title = Keyword.fetch!(opts, :title)
    archived = Keyword.get(opts, :archived, false)

    s_dir = Path.join([data_dir, "sessions", sid])
    File.mkdir_p!(s_dir)
    {:ok, store} = Storage.open(H.Storage.File, dir: s_dir, session_id: sid, cwd: cwd)

    agent =
      Document.initial("agent", default_model: "anthropic:claude-opus-5-5")
      |> Map.put("thinking", "high")

    batches = [
      [
        {:put_session_meta,
         %{session_id: sid, cwd: cwd, created_at: base_ts, updated_at: base_ts + 20_000}},
        {:put_doc, {:conversation, 1, "agent"}, Document.wrap("agent", agent)}
      ],
      [
        {:append_entry,
         %{
           id: 2,
           conversation_id: 1,
           kind: "user",
           data: %{"content" => [%{"type" => "text", "text" => "run checks"}]},
           created_at: base_ts + 1_000
         }},
        {:append_entry,
         %{
           id: 3,
           conversation_id: 1,
           kind: "assistant",
           data: %{
             "content" => [%{"type" => "text", "text" => "running bash"}],
             "tool_calls" => [%{"id" => "c1", "name" => "bash", "arguments" => %{}}],
             "finish_reason" => "tool_calls",
             "duration_ms" => 1_200,
             "usage" => %{
               "input_tokens" => 60_000,
               "cached_tokens" => 40_000,
               "output_tokens" => 600,
               "total_tokens" => 60_600,
               "total_cost" => 0.30
             }
           },
           created_at: base_ts + 2_200
         }},
        {:append_entry,
         %{
           id: 4,
           conversation_id: 1,
           kind: "tool_result",
           data: %{
             "tool_call_id" => "c1",
             "name" => "bash",
             "is_error" => false,
             "duration_ms" => 90
           },
           created_at: base_ts + 2_400
         }},
        {:append_entry,
         %{
           id: 5,
           conversation_id: 1,
           kind: "tool_result",
           data: %{
             "tool_call_id" => "c2",
             "name" => "edit",
             "is_error" => true,
             "duration_ms" => 350,
             "diagnostic" => "mismatch"
           },
           created_at: base_ts + 3_000
         }}
      ]
    ]

    {:ok, _res, store} = Storage.commit(store, batches)
    :ok = Storage.close(store)

    {:ok, _} =
      Catalog.put_session(catalog, %{
        session_id: sid,
        title: title,
        cwd: cwd,
        archived: archived,
        status: if(archived, do: "archived", else: "ok"),
        created_at: base_ts,
        updated_at: base_ts + 20_000
      })
  end

  defp seed_pi_archive(data_dir, catalog, source_id, opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    base_ts = Keyword.fetch!(opts, :base_ts)

    archives_dir = Path.join(data_dir, "archives")
    File.mkdir_p!(archives_dir)
    staged = Path.join(archives_dir, "staged-#{System.unique_integer([:positive])}.tmp")
    {:ok, fd} = :file.open(staged, [:raw, :binary, :write])

    {:ok, state} =
      Archive.stage(
        %{
          "source" => "pi",
          "source_id" => source_id,
          "cwd" => cwd,
          "created_at" => base_ts,
          "revision" => 1,
          "size" => 512
        },
        fd
      )

    {:ok, state} =
      Archive.append(state, %{
        "parent" => nil,
        "kind" => "user",
        "data" => %{"text" => "inspect repo"},
        "created_at" => base_ts + 1_000
      })

    {:ok, state} =
      Archive.append(state, %{
        "parent" => 2,
        "kind" => "assistant",
        "data" => %{
          "provider" => "openai-codex",
          "model" => "gpt-5.3-codex",
          "thinkingLevel" => "xhigh",
          "durationMs" => 2_000,
          "stopReason" => "stop",
          "usage" => %{
            "input" => 100_000,
            "output" => 800,
            "cacheRead" => 80_000,
            "cacheWrite" => 0,
            "totalTokens" => 180_800,
            "cost" => %{"total" => 0.45}
          }
        },
        "created_at" => base_ts + 3_000
      })

    {:ok, attrs} = Archive.finish(state, 2)
    :ok = :file.close(fd)
    {:ok, "created"} = Catalog.publish_archive(catalog, attrs, staged)
    attrs.session_id
  end
end
