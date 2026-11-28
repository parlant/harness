defmodule Extensions.Analytics.Scanner do
  @moduledoc """
  Read-only session and archive scanner for `Extensions.Analytics`.

  Reads native sessions strictly via `H.Storage.File.open_read_only/1` +
  `H.Storage.close/1` and imported archives directly via `:file.open/2` +
  `:file.pread/2` + `:file.close/1`. Never wakes or starts `H.Session.Server`
  or `H.Session.Supervisor`, and never creates atoms from external input.
  """

  alias H.{Catalog, Storage}
  alias H.Storage.Engine

  @max_fallback_gap_ms 600_000
  @archive_chunk_size 256

  @provider_aliases %{
    "openai-codex" => "openai_codex",
    "google-vertex" => "google_vertex"
  }

  @doc """
  Discovers catalog entries from `table` (if an ETS table exists) or from
  `<data_dir>/catalog/sessions.json`.
  """
  @spec discover_catalog(String.t(), keyword()) :: [map()]
  def discover_catalog(data_dir, opts \\ []) when is_binary(data_dir) and is_list(opts) do
    table = Keyword.get(opts, :catalog_table, :h_catalog)

    raw_entries =
      if is_atom(table) and :ets.whereis(table) != :undefined do
        try do
          Catalog.list_sessions(table)
        rescue
          ArgumentError -> read_catalog_json(data_dir)
        end
      else
        read_catalog_json(data_dir)
      end

    Enum.map(raw_entries, fn entry ->
      norm = normalize_catalog_entry(entry)
      Map.put(norm, :source_kind, classify_source(norm))
    end)
  end

  @doc """
  Computes an incremental cache fingerprint for a catalog `entry`.
  """
  @spec fingerprint(String.t(), map()) :: term()
  def fingerprint(data_dir, entry) when is_binary(data_dir) and is_map(entry) do
    sid = entry.session_id
    updated_at = Map.get(entry, :updated_at)

    case Map.get(entry, :archive) do
      %{generation: gen} ->
        {:archive, gen, updated_at}

      _ ->
        session_dir = Path.join([data_dir, "sessions", sid])
        wal_sig = file_sig(Path.join(session_dir, "commit.log"))
        snap_sig = latest_snapshot_sig(session_dir)
        {:native, updated_at, wal_sig, snap_sig}
    end
  end

  @doc """
  Scans a single session (native or imported archive) into a compact summary map.
  Returns `{:ok, summary}` or `{:error, reason}`.
  """
  @spec scan_session(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def scan_session(data_dir, entry) when is_binary(data_dir) and is_map(entry) do
    entry =
      entry
      |> normalize_catalog_entry()
      |> then(&Map.put_new(&1, :source_kind, classify_source(&1)))

    case Map.get(entry, :archive) do
      %{} -> scan_archive_session(data_dir, entry)
      nil -> scan_native_session(data_dir, entry)
    end
  end

  @doc """
  Inspects a single session (`entry` map or `session_id` string) and returns a
  turn-by-turn and tool-by-tool waterfall list for drill-down inspection.
  """
  @spec inspect_session(String.t(), map() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def inspect_session(data_dir, entry_or_sid, opts \\ [])

  def inspect_session(data_dir, sid, opts)
      when is_binary(data_dir) and is_binary(sid) and is_list(opts) do
    case Enum.find(discover_catalog(data_dir, opts), &(&1.session_id == sid)) do
      nil -> {:error, :not_found}
      entry -> inspect_session(data_dir, entry, opts)
    end
  end

  def inspect_session(data_dir, entry, _opts) when is_binary(data_dir) and is_map(entry) do
    entry =
      entry
      |> normalize_catalog_entry()
      |> then(&Map.put_new(&1, :source_kind, classify_source(&1)))

    case Map.get(entry, :archive) do
      %{} -> inspect_archive_session(data_dir, entry)
      nil -> inspect_native_session(data_dir, entry)
    end
  end

  @doc """
  Normalizes a single assistant entry and optional conversation `agent` document
  into a structured turn map.
  """
  @spec normalize_assistant_turn(map(), map() | nil, integer() | nil) :: map()
  def normalize_assistant_turn(entry, agent_doc, prev_ts) do
    data = map_field(entry, :data) || %{}
    ts = int_or_nil(map_field(entry, :created_at)) || 0
    seq = int_or_nil(map_field(entry, :seq))
    cid = parse_int_id(map_field(entry, :conversation_id)) || 1
    entry_id = parse_int_id(map_field(entry, :id))

    {provider, model} = resolve_provider_model(data, agent_doc)
    thinking = resolve_thinking(data, agent_doc)
    finish_reason = string_or_nil(data["finish_reason"]) || string_or_nil(data["stopReason"])
    outcome = classify_outcome(data, finish_reason)

    usage = if is_map(data["usage"]), do: data["usage"], else: %{}
    tokens = normalize_tokens(usage)
    cost_usd = normalize_cost(usage)
    duration_ms = resolve_duration_ms(data, ts, prev_ts)

    tps =
      if outcome == "completed" and is_integer(duration_ms) and duration_ms > 0 and
           tokens.output_tokens > 0 do
        Float.round(tokens.output_tokens * 1000.0 / duration_ms, 1)
      else
        nil
      end

    %{
      entry_id: entry_id,
      conversation_id: cid,
      seq: seq,
      ts: ts,
      day: ts_to_day(ts),
      provider: provider,
      model: model,
      thinking: thinking,
      outcome: outcome,
      finish_reason: finish_reason || outcome,
      prompt_tokens: tokens.prompt_tokens,
      uncached_tokens: tokens.uncached_tokens,
      cache_read_tokens: tokens.cache_read_tokens,
      cache_write_tokens: tokens.cache_write_tokens,
      output_tokens: tokens.output_tokens,
      reasoning_tokens: tokens.reasoning_tokens,
      cost_usd: cost_usd,
      duration_ms: duration_ms,
      tps: tps,
      context_band: context_band(tokens.prompt_tokens),
      cache_hit: tokens.cache_read_tokens > 0
    }
  end

  @doc """
  Normalizes a single `tool_result` entry.
  """
  @spec normalize_tool_result(map()) :: map()
  def normalize_tool_result(entry) do
    data = map_field(entry, :data) || %{}
    ts = int_or_nil(map_field(entry, :created_at)) || 0
    cid = parse_int_id(map_field(entry, :conversation_id)) || 1
    entry_id = parse_int_id(map_field(entry, :id))
    name = string_or_nil(data["name"]) || string_or_nil(data["toolName"]) || "unknown"
    is_error = data["is_error"] == true or data["isError"] == true
    duration_ms = non_neg_int(data["duration_ms"] || data["durationMs"])
    diagnostic = string_or_nil(data["diagnostic"])

    %{
      entry_id: entry_id,
      conversation_id: cid,
      ts: ts,
      day: ts_to_day(ts),
      name: name,
      is_error: is_error,
      duration_ms: duration_ms,
      diagnostic: diagnostic,
      tool_call_id: string_or_nil(data["tool_call_id"] || data["toolCallId"])
    }
  end

  @doc """
  Maps `prompt_tokens` to its context band label.
  """
  @spec context_band(non_neg_integer()) :: String.t()
  def context_band(prompt_tokens) when is_integer(prompt_tokens) do
    cond do
      prompt_tokens < 50_000 -> "0-50k"
      prompt_tokens < 250_000 -> "50k-250k"
      prompt_tokens < 400_000 -> "250k-400k"
      true -> "400k+"
    end
  end

  def context_band(_), do: "0-50k"

  @doc """
  Normalizes a provider name (e.g. `"openai-codex"` -> `"openai_codex"`).
  """
  @spec normalize_provider(term()) :: String.t()
  def normalize_provider(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: "unknown", else: Map.get(@provider_aliases, trimmed, trimmed)
  end

  def normalize_provider(_), do: "unknown"

  # Native session scanning

  defp scan_native_session(data_dir, entry) do
    session_dir = Path.join([data_dir, "sessions", entry.session_id])

    if not File.dir?(session_dir) do
      {:error, :session_dir_missing}
    else
      case H.Storage.File.open_read_only(
             dir: session_dir,
             session_id: entry.session_id,
             cwd: entry.cwd
           ) do
        {:ok, store} ->
          try do
            {_mod, state} = store
            entries = Engine.list_entries(state)
            restarts = count_task_restarts(state.tasks)

            summary =
              build_session_summary(entry, entries, &lookup_agent_doc(state, &1, &2), restarts)

            {:ok, summary}
          after
            Storage.close(store)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp inspect_native_session(data_dir, entry) do
    session_dir = Path.join([data_dir, "sessions", entry.session_id])

    if not File.dir?(session_dir) do
      {:error, :session_dir_missing}
    else
      case H.Storage.File.open_read_only(
             dir: session_dir,
             session_id: entry.session_id,
             cwd: entry.cwd
           ) do
        {:ok, store} ->
          try do
            {_mod, state} = store
            entries = Engine.list_entries(state)
            restarts = count_task_restarts(state.tasks)

            agent_lookup = &lookup_agent_doc(state, &1, &2)
            waterfall = build_waterfall(entries, agent_lookup)
            summary = build_session_summary(entry, entries, agent_lookup, restarts)
            {:ok, %{session: summary, events: waterfall}}
          after
            Storage.close(store)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp lookup_agent_doc(state, cid, seq) do
    as_of = if is_integer(seq) and seq > 0, do: seq, else: nil

    record =
      case Engine.get_doc(state, {:conversation, cid, "agent"}, as_of_seq: as_of) do
        nil -> Engine.get_doc(state, {:conversation, cid, "agent"})
        doc -> doc
      end

    case record do
      %{"value" => value} when is_map(value) -> value
      %{value: value} when is_map(value) -> value
      doc when is_map(doc) -> doc
      _ -> nil
    end
  end

  # Archive session scanning

  defp scan_archive_session(data_dir, entry) do
    with {:ok, entries} <- read_archive_entries(data_dir, entry) do
      agent_lookup = fn _cid, _seq -> nil end
      summary = build_session_summary(entry, entries, agent_lookup, 0)
      {:ok, summary}
    end
  end

  defp inspect_archive_session(data_dir, entry) do
    with {:ok, entries} <- read_archive_entries(data_dir, entry) do
      agent_lookup = fn _cid, _seq -> nil end
      waterfall = build_waterfall(entries, agent_lookup)
      summary = build_session_summary(entry, entries, agent_lookup, 0)
      {:ok, %{session: summary, events: waterfall}}
    end
  end

  defp read_archive_entries(data_dir, entry) do
    archives_dir = Path.join(data_dir, "archives")
    gen = get_in(entry, [:archive, :generation])

    if is_integer(gen) do
      filename = H.Archive.path(archives_dir, entry.session_id, gen)

      case :file.open(filename, [:raw, :binary, :read]) do
        {:ok, fd} ->
          try do
            with {:ok, size} <- :file.position(fd, :eof),
                 true <- size >= 8,
                 {:ok, <<offset::64>>} <- :file.pread(fd, size - 8, 8),
                 true <- offset <= size - 8,
                 {:ok, index_bin} <- :file.pread(fd, offset, size - 8 - offset) do
              {entries_index, _conversations} = :erlang.binary_to_term(index_bin, [:safe])

              locations =
                entries_index
                |> Enum.sort_by(fn {id, _} -> id end)
                |> Enum.map(fn {_id, {_cid, _parent, off, len}} -> {off, len} end)

              pread_all_entries(fd, locations)
            else
              _ -> {:error, :archive_unavailable}
            end
          after
            :file.close(fd)
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_archive}
    end
  end

  defp pread_all_entries(_fd, []), do: {:ok, []}

  defp pread_all_entries(fd, locations) do
    locations
    |> Enum.chunk_every(@archive_chunk_size)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case :file.pread(fd, chunk) do
        {:ok, bins} ->
          decoded =
            Enum.map(bins, fn bin ->
              case JSON.decode(bin) do
                {:ok, map} when is_map(map) -> map
                _ -> %{}
              end
            end)

          {:cont, {:ok, [decoded | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> List.flatten()}
      {:error, _} = err -> err
    end
  end

  # Summary & waterfall builders

  defp build_session_summary(entry, entries, agent_lookup, restarts) do
    {turns_rev, tools_rev, _prev_ts_by_cid} =
      Enum.reduce(entries, {[], [], %{}}, fn raw_entry, {turns_acc, tools_acc, prev_by_cid} ->
        kind = map_field(raw_entry, :kind)
        cid = parse_int_id(map_field(raw_entry, :conversation_id)) || 1
        ts = int_or_nil(map_field(raw_entry, :created_at))

        case kind do
          "assistant" ->
            seq = int_or_nil(map_field(raw_entry, :seq))
            agent_doc = agent_lookup.(cid, seq)
            prev_ts = Map.get(prev_by_cid, cid)
            turn = normalize_assistant_turn(raw_entry, agent_doc, prev_ts)

            compact_turn = %{
              ts: turn.ts,
              day: turn.day,
              provider: turn.provider,
              model: turn.model,
              thinking: turn.thinking,
              outcome: turn.outcome,
              finish_reason: turn.finish_reason,
              prompt_tokens: turn.prompt_tokens,
              uncached_tokens: turn.uncached_tokens,
              cache_read_tokens: turn.cache_read_tokens,
              cache_write_tokens: turn.cache_write_tokens,
              output_tokens: turn.output_tokens,
              reasoning_tokens: turn.reasoning_tokens,
              cost_usd: turn.cost_usd,
              duration_ms: turn.duration_ms,
              tps: turn.tps,
              context_band: turn.context_band,
              cache_hit: turn.cache_hit
            }

            next_prev = if is_integer(ts), do: Map.put(prev_by_cid, cid, ts), else: prev_by_cid
            {[compact_turn | turns_acc], tools_acc, next_prev}

          "tool_result" ->
            tool = normalize_tool_result(raw_entry)

            compact_tool = %{
              ts: tool.ts,
              day: tool.day,
              name: tool.name,
              is_error: tool.is_error,
              duration_ms: tool.duration_ms
            }

            next_prev = if is_integer(ts), do: Map.put(prev_by_cid, cid, ts), else: prev_by_cid
            {turns_acc, [compact_tool | tools_acc], next_prev}

          _ ->
            next_prev = if is_integer(ts), do: Map.put(prev_by_cid, cid, ts), else: prev_by_cid
            {turns_acc, tools_acc, next_prev}
        end
      end)

    turns = Enum.reverse(turns_rev)
    tools = Enum.reverse(tools_rev)

    totals = compute_totals(turns, tools, restarts)

    %{
      session_id: entry.session_id,
      title: Map.get(entry, :title),
      cwd: entry.cwd,
      env_id: Map.get(entry, :env_id, "host"),
      source_kind: Map.get(entry, :source_kind) || classify_source(entry),
      is_subsession: not is_nil(Map.get(entry, :parent)),
      parent_session_id: get_in(entry, [:parent, :session_id]),
      role: Map.get(entry, :role),
      harness_id: Map.get(entry, :harness_id, "coding"),
      status: Map.get(entry, :status, "ok"),
      archived: Map.get(entry, :archived, false),
      created_at: Map.get(entry, :created_at),
      updated_at: Map.get(entry, :updated_at),
      entry_count: length(entries),
      turns: turns,
      tools: tools,
      totals: totals
    }
  end

  defp build_waterfall(entries, agent_lookup) do
    {events_rev, _prev_by_cid} =
      Enum.reduce(entries, {[], %{}}, fn raw_entry, {acc, prev_by_cid} ->
        kind = map_field(raw_entry, :kind)
        cid = parse_int_id(map_field(raw_entry, :conversation_id)) || 1
        ts = int_or_nil(map_field(raw_entry, :created_at))
        entry_id = parse_int_id(map_field(raw_entry, :id))
        data = map_field(raw_entry, :data) || %{}

        event =
          case kind do
            "assistant" ->
              seq = int_or_nil(map_field(raw_entry, :seq))
              agent_doc = agent_lookup.(cid, seq)
              prev_ts = Map.get(prev_by_cid, cid)
              turn = normalize_assistant_turn(raw_entry, agent_doc, prev_ts)

              tool_calls =
                data
                |> Map.get("tool_calls", [])
                |> List.wrap()
                |> Enum.map(&(&1["name"] || "tool"))

              Map.merge(turn, %{
                kind: "assistant",
                tool_calls: tool_calls
              })

            "tool_result" ->
              raw_tool = normalize_tool_result(raw_entry)
              Map.put(raw_tool, :kind, "tool_result")

            other ->
              %{
                kind: to_string(other || "entry"),
                entry_id: entry_id,
                conversation_id: cid,
                ts: ts || 0,
                day: ts_to_day(ts || 0),
                preview: extract_preview(data)
              }
          end

        next_prev = if is_integer(ts), do: Map.put(prev_by_cid, cid, ts), else: prev_by_cid
        {[event | acc], next_prev}
      end)

    Enum.reverse(events_rev)
  end

  defp extract_preview(data) when is_map(data) do
    cond do
      is_binary(data["text"]) ->
        String.slice(data["text"], 0, 120)

      is_list(data["content"]) ->
        data["content"]
        |> Enum.find_value("", fn
          %{"type" => "text", "text" => txt} when is_binary(txt) -> txt
          _ -> nil
        end)
        |> String.slice(0, 120)

      is_binary(data["command"]) ->
        String.slice(data["command"], 0, 120)

      true ->
        ""
    end
  end

  defp extract_preview(_), do: ""

  defp compute_totals(turns, tools, restarts) do
    base = %{
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
      tool_calls: 0,
      tool_errors: 0,
      tool_duration_ms: 0,
      restarts: restarts
    }

    after_turns =
      Enum.reduce(turns, base, fn t, acc ->
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
            turn_duration_ms: acc.turn_duration_ms + dur
        }
      end)

    Enum.reduce(tools, after_turns, fn tr, acc ->
      %{
        acc
        | tool_calls: acc.tool_calls + 1,
          tool_errors: acc.tool_errors + if(tr.is_error, do: 1, else: 0),
          tool_duration_ms: acc.tool_duration_ms + (tr.duration_ms || 0)
      }
    end)
    |> Map.update!(:cost_usd, &Float.round(&1, 8))
  end

  # Normalization helpers

  defp resolve_provider_model(data, agent_doc) do
    data_provider = string_or_nil(data["provider"])
    data_model = string_or_nil(data["model"])
    agent_model = if is_map(agent_doc), do: string_or_nil(agent_doc["model"]), else: nil

    cond do
      data_provider && data_model ->
        {normalize_provider(data_provider), data_model}

      data_model && String.contains?(data_model, ":") ->
        split_provider_model(data_model)

      agent_model && String.contains?(agent_model, ":") ->
        split_provider_model(agent_model)

      data_model ->
        {"unknown", data_model}

      agent_model ->
        {"unknown", agent_model}

      true ->
        {"unknown", "unknown"}
    end
  end

  defp split_provider_model(spec) do
    case String.split(spec, ":", parts: 2) do
      [prov, mod] when prov != "" and mod != "" -> {normalize_provider(prov), mod}
      _ -> {"unknown", spec}
    end
  end

  defp resolve_thinking(data, agent_doc) do
    string_or_nil(data["thinkingLevel"]) ||
      string_or_nil(data["thinking"]) ||
      (is_map(agent_doc) && string_or_nil(agent_doc["thinking"])) ||
      "default"
  end

  defp classify_outcome(data, finish_reason) do
    cond do
      data["aborted"] == true or finish_reason in ["aborted", "cancelled"] ->
        "aborted"

      finish_reason in ["error", "failed"] ->
        "error"

      true ->
        "completed"
    end
  end

  defp normalize_tokens(usage) do
    raw_in = non_neg_int(usage["input_tokens"] || usage["input"])
    out = non_neg_int(usage["output_tokens"] || usage["output"])

    cache_read =
      non_neg_int(usage["cache_read_tokens"] || usage["cached_tokens"] || usage["cacheRead"])

    cache_write = non_neg_int(usage["cache_write_tokens"] || usage["cacheWrite"])
    reasoning = non_neg_int(usage["reasoning_tokens"] || usage["reasoning"])
    raw_total = non_neg_int(usage["total_tokens"] || usage["totalTokens"])

    {prompt_tokens, uncached_tokens} =
      if cache_read > 0 and raw_total >= raw_in + cache_read + out do
        {raw_in + cache_read + cache_write, raw_in}
      else
        {max(raw_in, cache_read) + cache_write, max(raw_in - cache_read, 0)}
      end

    %{
      prompt_tokens: prompt_tokens,
      uncached_tokens: uncached_tokens,
      cache_read_tokens: cache_read,
      cache_write_tokens: cache_write,
      output_tokens: out,
      reasoning_tokens: reasoning
    }
  end

  defp normalize_cost(usage) do
    raw =
      case Map.get(usage, "cost") do
        %{"total" => total} -> total
        num when is_number(num) -> num
        _ -> Map.get(usage, "total_cost")
      end

    case raw do
      n when is_integer(n) -> n * 1.0
      n when is_float(n) -> n
      _ -> 0.0
    end
  end

  defp resolve_duration_ms(data, ts, prev_ts) do
    case pos_int_or_nil(data["duration_ms"] || data["durationMs"]) do
      ms when is_integer(ms) ->
        ms

      nil ->
        if is_integer(prev_ts) and ts > prev_ts and ts - prev_ts <= @max_fallback_gap_ms do
          ts - prev_ts
        else
          nil
        end
    end
  end

  defp count_task_restarts(tasks) when is_map(tasks) do
    Enum.reduce(tasks, 0, fn {_id, task}, acc ->
      acc + non_neg_int(Map.get(task, :restarts) || Map.get(task, "restarts"))
    end)
  end

  defp count_task_restarts(_), do: 0

  # Catalog / file helpers

  defp read_catalog_json(data_dir) do
    path = Path.join([data_dir, "catalog", "sessions.json"])

    case File.read(path) do
      {:ok, raw} ->
        case JSON.decode(raw) do
          {:ok, %{"sessions" => list}} when is_list(list) -> list
          _ -> []
        end

      _ ->
        []
    end
  end

  defp normalize_catalog_entry(entry) when is_map(entry) do
    raw_archive = Map.get(entry, :archive) || Map.get(entry, "archive")

    archive =
      case raw_archive do
        %{generation: gen} when is_integer(gen) ->
          raw_archive

        %{"generation" => gen} when is_integer(gen) ->
          %{
            source: raw_archive["source"],
            source_id: raw_archive["source_id"],
            revision: raw_archive["revision"],
            size: raw_archive["size"],
            generation: gen
          }

        _ ->
          nil
      end

    raw_parent = Map.get(entry, :parent) || Map.get(entry, "parent")

    parent =
      case raw_parent do
        %{session_id: sid} when is_binary(sid) -> raw_parent
        %{"session_id" => sid} when is_binary(sid) -> %{session_id: sid}
        _ -> nil
      end

    status = Map.get(entry, :status) || Map.get(entry, "status") || "ok"

    archived =
      status == "archived" or Map.get(entry, :archived, Map.get(entry, "archived", false)) == true

    %{
      session_id: Map.get(entry, :session_id) || Map.get(entry, "session_id"),
      title: Map.get(entry, :title) || Map.get(entry, "title"),
      cwd: Map.get(entry, :cwd) || Map.get(entry, "cwd") || "",
      env_id: Map.get(entry, :env_id) || Map.get(entry, "env_id") || "host",
      harness_id: Map.get(entry, :harness_id) || Map.get(entry, "harness_id") || "coding",
      parent: parent,
      role: Map.get(entry, :role) || Map.get(entry, "role"),
      created_at: Map.get(entry, :created_at) || Map.get(entry, "created_at"),
      updated_at: Map.get(entry, :updated_at) || Map.get(entry, "updated_at"),
      status: status,
      archived: archived,
      archive: archive
    }
  end

  defp classify_source(entry) do
    cond do
      is_map(Map.get(entry, :archive)) ->
        "imported_archive"

      Map.get(entry, :status) == "archived" or Map.get(entry, :archived) == true ->
        "native_archived"

      true ->
        "native_active"
    end
  end

  defp file_sig(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} -> {size, mtime}
      _ -> nil
    end
  end

  defp latest_snapshot_sig(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.flat_map(fn name ->
          case Regex.run(~r/^snapshot\.(\d+)\.json$/, name) do
            [_, seq_str] -> [{String.to_integer(seq_str), Path.join(dir, name)}]
            _ -> []
          end
        end)
        |> Enum.max_by(&elem(&1, 0), fn -> nil end)
        |> case do
          nil -> nil
          {seq, path} -> {seq, file_sig(path)}
        end

      _ ->
        nil
    end
  end

  defp ts_to_day(ts) when is_integer(ts) and ts > 0 do
    case DateTime.from_unix(ts, :millisecond) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d")
      _ -> "unknown"
    end
  end

  defp ts_to_day(_), do: "unknown"

  defp map_field(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp int_or_nil(v) when is_integer(v), do: v
  defp int_or_nil(_), do: nil

  defp pos_int_or_nil(v) when is_integer(v) and v > 0, do: v
  defp pos_int_or_nil(_), do: nil

  defp non_neg_int(v) when is_integer(v) and v >= 0, do: v
  defp non_neg_int(_), do: 0

  defp parse_int_id(v) when is_integer(v), do: v

  defp parse_int_id(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int_id(_), do: nil

  defp string_or_nil(v) when is_binary(v) do
    trimmed = String.trim(v)
    if trimmed == "", do: nil, else: trimmed
  end

  defp string_or_nil(_), do: nil
end
