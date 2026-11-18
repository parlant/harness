defmodule HWeb.WorkspaceLiveTest do
  use HWeb.ConnCase, async: false

  alias H.Daemon

  test "renders environments, folder markers, session counts, and starts a session with auto ID",
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

    {:ok, %{session: existing}} = Daemon.create_session(%{"cwd" => repo_dir}, daemon_opts)

    conn = log_in_owner(conn, owner_token)
    {:ok, view, html} = live(conn, "/")

    assert html =~ "Workspace Browser"
    assert html =~ "alpha-app/"
    assert html =~ ".git"
    assert html =~ "mix.exs"
    assert html =~ "AGENTS.md"
    assert html =~ "1 direct / 1 total"
    assert html =~ existing.session_id

    view
    |> element("button[phx-click=\"select_dir\"][phx-value-path=\"#{repo_dir}\"]")
    |> render_click()

    assert has_element?(view, "#selected-cwd-input[value=\"#{Path.expand(repo_dir)}\"]")

    {:error, {:live_redirect, %{to: to_path}}} =
      view
      |> form("#start-session-form", %{cwd: repo_dir, session_id: ""})
      |> render_submit()

    assert to_path =~ ~r"^/sessions/alpha-app-[0-9a-f]+$"
    minted_sid = String.replace_prefix(to_path, "/sessions/", "")
    assert minted_sid != existing.session_id

    {:ok, _session_view, session_html} = live(conn, to_path)
    assert session_html =~ minted_sid
  end
end
