defmodule H.Provider.ReqLLM do
  @moduledoc """
  `H.Provider` adapter backed by `ReqLLM` and `LLMDB`.

  Streams canonical `ReqLLM.StreamEvent` values into `H.Provider` deltas,
  injects short-lived credentials from `H.Credentials`, ensures
  `ReqLLM.StreamResponse.close/1` runs on completion, cancellation, error, or
  worker exit, and lists catalog models from `LLMDB`.
  """

  @behaviour H.Provider

  alias H.{Context, Credentials}
  alias H.Provider.{CodexModels, Settings, VertexExpress}
  alias ReqLLM.{StreamEvent, StreamResponse}
  alias ReqLLM.StreamResponse.MetadataHandle

  @thinking_efforts %{
    :minimal => :minimal,
    :low => :low,
    :medium => :medium,
    :high => :high,
    :xhigh => :xhigh,
    :max => :max,
    :none => :none,
    :off => :none,
    "minimal" => :minimal,
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "xhigh" => :xhigh,
    "max" => :max,
    "none" => :none,
    "off" => :none
  }

  @default_providers [:openai, :openai_codex, :anthropic, :google_vertex, :google, :deepseek]

  @curated_model_ids %{
    openai: [
      "gpt-5.4",
      "gpt-5.4-mini",
      "gpt-5.3-codex",
      "gpt-5.4-pro",
      "gpt-6.2-sol",
      "gpt-6.2-astra"
    ],
    anthropic: [
      "claude-sonnet-5-5",
      "claude-opus-5-5",
      "claude-haiku-5-5",
      "claude-fable-5-2",
      "claude-sonnet-4-6",
      "claude-opus-4-8"
    ],
    google_vertex: [
      "gemini-4-hydrogen",
      "gemini-4-carbon",
      "gemini-4-argon",
      "gemini-3.8-flash"
    ],
    google: [
      "gemini-4-hydrogen",
      "gemini-4-carbon",
      "gemini-4-argon",
      "gemini-3.8-flash"
    ],
    deepseek: [
      "deepseek-v4-pro",
      "deepseek-flash"
    ]
  }

  @impl H.Provider
  def stream_turn(config, request, emit)
      when is_map(config) and is_map(request) and is_function(emit, 1) do
    model_spec = Map.get(request, :model) || Map.get(request, "model") || Map.get(config, :model)

    config = if Map.has_key?(config, :accounts_mode), do: config, else: attempt_config(config)

    case resolve_model(model_spec) do
      {:ok, %LLMDB.Model{provider: :openai_codex} = model}
      when config.accounts_mode == :managed ->
        managed_codex_turn(config, request, model, emit)

      {:ok, %LLMDB.Model{} = model} ->
        settings = Settings.read(config)
        {req_context, req_tools} = build_req_llm_inputs(request)

        with {:ok, stream_opts} <- build_stream_opts(config, request, model, req_tools, settings),
             {:ok, stream} <- start_stream(config, model, req_context, stream_opts) do
          consume_stream(stream, model, config, emit)
        else
          {:error, reason} -> {:error, normalize_error(reason)}
        end

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  @doc false
  def attempt_config(%{accounts: accounts} = config) do
    mode =
      if config[:codex_account_policy] || H.Accounts.configured?(accounts),
        do: :managed,
        else: :manual

    Map.put(config, :accounts_mode, mode)
  end

  def attempt_config(config), do: Map.put(config, :accounts_mode, :manual)

  defp managed_codex?(%{accounts_mode: :managed}, model),
    do: match?({:ok, %LLMDB.Model{provider: :openai_codex}}, resolve_model(model))

  defp managed_codex?(_, _), do: false

  def dispatch_limit(config, model) do
    config = if Map.has_key?(config, :accounts_mode), do: config, else: attempt_config(config)

    cond do
      not managed_codex?(config, model) -> nil
      config[:codex_account_policy] -> 2
      true -> 1
    end
  end

  defp managed_codex_turn(config, request, model, emit) do
    {context, tools} = build_req_llm_inputs(request)
    context = portable_codex_context(context)
    policy = config[:codex_account_policy]

    dispatch = fn credential ->
      managed_dispatch(config, request, model, context, tools, credential, emit, policy != nil)
    end

    result =
      if policy do
        deadline = System.monotonic_time(:millisecond) + 15_000
        pooled_dispatch(config, policy, model.id, dispatch, deadline, nil)
      else
        with {:ok, credential} <- H.Accounts.resolve_codex(config.accounts),
             do: dispatch.(credential)
      end

    managed_result(result)
  end

  defp pooled_dispatch(config, policy, model, dispatch, deadline, rejected) do
    with {:ok, source, credential} <- policy_credential(config, policy, model, rejected, deadline) do
      # Dispatch owns stream cleanup. Only a typed pre-output auth rejection
      # permits an alternate, and the rejected identity cannot be reused.
      case dispatch.(credential) do
        {:error, :invalid_token} = error ->
          notified = policy_callback(policy.module, :rejected, [model, source, :invalid_token])

          if is_nil(rejected) and notified == :ok do
            pooled_dispatch(
              config,
              policy,
              model,
              dispatch,
              deadline,
              {source, credential.account_id}
            )
          else
            error
          end

        {:error, :rate_limited} = error ->
          policy_callback(policy.module, :rejected, [model, source, :rate_limited])
          error

        result ->
          result
      end
    end
  end

  defp policy_credential(config, policy, model, rejected, deadline) do
    {excluded, excluded_identity} = rejected || {nil, nil}
    candidates = List.delete(policy.sources, excluded)

    case policy_callback(policy.module, :order, [model, candidates]) do
      ordered when is_list(ordered) and length(ordered) <= length(candidates) ->
        if ordered -- candidates == [] do
          Enum.reduce_while(ordered, {:error, :credential_unavailable}, fn source, unavailable ->
            case H.Accounts.resolve_codex(config.accounts, source, deadline) do
              {:ok, %{account_id: ^excluded_identity}} -> {:cont, unavailable}
              {:ok, credential} -> {:halt, {:ok, source, credential}}
              {:error, :credential_unavailable} -> {:cont, unavailable}
              error -> {:halt, error}
            end
          end)
        else
          {:error, :account_policy_unavailable}
        end

      _ ->
        {:error, :account_policy_unavailable}
    end
  end

  defp policy_callback(module, callback, args) do
    apply(module, callback, args)
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp managed_dispatch(config, request, model, context, tools, credential, emit, pooled?) do
    dispatch =
      config
      |> Map.take([:stream_fn, :close_fn, :receive_timeout])
      |> Map.put(:credentials, credential)

    with {:ok, opts} <- build_stream_opts(dispatch, request, model, tools, %{}),
         opts =
           Keyword.update!(
             opts,
             :provider_options,
             &Keyword.merge(&1, openai_stream_transport: :sse, codex_originator: "h")
           ),
         opts = Keyword.put(opts, :base_url, "https://chatgpt.com/backend-api"),
         {:ok, stream} <- start_stream(dispatch, model, context, opts) do
      safe_emit = fn
        %{type: :start} when pooled? -> :ok
        event -> emit.(Map.delete(event, :metadata))
      end

      consume_stream(stream, model, Map.put(dispatch, :managed_codex, true), safe_emit)
    else
      {:error, reason} -> {:error, managed_rejection(reason)}
    end
  end

  # A typed transport HTTP 401 with the explicit invalid_token code is an
  # authentication rejection, not a generic 401 or a stream error string.
  defp managed_rejection(%ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Request{} = request}),
    do: managed_rejection(request)

  defp managed_rejection(%ReqLLM.Error.API.Request{status: 401, provider_code: "invalid_token"}),
    do: :invalid_token

  defp managed_rejection(%ReqLLM.Error.API.Request{status: 429}), do: :rate_limited
  defp managed_rejection(_), do: :codex_request_failed

  defp managed_result({:ok, %{finish_reason: reason} = response})
       when reason in ["stop", "tool_calls", "length", "content_filter"] do
    {:ok,
     response
     |> Map.drop([:provider_meta, :reasoning_details])
     |> Map.update!(
       :content,
       &Enum.map(&1, fn part -> Map.drop(part, [:metadata, :signature]) end)
     )
     |> Map.update!(:tool_calls, &Enum.map(&1, fn call -> Map.delete(call, :metadata) end))}
  end

  defp managed_result({:cancelled, _}), do: {:cancelled, %{}}

  defp managed_result({:error, :credential_unavailable}),
    do: managed_codex_error(:codex_accounts_unavailable)

  defp managed_result({:error, :account_policy_unavailable}),
    do: managed_codex_error(:account_policy_unavailable)

  defp managed_result({:error, reason}) when reason in [:invalid_token, :rate_limited],
    do: managed_codex_error(reason)

  defp managed_result(_), do: managed_codex_error(:codex_request_failed)

  defp portable_codex_context(context) do
    messages =
      Enum.map(context.messages, fn message ->
        content =
          message.content
          |> Enum.reject(&(&1.type in [:thinking, :provider_block]))
          |> Enum.map(&%{&1 | metadata: %{}})

        tool_calls =
          if message.tool_calls do
            Enum.map(message.tool_calls, fn call ->
              %{call | function: Map.drop(call.function, [:metadata, "metadata"])}
            end)
          end

        metadata = Map.take(message.metadata || %{}, [:is_error])

        %{
          message
          | reasoning_details: nil,
            metadata: metadata,
            content: content,
            tool_calls: tool_calls
        }
      end)

    %{context | messages: messages}
  end

  defp managed_codex_error(code) do
    message =
      case code do
        :codex_accounts_unavailable ->
          "No eligible Codex credential is available. Use /login or /account; a configured pool may be waiting for fresh usage data."

        :account_policy_unavailable ->
          "The configured Codex account policy is unavailable."

        :invalid_token ->
          "Codex rejected the credential. Sign in again or switch accounts with /account."

        :rate_limited ->
          "Codex reported a rate limit. The request was not retried on another account."

        :codex_request_failed ->
          "Managed Codex request failed. No further automatic retry was made."
      end

    {:error, %{code: to_string(code), message: message, retryable: false}}
  end

  @impl H.Provider
  def list_models(config) when is_map(config) do
    case Map.get(config, :models) do
      list when is_list(list) ->
        list
        |> Enum.map(&project_model/1)
        |> Enum.sort_by(& &1.id)

      nil ->
        fetch_curated_models(config, Settings.read(config))
    end
  end

  @doc """
  Returns the recommended default model ID (`"provider:model_id"`) for the
  currently configured credentials.
  """
  @spec default_model(map()) :: String.t()
  def default_model(config \\ %{}) when is_map(config) do
    settings = Settings.read(config)

    case Map.get(config, :default_model) || Application.get_env(:harness, :default_model) ||
           settings["default_model"] do
      model when is_binary(model) and model != "" ->
        model

      _ ->
        case Enum.find(list_models(config), &(not Map.has_key?(&1, :unavailable_reason))) do
          %{id: id} -> id
          nil -> "openai:gpt-5.4"
        end
    end
  end

  # Model & Request preparation

  defp resolve_model(nil), do: {:error, {:invalid_model, "model is required"}}

  defp resolve_model("google_vertex:" <> id) do
    case vertex_model(id) do
      %LLMDB.Model{} = model -> ReqLLM.model(model)
      nil -> ReqLLM.model(%{provider: :google_vertex, id: id})
    end
  end

  defp resolve_model("google-vertex:" <> id), do: resolve_model("google_vertex:" <> id)
  defp resolve_model("openai-codex:" <> id), do: resolve_model("openai_codex:" <> id)

  defp resolve_model("openai_codex:" <> id) do
    case Enum.find(CodexModels.list(), &(&1.id == id)) do
      %LLMDB.Model{} = model -> ReqLLM.model(model)
      nil -> ReqLLM.model("openai_codex:" <> id)
    end
  end

  defp resolve_model(model_spec), do: ReqLLM.model(model_spec)

  defp vertex_model(id) do
    lookup_llmdb_model(:google_vertex, id) ||
      case lookup_llmdb_model(:google, id) do
        %LLMDB.Model{} = model ->
          # The Developer API catalog can advertise long-decode limits; H uses
          # ordinary synchronous Vertex streams, not long-decode continuation.
          limits =
            case get_nested(model.extra, [:default_synchronous_output_limit]) do
              n when is_integer(n) and n > 0 -> Map.put(model.limits || %{}, :output, n)
              _ -> model.limits
            end

          %{model | provider: :google_vertex, limits: limits}

        nil ->
          nil
      end
  end

  defp build_req_llm_inputs(request) do
    cond do
      Map.has_key?(request, :messages) or Map.has_key?(request, "messages") ->
        Context.to_req_llm(request)

      match?(%ReqLLM.Context{}, Map.get(request, :context)) ->
        ctx = Map.get(request, :context)
        {ctx, Map.get(request, :tools, ctx.tools || [])}

      true ->
        {ReqLLM.Context.new([]), []}
    end
  end

  defp build_stream_opts(config, request, model, req_tools, settings) do
    receive_timeout =
      Application.get_env(
        :req_llm,
        :stream_receive_timeout,
        Application.get_env(:req_llm, :receive_timeout, 300_000)
      )

    with {:ok, cred_opts} <- resolve_credential_opts(config, model, settings) do
      opts =
        cred_opts
        |> Keyword.put(:receive_timeout, Map.get(config, :receive_timeout, receive_timeout))
        |> Keyword.put(:max_retries, 0)
        |> Keyword.put(:on_unsupported, Map.get(config, :on_unsupported, :ignore))
        |> maybe_put_tools(req_tools)
        |> maybe_put_max_tokens(request)
        |> maybe_put_reasoning_effort(request, config)
        |> merge_user_provider_options(config)
        |> codex_transport(settings, model)

      {:ok, opts}
    end
  end

  defp resolve_credential_opts(config, %LLMDB.Model{provider: provider}, settings) do
    cond do
      is_map(Map.get(config, :credentials)) ->
        {:ok, credentials_to_opts(provider, Map.get(config, :credentials))}

      Map.get(config, :skip_credentials) == true ->
        {:ok, []}

      is_function(Map.get(config, :stream_fn), 3) and
        not Map.has_key?(config, :credentials_opts) and settings == %{} ->
        {:ok, []}

      true ->
        cred_opts = Keyword.put(Map.get(config, :credentials_opts, []), :settings, settings)

        case resolved_credentials(config, provider, cred_opts) do
          {:ok, creds} ->
            {:ok, credentials_to_opts(provider, creds)}

          {:error, {:missing_env, env}} ->
            {:error,
             %{
               code: "missing_provider_credential",
               message:
                 "No #{provider} API key is configured in the daemon credential store or #{env}. Set a key with /key set #{provider} <alias> or in Phoenix Account settings, then /continue.",
               retryable: false
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp resolved_credentials(config, provider, opts) do
    if config[:accounts] && not Keyword.has_key?(opts, :api_key) &&
         Credentials.api_key_provider?(Atom.to_string(provider)) do
      case H.Accounts.resolve_api_key(config.accounts, provider) do
        :not_configured -> Credentials.resolve(provider, opts)
        result -> result
      end
    else
      Credentials.resolve(provider, opts)
    end
  end

  defp credentials_to_opts(:google_vertex, %{
         access_token: token,
         project_id: project,
         region: region
       }) do
    [provider_options: [access_token: token, project_id: project, region: region]]
  end

  defp credentials_to_opts(:openai_codex, %{access_token: token} = creds) do
    opts = [auth_mode: :oauth, access_token: token]

    opts =
      case Map.get(creds, :account_id) do
        id when is_binary(id) and id != "" -> Keyword.put(opts, :chatgpt_account_id, id)
        _ -> opts
      end

    [provider_options: opts]
  end

  defp credentials_to_opts(_provider, %{auth_mode: :none}), do: []
  defp credentials_to_opts(_provider, %{api_key: key}) when is_binary(key), do: [api_key: key]
  defp credentials_to_opts(_provider, _creds), do: []

  defp maybe_put_tools(opts, []), do: opts
  defp maybe_put_tools(opts, tools), do: Keyword.put(opts, :tools, tools)

  defp maybe_put_max_tokens(opts, request) do
    case Map.get(request, :max_tokens) || Map.get(request, "max_tokens") do
      n when is_integer(n) and n > 0 -> Keyword.put(opts, :max_tokens, n)
      _ -> opts
    end
  end

  defp maybe_put_reasoning_effort(opts, request, config) do
    thinking =
      Map.get(request, :thinking) || Map.get(request, "thinking") || Map.get(config, :thinking)

    effort =
      case thinking do
        %{} = map -> Map.get(map, :effort) || Map.get(map, "effort")
        other -> other
      end

    case Map.get(@thinking_efforts, effort) do
      nil -> opts
      atom -> Keyword.put(opts, :reasoning_effort, atom)
    end
  end

  defp merge_user_provider_options(opts, config) do
    case Map.get(config, :provider_options) do
      extra when is_list(extra) and extra != [] ->
        existing = Keyword.get(opts, :provider_options, [])

        Keyword.put(opts, :provider_options, Keyword.merge(extra, existing))

      _ ->
        opts
    end
  end

  defp codex_transport(opts, settings, %LLMDB.Model{provider: :openai_codex}) do
    provider_opts = Keyword.get(opts, :provider_options, [])

    if Keyword.has_key?(provider_opts, :openai_stream_transport) do
      opts
    else
      case settings do
        %{"openai_codex" => %{"transport" => "websocket"}} ->
          Keyword.put(opts, :provider_options, [
            {:openai_stream_transport, :websocket} | provider_opts
          ])

        _ ->
          opts
      end
    end
  end

  defp codex_transport(opts, _settings, _model), do: opts

  defp start_stream(config, model, req_context, stream_opts) do
    result =
      case config do
        %{stream_fn: fun} -> fun.(model, req_context, stream_opts)
        _ -> provider_stream(model, req_context, stream_opts)
      end

    case result do
      {:ok, _stream_or_resp} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_stream_result, other}}
    end
  rescue
    exception ->
      {:error, exception}
  end

  defp provider_stream(%LLMDB.Model{provider: :google_vertex} = model, context, opts) do
    cond do
      not Keyword.has_key?(opts, :api_key) ->
        ReqLLM.stream_text(model, context, opts)

      String.starts_with?(model.provider_model_id || model.id, "gemini-") ->
        VertexExpress.stream(model, context, opts)

      true ->
        {:error, "Vertex API keys are supported for Gemini models only"}
    end
  end

  defp provider_stream(model, context, opts), do: ReqLLM.stream_text(model, context, opts)

  # Stream consumption & cleanup

  defp consume_stream(%StreamResponse{} = stream_resp, model, config, emit) do
    parent = self()
    watcher_ref = make_ref()

    watcher =
      spawn(fn ->
        mon = Process.monitor(parent)
        send(parent, {:watcher_armed, watcher_ref})

        receive do
          {:done, ^watcher_ref} ->
            Process.demonitor(mon, [:flush])
            :ok

          {:DOWN, ^mon, :process, ^parent, _reason} ->
            receive do
              {:done, ^watcher_ref} -> :ok
            after
              0 -> safe_close_stream(stream_resp)
            end
        end
      end)

    receive do
      {:watcher_armed, ^watcher_ref} -> :ok
    end

    try do
      result =
        run_event_loop(
          StreamResponse.events(stream_resp),
          model,
          emit,
          config[:managed_codex] == true
        )

      case result do
        {:ok, response}
        when model.provider == :openai_codex and not is_map_key(config, :managed_codex) ->
          case MetadataHandle.await(stream_resp.metadata_handle) do
            %{reasoning_details: [_ | _] = details} ->
              {:ok, Map.put(response, :reasoning_details, Credentials.sanitize(details))}

            _ ->
              result
          end

        _ ->
          result
      end
    after
      send(watcher, {:done, watcher_ref})
      safe_close_stream(stream_resp)
    end
  end

  defp consume_stream(event_stream, model, config, emit) do
    try do
      run_event_loop(event_stream, model, emit, config[:managed_codex] == true)
    after
      case Map.get(config, :close_fn) do
        fun when is_function(fun, 0) -> fun.()
        _ -> :ok
      end
    end
  end

  defp safe_close_stream(%StreamResponse{} = stream_resp) do
    StreamResponse.close(stream_resp)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp run_event_loop(events, model, emit, require_terminal) do
    init = %{
      model: model,
      blocks: [],
      current_block: nil,
      tool_calls: [],
      tool_index_map: %{},
      usage: %{},
      finish_reason: "stop",
      provider_meta: %{},
      terminal: nil,
      managed_codex: require_terminal,
      observed?: false
    }

    acc =
      Enum.reduce_while(events, init, fn %StreamEvent{} = event, acc ->
        acc = if event.type in [:start, :error], do: acc, else: %{acc | observed?: true}

        case handle_event(event, acc, emit) do
          {:halt, final_acc} -> {:halt, final_acc}
          {:cont, next_acc} -> {:cont, next_acc}
        end
      end)

    if require_terminal and is_nil(acc.terminal),
      do: {:error, :missing_terminal_event},
      else: finalize_stream_acc(acc)
  end

  defp handle_event(%StreamEvent{type: :start, data: data}, acc, emit) do
    provider = get_nested(data, [:model, :provider]) || acc.model.provider
    model_id = get_nested(data, [:model, :id]) || acc.model.id

    emit.(%{
      type: :start,
      provider: to_string(provider),
      model: to_string(model_id)
    })

    {:cont, acc}
  end

  defp handle_event(%StreamEvent{type: :reasoning_delta, data: data, metadata: meta}, acc, emit) do
    text = if is_binary(data), do: data, else: ""
    meta = safe_event_meta(meta)

    emit.(%{type: :thinking_delta, text: text, metadata: meta})
    {:cont, append_thinking_delta(acc, text, meta)}
  end

  defp handle_event(%StreamEvent{type: :text_delta, data: data, metadata: meta}, acc, emit) do
    text = if is_binary(data), do: data, else: ""
    meta = safe_event_meta(meta)

    emit.(%{type: :text_delta, text: text, metadata: meta})
    {:cont, append_text_delta(acc, text, meta)}
  end

  defp handle_event(%StreamEvent{type: :tool_call_start, data: data}, acc, emit)
       when is_map(data) do
    index = Map.get(data, :index) || Map.get(data, "index") || 0
    id = Map.get(data, :id) || Map.get(data, "id") || "call_#{index}"
    name = Map.get(data, :name) || Map.get(data, "name")

    tool_index_map = Map.put(acc.tool_index_map, index, %{id: id, name: name})
    emit.(%{type: :tool_call_delta, id: id, name: name, args_delta: ""})
    {:cont, %{acc | tool_index_map: tool_index_map}}
  end

  defp handle_event(%StreamEvent{type: :tool_call_delta, data: data}, acc, emit)
       when is_map(data) do
    index = Map.get(data, :index) || Map.get(data, "index") || 0
    known = Map.get(acc.tool_index_map, index, %{})

    id = Map.get(data, :id) || Map.get(data, "id") || Map.get(known, :id) || "call_#{index}"
    name = Map.get(data, :name) || Map.get(data, "name") || Map.get(known, :name)

    args_delta =
      Map.get(data, :fragment) ||
        Map.get(data, "fragment") ||
        Map.get(data, :args_delta) ||
        Map.get(data, "args_delta") ||
        ""

    emit.(%{type: :tool_call_delta, id: id, name: name, args_delta: args_delta})
    {:cont, acc}
  end

  defp handle_event(%StreamEvent{type: :tool_call, data: data}, acc, _emit) when is_map(data) do
    tool_call =
      %{
        id: Map.get(data, :id) || Map.get(data, "id"),
        name: Map.get(data, :name) || Map.get(data, "name"),
        arguments: normalize_arguments(Map.get(data, :arguments) || Map.get(data, "arguments"))
      }
      |> maybe_put_tool_metadata(Map.get(data, :metadata) || Map.get(data, "metadata"))

    {:cont, %{acc | tool_calls: [tool_call | acc.tool_calls]}}
  end

  defp handle_event(%StreamEvent{type: :usage, data: usage}, acc, emit) when is_map(usage) do
    normalized = usage |> Credentials.sanitize() |> compact_usage()
    emit.(%{type: :usage, usage: normalized})
    {:cont, %{acc | usage: normalized}}
  end

  defp handle_event(%StreamEvent{type: :provider_event, data: data}, acc, _emit) do
    provider_meta =
      case data do
        %{} = map ->
          acc.provider_meta
          |> Map.merge(Credentials.sanitize(map))
          |> compact_provider_meta()

        _ ->
          acc.provider_meta
      end

    {:cont, %{acc | provider_meta: provider_meta}}
  end

  defp handle_event(%StreamEvent{type: :finish, data: data, metadata: meta}, acc, _emit) do
    finish_reason = normalize_finish_reason(data)

    provider_meta =
      acc.provider_meta
      |> Map.merge(safe_event_meta(meta))
      |> compact_provider_meta()

    {:halt, %{acc | finish_reason: finish_reason, provider_meta: provider_meta, terminal: :ok}}
  end

  defp handle_event(%StreamEvent{type: :cancelled}, acc, _emit) do
    {:halt, %{acc | terminal: :cancelled}}
  end

  defp handle_event(%StreamEvent{type: :error, data: error}, acc, _emit) do
    error =
      case acc do
        %{managed_codex: true, observed?: false} -> managed_rejection(error)
        %{managed_codex: true} -> :codex_request_failed
        _ -> normalize_error(error)
      end

    {:halt, %{acc | terminal: {:error, error}}}
  end

  defp handle_event(%StreamEvent{}, acc, _emit), do: {:cont, acc}

  defp finalize_stream_acc(acc) do
    content = flush_current_block(acc) |> Enum.reverse()
    tool_calls = Enum.reverse(acc.tool_calls)

    case acc.terminal do
      {:error, error_reason} ->
        {:error, error_reason}

      :cancelled ->
        {:cancelled, %{partial_content: content, usage: acc.usage}}

      _ ->
        {:ok,
         %{
           content: content,
           tool_calls: tool_calls,
           finish_reason: acc.finish_reason,
           usage: acc.usage,
           provider_meta: acc.provider_meta
         }}
    end
  end

  # Content block accumulation

  defp append_thinking_delta(acc, text, meta) do
    sig = extract_signature(meta)

    case acc.current_block do
      %{type: "thinking", chunks: chunks} = block ->
        updated_meta = merge_block_meta(block.metadata, meta)
        updated_sig = block.signature || sig

        %{
          acc
          | current_block: %{
              block
              | chunks: [text | chunks],
                signature: updated_sig,
                metadata: updated_meta
            }
        }

      _other ->
        blocks = flush_current_block(acc)

        new_block = %{
          type: "thinking",
          chunks: [text],
          signature: sig,
          metadata: meta
        }

        %{acc | blocks: blocks, current_block: new_block}
    end
  end

  defp append_text_delta(acc, text, meta) do
    case acc.current_block do
      %{type: "text", chunks: chunks} = block ->
        updated_meta = merge_block_meta(block.metadata, meta)
        %{acc | current_block: %{block | chunks: [text | chunks], metadata: updated_meta}}

      _other ->
        blocks = flush_current_block(acc)
        new_block = %{type: "text", chunks: [text], metadata: meta}
        %{acc | blocks: blocks, current_block: new_block}
    end
  end

  defp flush_current_block(%{current_block: nil, blocks: blocks}), do: blocks

  defp flush_current_block(%{current_block: %{type: "thinking"} = block, blocks: blocks}) do
    text = block.chunks |> Enum.reverse() |> IO.iodata_to_binary()

    part =
      %{type: "thinking", text: text}
      |> maybe_put_non_nil(:signature, block.signature)
      |> maybe_put_non_empty_map(:metadata, block.metadata)

    [part | blocks]
  end

  defp flush_current_block(%{current_block: %{type: "text"} = block, blocks: blocks}) do
    text = block.chunks |> Enum.reverse() |> IO.iodata_to_binary()

    part =
      %{type: "text", text: text}
      |> maybe_put_non_empty_map(:metadata, block.metadata)

    [part | blocks]
  end

  # Model catalog listing

  defp fetch_curated_models(config, settings) do
    config
    |> resolve_target_providers(settings)
    |> Enum.flat_map(&curated_models_for_provider/1)
    |> Enum.map(fn
      %{provider: "openai_codex"} = model ->
        managed =
          config[:codex_account_policy] ||
            (config[:accounts] && H.Accounts.configured?(config.accounts))

        ready =
          if managed do
            H.Accounts.codex_ready?(
              config[:accounts],
              get_in(config, [:codex_account_policy, :sources])
            )
          else
            Credentials.configured?(
              :openai_codex,
              Keyword.put(Map.get(config, :credentials_opts, []), :settings, settings)
            )
          end

        if ready,
          do: model,
          else: Map.put(model, :unavailable_reason, "Codex sign-in required (/login)")

      model ->
        model
    end)
  end

  defp resolve_target_providers(config, settings) do
    case Map.get(config, :provider) do
      nil ->
        cred_opts = Keyword.put(Map.get(config, :credentials_opts, []), :settings, settings)

        stored = if config[:accounts], do: H.Accounts.key_providers(config.accounts), else: []
        stored = if is_list(stored), do: Enum.map(stored, &normalize_provider_name/1), else: []
        configured = Enum.uniq(Credentials.configured_providers(cred_opts) ++ stored)

        cond do
          config[:codex_account_policy] ||
              (config[:accounts] && H.Accounts.configured?(config.accounts)) ->
            Enum.uniq([:openai_codex | configured])

          configured == [] ->
            @default_providers

          true ->
            configured
        end

      provider when is_atom(provider) ->
        [provider]

      provider when is_binary(provider) ->
        case normalize_provider_name(provider) do
          nil -> []
          atom -> [atom]
        end
    end
  end

  defp normalize_provider_name("openai-codex"), do: :openai_codex
  defp normalize_provider_name("openai"), do: :openai
  defp normalize_provider_name("anthropic"), do: :anthropic
  defp normalize_provider_name("google_vertex"), do: :google_vertex
  defp normalize_provider_name("google-vertex"), do: :google_vertex
  defp normalize_provider_name("google"), do: :google
  defp normalize_provider_name("deepseek"), do: :deepseek
  defp normalize_provider_name("openrouter"), do: :openrouter
  defp normalize_provider_name("ollama"), do: :ollama

  defp normalize_provider_name(other) when is_binary(other) do
    Enum.find(@default_providers, &(Atom.to_string(&1) == other))
  end

  defp curated_models_for_provider(:openai_codex) do
    Enum.map(CodexModels.list(), &project_model/1)
  end

  defp curated_models_for_provider(provider) do
    case Map.get(@curated_model_ids, provider) do
      ids when is_list(ids) ->
        ids
        |> Enum.flat_map(fn id ->
          model =
            if provider == :google_vertex,
              do: vertex_model(id),
              else: lookup_llmdb_model(provider, id)

          case model do
            %LLMDB.Model{} = m -> [project_model(m)]
            nil -> []
          end
        end)

      nil ->
        provider
        |> LLMDB.models()
        |> Enum.filter(&active_tool_chat_model?/1)
        |> Enum.sort_by(&{&1.release_date || "", &1.id}, :desc)
        |> Enum.take(10)
        |> Enum.map(&project_model/1)
    end
  end

  defp lookup_llmdb_model(provider, id) when is_atom(provider) and is_binary(id) do
    case LLMDB.model(provider, id) do
      {:ok, %LLMDB.Model{} = model} -> model
      _ -> Enum.find(LLMDB.models(provider), &(&1.id == id))
    end
  end

  defp active_tool_chat_model?(%LLMDB.Model{} = m) do
    caps = m.capabilities || %{}
    out_mod = get_nested(m.modalities, [:output])

    get_nested(caps, [:tools, :enabled]) == true and
      Map.get(caps, :chat) == true and
      m.deprecated != true and
      m.retired != true and
      (out_mod == [:text] or is_nil(out_mod))
  end

  defp project_model(%LLMDB.Model{} = model) do
    %{
      id: "#{model.provider}:#{model.id}",
      provider: Atom.to_string(model.provider),
      name: model.name || model.id,
      context_window: get_nested(model.limits, [:context]),
      max_output_tokens: get_nested(model.limits, [:output]),
      supports_tools: get_nested(model.capabilities, [:tools, :enabled]) == true,
      supports_reasoning: get_nested(model.capabilities, [:reasoning, :enabled]) == true
    }
  end

  # Error & value normalization

  defp normalize_error(%{code: code, message: message, retryable: retryable}) do
    %{
      code: to_string(code),
      message: Credentials.sanitize(to_string(message)),
      retryable: retryable == true
    }
  end

  defp normalize_error(%{"code" => code, "message" => message} = err) do
    %{
      code: to_string(code),
      message: Credentials.sanitize(to_string(message)),
      retryable: Map.get(err, "retryable", false) == true
    }
  end

  defp normalize_error(%ReqLLM.Error.API.Request{status: status, provider_code: pcode} = err) do
    %{
      code: to_string(pcode || (status && "http_#{status}") || "api_request_error"),
      message: Credentials.sanitize(Exception.message(err)),
      retryable: if(is_boolean(err.retryable), do: err.retryable, else: retryable_status?(status))
    }
  end

  defp normalize_error(%ReqLLM.Error.API.Response{status: status} = err) do
    %{
      code: to_string((status && "http_#{status}") || "api_response_error"),
      message: Credentials.sanitize(Exception.message(err)),
      retryable: retryable_status?(status)
    }
  end

  defp normalize_error(%ReqLLM.Error.API.Stream{cause: cause})
       when cause == :timeout or cause == :recv_timeout do
    %{
      code: "provider_timeout",
      message: "Timed out waiting for the provider stream",
      retryable: true
    }
  end

  defp normalize_error(%ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Timeout{} = timeout}),
    do: normalize_error(timeout)

  defp normalize_error(%ReqLLM.Error.API.Timeout{kind: kind} = err) do
    %{
      code: "provider_timeout",
      message: Exception.message(err),
      retryable: kind in [:connect, :receive, :stream_idle]
    }
  end

  defp normalize_error(err) when is_exception(err) do
    %{
      code: "provider_error",
      message: Credentials.sanitize(Exception.message(err)),
      retryable: false
    }
  end

  defp normalize_error(%{finish_reason: reason}) do
    %{
      code: to_string(reason),
      message: "Stream ended with #{reason}",
      retryable: false
    }
  end

  defp normalize_error(reason) when is_binary(reason) do
    %{
      code: "provider_error",
      message: Credentials.sanitize(reason),
      retryable: false
    }
  end

  defp normalize_error(reason) do
    %{
      code: "provider_error",
      message: reason |> inspect() |> Credentials.sanitize(),
      retryable: false
    }
  end

  defp retryable_status?(status) when status in [408, 429, 500, 502, 503, 504], do: true
  defp retryable_status?(_), do: false

  defp normalize_finish_reason(%{finish_reason: reason}) when not is_nil(reason),
    do: to_string(reason)

  defp normalize_finish_reason(%{"finish_reason" => reason}) when not is_nil(reason),
    do: to_string(reason)

  defp normalize_finish_reason(_), do: "stop"

  defp normalize_arguments(args) when is_map(args), do: args

  defp normalize_arguments(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp normalize_arguments(_), do: %{}

  defp maybe_put_tool_metadata(tc, %{} = meta) when map_size(meta) > 0 do
    Map.put(tc, :metadata, Credentials.sanitize(meta))
  end

  defp maybe_put_tool_metadata(tc, _), do: tc

  defp extract_signature(meta) when is_map(meta) do
    Map.get(meta, :signature) ||
      Map.get(meta, "signature") ||
      Map.get(meta, :thought_signature) ||
      Map.get(meta, "thought_signature")
  end

  defp extract_signature(_), do: nil

  defp safe_event_meta(meta) when is_map(meta), do: Credentials.sanitize(meta)
  defp safe_event_meta(_), do: %{}

  defp compact_provider_meta(meta) when is_map(meta) do
    meta
    |> Map.drop([
      :provider_meta,
      "provider_meta",
      :tools,
      "tools",
      :tool_usage,
      "tool_usage",
      :input_transformations,
      "input_transformations"
    ])
  end

  defp compact_provider_meta(other), do: other

  defp compact_usage(usage) when is_map(usage) do
    case Map.get(usage, :cost) || Map.get(usage, "cost") do
      %{} = cost_map ->
        cleaned_cost = Map.drop(cost_map, [:line_items, "line_items"])

        if Map.has_key?(usage, :cost) do
          Map.put(usage, :cost, cleaned_cost)
        else
          Map.put(usage, "cost", cleaned_cost)
        end

      _ ->
        usage
    end
  end

  defp compact_usage(other), do: other

  defp merge_block_meta(left, right) when map_size(right) == 0, do: left
  defp merge_block_meta(left, right), do: Map.merge(left, right)

  defp maybe_put_non_nil(map, _key, nil), do: map
  defp maybe_put_non_nil(map, key, val), do: Map.put(map, key, val)

  defp maybe_put_non_empty_map(map, _key, %{} = val) when map_size(val) == 0, do: map
  defp maybe_put_non_empty_map(map, key, %{} = val), do: Map.put(map, key, val)

  defp get_nested(nil, _keys), do: nil
  defp get_nested(val, []), do: val

  defp get_nested(map, [key | rest]) when is_map(map) do
    next = Map.get(map, key) || Map.get(map, Atom.to_string(key))
    get_nested(next, rest)
  end

  defp get_nested(_, _), do: nil
end
