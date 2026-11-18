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
