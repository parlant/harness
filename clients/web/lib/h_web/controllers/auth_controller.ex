defmodule HWeb.AuthController do
  @moduledoc """
  Handles owner token login and logout with CSRF-protected form submissions and
  encrypted HttpOnly session cookies.
  """
  use HWeb, :controller

  alias HWeb.Auth

  def new(conn, _params) do
    if Auth.verify_session_token(get_session(conn, :h_owner_token)) do
      redirect(conn, to: ~p"/")
    else
      render(conn, :new, error: nil)
    end
  end

  def create(conn, %{"token" => token}) when is_binary(token) do
    case Auth.create_browser_session(String.trim(token)) do
      {:ok, session_cookie} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:h_owner_token, session_cookie)
        |> redirect(to: ~p"/")

      {:error, :auth_unavailable} ->
        conn
        |> put_status(:service_unavailable)
        |> render(:new, error: "Authentication service unavailable")

      {:error, :unauthorized} ->
        conn
        |> put_status(:unauthorized)
        |> render(:new, error: "Invalid owner token")
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> render(:new, error: "Owner token is required")
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end
end
