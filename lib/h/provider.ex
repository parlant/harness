defmodule H.Provider do
  @moduledoc """
  Storage-neutral LLM streaming behaviour for `H`.

  Implementations (`H.Provider.Fake` for deterministic tests and `H.Provider.ReqLLM`
  for live providers) emit incremental stream events and return plain JSON-compatible
  maps without auto-executing tools or persisting credentials.
  """

  @type stream_event ::
          %{type: :start, provider: String.t(), model: String.t()}
          | %{type: :thinking_delta, text: String.t(), metadata: map()}
          | %{type: :text_delta, text: String.t(), metadata: map()}
          | %{
              type: :tool_call_delta,
              id: String.t(),
              name: nil | String.t(),
              args_delta: String.t()
            }
          | %{type: :usage, usage: map()}

  @type assistant_response :: %{
          optional(:reasoning_details) => [map()],
          content: [map()],
          tool_calls: [map()],
          finish_reason: String.t(),
          usage: map(),
          provider_meta: map()
        }

  @type error_reason :: %{
          code: String.t(),
          message: String.t(),
          retryable: boolean()
        }

  @callback stream_turn(
              config :: map(),
              request :: map(),
              emit :: (stream_event() -> any())
            ) ::
              {:ok, assistant_response()}
              | {:cancelled, %{partial_content: [map()], usage: map()}}
              | {:error, error_reason()}

  @callback list_models(config :: map()) :: [map()]
  @optional_callbacks list_models: 1
end
