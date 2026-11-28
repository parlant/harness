defmodule HWeb.ExtensionLiveTest do
  use HWeb.ConnCase, async: false

  alias H.Daemon

  defmodule DemoPage do
    use Phoenix.Component
    use HWeb, :verified_routes

    @behaviour HWeb.Extension.Page

    @impl true
    def mount(_params, _session, socket) do
      {:ok, Phoenix.Component.assign(socket, count: 0)}
    end

    @impl true
    def handle_params(params, _uri, socket) do
      {:noreply, Phoenix.Component.assign(socket, subpath: Map.get(params, "subpath", []))}
    end

    @impl true
    def handle_event("increment", _params, socket) do
      {:noreply, Phoenix.Component.update(socket, :count, &(&1 + 1))}
    end

    def handle_event("drill_down", _params, socket) do
      {:noreply, Phoenix.LiveView.push_patch(socket, to: "/ext/demo/drill/down")}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <HWeb.Extension.shell title="Demo Extension" section={@ext_section}>
        <section id="demo-ext-page">
          <p id="demo-count">Count: {@count}</p>
          <p id="demo-subpath">Subpath: {Enum.join(@subpath, "/")}</p>
          <button id="demo-inc-btn" type="button" phx-click="increment">Increment</button>
          <button id="demo-drill-btn" type="button" phx-click="drill_down">Drill down</button>
        </section>
      </HWeb.Extension.shell>
      """
    end

    def sidebar_before_conv(assigns) do
      ~H"""
      <div class="sidebar-section" data-sidebar-marker="ext-before-conv">
        Before Conversations ({@sidebar.session_id})
      </div>
      """
    end

    def sidebar_after_agent(assigns) do
      ~H"""
      <div class="sidebar-section" data-sidebar-marker="ext-after-agent">
        After Agent ({@sidebar.conversation_id})
      </div>
      """
    end

    def sidebar_top(assigns) do
      ~H"""
      <div class="sidebar-section" data-sidebar-marker="ext-top">
        Top Panel
      </div>
      """
    end
  end

  setup ctx do
    static_dir = Path.join(ctx.tmp_root, "ext_static")
    File.mkdir_p!(Path.join(static_dir, "nested"))
    File.write!(Path.join(static_dir, "ext.css"), ".ext-demo { color: green; }\n")
    File.write!(Path.join([static_dir, "nested", "hook.mjs"]), "export const hooks = {};\n")
    File.write!(Path.join(ctx.tmp_root, "outside.css"), "body {}\n")
    File.ln_s!(Path.join(ctx.tmp_root, "outside.css"), Path.join(static_dir, "linked.css"))

    web_extensions = [
      %{
        ext_id: "demo.ext",
        static_dir: static_dir,
        pages: [
          %{ext_id: "demo.ext", slug: "demo", path: "/ext/demo", module: DemoPage, title: "Demo"}
        ],
        nav_items: [
          %{
            ext_id: "demo.ext",
            id: "demo-nav",
            label: "Demo Ext",
            path: "/ext/demo",
            section: {:ext, "demo"},
            order: 10
          }
        ],
        session_sidebar: [
          %{
            ext_id: "demo.ext",
            id: "panel-top",
            position: :top,
            module: DemoPage,
            function: :sidebar_top,
            order: 10
          },
          %{
            ext_id: "demo.ext",
            id: "panel-after-agent",
            position: {:after, "session-agent"},
            module: DemoPage,
            function: :sidebar_after_agent,
            order: 10
          },
          %{
            ext_id: "demo.ext",
            id: "panel-before-conv",
            position: {:before, "session-conversations"},
            module: DemoPage,
            function: :sidebar_before_conv,
            order: 10
          }
        ],
        stylesheets: [
          %{ext_id: "demo.ext", file: "ext.css", href: "/ext-assets/demo.ext/ext.css"}
        ],
        scripts: [
          %{
            ext_id: "demo.ext",
            file: "nested/hook.mjs",
            src: "/ext-assets/demo.ext/nested/hook.mjs"
          }
        ]
      }
    ]

    prev_daemon_opts = Application.get_env(:harness_web, :daemon_opts)

    Application.put_env(
      :harness_web,
      :daemon_opts,
      Keyword.put(ctx.daemon_opts, :web_extensions, web_extensions)
    )

    on_exit(fn ->
      Application.put_env(:harness_web, :daemon_opts, prev_daemon_opts)
    end)

    {:ok, static_dir: static_dir, web_extensions: web_extensions}
  end

  test "redirects unauthenticated requests on /ext/:slug and /ext/:slug/*subpath to /login", %{
    conn: conn
  } do
    for path <- ["/ext/demo", "/ext/demo/drill/down", "/ext/unknown"] do
      resp_conn = get(conn, path)
      assert redirected_to(resp_conn) == "/login"
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, path)
    end
  end

  test "mounts extension page, injects nav item, handles events and subpath push_patch, and renders assets",
       %{conn: conn, owner_token: owner_token} do
    conn = log_in_owner(conn, owner_token)

    page_conn = get(conn, "/ext/demo")
    assert html_response(page_conn, 200) =~ ~s(href="/ext-assets/demo.ext/ext.css")
    assert page_conn.resp_body =~ ~s(name="h-ext-scripts")
    assert page_conn.resp_body =~ "/ext-assets/demo.ext/nested/hook.mjs"

    {:ok, view, _html} = live(conn, "/ext/demo")
    assert has_element?(view, ~s(#app-menu a[href="/ext/demo"][aria-current="page"]), "Demo Ext")
    assert has_element?(view, "#demo-count", "Count: 0")
    assert has_element?(view, "#demo-subpath", "Subpath:")

    view |> element("#demo-inc-btn") |> render_click()
    assert has_element?(view, "#demo-count", "Count: 1")

    view |> element("#demo-drill-btn") |> render_click()
    assert_patch(view, "/ext/demo/drill/down")
    assert has_element?(view, "#demo-subpath", "Subpath: drill/down")

    {:ok, deep_view, _html} = live(conn, "/ext/demo/a/b")
    assert has_element?(deep_view, "#demo-subpath", "Subpath: a/b")

    {:ok, missing_view, _html} = live(conn, "/ext/missing")
    assert has_element?(missing_view, "h2", "Extension not found")
    assert has_element?(missing_view, ~s(a[href="/inbox"]), "Back to Inbox")
  end

  test "serves /ext-assets/:ext_id/* with security headers and 404s on traversal or symlinks", %{
    conn: conn
  } do
    css_conn = get(conn, "/ext-assets/demo.ext/ext.css")
    assert css_conn.status == 200
    assert get_resp_header(css_conn, "content-type") == ["text/css; charset=utf-8"]
    assert get_resp_header(css_conn, "x-content-type-options") == ["nosniff"]
    assert css_conn.resp_body =~ ".ext-demo"

    js_conn = get(conn, "/ext-assets/demo.ext/nested/hook.mjs")
    assert js_conn.status == 200
    assert get_resp_header(js_conn, "content-type") == ["text/javascript; charset=utf-8"]

    head_conn = head(conn, "/ext-assets/demo.ext/ext.css")
    assert head_conn.status == 200
    assert head_conn.resp_body == ""

    for bad_path <- [
          "/ext-assets/demo.ext/../outside.css",
          "/ext-assets/demo.ext/linked.css",
          "/ext-assets/demo.ext/missing.css",
          "/ext-assets/unknown.ext/ext.css"
        ] do
      bad_conn = get(conn, bad_path)
      assert bad_conn.status == 404
      assert get_resp_header(bad_conn, "x-content-type-options") == ["nosniff"]
    end
  end

  test "renders SessionLive sidebar panels in dependency-resolved order", %{
    conn: conn,
    projects_dir: projects_dir,
    owner_token: owner_token,
    daemon_opts: daemon_opts
  } do
    opts = Application.get_env(:harness_web, :daemon_opts) || daemon_opts
    {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => projects_dir}, opts)
    conn = log_in_owner(conn, owner_token)
    {:ok, view, _html} = live(conn, "/sessions/#{session.session_id}")

    html = render(view)
    assert has_element?(view, "#ext-sidebar-panel-top", "Top Panel")
    assert has_element?(view, "#ext-sidebar-panel-after-agent", "After Agent (1)")

    assert has_element?(
             view,
             "#ext-sidebar-panel-before-conv",
             "Before Conversations (#{session.session_id})"
           )

    top_pos = pos_in(html, "ext-sidebar-panel-top")
    meta_pos = pos_in(html, "hdr-harness")
    tags_pos = pos_in(html, "session-tags")
    after_agent_pos = pos_in(html, "ext-sidebar-panel-after-agent")
    before_conv_pos = pos_in(html, "ext-sidebar-panel-before-conv")
    branches_pos = pos_in(html, "branches-list")

    assert top_pos < meta_pos
    assert meta_pos < tags_pos
    assert tags_pos < after_agent_pos
    assert after_agent_pos < before_conv_pos
    assert before_conv_pos < branches_pos
  end

  defp pos_in(html, needle) do
    case :binary.match(html, needle) do
      {idx, _len} -> idx
      :nomatch -> flunk("Expected #{inspect(needle)} in HTML")
    end
  end
end
