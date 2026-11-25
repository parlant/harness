defmodule H.RemoteAgent.Client do
  @moduledoc """
  HTTP / Unix domain socket client handle for `H.RemoteAgent.HTTP`.

  Implements the client side of the `H.RemoteAgent` seam (`descriptor/1`, `cwd/1`,
  filesystem operations, fenced streaming `exec/3` with active lease heartbeats,
  `renew_lease/3`, `abort/2`, and `active_fences/1`).

  Bearer tokens are wrapped in `%H.Credentials.Redacted{}` so credentials are
  never exposed through `Inspect`.
  """

  alias H.Credentials.Redacted
  alias H.ExecutionEnv

  @default_request_timeout_ms 30_000
  @default_lease_ms 30_000
  @default_heartbeat_ms 5_000
  @default_abort_timeout_ms 10_000

  @enforce_keys [:token]
  defstruct [
    :base_url,
    :unix_socket,
    :token,
    :host,
    :headers,
    request_timeout_ms: @default_request_timeout_ms,
    lease_ms: @default_lease_ms,
    heartbeat_ms: @default_heartbeat_ms
  ]

  @type t :: %__MODULE__{
          base_url: nil | String.t(),
          unix_socket: nil | String.t(),
          token: Redacted.t(),
          host: nil | String.t(),
          headers: nil | [{String.t(), String.t()}],
          request_timeout_ms: pos_integer(),
          lease_ms: pos_integer(),
          heartbeat_ms: pos_integer()
        }

  @doc """
  Constructs a `%H.RemoteAgent.Client{}` from `url_or_opts` and optional `opts`.

  Accepts:
    * `"http://127.0.0.1:PORT"` (with `:token` in `opts`)
    * `[unix_socket: "/path/to/agent.sock", token: "..."]`
    * `[base_url: "http://...", token: "..."]` or `[url: "http://...", token: "..."]`

  ## Options
    * `:token` (required) - bearer token string (or `%H.Credentials.Redacted{}`)
    * `:unix_socket` - Unix domain socket path
    * `:base_url` / `:url` - HTTP base URL (e.g. `"http://127.0.0.1:4105"`)
    * `:host` - optional explicit `Host` header (useful over Unix sockets)
    * `:headers` - optional extra HTTP headers
    * `:request_timeout_ms` - HTTP request timeout for RPC calls (default `30_000`)
    * `:lease_ms` - default lease TTL in ms sent on `exec/3` (default `30_000`)
    * `:heartbeat_ms` - lease renewal interval in ms during `exec/3` (default `5_000`)
  """
  @spec new(String.t() | keyword(), keyword()) :: t()
  def new(url_or_opts, opts \\ [])

  def new(url, opts) when is_binary(url) and is_list(opts) do
    opts |> Keyword.put(:base_url, url) |> new()
  end

  def new(opts, extra_opts) when is_list(opts) and is_list(extra_opts) do
    merged = Keyword.merge(opts, extra_opts)

    token =
      case Keyword.get(merged, :token) do
        %Redacted{} = redacted ->
          redacted

        raw when is_binary(raw) and byte_size(raw) > 0 ->
          trimmed = String.trim(raw)

          if trimmed == "" do
            raise ArgumentError, "expected non-empty :token"
          else
            %Redacted{value: trimmed}
          end

        other ->
          raise ArgumentError, "expected non-empty :token, got: #{inspect(other)}"
      end

    unix_socket = Keyword.get(merged, :unix_socket)
    raw_url = Keyword.get(merged, :base_url) || Keyword.get(merged, :url)

    {base_url, unix_socket} =
      cond do
        is_binary(unix_socket) and unix_socket != "" ->
          {normalize_base_url(raw_url || "http://localhost"), unix_socket}

        is_binary(raw_url) and raw_url != "" ->
          {normalize_base_url(raw_url), nil}

        true ->
          raise ArgumentError, "expected either :base_url/:url or :unix_socket"
      end

    request_timeout_ms =
      validate_pos_int!(
        Keyword.get(merged, :request_timeout_ms, @default_request_timeout_ms),
        :request_timeout_ms
      )

    lease_ms =
      validate_pos_int!(Keyword.get(merged, :lease_ms, @default_lease_ms), :lease_ms)

    heartbeat_ms =
      validate_pos_int!(
        Keyword.get(merged, :heartbeat_ms, @default_heartbeat_ms),
        :heartbeat_ms
      )

    headers =
      merged
      |> Keyword.get(:headers, [])
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

    host = Keyword.get(merged, :host)

    %__MODULE__{
      base_url: base_url,
      unix_socket: unix_socket,
      token: token,
      host: host,
      headers: headers,
      request_timeout_ms: request_timeout_ms,
      lease_ms: lease_ms,
      heartbeat_ms: heartbeat_ms
    }
  end

  @doc "Fetches the remote agent descriptor (`%{id, kind, cwd}`)."
  @spec descriptor(t()) :: %{id: String.t(), kind: String.t(), cwd: String.t()}
  def descriptor(%__MODULE__{} = client) do
    case fetch_descriptor(client) do
      {:ok, desc} -> desc
      {:error, reason} -> exit(reason)
    end
  end

  @doc false
  @spec fetch_descriptor(t()) ::
          {:ok, %{id: String.t(), kind: String.t(), cwd: String.t()}} | {:error, term()}
  def fetch_descriptor(%__MODULE__{} = client) do
    case get_json(client, "/v1/descriptor") do
      {:ok, %{"id" => id, "kind" => kind, "cwd" => cwd}} ->
        {:ok, %{id: id, kind: kind, cwd: cwd}}

      {:ok, other} ->
        {:error, {:invalid_descriptor, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Fetches the remote agent base working directory."
  @spec cwd(t()) :: String.t()
  def cwd(%__MODULE__{} = client), do: descriptor(client).cwd

  @doc "Remotely resolves `path` and verifies that it exists as a directory."
  @spec bind_cwd(t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def bind_cwd(%__MODULE__{} = client, path, opts \\ []) when is_binary(path) and is_list(opts) do
    payload = put_optional_cwd(%{"path" => path}, opts)

    case post_json(client, "/v1/fs/bind_cwd", payload) do
      {:ok, %{"cwd" => resolved}} -> {:ok, resolved}
      {:error, _} = err -> err
    end
  end

  @doc "Remotely resolves `path` using target POSIX path semantics."
  @spec resolve_path(t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_path(%__MODULE__{} = client, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    payload = put_optional_cwd(%{"path" => path}, opts)

    case post_json(client, "/v1/fs/resolve_path", payload) do
      {:ok, %{"path" => resolved}} -> {:ok, resolved}
      {:error, _} = err -> err
    end
  end

  @doc "Remotely canonicalizes `path` by resolving symlinks on the target agent."
  @spec canonical_path(t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def canonical_path(%__MODULE__{} = client, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    payload = put_optional_cwd(%{"path" => path}, opts)

    case post_json(client, "/v1/fs/canonical_path", payload) do
      {:ok, %{"path" => resolved}} -> {:ok, resolved}
      {:error, _} = err -> err
    end
  end

  @doc "Reads bounded UTF-8 lines from a remote file."
  @spec read_file_lines(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_file_lines(%__MODULE__{} = client, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    payload =
      %{"path" => path}
      |> put_optional_cwd(opts)
      |> maybe_put_opt("offset", Keyword.get(opts, :offset))
      |> maybe_put_opt("limit", Keyword.get(opts, :limit))
      |> maybe_put_opt("max_bytes", Keyword.get(opts, :max_bytes))
      |> maybe_put_opt("no_follow", Keyword.get(opts, :no_follow))

    case post_json(client, "/v1/fs/read_lines", payload) do
      {:ok, data} ->
        {:ok,
         %{
           lines: Map.get(data, "lines", []),
           start_line: Map.get(data, "start_line"),
           total_lines_read: Map.get(data, "total_lines_read"),
           has_more: Map.get(data, "has_more", false),
           truncated_by_bytes: Map.get(data, "truncated_by_bytes", false)
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc "Reads bounded raw bytes from a remote file."
  @spec read_file_bytes(t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file_bytes(%__MODULE__{} = client, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    payload =
      %{"path" => path}
      |> put_optional_cwd(opts)
      |> maybe_put_opt("max_bytes", Keyword.get(opts, :max_bytes))
      |> maybe_put_opt("no_follow", Keyword.get(opts, :no_follow))

    case post_json(client, "/v1/fs/read_bytes", payload) do
      {:ok, %{"content_b64" => b64}} when is_binary(b64) ->
        case Base.decode64(b64) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, :invalid_base64}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Atomically writes `content` to a remote file, creating missing parent directories."
  @spec write_file(t(), String.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write_file(%__MODULE__{} = client, path, content, opts \\ [])
      when is_binary(path) and is_list(opts) do
    bin = IO.iodata_to_binary(content)

    payload =
      %{"path" => path, "content_b64" => Base.encode64(bin)}
      |> put_optional_cwd(opts)

    case post_json(client, "/v1/fs/write_file", payload) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Lists a remote directory with sorting, pagination, hidden/dir filters, and markers."
  @spec list_dir(t(), String.t(), keyword()) ::
          {:ok, %{entries: [map()], next_cursor: nil | non_neg_integer()}} | {:error, term()}
  def list_dir(%__MODULE__{} = client, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    payload =
      %{"path" => path}
      |> put_optional_cwd(opts)
      |> maybe_put_opt("limit", Keyword.get(opts, :limit))
      |> maybe_put_opt("cursor", Keyword.get(opts, :cursor))
      |> maybe_put_opt("include_hidden", Keyword.get(opts, :include_hidden))
      |> maybe_put_opt("only_dirs", Keyword.get(opts, :only_dirs))
      |> maybe_put_opt("markers", Keyword.get(opts, :markers))

    case post_json(client, "/v1/fs/list_dir", payload) do
      {:ok, %{"entries" => entries} = data} when is_list(entries) ->
        {:ok,
         %{
           entries: Enum.map(entries, &decode_list_dir_entry/1),
           next_cursor: Map.get(data, "next_cursor")
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc "Recursively discovers bounded files and directories on the remote agent."
  @spec list_files(t(), String.t(), keyword()) ::
          {:ok, %{entries: [map()], truncated: boolean()}} | {:error, term()}
  def list_files(%__MODULE__{} = client, path, opts \\ [])
      when is_binary(path) and is_list(opts) do
    payload =
      %{"path" => path}
      |> put_optional_cwd(opts)
      |> maybe_put_opt("limit", Keyword.get(opts, :limit))
      |> maybe_put_opt("max_bytes", Keyword.get(opts, :max_bytes))
      |> maybe_put_opt("max_depth", Keyword.get(opts, :max_depth))
      |> maybe_put_opt("max_scanned", Keyword.get(opts, :max_scanned))
      |> maybe_put_opt("timeout_ms", Keyword.get(opts, :timeout_ms))
      |> maybe_put_opt("include_hidden", Keyword.get(opts, :include_hidden))
      |> maybe_put_opt("include_dirs", Keyword.get(opts, :include_dirs))
      |> maybe_put_opt("exclude", Keyword.get(opts, :exclude))
      |> maybe_put_opt("query", Keyword.get(opts, :query))
      |> maybe_put_opt("no_follow", Keyword.get(opts, :no_follow))

    case post_json(client, "/v1/fs/list_files", payload) do
      {:ok, %{"entries" => entries} = data} when is_list(entries) ->
        {:ok,
         %{
           entries: Enum.map(entries, &decode_list_files_entry/1),
           truncated: Map.get(data, "truncated", false) == true
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Executes `command` on the remote HTTP agent with fencing, lease heartbeats,
  live output streaming, and `abort_ref` support.
  """
  @spec exec(t(), ExecutionEnv.command(), keyword()) ::
          {:ok, ExecutionEnv.exec_result()} | {:error, term()}
  def exec(%__MODULE__{} = client, command, opts \\ []) when is_list(opts) do
    with {:ok, cmd_payload} <- encode_command(command),
         {:ok, fence} <- resolve_fence(opts),
         {:ok, lease_ms} <- validate_lease_ms(Keyword.get(opts, :lease_ms, client.lease_ms)) do
      heartbeat_ms =
        case Keyword.get(opts, :heartbeat_ms, client.heartbeat_ms) do
          ms when is_integer(ms) and ms > 0 -> ms
          _ -> client.heartbeat_ms
        end

      abort_ref = Keyword.get(opts, :abort_ref)
      on_output = Keyword.get(opts, :on_output)

      payload =
        %{
          "command" => cmd_payload,
          "fence" => encode_fence(fence),
          "lease_ms" => lease_ms
        }
        |> put_optional_cwd(opts)
        |> maybe_put_opt("timeout_ms", Keyword.get(opts, :timeout_ms))
        |> maybe_put_opt("window_bytes", Keyword.get(opts, :window_bytes))
        |> maybe_put_opt("window_lines", Keyword.get(opts, :window_lines))
        |> maybe_put_opt("raw_output", Keyword.get(opts, :raw_output))
        |> maybe_put_opt("spill_output", Keyword.get(opts, :spill_output))
        |> maybe_put_env(Keyword.get(opts, :env))

      start_streaming_exec(client, payload, fence, lease_ms, heartbeat_ms, abort_ref, on_output)
    end
  end

  @doc "Renews the lease TTL (in milliseconds) for an active fenced execution."
  @spec renew_lease(t(), tuple(), pos_integer()) ::
          :ok | {:error, :not_found | :invalid_lease_ms | {:agent_down, term()} | term()}
  def renew_lease(%__MODULE__{} = client, {_s, _i, _t, _a} = fence, lease_ms) do
    if is_integer(lease_ms) and lease_ms > 0 do
      payload = %{"fence" => encode_fence(fence), "lease_ms" => lease_ms}

      case post_json(client, "/v1/exec/renew", payload) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    else
      {:error, :invalid_lease_ms}
    end
  end

  @doc "Aborts an active fenced execution and waits for its process group to be reaped."
  @spec abort(t(), tuple()) :: :ok | {:error, :not_found | {:agent_down, term()} | term()}
  def abort(%__MODULE__{} = client, {_s, _i, _t, _a} = fence) do
    payload = %{"fence" => encode_fence(fence)}

    case post_json(client, "/v1/exec/abort", payload, @default_abort_timeout_ms) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Returns the list of currently active execution fences on the remote agent."
  @spec active_fences(t()) :: [tuple()]
  def active_fences(%__MODULE__{} = client) do
    case get_json(client, "/v1/exec/fences") do
      {:ok, %{"fences" => fences}} when is_list(fences) ->
        Enum.map(fences, &decode_fence/1)

      {:ok, other} ->
        exit({:invalid_fences_response, other})

      {:error, reason} ->
        exit(reason)
    end
  end

  # --- Streaming exec + heartbeat loop ---

  defp start_streaming_exec(client, payload, fence, lease_ms, heartbeat_ms, abort_ref, on_output) do
    case Req.post(
           req_opts(client, "/v1/exec/stream",
             json: payload,
             into: :self,
             receive_timeout: :infinity
           )
         ) do
      {:ok, %Req.Response{status: 200, body: %Req.Response.Async{} = async} = resp} ->
        heartbeat_pid = spawn_heartbeat_loop(client, fence, lease_ms, heartbeat_ms)

        try do
          stream_exec_loop(
            client,
            resp,
            async,
            fence,
            abort_ref,
            on_output,
            "",
            heartbeat_pid
          )
        after
          stop_heartbeat_loop(heartbeat_pid)
          Req.cancel_async_response(resp)
        end

      {:ok, %Req.Response{status: status, body: %Req.Response.Async{} = async} = resp} ->
        body = collect_async_body(resp, async, "")
        decode_http_error(status, body)

      {:ok, %Req.Response{status: status, body: body}} ->
        decode_http_error(status, body)

      {:error, reason} ->
        {:error, {:agent_down, reason}}
    end
  end

  defp stream_exec_loop(
         client,
         resp,
         %Req.Response.Async{ref: ref} = async,
         fence,
         abort_ref,
         on_output,
         buffer,
         heartbeat_pid
       ) do
    receive do
      {:abort_exec, ^abort_ref} when not is_nil(abort_ref) ->
        stop_heartbeat_loop(heartbeat_pid)

        # Send abort asynchronously so we keep draining the stream in the calling
        # process, avoiding mailbox deadlock if the server flushes trailing chunks
        # before sending the terminal frame and replying to POST /v1/exec/abort.
        Task.start(fn ->
          _ = abort(client, fence)
        end)

        stream_exec_loop(client, resp, async, fence, nil, on_output, buffer, nil)

      {^ref, _} = msg ->
        case Req.parse_message(resp, msg) do
          {:ok, parts} ->
            handle_stream_parts(
              parts,
              client,
              resp,
              async,
              fence,
              abort_ref,
              on_output,
              buffer,
              heartbeat_pid
            )

          {:error, reason} ->
            Req.cancel_async_response(resp)
            {:error, {:agent_down, reason}}
        end
    end
  end

  defp handle_stream_parts(
         [],
         client,
         resp,
         async,
         fence,
         abort_ref,
         on_output,
         buffer,
         heartbeat_pid
       ) do
    stream_exec_loop(client, resp, async, fence, abort_ref, on_output, buffer, heartbeat_pid)
  end

  defp handle_stream_parts(
         [{:data, chunk} | rest],
         client,
         resp,
         async,
         fence,
         abort_ref,
         on_output,
         buffer,
         heartbeat_pid
       ) do
    case consume_ndjson_lines(buffer <> chunk, on_output) do
      {:done, result} ->
        Req.cancel_async_response(resp)
        result

      {:cont, next_buffer} ->
        handle_stream_parts(
          rest,
          client,
          resp,
          async,
          fence,
          abort_ref,
          on_output,
          next_buffer,
          heartbeat_pid
        )
    end
  end

  defp handle_stream_parts(
         [:done | _rest],
         _client,
         _resp,
         _async,
         _fence,
         _abort_ref,
         on_output,
         buffer,
         _heartbeat_pid
       ) do
    case consume_ndjson_lines(buffer <> "\n", on_output) do
      {:done, result} -> result
      {:cont, _} -> {:error, {:agent_down, :stream_closed}}
    end
  end

  defp handle_stream_parts(
         [_other | rest],
         client,
         resp,
         async,
         fence,
         abort_ref,
         on_output,
         buffer,
         heartbeat_pid
       ) do
    handle_stream_parts(
      rest,
      client,
      resp,
      async,
      fence,
      abort_ref,
      on_output,
      buffer,
      heartbeat_pid
    )
  end

  defp consume_ndjson_lines(buffer, on_output) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        trimmed = String.trim(line)

        if trimmed == "" do
          consume_ndjson_lines(rest, on_output)
        else
          case JSON.decode(trimmed) do
            {:ok, %{"type" => "output", "data_b64" => b64}} when is_binary(b64) ->
              case Base.decode64(b64) do
                {:ok, bytes} ->
                  if is_function(on_output, 1) and bytes != "", do: on_output.(bytes)
                  consume_ndjson_lines(rest, on_output)

                :error ->
                  {:done, {:error, :invalid_base64}}
              end

            {:ok, %{"type" => "result", "result" => res_map}} when is_map(res_map) ->
              {:done, {:ok, decode_exec_result(res_map)}}

            {:ok, %{"type" => "error", "error" => err_payload}} ->
              {:done, {:error, decode_exec_error(err_payload)}}

            {:ok, _other} ->
              consume_ndjson_lines(rest, on_output)

            {:error, reason} ->
              {:done, {:error, {:invalid_stream_frame, reason}}}
          end
        end

      [_incomplete] ->
        {:cont, buffer}
    end
  end

  defp collect_async_body(resp, %Req.Response.Async{ref: ref} = async, acc) do
    receive do
      {^ref, _} = msg ->
        case Req.parse_message(resp, msg) do
          {:ok, parts} ->
            Enum.reduce_while(parts, acc, fn
              {:data, chunk}, buf -> {:cont, buf <> chunk}
              :done, buf -> {:halt, {:done, buf}}
              _, buf -> {:cont, buf}
            end)
            |> case do
              {:done, body} -> body
              next_acc -> collect_async_body(resp, async, next_acc)
            end

          {:error, _reason} ->
            acc
        end
    after
      2_000 ->
        Req.cancel_async_response(resp)
        acc
    end
  end

  defp spawn_heartbeat_loop(_client, _fence, nil, _heartbeat_ms), do: nil

  defp spawn_heartbeat_loop(client, fence, lease_ms, heartbeat_ms) do
    interval = max(10, min(heartbeat_ms, max(10, div(lease_ms, 2))))
    parent = self()

    spawn(fn ->
      parent_mon = Process.monitor(parent)
      heartbeat_tick(client, fence, lease_ms, interval, parent_mon)
    end)
  end

  defp heartbeat_tick(client, fence, lease_ms, interval, parent_mon) do
    receive do
      :stop ->
        Process.demonitor(parent_mon, [:flush])
        :ok

      {:DOWN, ^parent_mon, :process, _pid, _reason} ->
        :ok
    after
      interval ->
        _ = renew_lease(client, fence, lease_ms)
        heartbeat_tick(client, fence, lease_ms, interval, parent_mon)
    end
  end

  defp stop_heartbeat_loop(nil), do: :ok

  defp stop_heartbeat_loop(pid) when is_pid(pid) do
    send(pid, :stop)
    :ok
  end

  # --- HTTP helpers ---

  defp get_json(client, path) do
    case Req.get(req_opts(client, path, receive_timeout: client.request_timeout_ms)) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        decode_http_error(status, body)

      {:error, reason} ->
        {:error, {:agent_down, reason}}
    end
  end

  defp post_json(client, path, payload, timeout_ms \\ nil) do
    timeout = timeout_ms || client.request_timeout_ms

    case Req.post(req_opts(client, path, json: payload, receive_timeout: timeout)) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        decode_http_error(status, body)

      {:error, reason} ->
        {:error, {:agent_down, reason}}
    end
  end

  defp req_opts(%__MODULE__{} = client, path, extra) do
    %Redacted{value: raw_token} = client.token

    base_headers =
      [{"authorization", "Bearer #{raw_token}"}] ++
        if(is_binary(client.host) and client.host != "", do: [{"host", client.host}], else: []) ++
        (client.headers || [])

    opts =
      [
        url: client.base_url <> path,
        headers: base_headers,
        retry: false
      ] ++ extra

    if client.unix_socket do
      Keyword.put(opts, :unix_socket, client.unix_socket)
    else
      opts
    end
  end

  # --- Wire encoding / decoding ---

  defp resolve_fence(opts) do
    session_id = Keyword.get(opts, :session_id)
    incarnation = Keyword.get(opts, :incarnation)
    task_id = Keyword.get(opts, :task_id)
    attempt_id = Keyword.get(opts, :attempt_id)

    cond do
      not is_nil(session_id) and not is_nil(incarnation) and not is_nil(task_id) and
          not is_nil(attempt_id) ->
        {:ok, {session_id, incarnation, task_id, attempt_id}}

      is_nil(session_id) and is_nil(incarnation) and is_nil(task_id) and is_nil(attempt_id) ->
        {:ok,
         {"client-#{System.pid()}", 0, "auto",
          "auto-#{System.unique_integer([:positive, :monotonic])}-#{System.system_time(:microsecond)}"}}

      true ->
        {:ok,
         {session_id || "anon", incarnation || 0, task_id || 0,
          attempt_id ||
            "auto-#{System.unique_integer([:positive, :monotonic])}-#{System.system_time(:microsecond)}"}}
    end
  end

  defp encode_fence({session_id, incarnation, task_id, attempt_id}) do
    %{
      "session_id" => session_id,
      "incarnation" => incarnation,
      "task_id" => task_id,
      "attempt_id" => attempt_id
    }
  end

  defp decode_fence(%{
         "session_id" => session_id,
         "incarnation" => incarnation,
         "task_id" => task_id,
         "attempt_id" => attempt_id
       }) do
    {session_id, incarnation, task_id, attempt_id}
  end

  defp encode_command({:shell, cmd}) when is_binary(cmd),
    do: {:ok, %{"type" => "shell", "command" => cmd}}

  defp encode_command({:argv, [exe | _] = argv}) when is_binary(exe) and is_list(argv) do
    if Enum.all?(argv, &is_binary/1) do
      {:ok, %{"type" => "argv", "argv" => argv}}
    else
      {:error, :invalid_command}
    end
  end

  defp encode_command(_), do: {:error, :invalid_command}

  defp decode_list_dir_entry(entry) when is_map(entry) do
    base = %{
      name: entry["name"],
      path: entry["path"],
      type: entry["type"],
      size: entry["size"]
    }

    base =
      case Map.fetch(entry, "target_type") do
        {:ok, tt} when is_binary(tt) -> Map.put(base, :target_type, tt)
        _ -> base
      end

    case Map.fetch(entry, "markers") do
      {:ok, markers} when is_list(markers) -> Map.put(base, :markers, markers)
      _ -> base
    end
  end

  defp decode_list_files_entry(entry) when is_map(entry) do
    %{
      path: entry["path"],
      type: entry["type"],
      size: entry["size"]
    }
  end

  defp decode_exec_result(map) when is_map(map) do
    output =
      case map do
        %{"output_b64" => b64} when is_binary(b64) -> Base.decode64!(b64)
        %{"output" => out} when is_binary(out) -> out
        _ -> ""
      end

    %{
      exit_code: map["exit_code"],
      output: output,
      truncated: map["truncated"] == true,
      skipped_bytes: map["skipped_bytes"] || 0,
      full_output_path: map["full_output_path"]
    }
  end

  defp decode_exec_error(%{"reason" => reason} = err) when is_map(err) do
    if Map.has_key?(err, "output_b64") or Map.has_key?(err, "output") do
      output =
        case err do
          %{"output_b64" => b64} when is_binary(b64) -> Base.decode64!(b64)
          %{"output" => out} when is_binary(out) -> out
          _ -> ""
        end

      %{
        reason: decode_reason(reason),
        output: output,
        truncated: err["truncated"] == true,
        skipped_bytes: err["skipped_bytes"] || 0,
        full_output_path: err["full_output_path"]
      }
    else
      decode_reason(reason)
    end
  end

  defp decode_exec_error(other), do: decode_reason(other)

  defp decode_http_error(status, body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decode_http_error(status, decoded)
      {:error, _} -> {:error, {:http_error, status, body}}
    end
  end

  defp decode_http_error(401, %{"error" => "unauthorized"}) do
    {:error, :unauthorized}
  end

  defp decode_http_error(_status, %{"error" => reason} = body) when is_binary(reason) do
    case Map.get(body, "detail") do
      detail when is_binary(detail) and reason == "enoent" ->
        {:error, {:enoent, detail}}

      detail when is_binary(detail) ->
        {:error, {decode_reason(reason), detail}}

      _ ->
        {:error, decode_reason(reason)}
    end
  end

  defp decode_http_error(status, body), do: {:error, {:http_error, status, body}}

  @known_reasons %{
    "stale_fence" => :stale_fence,
    "invalid_lease_ms" => :invalid_lease_ms,
    "not_found" => :not_found,
    "aborted" => :aborted,
    "timeout" => :timeout,
    "lease_expired" => :lease_expired,
    "client_down" => :client_down,
    "invalid_command" => :invalid_command,
    "einval" => :einval,
    "enoent" => :enoent,
    "enotdir" => :enotdir,
    "eisdir" => :eisdir,
    "eacces" => :eacces,
    "eexist" => :eexist,
    "eloop" => :eloop,
    "symlink_not_followed" => :symlink_not_followed,
    "not_regular_file" => :not_regular_file,
    "binary_file" => :binary_file,
    "file_too_large" => :file_too_large,
    "invalid_offset" => :invalid_offset,
    "invalid_limit" => :invalid_limit,
    "invalid_max_bytes" => :invalid_max_bytes,
    "invalid_cursor" => :invalid_cursor,
    "invalid_include_hidden" => :invalid_include_hidden,
    "invalid_only_dirs" => :invalid_only_dirs,
    "invalid_markers" => :invalid_markers,
    "invalid_max_depth" => :invalid_max_depth,
    "invalid_max_scanned" => :invalid_max_scanned,
    "invalid_timeout_ms" => :invalid_timeout_ms,
    "invalid_include_dirs" => :invalid_include_dirs,
    "invalid_exclude" => :invalid_exclude,
    "invalid_query" => :invalid_query,
    "invalid_no_follow" => :invalid_no_follow,
    "unauthorized" => :unauthorized,
    "bad_request" => :bad_request
  }

  defp decode_reason(reason) when is_binary(reason) do
    Map.get(@known_reasons, reason, reason)
  end

  defp decode_reason(other), do: other

  defp put_optional_cwd(payload, opts) do
    case Keyword.get(opts, :cwd) do
      cwd when is_binary(cwd) -> Map.put(payload, "cwd", cwd)
      _ -> payload
    end
  end

  defp maybe_put_opt(payload, _key, nil), do: payload
  defp maybe_put_opt(payload, key, val), do: Map.put(payload, key, val)

  defp maybe_put_env(payload, nil), do: payload

  defp maybe_put_env(payload, env) when is_map(env) or is_list(env) do
    encoded =
      Map.new(env, fn
        {k, nil} -> {to_string(k), nil}
        {k, false} -> {to_string(k), false}
        {k, v} -> {to_string(k), to_string(v)}
      end)

    Map.put(payload, "env", encoded)
  end

  defp validate_lease_ms(nil), do: {:ok, nil}
  defp validate_lease_ms(ms) when is_integer(ms) and ms > 0, do: {:ok, ms}
  defp validate_lease_ms(_), do: {:error, :invalid_lease_ms}

  defp validate_pos_int!(val, _key) when is_integer(val) and val > 0, do: val

  defp validate_pos_int!(val, key) do
    raise ArgumentError, "expected positive integer #{inspect(key)}, got: #{inspect(val)}"
  end

  defp normalize_base_url(url) do
    String.trim_trailing(url, "/")
  end
end
