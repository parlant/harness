defmodule H.Provider.GeminiModels do
  @moduledoc false

  # Bundled Gemini 4 metadata until upstream LLMDB includes post-2026-11-17 releases.
  # Source: https://ai.google.dev/gemini-api/docs/models/gemini-4-neon
  @bundled %{
    "gemini-4-neon" => %{
      id: "gemini-4-neon",
      model: "gemini-4-neon",
      provider: :google,
      family: "gemini",
      name: "Gemini 4 Neon",
      release_date: "2026-11-18",
      limits: %{context: 1_048_576, input: 1_048_576, output: 1_048_576},
      cost: %{input: 3.0, output: 15.0, cache_read: 0.15},
      pricing: %{
        currency: "USD",
        merge: "merge_by_id",
        components: [
          %{
            id: "token.input",
            kind: "token",
            meter: "input_tokens",
            per: 1_000_000,
            rate: 3.0,
            role: "rate",
            unit: "token"
          },
          %{
            id: "token.output",
            kind: "token",
            meter: "output_tokens",
            per: 1_000_000,
            rate: 15.0,
            role: "rate",
            unit: "token"
          },
          %{
            id: "token.cache_read",
            kind: "token",
            meter: "cache_read_tokens",
            per: 1_000_000,
            rate: 0.15,
            role: "rate",
            unit: "token"
          }
        ]
      },
      modalities: %{
        input: [:text, :image, :video, :audio, :pdf],
        output: [:text]
      },
      capabilities: %{
        chat: true,
        streaming: %{text: true, tool_calls: false},
        tools: %{enabled: true},
        reasoning: %{
          enabled: true,
          effort: %{
            supported: true,
            default: "high",
            values: ["low", "medium", "high", "xhigh"]
          }
        }
      },
      extra: %{
        default_synchronous_output_limit: 65_536,
        reasoning_options: [%{type: "effort", values: ["low", "medium", "high", "xhigh"]}]
      }
    }
  }

  def get(id) when is_binary(id) do
    case Map.get(@bundled, id) do
      nil -> nil
      attrs -> LLMDB.Model.new!(attrs)
    end
  end
end
