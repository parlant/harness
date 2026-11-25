defmodule HWeb.SessionCommandAndTreeTest do
  use HWeb.ConnCase, async: false

  alias H.Daemon
  alias H.Provider.Fake
  alias HWeb.Backend

  import Phoenix.LiveViewTest

  defp wait_until(fun, attempts \\ 60)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until_idle(view, expected_text) do
    wait_until(fn ->
      html = render(view)
      html =~ expected_text and not has_element?(view, "#stop-btn")
    end)
  end

  test "slash commands configure model/thinking, approval policy, budget, harness, approve/deny/abort, rename, triage, fork cwd, create new session, and reject unknown commands without calling LLM",
       %{
         conn: conn,
         projects_dir: projects_dir,
         owner_token: owner_token,
         daemon_opts: daemon_opts,
         fake: fake
       } do
    target_dir = Path.join(projects_dir, "fork-target") |> Path.expand()
    File.mkdir_p!(target_dir)

    {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => projects_dir}, daemon_opts)
    sid = session.session_id

    conn = log_in_owner(conn, owner_token)
    {:ok, view, _html} = live(conn, "/sessions/#{sid}")

    # Unknown slash command must never reach the fake provider
    view
    |> form("#composer-form", %{content: "/bogus-cmd"})
    |> render_submit()

    assert has_element?(view, "#session-error-banner", "Unknown command /bogus-cmd")
    assert Fake.requests(fake) == []

    # /thinking high
    view
    |> form("#composer-form", %{content: "/thinking high"})
    |> render_submit()

    wait_until(fn -> has_element?(view, ~s(#thinking-select option[value="high"][selected])) end)
    assert has_element?(view, "#session-info-banner", "Reasoning effort set to high.")

    # /harness
    view
    |> form("#composer-form", %{content: "/harness"})
    |> render_submit()

    assert has_element?(view, "#session-info-banner", "Harness: coding")
    assert has_element?(view, "#hdr-harness", "harness: coding")

    # /approval mutating and /approval
    view
    |> form("#composer-form", %{content: "/approval mutating"})
    |> render_submit()

    wait_until(fn -> has_element?(view, "#current-approval-policy", "mutating") end)
    assert has_element?(view, "#session-info-banner", "Approval policy set to mutating.")

    view
    |> form("#composer-form", %{content: "/approval"})
    |> render_submit()

    assert has_element?(view, "#session-info-banner", "Approval policy: mutating")

    # /budget turns=3 cost=0.5 and /budget clear
    view
    |> form("#composer-form", %{content: "/budget turns=3 cost=0.5"})
    |> render_submit()

    wait_until(fn -> has_element?(view, "#current-run-budget", "turns=3") end)
    assert has_element?(view, "#session-info-banner", "Budget set: turns=3, cost=$0.5.")

    view
    |> form("#composer-form", %{content: "/budget clear"})
    |> render_submit()

    wait_until(fn -> has_element?(view, "#current-run-budget", "none") end)
    assert has_element?(view, "#session-info-banner", "Budget cleared.")

    # /approve, /deny, and /abort <task_id> usage/error handling without calling LLM
    view
    |> form("#composer-form", %{content: "/approve"})
    |> render_submit()

    assert has_element?(view, "#session-error-banner", "Usage: /approve <task_id>")

    view
    |> form("#composer-form", %{content: "/deny 9999 nope"})
    |> render_submit()

    assert has_element?(view, "#session-error-banner", "Not found")

    view
    |> form("#composer-form", %{content: "/abort 9999"})
    |> render_submit()

    assert has_element?(view, "#session-error-banner", "Not found")
    assert Fake.requests(fake) == []

    # Agent panel forms configure approval_policy and budget
    view
    |> form("#approval-policy-form", %{approval_policy: "tools=bash,write_file"})
    |> render_submit()

    wait_until(fn -> has_element?(view, "#current-approval-policy", "bash, write_file") end)

    view
    |> form("#budget-config-form", %{max_turns: "5", max_cost_usd: "2.5", max_elapsed_ms: "15000"})
    |> render_submit()

    wait_until(fn -> has_element?(view, "#current-run-budget", "turns=5") end)

    view
    |> element("#clear-budget-btn")
    |> render_click()

    wait_until(fn -> has_element?(view, "#current-run-budget", "none") end)

    # /model fake:chat
    view
    |> form("#composer-form", %{content: "/model fake:chat"})
    |> render_submit()

    wait_until(fn ->
      has_element?(view, ~s(#model-select option[value="fake:chat"][selected]))
    end)

    # /name New Title
    view
    |> form("#composer-form", %{content: "/name New Title"})
    |> render_submit()

    assert has_element?(view, ".app-bar h1", "New Title")
    assert has_element?(view, "#session-info-banner", "New Title")

    # /attention off
    view
    |> form("#composer-form", %{content: "/attention off"})
    |> render_submit()

    assert has_element?(view, "#session-info-banner", "marked as read")
    {:ok, detail} = Backend.get_session_detail(sid)
    assert detail.session.needs_attention == false

    # /cwd (no arg) shows workspace status
    view
    |> form("#composer-form", %{content: "/cwd"})
    |> render_submit()

    assert has_element?(view, "#session-info-banner", "Workspace: host:")

    # /cwd fork-target (relative path) forks into target_dir and navigates
    {:error, {:live_redirect, %{to: forked_path}}} =
      view
      |> form("#composer-form", %{content: "/cwd fork-target"})
      |> render_submit()

    assert forked_path =~ ~r"^/sessions/"

    forked_sid =
      forked_path |> URI.parse() |> Map.fetch!(:path) |> String.replace_prefix("/sessions/", "")

    assert forked_sid != sid
    {:ok, forked_detail} = Backend.get_session_detail(forked_sid)
    assert Path.expand(forked_detail.session.cwd) == target_dir

    # /new creates a fresh session in the same workspace
    {:ok, view2, _html} = live(conn, forked_path)

    {:error, {:live_redirect, %{to: new_path}}} =
      view2
      |> form("#composer-form", %{content: "/new"})
      |> render_submit()

    assert new_path =~ ~r"^/sessions/"
    assert new_path != forked_path
    assert Fake.requests(fake) == []
  end

  test "/tree renders turn steps across forked conversations, branches from a sibling node, and edits an earlier user prompt via fork_and_submit",
       %{
         conn: conn,
         projects_dir: projects_dir,
         owner_token: owner_token,
         daemon_opts: daemon_opts,
         fake: fake
       } do
    Fake.push_step(fake, {:reply, [], %{content: "First reply", finish_reason: "stop"}})
    Fake.push_step(fake, {:reply, [], %{content: "Second reply on main", finish_reason: "stop"}})
    Fake.push_step(fake, {:reply, [], %{content: "Edited branch reply", finish_reason: "stop"}})

    {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => projects_dir}, daemon_opts)
    sid = session.session_id

    conn = log_in_owner(conn, owner_token)
    {:ok, view, _html} = live(conn, "/sessions/#{sid}")

    # Turn 1
    view |> form("#composer-form", %{content: "Prompt one"}) |> render_submit()
    wait_until_idle(view, "First reply")

    # Turn 2
    view |> form("#composer-form", %{content: "Prompt two"}) |> render_submit()
    wait_until_idle(view, "Second reply on main")

    # Open /tree via slash command
    view |> form("#composer-form", %{content: "/tree"}) |> render_submit()
    assert_push_event(view, "open_panel", %{id: "session-tree-panel"})

    assert has_element?(view, "#session-tree-list", "Prompt one")
    assert has_element?(view, "#session-tree-list", "First reply")
    assert has_element?(view, "#session-tree-list", "Prompt two")
    assert has_element?(view, "#session-tree-list", "Second reply on main")

    # Filter to user-only
    view |> element("#tree-filter-user-only") |> render_click()
    assert has_element?(view, "#session-tree-list", "Prompt one")
    assert has_element?(view, "#session-tree-list", "Prompt two")
    refute has_element?(view, "#session-tree-list", "First reply")

    # Switch back to default filter
    view |> element("#tree-filter-default") |> render_click()

    # Find entry IDs from Backend.get_session_tree
    {:ok, tree} = Backend.get_session_tree(sid)
    user2 = Enum.find(tree.nodes, &(&1.kind == "user" and &1.preview == "Prompt two"))
    asst1 = Enum.find(tree.nodes, &(&1.kind == "assistant" and &1.preview == "First reply"))
    assert user2 != nil
    assert asst1 != nil

    # Edit & fork Prompt two from the tree panel
    view
    |> element(~s(#tree-node-#{user2.id} button[phx-click="tree_edit_user_step"]))
    |> render_click()

    assert_push_event(view, "close_panel", %{id: "session-tree-panel"})
    assert_push_event(view, "set_draft", %{text: "Prompt two", open_reply: true})
    assert has_element?(view, "#fork-edit-banner", "Editing prompt ##{user2.id}")
    assert has_element?(view, "#fork-edit-banner", "will branch at ##{asst1.id}")

    # Submit edited prompt -> fork_and_submit creates a new conversation and patches URL
    view
    |> form("#composer-form", %{content: "Prompt two revised"})
    |> render_submit()

    patched_url = assert_patch(view)

    assert [_, forked_cid] =
             Regex.run(~r"^/sessions/#{Regex.escape(sid)}/conversations/(\d+)$", patched_url)

    assert forked_cid != "1"
    wait_until_idle(view, "Edited branch reply")
    refute has_element?(view, "#fork-edit-banner")

    # Open /tree again from header button and verify both branches + sibling branching
    view |> element("#session-tree-button") |> render_click()
    assert_push_event(view, "open_panel", %{id: "session-tree-panel"})
    assert has_element?(view, "#session-tree-list", "conv ##{forked_cid} (current)")
    assert has_element?(view, "#session-tree-list", "conv #1")
    assert has_element?(view, "#session-tree-list", "Prompt two revised")
    assert has_element?(view, "#session-tree-list", "Second reply on main")

    # Branch from a sibling branch node (the leaf of conv #1 while currently viewing forked_cid)
    asst2 =
      Enum.find(tree.nodes, &(&1.kind == "assistant" and &1.preview == "Second reply on main"))

    view
    |> element(~s(#tree-node-#{asst2.id} button[phx-click="tree_branch_at"]))
    |> render_click()

    branch3_url = assert_patch(view)

    assert [_, branch3_cid] =
             Regex.run(~r"^/sessions/#{Regex.escape(sid)}/conversations/(\d+)$", branch3_url)

    assert branch3_cid not in ["1", forked_cid]
  end

  test "complete_path and WorkspaceLive complete_directory return scoped directory and @file completions",
       %{
         conn: conn,
         projects_dir: projects_dir,
         owner_token: owner_token,
         daemon_opts: daemon_opts
       } do
    sub_a = Path.join(projects_dir, "alpha-dir")
    sub_b = Path.join(projects_dir, "beta-dir")
    File.mkdir_p!(Path.join(sub_a, "nested"))
    File.mkdir_p!(sub_b)
    File.write!(Path.join(projects_dir, "hello.ex"), "defmodule Hello, do: :ok\n")

    {:ok, %{session: session}} = Daemon.create_session(%{"cwd" => projects_dir}, daemon_opts)
    sid = session.session_id

    conn = log_in_owner(conn, owner_token)
    {:ok, view, _html} = live(conn, "/sessions/#{sid}")

    assert has_element?(view, ~s(#prompt-input-completion[phx-update="ignore"]))

    # Directory completion for /cwd al
    render_hook(view, "complete_path", %{
      "lookup_id" => 1,
      "target_id" => "prompt-input",
      "kind" => "directory",
      "prefix" => "al"
    })

    assert_push_event(view, "completion_results", %{
      lookup_id: 1,
      target_id: "prompt-input",
      kind: "directory",
      items: [%{value: "alpha-dir/", label: "alpha-dir/", kind: "dir"}]
    })

    # Chained directory completion inside alpha-dir/
    render_hook(view, "complete_path", %{
      "lookup_id" => 2,
      "target_id" => "prompt-input",
      "kind" => "directory",
      "prefix" => "alpha-dir/"
    })

    assert_push_event(view, "completion_results", %{
      lookup_id: 2,
      target_id: "prompt-input",
      kind: "directory",
      items: [%{value: "alpha-dir/nested/", label: "nested/", kind: "dir"}]
    })

    # Workspace @file completion
    render_hook(view, "complete_path", %{
      "lookup_id" => 3,
      "target_id" => "prompt-input",
      "kind" => "workspace_file",
      "prefix" => "hel"
    })

    assert_push_event(view, "completion_results", %{
      lookup_id: 3,
      target_id: "prompt-input",
      kind: "workspace_file",
      items: [%{value: "hello.ex", label: "hello.ex", kind: "file"}]
    })

    render_hook(view, "complete_path", %{
      "lookup_id" => 4,
      "target_id" => "prompt-input",
      "kind" => "workspace_file",
      "prefix" => "alp"
    })

    assert_push_event(view, "completion_results", %{
      lookup_id: 4,
      kind: "workspace_file",
      items: [%{value: "alpha-dir/", kind: "dir"}]
    })

    render_hook(view, "complete_path", %{
      "lookup_id" => 5,
      "target_id" => "prompt-input",
      "kind" => "workspace_file",
      "prefix" => "alpha-dir/"
    })

    assert_push_event(view, "completion_results", %{
      lookup_id: 5,
      kind: "workspace_file",
      items: [%{value: "alpha-dir/nested/", kind: "dir"}]
    })

    # WorkspaceLive directory completion
    {:ok, ws_view, _html} = live(conn, "/")

    render_hook(ws_view, "complete_directory", %{
      "lookup_id" => 10,
      "target_id" => "workspace-path-input",
      "prefix" => Path.expand(projects_dir) <> "/be"
    })

    expected_beta = Path.expand(projects_dir) <> "/beta-dir/"

    assert_push_event(ws_view, "completion_results", %{
      lookup_id: 10,
      target_id: "workspace-path-input",
      kind: "directory",
      items: [%{value: ^expected_beta, label: "beta-dir/", kind: "dir"}]
    })
  end
end
