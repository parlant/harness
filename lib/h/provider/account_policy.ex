defmodule H.Provider.AccountPolicy do
  @moduledoc """
  Optional account ordering for the existing Codex adapter. Return a subset
  of the supplied aliases, in preference order, using cached data only.

  Callbacks run in inference workers, never in the session coordinator. They
  get no request body, transport options, credential, or provider error body.
  A rejection notification can update state, but cannot authorize a retry.
  Rate-limit scope is unknown.
  """

  @callback order(model_id :: String.t(), eligible_aliases :: [String.t()]) :: [String.t()]
  @callback rejected(
              model_id :: String.t(),
              alias_id :: String.t(),
              :invalid_token | :rate_limited
            ) :: :ok
end
