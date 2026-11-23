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

  test "pool_wait banner explains Codex account pool waiting and rechecking states" do
    retry = %{
      "kind" => "pool_wait",
      "provider" => "openai_codex",
      "delay_ms" => 60_000,
      "until" => 1_800_000_060_000,
      "wait_until" => 1_800_003_600_000,
      "status" => "waiting",
      "code" => "codex_pool_credits_disabled",
      "message" =>
        "Included Codex quota is exhausted on all pooled accounts; workspace credits are available, but allow_credits is false in extensions.json."
    }

    for kind <- ["generation", "compaction"] do
      html =
        render_component(&ConversationComponents.live_region/1,
          live: %{kind => %{"retry" => retry}},
          tail_activity: nil,
          inbox: []
        )

      assert html =~ "Waiting for eligible Codex account"
      assert html =~ "codex_pool_credits_disabled"
      assert html =~ "allow_credits is false"
      assert html =~ "Waiting for pool eligibility; will continue automatically"
      assert html =~ "Resets around:"
      assert html =~ "Stop remains available."
      refute html =~ "Retrying after provider error"

      rechecking =
        render_component(&ConversationComponents.live_region/1,
          live: %{kind => %{"retry" => Map.put(retry, "status", "running")}},
          tail_activity: nil,
          inbox: []
        )

      assert rechecking =~ "Waiting for eligible Codex account"
      assert rechecking =~ "Rechecking account pool"
      refute rechecking =~ "Waiting for pool eligibility"
    end
  end
end
