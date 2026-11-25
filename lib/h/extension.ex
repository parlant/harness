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
  @type status_projection_spec :: %{
          required(:namespace) => String.t(),
          required(:module) => module()
        }
  @type contributions :: %{
          optional(:harnesses) => [module()],
          optional(:environments) => [map()],
          optional(:codex_account_policy) => %{module: module(), sources: [String.t()]},
          optional(:observers) => [module()],
          optional(:status_projections) => [status_projection_spec()],
          optional(:children) => [Supervisor.child_spec() | {module(), term()} | module()]
        }

  @callback configure(settings :: map(), context()) :: {:ok, contributions()} | {:error, atom()}
end

defmodule H.Extension.Observer do
  @moduledoc """
  Optional advisory post-commit observer behaviour for H extensions.

  Callbacks run asynchronously in a supervised bounded consumer process off
  `H.Session.Server` strictly after durable `Storage.commit/2` succeeds.
  Delivery is advisory (may drop under saturation) and receives only
  sanitized summaries without raw prompts, commands, or credentials.
  """

  @type command_committed_event :: %{
          required(:session_id) => String.t(),
          required(:conversation_id) => String.t(),
          required(:seq) => non_neg_integer(),
          required(:command) => String.t(),
          required(:receipt) => map()
        }

  @type work_settled_event :: %{
          required(:session_id) => String.t(),
          required(:conversation_id) => String.t(),
          required(:seq) => non_neg_integer(),
          required(:task_id) => String.t(),
          required(:task_kind) => String.t(),
          required(:outcome) => map()
        }

  @callback command_committed(command_committed_event()) :: any()
  @callback work_settled(work_settled_event()) :: any()
  @optional_callbacks command_committed: 1, work_settled: 1
end

defmodule H.Extension.StatusProjection do
  @moduledoc """
  Optional read-only status projection behaviour for H extensions.

  `project/1` inspects cached extension state without making provider I/O calls
  and returns either `:omit` or `{:ok, scalar_map, max_age_ms}`.
  """

  @type scope :: %{
          required(:session_id) => String.t(),
          required(:conversation_id) => String.t(),
          required(:model) => nil | String.t()
        }

  @callback project(scope()) :: :omit | {:ok, map(), pos_integer()}
end
