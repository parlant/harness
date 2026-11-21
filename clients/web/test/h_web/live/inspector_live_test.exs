defmodule HWeb.InspectorLiveTest do
  use HWeb.ConnCase, async: false

  alias HWeb.{Backend, Inspector}
  alias H.Provider.Fake

  setup %{projects_dir: dir} do
    Application.put_env(:harness_web, :inspector_workspace, dir)
    on_exit(fn -> Application.delete_env(:harness_web, :inspector_workspace) end)
  end

  test "owner-only pane records a reviewed crop separately without starting a run", ctx do
    refute get(ctx.conn, "/login").resp_body =~ "ui-inspector"
    {:ok, %{session: other}} = Backend.create_session(%{"cwd" => ctx.projects_dir})
    conn = log_in_owner(ctx.conn, ctx.owner_token)
    {:ok, view, _} = live(conn, "/sessions/#{other.session_id}")
    assert has_element?(view, "#app-menu [data-open-inspector]")
    inspector = find_live_child(view, "feedback-pane")
    assert inspector
    refute inspector.pid == view.pid

    payload = %{
      "action" => "save",
      "note" => "Make this narrower",
      "target" => "#session-details",
      "path" => "/sessions/#{other.session_id}",
      "request_id" => "e290a95c-c64d-4111-a107-4858495d3603",
      "image" => Base.encode64(<<255, 216, 255, 224, 255, 217>>)
    }

    for _ <- 1..2 do
      render_hook(inspector, "feedback", payload)
      assert_reply inspector, %{ok: true}
    end

    assert {:ok, %{items: []}} = Backend.scan_entries(other.session_id, 1)
    assert Fake.requests(ctx.fake) == []
    sid = Inspector.session_id()

    assert {:ok, %{items: [%{data: %{"content" => [text, image]}}]}} =
             Backend.scan_entries(sid, 1)

    assert has_element?(inspector, "#inspect-activity", "Make this narrower")
    render_hook(inspector, "unwatch")
    refute has_element?(inspector, "#inspect-activity")
    render_hook(inspector, "watch")
    assert has_element?(inspector, "#inspect-activity", "Make this narrower")
    assert text["text"] =~ "#session-details"
    assert image["data"] == payload["image"]
    {:ok, feedback, _} = live(conn, "/sessions/#{sid}")
    assert has_element?(feedback, "#entries-stream img[alt='Attached screenshot']")

    parent = self()
    ref = make_ref()

    Fake.push_step(
      ctx.fake,
      {:gate, [], parent, ref, %{content: "Reviewed", finish_reason: "stop"}}
    )

    render_hook(inspector, "feedback", %{
      payload
      | "action" => "ask",
        "request_id" => "de915113-b69b-4dc1-81ca-ec48248dc554"
    })

    assert_reply inspector, %{ok: true}
    assert_receive {:gate_entered, ^ref, pid}, 2000
    assert [_] = Fake.requests(ctx.fake)
    send(pid, {:release, ref})

    # Observe the receipt of the committed answer, not just a successful submit.
    assert Enum.any?(1..100, fn _ ->
             Process.sleep(10)
             has_element?(inspector, "#inspect-activity", "Reviewed")
           end)
  end

  test "rejects invalid or oversized feedback before creating a session" do
    base = %{
      "action" => "save",
      "path" => "/",
      "target" => "page",
      "note" => "hello",
      "request_id" => "e290a95c-c64d-4111-a107-4858495d3603"
    }

    for bad <- [
          %{"image" => String.duplicate("A", 524_289)},
          %{"image" => "not a JPEG"},
          %{"path" => "/?token=private"},
          %{"note" => " "},
          %{"action" => "other"}
        ] do
      assert {:error, _} = Inspector.submit(Map.merge(base, bad))
    end

    assert {:ok, []} = Backend.list_sessions(%{})
  end
end
