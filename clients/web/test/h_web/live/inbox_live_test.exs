defmodule HWeb.InboxLiveTest do
  use HWeb.ConnCase, async: false

  alias H.{Catalog, Daemon}
  alias H.Provider.Fake

  describe "authentication" do
    test "redirects unauthenticated GET and LiveView mount on /inbox to /login", %{conn: conn} do
      resp_conn = get(conn, "/inbox")
      assert redirected_to(resp_conn) == "/login"
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/inbox")
    end
  end

  describe "/inbox workspace grouping, states, filters, and live updates" do
    test "groups sessions by cwd, renders attention/processing states, filters, and updates live via :catalog PubSub",
         %{
           conn: conn,
           projects_dir: projects_dir,
           owner_token: owner_token,
           daemon_opts: daemon_opts,
           pubsub: pubsub
         } do
      catalog = Keyword.fetch!(daemon_opts, :catalog)

      dir_alpha = Path.join(projects_dir, "alpha") |> Path.expand()
      dir_beta = Path.join(projects_dir, "beta") |> Path.expand()
      File.mkdir_p!(dir_alpha)
      File.mkdir_p!(dir_beta)

      {:ok, _} =
        Catalog.put_session(catalog, %{
          session_id: "alpha-idle",
          cwd: dir_alpha,
          title: "Alpha Idle",
          attention: "idle"
        })

      {:ok, _} =
        Catalog.put_session(catalog, %{
          session_id: "alpha-bash",
          cwd: dir_alpha,
          title: "Alpha Running Bash",
          active: true,
          attention: "running",
          activity_kind: "tool",
          activity_label: "bash"
        })

      {:ok, _} =
        Catalog.put_session(catalog, %{
          session_id: "beta-err",
          cwd: dir_beta,
          title: "Beta Failed",
          attention: "error",
          activity_label: "model_error"
        })

      {:ok, _} =
        Catalog.put_session(catalog, %{
          session_id: "beta-quar",
          cwd: dir_beta,
          title: "Beta Quarantined",
          status: "quarantined",
          quarantine_reason: "corrupt_log"
        })

      conn = log_in_owner(conn, owner_token)
      {:ok, view, html} = live(conn, "/inbox")

      # Subscribed to :catalog PubSub topic
      assert Enum.any?(Registry.lookup(pubsub, :catalog), fn {pid, _} -> pid == view.pid end)

      # Grouped under working directory roots
      assert has_element?(view, ~s([data-workspace-root="#{dir_alpha}"]))
      assert has_element?(view, ~s([data-workspace-root="#{dir_beta}"]))

      # Status indicators and labels distinguish idle, running (bash), error (model_error), quarantined
      assert has_element?(
               view,
               ~s(a[data-session-id="alpha-idle"].needs-attention .inbox-status-idle)
             )

      assert has_element?(
               view,
               ~s(a[data-session-id="alpha-bash"].is-processing .inbox-status-running)
             )

      assert html =~ "bash"

      assert has_element?(
               view,
               ~s(a[data-session-id="beta-err"].is-error.needs-attention .inbox-status-error)
             )

      assert html =~ "model_error"

      assert has_element?(
               view,
               ~s(a[data-session-id="beta-quar"].is-error.needs-attention .inbox-status-error)
             )

      assert html =~ "quarantined"

      # Filter pills: Needs Attention (3) vs All Sessions (4)
      assert has_element?(view, "#inbox-filter-attention", "3")
      assert has_element?(view, "#inbox-filter-all", "4")

      view |> element("#inbox-filter-attention") |> render_click()
      assert has_element?(view, ~s(a[data-session-id="alpha-idle"]))
      assert has_element?(view, ~s(a[data-session-id="beta-err"]))
      assert has_element?(view, ~s(a[data-session-id="beta-quar"]))
      refute has_element?(view, ~s(a[data-session-id="alpha-bash"]))

      # Switch back to All Sessions and test search
      view |> element("#inbox-filter-all") |> render_click()
      assert has_element?(view, ~s(a[data-session-id="alpha-bash"]))

      view
      |> form("#inbox-filter-search-form", %{q: "beta"})
      |> render_change()

      assert has_element?(view, ~s(a[data-session-id="beta-err"]))
      refute has_element?(view, ~s(a[data-session-id="alpha-idle"]))

      view
      |> form("#inbox-filter-search-form", %{q: ""})
      |> render_change()

      # Live PubSub update: background running session transitions to generation, fails, then settles to idle
      {:ok, _} =
        Catalog.report_runtime(catalog, "alpha-bash", %{
          active: true,
          attention: "running",
          activity_kind: "generation",
          activity_label: "generation"
        })

      wait_until(fn ->
        has_element?(view, ~s(a[data-session-id="alpha-bash"]), "generation")
      end)

      {:ok, _} =
        Catalog.report_runtime(catalog, "alpha-bash", %{
          active: false,
          attention: "error",
          activity_kind: nil,
          activity_label: "rate_limited"
        })

      wait_until(fn ->
        has_element?(view, ~s(a[data-session-id="alpha-bash"].is-error), "rate_limited") and
          has_element?(view, "#inbox-filter-attention", "4")
      end)

      {:ok, _} =
        Catalog.report_runtime(catalog, "alpha-bash", %{
          active: false,
          attention: "idle",
          activity_kind: nil,
          activity_label: nil
        })

      wait_until(fn ->
        has_element?(
          view,
          ~s(a[data-session-id="alpha-bash"].needs-attention .inbox-status-idle)
        )
      end)

      # Live removal via PubSub
      :ok = Catalog.delete_session(catalog, "beta-quar")

      wait_until(fn ->
        not has_element?(view, ~s(a[data-session-id="beta-quar"])) and
          has_element?(view, "#inbox-filter-all", "3")
      end)
    end

    test "updates live during a real fake-provider run from idle -> running -> idle", %{
      conn: conn,
      projects_dir: projects_dir,
      owner_token: owner_token,
      daemon_opts: daemon_opts,
      fake: fake
    } do
      parent = self()
      gate_ref = make_ref()

      Fake.push_step(
        fake,
        {:gate, [%{type: :text_delta, text: "Working...", metadata: %{}}], parent, gate_ref,
         %{content: [%{type: "text", text: "Finished."}], finish_reason: "stop"}}
      )

      {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => projects_dir}, daemon_opts)
      sid = session.session_id

      conn = log_in_owner(conn, owner_token)
      {:ok, view, _html} = live(conn, "/inbox")

      assert has_element?(
               view,
               ~s(a[data-session-id="#{sid}"].needs-attention .inbox-status-idle)
             )

      # Submit work to the background session via Daemon
      {:ok, _receipt} =
        Daemon.execute_command(
          sid,
          %{
            "version" => 1,
            "request_id" => "inbox-run-1",
            "conversation_id" => "1",
            "command" => "submit",
            "args" => %{"type" => "input", "content" => "Run in background"}
          },
          daemon_opts
        )

      assert_receive {:gate_entered, ^gate_ref, gate_pid}, 2_000

      wait_until(fn ->
        has_element?(view, ~s(a[data-session-id="#{sid}"].is-processing .inbox-status-running))
      end)

      send(gate_pid, {:release, gate_ref})

      wait_until(fn ->
        has_element?(view, ~s(a[data-session-id="#{sid}"].needs-attention .inbox-status-idle))
      end)
    end
  end

  describe "navigation between /inbox and SessionLive switcher" do
    test "navigates from /inbox to /sessions/:sid?from=inbox, shows live switcher & return link, and jumps to next attention session",
         %{
           conn: conn,
           projects_dir: projects_dir,
           owner_token: owner_token,
           daemon_opts: daemon_opts,
           pubsub: pubsub
         } do
      catalog = Keyword.fetch!(daemon_opts, :catalog)

      dir_a = Path.join(projects_dir, "proj-a") |> Path.expand()
      dir_b = Path.join(projects_dir, "proj-b") |> Path.expand()
      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)

      {:ok, %{session: s1}} =
        Daemon.create_session(%{"cwd" => dir_a, "title" => "First"}, daemon_opts)

      {:ok, %{session: s2}} =
        Daemon.create_session(%{"cwd" => dir_b, "title" => "Second"}, daemon_opts)

      conn = log_in_owner(conn, owner_token)
      {:ok, inbox_view, _html} = live(conn, "/inbox")

      # Click session s1 from /inbox -> navigates to /sessions/:sid?from=inbox
      {:ok, session_view, _html} =
        inbox_view
        |> element(~s(a[data-session-id="#{s1.session_id}"]))
        |> render_click()
        |> follow_redirect(conn, "/sessions/#{s1.session_id}?from=inbox")

      # SessionLive is subscribed to :catalog as well as its conversation
      assert Enum.any?(Registry.lookup(pubsub, :catalog), fn {pid, _} ->
               pid == session_view.pid
             end)

      # Header shows <- Inbox return navigation and Next idle -> attention pill
      assert has_element?(session_view, "#header-inbox-link.btn-inbox-return", "← Inbox")
      assert has_element?(session_view, "#next-attention-btn", "1 need attention")
      assert has_element?(session_view, "#next-attention-btn", "Next idle →")

      # Sidebar/mobile drawer shows All Sessions (Inbox) tree with both sessions
      assert has_element?(
               session_view,
               ~s(#session-sidebar-inbox-tree a[data-session-id="#{s1.session_id}"].is-current)
             )

      assert has_element?(
               session_view,
               ~s(#session-sidebar-inbox-tree a[data-session-id="#{s2.session_id}"])
             )

      # Live catalog update inside SessionLive when s2 enters error state
      {:ok, _} =
        Catalog.report_runtime(catalog, s2.session_id, %{
          active: false,
          attention: "error",
          activity_label: "model_error"
        })

      wait_until(fn ->
        has_element?(session_view, "#next-attention-btn.is-error", "Next error →") and
          has_element?(
            session_view,
            ~s(#session-sidebar-inbox-tree a[data-session-id="#{s2.session_id}"].is-error)
          )
      end)

      # Jumping to next attention session opens s2?from=inbox
      {:ok, s2_view, _html} =
        session_view
        |> element("#next-attention-btn")
        |> render_click()
        |> follow_redirect(conn, "/sessions/#{s2.session_id}?from=inbox")

      assert has_element?(s2_view, ".header-sid", s2.session_id)
      assert has_element?(s2_view, "#header-inbox-link.btn-inbox-return", "← Inbox")

      # Clicking <- Inbox returns cleanly to /inbox
      {:ok, returned_inbox, _html} =
        s2_view
        |> element("#header-inbox-link")
        |> render_click()
        |> follow_redirect(conn, "/inbox")

      assert has_element?(returned_inbox, "#inbox-workspace-tree")
    end

    test "creates a new session from a workspace group header + New button and opens with ?from=inbox",
         %{
           conn: conn,
           projects_dir: projects_dir,
           owner_token: owner_token,
           daemon_opts: daemon_opts
         } do
      repo_dir = Path.join(projects_dir, "gamma") |> Path.expand()
      File.mkdir_p!(repo_dir)

      {:ok, %{session: existing}} = Daemon.create_session(%{"cwd" => repo_dir}, daemon_opts)

      conn = log_in_owner(conn, owner_token)
      {:ok, view, _html} = live(conn, "/inbox")

      {:error, {:live_redirect, %{to: to_path}}} =
        view
        |> element(~s([data-workspace-root="#{repo_dir}"] button[phx-click="new_session"]))
        |> render_click()

      assert to_path =~ ~r"^/sessions/gamma-[0-9a-f]+\?from=inbox$"
      refute to_path =~ existing.session_id
    end

    test "preserves from=inbox across conversation branch switches in SessionLive", %{
      conn: conn,
      projects_dir: projects_dir,
      owner_token: owner_token,
      daemon_opts: daemon_opts,
      fake: fake
    } do
      Fake.push_step(
        fake,
        {:reply, [], %{content: [%{type: "text", text: "Hello"}], finish_reason: "stop"}}
      )

      {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => projects_dir}, daemon_opts)
      sid = session.session_id

      conn = log_in_owner(conn, owner_token)
      {:ok, view, _html} = live(conn, "/sessions/#{sid}?from=inbox")

      assert has_element?(view, "#header-inbox-link.btn-inbox-return")

      view
      |> form("#composer-form", %{content: "Start branch"})
      |> render_submit()

      wait_until(fn -> render(view) =~ "Hello" end)

      view
      |> element("#entries-stream article:first-of-type button[phx-click=\"fork_entry\"]")
      |> render_click()

      patch_path = assert_patch(view)
      assert patch_path =~ ~r"^/sessions/#{Regex.escape(sid)}/conversations/\d+\?from=inbox$"
      assert has_element?(view, "#header-inbox-link.btn-inbox-return")
    end

    test "unsubscribes from :catalog PubSub when InboxLive and SessionLive terminate", %{
      conn: conn,
      projects_dir: projects_dir,
      owner_token: owner_token,
      daemon_opts: daemon_opts,
      pubsub: pubsub
    } do
      {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => projects_dir}, daemon_opts)
      conn = log_in_owner(conn, owner_token)

      {:ok, inbox_view, _} = live(conn, "/inbox")
      inbox_pid = inbox_view.pid
      assert Enum.any?(Registry.lookup(pubsub, :catalog), fn {pid, _} -> pid == inbox_pid end)
      GenServer.stop(inbox_pid)

      wait_until(fn ->
        not Enum.any?(Registry.lookup(pubsub, :catalog), fn {pid, _} -> pid == inbox_pid end)
      end)

      {:ok, session_view, _} = live(conn, "/sessions/#{session.session_id}?from=inbox")
      session_pid = session_view.pid
      assert Enum.any?(Registry.lookup(pubsub, :catalog), fn {pid, _} -> pid == session_pid end)
      GenServer.stop(session_pid)

      wait_until(fn ->
        not Enum.any?(Registry.lookup(pubsub, :catalog), fn {pid, _} -> pid == session_pid end)
      end)
    end

    test "WorkspaceLive sidebar subscribes live to :catalog and links to /inbox", %{
      conn: conn,
      projects_dir: projects_dir,
      owner_token: owner_token,
      daemon_opts: daemon_opts
    } do
      catalog = Keyword.fetch!(daemon_opts, :catalog)

      conn = log_in_owner(conn, owner_token)
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#workspace-inbox-link", "Inbox")

      {:ok, _} =
        Catalog.put_session(catalog, %{
          session_id: "live-added-session",
          cwd: projects_dir,
          title: "Live Added",
          attention: "idle"
        })

      wait_until(fn ->
        has_element?(view, ~s(#workspace-sidebar a[data-session-id="live-added-session"]))
      end)
    end
  end

  describe "root-first subsessions exemption and hierarchical toggle" do
    test "hides subsessions by default, exempts them from attention badges and Jump to next, and reveals them hierarchically on toggle",
         %{
           conn: conn,
           projects_dir: projects_dir,
           owner_token: owner_token,
           daemon_opts: daemon_opts
         } do
      catalog = Keyword.fetch!(daemon_opts, :catalog)

      repo_dir = Path.join(projects_dir, "main-repo") |> Path.expand()
      worktree_dir = Path.join(projects_dir, "wt-lane-1") |> Path.expand()
      File.mkdir_p!(repo_dir)
      File.mkdir_p!(worktree_dir)

      {:ok, _} =
        Catalog.put_session(catalog, %{
          session_id: "coord-root",
          cwd: repo_dir,
          title: "Coordinator Root",
          active: true,
          attention: "running",
          activity_kind: "tool",
          activity_label: "subagent"
        })

      {:ok, _} =
        Catalog.put_session(catalog, %{
          session_id: "sub-lane-idle",
          cwd: worktree_dir,
          title: "Lane 1 Explorer",
          attention: "idle",
          parent: %{
            session_id: "coord-root",
            conversation_id: 1,
            at_entry_id: 12,
            task_id: 13,
            depth: 1
          },
          role: "subagent"
        })

      {:ok, _} =
        Catalog.put_session(catalog, %{
          session_id: "sub-lane-err",
          cwd: repo_dir,
          title: "Lane 2 Failed",
          attention: "error",
          activity_label: "model_error",
          parent: %{
            session_id: "coord-root",
            conversation_id: 1,
            at_entry_id: 14,
            depth: 1
          },
          role: "subagent"
        })

      conn = log_in_owner(conn, owner_token)
      {:ok, view, _html} = live(conn, "/inbox")

      # Root session visible; subsessions hidden by default; no separate worktree workspace group
      assert has_element?(view, ~s(a[data-session-id="coord-root"]))
      refute has_element?(view, ~s(a[data-session-id="sub-lane-idle"]))
      refute has_element?(view, ~s(a[data-session-id="sub-lane-err"]))
      refute has_element?(view, ~s([data-workspace-root="#{worktree_dir}"]))

      # Attention badges and Jump to next exempt idle/error subsessions
      assert has_element?(view, "#inbox-filter-attention", "0")
      assert has_element?(view, "#inbox-filter-all", "1")
      refute has_element?(view, "#inbox-topbar-attention")
      refute has_element?(view, "#inbox-jump-next-btn")

      # Subsessions toggle pill shows count (2) and reveals nested children on click
      assert has_element?(view, "#inbox-filter-subsessions", "Subsessions")
      assert has_element?(view, "#inbox-filter-subsessions", "2")

      view |> element("#inbox-filter-subsessions") |> render_click()

      assert has_element?(view, "#inbox-filter-subsessions.is-active")

      # Still only one workspace group (repo_dir); worktree subsession nests under coord-root
      assert has_element?(view, ~s([data-workspace-root="#{repo_dir}"]))
      refute has_element?(view, ~s([data-workspace-root="#{worktree_dir}"]))

      assert has_element?(
               view,
               ~s(.inbox-subsession-list a[data-session-id="sub-lane-idle"].is-subsession)
             )

      assert has_element?(
               view,
               ~s(.inbox-subsession-list a[data-session-id="sub-lane-idle"] .inbox-status-subsession-idle)
             )

      refute has_element?(
               view,
               ~s(a[data-session-id="sub-lane-idle"].needs-attention)
             )

      assert has_element?(
               view,
               ~s(.inbox-subsession-list a[data-session-id="sub-lane-idle"] .inbox-step-badge),
               "@12"
             )

      assert has_element?(
               view,
               ~s(.inbox-subsession-list a[data-session-id="sub-lane-idle"] .inbox-worktree-badge),
               "wt-lane-1"
             )

      # Same-cwd subsession has step badge but no redundant worktree badge
      assert has_element?(
               view,
               ~s(.inbox-subsession-list a[data-session-id="sub-lane-err"] .inbox-step-badge),
               "@14"
             )

      refute has_element?(
               view,
               ~s(.inbox-subsession-list a[data-session-id="sub-lane-err"] .inbox-worktree-badge)
             )

      # Query param ?subsessions=1 starts expanded
      {:ok, expanded_view, _html} = live(conn, "/inbox?subsessions=1")
      assert has_element?(expanded_view, "#inbox-filter-subsessions.is-active")

      assert has_element?(
               expanded_view,
               ~s(.inbox-subsession-list a[data-session-id="sub-lane-idle"])
             )
    end
  end

  defp wait_until(fun, attempts \\ 60)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
