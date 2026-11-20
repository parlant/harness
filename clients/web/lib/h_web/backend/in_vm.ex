defmodule HWeb.Backend.InVM do
  @moduledoc """
  In-VM `HWeb.Backend` adapter calling `H.Daemon` directly and managing
  `H.PubSub` (`Registry`) subscriptions inside the shared BEAM VM.
  """

  @behaviour HWeb.Backend

  @default_pubsub H.PubSub

  @doc "Uses the booted daemon options, with a fixture fallback when no instance is running."
  @spec daemon_opts(keyword()) :: keyword()
  def daemon_opts(opts \\ []) when is_list(opts) do
    H.Daemon.instance_options() ||
      Keyword.merge(Application.get_env(:harness_web, :daemon_opts, []), opts)
  end

  @impl HWeb.Backend
  def list_environments(opts \\ []) do
    H.Daemon.list_environments(daemon_opts(opts))
  end

  @impl HWeb.Backend
  def browse_workspace(params \\ %{}, opts \\ []) do
    H.Daemon.browse_workspace(params, daemon_opts(opts))
  end

  @impl HWeb.Backend
  def list_sessions(params \\ %{}, opts \\ []) do
    H.Daemon.list_sessions(params, daemon_opts(opts))
  end

  @impl HWeb.Backend
  def create_session(params, opts \\ []) do
    H.Daemon.create_session(params, daemon_opts(opts))
  end

  @impl HWeb.Backend
  def get_session_detail(session_id, opts \\ []) do
    H.Daemon.get_session_detail(session_id, daemon_opts(opts))
  end

  @impl HWeb.Backend
  def scan_entries(session_id, conversation_id, params \\ %{}, opts \\ []) do
    H.Daemon.scan_entries(session_id, conversation_id, params, daemon_opts(opts))
  end

  @impl HWeb.Backend
  def list_models(opts \\ []) do
    H.Daemon.list_models(daemon_opts(opts))
  end

  @impl HWeb.Backend
  def execute_command(session_id, envelope, opts \\ []) do
    H.Daemon.execute_command(session_id, envelope, daemon_opts(opts))
  end

  @impl HWeb.Backend
  def subscribe_conversation(
        session_id,
        conversation_id,
        subscriber_pid,
        last_event_id \\ nil,
        opts \\ []
      ) do
    resolved = daemon_opts(opts)

    case H.Daemon.subscribe_conversation(
           session_id,
           conversation_id,
           subscriber_pid,
           last_event_id,
           resolved
         ) do
      {:ok, result} ->
        ensure_registered(resolved, session_id, conversation_id, subscriber_pid)
        {:ok, result}

      {:error, _} = err ->
        err
    end
  end

  @impl HWeb.Backend
  def unsubscribe_conversation(session_id, conversation_id, opts \\ []) do
    resolved = daemon_opts(opts)
    pubsub = Keyword.get(resolved, :pubsub, @default_pubsub)

    with cid when is_integer(cid) <- parse_cid(conversation_id),
         true <- not is_nil(pubsub) and not is_nil(Process.whereis(pubsub)) do
      Registry.unregister(pubsub, {:conversation, session_id, cid})
    end

    :ok
  end

  defp ensure_registered(resolved, session_id, conversation_id, subscriber_pid) do
    pubsub = Keyword.get(resolved, :pubsub, @default_pubsub)

    with true <- subscriber_pid == self() and not is_nil(pubsub),
         cid when is_integer(cid) <- parse_cid(conversation_id),
         topic = {:conversation, session_id, cid},
         false <- topic in Registry.keys(pubsub, self()) do
      Registry.register(pubsub, topic, nil)
    end

    :ok
  end

  defp parse_cid(cid) when is_integer(cid) and cid > 0, do: cid

  defp parse_cid(cid) when is_binary(cid) do
    case Integer.parse(cid) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_cid(_), do: nil
end
