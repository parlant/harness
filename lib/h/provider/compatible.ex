defmodule H.Provider.Compatible do
  @moduledoc false

  alias H.Accounts.Config

  @provider_limit 8

  @max_bytes 256_000
  @filename "openai-compatible.json"

  # Keep the registry local to the daemon, and use one fixed ReqLLM provider
  # tag for the codec. External provider names never become VM atoms.
  def load(opts) do
    with {:ok, _document, providers} <- read(Keyword.fetch!(opts, :data_dir)) do
      {:ok, Keyword.put(opts, :compatible_providers, providers)}
    end
  end

  def read(dir) do
    path = Path.join(dir, @filename)

    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, %{"version" => 1, "providers" => %{}}, %{}}

      {:ok, %File.Stat{type: :regular, mode: mode, size: size}}
      when size <= @max_bytes and Bitwise.band(mode, 0o022) == 0 ->
        with {:ok, body} when byte_size(body) <= @max_bytes <- File.read(path),
             {:ok, document} <- JSON.decode(body),
             {:ok, providers} <- parse(document) do
          {:ok, document, providers}
        else
          _ -> {:error, :invalid_openai_compatible_json}
        end

      _ ->
        {:error, :invalid_openai_compatible_json}
    end
  end

  def revision(document),
    do: Base.url_encode64(:crypto.hash(:sha256, JSON.encode!(document)), padding: false)

  def parse_edit(
        %{
          "id" => id,
          "name" => name,
          "base_url" => url,
          "models" => models_json,
          "revision" => revision
        } = edit
      )
      when map_size(edit) == 5 and is_binary(models_json) and byte_size(models_json) <= @max_bytes and
             is_binary(revision) and byte_size(revision) == 43 do
    with true <- provider_id?(id),
         {:ok, models} <- JSON.decode(models_json),
         provider = %{"name" => name, "base_url" => url, "models" => models},
         {:ok, {^id, parsed}} <- parse_provider(id, provider) do
      {:ok, {id, provider, parsed.base_url, revision}}
    else
      _ -> {:error, :invalid_provider_config}
    end
  end

  def parse_edit(_), do: {:error, :invalid_provider_config}

  # Called only by Accounts, the serialized writer under the daemon's store lock.
  def stage(dir, {id, provider, url, expected}, running, key_exists?) do
    with {:ok, document, saved} <- read(dir),
         :ok <- check_revision(document, expected),
         :ok <- check_binding(saved[id], running[id], url, key_exists?),
         next = put_in(document["providers"][id], provider),
         {:ok, _} <- parse(next),
         bytes when byte_size(bytes) <= @max_bytes <- JSON.encode!(next) <> "\n" do
      case H.Accounts.File.replace(dir, Path.join(dir, @filename), bytes) do
        :ok -> :ok
        _ -> {:error, :provider_config_unavailable}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_config}
    end
  end

  defp check_revision(document, expected) do
    if revision(document) == expected, do: :ok, else: {:error, :stale_provider_config}
  end

  defp check_binding(saved, running, url, key_exists?) do
    case {saved, running} do
      {nil, nil} when key_exists? -> {:error, :provider_key_binding}
      {%{base_url: existing}, _} when existing != url -> {:error, :provider_key_binding}
      {_, %{base_url: existing}} when existing != url -> {:error, :provider_key_binding}
      _ -> :ok
    end
  end

  defp parse(%{"version" => 1, "providers" => providers} = data)
       when map_size(data) == 2 and is_map(providers) and map_size(providers) <= @provider_limit do
    reduce_valid(providers, fn {id, raw} ->
      if provider_id?(id), do: parse_provider(id, raw), else: :error
    end)
  end

  defp parse(_), do: :error

  defp provider_id?(id) do
    if Config.valid_source?(id) do
      normalized = String.replace(id, "-", "_")

      normalized not in H.Credentials.api_key_providers() and
        normalized != "h_openai_compatible" and
        not Enum.any?(
          [:openai_codex, :google_vertex, :ollama, :github_copilot, :typesafe] ++
            LLMDB.Generated.ProviderRegistry.list() ++ ReqLLM.Providers.list(),
          &(Atom.to_string(&1) == normalized)
        )
    else
      false
    end
  end

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
