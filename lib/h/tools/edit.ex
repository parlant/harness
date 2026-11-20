defmodule H.Tools.Edit do
  @moduledoc """
  Core `edit` tool for exact, unique, non-overlapping multi-hunk replacements
  against the original file contents while preserving untouched line endings.
  """

  @behaviour H.Tool

  @max_edit_file_bytes 10_485_760

  @impl true
  def name, do: "edit"

  @impl true
  def description do
    "Apply one or more exact, unique, non-overlapping text replacements to a file. All old_text strings are matched against the original file."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "cwd" => H.Tool.cwd_schema(),
        "path" => %{"type" => "string", "description" => "Path to the file to edit"},
        "edits" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "old_text" => %{
                "type" => "string",
                "description" => "Exact non-empty text to replace in the original file"
              },
              "new_text" => %{
                "type" => "string",
                "description" => "Replacement text"
              }
            },
            "required" => ["old_text", "new_text"],
            "additionalProperties" => false
          },
          "description" => "List of non-overlapping exact replacements"
        }
      },
      "required" => ["path", "edits"],
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
    raw_edits = fetch_arg(args, "edits", :edits)

    with :ok <- validate_edits_list(raw_edits),
         {:ok, original} <- read_utf8_file(context.env, path),
         {:ok, hunks} <- locate_all_hunks(original, raw_edits),
         :ok <- ensure_non_overlapping(hunks),
         updated = apply_hunks(original, hunks),
         :ok <- write_updated(context.env, path, updated) do
      {:ok,
       %{
         content: [
           %{
             "type" => "text",
             "text" => "Applied #{length(hunks)} edit(s) to #{path}"
           }
         ],
         details: %{path: path, edits_applied: length(hunks)},
         is_error: false,
         diagnostic: nil
       }}
    end
  end

  defp validate_edits_list(edits) when is_list(edits) and edits != [] do
    Enum.with_index(edits)
    |> Enum.reduce_while(:ok, fn {edit, idx}, :ok ->
      old_text = if is_map(edit), do: fetch_arg(edit, "old_text", :old_text)
      new_text = if is_map(edit), do: fetch_arg(edit, "new_text", :new_text)

      cond do
        not (is_binary(old_text) and is_binary(new_text)) ->
          {:halt,
           error_result(
             "Edit #{idx} must provide string old_text and new_text.",
             %{index: idx},
             "invalid_edits"
           )}

        old_text == "" ->
          {:halt,
           error_result(
             "Edit #{idx} has empty old_text; old_text must be non-empty.",
             %{index: idx},
             "empty_old_text"
           )}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_edits_list(_) do
    error_result("edits must be a non-empty list.", %{}, "invalid_edits")
  end

  defp read_utf8_file(env, path) do
    case H.ExecutionEnv.read_file_bytes(env, path, max_bytes: @max_edit_file_bytes) do
      {:ok, bytes} ->
        if String.contains?(bytes, <<0>>) or not String.valid?(bytes) do
          error_result(
            "Cannot edit #{path}: binary or invalid UTF-8 file.",
            %{path: path},
            "binary_file"
          )
        else
          {:ok, bytes}
        end

      {:error, reason} ->
        error_result(
          "Failed to read #{path}: #{inspect(reason)}",
          %{path: path, reason: inspect(reason)},
          reason_diagnostic(reason)
        )
    end
  end

  defp locate_all_hunks(original, edits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {edit, idx}, {:ok, acc} ->
      old_text = fetch_arg(edit, "old_text", :old_text)
      new_text = fetch_arg(edit, "new_text", :new_text)

      case locate_unique_hunk(original, old_text, new_text) do
        {:ok, pos, len, replacement} ->
          {:cont, {:ok, [%{pos: pos, len: len, replacement: replacement, index: idx} | acc]}}

        {:error, :not_found} ->
          {:halt,
           error_result(
             "Edit #{idx} old_text was not found in #{original_hint(old_text)}.",
             %{index: idx},
             "old_text_not_found"
           )}

        {:error, :multiple_matches} ->
          {:halt,
           error_result(
             "Edit #{idx} old_text matched multiple times; provide more surrounding context.",
             %{index: idx},
             "old_text_not_unique"
           )}
      end
    end)
  end

  defp locate_unique_hunk(original, old_text, new_text) do
    case find_unique_span(original, old_text) do
      {:ok, pos, len} ->
        {:ok, pos, len, new_text}

      {:error, :not_found} ->
        if String.contains?(original, "\r\n") and not String.contains?(old_text, "\r\n") and
             String.contains?(old_text, "\n") do
          crlf_old = String.replace(old_text, "\n", "\r\n")

          case find_unique_span(original, crlf_old) do
            {:ok, pos, len} ->
              crlf_new =
                new_text
                |> String.replace("\r\n", "\n")
                |> String.replace("\n", "\r\n")

              {:ok, pos, len, crlf_new}

            other ->
              other
          end
        else
          {:error, :not_found}
        end

      {:error, :multiple_matches} ->
        {:error, :multiple_matches}
    end
  end

  defp find_unique_span(original, needle) do
    case :binary.match(original, needle) do
      :nomatch ->
        {:error, :not_found}

      {pos, len} ->
        next_start = pos + 1
        total = byte_size(original)

        if next_start < total and
             :binary.match(original, needle, scope: {next_start, total - next_start}) != :nomatch do
          {:error, :multiple_matches}
        else
          {:ok, pos, len}
        end
    end
  end

  defp ensure_non_overlapping(hunks) do
    sorted = Enum.sort_by(hunks, &{&1.pos, &1.len})

    sorted
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while(:ok, fn [a, b], :ok ->
      if a.pos + a.len > b.pos do
        {:halt,
         error_result(
           "Edit #{a.index} and edit #{b.index} overlap in the original file.",
           %{first_index: a.index, second_index: b.index},
           "overlapping_edits"
         )}
      else
        {:cont, :ok}
      end
    end)
  end

  defp apply_hunks(original, hunks) do
    sorted = Enum.sort_by(hunks, & &1.pos)

    {parts_rev, cursor} =
      Enum.reduce(sorted, {[], 0}, fn %{pos: pos, len: len, replacement: replacement},
                                      {acc, cursor} ->
        prefix = :binary.part(original, cursor, pos - cursor)
        {[replacement, prefix | acc], pos + len}
      end)

    tail = :binary.part(original, cursor, byte_size(original) - cursor)
    IO.iodata_to_binary(Enum.reverse([tail | parts_rev]))
  end

  defp write_updated(env, path, updated) do
    case H.ExecutionEnv.write_file(env, path, updated) do
      :ok ->
        :ok

      {:error, reason} ->
        error_result(
          "Failed to write #{path}: #{inspect(reason)}",
          %{path: path, reason: inspect(reason)},
          "write_failed"
        )
    end
  end

  defp original_hint(text) do
    preview = text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 60)
    inspect(preview)
  end

  defp reason_diagnostic(:enoent), do: "not_found"
  defp reason_diagnostic(:eisdir), do: "is_directory"
  defp reason_diagnostic(:eacces), do: "permission_denied"
  defp reason_diagnostic(:file_too_large), do: "file_too_large"
  defp reason_diagnostic(_), do: "read_failed"

  defp error_result(message, details, diagnostic) do
    {:error,
     %{
       content: [%{"type" => "text", "text" => message}],
       details: details,
       is_error: true,
       diagnostic: diagnostic
     }}
  end

  defp fetch_arg(args, str_key, atom_key) do
    case Map.fetch(args, str_key) do
      {:ok, val} -> val
      :error -> Map.get(args, atom_key)
    end
  end
end
