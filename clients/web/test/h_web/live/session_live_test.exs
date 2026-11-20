defmodule HWeb.SessionLiveTest do
  use HWeb.ConnCase, async: false

  alias H.{Catalog, Daemon}
  alias H.Provider.Fake
  alias HWeb.{CatalogState, ConversationComponents}

  import Phoenix.LiveViewTest

  test "processes fake generation live progress and commits assistant response without real LLM calls",
       %{
         conn: conn,
         projects_dir: projects_dir,
         owner_token: owner_token,
         daemon_opts: daemon_opts,
         fake: fake,
         pubsub: pubsub
       } do
    parent = self()
    gate_ref = make_ref()

    Fake.push_step(
      fake,
      {:gate,
       [
         %{type: :thinking_delta, text: "Checking project files...", metadata: %{}},
         %{type: :text_delta, text: "Partial ", metadata: %{}}
       ], parent, gate_ref,
       %{
         content: [%{type: "text", text: "Partial answer complete."}],
         finish_reason: "stop"
       }}
    )

    {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => projects_dir}, daemon_opts)
    sid = session.session_id

    conn = log_in_owner(conn, owner_token)
    {:ok, view, _html} = live(conn, "/sessions/#{sid}")

    # LiveView process subscribed on H.PubSub
    assert [{view_pid, _}] = Registry.lookup(pubsub, {:conversation, sid, 1})
    assert view_pid == view.pid

    # Submit user prompt
    view
    |> form("#composer-form", %{content: "Hello fake model"})
    |> render_submit()

    assert_receive {:gate_entered, ^gate_ref, gate_pid}, 2_000

    # Wait briefly for ephemeral live progress frame to arrive
    wait_until(fn ->
      html = render(view)
      html =~ "assistant (live)" and html =~ "Partial "
    end)

    live_html = render(view)
    assert live_html =~ "Checking project files..."
    assert has_element?(view, "#stop-btn")
    assert has_element?(view, "#steer-btn")

    # Release gated fake provider to finish turn
    send(gate_pid, {:release, gate_ref})

    wait_until(fn ->
      html = render(view)
      html =~ "Partial answer complete." and not (html =~ "assistant (live)")
    end)

    final_html = render(view)
    assert final_html =~ "Hello fake model"
    assert final_html =~ "Partial answer complete."
    assert length(Fake.requests(fake)) == 1
  end

  test "supports configure, steer, abort, fork, and resnapshot on sequence gap", %{
    conn: conn,
    projects_dir: projects_dir,
    owner_token: owner_token,
    daemon_opts: daemon_opts,
    fake: fake
  } do
    parent = self()
    gate1 = make_ref()
    gate2 = make_ref()

    Fake.push_step(
      fake,
      {:gate, [%{type: :text_delta, text: "First run...", metadata: %{}}], parent, gate1,
       %{content: [%{type: "text", text: "First done."}], finish_reason: "stop"}}
    )

    Fake.push_step(
      fake,
      {:gate, [%{type: :text_delta, text: "Steered run...", metadata: %{}}], parent, gate2,
       %{content: [%{type: "text", text: "Steered done."}], finish_reason: "stop"}}
    )

    {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => projects_dir}, daemon_opts)
    sid = session.session_id

    conn = log_in_owner(conn, owner_token)
    {:ok, view, _html} = live(conn, "/sessions/#{sid}")

    # Configure model and thinking
    view
    |> form("#agent-config-form", %{model: "fake:chat", thinking: "high"})
    |> render_change()

    wait_until(fn ->
      render(view) =~ ~s(value="fake:chat" selected)
    end)

    # Start turn 1
    view
    |> form("#composer-form", %{content: "Initial prompt"})
    |> render_submit()

    assert_receive {:gate_entered, ^gate1, pid1}, 2_000

    # Steer while busy
    wait_until(fn -> has_element?(view, "#steer-btn") end)

    view
    |> form("#composer-form", %{content: "Steer now"})
    |> render_change()

    view
    |> element("#steer-btn")
    |> render_click()

    send(pid1, {:release, gate1})
    assert_receive {:gate_entered, ^gate2, _pid2}, 2_000

    # Abort active steered run
    view
    |> element("#stop-btn")
    |> render_click()

    wait_until(fn ->
      not has_element?(view, "#stop-btn") and render(view) =~ "First done."
    end)

    # Simulate sequence gap -> triggers clean resnapshot without crashing
    send(view.pid, {:commit_frame, 999, JSON.encode!(%{"seq" => 999, "appended_entries" => []})})
    assert render(view) =~ "Initial prompt"

    # Fork from first entry
    view
    |> element("#entries-stream article:first-of-type button[phx-click=\"fork_entry\"]")
    |> render_click()

    patch_path = assert_patch(view)
    assert patch_path =~ ~r"^/sessions/#{Regex.escape(sid)}/conversations/\d+$"
    forked_cid = patch_path |> String.split("/") |> List.last()
    assert forked_cid != "1"
    assert render(view) =~ "conv ##{forked_cid}"
  end

  test "renders parent session breadcrumb on subsessions and toggles hierarchical subsessions in sidebar",
       %{
         conn: conn,
         projects_dir: projects_dir,
         owner_token: owner_token,
         daemon_opts: daemon_opts
       } do
    {:ok, %{session: parent_session}} =
      Daemon.create_session(%{"cwd" => projects_dir, "title" => "Coordinator"}, daemon_opts)

    {:ok, %{session: child_session}} =
      Daemon.create_session(
        %{
          "cwd" => projects_dir,
          "title" => "Worker Lane",
          "role" => "subagent",
          "parent" => %{
            "session_id" => parent_session.session_id,
            "conversation_id" => "1"
          }
        },
        daemon_opts
      )

    conn = log_in_owner(conn, owner_token)
    {:ok, view, _html} = live(conn, "/sessions/#{child_session.session_id}")

    expected_href = "/sessions/#{parent_session.session_id}/conversations/1"

    assert has_element?(
             view,
             ~s(#header-parent-session-link[href="#{expected_href}"]),
             "← Parent session"
           )

    assert has_element?(
             view,
             ~s(#sidebar-parent-lineage a[href="#{expected_href}"]),
             parent_session.session_id
           )

    # Sidebar switcher hides subsessions by default, then reveals them on toggle
    assert has_element?(
             view,
             ~s(#session-sidebar-inbox-tree a[data-session-id="#{parent_session.session_id}"])
           )

    refute has_element?(
             view,
             ~s(#session-sidebar-inbox-tree a[data-session-id="#{child_session.session_id}"])
           )

    assert has_element?(view, "#session-sidebar-subsessions-toggle", "1")
    view |> element("#session-sidebar-subsessions-toggle") |> render_click()

    assert has_element?(
             view,
             ~s(#session-sidebar-inbox-tree .inbox-subsession-list a[data-session-id="#{child_session.session_id}"].is-current)
           )
  end

  test "renders subagent tool_result delegation card with live child status and jump link", %{
    conn: conn,
    projects_dir: projects_dir,
    owner_token: owner_token,
    daemon_opts: daemon_opts
  } do
    catalog = Keyword.fetch!(daemon_opts, :catalog)

    {:ok, %{session: parent_session}} =
      Daemon.create_session(%{"cwd" => projects_dir, "title" => "Parent"}, daemon_opts)

    {:ok, %{session: child_session}} =
      Daemon.create_session(
        %{
          "cwd" => projects_dir,
          "title" => "Explorer Child",
          "role" => "subagent",
          "parent" => %{"session_id" => parent_session.session_id, "conversation_id" => "1"}
        },
        daemon_opts
      )

    {:ok, _} =
      Catalog.report_runtime(catalog, child_session.session_id, %{
        active: true,
        attention: "running",
        activity_kind: "tool",
        activity_label: "bash"
      })

    conn = log_in_owner(conn, owner_token)
    {:ok, view, _html} = live(conn, "/sessions/#{parent_session.session_id}")

    # Inject a committed subagent tool_result frame at next seq (cursor_seq starts at 1)
    commit_json =
      JSON.encode!(%{
        "seq" => 2,
        "appended_entries" => [
          %{
            "id" => "2",
            "kind" => "tool_result",
            "data" => %{
              "name" => "subagent",
              "content" => "Found 3 matching modules.",
              "details" => %{
                "child_session_id" => child_session.session_id,
                "child_conversation_id" => "1",
                "mode" => "wait",
                "read_only" => true,
                "status" => "done"
              }
            }
          }
        ]
      })

    send(view.pid, {:commit_frame, 2, commit_json})

    wait_until(fn ->
      has_element?(
        view,
        ~s(.subagent-card[data-child-session-id="#{child_session.session_id}"])
      )
    end)

    assert has_element?(
             view,
             ~s(.subagent-card[data-child-session-id="#{child_session.session_id}"] .subagent-status-pill),
             "running · bash"
           )

    assert has_element?(
             view,
             ~s(.subagent-card a.subagent-open-link[href="/sessions/#{child_session.session_id}"]),
             "Open subsession →"
           )

    assert has_element?(
             view,
             ~s(.subagent-card[data-child-session-id="#{child_session.session_id}"]),
             "read-only"
           )

    assert has_element?(
             view,
             ~s(.subagent-card[data-child-session-id="#{child_session.session_id}"]),
             "Explorer Child"
           )

    # Also verify ConversationComponents renders subagent tool_call and live_region slots cleanly
    catalog_by_id = %{
      child_session.session_id =>
        CatalogState.normalize_session(%{
          session_id: child_session.session_id,
          title: "Explorer Child",
          attention: "idle",
          parent: %{session_id: parent_session.session_id, conversation_id: "1", depth: 1}
        })
    }

    call_html =
      render_component(&ConversationComponents.entry_body/1,
        entry: %{
          "kind" => "assistant",
          "data" => %{
            "tool_calls" => [
              %{
                "id" => "call_sub_1",
                "name" => "subagent",
                "arguments" => %{
                  "session_id" => child_session.session_id,
                  "mode" => "await",
                  "read_only" => true,
                  "title" => "Check tests",
                  "prompt" => "Inspect catalog state tests"
                }
              }
            ]
          }
        },
        catalog_by_id: catalog_by_id
      )

    assert call_html =~ "subagent-card"
    assert call_html =~ "Check tests"
    assert call_html =~ "Inspect catalog state tests"
    assert call_html =~ "Open subsession →"
    assert call_html =~ "/sessions/#{child_session.session_id}"

    live_html =
      render_component(&ConversationComponents.live_region/1,
        live: %{
          "tools" => [
            %{
              "id" => "call_sub_2",
              "name" => "subagent",
              "status" => "waiting",
              "child_session_id" => child_session.session_id
            }
          ]
        },
        inbox: [],
        catalog_by_id: catalog_by_id
      )

    assert live_html =~ "subagent-card"
    assert live_html =~ "Open subsession →"
    assert live_html =~ "idle"
  end

  defp wait_until(fun, attempts \\ 50)
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
