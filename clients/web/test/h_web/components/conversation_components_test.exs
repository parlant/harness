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
