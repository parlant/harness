defmodule HWeb.CatalogStateTest do
  use ExUnit.Case, async: true

  alias HWeb.CatalogState

  describe "normalize_session/1" do
    test "parses parent with atom keys and role" do
      session =
        CatalogState.normalize_session(%{
          session_id: "child-1",
          cwd: "/private/tmp/wt-lane-1",
          parent: %{
            session_id: "coord-1",
            conversation_id: 2,
            at_entry_id: 42,
            task_id: 43,
            depth: 1
          },
          role: "subagent",
          attention: "running",
          activity_kind: "tool",
          activity_label: "bash"
        })

      assert session.parent == %{
               session_id: "coord-1",
               conversation_id: "2",
               at_entry_id: "42",
               task_id: "43",
               depth: 1
             }

      assert session.role == "subagent"
      assert CatalogState.subsession?(session)
      refute CatalogState.root_session?(session)
    end

    test "parses parent with string keys and defaults conversation_id and depth" do
      session =
        CatalogState.normalize_session(%{
          "session_id" => "child-2",
          "cwd" => "/repo",
          "parent" => %{"session_id" => "coord-1", "at_entry_id" => "7"},
          "role" => "subagent"
        })

      assert session.parent == %{
               session_id: "coord-1",
               conversation_id: "1",
               at_entry_id: "7",
               task_id: nil,
               depth: 1
             }

      assert session.role == "subagent"
      assert CatalogState.subsession?(session)
    end

    test "treats absent or invalid parent as root session" do
      root = CatalogState.normalize_session(%{session_id: "root-1", cwd: "/repo"})
      invalid = CatalogState.normalize_session(%{session_id: "root-2", cwd: "/repo", parent: %{}})

      assert root.parent == nil
      assert root.role == nil
      assert CatalogState.root_session?(root)
      refute CatalogState.subsession?(root)

      assert invalid.parent == nil
      assert CatalogState.root_session?(invalid)
    end

    test "normalizes new daemon lifecycle fields and provides backward-compatible fallbacks" do
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

      s3 =
        CatalogState.normalize_session(%{
          session_id: "s3",
          cwd: "/work/a",
          attention: "running"
        })

      assert s3.needs_attention == false
      assert s3.loaded == true

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

  describe "needs_attention?/1, counts/1, and next_attention_session/2" do
    test "exempts subsessions from attention, primary counts, and next_attention_session while tracking subsession counts" do
      sessions =
        [
          %{session_id: "root-running", cwd: "/repo", attention: "running", updated_at: 20},
          %{session_id: "root-idle", cwd: "/repo", attention: "idle", updated_at: 10},
          %{
            session_id: "sub-error",
            cwd: "/private/tmp/wt-1",
            attention: "error",
            activity_label: "model_error",
            updated_at: 50,
            parent: %{
              session_id: "root-running",
              conversation_id: "1",
              at_entry_id: "5",
              depth: 1
            },
            role: "subagent"
          },
          %{
            session_id: "sub-idle",
            cwd: "/private/tmp/wt-2",
            attention: "idle",
            updated_at: 40,
            parent: %{
              session_id: "root-running",
              conversation_id: "1",
              at_entry_id: "6",
              depth: 1
            },
            role: "subagent"
          },
          %{
            session_id: "sub-running",
            cwd: "/private/tmp/wt-3",
            attention: "running",
            activity_kind: "tool",
            activity_label: "bash",
            updated_at: 60,
            parent: %{
              session_id: "root-running",
              conversation_id: "1",
              at_entry_id: "7",
              depth: 1
            },
            role: "subagent"
          }
        ]
        |> Enum.map(&CatalogState.normalize_session/1)

      by_id = Map.new(sessions, &{&1.session_id, &1})

      assert CatalogState.needs_attention?(by_id["root-idle"])
      refute CatalogState.needs_attention?(by_id["root-running"])
      refute CatalogState.needs_attention?(by_id["sub-error"])
      refute CatalogState.needs_attention?(by_id["sub-idle"])
      refute CatalogState.needs_attention?(by_id["sub-running"])

      assert CatalogState.subsession_count(sessions) == 3

      assert CatalogState.counts(sessions) == %{
               inbox: 2,
               all: 2,
               archived: 0,
               attention: 1,
               error: 0,
               idle: 1,
               processing: 1,
               running: 1,
               sleeping: 0,
               retrying: 0,
               subsessions: 3,
               subsessions_running: 1
             }

      assert %{session_id: "root-idle"} = CatalogState.next_attention_session(sessions)
      assert nil == CatalogState.next_attention_session(sessions, "root-idle")
    end

    test "orders tiers within workspace groups and filters inbox/attention/archived/all correctly" do
      sessions =
        [
          %{
            session_id: "s-archived",
            cwd: "/work/repo",
            attention: "idle",
            needs_attention: false,
            archived: true,
            loaded: false,
            updated_at: 999
          },
          %{
            session_id: "s-cleared",
            cwd: "/work/repo",
            attention: "idle",
            needs_attention: false,
            archived: false,
            loaded: true,
            updated_at: 900
          },
          %{
            session_id: "s-cold",
            cwd: "/work/repo",
            attention: "idle",
            needs_attention: false,
            archived: false,
            loaded: false,
            updated_at: 850
          },
          %{
            session_id: "s-running",
            cwd: "/work/repo",
            attention: "running",
            needs_attention: false,
            archived: false,
            loaded: true,
            updated_at: 800
          },
          %{
            session_id: "s-idle-na",
            cwd: "/work/repo",
            attention: "idle",
            needs_attention: true,
            archived: false,
            loaded: true,
            updated_at: 700
          },
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

  describe "filter_sessions/4" do
    test "excludes subsessions by default and preserves ancestor root when subsession matches query" do
      sessions =
        [
          %{session_id: "coord-1", title: "Coordinator", cwd: "/repo", attention: "running"},
          %{
            session_id: "lane-a",
            title: "Worktree Explorer",
            cwd: "/private/tmp/wt-lane-1",
            attention: "idle",
            parent: %{session_id: "coord-1", conversation_id: "1", at_entry_id: "3", depth: 1}
          },
          %{session_id: "other-root", title: "Unrelated", cwd: "/other", attention: "idle"}
        ]
        |> Enum.map(&CatalogState.normalize_session/1)

      default_ids =
        sessions
        |> CatalogState.filter_sessions("all", "")
        |> Enum.map(& &1.session_id)

      assert default_ids == ["coord-1", "other-root"]

      search_ids =
        sessions
        |> CatalogState.filter_sessions("all", "wt-lane-1", include_subsessions: true)
        |> Enum.map(& &1.session_id)

      assert search_ids == ["coord-1", "lane-a"]

      attention_ids =
        sessions
        |> CatalogState.filter_sessions("attention", "", include_subsessions: true)
        |> Enum.map(& &1.session_id)

      assert attention_ids == ["other-root"]
    end

    test "keeps subsessions of an attention-needing root when filter_mode is attention and include_subsessions is true" do
      sessions =
        [
          %{session_id: "coord-idle", cwd: "/repo", attention: "idle"},
          %{
            session_id: "sub-child",
            cwd: "/private/tmp/wt-child",
            attention: "idle",
            parent: %{session_id: "coord-idle", conversation_id: "1", at_entry_id: "9", depth: 1}
          },
          %{session_id: "coord-running", cwd: "/repo", attention: "running"},
          %{
            session_id: "sub-other",
            cwd: "/private/tmp/wt-other",
            attention: "error",
            parent: %{
              session_id: "coord-running",
              conversation_id: "1",
              at_entry_id: "2",
              depth: 1
            }
          }
        ]
        |> Enum.map(&CatalogState.normalize_session/1)

      ids =
        sessions
        |> CatalogState.filter_sessions("attention", "", include_subsessions: true)
        |> Enum.map(& &1.session_id)

      assert ids == ["coord-idle", "sub-child"]
    end
  end

  describe "group_by_workspace/2" do
    test "excludes subsessions by default and attaches empty children list" do
      sessions =
        [
          %{session_id: "coord-1", cwd: "/repo", attention: "idle", updated_at: 10},
          %{
            session_id: "sub-1",
            cwd: "/private/tmp/wt-lane-1",
            attention: "running",
            updated_at: 20,
            parent: %{session_id: "coord-1", conversation_id: "1", at_entry_id: "4", depth: 1}
          }
        ]
        |> Enum.map(&CatalogState.normalize_session/1)

      groups = CatalogState.group_by_workspace(sessions, home: "/Users/test")

      assert length(groups) == 1
      [group] = groups
      assert group.cwd == "/repo"
      assert [%{session_id: "coord-1", children: []}] = group.sessions
    end

    test "nests subsessions hierarchically under their root parent across worktree cwds and preserves orphans" do
      sessions =
        [
          %{
            session_id: "coord-1",
            cwd: "/repo",
            attention: "idle",
            created_at: 1,
            updated_at: 10
          },
          %{
            session_id: "sub-b",
            cwd: "/private/tmp/wt-lane-b",
            attention: "idle",
            created_at: 30,
            updated_at: 35,
            parent: %{session_id: "coord-1", conversation_id: "1", at_entry_id: "8", depth: 1}
          },
          %{
            session_id: "sub-a",
            cwd: "/private/tmp/wt-lane-a",
            attention: "running",
            created_at: 20,
            updated_at: 25,
            parent: %{session_id: "coord-1", conversation_id: "1", at_entry_id: "5", depth: 1}
          },
          %{
            session_id: "grandchild-1",
            cwd: "/private/tmp/wt-grandchild",
            attention: "idle",
            created_at: 40,
            updated_at: 45,
            parent: %{session_id: "sub-a", conversation_id: "1", at_entry_id: "2", depth: 2}
          },
          %{
            session_id: "orphan-sub",
            cwd: "/private/tmp/wt-orphan",
            attention: "idle",
            created_at: 50,
            updated_at: 55,
            parent: %{
              session_id: "deleted-root",
              conversation_id: "1",
              at_entry_id: "1",
              depth: 1
            }
          }
        ]
        |> Enum.map(&CatalogState.normalize_session/1)

      groups =
        CatalogState.group_by_workspace(sessions,
          home: "/Users/test",
          include_subsessions: true
        )

      assert Enum.map(groups, & &1.cwd) == ["/repo", "/private/tmp/wt-orphan"]

      [repo_group, orphan_group] = groups

      assert [coord] = repo_group.sessions
      assert coord.session_id == "coord-1"
      assert Enum.map(coord.children, & &1.session_id) == ["sub-a", "sub-b"]

      [sub_a, sub_b] = coord.children
      assert sub_a.cwd == "/private/tmp/wt-lane-a"
      assert Enum.map(sub_a.children, & &1.session_id) == ["grandchild-1"]
      assert sub_b.children == []

      assert repo_group.counts.all == 1
      assert repo_group.counts.subsessions == 3
      assert repo_group.counts.subsessions_running == 1

      assert [%{session_id: "orphan-sub", children: []}] = orphan_group.sessions
    end
  end
end
