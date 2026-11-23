defmodule H.Provider.ReqLLM.CodexPool do
  @moduledoc """
  Managed Codex account dispatch, pooled credential selection, and pre-output
  authentication rejection handling for `H.Provider.ReqLLM`.
  """

  alias H.Provider.ReqLLM.Catalog

  def attempt_config(%{accounts: accounts} = config) do
    mode =
      if config[:codex_account_policy] || H.Accounts.configured?(accounts),
        do: :managed,
        else: :manual

    Map.put(config, :accounts_mode, mode)
  end

  def attempt_config(config), do: Map.put(config, :accounts_mode, :manual)

  def dispatch_limit(config, model) do
    config = if Map.has_key?(config, :accounts_mode), do: config, else: attempt_config(config)

    cond do
      not managed_codex?(config, model) -> nil
      config[:codex_account_policy] -> 2
      true -> 1
    end
  end

  def stream_turn(config, request, model, emit, ops) do
    {context, tools} = ops.build_inputs.(request)
    context = portable_codex_context(context)
    policy = config[:codex_account_policy]

    dispatch = fn credential ->
      managed_dispatch(
        config,
        request,
        model,
        context,
        tools,
        credential,
        emit,
        policy != nil,
        ops
      )
    end

    result =
      if policy do
        deadline = System.monotonic_time(:millisecond) + 15_000

        case pooled_dispatch(config, policy, model.id, dispatch, deadline, nil) do
          {:error, reason} when reason in [:pool_empty, :credential_unavailable] ->
            resolve_pool_unavailability(config, policy, model.id, reason)

          other ->
            other
        end
      else
        with {:ok, credential} <- H.Accounts.resolve_codex(config.accounts),
             do: dispatch.(credential)
      end

    managed_result(result)
  end

  # A typed transport HTTP 401 with the explicit invalid_token code is an
  # authentication rejection, not a generic 401 or a stream error string.
  def rejection(%ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Request{} = request}),
    do: rejection(request)

  def rejection(%ReqLLM.Error.API.Request{status: 401, provider_code: "invalid_token"}),
    do: :invalid_token

  def rejection(%ReqLLM.Error.API.Request{status: 429}), do: :rate_limited
  def rejection(_), do: :codex_request_failed

  # Internal pool & managed dispatch mechanics

  defp managed_codex?(%{accounts_mode: :managed}, model),
    do: match?({:ok, %LLMDB.Model{provider: :openai_codex}}, Catalog.resolve_model(model))

  defp managed_codex?(_, _), do: false

  defp pooled_dispatch(config, policy, model, dispatch, deadline, rejected) do
    case policy_credential(config, policy, model, rejected, deadline) do
      {:ok, source, credential} ->
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

      {:error, :credential_unavailable} when not is_nil(rejected) ->
        {:error, :invalid_token}

      error ->
        error
    end
  end

  defp policy_credential(config, policy, model, rejected, deadline) do
    {excluded, excluded_identity} = rejected || {nil, nil}
    candidates = List.delete(policy.sources, excluded)

    case policy_callback(policy.module, :order, [model, candidates]) do
      [] when is_nil(rejected) ->
        {:error, :pool_empty}

      [] ->
        {:error, :credential_unavailable}

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

  defp resolve_pool_unavailability(config, policy, model_id, reason) do
    case H.Accounts.codex_status(config.accounts, policy.sources) do
      :alias_mismatch ->
        {:error, :codex_pool_alias_mismatch}

      :signed_in when reason == :pool_empty ->
        if Code.ensure_loaded?(policy.module) and
             function_exported?(policy.module, :unavailable, 2) do
          case policy_callback(policy.module, :unavailable, [model_id, policy.sources]) do
            diag when is_map(diag) ->
              format_policy_unavailability(diag)

            _ ->
              {:error, :credential_unavailable}
          end
        else
          {:error, :credential_unavailable}
        end

      _ ->
        {:error, :credential_unavailable}
    end
  end

  defp format_policy_unavailability(diag) do
    code = sanitize_code(Map.get(diag, :code))
    message = sanitize_text(Map.get(diag, :message), 500)

    if is_binary(code) and is_binary(message) do
      if Map.get(diag, :wait) == true do
        resumes_at =
          case Map.get(diag, :resumes_at_ms) do
            ts when is_integer(ts) and ts > 0 -> ts
            _ -> nil
          end

        recheck_after_ms =
          case Map.get(diag, :recheck_after_ms) do
            ms when is_integer(ms) and ms >= 1_000 -> min(ms, 300_000)
            _ -> 60_000
          end

        wait =
          %{
            topic: "account_policy:openai_codex",
            title: sanitize_text(Map.get(diag, :wait_title), 120) || "Waiting to continue",
            detail: sanitize_text(Map.get(diag, :wait_detail), 240),
            resumes_at: resumes_at
          }

        {:error,
         %{
           code: code,
           message: message,
           retryable: true,
           wait: wait,
           retry_after_ms: recheck_after_ms
         }}
      else
        {:error, %{code: code, message: message, retryable: false}}
      end
    else
      {:error, :credential_unavailable}
    end
  end

  defp sanitize_code(code) when is_binary(code) do
    trimmed = String.trim(code)

    if Regex.match?(~r/\A[a-z0-9_.-]{1,64}\z/, trimmed),
      do: trimmed,
      else: nil
  end

  defp sanitize_code(_), do: nil

  defp sanitize_text(val, max_len) when is_binary(val) do
    cleaned =
      val
      |> H.Credentials.sanitize()
      |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    case cleaned do
      "" -> nil
      str -> String.slice(str, 0, max_len)
    end
  end

  defp sanitize_text(_, _), do: nil

  defp policy_callback(module, callback, args) do
    apply(module, callback, args)
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp managed_dispatch(
         config,
         request,
         model,
         context,
         tools,
         credential,
         emit,
         pooled?,
         ops
       ) do
    dispatch =
      config
      |> Map.take([:stream_fn, :close_fn, :receive_timeout])
      |> Map.put(:credentials, credential)

    with {:ok, opts} <- ops.build_stream_opts.(dispatch, request, model, tools, %{}),
         opts =
           Keyword.update!(
             opts,
             :provider_options,
             &Keyword.merge(&1, openai_stream_transport: :sse, codex_originator: "h")
           ),
         opts = Keyword.put(opts, :base_url, "https://chatgpt.com/backend-api"),
         {:ok, stream} <- ops.start_stream.(dispatch, model, context, opts) do
      safe_emit = fn
        %{type: :start} when pooled? -> :ok
        event -> emit.(Map.delete(event, :metadata))
      end

      ops.consume_stream.(stream, model, Map.put(dispatch, :managed_codex, true), safe_emit)
    else
      {:error, reason} -> {:error, rejection(reason)}
    end
  end

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

  defp managed_result({:error, %{code: code, message: message} = error})
       when is_binary(code) and is_binary(message),
       do: {:error, error}

  defp managed_result({:error, :credential_unavailable}),
    do: managed_codex_error(:codex_accounts_unavailable)

  defp managed_result({:error, :account_policy_unavailable}),
    do: managed_codex_error(:account_policy_unavailable)

  defp managed_result({:error, reason})
       when reason in [:codex_pool_alias_mismatch, :invalid_token, :rate_limited],
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
          "No eligible Codex credential is available. If a pool is enabled, check its aliases and allow time for a fresh usage check. Otherwise use /login or /account."

        :codex_pool_alias_mismatch ->
          "None of the Codex pool aliases match the daemon's accounts. Check /account, update the pool's sources in extensions.json (or disable the pool), then restart the daemon. /account only selects the stock account."

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
end
