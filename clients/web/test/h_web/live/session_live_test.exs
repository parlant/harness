defmodule HWeb.SessionLiveTest do
  use HWeb.ConnCase, async: false

  alias H.Daemon
  alias H.Provider.Fake

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

  test "workspace wait offers cancel and stop-holder actions and resumes on release", %{
    conn: conn,
    projects_dir: cwd,
    owner_token: token,
    daemon_opts: opts,
    fake: fake
  } do
    :ok = H.WorkspaceLease.acquire(opts[:workspace_lease], {"host", cwd}, {"holder", 1}, self())

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
    {:ok, view, _} = live(log_in_owner(conn, token), "/sessions/#{session.session_id}")
    view |> form("#composer-form", %{content: "First attempt"}) |> render_submit()
    wait_until(fn -> has_element?(view, "#workspace-wait") end)
    assert render(view) =~ "holder"
    assert has_element?(view, "#stop-holder-btn", "Stop holder and acquire")
    view |> element("#cancel-wait-btn") |> render_click()
    wait_until(fn -> not has_element?(view, "#workspace-wait") end)
    refute File.exists?(Path.join(cwd, "marker"))
    refute_receive {:stop_workspace_holder, _, _, _}, 0

    view |> form("#composer-form", %{content: "Second attempt"}) |> render_submit()
    wait_until(fn -> has_element?(view, "#workspace-wait") end)
    view |> element("#stop-holder-btn") |> render_click()
    assert_receive {:stop_workspace_holder, {"host", ^cwd}, {"holder", 1}, _}
    :ok = H.WorkspaceLease.release(opts[:workspace_lease], {"host", cwd}, {"holder", 1})
    wait_until(fn -> render(view) =~ "Finished waiting" end)
    refute has_element?(view, "#workspace-wait")
    assert File.read!(Path.join(cwd, "marker")) == "ran"
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
