defmodule H.Session.CompactionTest do
  use ExUnit.Case, async: true

  alias H.{Context, Entry, Session}
  alias H.Provider.Fake
  alias H.Session.Compaction

  defp entry(id, kind, data) do
    %Entry{id: id, conversation_id: 1, kind: kind, data: data}
  end

  defp fake_with(script) do
    start_supervised!({Fake, script: script})
  end

  describe "provider_visible_entry?/1" do
    test "accepts user, non-aborted assistant, and tool_result entries unless excluded" do
      assert Compaction.provider_visible_entry?(entry(1, "user", %{"text" => "hi"}))
      assert Compaction.provider_visible_entry?(entry(2, "assistant", %{"text" => "hello"}))
      assert Compaction.provider_visible_entry?(entry(3, "tool_result", %{"content" => "ok"}))

      refute Compaction.provider_visible_entry?(
               entry(4, "assistant", %{"aborted" => true, "text" => "partial"})
             )

      refute Compaction.provider_visible_entry?(entry(5, "system", %{"text" => "sys"}))
      refute Compaction.provider_visible_entry?(entry(6, "compaction", %{"summary" => "s"}))
      refute Compaction.provider_visible_entry?(entry(7, "reset", %{"handoff" => "h"}))
      refute Compaction.provider_visible_entry?(entry(8, "user_shell", %{"command" => "ls"}))

      assert Compaction.provider_visible_entry?(
               entry(81, "user_shell", %{
                 "command" => "git status",
                 "output" => "clean",
                 "include_in_context" => true
               })
             )

      refute Compaction.provider_visible_entry?(
               entry(82, "user_shell", %{
                 "command" => "env",
                 "output" => "SECRET=1",
                 "include_in_context" => false
               })
             )

      refute Compaction.provider_visible_entry?(
               entry(9, "user", %{"text" => "secret", "exclude_from_context" => true})
             )

      refute Compaction.provider_visible_entry?(
               entry(10, "user", %{"text" => "secret", "include_in_context" => false})
             )

      refute Compaction.provider_visible_entry?(
               entry(11, "user", %{"text" => "secret", "mode" => "!!"})
             )
    end
  end

  describe "validate_args/1" do
    test "validates expected_seq and optional instructions" do
      assert {:ok, %{expected_seq: 0, instructions: nil}} =
               Compaction.validate_args(%{"expected_seq" => 0})

      assert {:ok, %{expected_seq: 7, instructions: nil}} =
               Compaction.validate_args(%{"expected_seq" => 7, "instructions" => "   "})

      assert {:ok, %{expected_seq: 7, instructions: "Focus on API"}} =
               Compaction.validate_args(%{
                 "expected_seq" => 7,
                 "instructions" => " Focus on API "
               })

      assert {:error, _} = Compaction.validate_args(%{})
      assert {:error, _} = Compaction.validate_args(%{"expected_seq" => -1})
      assert {:error, _} = Compaction.validate_args(%{"expected_seq" => "7"})
      assert {:error, _} = Compaction.validate_args(%{"expected_seq" => 1, "instructions" => 42})
    end
  end

  describe "prepare/2" do
    test "returns :nothing_to_compact for empty entries or when tail fits budget" do
      assert {:error, :nothing_to_compact} = Compaction.prepare([])

      entries = [
        entry(1, "user", %{"text" => "short question"}),
        entry(2, "assistant", %{"text" => "short answer"})
      ]

      assert {:error, :nothing_to_compact} = Compaction.prepare(entries, keep_recent_chars: 1_000)
    end

    test "returns :already_compacted when trailing entry is compaction or reset" do
      compacted = [
        entry(1, "user", %{"text" => "hi"}),
        entry(2, "compaction", %{"summary" => "done", "kept_from_id" => 1})
      ]

      reset = [
        entry(1, "user", %{"text" => "hi"}),
        entry(2, "reset", %{"handoff" => "fresh"})
      ]

      assert {:error, :already_compacted} = Compaction.prepare(compacted, keep_recent_chars: 1)
      assert {:error, :already_compacted} = Compaction.prepare(reset, keep_recent_chars: 1)
    end

    test "selects real user/assistant boundary and keeps tool_call paired with tool_result" do
      entries = [
        entry(1, "user", %{"content" => [%{"type" => "text", "text" => "old request"}]}),
        entry(2, "assistant", %{"content" => [%{"type" => "text", "text" => "old reply"}]}),
        entry(3, "user", %{"content" => [%{"type" => "text", "text" => "read big file"}]}),
        entry(4, "assistant", %{
          "content" => [],
          "tool_calls" => [
            %{"id" => "call_1", "name" => "read", "arguments" => %{"path" => "a.ex"}}
          ]
        }),
        entry(5, "tool_result", %{
          "tool_call_id" => "call_1",
          "name" => "read",
          "content" => String.duplicate("x", 500)
        })
      ]

      # Budget (100 chars) is exceeded on trailing tool_result (id: 5),
      # so cut snaps to preceding assistant tool_call (id: 4), never tool_result.
      assert {:ok, prep} = Compaction.prepare(entries, keep_recent_chars: 100)
      assert prep.kept_from_id == 4
      assert Enum.map(prep.kept_entries, & &1.id) == [4, 5]
      assert length(prep.projected_messages) == 3
      assert Enum.map(prep.projected_messages, & &1.role) == ["user", "assistant", "user"]
    end

    test "supports explicit kept_from_id and rejects invalid or tool_result boundaries" do
      entries = [
        entry(1, "user", %{"text" => "u1"}),
        entry(2, "assistant", %{
          "content" => [],
          "tool_calls" => [%{"id" => "c1", "name" => "read", "arguments" => %{}}]
        }),
        entry(3, "tool_result", %{"tool_call_id" => "c1", "name" => "read", "content" => "res"}),
        entry(4, "user", %{"text" => "u2"}),
        entry(5, "user_shell", %{"command" => "env", "output" => "SECRET=1", "mode" => "!!"}),
        entry(6, "assistant", %{"text" => "aborted", "aborted" => true}),
        entry(7, "assistant", %{"text" => "a2"})
      ]

      assert {:ok, prep} = Compaction.prepare(entries, kept_from_id: 4)
      assert prep.kept_from_id == 4
      assert Enum.map(prep.kept_entries, & &1.id) == [4, 7]

      assert {:error, :invalid_boundary} = Compaction.prepare(entries, kept_from_id: 3)
      assert {:error, :invalid_boundary} = Compaction.prepare(entries, kept_from_id: 5)
      assert {:error, :invalid_boundary} = Compaction.prepare(entries, kept_from_id: 6)
      assert {:error, :invalid_boundary} = Compaction.prepare(entries, kept_from_id: 999)
      assert {:error, :nothing_to_compact} = Compaction.prepare(entries, kept_from_id: 1)
    end

    test "projects only already provider-visible prefix incl previous summary and excludes !! data" do
      entries = [
        entry(1, "user", %{"text" => "ancient dropped prompt"}),
        entry(2, "assistant", %{"text" => "ancient dropped reply"}),
        entry(3, "user", %{"text" => "kept from first compaction"}),
        entry(4, "compaction", %{"summary" => "First checkpoint summary", "kept_from_id" => 3}),
        entry(5, "user_shell", %{
          "command" => "cat .env",
          "output" => "API_SECRET=super-secret",
          "exclude_from_context" => true
        }),
        entry(6, "user", %{
          "text" => "!! local secret command",
          "exclude_from_context" => true
        }),
        entry(7, "assistant", %{"text" => "crashed partial output", "aborted" => true}),
        entry(8, "user", %{"text" => "new visible turn"}),
        entry(9, "assistant", %{"text" => String.duplicate("y", 200)})
      ]

      assert {:ok, prep} = Compaction.prepare(entries, keep_recent_chars: 100)
      assert prep.kept_from_id == 9
      assert prep.previous_summary == "First checkpoint summary"

      serialized = Compaction.serialize_messages(prep.projected_messages)
      assert serialized =~ "kept from first compaction"
      assert serialized =~ "new visible turn"
      refute serialized =~ "ancient dropped"
      refute serialized =~ "API_SECRET"
      refute serialized =~ "super-secret"
      refute serialized =~ "local secret command"
      refute serialized =~ "crashed partial output"
    end

    test "includes ! user_shell (include_in_context: true) and excludes !! (include_in_context: false)" do
      entries = [
        entry(1, "user", %{"text" => "check repo"}),
        entry(2, "user_shell", %{
          "command" => "git status",
          "output" => "clean tree",
          "exit_code" => 0,
          "cancelled" => false,
          "truncated" => false,
          "include_in_context" => true
        }),
        entry(3, "user_shell", %{
          "command" => "printenv",
          "output" => "HIDDEN_TOKEN=xyz",
          "exit_code" => 0,
          "cancelled" => false,
          "truncated" => false,
          "include_in_context" => false
        }),
        entry(4, "user", %{"text" => String.duplicate("recent ", 30)})
      ]

      assert {:ok, prep} = Compaction.prepare(entries, keep_recent_chars: 100)
      assert prep.kept_from_id == 4

      serialized = Compaction.serialize_messages(prep.projected_messages)
      assert serialized =~ "Ran `git status`"
      assert serialized =~ "clean tree"
      refute serialized =~ "printenv"
      refute serialized =~ "HIDDEN_TOKEN"
    end

    test "respects reset marker and excludes pre-reset history" do
      entries = [
        entry(1, "user", %{"text" => "before reset"}),
        entry(2, "assistant", %{"text" => "before reset answer"}),
        entry(3, "reset", %{"handoff" => "Reset handoff note"}),
        entry(4, "user", %{"text" => "after reset turn"}),
        entry(5, "assistant", %{"text" => String.duplicate("z", 200)})
      ]

      assert {:ok, prep} = Compaction.prepare(entries, keep_recent_chars: 100)
      assert prep.kept_from_id == 5
      assert prep.previous_summary == "Reset handoff note"

      serialized = Compaction.serialize_messages(prep.projected_messages)
      assert serialized =~ "after reset turn"
      refute serialized =~ "before reset"
    end
  end

  describe "serialize_messages/1" do
    test "omits thinking and image binaries and truncates long tool results" do
      messages = [
        %{
          role: "user",
          content: [
            %{type: "text", text: "Inspect image"},
            %{type: "image", data: <<1, 2, 3, 4>>, media_type: "image/png"}
          ]
        },
        %{
          role: "assistant",
          content: [
            %{type: "thinking", text: "private chain of thought", signature: "sig-1"},
            %{type: "text", text: "Reading file"}
          ],
          tool_calls: [
            %{id: "c1", name: "read", arguments: %{"path" => "lib/h.ex", "limit" => 10}}
          ]
        },
        %{
          role: "tool",
          tool_call_id: "c1",
          name: "read",
          content: [%{type: "text", text: String.duplicate("a", 2500)}]
        }
      ]

      out = Compaction.serialize_messages(messages)

      assert out =~ "[User]: Inspect image"
      assert out =~ "[Assistant]: Reading file"
      assert out =~ ~s{[Assistant tool calls]: read(limit=10, path="lib/h.ex")}
      assert out =~ "[Tool result]: " <> String.duplicate("a", 2000)
      assert out =~ "[... 500 more characters truncated]"
      refute out =~ "private chain of thought"
      refute out =~ "sig-1"
      refute out =~ <<1, 2, 3, 4>>
    end
  end

  describe "build_request/3" do
    test "builds single provider request with previous summary, user instructions, and no tools" do
      entries = [
        entry(1, "user", %{"text" => "ignored pre-cut"}),
        entry(2, "compaction", %{"summary" => "Prior summary text", "kept_from_id" => 3}),
        entry(3, "user", %{"text" => "visible follow-up"}),
        entry(4, "assistant", %{"text" => String.duplicate("k", 200)})
      ]

      {:ok, prep} = Compaction.prepare(entries, keep_recent_chars: 100)

      req =
        Compaction.build_request(
          prep,
          %{model: "fake:chat", thinking: "off"},
          instructions: "Focus on API contracts"
        )

      assert req.model == "fake:chat"
      assert req.thinking == nil
      assert req.tools == []
      assert [%{role: "system"}, %{role: "user", content: [%{text: prompt}]}] = req.messages

      assert prompt =~ "<conversation>\n[User]: visible follow-up\n</conversation>"
      assert prompt =~ "<previous-summary>\nPrior summary text\n</previous-summary>"
      assert prompt =~ "User instructions: Focus on API contracts"
      # Previous summary must not be duplicated inside <conversation>
      refute prompt =~ "<conversation>\n[User]: Prior summary text"
    end
  end

  describe "summarize/5" do
    test "executes one provider call and returns validated result" do
      entries = [
        entry(1, "user", %{"text" => "Implement feature X"}),
        entry(2, "assistant", %{"text" => "Implemented X in lib/x.ex"}),
        entry(3, "user", %{"text" => String.duplicate("next ", 50)})
      ]

      {:ok, prep} = Compaction.prepare(entries, keep_recent_chars: 100)

      fake =
        fake_with([
          {:expect,
           fn req ->
             assert req.model == "fake:chat"
             assert req.thinking == "medium"
             assert req.tools == []
             [_, %{role: "user", content: [%{text: prompt}]}] = req.messages
             assert prompt =~ "User instructions: Highlight lib/x.ex"
             assert prompt =~ "[User]: Implement feature X"
             true
           end,
           {:reply, [],
            %{
              content: [
                %{type: "thinking", text: "ignored reasoning"},
                %{type: "text", text: "## Goal\nImplemented X"}
              ],
              finish_reason: "stop",
              usage: %{input_tokens: 40, output_tokens: 15, total_tokens: 55}
            }}}
        ])

      assert {:ok, result} =
               Compaction.summarize(
                 prep,
                 %{"model" => "fake:chat", "thinking" => "medium"},
                 Fake,
                 %{server: fake},
                 instructions: "Highlight lib/x.ex"
               )

      assert result.summary == "## Goal\nImplemented X"
      assert result.kept_from_id == 3
      assert result.instructions == "Highlight lib/x.ex"
      assert result.usage == %{input_tokens: 40, output_tokens: 15, total_tokens: 55}
      assert length(Fake.requests(fake)) == 1
    end

    test "rejects length-truncated, tool-calling, cancelled, error, and empty responses" do
      entries = [
        entry(1, "user", %{"text" => "old"}),
        entry(2, "user", %{"text" => String.duplicate("recent", 40)})
      ]

      {:ok, prep} = Compaction.prepare(entries, keep_recent_chars: 50)
      agent = %{model: "fake:chat"}

      fake =
        fake_with([
          {:reply, [], %{content: [%{type: "text", text: "partial"}], finish_reason: "length"}},
          {:reply, [],
           %{
             content: [],
             tool_calls: [%{id: "c1", name: "read", arguments: %{}}],
             finish_reason: "tool_calls"
           }},
          {:reply, [], %{content: [%{type: "text", text: "   "}], finish_reason: "stop"}},
          {:error, %{code: "rate_limited", message: "try later", retryable: true}},
          fn _req, _emit -> {:cancelled, %{partial_content: [], usage: %{}}} end
        ])

      assert {:error, %{code: "truncated_summary", retryable: false}} =
               Compaction.summarize(prep, agent, Fake, %{server: fake})

      assert {:error, %{code: "tool_call_rejected", retryable: false}} =
               Compaction.summarize(prep, agent, Fake, %{server: fake})

      assert {:error, %{code: "empty_summary", retryable: false}} =
               Compaction.summarize(prep, agent, Fake, %{server: fake})

      assert {:error, %{code: "rate_limited", retryable: true}} =
               Compaction.summarize(prep, agent, Fake, %{server: fake})

      assert {:error, %{code: "cancelled", retryable: false}} =
               Compaction.summarize(prep, agent, Fake, %{server: fake})

      assert {:error, %{code: "missing_model"}} =
               Compaction.summarize(prep, %{}, Fake, %{server: fake})
    end
  end

  describe "compact/5 and entry_data/1" do
    test "appends compaction entry via H.Session without mutating previous entries and updates H.Context" do
      session = Session.new("s-compact", "/tmp/work")
      {:ok, session, u1} = Session.append(session, 1, "user", %{"text" => "Turn 1 prompt"})
      {:ok, session, a1} = Session.append(session, 1, "assistant", %{"text" => "Turn 1 reply"})

      {:ok, session, excl} =
        Session.append(session, 1, "user_shell", %{
          "command" => "printenv",
          "output" => "SECRET=nope",
          "exclude_from_context" => true
        })

      {:ok, session, u2} =
        Session.append(session, 1, "user", %{"text" => String.duplicate("recent turn ", 20)})

      {:ok, session, a2} =
        Session.append(session, 1, "assistant", %{"text" => String.duplicate("recent reply ", 20)})

      {:ok, before_entries} = Session.entries(session, 1)

      fake =
        fake_with([
          {:reply, [],
           %{
             content: [%{type: "text", text: "## Goal\nSummary of turn 1"}],
             finish_reason: "stop",
             usage: %{input_tokens: 10, output_tokens: 5}
           }}
        ])

      assert {:ok, result} =
               Compaction.compact(
                 before_entries,
                 %{"model" => "fake:chat"},
                 Fake,
                 %{server: fake},
                 keep_recent_chars: 300,
                 instructions: "Keep turn 2 intact"
               )

      data = Compaction.entry_data(result)
      assert data["summary"] == "## Goal\nSummary of turn 1"
      assert data["kept_from_id"] == u2.id
      assert data["instructions"] == "Keep turn 2 intact"

      {:ok, after_session, comp_entry} = Session.append(session, 1, "compaction", data)
      {:ok, after_entries} = Session.entries(after_session, 1)

      # Previous entries are untouched and immutable
      assert Enum.take(after_entries, length(before_entries)) == before_entries
      assert List.last(after_entries) == comp_entry

      assert Enum.map(after_entries, & &1.id) == [
               u1.id,
               a1.id,
               excl.id,
               u2.id,
               a2.id,
               comp_entry.id
             ]

      # H.Context applies the committed boundary cleanly
      ctx_req = Context.build_request(after_entries, %{"model" => "fake:chat"})

      assert [
               %{role: "user", content: [%{type: "text", text: "## Goal\nSummary of turn 1"}]},
               %{role: "user", content: [%{type: "text", text: "recent turn " <> _}]},
               %{role: "assistant", content: [%{type: "text", text: "recent reply " <> _}]}
             ] = ctx_req.messages

      # Forking before compaction leaves parent and compaction entry isolated
      {:ok, forked_session, fork_conv} = Session.fork(after_session, 1, a1.id)
      {:ok, fork_entries} = Session.entries(forked_session, fork_conv.id)
      assert Enum.map(fork_entries, & &1.id) == [u1.id, a1.id]
    end

    test "second compaction incorporates first summary without re-exposing dropped entries" do
      session = Session.new("s-double", "/tmp/work")
      {:ok, session, _u1} = Session.append(session, 1, "user", %{"text" => "Dropped phase 1"})

      {:ok, session, _excl} =
        Session.append(session, 1, "user", %{
          "text" => "!! secret env",
          "exclude_from_context" => true
        })

      {:ok, session, u2} = Session.append(session, 1, "user", %{"text" => "Kept phase 2"})

      {:ok, session, _c1} =
        Session.append(session, 1, "compaction", %{
          "summary" => "Checkpoint 1",
          "kept_from_id" => u2.id
        })

      {:ok, session, u3} =
        Session.append(session, 1, "user", %{"text" => String.duplicate("phase 3 ", 40)})

      {:ok, entries} = Session.entries(session, 1)

      fake =
        fake_with([
          {:expect,
           fn req ->
             [_, %{role: "user", content: [%{text: prompt}]}] = req.messages
             assert prompt =~ "<previous-summary>\nCheckpoint 1\n</previous-summary>"
             assert prompt =~ "[User]: Kept phase 2"
             refute prompt =~ "Dropped phase 1"
             refute prompt =~ "secret env"
             true
           end,
           {:reply, [],
            %{content: [%{type: "text", text: "Checkpoint 2"}], finish_reason: "stop"}}}
        ])

      assert {:ok, result2} =
               Compaction.compact(entries, %{model: "fake:chat"}, Fake, %{server: fake},
                 keep_recent_chars: 100
               )

      {:ok, session, _c2} =
        Session.append(session, 1, "compaction", Compaction.entry_data(result2))

      {:ok, final_entries} = Session.entries(session, 1)
      ctx_req = Context.build_request(final_entries, %{model: "fake:chat"})

      assert [
               %{role: "user", content: [%{type: "text", text: "Checkpoint 2"}]},
               %{role: "user", content: [%{type: "text", text: "phase 3 " <> _}]}
             ] = ctx_req.messages

      assert result2.kept_from_id == u3.id
    end
  end
end
