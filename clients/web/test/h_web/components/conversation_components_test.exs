defmodule HWeb.ConversationComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias HWeb.ConversationComponents

  @images (for media_type <- ["image/jpeg", "image/png", "image/webp"] do
             %{
               "type" => "image",
               "encoding" => "base64",
               "media_type" => media_type,
               "data" => Base.encode64("attachment: #{media_type}")
             }
           end)

  @rejected [
    %{
      "type" => "image",
      "encoding" => "base64",
      "media_type" => "image/svg+xml",
      "data" => "PHN2Zz4="
    },
    %{
      "type" => "image",
      "encoding" => "base64",
      "media_type" => "text/html",
      "data" => "PGgxPg=="
    },
    %{"type" => "image", "encoding" => "base64", "media_type" => "image/gif", "data" => "R0lG"},
    %{
      "type" => "image",
      "encoding" => "base64",
      "media_type" => "image/png;foo=bar",
      "data" => "AAAA"
    },
    %{
      "type" => "image",
      "encoding" => "url",
      "media_type" => "image/png",
      "data" => "https://example.org/image.png"
    },
    %{"type" => "image", "encoding" => "base64", "media_type" => "image/png", "data" => nil},
    %{"type" => "image", "encoding" => "base64", "media_type" => "image/webp", "data" => 123},
    %{"type" => "text", "encoding" => "base64", "media_type" => "image/png", "data" => "AAAA"},
    %{"type" => "image", "encoding" => "base64", "data" => "AAAA"}
  ]

  describe "entry_body/1" do
    test "renders base64 JPEG, PNG, and WebP attachments with their own MIME types" do
      for kind <- ["user", "assistant"] do
        html =
          render_component(&ConversationComponents.entry_body/1,
            entry: %{"kind" => kind, "data" => %{"content" => @images ++ @rejected}}
          )

        document = LazyHTML.from_fragment(html)
        images = LazyHTML.query(document, "img.feedback-image")

        assert LazyHTML.attribute(images, "src") ==
                 Enum.map(@images, fn image ->
                   "data:#{image["media_type"]};base64,#{image["data"]}"
                 end)

        assert LazyHTML.attribute(images, "alt") == List.duplicate("Attached screenshot", 3)
        assert LazyHTML.attribute(images, "loading") == List.duplicate("lazy", 3)
      end
    end

    test "renders legacy PNG attachments without an encoding field" do
      image = Enum.at(@images, 1) |> Map.delete("encoding")
      entry = %{"kind" => "assistant", "data" => %{"content" => [image]}}

      html = render_component(&ConversationComponents.entry_body/1, entry: entry)

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("img")
             |> LazyHTML.attribute("src") ==
               ["data:image/png;base64," <> image["data"]]

      assert ConversationComponents.message?(entry)
    end

    test "does not render unsupported or malformed attachments" do
      html =
        render_component(&ConversationComponents.entry_body/1,
          entry: %{"kind" => "user", "data" => %{"content" => @rejected}}
        )

      assert LazyHTML.from_fragment(html) |> LazyHTML.query("img") |> LazyHTML.to_tree() == []
    end
  end

  describe "entry_card/1" do
    test "renders user card with below-card toolbar, plain copy text, step id, and fork button" do
      entry = %{
        "id" => 12,
        "kind" => "user",
        "data" => %{"content" => "Hello **plain** prompt\nline 2"}
      }

      html =
        render_component(&ConversationComponents.entry_card/1,
          id: "entries-12",
          entry: entry,
          can_fork?: true
        )

      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.query(doc, "article#entries-12.entry-card.entry-user") |> LazyHTML.to_tree() !=
               []

      assert LazyHTML.query(doc, ".entry-header") |> LazyHTML.to_tree() == []

      assert LazyHTML.query(doc, ".entry-user .entry-body .entry-text") |> LazyHTML.text() ==
               "Hello **plain** prompt\nline 2"

      copy_btn = LazyHTML.query(doc, ".entry-user footer.entry-toolbar button[data-copy-btn]")
      assert LazyHTML.attribute(copy_btn, "data-copy-text") == ["Hello **plain** prompt\nline 2"]
      assert LazyHTML.attribute(copy_btn, "aria-label") == ["Copy message"]

      fork_btn =
        LazyHTML.query(
          doc,
          ".entry-user footer.entry-toolbar button[phx-click='fork_entry'][phx-value-entry_id='12']"
        )

      assert LazyHTML.to_tree(fork_btn) != []

      assert LazyHTML.query(doc, ".entry-user footer.entry-toolbar .entry-step-id")
             |> LazyHTML.text() == "#12"
    end

    test "renders assistant card with Markdown body, raw Markdown copy text, and status badges" do
      raw_md = "Here is **bold** text:\n\n```elixir\nIO.puts(:ok)\n```"

      aborted_entry = %{
        "id" => 15,
        "kind" => "assistant",
        "data" => %{"content" => [%{"type" => "text", "text" => raw_md}], "aborted" => true}
      }

      html =
        render_component(&ConversationComponents.entry_card/1,
          id: "entries-15",
          entry: aborted_entry,
          can_fork?: true
        )

      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.query(doc, "article#entries-15.entry-card.entry-assistant.has-status")
             |> LazyHTML.to_tree() != []

      assert LazyHTML.query(doc, ".entry-assistant .entry-body .markdown strong")
             |> LazyHTML.text() ==
               "bold"

      copy_btn =
        LazyHTML.query(doc, ".entry-assistant footer.entry-toolbar button[data-copy-btn]")

      assert LazyHTML.attribute(copy_btn, "data-copy-text") == [raw_md]

      assert LazyHTML.query(doc, "footer.entry-toolbar .entry-status.is-warn") |> LazyHTML.text() =~
               "Aborted"

      assert LazyHTML.query(doc, "footer.entry-toolbar .entry-step-id") |> LazyHTML.text() ==
               "#15"

      failed_entry = %{
        "id" => 16,
        "kind" => "assistant",
        "data" => %{"content" => "Partial", "is_error" => true}
      }

      failed_doc =
        render_component(&ConversationComponents.entry_card/1,
          id: "entries-16",
          entry: failed_entry,
          can_fork?: false
        )
        |> LazyHTML.from_fragment()

      assert LazyHTML.query(failed_doc, "footer.entry-toolbar .entry-status.is-danger")
             |> LazyHTML.text() =~ "Failed"

      assert LazyHTML.query(failed_doc, "button[phx-click='fork_entry']") |> LazyHTML.to_tree() ==
               []
    end

    test "omits copy button when message has only an image and no text" do
      entry = %{
        "id" => 20,
        "kind" => "user",
        "data" => %{"content" => [Enum.at(@images, 1)]}
      }

      doc =
        render_component(&ConversationComponents.entry_card/1,
          id: "entries-20",
          entry: entry,
          can_fork?: true
        )
        |> LazyHTML.from_fragment()

      assert LazyHTML.query(doc, "img.feedback-image") |> LazyHTML.to_tree() != []
      assert LazyHTML.query(doc, "button[data-copy-btn]") |> LazyHTML.to_tree() == []
    end

    test "renders copy button on subagent tool_result when text is present" do
      entry = %{
        "id" => 25,
        "kind" => "tool_result",
        "data" => %{
          "name" => "subagent",
          "content" => "Subagent summary text",
          "details" => %{"status" => "done"}
        }
      }

      doc =
        render_component(&ConversationComponents.entry_card/1,
          id: "entries-25",
          entry: entry,
          can_fork?: true
        )
        |> LazyHTML.from_fragment()

      assert LazyHTML.query(doc, "article#entries-25.entry-card.entry-tool_result")
             |> LazyHTML.to_tree() != []

      copy_btn = LazyHTML.query(doc, "footer.entry-toolbar button[data-copy-btn]")
      assert LazyHTML.attribute(copy_btn, "data-copy-text") == ["Subagent summary text"]
    end
  end

  describe "live_region/1" do
    test "renders streaming assistant text with below-card live status instead of top header" do
      html =
        render_component(&ConversationComponents.live_region/1,
          live: %{"generation" => %{"message" => %{"content" => "Working on **answer**"}}},
          inbox: []
        )

      doc = LazyHTML.from_fragment(html)

      assert LazyHTML.query(doc, "article#live-generation.entry-card.entry-assistant.entry-live")
             |> LazyHTML.to_tree() != []

      assert LazyHTML.query(doc, "#live-generation strong") |> LazyHTML.text() == "answer"

      assert LazyHTML.query(doc, "#live-generation footer.entry-live-status") |> LazyHTML.text() =~
               "Streaming…"

      refute html =~ "assistant (live)"
    end
  end

  describe "message?/1" do
    test "keeps assistant messages containing only a supported image visible" do
      for image <- @images do
        assert ConversationComponents.message?(%{
                 "kind" => "assistant",
                 "data" => %{"content" => [image]}
               })
      end
    end

    test "does not treat rejected images as assistant message content" do
      refute ConversationComponents.message?(%{
               "kind" => "assistant",
               "data" => %{"content" => @rejected}
             })
    end
  end
end
