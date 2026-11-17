defmodule H.SessionTest do
  use ExUnit.Case, async: true

  alias H.Session

  describe "new/2" do
    test "creates a root conversation and stores an absolute working directory" do
      session = Session.new("project", "/work/project/../project")

      assert session.id == "project"
      assert session.cwd == "/work/project"
      assert {:ok, []} = Session.entries(session, 1)
    end

    test "rejects a relative working directory" do
      assert_raise ArgumentError, "working directory must be absolute", fn ->
        Session.new("project", "relative")
      end
    end
  end

  describe "append/4" do
    test "appends immutable entries to one conversation" do
      original = Session.new("project", "/work/project")
      assert {:ok, updated, entry} = Session.append(original, 1, "user", %{text: "Hello"})

      assert entry.conversation_id == 1
      assert entry.kind == "user"
      assert entry.data == %{text: "Hello"}
      assert {:ok, []} = Session.entries(original, 1)
      assert {:ok, [^entry]} = Session.entries(updated, 1)
    end

    test "rejects an unknown conversation" do
      session = Session.new("project", "/work/project")

      assert {:error, :conversation_not_found} =
               Session.append(session, 99, "user", %{text: "Hello"})
    end
  end

  describe "create_conversation/1" do
    test "creates an independent conversation without inherited entries" do
      {session, _first, _second} = history()
      assert {:ok, session, other} = Session.create_conversation(session)

      assert {:ok, session, entry} =
               Session.append(session, other.id, "user", %{text: "Independent"})

      assert is_nil(other.parent)
      assert {:ok, [^entry]} = Session.entries(session, other.id)
      assert {:ok, [_, _]} = Session.entries(session, 1)
    end
  end

  describe "fork/3" do
    test "shares the prefix without copying entries or inheriting later parent appends" do
      {session, first, _second} = history()
      original_count = map_size(session.entries)
      assert {:ok, forked, branch} = Session.fork(session, 1, first.id)

      assert branch.parent == %{conversation_id: 1, at: first.id}
      assert map_size(forked.entries) == original_count

      assert {:ok, forked, parent_entry} =
               Session.append(forked, 1, "user", %{text: "Parent later"})

      assert {:ok, forked, child_entry} =
               Session.append(forked, branch.id, "user", %{text: "Child"})

      assert {:ok, [^first, ^child_entry]} = Session.entries(forked, branch.id)
      assert {:ok, [^first, _, ^parent_entry]} = Session.entries(forked, 1)
    end

    test "can fork at an inherited entry without leaking any descendant suffix" do
      {session, first, second} = history()
      assert {:ok, session, branch} = Session.fork(session, 1, second.id)

      assert {:ok, session, _child_entry} =
               Session.append(session, branch.id, "user", %{text: "Child"})

      assert {:ok, session, nested} = Session.fork(session, branch.id, first.id)

      assert {:ok, [^first]} = Session.entries(session, nested.id)
    end

    test "rejects an entry that is not visible through the source conversation" do
      {session, first, second} = history()
      assert {:ok, session, branch} = Session.fork(session, 1, first.id)

      assert {:error, :entry_not_visible} = Session.fork(session, branch.id, second.id)
      assert {:error, :entry_not_visible} = Session.fork(session, 1, 999)
    end

    test "rejects an unknown source conversation" do
      {session, first, _second} = history()

      assert {:error, :conversation_not_found} = Session.fork(session, 99, first.id)
    end

    test "allocates distinct session-local IDs across conversations and entries" do
      {session, first, second} = history()
      assert {:ok, session, branch} = Session.fork(session, 1, second.id)
      assert {:ok, session, entry} = Session.append(session, branch.id, "user", %{text: "Branch"})
      assert {:ok, _session, other} = Session.create_conversation(session)

      assert [1, first.id, second.id, branch.id, entry.id, other.id] == [1, 2, 3, 4, 5, 6]
    end
  end

  describe "entries/2" do
    test "returns entries oldest first, across several inherited segments" do
      {session, first, second} = history()
      assert {:ok, session, branch} = Session.fork(session, 1, second.id)
      assert {:ok, session, third} = Session.append(session, branch.id, "user", %{text: "Third"})
      assert {:ok, session, nested} = Session.fork(session, branch.id, third.id)

      assert {:ok, session, fourth} =
               Session.append(session, nested.id, "assistant", %{text: "Fourth"})

      assert {:ok, [^first, ^second, ^third, ^fourth]} = Session.entries(session, nested.id)
    end

    test "rejects an unknown conversation" do
      assert {:error, :conversation_not_found} =
               Session.entries(Session.new("project", "/work/project"), 99)
    end
  end

  defp history do
    session = Session.new("project", "/work/project")
    {:ok, session, first} = Session.append(session, 1, "user", %{text: "First"})
    {:ok, session, second} = Session.append(session, 1, "assistant", %{text: "Second"})
    {session, first, second}
  end
end
