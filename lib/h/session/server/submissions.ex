defmodule H.Session.Server.Submissions do
  @moduledoc """
  Submission lookup, bounded LRU caching, settlement, inbox draining, automatic
  initial title derivation, and pending generation run creation for
  `H.Session.Server` and `H.Session.UserShell`.
  """

  alias H.{Context, Storage, Submission, Task}
  alias H.Session.Server.State

  @max_recent_submissions 256

  def lookup_with_pending(state, req_id, _pending_subs) when not is_binary(req_id) do
    {:not_found, state}
  end

  def lookup_with_pending(state, req_id, pending_subs) do
    case Map.fetch(pending_subs, req_id) do
      {:ok, sub} -> {:ok, sub, state}
      :error -> lookup(state, req_id)
    end
  end

  def lookup(state, req_id) do
    case Map.fetch(state.recent_submissions, req_id) do
      {:ok, sub} ->
        {:ok, sub, state}

      :error ->
        case Storage.get_submission(state.store, req_id) do
          {:ok, nil, next_store} ->
            {:not_found, %{state | store: next_store}}

          {:ok, raw, next_store} ->
            sub = Submission.from_storage(raw)
            next_state = cache(%{state | store: next_store}, [sub], sub.seq)
            {:ok, sub, next_state}
        end
    end
  end

  def cache(state, subs, batch_seq) do
    updated =
      Enum.reduce(subs, state.recent_submissions, fn sub, acc ->
        stamped = if batch_seq, do: Map.put(sub, :seq, batch_seq), else: sub
        Map.put(acc, stamped.request_id, stamped)
      end)

    %{state | recent_submissions: trim_cache(updated)}
  end

  def settle([], _mode, _val, state, _now), do: {[], state}

  def settle(sub_ids, mode, val, state, now) do
    {by_id, state} = load_submissions_by_id(sub_ids, state)

    Enum.reduce(sub_ids, {[], state}, fn sid, {acc_w, acc_s} ->
      case Map.get(by_id, sid) do
        nil ->
          {acc_w, acc_s}

        sub ->
          updated =
            case mode do
              :done -> Submission.mark_done(sub, val, now)
              :unanswered -> Submission.mark_unanswered(sub, val, now)
            end

          next_cache = trim_cache(Map.put(acc_s.recent_submissions, updated.request_id, updated))
          {acc_w ++ [{:put_submission, updated}], %{acc_s | recent_submissions: next_cache}}
      end
    end)
  end

  defp load_submissions_by_id(sub_ids, state) do
    cached_by_id = Map.new(state.recent_submissions, fn {_rid, s} -> {s.id, s} end)
    missing = Enum.reject(sub_ids, &Map.has_key?(cached_by_id, &1))

    if missing == [] do
      {cached_by_id, state}
    else
      case Storage.read_bootstrap(state.store) do
        {:ok, %{submissions: raw_subs}, next_store} when is_map(raw_subs) ->
          missing_set = MapSet.new(missing)

          recovered =
            Enum.reduce(raw_subs, cached_by_id, fn {_rid, raw}, acc ->
              sub = Submission.from_storage(raw)
              if MapSet.member?(missing_set, sub.id), do: Map.put(acc, sub.id, sub), else: acc
            end)

          {recovered, %{state | store: next_store}}

        _ ->
          {cached_by_id, state}
      end
    end
  end

  def drain_inbox(cid, state, now, filter_mode) do
    inbox = state.docs[cid]["inbox"] || []

    {matching, remaining} =
      if is_nil(filter_mode) do
        {inbox, []}
      else
        Enum.split_with(inbox, &(Map.get(&1, "when_busy") == filter_mode))
      end

    if matching == [] do
      {[], [], [], [], state}
    else
      {entries, sub_writes, sub_ids, state} =
        Enum.reduce(matching, {[], [], [], state}, fn item, {acc_e, acc_sw, acc_sids, acc_st} ->
          {:ok, entry_id, store} = Storage.mint_id(acc_st.store)
          acc_st = %{acc_st | store: store}

          entry =
            State.build_entry(
              entry_id,
              cid,
              "user",
              %{"content" => Map.get(item, "content", [])},
              now
            )

          acc_st = State.record_entry(acc_st, cid, entry_id)
          req_id = Map.get(item, "request_id")

          {sw, sids, acc_st} =
            case lookup(acc_st, req_id) do
              {:ok, sub, acc_st} ->
                placed = Submission.mark_placed(sub, entry_id, now)
                acc_st = cache(acc_st, [placed], placed.seq)
                {[{:put_submission, placed}], [placed.id], acc_st}

              {:not_found, acc_st} ->
                {[], [], acc_st}
            end

          {acc_e ++ [entry], acc_sw ++ sw, acc_sids ++ sids, acc_st}
        end)

      state = State.put_doc(state, cid, "inbox", remaining)
      {entries, sub_writes, sub_ids, [["replace", remaining]], state}
    end
  end

  @doc """
  Mints and stages a new pending `"generation"` task and initial `"live"` document
  for `cid`, updating `state.store`, `state.tasks`, and `state.docs[cid]["live"]`.
  """
  def start_pending_generation(cid, sub_ids, state, now, turns \\ 1) do
    {:ok, gen_task_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}

    gen_task =
      Task.new(%{
        id: gen_task_id,
        kind: "generation",
        owner: {:conversation, cid},
        status: "pending",
        checkpoint: %{
          "conversation_id" => cid,
          "turns" => turns,
          "retry_count" => 0,
          "phase" => "stream",
          "submission_ids" => sub_ids
        },
        created_at: now
      })

    next_live = initial_generation_live(gen_task_id, turns)

    state =
      state
      |> State.put_task(gen_task)
      |> State.put_doc(cid, "live", next_live)

    {gen_task, next_live, state}
  end

  def initial_generation_live(gen_task_id, turns \\ 1) do
    %{
      "run" => %{"task_id" => to_string(gen_task_id), "turns" => turns},
      "generation" => %{"message" => %{"thinking" => "", "text" => "", "tool_calls" => []}}
    }
  end

  def maybe_derive_initial_title(content, state) do
    current = state.session_meta[:title]
    explicit? = state.session_meta[:title_explicit] == true

    if explicit? or (is_binary(current) and String.trim(current) != "") do
      {[], state}
    else
      case extract_prompt_title(content) do
        nil ->
          {[], state}

        derived ->
          next_meta = Map.put(state.session_meta, :title, derived)
          {[{:put_session_meta, next_meta}], %{state | session_meta: next_meta}}
      end
    end
  end

  def has_answerable_context?(cid, newly_placed_entries, state) do
    if newly_placed_entries != [] do
      {:ok, true, state}
    else
      {:ok, entries, state} = State.load_visible_entries(state, cid)

      last_non_aborted =
        entries
        |> Enum.reverse()
        |> Enum.find(fn e ->
          cond do
            e.kind == "assistant" ->
              not Context.aborted_assistant?(e)

            e.kind == "system" ->
              not Context.pi_transcript_only?(e.data)

            e.kind == "user_shell" ->
              Map.get(e.data, "include_in_context", Map.get(e.data, :include_in_context)) == true

            true ->
              true
          end
        end)

      answerable? =
        case last_non_aborted do
          %{kind: kind}
          when kind in ["user", "user_shell", "tool_result", "compaction", "reset"] ->
            true

          _ ->
            false
        end

      {:ok, answerable?, state}
    end
  end

  def map_storage_refusal({:duplicate_request_id, existing}) do
    {:duplicate, Submission.to_receipt(existing, 0)}
  end

  def map_storage_refusal({:conflict_request_id, _existing}) do
    {:conflict, "request_id already used with different payload"}
  end

  def map_storage_refusal({:conversation_not_found, _cid}), do: :not_found
  def map_storage_refusal(other), do: other

  # Internal helpers

  defp trim_cache(updated) when map_size(updated) <= @max_recent_submissions, do: updated

  defp trim_cache(updated) do
    {active, terminal} =
      Enum.split_with(updated, fn {_k, v} ->
        v.status not in ["done", "unanswered", "withdrawn"]
      end)

    remaining_slots = max(0, @max_recent_submissions - length(active))

    kept_terminal =
      terminal
      |> Enum.sort_by(fn {_k, v} -> v.updated_at || 0 end, :desc)
      |> Enum.take(remaining_slots)

    Map.new(active ++ kept_terminal)
  end

  defp extract_prompt_title(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => t} when is_binary(t) -> [t]
      %{type: "text", text: t} when is_binary(t) -> [t]
      t when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join(" ")
    |> format_title_line()
  end

  defp extract_prompt_title(text) when is_binary(text), do: format_title_line(text)
  defp extract_prompt_title(_), do: nil

  defp format_title_line(raw) do
    line =
      raw
      |> String.split(~r/\R/, parts: 2)
      |> hd()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      line == "" -> nil
      String.length(line) <= 72 -> line
      true -> String.slice(line, 0, 69) <> "..."
    end
  end
end
