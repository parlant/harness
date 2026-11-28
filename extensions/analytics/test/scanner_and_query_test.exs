defmodule Extensions.Analytics.ScannerAndQueryTest do
  use ExUnit.Case, async: true

  alias Extensions.Analytics
  alias Extensions.Analytics.{Observer, Query, Scanner, Store}
  alias H.{Archive, Catalog, Document, Storage}

  setup do
    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()

    root =
      Path.join(base, "h-analytics-test-#{System.pid()}-#{System.unique_integer([:positive])}")

    data_dir = Path.join(root, "data")
    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, data_dir: data_dir}
  end

  defp build_native_session(data_dir, sid, opts) do
    cwd = Keyword.get(opts, :cwd, "/tmp/work/proj-a")
    s_dir = Path.join([data_dir, "sessions", sid])
    File.mkdir_p!(s_dir)
    {:ok, store} = Storage.open(H.Storage.File, dir: s_dir, session_id: sid, cwd: cwd)

    base_ts = Keyword.get(opts, :base_ts, System.system_time(:millisecond) - 3_600_000)

    agent_v1 =
      Document.initial("agent", default_model: "openai:gpt-5.4")
      |> Map.put("thinking", "medium")

    agent_v2 =
      agent_v1
      |> Map.put("model", "anthropic:claude-opus-5-5")
      |> Map.put("thinking", "high")

    batches = [
      [
        {:put_session_meta,
         %{session_id: sid, cwd: cwd, created_at: base_ts, updated_at: base_ts + 50_000}},
        {:put_doc, {:conversation, 1, "agent"}, Document.wrap("agent", agent_v1)}
      ],
      [
        {:append_entry,
         %{
           id: 2,
           conversation_id: 1,
           kind: "user",
           data: %{"content" => [%{"type" => "text", "text" => "hello"}]},
           created_at: base_ts + 1_000
         }},
        {:append_entry,
         %{
           id: 3,
           conversation_id: 1,
           kind: "assistant",
           data: %{
             "content" => [%{"type" => "text", "text" => "running bash"}],
             "tool_calls" => [
               %{"id" => "call_1", "name" => "bash", "arguments" => %{"command" => "ls"}}
             ],
             "finish_reason" => "tool_calls",
             "duration_ms" => 1_000,
             "usage" => %{
               "input_tokens" => 60_000,
               "cached_tokens" => 40_000,
               "output_tokens" => 500,
               "reasoning_tokens" => 100,
               "total_tokens" => 60_500,
               "total_cost" => 0.25
             }
           },
           created_at: base_ts + 2_000
         }},
        {:append_entry,
         %{
           id: 4,
           conversation_id: 1,
           kind: "tool_result",
           data: %{
             "tool_call_id" => "call_1",
             "name" => "bash",
             "is_error" => false,
             "duration_ms" => 120
           },
           created_at: base_ts + 2_500
         }},
        {:put_task,
         %{
           id: 10,
           kind: "generation",
           version: 1,
           status: "terminal",
           owner: {:conversation, 1},
           restarts: 2
         }}
      ],
      [
        {:put_doc, {:conversation, 1, "agent"}, Document.wrap("agent", agent_v2)}
      ],
      [
        {:append_entry,
         %{
           id: 5,
           conversation_id: 1,
           kind: "assistant",
           data: %{
             "content" => [%{"type" => "text", "text" => "partial"}],
             "aborted" => true,
             "finish_reason" => "aborted",
             "duration_ms" => 2_500,
             "usage" => %{
               "input_tokens" => 10_000,
               "cached_tokens" => 0,
               "output_tokens" => 200,
               "total_cost" => 0.05
             }
           },
           created_at: base_ts + 12_500
         }},
        {:append_entry,
         %{
           id: 6,
           conversation_id: 1,
           kind: "tool_result",
           data: %{
             "tool_call_id" => "call_2",
             "name" => "edit",
             "is_error" => true,
             "duration_ms" => 450,
             "diagnostic" => "mismatch"
           },
           created_at: base_ts + 13_000
         }},
        {:append_entry,
         %{
           id: 7,
           conversation_id: 1,
           kind: "assistant",
           data: %{
             "content" => [%{"type" => "text", "text" => "failed"}],
             "finish_reason" => "error",
             "duration_ms" => 4_000,
             "usage" => %{
               "input_tokens" => 20_000,
               "cached_tokens" => 0,
               "output_tokens" => 0,
               "total_cost" => 0.10
             }
           },
           created_at: base_ts + 17_000
         }}
      ]
    ]

    {:ok, _res, store} = Storage.commit(store, batches)
    :ok = Storage.close(store)
    base_ts
  end

  defp build_pi_archive(data_dir, catalog_server, source_id, opts) do
    cwd = Keyword.get(opts, :cwd, "/tmp/work/proj-b")
    base_ts = Keyword.get(opts, :base_ts, System.system_time(:millisecond) - 1_800_000)

    archives_dir = Path.join(data_dir, "archives")
    File.mkdir_p!(archives_dir)
    staged_path = Path.join(archives_dir, "staged-#{System.unique_integer([:positive])}.tmp")
    {:ok, fd} = :file.open(staged_path, [:raw, :binary, :write])

    {:ok, state} =
      Archive.stage(
        %{
          "source" => "pi",
          "source_id" => source_id,
          "cwd" => cwd,
          "created_at" => base_ts,
          "revision" => 1,
          "size" => 1024
        },
        fd
      )

    {:ok, state} =
      Archive.append(state, %{
        "parent" => nil,
        "kind" => "user",
        "data" => %{"text" => "pi prompt"},
        "created_at" => base_ts + 1_000
      })

    {:ok, state} =
      Archive.append(state, %{
        "parent" => 2,
        "kind" => "assistant",
        "data" => %{
          "provider" => "openai-codex",
          "model" => "gpt-5.3-codex",
          "thinkingLevel" => "xhigh",
          "durationMs" => 2_000,
          "stopReason" => "stop",
          "usage" => %{
            "input" => 300_000,
            "output" => 1_000,
            "cacheRead" => 150_000,
            "cacheWrite" => 25_000,
            "totalTokens" => 476_000,
            "cost" => %{"total" => 0.75}
          }
        },
        "created_at" => base_ts + 3_000
      })

    {:ok, state} =
      Archive.append(state, %{
        "parent" => 4,
        "kind" => "tool_result",
        "data" => %{
          "toolCallId" => "pi_call_1",
          "name" => "read",
          "isError" => false,
          "durationMs" => 80
        },
        "created_at" => base_ts + 3_200
      })

    {:ok, attrs} = Archive.finish(state, 3)
    :ok = :file.close(fd)

    {:ok, "created"} = Catalog.publish_archive(catalog_server, attrs, staged_path)
    attrs.session_id
  end

  describe "Extensions.Analytics.configure/2" do
    test "validates settings and returns web + observer + store contributions", %{
      data_dir: data_dir
    } do
      assert {:error, :invalid_analytics_settings} =
               Analytics.configure(%{"unknown" => 1}, %{data_dir: data_dir})

      assert {:error, :invalid_analytics_settings} =
               Analytics.configure(%{"sync_interval_ms" => 100}, %{data_dir: data_dir})

      assert {:ok,
              %{
                observers: [Observer],
                children: [{Store, child_opts}],
                web:
                  %{
                    pages: [
                      %{slug: "analytics", module: Extensions.Analytics.Live, title: "Analytics"}
                    ],
                    nav_items: [
                      %{id: "analytics", label: "Analytics", slug: "analytics", order: 30}
                    ],
                    stylesheets: ["analytics.css"],
                    scripts: ["analytics.js"]
                  } = web
              }} =
               Analytics.configure(%{"sync_interval_ms" => 2_000, "batch_size" => 10}, %{
                 data_dir: data_dir
               })

      assert child_opts[:data_dir] == data_dir
      assert child_opts[:sync_interval_ms] == 2_000
      assert child_opts[:batch_size] == 10

      ext_root = Path.expand("..", __DIR__)
      static_dir = Path.join([ext_root, "priv", "static"])

      assert {:ok,
              %{
                ext_id: "analytics",
                static_dir: ^static_dir,
                pages: [
                  %{
                    ext_id: "analytics",
                    slug: "analytics",
                    path: "/ext/analytics",
                    module: Extensions.Analytics.Live,
                    title: "Analytics"
                  }
                ],
                nav_items: [
                  %{
                    ext_id: "analytics",
                    id: "analytics",
                    label: "Analytics",
                    path: "/ext/analytics",
                    section: {:ext, "analytics"},
                    order: 30
                  }
                ],
                stylesheets: [
                  %{
                    ext_id: "analytics",
                    file: "analytics.css",
                    href: "/ext-assets/analytics/analytics.css"
                  }
                ],
                scripts: [
                  %{
                    ext_id: "analytics",
                    file: "analytics.js",
                    src: "/ext-assets/analytics/analytics.js"
                  }
                ]
              }} = H.Extensions.Web.validate(web, %{id: "analytics", path: ext_root})
    end
  end

  describe "Scanner.scan_session/2 and Scanner.inspect_session/3" do
    test "scans native session with mid-conversation model switch without waking H.Session.Server",
         %{
           data_dir: data_dir
         } do
      suffix = System.unique_integer([:positive])
      catalog = :"analytics_cat_#{suffix}"
      table = :"analytics_tbl_#{suffix}"
      start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: table, pubsub: nil})

      base_ts = build_native_session(data_dir, "sess-native-1", cwd: "/tmp/work/alpha")

      {:ok, entry} =
        Catalog.put_session(catalog, %{
          session_id: "sess-native-1",
          title: "Native Alpha",
          cwd: "/tmp/work/alpha",
          created_at: base_ts,
          updated_at: base_ts + 50_000
        })

      discovered = Scanner.discover_catalog(data_dir, catalog_table: table)
      assert [%{session_id: "sess-native-1", source_kind: "native_active"}] = discovered

      assert {:ok, summary} = Scanner.scan_session(data_dir, hd(discovered))
      assert summary.totals.restarts == 2
      assert summary.totals.turn_count == 3
      assert summary.totals.completed_turns == 1
      assert summary.totals.aborted_turns == 1
      assert summary.totals.error_turns == 1
      assert summary.totals.wasted_ms == 6_500
      assert summary.totals.tool_calls == 2
      assert summary.totals.tool_errors == 1

      # OpenAI-style usage: input_tokens (60k) includes cached_tokens (40k) -> uncached = 20k
      [t1, t2, t3] = summary.turns
      assert t1.provider == "openai"
      assert t1.model == "gpt-5.4"
      assert t1.thinking == "medium"
      assert t1.prompt_tokens == 60_000
      assert t1.cache_read_tokens == 40_000
      assert t1.uncached_tokens == 20_000
      assert t1.context_band == "50k-250k"
      assert t1.cache_hit == true
      assert t1.tps == 500.0

      # Mid-conversation switch to anthropic:claude-opus-5-5 / high
      assert t2.provider == "anthropic"
      assert t2.model == "claude-opus-5-5"
      assert t2.thinking == "high"
      assert t2.outcome == "aborted"
      assert t2.tps == nil

      assert t3.provider == "anthropic"
      assert t3.model == "claude-opus-5-5"
      assert t3.outcome == "error"

      # Verify zero H.Session.Server processes were started
      assert Process.whereis(H.Session.Supervisor) == nil
      assert entry.session_id == "sess-native-1"

      # Inspect waterfall
      assert {:ok, %{session: _, events: events}} =
               Scanner.inspect_session(data_dir, "sess-native-1", catalog_table: table)

      assert Enum.map(events, & &1.kind) == [
               "user",
               "assistant",
               "tool_result",
               "assistant",
               "tool_result",
               "assistant"
             ]

      assert Enum.at(events, 1).tool_calls == ["bash"]
      assert Enum.at(events, 4).diagnostic == "mismatch"
    end

    test "scans imported Pi archive with Pi cache/cost schema and provider normalization", %{
      data_dir: data_dir
    } do
      suffix = System.unique_integer([:positive])
      catalog = :"analytics_pi_cat_#{suffix}"
      table = :"analytics_pi_tbl_#{suffix}"
      start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: table, pubsub: nil})

      sid = build_pi_archive(data_dir, catalog, "pi-sess-42", cwd: "/tmp/work/beta")

      [entry] = Scanner.discover_catalog(data_dir, catalog_table: table)
      assert entry.session_id == sid
      assert entry.source_kind == "imported_archive"

      assert {:ok, summary} = Scanner.scan_session(data_dir, entry)

      # Ensure normalize_provider does not intern runtime strings as atoms
      assert Scanner.normalize_provider("never_created_atom_provider_xyz") ==
               "never_created_atom_provider_xyz"

      assert_raise ArgumentError, fn ->
        String.to_existing_atom("never_created_atom_provider_xyz")
      end

      assert [turn] = summary.turns
      assert turn.provider == "openai_codex"
      assert turn.model == "gpt-5.3-codex"
      assert turn.thinking == "xhigh"
      assert turn.duration_ms == 2_000
      assert turn.tps == 500.0
      # Pi schema: input=300k (uncached), cacheRead=150k, cacheWrite=25k, totalTokens=476k
      # prompt_tokens = 300k + 150k + 25k = 475k, uncached = 300k
      assert turn.prompt_tokens == 475_000
      assert turn.uncached_tokens == 300_000
      assert turn.cache_read_tokens == 150_000
      assert turn.cache_write_tokens == 25_000
      assert turn.context_band == "400k+"
      assert turn.cost_usd == 0.75

      assert [tool] = summary.tools
      assert tool.name == "read"
      assert tool.is_error == false
      assert tool.duration_ms == 80
    end
  end

  describe "Query.run/3 and Store incremental sync" do
    test "aggregates KPIs, percentiles, breakdowns, filters, and persists index.v1.etf", %{
      data_dir: data_dir
    } do
      suffix = System.unique_integer([:positive])
      catalog = :"analytics_q_cat_#{suffix}"
      table = :"analytics_q_tbl_#{suffix}"
      store_name = :"analytics_store_#{suffix}"
      ets_table = :"analytics_ets_#{suffix}"

      start_supervised!({Catalog, data_dir: data_dir, name: catalog, table: table, pubsub: nil})

      now = System.system_time(:millisecond)
      base_ts = now - 60_000

      build_native_session(data_dir, "sess-active-1", cwd: "/tmp/work/alpha", base_ts: base_ts)

      {:ok, _} =
        Catalog.put_session(catalog, %{
          session_id: "sess-active-1",
          title: "Active Alpha",
          cwd: "/tmp/work/alpha",
          created_at: base_ts,
          updated_at: base_ts + 50_000
        })

      # Subsession that is archived natively
      build_native_session(data_dir, "sess-sub-1", cwd: "/tmp/work/alpha", base_ts: base_ts)

      {:ok, _} =
        Catalog.put_session(catalog, %{
          session_id: "sess-sub-1",
          title: "Sub Alpha",
          cwd: "/tmp/work/alpha",
          parent: %{session_id: "sess-active-1", conversation_id: 1, depth: 1},
          archived: true,
          created_at: base_ts,
          updated_at: base_ts + 50_000
        })

      archive_sid =
        build_pi_archive(data_dir, catalog, "pi-99", cwd: "/tmp/work/beta", base_ts: base_ts)

      store_pid =
        start_supervised!(
          {Store,
           data_dir: data_dir,
           name: store_name,
           table: ets_table,
           catalog_table: table,
           sync_interval_ms: 0,
           auto_sync: false}
        )

      assert {:ok, stats1} = Store.sync_now(store_pid)
      assert stats1.total == 3
      assert stats1.scanned == 3
      assert stats1.errors == 0

      # Second sync with unchanged fingerprints should scan 0 sessions
      assert {:ok, stats2} = Store.sync_now(store_pid)
      assert stats2.scanned == 0

      # Index ETF persisted on disk
      index_path = Path.join([data_dir, "extensions_state", "analytics", "index.v1.etf"])
      assert File.regular?(index_path)

      # Default window is "all"
      assert Query.normalize_filters(%{}).window == "all"
      assert Query.normalize_filters(%{"window" => "24h"}).window == "24h"
      assert Query.normalize_filters(%{"window" => "invalid"}).window == "all"

      # Full query across all 3 sessions
      res = Store.query(%{"window" => "30d"}, server: store_pid, now_ms: now)
      assert res.kpis.session_count == 3

      assert res.kpis.sessions_by_source == %{
               "native_active" => 1,
               "native_archived" => 1,
               "imported_archive" => 1
             }

      assert res.kpis.turn_count == 7
      assert res.kpis.completed_turns == 3
      assert res.kpis.error_turns == 2
      assert res.kpis.aborted_turns == 2
      assert res.kpis.tool_calls == 5
      assert res.kpis.tool_errors == 2
      assert res.kpis.tool_error_pct == 40.0
      # Durations across 7 turns: [1000, 1000, 2000, 2500, 2500, 4000, 4000]
      assert res.kpis.p50_turn_ms == 2_500
      assert res.kpis.p90_turn_ms == 4_000
      assert res.kpis.median_tps == 500.0

      assert Enum.map(res.filter_options.providers, & &1) == [
               "anthropic",
               "openai",
               "openai_codex"
             ]

      assert length(res.workspace_breakdown) == 2

      # Filter to roots_only + provider=openai_codex
      filtered =
        Store.query(
          %{"subsessions" => "roots_only", "provider" => "openai_codex"},
          server: store_pid,
          now_ms: now
        )

      assert filtered.kpis.session_count == 1
      assert hd(filtered.sessions).session_id == archive_sid
      assert filtered.kpis.prompt_tokens == 475_000

      # Focused model breakdown
      focused =
        Store.query(%{"model" => "claude-opus-5-5"}, server: store_pid, now_ms: now)

      assert focused.focused_model_breakdown.model == "claude-opus-5-5"
      assert [%{thinking: "high", turns: 4}] = focused.focused_model_breakdown.by_thinking

      # Mark dirty via Observer API and verify rescan occurs
      :ok = Store.mark_dirty("sess-active-1", store_pid)
      assert {:ok, stats3} = Store.sync_now(store_pid)
      assert stats3.scanned == 1

      # Direct fallback without Store running
      direct =
        Store.query(
          %{"source" => "imported_archive"},
          data_dir: data_dir,
          catalog_table: table,
          server: :nonexistent_analytics_store,
          table: :nonexistent_analytics_ets,
          now_ms: now
        )

      assert direct.kpis.session_count == 1
      assert hd(direct.sessions).session_id == archive_sid

      # Exact percentile check
      assert Query.percentile([10, 20, 30, 40, 50, 60, 70, 80, 90, 100], 50) == 50
      assert Query.percentile([10, 20, 30, 40, 50, 60, 70, 80, 90, 100], 90) == 90
      assert Query.percentile([], 90) == nil
    end
  end
end
