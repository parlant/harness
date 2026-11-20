defmodule H.Provider.Compatible do
  @moduledoc false

  alias H.Accounts.Config

  @provider_limit 8

  # Keep the registry local to the daemon, and use one fixed ReqLLM provider
  # tag for the codec. External provider names never become VM atoms.
  def load(opts) do
    dir = Keyword.fetch!(opts, :data_dir)
    path = Path.join(dir, "openai-compatible.json")

    result =
      case File.lstat(path) do
        {:error, :enoent} ->
          {:ok, %{}}

        {:ok, %File.Stat{type: :regular, mode: mode, size: size}}
        when size <= 256_000 and Bitwise.band(mode, 0o022) == 0 ->
          with {:ok, body} when byte_size(body) <= 256_000 <- File.read(path),
               {:ok, data} <- JSON.decode(body),
               do: parse(data)

        _ ->
          :error
      end

    case result do
      {:ok, providers} -> {:ok, Keyword.put(opts, :compatible_providers, providers)}
      _ -> {:error, :invalid_openai_compatible_json}
    end
  end

  defp parse(%{"version" => 1, "providers" => providers} = data)
       when map_size(data) == 2 and is_map(providers) and map_size(providers) <= @provider_limit do
    reserved =
      ([:openai_codex, :google_vertex, :ollama, :github_copilot, :typesafe] ++
         LLMDB.Generated.ProviderRegistry.list() ++ ReqLLM.Providers.list())
      |> Enum.map(&Atom.to_string/1)
      |> MapSet.new()
      |> MapSet.union(MapSet.new(H.Credentials.api_key_providers()))
      |> MapSet.put("h_openai_compatible")

    reduce_valid(providers, fn {id, raw} ->
      if Config.valid_source?(id) and not MapSet.member?(reserved, String.replace(id, "-", "_")),
        do: parse_provider(id, raw),
        else: :error
    end)
  end

  defp parse(_), do: :error

  defp valid_base_url?(url) when is_binary(url) and byte_size(url) <= 512 do
    case URI.new(url) do
      {:ok,
       %URI{scheme: "https", host: host, port: port, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" and port in 1..65_535 ->
        true

      _ ->
        false
    end
  end

  defp valid_base_url?(_), do: false

  defp parse_provider(id, %{"name" => name, "base_url" => url, "models" => models} = raw)
       when map_size(raw) == 3 and is_map(models) and map_size(models) in 1..64 do
    with true <- label?(name),
         true <- valid_base_url?(url),
         {:ok, models} <- reduce_valid(models, &parse_model/1) do
      {:ok, {id, %{name: name, base_url: String.trim_trailing(url, "/"), models: models}}}
    else
      _ -> :error
    end
  end

  defp parse_provider(_, _), do: :error

  defp parse_model(
         {id,
          %{
            "name" => name,
            "context_window" => context,
            "max_output_tokens" => output,
            "supports_reasoning" => reasoning,
            "supports_images" => images,
            "price_per_million_tokens" =>
              %{
                "input" => input_rate,
                "output" => output_rate,
                "cache_read" => read_rate,
                "cache_write" => write_rate
              } = rates
          } = raw}
       )
       when map_size(raw) == 6 and map_size(rates) == 4 and context in 1..100_000_000 and
              is_integer(output) and output > 0 and output <= context and is_boolean(reasoning) and
              is_boolean(images) do
    if byte_size(id) in 1..160 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/, id) and
         label?(name) and
         Enum.all?(Map.values(rates), &(is_number(&1) and &1 >= 0 and &1 <= 1_000_000)) do
      model = %LLMDB.Model{
        id: id,
        model: id,
        provider: :h_openai_compatible,
        name: name,
        limits: %{context: context, output: output},
        modalities: %{input: if(images, do: [:text, :image], else: [:text]), output: [:text]},
        capabilities: %{
          chat: true,
          streaming: %{text: true, tool_calls: true},
          tools: %{enabled: true},
          reasoning: %{enabled: reasoning}
        },
        cost: %{
          input: input_rate,
          output: output_rate,
          cache_read: read_rate,
          cache_write: write_rate
        }
      }

      [model] = LLMDB.Pricing.apply_cost_components([model])
      {:ok, {id, model}}
    else
      :error
    end
  end

  defp parse_model(_), do: :error

  defp label?(value),
    do:
      is_binary(value) and byte_size(value) in 1..120 and String.trim(value) != "" and
        not Regex.match?(~r/[\p{C}]/u, value)

  defp reduce_valid(entries, parse) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      case parse.(entry) do
        {:ok, {id, value}} -> {:cont, {:ok, Map.put(acc, id, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  def provider_for_model(providers, spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [id, model] when is_map_key(providers, id) -> {id, providers[id], model}
      _ -> nil
    end
  end

  def provider_for_model(_providers, _spec), do: nil
end
