defmodule H.Accounts.Config do
  @moduledoc false

  @alias ~r/\A[a-z][a-z0-9_-]{0,31}\z/

  @limit 4096

  def read(dir) do
    path = Path.join(dir, "accounts.json")

    with {:ok, %File.Stat{type: :regular, size: size, links: 1}} when size <= @limit <-
           File.lstat(path),
         {:ok, body} when byte_size(body) <= @limit <- File.read(path),
         {:ok, %{"version" => 1, "openai_codex" => settings} = config} when map_size(config) == 2 <-
           JSON.decode(body),
         {:ok, sources, active} <- parse(settings) do
      {:ok, sources, active}
    else
      {:error, :enoent} -> {:ok, [], nil}
      _ -> {:error, :invalid_accounts_json}
    end
  end

  def write(dir, sources, active) do
    path = Path.join(dir, "accounts.json")

    with {:ok, _, _} <- read(dir),
         :ok <-
           H.Accounts.File.replace(
             dir,
             path,
             JSON.encode!(%{version: 1, openai_codex: %{sources: sources, active: active}}) <>
               "\n"
           ) do
      :ok
    else
      _ -> {:error, :account_config_unavailable}
    end
  end

  def delete(dir) do
    path = Path.join(dir, "accounts.json")

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} -> {:error, :account_config_unavailable}
    end
  end

  def parse(%{"sources" => sources} = settings)
      when is_list(sources) and length(sources) in 1..8 do
    active = Map.get(settings, "active", hd(sources))

    if Map.keys(settings) -- ["sources", "active"] == [] and
         Enum.all?(sources, &valid_source?/1) and Enum.uniq(sources) == sources and
         active in sources do
      {:ok, sources, active}
    else
      {:error, :invalid_codex_sources}
    end
  end

  def parse(_), do: {:error, :invalid_codex_sources}

  def valid_source?(source), do: is_binary(source) and Regex.match?(@alias, source)
end
