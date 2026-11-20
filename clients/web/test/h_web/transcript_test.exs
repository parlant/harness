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
end
