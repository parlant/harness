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
  plus `<data_dir>/daemon.json`) and prints the API base URL.

  Options:
    * `:data_dir` - storage root directory (default `"~/.local/share/h"`)
    * `:port` - loopback HTTP port (default `4100`)
    * `:api_socket` - bind local Unix domain socket (default `true`)
    * `:provider` - `H.Provider` module (default `H.Provider.ReqLLM`)
    * `:provider_config` - map forwarded to provider (default `%{}`)
    * `:auto_compaction` - scoped input token thresholds (see `docs/protocol.md`)
    * `:environments` - optional map/list of `H.EnvRegistry` specs
    * `:harnesses` - optional trusted `H.Harness` registrations
    * `:no_extensions` - bypass `<data_dir>/extensions.json` and all path packages
  """
  @spec serve(keyword()) ::
          {:ok,
           %{
             url: String.t(),
             port: non_neg_integer(),
             api_socket: nil | String.t(),
             data_dir: String.t()
           }}
          | {:error, term()}
  def serve(opts \\ []) when is_list(opts) do
    data_dir =
      opts
      |> Keyword.get(:data_dir, System.get_env("H_DATA_DIR") || "~/.local/share/h")
      |> Path.expand()

    instance_opts =
      opts
      |> Keyword.put(:data_dir, data_dir)
      |> Keyword.put(:http_port, Keyword.get(opts, :port, 4100))
      |> Keyword.put_new(:api_socket, true)

    with :ok <- ensure_standalone_application(),
         {:ok, _pid} <- start_instance(instance_opts) do
      {:ok, {_ip, port}} = ThousandIsland.listener_info(H.Daemon.HTTP)
      socket = if instance_opts[:api_socket], do: api_socket_path(data_dir)
      url = "http://127.0.0.1:#{port}"
      IO.puts("H daemon API listening at #{url}/api/v1")
      {:ok, %{url: url, port: port, api_socket: socket, data_dir: data_dir}}
    end
  end

  defp start_instance(opts) do
    case Supervisor.start_child(H.Supervisor, {H.Daemon.Instance, opts}) do
      {:error, {{:shutdown, {:failed_to_start_child, _, reason}}, _}} -> {:error, reason}
      result -> result
    end
  end

  defp ensure_standalone_application do
    cond do
      Process.whereis(H.Supervisor) ->
        :ok

      H.Application.children() != [] ->
        {:error, :embedded_daemon_configured}

      true ->
        with {:ok, _} <- Application.ensure_all_started(:harness), do: :ok
    end
  end

  @doc false
  @spec write_daemon_manifest!(String.t(), nil | non_neg_integer(), nil | String.t()) :: :ok
  def write_daemon_manifest!(data_dir, bound_port, sock_path) do
    manifest_path = Path.join(data_dir, "daemon.json")
    tmp_path = "#{manifest_path}.tmp.#{System.unique_integer([:positive])}"

    payload = %{
      "version" => 1,
      "pid" => String.to_integer(System.pid()),
      "http_url" =>
        if(is_integer(bound_port) and bound_port > 0,
          do: "http://127.0.0.1:#{bound_port}",
          else: nil
        ),
      "api_socket" => sock_path
    }

    File.write!(tmp_path, JSON.encode!(payload))
    File.chmod!(tmp_path, 0o600)
    File.rename!(tmp_path, manifest_path)
  end
end
