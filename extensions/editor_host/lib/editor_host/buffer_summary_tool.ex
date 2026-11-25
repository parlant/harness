defmodule Extensions.EditorHost.BufferSummaryTool do
  @moduledoc """
  Static `editor_buffer_summary` tool proxy (`@behaviour H.Tool`).

  Reads a live editor buffer summary from the single paired live host for the
  session workspace. Requires an explicit `expected_revision` precondition so
  replaying an interrupted read cannot silently return a different buffer
  revision.
  """

  @behaviour H.Tool

  alias Extensions.EditorHost.Broker
  alias H.ExecutionEnv

  @default_max_lines 100
  @max_lines_cap 500

  @impl H.Tool
  def name, do: "editor_buffer_summary"

  @impl H.Tool
  def description do
    "Read a bounded summary of an open editor buffer for the session workspace, requiring an expected_revision precondition."
  end

  @impl H.Tool
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "Relative or workspace file path of the open editor buffer"
        },
        "expected_revision" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "Required non-empty buffer revision precondition (e.g. \"rev-1\")"
        },
        "max_lines" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => @max_lines_cap,
          "description" => "Maximum number of lines to summarize (1..500, default 100)"
        }
      },
      "required" => ["path", "expected_revision"],
      "additionalProperties" => false
    }
  end

  @impl H.Tool
  def replay, do: :safe

  @impl H.Tool
  def mutating?, do: false

  @impl H.Tool
  def execute(args, context) when is_map(args) and is_map(context) do
    path = fetch_arg(args, "path", :path)
    expected_revision = fetch_arg(args, "expected_revision", :expected_revision)
    max_lines = fetch_arg(args, "max_lines", :max_lines) || @default_max_lines
    workspace_cwd = ExecutionEnv.cwd(context.env)

    with :ok <- validate_non_empty_string(path, "path"),
         :ok <- validate_non_empty_string(expected_revision, "expected_revision"),
         {:ok, normalized_path} <- validate_workspace_path(context.env, workspace_cwd, path),
         :ok <- validate_max_lines(max_lines) do
      broker_opts =
        [
          timeout_ms: Map.get(context, :timeout_ms),
          server: Map.get(context, :broker)
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      Broker.invoke_buffer_summary(
        workspace_cwd,
        %{
          "path" => normalized_path,
          "expected_revision" => expected_revision,
          "max_lines" => max_lines
        },
        broker_opts
      )
    else
      {:error, diagnostic, message} ->
        {:error,
         %{
           content: [%{"type" => "text", "text" => message}],
           details: %{"reason" => diagnostic},
           is_error: true,
           diagnostic: diagnostic
         }}
    end
  end

  defp fetch_arg(args, str_key, atom_key) do
    case Map.fetch(args, str_key) do
      {:ok, val} -> val
      :error -> Map.get(args, atom_key)
    end
  end

  defp validate_non_empty_string(val, field) when is_binary(val) do
    if String.valid?(val) and String.trim(val) != "" and not String.contains?(val, <<0>>) do
      :ok
    else
      {:error, "invalid_arguments", "#{field} must be a non-empty valid UTF-8 string"}
    end
  end

  defp validate_non_empty_string(_val, field),
    do: {:error, "invalid_arguments", "#{field} must be a non-empty valid UTF-8 string"}

  defp validate_workspace_path(env, workspace_cwd, raw_path) do
    case ExecutionEnv.resolve_path(env, raw_path) do
      {:ok, resolved} ->
        if within_workspace?(resolved, workspace_cwd) do
          {:ok, Path.relative_to(resolved, workspace_cwd)}
        else
          {:error, "invalid_arguments", "path escapes session workspace"}
        end

      {:error, _reason} ->
        {:error, "invalid_arguments", "invalid workspace path"}
    end
  end

  defp within_workspace?(resolved, workspace_cwd) do
    resolved == workspace_cwd or String.starts_with?(resolved, workspace_cwd <> "/")
  end

  defp validate_max_lines(n) when is_integer(n) and n in 1..@max_lines_cap, do: :ok

  defp validate_max_lines(_),
    do: {:error, "invalid_arguments", "max_lines must be an integer between 1 and 500"}
end
