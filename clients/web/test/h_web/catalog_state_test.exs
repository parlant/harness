defmodule HWeb.CatalogStateTest do
  use ExUnit.Case, async: true

  alias HWeb.CatalogState

  describe "normalize_session/1" do
    test "normalizes new daemon lifecycle fields and provides backward-compatible fallbacks" do
      # Explicit fields
      s1 =
        CatalogState.normalize_session(%{
          "session_id" => "s1",
          "cwd" => "/work/a",
          "attention" => "idle",
          "needs_attention" => false,
          "archived" => false,
          "loaded" => true,
          "cwd_exists" => false
        })

      assert s1.needs_attention == false
      assert s1.archived == false
      assert s1.loaded == true
      assert s1.cwd_exists == false

      # Backward-compatible fallbacks when fields are omitted
      s2 =
        CatalogState.normalize_session(%{
          session_id: "s2",
          cwd: "/work/a",
          attention: "idle"
        })

      assert s2.archived == false
      assert s2.needs_attention == true
      assert s2.loaded == true
      assert s2.cwd_exists == true

      # Running fallback -> needs_attention false
      s3 =
        CatalogState.normalize_session(%{
          session_id: "s3",
          cwd: "/work/a",
          attention: "running"
        })

      assert s3.needs_attention == false
      assert s3.loaded == true

      # Imported archive fallback -> archived true, needs_attention false, loaded false
      s4 =
        CatalogState.normalize_session(%{
          session_id: "s4",
          cwd: "/work/a",
          status: "archived"
        })

      assert s4.archived == true
      assert s4.needs_attention == false
      assert s4.loaded == false
    end
  end

  describe "filter_sessions/3, counts/1, group_by_workspace/2, and next_attention_session/2" do
    test "orders tiers within workspace groups and filters inbox/attention/archived/all correctly" do
      sessions =
        [
          # Tier 4: archived
          %{
            session_id: "s-archived",
            cwd: "/work/repo",
            attention: "idle",
            needs_attention: false,
            archived: true,
            loaded: false,
            updated_at: 999
          },
          # Tier 3: loaded but dismissed (does not need attention)
          %{
            session_id: "s-cleared",
            cwd: "/work/repo",
            attention: "idle",
            needs_attention: false,
            archived: false,
            loaded: true,
            updated_at: 900
          },
          # Cold unloaded & cleared -> hidden from Inbox, shown in Archived
          %{
            session_id: "s-cold",
            cwd: "/work/repo",
            attention: "idle",
            needs_attention: false,
            archived: false,
            loaded: false,
            updated_at: 850
          },
          # Tier 2: processing
          %{
            session_id: "s-running",
            cwd: "/work/repo",
            attention: "running",
            needs_attention: false,
            archived: false,
            loaded: true,
            updated_at: 800
          },
          # Tier 1: needs attention (idle)
          %{
            session_id: "s-idle-na",
            cwd: "/work/repo",
            attention: "idle",
            needs_attention: true,
            archived: false,
            loaded: true,
            updated_at: 700
          },
          # Tier 0: error needing attention
          %{
            session_id: "s-error-na",
            cwd: "/work/repo",
            attention: "error",
            needs_attention: true,
            archived: false,
            loaded: true,
            updated_at: 600
          }
        ]
        |> Enum.map(&CatalogState.normalize_session/1)

      counts = CatalogState.counts(sessions)
      assert counts.inbox == 4
      assert counts.attention == 2
      assert counts.error == 1
      assert counts.idle == 1
      assert counts.processing == 1
      assert counts.running == 1
      assert counts.sleeping == 0
      assert counts.archived == 2
      assert counts.all == 6

      assert Enum.map(CatalogState.filter_sessions(sessions, "inbox"), & &1.session_id) --
               ["s-cleared", "s-running", "s-idle-na", "s-error-na"] == []

      assert Enum.map(CatalogState.filter_sessions(sessions, "attention"), & &1.session_id) --
               ["s-idle-na", "s-error-na"] == []

      assert Enum.map(CatalogState.filter_sessions(sessions, "archived"), & &1.session_id) --
               ["s-archived", "s-cold"] == []

      assert length(CatalogState.filter_sessions(sessions, "all")) == 6

      [group] = CatalogState.group_by_workspace(sessions)

      assert Enum.map(group.sessions, & &1.session_id) == [
               "s-error-na",
               "s-idle-na",
               "s-running",
               "s-cleared",
               "s-cold",
               "s-archived"
             ]

      assert CatalogState.next_attention_session(sessions).session_id == "s-error-na"
      assert CatalogState.next_attention_session(sessions, "s-error-na").session_id == "s-idle-na"

      assert CatalogState.next_attention_session(
               Enum.reject(sessions, &(&1.session_id in ["s-error-na", "s-idle-na"]))
             ) == nil
    end
  end
end
