defmodule HWeb.WorkspaceLiveTest do
  use HWeb.ConnCase, async: false

  alias H.{Catalog, Daemon}

  defp wait_for_session(view, session_id, attempts \\ 40) do
    listed? = has_element?(view, "#folder-sessions-list .session-id", session_id)

    if not listed? and attempts > 0 do
      Process.sleep(25)
      wait_for_session(view, session_id, attempts - 1)
    else
      assert listed?
    end
  end

  test "browses folders and previews their sessions without changing the current directory",
       %{
         conn: conn,
         projects_dir: projects_dir,
         owner_token: owner_token,
         daemon_opts: daemon_opts
       } do
    repo_dir = Path.join(projects_dir, "alpha-app")
    File.mkdir_p!(Path.join(repo_dir, ".git"))
    File.write!(Path.join(repo_dir, "mix.exs"), "defmodule Alpha.MixProject, do: nil\n")
    File.write!(Path.join(repo_dir, "AGENTS.md"), "Keep tests fast.\n")

    nested_dir = Path.join(repo_dir, "nested")
    File.mkdir_p!(nested_dir)

    {:ok, %{session: current}} = Daemon.create_session(%{"cwd" => projects_dir}, daemon_opts)
    {:ok, %{session: existing}} = Daemon.create_session(%{"cwd" => repo_dir}, daemon_opts)
    {:ok, %{session: nested}} = Daemon.create_session(%{"cwd" => nested_dir}, daemon_opts)

    conn = log_in_owner(conn, owner_token)
    {:ok, view, html} = live(conn, "/")

    assert has_element?(view, "#workspace-sessions #all-sessions-list")
    assert has_element?(view, ".workspace-browser #directories-list")
    refute has_element?(view, "#ui-inspector")
    assert html =~ "Workspace Browser"
    assert html =~ "alpha-app/"
    assert html =~ ".git"
    assert html =~ "mix.exs"
    assert html =~ "AGENTS.md"
    assert html =~ "1 direct / 2 total"
    refute has_element?(view, "#start-session-form")
    assert has_element?(view, "#folder-sessions-list .session-id", current.session_id)
    refute has_element?(view, "#folder-sessions-list .session-id", existing.session_id)

    folder = ~s(button[phx-click="select_dir"][phx-value-path="#{repo_dir}"])
    view |> element(folder) |> render_click()

    assert has_element?(view, folder <> ~s([aria-pressed="true"]))
    assert has_element?(view, ~s(#workspace-path-input[value="#{projects_dir}"]))
    assert has_element?(view, ~s(.workspace-columns[data-pane="sessions"]))
    assert has_element?(view, "#workspace-sessions-path", repo_dir)
    assert has_element?(view, "#folder-sessions-list .session-id", existing.session_id)
    refute has_element?(view, "#folder-sessions-list .session-id", current.session_id)
    refute has_element?(view, "#folder-sessions-list .session-id", nested.session_id)

    {:ok, %{session: live_session}} = Daemon.create_session(%{"cwd" => repo_dir}, daemon_opts)
    wait_for_session(view, live_session.session_id)

    view |> element(folder) |> render_click()
    assert has_element?(view, folder <> ~s([aria-pressed="false"]))
    assert has_element?(view, "#folder-sessions-list .session-id", current.session_id)

    view |> element(folder) |> render_click()
    view |> element(~s(button[phx-click="clear_dir_selection"])) |> render_click()
    assert has_element?(view, "#folder-sessions-list .session-id", current.session_id)

    view
    |> element(~s(button[phx-click="browse_dir"][phx-value-path="#{repo_dir}"]))
    |> render_click()

    assert has_element?(view, ~s(#workspace-path-input[value="#{repo_dir}"]))
    assert has_element?(view, ~s(.workspace-columns[data-pane="folders"]))
    assert has_element?(view, "#folder-sessions-list .session-id", existing.session_id)
  end

  test "opens a new session dialog for the explicit directory before creating anything", ctx do
    %{conn: conn, owner_token: token, projects_dir: cwd, daemon_opts: opts} = ctx
    repo_dir = Path.join(cwd, "alpha-app")
    File.mkdir_p!(repo_dir)

    conn = log_in_owner(conn, token)
    {:ok, view, _html} = live(conn, "/workspaces")

    view
    |> element(~s(button[phx-click="select_dir"][phx-value-path="#{repo_dir}"]))
    |> render_click()

    view |> element("#new-current-session-btn") |> render_click()
    assert_push_event(view, "open_panel", %{id: "workspace-new-session"})
    assert has_element?(view, "#new-session-directory", cwd)
    refute has_element?(view, "#new-session-directory", repo_dir)
    assert {:ok, []} = Daemon.list_sessions(%{}, opts)

    view
    |> element(~s([popover] button[phx-click="prepare_session"][phx-value-cwd="#{repo_dir}"]))
    |> render_click()

    assert_push_event(view, "open_panel", %{id: "workspace-new-session"})
    assert has_element?(view, "#new-session-directory", repo_dir)
    assert {:ok, []} = Daemon.list_sessions(%{}, opts)

    view |> form("#start-session-form", %{session_id: "invalid/id"}) |> render_submit()
    assert has_element?(view, "#start-session-form [role=alert]")
    assert has_element?(view, ~s(#new-session-id-input[value="invalid/id"]))
    assert {:ok, []} = Daemon.list_sessions(%{}, opts)

    {:error, {:live_redirect, %{to: to_path}}} =
      view |> form("#start-session-form", %{session_id: ""}) |> render_submit()

    assert to_path =~ ~r"^/sessions/alpha-app-[0-9a-f]+$"
    sid = String.replace_prefix(to_path, "/sessions/", "")
    assert {:ok, %{session: %{cwd: ^repo_dir}}} = Daemon.get_session_detail(sid, opts)
    assert H.Provider.Fake.requests(ctx.fake) == []

    {:ok, session_view, _html} = live(conn, to_path)
    assert has_element?(session_view, "#reply[open]")
  end

  test "keeps archived status separate from the Open action for long session IDs", ctx do
    sid = "archive-" <> String.duplicate("a", 60)
    catalog = Keyword.fetch!(ctx.daemon_opts, :catalog)

    assert {:ok, _} =
             Catalog.put_session(catalog, %{
               session_id: sid,
               cwd: ctx.projects_dir,
               title: "An archived session with a long ID",
               archived: true
             })

    {:ok, view, _} = live(log_in_owner(ctx.conn, ctx.owner_token), "/workspaces")
    assert has_element?(view, ".session-card .session-id", sid)
    assert has_element?(view, ".session-card-badges > .badge", "Archived")
    assert has_element?(view, ~s(.session-card > a[href="/sessions/#{sid}"]), "Open")
  end

  test "keeps subsessions out of WorkspaceLive sidebar and attention counts", %{
    conn: conn,
    projects_dir: projects_dir,
    owner_token: owner_token,
    daemon_opts: daemon_opts
  } do
    catalog = Keyword.fetch!(daemon_opts, :catalog)
    repo_dir = Path.join(projects_dir, "root-repo") |> Path.expand()
    wt_dir = Path.join(projects_dir, "wt-sub") |> Path.expand()
    File.mkdir_p!(repo_dir)
    File.mkdir_p!(wt_dir)

    {:ok, _} =
      Catalog.put_session(catalog, %{
        session_id: "ws-root",
        cwd: repo_dir,
        title: "Root Session",
        active: true,
        attention: "running"
      })

    {:ok, _} =
      Catalog.put_session(catalog, %{
        session_id: "ws-child",
        cwd: wt_dir,
        title: "Hidden Subsession",
        attention: "idle",
        parent: %{session_id: "ws-root", conversation_id: 1, at_entry_id: 3, depth: 1},
        role: "subagent"
      })

    conn = log_in_owner(conn, owner_token)
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, ~s(#all-sessions-list a[data-session-id="ws-root"]))
    refute has_element?(view, ~s(#all-sessions-list a[data-session-id="ws-child"]))
    refute has_element?(view, ~s(#workspace-inbox-link .badge))
  end
end
