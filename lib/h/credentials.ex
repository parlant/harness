defmodule H.Credentials do
  @moduledoc """
  In-memory credential resolver for LLM providers.

  Credentials are resolved on demand from explicit options, environment
  variables, or external helpers (such as `token-exchange`) and optionally
  cached in memory with a TTL safety margin. Secrets are never persisted to disk
  or included in inspected/sanitized error values.
  """

  use GenServer

  @default_ttl_ms 3_600_000
  @default_ttl_margin_ms 60_000

  @provider_priority [
    :openai,
    :anthropic,
    :google_vertex,
    :google,
    :deepseek,
    :openrouter
  ]

  @env_vars %{
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai" => "OPENAI_API_KEY",
    "openrouter" => "OPENROUTER_API_KEY",
    "deepseek" => "DEEPSEEK_API_KEY",
    "google" => "GOOGLE_API_KEY"
  }

  @sensitive_keys MapSet.new([
                    "access_token",
                    "api_key",
                    "api_token",
                    "authorization",
                    "credential",
                    "credentials",
                    "secret",
                    "token"
                  ])

  defmodule Redacted do
    @moduledoc false
    @enforce_keys [:value]
    defstruct [:value]

    defimpl Inspect do
      def inspect(_struct, _opts), do: "#H.Credentials.Redacted<[REDACTED]>"
    end
  end

  defmodule CacheEntry do
    @moduledoc false
    @enforce_keys [:token, :expires_at]
    defstruct [:token, :expires_at]

    defimpl Inspect do
      def inspect(%{expires_at: expires_at}, _opts) do
        "#H.Credentials.CacheEntry<token: [REDACTED], expires_at: #{expires_at}>"
      end
    end
  end

  @type vertex_credentials :: %{
          access_token: String.t(),
          project_id: String.t(),
          region: String.t()
        }

  @type api_key_credentials :: %{api_key: String.t()}
  @type anonymous_credentials :: %{auth_mode: :none}

  @type credentials :: vertex_credentials() | api_key_credentials() | anonymous_credentials()

  # Optional in-memory cache server

  @doc """
  Starts an in-memory credential cache process.

  Options:
  - `:name` - Optional registered name (defaults to `nil`)
  - `:ttl_margin_ms` - Safety margin subtracted from token expiration (default `60_000`)
  - `:default_ttl_ms` - Fallback TTL when helper output omits expiration (default `3_600_000`)
  - `:now_fn` - Zero-arity clock function returning monotonic/unix ms (default `&System.system_time(:millisecond)`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, state_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, state_opts, gen_opts)
  end

  @doc """
  Clears all cached tokens from a running cache process.
  """
  @spec clear_cache(GenServer.server()) :: :ok
  def clear_cache(cache \\ __MODULE__) do
    GenServer.call(cache, :clear)
  end

  @doc """
  Resolves in-memory credentials for `provider`.

  Supported providers:
  - `:google_vertex` / `"google_vertex"` / `"google-vertex"`
  - `:anthropic` / `"anthropic"` (`ANTHROPIC_API_KEY`)
  - `:openai` / `"openai"` (`OPENAI_API_KEY`)
  - `:openrouter` / `"openrouter"` (`OPENROUTER_API_KEY`)
  - `:deepseek` / `"deepseek"` (`DEEPSEEK_API_KEY`)
  - `:google` / `"google"` (`GOOGLE_API_KEY`)
  - `:ollama` / `"ollama"` (no key required; returns `%{auth_mode: :none}`)

  Options:
  - `:access_token` - Explicit bearer token for `:google_vertex`
  - `:project_id` - Override `GOOGLE_CLOUD_PROJECT`
  - `:region` - Override `GOOGLE_CLOUD_REGION` (defaults to `"global"`)
  - `:api_key` - Explicit API key override
  - `:fetcher` - Injectable 0-arity or 1-arity callback for `:google_vertex`
  - `:cache` - Cache server pid/name, or `false` to bypass cache
  - `:env` - Optional `%{String.t() => String.t()}` map overriding `System.get_env/1`
  - `:ttl_margin_ms` / `:default_ttl_ms` / `:now_fn` - Timing overrides when uncached or configuring cache
  """
  @spec resolve(atom() | String.t(), keyword()) :: {:ok, credentials()} | {:error, term()}
  def resolve(provider, opts \\ []) when is_list(opts) do
    case normalize_provider(provider) do
      {:ok, "google_vertex"} ->
        resolve_vertex(opts)

      {:ok, "ollama"} ->
        {:ok, %{auth_mode: :none}}

      {:ok, name} ->
        resolve_env_api_key(name, Map.fetch!(@env_vars, name), opts)

      :error ->
        {:error, {:unsupported_provider, sanitize(to_string(provider))}}
    end
  end

  @doc """
  Returns the list of providers that currently have credentials configured in
  `opts` or the environment, ordered by `@provider_priority`.
  """
  @spec configured_providers(keyword()) :: [atom()]
  def configured_providers(opts \\ []) when is_list(opts) do
    Enum.filter(@provider_priority, &configured?(&1, opts))
  end

  @doc """
  Returns `true` if `provider` has credentials available in `opts` or the
  environment without executing external token helpers.
  """
  @spec configured?(atom() | String.t(), keyword()) :: boolean()
  def configured?(provider, opts \\ []) when is_list(opts) do
    case normalize_provider(provider) do
      {:ok, "google_vertex"} ->
        match?({:ok, _}, resolve_project_id(opts)) and
          (is_binary(presence(Keyword.get(opts, :access_token))) or
             is_function(Keyword.get(opts, :fetcher)) or
             not is_nil(System.find_executable("token-exchange")) or
             not is_nil(System.find_executable("google-adc")))

      {:ok, "ollama"} ->
        true

      {:ok, name} ->
        env_var = Map.fetch!(@env_vars, name)

        is_binary(presence(Keyword.get(opts, :api_key))) or
          is_binary(presence(get_env(env_var, opts)))

      :error ->
        false
    end
  end

  @doc """
  Redacts secret values (`access_token`, `api_key`, `Bearer ...`, etc.) from maps,
  lists, tuples, exceptions, and strings so credentials never leak into logs or errors.
  """
  @spec sanitize(term()) :: term()
  def sanitize(%_{} = struct) do
    if is_exception(struct) do
      struct |> Exception.message() |> sanitize_binary()
    else
      struct |> Map.from_struct() |> sanitize()
    end
  end

  def sanitize(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, sanitize(value)}
      end
    end)
  end

  def sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)

  def sanitize(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> sanitize() |> List.to_tuple()
  end

  def sanitize(binary) when is_binary(binary), do: sanitize_binary(binary)
  def sanitize(other), do: other

  # GenServer callbacks

  @impl true
  def init(opts) do
    table = :ets.new(:h_credentials_cache, [:set, :protected])

    state = %{
      table: table,
      ttl_margin_ms: Keyword.get(opts, :ttl_margin_ms, @default_ttl_margin_ms),
      default_ttl_ms: Keyword.get(opts, :default_ttl_ms, @default_ttl_ms),
      now_fn: Keyword.get(opts, :now_fn, fn -> System.system_time(:millisecond) end)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get_or_fetch, key, fetcher_fn}, _from, state) do
    now = state.now_fn.()

    case lookup_valid(state.table, key, now, state.ttl_margin_ms) do
      {:ok, token} ->
        {:reply, {:ok, token}, state}

      :miss ->
        case invoke_fetcher(fetcher_fn, now, state.default_ttl_ms) do
          {:ok, %CacheEntry{} = entry} ->
            :ets.insert(state.table, {key, entry})
            {:reply, {:ok, entry.token}, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if :ets.info(state.table) != :undefined do
      :ets.delete(state.table)
    end

    :ok
  end

  # Resolution internals

  defp resolve_vertex(opts) do
    with {:ok, project_id} <- resolve_project_id(opts),
         region = resolve_region(opts),
         {:ok, access_token} <- resolve_vertex_token(project_id, opts) do
      {:ok, %{access_token: access_token, project_id: project_id, region: region}}
    end
  end

  defp resolve_project_id(opts) do
    case presence(Keyword.get(opts, :project_id)) ||
           presence(get_env("GOOGLE_CLOUD_PROJECT", opts)) do
      nil -> {:error, {:missing_env, "GOOGLE_CLOUD_PROJECT"}}
      project_id -> {:ok, project_id}
    end
  end

  defp resolve_region(opts) do
    presence(Keyword.get(opts, :region)) ||
      presence(get_env("GOOGLE_CLOUD_REGION", opts)) ||
      "global"
  end

  defp resolve_vertex_token(project_id, opts) do
    case Keyword.fetch(opts, :access_token) do
      {:ok, token} when is_binary(token) and token != "" ->
        {:ok, strip_bearer(token)}

      {:ok, _empty} ->
        {:error, :empty_access_token}

      :error ->
        fetch_vertex_token(project_id, opts)
    end
  end

  defp fetch_vertex_token(project_id, opts) do
    fetcher = Keyword.get(opts, :fetcher, &default_vertex_fetcher/1)
    fetcher_fn = fn -> call_fetcher(fetcher, opts) end

    case cache_target(opts) do
      nil ->
        now = now_ms(opts)
        default_ttl = Keyword.get(opts, :default_ttl_ms, @default_ttl_ms)

        case invoke_fetcher(fetcher_fn, now, default_ttl) do
          {:ok, %CacheEntry{token: token}} -> {:ok, token}
          {:error, _} = error -> error
        end

      cache ->
        cache_key = Keyword.get(opts, :cache_key, {:google_vertex, project_id})
        GenServer.call(cache, {:get_or_fetch, cache_key, fetcher_fn})
    end
  end

  defp resolve_env_api_key(provider_name, env_var, opts) do
    case Keyword.fetch(opts, :api_key) do
      {:ok, key} when is_binary(key) and key != "" ->
        {:ok, %{api_key: key}}

      {:ok, _empty} ->
        {:error, {:empty_api_key, provider_name}}

      :error ->
        case presence(get_env(env_var, opts)) do
          nil -> {:error, {:missing_env, env_var}}
          key -> {:ok, %{api_key: key}}
        end
    end
  end

  defp cache_target(opts) do
    case Keyword.get(opts, :cache) do
      false -> nil
      nil -> Process.whereis(__MODULE__)
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid, else: nil
      name when is_atom(name) -> Process.whereis(name)
    end
  end

  defp lookup_valid(table, key, now, ttl_margin_ms) do
    case :ets.lookup(table, key) do
      [{^key, %CacheEntry{token: token, expires_at: expires_at}}]
      when expires_at - ttl_margin_ms > now ->
        {:ok, token}

      _ ->
        :miss
    end
  end

  defp invoke_fetcher(fetcher_fn, now, default_ttl_ms) do
    case fetcher_fn.() do
      {:ok, raw} -> parse_token_payload(raw, now, default_ttl_ms)
      {:error, reason} -> {:error, sanitize(reason)}
      other -> {:error, {:invalid_fetcher_result, sanitize(other)}}
    end
  rescue
    exception ->
      {:error, {:fetcher_crashed, sanitize(Exception.message(exception))}}
  end

  defp call_fetcher(fun, _opts) when is_function(fun, 0), do: fun.()
  defp call_fetcher(fun, opts) when is_function(fun, 1), do: fun.(opts)

  defp default_vertex_fetcher(_opts) do
    cond do
      exe = System.find_executable("token-exchange") ->
        run_cli_token(exe, ["google", "token", "--for", "adc", "--no-login"])

      exe = System.find_executable("google-adc") ->
        run_cli_token(exe, [])

      true ->
        {:error, :credential_helper_not_found}
    end
  end

  defp run_cli_token(exe, args) do
    case System.cmd(exe, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:credential_helper_failed, status, sanitize_binary(output)}}
    end
  end

  defp parse_token_payload(%{access_token: token} = payload, now, default_ttl_ms)
       when is_binary(token) and token != "" do
    expires_at = resolve_expires_at(payload, now, default_ttl_ms)
    {:ok, %CacheEntry{token: strip_bearer(token), expires_at: expires_at}}
  end

  defp parse_token_payload(%{"access_token" => token} = payload, now, default_ttl_ms)
       when is_binary(token) and token != "" do
    expires_at = resolve_expires_at(payload, now, default_ttl_ms)
    {:ok, %CacheEntry{token: strip_bearer(token), expires_at: expires_at}}
  end

  defp parse_token_payload(raw, now, default_ttl_ms) when is_binary(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        {:error, :empty_access_token}

      String.starts_with?(trimmed, "{") ->
        case JSON.decode(trimmed) do
          {:ok, %{} = decoded} -> parse_decoded_json_token(decoded, now, default_ttl_ms)
          _ -> {:error, :invalid_token_payload}
        end

      true ->
        case strip_bearer(trimmed) do
          "" -> {:error, :empty_access_token}
          token -> {:ok, %CacheEntry{token: token, expires_at: now + default_ttl_ms}}
        end
    end
  end

  defp parse_token_payload(_other, _now, _default_ttl_ms) do
    {:error, :invalid_token_payload}
  end

  defp parse_decoded_json_token(%{"access_token" => token} = map, now, default_ttl_ms)
       when is_binary(token) and token != "" do
    {:ok,
     %CacheEntry{
       token: strip_bearer(token),
       expires_at: resolve_expires_at(map, now, default_ttl_ms)
     }}
  end

  defp parse_decoded_json_token(%{"token" => token} = map, now, default_ttl_ms)
       when is_binary(token) and token != "" do
    {:ok,
     %CacheEntry{
       token: strip_bearer(token),
       expires_at: resolve_expires_at(map, now, default_ttl_ms)
     }}
  end

  defp parse_decoded_json_token(_map, _now, _default_ttl_ms), do: {:error, :invalid_token_payload}

  defp resolve_expires_at(payload, now, default_ttl_ms) do
    cond do
      is_integer(payload[:expires_at]) -> payload[:expires_at]
      is_integer(payload["expires_at"]) -> payload["expires_at"]
      is_integer(payload[:expires_in]) -> now + payload[:expires_in] * 1_000
      is_integer(payload["expires_in"]) -> now + payload["expires_in"] * 1_000
      true -> now + default_ttl_ms
    end
  end

  defp strip_bearer(token) do
    trimmed = String.trim(token)

    case Regex.run(~r/^bearer\s+(.+)$/i, trimmed) do
      [_, raw] -> String.trim(raw)
      _ -> trimmed
    end
  end

  defp normalize_provider(:google_vertex), do: {:ok, "google_vertex"}
  defp normalize_provider(:anthropic), do: {:ok, "anthropic"}
  defp normalize_provider(:openai), do: {:ok, "openai"}
  defp normalize_provider(:openrouter), do: {:ok, "openrouter"}
  defp normalize_provider(:deepseek), do: {:ok, "deepseek"}
  defp normalize_provider(:google), do: {:ok, "google"}
  defp normalize_provider(:ollama), do: {:ok, "ollama"}

  defp normalize_provider(name) when is_binary(name) do
    case name do
      "google_vertex" -> {:ok, "google_vertex"}
      "google-vertex" -> {:ok, "google_vertex"}
      "anthropic" -> {:ok, "anthropic"}
      "openai" -> {:ok, "openai"}
      "openrouter" -> {:ok, "openrouter"}
      "deepseek" -> {:ok, "deepseek"}
      "google" -> {:ok, "google"}
      "ollama" -> {:ok, "ollama"}
      _ -> :error
    end
  end

  defp normalize_provider(_other), do: :error

  defp get_env(var, opts) do
    case Keyword.get(opts, :env) do
      %{} = env_map -> Map.get(env_map, var)
      nil -> System.get_env(var)
    end
  end

  defp now_ms(opts) do
    case Keyword.get(opts, :now_fn) do
      fun when is_function(fun, 0) -> fun.()
      _ -> System.system_time(:millisecond)
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  defp sensitive_key?(key) when is_atom(key) or is_binary(key) do
    normalized = key |> to_string() |> String.downcase()

    MapSet.member?(@sensitive_keys, normalized) or
      String.ends_with?(normalized, ["_token", "_key", "_secret", "_password"])
  end

  defp sensitive_key?(_), do: false

  defp sanitize_binary(text) do
    text
    |> String.replace(~r/(Bearer\s+)[A-Za-z0-9._\-\+\/=]+/i, "\\1[REDACTED]")
    |> String.replace(
      ~r/((?:access_token|api_key|token|secret)["']?\s*[:=]\s*["']?)[^\s"',}]+/i,
      "\\1[REDACTED]"
    )
    |> String.replace(~r/\bsk-[A-Za-z0-9._\-]{8,}\b/, "[REDACTED]")
    |> String.replace(~r/\bya29\.[A-Za-z0-9._\-]{8,}\b/, "[REDACTED]")
  end
end
