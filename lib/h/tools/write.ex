defmodule H.Tools.Write do
  @moduledoc """
  Core `write` tool for atomically writing a file through `H.ExecutionEnv`.
  """

  @behaviour H.Tool

  @impl true
  def name, do: "write"

  @impl true
  def description do
    "Write content to a file, creating parent directories if needed and overwriting atomically."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to write"},
        "content" => %{"type" => "string", "description" => "Content to write to the file"}
      },
      "required" => ["path", "content"],
      "additionalProperties" => false
    }
  end

  @impl true
  def replay, do: :unsafe

  @impl true
  def mutating?, do: true

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    path = fetch_arg(args, "path", :path)
    content = fetch_arg(args, "content", :content)

    case H.ExecutionEnv.write_file(context.env, path, content) do
      :ok ->
        bytes = IO.iodata_length(content)

        {:ok,
         %{
           content: [%{"type" => "text", "text" => "Wrote #{bytes} bytes to #{path}"}],
           details: %{path: path, bytes: bytes},
           is_error: false,
           diagnostic: nil
         }}

      {:error, reason} ->
        {:error,
         %{
           content: [
             %{"type" => "text", "text" => "Failed to write #{path}: #{format_reason(reason)}"}
           ],
           details: %{path: path, reason: inspect(reason)},
           is_error: true,
           diagnostic: reason_diagnostic(reason)
         }}
    end
  end

  defp reason_diagnostic(:eisdir), do: "is_directory"
  defp reason_diagnostic(:eacces), do: "permission_denied"
  defp reason_diagnostic(_), do: "write_failed"

  defp format_reason(:eisdir), do: "path is a directory"
  defp format_reason(:eacces), do: "permission denied"
  defp format_reason(other), do: inspect(other)

  defp fetch_arg(args, str_key, atom_key) do
    case Map.fetch(args, str_key) do
      {:ok, val} -> val
      :error -> Map.get(args, atom_key)
    end
  end
end
