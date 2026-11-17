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
  alias ReqLLM.{StreamEvent, StreamResponse}

  @thinking_efforts %{
    :minimal => :minimal,
    :low => :low,
    :medium => :medium,
    :high => :high,
    :max => :max,
    :none => :none,
    :off => :none,
    "minimal" => :minimal,
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "max" => :max,
    "none" => :none,
    "off" => :none
  }

  @impl H.Provider
  def stream_turn(config, request, emit)
      when is_map(config) and is_map(request) and is_function(emit, 1) do
    model_spec = Map.get(request, :model) || Map.get(request, "model") || Map.get(config, :model)

    with {:ok, %LLMDB.Model{} = model} <- resolve_model(model_spec),
         {req_context, req_tools} <- build_req_llm_inputs(request),
         {:ok, stream_opts} <- build_stream_opts(config, request, model, req_tools),
         {:ok, stream_or_resp} <- start_stream(config, model, req_context, stream_opts) do
      consume_stream(stream_or_resp, model, config, emit)
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl H.Provider
  def list_models(config) when is_map(config) do
    models =
      case Map.get(config, :models) do
        list when is_list(list) -> list
        nil -> fetch_llmdb_models(config)
      end

    models
    |> Enum.map(&project_model/1)
    |> Enum.sort_by(& &1.id)
  end

  # Model & Request preparation

  defp resolve_model(nil), do: {:error, {:invalid_model, "model is required"}}

  defp resolve_model(model_spec) do
    ReqLLM.model(model_spec)
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

  defp build_stream_opts(config, request, model, req_tools) do
    with {:ok, cred_opts} <- resolve_credential_opts(config, model) do
      opts =
        cred_opts
        |> maybe_put_tools(req_tools)
        |> maybe_put_max_tokens(request)
        |> maybe_put_reasoning_effort(request, config)
        |> merge_user_provider_options(config)

      {:ok, opts}
    end
  end

  defp resolve_credential_opts(config, %LLMDB.Model{provider: provider}) do
    cond do
      is_map(Map.get(config, :credentials)) ->
        {:ok, credentials_to_opts(provider, Map.get(config, :credentials))}

      Map.get(config, :skip_credentials) == true ->
        {:ok, []}

      is_function(Map.get(config, :stream_fn), 3) and not Map.has_key?(config, :credentials_opts) ->
        case Credentials.resolve(provider, []) do
          {:ok, creds} -> {:ok, credentials_to_opts(provider, creds)}
          {:error, _} -> {:ok, []}
        end

      true ->
        cred_opts = Map.get(config, :credentials_opts, [])

        case Credentials.resolve(provider, cred_opts) do
          {:ok, creds} -> {:ok, credentials_to_opts(provider, creds)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp credentials_to_opts(:google_vertex, %{
         access_token: token,
         project_id: project,
         region: region
       }) do
    [provider_options: [access_token: token, project_id: project, region: region]]
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

  defp start_stream(config, model, req_context, stream_opts) do
    stream_fn = Map.get(config, :stream_fn, &ReqLLM.stream_text/3)

    case stream_fn.(model, req_context, stream_opts) do
      {:ok, _stream_or_resp} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_stream_result, other}}
    end
  rescue
    exception ->
      {:error, exception}
  end

  # Stream consumption & cleanup

  defp consume_stream(%StreamResponse{} = stream_resp, model, _config, emit) do
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
      stream_resp
      |> StreamResponse.events()
      |> run_event_loop(model, emit)
    after
      send(watcher, {:done, watcher_ref})
      safe_close_stream(stream_resp)
    end
  end

  defp consume_stream(event_stream, model, config, emit) do
    try do
      run_event_loop(event_stream, model, emit)
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

  defp run_event_loop(events, model, emit) do
    init = %{
      model: model,
      blocks: [],
      current_block: nil,
      tool_calls: [],
      tool_index_map: %{},
      usage: %{},
      finish_reason: "stop",
      provider_meta: %{},
      terminal: nil
    }

    acc =
      Enum.reduce_while(events, init, fn %StreamEvent{} = event, acc ->
        case handle_event(event, acc, emit) do
          {:halt, final_acc} -> {:halt, final_acc}
          {:cont, next_acc} -> {:cont, next_acc}
        end
      end)

    finalize_stream_acc(acc)
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
    normalized = Credentials.sanitize(usage)
    emit.(%{type: :usage, usage: normalized})
    {:cont, %{acc | usage: normalized}}
  end

  defp handle_event(%StreamEvent{type: :provider_event, data: data}, acc, _emit) do
    provider_meta =
      case data do
        %{} = map -> Map.merge(acc.provider_meta, Credentials.sanitize(map))
        _ -> acc.provider_meta
      end

    {:cont, %{acc | provider_meta: provider_meta}}
  end

  defp handle_event(%StreamEvent{type: :finish, data: data, metadata: meta}, acc, _emit) do
    finish_reason = normalize_finish_reason(data)

    provider_meta =
      acc.provider_meta
      |> Map.merge(safe_event_meta(meta))

    {:halt, %{acc | finish_reason: finish_reason, provider_meta: provider_meta, terminal: :ok}}
  end

  defp handle_event(%StreamEvent{type: :cancelled}, acc, _emit) do
    {:halt, %{acc | terminal: :cancelled}}
  end

  defp handle_event(%StreamEvent{type: :error, data: error}, acc, _emit) do
    {:halt, %{acc | terminal: {:error, normalize_error(error)}}}
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

  defp fetch_llmdb_models(config) do
    case Map.get(config, :provider) do
      nil ->
        LLMDB.models()

      provider when is_atom(provider) ->
        LLMDB.models(provider)

      provider when is_binary(provider) ->
        LLMDB.models()
        |> Enum.filter(&(Atom.to_string(&1.provider) == provider))
    end
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
