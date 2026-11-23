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
          required(:code) => String.t(),
          required(:message) => String.t(),
          optional(:summary) => String.t(),
          optional(:wait) => boolean(),
          optional(:wait_title) => String.t(),
          optional(:wait_detail) => String.t(),
          optional(:resumes_at_ms) => integer() | nil,
          optional(:recheck_after_ms) => pos_integer()
        }

  @type status_projection :: %{
          optional(:status_note) => String.t() | nil,
          optional(:sources) => %{optional(String.t()) => String.t()}
        }

  @callback order(model_id :: String.t(), eligible_aliases :: [String.t()]) :: [String.t()]
  @callback rejected(
              model_id :: String.t(),
              alias_id :: String.t(),
              :invalid_token | :rate_limited
            ) :: :ok
  @callback unavailable(model_id :: String.t(), eligible_aliases :: [String.t()]) ::
              unavailability() | nil
  @callback status(sources :: [String.t()]) :: status_projection()
  @optional_callbacks unavailable: 2, status: 1
end
