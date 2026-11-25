defmodule HWeb.Backend.HTTP do
  @moduledoc """
  HTTP / Unix domain socket `HWeb.Backend` adapter communicating with a running
  `H.HTTP.Router` daemon via `Req` and supervised SSE stream bridges.

  Resolves connection settings from explicit `opts`, `:harness_web` application
  config (`:http_backend`), or `H_DAEMON_URL` / `H_DATA_DIR` + `auth.token`.
  Owner tokens are kept inside `%H.Credentials.Redacted{}` so credentials are
  never exposed in logs or stack traces, and all JSON keys are normalized to the
  same shapes as `HWeb.Backend.InVM` without calling `String.to_atom/1`.
  """

  @behaviour HWeb.Backend

  alias H.Credentials.Redacted
  alias HWeb.Backend.HTTP.SSEBridge

  @default_timeout_ms 30_000
  @default_subscribe_timeout_ms 10_000

  @error_codes %{
    "not_found" => :not_found,
    "unknown_environment" => :unknown_environment,
    "workspace_unavailable" => :workspace_unavailable,
    "harness_unavailable" => :harness_unavailable,
    "daemon_draining" => :daemon_draining,
    "catalog_unavailable" => :catalog_unavailable,
    "session_unavailable" => :session_unavailable,
    "invalid_api_key_profile" => :invalid_api_key_profile,
    "too_many_account_sources" => :too_many_account_sources,
    "unknown_account_source" => :unknown_account_source,
    "invalid_login_request" => :invalid_login_request,
    "credential_unavailable" => :credential_unavailable,
    "credential_store_unavailable" => :credential_store_unavailable,
    "login_unavailable" => :login_unavailable,
    "login_not_found" => :login_not_found,
    "login_busy" => :login_busy,
    "login_request_conflict" => :login_request_conflict,
    "login_rate_limited" => :login_rate_limited,
    "accounts_unavailable" => :accounts_unavailable,
    "account_config_unavailable" => :account_config_unavailable,
    "accounts_busy" => :accounts_busy,
    "invalid_provider_config" => :invalid_provider_config,
    "stale_provider_config" => :stale_provider_config,
    "provider_key_binding" => :provider_key_binding,
    "provider_config_unavailable" => :provider_config_unavailable,
    "enoent" => :enoent,
    "not_in_head" => :not_in_head,
    "not_in_commit" => :not_in_commit,
    "invalid_commit" => :invalid_commit,
    "commit_unavailable" => :commit_unavailable,
    "git_unavailable" => :git_unavailable,
    "tree_too_large" => :tree_too_large,
    "file_too_large" => :file_too_large,
    "unsupported_binary" => :unsupported_binary,
    "not_text" => :not_text,
    "file_changed" => :file_changed,
    "workspace_busy" => :workspace_busy,
    "read_only" => :read_only,
    "symlink_not_followed" => :symlink_not_followed,
    "invalid_path" => :invalid_path,
    "invalid_edit" => :invalid_edit,
    "review_unavailable" => :review_unavailable
  }

  @doc "Resolves HTTP client config (`base_url`, `unix_socket`, redacted `token`, `host`)."
  @spec config(keyword()) :: {:ok, map()} | {:error, term()}
  def config(opts \\ []) when is_list(opts) do
    app_cfg = Application.get_env(:harness_web, :http_backend, [])

    merged =
      Keyword.merge(
        if(is_list(app_cfg), do: app_cfg, else: Map.to_list(app_cfg)),
        opts
      )

    data_dir =
      Keyword.get(merged, :data_dir) ||
        System.get_env("H_DATA_DIR") ||
        "~/.local/share/h"
        |> Path.expand()

    data_dir = Path.expand(data_dir)
    unix_socket = resolve_unix_socket(merged, data_dir)

    daemon_url =
      Keyword.get(merged, :daemon_url) || Keyword.get(merged, :url) ||
        System.get_env("H_DAEMON_URL")

    token_result = resolve_token(merged, data_dir)

    with {:ok, token} <- token_result,
         {:ok, base_url, socket_path, host} <- resolve_transport(daemon_url, unix_socket, merged) do
      {:ok,
       %{
         base_url: base_url,
         unix_socket: socket_path,
         token: token,
         host: host,
         timeout_ms: Keyword.get(merged, :timeout_ms, @default_timeout_ms),
         subscribe_timeout_ms:
           Keyword.get(merged, :subscribe_timeout_ms, @default_subscribe_timeout_ms),
         sse_sup: Keyword.get(merged, :sse_sup, HWeb.Backend.HTTP.SSESupervisor),
         sse_registry: Keyword.get(merged, :sse_registry, HWeb.Backend.HTTP.Registry),
         req_opts: Keyword.get(merged, :req_opts, [])
       }}
    end
  end

  @doc "Configures `:harness_web` `:backend` and `:http_backend` from environment (`H_WEB_BACKEND=http`)."
  @spec configure_from_env() :: :ok
  def configure_from_env do
    if System.get_env("H_WEB_BACKEND") == "http" do
      Application.put_env(:harness_web, :backend, __MODULE__)
    end

    :ok
  end

  # --- Browser auth callbacks ---

  @impl HWeb.Backend
  def create_browser_session(owner_token, opts \\ []) when is_binary(owner_token) do
    with {:ok, cfg} <- config(Keyword.put(opts, :token, owner_token)) do
      req_opts =
        build_req_opts(cfg, "/api/v1/auth/session",
          json: %{"token" => owner_token},
          bearer?: false
        )

      case Req.post(req_opts) do
        {:ok, %Req.Response{status: 200} = resp} ->
          case extract_owner_cookie(resp) do
            {:ok, cookie} -> {:ok, cookie}
            :error -> {:error, :auth_unavailable}
          end

        {:ok, %Req.Response{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %Req.Response{status: _}} ->
          {:error, :auth_unavailable}

        {:error, _} ->
          {:error, :auth_unavailable}
      end
    else
      _ -> {:error, :auth_unavailable}
    end
  end

  @impl HWeb.Backend
  def verify_browser_session(cookie, opts \\ [])

  def verify_browser_session(cookie, opts) when is_binary(cookie) and byte_size(cookie) > 0 do
    case config(Keyword.put(opts, :allow_missing_token, true)) do
      {:ok, cfg} ->
        req_opts =
          build_req_opts(cfg, "/api/v1/daemon/status",
            bearer?: false,
            headers: [{"cookie", "h_owner=#{cookie}"}]
          )

        case Req.get(req_opts) do
          {:ok, %Req.Response{status: 200}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  def verify_browser_session(_, _), do: false

  # --- Environment, workspace, harness, model endpoints ---

  @impl HWeb.Backend
  def list_environments(opts \\ []) do
    case request(:get, "/api/v1/environments", opts) do
      {:ok, %{"environments" => envs}} when is_list(envs) ->
        Enum.map(envs, &normalize_environment/1)

      _ ->
        []
    end
  end

  @impl HWeb.Backend
  def list_harnesses(opts \\ []) do
    case request(:get, "/api/v1/harnesses", opts) do
      {:ok, %{"harnesses" => harnesses}} when is_list(harnesses) ->
        harnesses

      _ ->
        []
    end
  end

  @impl HWeb.Backend
  def browse_workspace(params \\ %{}, opts \\ []) do
    query = compact_query(params, ~w(env_id path include_hidden include_subsessions))

    with {:ok, body} <- request(:get, "/api/v1/fs", Keyword.put(opts, :params, query)) do
      {:ok, normalize_browse_workspace(body)}
    end
  end

  @impl HWeb.Backend
  def list_files(params \\ %{}, opts \\ []) do
    query =
      compact_query(
        params,
        ~w(env_id cwd query include_hidden include_dirs exclude limit max_depth)
      )

    with {:ok, body} <- request(:get, "/api/v1/fs/files", Keyword.put(opts, :params, query)) do
      {:ok, normalize_list_files(body)}
    end
  end

  @impl HWeb.Backend
  def list_session_files(session_id, params \\ %{}, opts \\ []) do
    query =
      compact_query(
        params,
        ~w(query include_hidden include_dirs exclude limit max_depth)
      )

    with {:ok, body} <-
           request(
             :get,
             "/api/v1/sessions/#{URI.encode(session_id)}/files",
             Keyword.put(opts, :params, query)
           ) do
      {:ok, normalize_list_files(body)}
    end
  end

  @impl HWeb.Backend
  def list_models(opts \\ []) do
    case request(:get, "/api/v1/models", opts) do
      {:ok, %{"models" => models}} when is_list(models) ->
        Enum.map(models, &normalize_model/1)

      _ ->
        []
    end
  end

  # --- Sessions & reviews ---

  @impl HWeb.Backend
  def list_sessions(params \\ %{}, opts \\ []) do
    query = compact_query(params, ~w(env_id cwd subtree archived include_subsessions))

    with {:ok, %{"sessions" => sessions}} <-
           request(:get, "/api/v1/sessions", Keyword.put(opts, :params, query)) do
      {:ok, Enum.map(sessions, &normalize_session/1)}
    end
  end

  @impl HWeb.Backend
  def create_session(params, opts \\ []) do
    with {:ok, %{"session" => session, "seq" => seq}} <-
           request(:post, "/api/v1/sessions", Keyword.put(opts, :json, params)) do
      {:ok, %{session: normalize_session(session), seq: seq}}
    end
  end

  @impl HWeb.Backend
  def open_workspace_review(params, opts \\ []) do
    with {:ok, %{"session" => session, "seq" => seq}} <-
           request(:post, "/api/v1/workspaces/review", Keyword.put(opts, :json, params)) do
      {:ok, %{session: normalize_session(session), seq: seq}}
    end
  end

  @impl HWeb.Backend
  def review_workspace(session_id, params, opts \\ []) do
    query = build_review_query(params)

    with {:ok, body} <-
           request(
             :get,
             "/api/v1/sessions/#{URI.encode(session_id)}/review",
             Keyword.put(opts, :params, query)
           ) do
      {:ok, normalize_review_browse(body)}
    end
  end

  @impl HWeb.Backend
  def read_review_file(session_id, path, source, opts \\ []) do
    query = %{"path" => path, "source" => to_string(source)}

    with {:ok, body} <-
           request(
             :get,
             "/api/v1/sessions/#{URI.encode(session_id)}/review/file",
             Keyword.put(opts, :params, query)
           ) do
      normalize_review_file(body)
    end
  end

  @impl HWeb.Backend
  def save_review_file(session_id, path, revision, text, opts \\ []) do
    payload = %{"path" => path, "revision" => revision, "text" => text}

    with {:ok, %{"revision" => new_revision}} <-
           request(
             :post,
             "/api/v1/sessions/#{URI.encode(session_id)}/review/file",
             Keyword.put(opts, :json, payload)
           ) do
      {:ok, new_revision}
    end
  end

  @impl HWeb.Backend
  def get_session_detail(session_id, opts \\ []) do
    with {:ok, body} <-
           request(:get, "/api/v1/sessions/#{URI.encode(session_id)}", opts) do
      {:ok,
       %{
         session: normalize_session(body["session"]),
         conversations: Enum.map(body["conversations"] || [], &normalize_conversation/1),
         tasks: Enum.map(body["tasks"] || [], &normalize_task/1)
       }}
    end
  end

  @impl HWeb.Backend
  def get_session_tree(session_id, opts \\ []) do
    with {:ok, body} <-
           request(:get, "/api/v1/sessions/#{URI.encode(session_id)}/tree", opts) do
      {:ok,
       %{
         session: normalize_session(body["session"]),
         conversations: Enum.map(body["conversations"] || [], &normalize_tree_conversation/1),
         nodes: Enum.map(body["nodes"] || [], &normalize_tree_node/1),
         truncated: body["truncated"] == true
       }}
    end
  end

  @impl HWeb.Backend
  def scan_entries(session_id, conversation_id, params \\ %{}, opts \\ []) do
    query = compact_query(params, ~w(order cursor limit))

    with {:ok, %{"items" => items} = body} <-
           request(
             :get,
             "/api/v1/sessions/#{URI.encode(session_id)}/conversations/#{URI.encode(to_string(conversation_id))}/entries",
             Keyword.put(opts, :params, query)
           ) do
      {:ok,
       %{
         items: Enum.map(items, &normalize_entry/1),
         next_cursor: body["next_cursor"]
       }}
    end
  end

  @impl HWeb.Backend
  def get_extension_status(session_id, conversation_id, opts \\ []) do
    request(
      :get,
      "/api/v1/sessions/#{URI.encode(session_id)}/conversations/#{URI.encode(to_string(conversation_id))}/extension-status",
      opts
    )
  end

  @impl HWeb.Backend
  def execute_command(session_id, envelope, opts \\ []) do
    with {:ok, body} <-
           request(
             :post,
             "/api/v1/sessions/#{URI.encode(session_id)}/commands",
             Keyword.put(opts, :json, envelope)
           ) do
      {:ok, normalize_receipt(body)}
    end
  end

  @impl HWeb.Backend
  def deliver_signal(session_id, params, opts \\ []) do
    with {:ok, body} <-
           request(
             :post,
             "/api/v1/sessions/#{URI.encode(session_id)}/signals",
             Keyword.put(opts, :json, params)
           ) do
      {:ok, normalize_receipt(body)}
    end
  end

  @impl HWeb.Backend
  def triage_session(session_id, params, opts \\ []) do
    with {:ok, %{"session" => session}} <-
           request(
             :post,
             "/api/v1/sessions/#{URI.encode(session_id)}/triage",
             Keyword.put(opts, :json, params)
           ) do
      {:ok, %{session: normalize_session(session)}}
    end
  end

  @impl HWeb.Backend
  def stop_session(session_id, params \\ %{}, opts \\ []) do
    with {:ok, %{"session" => session}} <-
           request(
             :post,
             "/api/v1/sessions/#{URI.encode(session_id)}/stop",
             Keyword.put(opts, :json, params)
           ) do
      {:ok, %{session: normalize_session(session)}}
    end
  end

  @impl HWeb.Backend
  def archive_session(session_id, params \\ %{}, opts \\ []) do
    with {:ok, %{"session" => session}} <-
           request(
             :post,
             "/api/v1/sessions/#{URI.encode(session_id)}/archive",
             Keyword.put(opts, :json, params)
           ) do
      {:ok, %{session: normalize_session(session)}}
    end
  end

  @impl HWeb.Backend
  def fork_session(session_id, params, opts \\ []) do
    with {:ok, %{"session" => session, "seq" => seq}} <-
           request(
             :post,
             "/api/v1/sessions/#{URI.encode(session_id)}/fork",
             Keyword.put(opts, :json, params)
           ) do
      {:ok, %{session: normalize_session(session), seq: seq}}
    end
  end

  # --- Accounts & provider catalog ---

  @impl HWeb.Backend
  def api_keys(opts \\ []) do
    with {:ok, %{"providers" => providers}} <- request(:get, "/api/v1/provider-keys", opts) do
      {:ok, %{providers: Enum.map(providers, &normalize_api_key_profile/1)}}
    end
  end

  @impl HWeb.Backend
  def put_api_key(params, opts \\ []) do
    with {:ok, body} <-
           request(:post, "/api/v1/provider-keys/set", Keyword.put(opts, :json, params)) do
      {:ok, normalize_key_mutation(body)}
    end
  end

  @impl HWeb.Backend
  def use_api_key(params, opts \\ []) do
    with {:ok, body} <-
           request(:post, "/api/v1/provider-keys/use", Keyword.put(opts, :json, params)) do
      {:ok, normalize_key_mutation(body)}
    end
  end

  @impl HWeb.Backend
  def remove_api_key(params, opts \\ []) do
    with {:ok, body} <-
           request(:post, "/api/v1/provider-keys/remove", Keyword.put(opts, :json, params)) do
      {:ok, normalize_key_mutation(body)}
    end
  end

  @impl HWeb.Backend
  def discover_logins(opts \\ []) do
    with {:ok, %{"providers" => providers}} <- request(:get, "/api/v1/provider-logins", opts) do
      {:ok, %{providers: Enum.map(providers, &normalize_login_provider/1)}}
    end
  end

  @impl HWeb.Backend
  def start_login(params, opts \\ []) do
    with {:ok, body} <-
           request(:post, "/api/v1/provider-logins/start", Keyword.put(opts, :json, params)) do
      {:ok, normalize_login_flow(body)}
    end
  end

  @impl HWeb.Backend
  def login_operation(action, params, opts \\ []) when action in [:status, :cancel] do
    path =
      case action do
        :status -> "/api/v1/provider-logins/status"
        :cancel -> "/api/v1/provider-logins/cancel"
      end

    with {:ok, body} <- request(:post, path, Keyword.put(opts, :json, params)) do
      {:ok, normalize_login_flow(body)}
    end
  end

  @impl HWeb.Backend
  def add_account(params, opts \\ []) do
    with {:ok, body} <-
           request(:post, "/api/v1/provider-accounts/add", Keyword.put(opts, :json, params)) do
      {:ok, %{source: body["source"]}}
    end
  end

  @impl HWeb.Backend
  def activate_account(params, opts \\ []) do
    with {:ok, body} <-
           request(:post, "/api/v1/provider-accounts/activate", Keyword.put(opts, :json, params)) do
      {:ok, %{active: body["active"]}}
    end
  end

  @impl HWeb.Backend
  def remove_account(params, opts \\ []) do
    with {:ok, body} <-
           request(:post, "/api/v1/provider-accounts/remove", Keyword.put(opts, :json, params)) do
      {:ok, %{removed: body["removed"], active: body["active"]}}
    end
  end

  @impl HWeb.Backend
  def provider_catalog(opts \\ []) do
    with {:ok, body} <- request(:get, "/api/v1/provider-catalog", opts) do
      {:ok,
       %{
         providers: body["providers"] || %{},
         revision: body["revision"],
         pending?: body["pending?"] == true,
         running: body["running"] || []
       }}
    end
  end

  @impl HWeb.Backend
  def stage_provider(params, opts \\ []) do
    case request(:post, "/api/v1/provider-catalog", Keyword.put(opts, :json, params)) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # --- Supervised SSE subscriptions ---

  @impl HWeb.Backend
  def subscribe_sessions(subscriber_pid, opts \\ []) when is_pid(subscriber_pid) do
    with {:ok, cfg} <- config(opts) do
      SSEBridge.subscribe_catalog(cfg, subscriber_pid)
    end
  end

  @impl HWeb.Backend
  def unsubscribe_sessions(opts \\ []) do
    with {:ok, cfg} <- config(opts) do
      SSEBridge.unsubscribe_catalog(cfg, self())
    else
      _ -> :ok
    end
  end

  @impl HWeb.Backend
  def subscribe_conversation(
        session_id,
        conversation_id,
        subscriber_pid,
        last_event_id \\ nil,
        opts \\ []
      )
      when is_binary(session_id) and is_pid(subscriber_pid) do
    with {:ok, cfg} <- config(opts) do
      SSEBridge.subscribe_conversation(
        cfg,
        session_id,
        to_string(conversation_id),
        subscriber_pid,
        last_event_id
      )
    end
  end

  @impl HWeb.Backend
  def unsubscribe_conversation(session_id, conversation_id, opts \\ []) do
    with {:ok, cfg} <- config(opts) do
      SSEBridge.unsubscribe_conversation(cfg, session_id, to_string(conversation_id), self())
    else
      _ -> :ok
    end
  end

  # --- HTTP request plumbing ---

  @doc false
  def build_req_opts(cfg, path, extra \\ []) do
    %Redacted{value: raw_token} = cfg.token
    bearer? = Keyword.get(extra, :bearer?, true)
    extra_headers = Keyword.get(extra, :headers, [])

    headers =
      []
      |> then(fn h ->
        if bearer? and raw_token != "" do
          [{"authorization", "Bearer #{raw_token}"} | h]
        else
          h
        end
      end)
      |> then(fn h ->
        if is_binary(cfg.host) and cfg.host != "" do
          [{"host", cfg.host} | h]
        else
          h
        end
      end)
      |> Kernel.++(extra_headers)

    base =
      [
        url: cfg.base_url <> path,
        headers: headers,
        retry: false,
        receive_timeout: cfg.timeout_ms
      ]
      |> Kernel.++(Keyword.drop(extra, [:bearer?, :headers]))
      |> Kernel.++(cfg.req_opts || [])

    if cfg.unix_socket do
      Keyword.put(base, :unix_socket, cfg.unix_socket)
    else
      base
    end
  end

  defp request(method, path, opts) do
    with {:ok, cfg} <- config(opts) do
      req_opts =
        build_req_opts(
          cfg,
          path,
          Keyword.take(opts, [:params, :json, :headers, :receive_timeout])
        )

      result =
        case method do
          :get -> Req.get(req_opts)
          :post -> Req.post(req_opts)
        end

      case result do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, decode_error(status, body)}

        {:error, reason} ->
          {:error, {:daemon_unavailable, reason}}
      end
    end
  end

  defp decode_error(status, %{"code" => code} = body) when is_binary(code) do
    case Map.fetch(@error_codes, code) do
      {:ok, atom} -> atom
      :error -> decode_error(status, Map.delete(body, "code"))
    end
  end

  defp decode_error(404, %{"error" => msg}) do
    Map.get(@error_codes, msg, :not_found)
  end

  defp decode_error(404, _), do: :not_found

  defp decode_error(409, %{"error" => msg}) when is_binary(msg) do
    Map.get(@error_codes, msg, {:conflict, msg})
  end

  defp decode_error(422, %{"error" => msg}) when is_binary(msg) do
    Map.get(@error_codes, msg, {:bad_request, msg})
  end

  defp decode_error(403, %{"error" => msg}) when is_binary(msg) do
    Map.get(@error_codes, msg, {:forbidden, msg})
  end

  defp decode_error(429, %{"error" => msg}) when is_binary(msg) do
    Map.get(@error_codes, msg, {:rate_limited, msg})
  end

  defp decode_error(503, %{"error" => "session quarantined", "reason" => reason}) do
    {:quarantined, reason}
  end

  defp decode_error(503, %{"error" => msg}) when is_binary(msg) do
    Map.get(@error_codes, msg, :daemon_unavailable)
  end

  defp decode_error(status, body), do: {:http_error, status, body}

  defp extract_owner_cookie(%Req.Response{} = resp) do
    resp.headers
    |> Enum.flat_map(fn
      {k, vals} when is_binary(k) ->
        if String.downcase(k) == "set-cookie", do: List.wrap(vals), else: []

      _ ->
        []
    end)
    |> Enum.find_value(:error, fn header ->
      case Regex.run(~r/\Ah_owner=([^;]+)/, header) do
        [_, cookie] when byte_size(cookie) > 0 -> {:ok, cookie}
        _ -> nil
      end
    end)
  end

  # --- Config resolution ---

  defp resolve_unix_socket(merged, data_dir) do
    case Keyword.fetch(merged, :unix_socket) do
      {:ok, path} ->
        path

      :error ->
        cond do
          Keyword.has_key?(merged, :daemon_url) or Keyword.has_key?(merged, :url) or
              is_binary(System.get_env("H_DAEMON_URL")) ->
            nil

          true ->
            Path.join(data_dir, "api.sock")
        end
    end
  end

  defp resolve_token(merged, data_dir) do
    case Keyword.get(merged, :token) do
      %Redacted{} = redacted ->
        {:ok, redacted}

      token when is_binary(token) ->
        trimmed = String.trim(token)

        if trimmed != "" do
          {:ok, %Redacted{value: trimmed}}
        else
          if Keyword.get(merged, :allow_missing_token, false),
            do: {:ok, %Redacted{value: ""}},
            else: {:error, :missing_auth_token}
        end

      nil ->
        token_path = Keyword.get(merged, :token_path) || Path.join(data_dir, "auth.token")

        case File.read(token_path) do
          {:ok, content} ->
            trimmed = String.trim(content)

            if trimmed != "" do
              {:ok, %Redacted{value: trimmed}}
            else
              {:error, :missing_auth_token}
            end

          {:error, _} ->
            if Keyword.get(merged, :allow_missing_token, false),
              do: {:ok, %Redacted{value: ""}},
              else: {:error, :missing_auth_token}
        end
    end
  end

  defp resolve_transport(daemon_url, unix_socket, merged) do
    cond do
      is_binary(unix_socket) and unix_socket != "" ->
        base = normalize_base_url(daemon_url || "http://localhost")
        host = Keyword.get(merged, :host) || "localhost"
        {:ok, base, unix_socket, host}

      is_binary(daemon_url) and daemon_url != "" ->
        base = normalize_base_url(daemon_url)
        host = Keyword.get(merged, :host) || host_from_url(base)
        {:ok, base, nil, host}

      true ->
        {:error, :missing_daemon_endpoint}
    end
  end

  defp normalize_base_url(url) do
    url |> String.trim() |> String.trim_trailing("/")
  end

  defp host_from_url(url) do
    case URI.parse(url) do
      %URI{host: host, port: port} when is_binary(host) and is_integer(port) ->
        formatted = if String.contains?(host, ":"), do: "[#{host}]", else: host
        "#{formatted}:#{port}"

      %URI{host: host} when is_binary(host) ->
        host

      _ ->
        nil
    end
  end

  # --- JSON -> InVM shape normalizers (no String.to_atom) ---

  defp compact_query(params, allowed_keys) when is_map(params) do
    Enum.reduce(allowed_keys, %{}, fn key, acc ->
      val = fetch_any(params, key)
      if is_nil(val) or val == "", do: acc, else: Map.put(acc, key, to_string(val))
    end)
  end

  defp build_review_query(params) when is_map(params) do
    cond do
      not is_nil(fetch_any(params, "history")) ->
        %{"history" => to_string(fetch_any(params, "history"))}

      not is_nil(fetch_any(params, "commit")) and is_nil(fetch_any(params, "dir")) and
          is_nil(fetch_any(params, "page")) ->
        %{"commit" => to_string(fetch_any(params, "commit"))}

      true ->
        %{}
        |> maybe_put_query("dir", fetch_any(params, "dir"))
        |> maybe_put_query("page", fetch_any(params, "page"))
        |> maybe_put_query("commit", fetch_any(params, "commit"))
        |> maybe_put_query(
          "changes",
          case fetch_any(params, "changes?") || fetch_any(params, "changes") do
            nil -> nil
            v -> to_string(v)
          end
        )
    end
  end

  defp maybe_put_query(map, _key, nil), do: map
  defp maybe_put_query(map, key, val), do: Map.put(map, key, to_string(val))

  defp fetch_any(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, val} ->
        val

      :error ->
        Enum.find_value(map, fn
          {k, v} when is_atom(k) ->
            if Atom.to_string(k) == key, do: v, else: nil

          _ ->
            nil
        end)
    end
  end

  defp normalize_environment(env) when is_map(env) do
    %{
      id: env["id"],
      kind: env["kind"],
      label: env["label"],
      default_cwd: env["default_cwd"]
    }
  end

  defp normalize_browse_workspace(body) do
    %{
      env_id: body["env_id"],
      path: body["path"],
      parent_path: Map.get(body, "parent_path", body["parent"]),
      directories: Enum.map(body["directories"] || body["entries"] || [], &normalize_directory/1),
      sessions: Enum.map(body["sessions"] || [], &normalize_session/1)
    }
  end

  defp normalize_directory(dir) do
    %{
      name: dir["name"],
      path: dir["path"],
      type: dir["type"],
      markers: dir["markers"] || [],
      direct_session_count: dir["direct_session_count"] || 0,
      subtree_session_count: dir["subtree_session_count"] || 0,
      active_session_count: dir["active_session_count"] || 0,
      latest_session:
        case dir["latest_session"] do
          nil -> nil
          sess when is_map(sess) -> normalize_session(sess)
        end
    }
  end

  defp normalize_list_files(body) do
    %{
      env_id: body["env_id"],
      cwd: body["cwd"],
      entries: Enum.map(body["entries"] || [], &normalize_file_entry/1),
      truncated: body["truncated"] == true
    }
  end

  defp normalize_file_entry(entry) when is_map(entry) do
    %{
      path: entry["path"],
      type: entry["type"],
      name: entry["name"],
      size: entry["size"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_model(m) when is_map(m) do
    base = %{
      id: m["id"],
      provider: m["provider"],
      name: m["name"],
      context_window: m["context_window"],
      max_output_tokens: m["max_output_tokens"],
      supports_tools: m["supports_tools"] == true,
      supports_reasoning: m["supports_reasoning"] == true
    }

    base =
      if is_binary(m["provider_name"]),
        do: Map.put(base, :provider_name, m["provider_name"]),
        else: base

    base =
      if is_boolean(m["supports_images"]),
        do: Map.put(base, :supports_images, m["supports_images"]),
        else: base

    base =
      if is_map(m["price_per_million_tokens"]),
        do: Map.put(base, :price_per_million_tokens, m["price_per_million_tokens"]),
        else: base

    if is_binary(m["unavailable_reason"]),
      do: Map.put(base, :unavailable_reason, m["unavailable_reason"]),
      else: base
  end

  defp normalize_session(s) when is_map(s) do
    HWeb.CatalogState.normalize_session(s)
  end

  defp normalize_conversation(c) when is_map(c) do
    parent =
      case c["parent"] do
        %{"conversation_id" => cid, "at" => at} ->
          %{conversation_id: to_string(cid), at: to_string(at)}

        _ ->
          nil
      end

    %{
      id: to_string(c["id"]),
      parent: parent,
      owner: c["owner"]
    }
  end

  defp normalize_task(t) when is_map(t) do
    %{
      id: to_string(t["id"]),
      kind: t["kind"],
      version: t["version"],
      status: t["status"],
      owner: t["owner"],
      restarts: t["restarts"] || 0,
      cancelled: t["cancelled"] == true,
      abort_reason: t["abort_reason"],
      wake: t["wake"],
      outcome: t["outcome"],
      created_at: t["created_at"],
      updated_at: t["updated_at"]
    }
  end

  defp normalize_tree_conversation(c) when is_map(c) do
    parent =
      case c["parent"] do
        %{"conversation_id" => cid, "at" => at} ->
          %{conversation_id: to_string(cid), at: to_string(at)}

        _ ->
          nil
      end

    %{
      id: to_string(c["id"]),
      parent: parent,
      owner: c["owner"],
      leaf_entry_id: c["leaf_entry_id"]
    }
  end

  defp normalize_tree_node(n) when is_map(n) do
    %{
      id: to_string(n["id"]),
      parent_id: n["parent_id"] && to_string(n["parent_id"]),
      conversation_id: to_string(n["conversation_id"]),
      kind: n["kind"],
      preview: n["preview"],
      has_text: n["has_text"] == true,
      tool_name: n["tool_name"],
      aborted: n["aborted"] == true,
      is_error: n["is_error"] == true,
      error: n["error"] == true,
      created_at: n["created_at"]
    }
  end

  defp normalize_entry(e) when is_map(e) do
    %{
      id: to_string(e["id"]),
      conversation_id: to_string(e["conversation_id"]),
      seq: e["seq"],
      kind: e["kind"],
      data: e["data"],
      created_at: e["created_at"]
    }
  end

  defp normalize_receipt(r) when is_map(r) do
    %{}
    |> put_if_present(:version, r["version"])
    |> put_if_present(:request_id, r["request_id"])
    |> put_if_present(:seq, r["seq"])
    |> put_if_present(:conversation_id, r["conversation_id"])
    |> put_if_present(:submission_id, r["submission_id"])
    |> put_if_present(:signal_id, r["signal_id"])
    |> put_if_present(:topic, r["topic"])
    |> put_if_present(:status, r["status"])
    |> put_if_present(:consumed_by_task_id, r["consumed_by_task_id"])
    |> put_if_present(:withdrawn, r["withdrawn"])
    |> put_if_present(:title, r["title"])
    |> put_if_present(:reason, r["reason"])
    |> put_if_present(:aborted_conversations, r["aborted_conversations"])
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, val), do: Map.put(map, key, val)

  defp normalize_review_browse(body) when is_map(body) do
    base = %{archived: body["archived"] == true}

    base =
      if Map.has_key?(body, "commits") do
        commits =
          Enum.map(body["commits"] || [], fn c ->
            %{
              id: c["id"],
              parent: c["parent"],
              date: c["date"],
              subject: c["subject"]
            }
          end)

        Map.merge(base, %{commits: commits, next?: body["next?"] == true})
      else
        base
      end

    base =
      if is_map(body["commit"]) do
        c = body["commit"]

        Map.put(base, :commit, %{
          id: c["id"],
          parent: c["parent"],
          date: c["date"],
          subject: c["subject"],
          base: c["base"]
        })
      else
        base
      end

    base =
      if Map.has_key?(body, "entries") do
        entries =
          Enum.map(body["entries"] || [], fn e ->
            %{name: e["name"], path: e["path"], type: e["type"]}
          end)

        Map.merge(base, %{entries: entries, next?: body["next?"] == true})
      else
        base
      end

    if Map.has_key?(body, "git") do
      Map.put(base, :git, normalize_review_git(body["git"]))
    else
      base
    end
  end

  defp normalize_review_git(nil), do: nil
  defp normalize_review_git("not_git"), do: :not_git
  defp normalize_review_git("git_unavailable"), do: :git_unavailable
  defp normalize_review_git("parent_unavailable"), do: :parent_unavailable

  defp normalize_review_git(%{"entries" => entries} = git) when is_list(entries) do
    %{
      entries: Enum.map(entries, &normalize_review_git_entry/1),
      truncated?: git["truncated?"] == true
    }
  end

  defp normalize_review_git_entry(e) when is_map(e) do
    %{path: e["path"]}
    |> put_if_present(:staged, e["staged"])
    |> put_if_present(:working, e["working"])
    |> put_if_present(:untracked, e["untracked"])
    |> put_if_present(:status, e["status"])
  end

  defp normalize_review_file(%{"kind" => "text"} = body) do
    preview =
      case body["preview"] do
        %{"mode" => mode, "mime" => mime} ->
          mode_atom =
            case mode do
              "image" -> :image
              "html" -> :html
              "audio" -> :audio
              "video" -> :video
              _ -> nil
            end

          if mode_atom, do: {mode_atom, mime}, else: nil

        _ ->
          nil
      end

    {:ok,
     %{
       kind: :text,
       text: body["text"],
       revision: body["revision"],
       preview: preview,
       archived: body["archived"] == true
     }}
  end

  defp normalize_review_file(%{"kind" => "media", "bytes" => encoded} = body)
       when is_binary(encoded) do
    mode =
      case body["mode"] do
        "image" -> :image
        "audio" -> :audio
        "video" -> :video
        _ -> nil
      end

    with {:ok, bytes} <- Base.decode64(encoded),
         true <- not is_nil(mode) do
      {:ok,
       %{
         kind: :media,
         mode: mode,
         mime: body["mime"],
         bytes: bytes,
         revision: body["revision"],
         archived: body["archived"] == true
       }}
    else
      _ -> {:error, :review_unavailable}
    end
  end

  defp normalize_review_file(_), do: {:error, :review_unavailable}

  defp normalize_api_key_profile(p) when is_map(p) do
    %{
      provider: p["provider"],
      active: p["active"],
      sources: p["sources"] || []
    }
  end

  defp normalize_key_mutation(body) when is_map(body) do
    %{}
    |> put_if_present(:provider, body["provider"])
    |> put_if_present(:active, body["active"])
    |> put_if_present(:removed, body["removed"])
  end

  defp normalize_login_provider(p) when is_map(p) do
    sources =
      Enum.map(p["sources"] || [], fn s ->
        base = %{
          id: s["id"],
          state: s["state"],
          active: s["active"] == true
        }

        if is_binary(s["status_note"]),
          do: Map.put(base, :status_note, s["status_note"]),
          else: base
      end)

    base = %{
      id: p["id"],
      interaction: p["interaction"],
      sources: sources
    }

    if is_binary(p["status_note"]),
      do: Map.put(base, :status_note, p["status_note"]),
      else: base
  end

  defp normalize_login_flow(f) when is_map(f) do
    %{}
    |> put_if_present(:operation, f["operation"])
    |> put_if_present(:source, f["source"])
    |> put_if_present(:state, f["state"])
    |> put_if_present(:expires_in_ms, f["expires_in_ms"])
    |> put_if_present(:poll_after_ms, f["poll_after_ms"])
    |> put_if_present(:verification_url, f["verification_url"])
    |> put_if_present(:user_code, f["user_code"])
    |> put_if_present(:reason, f["reason"])
  end
end
