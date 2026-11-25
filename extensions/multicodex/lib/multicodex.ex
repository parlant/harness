defmodule Extensions.MultiCodex do
  @moduledoc """
  Account selection from cached Codex quota observations. Owns no grants
  and makes no inference requests; H retains authority over every dispatch.
  """
  @behaviour H.Extension
  @behaviour H.Extension.StatusProjection
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
         codex_account_policy: %{module: __MODULE__, sources: sources},
         status_projections: [%{namespace: "account_pool", module: __MODULE__}]
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
  def status(sources),
    do: GenServer.call(__MODULE__, {:status, sources}, 500)

  @impl H.Extension.StatusProjection
  def project(scope) when is_map(scope) do
    if Process.whereis(__MODULE__) do
      try do
        GenServer.call(__MODULE__, {:project_status, scope}, 250)
      catch
        :exit, _ -> :omit
      end
    else
      :omit
    end
  end

  def project(_), do: :omit

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
            build_unavailable(
              :credits_disabled,
              earliest_timestamp(credits_resets),
              state,
              now_sys
            )

          exhausted_resets != [] ->
            build_unavailable(
              :quota_exhausted,
              earliest_timestamp(exhausted_resets),
              state,
              now_sys
            )

          blocked_resets != [] ->
            build_unavailable(
              :workspace_blocked,
              earliest_timestamp(blocked_resets),
              state,
              now_sys
            )

          cooldown_remaining != [] ->
            build_unavailable(
              :auth_cooldown,
              now_sys + Enum.min(cooldown_remaining),
              state,
              now_sys
            )

          state.job == nil and state.next == [] and
              Enum.all?(pool_candidates, &(state.probe_errors[&1] == :credential_unavailable)) ->
            nil

          true ->
            build_unavailable(:checking_usage, nil, state, now_sys)
        end
      end

    {:reply, result, state}
  end

  def handle_call({:status, sources}, _from, state) do
    now_mono = System.monotonic_time(:millisecond)
    now_sys = System.system_time(:millisecond)

    source_notes =
      sources
      |> Enum.filter(&(&1 in state.sources))
      |> Map.new(fn id ->
        {id, format_source_note(id, state, now_mono, now_sys)}
      end)

    {:reply,
     %{
       status_note: format_provider_status_note(state),
       sources: source_notes
     }, state}
  end

  def handle_call({:project_status, _scope}, _from, state) do
    {:reply, build_status_projection(state), state}
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
      topic = "account_policy:openai_codex"

      Registry.dispatch(pubsub, {:wait_signal, topic}, fn entries ->
        for {pid, _} <- entries, do: send(pid, {:wait_signal, topic})
      end)
    end
  end

  defp broadcast_available(_state), do: :ok

  defp earliest_timestamp(timestamps) do
    timestamps
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
  end

  defp build_unavailable(reason, resumes_at_ms, state, now_sys) do
    {code, message, summary} = unavailable_copy(reason, resumes_at_ms, now_sys)

    diag = %{
      code: code,
      message: message,
      summary: summary,
      wait: state.wait_when_exhausted,
      wait_title: "Waiting for eligible Codex account",
      wait_detail: "Will continue automatically when an account becomes eligible.",
      resumes_at_ms: resumes_at_ms,
      recheck_after_ms: recheck_after_ms(reason, resumes_at_ms, now_sys)
    }

    diag
  end

  defp unavailable_copy(:credits_disabled, resumes_at_ms, now_sys) do
    suffix = format_wait_suffix("resets in", resumes_at_ms, now_sys)

    {"codex_pool_credits_disabled",
     "Included Codex quota is exhausted on all pooled accounts#{suffix}; workspace credits are available, but allow_credits is false in extensions.json.",
     "Codex pool included quota exhausted (allow_credits: false)"}
  end

  defp unavailable_copy(:quota_exhausted, resumes_at_ms, now_sys) do
    suffix = format_wait_suffix("resets in", resumes_at_ms, now_sys)

    {"codex_pool_quota_exhausted", "Codex quota is exhausted on all pooled accounts#{suffix}.",
     "Codex pool quota exhausted"}
  end

  defp unavailable_copy(:workspace_blocked, resumes_at_ms, now_sys) do
    suffix = format_wait_suffix("resets in", resumes_at_ms, now_sys)

    {"codex_pool_workspace_blocked",
     "Codex workspace spend or usage limit is reached on all pooled accounts#{suffix}.",
     "Codex pool workspace limit reached"}
  end

  defp unavailable_copy(:auth_cooldown, resumes_at_ms, now_sys) do
    suffix = format_wait_suffix("ready in", resumes_at_ms, now_sys)

    {"codex_pool_auth_cooldown",
     "Pooled Codex accounts are cooling down after an authentication rejection#{suffix}.",
     "Codex pool cooling down after auth error"}
  end

  defp unavailable_copy(:checking_usage, _resumes_at_ms, _now_sys) do
    {"codex_pool_checking_usage",
     "Checking Codex account pool usage; waiting for an eligible account.", nil}
  end

  defp recheck_after_ms(:checking_usage, _resumes_at_ms, _now_sys), do: 5_000

  defp recheck_after_ms(:auth_cooldown, resumes_at_ms, now_sys) do
    remaining = (resumes_at_ms || now_sys + 15_000) - now_sys
    clamp(remaining, 1_000, 125_000)
  end

  defp recheck_after_ms(_reason, resumes_at_ms, now_sys) do
    remaining = (resumes_at_ms || now_sys + 60_000) - now_sys
    clamp(remaining, 5_000, 300_000)
  end

  defp clamp(val, min_val, max_val), do: val |> max(min_val) |> min(max_val)

  defp build_status_projection(state) do
    now_mono = System.monotonic_time(:millisecond)

    {eligible_count, min_remaining_ms, has_fresh?} =
      Enum.reduce(state.sources, {0, nil, false}, fn id, {count, min_rem, fresh?} ->
        blocked_until = Map.get(state.blocked, id)
        is_blocked? = is_integer(blocked_until) and blocked_until > now_mono

        case state.cache[id] do
          {expires, capacity, _reset_at_ms} when expires > now_mono ->
            rem_ms = expires - now_mono
            next_min = if is_nil(min_rem), do: rem_ms, else: min(min_rem, rem_ms)

            eligible? = not is_blocked? and rank(capacity, state.allow_credits) != nil
            next_count = if eligible?, do: count + 1, else: count
            {next_count, next_min, true}

          _ ->
            {count, min_rem, fresh?}
        end
      end)

    cond do
      not has_fresh? ->
        :omit

      eligible_count > 0 ->
        {:ok, %{"state" => "available", "eligible_sources" => eligible_count}, min_remaining_ms}

      true ->
        {:ok, %{"state" => "unavailable", "eligible_sources" => 0}, min_remaining_ms}
    end
  end

  defp format_provider_status_note(state) do
    credits_label = if state.allow_credits, do: "credits enabled", else: "credits disabled"
    wait_label = if state.wait_when_exhausted, do: "auto-wait on", else: "auto-wait off"
    "Managed by MultiCodex pool (overrides stock active) · #{credits_label} · #{wait_label}"
  end

  defp format_source_note(id, state, now_mono, now_sys) do
    cooldown_until = Map.get(state.blocked, id)

    cond do
      is_integer(cooldown_until) and cooldown_until > now_mono ->
        suffix = format_wait_suffix("ready in", now_sys + (cooldown_until - now_mono), now_sys)
        "pool: auth cooldown#{suffix}"

      match?({expires, _, _} when expires > now_mono, state.cache[id]) ->
        {_expires, capacity, reset_at_ms} = state.cache[id]
        base = capacity_note(capacity, state.allow_credits)
        suffix = format_wait_suffix("resets in", reset_at_ms, now_sys)
        base <> suffix

      state.probe_errors[id] == :credential_unavailable ->
        "pool: unavailable"

      true ->
        "pool: checking"
    end
  end

  defp capacity_note({:quota, _}, _allow_credits), do: "pool: eligible"
  defp capacity_note(:credits, true), do: "pool: credits only"
  defp capacity_note(:credits, false), do: "pool: credits disabled"
  defp capacity_note(:exhausted, _allow_credits), do: "pool: quota exhausted"
  defp capacity_note(:blocked, _allow_credits), do: "pool: workspace blocked"
  defp capacity_note(_, _allow_credits), do: "pool: unavailable"

  defp format_wait_suffix(verb, wait_until_ms, now_sys)
       when is_integer(wait_until_ms) and wait_until_ms > now_sys do
    " (#{verb} #{format_duration_ms(wait_until_ms - now_sys)})"
  end

  defp format_wait_suffix(_verb, _wait_until_ms, _now_sys), do: ""

  defp format_duration_ms(ms) when ms > 0 do
    total_seconds = max(1, ceil(ms / 1_000))
    hours = div(total_seconds, 3_600)
    minutes = div(rem(total_seconds, 3_600), 60)
    seconds = rem(total_seconds, 60)

    cond do
      hours > 0 and minutes > 0 -> "#{hours}h #{minutes}m"
      hours > 0 -> "#{hours}h"
      minutes > 0 and seconds > 0 -> "#{minutes}m #{seconds}s"
      minutes > 0 -> "#{minutes}m"
      true -> "#{seconds}s"
    end
  end
end
