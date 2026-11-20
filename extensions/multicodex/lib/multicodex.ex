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
  def configure(%{"sources" => sources} = settings, _context) do
    poll = Map.get(settings, "poll_ms", @default_poll_ms)
    credits = Map.get(settings, "allow_credits", false)

    with [] <- Map.keys(settings) -- ["sources", "poll_ms", "allow_credits"],
         {:ok, [_, _ | _], _} <- H.Accounts.Config.parse(%{"sources" => sources}),
         true <- is_integer(poll) and poll in 30_000..600_000 and is_boolean(credits) do
      {:ok,
       %{
         children: [{__MODULE__, sources: sources, poll_ms: poll, allow_credits: credits}],
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
       accounts: Keyword.get(opts, :accounts, H.Accounts),
       fetch: Keyword.get(opts, :fetch, &Usage.fetch/1),
       cache: %{},
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
          Map.get(state.blocked, alias_id, now) <= now,
          {expires, capacity} when expires > now <- [state.cache[alias_id]],
          rank = rank(capacity, state.allow_credits),
          rank != nil,
          do: {rank, alias_id}

    ordered = ranks |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    {:reply, ordered, state}
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
    now = System.monotonic_time(:millisecond)

    cache =
      case {state.discard_probe?, observation} do
        {false, {:ok, capacity, valid_ms}} ->
          Map.put(state.cache, job.source, {now + min(valid_ms, 2 * state.poll_ms), capacity})

        _ ->
          Map.delete(state.cache, job.source)
      end

    {:noreply, probe_next(%{state | job: nil, cache: cache})}
  end

  def handle_info({:probe_timeout, ref}, %{job: %{ref: ref} = job} = state) do
    Process.exit(job.pid, :kill)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{job: %{monitor: monitor} = job} = state) do
    Process.cancel_timer(job.timer)
    {:noreply, probe_next(%{state | job: nil, cache: Map.delete(state.cache, job.source)})}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_, %{job: %{pid: pid}}), do: Process.exit(pid, :kill)
  def terminate(_, _), do: :ok

  defp probe_next(%{next: []} = state) do
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
end
