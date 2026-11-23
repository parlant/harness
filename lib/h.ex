defmodule H do
  @moduledoc """
  Elixir/OTP core for H (`hiness` on Hex, `:harness` OTP application).

  H runs coding-agent sessions in a supervised local daemon with branched
  conversations, file-backed WAL commits, and synchronized terminal (`hi`) and
  browser (`hiweb`) clients.

  ## Start or embed the daemon

    * Call `H.serve/1` to start a standalone daemon instance with loopback HTTP,
      a private Unix domain socket (`api.sock`), and owner-token authentication.
    * Configure `config :harness, data_dir: "/path/to/store"` to start the
      supervised daemon instance inside an existing OTP application (see
      `H.Application`) and call `H.Daemon` directly in the same BEAM VM.
    * Implement `H.Extension`, `H.Harness`, `H.Tool`, `H.ExecutionEnv`,
      `H.Storage`, or `H.Provider` to extend H at startup.

  ## Operator manual and installation

  This HexDocs package documents the Elixir module API, typespecs, and behaviour
  contracts. Read the operator manual, walkthroughs, and signed binary release
  guides on [hiness.dev](https://hiness.dev):

    * [Install H (`hi`, `h-daemon`, `H.app`)](https://hiness.dev/docs/setup/)
    * [Architecture and recovery](https://hiness.dev/docs/architecture/)
    * [Local HTTP and SSE protocol](https://hiness.dev/docs/protocol/)
    * [Write a startup extension](https://hiness.dev/docs/extensions/)
    * [Build a custom client](https://hiness.dev/docs/guides/build-a-client/)
    * [Manage the background daemon](https://hiness.dev/docs/daemon/)
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
  Starts the `H` daemon with TCP and `<data_dir>/api.sock`, publishes
  `<data_dir>/daemon.json`, and prints the bound API URLs.

  Options:
    * `:data_dir` - storage root directory (default `"~/.local/share/h"`)
    * `:port` - HTTP port (default `4100`)
    * `:bind_addresses` - IPv4 tuples (default from `<data_dir>/network.json`, or loopback)
    * `:api_socket` - bind local Unix domain socket (default `true`)
    * `:idle_session_timeout_ms` - unload quiet local file-backed sessions (default `300_000`; `:infinity` disables)
    * `:provider` - `H.Provider` module (default `H.Provider.ReqLLM`)
    * `:provider_config` - map forwarded to provider (default `%{}`)
    * `:auto_compaction` - scoped input token thresholds (see [Local HTTP and SSE protocol](https://hiness.dev/docs/protocol/))
    * `:environments` - optional map/list of `H.EnvRegistry` specs
    * `:harnesses` - optional trusted `H.Harness` registrations
    * `:no_extensions` - bypass `<data_dir>/extensions.json` and all path packages
  """
  @spec serve(keyword()) ::
          {:ok,
           %{
             url: String.t(),
             urls: [String.t()],
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

    network =
      case Keyword.fetch(opts, :bind_addresses) do
        {:ok, addresses} -> {:ok, addresses}
        :error -> H.Daemon.Network.load(data_dir)
      end

    with {:ok, addresses} <- network,
         instance_opts = Keyword.put(instance_opts, :bind_addresses, addresses),
         :ok <- ensure_standalone_application(),
         {:ok, _pid} <- start_instance(instance_opts) do
      [{port, url} | _] = endpoints = H.Daemon.Runtime.http_endpoints(instance_opts)
      urls = Enum.map(endpoints, &elem(&1, 1))
      socket = if instance_opts[:api_socket], do: api_socket_path(data_dir)
      Enum.each(urls, &IO.puts("H daemon API listening at #{&1}/api/v1"))
      {:ok, %{url: url, urls: urls, port: port, api_socket: socket, data_dir: data_dir}}
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
  @spec write_daemon_manifest!(String.t(), [String.t()], nil | String.t()) :: :ok
  def write_daemon_manifest!(data_dir, urls, sock_path) do
    manifest_path = Path.join(data_dir, "daemon.json")
    tmp_path = "#{manifest_path}.tmp.#{System.unique_integer([:positive])}"

    payload = %{
      "version" => 1,
      "pid" => String.to_integer(System.pid()),
      "http_url" => List.first(urls),
      "http_urls" => urls,
      "api_socket" => sock_path
    }

    File.write!(tmp_path, JSON.encode!(payload))
    File.chmod!(tmp_path, 0o600)
    File.rename!(tmp_path, manifest_path)
  end
end
