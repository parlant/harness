defmodule Extensions.EditorHost.Broker do
  @moduledoc """
  Daemon-owned live tool-host broker for `Extensions.EditorHost`.

  Security & fencing model:
    * Owner pairing (`issue_grant/2`) mints a 32-byte base64url single-claim grant
      and stores only its SHA-256 digest (`Plug.Crypto.secure_compare/2` verified).
    * Grants are bound to a canonicalized workspace `cwd` and short `grant_ttl_ms`.
      They never expose or accept the daemon owner token.
    * Claiming a grant (`claim_grant/4`) verifies capability, non-expiry,
      single-claim status, and exact `cwd` match, increments a monotonic
      `host_generation` (`1, 2, ...`), supersedes any previous host generation
      for that workspace, and monitors the live host process (`Process.monitor/1`).
    * Tool invocations (`invoke_buffer_summary/3`) check for an active eligible
      host before dispatch (`tool_unavailable` otherwise), enforce per-host
      concurrency caps, mint one-use `invocation_id` tokens, bind the call to the
      exact current `host_generation`, validate & sanitize responses, and fence
      any late, malformed, oversized, or stale-generation replies.
  """

  use GenServer

  alias Extensions.EditorHost.Broker.Endpoint

  @default_grant_ttl_ms 60_000
  @default_invocation_timeout_ms 5_000
  @default_max_summary_bytes 16_384
  @default_max_concurrency 4
  @required_capability "editor_buffer_summary"
  @status_max_age_ms 5_000

  @type host_dispatch_fn :: (map() -> any())

  def start_link(opts \\ []) when is_list(opts) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Issues a short-lived, single-claim tool-host grant bound to `workspace_cwd`.
  """
  @spec issue_grant(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue_grant(workspace_cwd, opts \\ []) when is_binary(workspace_cwd) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    ttl_ms = Keyword.get(opts, :grant_ttl_ms)

    if alive_server?(server) do
      GenServer.call(server, {:issue_grant, workspace_cwd, ttl_ms}, 2_000)
    else
      {:error, :broker_unavailable}
    end
  end

  @doc """
  Claims a grant token for a live tool-host process (or callback transport).

  `host_ref` may be a live `pid()` (which can handle `{:editor_host_invoke, payload}`
  messages, or be paired with an explicit `send_fn` in `metadata[:dispatch]`),
  or `%{pid: pid, dispatch: fun}` where `pid` is monitored for liveness.
  """
  @spec claim_grant(String.t(), pid() | map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def claim_grant(grant_token, host_ref, metadata, opts \\ [])
      when is_binary(grant_token) and is_map(metadata) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    if alive_server?(server) do
      GenServer.call(server, {:claim_grant, grant_token, host_ref, metadata}, 2_000)
    else
      {:error, :broker_unavailable}
    end
  end

  @doc """
  Submits a host reply for an in-flight `invocation_id` (used by local HTTP/UDS
  endpoints or external host adapters).
  """
  @spec complete_invocation(String.t(), pos_integer(), map(), keyword()) ::
          :ok | {:error, term()}
  def complete_invocation(invocation_id, host_generation, response, opts \\ [])
      when is_binary(invocation_id) and is_integer(host_generation) and is_map(response) and
             is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    if alive_server?(server) do
      GenServer.call(
        server,
        {:complete_invocation, invocation_id, host_generation, response},
        2_000
      )
    else
      {:error, :broker_unavailable}
    end
  end

  @doc """
  Disconnects the current live host for `workspace_cwd` (or matching `host_generation`).
  """
  @spec disconnect_host(String.t(), keyword()) :: :ok | {:error, term()}
  def disconnect_host(workspace_cwd, opts \\ [])
      when is_binary(workspace_cwd) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    generation = Keyword.get(opts, :host_generation)

    if alive_server?(server) do
      GenServer.call(server, {:disconnect_host, workspace_cwd, generation}, 2_000)
    else
      {:error, :broker_unavailable}
    end
  end

  @doc """
  Returns the current broker endpoint binding (`%{socket_path: ..., http_port: ...}`).
  """
  @spec endpoint_info(keyword()) :: {:ok, map()} | {:error, term()}
  def endpoint_info(opts \\ []) when is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    if alive_server?(server) do
      GenServer.call(server, :endpoint_info, 1_000)
    else
      {:error, :broker_unavailable}
    end
  end

  @doc """
  Dispatches an `editor_buffer_summary` call to the single currently connected
  live host for `workspace_cwd`, fencing generation, concurrency, timeout, and
  output validation.
  """
  @spec invoke_buffer_summary(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def invoke_buffer_summary(workspace_cwd, args, opts \\ [])
      when is_binary(workspace_cwd) and is_map(args) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    if not alive_server?(server) do
      {:error, error_payload("tool_unavailable", "Live editor host broker is not running.")}
    else
      call_timeout_ms = Keyword.get(opts, :timeout_ms)

      case GenServer.call(
             server,
             {:begin_invocation, workspace_cwd, args, call_timeout_ms},
             2_000
           ) do
        {:ok, invocation_id, wait_timeout_ms} ->
          wait_for_invocation(server, invocation_id, wait_timeout_ms)

        {:error, reason, message} ->
          {:error, error_payload(reason, message)}
      end
    end
  end

  @doc """
  Projects cached `editor_host` status without performing I/O.
  """
  @spec project_status(map(), keyword()) :: :omit | {:ok, map(), pos_integer()}
  def project_status(scope, opts \\ []) when is_map(scope) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    if alive_server?(server) do
      try do
        GenServer.call(server, {:project_status, scope}, 250)
      catch
        :exit, _ -> :omit
      end
    else
      :omit
    end
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      grant_ttl_ms: Keyword.get(opts, :grant_ttl_ms, @default_grant_ttl_ms),
      invocation_timeout_ms:
        Keyword.get(opts, :invocation_timeout_ms, @default_invocation_timeout_ms),
      max_summary_bytes: Keyword.get(opts, :max_summary_bytes, @default_max_summary_bytes),
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      socket_path: Keyword.get(opts, :socket_path),
      http_port: Keyword.get(opts, :http_port),
      endpoint_pid: nil,
      bound_http_port: nil,
      grants: %{},
      hosts: %{},
      monitors: %{},
      next_generation: 1,
      invocations: %{}
    }

    case maybe_start_endpoint(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.endpoint_pid) and Process.alive?(state.endpoint_pid) do
      Supervisor.stop(state.endpoint_pid, :normal, 1_000)
    end

    if is_binary(state.socket_path) do
      File.rm(state.socket_path)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def handle_call({:issue_grant, raw_cwd, custom_ttl}, _from, state) do
    now = monotonic_ms()
    state = prune_expired_grants(state, now)

    with {:ok, cwd} <- canonicalize_existing_dir(raw_cwd),
         {:ok, ttl_ms} <- resolve_grant_ttl(custom_ttl, state.grant_ttl_ms) do
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      digest = sha256(token)
      grant_id = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      expires_at_mono = now + ttl_ms
      expires_at_ms = System.system_time(:millisecond) + ttl_ms

      grant = %{
        grant_id: grant_id,
        digest: digest,
        cwd: cwd,
        expires_at_mono: expires_at_mono,
        expires_at_ms: expires_at_ms,
        claimed: false
      }

      grants = Map.put(state.grants, grant_id, grant)

      reply = %{
        grant_token: token,
        grant_id: grant_id,
        cwd: cwd,
        capabilities: [@required_capability],
        expires_at_ms: expires_at_ms,
        ttl_ms: ttl_ms
      }

      {:reply, {:ok, reply}, %{state | grants: grants}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:claim_grant, grant_token, host_ref, metadata}, _from, state) do
    now = monotonic_ms()

    with {:ok, grant_id, grant} <- verify_grant_token(state.grants, grant_token, now),
         {:ok, host_cwd} <- canonicalize_existing_dir(metadata_cwd(metadata)),
         :ok <- ensure_matching_cwd(grant.cwd, host_cwd),
         :ok <- ensure_valid_capabilities(metadata_capabilities(metadata)),
         {:ok, host_pid, dispatch_fn} <- normalize_host_ref(host_ref) do
      # Mark grant single-claim immediately and prune any older expired grants
      grants = Map.put(state.grants, grant_id, %{grant | claimed: true})
      state = prune_expired_grants(%{state | grants: grants}, now)

      # Supersede any prior host generation for this workspace and cancel its in-flight invocations
      state = supersede_workspace_host(state, grant.cwd, :superseded)

      generation = state.next_generation
      mon_ref = Process.monitor(host_pid)

      host = %{
        cwd: grant.cwd,
        generation: generation,
        pid: host_pid,
        monitor_ref: mon_ref,
        dispatch_fn: dispatch_fn,
        capabilities: [@required_capability],
        connected_at_ms: System.system_time(:millisecond),
        in_flight: 0
      }

      state = %{
        state
        | next_generation: generation + 1,
          hosts: Map.put(state.hosts, grant.cwd, host),
          monitors: Map.put(state.monitors, mon_ref, {:host, grant.cwd, generation})
      }

      {:reply,
       {:ok,
        %{
          cwd: grant.cwd,
          host_generation: generation,
          capabilities: host.capabilities,
          max_concurrency: state.max_concurrency
        }}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:begin_invocation, raw_cwd, args, custom_timeout_ms}, _from, state) do
    with {:ok, cwd} <- canonicalize_existing_dir(raw_cwd),
         {:ok, host} <- fetch_eligible_host(state.hosts, cwd),
         :ok <- ensure_capacity(host, state.max_concurrency) do
      timeout_ms = resolve_invocation_timeout(custom_timeout_ms, state.invocation_timeout_ms)
      invocation_id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      deadline_mono = monotonic_ms() + timeout_ms
      deadline_ms = System.system_time(:millisecond) + timeout_ms

      payload = %{
        "invocation_id" => invocation_id,
        "cwd" => host.cwd,
        "host_generation" => host.generation,
        "tool" => @required_capability,
        "args" => %{
          "path" => args["path"],
          "expected_revision" => args["expected_revision"],
          "max_lines" => args["max_lines"]
        },
        "deadline_ms" => deadline_ms,
        "timeout_ms" => timeout_ms
      }

      timer_ref = Process.send_after(self(), {:invocation_timeout, invocation_id}, timeout_ms)

      inv = %{
        id: invocation_id,
        cwd: host.cwd,
        generation: host.generation,
        args: args,
        deadline_mono: deadline_mono,
        timer_ref: timer_ref,
        waiter: nil,
        settled: nil
      }

      state =
        state
        |> put_in([:hosts, host.cwd, :in_flight], host.in_flight + 1)
        |> put_in([:invocations, invocation_id], inv)

      case safe_dispatch_to_host(host, payload) do
        :ok ->
          {:reply, {:ok, invocation_id, timeout_ms + 500}, state}

        {:error, _reason} ->
          Process.cancel_timer(timer_ref)
          state = drop_invocation(state, invocation_id)
          {:reply, {:error, "host_disconnected", "Live editor host rejected dispatch."}, state}
      end
    else
      {:error, :no_host} ->
        {:reply,
         {:error, "tool_unavailable",
          "No live editor host is currently connected for this workspace."}, state}

      {:error, :busy} ->
        {:reply,
         {:error, "tool_busy", "Live editor host concurrency limit reached; retry shortly."},
         state}

      {:error, _} ->
        {:reply, {:error, "tool_unavailable", "Workspace is not eligible for live host lookup."},
         state}
    end
  end

  def handle_call({:await_invocation, invocation_id}, from, state) do
    case Map.get(state.invocations, invocation_id) do
      nil ->
        {:reply, {:error, error_payload("tool_unavailable", "Invocation is no longer active.")},
         state}

      %{settled: {:ok, result}} ->
        state = drop_invocation(state, invocation_id)
        {:reply, {:ok, result}, state}

      %{settled: {:error, err}} ->
        state = drop_invocation(state, invocation_id)
        {:reply, {:error, err}, state}

      %{settled: nil, waiter: nil} = inv ->
        {:noreply, put_in(state.invocations[invocation_id], %{inv | waiter: from})}

      %{settled: nil} ->
        {:reply, {:error, error_payload("tool_busy", "Invocation already has a waiter.")}, state}
    end
  end

  def handle_call({:complete_invocation, invocation_id, generation, response}, _from, state) do
    case Map.get(state.invocations, invocation_id) do
      nil ->
        {:reply, {:error, :stale_or_unknown_invocation}, state}

      %{generation: expected_gen} when expected_gen != generation ->
        {:reply, {:error, :stale_host_generation}, state}

      %{cwd: cwd} = inv ->
        case Map.get(state.hosts, cwd) do
          %{generation: ^generation} ->
            outcome = validate_host_response(response, inv, state.max_summary_bytes)
            state = settle_invocation(state, invocation_id, outcome)
            {:reply, :ok, state}

          _ ->
            {:reply, {:error, :stale_host_generation}, state}
        end
    end
  end

  def handle_call({:disconnect_host, raw_cwd, generation}, _from, state) do
    case canonicalize_existing_dir(raw_cwd) do
      {:ok, cwd} ->
        case Map.get(state.hosts, cwd) do
          nil ->
            {:reply, :ok, state}

          %{generation: current_gen} when is_nil(generation) or current_gen == generation ->
            state = supersede_workspace_host(state, cwd, :disconnected)
            {:reply, :ok, state}

          _other_gen ->
            {:reply, {:error, :stale_host_generation}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:endpoint_info, _from, state) do
    {:reply,
     {:ok,
      %{
        socket_path: state.socket_path,
        http_port: state.bound_http_port || state.http_port
      }}, state}
  end

  def handle_call({:project_status, _scope}, _from, state) do
    connected_hosts = map_size(state.hosts)

    latest_generation =
      state.hosts
      |> Map.values()
      |> Enum.map(& &1.generation)
      |> Enum.max(fn -> 0 end)

    status = %{
      "state" => if(connected_hosts > 0, do: "connected", else: "disconnected"),
      "paired_hosts" => connected_hosts,
      "generation" => latest_generation
    }

    {:reply, {:ok, status, @status_max_age_ms}, state}
  end

  @impl true
  def handle_info({:invocation_timeout, invocation_id}, state) do
    case Map.get(state.invocations, invocation_id) do
      nil ->
        {:noreply, state}

      %{settled: nil} ->
        err = error_payload("tool_timeout", "Live editor host timed out before responding.")
        {:noreply, settle_invocation(state, invocation_id, {:error, err})}

      _already_settled ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, mon_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, mon_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {{:host, cwd, generation}, monitors} ->
        state = %{state | monitors: monitors}

        case Map.get(state.hosts, cwd) do
          %{generation: ^generation} ->
            state =
              state
              |> update_in([:hosts], &Map.delete(&1, cwd))
              |> fail_invocations_for_host(
                cwd,
                generation,
                error_payload(
                  "host_disconnected",
                  "Live editor host disconnected mid-invocation."
                )
              )

            {:noreply, state}

          _ ->
            {:noreply, state}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private helpers ---

  defp maybe_start_endpoint(%{socket_path: nil, http_port: nil} = state), do: {:ok, state}

  defp maybe_start_endpoint(state) do
    Endpoint.start_link_with_info(
      broker: self(),
      socket_path: state.socket_path,
      http_port: state.http_port
    )
    |> case do
      {:ok, pid, bound_port} ->
        {:ok, %{state | endpoint_pid: pid, bound_http_port: bound_port}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_invocation(server, invocation_id, wait_timeout_ms) do
    try do
      GenServer.call(server, {:await_invocation, invocation_id}, wait_timeout_ms)
    catch
      :exit, {:timeout, _} ->
        {:error, error_payload("tool_timeout", "Live editor host timed out before responding.")}

      :exit, _ ->
        {:error, error_payload("host_disconnected", "Live editor host broker stopped.")}
    end
  end

  defp safe_dispatch_to_host(host, payload) do
    host.dispatch_fn.(payload)
  rescue
    _ -> {:error, :dispatch_failed}
  catch
    _, _ -> {:error, :dispatch_failed}
  end

  defp settle_invocation(state, invocation_id, outcome) do
    case Map.get(state.invocations, invocation_id) do
      nil ->
        state

      %{timer_ref: timer_ref, waiter: nil} = inv ->
        Process.cancel_timer(timer_ref)
        state = decrement_host_in_flight(state, inv.cwd, inv.generation)
        put_in(state.invocations[invocation_id], %{inv | settled: outcome})

      %{timer_ref: timer_ref, waiter: from} ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, outcome)
        drop_invocation(state, invocation_id)
    end
  end

  defp drop_invocation(state, invocation_id) do
    case Map.pop(state.invocations, invocation_id) do
      {nil, _} ->
        state

      {inv, remaining} ->
        Process.cancel_timer(inv.timer_ref)
        state = %{state | invocations: remaining}

        if is_nil(inv.settled) do
          decrement_host_in_flight(state, inv.cwd, inv.generation)
        else
          state
        end
    end
  end

  defp decrement_host_in_flight(state, cwd, generation) do
    case Map.get(state.hosts, cwd) do
      %{generation: ^generation, in_flight: count} when count > 0 ->
        put_in(state.hosts[cwd].in_flight, count - 1)

      _ ->
        state
    end
  end

  defp supersede_workspace_host(state, cwd, _reason) do
    case Map.pop(state.hosts, cwd) do
      {nil, _hosts} ->
        state

      {old_host, hosts} ->
        Process.demonitor(old_host.monitor_ref, [:flush])
        monitors = Map.delete(state.monitors, old_host.monitor_ref)

        state = %{state | hosts: hosts, monitors: monitors}

        fail_invocations_for_host(
          state,
          cwd,
          old_host.generation,
          error_payload("host_disconnected", "Live editor host was disconnected or superseded.")
        )
    end
  end

  defp fail_invocations_for_host(state, cwd, generation, err_payload) do
    matching_ids =
      for {id, %{cwd: ^cwd, generation: ^generation, settled: nil}} <- state.invocations, do: id

    Enum.reduce(matching_ids, state, fn id, acc ->
      settle_invocation(acc, id, {:error, err_payload})
    end)
  end

  defp validate_host_response(response, inv, max_summary_bytes) do
    with :ok <- check_response_generation(response, inv.generation),
         :ok <- check_response_invocation(response, inv.id) do
      status = fetch_field(response, "status", :status) || "ok"

      case status do
        "revision_mismatch" ->
          actual_rev = sanitize_text(fetch_field(response, "actual_revision", :actual_revision))

          {:error,
           %{
             content: [
               %{
                 "type" => "text",
                 "text" =>
                   "Buffer revision mismatch for #{inv.args["path"]}: expected #{inv.args["expected_revision"]}" <>
                     if(actual_rev != "", do: ", actual #{actual_rev}", else: "")
               }
             ],
             details: %{
               "reason" => "revision_mismatch",
               "path" => inv.args["path"],
               "expected_revision" => inv.args["expected_revision"],
               "actual_revision" => if(actual_rev == "", do: nil, else: actual_rev),
               "host_generation" => inv.generation
             },
             is_error: true,
             diagnostic: "revision_mismatch"
           }}

        "error" ->
          diag = sanitize_diagnostic(fetch_field(response, "diagnostic", :diagnostic))

          msg =
            sanitize_text(fetch_field(response, "message", :message) || "Editor host error.")

          {:error, error_payload(diag, msg)}

        "ok" ->
          build_ok_response(response, inv, max_summary_bytes)

        _ ->
          {:error, error_payload("malformed_host_response", "Host returned unsupported status.")}
      end
    else
      {:error, reason, message} ->
        {:error, error_payload(reason, message)}
    end
  end

  defp build_ok_response(response, inv, max_summary_bytes) do
    summary = fetch_field(response, "summary", :summary)
    revision = fetch_field(response, "revision", :revision) || inv.args["expected_revision"]
    line_count = fetch_field(response, "line_count", :line_count)
    dirty = fetch_field(response, "dirty", :dirty)

    cond do
      not is_binary(summary) or not String.valid?(summary) ->
        {:error,
         error_payload("malformed_host_response", "Host summary must be valid UTF-8 text.")}

      byte_size(summary) > max_summary_bytes ->
        {:error,
         error_payload(
           "response_too_large",
           "Host summary exceeds max_summary_bytes (#{max_summary_bytes})."
         )}

      revision != inv.args["expected_revision"] ->
        {:error,
         %{
           content: [
             %{
               "type" => "text",
               "text" =>
                 "Buffer revision mismatch for #{inv.args["path"]}: expected #{inv.args["expected_revision"]}, actual #{sanitize_text(to_string(revision))}"
             }
           ],
           details: %{
             "reason" => "revision_mismatch",
             "path" => inv.args["path"],
             "expected_revision" => inv.args["expected_revision"],
             "actual_revision" => sanitize_text(to_string(revision)),
             "host_generation" => inv.generation
           },
           is_error: true,
           diagnostic: "revision_mismatch"
         }}

      true ->
        clean_summary = sanitize_text(summary)

        if byte_size(clean_summary) > max_summary_bytes do
          {:error,
           error_payload(
             "response_too_large",
             "Host summary exceeds max_summary_bytes (#{max_summary_bytes})."
           )}
        else
          details = %{
            "path" => inv.args["path"],
            "revision" => inv.args["expected_revision"],
            "host_generation" => inv.generation,
            "bytes" => byte_size(clean_summary)
          }

          details =
            if is_integer(line_count) and line_count >= 0,
              do: Map.put(details, "line_count", line_count),
              else: details

          details =
            if is_boolean(dirty),
              do: Map.put(details, "dirty", dirty),
              else: details

          {:ok,
           %{
             content: [%{"type" => "text", "text" => clean_summary}],
             details: details,
             is_error: false,
             diagnostic: nil
           }}
        end
    end
  end

  defp check_response_generation(response, expected_gen) do
    case fetch_field(response, "host_generation", :host_generation) do
      nil -> :ok
      ^expected_gen -> :ok
      _ -> {:error, "stale_host_generation", "Host response generation did not match."}
    end
  end

  defp check_response_invocation(response, expected_id) do
    case fetch_field(response, "invocation_id", :invocation_id) do
      nil -> :ok
      ^expected_id -> :ok
      _ -> {:error, "malformed_host_response", "Host response invocation_id did not match."}
    end
  end

  defp fetch_field(map, str_key, atom_key) do
    case Map.fetch(map, str_key) do
      {:ok, val} -> val
      :error -> Map.get(map, atom_key)
    end
  end

  defp sanitize_text(text) when is_binary(text) do
    text
    |> String.replace_invalid()
    |> H.Credentials.sanitize()
    |> strip_active_html()
    |> strip_controls()
  end

  defp sanitize_text(_), do: ""

  defp strip_active_html(text) do
    text
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<iframe\b[^>]*>.*?<\/iframe>/is, "")
    |> String.replace(~r/\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/i, "")
  end

  defp strip_controls(text) do
    # Preserve \n (10) and \t (9); strip ANSI CSI/OSC sequences and other C0/C1/DEL control chars
    text
    |> String.replace(~r/\x1B\[[0-9;?]*[ -\/]*[@-~]/, "")
    |> String.replace(~r/\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)/, "")
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/, "")
  end

  defp sanitize_diagnostic(diag) when is_binary(diag) do
    case Regex.run(~r/\A[a-z][a-z0-9_]{0,47}\z/, diag) do
      [valid] -> valid
      _ -> "host_error"
    end
  end

  defp sanitize_diagnostic(_), do: "host_error"

  defp verify_grant_token(grants, candidate, now) when is_binary(candidate) do
    candidate_digest = sha256(candidate)

    # Constant-time scan over active grants to avoid timing leaks on token lookup
    matched =
      Enum.reduce(grants, nil, fn {grant_id, grant}, acc ->
        if Plug.Crypto.secure_compare(candidate_digest, grant.digest) do
          {grant_id, grant}
        else
          acc
        end
      end)

    case matched do
      nil ->
        {:error, :unauthorized}

      {_grant_id, %{claimed: true}} ->
        {:error, :grant_already_claimed}

      {_grant_id, %{expires_at_mono: exp}} when exp <= now ->
        {:error, :grant_expired}

      {grant_id, grant} ->
        {:ok, grant_id, grant}
    end
  end

  defp verify_grant_token(_grants, _candidate, _now), do: {:error, :unauthorized}

  defp prune_expired_grants(state, now) do
    grants =
      state.grants
      |> Enum.reject(fn {_id, grant} -> grant.expires_at_mono <= now and not grant.claimed end)
      |> Map.new()

    %{state | grants: grants}
  end

  defp ensure_matching_cwd(expected_cwd, expected_cwd), do: :ok
  defp ensure_matching_cwd(_, _), do: {:error, :workspace_mismatch}

  defp ensure_valid_capabilities([@required_capability]), do: :ok

  defp ensure_valid_capabilities(caps) when is_list(caps) do
    if @required_capability in caps and Enum.all?(caps, &(&1 == @required_capability)) do
      :ok
    else
      {:error, :unsupported_capabilities}
    end
  end

  defp ensure_valid_capabilities(_), do: {:error, :unsupported_capabilities}

  defp metadata_cwd(metadata) do
    Map.get(metadata, :cwd) || Map.get(metadata, "cwd")
  end

  defp metadata_capabilities(metadata) do
    Map.get(metadata, :capabilities) || Map.get(metadata, "capabilities")
  end

  defp normalize_host_ref(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, pid,
       fn payload ->
         send(pid, {:editor_host_invoke, payload})
         :ok
       end}
    else
      {:error, :host_not_alive}
    end
  end

  defp normalize_host_ref(%{pid: pid, dispatch: dispatch})
       when is_pid(pid) and is_function(dispatch, 1) do
    if Process.alive?(pid) do
      {:ok, pid, dispatch}
    else
      {:error, :host_not_alive}
    end
  end

  defp normalize_host_ref(_), do: {:error, :invalid_host_ref}

  defp fetch_eligible_host(hosts, cwd) do
    case Map.get(hosts, cwd) do
      nil ->
        {:error, :no_host}

      host ->
        if Process.alive?(host.pid) do
          {:ok, host}
        else
          {:error, :no_host}
        end
    end
  end

  defp ensure_capacity(host, max_concurrency) do
    if host.in_flight < max_concurrency, do: :ok, else: {:error, :busy}
  end

  defp resolve_grant_ttl(nil, default_ttl), do: {:ok, default_ttl}

  defp resolve_grant_ttl(ttl, _default_ttl)
       when is_integer(ttl) and ttl in 1_000..300_000,
       do: {:ok, ttl}

  defp resolve_grant_ttl(_, _), do: {:error, :invalid_grant_ttl}

  defp resolve_invocation_timeout(nil, default_ms), do: default_ms

  defp resolve_invocation_timeout(ms, _default_ms) when is_integer(ms) and ms in 500..60_000,
    do: ms

  defp resolve_invocation_timeout(_, default_ms), do: default_ms

  defp canonicalize_existing_dir(raw_cwd) when is_binary(raw_cwd) do
    if String.valid?(raw_cwd) and not String.contains?(raw_cwd, <<0>>) and
         Path.type(raw_cwd) == :absolute do
      env = H.ExecutionEnv.Host.new(Path.expand("/"))

      case H.ExecutionEnv.canonical_path(env, raw_cwd) do
        {:ok, canonical} ->
          if File.dir?(canonical), do: {:ok, canonical}, else: {:error, :enotdir}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_cwd}
    end
  end

  defp canonicalize_existing_dir(_), do: {:error, :invalid_cwd}

  defp sha256(bin), do: :crypto.hash(:sha256, bin)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp alive_server?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive_server?(name) when is_atom(name), do: is_pid(Process.whereis(name))
  defp alive_server?(_), do: false

  defp error_payload(diagnostic, message) do
    %{
      content: [%{"type" => "text", "text" => message}],
      details: %{"reason" => diagnostic},
      is_error: true,
      diagnostic: diagnostic
    }
  end
end
