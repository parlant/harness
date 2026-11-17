defmodule H.Tools.Read do
  @moduledoc """
  Core `read` tool for bounded UTF-8 text reads and PNG/JPEG/GIF/WebP image reads.
  """

  @behaviour H.Tool

  @default_limit 2_000
  @max_image_bytes 4_718_592

  @image_mimes %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  @impl true
  def name, do: "read"

  @impl true
  def description do
    "Read a UTF-8 text file (with optional 1-indexed line offset and limit) or an image file (PNG, JPEG, GIF, WebP up to 4.5 MiB)."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to read"},
        "offset" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" => "1-indexed line number to start reading from"
        },
        "limit" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" => "Maximum number of lines to read"
        }
      },
      "required" => ["path"],
      "additionalProperties" => false
    }
  end

  @impl true
  def replay, do: :safe

  @impl true
  def mutating?, do: false

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    path = fetch_arg(args, "path", :path)
    offset = fetch_arg(args, "offset", :offset) || 1
    limit = fetch_arg(args, "limit", :limit) || @default_limit

    case image_mime(path) do
      {:ok, mime} ->
        read_image(context.env, path, mime)

      :not_image ->
        read_text(context.env, path, offset, limit)
    end
  end

  defp image_mime(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()

    case Map.fetch(@image_mimes, ext) do
      {:ok, mime} -> {:ok, mime}
      :error -> :not_image
    end
  end

  defp read_image(env, path, mime) do
    case H.ExecutionEnv.read_file_bytes(env, path, max_bytes: @max_image_bytes) do
      {:ok, bytes} ->
        {:ok,
         %{
           content: [
             %{
               "type" => "image",
               "mime_type" => mime,
               "data" => Base.encode64(bytes)
             }
           ],
           details: %{path: path, mime_type: mime, bytes: byte_size(bytes)},
           is_error: false,
           diagnostic: nil
         }}

      {:error, :file_too_large} ->
        error_result(
          "Image #{path} exceeds maximum allowed size of 4.5 MiB.",
          %{path: path, reason: "file_too_large"},
          "file_too_large"
        )

      {:error, reason} ->
        error_result(
          "Failed to read image #{path}: #{format_reason(reason)}",
          %{path: path, reason: format_reason(reason)},
          reason_diagnostic(reason)
        )
    end
  end

  defp read_text(env, path, offset, limit) do
    case H.ExecutionEnv.read_file_lines(env, path, offset: offset, limit: limit) do
      {:ok, %{total_lines_read: 0, truncated_by_bytes: true, start_line: start_line}} ->
        error_result(
          "Line #{start_line} in #{path} exceeds the maximum read byte limit.",
          %{path: path, start_line: start_line},
          "line_too_large"
        )

      {:ok, result} ->
        text = format_text_result(result)

        {:ok,
         %{
           content: [%{"type" => "text", "text" => text}],
           details: %{
             path: path,
             start_line: result.start_line,
             lines_read: result.total_lines_read,
             has_more: result.has_more,
             truncated_by_bytes: result.truncated_by_bytes
           },
           is_error: false,
           diagnostic: nil
         }}

      {:error, reason} ->
        error_result(
          "Failed to read #{path}: #{format_reason(reason)}",
          %{path: path, reason: format_reason(reason)},
          reason_diagnostic(reason)
        )
    end
  end

  defp format_text_result(%{lines: [], has_more: false}) do
    "(empty file)"
  end

  defp format_text_result(result) do
    body =
      result.lines
      |> Enum.with_index(result.start_line)
      |> Enum.map_join("\n", fn {line, line_no} -> "#{line_no}: #{line}" end)

    if result.has_more do
      next_offset = result.start_line + result.total_lines_read
      reason_note = if result.truncated_by_bytes, do: " (byte limit reached)", else: ""

      body <>
        "\n\n[Truncated#{reason_note}. Showing lines #{result.start_line}-#{next_offset - 1}. Pass offset: #{next_offset} to read more.]"
    else
      body
    end
  end

  defp error_result(message, details, diagnostic) do
    {:error,
     %{
       content: [%{"type" => "text", "text" => message}],
       details: details,
       is_error: true,
       diagnostic: diagnostic
     }}
  end

  defp reason_diagnostic(:binary_file), do: "binary_file"
  defp reason_diagnostic(:enoent), do: "not_found"
  defp reason_diagnostic(:eisdir), do: "is_directory"
  defp reason_diagnostic(:eacces), do: "permission_denied"
  defp reason_diagnostic(_), do: "read_failed"

  defp format_reason(:binary_file), do: "binary or invalid UTF-8 file"
  defp format_reason(:enoent), do: "file not found"
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
