defmodule H.ContextTest do
  use ExUnit.Case, async: true

  alias H.Context
  alias ReqLLM.Message.{ContentPart, ReasoningDetails}

  describe "build_request/3" do
    test "places leading system baseline first and omits aborted assistant entries" do
      agent = %{
        model: "anthropic:claude-sonnet-4-5",
        thinking: :high,
        system_prompt: "You are H.",
        instructions: "Be concise.",
        tools: ["read"]
      }

      entries = [
        %{id: 1, kind: "user", data: %{text: "Hello"}},
        %{id: 2, kind: "assistant", data: %{aborted: true, text: "Partial crashed output"}},
        %{
          id: 3,
          kind: "assistant",
          data: %{
            "aborted" => false,
            "content" => [%{"type" => "text", "text" => "Hi there!"}]
          }
        }
      ]

      tool_specs = [
        %{
          name: "read",
          description: "Read file",
          parameters_schema: %{"type" => "object", "properties" => %{}}
        },
        %{
          name: "write",
          description: "Write file",
          parameters_schema: %{"type" => "object", "properties" => %{}}
        }
      ]

      req = Context.build_request(entries, agent, tool_specs)

      assert req.model == "anthropic:claude-sonnet-4-5"
      assert req.thinking == :high
      assert Enum.map(req.tools, & &1.name) == ["read"]

      assert [
               %{role: "system", content: [%{type: "text", text: "You are H.\n\nBe concise."}]},
               %{role: "user", content: [%{type: "text", text: "Hello"}]},
               %{role: "assistant", content: [%{type: "text", text: "Hi there!"}], tool_calls: []}
             ] = req.messages
    end

    test "applies compaction head cut with kept_from_id and reset head cut with handoff" do
      agent = %{model: "openai:gpt-4o", system_prompt: "Sys"}

      compacted_entries = [
        %{id: 1, kind: "user", data: %{text: "Old 1"}},
        %{id: 2, kind: "assistant", data: %{text: "Old 2"}},
        %{id: 3, kind: "user", data: %{text: "Kept 3"}},
        %{id: 4, kind: "compaction", data: %{summary: "Summary of 1-2", kept_from_id: 3}},
        %{id: 5, kind: "assistant", data: %{text: "After compaction"}}
      ]

      compacted_req = Context.build_request(compacted_entries, agent)

      assert [
               %{role: "system"},
               %{role: "user", content: [%{type: "text", text: "Summary of 1-2"}]},
               %{role: "user", content: [%{type: "text", text: "Kept 3"}]},
               %{role: "assistant", content: [%{type: "text", text: "After compaction"}]}
             ] = compacted_req.messages

      reset_entries =
        compacted_entries ++
          [
            %{id: 6, kind: "reset", data: %{handoff: "Fresh start note"}},
            %{id: 7, kind: "user", data: %{text: "New task"}}
          ]

      reset_req = Context.build_request(reset_entries, agent)

      assert [
               %{role: "system"},
               %{role: "user", content: [%{type: "text", text: "Fresh start note"}]},
               %{role: "user", content: [%{type: "text", text: "New task"}]}
             ] = reset_req.messages
    end

    test "injects synthetic interrupted tool_result when fork leaves tool_calls unpaired" do
      agent = %{model: "anthropic:claude-sonnet-4-5"}

      entries = [
        %{id: 1, kind: "user", data: %{text: "Check files"}},
        %{
          id: 2,
          kind: "assistant",
          data: %{
            content: [%{type: "text", text: "Checking..."}],
            tool_calls: [
              %{id: "call_1", name: "read", arguments: %{"path" => "a.ex"}},
              %{id: "call_2", name: "bash", arguments: %{"command" => "ls"}}
            ]
          }
        },
        %{
          id: 3,
          kind: "tool_result",
          data: %{tool_call_id: "call_1", name: "read", content: "ok", is_error: false}
        },
        %{id: 4, kind: "user", data: %{text: "Actually do something else"}}
      ]

      req = Context.build_request(entries, agent)

      assert [
               %{role: "user"},
               %{role: "assistant", tool_calls: [%{id: "call_1"}, %{id: "call_2"}]},
               %{role: "tool", tool_call_id: "call_1", name: "read", is_error: false},
               %{
                 role: "tool",
                 tool_call_id: "call_2",
                 name: "bash",
                 is_error: true,
                 content: [%{type: "text", text: "Tool call interrupted by conversation fork."}]
               },
               %{role: "user", content: [%{type: "text", text: "Actually do something else"}]}
             ] = req.messages
    end

    test "injects synthetic tool_result at end of entries when forked right after tool call" do
      agent = %{model: "anthropic:claude-sonnet-4-5"}

      entries = [
        %{id: 1, kind: "user", data: %{text: "Run tool"}},
        %{
          id: 2,
          kind: "assistant",
          data: %{
            content: [],
            tool_calls: [%{id: "call_99", name: "edit", arguments: %{"path" => "x.ex"}}]
          }
        }
      ]

      req = Context.build_request(entries, agent)

      assert [
               %{role: "user"},
               %{role: "assistant", tool_calls: [%{id: "call_99"}]},
               %{
                 role: "tool",
                 tool_call_id: "call_99",
                 name: "edit",
                 is_error: true,
                 content: [%{type: "text", text: "Tool call interrupted by conversation fork."}]
               }
             ] = req.messages
    end

    test "preserves thinking signatures, provider_meta, image blocks, and tool_calls" do
      agent = %{model: "anthropic:claude-sonnet-4-5"}

      entries = [
        %{
          id: 1,
          kind: "user",
          data: %{
            content: [
              %{type: "text", text: "Look at this"},
              %{type: "image", data: <<1, 2, 3>>, media_type: "image/png"}
            ]
          }
        },
        %{
          id: 2,
          kind: "assistant",
          data: %{
            content: [
              %{
                type: "thinking",
                text: "Let me inspect",
                signature: "sig-xyz",
                provider_meta: %{provider: :anthropic, format: "anthropic-v1"}
              },
              %{type: "text", text: "I see an image."}
            ],
            tool_calls: [%{id: "tc_1", name: "tag", arguments: %{"label" => "chart"}}]
          }
        },
        %{
          id: 3,
          kind: "tool_result",
          data: %{tool_call_id: "tc_1", name: "tag", content: "tagged"}
        }
      ]

      req = Context.build_request(entries, agent)

      assert [
               %{
                 role: "user",
                 content: [
                   %{type: "text", text: "Look at this"},
                   %{type: "image", data: <<1, 2, 3>>, media_type: "image/png"}
                 ]
               },
               %{
                 role: "assistant",
                 content: [
                   %{
                     type: "thinking",
                     text: "Let me inspect",
                     signature: "sig-xyz",
                     provider_meta: %{provider: :anthropic, format: "anthropic-v1"}
                   },
                   %{type: "text", text: "I see an image."}
                 ],
                 tool_calls: [%{id: "tc_1", name: "tag", arguments: %{"label" => "chart"}}]
               },
               %{role: "tool", tool_call_id: "tc_1", name: "tag"}
             ] = req.messages
    end

    test "projects included user_shell entries and omits excluded ones" do
      agent = %{model: "anthropic:claude-sonnet-4-5"}

      entries = [
        %{id: 1, kind: "user", data: %{text: "Start"}},
        %{
          id: 2,
          kind: "user_shell",
          data: %{
            "command" => "echo SECRET_EXCLUDED",
            "output" => "SECRET_OUTPUT",
            "exit_code" => 0,
            "cancelled" => false,
            "truncated" => false,
            "full_output_path" => "/tmp/secret-excluded.log",
            "include_in_context" => false
          }
        },
        %{
          id: 3,
          kind: "user_shell",
          data: %{
            "command" => "git status",
            "output" => "clean\n",
            "exit_code" => 0,
            "cancelled" => false,
            "truncated" => false,
            "include_in_context" => true
          }
        },
        %{
          id: 4,
          kind: "user_shell",
          data: %{
            "command" => "make test",
            "output" => "failed line",
            "exit_code" => 2,
            "cancelled" => false,
            "truncated" => true,
            "skipped_bytes" => 512,
            "full_output_path" => "/tmp/make.log",
            "include_in_context" => true
          }
        },
        %{
          id: 5,
          kind: "user_shell",
          data: %{
            "command" => "sleep 30",
            "output" => "",
            "exit_code" => nil,
            "cancelled" => true,
            "truncated" => false,
            "include_in_context" => true
          }
        },
        %{
          id: 6,
          kind: "user_shell",
          data: %{
            "command" => "deploy",
            "output" => "partial",
            "exit_code" => nil,
            "cancelled" => false,
            "diagnostic" => "interrupted",
            "include_in_context" => true
          }
        },
        %{
          id: 7,
          kind: "user_shell",
          data: %{
            "command" => "missing_flag",
            "output" => "SHOULD_NOT_LEAK"
          }
        }
      ]

      req = Context.build_request(entries, agent)

      assert [
               %{role: "user", content: [%{type: "text", text: "Start"}]},
               %{
                 role: "user",
                 content: [%{type: "text", text: "Ran `git status`\n```\nclean\n\n```"}]
               },
               %{
                 role: "user",
                 content: [
                   %{
                     type: "text",
                     text:
                       "Ran `make test`\n```\nfailed line\n```\n\nCommand exited with code 2\n\n[Output truncated: 512 bytes omitted. Full output: /tmp/make.log]"
                   }
                 ]
               },
               %{
                 role: "user",
                 content: [
                   %{type: "text", text: "Ran `sleep 30`\n(no output)\n\n(command cancelled)"}
                 ]
               },
               %{
                 role: "user",
                 content: [
                   %{
                     type: "text",
                     text: "Ran `deploy`\n```\npartial\n```\n\n(command interrupted)"
                   }
                 ]
               }
             ] = req.messages

      rendered =
        req.messages
        |> Enum.flat_map(& &1.content)
        |> Enum.map(& &1.text)
        |> Enum.join("\n")

      refute rendered =~ "SECRET_EXCLUDED"
      refute rendered =~ "SECRET_OUTPUT"
      refute rendered =~ "secret-excluded.log"
      refute rendered =~ "missing_flag"
      refute rendered =~ "SHOULD_NOT_LEAK"
    end
  end

  describe "to_req_llm/1" do
    test "decodes explicitly base64-encoded transcript images only at the provider boundary" do
      bytes = <<255, 216, 255, 224, 255, 217>>

      block = %{
        "type" => "image",
        "media_type" => "image/jpeg",
        "encoding" => "base64",
        "data" => Base.encode64(bytes)
      }

      request = Context.build_request([%{kind: "user", data: %{"content" => [block]}}], %{})
      assert [_] = JSON.decode!(JSON.encode!(request))["messages"]

      assert {%{
                messages: [
                  %{content: [%ContentPart{type: :image, media_type: "image/jpeg", data: ^bytes}]}
                ]
              }, []} = Context.to_req_llm(request)
    end

    test "converts request map to ReqLLM.Context and non-executing ReqLLM.Tool structs" do
      agent = %{
        model: "anthropic:claude-sonnet-4-5",
        system_prompt: "System baseline"
      }

      entries = [
        %{
          id: 1,
          kind: "user",
          data: %{
            content: [
              %{type: "text", text: "Analyze"},
              %{type: "image", data: <<9, 8, 7>>, media_type: "image/jpeg"}
            ]
          }
        },
        %{
          id: 2,
          kind: "assistant",
          data: %{
            content: [
              %{
                type: "thinking",
                text: "Reasoning step",
                signature: "sig-123",
                provider: "anthropic"
              },
              %{type: "text", text: "Calling tool"}
            ],
            tool_calls: [%{id: "call_a", name: "read", arguments: %{"path" => "mix.exs"}}]
          }
        }
      ]

      tool_specs = [
        %{
          name: "read",
          description: "Read a file",
          parameters_schema: %{
            "type" => "object",
            "properties" => %{"path" => %{"type" => "string"}},
            "required" => ["path"]
          }
        }
      ]

      request = Context.build_request(entries, agent, tool_specs)
      {%ReqLLM.Context{} = ctx, [tool]} = Context.to_req_llm(request)

      assert :ok == elem(ReqLLM.Context.validate(ctx), 0)

      assert %ReqLLM.Tool{name: "read", description: "Read a file"} = tool
      assert {:error, :managed_by_harness} = ReqLLM.Tool.execute(tool, %{"path" => "mix.exs"})

      assert [sys_msg, user_msg, assistant_msg, tool_msg] = ctx.messages
      assert sys_msg.role == :system
      assert [%ContentPart{type: :text, text: "System baseline"}] = sys_msg.content

      assert user_msg.role == :user

      assert [
               %ContentPart{type: :text, text: "Analyze"},
               %ContentPart{type: :image, data: <<9, 8, 7>>, media_type: "image/jpeg"}
             ] = user_msg.content

      assert assistant_msg.role == :assistant

      assert [
               %ContentPart{type: :thinking, text: "Reasoning step"},
               %ContentPart{type: :text, text: "Calling tool"}
             ] = assistant_msg.content

      assert [
               %ReasoningDetails{
                 text: "Reasoning step",
                 signature: "sig-123",
                 provider: :anthropic
               }
             ] = assistant_msg.reasoning_details

      assert [%ReqLLM.ToolCall{id: "call_a", function: %{name: "read"}}] =
               assistant_msg.tool_calls

      assert tool_msg.role == :tool
      assert tool_msg.tool_call_id == "call_a"
      assert tool_msg.name == "read"
      assert tool_msg.metadata[:is_error] == true
    end
  end
end
