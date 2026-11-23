defmodule H.Provider.ReqLLM.Catalog do
  @moduledoc """
  Model catalog curation, `LLMDB` lookup, Gemini/Vertex synchronous limit
  normalization, and default model selection for `H.Provider.ReqLLM`.
  """

  alias H.Credentials
  alias H.Provider.{CodexModels, Compatible, GeminiModels, Settings}

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
      "gemini-4-neon",
      "gemini-4-hydrogen",
      "gemini-4-carbon",
      "gemini-4-argon",
      "gemini-3.8-flash"
    ],
    google: [
      "gemini-4-neon",
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

  def list_models(config) when is_map(config) do
    stock_models(config) ++ compatible_models(config)
  end

  defp stock_models(config) do
    case Map.get(config, :models) do
      list when is_list(list) ->
        list
        |> Enum.map(&project_model/1)
        |> Enum.sort_by(& &1.id)

      nil ->
        fetch_curated_models(config, Settings.read(config))
    end
  end

  def default_model(config \\ %{}) when is_map(config) do
    settings = Settings.read(config)

    case Map.get(config, :default_model) || Application.get_env(:harness, :default_model) ||
           settings["default_model"] do
      model when is_binary(model) and model != "" ->
        model

      _ ->
        case Enum.find(stock_models(config), &(not Map.has_key?(&1, :unavailable_reason))) do
          %{id: id} -> id
          nil -> "openai:gpt-5.4"
        end
    end
  end

  def context_window(model_spec, config \\ %{}) do
    model =
      case Compatible.provider_for_model(config[:compatible_providers] || %{}, model_spec) do
        {_, provider, id} ->
          provider.models[id]

        nil ->
          case resolve_model(model_spec) do
            {:ok, model} -> model
            _ -> nil
          end
      end

    get_nested(model, [:limits, :context])
  end

  def resolve_model(nil), do: {:error, {:invalid_model, "model is required"}}

  def resolve_model("google:" <> id) do
    case google_model(id) do
      %LLMDB.Model{} = model -> ReqLLM.model(model)
      nil -> ReqLLM.model(%{provider: :google, id: id})
    end
  end

  def resolve_model("google_vertex:" <> id) do
    case vertex_model(id) do
      %LLMDB.Model{} = model -> ReqLLM.model(model)
      nil -> ReqLLM.model(%{provider: :google_vertex, id: id})
    end
  end

  def resolve_model("google-vertex:" <> id), do: resolve_model("google_vertex:" <> id)
  def resolve_model("openai-codex:" <> id), do: resolve_model("openai_codex:" <> id)

  def resolve_model("openai_codex:" <> id) do
    case Enum.find(CodexModels.list(), &(&1.id == id)) do
      %LLMDB.Model{} = model -> ReqLLM.model(model)
      nil -> ReqLLM.model("openai_codex:" <> id)
    end
  end

  def resolve_model(model_spec), do: ReqLLM.model(model_spec)

  def get_nested(nil, _keys), do: nil
  def get_nested(val, []), do: val

  def get_nested(map, [key | rest]) when is_map(map) do
    next = Map.get(map, key) || Map.get(map, Atom.to_string(key))
    get_nested(next, rest)
  end

  def get_nested(_, _), do: nil

  # Internal catalog resolution

  defp google_model(id) do
    case lookup_llmdb_model(:google, id) || GeminiModels.get(id) do
      %LLMDB.Model{} = model -> synchronous_gemini_limits(model)
      nil -> nil
    end
  end

  defp vertex_model(id) do
    lookup_llmdb_model(:google_vertex, id) ||
      case google_model(id) do
        %LLMDB.Model{} = model -> %{model | provider: :google_vertex}
        nil -> nil
      end
  end

  # The Developer API catalog can advertise long-decode limits; H uses
  # ordinary synchronous streams, not long-decode continuation.
  defp synchronous_gemini_limits(%LLMDB.Model{} = model) do
    limits =
      case get_nested(model.extra, [:default_synchronous_output_limit]) do
        n when is_integer(n) and n > 0 -> Map.put(model.limits || %{}, :output, n)
        _ -> model.limits
      end

    %{model | limits: limits}
  end

  defp compatible_models(config) do
    selected = config[:provider]
    stored = if config[:accounts], do: H.Accounts.key_providers(config.accounts), else: []
    stored = if is_list(stored), do: stored, else: []

    for {id, provider} <- Enum.sort(config[:compatible_providers] || %{}),
        is_nil(selected) or selected == id,
        {_id, model} <- Enum.sort(provider.models) do
      entry =
        model
        |> project_model()
        |> Map.merge(%{
          id: "#{id}:#{model.id}",
          provider: id,
          provider_name: provider.name,
          supports_images: :image in model.modalities.input,
          price_per_million_tokens: model.cost
        })

      if id in stored,
        do: entry,
        else: Map.put(entry, :unavailable_reason, "API key required (/key set #{id} <alias>)")
    end
  end

  defp fetch_curated_models(config, settings) do
    models =
      config
      |> resolve_target_providers(settings)
      |> Enum.flat_map(&curated_models_for_provider/1)

    if Enum.any?(models, &(&1.provider == "openai_codex")) do
      case codex_unavailable_reason(config, settings) do
        nil -> models
        reason -> Enum.map(models, &mark_codex_unavailable(&1, reason))
      end
    else
      models
    end
  end

  defp codex_unavailable_reason(config, settings) do
    policy = config[:codex_account_policy]
    accounts = config[:accounts]

    status =
      if policy || (accounts && H.Accounts.configured?(accounts)) do
        H.Accounts.codex_status(accounts, get_in(policy, [:sources]))
      else
        opts = Keyword.put(Map.get(config, :credentials_opts, []), :settings, settings)
        if Credentials.configured?(:openai_codex, opts), do: :signed_in, else: :sign_in_required
      end

    case status do
      :signed_in -> pool_unavailable_reason(policy)
      :alias_mismatch -> "Codex pool aliases do not match accounts (extensions.json)"
      :sign_in_required -> "Codex sign-in required (/login)"
      {:error, _} -> "Codex account store unavailable"
    end
  end

  defp pool_unavailable_reason(%{module: mod, sources: sources})
       when is_atom(mod) and is_list(sources) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :unavailable, 2) and
         safe_policy_call(mod, :order, ["openai_codex:gpt-6.2-sol", sources]) == [] do
      case safe_policy_call(mod, :unavailable, ["openai_codex:gpt-6.2-sol", sources]) do
        %{summary: summary} when is_binary(summary) ->
          sanitize_reason(summary)

        %{summary: nil} ->
          nil

        %{message: message} when is_binary(message) ->
          sanitize_reason(message)

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp pool_unavailable_reason(_), do: nil

  defp sanitize_reason(val) when is_binary(val) do
    cleaned =
      val
      |> Credentials.sanitize()
      |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    case cleaned do
      "" -> nil
      str -> String.slice(str, 0, 200)
    end
  end

  defp safe_policy_call(mod, fun, args) do
    apply(mod, fun, args)
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp mark_codex_unavailable(%{provider: "openai_codex"} = model, reason),
    do: Map.put(model, :unavailable_reason, reason)

  defp mark_codex_unavailable(model, _reason), do: model

  defp resolve_target_providers(config, settings) do
    case Map.get(config, :provider) do
      nil ->
        cred_opts = Keyword.put(Map.get(config, :credentials_opts, []), :settings, settings)

        stored = if config[:accounts], do: H.Accounts.key_providers(config.accounts), else: []

        stored =
          if is_list(stored),
            do: Enum.flat_map(stored, fn id -> List.wrap(normalize_provider_name(id)) end),
            else: []

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
            case provider do
              :google -> google_model(id)
              :google_vertex -> vertex_model(id)
              _ -> lookup_llmdb_model(provider, id)
            end

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
end
