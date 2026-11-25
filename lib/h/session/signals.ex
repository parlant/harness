defmodule H.Session.Signals do
  @moduledoc """
  Durable external wake signals (`{:session, "signals"}` doc) and coordinator-managed
  `wait_signal` tool call lifecycle for `H.Session.Server`.

  Signals are idempotent by `request_id` + payload fingerprint, persisted in
  `{:session, "signals"}`, and either immediately wake the oldest parked
  `wait_signal` task for `topic` or remain queued unconsumed for a subsequent
  `wait_signal` call.
  """

  alias H.{Document, Storage, Submission, Task}
  alias H.Session.Server.{State, Stream, Tools}

  @max_history_records 512

  @doc "Normalizes a stored `{:session, \"signals\"}` document value."
  @spec from_doc(nil | map()) :: map()
  def from_doc(nil) do
    %{"unconsumed" => %{}, "records" => %{}, "order" => []}
  end

  def from_doc(%{"value" => val}) when is_map(val), do: from_doc(val)

  def from_doc(val) when is_map(val) do
    %{
      "unconsumed" => Map.get(val, "unconsumed") || %{},
      "records" => Map.get(val, "records") || %{},
      "order" => Map.get(val, "order") || []
    }
  end

  @doc "Computes a deterministic SHA-256 fingerprint for a signal delivery."
  @spec fingerprint(String.t(), term()) :: String.t()
  def fingerprint(topic, payload) when is_binary(topic) do
    Submission.fingerprint("signal", 0, %{"topic" => topic, "payload" => payload})
  end

  @doc """
  Dispatches a `wait_signal` tool call: consumes an already-queued signal for
  `topic` immediately if available, or parks the `tool_call` task in
  `"waiting"` state with zero workers and an optional timeout timer.
  """
  def dispatch_wait_signal(cid, tool_task, validated_args, state, apply_effects_fn) do
    now = System.system_time(:millisecond)
    topic = Map.fetch!(validated_args, "topic")
    timeout_ms = Map.get(validated_args, "timeout_ms")
    signals_doc = from_doc(state.signals)

    case pop_unconsumed(signals_doc, topic) do
      {:ok, signal, next_signals_doc} ->
        consume_and_complete(
          cid,
          tool_task,
          signal,
          next_signals_doc,
          state,
          now,
          apply_effects_fn
        )

      :empty ->
        park_waiting(cid, tool_task, topic, timeout_ms, state, now, apply_effects_fn)
    end
  end

  @doc """
  Stages an incoming external signal delivery (`deliver_signal`) into the
  session coordinator's drain-batch pipeline.
  """
  def stage_deliver(from, params, state) do
    req_id = params.request_id
    topic = params.topic
    payload = Map.get(params, :payload)
    fp = fingerprint(topic, payload)
    signals_doc = from_doc(state.signals)

    case Map.fetch(signals_doc["records"], req_id) do
      {:ok, existing} ->
        if existing["fingerprint"] == fp do
          {:immediate, from, {:ok, to_receipt(existing, state.seq)}, [], state}
        else
          {:immediate, from,
           {:error, {:conflict, "request_id already used with different payload"}}, [], state}
        end

      :error ->
        now = System.system_time(:millisecond)
        {:ok, sig_id, store} = Storage.mint_id(state.store)
        state = %{state | store: store}

        waiting_task = find_oldest_waiting_task(state, topic)

        record = %{
          "id" => to_string(sig_id),
          "request_id" => req_id,
          "fingerprint" => fp,
          "topic" => topic,
          "payload" => payload,
          "delivered_at" => now,
          "status" => if(waiting_task, do: "delivered", else: "queued"),
          "consumed_by_task_id" => if(waiting_task, do: to_string(waiting_task.id), else: nil)
        }

        next_signals_doc =
          signals_doc
          |> put_record(req_id, record)
          |> then(fn doc ->
            if waiting_task do
              doc
            else
              enqueue_unconsumed(doc, topic, record)
            end
          end)

        state = %{state | signals: next_signals_doc}

        signals_write =
          {:put_doc, {:session, "signals"}, Document.wrap("signals", next_signals_doc)}

        if waiting_task do
          cid = waiting_task.checkpoint["conversation_id"]

          {entry, done_task, live, state} =
            build_signal_completion(cid, waiting_task, record, state, now)

          {:batch, tool_staged, state} =
            Tools.stage_after_tool_settled(
              cid,
              done_task,
              entry,
              live,
              state,
              now,
              [{:cancel_wake_timer, waiting_task.id}]
            )

          staged = %{
            tool_staged
            | raw_item: {:deliver_signal, from, params},
              writes: [signals_write | tool_staged.writes],
              reply_from: from,
              receipt: to_receipt(record, state.seq)
          }

          {:batch, staged, state}
        else
          staged = %{
            raw_item: {:deliver_signal, from, params},
            writes: [signals_write],
            conv_events: %{},
            submissions: [],
            effects: [],
            reply_from: from,
            receipt: to_receipt(record, state.seq)
          }

          {:batch, staged, state}
        end
    end
  end

  @doc """
  Stages timeout expiry for a parked `wait_signal` task (`{:wake_task, tid}`).
  """
  def stage_timeout(%{kind: "tool_call", status: "waiting"} = tool_task, state) do
    if tool_task.checkpoint["name"] == "wait_signal" and
         get_in(tool_task.wake, ["on"]) == "signal" do
      now = System.system_time(:millisecond)
      cid = tool_task.checkpoint["conversation_id"]
      call_id = tool_task.checkpoint["call_id"]
      topic = get_in(tool_task.wake, ["topic"]) || tool_task.checkpoint["arguments"]["topic"]

      {:ok, entry_id, store} = Storage.mint_id(state.store)
      state = %{state | store: store}

      duration_ms =
        if is_integer(tool_task.started_at),
          do: max(0, now - tool_task.started_at),
          else: 0

      entry_data = %{
        "tool_call_id" => call_id,
        "name" => "wait_signal",
        "content" => [
          %{
            "type" => "text",
            "text" => "Timed out waiting for signal on topic \"#{topic}\"."
          }
        ],
        "details" => %{
          "topic" => topic,
          "timed_out" => true,
          "diagnostic" => "signal_timeout"
        },
        "is_error" => true,
        "diagnostic" => "signal_timeout",
        "duration_ms" => duration_ms
      }

      entry = State.build_entry(entry_id, cid, "tool_result", entry_data, now)
      state = State.record_entry(state, cid, entry_id)

      done_task =
        Task.complete(
          tool_task,
          %{"entry_id" => entry_id, "is_error" => true, "diagnostic" => "signal_timeout"},
          now
        )

      live = State.put_tool_status(state.docs[cid]["live"], call_id, "done")
      state = state |> State.put_task(done_task) |> State.put_doc(cid, "live", live)

      {:batch, tool_staged, state} =
        Tools.stage_after_tool_settled(
          cid,
          done_task,
          entry,
          live,
          state,
          now,
          [{:cancel_wake_timer, tool_task.id}]
        )

      {:batch, %{tool_staged | raw_item: {:wake_task, tool_task.id}}, state}
    else
      {:skip, state}
    end
  end

  def stage_timeout(_task, state), do: {:skip, state}

  @doc "Returns wake timer effects for any parked `wait_signal` tasks with a deadline."
  def recovery_wake_effects(tasks, now) when is_map(tasks) do
    tasks
    |> Map.values()
    |> Enum.filter(fn t ->
      t.kind == "tool_call" and t.status == "waiting" and
        t.checkpoint["name"] == "wait_signal" and
        is_integer(get_in(t.wake, ["until"]))
    end)
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn t ->
      until_ms = get_in(t.wake, ["until"])
      {:arm_wake_timer, t.id, max(0, until_ms - now)}
    end)
  end

  # Internal helpers

  defp park_waiting(cid, tool_task, topic, timeout_ms, state, now, apply_effects_fn) do
    call_id = tool_task.checkpoint["call_id"]
    until_ms = if is_integer(timeout_ms), do: now + timeout_ms, else: nil

    wake =
      %{"on" => "signal", "topic" => topic}
      |> then(fn w -> if until_ms, do: Map.put(w, "until", until_ms), else: w end)

    waiting_task = %{
      Task.start_waiting(tool_task, now, %{"phase" => "waiting", "replay" => "safe"})
      | wake: wake,
        started_at: tool_task.started_at || now
    }

    live = State.put_tool_status(state.docs[cid]["live"], call_id, "waiting")
    state = state |> State.put_task(waiting_task) |> State.put_doc(cid, "live", live)

    writes = [
      {:put_task, waiting_task},
      {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", live)}
    ]

    case Storage.commit(state.store, [writes]) do
      {:ok, %{seqs: [batch_seq]}, committed_store} ->
        state = %{state | store: committed_store, seq: batch_seq}

        state =
          Stream.broadcast_commit_frame(state, cid, batch_seq, [], %{
            "live" => [["replace", live]]
          })

        State.report_catalog_active(state)

        effects =
          if is_integer(timeout_ms),
            do: [{:arm_wake_timer, waiting_task.id, timeout_ms}],
            else: []

        apply_effects_fn.(effects, state)

      {:error, reason} ->
        send(self(), {:stop_storage_failed, reason})
        %{state | storage_failed: true}
    end
  end

  defp consume_and_complete(
         cid,
         tool_task,
         signal,
         next_signals_doc,
         state,
         now,
         apply_effects_fn
       ) do
    updated_signal =
      signal
      |> Map.put("status", "delivered")
      |> Map.put("consumed_by_task_id", to_string(tool_task.id))

    next_signals_doc = put_record(next_signals_doc, signal["request_id"], updated_signal)
    state = %{state | signals: next_signals_doc}

    {entry, done_task, live, state} =
      build_signal_completion(cid, tool_task, updated_signal, state, now)

    {:batch, staged, state} =
      Tools.stage_after_tool_settled(cid, done_task, entry, live, state, now, [])

    writes = [
      {:put_doc, {:session, "signals"}, Document.wrap("signals", next_signals_doc)}
      | staged.writes
    ]

    case Storage.commit(state.store, [writes]) do
      {:ok, %{seqs: [batch_seq]}, committed_store} ->
        staged = %{staged | writes: writes}

        state =
          Stream.apply_committed_batches([staged], [batch_seq], %{state | store: committed_store})

        State.report_catalog_active(state)
        apply_effects_fn.(staged.effects, state)

      {:error, reason} ->
        send(self(), {:stop_storage_failed, reason})
        %{state | storage_failed: true}
    end
  end

  defp build_signal_completion(cid, tool_task, signal, state, now) do
    call_id = tool_task.checkpoint["call_id"]
    topic = signal["topic"]
    payload = signal["payload"]

    {:ok, entry_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}

    duration_ms =
      if is_integer(tool_task.started_at),
        do: max(0, now - tool_task.started_at),
        else: 0

    text =
      if is_nil(payload) do
        "Signal received on topic \"#{topic}\" (request_id: #{signal["request_id"]})."
      else
        "Signal received on topic \"#{topic}\" (request_id: #{signal["request_id"]}):\n" <>
          IO.iodata_to_binary(JSON.encode_to_iodata!(payload))
      end

    entry_data = %{
      "tool_call_id" => call_id,
      "name" => "wait_signal",
      "content" => [%{"type" => "text", "text" => text}],
      "details" => %{
        "signal_id" => signal["id"],
        "request_id" => signal["request_id"],
        "topic" => topic,
        "payload" => payload
      },
      "is_error" => false,
      "diagnostic" => nil,
      "duration_ms" => duration_ms
    }

    entry = State.build_entry(entry_id, cid, "tool_result", entry_data, now)
    state = State.record_entry(state, cid, entry_id)

    done_task =
      Task.complete(
        tool_task,
        %{"entry_id" => entry_id, "is_error" => false, "signal_id" => signal["id"]},
        now
      )

    live = State.put_tool_status(state.docs[cid]["live"], call_id, "done")
    state = state |> State.put_task(done_task) |> State.put_doc(cid, "live", live)
    {entry, done_task, live, state}
  end

  defp find_oldest_waiting_task(state, topic) do
    state.tasks
    |> Map.values()
    |> Enum.filter(fn t ->
      t.kind == "tool_call" and t.status == "waiting" and
        t.checkpoint["name"] == "wait_signal" and
        get_in(t.wake, ["on"]) == "signal" and
        get_in(t.wake, ["topic"]) == topic
    end)
    |> Enum.min_by(& &1.id, fn -> nil end)
  end

  defp pop_unconsumed(signals_doc, topic) do
    unconsumed = signals_doc["unconsumed"] || %{}

    case Map.get(unconsumed, topic, []) do
      [head | rest] ->
        next_unconsumed =
          if rest == [],
            do: Map.delete(unconsumed, topic),
            else: Map.put(unconsumed, topic, rest)

        {:ok, head, Map.put(signals_doc, "unconsumed", next_unconsumed)}

      [] ->
        :empty
    end
  end

  defp enqueue_unconsumed(signals_doc, topic, record) do
    unconsumed = signals_doc["unconsumed"] || %{}
    queue = Map.get(unconsumed, topic, []) ++ [record]
    Map.put(signals_doc, "unconsumed", Map.put(unconsumed, topic, queue))
  end

  defp put_record(signals_doc, req_id, record) do
    records = Map.put(signals_doc["records"] || %{}, req_id, record)
    order = signals_doc["order"] || []
    order = if req_id in order, do: order, else: order ++ [req_id]

    {records, order} =
      if length(order) > @max_history_records do
        {drop_ids, keep_ids} = Enum.split(order, length(order) - @max_history_records)
        {Map.drop(records, drop_ids), keep_ids}
      else
        {records, order}
      end

    signals_doc
    |> Map.put("records", records)
    |> Map.put("order", order)
  end

  defp to_receipt(record, seq) do
    %{
      version: 1,
      signal_id: record["id"],
      request_id: record["request_id"],
      topic: record["topic"],
      status: record["status"],
      consumed_by_task_id: record["consumed_by_task_id"],
      seq: seq
    }
  end
end
