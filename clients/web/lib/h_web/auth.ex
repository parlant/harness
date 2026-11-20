defmodule HWeb.Auth do
  @moduledoc """
  Owner authentication Plug and LiveView `on_mount` hook backed by `H.Auth`.

  Fail-closed in all environments: if `H.Auth` is unavailable or the browser
  session lacks a valid owner cookie, browsing and commands are rejected.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  @session_key :h_owner_token
  @session_string_key "h_owner_token"

  @doc "Plug pipeline guard requiring an authenticated owner browser session."
  def require_authenticated_owner(conn, _opts) do
    token = get_session(conn, @session_key)

    if verify_session_token(token) do
      assign(conn, :authenticated_owner?, true)
    else
      conn
      |> redirect(to: "/login")
      |> halt()
    end
  end

  @doc "LiveView `on_mount` hook verifying the owner session on HTTP and WebSocket mount."
  def on_mount(:require_owner, _params, session, socket) do
    token = Map.get(session, @session_string_key)

    if verify_session_token(token) do
      {:cont, Phoenix.Component.assign(socket, :authenticated_owner?, true)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  end

  @doc "Verifies a browser session token against `H.Auth`'s ETS table."
  @spec verify_session_token(term()) :: boolean()
  def verify_session_token(token) when is_binary(token) and byte_size(token) > 0 do
    table = auth_table()

    case :ets.whereis(table) do
      :undefined -> false
      _ref -> H.Auth.verify_cookie(token, table)
    end
  end

  def verify_session_token(_), do: false

  @doc "Exchanges an owner bearer token for a browser session token via `H.Auth`."
  @spec create_browser_session(term()) ::
          {:ok, String.t()} | {:error, :unauthorized | :auth_unavailable}
  def create_browser_session(owner_token) when is_binary(owner_token) do
    server = auth_server()
    table = auth_table()

    if :ets.whereis(table) != :undefined and GenServer.whereis(server) != nil do
      H.Auth.create_browser_session(owner_token, server, table)
    else
      {:error, :auth_unavailable}
    end
  end

  def create_browser_session(_), do: {:error, :unauthorized}

  defp auth_server do
    daemon_opts = HWeb.Backend.InVM.daemon_opts()
    Keyword.get(daemon_opts, :auth_server, H.Auth)
  end

  defp auth_table do
    daemon_opts = HWeb.Backend.InVM.daemon_opts()
    Keyword.get(daemon_opts, :auth_table, :h_auth)
  end
end
