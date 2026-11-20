defmodule HWeb.ReviewLiveTest do
  use HWeb.ConnCase, async: false

  alias H.{Daemon, WorkspaceLease}
  alias H.Daemon.Review

  describe "workspace and session navigation" do
    test "reuses its own empty session for concurrent opens and replaces it after a comment",
         ctx do
      %{conn: conn, owner_token: token, projects_dir: cwd, daemon_opts: opts} = ctx
      File.write!(Path.join(cwd, "notes.txt"), "abc\n")
      {:ok, %{session: ordinary}} = Daemon.create_session(%{cwd: cwd}, opts)

      [sid] =
        1..4
        |> Task.async_stream(fn _ ->
          {:ok, %{session: s}} = Daemon.open_workspace_review(%{cwd: cwd}, opts)
          s.session_id
        end)
        |> Enum.map(fn {:ok, sid} -> sid end)
        |> Enum.uniq()

      refute sid == ordinary.session_id
      conn = log_in_owner(conn, token)
      {:ok, workspace, _} = live(conn, "/workspaces")

      assert {:error, {:live_redirect, %{to: "/sessions/" <> ^sid <> "/review"}}} =
               workspace |> element("#review-selected-workspace-btn") |> render_click()

      {:ok, view, html} = live(conn, "/sessions/#{sid}/review")
      assert html =~ ~s(id="review-files")
      refute html =~ ~s(id="review-changes")
      render_click(view, "review_open", %{path: "notes.txt"})
      render_hook(view, "review_comment", comment("notes.txt", "abc\n"))
      assert_reply view, %{ok: true}

      {:ok, %{session: next}} = Daemon.open_workspace_review(%{cwd: cwd}, opts)
      refute sid == next.session_id

      assert {:ok, %{session: %{session_id: next_id}}} =
               Daemon.open_workspace_review(%{cwd: cwd}, opts)

      assert next_id == next.session_id

      {:ok, _view, html} = live(conn, "/inbox?filter=all")
      assert html =~ ~s(href="/sessions/#{sid}/review?)
      {:ok, view, _} = live(conn, "/sessions/#{sid}")
      assert has_element?(view, "#session-review-link")
    end

    test "selects the requested branch, validates UTF-16 offsets and records a note without a run",
         ctx do
      %{conn: conn, owner_token: token, projects_dir: cwd, daemon_opts: opts} = ctx
      text = "abc\r\na😀bc\r\n"
      File.write!(Path.join(cwd, "notes.txt"), text)
      {:ok, %{session: session}} = Daemon.create_session(%{cwd: cwd}, opts)
      sid = session.session_id

      {:ok, %{status: "done"}} =
        Daemon.execute_command(
          sid,
          %{
            version: 1,
            conversation_id: 1,
            request_id: "original",
            command: "submit",
            args: %{type: "write", content: "Original message"}
          },
          opts
        )

      {:ok, %{items: [%{id: entry}]}} = Daemon.scan_entries(sid, 1, %{}, opts)

      {:ok, %{conversation_id: cid}} =
        Daemon.execute_command(
          sid,
          %{
            version: 1,
            conversation_id: 1,
            request_id: "fork-review",
            command: "fork",
            args: %{at_entry_id: entry}
          },
          opts
        )

      conn = log_in_owner(conn, token)

      {:ok, view, _} =
        live(conn, "/sessions/#{sid}/review?conversation=#{cid}&from=inbox&tag=review")

      assert has_element?(
               view,
               ~s(#review-session-link[href^="/sessions/#{sid}/conversations/#{cid}?"])
             )

      render_click(view, "review_open", %{path: "notes.txt"})
      render_hook(view, "review_comment", %{comment("notes.txt", text) | range: [2, 3, 2, 4]})
      assert_reply view, %{ok: false}
      payload = %{comment("notes.txt", text) | range: [2, 2, 2, 4]}
      render_hook(view, "review_comment", payload)
      assert_reply view, %{ok: true}
      render_hook(view, "review_comment", payload)
      assert_reply view, %{ok: true}

      assert {:ok,
              %{
                items: [%{kind: "user", data: %{"content" => [%{"text" => note}]}}, %{id: ^entry}]
              }} =
               Daemon.scan_entries(sid, cid, %{}, opts)

      assert note =~ "notes.txt:2:2–2:4 (working"
      assert note =~ "Selected text:\n😀"
      assert {:ok, %{items: [%{id: ^entry}]}} = Daemon.scan_entries(sid, 1, %{}, opts)
      assert {:ok, %{tasks: []}} = Daemon.get_session_detail(sid, opts)

      File.write!(Path.join(cwd, "notes.txt"), "different")

      render_hook(view, "review_comment", %{
        payload
        | request_id: "00000000-0000-0000-0000-000000000002"
      })

      assert_reply view, %{ok: false, code: "file_changed"}
    end
  end

  test "expands siblings and paginates one branch without moving the file selection", ctx do
    %{conn: conn, owner_token: token, projects_dir: cwd, daemon_opts: opts} = ctx

    for path <- ["root.txt", "src/deep/nested.txt", "docs/guide.txt"] do
      full = Path.join(cwd, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, path)
    end

    for n <- 100..300, do: File.write!(Path.join(cwd, "docs/#{n}.txt"), "page")
    {:ok, %{session: session}} = Daemon.create_session(%{cwd: cwd}, opts)
    {:ok, view, _} = live(log_in_owner(conn, token), "/sessions/#{session.session_id}/review")

    src = ~s(button[phx-value-dir="src"])
    deep = ~s(button[phx-value-dir="src/deep"])
    docs = ~s(button[phx-value-dir="docs"])
    root = ~s(button[phx-value-path="root.txt"])
    nested = ~s(button[phx-value-path="src/deep/nested.txt"])
    guide = ~s(button[phx-value-path="docs/guide.txt"])
    assert has_element?(view, src <> ~s([aria-expanded="false"]))
    refute has_element?(view, deep)
    view |> element(src) |> render_click()
    view |> element(deep) |> render_click()
    view |> element(docs) |> render_click()

    view
    |> element(
      ~s(button[phx-click="review_page"][phx-value-dir="docs"][phx-value-direction="next"])
    )
    |> render_click()

    assert has_element?(view, guide)
    assert has_element?(view, root)
    assert has_element?(view, nested)
    send(view.pid, :review_refresh)
    assert has_element?(view, nested)
    view |> element(nested) |> render_click()
    view |> element(src) |> render_click()
    refute has_element?(view, nested)
    assert has_element?(view, guide)
    assert has_element?(view, ~s(#review-editor[data-path="src/deep/nested.txt"]))
    view |> element(src) |> render_click()
    assert has_element?(view, deep <> ~s([aria-expanded="false"]))
  end

  test "reviews a pinned historical commit and its parent without writing the working file",
       ctx do
    %{conn: conn, owner_token: token, projects_dir: cwd, daemon_opts: opts} = ctx
    git(cwd, ~w(init --quiet))
    File.mkdir_p!(Path.join(cwd, "src"))
    path = "src/notes.txt"
    File.write!(Path.join(cwd, path), "first\n")
    File.write!(Path.join(cwd, "removed.txt"), "removed in the second commit\n")
    git(cwd, ~w(add .))
    git(cwd, ~w(commit -qm initial))
    parent = git(cwd, ~w(rev-parse HEAD))
    File.write!(Path.join(cwd, path), "second\n")
    File.rm!(Path.join(cwd, "removed.txt"))
    git(cwd, ~w(add -A))
    git(cwd, ["commit", "-qm", "Update notes"])
    hash = git(cwd, ~w(rev-parse HEAD))
    File.write!(Path.join(cwd, path), "third\n")
    git(cwd, ~w(add .))
    git(cwd, ~w(commit -qm latest))
    {:ok, %{session: session}} = Daemon.create_session(%{cwd: cwd}, opts)
    sid = session.session_id
    {:ok, view, _} = live(log_in_owner(conn, token), "/sessions/#{sid}/review")
    view |> element(~s(button[phx-click="review_history"])) |> render_click()
    assert has_element?(view, ~s(#review-history button[phx-value-ref="#{hash}"]), "Update notes")
    view |> form("#review-commit-form", %{ref: "HEAD; echo bad"}) |> render_submit()
    assert has_element?(view, "[role=status]", "Enter a full or abbreviated commit hash.")
    view |> form("#review-commit-form", %{ref: String.slice(hash, 0, 10)}) |> render_submit()
    assert has_element?(view, "#review-selected-commit", "Read-only files")

    assert has_element?(
             view,
             ~s(#review-changes button[phx-value-path="removed.txt"][phx-value-deleted="true"])
           )

    view |> element(~s(#review-changes button[phx-value-path="#{path}"])) |> render_click()
    assert has_element?(view, ~s(#review-editor[data-commit="#{hash}"][data-base="#{parent}"]))

    render_hook(view, "review_save", %{
      path: path,
      revision: Review.revision("third\n"),
      text: "edited\n"
    })

    assert_reply view, %{ok: false, error: "Files from a commit are read-only."}
    assert File.read!(Path.join(cwd, path)) == "third\n"

    payload = comment(path, "second\n")
    render_hook(view, "review_comment", payload)
    assert_reply view, %{ok: false}
    render_hook(view, "review_comment", %{payload | source: hash})
    assert_reply view, %{ok: true}

    render_hook(view, "review_comment", %{
      comment(path, "first\n")
      | source: parent,
        request_id: "00000000-0000-0000-0000-000000000002"
    })

    assert_reply view, %{ok: true}

    assert {:ok,
            %{
              items: [
                %{data: %{"content" => [%{"text" => before}]}},
                %{data: %{"content" => [%{"text" => after_text}]}}
              ]
            }} =
             Daemon.scan_entries(sid, 1, %{}, opts)

    assert before =~ "#{parent}, sha256"
    assert before =~ "parent of #{hash}"
    assert before =~ "Selected text:\nfir"
    assert after_text =~ "#{hash}, sha256"
    assert after_text =~ "Selected text:\nsec"
    assert {:ok, %{tasks: []}} = Daemon.get_session_detail(sid, opts)

    view |> element(~s(button[phx-value-tab="files"])) |> render_click()
    view |> element(~s(button[phx-value-dir="src"])) |> render_click()
    assert has_element?(view, ~s(#review-files button[phx-value-path="#{path}"]))
    refute has_element?(view, ~s(#review-files button[phx-value-path="removed.txt"]))
    view |> element(~s(button[phx-click="review_working"])) |> render_click()
    refute has_element?(view, "#review-selected-commit")
    assert has_element?(view, "#review-changes", "No git changes.")
  end

  describe "review_save" do
    test "checks selection, current revision and workspace lease", ctx do
      %{conn: conn, owner_token: token, projects_dir: cwd, tmp_root: root, daemon_opts: opts} =
        ctx

      path = Path.join(cwd, "notes.txt")
      File.write!(path, "before\n")
      alias_cwd = Path.join(root, "alias")
      File.ln_s!(cwd, alias_cwd)
      {:ok, canonical} = H.ExecutionEnv.canonical_path(H.ExecutionEnv.Host.new(cwd), cwd)
      key = {"host", canonical}
      {:ok, %{session: session}} = Daemon.create_session(%{cwd: alias_cwd}, opts)
      {:ok, view, _} = live(log_in_owner(conn, token), "/sessions/#{session.session_id}/review")
      render_click(view, "review_open", %{path: "notes.txt"})
      payload = %{path: "notes.txt", revision: Review.revision("before\n"), text: "edited\n"}

      assert :ok =
               WorkspaceLease.acquire(opts[:workspace_lease], key, {:agent, 1}, self())

      render_hook(view, "review_save", payload)

      assert_reply view, %{
        ok: false,
        error: "An agent is writing in this workspace. Try again when it is idle."
      }

      WorkspaceLease.release(opts[:workspace_lease], key, {:agent, 1})

      render_hook(view, "review_save", %{payload | path: "other.txt"})
      assert_reply view, %{ok: false}
      File.write!(path, "changed by agent\n")
      render_hook(view, "review_save", payload)
      assert_reply view, %{ok: false, code: "file_changed"}
      assert File.read!(path) == "changed by agent\n"

      render_hook(view, "review_save", %{
        payload
        | revision: Review.revision("changed by agent\n")
      })

      assert_reply view, %{ok: true}
      assert File.read!(path) == "edited\n"
    end
  end

  defp git(cwd, args) do
    assert {result, 0} =
             System.cmd(
               "git",
               [
                 "-c",
                 "core.hooksPath=/dev/null",
                 "-c",
                 "commit.gpgsign=false",
                 "-c",
                 "user.name=H Review Test",
                 "-c",
                 "user.email=test@example.invalid" | args
               ],
               cd: cwd,
               stderr_to_stdout: true,
               env: [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}]
             )

    String.trim(result)
  end

  defp comment(path, text) do
    %{
      path: path,
      note: "Could we simplify this?",
      source: "working",
      action: "save",
      revision: Review.revision(text),
      range: [1, 1, 1, 4],
      request_id: "00000000-0000-0000-0000-000000000001"
    }
  end
end
