defmodule HWeb.ComposerAttachmentTest do
  use HWeb.ConnCase, async: false

  alias H.Provider.Fake
  alias HWeb.Backend

  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGO4W84AAAOJAVUYvr/9AAAAAElFTkSuQmCC"

  setup ctx do
    {:ok, %{session: session}} = Backend.create_session(%{"cwd" => ctx.projects_dir})
    conn = log_in_owner(ctx.conn, ctx.owner_token)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.session_id}")
    %{view: view, sid: session.session_id}
  end

  test "previews a screenshot, then commits it once with the message on Send", ctx do
    assert has_element?(ctx.view, ~s(#composer-form input[type="file"][aria-label="Attach file"]))

    # MIME from the browser is only a hint; the stored MIME comes from the bytes.
    upload = attachment(ctx.view, "mobile.PNG", Base.decode64!(@png), "application/octet-stream")
    assert render_upload(upload, "mobile.PNG", 50) =~ "Uploading attachment"
    assert has_element?(ctx.view, ".composer-attachment img[alt='Selected image preview']")
    assert has_element?(ctx.view, ".composer-attachment", "mobile.PNG")
    render_upload(upload, "mobile.PNG", 50)
    assert {:ok, %{items: []}} = Backend.scan_entries(ctx.sid, 1)
    assert Fake.requests(ctx.fake) == []

    assert ctx.view
           |> form("#composer-form", %{content: "The footer is cut off"})
           |> render_submit(%{mode: "steer"}) =~
             "conversation_idle"

    assert has_element?(ctx.view, ".composer-attachment", "mobile.PNG")
    assert Fake.requests(ctx.fake) == []

    gate = make_ref()

    Fake.push_step(
      ctx.fake,
      {:gate, [], self(), gate, %{content: "Reviewed", finish_reason: "stop"}}
    )

    ctx.view |> form("#composer-form", %{content: "The footer is cut off"}) |> render_submit()
    assert_receive {:gate_entered, ^gate, worker}, 2_000

    assert {:ok, %{items: [%{kind: "user", data: %{"content" => [text, image]}}]}} =
             Backend.scan_entries(ctx.sid, 1)

    assert text == %{"type" => "text", "text" => "The footer is cut off"}

    assert image == %{
             "type" => "image",
             "media_type" => "image/png",
             "encoding" => "base64",
             "data" => @png
           }

    assert has_element?(ctx.view, "#entries-stream img[alt='Attached screenshot']")
    refute has_element?(ctx.view, ".composer-attachment")
    send(worker, {:release, gate})
  end

  test "rejects oversize uploads and unsupported bytes without sending the draft", ctx do
    large =
      attachment(ctx.view, "large.png", :binary.copy(<<0>>, 2 * 1024 * 1024 + 1), "image/png")

    assert {:error, [[_ref, :too_large]]} = render_upload(large, "large.png")
    assert has_element?(ctx.view, ".attachment-error", "Choose an image up to 2 MiB")
    ctx.view |> element(~s(button[aria-label="Remove attachment"])) |> render_click()

    for {name, bytes, error} <- [
          {"image.png", "not a screenshot", "not a valid PNG, JPEG or WebP"},
          {"binary.dat", <<0, 255>>, "Choose a PNG, JPEG, WebP or UTF-8 text file"},
          {"large.txt", String.duplicate("a", 64 * 1024 + 1), "Text files must be 64 KiB"}
        ] do
      upload = attachment(ctx.view, name, bytes, "image/png")
      render_upload(upload, name)

      assert ctx.view
             |> form("#composer-form", %{content: "Don't send this yet"})
             |> render_submit() =~ error

      assert has_element?(ctx.view, ".composer-attachment", name)
      ctx.view |> element(~s(button[aria-label="Remove attachment"])) |> render_click()
    end

    assert Fake.requests(ctx.fake) == []
    assert {:ok, %{items: []}} = Backend.scan_entries(ctx.sid, 1)
  end

  test "sends a text file without a message", ctx do
    upload = attachment(ctx.view, "notes.txt", "\uFEFFSidebar opens offscreen", "text/plain")
    render_upload(upload, "notes.txt")
    gate = make_ref()

    Fake.push_step(
      ctx.fake,
      {:gate, [], self(), gate, %{content: "Reviewed", finish_reason: "stop"}}
    )

    ctx.view |> form("#composer-form") |> render_submit()
    assert_receive {:gate_entered, ^gate, worker}, 2_000

    assert {:ok, %{items: [%{data: %{"content" => [block]}}]}} = Backend.scan_entries(ctx.sid, 1)

    assert block == %{
             "type" => "text",
             "text" => "Attached file \"notes.txt\":\nSidebar opens offscreen"
           }

    send(worker, {:release, gate})
  end

  test "changing branches discards the attachment and fences a stale submit", ctx do
    assert {:ok, %{status: "done"}} =
             Backend.execute_command(ctx.sid, %{
               "version" => 1,
               "request_id" => "entry",
               "conversation_id" => 1,
               "command" => "submit",
               "args" => %{"type" => "write", "content" => "Root"}
             })

    assert {:ok, %{items: [%{id: id}]}} = Backend.scan_entries(ctx.sid, 1)

    assert {:ok, %{conversation_id: cid}} =
             Backend.execute_command(ctx.sid, %{
               "version" => 1,
               "request_id" => "fork",
               "conversation_id" => 1,
               "command" => "fork",
               "args" => %{"at_entry_id" => id}
             })

    upload = attachment(ctx.view, "notes.txt", "Only for the root", "text/plain")
    render_upload(upload, "notes.txt")
    assert has_element?(ctx.view, ".composer-attachment", "notes.txt")
    render_patch(ctx.view, ~p"/sessions/#{ctx.sid}/conversations/#{cid}")
    refute has_element?(ctx.view, ".composer-attachment")
    render_submit(ctx.view, "submit", %{"destination" => "#{ctx.sid}:1", "content" => "Stale"})
    assert Fake.requests(ctx.fake) == []
    assert {:ok, %{items: [%{id: ^id}]}} = Backend.scan_entries(ctx.sid, cid)
  end

  defp attachment(view, name, content, type) do
    file_input(view, "#composer-form", :attachment, [
      %{name: name, content: content, type: type, size: byte_size(content)}
    ])
  end
end
