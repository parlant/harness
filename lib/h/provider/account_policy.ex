defmodule H.Provider.AccountPolicy do
  @moduledoc """
  Optional account ordering for the existing Codex adapter. Return a subset
  of the supplied aliases, in preference order, using cached data only.

  Callbacks run in inference workers, never in the session coordinator. They
  get no request body, transport options, credential, or provider error body.
  A rejection notification can update state, but cannot authorize a retry.
  Rate-limit scope is unknown.
  """

  @type unavailability :: %{
          reason:
            :credits_disabled
            | :quota_exhausted
            | :workspace_blocked
            | :checking_usage
            | :auth_cooldown,
          wait: boolean(),
          wait_until_ms: integer() | nil
        }

  @type source_status :: %{
          id: String.t(),
          eligibility:
            :eligible
            | :credits_only
            | :credits_disabled
            | :quota_exhausted
            | :workspace_blocked
            | :auth_cooldown
            | :checking
            | :unavailable,
          reset_at_ms: integer() | nil
        }

  @type pool_status :: %{
          allow_credits: boolean(),
          wait_when_exhausted: boolean(),
          sources: [source_status()]
        }

  @callback order(model_id :: String.t(), eligible_aliases :: [String.t()]) :: [String.t()]
  @callback rejected(
              model_id :: String.t(),
              alias_id :: String.t(),
              :invalid_token | :rate_limited
            ) :: :ok
  @callback unavailable(model_id :: String.t(), eligible_aliases :: [String.t()]) ::
              unavailability() | nil
  @callback pool_status(sources :: [String.t()]) :: pool_status()
  @optional_callbacks unavailable: 2, pool_status: 1
end
