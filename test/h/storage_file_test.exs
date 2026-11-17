defmodule H.Storage.FileTest do
  use H.Storage.Conformance

  alias H.Storage

  def open_store(opts \\ []) do
    dir = unique_dir()
    on_exit(fn -> File.rm_rf!(dir) end)
    Storage.open(H.Storage.File, Keyword.put_new(opts, :dir, dir))
  end

  describe "open/1 options and directory creation" do
    test "creates missing directory with 0700 permissions and validates options" do
      base = unique_dir()
      dir = Path.join(base, "nested/session")
      on_exit(fn -> File.rm_rf!(base) end)

      assert {:error, :missing_dir} = Storage.open(H.Storage.File, [])

      assert {:error, {:invalid_sync, :bogus}} =
               Storage.open(H.Storage.File, dir: dir, sync: :bogus)

      assert {:error, {:invalid_snapshot_every, 0}} =
               Storage.open(H.Storage.File, dir: dir, snapshot_every: 0)

      assert {:ok, store} = Storage.open(H.Storage.File, dir: dir, sync: :none)
      Storage.close(store)

      stat = File.stat!(dir)
      assert Bitwise.band(stat.mode, 0o777) == 0o700
    end
  end

  describe "persistence and mint_id/1 across reopen" do
    test "persists minted ID watermark even when minted IDs are unused in the commit" do
      dir = unique_dir()
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, store} = Storage.open(H.Storage.File, dir: dir, session_id: "s1", cwd: "/tmp/work")
      {:ok, 2, store} = Storage.mint_id(store)
      {:ok, 3, store} = Storage.mint_id(store)
      {:ok, 4, store} = Storage.mint_id(store)

      # Commit without using IDs 2, 3, or 4
      assert {:ok, %{stored: 1, seqs: [1], refused: nil}, store} =
               Storage.commit(store, [[{:put_session_meta, %{title: "Persisted"}}]])

      :ok = Storage.close(store)

      {:ok, reopened} = Storage.open(H.Storage.File, dir: dir)

      assert {:ok, 5, reopened} = Storage.mint_id(reopened)
      assert {:ok, bootstrap, reopened} = Storage.read_bootstrap(reopened)
      assert bootstrap.session_meta.title == "Persisted"
      assert bootstrap.next_id == 6
      :ok = Storage.close(reopened)
    end

    test "reopen recovers full state including conversations, submissions, tasks, and doc history" do
      dir = unique_dir()
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, store} = Storage.open(H.Storage.File, dir: dir)
      {:ok, cid, store} = Storage.mint_id(store)
      {:ok, eid, store} = Storage.mint_id(store)
      {:ok, tid, store} = Storage.mint_id(store)

      assert {:ok, %{seqs: [1, 2]}, store} =
               Storage.commit(store, [
                 [
                   {:put_conversation, %{id: cid, parent: nil, owner: {:task, tid}}},
                   {:put_task,
                    %{
                      id: tid,
                      kind: "tool_exec",
                      version: 1,
                      status: "running",
                      owner: {:conversation, 1},
                      checkpoint: %{"step" => "init"}
                    }},
                   {:put_doc, {:conversation, cid, "agent"}, %{"model" => "m1"}}
                 ],
                 [
                   {:append_entry,
                    %{id: eid, conversation_id: cid, kind: "user", data: %{"text" => "hi"}}},
                   {:put_submission,
                    %{
                      request_id: "req-persist",
                      fingerprint: "fp-persist",
                      kind: "input",
                      status: "done",
                      entry_id: eid,
                      notify: {tid, "answer"}
                    }},
                   {:put_doc, {:conversation, cid, "agent"}, %{"model" => "m2"}}
                 ]
               ])

      :ok = Storage.close(store)

      {:ok, reopened} = Storage.open(H.Storage.File, dir: dir)

      assert {:ok, bootstrap, reopened} = Storage.read_bootstrap(reopened)
      assert bootstrap.seq == 2
      assert bootstrap.conversations[cid].owner == {:task, tid}
      assert bootstrap.tasks[tid].owner == {:conversation, 1}
      assert bootstrap.submissions["req-persist"].notify == {tid, "answer"}
      assert bootstrap.docs[{:conversation, cid, "agent"}] == %{"model" => "m2"}

      assert {:ok, %{"model" => "m1"}, reopened} =
               Storage.get_doc(reopened, {:conversation, cid, "agent"}, as_of_seq: 1)

      assert {:ok, %{id: ^eid, seq: 2, data: %{"text" => "hi"}}, reopened} =
               Storage.get_entry(reopened, eid)

      :ok = Storage.close(reopened)
    end
  end

  describe "torn-tail WAL recovery" do
    test "truncates final frame at every byte offset and preserves earlier commits" do
      template_dir = unique_dir()
      on_exit(fn -> File.rm_rf!(template_dir) end)

      {:ok, store} = Storage.open(H.Storage.File, dir: template_dir, sync: :none)
      {:ok, e1, store} = Storage.mint_id(store)
      {:ok, e2, store} = Storage.mint_id(store)
      {:ok, e3, store} = Storage.mint_id(store)

      {:ok, _, store} =
        Storage.commit(store, [
          [{:append_entry, %{id: e1, conversation_id: 1, kind: "user", data: %{"n" => 1}}}]
        ])

      {:ok, _, store} =
        Storage.commit(store, [
          [{:append_entry, %{id: e2, conversation_id: 1, kind: "user", data: %{"n" => 2}}}]
        ])

      log_path = Path.join(template_dir, "commit.log")
      valid_offset = File.stat!(log_path).size

      {:ok, _, store} =
        Storage.commit(store, [
          [{:append_entry, %{id: e3, conversation_id: 1, kind: "user", data: %{"n" => 3}}}]
        ])

      :ok = Storage.close(store)

      full_bytes = File.read!(log_path)
      full_size = byte_size(full_bytes)
      assert full_size > valid_offset + 13

      # Test truncation at EVERY byte offset inside the final frame (header + payload)
      for cut_at <- (valid_offset + 1)..(full_size - 1) do
        test_dir = unique_dir()
        File.mkdir_p!(test_dir)
        File.write!(Path.join(test_dir, "commit.log"), binary_part(full_bytes, 0, cut_at))

        try do
          assert {:ok, recovered} = Storage.open(H.Storage.File, dir: test_dir, sync: :none)
          assert File.stat!(Path.join(test_dir, "commit.log")).size == valid_offset

          assert {:ok, %{seq: 2}, recovered} = Storage.read_bootstrap(recovered)
          assert {:ok, %{id: ^e1}, recovered} = Storage.get_entry(recovered, e1)
          assert {:ok, %{id: ^e2}, recovered} = Storage.get_entry(recovered, e2)
          assert {:ok, nil, recovered} = Storage.get_entry(recovered, e3)

          # Subsequent commits append cleanly after recovery
          {:ok, e4, recovered} = Storage.mint_id(recovered)

          assert {:ok, %{stored: 1, seqs: [3], refused: nil}, recovered} =
                   Storage.commit(recovered, [
                     [
                       {:append_entry,
                        %{id: e4, conversation_id: 1, kind: "user", data: %{"n" => 4}}}
                     ]
                   ])

          :ok = Storage.close(recovered)

          assert {:ok, reopened} = Storage.open(H.Storage.File, dir: test_dir, sync: :none)
          assert {:ok, %{id: ^e4, seq: 3}, reopened} = Storage.get_entry(reopened, e4)
          :ok = Storage.close(reopened)
        after
          File.rm_rf!(test_dir)
        end
      end
    end

    test "discards final frame with corrupted magic, version, CRC32, or payload byte" do
      template_dir = unique_dir()
      on_exit(fn -> File.rm_rf!(template_dir) end)

      {:ok, store} = Storage.open(H.Storage.File, dir: template_dir, sync: :none)
      {:ok, e1, store} = Storage.mint_id(store)
      {:ok, e2, store} = Storage.mint_id(store)

      {:ok, _, store} =
        Storage.commit(store, [
          [{:append_entry, %{id: e1, conversation_id: 1, kind: "user", data: %{"n" => 1}}}]
        ])

      log_path = Path.join(template_dir, "commit.log")
      valid_offset = File.stat!(log_path).size

      {:ok, _, store} =
        Storage.commit(store, [
          [{:append_entry, %{id: e2, conversation_id: 1, kind: "user", data: %{"n" => 2}}}]
        ])

      :ok = Storage.close(store)

      full_bytes = File.read!(log_path)
      full_size = byte_size(full_bytes)

      corrupt_offsets = [
        # Magic
        valid_offset,
        # Version
        valid_offset + 4,
        # Length
        valid_offset + 7,
        # CRC32
        valid_offset + 10,
        # Middle of payload
        div(valid_offset + 13 + full_size, 2),
        # Last byte of payload
        full_size - 1
      ]

      for byte_idx <- corrupt_offsets do
        test_dir = unique_dir()
        File.mkdir_p!(test_dir)

        <<prefix::binary-size(^byte_idx), target::8, suffix::binary>> = full_bytes
        corrupted = <<prefix::binary, Bitwise.bxor(target, 0xFF)::8, suffix::binary>>
        File.write!(Path.join(test_dir, "commit.log"), corrupted)

        try do
          assert {:ok, recovered} = Storage.open(H.Storage.File, dir: test_dir, sync: :none)
          assert File.stat!(Path.join(test_dir, "commit.log")).size == valid_offset
          assert {:ok, %{seq: 1}, recovered} = Storage.read_bootstrap(recovered)
          assert {:ok, %{id: ^e1}, recovered} = Storage.get_entry(recovered, e1)
          assert {:ok, nil, recovered} = Storage.get_entry(recovered, e2)

          {:ok, e3, recovered} = Storage.mint_id(recovered)

          assert {:ok, %{stored: 1, seqs: [2], refused: nil}, recovered} =
                   Storage.commit(recovered, [
                     [
                       {:append_entry,
                        %{id: e3, conversation_id: 1, kind: "user", data: %{"n" => 3}}}
                     ]
                   ])

          :ok = Storage.close(recovered)
        after
          File.rm_rf!(test_dir)
        end
      end
    end
  end

  describe "snapshot rotation and reopen" do
    test "rotates snapshot at snapshot_every, truncates commit.log, and cleans old snapshots" do
      dir = unique_dir()
      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, store} = Storage.open(H.Storage.File, dir: dir, snapshot_every: 3, sync: :sync)

      {entries, store} =
        Enum.map_reduce(1..7, store, fn n, acc ->
          {:ok, eid, acc} = Storage.mint_id(acc)

          {:ok, %{seqs: [seq], refused: nil}, acc} =
            Storage.commit(acc, [
              [
                {:append_entry, %{id: eid, conversation_id: 1, kind: "user", data: %{"n" => n}}},
                {:put_doc, {:conversation, 1, "agent"}, %{"step" => n}}
              ]
            ])

          assert seq == n
          {eid, acc}
        end)

      # After 6 commits, snapshot.6.json should exist and snapshot.3.json removed.
      # Commit 7 is in commit.log.
      assert File.exists?(Path.join(dir, "snapshot.6.json"))
      refute File.exists?(Path.join(dir, "snapshot.3.json"))
      assert File.stat!(Path.join(dir, "commit.log")).size > 0

      :ok = Storage.close(store)

      {:ok, reopened} = Storage.open(H.Storage.File, dir: dir, snapshot_every: 3, sync: :sync)

      assert {:ok, bootstrap, reopened} = Storage.read_bootstrap(reopened)
      assert bootstrap.seq == 7
      assert bootstrap.docs[{:conversation, 1, "agent"}] == %{"step" => 7}

      # Historical as_of_seq across snapshot boundary
      assert {:ok, %{"step" => 2}, reopened} =
               Storage.get_doc(reopened, {:conversation, 1, "agent"}, as_of_seq: 2)

      assert {:ok, %{"step" => 7}, reopened} =
               Storage.get_doc(reopened, {:conversation, 1, "agent"}, as_of_seq: 7)

      # All 7 entries scannable
      assert {:ok, %{items: items, next_cursor: nil}, reopened} =
               Storage.scan_entries(reopened, %{conversation_id: 1, order: :asc})

      assert Enum.map(items, & &1.id) == entries

      # 2 more commits (total 3 since snapshot 6) should trigger snapshot.9.json
      {_, reopened} =
        Enum.reduce(8..9, {nil, reopened}, fn n, {_, acc} ->
          {:ok, eid, acc} = Storage.mint_id(acc)

          {:ok, _, acc} =
            Storage.commit(acc, [
              [{:append_entry, %{id: eid, conversation_id: 1, kind: "user", data: %{"n" => n}}}]
            ])

          {eid, acc}
        end)

      assert File.exists?(Path.join(dir, "snapshot.9.json"))
      refute File.exists?(Path.join(dir, "snapshot.6.json"))
      assert File.stat!(Path.join(dir, "commit.log")).size == 0
      :ok = Storage.close(reopened)
    end

    test "replays only frames with seq > snapshot_seq when commit.log overlaps snapshot" do
      dir = unique_dir()
      on_exit(fn -> File.rm_rf!(dir) end)

      # Create store without rotation to capture a full 3-commit commit.log
      {:ok, store} = Storage.open(H.Storage.File, dir: dir, snapshot_every: 100, sync: :none)

      {e1, store} =
        with {:ok, id, s} <- Storage.mint_id(store),
             {:ok, _, s} <-
               Storage.commit(s, [
                 [{:append_entry, %{id: id, conversation_id: 1, kind: "user", data: %{"n" => 1}}}]
               ]),
             do: {id, s}

      {e2, store} =
        with {:ok, id, s} <- Storage.mint_id(store),
             {:ok, _, s} <-
               Storage.commit(s, [
                 [{:append_entry, %{id: id, conversation_id: 1, kind: "user", data: %{"n" => 2}}}]
               ]),
             do: {id, s}

      :ok = Storage.close(store)
      saved_log = File.read!(Path.join(dir, "commit.log"))

      # Force snapshot at seq 2 via snapshot_every: 1 on a second commit, OR write snapshot at seq 2
      # Better: reopen with snapshot_every: 1, commit seq 3 (creates snapshot.3.json),
      # then simulate crash before truncation by restoring log with seq 1..2 and appending seq 3?
      # Even simpler: create snapshot at seq 2 by doing 2 commits with snapshot_every: 2 after copying log,
      # wait: let's test snapshot.2.json + full log containing seq 1, 2, 3!
      dir2 = unique_dir()
      on_exit(fn -> File.rm_rf!(dir2) end)

      {:ok, s2} = Storage.open(H.Storage.File, dir: dir2, snapshot_every: 2, sync: :none)

      {:ok, _, s2} =
        Storage.commit(s2, [
          [{:append_entry, %{id: e1, conversation_id: 1, kind: "user", data: %{"n" => 1}}}]
        ])

      {:ok, _, s2} =
        Storage.commit(s2, [
          [{:append_entry, %{id: e2, conversation_id: 1, kind: "user", data: %{"n" => 2}}}]
        ])

      assert File.exists?(Path.join(dir2, "snapshot.2.json"))
      # Now commit seq 3 so commit.log has seq 3
      {:ok, e3, s2} = Storage.mint_id(s2)

      {:ok, _, s2} =
        Storage.commit(s2, [
          [{:append_entry, %{id: e3, conversation_id: 1, kind: "user", data: %{"n" => 3}}}]
        ])

      :ok = Storage.close(s2)

      seq3_log = File.read!(Path.join(dir2, "commit.log"))
      # Prepend saved_log (seq 1 and seq 2) before seq3_log!
      File.write!(Path.join(dir2, "commit.log"), saved_log <> seq3_log)
      # Also leave behind an incomplete .tmp file and a corrupt newer snapshot
      File.write!(Path.join(dir2, "snapshot.99.tmp"), "partial")
      File.write!(Path.join(dir2, "snapshot.50.json"), "{corrupt")

      {:ok, recovered} = Storage.open(H.Storage.File, dir: dir2, snapshot_every: 10, sync: :none)

      assert {:ok, %{seq: 3}, recovered} = Storage.read_bootstrap(recovered)

      assert {:ok, %{items: items}, recovered} =
               Storage.scan_entries(recovered, %{conversation_id: 1, order: :asc})

      assert Enum.map(items, & &1.id) == [e1, e2, e3]
      :ok = Storage.close(recovered)
    end
  end

  defp unique_dir do
    Path.join(System.tmp_dir!(), "h-storage-file-test-#{System.unique_integer([:positive])}")
  end
end
