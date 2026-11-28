defmodule HWeb.Plugs.ExtensionAssets do
  @moduledoc """
  Serves static CSS, JS/MJS, font, and image assets declared by active `:web`
  extensions under `/ext-assets/:ext_id/*path`.

  Rejects path traversal and symlinks via `HWeb.Extensions.static_file/3`, and
  responds with `404` for unknown `/ext-assets/*` requests while passing all
  other request paths through untouched.
  """

  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{method: method, path_info: ["ext-assets", ext_id | path_segments]} = conn, opts)
      when method in ["GET", "HEAD"] do
    case HWeb.Extensions.static_file(ext_id, path_segments, opts) do
      {:ok, file_path, content_type} ->
        conn =
          conn
          |> put_resp_header("content-type", content_type)
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header("cache-control", "no-cache")

        if method == "HEAD" do
          conn
          |> send_resp(200, "")
          |> halt()
        else
          conn
          |> send_file(200, file_path)
          |> halt()
        end

      :error ->
        not_found(conn)
    end
  end

  def call(%{path_info: ["ext-assets" | _]} = conn, _opts), do: not_found(conn)
  def call(conn, _opts), do: conn

  defp not_found(conn) do
    conn
    |> put_resp_header("content-type", "text/plain; charset=utf-8")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(404, "not found")
    |> halt()
  end
end
