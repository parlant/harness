defmodule HWeb.ComposerAttachment do
  @moduledoc "Converts a bounded LiveView upload into an existing transcript content block."

  @max_image_bytes 2 * 1024 * 1024
  @max_text_bytes 64 * 1024
  @image_extensions ~w(.png .jpg .jpeg .webp)

  def upload_options do
    [accept: :any, max_entries: 1, max_file_size: @max_image_bytes]
  end

  def image_name?(name), do: String.downcase(Path.extname(name)) in @image_extensions

  # The path is from LiveView's upload writer, never from the browser. It is
  # size-limited during upload; only the content block enters session history.
  def read(%{path: path}, %{client_name: name}) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= @max_image_bytes -> content_block(bytes, name)
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
