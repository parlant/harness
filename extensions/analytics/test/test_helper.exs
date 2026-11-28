{:ok, _} = Application.ensure_all_started(:phoenix_live_view)
{:ok, _} = Application.ensure_all_started(:plug_crypto)
{:ok, _} = Application.ensure_all_started(:bandit)
ExUnit.start()
