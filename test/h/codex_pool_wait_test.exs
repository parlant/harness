defmodule H.CodexPoolWaitTest do
  use ExUnit.Case, async: false

  alias H.{Accounts, Catalog, Daemon}
  alias H.Provider.ReqLLM, as: ReqLLMProvider

  defmodule FakePoolPolicy do
    @behaviour H.Provider.AccountPolicy

    def set_state(state), do: Application.put_env(:harness, __MODULE__, state)

    @impl true
    def order(_model, candidates) do
      case Application.get_env(:harness, __MODULE__, %{}) do
        %{order: ordered} -> Enum.filter(ordered, &(&1 in candidates))
        _ -> []
      end
    end

    @impl true
    def rejected(_model, _source, _reason), do: :ok

    @impl true
    def unavailable(_model, _candidates) do
      Application.get_env(:harness, __MODULE__, %{})[:unavailable]
    end

    @impl true
    def pool_status(sources) do
      case Application.get_env(:harness, __MODULE__, %{}) do
        %{pool_status: status} when is_map(status) ->
          status

        _ ->
          %{
            allow_credits: false,
            wait_when_exhausted: true,
            sources: Enum.map(sources, &%{id: &1, eligibility: :checking, reset_at_ms: nil})
          }
      end
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:harness, FakePoolPolicy) end)
    :ok
  end

  defp setup_env(opts \\ []) do
    id = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "h-codex-pool-wait-#{id}")
    data_dir = Path.join(tmp_root, "data")
    cwd = Path.join(tmp_root, "work")
    File.mkdir_p!(data_dir)
    File.chmod!(data_dir, 0o700)
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(tmp_root) end)

    sources = Keyword.get(opts, :sources, ["personal", "work"])
    {:ok, vault, _} = Accounts.Vault.open(data_dir, [])

    for source <- sources do
      :ok =
        Accounts.Vault.write(vault, source, %{
          "account_id" => source,
          "subject" => source,
          "access_token" => "access-#{source}",
          "refresh_token" => "refresh-#{source}",
          "expires_at_ms" => System.system_time(:millisecond) + 120_000
        })
    end

    accounts =
      start_supervised!(
        {Accounts,
         sources: sources, data_dir: data_dir, http: fn _ -> flunk("unexpected auth refresh") end}
      )

    registry = :"H.CodexPoolWait.Registry.#{id}"
    pubsub = :"H.CodexPoolWait.PubSub.#{id}"
    catalog = :"H.CodexPoolWait.Catalog.#{id}"
    catalog_table = :"h_codex_pool_wait_catalog_#{id}"
    lease = :"H.CodexPoolWait.Lease.#{id}"
    runtime_sup = :"H.CodexPoolWait.RuntimeSup.#{id}"

    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: catalog_table})
    start_supervised!({H.WorkspaceLease, name: lease})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: runtime_sup})

    owner = self()
    reply_text = Keyword.get(opts, :reply_text, "Recovered answer")

    stream_fn =
      Keyword.get(opts, :stream_fn, fn model, context, _req_opts ->
        send(owner, {:dispatched, "#{model.provider}:#{model.id}"})

        {:ok, metadata_handle} =
          ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
            %{finish_reason: :stop, usage: %{input_tokens: 10, output_tokens: 5}}
          end)

        stream = [
          ReqLLM.StreamChunk.text(reply_text)
        ]

        {:ok,
         %ReqLLM.StreamResponse{
           stream: stream,
           metadata_handle: metadata_handle,
           cancel: fn -> :ok end,
           model: model,
           context: context
         }}
      end)

    policy = %{module: FakePoolPolicy, sources: sources}

    provider_config = %{
      accounts: accounts,
      codex_account_policy: policy,
      stream_fn: stream_fn,
      credentials_opts: [api_key: "test-key"]
    }

    daemon_opts =
      [
        registry: registry,
        pubsub: pubsub,
        catalog: catalog,
        catalog_table: catalog_table,
        workspace_lease: lease,
        runtime_sup: runtime_sup,
        data_dir: data_dir,
        accounts: accounts,
        codex_account_policy: policy,
        provider: ReqLLMProvider,
        provider_config: provider_config,
        storage_mod: H.Storage.File,
        storage_opts: [sync: :none],
        default_model: "openai_codex:gpt-6.2-sol"
      ] ++ Keyword.get(opts, :daemon_opts, [])

    %{
      daemon_opts: daemon_opts,
      cwd: cwd,
      pubsub: pubsub,
      accounts: accounts,
      policy: policy,
      runtime_sup: runtime_sup,
      registry: registry,
      catalog_table: catalog_table
    }
  end

  defp cmd(req_id, command, cid, args) do
    %{
      "version" => 1,
      "request_id" => req_id,
      "command" => command,
      "conversation_id" => cid,
      "args" => args
    }
  end

  defp broadcast_pool_available(pubsub) do
    Registry.dispatch(pubsub, {:account_pool, :openai_codex}, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:account_pool_available, :openai_codex})
    end)
  end

  defp snapshot(sid, opts) do
    {:ok, {:snapshot, seq, bin}} = Daemon.subscribe_conversation(sid, "1", self(), nil, opts)
    {seq, JSON.decode!(bin)}
  end

  defp wait_until(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if res = fun.() do
      res
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for condition")
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end

  test "generation enters sleeping pool_wait when credits are disabled and wakes automatically on PubSub recovery" do
    reset_at = System.system_time(:millisecond) + 3_600_000

    FakePoolPolicy.set_state(%{
      order: [],
      unavailable: %{reason: :credits_disabled, wait: true, wait_until_ms: reset_at}
    })

    %{daemon_opts: opts, cwd: cwd, pubsub: pubsub, catalog_table: catalog_table} = setup_env()

    sid = "pool-wait-gen"
    {:ok, _} = Daemon.create_session(%{"session_id" => sid, "cwd" => cwd}, opts)

    {:ok, _} =
      Daemon.execute_command(
        sid,
        cmd("req-1", "submit", "1", %{"type" => "input", "content" => "hello pool"}),
        opts
      )

    live_retry =
      wait_until(fn ->
        {_seq, snap} = snapshot(sid, opts)

        case get_in(snap, ["docs", "live", "generation", "retry"]) do
          %{"kind" => "pool_wait", "status" => "waiting"} = retry -> retry
          _ -> nil
        end
      end)

    assert live_retry["provider"] == "openai_codex"
    assert live_retry["code"] == "codex_pool_credits_disabled"
    assert live_retry["message"] =~ "allow_credits is false"
    assert live_retry["wait_until"] == reset_at

    {:ok, detail} = Daemon.get_session_detail(sid, opts)
    assert [gen_task] = Enum.filter(detail.tasks, &(&1.kind == "generation"))
    assert gen_task.status == "sleeping"
    assert gen_task.wake["reason"] == "pool_wait"
    assert gen_task.wake["provider"] == "openai_codex"

    {:ok, summary} = Catalog.get_session(sid, catalog_table)
    assert summary.attention == "retrying"
    assert summary.active == true
    assert summary.activity_kind == "retry"
    assert summary.activity_label =~ "Pool wait"

    refute_receive {:dispatched, _}, 50

    # Pool recovers and broadcasts availability over PubSub.
    FakePoolPolicy.set_state(%{order: ["personal"], unavailable: nil})
    broadcast_pool_available(pubsub)

    assert_receive {:dispatched, "openai_codex:gpt-6.2-sol"}, 2_000

    wait_until(fn ->
      {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)

      Enum.any?(items, fn e ->
        e.kind == "assistant" and
          get_in(e.data, ["content", Access.at(0), "text"]) == "Recovered answer"
      end)
    end)

    {_seq, final_snap} = snapshot(sid, opts)
    assert final_snap["docs"]["live"] == %{}

    {:ok, final_summary} = Catalog.get_session(sid, catalog_table)
    assert final_summary.attention == "idle"
    assert final_summary.active == false
  end

  test "compaction enters pool_wait and wakes automatically when pool recovers" do
    FakePoolPolicy.set_state(%{
      order: ["personal"],
      unavailable: nil
    })

    %{daemon_opts: opts, cwd: cwd, pubsub: pubsub} =
      setup_env(
        reply_text: "Summary checkpoint",
        daemon_opts: [compaction_keep_recent_chars: 100]
      )

    sid = "pool-wait-compact"
    {:ok, _} = Daemon.create_session(%{"session_id" => sid, "cwd" => cwd}, opts)

    # Seed enough turns to be compactable without calling the provider.
    [{server, _}] = Registry.lookup(opts[:registry], {:session, sid})

    {:ok, %{seq: seq}} =
      H.Session.Server.seed_entries(
        server,
        [
          %{
            kind: "user",
            data: %{"content" => [%{"type" => "text", "text" => String.duplicate("u1 ", 100)}]}
          },
          %{
            kind: "assistant",
            data: %{"content" => [%{"type" => "text", "text" => String.duplicate("a1 ", 100)}]}
          },
          %{
            kind: "user",
            data: %{"content" => [%{"type" => "text", "text" => String.duplicate("u2 ", 100)}]}
          },
          %{
            kind: "assistant",
            data: %{"content" => [%{"type" => "text", "text" => String.duplicate("a2 ", 100)}]}
          }
        ],
        1
      )

    # Exhaust pool before manual compaction.
    FakePoolPolicy.set_state(%{
      order: [],
      unavailable: %{reason: :quota_exhausted, wait: true, wait_until_ms: nil}
    })

    {:ok, _} =
      Daemon.execute_command(
        sid,
        cmd("cmp-1", "compact", "1", %{"expected_seq" => seq}),
        opts
      )

    comp_retry =
      wait_until(fn ->
        {_seq, snap} = snapshot(sid, opts)

        case get_in(snap, ["docs", "live", "compaction", "retry"]) do
          %{"kind" => "pool_wait", "status" => "waiting"} = retry -> retry
          _ -> nil
        end
      end)

    assert comp_retry["code"] == "codex_pool_quota_exhausted"
    refute_receive {:dispatched, _}, 50

    FakePoolPolicy.set_state(%{order: ["work"], unavailable: nil})
    broadcast_pool_available(pubsub)

    assert_receive {:dispatched, "openai_codex:gpt-6.2-sol"}, 2_000

    wait_until(fn ->
      {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)
      Enum.any?(items, &(&1.kind == "compaction"))
    end)
  end

  test "reopening a session preserves sleeping pool_wait and resumes on PubSub recovery" do
    FakePoolPolicy.set_state(%{
      order: [],
      unavailable: %{reason: :workspace_blocked, wait: true, wait_until_ms: nil}
    })

    %{daemon_opts: opts, cwd: cwd, pubsub: pubsub, runtime_sup: runtime_sup, registry: registry} =
      setup_env()

    sid = "pool-wait-reopen"
    {:ok, _} = Daemon.create_session(%{"session_id" => sid, "cwd" => cwd}, opts)

    {:ok, _} =
      Daemon.execute_command(
        sid,
        cmd("reopen-1", "submit", "1", %{"type" => "input", "content" => "persist wait"}),
        opts
      )

    wait_until(fn ->
      {:ok, detail} = Daemon.get_session_detail(sid, opts)
      Enum.any?(detail.tasks, &(&1.status == "sleeping" and &1.wake["reason"] == "pool_wait"))
    end)

    # Cleanly stop the session supervisor and reopen it via Daemon.
    [{_, sup_pid, :supervisor, _}] = DynamicSupervisor.which_children(runtime_sup)
    :ok = DynamicSupervisor.terminate_child(runtime_sup, sup_pid)

    wait_until(fn -> Registry.lookup(registry, {:session, sid}) == [] end)

    {:ok, detail} = Daemon.get_session_detail(sid, opts)
    assert [gen_task] = Enum.filter(detail.tasks, &(&1.kind == "generation"))
    assert gen_task.status == "sleeping"
    assert gen_task.wake["reason"] == "pool_wait"
    refute_receive {:dispatched, _}, 50

    # Broadcast after reopen wakes the recovered coordinator!
    FakePoolPolicy.set_state(%{order: ["personal"], unavailable: nil})
    broadcast_pool_available(pubsub)

    assert_receive {:dispatched, "openai_codex:gpt-6.2-sol"}, 2_000

    wait_until(fn ->
      {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)
      Enum.any?(items, &(&1.kind == "assistant"))
    end)
  end

  test "wait_when_exhausted: false pauses immediately with codex_pool_credits_disabled" do
    FakePoolPolicy.set_state(%{
      order: [],
      unavailable: %{reason: :credits_disabled, wait: false, wait_until_ms: nil}
    })

    %{daemon_opts: opts, cwd: cwd} = setup_env()

    sid = "pool-no-wait"
    {:ok, _} = Daemon.create_session(%{"session_id" => sid, "cwd" => cwd}, opts)

    {:ok, _} =
      Daemon.execute_command(
        sid,
        cmd("nw-1", "submit", "1", %{"type" => "input", "content" => "no wait"}),
        opts
      )

    failure =
      wait_until(fn ->
        {_seq, snap} = snapshot(sid, opts)
        get_in(snap, ["docs", "live", "run_failure"])
      end)

    assert failure["code"] == "codex_pool_credits_disabled"
    assert failure["message"] =~ "allow_credits is false"
    refute_receive {:dispatched, _}, 50
  end

  test "switching model via configure during pool_wait wakes and runs on the new model" do
    FakePoolPolicy.set_state(%{
      order: [],
      unavailable: %{reason: :credits_disabled, wait: true, wait_until_ms: nil}
    })

    %{daemon_opts: opts, cwd: cwd} = setup_env()

    sid = "pool-switch-model"
    {:ok, _} = Daemon.create_session(%{"session_id" => sid, "cwd" => cwd}, opts)

    {:ok, _} =
      Daemon.execute_command(
        sid,
        cmd("sw-1", "submit", "1", %{"type" => "input", "content" => "switch me"}),
        opts
      )

    wait_until(fn ->
      {:ok, detail} = Daemon.get_session_detail(sid, opts)
      Enum.any?(detail.tasks, &(&1.status == "sleeping" and &1.wake["reason"] == "pool_wait"))
    end)

    {:ok, _} =
      Daemon.execute_command(
        sid,
        cmd("sw-2", "configure", "1", %{"model" => "openai:gpt-5.4"}),
        opts
      )

    assert_receive {:dispatched, "openai:gpt-5.4"}, 2_000

    wait_until(fn ->
      {:ok, %{items: items}} = Daemon.scan_entries(sid, "1", %{"order" => "asc"}, opts)
      Enum.any?(items, &(&1.kind == "assistant"))
    end)
  end

  test "aborting during pool_wait settles cleanly and ignores later pool availability broadcasts" do
    FakePoolPolicy.set_state(%{
      order: [],
      unavailable: %{reason: :credits_disabled, wait: true, wait_until_ms: nil}
    })

    %{daemon_opts: opts, cwd: cwd, pubsub: pubsub} = setup_env()

    sid = "pool-abort"
    {:ok, _} = Daemon.create_session(%{"session_id" => sid, "cwd" => cwd}, opts)

    {:ok, _} =
      Daemon.execute_command(
        sid,
        cmd("ab-1", "submit", "1", %{"type" => "input", "content" => "abort me"}),
        opts
      )

    wait_until(fn ->
      {:ok, detail} = Daemon.get_session_detail(sid, opts)
      Enum.any?(detail.tasks, &(&1.status == "sleeping" and &1.wake["reason"] == "pool_wait"))
    end)

    {:ok, _} =
      Daemon.execute_command(
        sid,
        cmd("ab-2", "abort", "1", %{"reason" => "user_aborted"}),
        opts
      )

    wait_until(fn ->
      {:ok, detail} = Daemon.get_session_detail(sid, opts)
      Enum.all?(detail.tasks, &(&1.status == "terminal"))
    end)

    FakePoolPolicy.set_state(%{order: ["personal"], unavailable: nil})
    broadcast_pool_available(pubsub)

    refute_receive {:dispatched, _}, 150
  end

  test "list_models surfaces unavailable_reason when pool is exhausted and Accounts.discover/2 exposes sanitized pool status" do
    reset_at = System.system_time(:millisecond) + 120_000

    FakePoolPolicy.set_state(%{
      order: [],
      unavailable: %{reason: :credits_disabled, wait: true, wait_until_ms: reset_at},
      pool_status: %{
        allow_credits: false,
        wait_when_exhausted: true,
        sources: [
          %{id: "personal", eligibility: :credits_disabled, reset_at_ms: reset_at},
          %{id: "work", eligibility: :quota_exhausted, reset_at_ms: reset_at}
        ]
      }
    })

    %{daemon_opts: opts, accounts: accounts, policy: policy} = setup_env()

    models = Daemon.list_models(opts)
    codex_models = Enum.filter(models, &(&1.provider == "openai_codex"))
    assert codex_models != []

    assert Enum.all?(
             codex_models,
             &(&1[:unavailable_reason] ==
                 "Codex pool included quota exhausted (allow_credits: false)")
           )

    assert {:ok, %{providers: [provider]}} = Accounts.discover(accounts, policy)
    assert provider.id == "openai_codex"

    assert provider.pool == %{
             enabled: true,
             allow_credits: false,
             wait_when_exhausted: true,
             sources: [
               %{id: "personal", eligibility: "credits_disabled", reset_at_ms: reset_at},
               %{id: "work", eligibility: "quota_exhausted", reset_at_ms: reset_at}
             ]
           }

    # Once an account becomes eligible, unavailable_reason clears.
    FakePoolPolicy.set_state(%{order: ["personal"], unavailable: nil})
    recovered_models = Daemon.list_models(opts)
    recovered_codex = Enum.filter(recovered_models, &(&1.provider == "openai_codex"))
    assert Enum.all?(recovered_codex, &(not Map.has_key?(&1, :unavailable_reason)))
  end
end
