defmodule H.TranscriptTest do
  use ExUnit.Case, async: true

  alias H.Transcript

  describe "new/1" do
    test "creates an empty reducer with nil seq and default docs" do
      t = Transcript.new(session_id: "s1", conversation_id: 1)

      assert t.session_id == "s1"
      assert t.conversation_id == "1"
      assert t.seq == nil
      assert t.entries == []
      assert MapSet.size(t.entry_ids) == 0
      assert t.has_more == false
      assert t.before_entry_id == nil

      expected_docs = %{"live" => %{}, "inbox" => [], "agent" => %{}, "usage" => %{}}
      assert t.committed_docs == expected_docs
      assert t.docs == expected_docs
    end
  end

  describe "apply_snapshot/2" do
    test "decodes JSON binary or map, normalizes/sorts entries, and sets cursor and docs" do
      t0 = Transcript.new()

      payload =
        JSON.encode!(%{
          "version" => 1,
          "session_id" => "demo",
          "conversation_id" => "1",
          "seq" => 10,
          "before_entry_id" => "8",
          "entries" => [
            %{"id" => "10", "kind" => "assistant", "data" => %{"text" => "hi"}},
            %{"id" => "9", "kind" => "user", "data" => %{"text" => "stale"}},
            %{"id" => "9", "kind" => "user", "data" => %{"text" => "yo"}}
          ],
          "docs" => %{
            "live" => %{"run" => %{"turns" => 1}},
            "inbox" => [],
            "agent" => %{"model" => "m1"},
            "usage" => %{"total_tokens" => 5}
          }
        })

      assert {:ok, t1} = Transcript.apply_snapshot(t0, payload)
      assert t1.session_id == "demo"
      assert t1.conversation_id == "1"
      assert t1.seq == 10
      assert t1.before_entry_id == "8"
      assert t1.has_more == true
      assert Enum.map(t1.entries, & &1["id"]) == ["9", "10"]
      assert hd(t1.entries)["data"]["text"] == "yo"
      assert MapSet.equal?(t1.entry_ids, MapSet.new(["9", "10"]))
      assert t1.committed_docs["agent"] == %{"model" => "m1"}
      assert t1.docs == t1.committed_docs
    end

    test "sets has_more to false when before_entry_id is nil" do
      t0 = Transcript.new()

      assert {:ok, t1} =
               Transcript.apply_snapshot(t0, %{
                 "seq" => 1,
                 "before_entry_id" => nil,
                 "entries" => [],
                 "docs" => %{}
               })

      assert t1.before_entry_id == nil
      assert t1.has_more == false
    end

    test "returns error on malformed JSON or missing seq" do
      t0 = Transcript.new()
      assert {:error, _} = Transcript.apply_snapshot(t0, "{bad")
      assert {:error, :invalid_snapshot} = Transcript.apply_snapshot(t0, %{"entries" => []})
    end
  end

  describe "apply_commit/2" do
    test "returns {:gap, t} before snapshot or when seq > cursor + 1" do
      t0 = Transcript.new()
      assert {:gap, ^t0} = Transcript.apply_commit(t0, %{"seq" => 1, "appended_entries" => []})

      {:ok, t1} =
        Transcript.apply_snapshot(t0, %{
          "seq" => 10,
          "entries" => [%{"id" => "10", "kind" => "user"}],
          "docs" => %{}
        })

      assert {:gap, ^t1} =
               Transcript.apply_commit(t1, %{
                 "seq" => 12,
                 "appended_entries" => [%{"id" => "12", "kind" => "assistant"}],
                 "doc_ops" => %{}
               })
    end

    test "returns {:stale, t} when seq <= cursor" do
      {:ok, t1} =
        Transcript.new()
        |> Transcript.apply_snapshot(%{
          "seq" => 10,
          "entries" => [%{"id" => "10", "kind" => "user"}],
          "docs" => %{}
        })

      assert {:stale, ^t1} =
               Transcript.apply_commit(t1, %{
                 "seq" => 10,
                 "appended_entries" => [%{"id" => "99", "kind" => "user"}],
                 "doc_ops" => %{}
               })

      assert {:stale, ^t1} =
               Transcript.apply_commit(t1, %{
                 "seq" => 9,
                 "appended_entries" => [%{"id" => "98", "kind" => "user"}],
                 "doc_ops" => %{}
               })
    end

    test "applies sequential commit, deduplicates entries, updates committed_docs, and clears stale ephemeral live state" do
      {:ok, t1} =
        Transcript.new()
        |> Transcript.apply_snapshot(%{
          "seq" => 10,
          "entries" => [%{"id" => "10", "kind" => "user"}],
          "docs" => %{
            "live" => %{"run" => %{"turns" => 1}},
            "inbox" => [],
            "agent" => %{"model" => "m1"},
            "usage" => %{"total_tokens" => 10}
          }
        })

      {:ok, t_eph} =
        Transcript.apply_ephemeral(t1, %{
          "base_seq" => 10,
          "doc_ops" => %{
            "live" => [["append_text", ["generation", "message", "text"], "streaming..."]]
          }
        })

      assert t_eph.docs["live"]["generation"]["message"]["text"] == "streaming..."
      assert t_eph.committed_docs["live"]["generation"] == nil

      commit_json =
        JSON.encode!(%{
          "version" => 1,
          "seq" => 11,
          "appended_entries" => [
            %{"id" => "10", "kind" => "user"},
            %{"id" => "11", "kind" => "assistant", "data" => %{"text" => "final"}}
          ],
          "doc_ops" => %{
            "live" => [["replace", %{"run" => %{"turns" => 2}}]],
            "usage" => [["set", ["total_tokens"], 42]]
          }
        })

      assert {:ok, t2, %{appended_entries: [new_entry]}} =
               Transcript.apply_commit(t_eph, commit_json)

      assert new_entry["id"] == "11"
      assert t2.seq == 11
      assert Enum.map(t2.entries, & &1["id"]) == ["10", "11"]
      assert MapSet.equal?(t2.entry_ids, MapSet.new(["10", "11"]))
      assert t2.committed_docs["live"] == %{"run" => %{"turns" => 2}}
      assert t2.committed_docs["usage"] == %{"total_tokens" => 42}
      assert t2.docs == t2.committed_docs
      refute Map.has_key?(t2.docs["live"], "generation")
    end
  end

  describe "apply_ephemeral/2" do
    test "ignores frames before snapshot or with mismatched base_seq" do
      t0 = Transcript.new()

      assert :ignored =
               Transcript.apply_ephemeral(t0, %{
                 "base_seq" => 0,
                 "doc_ops" => %{"live" => [["set", ["x"], 1]]}
               })

      {:ok, t1} =
        Transcript.apply_snapshot(t0, %{
          "seq" => 11,
          "entries" => [],
          "docs" => %{"live" => %{}}
        })

      assert :ignored =
               Transcript.apply_ephemeral(t1, %{
                 "base_seq" => 10,
                 "doc_ops" => %{"live" => [["append_text", ["generation", "text"], "STALE"]]}
               })

      assert :ignored =
               Transcript.apply_ephemeral(t1, %{
                 "base_seq" => 12,
                 "doc_ops" => %{"live" => [["append_text", ["generation", "text"], "FUTURE"]]}
               })

      assert t1.seq == 11
      assert t1.docs["live"] == %{}
      assert t1.committed_docs["live"] == %{}
    end

    test "applies both doc_ops.live and top-level ops to docs.live without mutating seq or committed_docs" do
      {:ok, t1} =
        Transcript.new()
        |> Transcript.apply_snapshot(%{
          "seq" => 11,
          "entries" => [],
          "docs" => %{"live" => %{"run" => %{"turns" => 1}}}
        })

      wire_json =
        JSON.encode!(%{
          "version" => 1,
          "session_id" => "demo",
          "conversation_id" => "1",
          "base_seq" => 11,
          "doc_ops" => %{
            "live" => [["append_text", ["generation", "message", "text"], "Hel"]]
          }
        })

      assert {:ok, t2} = Transcript.apply_ephemeral(t1, wire_json)

      assert {:ok, t3} =
               Transcript.apply_ephemeral(t2, %{
                 "base_seq" => 11,
                 "ops" => [["append_text", ["generation", "message", "text"], "lo"]]
               })

      assert t3.seq == 11
      assert t3.committed_docs["live"] == %{"run" => %{"turns" => 1}}
      assert t3.docs["live"]["run"] == %{"turns" => 1}
      assert t3.docs["live"]["generation"]["message"]["text"] == "Hello"
    end
  end

  describe "prepend_older_page/3" do
    test "sorts ascending, deduplicates against existing entries, and updates cursor and has_more" do
      {:ok, t1} =
        Transcript.new()
        |> Transcript.apply_snapshot(%{
          "seq" => 10,
          "before_entry_id" => "8",
          "entries" => [
            %{"id" => "9", "kind" => "user"},
            %{"id" => "10", "kind" => "assistant"}
          ],
          "docs" => %{}
        })

      t2 =
        Transcript.prepend_older_page(
          t1,
          [
            %{"id" => "9", "kind" => "user"},
            %{"id" => "8", "kind" => "assistant"},
            %{"id" => "7", "kind" => "user"}
          ],
          "6"
        )

      assert Enum.map(t2.entries, & &1["id"]) == ["7", "8", "9", "10"]
      assert MapSet.equal?(t2.entry_ids, MapSet.new(["7", "8", "9", "10"]))
      assert t2.before_entry_id == "6"
      assert t2.has_more == true

      t3 =
        Transcript.prepend_older_page(
          t2,
          [
            %{"id" => "2", "kind" => "user"},
            %{"id" => "6", "kind" => "assistant"}
          ],
          nil
        )

      assert Enum.map(t3.entries, & &1["id"]) == ["2", "6", "7", "8", "9", "10"]
      assert t3.before_entry_id == nil
      assert t3.has_more == false
    end
  end
end
