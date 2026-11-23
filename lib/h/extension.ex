defmodule H.Extension do
  @moduledoc """
  Startup contract for a trusted, locally built H extension (API 1).

  `configure/2` validates JSON settings and declares existing H registrations
  and supervised children. It must not start processes or perform effects.
  Children start under the daemon's store lock, before session recovery. Their
  initialization must not replay work just because a process started again.
  `:codex_account_policy` is an optional, unique `H.Provider.AccountPolicy`
  contribution for aliases already configured in `accounts.json`.

  Follow [Write a startup extension on hiness.dev](https://hiness.dev/docs/extensions/)
  to build and register an extension artifact.
  """

  @type context :: %{
          required(:id) => String.t(),
          required(:data_dir) => String.t(),
          optional(:pubsub) => atom()
        }
  @type contributions :: %{
          optional(:harnesses) => [module()],
          optional(:environments) => [map()],
          optional(:codex_account_policy) => %{module: module(), sources: [String.t()]},
          optional(:children) => [Supervisor.child_spec() | {module(), term()} | module()]
        }

  @callback configure(settings :: map(), context()) :: {:ok, contributions()} | {:error, atom()}
end
