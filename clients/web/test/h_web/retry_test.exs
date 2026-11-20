defmodule HWeb.RetryTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HWeb.{CatalogState, ConversationComponents, InboxComponents}

  test "retrying remains processing and has a distinct operator indicator" do
    session =
      CatalogState.normalize_session(%{
        "session_id" => "s",
        "cwd" => "/tmp",
        "attention" => "retrying",
        "active" => true,
        "activity_label" => "Retry 1/3 · http_429 · waiting 2s"
      })

    assert session.attention == "retrying"
    assert CatalogState.processing?(session)
    refute CatalogState.needs_attention?(session)
    assert CatalogState.counts([session]).retrying == 1
    html = render_component(&InboxComponents.status_indicator/1, attention: "retrying")
    assert html =~ ~s(aria-label="retrying")
    assert html =~ "Retrying after provider error"
  end

  test "generation and compaction retries explain the wait instead of showing streaming or Continue" do
    retry = %{
      "attempt" => 1,
      "max_attempts" => 3,
      "delay_ms" => 2_000,
      "until" => 1_800_000_000_000,
      "status" => "waiting",
      "code" => "http_429",
      "message" => "Monthly spending cap reached"
    }

    for kind <- ["generation", "compaction"] do
      assert HWeb.Transcript.run_active?(%{kind => %{"retry" => retry}})

      html =
        render_component(&ConversationComponents.live_region/1,
          live: %{kind => %{"retry" => retry}},
          tail_activity: nil,
          inbox: []
        )

      assert html =~ "Retrying after provider error"
      assert html =~ "Monthly spending cap reached"
      assert html =~ "http_429"
      assert html =~ "1/3"
      assert html =~ "2s"
      refute html =~ "Streaming…"
      refute html =~ "Continue Run"

      html =
        render_component(&ConversationComponents.live_region/1,
          live: %{kind => %{"retry" => Map.put(retry, "status", "running")}},
          tail_activity: nil,
          inbox: []
        )

      assert html =~ "Retry request in progress"
      refute html =~ "Waiting 2s"
    end
  end
end
