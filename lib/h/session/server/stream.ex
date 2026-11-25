defmodule H.Session.Server.Stream do
  @moduledoc """
  Ephemeral streaming output buffers, periodic live document flushing,
  `ProcBin` SSE commit/ephemeral frame broadcasting, 64-entry replay ring,
  and initial conversation snapshot encoding.
  """

  alias H.{Document, Storage}
  alias H.Session.Server.{State, Submissions}

  @max_replay_ring 64

  def handle_gen_chunk(state, cid, _tid, event) do
    eph = get_or_init_ephemeral(state, cid)

    {next_eph, new_ops} =
      case event do
        %{type: :thinking_delta, text: delta} when is_binary(delta) and delta != "" ->
          {
            %{eph | thinking: eph.thinking <> delta, dirty: true},
            [["append_text", ["generation", "message", "thinking"], delta]]
          }

        %{type: :text_delta, text: delta} when is_binary(delta) and delta != "" ->
          {
            %{eph | text: eph.text <> delta, dirty: true},
            [["append_text", ["generation", "message", "text"], delta]]
          }

        %{type: :tool_call_delta, id: id, name: name, args_delta: args_delta} ->
          prev_tc =
            Map.get(eph.tool_calls, id, %{"id" => id, "name" => name || "", "arguments" => ""})

          updated_tc = %{
            prev_tc
            | "name" => name || prev_tc["name"],
              "arguments" => (prev_tc["arguments"] || "") <> (args_delta || "")
          }

          tool_order = if id in eph.tool_order, do: eph.tool_order, else: eph.tool_order ++ [id]
          tool_calls_map = Map.put(eph.tool_calls, id, updated_tc)
          tc_list = Enum.map(tool_order, &Map.fetch!(tool_calls_map, &1))

          {
            %{eph | tool_calls: tool_calls_map, tool_order: tool_order, dirty: true},
            [["set", ["generation", "message", "tool_calls"], tc_list]]
          }

        _ ->
          {eph, []}
      end

    if new_ops == [] do
      state
    else
      next_eph =
        %{next_eph | pending_ops: next_eph.pending_ops ++ new_ops}
        |> arm_ephemeral_timers(cid, state.ephemeral_interval_ms, state.persist_within_ms)

      %{state | ephemeral: Map.put(state.ephemeral, cid, next_eph)}
    end
  end

  def handle_tool_output(state, cid, _tid, call_id, chunk)
      when is_binary(chunk) and chunk != "" do
    eph = get_or_init_ephemeral(state, cid)

    prev_out =
      Map.get(eph.tool_outputs, call_id) ||
        get_in(state.docs[cid]["live"], ["tools", call_id, "output"]) || ""

    next_out = prev_out <> chunk

    next_eph =
      %{
        eph
        | tool_outputs: Map.put(eph.tool_outputs, call_id, next_out),
          dirty: true,
          pending_ops: eph.pending_ops ++ [["append_text", ["tools", call_id, "output"], chunk]]
      }
      |> arm_ephemeral_timers(cid, state.ephemeral_interval_ms, state.persist_within_ms)

    %{state | ephemeral: Map.put(state.ephemeral, cid, next_eph)}
  end

  def handle_tool_output(state, _cid, _tid, _call_id, _chunk), do: state

  def handle_user_shell_output(state, cid, _tid, chunk) when is_binary(chunk) and chunk != "" do
    eph = get_or_init_ephemeral(state, cid)

    prev_out =
      Map.get(eph, :user_shell_output) ||
        get_in(state.docs, [cid, "live", "user_shell", "output"]) || ""

    next_out = prev_out <> chunk

    next_eph =
      %{
        eph
        | user_shell_output: next_out,
          dirty: true,
          pending_ops: eph.pending_ops ++ [["append_text", ["user_shell", "output"], chunk]]
      }
      |> arm_ephemeral_timers(cid, state.ephemeral_interval_ms, state.persist_within_ms)

    %{state | ephemeral: Map.put(state.ephemeral, cid, next_eph)}
  end

  def handle_user_shell_output(state, _cid, _tid, _chunk), do: state

  def get_or_init_ephemeral(state, cid) do
    case Map.get(state.ephemeral, cid) do
      nil ->
        live_msg = get_in(state.docs[cid]["live"], ["generation", "message"]) || %{}

        %{
          thinking: Map.get(live_msg, "thinking", ""),
          text: Map.get(live_msg, "text", ""),
          tool_calls: %{},
          tool_order: [],
          tool_outputs: %{},
          user_shell_output: nil,
          dirty: false,
          pending_ops: [],
          emit_timer: nil,
          flush_timer: nil
        }

      eph ->
        eph
    end
  end

  def arm_ephemeral_timers(eph, cid, emit_ms, flush_ms) do
    eph =
      if is_nil(eph.emit_timer) do
        ref = Process.send_after(self(), {:emit_ephemeral, cid}, emit_ms)
        %{eph | emit_timer: ref}
      else
        eph
      end

    if is_nil(eph.flush_timer) do
      ref = Process.send_after(self(), {:flush_live, cid}, flush_ms)
      %{eph | flush_timer: ref}
    else
      eph
    end
  end

  def flush_ephemeral_broadcast(state, cid) do
    case Map.get(state.ephemeral, cid) do
      %{pending_ops: []} = eph ->
        %{state | ephemeral: Map.put(state.ephemeral, cid, %{eph | emit_timer: nil})}

      %{pending_ops: ops} = eph ->
        base_seq = Map.get(state.conv_last_seq, cid, state.seq)

        frame = %{
          "version" => 1,
          "session_id" => state.session_id,
          "conversation_id" => to_string(cid),
          "base_seq" => base_seq,
          "doc_ops" => %{"live" => ops}
        }

        bin = IO.iodata_to_binary(JSON.encode_to_iodata!(frame))
        dispatch_pubsub(Map.get(state, :pubsub), state.session_id, cid, {:ephemeral_frame, bin})

        %{
          state
          | ephemeral: Map.put(state.ephemeral, cid, %{eph | pending_ops: [], emit_timer: nil})
        }

      nil ->
        state
    end
  end

  def clear_ephemeral_for_conv(state, cid) do
    case Map.pop(state.ephemeral, cid) do
      {nil, _} ->
        state

      {eph, rest} ->
        if eph.emit_timer, do: Process.cancel_timer(eph.emit_timer)
        if eph.flush_timer, do: Process.cancel_timer(eph.flush_timer)
        %{state | ephemeral: rest}
    end
  end

  def merge_user_shell_ephemeral(live, nil), do: live

  def merge_user_shell_ephemeral(%{"user_shell" => shell_live} = live, eph)
      when is_map(shell_live) and is_map(eph) do
    case Map.get(eph, :user_shell_output) do
      output when is_binary(output) -> put_in(live, ["user_shell", "output"], output)
      _ -> live
    end
  end

  def merge_user_shell_ephemeral(live, _eph), do: live

  def merge_ephemeral_into_live(live, nil), do: live

  def merge_ephemeral_into_live(live, eph) do
    live =
      if Map.has_key?(live, "generation") do
        tc_list = Enum.map(eph.tool_order, &Map.fetch!(eph.tool_calls, &1))

        gen_msg = %{
          "thinking" => eph.thinking,
          "text" => eph.text,
          "tool_calls" => tc_list
        }

        put_in(live, ["generation", "message"], gen_msg)
      else
        live
      end

    live
    |> then(fn acc ->
      Enum.reduce(eph.tool_outputs, acc, fn {call_id, output}, inner_acc ->
        if get_in(inner_acc, ["tools", call_id]) do
          put_in(inner_acc, ["tools", call_id, "output"], output)
        else
          inner_acc
        end
      end)
    end)
    |> merge_user_shell_ephemeral(eph)
  end

  def stage_flush_live(cid, state) do
    case Map.get(state.ephemeral, cid) do
      %{dirty: true} = eph ->
        next_live = merge_ephemeral_into_live(state.docs[cid]["live"], eph)
        state = State.put_doc(state, cid, "live", next_live)

        next_eph = %{eph | dirty: false, flush_timer: nil}
        state = %{state | ephemeral: Map.put(state.ephemeral, cid, next_eph)}

        staged = %{
          raw_item: {:flush_live, cid},
          writes: [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}],
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [],
          effects: [],
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}

      _ ->
        {:skip, state}
    end
  end

  # Commit broadcasting & replay ring

  def apply_committed_batches([], [], state), do: state

  def apply_committed_batches([staged | rest_s], [batch_seq | rest_q], state) do
    state = %{state | seq: batch_seq}

    committed_subs =
      extract_written_submissions(staged.writes, staged.submissions)

    state = Submissions.cache(state, committed_subs, batch_seq)

    state =
      Enum.reduce(staged.conv_events, state, fn {cid, ev}, acc_state ->
        wire_entries = Enum.map(ev.entries, &State.wire_entry(&1, batch_seq))
        broadcast_commit_frame(acc_state, cid, batch_seq, wire_entries, ev.doc_ops)
      end)

    state = broadcast_settled_submissions(state, staged.writes, batch_seq)
    notify_observers(state, staged, batch_seq)

    apply_committed_batches(rest_s, rest_q, state)
  end

  def broadcast_settled_submissions(state, writes, batch_seq) when is_list(writes) do
    settled_subs =
      Enum.flat_map(writes, fn
        {:put_submission, %{status: status} = sub}
        when status in ["done", "unanswered", "withdrawn"] ->
          [sub]

        _ ->
          []
      end)

    if settled_subs == [] do
      state
    else
      appended_by_id =
        Enum.reduce(writes, %{}, fn
          {:append_entry, entry}, acc -> Map.put(acc, entry.id, entry)
          _, acc -> acc
        end)

      Enum.reduce(settled_subs, state, fn sub, acc_state ->
        {outcome, next_state} =
          build_submission_outcome(acc_state, sub, batch_seq, appended_by_id)

        dispatch_submission_settled(Map.get(next_state, :pubsub), outcome)
        next_state
      end)
    end
  end

  def build_submission_outcome(state, sub, fallback_seq \\ nil, entry_cache \\ %{}) do
    {answer_text, next_state} =
      if sub.status == "done" and is_integer(sub.answer_entry_id) do
        load_assistant_answer_text(state, sub.answer_entry_id, entry_cache)
      else
        {nil, state}
      end

    outcome = %{
      session_id: next_state.session_id,
      conversation_id: sub.conversation_id,
      submission_id: sub.id,
      request_id: sub.request_id,
      kind: sub.kind,
      status: sub.status,
      entry_id: sub.entry_id,
      answer_entry_id: sub.answer_entry_id,
      answer_text: answer_text,
      reason: sub.reason,
      seq: fallback_seq || sub.seq || next_state.seq
    }

    {outcome, next_state}
  end

  def reply_committed_batches([], []), do: :ok

  def reply_committed_batches([staged | rest_s], [batch_seq | rest_q]) do
    if staged.reply_from do
      GenServer.reply(staged.reply_from, {:ok, Map.put(staged.receipt, :seq, batch_seq)})
    end

    reply_committed_batches(rest_s, rest_q)
  end

  def broadcast_commit_frame(state, cid, batch_seq, wire_entries, doc_ops) do
    prev_conv_seq = Map.get(state.conv_last_seq, cid, 0)

    frame = %{
      "version" => 1,
      "session_id" => state.session_id,
      "conversation_id" => to_string(cid),
      "prev_seq" => prev_conv_seq,
      "seq" => batch_seq,
      "appended_entries" => wire_entries,
      "doc_ops" => doc_ops
    }

    commit_bin = IO.iodata_to_binary(JSON.encode_to_iodata!(frame))

    dispatch_pubsub(
      Map.get(state, :pubsub),
      state.session_id,
      cid,
      {:commit_frame, batch_seq, commit_bin}
    )

    ring = Map.get(state.replay_rings, cid, []) ++ [{batch_seq, commit_bin}]

    {ring, ring_base_seq} =
      if length(ring) > @max_replay_ring do
        [{evicted_seq, _} | trimmed] = ring
        {trimmed, Map.put(state.ring_base_seq, cid, evicted_seq)}
      else
        {ring, Map.put_new(state.ring_base_seq, cid, prev_conv_seq)}
      end

    %{
      state
      | replay_rings: Map.put(state.replay_rings, cid, ring),
        ring_base_seq: ring_base_seq,
        conv_last_seq: Map.put(state.conv_last_seq, cid, batch_seq)
    }
  end

  def snapshot_or_replay(state, cid, last_event_id) do
    conv_seq = Map.get(state.conv_last_seq, cid, 0)
    ring = Map.get(state.replay_rings, cid, [])
    ring_base = Map.get(state.ring_base_seq, cid, conv_seq)

    cond do
      not is_nil(last_event_id) and last_event_id == conv_seq ->
        {:ok, {:replay, []}, state}

      not is_nil(last_event_id) and ring != [] and last_event_id >= ring_base and
          last_event_id < conv_seq ->
        frames = Enum.filter(ring, fn {seq, _bin} -> seq > last_event_id end)
        {:ok, {:replay, frames}, state}

      true ->
        case build_snapshot_payload(state, cid, conv_seq) do
          {:ok, json_bin, next_state} ->
            {:ok, {:snapshot, conv_seq, json_bin}, next_state}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def build_snapshot_payload(state, cid, conv_seq) do
    case Storage.scan_entries(state.store, %{conversation_id: cid, order: :desc, limit: 50}) do
      {:ok, %{items: newest_first, next_cursor: next_cursor}, next_store} ->
        entries_oldest_first =
          newest_first
          |> Enum.reverse()
          |> Enum.map(&State.wire_entry(&1, &1.seq))

        conv_docs = state.docs[cid]

        payload = %{
          "version" => 1,
          "session_id" => state.session_id,
          "conversation_id" => to_string(cid),
          "seq" => conv_seq,
          "before_entry_id" => if(next_cursor, do: to_string(next_cursor), else: nil),
          "entries" => entries_oldest_first,
          "docs" => %{
            "live" => conv_docs["live"],
            "inbox" => conv_docs["inbox"],
            "agent" => conv_docs["agent"],
            "usage" => conv_docs["usage"]
          }
        }

        {:ok, IO.iodata_to_binary(JSON.encode_to_iodata!(payload)), %{state | store: next_store}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_written_submissions(writes, fallback_subs) do
    written =
      Enum.flat_map(writes, fn
        {:put_submission, sub} -> [sub]
        _ -> []
      end)

    if written == [], do: fallback_subs, else: written
  end

  defp load_assistant_answer_text(state, entry_id, entry_cache) do
    case Map.fetch(entry_cache, entry_id) do
      {:ok, entry} ->
        {extract_assistant_text(entry), state}

      :error ->
        case Storage.get_entry(state.store, entry_id) do
          {:ok, nil, next_store} ->
            {nil, %{state | store: next_store}}

          {:ok, entry, next_store} ->
            {extract_assistant_text(entry), %{state | store: next_store}}
        end
    end
  end

  defp extract_assistant_text(%{kind: "assistant", data: data}) when is_map(data) do
    blocks = Map.get(data, "content", Map.get(data, :content, []))

    if is_list(blocks) do
      blocks
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) -> [text]
        %{type: "text", text: text} when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("")
    else
      nil
    end
  end

  defp extract_assistant_text(_), do: nil

  defp dispatch_submission_settled(nil, _outcome), do: :ok

  defp dispatch_submission_settled(pubsub, outcome) do
    if Process.whereis(pubsub) != nil do
      msg = {:submission_settled, outcome}

      topics = [
        {:submission, outcome.session_id, outcome.request_id},
        {:submission_id, outcome.session_id, outcome.submission_id},
        {:session_signals, outcome.session_id}
      ]

      Enum.each(topics, fn topic ->
        Registry.dispatch(pubsub, topic, fn entries ->
          for {pid, _val} <- entries, do: send(pid, msg)
        end)
      end)
    end

    :ok
  end

  defp dispatch_pubsub(nil, _sid, _cid, _msg), do: :ok

  defp dispatch_pubsub(pubsub, sid, cid, msg) do
    Registry.dispatch(pubsub, {:conversation, sid, cid}, fn entries ->
      for {pid, _val} <- entries, do: send(pid, msg)
    end)
  end

  defp notify_observers(state, staged, batch_seq) do
    observers_server = Map.get(state, :observers_server)

    if observers_server do
      case Map.get(staged, :raw_item) do
        {:command, _from, %{command: command, conversation_id: cid}} ->
          H.Extensions.Observers.notify(observers_server, :command_committed, %{
            session_id: state.session_id,
            conversation_id: to_string(cid),
            seq: batch_seq,
            command: command,
            receipt: Map.get(staged, :receipt) || %{}
          })

        _ ->
          :ok
      end

      Enum.each(staged.writes, fn
        {:put_task, %{status: "terminal"} = task} ->
          cid = get_in(task.checkpoint, ["conversation_id"])

          H.Extensions.Observers.notify(observers_server, :work_settled, %{
            session_id: state.session_id,
            conversation_id: if(cid, do: to_string(cid), else: ""),
            seq: batch_seq,
            task_id: to_string(task.id),
            task_kind: task.kind,
            outcome: task.outcome || %{}
          })

        _ ->
          :ok
      end)
    end

    :ok
  end
end
