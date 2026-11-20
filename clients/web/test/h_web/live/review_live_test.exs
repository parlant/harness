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
