defmodule HWeb.ProvidersLiveTest do
  use HWeb.ConnCase, async: false

  alias H.Accounts
  alias H.Provider.Compatible

  @catalog Path.expand("../../../../../examples/providers/openai-compatible.json", __DIR__)
  @provider "example-router"

  test "owner can stage a provider without changing the running registry or key profiles", ctx do
    accounts = start_accounts(ctx, %{})
    assert {:error, {:redirect, %{to: "/login"}}} = live(ctx.conn, "/settings/providers")

    conn = log_in_owner(ctx.conn, ctx.owner_token)
    page = get(conn, "/settings/providers")
    assert page.resp_body =~ "No named providers configured yet"

    body = provider_params(page)
    assert redirected_to(post(ctx.conn, "/settings/providers", body)) == "/login"
    refute File.exists?(Path.join(ctx.data_dir, "openai-compatible.json"))

    out = post(enforce_csrf(page), "/settings/providers", body)
    assert redirected_to(out) == "/settings/providers?provider=example-router"

    assert Bitwise.band(File.stat!(Path.join(ctx.data_dir, "openai-compatible.json")).mode, 0o777) ==
             0o600

    assert {:ok, _, %{"example-router" => _} = saved} = Compatible.read(ctx.data_dir)
    updated = get(recycle(out), redirected_to(out))
    assert updated.resp_body =~ "Restart the daemon when idle"
    assert updated.resp_body =~ "Example Model Router"
    refute updated.resp_body =~ "Active key alias:"

    assert {:ok, %{providers: providers}} =
             Accounts.api_keys(accounts)

    refute Enum.any?(providers, &(&1.provider == @provider))
    refute File.exists?(Path.join(ctx.data_dir, "providers.json"))
    refute File.exists?(Path.join(ctx.data_dir, "extensions.json"))

    # Starting a new account service with startup's validated registry applies the staged catalog.
    assert :ok = stop_supervised!(Accounts)
    accounts = start_accounts(ctx, saved)
    assert {:ok, %{pending?: false}} = Accounts.provider_catalog(accounts)
    assert {:ok, %{providers: providers}} = Accounts.api_keys(accounts)
    assert %{provider: @provider, active: nil, sources: []} in providers
  end

  test "existing config is editable with stale-write and endpoint protection; keys are never rendered",
       ctx do
    path = Path.join(ctx.data_dir, "openai-compatible.json")
    File.cp!(@catalog, path)
    assert {:ok, _, running} = Compatible.read(ctx.data_dir)
    accounts = start_accounts(ctx, running)
    key = "fixture-credential-not-for-display"

    assert {:ok, _} =
             Accounts.put_api_key(accounts, %{
               "provider" => @provider,
               "source" => "work",
               "api_key" => key
             })

    conn = log_in_owner(ctx.conn, ctx.owner_token)
    page = get(conn, "/settings/providers?provider=#{@provider}")
    assert page.resp_body =~ "Edit example-router"
    assert page.resp_body =~ "Active key alias: work"
    refute page.resp_body =~ key
    refute page.resp_body =~ "id=\"provider-restart-required\""

    params = provider_params(page)

    out =
      post(
        recycle(page),
        "/settings/providers",
        put_in(params["provider"]["base_url"], "https://different.example.invalid/v1")
      )

    rejected = get(recycle(out), redirected_to(out))
    assert rejected.resp_body =~ "already bound"
    assert {:ok, _, ^running} = Compatible.read(ctx.data_dir)

    params = put_in(params["provider"]["name"], "New display name")
    out = post(recycle(page), "/settings/providers", params)
    assert redirected_to(out) == "/settings/providers?provider=example-router"
    assert {:ok, %{pending?: true}} = Accounts.provider_catalog(accounts)

    out =
      post(
        recycle(page),
        "/settings/providers",
        put_in(params["provider"]["name"], "Stale update")
      )

    result = get(recycle(out), redirected_to(out))
    assert result.resp_body =~ "catalog changed while you were editing"
    assert result.resp_body =~ "New display name"
    refute result.resp_body =~ "Stale update"
  end

  test "invalid forms are not saved or echoed in diagnostics", ctx do
    start_accounts(ctx, %{})
    conn = log_in_owner(ctx.conn, ctx.owner_token)
    page = get(conn, "/settings/providers")
    params = provider_params(page)
    fixture = "fixture-secrets-must-not-be-echoed"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        out =
          post(
            recycle(page),
            "/settings/providers",
            put_in(params["provider"]["models"], ~s({"api_key":"#{fixture}"}))
          )

        result = get(recycle(out), redirected_to(out))
        assert result.resp_body =~ "Invalid provider ID, HTTPS URL, or model catalog"
        refute result.resp_body =~ fixture
      end)

    refute log =~ fixture
    refute File.exists?(Path.join(ctx.data_dir, "openai-compatible.json"))

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(enforce_csrf(page), "/settings/providers", Map.delete(params, "_csrf_token"))
    end
  end

  defp start_accounts(ctx, running) do
    accounts =
      start_supervised!(
        {Accounts, data_dir: ctx.data_dir, sources: [], compatible_providers: running}
      )

    Application.put_env(
      :harness_web,
      :daemon_opts,
      ctx.daemon_opts
      |> Keyword.put(:accounts, accounts)
      |> Keyword.put(:compatible_providers, running)
    )

    accounts
  end

  defp enforce_csrf(page), do: put_private(recycle(page), :plug_skip_csrf_protection, false)

  defp provider_params(page) do
    doc = LazyHTML.from_document(page.resp_body)

    [csrf] =
      doc
      |> LazyHTML.query("#provider-config-form [name=_csrf_token]")
      |> LazyHTML.attribute("value")

    [revision] =
      doc |> LazyHTML.query(~s(input[name="provider[revision]"])) |> LazyHTML.attribute("value")

    example = JSON.decode!(File.read!(@catalog))["providers"][@provider]

    %{
      "_csrf_token" => csrf,
      "provider" => %{
        "id" => @provider,
        "name" => example["name"],
        "base_url" => example["base_url"],
        "models" => JSON.encode!(example["models"]),
        "revision" => revision
      }
    }
  end
end
