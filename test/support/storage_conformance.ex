defmodule H.Storage.Conformance do
  @moduledoc """
  Shared `ExUnit` conformance suite for any `H.Storage` backend.

  Using modules must define `open_store/1` returning `{:ok, H.Storage.t()}`.
  """

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: true

      alias H.Storage

      describe "open/1 and read_bootstrap/1" do
        test "initializes root conversation, seq 0, and next_id 2" do
          {:ok, store} = open_store([])

          assert {:ok, bootstrap, store} = Storage.read_bootstrap(store)

          assert bootstrap == %{
                   seq: 0,
                   next_id: 2,
                   session_meta: %{},
                   conversations: %{
                     1 => %{id: 1, parent: nil, owner: :ownerless, entry_ids: []}
                   },
                   tasks: %{},
                   submissions: %{},
                   docs: %{}
                 }

          :ok = Storage.close(store)
        end

        test "accepts optional session_id and cwd" do
          {:ok, store} = open_store(session_id: "sess-1", cwd: "/work/project")

          assert {:ok, bootstrap, store} = Storage.read_bootstrap(store)
          assert bootstrap.session_meta == %{session_id: "sess-1", cwd: "/work/project"}
          :ok = Storage.close(store)
        end
      end

      describe "mint_id/1" do
        test "returns strictly monotonic IDs starting at 2 and above stored IDs" do
          {:ok, store} = open_store([])

          assert {:ok, 2, store} = Storage.mint_id(store)
          assert {:ok, 3, store} = Storage.mint_id(store)
          assert {:ok, 4, store} = Storage.mint_id(store)

          assert {:ok, %{stored: 1, seqs: [1], refused: nil}, store} =
                   Storage.commit(store, [
                     [
                       {:append_entry,
                        %{id: 10, conversation_id: 1, kind: "user", data: %{"text" => "hi"}}}
                     ]
                   ])

          assert {:ok, 11, store} = Storage.mint_id(store)
          :ok = Storage.close(store)
        end
      end

      describe "commit/2" do
        test "empty batches list is a no-op" do
          {:ok, store} = open_store([])

          assert {:ok, %{stored: 0, seqs: [], refused: nil}, store} = Storage.commit(store, [])
          assert {:ok, %{seq: 0}, store} = Storage.read_bootstrap(store)
          :ok = Storage.close(store)
        end

        test "commits multiple batches sequentially with monotonic seqs and stamps records" do
          {:ok, store} = open_store([])

          {:ok, cid, store} = Storage.mint_id(store)
          {:ok, eid1, store} = Storage.mint_id(store)
          {:ok, eid2, store} = Storage.mint_id(store)
          {:ok, tid, store} = Storage.mint_id(store)

          batches = [
            [
              {:put_session_meta, %{"title" => "Demo", "incarnation" => 1}},
              {:put_conversation,
               %{
                 "id" => cid,
                 "parent" => %{"conversation_id" => 1, "at" => nil},
                 "owner" => {:task, tid}
               }},
              {:put_task,
               %{
                 "id" => tid,
                 "kind" => "agent_run",
                 "version" => 1,
                 "status" => "running",
                 "owner" => {:conversation, 1}
               }}
            ],
            [
              {:check, {:conversation_exists, cid}},
              {:append_entry,
               %{
                 "id" => eid1,
                 "conversation_id" => 1,
                 "kind" => "user",
                 "data" => %{"text" => "hello"}
               }},
              {:append_entry,
               %H.Entry{
                 id: eid2,
                 conversation_id: cid,
                 kind: "assistant",
                 data: %{"text" => "world"}
               }},
              {:put_submission,
               %{
                 "request_id" => "req-1",
                 "fingerprint" => "fp-1",
                 "kind" => "input",
                 "status" => "done",
                 "entry_id" => eid1
               }}
            ]
          ]

          assert {:ok, %{stored: 2, seqs: [1, 2], refused: nil}, store} =
                   Storage.commit(store, batches)

          assert {:ok, bootstrap, store} = Storage.read_bootstrap(store)
          assert bootstrap.seq == 2
          assert bootstrap.session_meta == %{title: "Demo", incarnation: 1}
          assert bootstrap.conversations[cid].owner == {:task, tid}
          assert bootstrap.tasks[tid].owner == {:conversation, 1}

          assert {:ok, e1, store} = Storage.get_entry(store, eid1)
          assert e1.seq == 2
          assert e1.data == %{"text" => "hello"}

          assert {:ok, e2, store} = Storage.get_entry(store, eid2)
          assert e2.seq == 2
          assert e2.data == %{"text" => "world"}

          assert {:ok, sub, store} = Storage.get_submission(store, "req-1")
          assert sub.request_id == "req-1"
          assert sub.fingerprint == "fp-1"
          assert sub.entry_id == eid1
          :ok = Storage.close(store)
        end

        test "supports prefix refusal for unique_request_id, conversation_exists, and missing entry conversation" do
          {:ok, store} = open_store([])

          {:ok, eid1, store} = Storage.mint_id(store)
          {:ok, eid2, store} = Storage.mint_id(store)
          {:ok, eid3, store} = Storage.mint_id(store)

          # Seed submission req-1
          assert {:ok, %{stored: 1, seqs: [1], refused: nil}, store} =
                   Storage.commit(store, [
                     [
                       {:put_submission,
                        %{request_id: "req-1", fingerprint: "fp-a", status: "queued"}}
                     ]
                   ])

          # Batch 0 succeeds; Batch 1 fails duplicate_request_id (after partial write inside batch 1);
          # Batch 2 is never executed.
          assert {:ok, %{stored: 1, seqs: [2], refused: {1, {:duplicate_request_id, dup_sub}}},
                  store} =
                   Storage.commit(store, [
                     [
                       {:append_entry,
                        %{id: eid1, conversation_id: 1, kind: "user", data: %{"text" => "ok"}}}
                     ],
                     [
                       {:append_entry,
                        %{
                          id: eid2,
                          conversation_id: 1,
                          kind: "user",
                          data: %{"text" => "rolled back"}
                        }},
                       {:check, {:unique_request_id, "req-1", "fp-a"}}
                     ],
                     [
                       {:append_entry,
                        %{
                          id: eid3,
                          conversation_id: 1,
                          kind: "user",
                          data: %{"text" => "skipped"}
                        }}
                     ]
                   ])

          assert dup_sub.request_id == "req-1"
          assert {:ok, %{id: ^eid1}, store} = Storage.get_entry(store, eid1)
          assert {:ok, nil, store} = Storage.get_entry(store, eid2)
          assert {:ok, nil, store} = Storage.get_entry(store, eid3)

          # Conflict request id
          assert {:ok, %{stored: 0, seqs: [], refused: {0, {:conflict_request_id, conflict_sub}}},
                  store} =
                   Storage.commit(store, [
                     [{:check, {:unique_request_id, "req-1", "fp-different"}}]
                   ])

          assert conflict_sub.fingerprint == "fp-a"

          # Missing conversation check
          assert {:ok, %{stored: 0, seqs: [], refused: {0, {:conversation_not_found, 999}}},
                  store} =
                   Storage.commit(store, [
                     [{:check, {:conversation_exists, 999}}]
                   ])

          # Missing conversation on append_entry
          assert {:ok, %{stored: 0, seqs: [], refused: {0, {:conversation_not_found, 999}}},
                  store} =
                   Storage.commit(store, [
                     [
                       {:append_entry, %{id: eid2, conversation_id: 999, kind: "user", data: %{}}}
                     ]
                   ])

          :ok = Storage.close(store)
        end

        test "evaluates duplicate request_id against earlier batches in same commit" do
          {:ok, store} = open_store([])

          assert {:ok, %{stored: 1, seqs: [1], refused: {1, {:duplicate_request_id, sub}}}, store} =
                   Storage.commit(store, [
                     [
                       {:check, {:unique_request_id, "req-batch", "fp-1"}},
                       {:put_submission,
                        %{request_id: "req-batch", fingerprint: "fp-1", status: "queued"}}
                     ],
                     [
                       {:check, {:unique_request_id, "req-batch", "fp-1"}}
                     ]
                   ])

          assert sub.request_id == "req-batch"
          :ok = Storage.close(store)
        end
      end

      describe "get_doc/3 and document history" do
        test "tracks latest unretired documents and as_of_seq revisions across scopes" do
          {:ok, store} = open_store([])

          sess_addr = {:session, "prefs"}
          conv_addr = {:conversation, 1, "agent"}
          task_addr = {:task, 42, "state"}

          assert {:ok, nil, store} = Storage.get_doc(store, conv_addr)
          assert {:ok, nil, store} = Storage.get_doc(store, conv_addr, as_of_seq: 0)

          assert {:ok, %{seqs: [1, 2, 3, 4]}, store} =
                   Storage.commit(store, [
                     [
                       {:put_doc, sess_addr, %{"theme" => "dark"}},
                       {:put_doc, conv_addr, %{"model" => "m1"}}
                     ],
                     [{:put_doc, conv_addr, %{"model" => "m2"}}],
                     [{:retire_doc, conv_addr}, {:put_doc, task_addr, %{"step" => 1}}],
                     [{:put_doc, conv_addr, %{"model" => "m3"}}]
                   ])

          assert {:ok, %{"theme" => "dark"}, store} = Storage.get_doc(store, sess_addr)
          assert {:ok, %{"step" => 1}, store} = Storage.get_doc(store, task_addr)
          assert {:ok, %{"model" => "m3"}, store} = Storage.get_doc(store, conv_addr)

          assert {:ok, nil, store} = Storage.get_doc(store, conv_addr, as_of_seq: 0)

          assert {:ok, %{"model" => "m1"}, store} =
                   Storage.get_doc(store, conv_addr, as_of_seq: 1)

          assert {:ok, %{"model" => "m2"}, store} =
                   Storage.get_doc(store, conv_addr, as_of_seq: 2)

          assert {:ok, nil, store} = Storage.get_doc(store, conv_addr, as_of_seq: 3)

          assert {:ok, %{"model" => "m3"}, store} =
                   Storage.get_doc(store, conv_addr, as_of_seq: 4)

          # Retire permanently at seq 5
          assert {:ok, %{seqs: [5]}, store} =
                   Storage.commit(store, [[{:retire_doc, conv_addr}]])

          assert {:ok, nil, store} = Storage.get_doc(store, conv_addr)
          assert {:ok, nil, store} = Storage.get_doc(store, conv_addr, as_of_seq: 5)

          assert {:ok, %{"model" => "m3"}, store} =
                   Storage.get_doc(store, conv_addr, as_of_seq: 4)

          assert {:ok, bootstrap, store} = Storage.read_bootstrap(store)
          assert Map.has_key?(bootstrap.docs, sess_addr)
          assert Map.has_key?(bootstrap.docs, task_addr)
          refute Map.has_key?(bootstrap.docs, conv_addr)
          :ok = Storage.close(store)
        end
      end

      describe "scan_entries/2" do
        test "returns error for unknown conversation" do
          {:ok, store} = open_store([])

          assert {:error, {:conversation_not_found, 99}} =
                   Storage.scan_entries(store, %{conversation_id: 99})

          :ok = Storage.close(store)
        end

        test "enforces fork ancestry min-cutoff rule and explicit cutoff" do
          {:ok, store} = open_store([])

          {:ok, e2, store} = Storage.mint_id(store)
          {:ok, e3, store} = Storage.mint_id(store)
          {:ok, branch_id, store} = Storage.mint_id(store)
          {:ok, e5, store} = Storage.mint_id(store)
          {:ok, e6, store} = Storage.mint_id(store)
          {:ok, nested_id, store} = Storage.mint_id(store)
          {:ok, e8, store} = Storage.mint_id(store)

          assert {:ok, %{refused: nil}, store} =
                   Storage.commit(store, [
                     [
                       {:append_entry,
                        %{id: e2, conversation_id: 1, kind: "user", data: %{"n" => 1}}},
                       {:append_entry,
                        %{id: e3, conversation_id: 1, kind: "assistant", data: %{"n" => 2}}}
                     ],
                     [
                       {:put_conversation,
                        %{id: branch_id, parent: %{conversation_id: 1, at: e3}, owner: :ownerless}},
                       {:append_entry,
                        %{id: e5, conversation_id: 1, kind: "user", data: %{"n" => 3}}},
                       {:append_entry,
                        %{
                          id: e6,
                          conversation_id: branch_id,
                          kind: "user",
                          data: %{"n" => 4}
                        }}
                     ],
                     [
                       # Fork branch at inherited e2 (min(e2, e3) == e2)
                       {:put_conversation,
                        %{
                          id: nested_id,
                          parent: %{conversation_id: branch_id, at: e2},
                          owner: :ownerless
                        }},
                       {:append_entry,
                        %{
                          id: e8,
                          conversation_id: nested_id,
                          kind: "assistant",
                          data: %{"n" => 5}
                        }}
                     ]
                   ])

          assert {:ok, %{items: root_asc, next_cursor: nil}, store} =
                   Storage.scan_entries(store, %{conversation_id: 1, order: :asc})

          assert Enum.map(root_asc, & &1.id) == [e2, e3, e5]

          assert {:ok, %{items: branch_asc, next_cursor: nil}, store} =
                   Storage.scan_entries(store, %{conversation_id: branch_id, order: :asc})

          assert Enum.map(branch_asc, & &1.id) == [e2, e3, e6]

          assert {:ok, %{items: nested_asc, next_cursor: nil}, store} =
                   Storage.scan_entries(store, %{conversation_id: nested_id, order: :asc})

          assert Enum.map(nested_asc, & &1.id) == [e2, e8]

          # Explicit cutoff caps visible entries
          assert {:ok, %{items: capped, next_cursor: nil}, store} =
                   Storage.scan_entries(store, %{
                     conversation_id: branch_id,
                     cutoff: e3,
                     order: :asc
                   })

          assert Enum.map(capped, & &1.id) == [e2, e3]
          :ok = Storage.close(store)
        end

        test "supports asc/desc cursor pagination and sets next_cursor only when more exist" do
          {:ok, store} = open_store([])

          {ids, store} =
            Enum.map_reduce(1..5, store, fn _, acc ->
              {:ok, id, acc} = Storage.mint_id(acc)
              {id, acc}
            end)

          writes =
            Enum.map(ids, fn id ->
              {:append_entry, %{id: id, conversation_id: 1, kind: "user", data: %{"id" => id}}}
            end)

          assert {:ok, %{refused: nil}, store} = Storage.commit(store, [writes])
          [i1, i2, i3, i4, i5] = ids

          # Default desc, limit 2
          assert {:ok, %{items: page1, next_cursor: ^i4}, store} =
                   Storage.scan_entries(store, %{conversation_id: 1, limit: 2})

          assert Enum.map(page1, & &1.id) == [i5, i4]

          assert {:ok, %{items: page2, next_cursor: ^i2}, store} =
                   Storage.scan_entries(store, %{conversation_id: 1, cursor: i4, limit: 2})

          assert Enum.map(page2, & &1.id) == [i3, i2]

          assert {:ok, %{items: page3, next_cursor: nil}, store} =
                   Storage.scan_entries(store, %{conversation_id: 1, cursor: i2, limit: 2})

          assert Enum.map(page3, & &1.id) == [i1]

          # Asc, exact boundary limit sets next_cursor to nil
          assert {:ok, %{items: asc1, next_cursor: ^i2}, store} =
                   Storage.scan_entries(store, %{conversation_id: 1, order: :asc, limit: 2})

          assert Enum.map(asc1, & &1.id) == [i1, i2]

          assert {:ok, %{items: asc2, next_cursor: ^i4}, store} =
                   Storage.scan_entries(store, %{
                     conversation_id: 1,
                     order: :asc,
                     cursor: i2,
                     limit: 2
                   })

          assert Enum.map(asc2, & &1.id) == [i3, i4]

          assert {:ok, %{items: asc3, next_cursor: nil}, store} =
                   Storage.scan_entries(store, %{
                     conversation_id: 1,
                     order: :asc,
                     cursor: i4,
                     limit: 2
                   })

          assert Enum.map(asc3, & &1.id) == [i5]
          :ok = Storage.close(store)
        end
      end
    end
  end
end
