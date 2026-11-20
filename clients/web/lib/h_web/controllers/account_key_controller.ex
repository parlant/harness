defmodule HWeb.AccountKeyController do
  use HWeb, :controller

  def create(conn, params) do
    change(conn, :put_api_key, Map.take(params, ~w(provider source api_key)))
  end

  def use(conn, params) do
    change(conn, :use_api_key, Map.take(params, ~w(provider source)))
  end

  defp change(conn, operation, params) do
    opts = H.Daemon.instance_options() || Application.get_env(:harness_web, :daemon_opts, [])

    result =
      H.Daemon.Maintenance.admit(opts, fn ->
        apply(H.Accounts, operation, [opts[:accounts], params])
      end)

    conn =
      case result do
        {:ok, _} ->
          put_flash(conn, :info, "Provider profile saved.")

        {:error, :invalid_api_key_profile} ->
          put_flash(conn, :error, "Invalid provider, alias or key.")

        _ ->
          put_flash(conn, :error, "The daemon could not update that provider profile.")
      end

    conn |> put_resp_header("cache-control", "no-store") |> redirect(to: ~p"/settings/accounts")
  end
end
