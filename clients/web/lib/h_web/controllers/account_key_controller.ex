defmodule HWeb.AccountKeyController do
  use HWeb, :controller

  alias HWeb.Backend

  def create(conn, params) do
    change(
      conn,
      :put_api_key,
      Map.take(params, ~w(provider source api_key)),
      "Provider profile saved."
    )
  end

  def use(conn, params) do
    change(conn, :use_api_key, Map.take(params, ~w(provider source)), "Provider profile saved.")
  end

  def remove(conn, params) do
    change(conn, :remove_api_key, Map.take(params, ~w(provider source)), "Provider key removed.")
  end

  defp change(conn, operation, params, ok_message) do
    result = apply(Backend, operation, [params, []])

    conn =
      case result do
        {:ok, _} ->
          put_flash(conn, :info, ok_message)

        {:error, :invalid_api_key_profile} ->
          put_flash(conn, :error, "Invalid provider, alias or key.")

        {:error, :unknown_account_source} ->
          put_flash(conn, :error, "Provider key alias not found.")

        {:error, :too_many_account_sources} ->
          put_flash(conn, :error, "At most eight aliases can be configured.")

        _ ->
          put_flash(conn, :error, "The daemon could not update that provider profile.")
      end

    conn |> put_resp_header("cache-control", "no-store") |> redirect(to: ~p"/settings/accounts")
  end
end
