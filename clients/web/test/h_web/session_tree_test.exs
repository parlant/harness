defmodule HWeb.SessionTreeTest do
  use ExUnit.Case, async: true

  alias HWeb.SessionTree

  defp sample_tree do
    %{
      conversations: [
        %{id: "1", parent: nil, owner: "ownerless", leaf_entry_id: "5"},
        %{
          id: "2",
          parent: %{conversation_id: "1", at: "2"},
          owner: "ownerless",
          leaf_entry_id: "7"
        },
        %{
          id: "3",
          parent: %{conversation_id: "1", at: "2"},
          owner: "ownerless",
          leaf_entry_id: "2"
        }
      ],
      nodes: [
        %{
          id: "1",
          parent_id: nil,
          conversation_id: "1",
          kind: "user",
          preview: "First question",
          has_text: true,
          tool_name: nil,
          aborted: false,
          is_error: false
        },
        %{
          id: "2",
          parent_id: "1",
          conversation_id: "1",
          kind: "assistant",
          preview: "First answer",
          has_text: true,
          tool_name: nil,
          aborted: false,
          is_error: false
        },
        %{
          id: "3",
          parent_id: "2",
          conversation_id: "1",
          kind: "assistant",
          preview: "[tool: read mix.exs]",
          has_text: false,
          tool_name: nil,
          aborted: false,
          is_error: false
        },
        %{
          id: "4",
          parent_id: "3",
          conversation_id: "1",
          kind: "tool_result",
          preview: "[read: mix.exs]",
          has_text: false,
          tool_name: "read",
          aborted: false,
          is_error: false
        },
        %{
          id: "5",
          parent_id: "4",
          conversation_id: "1",
          kind: "assistant",
          preview: "Final branch 1 reply",
          has_text: true,
          tool_name: nil,
          aborted: false,
          is_error: false
        },
        %{
          id: "6",
          parent_id: "2",
          conversation_id: "2",
          kind: "user",
          preview: "Forked question",
          has_text: true,
          tool_name: nil,
          aborted: false,
          is_error: false
        },
        %{
          id: "7",
          parent_id: "6",
          conversation_id: "2",
          kind: "assistant",
          preview: "Forked answer",
          has_text: true,
          tool_name: nil,
          aborted: false,
          is_error: false
        }
      ],
      truncated: false
    }
  end

  test "keeps single-child chains flat and indents multi-branch splits with connectors and active path" do
    view = SessionTree.project(sample_tree(), current_conversation_id: "2", filter: "default")

    # Node 3 (tool-only assistant) is hidden in default mode; node 4 attaches under 2 alongside node 6.
    # Because conversation 2 is active, branch [6 -> 7] sorts before branch [4 -> 5].
    ids = Enum.map(view.rows, & &1.id)
    assert ids == ["1", "2", "6", "7", "4", "5"]

    rows = Map.new(view.rows, &{&1.id, &1})

    # Root chain 1 -> 2 stays flat (indent 0, empty prefix)
    assert rows["1"].indent == 0
    assert rows["1"].prefix == ""
    assert rows["2"].indent == 0
    assert rows["2"].prefix == ""
    assert rows["2"].foldable? == true

    # Empty fork conv #3 shares leaf_entry_id "2"
    assert [%{id: "3", current?: false}] = rows["2"].conversation_tips

    # Active branch comes first with ├─ connector, its child 7 groups under it with vertical gutter
    assert rows["6"].prefix == "├─ "
    assert rows["6"].active_path? == true
    assert rows["7"].prefix == "│     "
    assert rows["7"].active_path? == true
    assert rows["7"].current_leaf? == true
    assert [%{id: "2", current?: true}] = rows["7"].conversation_tips

    # Sibling branch starts with └─ connector, its child has blank gutter
    assert rows["4"].prefix == "└─ "
    assert rows["4"].active_path? == false
    assert rows["5"].prefix == "      "
    assert [%{id: "1", current?: false}] = rows["5"].conversation_tips
  end

  test "supports no-tools, user-only, all filter modes, and search query" do
    no_tools =
      SessionTree.project(sample_tree(), current_conversation_id: "1", filter: "no-tools")

    refute Enum.any?(no_tools.rows, &(&1.kind == "tool_result"))
    assert Enum.map(no_tools.rows, & &1.id) == ["1", "2", "5", "6", "7"]

    user_only =
      SessionTree.project(sample_tree(), current_conversation_id: "1", filter: "user-only")

    assert Enum.map(user_only.rows, & &1.id) == ["1", "6"]
    # Single-child filtered chain 1 -> 6 stays flat!
    assert Enum.all?(user_only.rows, &(&1.indent == 0))

    all_view = SessionTree.project(sample_tree(), current_conversation_id: "1", filter: "all")
    assert Enum.map(all_view.rows, & &1.id) == ["1", "2", "3", "4", "5", "6", "7"]

    searched = SessionTree.project(sample_tree(), current_conversation_id: "1", query: "forked")
    assert Enum.map(searched.rows, & &1.id) == ["6", "7"]
  end

  test "folds and counts hidden descendants on branch points" do
    folded =
      SessionTree.project(sample_tree(),
        current_conversation_id: "1",
        filter: "default",
        folded_ids: MapSet.new(["2"])
      )

    assert Enum.map(folded.rows, & &1.id) == ["1", "2"]
    node2 = Enum.find(folded.rows, &(&1.id == "2"))
    assert node2.folded? == true
    assert node2.foldable? == true
    assert node2.hidden_descendants == 4
  end
end
