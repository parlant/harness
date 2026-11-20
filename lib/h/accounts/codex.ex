defmodule H.Accounts.Codex do
  @moduledoc false

  # Codex first-party device protocol. This is not a public third-party OAuth
  # contract. No endpoint settings, auth-store discovery, redirect or retry.
  @issuer "https://auth.openai.com"
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @verification_url @issuer <> "/codex/device"

  alias H.Accounts.Vault

  def verification_url, do: @verification_url

  def request_code(http) do
    case post(http, "/api/accounts/deviceauth/usercode", json: %{client_id: @client_id}) do
      {:ok, status, %{"device_auth_id" => id, "interval" => interval} = body}
      when status in 200..299 ->
        code = body["user_code"] || body["usercode"]

        with true <- Vault.token?(id) and byte_size(id) <= 512,
             true <- user_code?(code),
             {:ok, seconds} <- parse_interval(interval) do
          {:ok, %{device_id: id, user_code: code, interval_ms: seconds * 1000}}
        else
          _ -> {:error, :invalid_device_response}
        end

      {:ok, status, _} when status in [403, 404] ->
        {:error, :device_auth_unavailable}

      _ ->
        {:error, :device_request_failed}
    end
  end

  def poll(http, %{device_id: id, user_code: code}) do
    case post(http, "/api/accounts/deviceauth/token",
           json: %{device_auth_id: id, user_code: code}
         ) do
      {:ok, status, %{"authorization_code" => auth_code, "code_verifier" => verifier}}
      when status in 200..299 ->
        if Vault.token?(auth_code) and Vault.token?(verifier),
          do: {:ok, {auth_code, verifier}},
          else: {:error, :invalid_device_response}

      {:ok, _, %{"error" => "slow_down"}} ->
        :slow_down

      {:ok, _, %{"error" => "access_denied"}} ->
        {:error, :access_denied}

      {:ok, _, %{"error" => "expired_token"}} ->
        {:error, :expired}

      {:ok, status, _} when status in [403, 404] ->
        :pending

      _ ->
        {:error, :device_poll_failed}
    end
  end

  def exchange(http, {code, verifier}) do
    tokens(http,
      grant_type: "authorization_code",
      code: code,
      code_verifier: verifier,
      redirect_uri: @issuer <> "/deviceauth/callback"
    )
  end

  def refresh(http, token), do: tokens(http, grant_type: "refresh_token", refresh_token: token)

  defp tokens(http, form) do
    with {:ok, status, %{"access_token" => access, "refresh_token" => refresh} = body}
         when status in 200..299 <-
           post(http, "/oauth/token", form: [client_id: @client_id] ++ form),
         true <- Vault.token?(access) and Vault.token?(refresh),
         {:ok, claims} <- claims(access),
         %{"chatgpt_account_id" => account} <- claims["https://api.openai.com/auth"],
         subject when is_binary(subject) <- claims["sub"],
         expiry when is_integer(expiry) <- expiry(body, claims),
         record = %{
           "access_token" => access,
           "refresh_token" => refresh,
           "account_id" => account,
           "subject" => subject,
           "expires_at_ms" => expiry
         },
         true <- Vault.valid_record?(record) do
      {:ok, record}
    else
      _ -> {:error, :token_exchange_failed}
    end
  end

  # Claims on the access token returned directly by the fixed TLS endpoint
  # are routing/replacement metadata, not local authentication or ID tokens.
  defp claims(access) do
    with [_, payload, _] <- String.split(access, ".", parts: 4),
         {:ok, data} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- JSON.decode(data) do
      {:ok, claims}
    else
      _ -> :error
    end
  end

  defp expiry(body, claims) do
    now = System.system_time(:millisecond)

    candidates =
      for {field, factor, base} <- [{body["expires_in"], 1000, now}, {claims["exp"], 1000, 0}],
          is_integer(field) and field > 0,
          do: field * factor + base

    case Enum.min(candidates, fn -> 0 end) do
      expiry when expiry > now and expiry <= now + 90 * 86_400_000 -> expiry
      _ -> nil
    end
  end

  defp post(http, path, params) do
    opts = [
      url: @issuer <> path,
      retry: false,
      redirect: false,
      connect_options: [timeout: 5_000],
      pool_timeout: 3_000,
      receive_timeout: 5_000
    ]

    case http.(opts ++ params) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, body}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp parse_interval(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> parse_interval(n)
      _ -> :error
    end
  end

  defp parse_interval(n) when is_integer(n) and n in 1..120, do: {:ok, max(n, 5)}
  defp parse_interval(_), do: :error

  def user_code?(code), do: is_binary(code) and Regex.match?(~r/\A[A-Z0-9-]{4,24}\z/, code)
end
