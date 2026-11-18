defmodule H do
  @moduledoc """
  Top-level entry point for `:harness` (`H`).
  """

  @max_unix_socket_bytes 100

  @doc """
  Computes the local Unix domain socket path inside the private data directory.
  Use a shorter data directory or disable the socket if the path exceeds the OS limit.
  """
  @spec api_socket_path(String.t()) :: String.t()
  def api_socket_path(data_dir) when is_binary(data_dir) do
    path = Path.join(Path.expand(data_dir), "api.sock")

    if byte_size(path) > @max_unix_socket_bytes do
      raise ArgumentError, "api.sock path is too long; use a shorter data directory"
    end

    path
  end

  @doc """
  Starts the local `H` daemon (binding both loopback TCP and `<data_dir>/api.sock`
  plus `<data_dir>/daemon.json`) and prints the authenticated web client URL.

  Options:
    * `:data_dir` - storage root directory (default `"~/.local/share/h"`)
    * `:port` - loopback HTTP port (default `4100`)
    * `:api_socket` - bind local Unix domain socket (default `true`)
    * `:provider` - `H.Provider` module (default `H.Provider.ReqLLM`)
    * `:provider_config` - map forwarded to provider (default `%{}`)
    * `:environments` - optional map/list of `H.EnvRegistry` specs
  """
  @spec serve(keyword()) ::
          {:ok,
           %{
             url: String.t(),
             port: non_neg_integer(),
             api_socket: nil | String.t(),
             data_dir: String.t()
           }}
  def serve(opts \\ []) when is_list(opts) do
    {:ok, _} = Application.ensure_all_started(:harness)

    data_dir =
      opts
      |> Keyword.get(:data_dir, Path.expand("~/.local/share/h"))
      |> Path.expand()

    port = Keyword.get(opts, :port, 4100)
    bind_socket? = Keyword.get(opts, :api_socket, true)
    provider = Keyword.get(opts, :provider, H.Provider.ReqLLM)
    provider_config = Keyword.get(opts, :provider_config, %{})

    {:ok, _} = ensure_started({H.StoreLock, data_dir: data_dir, name: H.StoreLock})
    {:ok, _} = ensure_started({H.Auth, data_dir: data_dir, name: H.Auth, table: :h_auth})
    {:ok, _} = ensure_started({H.Catalog, data_dir: data_dir, name: H.Catalog, table: :h_catalog})

    daemon_opts =
      [
        data_dir: data_dir,
        provider: provider,
        provider_config: provider_config
      ]
      |> maybe_put_kw(:environments, Keyword.get(opts, :environments))

    :ok = H.Daemon.recover_active_sessions(daemon_opts)

    router_opts = [
      port: port,
      auth_server: H.Auth,
      auth_table: :h_auth,
      daemon: H.Daemon,
      daemon_opts: daemon_opts
    ]

    {:ok, bandit_pid} =
      ensure_started(
        Supervisor.child_spec(
          {Bandit, plug: {H.HTTP.Router, router_opts}, ip: {127, 0, 0, 1}, port: port},
          id: :h_http_tcp
        )
      )

    {:ok, {_ip, bound_port}} = ThousandIsland.listener_info(bandit_pid)

    sock_path =
      if bind_socket? do
        path = api_socket_path(data_dir)
        {:ok, _unix_pid} = ensure_started({H.HTTP.UnixListener, {path, router_opts}})
        path
      else
        nil
      end

    write_daemon_manifest!(data_dir, bound_port, sock_path)

    token = H.Auth.owner_token(:h_auth)
    url = "http://127.0.0.1:#{bound_port}/#token=#{token}"
    IO.puts("H web client listening at #{url}")

    {:ok, %{url: url, port: bound_port, api_socket: sock_path, data_dir: data_dir}}
  end

  @doc false
  @spec write_daemon_manifest!(String.t(), nil | non_neg_integer(), nil | String.t()) :: :ok
  def write_daemon_manifest!(data_dir, bound_port, sock_path) do
    manifest_path = Path.join(data_dir, "daemon.json")
    tmp_path = "#{manifest_path}.tmp.#{System.unique_integer([:positive])}"

    payload = %{
      "version" => 1,
      "pid" => String.to_integer(System.pid()),
      "http_url" => if(is_integer(bound_port), do: "http://127.0.0.1:#{bound_port}", else: nil),
      "api_socket" => sock_path
    }

    File.write!(tmp_path, JSON.encode!(payload))
    File.chmod!(tmp_path, 0o600)
    File.rename!(tmp_path, manifest_path)
  end

  defp ensure_started(child_spec) do
    case Supervisor.start_child(H.Supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, val), do: Keyword.put(opts, key, val)
end
