defmodule H.Accounts do
  @moduledoc """
  Daemon-owned named accounts and login operations. Inference workers can
  resolve a credential; owner clients get only an explicitly projected view.
  """

  use GenServer

  alias H.Accounts.{Codex, Config, Vault}
  alias H.Provider.Compatible

  @login_ttl 900_000
  @retention 60_000
  @max_receipts 32
  @refresh_margin 30_000
  @refresh_timeout 14_000
  @max_waiters 64

  def boot(opts) do
    dir = Keyword.fetch!(opts, :data_dir)

    with {:ok, sources, active} <- Config.read(dir) do
      {:ok, Keyword.put(opts, :accounts, __MODULE__),
       [
         {__MODULE__,
          data_dir: dir,
          sources: sources,
          active: active,
          name: __MODULE__,
          compatible_providers: opts[:compatible_providers] || %{}}
       ]}
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def discover(server, policy \\ nil)
  def discover(nil, _policy), do: {:ok, %{providers: []}}

  def discover(server, policy) do
    case call(server, :discover) do
      {:ok, %{providers: providers} = payload} when is_map(policy) ->
        status = fetch_policy_status(policy)

        updated =
          Enum.map(providers, fn
            %{id: "openai_codex"} = provider when is_map(status) ->
              apply_provider_status(provider, status)

            provider ->
              provider
          end)

        {:ok, %{payload | providers: updated}}

      other ->
        other
    end
  end

  @doc "Returns whether managed credentials are configured without refreshing anything."
  def configured?(server) when is_pid(server), do: call(server, :configured) != false

  def configured?(server) when is_atom(server) do
    # The daemon owns and writes this marker, never a client. A single ETS
    # lookup avoids blocking a session coordinator behind a vault file sync.
    case :ets.whereis(server) do
      :undefined -> true
      table -> :ets.lookup_element(table, :configured, 2, true)
    end
  end

  @doc false
  def key_providers(server) when is_atom(server) do
    :ets.lookup_element(server, :key_providers, 2, [])
  rescue
    ArgumentError -> []
  end

  def key_providers(server), do: call(server, :key_providers)

  def api_keys(server), do: call(server, :api_keys)

  @doc "Returns the validated, credential-free startup catalog and whether changes are pending."
  def provider_catalog(server), do: call(server, :provider_catalog)

  @doc "Stages one named provider for the next daemon boot without rebinding existing URLs."
  def stage_provider(server, params) do
    with {:ok, edit} <- Compatible.parse_edit(params),
         do: call(server, {:stage_provider, edit})
  end

  def put_api_key(
        server,
        %{"provider" => provider, "source" => source, "api_key" => key} = params
      )
      when map_size(params) == 3 do
    if Config.valid_source?(provider) and Config.valid_source?(source) and
         Vault.api_key?(key) do
      call(server, {:put_api_key, provider, source, %H.Credentials.Redacted{value: key}})
    else
      {:error, :invalid_api_key_profile}
    end
  end

  def put_api_key(_server, _params), do: {:error, :invalid_api_key_profile}

  def use_api_key(server, %{"provider" => provider, "source" => source} = params)
      when map_size(params) == 2 do
    if Config.valid_source?(provider) and Config.valid_source?(source),
      do: call(server, {:use_api_key, provider, source}),
      else: {:error, :invalid_api_key_profile}
  end

  def use_api_key(_server, _params), do: {:error, :invalid_api_key_profile}

  @doc "Removes a stored API key alias for `provider` (reassigning active or dropping provider)."
  def remove_api_key(server, %{"provider" => provider, "source" => source} = params)
      when map_size(params) == 2 do
    if Config.valid_source?(provider) and Config.valid_source?(source),
      do: call(server, {:remove_api_key, provider, source}),
      else: {:error, :invalid_api_key_profile}
  end

  def remove_api_key(_server, _params), do: {:error, :invalid_api_key_profile}

  @doc false
  def resolve_api_key(server, provider) when is_atom(provider),
    do: resolve_api_key(server, Atom.to_string(provider))

  def resolve_api_key(server, provider) when is_binary(provider),
    do: call(server, {:api_key, provider})

  @doc false
  def codex_status(server, sources), do: call(server, {:codex_status, sources})

  def add(server, %{"source" => source} = params) when map_size(params) == 1 do
    if Config.valid_source?(source),
      do: call(server, {:add, source}),
      else: {:error, :invalid_login_request}
  end

  def add(_server, _params), do: {:error, :invalid_login_request}

  def start(server, %{"provider" => provider, "request_id" => id} = params)
      when provider in ["openai_codex", "openai-codex"] and is_binary(id) and
             byte_size(id) in 1..80 do
    source = params["source"]

    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id) and
         (is_nil(source) or Config.valid_source?(source)) and
         Map.keys(params) -- ["provider", "request_id", "source"] == [] do
      call(server, {:start, id, source})
    else
      {:error, :invalid_login_request}
    end
  end

  def start(_server, _params), do: {:error, :invalid_login_request}

  def operation(server, action, %{"operation" => ref} = params)
      when action in [:status, :cancel] and map_size(params) == 1 and is_binary(ref) and
             byte_size(ref) == 43 do
    call(server, {action, ref})
  end

  def operation(_server, _action, _params), do: {:error, :invalid_login_request}

  @doc "Persists the stock account selection for future requests."
  def activate(server, %{"source" => source} = params) when map_size(params) == 1 do
    if Config.valid_source?(source),
      do: call(server, {:activate, source}),
      else: {:error, :invalid_login_request}
  end

  def activate(_server, _params), do: {:error, :invalid_login_request}

  @doc "Removes a Codex account source alias and its credential file from the vault."
  def remove(server, %{"source" => source} = params) when map_size(params) == 1 do
    if Config.valid_source?(source),
      do: call(server, {:remove, source}),
      else: {:error, :invalid_login_request}
  end

  def remove(_server, _params), do: {:error, :invalid_login_request}

  @doc "Resolves one named Codex credential (or the active stock account); never falls through."
  def resolve_codex(
        server,
        source \\ :active,
        deadline \\ System.monotonic_time(:millisecond) + 15_000
      ) do
    call(server, {:credential, source, deadline}, max(1, deadline - monotonic_ms()))
  end

  defp call(server, msg, timeout \\ 3_000)
  defp call(nil, _msg, _timeout), do: {:error, :login_unavailable}

  defp call(server, msg, timeout) do
    GenServer.call(server, msg, timeout)
  catch
    :exit, _ -> {:error, :accounts_unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Process.flag(:sensitive, true)
    sources = Keyword.fetch!(opts, :sources)

    dir = Keyword.fetch!(opts, :data_dir)

    compatible_providers = Keyword.get(opts, :compatible_providers, %{})
    providers = Enum.sort(H.Credentials.api_key_providers() ++ Map.keys(compatible_providers))

    result =
      with {:ok, vault, credentials} <- Vault.open(dir, sources),
           {:ok, keys} <- Vault.read_api_keys(vault),
           do: {:ok, vault, credentials, keys}

    case result do
      {:ok, vault, credentials, keys} ->
        table = if name = opts[:name], do: :ets.new(name, [:named_table, :protected])

        if table do
          :ets.insert(table, [{:configured, sources != []}, {:key_providers, Map.keys(keys)}])
        end

        {:ok,
         %{
           dir: dir,
           table: table,
           sources: sources,
           active: Keyword.get(opts, :active, List.first(sources)),
           vault: vault,
           credentials: credentials,
           keys: keys,
           key_providers: providers,
           compatible_providers: compatible_providers,
           http: Keyword.get(opts, :http, &Req.post/1),
           ttl: Keyword.get(opts, :login_ttl, @login_ttl),
           poll_cap: Keyword.get(opts, :test_poll_cap, 120_000),
           login: nil,
           receipts: %{},
           refreshes: %{}
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:state, :redacted)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
  end

  @impl true
  def handle_call(:idle, _from, state),
    do: {:reply, is_nil(state.login) and map_size(state.refreshes) == 0, state}

  def handle_call(:drained, _from, state),
    do: {:reply, map_size(state.refreshes) == 0, state}

  def handle_call(:active_refresh_count, _from, state),
    do: {:reply, map_size(state.refreshes), state}

  def handle_call(:key_providers, _from, state), do: {:reply, Map.keys(state.keys), state}

  def handle_call({:codex_status, pool}, _from, state) do
    sources = if pool, do: Enum.filter(pool, &(&1 in state.sources)), else: [state.active]

    status =
      cond do
        sources == [] and state.sources != [] -> :alias_mismatch
        Enum.any?(sources, &match?(%{"refresh_token" => _}, state.credentials[&1])) -> :signed_in
        true -> :sign_in_required
      end

    {:reply, status, state}
  end

  def handle_call(:configured, _from, state), do: {:reply, state.sources != [], state}

  def handle_call(:provider_catalog, _from, state) do
    result =
      with {:ok, document, saved} <- Compatible.read(state.dir) do
        {:ok,
         %{
           providers: document["providers"],
           revision: Compatible.revision(document),
           pending?: saved != state.compatible_providers
         }}
      end

    {:reply, result, state}
  end

  def handle_call({:stage_provider, {id, _, _, _} = edit}, _from, state) do
    result =
      Compatible.stage(state.dir, edit, state.compatible_providers, Map.has_key?(state.keys, id))

    {:reply, result, state}
  end

  def handle_call(:api_keys, _from, state) do
    providers =
      for provider <- state.key_providers do
        %{keys: keys, active: active} = Map.get(state.keys, provider, %{keys: %{}, active: nil})
        %{provider: provider, active: active, sources: Enum.sort(Map.keys(keys))}
      end

    {:reply, {:ok, %{providers: providers}}, state}
  end

  def handle_call({:api_key, provider}, _from, state) do
    result =
      case provider in state.key_providers && state.keys[provider] do
        %{active: source, keys: keys} -> {:ok, %{api_key: Map.fetch!(keys, source)}}
        _ -> :not_configured
      end

    {:reply, result, state}
  end

  def handle_call(
        {:put_api_key, provider, source, %H.Credentials.Redacted{value: key}},
        _from,
        state
      ) do
    profile = Map.get(state.keys, provider, %{active: source, keys: %{}})

    cond do
      provider not in state.key_providers ->
        {:reply, {:error, :invalid_api_key_profile}, state}

      map_size(profile.keys) < 8 or Map.has_key?(profile.keys, source) ->
        persist_keys(state, provider, put_in(profile.keys[source], key))

      true ->
        {:reply, {:error, :too_many_account_sources}, state}
    end
  end

  def handle_call({:use_api_key, provider, source}, _from, state) do
    case provider in state.key_providers && state.keys[provider] do
      false ->
        {:reply, {:error, :invalid_api_key_profile}, state}

      %{keys: keys} = profile when is_map_key(keys, source) ->
        persist_keys(state, provider, %{profile | active: source})

      _ ->
        {:reply, {:error, :unknown_account_source}, state}
    end
  end

  def handle_call({:remove_api_key, provider, source}, _from, state) do
    case provider in state.key_providers && state.keys[provider] do
      false ->
        {:reply, {:error, :unknown_account_source}, state}

      %{keys: keys, active: active} = profile when is_map_key(keys, source) ->
        remaining = Map.delete(keys, source)

        {next_all, next_active} =
          if map_size(remaining) == 0 do
            {Map.delete(state.keys, provider), nil}
          else
            reassigned =
              if active == source,
                do: remaining |> Map.keys() |> Enum.sort() |> hd(),
                else: active

            {Map.put(state.keys, provider, %{profile | keys: remaining, active: reassigned}),
             reassigned}
          end

        case Vault.write_api_keys(state.vault, next_all) do
          :ok ->
            if state.table, do: :ets.insert(state.table, {:key_providers, Map.keys(next_all)})

            {:reply, {:ok, %{removed: source, provider: provider, active: next_active}},
             %{state | keys: next_all}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :unknown_account_source}, state}
    end
  end

  def handle_call({:add, source}, _from, state) do
    case add_source(source, state) do
      {:ok, state} -> {:reply, {:ok, %{source: source}}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:discover, _from, state) do
    sources =
      Enum.map(state.sources, fn source ->
        status =
          cond do
            Map.has_key?(state.refreshes, source) -> "refreshing"
            usable?(state.credentials[source]) -> "available"
            match?(%{"refresh_token" => _}, state.credentials[source]) -> "refresh_needed"
            state.credentials[source] -> "reauth_required"
            true -> "not_signed_in"
          end

        %{id: source, state: status, active: source == state.active}
      end)

    {:reply,
     {:ok,
      %{providers: [%{id: "openai_codex", interaction: "device_code_v1", sources: sources}]}},
     state}
  end

  def handle_call({:activate, source}, _from, state) do
    cond do
      source not in state.sources ->
        {:reply, {:error, :unknown_account_source}, state}

      not match?(%{"refresh_token" => _}, state.credentials[source]) ->
        {:reply, {:error, :credential_unavailable}, state}

      true ->
        case Config.write(state.dir, state.sources, source) do
          :ok -> {:reply, {:ok, %{active: source}}, %{state | active: source}}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:remove, source}, _from, state) do
    cond do
      source not in state.sources ->
        {:reply, {:error, :unknown_account_source}, state}

      match?(%{source: ^source}, state.login) or Map.has_key?(state.refreshes, source) ->
        {:reply, {:error, :login_busy}, state}

      true ->
        remaining_sources = List.delete(state.sources, source)

        next_active =
          cond do
            remaining_sources == [] -> nil
            state.active == source -> hd(remaining_sources)
            true -> state.active
          end

        with :ok <- Vault.delete(state.vault, source),
             :ok <- write_or_delete_config(state.dir, remaining_sources, next_active) do
          if state.table, do: :ets.insert(state.table, {:configured, remaining_sources != []})

          next_state = %{
            state
            | sources: remaining_sources,
              active: next_active,
              credentials: Map.delete(state.credentials, source)
          }

          {:reply, {:ok, %{removed: source, active: next_active}}, next_state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:start, id, source}, _from, state) do
    now = monotonic_ms()
    receipts = Map.reject(state.receipts, fn {_, r} -> r.until <= now end)
    state = %{state | receipts: receipts}
    busy = state.login
    previous = receipts[id] && receipts[id].view.source
    pending = if busy && busy.request_id == id, do: busy.source
    source = source || previous || pending || state.active || "default"

    case {receipts[id], busy} do
      {%{view: %{source: ^source} = view}, _} -> {:reply, {:ok, view}, state}
      {%{}, _} -> {:reply, {:error, :login_request_conflict}, state}
      {nil, %{request_id: ^id, source: ^source} = login} -> {:reply, {:ok, view(login)}, state}
      {nil, %{request_id: ^id}} -> {:reply, {:error, :login_request_conflict}, state}
      {nil, %{}} -> {:reply, {:error, :login_busy}, state}
      {nil, nil} -> begin_login(id, source, now, state)
    end
  end

  def handle_call({action, ref}, _from, state) when action in [:status, :cancel] do
    case state.login do
      %{ref: ^ref} = login when action == :status ->
        {:reply, {:ok, view(login)}, state}

      %{ref: ^ref} ->
        {view, state} = finish_login(state, "cancelled")
        {:reply, {:ok, view}, state}

      _ ->
        now = monotonic_ms()

        result =
          Enum.find_value(state.receipts, {:error, :login_not_found}, fn
            {_, %{until: until, view: %{operation: ^ref} = view}} when until > now -> {:ok, view}
            _ -> nil
          end)

        {:reply, result, state}
    end
  end

  def handle_call({:credential, source, deadline}, from, state) do
    source = if source == :active, do: state.active, else: source
    credential = state.credentials[source]

    cond do
      deadline <= monotonic_ms() ->
        {:reply, {:error, :accounts_unavailable}, state}

      job = state.refreshes[source] ->
        if length(job.waiters) < @max_waiters do
          job = %{job | waiters: [from | job.waiters]}
          {:noreply, put_in(state.refreshes[source], job)}
        else
          {:reply, {:error, :accounts_busy}, state}
        end

      usable?(credential) ->
        {:reply, {:ok, dispatch_credential(credential)}, state}

      match?(%{source: ^source}, state.login) or not match?(%{"refresh_token" => _}, credential) ->
        {:reply, {:error, :credential_unavailable}, state}

      true ->
        # Record that this rotating grant may have been consumed before
        # dispatch. Neither VM loss nor a lost exchange response can replay it.
        blocked = reauth(credential)

        # Even a failed commit can have performed the rename. Fence the grant
        # in memory too until a new login or a reload of the on-disk record.
        state = put_in(state.credentials[source], blocked)

        case Vault.write(state.vault, source, blocked) do
          :ok ->
            job =
              launch({:refresh, source}, fn ->
                Codex.refresh(state.http, credential["refresh_token"])
              end)

            timer =
              Process.send_after(self(), {:refresh_timeout, source, job.fence}, @refresh_timeout)

            job = Map.merge(job, %{waiters: [from], timer: timer})
            {:noreply, put_in(state.refreshes[source], job)}

          {:error, _} ->
            {:reply, {:error, :credential_store_unavailable}, state}
        end
    end
  end

  defp begin_login(id, source, now, state) do
    cond do
      Map.has_key?(state.refreshes, source) ->
        {:reply, {:error, :login_busy}, state}

      map_size(state.receipts) >= @max_receipts ->
        {:reply, {:error, :login_rate_limited}, state}

      true ->
        case add_source(source, state) do
          {:ok, state} ->
            ref = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

            login = %{
              ref: ref,
              request_id: id,
              source: source,
              deadline: now + state.ttl,
              expiry: Process.send_after(self(), {:expire, ref}, state.ttl),
              timer: nil,
              code: nil,
              phase: :request,
              job: launch({:login, ref}, fn -> Codex.request_code(state.http) end)
            }

            {:reply, {:ok, view(login)}, %{state | login: login}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  defp write_or_delete_config(dir, [], nil), do: Config.delete(dir)
  defp write_or_delete_config(dir, sources, active), do: Config.write(dir, sources, active)

  defp persist_keys(state, provider, profile) do
    all = Map.put(state.keys, provider, profile)

    case Vault.write_api_keys(state.vault, all) do
      :ok ->
        if state.table, do: :ets.insert(state.table, {:key_providers, Map.keys(all)})
        {:reply, {:ok, %{provider: provider, active: profile.active}}, %{state | keys: all}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp add_source(source, state) do
    cond do
      source in state.sources ->
        {:ok, state}

      length(state.sources) >= 8 ->
        {:error, :too_many_account_sources}

      true ->
        sources = state.sources ++ [source]
        active = state.active || source

        with {:ok, vault, records} <- Vault.open(state.dir, [source]),
             :ok <- Config.write(state.dir, sources, active) do
          if state.table, do: :ets.insert(state.table, {:configured, true})

          {:ok,
           %{
             state
             | sources: sources,
               active: active,
               vault: vault,
               credentials: Map.merge(state.credentials, records)
           }}
        end
    end
  end

  @impl true
  def handle_info({:done, {:login, ref}, fence, result}, %{login: login} = state)
      when login.ref == ref and login.job.fence == fence do
    Process.demonitor(login.job.monitor, [:flush])
    state = put_in(state.login.job, nil)

    if monotonic_ms() >= login.deadline do
      {:noreply, elem(finish_login(state, "expired"), 1)}
    else
      {:noreply, advance_login(state, result)}
    end
  end

  def handle_info({:done, {:refresh, source}, fence, result}, state) do
    case state.refreshes[source] do
      %{fence: ^fence} = job ->
        Process.demonitor(job.monitor, [:flush])
        {:noreply, finish_refresh(state, source, result)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:refresh_timeout, source, fence}, state) do
    case state.refreshes[source] do
      %{fence: ^fence} = job ->
        Process.demonitor(job.monitor, [:flush])
        Process.exit(job.pid, :kill)
        {:noreply, finish_refresh(state, source, {:error, :refresh_interrupted})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:expire, ref}, %{login: %{ref: ref}} = state),
    do: {:noreply, elem(finish_login(state, "expired"), 1)}

  def handle_info({:poll, ref}, %{login: %{ref: ref, job: nil, code: code}} = state) do
    if monotonic_ms() >= state.login.deadline do
      {:noreply, elem(finish_login(state, "expired"), 1)}
    else
      job = launch({:login, ref}, fn -> Codex.poll(state.http, code) end)
      {:noreply, %{state | login: %{state.login | job: job, timer: nil}}}
    end
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{login: %{job: %{monitor: monitor}}} = state) do
    {:noreply, elem(finish_login(state, "failed", :login_worker_lost), 1)}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    case Enum.find(state.refreshes, fn {_, job} -> job.monitor == monitor end) do
      {source, _} -> {:noreply, finish_refresh(state, source, {:error, :refresh_interrupted})}
      nil -> {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp advance_login(%{login: %{phase: :request}} = state, {:ok, code}) do
    schedule_poll(put_in(state.login.code, code))
  end

  defp advance_login(%{login: %{phase: :poll}} = state, :pending), do: schedule_poll(state)

  defp advance_login(%{login: %{phase: :poll}} = state, :slow_down),
    do:
      state
      |> update_in([:login, :code, :interval_ms], &min(&1 + 5000, 120_000))
      |> schedule_poll()

  defp advance_login(%{login: %{phase: :poll} = login} = state, {:ok, grant}) do
    job = launch({:login, login.ref}, fn -> Codex.exchange(state.http, grant) end)
    %{state | login: %{login | job: job, phase: :exchange, code: nil}}
  end

  defp advance_login(%{login: %{phase: :exchange, source: source}} = state, {:ok, record}) do
    case install(state, source, record) do
      {:ok, state} -> elem(finish_login(state, "complete"), 1)
      {:error, reason} -> elem(finish_login(state, "failed", reason), 1)
    end
  end

  defp advance_login(state, {:error, :expired}), do: elem(finish_login(state, "expired"), 1)
  defp advance_login(state, {:error, reason}), do: elem(finish_login(state, "failed", reason), 1)

  defp schedule_poll(%{login: login} = state) do
    delay = min(login.code.interval_ms, state.poll_cap)
    timer = Process.send_after(self(), {:poll, login.ref}, delay)
    %{state | login: %{login | phase: :poll, timer: timer}}
  end

  defp finish_login(%{login: login} = state, status, reason \\ nil) do
    Process.cancel_timer(login.expiry)
    if login.timer, do: Process.cancel_timer(login.timer)

    if login.job do
      Process.demonitor(login.job.monitor, [:flush])
      Process.exit(login.job.pid, :kill)
    end

    view = %{operation: login.ref, source: login.source, state: status}
    view = if reason, do: Map.put(view, :reason, Atom.to_string(reason)), else: view
    receipt = %{view: view, until: monotonic_ms() + @retention}
    {view, %{state | login: nil, receipts: Map.put(state.receipts, login.request_id, receipt)}}
  end

  defp finish_refresh(state, source, result) do
    {job, refreshes} = Map.pop(state.refreshes, source)
    Process.cancel_timer(job.timer)
    state = %{state | refreshes: refreshes}

    {reply, state} =
      case result do
        {:ok, record} ->
          case install(state, source, record) do
            {:ok, state} -> {{:ok, dispatch_credential(record)}, state}
            {:error, :identity_mismatch} -> {{:error, :credential_unavailable}, state}
            {:error, reason} -> {{:error, reason}, state}
          end

        {:error, _} ->
          {{:error, :credential_unavailable}, state}
      end

    Enum.each(job.waiters, &GenServer.reply(&1, reply))
    state
  end

  defp install(state, source, record) do
    existing = state.credentials[source]

    cond do
      existing && reauth(existing) != reauth(record) ->
        {:error, :identity_mismatch}

      Enum.any?(state.credentials, fn {id, other} ->
        id != source and reauth(other) == reauth(record)
      end) ->
        {:error, :identity_already_configured}

      Vault.write(state.vault, source, record) == :ok ->
        {:ok, put_in(state.credentials[source], record)}

      true ->
        {:error, :credential_store_unavailable}
    end
  end

  defp reauth(record),
    do: record |> Map.take(["account_id", "subject"]) |> Map.put("state", "reauth")

  defp usable?(%{"expires_at_ms" => expiry}),
    do: expiry > System.system_time(:millisecond) + @refresh_margin

  defp usable?(_), do: false

  defp dispatch_credential(record),
    do: %{access_token: record["access_token"], account_id: record["account_id"]}

  defp view(login) do
    view = %{
      operation: login.ref,
      source: login.source,
      state: if(login.phase == :request, do: "starting", else: "pending"),
      expires_in_ms: max(login.deadline - monotonic_ms(), 0),
      poll_after_ms: 1000
    }

    if login.code do
      Map.merge(view, %{
        verification_url: Codex.verification_url(),
        user_code: login.code.user_code
      })
    else
      view
    end
  end

  defp launch(key, fun) do
    owner = self()
    fence = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          Process.flag(:sensitive, true)
          send(owner, {:done, key, fence, fun.()})
        end,
        [:link, :monitor]
      )

    %{pid: pid, monitor: monitor, fence: fence}
  end

  @impl true
  def terminate(_, state) do
    for job <- [state.login && state.login.job | Map.values(state.refreshes)], job != nil do
      Process.exit(job.pid, :kill)
    end

    :ok
  end

  defp fetch_policy_status(%{module: mod, sources: policy_sources})
       when is_atom(mod) and is_list(policy_sources) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :status, 1) do
      case safe_policy_status(mod, policy_sources) do
        %{} = status ->
          %{
            status_note: sanitize_status_note(Map.get(status, :status_note), 240),
            sources: sanitize_source_notes(Map.get(status, :sources))
          }

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp fetch_policy_status(_), do: nil

  defp apply_provider_status(provider, status) do
    source_notes = status.sources

    sources =
      Enum.map(provider.sources, fn source ->
        case Map.get(source_notes, source.id) do
          note when is_binary(note) -> Map.put(source, :status_note, note)
          _ -> source
        end
      end)

    provider = %{provider | sources: sources}

    case status.status_note do
      note when is_binary(note) -> Map.put(provider, :status_note, note)
      _ -> provider
    end
  end

  defp safe_policy_status(mod, policy_sources) do
    mod.status(policy_sources)
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp sanitize_source_notes(notes) when is_map(notes) do
    Enum.reduce(notes, %{}, fn
      {id, note}, acc when is_binary(id) ->
        case sanitize_status_note(note, 120) do
          nil -> acc
          clean -> Map.put(acc, id, clean)
        end

      _, acc ->
        acc
    end)
  end

  defp sanitize_source_notes(_), do: %{}

  defp sanitize_status_note(val, max_len) when is_binary(val) do
    cleaned =
      val
      |> H.Credentials.sanitize()
      |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    case cleaned do
      "" -> nil
      str -> String.slice(str, 0, max_len)
    end
  end

  defp sanitize_status_note(_, _), do: nil

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
