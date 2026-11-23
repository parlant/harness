defmodule Extensions.MultiCodexTest do
  use ExUnit.Case, async: false

  alias Extensions.MultiCodex
  alias Extensions.MultiCodex.Usage

  test "only accepts an explicit pool of at least two configured aliases" do
    assert {:error, :invalid_multicodex_settings} =
             MultiCodex.configure(%{"sources" => ["one"]}, %{})

    assert {:error, :invalid_multicodex_settings} =
             MultiCodex.configure(
               %{"sources" => ["one", "two"], "wait_when_exhausted" => "yes"},
               %{}
             )

    assert {:ok,
            %{
              codex_account_policy: %{sources: ["one", "two"], module: MultiCodex},
              children: [{MultiCodex, child_opts}]
            }} =
             MultiCodex.configure(
               %{"sources" => ["one", "two"], "wait_when_exhausted" => false},
               %{pubsub: :custom_pubsub}
             )

    assert child_opts[:wait_when_exhausted] == false
    assert child_opts[:pubsub] == :custom_pubsub
  end

  test "usage is based on explicit windows, explicit credits, and workspace spend limits" do
    now = 1000

    body = %{
      "rate_limit" => %{
        "allowed" => true,
        "limit_reached" => false,
        "primary_window" => %{"used_percent" => 30, "reset_at" => now + 10},
        "secondary_window" => %{"used_percent" => 20, "reset_at" => now + 100}
      }
    }

    assert Usage.parse(body, now) == {:ok, {:quota, 30}, 10_000}
    assert Usage.parse_detailed(body, now) == {:ok, {:quota, 30}, 10_000, %{reset_ms: nil}}

    exhausted = put_in(body["rate_limit"]["limit_reached"], true)
    assert Usage.parse(exhausted, now) == {:ok, :exhausted, 10_000}
    assert Usage.parse_detailed(exhausted, now) == {:ok, :exhausted, 10_000, %{reset_ms: 10_000}}

    weekly_exhausted =
      body
      |> put_in(["rate_limit", "primary_window", "used_percent"], 45)
      |> put_in(["rate_limit", "secondary_window"], %{
        "used_percent" => 100,
        "reset_at" => now + 500
      })

    assert Usage.parse_detailed(weekly_exhausted, now) ==
             {:ok, :exhausted, 10_000, %{reset_ms: 500_000}}

    weekly_credits = Map.put(weekly_exhausted, "credits", %{"has_credits" => true})

    assert Usage.parse(weekly_credits, now) == {:ok, :credits, 10_000}

    assert Usage.parse_detailed(weekly_credits, now) ==
             {:ok, :credits, 10_000, %{reset_ms: 500_000}}

    credits = Map.put(exhausted, "credits", %{"has_credits" => true})
    assert Usage.parse(credits, now) == {:ok, :credits, 10_000}

    assert Usage.parse(
             Map.put(credits, "rate_limit_reached_type", %{"type" => "future_limit"}),
             now
           ) == :unavailable

    spend_blocked =
      Map.put(credits, "spend_control", %{
        "reached" => true,
        "individual_limit" => %{"reset_after_seconds" => 900}
      })

    assert Usage.parse(spend_blocked, now) == {:ok, :blocked, 10_000}

    assert Usage.parse_detailed(spend_blocked, now) ==
             {:ok, :blocked, 10_000, %{reset_ms: 900_000}}

    assert Usage.parse(Map.put(credits, "spend_control", %{"reached" => true}), now) ==
             {:ok, :blocked, 10_000}

    assert Usage.parse(%{"rate_limit" => %{}, "credits" => %{"has_credits" => true}}, now) ==
             :unavailable
  end

  test "observes credentials independently, ranks quota before opted-in credits, and excludes a rejected alias" do
    dir = Path.join(System.tmp_dir!(), "multicodex-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    sources = ~w(full light credits)
    {:ok, vault, _} = H.Accounts.Vault.open(dir, [])

    for source <- sources do
      :ok =
        H.Accounts.Vault.write(vault, source, %{
          "account_id" => source,
          "subject" => source,
          "access_token" => "token-#{source}",
          "refresh_token" => "refresh-#{source}",
          "expires_at_ms" => System.system_time(:millisecond) + 120_000
        })
    end

    accounts =
      start_supervised!(
        {H.Accounts,
         sources: sources, data_dir: dir, http: fn _ -> flunk("unexpected authentication") end}
      )

    test = self()

    fetch = fn %{account_id: source} ->
      send(test, {:probe, source})
      capacity = %{"full" => {:quota, 60}, "light" => {:quota, 10}, "credits" => :credits}[source]
      {:ok, capacity, 10_000}
    end

    opts = [sources: sources, accounts: accounts, poll_ms: 30_000, fetch: fetch]
    start_supervised!({MultiCodex, opts ++ [allow_credits: false]})
    assert_receive {:probe, "credits"}, 1000
    assert_order(sources, ["light", "full"])
    :ok = stop_supervised!(MultiCodex)
    start_supervised!({MultiCodex, opts ++ [allow_credits: true]})
    assert_receive {:probe, "credits"}, 1000
    assert_order(sources, ["light", "full", "credits"])
    assert MultiCodex.rejected("model", "light", :invalid_token) == :ok
    assert MultiCodex.order("model", sources) == ["full", "credits"]
    assert MultiCodex.order("model", ["not-configured"]) == []
    assert MultiCodex.rejected("model", "full", :rate_limited) == :ok
    assert MultiCodex.order("model", sources) == []
  end

  test "reports unavailable diagnostics, pool_status, wait_when_exhausted: false, and broadcasts PubSub wake on recovery" do
    dir = Path.join(System.tmp_dir!(), "multicodex-diag-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)

    sources = ~w(first second)
    {:ok, vault, _} = H.Accounts.Vault.open(dir, [])

    for source <- sources do
      :ok =
        H.Accounts.Vault.write(vault, source, %{
          "account_id" => source,
          "subject" => source,
          "access_token" => "token-#{source}",
          "refresh_token" => "refresh-#{source}",
          "expires_at_ms" => System.system_time(:millisecond) + 120_000
        })
    end

    accounts =
      start_supervised!(
        {H.Accounts,
         sources: sources, data_dir: dir, http: fn _ -> flunk("unexpected authentication") end}
      )

    pubsub = :"multicodex_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    {:ok, _} = Registry.register(pubsub, {:account_pool, :openai_codex}, nil)

    phase = :atomics.new(1, [])
    :atomics.put(phase, 1, 1)
    test = self()

    fetch = fn %{account_id: source} ->
      send(test, {:probe, source, :atomics.get(phase, 1)})

      case {:atomics.get(phase, 1), source} do
        {1, "first"} -> {:ok, :credits, 30_000, %{reset_ms: 120_000}}
        {1, "second"} -> {:ok, :credits, 30_000, %{reset_ms: 60_000}}
        {2, _} -> {:ok, {:quota, 15}, 30_000, %{reset_ms: nil}}
      end
    end

    start_supervised!(
      {MultiCodex,
       sources: sources,
       accounts: accounts,
       poll_ms: 30_000,
       allow_credits: false,
       wait_when_exhausted: true,
       pubsub: pubsub,
       fetch: fetch}
    )

    assert_receive {:probe, "second", 1}, 1_000
    assert_order(sources, [])

    diag = MultiCodex.unavailable("openai_codex:gpt-6.2-sol", sources)
    assert diag.reason == :credits_disabled
    assert diag.wait == true
    assert is_integer(diag.wait_until_ms)
    now_sys = System.system_time(:millisecond)
    assert diag.wait_until_ms > now_sys + 40_000 and diag.wait_until_ms < now_sys + 80_000

    status = MultiCodex.pool_status(sources)
    assert status.allow_credits == false
    assert status.wait_when_exhausted == true

    assert [
             %{id: "first", eligibility: :credits_disabled, reset_at_ms: first_reset},
             %{id: "second", eligibility: :credits_disabled, reset_at_ms: second_reset}
           ] = status.sources

    assert first_reset > second_reset
    refute_receive {:account_pool_available, :openai_codex}, 50

    # Flip probe to eligible quota and trigger a fresh poll tick.
    :atomics.put(phase, 1, 2)
    send(Process.whereis(MultiCodex), :tick)

    assert_receive {:probe, "first", 2}, 1_000
    assert_receive {:account_pool_available, :openai_codex}, 1_000
    assert_order(sources, ["first", "second"])

    recovered_status = MultiCodex.pool_status(sources)

    assert [
             %{id: "first", eligibility: :eligible, reset_at_ms: nil},
             %{id: "second", eligibility: :eligible, reset_at_ms: nil}
           ] = recovered_status.sources

    # Verify auth_cooldown diagnostic + wait_when_exhausted: false
    :ok = stop_supervised!(MultiCodex)

    start_supervised!(
      {MultiCodex,
       sources: sources,
       accounts: accounts,
       poll_ms: 30_000,
       allow_credits: false,
       wait_when_exhausted: false,
       pubsub: pubsub,
       fetch: fn %{account_id: source} ->
         send(test, {:probe_no_wait, source})
         {:ok, :exhausted, 30_000, %{reset_ms: 30_000}}
       end}
    )

    assert_receive {:probe_no_wait, "second"}, 1_000
    assert_order(sources, [])

    no_wait_diag = MultiCodex.unavailable("openai_codex:gpt-6.2-sol", sources)
    assert no_wait_diag.reason == :quota_exhausted
    assert no_wait_diag.wait == false
    assert is_integer(no_wait_diag.wait_until_ms)

    assert MultiCodex.rejected("openai_codex:gpt-6.2-sol", "first", :invalid_token) == :ok
    assert MultiCodex.rejected("openai_codex:gpt-6.2-sol", "second", :invalid_token) == :ok

    cooldown_diag = MultiCodex.unavailable("openai_codex:gpt-6.2-sol", sources)
    assert cooldown_diag.reason == :auth_cooldown
    assert cooldown_diag.wait == false
    assert cooldown_diag.wait_until_ms > System.system_time(:millisecond)
  end

  test "returns nil unavailable when all pooled aliases lack credentials" do
    dir = Path.join(System.tmp_dir!(), "multicodex-unauth-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)

    sources = ~w(a b)

    accounts =
      start_supervised!(
        {H.Accounts,
         sources: sources, data_dir: dir, http: fn _ -> flunk("unexpected authentication") end}
      )

    start_supervised!(
      {MultiCodex,
       sources: sources,
       accounts: accounts,
       poll_ms: 30_000,
       allow_credits: false,
       fetch: fn _ -> flunk("should not fetch without credentials") end}
    )

    wait_until(fn ->
      MultiCodex.unavailable("openai_codex:gpt-6.2-sol", sources) == nil
    end)

    assert %{
             allow_credits: false,
             wait_when_exhausted: true,
             sources: [
               %{id: "a", eligibility: :unavailable, reset_at_ms: nil},
               %{id: "b", eligibility: :unavailable, reset_at_ms: nil}
             ]
           } = MultiCodex.pool_status(sources)
  end

  defp wait_until(fun, tries \\ 100) do
    if fun.() or tries == 0 do
      assert fun.()
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end

  defp assert_order(candidates, expected, tries \\ 50) do
    order = MultiCodex.order("model", candidates)

    if order == expected or tries == 0 do
      assert order == expected
    else
      Process.sleep(10)
      assert_order(candidates, expected, tries - 1)
    end
  end
end
