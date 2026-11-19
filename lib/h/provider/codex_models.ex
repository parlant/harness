defmodule H.Provider.CodexModels do
  @moduledoc false

  # A bundled snapshot of public model IDs and limits; no runtime catalog import.
  @bundled [
    {"gpt-6.1-sol", "GPT-6.1 Sol", 500_000},
    {"gpt-6-astra", "GPT-6 Astra", 272_000},
    {"gpt-6-luna", "GPT-6 Luna", 272_000},
    {"gpt-6-sol", "GPT-6 Sol", 272_000},
    {"gpt-5.6-luna", "GPT-5.6 Luna", 272_000},
    {"gpt-5.6-sol", "GPT-5.6 Sol", 272_000},
    {"gpt-5.6-terra", "GPT-5.6 Terra", 272_000},
    {"gpt-5.5", "GPT-5.5", 272_000},
    {"gpt-5.3-codex-spark", "GPT-5.3 Codex Spark", 128_000}
  ]

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
      capabilities: %{
        chat: true,
        streaming: %{text: true, tool_calls: true},
        tools: %{enabled: true},
        reasoning: %{enabled: true}
      }
    }
  end
end
