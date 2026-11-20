defmodule H.Provider.CodexModels do
  @moduledoc false

  # A bundled snapshot of public model IDs and limits; no runtime catalog import.
  @bundled [
    {"gpt-6.1-sol", "GPT-6.1 Sol", 500_000},
    {"gpt-6.2-sol", "GPT-6.2 Sol", 500_000},
    {"gpt-6.2-astra", "GPT-6.2 Astra", 272_000},
    {"gpt-6-astra", "GPT-6 Astra", 272_000},
    {"gpt-6-luna", "GPT-6 Luna", 272_000},
    {"gpt-6-sol", "GPT-6 Sol", 272_000},
    {"gpt-5.6-luna", "GPT-5.6 Luna", 272_000},
    {"gpt-5.6-sol", "GPT-5.6 Sol", 272_000},
    {"gpt-5.6-terra", "GPT-5.6 Terra", 272_000},
    {"gpt-5.5", "GPT-5.5", 272_000},
    {"gpt-5.3-codex-spark", "GPT-5.3 Codex Spark", 128_000}
  ]

  # LLMDB's openai entries are for the public API. Until ReqLLM supplies this
  # Codex metadata itself, opt these IDs into its Responses Lite request path.
  # https://github.com/openai/codex/blob/ead489ac4d06b13a69909173469a17be126348a4/codex-rs/models-manager/models.json
  @codex_metadata %{
    "gpt-6.2-sol" => %{use_responses_lite: true},
    "gpt-6.2-astra" => %{use_responses_lite: true}
  }

  def list do
    Enum.map(@bundled, fn {id, name, context} -> model(id, name, context) end)
  end

  defp model(id, name, context) do
    %LLMDB.Model{
      id: id,
      model: id,
      provider: :openai_codex,
      name: name,
      limits: %{context: context, output: 128_000},
      extra: if(metadata = @codex_metadata[id], do: %{openai_codex: metadata}),
      capabilities: %{
        chat: true,
        streaming: %{text: true, tool_calls: true},
        tools: %{enabled: true},
        reasoning: %{enabled: true}
      }
    }
  end
end
