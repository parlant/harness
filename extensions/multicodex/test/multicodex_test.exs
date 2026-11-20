defmodule Extensions.MultiCodexTest do
  use ExUnit.Case, async: false

  alias Extensions.MultiCodex
  alias Extensions.MultiCodex.Usage

  test "only accepts an explicit pool of at least two configured aliases" do
    assert {:error, :invalid_multicodex_settings} =
             MultiCodex.configure(%{"sources" => ["one"]}, %{})

    assert {:ok, %{codex_account_policy: %{sources: ["one", "two"], module: MultiCodex}}} =
             MultiCodex.configure(%{"sources" => ["one", "two"]}, %{})
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
    exhausted = put_in(body["rate_limit"]["limit_reached"], true)
    assert Usage.parse(exhausted, now) == :unavailable
    credits = Map.put(exhausted, "credits", %{"has_credits" => true})
    assert Usage.parse(credits, now) == {:ok, :credits, 10_000}

    assert Usage.parse(
             Map.put(credits, "rate_limit_reached_type", %{"type" => "future_limit"}),
             now
           ) == :unavailable

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
