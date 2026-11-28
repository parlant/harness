defmodule Extensions.Analytics.Query do
  @moduledoc """
  Pure query and aggregation engine over scanned session summaries.

  Supports filtering by `window` (`"24h"`, `"7d"`, `"30d"`, `"90d"`, `"all"`),
  `source` (`"all"`, `"native"`, `"native_active"`, `"native_archived"`, `"imported_archive"`),
  `subsessions` (`"all"`, `"roots_only"`, `"subsessions_only"`),
  `provider`, `model`, `cwd`, and `cache` (`"all"`, `"hit"`, `"miss"`).
  """

  @context_band_order %{"0-50k" => 0, "50k-250k" => 1, "250k-400k" => 2, "400k+" => 3}

  @default_filters %{
    window: "all",
    source: "all",
    subsessions: "all",
    provider: nil,
    model: nil,
    cwd: nil,
    cache: "all",
    sort_by: "updated_at",
    sort_dir: "desc"
  }

  @doc """
  Returns the default normalized filters map.
  """
  @spec default_filters() :: map()
  def default_filters, do: @default_filters

  @doc """
  Normalizes filter params (string- or atom-keyed) without creating atoms.
  """
  @spec normalize_filters(map()) :: map()
  def normalize_filters(params \\ %{}) when is_map(params) do
    get = fn k -> Map.get(params, k) || Map.get(params, Atom.to_string(k)) end

    %{
      window:
        normalize_enum(get.(:window), ["24h", "7d", "30d", "90d", "all"], @default_filters.window),
      source:
        normalize_enum(
          get.(:source),
          ["all", "native", "native_active", "native_archived", "imported_archive"],
          @default_filters.source
        ),
      subsessions:
        normalize_enum(
          get.(:subsessions),
          ["all", "roots_only", "subsessions_only"],
          @default_filters.subsessions
        ),
      provider: normalize_optional_string(get.(:provider)),
      model: normalize_optional_string(get.(:model)),
      cwd: normalize_optional_string(get.(:cwd)),
      cache: normalize_enum(get.(:cache), ["all", "hit", "miss"], @default_filters.cache),
      sort_by:
        normalize_enum(
          get.(:sort_by),
          ["updated_at", "cost", "tokens", "p90_ms", "errors"],
          @default_filters.sort_by
        ),
      sort_dir: normalize_enum(get.(:sort_dir), ["asc", "desc"], @default_filters.sort_dir)
    }
  end

  @doc """
  Executes an analytics query over a list of session summaries.
  """
  @spec run([map()], map(), keyword()) :: map()
  def run(summaries, params \\ %{}, opts \\ []) when is_list(summaries) and is_map(params) do
    filters = normalize_filters(params)
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    cutoff_ms = window_cutoff_ms(filters.window, now_ms)

    # First apply session-level metadata filters except provider/model/cache
    meta_filtered =
      Enum.filter(summaries, fn s ->
        source_matches?(s, filters.source) and
          subsession_matches?(s, filters.subsessions) and
          cwd_matches?(s, filters.cwd)
      end)

    filter_options = collect_filter_options(summaries, cutoff_ms)

    # Build filtered per-session slices (turning turns & tools through window + provider/model/cache)
    session_slices =
      Enum.reduce(meta_filtered, [], fn s, acc ->
        turns = filter_turns(s.turns || [], cutoff_ms, filters)
        tools = filter_tools(s.tools || [], cutoff_ms)

        include_session? =
          if filters.provider || filters.model || filters.cache != "all" do
            turns != []
          else
            window_matches_session?(s, turns, tools, cutoff_ms)
          end

        if include_session? do
          [build_session_slice(s, turns, tools) | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    all_turns = Enum.flat_map(session_slices, & &1.turns)
    all_tools = Enum.flat_map(session_slices, & &1.tools)

    %{
      filters: filters,
      filter_options: filter_options,
      kpis: compute_kpis(session_slices, all_turns, all_tools),
      daily_series: compute_daily_series(all_turns),
      model_breakdown: compute_model_breakdown(all_turns),
      focused_model_breakdown: compute_focused_model_breakdown(all_turns, filters.model),
      context_band_breakdown: compute_context_band_breakdown(all_turns),
      tool_breakdown: compute_tool_breakdown(session_slices),
      workspace_breakdown: compute_workspace_breakdown(session_slices),
      sessions: sort_sessions(session_slices, filters.sort_by, filters.sort_dir)
    }
  end

  @doc """
  Computes exact nearest-rank percentile (`p` in `0..100`) on a list of numbers.
  Returns `nil` for empty lists.
  """
  @spec percentile([number()], number()) :: number() | nil
  def percentile([], _p), do: nil

  def percentile(values, p) when is_list(values) and is_number(p) do
    sorted = Enum.sort(values)
    count = length(sorted)
    rank = max(1, ceil(p / 100.0 * count))
    Enum.at(sorted, rank - 1)
  end

  # Filtering

  defp window_cutoff_ms("all", _now_ms), do: nil
  defp window_cutoff_ms("24h", now_ms), do: now_ms - 86_400_000
  defp window_cutoff_ms("7d", now_ms), do: now_ms - 7 * 86_400_000
  defp window_cutoff_ms("30d", now_ms), do: now_ms - 30 * 86_400_000
  defp window_cutoff_ms("90d", now_ms), do: now_ms - 90 * 86_400_000

  defp source_matches?(_s, "all"), do: true
  defp source_matches?(s, "native"), do: s.source_kind in ["native_active", "native_archived"]
  defp source_matches?(s, kind), do: s.source_kind == kind

  defp subsession_matches?(_s, "all"), do: true
  defp subsession_matches?(s, "roots_only"), do: not (s.is_subsession == true)
  defp subsession_matches?(s, "subsessions_only"), do: s.is_subsession == true

  defp cwd_matches?(_s, nil), do: true
  defp cwd_matches?(s, cwd), do: s.cwd == cwd

  defp filter_turns(turns, cutoff_ms, filters) do
    Enum.filter(turns, fn t ->
      (is_nil(cutoff_ms) or (t.ts || 0) >= cutoff_ms) and
        (is_nil(filters.provider) or t.provider == filters.provider) and
        (is_nil(filters.model) or t.model == filters.model) and
        case filters.cache do
          "all" -> true
          "hit" -> t.cache_hit == true
          "miss" -> t.cache_hit == false
        end
    end)
  end

  defp filter_tools(tools, nil), do: tools

  defp filter_tools(tools, cutoff_ms) do
    Enum.filter(tools, fn tr -> (tr.ts || 0) >= cutoff_ms end)
  end

  defp window_matches_session?(_s, _turns, _tools, nil), do: true

  defp window_matches_session?(s, turns, tools, cutoff_ms) do
    turns != [] or tools != [] or (s.updated_at || 0) >= cutoff_ms
  end

  defp build_session_slice(s, turns, tools) do
    turn_durs = for t <- turns, is_integer(t.duration_ms) and t.duration_ms > 0, do: t.duration_ms

    tool_durs =
      for tr <- tools, is_integer(tr.duration_ms) and tr.duration_ms > 0, do: tr.duration_ms

    agg =
      Enum.reduce(
        turns,
        %{
          turn_count: 0,
          completed_turns: 0,
          error_turns: 0,
          aborted_turns: 0,
          wasted_ms: 0,
          prompt_tokens: 0,
          uncached_tokens: 0,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
          output_tokens: 0,
          reasoning_tokens: 0,
          cost_usd: 0.0,
          turn_duration_ms: 0,
          models: MapSet.new(),
          providers: MapSet.new()
        },
        fn t, acc ->
          dur = t.duration_ms || 0
          wasted = if t.outcome in ["error", "aborted"], do: dur, else: 0

          %{
            acc
            | turn_count: acc.turn_count + 1,
              completed_turns: acc.completed_turns + if(t.outcome == "completed", do: 1, else: 0),
              error_turns: acc.error_turns + if(t.outcome == "error", do: 1, else: 0),
              aborted_turns: acc.aborted_turns + if(t.outcome == "aborted", do: 1, else: 0),
              wasted_ms: acc.wasted_ms + wasted,
              prompt_tokens: acc.prompt_tokens + t.prompt_tokens,
              uncached_tokens: acc.uncached_tokens + t.uncached_tokens,
              cache_read_tokens: acc.cache_read_tokens + t.cache_read_tokens,
              cache_write_tokens: acc.cache_write_tokens + t.cache_write_tokens,
              output_tokens: acc.output_tokens + t.output_tokens,
              reasoning_tokens: acc.reasoning_tokens + t.reasoning_tokens,
              cost_usd: acc.cost_usd + t.cost_usd,
              turn_duration_ms: acc.turn_duration_ms + dur,
              models: MapSet.put(acc.models, t.model),
              providers: MapSet.put(acc.providers, t.provider)
          }
        end
      )

    tool_errors = Enum.count(tools, & &1.is_error)
    tool_duration_ms = Enum.reduce(tools, 0, fn tr, acc -> acc + (tr.duration_ms || 0) end)

    %{
      session_id: s.session_id,
      title: s.title,
      cwd: s.cwd,
      env_id: s.env_id,
      source_kind: s.source_kind,
      is_subsession: s.is_subsession,
      parent_session_id: s.parent_session_id,
      role: s.role,
      created_at: s.created_at,
      updated_at: s.updated_at,
      restarts: get_in(s, [:totals, :restarts]) || 0,
      turns: turns,
      tools: tools,
      models: MapSet.to_list(agg.models) |> Enum.sort(),
      providers: MapSet.to_list(agg.providers) |> Enum.sort(),
      turn_count: agg.turn_count,
      completed_turns: agg.completed_turns,
      error_turns: agg.error_turns,
      aborted_turns: agg.aborted_turns,
      wasted_ms: agg.wasted_ms,
      prompt_tokens: agg.prompt_tokens,
      uncached_tokens: agg.uncached_tokens,
      cache_read_tokens: agg.cache_read_tokens,
      cache_write_tokens: agg.cache_write_tokens,
      output_tokens: agg.output_tokens,
      reasoning_tokens: agg.reasoning_tokens,
      cost_usd: Float.round(agg.cost_usd, 8),
      turn_duration_ms: agg.turn_duration_ms,
      p50_turn_ms: percentile(turn_durs, 50),
      p90_turn_ms: percentile(turn_durs, 90),
      tool_calls: length(tools),
      tool_errors: tool_errors,
      tool_duration_ms: tool_duration_ms,
      p90_tool_ms: percentile(tool_durs, 90),
      total_errors: agg.error_turns + agg.aborted_turns + tool_errors
    }
  end

  # Aggregations

  defp compute_kpis(session_slices, turns, tools) do
    by_source =
      Enum.reduce(
        session_slices,
        %{"native_active" => 0, "native_archived" => 0, "imported_archive" => 0},
        fn s, acc -> Map.update(acc, s.source_kind, 1, &(&1 + 1)) end
      )

    turn_stats =
      Enum.reduce(
        turns,
        %{
          turns: 0,
          completed: 0,
          errors: 0,
          aborted: 0,
          wasted_ms: 0,
          prompt_tokens: 0,
          cache_read_tokens: 0,
          cache_write_tokens: 0,
          uncached_tokens: 0,
          output_tokens: 0,
          reasoning_tokens: 0,
          cost_usd: 0.0,
          durs: [],
          tps: []
        },
        fn t, acc ->
          dur = t.duration_ms || 0
          wasted = if t.outcome in ["error", "aborted"], do: dur, else: 0

          %{
            acc
            | turns: acc.turns + 1,
              completed: acc.completed + if(t.outcome == "completed", do: 1, else: 0),
              errors: acc.errors + if(t.outcome == "error", do: 1, else: 0),
              aborted: acc.aborted + if(t.outcome == "aborted", do: 1, else: 0),
              wasted_ms: acc.wasted_ms + wasted,
              prompt_tokens: acc.prompt_tokens + t.prompt_tokens,
              cache_read_tokens: acc.cache_read_tokens + t.cache_read_tokens,
              cache_write_tokens: acc.cache_write_tokens + t.cache_write_tokens,
              uncached_tokens: acc.uncached_tokens + t.uncached_tokens,
              output_tokens: acc.output_tokens + t.output_tokens,
              reasoning_tokens: acc.reasoning_tokens + t.reasoning_tokens,
              cost_usd: acc.cost_usd + t.cost_usd,
              durs:
                if(is_integer(t.duration_ms) and t.duration_ms > 0,
                  do: [t.duration_ms | acc.durs],
                  else: acc.durs
                ),
              tps: if(is_number(t.tps), do: [t.tps | acc.tps], else: acc.tps)
          }
        end
      )

    tool_durs =
      for tr <- tools, is_integer(tr.duration_ms) and tr.duration_ms > 0, do: tr.duration_ms

    tool_calls = length(tools)
    tool_errors = Enum.count(tools, & &1.is_error)

    cache_hit_pct =
      if turn_stats.prompt_tokens > 0 do
        Float.round(turn_stats.cache_read_tokens * 100.0 / turn_stats.prompt_tokens, 1)
      else
        0.0
      end

    tool_error_pct =
      if tool_calls > 0 do
        Float.round(tool_errors * 100.0 / tool_calls, 1)
      else
        0.0
      end

    %{
      session_count: length(session_slices),
      sessions_by_source: by_source,
      turn_count: turn_stats.turns,
      completed_turns: turn_stats.completed,
      error_turns: turn_stats.errors,
      aborted_turns: turn_stats.aborted,
      wasted_ms: turn_stats.wasted_ms,
      cost_usd: Float.round(turn_stats.cost_usd, 6),
      prompt_tokens: turn_stats.prompt_tokens,
      cached_tokens: turn_stats.cache_read_tokens,
      cache_write_tokens: turn_stats.cache_write_tokens,
      uncached_tokens: turn_stats.uncached_tokens,
      output_tokens: turn_stats.output_tokens,
      reasoning_tokens: turn_stats.reasoning_tokens,
      cache_hit_pct: cache_hit_pct,
      p50_turn_ms: percentile(turn_stats.durs, 50),
      p90_turn_ms: percentile(turn_stats.durs, 90),
      median_tps: percentile(turn_stats.tps, 50),
      tool_calls: tool_calls,
      tool_errors: tool_errors,
      tool_error_pct: tool_error_pct,
      p50_tool_ms: percentile(tool_durs, 50),
      p90_tool_ms: percentile(tool_durs, 90),
      restarts: Enum.reduce(session_slices, 0, &(&1.restarts + &2))
    }
  end

  defp compute_daily_series(turns) do
    turns
    |> Enum.reject(&(&1.day == "unknown"))
    |> Enum.group_by(& &1.day)
    |> Enum.map(fn {day, day_turns} ->
      Enum.reduce(
        day_turns,
        %{
          day: day,
          turns: 0,
          cost_usd: 0.0,
          prompt_tokens: 0,
          cached_tokens: 0,
          uncached_tokens: 0,
          output_tokens: 0,
          error_turns: 0,
          aborted_turns: 0
        },
        fn t, acc ->
          %{
            acc
            | turns: acc.turns + 1,
              cost_usd: acc.cost_usd + t.cost_usd,
              prompt_tokens: acc.prompt_tokens + t.prompt_tokens,
              cached_tokens: acc.cached_tokens + t.cache_read_tokens,
              uncached_tokens: acc.uncached_tokens + t.uncached_tokens,
              output_tokens: acc.output_tokens + t.output_tokens,
              error_turns: acc.error_turns + if(t.outcome == "error", do: 1, else: 0),
              aborted_turns: acc.aborted_turns + if(t.outcome == "aborted", do: 1, else: 0)
          }
        end
      )
      |> Map.update!(:cost_usd, &Float.round(&1, 6))
    end)
    |> Enum.sort_by(& &1.day)
  end

  defp compute_model_breakdown(turns) do
    turns
    |> Enum.group_by(&{&1.provider, &1.model})
    |> Enum.map(fn {{provider, model}, group} ->
      summarize_turn_group(group, %{provider: provider, model: model})
    end)
    |> Enum.sort_by(&{-&1.cost_usd, -&1.turns, &1.model})
  end

  defp compute_focused_model_breakdown(_turns, nil), do: nil

  defp compute_focused_model_breakdown(turns, model) do
    matching = Enum.filter(turns, &(&1.model == model))

    by_thinking =
      matching
      |> Enum.group_by(& &1.thinking)
      |> Enum.map(fn {thinking, group} ->
        summarize_turn_group(group, %{thinking: thinking})
      end)
      |> Enum.sort_by(&{-&1.turns, &1.thinking})

    by_context_cache =
      matching
      |> Enum.group_by(&{&1.context_band, &1.cache_hit})
      |> Enum.map(fn {{band, cache_hit}, group} ->
        summarize_turn_group(group, %{context_band: band, cache_hit: cache_hit})
      end)
      |> Enum.sort_by(&{Map.get(@context_band_order, &1.context_band, 99), &1.cache_hit})

    %{
      model: model,
      by_thinking: by_thinking,
      by_context_cache: by_context_cache
    }
  end

  defp compute_context_band_breakdown(turns) do
    turns
    |> Enum.group_by(&{&1.context_band, &1.cache_hit})
    |> Enum.map(fn {{band, cache_hit}, group} ->
      summarize_turn_group(group, %{
        context_band: band,
        cache_hit: cache_hit,
        cache_label: if(cache_hit, do: "cache_hit", else: "cache_miss")
      })
    end)
    |> Enum.sort_by(&{Map.get(@context_band_order, &1.context_band, 99), &1.cache_hit})
  end

  defp summarize_turn_group(group, extra_fields) do
    stats =
      Enum.reduce(
        group,
        %{
          turns: 0,
          completed: 0,
          errors: 0,
          aborted: 0,
          prompt_tokens: 0,
          cached_tokens: 0,
          uncached_tokens: 0,
          output_tokens: 0,
          reasoning_tokens: 0,
          cost_usd: 0.0,
          durs: [],
          tps: []
        },
        fn t, acc ->
          %{
            acc
            | turns: acc.turns + 1,
              completed: acc.completed + if(t.outcome == "completed", do: 1, else: 0),
              errors: acc.errors + if(t.outcome == "error", do: 1, else: 0),
              aborted: acc.aborted + if(t.outcome == "aborted", do: 1, else: 0),
              prompt_tokens: acc.prompt_tokens + t.prompt_tokens,
              cached_tokens: acc.cached_tokens + t.cache_read_tokens,
              uncached_tokens: acc.uncached_tokens + t.uncached_tokens,
              output_tokens: acc.output_tokens + t.output_tokens,
              reasoning_tokens: acc.reasoning_tokens + t.reasoning_tokens,
              cost_usd: acc.cost_usd + t.cost_usd,
              durs:
                if(is_integer(t.duration_ms) and t.duration_ms > 0,
                  do: [t.duration_ms | acc.durs],
                  else: acc.durs
                ),
              tps: if(is_number(t.tps), do: [t.tps | acc.tps], else: acc.tps)
          }
        end
      )

    cache_pct =
      if stats.prompt_tokens > 0 do
        Float.round(stats.cached_tokens * 100.0 / stats.prompt_tokens, 1)
      else
        0.0
      end

    Map.merge(extra_fields, %{
      turns: stats.turns,
      completed: stats.completed,
      errors: stats.errors,
      aborted: stats.aborted,
      prompt_tokens: stats.prompt_tokens,
      cached_tokens: stats.cached_tokens,
      uncached_tokens: stats.uncached_tokens,
      output_tokens: stats.output_tokens,
      reasoning_tokens: stats.reasoning_tokens,
      cache_pct: cache_pct,
      cost_usd: Float.round(stats.cost_usd, 6),
      p50_ms: percentile(stats.durs, 50),
      p90_ms: percentile(stats.durs, 90),
      median_tps: percentile(stats.tps, 50)
    })
  end

  defp compute_tool_breakdown(session_slices) do
    grouped =
      Enum.reduce(session_slices, %{}, fn s, acc ->
        Enum.reduce(s.tools, acc, fn tr, tool_acc ->
          entry =
            Map.get(tool_acc, tr.name, %{
              count: 0,
              errors: 0,
              total_ms: 0,
              max_ms: 0,
              durs: [],
              by_session: %{}
            })

          dur = tr.duration_ms || 0

          sess_entry =
            Map.get(entry.by_session, s.session_id, %{
              session_id: s.session_id,
              title: s.title,
              errors: 0,
              max_ms: 0,
              total_ms: 0,
              count: 0
            })

          next_sess = %{
            sess_entry
            | count: sess_entry.count + 1,
              errors: sess_entry.errors + if(tr.is_error, do: 1, else: 0),
              max_ms: max(sess_entry.max_ms, dur),
              total_ms: sess_entry.total_ms + dur
          }

          next_entry = %{
            entry
            | count: entry.count + 1,
              errors: entry.errors + if(tr.is_error, do: 1, else: 0),
              total_ms: entry.total_ms + dur,
              max_ms: max(entry.max_ms, dur),
              durs:
                if(is_integer(tr.duration_ms) and tr.duration_ms > 0,
                  do: [tr.duration_ms | entry.durs],
                  else: entry.durs
                ),
              by_session: Map.put(entry.by_session, s.session_id, next_sess)
          }

          Map.put(tool_acc, tr.name, next_entry)
        end)
      end)

    grouped
    |> Enum.map(fn {name, st} ->
      error_pct = if st.count > 0, do: Float.round(st.errors * 100.0 / st.count, 1), else: 0.0

      top_failing =
        st.by_session
        |> Map.values()
        |> Enum.filter(&(&1.errors > 0))
        |> Enum.sort_by(&{-&1.errors, -&1.count, &1.session_id})
        |> Enum.take(3)

      top_slow =
        st.by_session
        |> Map.values()
        |> Enum.filter(&(&1.max_ms > 0))
        |> Enum.sort_by(&{-&1.max_ms, -&1.total_ms, &1.session_id})
        |> Enum.take(3)

      %{
        name: name,
        count: st.count,
        errors: st.errors,
        error_pct: error_pct,
        p50_ms: percentile(st.durs, 50),
        p90_ms: percentile(st.durs, 90),
        max_ms: st.max_ms,
        total_ms: st.total_ms,
        top_failing_sessions: top_failing,
        top_slow_sessions: top_slow
      }
    end)
    |> Enum.sort_by(&{-&1.count, -&1.errors, &1.name})
  end

  defp compute_workspace_breakdown(session_slices) do
    Enum.group_by(session_slices, & &1.cwd)
    |> Enum.map(fn {cwd, slices} ->
      Enum.reduce(
        slices,
        %{
          cwd: cwd,
          sessions: 0,
          turns: 0,
          prompt_tokens: 0,
          cached_tokens: 0,
          output_tokens: 0,
          cost_usd: 0.0,
          tool_calls: 0,
          errors: 0,
          last_active_at: nil
        },
        fn s, acc ->
          last_active =
            case {acc.last_active_at, s.updated_at} do
              {nil, u} -> u
              {a, nil} -> a
              {a, u} -> max(a, u)
            end

          %{
            acc
            | sessions: acc.sessions + 1,
              turns: acc.turns + s.turn_count,
              prompt_tokens: acc.prompt_tokens + s.prompt_tokens,
              cached_tokens: acc.cached_tokens + s.cache_read_tokens,
              output_tokens: acc.output_tokens + s.output_tokens,
              cost_usd: acc.cost_usd + s.cost_usd,
              tool_calls: acc.tool_calls + s.tool_calls,
              errors: acc.errors + s.total_errors,
              last_active_at: last_active
          }
        end
      )
      |> Map.update!(:cost_usd, &Float.round(&1, 6))
    end)
    |> Enum.sort_by(&{-&1.cost_usd, -&1.sessions, &1.cwd})
  end

  defp sort_sessions(session_slices, sort_by, sort_dir) do
    key_fn =
      case sort_by do
        "cost" ->
          fn s -> {s.cost_usd, s.updated_at || 0, s.session_id} end

        "tokens" ->
          fn s -> {s.prompt_tokens + s.output_tokens, s.updated_at || 0, s.session_id} end

        "p90_ms" ->
          fn s -> {s.p90_turn_ms || 0, s.updated_at || 0, s.session_id} end

        "errors" ->
          fn s -> {s.total_errors, s.updated_at || 0, s.session_id} end

        _ ->
          fn s -> {s.updated_at || 0, s.session_id} end
      end

    dir = if sort_dir == "asc", do: :asc, else: :desc

    session_slices
    |> Enum.sort_by(key_fn, dir)
    |> Enum.map(&Map.drop(&1, [:turns, :tools]))
  end

  defp collect_filter_options(summaries, cutoff_ms) do
    {provs, mods, cwds} =
      Enum.reduce(summaries, {MapSet.new(), MapSet.new(), MapSet.new()}, fn s, {p, m, c} ->
        c = if is_binary(s.cwd) and s.cwd != "", do: MapSet.put(c, s.cwd), else: c

        Enum.reduce(s.turns || [], {p, m, c}, fn t, {ap, am, ac} ->
          if is_nil(cutoff_ms) or (t.ts || 0) >= cutoff_ms do
            ap =
              if t.provider && t.provider != "unknown", do: MapSet.put(ap, t.provider), else: ap

            am = if t.model && t.model != "unknown", do: MapSet.put(am, t.model), else: am
            {ap, am, ac}
          else
            {ap, am, ac}
          end
        end)
      end)

    %{
      providers: provs |> MapSet.to_list() |> Enum.sort(),
      models: mods |> MapSet.to_list() |> Enum.sort(),
      workspaces: cwds |> MapSet.to_list() |> Enum.sort()
    }
  end

  defp normalize_enum(val, allowed, default) when is_binary(val) do
    if val in allowed, do: val, else: default
  end

  defp normalize_enum(_, _allowed, default), do: default

  defp normalize_optional_string(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "" or trimmed == "all", do: nil, else: trimmed
  end

  defp normalize_optional_string(_), do: nil
end
