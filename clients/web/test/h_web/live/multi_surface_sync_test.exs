defmodule HWeb.MultiSurfaceSyncTest do
  use HWeb.ConnCase, async: false

  alias H.Daemon
  alias H.Provider.Fake

  @tag :native_client
  test "Phoenix LiveView (HWeb) and cooperative Rust hi client synchronize live over api.sock on the same folder session",
       %{
         conn: conn,
         data_dir: data_dir,
         projects_dir: projects_dir,
         owner_token: owner_token,
         daemon_opts: daemon_opts,
         fake: fake
       } do
    repo_dir = Path.join(projects_dir, "sync-repo")
    File.mkdir_p!(repo_dir)

    Fake.push_step(
      fake,
      {:reply,
       [
         %{type: :thinking_delta, text: "Syncing across surfaces...", metadata: %{}},
         %{type: :text_delta, text: "Synced reply to both TUI and Phoenix!", metadata: %{}}
       ],
       %{
         content: [%{type: "text", text: "Synced reply to both TUI and Phoenix!"}],
         finish_reason: "stop"
       }}
    )

    Fake.push_step(
      fake,
      {:reply,
       [
         %{type: :thinking_delta, text: "Syncing interactively...", metadata: %{}},
         %{type: :text_delta, text: "Synced reply from interactive hi!", metadata: %{}}
       ],
       %{
         content: [%{type: "text", text: "Synced reply from interactive hi!"}],
         finish_reason: "stop"
       }}
    )

    # Start Unix domain socket listener (<data_dir>/api.sock) inside the same BEAM VM as HWeb.Endpoint
    sock_path = H.api_socket_path(data_dir)

    router_opts = [
      auth_server: daemon_opts[:auth_server],
      auth_table: daemon_opts[:auth_table],
      daemon: Daemon,
      daemon_opts: daemon_opts,
      sse_keepalive_ms: 100
    ]

    start_supervised!({H.HTTP.UnixListener, {sock_path, router_opts}})

    # 1. Create folder-scoped session and open it in Phoenix LiveView
    {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => repo_dir}, daemon_opts)
    sid = session.session_id

    conn = log_in_owner(conn, owner_token)
    {:ok, view, initial_html} = live(conn, "/sessions/#{sid}")
    refute initial_html =~ "Synced reply to both TUI and Phoenix!"

    hi_bin =
      (System.get_env("HI_BIN") || System.fetch_env!("H_INTERACTIVE_TEST_BIN"))
      |> Path.expand()

    {tui_out, 0} =
      System.cmd(
        hi_bin,
        ["--data-dir", data_dir, "--session", sid, "--print", "Hello from headless hi"],
        cd: repo_dir,
        env: [{"H_DAEMON_URL", nil}]
      )

    assert tui_out =~ "Synced reply to both TUI and Phoenix!"

    wait_until(fn ->
      html = render(view)

      html =~ "Hello from headless hi" and
        html =~ "Synced reply to both TUI and Phoenix!"
    end)

    driver = Path.expand("../../../../tui/tests/live_session.py", __DIR__)

    assert {_, 0} =
             System.cmd(
               "python3",
               [driver, hi_bin, data_dir, sid, repo_dir],
               env: [{"PYTHONDONTWRITEBYTECODE", "1"}]
             )

    # 3. Verify Phoenix LiveView automatically received the interactive TUI's prompt & streamed assistant reply!
    wait_until(fn ->
      html = render(view)

      html =~ "Hello from Rust TUI" and
        html =~ "Synced reply from interactive hi!"
    end)

    # 4. Spawn a step-anchored subsession via Rust `hi --parent <sid> --title ... -p ...`
    #    and verify HWeb `/inbox` exempts it by default, then nests it hierarchically when toggled!
    Fake.push_step(
      fake,
      {:reply, [%{type: :text_delta, text: "Subagent report ready!", metadata: %{}}],
       %{
         content: [%{type: "text", text: "Subagent report ready!"}],
         finish_reason: "stop"
       }}
    )

    worktree_dir = Path.join(projects_dir, "sync-sub-worktree")
    File.mkdir_p!(worktree_dir)

    {sub_out, 0} =
      System.cmd(
        hi_bin,
        [
          "--data-dir",
          data_dir,
          "--session",
          "sync-child-1",
          "--parent",
          sid,
          "--title",
          "Explore Lane",
          "--model",
          "fake:coder",
          "--thinking",
          "high",
          "--print",
          "Inspect sync-repo"
        ],
        cd: worktree_dir,
        env: [{"H_DAEMON_URL", nil}]
      )

    assert sub_out =~ "Subagent report ready!"

    {:ok, inbox_view, inbox_html} = live(conn, "/inbox")
    assert inbox_html =~ sid
    refute inbox_html =~ "Explore Lane"
    refute inbox_html =~ "sync-sub-worktree"

    toggled_html = inbox_view |> element("#inbox-filter-subsessions") |> render_click()
    assert toggled_html =~ "Explore Lane"
    assert toggled_html =~ "sync-child-1"
  end

  defp wait_until(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for LiveView sync")
      else
        Process.sleep(15)
        do_wait_until(fun, deadline)
      end
    end
  end
end
