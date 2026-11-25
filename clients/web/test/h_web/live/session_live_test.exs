defmodule HWeb.SessionLiveTest do
  use HWeb.ConnCase, async: false

  alias H.{Catalog, Daemon}
  alias H.Provider.Fake

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

    assert has_element?(
             view,
             ~s(.session-footer > #stop-btn.stop-run-compact[type="button"][phx-click="abort"][aria-label="Stop current run"] svg rect)
           )

    assert has_element?(
             view,
             ~s(#composer-form .composer-send-actions #composer-stop-btn[type="button"][phx-click="abort"][aria-label="Stop current run"] svg rect)
           )

    assert has_element?(view, "#composer-form .composer-send-actions #send-btn", "Queue")

    assert has_element?(
             view,
             ~s(#composer-form .composer-send-actions #steer-btn[name="mode"][value="steer"]),
             "Steer"
           )

    refute has_element?(view, ".tool-call-card")

    # Release gated fake provider to finish turn
    send(gate_pid, {:release, gate_ref})

    wait_until(fn ->
      html = render(view)
      html =~ "Partial answer complete." and not (html =~ "assistant (live)")
    end)

    wait_until(fn ->
      has_element?(view, "#send-btn", "Send") and
        not has_element?(view, "#stop-btn, #composer-stop-btn, #steer-btn")
    end)

    final_html = render(view)
    assert final_html =~ "Hello fake model"

    assert has_element?(
             view,
             "#entries-stream .entry-assistant strong",
             "Partial answer complete."
           )

    assert has_element?(view, "#entries-stream .console-block code", "$ mix test")

    # Below-card toolbars carry raw copy text (plain for user, Markdown for assistant) and edit action
    assert has_element?(
             view,
             ~s(#entries-stream .entry-user footer.entry-toolbar button[data-copy-btn][data-copy-text="Hello fake model"])
           )

    assert has_element?(
             view,
             "#entries-stream .entry-user footer.entry-toolbar button[phx-click=edit_entry]"
           )

    assert has_element?(
             view,
             "#entries-stream .entry-assistant footer.entry-toolbar button[data-copy-btn]"
           )

    raw_assistant_copy =
      final_html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        "#entries-stream .entry-assistant footer.entry-toolbar button[data-copy-btn]"
      )
      |> LazyHTML.attribute("data-copy-text")

    assert raw_assistant_copy == ["**Partial answer complete.**\n\n```console\n$ mix test\n```"]
    assert length(Fake.requests(fake)) == 1
  end

  test "opens the composer on a new session with a compact header and on-demand settings",
       ctx do
    {:ok, %{session: session}} =
      Daemon.create_session(%{cwd: ctx.projects_dir, title: "Release notes"}, ctx.daemon_opts)

    {:ok, view, _} =
      live(log_in_owner(ctx.conn, ctx.owner_token), "/sessions/#{session.session_id}")

    assert has_element?(view, ".app-bar h1", "Release notes")
    assert has_element?(view, ~s(.app-bar button[popovertarget="app-menu"]))
    assert has_element?(view, ~s(.app-bar button[popovertarget="session-actions"]))

    assert has_element?(
             view,
             ~s(.app-bar button[aria-controls="session-details"][aria-expanded="false"])
           )

    assert has_element?(view, "aside#session-details[hidden] #session-tags-form")
    refute has_element?(view, ".app-bar .inbox-caret")
    refute has_element?(view, ".app-bar > a")
    refute has_element?(view, ".app-bar select")
    refute has_element?(view, "#transcript-scroll #composer-form")
    assert has_element?(view, "details#reply[open]")
    assert has_element?(view, "details#reply #composer-form textarea[name=content]")
    assert has_element?(view, ~s(#composer-form [data-open-panel="agent-options"]))
    assert has_element?(view, "dialog#agent-options #agent-config-form")
    refute has_element?(view, "#composer-form select")
  end

  test "New creates an empty session in the same folder without starting work", ctx do
    {:ok, %{session: session}} =
      Daemon.create_session(%{cwd: ctx.projects_dir, title: "Release notes"}, ctx.daemon_opts)

    conn = log_in_owner(ctx.conn, ctx.owner_token)
    {:ok, view, _} = live(conn, "/sessions/#{session.session_id}?from=inbox")

    {:error, {:live_redirect, %{to: path}}} =
      view |> element("#session-actions #session-new-button") |> render_click()

    uri = URI.parse(path)
    sid = String.replace_prefix(uri.path, "/sessions/", "")
    assert sid != session.session_id
    assert uri.query == "from=inbox"
    {:ok, %{session: new_session}} = Daemon.get_session_detail(sid, ctx.daemon_opts)
    assert {new_session.env_id, new_session.cwd} == {session.env_id, session.cwd}
    {:ok, new_view, _} = live(conn, path)
    assert has_element?(new_view, "#reply[open]")
    refute has_element?(new_view, "#entries-stream > *")
    assert Fake.requests(ctx.fake) == []
  end

  test "session tags add and remove in place, report invalid tags, and survive reopening", ctx do
    {:ok, %{session: session}} =
      Daemon.create_session(%{cwd: ctx.projects_dir, tags: ["keep"]}, ctx.daemon_opts)

    conn = log_in_owner(ctx.conn, ctx.owner_token)
    path = "/sessions/#{session.session_id}"
    {:ok, view, _} = live(conn, path)

    view |> form("#session-tags-form", %{tags: " added tag, keep, "}) |> render_submit()
    assert has_element?(view, ~s(#session-tags-form button[aria-label="Remove tag added tag"]))
    assert has_element?(view, ~s(#session-tags-form button[aria-label="Remove tag keep"]))

    assert view
           |> form("#session-tags-form", %{tags: String.duplicate("a", 65)})
           |> render_submit() =~ "must be 1–64 characters without commas or control characters"

    view |> element(~s(#session-tags-form button[aria-label="Remove tag keep"])) |> render_click()
    refute has_element?(view, "#session-tags-form [role=alert]")

    {:ok, reopened, _} = live(conn, path)

    assert has_element?(
             reopened,
             ~s(#session-tags-form button[aria-label="Remove tag added tag"])
           )

    refute has_element?(reopened, ~s(#session-tags-form button[aria-label="Remove tag keep"]))
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

    # Abort active steered run from the composer, without submitting the draft.
    view
    |> element("#composer-stop-btn")
    |> render_click()

    wait_until(fn ->
      not has_element?(view, "#stop-btn") and render(view) =~ "First done."
    end)

    # Simulate sequence gap -> triggers clean resnapshot without crashing
    send(view.pid, {:commit_frame, 999, JSON.encode!(%{"seq" => 999, "appended_entries" => []})})
    assert render(view) =~ "Initial prompt"

    # Fork from the first assistant reply (the aborted generation may also have a row).
    [assistant_id | _] =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#entries-stream .entry-assistant")
      |> LazyHTML.attribute("id")

    view
    |> element("##{assistant_id} .fork-btn")
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
             parent_session.session_id
           )

    assert has_element?(
             view,
             ~s(#sidebar-parent-lineage a[href="#{expected_href}"]),
             parent_session.session_id
           )

    {:ok, %{session: sibling}} =
      Daemon.create_session(
        %{
          "cwd" => projects_dir,
          "role" => "subagent",
          "parent" => %{"session_id" => parent_session.session_id, "conversation_id" => "1"}
        },
        daemon_opts
      )

    # A sibling in the same folder can be shown, but not the session already open.
    assert has_element?(
             view,
             ~s(#session-sidebar-inbox-tree a[data-session-id="#{parent_session.session_id}"])
           )

    refute has_element?(
             view,
             ~s(#session-sidebar-inbox-tree a[data-session-id="#{child_session.session_id}"])
           )

    wait_until(fn -> has_element?(view, "#session-sidebar-subsessions-toggle", "1") end)

    refute has_element?(
             view,
             ~s(#session-sidebar-inbox-tree a[data-session-id="#{sibling.session_id}"])
           )

    view |> element("#session-sidebar-subsessions-toggle") |> render_click()

    assert has_element?(
             view,
             ~s(#session-sidebar-inbox-tree .inbox-subsession-list a[data-session-id="#{sibling.session_id}"])
           )

    refute has_element?(
             view,
             ~s(#session-sidebar-inbox-tree a[data-session-id="#{child_session.session_id}"])
           )
  end

  test "Edit preloads a user prompt and sends its replacement on a fork, not the original branch",
       ctx do
    for reply <- ["Prefix reply", "Original reply", "Fork reply"] do
      Fake.push_step(ctx.fake, {:reply, [], %{content: reply}})
    end

    {:ok, %{session: session}} =
      Daemon.create_session(%{"cwd" => ctx.projects_dir}, ctx.daemon_opts)

    path = "/sessions/#{session.session_id}"
    conn = log_in_owner(ctx.conn, ctx.owner_token)
    {:ok, view, _} = live(conn, path)

    for {prompt, reply} <- [{"Prefix", "Prefix reply"}, {"Original prompt", "Original reply"}] do
      view |> form("#composer-form", %{content: prompt}) |> render_submit()
      wait_until(fn -> has_element?(view, ".entry-assistant", reply) end)
    end

    view |> form("#composer-form", %{content: "Unrelated draft"}) |> render_change()
    doc = LazyHTML.from_fragment(render(view))

    [_, original_id] =
      LazyHTML.query(doc, ".entry-user .edit-btn") |> LazyHTML.attribute("phx-value-entry_id")

    edit = element(view, ~s(.entry-user .edit-btn[phx-value-entry_id="#{original_id}"]), "Edit")
    render_click(edit)
    assert_push_event(view, "set_draft", %{text: "Original prompt", open_reply: true})
    assert has_element?(view, "#fork-edit-banner", "Editing prompt ##{original_id}")
    refute has_element?(view, ".entry-user .fork-btn")

    render_submit(view, "submit", %{
      "destination" => "#{session.session_id}:1",
      "content" => "Stale"
    })

    assert length(Fake.requests(ctx.fake)) == 2

    view |> element("#cancel-fork-edit-btn") |> render_click()
    assert_push_event(view, "set_draft", %{text: "Unrelated draft"})
    refute has_element?(view, "#fork-edit-banner")
    render_click(edit)

    # Command-looking text is still a prompt when editing.
    view |> form("#composer-form", %{content: "/tree revised"}) |> render_submit()
    assert assert_patch(view) =~ ~r"^#{Regex.escape(path)}/conversations/\d+$"
    wait_until(fn -> has_element?(view, ".entry-assistant", "Fork reply") end)
    assert has_element?(view, ".entry-user", "Prefix")
    assert has_element?(view, ".entry-user", "/tree revised")
    refute has_element?(view, ".entry-user", "Original prompt")
    refute has_element?(view, ".entry-assistant", "Original reply")

    {:ok, original, _} = live(conn, path)
    assert has_element?(original, ".entry-user", "Original prompt")
    assert has_element?(original, ".entry-assistant", "Original reply")
    refute has_element?(original, ".entry-user", "/tree revised")
  end

  test "editing the first prompt creates a new session in the same workspace on Send", ctx do
    Fake.push_step(ctx.fake, {:reply, [], %{content: "First answer"}})
    Fake.push_step(ctx.fake, {:reply, [], %{content: "New answer"}})

    {:ok, %{session: session}} =
      Daemon.create_session(%{"cwd" => ctx.projects_dir}, ctx.daemon_opts)

    conn = log_in_owner(ctx.conn, ctx.owner_token)
    path = "/sessions/#{session.session_id}"
    {:ok, view, _} = live(conn, path)

    view |> form("#composer-form", %{content: "First prompt"}) |> render_submit()
    wait_until(fn -> has_element?(view, ".entry-assistant", "First answer") end)
    view |> element(".entry-user .edit-btn") |> render_click()
    assert_push_event(view, "set_draft", %{text: "First prompt", open_reply: true})
    assert has_element?(view, "#fork-edit-banner", "will start a new session")
    assert length(Fake.requests(ctx.fake)) == 1

    assert {:error, {:live_redirect, %{to: new_path}}} =
             view |> form("#composer-form", %{content: "New first prompt"}) |> render_submit()

    assert new_path != path
    {:ok, fork, _} = live(conn, new_path)
    wait_until(fn -> has_element?(fork, ".entry-assistant", "New answer") end)
    assert has_element?(fork, ".entry-user", "New first prompt")

    assert {:ok, %{session: new_session}} =
             Daemon.get_session_detail(
               String.replace_prefix(URI.parse(new_path).path, "/sessions/", ""),
               ctx.daemon_opts
             )

    assert {new_session.env_id, new_session.cwd} == {session.env_id, session.cwd}
  end

  test "updates one subagent bubble and keeps the surrounding assistant prose separate", ctx do
    {:ok, %{session: parent}} =
      Daemon.create_session(%{"cwd" => ctx.projects_dir, "title" => "Parent"}, ctx.daemon_opts)

    {:ok, %{session: child}} =
      Daemon.create_session(
        %{
          "cwd" => ctx.projects_dir,
          "title" => "Explorer Child",
          "role" => "subagent",
          "parent" => %{"session_id" => parent.session_id, "conversation_id" => "1"}
        },
        ctx.daemon_opts
      )

    catalog = Keyword.fetch!(ctx.daemon_opts, :catalog)
    prompt = "Inspect the project modules."
    prose = "I’ll keep the existing attachment flow."
    call_id = "call_sub_1"

    {:ok, view, _} =
      live(log_in_owner(ctx.conn, ctx.owner_token), "/sessions/#{parent.session_id}")

    send_commit(
      view,
      2,
      [
        %{
          id: "2",
          kind: "assistant",
          data: %{
            text: prose,
            tool_calls: [
              %{id: call_id, name: "subagent", arguments: %{prompt: prompt, title: "Check tests"}}
            ]
          }
        }
      ],
      %{"tools" => %{call_id => %{name: "subagent", status: "pending"}}}
    )

    bubble = "#entry-subagent-call-2-0"
    assert has_element?(view, "#entry-2.entry-assistant .markdown", prose)
    refute has_element?(view, "#entry-2 .subagent-card")
    assert has_element?(view, bubble <> " .subagent-status-pill", "pending")

    send_commit(view, 3, [], %{
      "tools" => %{
        call_id => %{name: "subagent", status: "waiting", child_session_id: child.session_id}
      }
    })

    assert {:ok, _} =
             Catalog.report_runtime(catalog, child.session_id, %{
               active: true,
               attention: "running",
               activity_kind: "tool",
               activity_label: "read"
             })

    wait_until(fn -> has_element?(view, bubble <> " .subagent-status-pill", "running") end)
    refute has_element?(view, bubble, "running · read")
    assert has_element?(view, bubble <> " .subagent-card-title", "Check tests")
    assert has_element?(view, bubble <> " .subagent-card-preview", prompt)

    assert has_element?(
             view,
             bubble <> ~s( footer .fork-btn + a[href="/sessions/#{child.session_id}"]),
             "Open subsession"
           )

    refute has_element?(view, "#live-subagents, #live-activity")

    send_commit(
      view,
      4,
      [
        %{
          id: "4",
          kind: "tool_result",
          data: %{
            tool_call_id: call_id,
            name: "subagent",
            content: "Found 3 matching modules.",
            details: %{child_session_id: child.session_id, status: "placed"}
          }
        },
        %{id: "5", kind: "assistant", data: %{text: "I’ll review the findings."}}
      ],
      %{}
    )

    assert {:ok, _} =
             Catalog.report_runtime(catalog, child.session_id, %{active: false, attention: "idle"})

    wait_until(fn -> has_element?(view, bubble <> " .subagent-status-pill", "idle") end)
    assert has_element?(view, bubble <> ~s( footer [data-copy-text="#{prompt}"]))
    assert has_element?(view, bubble <> ~s( footer .fork-btn[phx-value-entry_id="4"]))

    html = render(view)
    doc = LazyHTML.from_fragment(html)

    assert LazyHTML.query(doc, "#entries-stream > *") |> LazyHTML.attribute("id") ==
             ["entry-2", "entry-subagent-call-2-0", "entry-5"]

    assert LazyHTML.query(doc, bubble <> " .badge") |> LazyHTML.text() == "subagentidle"
    refute html =~ "Subagent Output"
    refute html =~ "Found 3 matching modules."
  end

  test "loading earlier subagent calls replaces the result-only bubble with the original prompt",
       ctx do
    {:ok, %{session: session}} =
      Daemon.create_session(%{"cwd" => ctx.projects_dir}, ctx.daemon_opts)

    sid = session.session_id
    server = {:via, Registry, {ctx.daemon_opts[:registry], {:session, sid}}}

    assert {:ok, _} =
             H.Session.Server.seed_entries(
               server,
               [
                 %{
                   kind: "assistant",
                   data: %{
                     "text" => "Delegating",
                     "tool_calls" => [
                       %{
                         "name" => "subagent",
                         "id" => "delegate",
                         "arguments" => %{"title" => "Worker", "prompt" => "Original task"}
                       }
                     ]
                   }
                 }
               ] ++
                 List.duplicate(%{kind: "system", data: %{}}, 50) ++
                 [
                   %{
                     kind: "tool_result",
                     data: %{
                       "name" => "subagent",
                       "tool_call_id" => "delegate",
                       "details" => %{"child_session_id" => "worker"}
                     }
                   }
                 ]
             )

    {:ok, view, _} = live(log_in_owner(ctx.conn, ctx.owner_token), "/sessions/#{sid}")
    assert has_element?(view, "article[id^=entry-subagent-result-] .subagent-status-pill", "done")
    refute has_element?(view, ".entry-subagent [data-copy-btn]")

    view |> element("#load-earlier-btn") |> render_click()
    refute has_element?(view, "article[id^=entry-subagent-result-]")
    assert has_element?(view, ".entry-assistant .markdown", "Delegating")
    assert has_element?(view, ".entry-subagent .subagent-card-title", "Worker")
    assert has_element?(view, ~s(.entry-subagent [data-copy-text="Original task"]))
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

    assert has_element?(holder_view, "#session-details .session-id-label", holder_sid)
    assert has_element?(holder_view, "#session-details .badge", "conv ##{holder_cid}")
    assert has_element?(holder_view, ~s(#app-menu a[href="/inbox"]))

    {:ok, view, _} = live(conn, waiter_path)
    assert has_element?(view, "#workspace-wait")
    assert has_element?(view, "#live-activity[data-status=waiting] summary", "1 tool call")
    refute has_element?(view, "#live-activity .activity-spinner")
    refute has_element?(view, "#entries-stream .entry-assistant")
    assert has_element?(view, "#stop-holder-btn", "Stop holder and acquire")
    view |> element("#cancel-wait-btn") |> render_click()
    wait_until(fn -> not has_element?(view, "#workspace-wait") end)

    wait_until(fn ->
      has_element?(view, "#live-activity[data-status=paused] summary", "1 tool call")
    end)

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
             "#entries-stream .activity-line summary",
             "1 tool call"
           )

    refute has_element?(view, "#entries-stream .entry-tool_result")
    assert File.read!(Path.join(cwd, "marker")) == "ran"
  end

  test "spins during tool work and only shows the count until calls are inspected", %{
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
      has_element?(view, "#live-activity[data-status=working] .activity-spinner") and
        has_element?(view, "#live-activity details:not([open]) > summary", "1 tool call")
    end)

    refute has_element?(view, "#live-generation")
    refute render(view) =~ "hidden arguments"

    view |> element("#live-activity button", "read") |> render_click()
    assert_push_event(view, "open_panel", %{id: "tool-inspection"})
    assert has_element?(view, "#tool-inspection pre", "hidden arguments")
    send(gate_pid, {:release, gate_ref})

    wait_until(fn -> has_element?(view, "#entries-stream .entry-assistant", "Final answer") end)
    assert has_element?(view, "#entries-stream .activity-line summary", "1 tool call")
    refute has_element?(view, "#entries-stream .activity-spinner")
    refute render(view) =~ "missing.txt"

    view |> element("#entries-stream .activity-line button", "read") |> render_click()
    assert has_element?(view, "#tool-inspection pre", ~s("path": "missing.txt"))
    assert has_element?(view, "#tool-inspection pre", "Failed to read missing.txt")
  end

  test "merges calls and results across Load earlier without exposing tool bodies up front",
       ctx do
    {:ok, %{session: session}} =
      Daemon.create_session(%{"cwd" => ctx.projects_dir}, ctx.daemon_opts)

    sid = session.session_id
    server = {:via, Registry, {ctx.daemon_opts[:registry], {:session, sid}}}

    entries =
      [
        %{kind: "user", data: %{"content" => "First **prompt**"}},
        %{
          kind: "assistant",
          data: %{
            "tool_calls" => [
              %{"id" => "read-1", "name" => "read", "arguments" => %{"path" => "a.txt"}},
              %{"id" => "read-2", "name" => "read", "arguments" => %{"path" => "b.txt"}}
            ]
          }
        }
      ] ++
        for(_ <- 1..50, do: %{kind: "system", data: %{"content" => "Hidden system text"}}) ++
        [
          %{
            kind: "tool_result",
            data: %{"tool_call_id" => "read-2", "name" => "read", "content" => "Hidden success"}
          },
          %{
            kind: "tool_result",
            data: %{
              "tool_call_id" => "read-1",
              "name" => "read",
              "content" => "Hidden <script>bad()</script>",
              "is_error" => true
            }
          },
          %{kind: "assistant", data: %{"content" => "Done"}}
        ]

    assert {:ok, %{seeded: 55}} = H.Session.Server.seed_entries(server, entries)
    {:ok, view, html} = live(log_in_owner(ctx.conn, ctx.owner_token), "/sessions/#{sid}")
    refute html =~ "Hidden"
    refute has_element?(view, ".entry-user")

    assert has_element?(
             view,
             "#entries-stream > .activity-line summary",
             "2 tool calls"
           )

    view |> element("#entries-stream .activity-line li:first-child button") |> render_click()
    assert has_element?(view, "#tool-inspection pre", "Hidden success")
    refute has_element?(view, "#tool-inspection pre", "b.txt")

    view |> element("#load-earlier-btn") |> render_click()

    assert has_element?(view, "#entries-stream > :nth-child(1).entry-user", "First **prompt**")

    assert has_element?(
             view,
             "#entries-stream > :nth-child(2).activity-line summary",
             "2 tool calls"
           )

    view |> element("#entries-stream .activity-line li:first-child button") |> render_click()
    assert has_element?(view, "#tool-inspection pre", ~s("path": "a.txt"))
    assert has_element?(view, "#tool-inspection pre", "Hidden <script>bad()</script>")
    refute has_element?(view, "#tool-inspection script")

    view |> element("#entries-stream .activity-line li:nth-child(2) button") |> render_click()
    assert has_element?(view, "#tool-inspection pre", ~s("path": "b.txt"))
    assert has_element?(view, "#tool-inspection pre", "Hidden success")

    assert LazyHTML.text(
             LazyHTML.query(
               LazyHTML.from_fragment(render(view)),
               "#entries-stream .activity-line summary"
             )
           )
           |> String.trim() == "2 tool calls"

    assert has_element?(view, "#entries-stream > :nth-child(3).entry-assistant", "Done")
    refute has_element?(view, "#entries-stream > :nth-child(4)")
    refute has_element?(view, "#load-earlier-btn")
  end

  defp send_commit(view, seq, entries, live) do
    json =
      JSON.encode!(%{seq: seq, appended_entries: entries, doc_ops: %{live: [["replace", live]]}})

    send(view.pid, {:commit_frame, seq, json})
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
