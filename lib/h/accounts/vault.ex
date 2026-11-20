defmodule H.Accounts.Vault do
  @moduledoc """
  Private single-writer credential storage under the daemon's data-dir lock.
  Not part of session storage and not an isolation boundary for same-UID tools.
  """

  import Bitwise

  alias H.Accounts.Config

  @limit 64_000
  @fields ~w(access_token refresh_token account_id subject expires_at_ms)

  def open(data_dir, sources) do
    dir = Path.join(data_dir, "credentials")

    with true <- Enum.all?(sources, &Config.valid_source?/1),
         {:ok, %File.Stat{type: :directory, uid: uid, mode: mode}} <- File.lstat(data_dir),
         true <- (mode &&& 0o077) == 0,
         :ok <- mkdir(dir),
         {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}} <- File.lstat(dir),
         true <- (mode &&& 0o777) == 0o700 do
      vault = {dir, uid}

      Enum.reduce_while(sources, {:ok, vault, %{}}, fn source, {:ok, ^vault, records} ->
        case read(vault, source) do
          {:ok, record} -> {:cont, {:ok, vault, Map.put(records, source, record)}}
          {:error, :enoent} -> {:cont, {:ok, vault, records}}
          {:error, _} -> {:halt, {:error, :unsafe_or_invalid_credential_file}}
        end
      end)
    else
      _ -> {:error, :unsafe_credentials_directory}
    end
  end

  defp mkdir(dir) do
    case File.mkdir(dir) do
      :ok -> File.chmod(dir, 0o700)
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp read({dir, uid}, source) do
    path = Path.join(dir, "openai_codex-#{source}.json")

    with :ok <- check_file(path, uid),
         {:ok, body} when byte_size(body) <= @limit <- File.read(path),
         {:ok, %{"version" => 1, "credential" => record} = data} when map_size(data) == 2 <-
           JSON.decode(body),
         true <- valid_record?(record) do
      {:ok, record}
    else
      {:error, :enoent} -> {:error, :enoent}
      _ -> {:error, :invalid_credential_file}
    end
  end

  defp check_file(path, uid, limit \\ @limit) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, uid: ^uid, mode: mode, links: 1, size: size}}
      when (mode &&& 0o777) == 0o600 and size <= limit ->
        :ok

      {:error, :enoent} = error ->
        error

      _ ->
        {:error, :unsafe_credential_file}
    end
  end

  # Write to an exclusive file inside the private directory. No secret bytes
  # are written until chmod succeeds. Sync before atomic publication.
  def write({dir, uid}, source, record) do
    with true <- Config.valid_source?(source) and valid_record?(record),
         {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}} <- File.lstat(dir),
         true <- (mode &&& 0o777) == 0o700,
         path = Path.join(dir, "openai_codex-#{source}.json"),
         allowed when allowed in [:ok, {:error, :enoent}] <- check_file(path, uid),
         :ok <-
           H.Accounts.File.replace(dir, path, JSON.encode!(%{version: 1, credential: record})) do
      :ok
    else
      _ -> {:error, :credential_store_unavailable}
    end
  end

  # A bounded, atomically replaced file keeps key material and each provider's
  # selection together. Unlike a Codex grant, API keys do not rotate on use.
  @key_limit 500_000
  @max_key_providers 13

  def read_api_keys({dir, uid}) do
    path = Path.join(dir, "api-keys.json")

    with :ok <- check_file(path, uid, @key_limit),
         {:ok, bytes} when byte_size(bytes) <= @key_limit <- File.read(path),
         {:ok, %{"version" => 1, "providers" => providers} = record} when map_size(record) == 2 <-
           JSON.decode(bytes),
         {:ok, profiles} <- decode_profiles(providers) do
      {:ok, profiles}
    else
      {:error, :enoent} -> {:ok, %{}}
      _ -> {:error, :unsafe_or_invalid_api_key_store}
    end
  end

  def write_api_keys({dir, uid}, profiles) do
    path = Path.join(dir, "api-keys.json")

    with {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}} <- File.lstat(dir),
         true <- (mode &&& 0o777) == 0o700,
         allowed when allowed in [:ok, {:error, :enoent}] <- check_file(path, uid, @key_limit),
         true <- map_size(profiles) <= @max_key_providers,
         body = JSON.encode!(%{version: 1, providers: profiles}),
         true <- byte_size(body) <= @key_limit,
         :ok <- H.Accounts.File.replace(dir, path, body) do
      :ok
    else
      _ -> {:error, :credential_store_unavailable}
    end
  end

  defp decode_profiles(profiles)
       when is_map(profiles) and map_size(profiles) <= @max_key_providers do
    Enum.reduce_while(profiles, {:ok, %{}}, fn
      {provider, %{"active" => active, "keys" => keys} = profile}, {:ok, acc}
      when map_size(profile) == 2 and is_map(keys) and map_size(keys) in 1..8 and
             is_map_key(keys, active) ->
        if Config.valid_source?(provider) and
             Enum.all?(keys, fn {name, key} -> Config.valid_source?(name) and api_key?(key) end) do
          {:cont, {:ok, Map.put(acc, provider, %{active: active, keys: keys})}}
        else
          {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp decode_profiles(_), do: :error

  def api_key?(key), do: is_binary(key) and byte_size(key) <= 2048 and token?(key)

  def valid_record?(%{"account_id" => account, "subject" => subject, "state" => "reauth"} = r)
      when map_size(r) == 3,
      do: identity?(account) and identity?(subject)

  def valid_record?(%{"expires_at_ms" => expiry} = record)
      when is_integer(expiry) and expiry > 0 and map_size(record) == length(@fields) do
    token?(record["access_token"]) and token?(record["refresh_token"]) and
      identity?(record["account_id"]) and identity?(record["subject"])
  end

  def valid_record?(_), do: false

  def token?(s),
    do: is_binary(s) and byte_size(s) in 1..16_384 and Regex.match?(~r/\A[!-~]+\z/, s)

  defp identity?(s),
    do: is_binary(s) and byte_size(s) in 1..256 and Regex.match?(~r/\A[A-Za-z0-9._|:@-]+\z/, s)
end
