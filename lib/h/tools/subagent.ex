defmodule H.Tools.Subagent do
  @moduledoc """
  Coordinator-managed subagent delegation tool (`name: "subagent"`).

  Spawns or coordinates child subsessions anchored to the launching assistant
  step, parking in `H.Session.Server` with zero `Task.Supervisor` workers while
  waiting on `:submission_settled` signals.
  """

  @behaviour H.Tool

  @session_id_pattern "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$"

  @impl true
  def name, do: "subagent"

  @impl true
  def description do
    "Spawn or coordinate a child session (wait, start, await, steer, abort). For parallel edits, prepare separate Git worktrees with bash and pass each child its own cwd. Use read_only for shared-directory exploration."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "mode" => %{
          "type" => "string",
          "enum" => ["wait", "start", "await", "steer", "abort"],
          "description" =>
            "Execution mode: wait (default, spawn/follow-up and await answer), start (spawn/follow-up asynchronously), await (wait for a started child submission), steer (deliver steering input to a busy child), or abort (cancel active child work)."
        },
        "prompt" => %{
          "type" => "string",
          "description" =>
            "Task instructions or message for the subagent (required when mode is wait, start, or steer)."
        },
        "session_id" => %{
          "type" => "string",
          "pattern" => @session_id_pattern,
          "description" =>
            "Existing direct child subsession ID to follow up on, await, steer, or abort. Omit in wait/start to spawn a new child subsession."
        },
        "request_id" => %{
          "type" => "string",
          "minLength" => 1,
          "description" =>
            "Specific child submission request_id to await when mode is await (defaults to the latest tracked request for session_id)."
        },
        "title" => %{
          "type" => "string",
          "description" => "Optional display title for a newly spawned child subsession."
        },
        "cwd" => %{
          "type" => "string",
          "pattern" => "^/",
          "description" =>
            "New spawns only. Existing absolute directory in the parent's environment. Defaults to the parent's session workspace. Pass the root of a separate Git worktree for parallel mutations; this tool does not create worktrees."
        },
        "model" => %{
          "type" => "string",
          "minLength" => 1,
          "description" =>
            "Model identifier for a new child subsession (defaults to parent conversation model)."
        },
        "thinking" => %{
          "type" => "string",
          "minLength" => 1,
          "description" =>
            "Thinking level for a new child subsession (defaults to parent conversation thinking level)."
        },
        "read_only" => %{
          "type" => "boolean",
          "description" =>
            "When true on a new spawn, restricts the child's tools to read and search_history."
        },
        "reason" => %{
          "type" => "string",
          "description" => "Optional abort reason when mode is abort."
        }
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def replay, do: :unsafe

  @impl true
  def mutating?, do: false

  @impl true
  def execute(_args, _context) do
    {:error,
     %{
       content: [%{"type" => "text", "text" => "subagent tool requires coordinator runtime"}],
       details: %{},
       is_error: true,
       diagnostic: "unsupported_context"
     }}
  end
end
