defmodule HWeb.ReviewFileController do
  use HWeb, :controller

  alias HWeb.{Backend, ReviewLive, WorkspaceMedia}

  def show(conn, %{"session_id" => sid, "path" => path, "preview" => "media"}) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with {:ok, {mode, mime}} <- WorkspaceMedia.type(path),
         {:ok, %{kind: :media, mode: ^mode, mime: ^mime, bytes: bytes}} <-
           Backend.read_review_file(sid, path, "working") do
      preview(conn, mime, bytes)
    else
      _ -> send_resp(conn, 404, "Media unavailable")
    end
  end

  def show(conn, %{"session_id" => sid, "path" => path} = params) do
    source = Map.get(params, "source", "working")
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Backend.read_review_file(sid, path, source) do
      {:ok, file} ->
        respond(conn, file, params["preview"] == "1")

      {:error, reason} ->
        code =
          if reason in [:enoent, :not_in_head, :not_in_commit], do: "missing", else: "unavailable"

        conn
        |> put_status(:not_found)
        |> json(%{code: code, error: ReviewLive.error_message(reason)})
    end
  end

  def show(conn, _params), do: send_resp(conn, 400, "File path required")

  defp respond(conn, %{revision: revision} = file, false) do
    etag = ~s("#{revision}")
    conn = put_resp_header(conn, "etag", etag)

    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      view =
        case file do
          %{kind: :text, text: text, preview: preview} ->
            %{kind: "text", text: text, preview: preview && elem(preview, 0)}

          %{kind: :media, mode: mode} ->
            %{kind: "media", preview: mode}
        end

      json(conn, Map.put(view, :revision, revision))
    end
  end

  defp respond(conn, %{kind: :text, preview: {_mode, mime}, text: text}, true),
    do: preview(conn, mime, text)

  defp respond(conn, %{kind: :media, mime: mime, bytes: bytes}, true),
    do: preview(conn, mime, bytes)

  defp respond(conn, _, true), do: send_resp(conn, 404, "No preview available")

  # No workspace document should ever execute with the owner origin. Inline
  # styles/data images are enough to preview static HTML without requesting
  # arbitrary URLs (including authenticated URLs on this server).
  defp preview(conn, mime, bytes) do
    conn
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header(
      "content-security-policy",
      "sandbox; default-src 'none'; frame-ancestors 'self'; style-src 'unsafe-inline'; img-src data:"
    )
    |> put_resp_header("x-frame-options", "SAMEORIGIN")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_content_type(mime, nil)
    |> send_media(bytes)
  end

  # Media elements (notably Safari) may require byte ranges to play or seek.
  defp send_media(conn, bytes) do
    size = byte_size(bytes)
    conn = put_resp_header(conn, "accept-ranges", "bytes")

    case get_req_header(conn, "range") do
      ["bytes=" <> range] ->
        case byte_range(range, size) do
          {first, last} ->
            conn
            |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
            |> send_resp(206, binary_part(bytes, first, last - first + 1))

          nil ->
            conn |> put_resp_header("content-range", "bytes */#{size}") |> send_resp(416, "")
        end

      _ ->
        send_resp(conn, 200, bytes)
    end
  end

  defp byte_range(range, size) when size > 0 and byte_size(range) <= 40 do
    case String.split(range, "-", parts: 2) do
      ["", suffix] ->
        case Integer.parse(suffix) do
          {len, ""} when len > 0 -> {max(size - len, 0), size - 1}
          _ -> nil
        end

      [start, finish] ->
        with {first, ""} when first in 0..(size - 1)//1 <- Integer.parse(start),
             {last, ""} when last >= first <-
               if(finish == "", do: {size - 1, ""}, else: Integer.parse(finish)) do
          {first, min(last, size - 1)}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp byte_range(_, _), do: nil
end
