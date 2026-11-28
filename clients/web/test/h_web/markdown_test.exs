defmodule HWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias HWeb.Markdown
  import Phoenix.HTML, only: [safe_to_string: 1]

  describe "render/2" do
    test "renders only session-relative supported media and escapes descriptions and paths" do
      html =
        Markdown.render(
          """
          ![Workspace screenshot](workspace:artifacts/workspace%20preview.png)

          ![Walkthrough](workspace:artifacts/demo.webm)
          """,
          "demo-session"
        )
        |> safe_to_string()

      assert html =~ ~s(<img src="/sessions/demo-session/review/file?)
      assert html =~ "path=artifacts%2Fworkspace+preview.png"
      assert html =~ "preview=media"
      assert html =~ ~s(alt="Workspace screenshot" loading="lazy")
      assert html =~ ~s(<video src="/sessions/demo-session/review/file?)
      assert html =~ ~s(aria-label="Walkthrough" controls playsinline preload="none")
    end

    test "does not embed media outside the current workspace or from arbitrary URLs" do
      for src <- [
            "workspace:../outside.png",
            "workspace:%2Fetc%2Foutside.png",
            "workspace:artifacts/%2e%2e/outside.png",
            "workspace:artifacts/.git/image.png",
            "workspace:artifacts/%00image.png",
            "workspace:artifacts/icon.svg",
            "https://example.org/demo.mp4",
            "//example.org/image.png",
            "/sessions/other/review/file?path=secret.png"
          ] do
        assert safe_to_string(Markdown.render("![Preview](#{src})", "demo-session")) ==
                 "<p>Preview</p>"
      end

      assert safe_to_string(Markdown.render("![Preview](workspace:preview.png)")) ==
               "<p>Preview</p>"
    end
  end

  describe "render/1" do
    test "renders headings, lists, links, inline code, and tables" do
      html =
        Markdown.render("""
        ## Summary

        - **Changed** `app.ex`
        - [Docs](https://example.org/docs?a=1&b=2)

        Item | Status
        ---- | ------
        app  | ok
        """)
        |> safe_to_string()

      assert html =~ "<h2>Summary</h2>"
      assert html =~ "<li><strong>Changed</strong> <code>app.ex</code></li>"
      assert html =~ ~s(href="https://example.org/docs?a=1&amp;b=2")
      assert html =~ "<table><thead><tr><th>Item</th>"
    end

    test "renders a partial console fence without evaluating or altering the code" do
      assert safe_to_string(Markdown.render("```console\n$ echo '<tag>'\n  a  b")) ==
               ~s(<pre class="console-block"><code>$ echo &#39;&lt;tag&gt;&#39;\n  a  b</code></pre>)
    end

    test "ignores raw HTML, unsafe links, and image URLs" do
      html =
        Markdown.render("""
        <div id="injected">raw HTML</div>

        Inline <b>text</b> and [unsafe](javascript:alert%281%29).

        ![preview](https://example.org/preview.png)
        """)
        |> safe_to_string()

      refute html =~ "id=\"injected\""
      refute html =~ "<b>"
      refute html =~ "href="
      refute html =~ "<img"
      refute html =~ "https://example.org"
      assert html =~ "Inline &lt;b&gt;text&lt;/b&gt; and unsafe."
      assert html =~ "<p>preview</p>"
    end
  end
end
