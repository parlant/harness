defmodule HWeb.Backend do
  @moduledoc """
  Backend contract decoupling `HWeb` LiveViews and controllers from how
  `:harness` is reached (in-VM `H.Daemon` + `H.PubSub` by default).
  """

  @callback list_environments(keyword()) :: [map()]
  @callback browse_workspace(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback list_sessions(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback create_session(map(), keyword()) ::
              {:ok, %{session: map(), seq: non_neg_integer()}} | {:error, term()}
  @callback get_session_detail(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback scan_entries(String.t(), term(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback list_models(keyword()) :: [map()]
  @callback execute_command(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback subscribe_conversation(String.t(), term(), pid(), term(), keyword()) ::
              {:ok,
               {:snapshot, non_neg_integer(), binary()}
               | {:replay, [{non_neg_integer(), binary()}]}}
              | {:error, term()}
  @callback unsubscribe_conversation(String.t(), term(), keyword()) :: :ok

  @doc "Returns the configured backend adapter module."
  @spec impl() :: module()
  def impl do
    Application.get_env(:harness_web, :backend, HWeb.Backend.InVM)
  end

  def list_environments(opts \\ []), do: impl().list_environments(opts)

  def browse_workspace(params \\ %{}, opts \\ []), do: impl().browse_workspace(params, opts)

  def list_sessions(params \\ %{}, opts \\ []), do: impl().list_sessions(params, opts)

  def create_session(params, opts \\ []), do: impl().create_session(params, opts)

  def get_session_detail(session_id, opts \\ []), do: impl().get_session_detail(session_id, opts)

  def scan_entries(session_id, conversation_id, params \\ %{}, opts \\ []),
    do: impl().scan_entries(session_id, conversation_id, params, opts)

  def list_models(opts \\ []), do: impl().list_models(opts)

  def execute_command(session_id, envelope, opts \\ []),
    do: impl().execute_command(session_id, envelope, opts)

  def subscribe_conversation(
        session_id,
        conversation_id,
        subscriber_pid,
        last_event_id \\ nil,
        opts \\ []
      ),
      do:
        impl().subscribe_conversation(
          session_id,
          conversation_id,
          subscriber_pid,
          last_event_id,
          opts
        )

  def unsubscribe_conversation(session_id, conversation_id, opts \\ []),
    do: impl().unsubscribe_conversation(session_id, conversation_id, opts)
end
