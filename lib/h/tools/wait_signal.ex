defmodule H.Tools.WaitSignal do
  @moduledoc """
  Coordinator-managed external wake signal tool (`name: "wait_signal"`).

  Parks the calling `tool_call` task in `"waiting"` state with zero
  `Task.Supervisor` workers until an operator or external process delivers a
  matching signal on `topic` or an optional `timeout_ms` expires.
  """

  @behaviour H.Tool

  @impl true
  def name, do: "wait_signal"

  @impl true
  def description do
    "Wait for an external wake signal on a topic (with optional timeout_ms) without consuming a worker process."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "topic" => %{
          "type" => "string",
          "pattern" => "^[a-zA-Z0-9:._-]{1,80}$",
          "description" => "Signal topic to wait for (1..80 chars of [a-zA-Z0-9:._-])."
        },
        "timeout_ms" => %{
          "type" => "integer",
          "minimum" => 100,
          "maximum" => 86_400_000,
          "description" => "Optional timeout in milliseconds (100..86400000)."
        }
      },
      "required" => ["topic"],
      "additionalProperties" => false
    }
  end

  @impl true
  def replay, do: :safe

  @impl true
  def mutating?, do: false

  @impl true
  def execute(_args, _context) do
    {:error,
     %{
       content: [%{"type" => "text", "text" => "wait_signal tool requires coordinator runtime"}],
       details: %{},
       is_error: true,
       diagnostic: "unsupported_context"
     }}
  end
end
