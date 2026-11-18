defmodule H.DocumentTest do
  use ExUnit.Case, async: true

  alias H.{Document, Storage}

  describe "apply_op/2 and apply_ops/2" do
    test "supports replace, r, set, append_text, and delete" do
      assert %{"b" => 2} == Document.apply_ops(%{"a" => 1}, [["replace", %{"b" => 2}]])
      assert %{"c" => 3} == Document.apply_ops(%{"a" => 1}, [["r", %{"c" => 3}]])

      doc0 = %{"run" => %{"turns" => 1}, "items" => ["x", "y"]}

      doc1 =
        Document.apply_ops(doc0, [
          ["set", ["run", "turns"], 2],
          ["set", ["generation", "message", "role"], "assistant"],
          ["set", ["items", 1], "z"]
        ])

      assert doc0["run"]["turns"] == 1
      assert doc0["generation"] == nil
      assert doc1["run"]["turns"] == 2
      assert doc1["generation"]["message"]["role"] == "assistant"
      assert doc1["items"] == ["x", "z"]

      doc2 =
        Document.apply_ops(doc1, [
          ["append_text", ["generation", "message", "text"], "Hello"],
          ["append_text", ["generation", "message", "text"], " world"]
        ])

      assert doc2["generation"]["message"]["text"] == "Hello world"

      doc3 =
        Document.apply_ops(doc2, [
          ["delete", ["generation", "message", "role"]],
          ["delete", ["items", 0]],
          ["delete", ["missing", "nested"]]
        ])

      refute Map.has_key?(doc3["generation"]["message"], "role")
      assert doc3["items"] == ["z"]
    end

    test "mutation helpers return {new_doc, delta_ops}" do
      {doc, ops1} = Document.set(%{}, ["a", "b"], 42)
      assert doc == %{"a" => %{"b" => 42}}
      assert ops1 == [["set", ["a", "b"], 42]]

      {doc2, ops2} = Document.append_text(doc, ["a", "text"], "hi")
      assert doc2["a"]["text"] == "hi"
      assert ops2 == [["append_text", ["a", "text"], "hi"]]

      {doc3, ops3} = Document.delete(doc2, ["a", "b"])
      assert doc3 == %{"a" => %{"text" => "hi"}}
      assert ops3 == [["delete", ["a", "b"]]]
    end
  end

  describe "configure_agent/2 and accumulate_usage/2" do
    test "updates only known agent fields and emits set ops" do
      agent = Document.initial("agent")

      {updated, ops} =
        Document.configure_agent(agent, %{
          model: "fake:coder",
          thinking: "high",
          max_turns: 12,
          ignored: "nope"
        })

      assert updated["model"] == "fake:coder"
      assert updated["thinking"] == "high"
      assert updated["max_turns"] == 12
      assert updated["tools"] == ["read", "write", "edit", "bash", "search_history"]

      assert ops == [
               ["set", ["model"], "fake:coder"],
               ["set", ["thinking"], "high"],
               ["set", ["max_turns"], 12]
             ]
    end

    test "accumulates usage counters and cost" do
      usage0 = Document.initial("usage")

      {usage1, ops1} =
        Document.accumulate_usage(usage0, %{
          input_tokens: 100,
          output_tokens: 40,
          cost: 0.0025
        })

      assert usage1 == %{
               "input_tokens" => 100,
               "output_tokens" => 40,
               "total_tokens" => 140,
               "cost" => 0.0025
             }

      assert ops1 == [["replace", usage1]]

      {usage2, _} =
        Document.accumulate_usage(usage1, %{
          "input_tokens" => 50,
          "output_tokens" => 10,
          "total_tokens" => 60,
          "cost" => 0.001
        })

      assert usage2 == %{
               "input_tokens" => 150,
               "output_tokens" => 50,
               "total_tokens" => 200,
               "cost" => 0.0035
             }
    end
  end

  describe "fork_docs/4" do
    test "uses as_of_seq for agent and resets live, inbox, and usage to initial" do
      {:ok, store} = Storage.open(H.Storage.Memory, session_id: "doc-test", cwd: "/tmp/work")

      agent_v1 = Map.put(Document.initial("agent"), "model", "model-v1")
      agent_v2 = Map.put(Document.initial("agent"), "model", "model-v2")
      dirty_live = %{"run" => %{"task_id" => "99", "turns" => 3}}
      dirty_inbox = [%{"text" => "queued"}]

      dirty_usage = %{
        "input_tokens" => 500,
        "output_tokens" => 100,
        "total_tokens" => 600,
        "cost" => 0.1
      }

      {:ok, %{seqs: [seq1]}, store} =
        Storage.commit(store, [
          [
            {:put_doc, {:conversation, 1, "agent"}, Document.wrap("agent", agent_v1)},
            {:append_entry, %{id: 2, conversation_id: 1, kind: "user", data: %{"text" => "hi"}}}
          ]
        ])

      {:ok, %{seqs: [_seq2]}, store} =
        Storage.commit(store, [
          [
            {:put_doc, {:conversation, 1, "agent"}, Document.wrap("agent", agent_v2)},
            {:put_doc, {:conversation, 1, "live"}, Document.wrap("live", dirty_live)},
            {:put_doc, {:conversation, 1, "inbox"}, Document.wrap("inbox", dirty_inbox)},
            {:put_doc, {:conversation, 1, "usage"}, Document.wrap("usage", dirty_usage)},
            {:append_entry,
             %{id: 3, conversation_id: 1, kind: "user", data: %{"text" => "later"}}}
          ]
        ])

      assert {:ok, forked, _store} = Document.fork_docs(store, 1, seq1)
      assert forked["agent"]["model"] == "model-v1"
      assert forked["live"] == %{}
      assert forked["inbox"] == []
      assert forked["usage"] == Document.initial("usage")
    end
  end
end
