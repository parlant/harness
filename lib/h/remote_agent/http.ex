defmodule H.RemoteAgent.HTTP do
  @moduledoc """
  Authenticated HTTP / Unix domain socket server exposing an `H.RemoteAgent`
  over `/v1/*`.

  Supervises a dedicated `H.RemoteAgent` (owning an `H.ExecutionEnv.Host`) along
  with a TCP `Bandit` listener (`:ip`, `:port`, supporting `port: 0`) and/or a
  Unix domain socket listener (`:socket_path`).

  Security & execution guarantees:
    * Constant-time bearer authentication on all `/v1/*` routes: SHA-256 hashes
      of the provided and expected bearer tokens are compared via
      `Plug.Crypto.secure_compare/2`, returning `401` with `cache-control: no-store`.
    * Streaming command execution (`POST /v1/exec/stream`) sends NDJSON frames
      (`output`, `result`, `error`) with base64-encoded chunks and validates fences
      before spawning any OS process (`409` `"stale_fence"` on duplicate/older fences).
    * Monitors the underlying HTTP/UDS client socket (`active: :once` disconnect
      detection) so client disconnect immediately aborts the active `H.RemoteAgent`
      execution and reaps its OS process group (`SIGTERM` -> `SIGKILL`), just like
      lease expiry (`POST /v1/exec/renew`) and explicit abort (`POST /v1/exec/abort`).
  """

  use Supervisor

  alias H.ExecutionEnv.Host
  alias H.RemoteAgent

  @doc """
  Starts an `H.RemoteAgent.HTTP` supervision tree.

  ## Options
    * `:token` (required) - non-empty bearer token string
    * `:cwd` - working directory for the owned `H.ExecutionEnv.Host` (defaults to `File.cwd!/0`)
    * `:env` - optional prebuilt `H.ExecutionEnv.t()` instead of `:cwd`
    * `:id` - environment identifier (defaults to `H.ExecutionEnv.env_id(env)` or `"remote"`)
    * `:ip` - IPv4/IPv6 tuple to bind TCP listener on (default `{127, 0, 0, 1}`; pass `nil` with `:socket_path` for UDS-only)
    * `:port` - TCP port (default `0`; set `nil` to disable TCP when `:socket_path` is provided)
    * `:socket_path` - optional Unix domain socket path
    * `:startup_log` - Bandit startup log level or `false` (default `false`)
    * `:name` - optional supervisor registration name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    Supervisor.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc "Returns the bound HTTP endpoint URL (`http://<ip>:<port>`) for a running supervisor, or `nil`."
  @spec endpoint_url(Supervisor.supervisor()) :: nil | String.t()
  def endpoint_url(supervisor) do
    case listener_info(supervisor) do
      {:ok, {ip, port}} -> "http://#{format_ip(ip)}:#{port}"
      :error -> nil
    end
  end

  @doc "Returns the bound TCP port for a running supervisor, or `nil`."
  @spec port(Supervisor.supervisor()) :: nil | :inet.port_number()
  def port(supervisor) do
    case listener_info(supervisor) do
      {:ok, {_ip, port}} -> port
      :error -> nil
    end
  end

  @doc "Returns the child `H.RemoteAgent` pid inside this supervisor."
  @spec agent_pid(Supervisor.supervisor()) :: nil | pid()
  def agent_pid(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {H.RemoteAgent, pid, _type, _mods} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp listener_info(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {:http_listener, pid, _type, _mods} when is_pid(pid) ->
        ThousandIsland.listener_info(pid)

      _ ->
        nil
    end)
    |> case do
      {:ok, {_ip, _port}} = ok -> ok
      _ -> :error
    end
  end

  defp format_ip({0, 0, 0, 0}), do: "127.0.0.1"
  defp format_ip({0, 0, 0, 0, 0, 0, 0, 0}), do: "[::1]"
  defp format_ip({_, _, _, _} = ip), do: to_string(:inet.ntoa(ip))
  defp format_ip({_, _, _, _, _, _, _, _} = ip), do: "[#{:inet.ntoa(ip)}]"

  @impl true
  def init(opts) do
    token = validate_token!(Keyword.get(opts, :token))
    token_digest = :crypto.hash(:sha256, token)

    env =
      case Keyword.get(opts, :env) do
        {mod, _state} = provided when is_atom(mod) ->
          provided

        nil ->
          cwd = Keyword.get(opts, :cwd) || File.cwd!()
          env_id = Keyword.get(opts, :id) || "remote"
          Host.new(cwd, env_id: env_id)

        other ->
          raise ArgumentError, "expected :env to be H.ExecutionEnv.t(), got: #{inspect(other)}"
      end

    agent_id = Keyword.get(opts, :id) || H.ExecutionEnv.env_id(env)
    socket_path = Keyword.get(opts, :socket_path)
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, if(is_binary(socket_path) and is_nil(ip), do: nil, else: 0))
    startup_log = Keyword.get(opts, :startup_log, false)

    if is_nil(port) and not (is_binary(socket_path) and socket_path != "") do
      raise ArgumentError, "expected at least one of :port (TCP) or :socket_path (Unix socket)"
    end

    {registry_children, via_agent} =
      case Keyword.get(opts, :agent_name) do
        nil ->
          registry_name = :"H.RemoteAgent.HTTP.Registry.#{System.unique_integer([:positive])}"

          {[{Registry, keys: :unique, name: registry_name}],
           {:via, Registry, {registry_name, :agent}}}

        name ->
          {[], name}
      end

    agent_opts = [env: env, id: agent_id, name: via_agent]

    router_opts = [
      agent: via_agent,
      token_digest: token_digest
    ]

    tcp_children =
      if not is_nil(ip) and is_integer(port) do
        [
          Supervisor.child_spec(
            {Bandit,
             plug: {H.RemoteAgent.HTTP.Router, router_opts},
             ip: ip,
             port: port,
             startup_log: startup_log,
             thousand_island_options: [shutdown_timeout: 500]},
            id: :http_listener
          )
        ]
      else
        []
      end

    unix_children =
      if is_binary(socket_path) and socket_path != "" do
        [
          %{
            id: :unix_listener,
            start:
              {H.RemoteAgent.HTTP, :start_unix_listener, [socket_path, router_opts, startup_log]},
            type: :supervisor
          }
        ]
      else
        []
      end

    children =
      registry_children ++
        [
          Supervisor.child_spec({RemoteAgent, agent_opts}, id: H.RemoteAgent)
        ] ++ tcp_children ++ unix_children

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 0)
  end

  @doc false
  def start_unix_listener(socket_path, router_opts, startup_log) do
    File.mkdir_p!(Path.dirname(socket_path))

    with :ok <- remove_stale_unix_socket(socket_path),
         {:ok, pid} <-
           Bandit.start_link(
             plug: {H.RemoteAgent.HTTP.Router, router_opts},
             ip: {:local, socket_path},
             port: 0,
             startup_log: startup_log,
             thousand_island_options: [shutdown_timeout: 500]
           ) do
      case File.chmod(socket_path, 0o600) do
        :ok ->
          {:ok, pid}

        {:error, reason} ->
          Supervisor.stop(pid)
          {:error, reason}
      end
    end
  end

  defp remove_stale_unix_socket(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{mode: mode}} when Bitwise.band(mode, 0o170000) == 0o140000 ->
        case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 100) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
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

  # Each HTTP supervisor owns its own local Registry.

  defp validate_token!(token) when is_binary(token) do
    trimmed = String.trim(token)

    if trimmed == "" do
      raise ArgumentError, "expected non-empty :token"
    else
      trimmed
    end
  end

  defp validate_token!(other) do
    raise ArgumentError, "expected non-empty :token string, got: #{inspect(other)}"
  end

  defmodule AuthPlug do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @json_parser Plug.Parsers.init(
                   parsers: [:json],
                   pass: ["application/json"],
                   json_decoder: JSON,
                   length: 8_000_000
                 )

    @impl true
    def init(opts) when is_list(opts), do: opts

    @impl true
    def call(conn, opts) do
      expected_digest = Keyword.fetch!(opts, :token_digest)

      conn =
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("x-content-type-options", "nosniff")

      if bearer_matches?(conn, expected_digest) do
        parse_body_if_mutating(conn)
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode_to_iodata!(%{"error" => "unauthorized"}))
        |> halt()
      end
    end

    defp bearer_matches?(conn, expected_digest) do
      case get_req_header(conn, "authorization") do
        [header] ->
          case String.split(header, " ", parts: 2) do
            [scheme, provided] when byte_size(provided) > 0 ->
              if String.downcase(scheme) == "bearer" do
                provided_digest = :crypto.hash(:sha256, provided)
                Plug.Crypto.secure_compare(provided_digest, expected_digest)
              else
                false
              end

            _ ->
              false
          end

        _ ->
          false
      end
    end

    defp parse_body_if_mutating(%Plug.Conn{method: method} = conn)
         when method in ["POST", "PUT", "PATCH", "DELETE"] do
      case get_req_header(conn, "content-type") do
        [ct | _] ->
          case Plug.Conn.Utils.content_type(ct) do
            {:ok, "application", "json", _} ->
              parse_json_body(conn)

            _ ->
              send_error_halt(conn, 415, "expected application/json")
          end

        [] ->
          case read_body(conn, length: 1) do
            {:ok, "", conn} -> %{conn | body_params: %{}}
            _ -> send_error_halt(conn, 415, "expected application/json")
          end
      end
    end

    defp parse_body_if_mutating(conn), do: conn

    defp parse_json_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
      Plug.Parsers.call(conn, @json_parser)
    rescue
      Plug.Parsers.RequestTooLargeError ->
        send_error_halt(conn, 413, "request too large")

      Plug.Parsers.ParseError ->
        send_error_halt(conn, 400, "invalid json")

      Plug.Parsers.BadEncodingError ->
        send_error_halt(conn, 400, "invalid utf-8 encoding")

      Plug.Parsers.UnsupportedMediaTypeError ->
        send_error_halt(conn, 415, "expected application/json")

      Plug.BadRequestError ->
        send_error_halt(conn, 400, "bad request")

      Plug.TimeoutError ->
        send_error_halt(conn, 408, "request timeout")
    end

    defp parse_json_body(conn), do: conn

    defp send_error_halt(conn, status, msg) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, JSON.encode_to_iodata!(%{"error" => msg}))
      |> halt()
    end
  end

  defmodule Router do
    @moduledoc false
    use Plug.Router, copy_opts_to_assign: :remote_opts

    alias H.RemoteAgent

    plug(:auth_plug)
    plug(Plug.Head)
    plug(:match)
    plug(:dispatch)

    get "/v1/descriptor" do
      agent = agent(conn)
      send_json(conn, 200, RemoteAgent.descriptor(agent))
    end

    post "/v1/fs/bind_cwd" do
      agent = agent(conn)
      params = body(conn)

      with {:ok, path} <- require_string(params, "path"),
           {:ok, opts} <- optional_cwd_opts(params),
           {:ok, resolved} <- RemoteAgent.bind_cwd(agent, path, opts) do
        send_json(conn, 200, %{"cwd" => resolved})
      else
        {:error, reason} -> send_agent_error(conn, reason)
      end
    end

    post "/v1/fs/resolve_path" do
      agent = agent(conn)
      params = body(conn)

      with {:ok, path} <- require_string(params, "path"),
           {:ok, opts} <- optional_cwd_opts(params),
           {:ok, resolved} <- RemoteAgent.resolve_path(agent, path, opts) do
        send_json(conn, 200, %{"path" => resolved})
      else
        {:error, reason} -> send_agent_error(conn, reason)
      end
    end

    post "/v1/fs/canonical_path" do
      agent = agent(conn)
      params = body(conn)

      with {:ok, path} <- require_string(params, "path"),
           {:ok, opts} <- optional_cwd_opts(params),
           {:ok, resolved} <- RemoteAgent.canonical_path(agent, path, opts) do
        send_json(conn, 200, %{"path" => resolved})
      else
        {:error, reason} -> send_agent_error(conn, reason)
      end
    end

    post "/v1/fs/read_lines" do
      agent = agent(conn)
      params = body(conn)

      with {:ok, path} <- require_string(params, "path"),
           {:ok, opts} <-
             build_opts(params, [
               {"cwd", :cwd, :string},
               {"offset", :offset, :integer},
               {"limit", :limit, :integer},
               {"max_bytes", :max_bytes, :integer},
               {"no_follow", :no_follow, :boolean}
             ]),
           {:ok, result} <- RemoteAgent.read_file_lines(agent, path, opts) do
        send_json(conn, 200, result)
      else
        {:error, reason} -> send_agent_error(conn, reason)
      end
    end

    post "/v1/fs/read_bytes" do
      agent = agent(conn)
      params = body(conn)

      with {:ok, path} <- require_string(params, "path"),
           {:ok, opts} <-
             build_opts(params, [
               {"cwd", :cwd, :string},
               {"max_bytes", :max_bytes, :integer},
               {"no_follow", :no_follow, :boolean}
             ]),
           {:ok, bytes} <- RemoteAgent.read_file_bytes(agent, path, opts) do
        send_json(conn, 200, %{"content_b64" => Base.encode64(bytes)})
      else
        {:error, reason} -> send_agent_error(conn, reason)
      end
    end

    post "/v1/fs/write_file" do
      agent = agent(conn)
      params = body(conn)

      with {:ok, path} <- require_string(params, "path"),
           {:ok, content} <- decode_write_content(params),
           {:ok, opts} <- optional_cwd_opts(params),
           :ok <- RemoteAgent.write_file(agent, path, content, opts) do
        send_json(conn, 200, %{"ok" => true})
      else
        {:error, reason} -> send_agent_error(conn, reason)
      end
    end

    post "/v1/fs/list_dir" do
      agent = agent(conn)
      params = body(conn)

      with {:ok, path} <- require_string(params, "path"),
           {:ok, opts} <-
             build_opts(params, [
               {"cwd", :cwd, :string},
               {"limit", :limit, :integer},
               {"cursor", :cursor, :integer},
               {"include_hidden", :include_hidden, :boolean},
               {"only_dirs", :only_dirs, :boolean},
               {"markers", :markers, :string_list}
             ]),
           {:ok, result} <- RemoteAgent.list_dir(agent, path, opts) do
        send_json(conn, 200, result)
      else
        {:error, reason} -> send_agent_error(conn, reason)
      end
    end

    post "/v1/fs/list_files" do
      agent = agent(conn)
      params = body(conn)

      with {:ok, path} <- require_string(params, "path"),
           {:ok, opts} <-
             build_opts(params, [
               {"cwd", :cwd, :string},
               {"limit", :limit, :integer},
               {"max_bytes", :max_bytes, :integer},
               {"max_depth", :max_depth, :integer},
               {"max_scanned", :max_scanned, :integer},
               {"timeout_ms", :timeout_ms, :integer},
               {"include_hidden", :include_hidden, :boolean},
               {"include_dirs", :include_dirs, :boolean},
               {"exclude", :exclude, :string_list},
               {"query", :query, :string},
               {"no_follow", :no_follow, :boolean}
             ]),
           {:ok, result} <- RemoteAgent.list_files(agent, path, opts) do
        send_json(conn, 200, result)
      else
        {:error, reason} -> send_agent_error(conn, reason)
      end
    end

    get "/v1/exec/fences" do
      fences =
        conn
        |> agent()
        |> RemoteAgent.active_fences()
        |> Enum.map(&encode_fence/1)

      send_json(conn, 200, %{"fences" => fences})
    end

    post "/v1/exec/renew" do
      agent = agent(conn)
      params = body(conn)

      with {:ok, fence} <- decode_fence(params["fence"]),
           {:ok, lease_ms} <- require_int(params, "lease_ms"),
           :ok <- RemoteAgent.renew_lease(agent, fence, lease_ms) do
        send_json(conn, 200, %{"ok" => true})
      else
        {:error, reason} -> send_agent_error(conn, reason)
      end
    end

    post "/v1/exec/abort" do
      agent = agent(conn)
      params = body(conn)

      with {:ok, fence} <- decode_fence(params["fence"]),
           :ok <- RemoteAgent.abort(agent, fence) do
        send_json(conn, 200, %{"ok" => true})
      else
        {:error, reason} -> send_agent_error(conn, reason)
      end
    end

    post "/v1/exec/stream" do
      agent = agent(conn)
      params = body(conn)

      with {:ok, command} <- decode_command(params["command"]),
           {:ok, exec_opts} <- decode_exec_opts(params) do
        stream_exec(conn, agent, command, exec_opts)
      else
        {:error, reason} -> send_agent_error(conn, reason)
      end
    end

    match _ do
      send_json(conn, 404, %{"error" => "not_found"})
    end

    # --- Streaming execution ---

    defp stream_exec(conn, agent, command, exec_opts) do
      case GenServer.call(agent, {:start_exec, self(), command, exec_opts}) do
        {:ok, agent_pid, op_ref, fence} ->
          agent_mon = Process.monitor(agent_pid)
          {sock_monitor, ti_socket} = arm_socket_disconnect(conn)

          conn =
            conn
            |> put_resp_content_type("application/x-ndjson")
            |> put_resp_header("x-accel-buffering", "no")
            |> send_chunked(200)

          try do
            stream_loop(conn, agent, agent_pid, agent_mon, op_ref, fence, sock_monitor, ti_socket)
          after
            if ti_socket, do: _ = ThousandIsland.Socket.setopts(ti_socket, active: false)
            Process.demonitor(agent_mon, [:flush])
          end

        {:error, reason} ->
          send_agent_error(conn, reason)
      end
    end

    defp stream_loop(conn, agent, agent_pid, agent_mon, op_ref, fence, sock_monitor, ti_socket) do
      receive do
        {:remote_exec_output, ^op_ref, chunk} ->
          frame = encode_ndjson(%{"type" => "output", "data_b64" => Base.encode64(chunk)})

          case chunk(conn, frame) do
            {:ok, next_conn} ->
              stream_loop(
                next_conn,
                agent,
                agent_pid,
                agent_mon,
                op_ref,
                fence,
                sock_monitor,
                ti_socket
              )

            {:error, _reason} ->
              _ = safe_abort(agent, fence)
              conn
          end

        {:remote_exec_result, ^op_ref, result} ->
          conn = drain_stream_output(conn, op_ref)
          frame = encode_terminal_frame(result)

          case chunk(conn, frame) do
            {:ok, next_conn} -> next_conn
            {:error, _reason} -> conn
          end

        {:tcp, raw_sock, _data} when raw_sock == sock_monitor ->
          # Re-arm active: :once if pipelined/unexpected bytes arrive, though HTTP/1.1 keeps socket quiet.
          if ti_socket, do: _ = ThousandIsland.Socket.setopts(ti_socket, active: :once)
          stream_loop(conn, agent, agent_pid, agent_mon, op_ref, fence, sock_monitor, ti_socket)

        {:ssl, raw_sock, _data} when raw_sock == sock_monitor ->
          if ti_socket, do: _ = ThousandIsland.Socket.setopts(ti_socket, active: :once)
          stream_loop(conn, agent, agent_pid, agent_mon, op_ref, fence, sock_monitor, ti_socket)

        {:tcp_closed, raw_sock} when raw_sock == sock_monitor ->
          _ = safe_abort(agent, fence)
          conn

        {:ssl_closed, raw_sock} when raw_sock == sock_monitor ->
          _ = safe_abort(agent, fence)
          conn

        {:tcp_error, raw_sock, _reason} when raw_sock == sock_monitor ->
          _ = safe_abort(agent, fence)
          conn

        {:ssl_error, raw_sock, _reason} when raw_sock == sock_monitor ->
          _ = safe_abort(agent, fence)
          conn

        {:DOWN, ^agent_mon, :process, ^agent_pid, reason} ->
          conn = drain_stream_output(conn, op_ref)
          frame = encode_terminal_frame({:error, {:agent_down, reason}})

          case chunk(conn, frame) do
            {:ok, next_conn} -> next_conn
            {:error, _reason} -> conn
          end

        {:EXIT, from, reason}
        when reason == :shutdown or (is_tuple(reason) and elem(reason, 0) == :shutdown) ->
          _ = safe_abort(agent, fence)
          send(self(), {:EXIT, from, reason})
          conn
      end
    end

    defp drain_stream_output(conn, op_ref) do
      receive do
        {:remote_exec_output, ^op_ref, chunk} ->
          frame = encode_ndjson(%{"type" => "output", "data_b64" => Base.encode64(chunk)})

          case chunk(conn, frame) do
            {:ok, next_conn} -> drain_stream_output(next_conn, op_ref)
            {:error, _reason} -> conn
          end
      after
        0 -> conn
      end
    end

    defp arm_socket_disconnect(%Plug.Conn{adapter: {_mod, %{transport: %{socket: ti_sock}}}}) do
      raw = Map.get(ti_sock, :socket)
      _ = ThousandIsland.Socket.setopts(ti_sock, active: :once)
      {raw, ti_sock}
    rescue
      _ -> {nil, nil}
    catch
      _, _ -> {nil, nil}
    end

    defp arm_socket_disconnect(_conn), do: {nil, nil}

    defp safe_abort(agent, fence) do
      RemoteAgent.abort(agent, fence)
    catch
      :exit, _ -> :ok
    end

    defp encode_terminal_frame({:ok, res}) do
      encode_ndjson(%{
        "type" => "result",
        "result" => %{
          "exit_code" => res.exit_code,
          "output_b64" => Base.encode64(res.output),
          "truncated" => res.truncated,
          "skipped_bytes" => res.skipped_bytes,
          "full_output_path" => res.full_output_path
        }
      })
    end

    defp encode_terminal_frame({:error, %{reason: reason} = err}) do
      encode_ndjson(%{
        "type" => "error",
        "error" => %{
          "reason" => encode_reason(reason),
          "output_b64" => Base.encode64(Map.get(err, :output, "")),
          "truncated" => Map.get(err, :truncated, false),
          "skipped_bytes" => Map.get(err, :skipped_bytes, 0),
          "full_output_path" => Map.get(err, :full_output_path)
        }
      })
    end

    defp encode_terminal_frame({:error, reason}) do
      encode_ndjson(%{
        "type" => "error",
        "error" => %{"reason" => encode_reason(reason)}
      })
    end

    defp encode_ndjson(map) do
      [JSON.encode_to_iodata!(map), "\n"]
    end

    # --- Parameter validation & error mapping ---

    defp auth_plug(conn, _opts) do
      H.RemoteAgent.HTTP.AuthPlug.call(conn, remote_opts(conn))
    end

    defp remote_opts(conn), do: conn.assigns[:remote_opts] || []
    defp agent(conn), do: Keyword.fetch!(remote_opts(conn), :agent)
    defp body(conn), do: if(is_map(conn.body_params), do: conn.body_params, else: %{})

    defp require_string(params, key) do
      case Map.get(params, key) do
        val when is_binary(val) -> {:ok, val}
        _ -> {:error, {:bad_request, "#{key} must be a string"}}
      end
    end

    defp require_int(params, key) do
      case Map.get(params, key) do
        val when is_integer(val) -> {:ok, val}
        _ -> {:error, {:bad_request, "#{key} must be an integer"}}
      end
    end

    defp optional_cwd_opts(params) do
      build_opts(params, [{"cwd", :cwd, :string}])
    end

    defp decode_write_content(params) do
      case Map.fetch(params, "content_b64") do
        {:ok, b64} when is_binary(b64) ->
          case Base.decode64(b64) do
            {:ok, bytes} -> {:ok, bytes}
            :error -> {:error, {:bad_request, "invalid content_b64"}}
          end

        _ ->
          case Map.fetch(params, "content") do
            {:ok, text} when is_binary(text) -> {:ok, text}
            _ -> {:error, {:bad_request, "content_b64 or content string required"}}
          end
      end
    end

    defp build_opts(params, specs) do
      Enum.reduce_while(specs, {:ok, []}, fn {json_key, opt_key, type}, {:ok, acc} ->
        case Map.fetch(params, json_key) do
          :error ->
            {:cont, {:ok, acc}}

          {:ok, nil} ->
            {:cont, {:ok, acc}}

          {:ok, val} ->
            case validate_opt_value(type, val) do
              {:ok, checked} -> {:cont, {:ok, [{opt_key, checked} | acc]}}
              :error -> {:halt, {:error, {:bad_request, "invalid #{json_key}"}}}
            end
        end
      end)
      |> case do
        {:ok, list} -> {:ok, Enum.reverse(list)}
        err -> err
      end
    end

    defp validate_opt_value(:string, val) when is_binary(val), do: {:ok, val}
    defp validate_opt_value(:integer, val) when is_integer(val), do: {:ok, val}
    defp validate_opt_value(:boolean, val) when is_boolean(val), do: {:ok, val}

    defp validate_opt_value(:string_list, val) when is_list(val) do
      if Enum.all?(val, &is_binary/1), do: {:ok, val}, else: :error
    end

    defp validate_opt_value(_type, _val), do: :error

    defp decode_command(%{"type" => "shell", "command" => cmd}) when is_binary(cmd),
      do: {:ok, {:shell, cmd}}

    defp decode_command(%{"type" => "argv", "argv" => [exe | _] = argv})
         when is_binary(exe) and is_list(argv) do
      if Enum.all?(argv, &is_binary/1),
        do: {:ok, {:argv, argv}},
        else: {:error, :invalid_command}
    end

    defp decode_command(_), do: {:error, :invalid_command}

    defp decode_exec_opts(params) do
      with {:ok, fence_opts} <- decode_optional_fence_opts(params["fence"]),
           {:ok, base_opts} <-
             build_opts(params, [
               {"cwd", :cwd, :string},
               {"lease_ms", :lease_ms, :integer},
               {"timeout_ms", :timeout_ms, :integer},
               {"window_bytes", :window_bytes, :integer},
               {"window_lines", :window_lines, :integer},
               {"raw_output", :raw_output, :boolean},
               {"spill_output", :spill_output, :boolean}
             ]),
           {:ok, env_opts} <- decode_env_opt(params["env"]) do
        {:ok, fence_opts ++ base_opts ++ env_opts}
      end
    end

    defp decode_optional_fence_opts(nil), do: {:ok, []}

    defp decode_optional_fence_opts(fence_map) do
      with {:ok, {sid, inc, tid, aid}} <- decode_fence(fence_map) do
        {:ok, [session_id: sid, incarnation: inc, task_id: tid, attempt_id: aid]}
      end
    end

    defp decode_fence(%{
           "session_id" => sid,
           "incarnation" => inc,
           "task_id" => tid,
           "attempt_id" => aid
         })
         when not is_nil(sid) and not is_nil(inc) and not is_nil(tid) and not is_nil(aid) do
      {:ok, {sid, inc, tid, aid}}
    end

    defp decode_fence(_), do: {:error, {:bad_request, "invalid fence"}}

    defp decode_env_opt(nil), do: {:ok, []}

    defp decode_env_opt(env) when is_map(env) do
      valid? =
        Enum.all?(env, fn
          {k, v} when is_binary(k) and (is_binary(v) or is_nil(v) or is_boolean(v)) -> true
          _ -> false
        end)

      if valid?, do: {:ok, [env: env]}, else: {:error, {:bad_request, "invalid env"}}
    end

    defp decode_env_opt(_), do: {:error, {:bad_request, "invalid env"}}

    defp encode_fence({sid, inc, tid, aid}) do
      %{
        "session_id" => sid,
        "incarnation" => inc,
        "task_id" => tid,
        "attempt_id" => aid
      }
    end

    defp send_agent_error(conn, :stale_fence),
      do: send_json(conn, 409, %{"error" => "stale_fence"})

    defp send_agent_error(conn, :not_found),
      do: send_json(conn, 404, %{"error" => "not_found"})

    defp send_agent_error(conn, :enoent),
      do: send_json(conn, 404, %{"error" => "enoent"})

    defp send_agent_error(conn, {:enoent, detail}),
      do: send_json(conn, 404, %{"error" => "enoent", "detail" => to_string(detail)})

    defp send_agent_error(conn, {:bad_request, msg}),
      do: send_json(conn, 422, %{"error" => "bad_request", "detail" => msg})

    defp send_agent_error(conn, reason)
         when reason in [:invalid_lease_ms, :invalid_command, :einval, :enotdir, :eisdir, :eloop] do
      send_json(conn, 422, %{"error" => Atom.to_string(reason)})
    end

    defp send_agent_error(conn, reason) when is_atom(reason) do
      send_json(conn, 422, %{"error" => Atom.to_string(reason)})
    end

    defp send_agent_error(conn, {:agent_down, _reason}) do
      send_json(conn, 503, %{"error" => "agent_down"})
    end

    defp send_agent_error(conn, reason) do
      send_json(conn, 422, %{"error" => encode_reason(reason)})
    end

    defp encode_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
    defp encode_reason({:agent_down, _}), do: "agent_down"
    defp encode_reason(other), do: inspect(other)

    defp send_json(conn, status, payload) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, JSON.encode_to_iodata!(payload))
    end
  end
end
