defmodule H do
  @moduledoc """
  Top-level entry point for `:harness` (`H`).
  """

  @doc """
  Starts the local `H` daemon and prints the authenticated web client URL.

  Options:
    * `:data_dir` - storage root directory (default `"~/.local/share/h"`)
    * `:port` - loopback HTTP port (default `4100`)
    * `:provider` - `H.Provider` module (default `H.Provider.ReqLLM`)
    * `:provider_config` - map forwarded to provider (default `%{}`)
  """
  @spec serve(keyword()) :: {:ok, %{url: String.t(), port: pos_integer(), data_dir: String.t()}}
  def serve(opts \\ []) when is_list(opts) do
    {:ok, _} = Application.ensure_all_started(:harness)

    data_dir =
      opts
      |> Keyword.get(:data_dir, Path.expand("~/.local/share/h"))
      |> Path.expand()

    port = Keyword.get(opts, :port, 4100)
    provider = Keyword.get(opts, :provider, H.Provider.ReqLLM)
    provider_config = Keyword.get(opts, :provider_config, %{})

    {:ok, _} = ensure_started({H.StoreLock, data_dir: data_dir, name: H.StoreLock})
    {:ok, _} = ensure_started({H.Auth, data_dir: data_dir, name: H.Auth, table: :h_auth})
    {:ok, _} = ensure_started({H.Catalog, data_dir: data_dir, name: H.Catalog, table: :h_catalog})

    daemon_opts = [
      data_dir: data_dir,
      provider: provider,
      provider_config: provider_config
    ]

    :ok = H.Daemon.recover_active_sessions(daemon_opts)

    router_opts = [
      port: port,
      auth_server: H.Auth,
      auth_table: :h_auth,
      daemon: H.Daemon,
      daemon_opts: daemon_opts
    ]

    {:ok, bandit_pid} =
      Supervisor.start_child(
        H.Supervisor,
        {Bandit, plug: {H.HTTP.Router, router_opts}, ip: {127, 0, 0, 1}, port: port}
      )

    {:ok, {_ip, bound_port}} = ThousandIsland.listener_info(bandit_pid)
    token = H.Auth.owner_token(:h_auth)
    url = "http://127.0.0.1:#{bound_port}/#token=#{token}"
    IO.puts("H web client listening at #{url}")

    {:ok, %{url: url, port: bound_port, data_dir: data_dir}}
  end

  defp ensure_started(child_spec) do
    case Supervisor.start_child(H.Supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end
end
