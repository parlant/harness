defmodule HWeb.TranscriptTest do
  use ExUnit.Case, async: true

  alias HWeb.Transcript

  describe "apply_snapshot/2 and memory bounds" do
    test "delegates to H.Transcript, returns normalized entries, and clears retained entry bodies" do
      t0 = Transcript.new(session_id: "s1", conversation_id: "1")

      payload =
        JSON.encode!(%{
          "seq" => 4,
          "before_entry_id" => "2",
          "entries" => [
            %{"id" => "4", "kind" => "assistant", "data" => %{"text" => "hi"}},
            %{"id" => "3", "kind" => "user", "data" => %{"text" => "hello"}}
          ],
          "docs" => %{
            "live" => %{},
            "inbox" => [],
            "agent" => %{"model" => "fake:coder", "thinking" => "medium"},
            "usage" => %{"input_tokens" => 3, "output_tokens" => 5, "total_tokens" => 8}
          }
        })

      assert {:ok, entries, t1} = Transcript.apply_snapshot(t0, payload)
      assert Enum.map(entries, & &1["id"]) == ["3", "4"]
      assert t1.reducer.entries == []

      assigns = Transcript.compact_assigns(t1)
      assert assigns.cursor_seq == 4
      assert assigns.before_entry_id == "2"
      assert assigns.has_more == true
      assert assigns.agent["model"] == "fake:coder"
      assert assigns.usage["total_tokens"] == 8
      assert assigns.run_active? == false
    end
  end

  describe "prepend_older_page/3" do
    test "joins an older assistant tool call to the trailing result and emits one summary on the next reply" do
      {:ok, [], snapshot} =
        Transcript.apply_snapshot(Transcript.new(), %{
          "seq" => 4,
          "before_entry_id" => "4",
          "entries" => [
            %{id: 4, kind: "tool_result", data: %{tool_call_id: "call", content: "tool body"}}
          ]
        })

      assert {[message], paged} =
               Transcript.prepend_older_page(
                 snapshot,
                 [
                   %{
                     id: 2,
                     kind: "assistant",
                     data: %{text: "Checking", tool_calls: [%{id: "call"}]}
                   }
                 ],
                 nil
               )

      assert message["id"] == "2"
      assert paged.head_activity == nil
      assert paged.tail_activity.id == "4"

      assert {:ok, [activity, reply], finished} =
               Transcript.apply_commit(paged, %{
                 "seq" => 5,
                 "appended_entries" => [%{id: 5, kind: "assistant", data: %{text: "Done"}}]
               })

      assert activity == %{"id" => "activity-4", "activity" => %{count: 1, status: :complete}}
      assert reply["id"] == "5"
      assert finished.tail_activity == nil
      assert finished.reducer.entries == []
    end
  end

  describe "apply_commit/2 and apply_ephemeral/2" do
    test "applies sequential commits, detects gaps, and patches ephemeral live state without mutating committed_docs" do
      t0 = Transcript.new(session_id: "s1", conversation_id: "1")

      {:ok, _entries, t1} =
        Transcript.apply_snapshot(t0, %{
          "seq" => 1,
          "entries" => [],
          "docs" => %{"live" => %{}, "inbox" => [], "agent" => %{}, "usage" => %{}}
        })

      assert {:ok, t_eph} =
               Transcript.apply_ephemeral(t1, %{
                 "base_seq" => 1,
                 "doc_ops" => %{
                   "live" => [
                     ["set", ["run"], %{"turns" => 1}],
                     ["append_text", ["generation", "message", "text"], "working..."]
                   ]
                 }
               })

      eph_assigns = Transcript.compact_assigns(t_eph)
      assert eph_assigns.run_active? == true
      assert eph_assigns.ephemeral_live["generation"]["message"]["text"] == "working..."
      assert eph_assigns.committed_docs["live"] == %{}

      assert {:gap, ^t_eph} =
               Transcript.apply_commit(t_eph, %{
                 "seq" => 5,
                 "appended_entries" => [],
                 "doc_ops" => %{}
               })

      assert {:ok, [appended], t2} =
               Transcript.apply_commit(t_eph, %{
                 "seq" => 2,
                 "appended_entries" => [
                   %{"id" => "1", "kind" => "assistant", "data" => %{"text" => "done"}}
                 ],
                 "doc_ops" => %{"live" => [["replace", %{}]]}
               })

      assert appended["id"] == "1"
      assert appended["data"]["text"] == "done"
      assert t2.reducer.entries == []
      assert Transcript.compact_assigns(t2).run_active? == false
      assert Transcript.compact_assigns(t2).cursor_seq == 2
    end
  end

  describe "subagent tool_call and tool_result projection" do
    test "does not leave stuck incomplete activity lines or liveWorking spinners for parallel subagent rounds" do
      {:ok, rows, t1} =
        Transcript.apply_snapshot(Transcript.new(session_id: "p1", conversation_id: "1"), %{
          "seq" => 10,
          "entries" => [
            %{
              "id" => "1",
              "kind" => "user",
              "data" => %{"content" => [%{"type" => "text", "text" => "Delegate two tasks"}]}
            },
            %{
              "id" => "2",
              "kind" => "assistant",
              "data" => %{
                "content" => [],
                "tool_calls" => [
                  %{"id" => "sub_1", "name" => "subagent", "arguments" => %{"mode" => "await"}},
                  %{"id" => "sub_2", "name" => "subagent", "arguments" => %{"mode" => "await"}}
                ]
              }
            },
            %{
              "id" => "3",
              "kind" => "tool_result",
              "data" => %{
                "tool_call_id" => "sub_1",
                "name" => "subagent",
                "content" => [%{"type" => "text", "text" => "Subagent 1 finished"}]
              }
            }
          ],
          "docs" => %{
            "live" => %{
              "run" => %{"task_id" => "9", "turns" => 2},
              "tools" => %{
                "sub_1" => %{"id" => "sub_1", "name" => "subagent", "status" => "done"},
                "sub_2" => %{"id" => "sub_2", "name" => "subagent", "status" => "waiting"}
              }
            },
            "inbox" => [],
            "agent" => %{},
            "usage" => %{}
          }
        })

      # Only visible entries (user, assistant subagent card, tool_result subagent card) — zero bogus activity rows!
      assert Enum.map(rows, & &1["id"]) == ["1", "2", "3"]
      assert t1.tail_activity == nil

      # Live summary does not show a spinning Working activity while only parked waiting on sub_2
      live1 = Transcript.compact_assigns(t1).ephemeral_live
      assert HWeb.Activity.live_summary(t1.tail_activity, live1, %{}, false) == nil

      # When sub_2 settles and next turn starts with a bash tool call, no stale "incomplete" row appears!
      {:ok, commit_rows, t2} =
        Transcript.apply_commit(t1, %{
          "seq" => 11,
          "appended_entries" => [
            %{
              "id" => "4",
              "kind" => "tool_result",
              "data" => %{
                "tool_call_id" => "sub_2",
                "name" => "subagent",
                "content" => [%{"type" => "text", "text" => "Subagent 2 finished"}]
              }
            },
            %{
              "id" => "5",
              "kind" => "assistant",
              "data" => %{"content" => [%{"type" => "text", "text" => "Both subagents done!"}]}
            }
          ],
          "doc_ops" => %{"live" => [["replace", %{}]]}
        })

      assert Enum.map(commit_rows, & &1["id"]) == ["4", "5"]
      refute Enum.any?(commit_rows, &Map.has_key?(&1, "activity"))
      assert t2.tail_activity == nil
    end

    test "preserves surrounding non-subagent tool activity across a subagent tool_result" do
      {:ok, rows, t1} =
        Transcript.apply_snapshot(Transcript.new(session_id: "p1", conversation_id: "1"), %{
          "seq" => 5,
          "entries" => [
            %{
              "id" => "1",
              "kind" => "assistant",
              "data" => %{
                "content" => [%{"type" => "text", "text" => "Running mixed tools"}],
                "tool_calls" => [
                  %{"id" => "sub_1", "name" => "subagent", "arguments" => %{"prompt" => "go"}},
                  %{"id" => "read_1", "name" => "read", "arguments" => %{"path" => "a.txt"}}
                ]
              }
            },
            %{
              "id" => "2",
              "kind" => "tool_result",
              "data" => %{
                "tool_call_id" => "read_1",
                "name" => "read",
                "content" => [%{"type" => "text", "text" => "body"}]
              }
            },
            %{
              "id" => "3",
              "kind" => "tool_result",
              "data" => %{
                "tool_call_id" => "sub_1",
                "name" => "subagent",
                "content" => [%{"type" => "text", "text" => "sub done"}]
              }
            },
            %{
              "id" => "4",
              "kind" => "assistant",
              "data" => %{"content" => [%{"type" => "text", "text" => "All done"}]}
            }
          ],
          "docs" => %{"live" => %{}, "inbox" => [], "agent" => %{}, "usage" => %{}}
        })

      assert [
               %{"id" => "1"},
               %{"id" => "3"},
               %{"id" => "activity-1", "activity" => %{count: 1, status: :complete}},
               %{"id" => "4"}
             ] = rows

      assert t1.tail_activity == nil
    end
  end
end
