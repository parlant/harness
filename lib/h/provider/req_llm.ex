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
  alias H.Provider.{Compatible, ReqLLM.Catalog, ReqLLM.CodexPool, ReqLLM.CompatibleChat}
  alias H.Provider.{Settings, VertexExpress}
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

  @impl H.Provider
  def stream_turn(config, request, emit)
      when is_map(config) and is_map(request) and is_function(emit, 1) do
    model_spec = Map.get(request, :model) || Map.get(request, "model") || Map.get(config, :model)

    config = if Map.has_key?(config, :accounts_mode), do: config, else: attempt_config(config)

    case Compatible.provider_for_model(config[:compatible_providers] || %{}, model_spec) do
      {id, provider, model_id} -> stream_compatible(config, request, id, provider, model_id, emit)
      nil -> stream_stock(config, request, model_spec, emit)
    end
  end

  defp stream_stock(config, request, model_spec, emit) do
    case Catalog.resolve_model(model_spec) do
      {:ok, %LLMDB.Model{provider: :openai_codex} = model}
      when config.accounts_mode == :managed ->
        CodexPool.stream_turn(config, request, model, emit, %{
          build_inputs: &build_req_llm_inputs/1,
          build_stream_opts: &build_stream_opts/5,
          start_stream: &start_stream/4,
          consume_stream: &consume_stream/4
        })

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

  defp stream_compatible(config, request, id, provider, model_id, emit) do
    with %LLMDB.Model{} = model <- provider.models[model_id] || :unknown_model,
         {:ok, %{api_key: key}} <- H.Accounts.resolve_api_key(config[:accounts], id) do
      {context, tools} = build_req_llm_inputs(request)
      limit = model.limits.output

      opts =
        [
          named_key: %Credentials.Redacted{value: key},
          base_url: provider.base_url,
          receive_timeout: receive_timeout(config)
        ]
        |> maybe_put_tools(tools)
        |> maybe_put_max_tokens(request)
        |> Keyword.update(:max_tokens, limit, &min(&1, limit))

      opts =
        if model.capabilities.reasoning.enabled,
          do: maybe_put_reasoning_effort(opts, request, config),
          else: opts

      with {:ok, stream} <- CompatibleChat.stream(model, context, opts) do
        # The fixed codec tag is never the public provider or billing identity.
        consume_stream(stream, model, config, fn
          %{type: :start} = event -> emit.(%{event | provider: id, model: model_id})
          event -> emit.(event)
        end)
      else
        {:error, _} -> {:error, normalize_error(:chat_stream_failed)}
      end
    else
      :unknown_model ->
        {:error,
         %{
           code: "invalid_model",
           message: "Model is not registered for this provider",
           retryable: false
         }}

      :not_configured ->
        {:error,
         %{
           code: "missing_provider_credential",
           message: "No daemon key for #{id}. Use /key set #{id} <alias>, then /continue.",
           retryable: false
         }}

      {:error, _} ->
        {:error,
         %{
           code: "provider_credentials_unavailable",
           message: "Daemon credential store unavailable",
           retryable: false
         }}
    end
  end

  @impl H.Provider
  def list_models(config) when is_map(config), do: Catalog.list_models(config)

  @doc """
  Returns the recommended default model ID (`"provider:model_id"`) for the
  currently configured credentials.
  """
  @spec default_model(map()) :: String.t()
  def default_model(config \\ %{}) when is_map(config), do: Catalog.default_model(config)

  @doc false
  def context_window(model_spec, config \\ %{}), do: Catalog.context_window(model_spec, config)

  @doc false
  def attempt_config(config), do: CodexPool.attempt_config(config)

  @doc false
  def dispatch_limit(config, model) do
    if Compatible.provider_for_model(config[:compatible_providers] || %{}, model),
      do: 1,
      else: CodexPool.dispatch_limit(config, model)
  end

  # Request & stream option preparation

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

  defp receive_timeout(config) do
    Map.get_lazy(config, :receive_timeout, fn ->
      Application.get_env(
        :req_llm,
        :stream_receive_timeout,
        Application.get_env(:req_llm, :receive_timeout, 300_000)
      )
    end)
  end

  defp build_stream_opts(config, request, model, req_tools, settings) do
    with {:ok, cred_opts} <- resolve_credential_opts(config, model, settings) do
      opts =
        cred_opts
        |> Keyword.put(:receive_timeout, receive_timeout(config))
        |> Keyword.put(:max_retries, 0)
        |> Keyword.put(:on_unsupported, Map.get(config, :on_unsupported, :ignore))
        |> maybe_put_tools(req_tools)
        |> maybe_put_max_tokens(request)
        |> maybe_put_reasoning_effort(request, config)
        |> merge_user_provider_options(config)
        |> gemini_thinking_level(model)
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

  # ReqLLM 1.30 clamps Gemini reasoning_effort :xhigh/:max to :high, whereas
  # Gemini 4 Neon and Hydrogen support thinkingLevel "xhigh" natively.
  defp gemini_thinking_level(opts, %LLMDB.Model{provider: provider} = model)
       when provider in [:google, :google_vertex] do
    effort = Keyword.get(opts, :reasoning_effort)
    provider_opts = Keyword.get(opts, :provider_options, [])

    if effort in [:xhigh, :max] and not Keyword.has_key?(provider_opts, :google_thinking_level) and
         not Keyword.has_key?(provider_opts, :google_thinking_budget) and
         gemini_supports_effort?(model, "xhigh") do
      opts
      |> Keyword.delete(:reasoning_effort)
      |> Keyword.put(:provider_options, [{:google_thinking_level, "xhigh"} | provider_opts])
    else
      opts
    end
  end

  defp gemini_thinking_level(opts, _model), do: opts

  defp gemini_supports_effort?(%LLMDB.Model{capabilities: caps}, level) do
    values = Catalog.get_nested(caps, [:reasoning, :effort, :values]) || []
    Enum.any?(values, &(to_string(&1) == level))
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
    provider = Catalog.get_nested(data, [:model, :provider]) || acc.model.provider
    model_id = Catalog.get_nested(data, [:model, :id]) || acc.model.id

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
        %{managed_codex: true, observed?: false} -> CodexPool.rejection(error)
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

  # Error & value normalization

  defp normalize_error(%ReqLLM.Error.API.Stream{cause: {:compatible_http_status, status}}) do
    %{code: "http_#{status}", message: "Model router returned HTTP #{status}", retryable: false}
  end

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
    http_error(
      status,
      pcode,
      if(status == 429, do: err.reason || Exception.message(err), else: Exception.message(err)),
      if(is_boolean(err.retryable), do: err.retryable, else: retryable_status?(status)),
      err.headers
    )
  end

  defp normalize_error(%ReqLLM.Error.API.Response{status: status} = err) do
    code = if status, do: "http_#{status}", else: "api_response_error"
    http_error(status, code, Exception.message(err), retryable_status?(status), [])
  end

  defp normalize_error(%ReqLLM.Error.API.Stream{cause: cause})
       when cause == :timeout or cause == :recv_timeout do
    %{
      code: "provider_timeout",
      message: "Timed out waiting for the provider stream",
      retryable: true
    }
  end

  # The stream wrapper's message can inspect the entire HTTP exception, including
  # response headers. Use only the same normalized fields as a direct failure.
  defp normalize_error(%ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Request{} = request}),
    do: normalize_error(request)

  defp normalize_error(%ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Response{} = response}),
    do: normalize_error(response)

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

  defp http_error(status, provider_code, message, retryable, headers) do
    message = Credentials.sanitize(to_string(message))

    message =
      if status == 429 do
        "HTTP 429: provider rate limit or quota restriction. " <>
          message <>
          " Automatic retries use increasing waits. If a spending cap or quota is exhausted, raise the applicable limit, wait for its reset, or switch provider/project; retries cannot remove the restriction."
      else
        message
      end

    error = %{
      code: to_string(provider_code || (status && "http_#{status}") || "api_request_error"),
      message: message,
      retryable: status == 429 or retryable
    }

    case retry_after_ms(headers) do
      nil -> error
      delay -> Map.put(error, :retry_after_ms, delay)
    end
  end

  defp retry_after_ms(headers) do
    case Req.Response.get_retry_after(Req.Response.new(headers: headers || [])) do
      milliseconds when is_integer(milliseconds) and milliseconds >= 0 ->
        min(milliseconds, 86_400_000)

      _ ->
        nil
    end
  rescue
    _ -> nil
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
end
