defmodule HWeb.WorkspaceMedia do
  @moduledoc """
  Session-relative raster image and video references for assistant replies.

  The review reader enforces filesystem containment and size limits; this module
  restricts what the transcript can embed and verifies the returned media type.
  """
  use HWeb, :verified_routes

  @types %{
    ".png" => {:image, "image/png"},
    ".jpg" => {:image, "image/jpeg"},
    ".jpeg" => {:image, "image/jpeg"},
    ".gif" => {:image, "image/gif"},
    ".webp" => {:image, "image/webp"},
    ".mp4" => {:video, "video/mp4"},
    ".webm" => {:video, "video/webm"}
  }

  def from_reference(session_id, encoded_path) when byte_size(encoded_path) <= 12_288 do
    path = URI.decode(encoded_path)

    with true <- valid_relative_path?(path),
         {:ok, {kind, _mime}} <- type(path) do
      url =
        path(%URI{}, ~p"/sessions/#{session_id}/review/file?#{%{path: path, preview: "media"}}")

      {:ok, {kind, url}}
    end
  end

  def from_reference(_, _), do: :error

  def type(path) when is_binary(path), do: Map.fetch(@types, String.downcase(Path.extname(path)))
  def type(_), do: :error

  defp valid_relative_path?(path) when byte_size(path) in 1..4096 do
    String.valid?(path) and not String.contains?(path, [<<0>>, "\r", "\n", "\\"]) and
      Enum.all?(
        String.split(path, "/"),
        &(&1 not in ["", ".", ".."] and String.downcase(&1) != ".git")
      )
  end

  defp valid_relative_path?(_), do: false
end
