defmodule HWeb.ReviewFileControllerTest do
  use HWeb.ConnCase, async: false

  alias H.Daemon

  describe "show/2" do
    test "serves owner-only transcript media with range support and rejects other file types",
         ctx do
      %{conn: conn, owner_token: token, projects_dir: cwd, daemon_opts: opts, tmp_root: root} =
        ctx

      png = <<137, 80, 78, 71, 13, 10, 26, 10>>
      File.write!(Path.join(cwd, "screenshot.png"), png)
      File.write!(Path.join(cwd, "walkthrough.webm"), <<0, 1, 2, 3>>)
      File.write!(Path.join(cwd, "page.html"), "<h1>Not transcript media</h1>")
      File.write!(Path.join(root, "outside.png"), png)
      File.ln_s!(root, Path.join(cwd, "escape"))
      {:ok, %{session: session}} = Daemon.create_session(%{cwd: cwd}, opts)
      url = "/sessions/#{session.session_id}/review/file?preview=media&path="

      assert redirected_to(get(conn, url <> "screenshot.png")) == "/login"
      conn = log_in_owner(conn, token)

      image = get(conn, url <> "screenshot.png")
      assert response(image, 200) == png
      assert get_resp_header(image, "content-type") == ["image/png"]
      assert get_resp_header(image, "x-content-type-options") == ["nosniff"]

      partial = conn |> put_req_header("range", "bytes=1-2") |> get(url <> "walkthrough.webm")
      assert response(partial, 206) == <<1, 2>>
      assert get_resp_header(partial, "content-type") == ["video/webm"]

      for path <- ["page.html", "../outside.png", "escape/outside.png", "missing.png"] do
        assert response(get(conn, url <> path), 404) == "Media unavailable"
      end
    end

    test "authenticates every file request, sends conditional text and sandboxes HTML", ctx do
      %{conn: conn, owner_token: token, projects_dir: cwd, daemon_opts: opts} = ctx
      html = "<h1>Preview</h1><script>document.body.textContent='script ran'</script>"
      File.write!(Path.join(cwd, "index.html"), html)
      File.write!(Path.join(cwd, "test.svg"), ~s(<svg xmlns="http://www.w3.org/2000/svg"/>))
      {:ok, %{session: session}} = Daemon.create_session(%{cwd: cwd}, opts)
      url = "/sessions/#{session.session_id}/review/file?path=index.html"
      assert redirected_to(get(conn, url <> "&preview=1")) == "/login"

      conn = log_in_owner(conn, token)
      text = get(conn, url)

      assert %{"kind" => "text", "text" => ^html, "preview" => "html", "revision" => rev} =
               json_response(text, 200)

      assert get_resp_header(text, "cache-control") == ["no-store"]

      assert response(conn |> put_req_header("if-none-match", ~s("#{rev}")) |> get(url), 304) ==
               ""

      preview = get(conn, url <> "&preview=1")
      assert response(preview, 200) == html

      assert ["sandbox; default-src 'none';" <> _] =
               get_resp_header(preview, "content-security-policy")

      assert get_resp_header(preview, "x-frame-options") == ["SAMEORIGIN"]

      svg = get(conn, String.replace(url, "index.html", "test.svg") <> "&preview=1")
      assert get_resp_header(svg, "content-type") == ["image/svg+xml"]
      assert ["sandbox;" <> _] = get_resp_header(svg, "content-security-policy")
    end

    test "rejects invalid sources rather than falling back to the working file", ctx do
      %{conn: conn, owner_token: token, projects_dir: cwd, daemon_opts: opts} = ctx
      File.write!(Path.join(cwd, "notes.txt"), "working file\n")
      {:ok, %{session: session}} = Daemon.create_session(%{cwd: cwd}, opts)
      url = "/sessions/#{session.session_id}/review/file"
      conn = log_in_owner(conn, token)

      for source <- ["--all", "HEAD^", "working:notes.txt", %{"unexpected" => "working"}] do
        assert %{"code" => "unavailable", "error" => "Enter a full or abbreviated commit hash."} =
                 json_response(get(conn, url, %{"path" => "notes.txt", "source" => source}), 404)
      end
    end

    test "offers single byte ranges to media players", ctx do
      %{conn: conn, owner_token: token, projects_dir: cwd, daemon_opts: opts} = ctx
      File.write!(Path.join(cwd, "sample.wav"), <<0, 1, 2, 3, 4, 5, 6, 7>>)
      {:ok, %{session: session}} = Daemon.create_session(%{cwd: cwd}, opts)
      url = "/sessions/#{session.session_id}/review/file?path=sample.wav&preview=1"
      conn = log_in_owner(conn, token)

      for {range, expected, content_range} <- [
            {"bytes=1-3", <<1, 2, 3>>, "bytes 1-3/8"},
            {"bytes=6-", <<6, 7>>, "bytes 6-7/8"},
            {"bytes=-2", <<6, 7>>, "bytes 6-7/8"}
          ] do
        partial = conn |> put_req_header("range", range) |> get(url)
        assert response(partial, 206) == expected
        assert get_resp_header(partial, "content-range") == [content_range]
      end

      unsatisfiable = conn |> put_req_header("range", "bytes=8-9") |> get(url)
      assert response(unsatisfiable, 416) == ""
      assert get_resp_header(unsatisfiable, "content-range") == ["bytes */8"]
    end

    test "rejects traversal and symlinks without accepting a client workspace override", ctx do
      %{conn: conn, owner_token: token, projects_dir: cwd, daemon_opts: opts, tmp_root: root} =
        ctx

      outside = Path.join(root, "outside.txt")
      File.write!(outside, "outside review scope")
      File.ln_s!(root, Path.join(cwd, "escape"))
      {:ok, %{session: session}} = Daemon.create_session(%{cwd: cwd}, opts)
      url = "/sessions/#{session.session_id}/review/file"
      conn = log_in_owner(conn, token)

      for path <- ["../outside.txt", outside, "escape/outside.txt", ".git/config", "outside.txt"] do
        assert %{"error" => _} =
                 json_response(get(conn, url, %{"path" => path, "cwd" => root}), 404)
      end
    end
  end
end
