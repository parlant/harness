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

  def link(conn, %{"code" => code} = params) when is_binary(code) do
    target = sanitize_redirect_target(params["next"])

    conn = put_resp_header(conn, "cache-control", "no-store")

    case Auth.redeem_sign_in_code(String.trim(code)) do
      {:ok, session_cookie} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:h_owner_token, session_cookie)
        |> redirect(to: target)

      {:error, :auth_unavailable} ->
        conn
        |> put_status(:service_unavailable)
        |> render(:new, error: "Authentication service unavailable")

      {:error, :unauthorized} ->
        if Auth.verify_session_token(get_session(conn, :h_owner_token)) do
          redirect(conn, to: target)
        else
          conn
          |> put_status(:unauthorized)
          |> render(:new, error: "Sign-in link is invalid or expired")
        end
    end
  end

  def link(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> redirect(to: ~p"/login")
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

  defp sanitize_redirect_target(target) when is_binary(target) do
    trimmed = String.trim(target)

    if String.starts_with?(trimmed, "/") and not String.starts_with?(trimmed, "//") and
         not String.contains?(trimmed, ["\r", "\n", "\\"]) do
      trimmed
    else
      "/"
    end
  end

  defp sanitize_redirect_target(_), do: "/"
end
