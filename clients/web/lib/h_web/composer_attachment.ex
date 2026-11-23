defmodule HWeb.ComposerAttachment do
  @moduledoc "Converts bounded LiveView uploads into existing transcript content blocks."

  @max_entries 6
  @max_image_bytes 2 * 1024 * 1024
  @max_total_bytes 8 * 1024 * 1024
  @max_text_bytes 64 * 1024
  @image_extensions ~w(.png .jpg .jpeg .webp)

  def max_entries, do: @max_entries

  def upload_options do
    [accept: :any, max_entries: @max_entries, max_file_size: @max_image_bytes]
  end

  def image_name?(name), do: String.downcase(Path.extname(name)) in @image_extensions

  def read_all(uploads) when is_list(uploads) do
    Enum.reduce_while(uploads, {:ok, [], 0}, fn {meta, entry}, {:ok, blocks, total} ->
      case read_bytes(meta, entry) do
        {:ok, bytes} when total + byte_size(bytes) > @max_total_bytes ->
          {:halt, {:error, "Total attachments must be 8 MiB or smaller."}}

        {:ok, bytes} ->
          case content_block(bytes, entry.client_name) do
            {:ok, block} -> {:cont, {:ok, [block | blocks], total + byte_size(bytes)}}
            {:error, message} -> {:halt, {:error, "#{entry.client_name}: #{message}"}}
          end

        {:error, message} ->
          {:halt, {:error, "#{entry.client_name}: #{message}"}}
      end
    end)
    |> case do
      {:ok, blocks, _total} -> {:ok, Enum.reverse(blocks)}
      {:error, message} -> {:error, message}
    end
  end

  # The path is from LiveView's upload writer, never from the browser. It is
  # size-limited during upload; only the content block enters session history.
  defp read_bytes(%{path: path}, _entry) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= @max_image_bytes -> {:ok, bytes}
      {:ok, _} -> {:error, "Images must be 2 MiB or smaller."}
      {:error, _} -> {:error, "Could not read the attachment. Choose it again."}
    end
  end

  defp content_block(bytes, name) do
    case image_type(bytes) do
      nil ->
        text_block(bytes, name)

      media_type ->
        {:ok,
         %{
           "type" => "image",
           "media_type" => media_type,
           "encoding" => "base64",
           "data" => Base.encode64(bytes)
         }}
    end
  end

  defp image_type(<<137, "PNG\r\n\x1a\n", 13::32, "IHDR", _::binary>>), do: "image/png"
  defp image_type(<<255, 216, 255, _::binary>>), do: "image/jpeg"

  defp image_type(<<"RIFF", _size::32, "WEBP", chunk::binary-size(4), _::binary>>)
       when chunk in ["VP8 ", "VP8L", "VP8X"],
       do: "image/webp"

  defp image_type(_), do: nil

  defp text_block(bytes, name) do
    cond do
      image_name?(name) ->
        {:error, "The screenshot is not a valid PNG, JPEG or WebP."}

      not String.valid?(bytes) or :binary.match(bytes, <<0>>) != :nomatch ->
        {:error, "Choose a PNG, JPEG, WebP or UTF-8 text file."}

      byte_size(bytes) > @max_text_bytes ->
        {:error, "Text files must be 64 KiB or smaller."}

      true ->
        text = String.replace_prefix(bytes, "\uFEFF", "")

        {:ok,
         %{
           "type" => "text",
           "text" => "Attached file #{inspect(name, printable_limit: 160)}:\n#{text}"
         }}
    end
  end
end
