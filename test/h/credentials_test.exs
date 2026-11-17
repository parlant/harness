defmodule H.CredentialsTest do
  use ExUnit.Case, async: true

  alias H.Credentials
  alias H.Credentials.{CacheEntry, Redacted}

  describe "resolve/2" do
    test "resolves google_vertex with explicit access_token and default global region" do
      assert {:ok, creds} =
               Credentials.resolve(:google_vertex,
                 access_token: "Bearer ya29.test-token",
                 env: %{"GOOGLE_CLOUD_PROJECT" => "my-gcp-project"}
               )

      assert creds == %{
               access_token: "ya29.test-token",
               project_id: "my-gcp-project",
               region: "global"
             }
    end

    test "resolves google_vertex from string provider name and GOOGLE_CLOUD_REGION" do
      fetcher = fn -> {:ok, ~s({"access_token": "tok-json-1", "expires_in": 1800})} end

      assert {:ok, creds} =
               Credentials.resolve("google_vertex",
                 fetcher: fetcher,
                 cache: false,
                 env: %{
                   "GOOGLE_CLOUD_PROJECT" => "proj-1",
                   "GOOGLE_CLOUD_REGION" => "us-central1"
                 }
               )

      assert creds == %{
               access_token: "tok-json-1",
               project_id: "proj-1",
               region: "us-central1"
             }
    end

    test "caches google_vertex tokens with TTL margin and refreshes when expired" do
      clock = start_supervised!({Agent, fn -> 1_000_000 end})
      calls = start_supervised!({Agent, fn -> 0 end}, id: :fetch_counter)

      cache =
        start_supervised!(
          {Credentials,
           ttl_margin_ms: 60_000,
           default_ttl_ms: 300_000,
           now_fn: fn -> Agent.get(clock, & &1) end}
        )

      fetcher = fn ->
        n = Agent.get_and_update(calls, fn count -> {count + 1, count + 1} end)
        {:ok, %{access_token: "tok-#{n}", expires_in: 120}}
      end

      opts = [
        cache: cache,
        fetcher: fetcher,
        project_id: "proj-cache",
        region: "global"
      ]

      # Initial fetch at t = 1_000_000 (expires_at = 1_120_000, valid until 1_060_000)
      assert {:ok, %{access_token: "tok-1"}} = Credentials.resolve(:google_vertex, opts)
      assert Agent.get(calls, & &1) == 1

      # Within TTL margin (t = 1_050_000): served from cache
      Agent.update(clock, fn _ -> 1_050_000 end)
      assert {:ok, %{access_token: "tok-1"}} = Credentials.resolve(:google_vertex, opts)
      assert Agent.get(calls, & &1) == 1

      # Inside TTL safety margin (t = 1_060_000): refreshed
      Agent.update(clock, fn _ -> 1_060_000 end)
      assert {:ok, %{access_token: "tok-2"}} = Credentials.resolve(:google_vertex, opts)
      assert Agent.get(calls, & &1) == 2

      # Clearing cache forces a fresh fetch
      assert :ok = Credentials.clear_cache(cache)
      assert {:ok, %{access_token: "tok-3"}} = Credentials.resolve(:google_vertex, opts)
      assert Agent.get(calls, & &1) == 3
    end

    test "returns missing env error when GOOGLE_CLOUD_PROJECT is absent" do
      assert {:error, {:missing_env, "GOOGLE_CLOUD_PROJECT"}} =
               Credentials.resolve(:google_vertex,
                 access_token: "tok-ignored",
                 env: %{}
               )
    end

    test "sanitizes secrets from fetcher errors" do
      fetcher = fn ->
        {:error, "helper failed with Bearer secret-abc-123 and access_token=tok-xyz"}
      end

      assert {:error, reason} =
               Credentials.resolve(:google_vertex,
                 fetcher: fetcher,
                 cache: false,
                 project_id: "proj-1"
               )

      refute reason =~ "secret-abc-123"
      refute reason =~ "tok-xyz"
      assert reason =~ "[REDACTED]"
    end

    test "resolves API key providers from env map" do
      env = %{
        "ANTHROPIC_API_KEY" => "sk-ant-1",
        "OPENAI_API_KEY" => "sk-openai-1",
        "OPENROUTER_API_KEY" => "sk-or-1",
        "DEEPSEEK_API_KEY" => "sk-ds-1",
        "GOOGLE_API_KEY" => "AIza-1"
      }

      assert {:ok, %{api_key: "sk-ant-1"}} = Credentials.resolve("anthropic", env: env)
      assert {:ok, %{api_key: "sk-openai-1"}} = Credentials.resolve("openai", env: env)
      assert {:ok, %{api_key: "sk-or-1"}} = Credentials.resolve("openrouter", env: env)
      assert {:ok, %{api_key: "sk-ds-1"}} = Credentials.resolve("deepseek", env: env)
      assert {:ok, %{api_key: "AIza-1"}} = Credentials.resolve("google", env: env)

      assert {:error, {:missing_env, "ANTHROPIC_API_KEY"}} =
               Credentials.resolve("anthropic", env: %{})
    end

    test "returns auth_mode :none for local ollama" do
      assert {:ok, %{auth_mode: :none}} = Credentials.resolve("ollama", env: %{})
      assert {:ok, %{auth_mode: :none}} = Credentials.resolve(:ollama, env: %{})
    end

    test "rejects unknown provider without creating atoms" do
      assert {:error, {:unsupported_provider, "never_seen_provider_xyz"}} =
               Credentials.resolve("never_seen_provider_xyz")
    end
  end

  describe "sanitize/1" do
    test "redacts sensitive map keys, bearer tokens, and known key prefixes" do
      dirty = %{
        access_token: "ya29.secret-value-1234",
        api_key: "sk-proj-secret123456",
        nested: %{"token" => "tok-999", ok: "keep-me"},
        message: "Auth header Bearer my.jwt.token failed with sk-ant-abcdef123456"
      }

      clean = Credentials.sanitize(dirty)

      assert clean.access_token == "[REDACTED]"
      assert clean.api_key == "[REDACTED]"
      assert clean.nested["token"] == "[REDACTED]"
      assert clean.nested.ok == "keep-me"
      refute clean.message =~ "my.jwt.token"
      refute clean.message =~ "sk-ant-abcdef123456"
      assert clean.message =~ "[REDACTED]"
    end

    test "Inspect for Redacted and CacheEntry hides secret values" do
      redacted = %Redacted{value: "super-secret-key"}
      entry = %CacheEntry{token: "ya29.super-secret-token", expires_at: 999_999}

      refute inspect(redacted) =~ "super-secret-key"
      refute inspect(entry) =~ "ya29.super-secret-token"
      assert inspect(entry) =~ "[REDACTED]"
    end
  end
end
