defmodule Extensions.MultiCodex do
  @moduledoc """
  Account selection from cached Codex quota observations. Owns no grants
  and makes no inference requests; H retains authority over every dispatch.
  """
  @behaviour H.Extension
  @behaviour H.Provider.AccountPolicy
  use GenServer

  alias __MODULE__.Usage

  @default_poll_ms 60_000
  @auth_cooldown_ms 120_000
  @probe_timeout_ms 22_000

  @impl H.Extension
  def configure(%{"sources" => sources} = settings, context) do
    poll = Map.get(settings, "poll_ms", @default_poll_ms)
    credits = Map.get(settings, "allow_credits", false)
    wait = Map.get(settings, "wait_when_exhausted", true)
    pubsub = if is_map(context), do: Map.get(context, :pubsub, H.PubSub), else: H.PubSub

    with [] <-
           Map.keys(settings) -- ["sources", "poll_ms", "allow_credits", "wait_when_exhausted"],
         {:ok, [_, _ | _], _} <- H.Accounts.Config.parse(%{"sources" => sources}),
         true <-
           is_integer(poll) and poll in 30_000..600_000 and is_boolean(credits) and
             is_boolean(wait) do
      {:ok,
       %{
         children: [
           {__MODULE__,
            sources: sources,
            poll_ms: poll,
            allow_credits: credits,
            wait_when_exhausted: wait,
            pubsub: pubsub}
         ],
         codex_account_policy: %{module: __MODULE__, sources: sources}
       }}
    else
      _ -> {:error, :invalid_multicodex_settings}
    end
  end

  def configure(_, _), do: {:error, :invalid_multicodex_settings}

  @impl H.Provider.AccountPolicy
  def order(_model, candidates), do: GenServer.call(__MODULE__, {:order, candidates}, 500)

  @impl H.Provider.AccountPolicy
  def rejected(_model, source, reason),
    do: GenServer.call(__MODULE__, {:rejected, source, reason}, 500)

  @impl H.Provider.AccountPolicy
  def unavailable(_model, candidates),
    do: GenServer.call(__MODULE__, {:unavailable, candidates}, 500)

  @impl H.Provider.AccountPolicy
  def pool_status(sources),
    do: GenServer.call(__MODULE__, {:pool_status, sources}, 500)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :tick)

    {:ok,
     %{
       sources: Keyword.fetch!(opts, :sources),
       poll_ms: Keyword.fetch!(opts, :poll_ms),
       allow_credits: Keyword.fetch!(opts, :allow_credits),
       wait_when_exhausted: Keyword.get(opts, :wait_when_exhausted, true),
       pubsub: Keyword.get(opts, :pubsub, H.PubSub),
       accounts: Keyword.get(opts, :accounts, H.Accounts),
       fetch: Keyword.get(opts, :fetch, &Usage.fetch/1),
       cache: %{},
       probe_errors: %{},
       next: [],
       job: nil,
       blocked: %{},
       discard_probe?: false
     }}
  end

  @impl GenServer
  def handle_call({:order, candidates}, _from, state) do
    now = System.monotonic_time(:millisecond)

    ranks =
      for alias_id <- candidates,
          alias_id in state.sources,
          Map.get(state.blocked, alias_id, now) <= now,
          {expires, capacity, _reset_at_ms} when expires > now <- [state.cache[alias_id]],
          rank = rank(capacity, state.allow_credits),
          rank != nil,
          do: {rank, alias_id}

    ordered = ranks |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    {:reply, ordered, state}
  end

  def handle_call({:unavailable, candidates}, _from, state) do
    now_mono = System.monotonic_time(:millisecond)
    now_sys = System.system_time(:millisecond)
    pool_candidates = Enum.filter(candidates, &(&1 in state.sources))

    result =
      if pool_candidates == [] do
        nil
      else
        fresh =
          for id <- pool_candidates,
              Map.get(state.blocked, id, now_mono) <= now_mono,
              {expires, capacity, reset_at_ms} when expires > now_mono <- [state.cache[id]],
              do: {id, capacity, reset_at_ms}

        credits_resets =
          for {_id, :credits, reset_at_ms} <- fresh, not state.allow_credits, do: reset_at_ms

        exhausted_resets = for {_id, :exhausted, reset_at_ms} <- fresh, do: reset_at_ms
        blocked_resets = for {_id, :blocked, reset_at_ms} <- fresh, do: reset_at_ms

        cooldown_remaining =
          for id <- pool_candidates,
              {:ok, until} <- [Map.fetch(state.blocked, id)],
              until > now_mono,
              do: until - now_mono

        cond do
          credits_resets != [] ->
            %{
              reason: :credits_disabled,
              wait: state.wait_when_exhausted,
              wait_until_ms: earliest_timestamp(credits_resets)
            }

          exhausted_resets != [] ->
            %{
              reason: :quota_exhausted,
              wait: state.wait_when_exhausted,
              wait_until_ms: earliest_timestamp(exhausted_resets)
            }

          blocked_resets != [] ->
            %{
              reason: :workspace_blocked,
              wait: state.wait_when_exhausted,
              wait_until_ms: earliest_timestamp(blocked_resets)
            }

          cooldown_remaining != [] ->
            %{
              reason: :auth_cooldown,
              wait: state.wait_when_exhausted,
              wait_until_ms: now_sys + Enum.min(cooldown_remaining)
            }

          state.job == nil and state.next == [] and
              Enum.all?(pool_candidates, &(state.probe_errors[&1] == :credential_unavailable)) ->
            nil

          true ->
            %{
              reason: :checking_usage,
              wait: state.wait_when_exhausted,
              wait_until_ms: nil
            }
        end
      end

    {:reply, result, state}
  end

  def handle_call({:pool_status, sources}, _from, state) do
    now_mono = System.monotonic_time(:millisecond)
    now_sys = System.system_time(:millisecond)

    statuses =
      Enum.map(sources, fn id ->
        classify_source(id, state, now_mono, now_sys)
      end)

    {:reply,
     %{
       allow_credits: state.allow_credits,
       wait_when_exhausted: state.wait_when_exhausted,
       sources: statuses
     }, state}
  end

  def handle_call({:rejected, _source, :rate_limited}, _from, state) do
    # Unknown scope: don't mark just this alias exhausted and route around it.
    # A fresh observation cycle (not this response) can re-admit accounts.
    {:reply, :ok, %{state | cache: %{}, discard_probe?: true}}
  end

  def handle_call({:rejected, source, :invalid_token}, _from, state) do
    now = System.monotonic_time(:millisecond)

    state = %{
      state
      | cache: Map.delete(state.cache, source),
        blocked: Map.put(state.blocked, source, now + @auth_cooldown_ms)
    }

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:tick, %{job: nil, next: []} = state),
    do: {:noreply, probe_next(%{state | next: state.sources, discard_probe?: false})}

  def handle_info({:observed, ref, observation}, %{job: %{ref: ref} = job} = state) do
    Process.demonitor(job.monitor, [:flush])
    Process.cancel_timer(job.timer)
    now_mono = System.monotonic_time(:millisecond)
    now_sys = System.system_time(:millisecond)

    {cache, probe_errors, eligible_now?} =
      case {state.discard_probe?, observation} do
        {false, {:ok, capacity, valid_ms}} ->
          entry = {now_mono + min(valid_ms, 2 * state.poll_ms), capacity, nil}

          {Map.put(state.cache, job.source, entry), Map.delete(state.probe_errors, job.source),
           eligible_source?(job.source, capacity, state, now_mono)}

        {false, {:ok, capacity, valid_ms, meta}} ->
          reset_at_ms =
            case is_map(meta) && meta[:reset_ms] do
              ms when is_integer(ms) and ms > 0 -> now_sys + ms
              _ -> nil
            end

          entry = {now_mono + min(valid_ms, 2 * state.poll_ms), capacity, reset_at_ms}

          {Map.put(state.cache, job.source, entry), Map.delete(state.probe_errors, job.source),
           eligible_source?(job.source, capacity, state, now_mono)}

        {_, {:error, :credential_unavailable}} ->
          {Map.delete(state.cache, job.source),
           Map.put(state.probe_errors, job.source, :credential_unavailable), false}

        _ ->
          {Map.delete(state.cache, job.source), Map.delete(state.probe_errors, job.source), false}
      end

    if eligible_now?, do: broadcast_available(state)

    {:noreply, probe_next(%{state | job: nil, cache: cache, probe_errors: probe_errors})}
  end

  def handle_info({:probe_timeout, ref}, %{job: %{ref: ref} = job} = state) do
    Process.exit(job.pid, :kill)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{job: %{monitor: monitor} = job} = state) do
    Process.cancel_timer(job.timer)

    {:noreply,
     probe_next(%{
       state
       | job: nil,
         cache: Map.delete(state.cache, job.source),
         probe_errors: Map.delete(state.probe_errors, job.source)
     })}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_, %{job: %{pid: pid}}), do: Process.exit(pid, :kill)
  def terminate(_, _), do: :ok

  defp probe_next(%{next: []} = state) do
    if any_eligible?(state), do: broadcast_available(state)
    Process.send_after(self(), :tick, state.poll_ms)
    state
  end

  defp probe_next(%{next: [source | rest]} = state) do
    ref = make_ref()
    parent = self()
    accounts = state.accounts
    fetch = state.fetch

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          Process.flag(:sensitive, true)

          result =
            with {:ok, credential} <- H.Accounts.resolve_codex(accounts, source),
                 do: fetch.(credential)

          send(parent, {:observed, ref, result})
        end,
        [:link, :monitor]
      )

    timer = Process.send_after(self(), {:probe_timeout, ref}, @probe_timeout_ms)

    %{
      state
      | job: %{monitor: monitor, pid: pid, timer: timer, source: source, ref: ref},
        next: rest
    }
  end

  defp rank({:quota, used}, _credits), do: {0, used}
  defp rank(:credits, true), do: {1, 0}
  defp rank(_, _), do: nil

  defp eligible_source?(source, capacity, state, now_mono) do
    Map.get(state.blocked, source, now_mono) <= now_mono and
      rank(capacity, state.allow_credits) != nil
  end

  defp any_eligible?(state) do
    now_mono = System.monotonic_time(:millisecond)

    Enum.any?(state.sources, fn id ->
      Map.get(state.blocked, id, now_mono) <= now_mono and
        case state.cache[id] do
          {expires, capacity, _reset_at_ms} when expires > now_mono ->
            rank(capacity, state.allow_credits) != nil

          _ ->
            false
        end
    end)
  end

  defp broadcast_available(%{pubsub: pubsub}) when not is_nil(pubsub) do
    if Process.whereis(pubsub) do
      Registry.dispatch(pubsub, {:account_pool, :openai_codex}, fn entries ->
        for {pid, _} <- entries, do: send(pid, {:account_pool_available, :openai_codex})
      end)
    end
  end

  defp broadcast_available(_state), do: :ok

  defp earliest_timestamp(timestamps) do
    timestamps
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
  end

  defp classify_source(id, state, now_mono, now_sys) do
    cooldown_until = Map.get(state.blocked, id)

    cond do
      is_integer(cooldown_until) and cooldown_until > now_mono ->
        %{id: id, eligibility: :auth_cooldown, reset_at_ms: now_sys + (cooldown_until - now_mono)}

      match?({expires, _, _} when expires > now_mono, state.cache[id]) ->
        {_expires, capacity, reset_at_ms} = state.cache[id]

        %{
          id: id,
          eligibility: capacity_eligibility(capacity, state.allow_credits),
          reset_at_ms: reset_at_ms
        }

      state.probe_errors[id] == :credential_unavailable ->
        %{id: id, eligibility: :unavailable, reset_at_ms: nil}

      true ->
        %{id: id, eligibility: :checking, reset_at_ms: nil}
    end
  end

  defp capacity_eligibility({:quota, _}, _allow_credits), do: :eligible
  defp capacity_eligibility(:credits, true), do: :credits_only
  defp capacity_eligibility(:credits, false), do: :credits_disabled
  defp capacity_eligibility(:exhausted, _allow_credits), do: :quota_exhausted
  defp capacity_eligibility(:blocked, _allow_credits), do: :workspace_blocked
  defp capacity_eligibility(_, _allow_credits), do: :unavailable
end
