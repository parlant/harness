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
    test "navigates in inbox order while the sidebar highlights the current session among its folder peers",
         %{
           conn: conn,
           projects_dir: cwd,
           owner_token: owner_token,
           daemon_opts: opts,
           pubsub: pubsub
         } do
      catalog = Keyword.fetch!(opts, :catalog)
      other_dir = Path.join(cwd, "other")
      File.mkdir_p!(other_dir)

      for {sid, dir} <- [{"current", cwd}, {"peer", cwd}, {"elsewhere", other_dir}] do
        assert {:ok, _} = Daemon.create_session(%{session_id: sid, cwd: dir}, opts)
      end

      conn = log_in_owner(conn, owner_token)
      {:ok, inbox, _} = live(conn, "/inbox")

      {:ok, view, _} =
        inbox
        |> element(~s(a[data-session-id="current"]))
        |> render_click()
        |> follow_redirect(conn, "/sessions/current?from=inbox")

      assert Enum.any?(Registry.lookup(pubsub, :catalog), fn {pid, _} -> pid == view.pid end)
      assert has_element?(view, ~s(#app-menu a[href="/inbox"]), "Inbox")
      assert has_element?(view, ~s(#session-sidebar-inbox-tree a[data-session-id="peer"]))

      assert has_element?(
               view,
               ~s(#session-sidebar-inbox-tree a[data-session-id="current"].is-current[aria-current="page"])
             )

      refute has_element?(view, ~s(#session-sidebar-inbox-tree a[data-session-id="elsewhere"]))

      assert {:ok, _} =
               Catalog.report_runtime(catalog, "peer", %{
                 active: false,
                 attention: "error",
                 activity_label: "model_error"
               })

      wait_until(fn ->
        has_element?(view, ~s(#inbox-previous-session[href="/sessions/peer?from=inbox"])) and
          has_element?(view, ~s(#session-sidebar-inbox-tree a[data-session-id="peer"].is-error))
      end)

      {:ok, peer, _} =
        view
        |> element("#inbox-previous-session")
        |> render_click()
        |> follow_redirect(conn, "/sessions/peer?from=inbox")

      assert has_element?(peer, ~s(#inbox-next-session[href="/sessions/current?from=inbox"]))

      {:ok, returned, _} =
        peer
        |> element(~s(#app-menu a[href="/inbox"]))
        |> render_click()
        |> follow_redirect(conn, "/inbox")

      assert has_element?(returned, "#inbox-workspace-tree")
    end

    test "carries exact directory, tag, and search filters through the inbox carets, branch links, and main menu",
         %{conn: conn, projects_dir: cwd, owner_token: owner_token, daemon_opts: opts} do
      catalog = Keyword.fetch!(opts, :catalog)
      other_cwd = Path.join(cwd, "child")
      File.mkdir_p!(other_cwd)

      for {sid, title, tags} <- [
            {"current", "Review first", ["topic & notes"]},
            {"peer", "Review second", ["topic & notes"]},
            {"wrong-tag", "Review another", ["topic"]},
            {"wrong-title", "Unrelated", ["topic & notes"]}
          ] do
        assert {:ok, _} =
                 Daemon.create_session(
                   %{session_id: sid, cwd: cwd, title: title, tags: tags},
                   opts
                 )
      end

      for {sid, env_id, path} <- [{"wrong-dir", "host", other_cwd}, {"wrong-env", "vm", cwd}] do
        assert {:ok, _} =
                 Catalog.put_session(catalog, %{
                   session_id: sid,
                   title: "Review error",
                   env_id: env_id,
                   cwd: path,
                   tags: ["topic & notes"],
                   attention: "error"
                 })
      end

      conn = log_in_owner(conn, owner_token)
      {:ok, inbox, _} = live(conn, "/inbox")

      inbox
      |> form("#inbox-filter-search-form", %{
        workspace: JSON.encode!(["host", cwd]),
        tag: "topic & notes",
        q: "review"
      })
      |> render_change()

      filters = %{cwd: cwd, tag: "topic & notes", q: "review"}
      assert_patch(inbox, ~p"/inbox?#{filters}")

      assert has_element?(
               inbox,
               ~s(a[data-session-id="current"] .inbox-session-tag),
               "topic & notes"
             )

      assert has_element?(inbox, ~s(a[data-session-id="peer"]))
      refute has_element?(inbox, ~s(a[data-session-id^="wrong-"]))

      assert has_element?(inbox, "#inbox-topbar-attention", "2 attention")
      assert has_element?(inbox, "#inbox-jump-next-btn")

      session_filters = Map.put(filters, :from, "inbox")

      {:ok, view, _} =
        inbox
        |> element(~s(a[data-session-id="current"]))
        |> render_click()
        |> follow_redirect(conn, ~p"/sessions/current?#{session_filters}")

      refute has_element?(view, ~s(.app-bar a[title*="wrong-"]))
      assert has_element?(view, ".app-bar a.inbox-caret[title$='Review second']")
      assert has_element?(view, ".app-bar button.inbox-caret[disabled]")

      view |> element("#branches-list a") |> render_click()
      assert_patch(view, ~p"/sessions/current/conversations/1?#{session_filters}")

      {:ok, peer, _} =
        view
        |> element(".app-bar a.inbox-caret")
        |> render_click()
        |> follow_redirect(conn, ~p"/sessions/peer?#{session_filters}")

      {:ok, returned, _} =
        peer
        |> element("#app-menu a", "Inbox")
        |> render_click()
        |> follow_redirect(conn, ~p"/inbox?#{filters}")

      refute has_element?(returned, ~s(a[data-session-id^="wrong-"]))
    end

    test "updates filtered inbox neighbors on tag edits without hiding same-folder sessions",
         %{conn: conn, projects_dir: cwd, owner_token: owner_token, daemon_opts: opts} do
      for {sid, tags} <- [{"current", ["work"]}, {"peer", ["work"]}, {"other", ["personal"]}] do
        assert {:ok, _} = Daemon.create_session(%{session_id: sid, cwd: cwd, tags: tags}, opts)
      end

      conn = log_in_owner(conn, owner_token)
      {:ok, view, _} = live(conn, "/sessions/current?from=inbox&tag=work")
      {:ok, peer, _} = live(conn, "/sessions/peer")

      assert has_element?(view, ~s(.app-bar a.inbox-caret[title$=": peer"]))
      assert has_element?(view, ~s(#session-sidebar-inbox-tree a[data-session-id="other"]))
      refute has_element?(peer, ".app-bar .inbox-caret")

      peer
      |> element(~s(#session-tags-form button[aria-label="Remove tag work"]))
      |> render_click()

      wait_until(fn -> not has_element?(view, ".app-bar a.inbox-caret") end)
      assert has_element?(view, ~s(#session-sidebar-inbox-tree a[data-session-id="peer"]))

      peer |> form("#session-tags-form", %{tags: "work"}) |> render_submit()
      wait_until(fn -> has_element?(view, ~s(.app-bar a.inbox-caret[title$=": peer"])) end)
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

      assert has_element?(view, ~s(#app-menu a[href="/inbox"]))

      view
      |> form("#composer-form", %{content: "Start branch"})
      |> render_submit()

      wait_until(fn -> render(view) =~ "Hello" end)

      view
      |> element("#entries-stream .entry-assistant button[phx-click=\"fork_entry\"]")
      |> render_click()

      patch_path = assert_patch(view)
      assert patch_path =~ ~r"^/sessions/#{Regex.escape(sid)}/conversations/\d+\?from=inbox$"
      assert has_element?(view, ~s(#app-menu a[href="/inbox"]))
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
        has_element?(view, ~s(#workspace-sessions a[data-session-id="live-added-session"]))
      end)
    end
  end

  describe "triage, stop, archive/unload, and missing-cwd recovery" do
    test "dismissing attention keeps the session in Inbox but excludes it from Next; Archived shows and restores archived sessions",
         %{
           conn: conn,
           projects_dir: projects_dir,
           owner_token: owner_token,
           daemon_opts: daemon_opts
         } do
      dir_a = Path.join(projects_dir, "triage-ws") |> Path.expand()
      File.mkdir_p!(dir_a)

      {:ok, %{session: s1}} =
        Daemon.create_session(%{"cwd" => dir_a, "title" => "First"}, daemon_opts)

      {:ok, %{session: s2}} =
        Daemon.create_session(%{"cwd" => dir_a, "title" => "Second"}, daemon_opts)

      conn = log_in_owner(conn, owner_token)
      {:ok, view, _html} = live(conn, "/inbox")

      # Default filter is "inbox"
      assert has_element?(view, "#inbox-filter-inbox.is-active", "2")
      assert has_element?(view, "#inbox-filter-attention", "2")
      assert has_element?(view, "#inbox-filter-archived", "0")
      assert has_element?(view, "#inbox-filter-all", "2")

      assert has_element?(
               view,
               ~s(a[data-session-id="#{s1.session_id}"][data-needs-attention="true"])
             )

      assert has_element?(
               view,
               ~s(a[data-session-id="#{s2.session_id}"][data-needs-attention="true"])
             )

      # Toggle s2 to not needing attention
      view
      |> element(~s([data-session-row="#{s2.session_id}"] button[phx-click="toggle_attention"]))
      |> render_click()

      wait_until(fn ->
        has_element?(
          view,
          ~s(a[data-session-id="#{s2.session_id}"][data-needs-attention="false"].is-cleared)
        ) and has_element?(view, "#inbox-filter-attention", "1")
      end)

      # Still visible in Inbox, but pushed to the bottom of the workspace group (after s1)
      assert has_element?(view, "#inbox-filter-inbox", "2")
      html = render(view)
      {s1_pos, _} = :binary.match(html, ~s(data-session-id="#{s1.session_id}"))
      {s2_pos, _} = :binary.match(html, ~s(data-session-id="#{s2.session_id}"))
      assert s1_pos < s2_pos

      # Carets traverse the inbox, including sessions already marked read.
      {:ok, s1_view, _} = live(conn, "/sessions/#{s1.session_id}?from=inbox")

      assert has_element?(
               s1_view,
               ~s(#inbox-next-session[href="/sessions/#{s2.session_id}?from=inbox"])
             )

      assert has_element?(s1_view, "#session-attention-toggle", "Mark as read")

      # Toggle attention right from SessionLive header
      s1_view
      |> element("#session-attention-toggle")
      |> render_click()

      assert has_element?(s1_view, "#session-attention-toggle", "Mark for attention")

      # Archive s2 from /inbox -> disappears from Inbox, appears in Archived, and Unarchive restores it
      {:ok, inbox_view, _} = live(conn, "/inbox")

      inbox_view
      |> element(~s([data-session-row="#{s2.session_id}"] button[phx-click="archive_session"]))
      |> render_click()

      wait_until(fn ->
        not has_element?(inbox_view, ~s(a[data-session-id="#{s2.session_id}"])) and
          has_element?(inbox_view, "#inbox-filter-archived", "1")
      end)

      # Verify OTP server was unloaded
      registry = Keyword.fetch!(daemon_opts, :registry)
      assert [] == Registry.lookup(registry, {:session, s2.session_id})

      # Switch to Archived filter and unarchive s2
      inbox_view |> element("#inbox-filter-archived") |> render_click()

      assert has_element?(
               inbox_view,
               ~s(a[data-session-id="#{s2.session_id}"][data-archived="true"])
             )

      inbox_view
      |> element(~s([data-session-row="#{s2.session_id}"] button[phx-click="unarchive_session"]))
      |> render_click()

      wait_until(fn ->
        has_element?(inbox_view, "#inbox-filter-archived", "0")
      end)

      inbox_view |> element("#inbox-filter-inbox") |> render_click()
      assert has_element?(inbox_view, ~s(a[data-session-id="#{s2.session_id}"]))
    end

    test "stops a running session directly from /inbox and archives from SessionLive header", %{
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
         %{content: [%{type: "text", text: "Done."}], finish_reason: "stop"}}
      )

      {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => projects_dir}, daemon_opts)
      sid = session.session_id

      conn = log_in_owner(conn, owner_token)
      {:ok, view, _html} = live(conn, "/inbox")

      {:ok, _receipt} =
        Daemon.execute_command(
          sid,
          %{
            "version" => 1,
            "request_id" => "inbox-stop-1",
            "conversation_id" => "1",
            "command" => "submit",
            "args" => %{"type" => "input", "content" => "Long running task"}
          },
          daemon_opts
        )

      assert_receive {:gate_entered, ^gate_ref, _gate_pid}, 2_000

      wait_until(fn ->
        has_element?(view, ~s([data-session-row="#{sid}"] button[phx-click="stop_session"]))
      end)

      # Stop directly from /inbox
      view
      |> element(~s([data-session-row="#{sid}"] button[phx-click="stop_session"]))
      |> render_click()

      wait_until(fn ->
        has_element?(view, ~s(a[data-session-id="#{sid}"][data-needs-attention="true"])) and
          not has_element?(view, ~s([data-session-row="#{sid}"] button[phx-click="stop_session"]))
      end)

      # Open session and archive from SessionLive header -> unloads OTP server and redirects to /inbox
      {:ok, session_view, _} = live(conn, "/sessions/#{sid}?from=inbox")

      {:ok, returned_inbox, _} =
        session_view
        |> element("#archive-session-btn")
        |> render_click()
        |> follow_redirect(conn, "/inbox")

      assert has_element?(returned_inbox, "#inbox-filter-archived", "1")
      refute has_element?(returned_inbox, ~s(a[data-session-id="#{sid}"]))

      registry = Keyword.fetch!(daemon_opts, :registry)
      assert [] == Registry.lookup(registry, {:session, sid})
    end

    test "deleted cwd renders transcript without crashing, replaces composer with #missing-cwd-picker, and forks into a valid directory",
         %{
           conn: conn,
           projects_dir: projects_dir,
           owner_token: owner_token,
           daemon_opts: daemon_opts,
           fake: fake
         } do
      ephemeral_dir = Path.join(projects_dir, "ephemeral-wt") |> Path.expand()
      target_dir = Path.join(projects_dir, "valid-target") |> Path.expand()
      File.mkdir_p!(ephemeral_dir)
      File.mkdir_p!(target_dir)

      Fake.push_step(
        fake,
        {:reply, [],
         %{
           content: [%{type: "text", text: "Transcript preserved cleanly."}],
           finish_reason: "stop"
         }}
      )

      Fake.push_step(
        fake,
        {:reply, [],
         %{content: [%{type: "text", text: "Continued in new workspace!"}], finish_reason: "stop"}}
      )

      {:ok, %{session: s}} =
        Daemon.create_session(%{"cwd" => ephemeral_dir, "title" => "Worktree"}, daemon_opts)

      sid = s.session_id

      # Run one completed turn
      {:ok, _} =
        Daemon.execute_command(
          sid,
          %{
            "version" => 1,
            "request_id" => "wt-turn-1",
            "conversation_id" => "1",
            "command" => "submit",
            "args" => %{"type" => "input", "content" => "Remember this history"}
          },
          daemon_opts
        )

      wait_until(fn ->
        case Daemon.scan_entries(sid, "1", %{}, daemon_opts) do
          {:ok, %{items: items}} -> length(items) >= 2
          _ -> false
        end
      end)

      # Delete the working directory and unload/archive then unarchive so it opens cold like a restarted/unloaded session
      File.rm_rf!(ephemeral_dir)
      {:ok, _} = Daemon.archive_session(sid, %{"archived" => true}, daemon_opts)
      {:ok, _} = Daemon.archive_session(sid, %{"archived" => false}, daemon_opts)

      conn = log_in_owner(conn, owner_token)

      # /inbox displays missing dir badge and allows opening via link
      {:ok, inbox_view, _} = live(conn, "/inbox")

      assert has_element?(
               inbox_view,
               ~s(a[data-session-id="#{sid}"] .inbox-missing-cwd-badge),
               "missing dir"
             )

      # Opening /sessions/:sid?from=inbox succeeds (HTTP 200, no crash!)
      {:ok, session_view, html} = live(conn, "/sessions/#{sid}?from=inbox")

      assert html =~ "Remember this history"
      assert html =~ "Transcript preserved cleanly."
      refute has_element?(session_view, "#composer-form")
      assert has_element?(session_view, "#missing-cwd-picker")
      assert html =~ "Working directory no longer exists"

      # Picker initialized to nearest existing ancestor (projects_dir) and lists valid-target/
      assert has_element?(
               session_view,
               ~s(#picker-dir-list button[phx-value-path="#{target_dir}"])
             )

      # Click child directory valid-target/
      session_view
      |> element(~s(#picker-dir-list button[phx-value-path="#{target_dir}"]))
      |> render_click()

      assert has_element?(session_view, "#fork-to-cwd-btn", target_dir)

      # Fork into valid-target/ -> navigates to brand-new live session
      {:error, {:live_redirect, %{to: forked_path}}} =
        session_view
        |> element("#fork-to-cwd-btn")
        |> render_click()

      assert forked_path =~ ~r"^/sessions/valid-target-[0-9a-f]+\?from=inbox$"
      refute forked_path =~ sid

      # Open forked session: transcript is preserved, composer is active, and new prompts work!
      {:ok, forked_view, forked_html} = live(conn, forked_path)
      assert forked_html =~ "Remember this history"
      assert forked_html =~ "Transcript preserved cleanly."
      assert has_element?(forked_view, "#composer-form")
      refute has_element?(forked_view, "#missing-cwd-picker")

      forked_view
      |> form("#composer-form", %{content: "Carry on here"})
      |> render_submit()

      wait_until(fn ->
        render(forked_view) =~ "Continued in new workspace!"
      end)
    end

    test "unavailable non-host environment redirects cleanly with flash error instead of crashing SessionLive",
         %{
           conn: conn,
           projects_dir: projects_dir,
           owner_token: owner_token,
           daemon_opts: daemon_opts
         } do
      catalog = Keyword.fetch!(daemon_opts, :catalog)

      {:ok, _} =
        Catalog.put_session(catalog, %{
          session_id: "offline-vm-session",
          env_id: "offline-vm",
          cwd: projects_dir,
          title: "Offline VM",
          attention: "idle"
        })

      conn = log_in_owner(conn, owner_token)

      # Opening from inbox redirects cleanly to /inbox with flash error (no 500 crash)
      assert {:error, {:live_redirect, %{to: "/inbox", flash: %{"error" => msg}}}} =
               live(conn, "/sessions/offline-vm-session?from=inbox")

      assert msg =~ "unavailable"

      # Opening without from=inbox redirects cleanly to / with flash error
      assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => msg2}}}} =
               live(conn, "/sessions/offline-vm-session")

      assert msg2 =~ "unavailable"
    end

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

    test "inspecting an archived session keeps it archived and unloaded until messaged or unarchived",
         %{
           conn: conn,
           projects_dir: projects_dir,
           owner_token: owner_token,
           daemon_opts: daemon_opts,
           fake: fake
         } do
      Fake.push_step(
        fake,
        {:reply, [],
         %{content: [%{type: "text", text: "Cold archived reply."}], finish_reason: "stop"}}
      )

      Fake.push_step(
        fake,
        {:reply, [],
         %{content: [%{type: "text", text: "Resumed from archive!"}], finish_reason: "stop"}}
      )

      {:ok, %{session: s_arch}} =
        Daemon.create_session(%{"cwd" => projects_dir, "title" => "Shelved"}, daemon_opts)

      {:ok, %{session: s_live}} =
        Daemon.create_session(%{"cwd" => projects_dir, "title" => "Active"}, daemon_opts)

      {:ok, _} =
        Daemon.execute_command(
          s_arch.session_id,
          %{
            "version" => 1,
            "request_id" => "arch-turn-1",
            "conversation_id" => "1",
            "command" => "submit",
            "args" => %{"type" => "input", "content" => "Initial prompt"}
          },
          daemon_opts
        )

      wait_until(fn ->
        {:ok, d} = Daemon.get_session_detail(s_arch.session_id, daemon_opts)
        d.session.attention == "idle"
      end)

      {:ok, %{session: archived_meta}} =
        Daemon.archive_session(s_arch.session_id, %{"archived" => true}, daemon_opts)

      assert archived_meta.archived == true
      assert archived_meta.attention == "archived"
      assert archived_meta.loaded == false
      assert [] == Registry.lookup(daemon_opts[:registry], {:session, s_arch.session_id})

      conn = log_in_owner(conn, owner_token)

      # Viewing s_live hides archived sessions from the compact sidebar switcher
      {:ok, live_view, _} = live(conn, "/sessions/#{s_live.session_id}?from=inbox")

      refute has_element?(
               live_view,
               ~s(#session-sidebar-inbox-tree a[data-session-id="#{s_arch.session_id}"])
             )

      # Viewing s_arch renders transcript cold WITHOUT waking OTP or clearing archived!
      {:ok, arch_view, arch_html} = live(conn, "/sessions/#{s_arch.session_id}?from=inbox")

      assert arch_html =~ "Initial prompt"
      assert arch_html =~ "Cold archived reply."
      assert has_element?(arch_view, "#hdr-archived-badge", "archived")
      assert has_element?(arch_view, "#unarchive-session-btn", "Unarchive")
      refute has_element?(arch_view, "#archive-session-btn")
      assert [] == Registry.lookup(daemon_opts[:registry], {:session, s_arch.session_id})

      # Submitting a prompt automatically unarchives, boots OTP, and streams the new turn
      arch_view
      |> form("#composer-form", %{content: "Wake up now"})
      |> render_submit()

      wait_until(fn ->
        html = render(arch_view)

        html =~ "Resumed from archive!" and
          not has_element?(arch_view, "#hdr-archived-badge") and
          has_element?(arch_view, "#archive-session-btn")
      end)

      assert [{_, _}] = Registry.lookup(daemon_opts[:registry], {:session, s_arch.session_id})
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
