defmodule HWeb.ProviderConfigController do
  use HWeb, :controller

  alias HWeb.Backend

  def create(conn, %{"provider" => params}) when is_map(params) do
    case Backend.stage_provider(params) do
      :ok ->
        conn
        |> put_flash(:info, "Provider configuration saved for the next daemon restart.")
        |> redirect(to: ~p"/settings/providers?#{[provider: params["id"]]}")

      {:error, reason} ->
        conn |> put_flash(:error, message(reason)) |> redirect(to: ~p"/settings/providers")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, message(:invalid_provider_config))
    |> redirect(to: ~p"/settings/providers")
  end

  defp message(:invalid_provider_config),
    do: "Invalid provider ID, HTTPS URL, or model catalog. Check the fields and try again."

  defp message(:stale_provider_config),
    do: "The catalog changed while you were editing it. Reopen the provider before saving again."

  defp message(:provider_key_binding),
    do: "That provider ID is already bound. Use a new ID for a different endpoint."

  defp message(_), do: "The daemon could not save the provider catalog."
end
