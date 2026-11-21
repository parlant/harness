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
         %{type: :text_delta, text: "**Partial**\n\n```console\n$ mix test", metadata: %{}}
       ], parent, gate_ref,
       %{
         content: [
           %{type: "text", text: "**Partial answer complete.**\n\n```console\n$ mix test\n```"}
         ],
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
      has_element?(view, "#live-generation strong", "Partial") and
        has_element?(view, "#live-generation .console-block code", "$ mix test")
    end)

    live_html = render(view)
    refute live_html =~ "Checking project files..."
    assert has_element?(view, "#stop-btn")
    assert has_element?(view, "#steer-btn")
    refute has_element?(view, ".tool-call-card")

    # Release gated fake provider to finish turn
    send(gate_pid, {:release, gate_ref})

    wait_until(fn ->
      html = render(view)
      html =~ "Partial answer complete." and not (html =~ "assistant (live)")
    end)

    final_html = render(view)
    assert final_html =~ "Hello fake model"

    assert has_element?(
             view,
             "#entries-stream .entry-assistant strong",
             "Partial answer complete."
           )

    assert has_element?(view, "#entries-stream .console-block code", "$ mix test")
    assert length(Fake.requests(fake)) == 1
  end

  test "provider filters the model list without changing the conversation", ctx do
    id = "example-router:vendor/Exact-Model"

    models =
      Fake.list_models(%{}) ++
        [
          %{
            id: id,
            provider: "example-router",
            provider_name: "Example Model Router",
            name: "Exact Model",
            unavailable_reason: "API key required"
          }
        ]

    opts = Keyword.update!(ctx.daemon_opts, :provider_config, &Map.put(&1, :models, models))
    Application.put_env(:harness_web, :daemon_opts, opts)

    assert {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => ctx.projects_dir}, opts)
    sid = session.session_id
    {:ok, view, _} = live(log_in_owner(ctx.conn, ctx.owner_token), "/sessions/#{sid}")
    assert has_element?(view, ~s(#provider-select option[value="fake"][selected]))
    assert has_element?(view, ~s(#model-select option[value="fake:coder"][selected]))

    view |> form("#provider-filter-form", %{provider: "example-router"}) |> render_change()

    assert has_element?(
             view,
             ~s(#provider-select option[value="example-router"][selected]),
             "Example Model Router"
           )

    assert has_element?(view, "#active-model-note", "fake:coder")
    refute has_element?(view, ~s(#model-select option[value="fake:coder"]))

    assert has_element?(
             view,
             ~s(#model-select option[value="#{id}"]),
             "Exact Model · unavailable"
           )

    # A thinking event includes the model field in the browser form, but does not change it.
    render_change(element(view, "#agent-config-form"), %{
      "_target" => ["thinking"],
      "model" => id,
      "thinking" => "high"
    })

    wait_until(fn -> has_element?(view, ~s(#thinking-select option[value="high"][selected])) end)
    assert has_element?(view, "#active-model-note", "fake:coder")

    render_change(element(view, "#agent-config-form"), %{
      "_target" => ["model"],
      "model" => id,
      "thinking" => "off"
    })

    wait_until(fn -> has_element?(view, ~s(#model-select option[value="#{id}"][selected])) end)
    assert has_element?(view, ~s(#thinking-select option[value="high"][selected]))
    assert has_element?(view, "#model-unavailable-note", "API key required")

    # A fresh view reads the exact qualified model back from the daemon.
    {:ok, new_view, _} = live(log_in_owner(ctx.conn, ctx.owner_token), "/sessions/#{sid}")
    assert has_element?(new_view, ~s(#model-select option[value="#{id}"][selected]))
  end

  test "shows provider backoff as active retrying work and clears it on success", %{
    conn: conn,
    projects_dir: cwd,
    owner_token: token,
    daemon_opts: opts,
    fake: fake
  } do
    gate = make_ref()

    Fake.push_step(
      fake,
      {:error, %{code: "http_429", message: "Monthly spending cap reached", retryable: true}}
    )

    Fake.push_step(
      fake,
      {:gate, [], self(), gate, %{content: [%{type: "text", text: "Recovered after rate limit"}]}}
    )

    {:ok, %{session: session}} =
      Daemon.create_session(%{"cwd" => cwd}, Keyword.put(opts, :retry_backoff_ms, 300))

    {:ok, view, _} = live(log_in_owner(conn, token), "/sessions/#{session.session_id}")
    view |> form("#composer-form", %{content: "Retry this work"}) |> render_submit()
    wait_until(fn -> has_element?(view, "#retry-banner", "Monthly spending cap reached") end)
    assert has_element?(view, "#retry-banner", "Waiting 1s")
    assert has_element?(view, "#stop-btn")
    refute has_element?(view, "#continue-run-btn")
    refute has_element?(view, "#run-failure-banner")
    assert_receive {:gate_entered, ^gate, pid}, 2_000
    wait_until(fn -> has_element?(view, "#retry-banner", "Retry request in progress") end)
    send(pid, {:release, gate})
    wait_until(fn -> has_element?(view, "#entries-stream", "Recovered after rate limit") end)
    refute has_element?(view, "#retry-banner")
    assert length(Fake.requests(fake)) == 2
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
    |> put_submitter("#steer-btn")
    |> render_submit()

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

  test "workspace wait links to the holder and offers cancel and stop-holder actions", %{
    conn: conn,
    projects_dir: cwd,
    owner_token: token,
    daemon_opts: opts,
    fake: fake
  } do
    {:ok, %{session: %{session_id: holder_sid}}} =
      Daemon.create_session(%{"cwd" => cwd, "session_id" => "holder"}, opts)

    {:ok, _} =
      Daemon.execute_command(
        holder_sid,
        %{
          "version" => 1,
          "request_id" => "holder-note",
          "conversation_id" => 1,
          "command" => "submit",
          "args" => %{"type" => "write", "content" => "Holder transcript"}
        },
        opts
      )

    {:ok, %{items: [note]}} = Daemon.scan_entries(holder_sid, 1, %{}, opts)

    {:ok, %{conversation_id: holder_cid}} =
      Daemon.execute_command(
        holder_sid,
        %{
          "version" => 1,
          "request_id" => "holder-fork",
          "conversation_id" => 1,
          "command" => "fork",
          "args" => %{"at_entry_id" => note.id}
        },
        opts
      )

    holder = {holder_sid, String.to_integer(holder_cid)}
    {:ok, canonical_cwd} = H.ExecutionEnv.canonical_path(H.ExecutionEnv.Host.new(cwd), cwd)
    lease_key = {"host", canonical_cwd}
    :ok = H.WorkspaceLease.acquire(opts[:workspace_lease], lease_key, holder, self())

    for call <- ["first", "second"] do
      Fake.push_step(
        fake,
        {:reply, [],
         %{
           content: [],
           tool_calls: [
             %{id: call, name: "write", arguments: %{"path" => "marker", "content" => "ran"}}
           ],
           finish_reason: "tool_calls"
         }}
      )
    end

    Fake.push_step(fake, {:reply, [], %{content: [%{type: "text", text: "Finished waiting"}]}})
    {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => cwd}, opts)
    conn = log_in_owner(conn, token)
    waiter_path = ~p"/sessions/#{session.session_id}?from=inbox"
    holder_path = ~p"/sessions/#{holder_sid}/conversations/#{holder_cid}?from=inbox"
    {:ok, view, _} = live(conn, waiter_path)
    view |> form("#composer-form", %{content: "First attempt"}) |> render_submit()
    wait_until(fn -> has_element?(view, "#workspace-wait") end)

    {:ok, holder_view, _html} =
      view
      |> element("#workspace-holder-link")
      |> render_click()
      |> follow_redirect(conn, holder_path)

    assert has_element?(holder_view, ".header-sid", holder_sid)
    assert has_element?(holder_view, ".session-header .badge", "conv ##{holder_cid}")
    assert has_element?(holder_view, "#header-inbox-link.btn-inbox-return")

    {:ok, view, _} = live(conn, waiter_path)
    assert has_element?(view, "#workspace-wait")
    assert has_element?(view, "#live-activity[data-status=waiting]", "1 activity")
    refute has_element?(view, "#live-activity .activity-spinner")
    refute has_element?(view, "#entries-stream .entry-assistant")
    assert has_element?(view, "#stop-holder-btn", "Stop holder and acquire")
    view |> element("#cancel-wait-btn") |> render_click()
    wait_until(fn -> not has_element?(view, "#workspace-wait") end)
    wait_until(fn -> has_element?(view, "#live-activity[data-status=paused]", "1 activity") end)
    refute File.exists?(Path.join(cwd, "marker"))
    refute_receive {:stop_workspace_holder, _, _, _}, 0

    view |> form("#composer-form", %{content: "Second attempt"}) |> render_submit()
    wait_until(fn -> has_element?(view, "#workspace-wait") end)
    view |> element("#stop-holder-btn") |> render_click()
    assert_receive {:stop_workspace_holder, ^lease_key, ^holder, _}
    :ok = H.WorkspaceLease.release(opts[:workspace_lease], lease_key, holder)
    wait_until(fn -> render(view) =~ "Finished waiting" end)
    refute has_element?(view, "#workspace-wait")

    assert has_element?(
             view,
             "#entries-stream .activity-line[data-status=complete]",
             "1 activity"
           )

    refute has_element?(view, "#entries-stream .entry-tool_result")
    assert File.read!(Path.join(cwd, "marker")) == "ran"
  end

  test "shows a spinner for a tool-only stream, then counts the call and result once", %{
    conn: conn,
    projects_dir: cwd,
    owner_token: token,
    daemon_opts: opts,
    fake: fake
  } do
    parent = self()
    gate_ref = make_ref()

    Fake.push_step(
      fake,
      {:gate,
       [%{type: :tool_call_delta, id: "read-1", name: "read", args_delta: "hidden arguments"}],
       parent, gate_ref,
       %{
         tool_calls: [%{id: "read-1", name: "read", arguments: %{"path" => "missing.txt"}}],
         finish_reason: "tool_calls"
       }}
    )

    Fake.push_step(fake, {:reply, [], %{content: [%{type: "text", text: "Final answer"}]}})

    {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => cwd}, opts)
    {:ok, view, _} = live(log_in_owner(conn, token), "/sessions/#{session.session_id}")
    view |> form("#composer-form", %{content: "A question"}) |> render_submit()
    assert_receive {:gate_entered, ^gate_ref, gate_pid}, 2_000

    wait_until(fn ->
      has_element?(view, "#live-activity[data-status=working] .activity-spinner")
    end)

    assert has_element?(view, "#live-activity", "1 activity")
    refute has_element?(view, "#live-generation")
    refute render(view) =~ "hidden arguments"
    send(gate_pid, {:release, gate_ref})

    wait_until(fn -> has_element?(view, "#entries-stream .entry-assistant", "Final answer") end)
    assert has_element?(view, "#entries-stream .activity-line[data-status=failed]", "1 activity")
    refute has_element?(view, "#entries-stream .activity-spinner")
    refute render(view) =~ "missing.txt"
  end

  test "merges activity across Load earlier without exposing system and tool entries", ctx do
    {:ok, %{session: session}} =
      Daemon.create_session(%{"cwd" => ctx.projects_dir}, ctx.daemon_opts)

    sid = session.session_id
    server = {:via, Registry, {ctx.daemon_opts[:registry], {:session, sid}}}

    entries =
      [%{kind: "user", data: %{"content" => "First **prompt**"}}] ++
        for(_ <- 1..51, do: %{kind: "system", data: %{"content" => "Hidden system text"}}) ++
        [
          %{kind: "tool_result", data: %{"content" => "Hidden tool output", "is_error" => true}},
          %{kind: "assistant", data: %{"content" => "Done"}}
        ]

    assert {:ok, %{seeded: 54}} = H.Session.Server.seed_entries(server, entries)
    {:ok, view, html} = live(log_in_owner(ctx.conn, ctx.owner_token), "/sessions/#{sid}")
    refute html =~ "Hidden"
    refute has_element?(view, ".entry-user")

    assert has_element?(
             view,
             "#entries-stream > .activity-line[data-status=failed]",
             "49 activities"
           )

    view |> element("#load-earlier-btn") |> render_click()

    assert has_element?(view, "#entries-stream > :nth-child(1).entry-user", "First **prompt**")

    assert has_element?(
             view,
             "#entries-stream > :nth-child(2).activity-line[data-status=failed]",
             "52 activities"
           )

    assert has_element?(view, "#entries-stream > :nth-child(3).entry-assistant", "Done")
    refute has_element?(view, "#entries-stream > :nth-child(4)")
    refute has_element?(view, "#load-earlier-btn")
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
