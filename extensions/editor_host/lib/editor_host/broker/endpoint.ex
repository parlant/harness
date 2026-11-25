defmodule Extensions.EditorHost.Broker.Endpoint do
  @moduledoc """
  Optional private local transport listener (Unix domain socket and/or loopback
  HTTP) for external live tool-host processes.

  Uses short-lived tool-host grants only; never accepts or exposes the daemon
  owner token.
  """

  use Supervisor

  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    broker = Keyword.fetch!(opts, :broker)
    socket_path = Keyword.get(opts, :socket_path)
    http_port = Keyword.get(opts, :http_port)

    children =
      []
      |> maybe_add_unix(socket_path, broker)
      |> maybe_add_http(http_port, broker)

    Supervisor.init(children, strategy: :one_for_one)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc false
  def start_link_with_info(opts) do
    case start_link(opts) do
      {:ok, sup} ->
        port = find_http_port(sup)
        {:ok, sup, port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_http_port(sup) do
    case Enum.find(Supervisor.which_children(sup), fn {id, _pid, _type, _mods} ->
           id == :editor_host_http
         end) do
      {:editor_host_http, pid, _, _} when is_pid(pid) ->
        case ThousandIsland.listener_info(pid) do
          {:ok, {_ip, port}} -> port
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_add_unix(children, nil, _broker), do: children

  defp maybe_add_unix(children, path, broker) when is_binary(path) do
    spec = %{
      id: :editor_host_unix,
      start: {__MODULE__.UnixListener, :start_link, [path, broker]},
      type: :supervisor
    }

    children ++ [spec]
  end

  defp maybe_add_http(children, nil, _broker), do: children

  defp maybe_add_http(children, port, broker) when is_integer(port) do
    spec =
      Supervisor.child_spec(
        {Bandit,
         plug: {__MODULE__.Router, [broker: broker]},
         ip: {127, 0, 0, 1},
         port: port,
         thousand_island_options: [shutdown_timeout: 1_000]},
        id: :editor_host_http
      )

    children ++ [spec]
  end

  defmodule UnixListener do
    @moduledoc false

    def start_link(path, broker) do
      with :ok <- remove_stale_socket(path),
           {:ok, pid} <-
             Bandit.start_link(
               plug: {Extensions.EditorHost.Broker.Endpoint.Router, [broker: broker]},
               ip: {:local, path},
               port: 0,
               thousand_island_options: [shutdown_timeout: 1_000]
             ) do
        case File.chmod(path, 0o600) do
          :ok ->
            {:ok, pid}

          {:error, reason} ->
            Supervisor.stop(pid)
            {:error, reason}
        end
      end
    end

    defp remove_stale_socket(path) do
      case File.lstat(path) do
        {:error, :enoent} ->
          :ok

        {:ok, %File.Stat{mode: mode}} when Bitwise.band(mode, 0o170000) == 0o140000 ->
          case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 100) do
            {:ok, sock} ->
              :gen_tcp.close(sock)
              {:error, :eaddrinuse}

            {:error, reason} when reason in [:enoent, :econnrefused] ->
              File.rm(path)

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, _} ->
          {:error, :eexist}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule Router do
    @moduledoc false
    use Plug.Router, copy_opts_to_assign: :broker_opts

    plug(:check_local_host)

    plug(Plug.Parsers,
      parsers: [:json],
      pass: ["application/json"],
      json_decoder: JSON,
      length: 131_072
    )

    plug(:match)
    plug(:dispatch)

    post "/editor-host/v1/connect" do
      broker = conn.assigns[:broker_opts][:broker]
      body = if is_map(conn.body_params), do: conn.body_params, else: %{}
      token = Map.get(body, "grant_token")

      if is_binary(token) do
        case Extensions.EditorHost.Broker.claim_grant(
               token,
               self(),
               body,
               server: broker
             ) do
          {:ok, claimed} ->
            conn =
              conn
              |> put_resp_content_type("text/event-stream")
              |> put_resp_header("cache-control", "no-cache")
              |> send_chunked(200)

            case chunk(conn, "event: connected\ndata: #{JSON.encode!(claimed)}\n\n") do
              {:ok, conn} -> stream_host_loop(conn)
              {:error, _} -> conn
            end

          {:error, reason} ->
            send_json(conn, 401, %{"error" => to_string(reason)})
        end
      else
        send_json(conn, 400, %{"error" => "missing_grant_token"})
      end
    end

    post "/editor-host/v1/invocations/:invocation_id/result" do
      broker = conn.assigns[:broker_opts][:broker]
      body = if is_map(conn.body_params), do: conn.body_params, else: %{}
      gen = Map.get(body, "host_generation")

      if is_integer(gen) and gen > 0 do
        case Extensions.EditorHost.Broker.complete_invocation(
               invocation_id,
               gen,
               body,
               server: broker
             ) do
          :ok -> send_json(conn, 200, %{"status" => "accepted"})
          {:error, reason} -> send_json(conn, 409, %{"error" => to_string(reason)})
        end
      else
        send_json(conn, 422, %{"error" => "invalid_host_generation"})
      end
    end

    match _ do
      send_json(conn, 404, %{"error" => "not_found"})
    end

    defp stream_host_loop(conn) do
      receive do
        {:editor_host_invoke, payload} ->
          frame = "event: invoke\ndata: #{JSON.encode!(payload)}\n\n"

          case chunk(conn, frame) do
            {:ok, conn} -> stream_host_loop(conn)
            {:error, _} -> conn
          end
      after
        15_000 ->
          case chunk(conn, ": keepalive\n\n") do
            {:ok, conn} -> stream_host_loop(conn)
            {:error, _} -> conn
          end
      end
    end

    defp check_local_host(conn, _opts) do
      unix? =
        match?({:local, _}, conn.remote_ip) or
          conn.remote_ip == :unspec or
          match?({:unspec, _}, conn.remote_ip)

      if unix? do
        put_resp_header(conn, "x-content-type-options", "nosniff")
      else
        port = conn.port

        case get_req_header(conn, "host") do
          [host] ->
            if host in ["127.0.0.1:#{port}", "[::1]:#{port}", "localhost:#{port}"] do
              put_resp_header(conn, "x-content-type-options", "nosniff")
            else
              conn |> send_json(421, %{"error" => "invalid_host"}) |> halt()
            end

          _ ->
            conn |> send_json(421, %{"error" => "invalid_host"}) |> halt()
        end
      end
    end

    defp send_json(conn, status, payload) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, JSON.encode!(payload))
    end
  end
end
