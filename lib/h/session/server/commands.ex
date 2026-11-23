defmodule H.Session.Server.Commands do
  @moduledoc """
  Command envelope deduplication and staging (`submit`, `fork`, `fork_and_submit`,
  `configure`, `abort`, `withdraw`, `rename`, `compact`, and `user_shell`
  delegation) for `H.Session.Server`.
  """

  alias H.{Document, Storage, Submission, Task}
  alias H.Session.{Compaction, UserShell}
  alias H.Session.Server.{Generation, State, Submissions}

  def stage(from, cmd, state, staged_rev) do
    req_id = cmd.request_id
    cid = cmd.conversation_id
    command = cmd.command
    args = cmd.args
    fingerprint = Submission.fingerprint(command, cid, args)

    case Submissions.lookup(state, req_id) do
      {:ok, existing, next_state} ->
        if existing.fingerprint == fingerprint do
          {:immediate, from, {:ok, Submission.to_receipt(existing, next_state.seq)}, [],
           next_state}
        else
          {:immediate, from,
           {:error, {:conflict, "request_id already used with different payload"}}, [],
           next_state}
        end

      {:not_found, next_state} ->
        if Map.has_key?(next_state.conversations, cid) do
          dispatch(from, command, cid, req_id, fingerprint, args, next_state, staged_rev)
        else
          {:immediate, from, {:error, :not_found}, [], next_state}
        end
    end
  end

  def stage_user_shell_done(tid, attempt_id, result, state) do
    case UserShell.stage_done(tid, attempt_id, result, state) do
      {:skip, next_state} ->
        {:skip, next_state}

      {:batch, staged, next_state} ->
        maybe_drain_inbox_after_user_shell(tid, staged, next_state)
    end
  end

  # Command dispatch

  defp dispatch(from, "submit", cid, req_id, fp, args, state, _staged_rev) do
    now = System.system_time(:millisecond)

    case args.type do
      "write" ->
        stage_submit_write(from, cid, req_id, fp, args, state, now)

      "continue" ->
        if State.cwd_available?(state) do
          stage_submit_continue(from, cid, req_id, fp, state, now)
        else
          {:immediate, from, {:error, {:conflict, "cwd_missing"}}, [], state}
        end

      "input" ->
        if State.cwd_available?(state) do
          stage_submit_input(from, cid, req_id, fp, args, state, now)
        else
          {:immediate, from, {:error, {:conflict, "cwd_missing"}}, [], state}
        end
    end
  end

  defp dispatch(from, "fork", cid, req_id, fp, args, state, _staged_rev) do
    stage_fork(from, cid, req_id, fp, args, state, false)
  end

  defp dispatch(from, "fork_and_submit", cid, req_id, fp, args, state, _staged_rev) do
    if State.cwd_available?(state) do
      stage_fork(from, cid, req_id, fp, args, state, true)
    else
      {:immediate, from, {:error, {:conflict, "cwd_missing"}}, [], state}
    end
  end

  defp dispatch(from, "configure", cid, req_id, fp, args, state, _staged_rev) do
    stage_configure(from, cid, req_id, fp, args, state)
  end

  defp dispatch(from, "abort", cid, req_id, fp, args, state, _staged_rev) do
    stage_abort(from, cid, req_id, fp, args, state)
  end

  defp dispatch(from, "workspace_wait", cid, req_id, fp, args, state, _staged_rev) do
    wait = get_in(state.docs, [cid, "live", "workspace_wait"])

    if wait && wait["task_id"] == to_string(args.task_id) &&
         (args.action == "cancel" or wait["lease_id"] == args.lease_id) do
      case args.action do
        "cancel" ->
          stage_abort(
            from,
            cid,
            req_id,
            fp,
            Map.put(args, :reason, "wait_cancelled"),
            state,
            "workspace_wait"
          )

        "stop_holder" ->
          now = System.system_time(:millisecond)
          {:ok, id, store} = Storage.mint_id(state.store)
          state = %{state | store: store}

          sub =
            Submission.new(%{
              id: id,
              request_id: req_id,
              fingerprint: fp,
              kind: "workspace_wait",
              status: "done",
              conversation_id: cid,
              created_at: now
            })

          staged = %{
            raw_item:
              {:command, from,
               %{command: "workspace_wait", conversation_id: cid, request_id: req_id, args: args}},
            writes: [{:check, {:unique_request_id, req_id, fp}}, {:put_submission, sub}],
            conv_events: %{},
            submissions: [sub],
            effects: [{:stop_workspace_holder, cid, args.task_id, args.lease_id}],
            reply_from: from,
            receipt: Submission.to_receipt(sub, state.seq)
          }

          {:batch, staged, state}
      end
    else
      {:immediate, from, {:error, {:conflict, "stale_workspace_wait"}}, [], state}
    end
  end

  defp dispatch(from, "withdraw", cid, req_id, fp, args, state, staged_rev) do
    stage_withdraw(from, cid, req_id, fp, args, state, staged_rev)
  end

  defp dispatch(from, "rename", cid, req_id, fp, args, state, _staged_rev) do
    stage_rename(from, cid, req_id, fp, args, state)
  end

  defp dispatch(from, "user_shell", cid, req_id, fp, args, state, _staged_rev) do
    if State.cwd_available?(state) do
      UserShell.stage(from, cid, req_id, fp, args, state)
    else
      {:immediate, from, {:error, {:conflict, "cwd_missing"}}, [], state}
    end
  end

  defp dispatch(from, "compact", cid, req_id, fp, args, state, _staged_rev) do
    if State.cwd_available?(state) do
      stage_compact(from, cid, req_id, fp, args, state)
    else
      {:immediate, from, {:error, {:conflict, "cwd_missing"}}, [], state}
    end
  end

  # Individual command stagers

  defp stage_submit_write(from, cid, req_id, fp, args, state, now) do
    {:ok, entry_id, store} = Storage.mint_id(state.store)
    {:ok, sub_id, store} = Storage.mint_id(store)
    state = %{state | store: store}

    entry_kind = Map.get(args, :kind) || "user"

    entry_data =
      Map.get(args, :data) || %{"content" => State.normalize_content(Map.get(args, :content, ""))}

    entry = State.build_entry(entry_id, cid, entry_kind, entry_data, now)
    state = State.record_entry(state, cid, entry_id)

    sub =
      Submission.new(%{
        id: sub_id,
        request_id: req_id,
        fingerprint: fp,
        kind: "write",
        status: "done",
        conversation_id: cid,
        entry_id: entry_id,
        created_at: now
      })

    writes = [
      {:check, {:unique_request_id, req_id, fp}},
      {:append_entry, entry},
      {:put_submission, sub}
    ]

    staged = %{
      raw_item:
        {:command, from,
         %{command: "submit", conversation_id: cid, request_id: req_id, args: args}},
      writes: writes,
      conv_events: %{cid => %{entries: [entry], doc_ops: %{}}},
      submissions: [sub],
      effects: [],
      reply_from: from,
      receipt: Submission.to_receipt(sub, state.seq)
    }

    {:batch, staged, state}
  end

  defp stage_submit_input(from, cid, req_id, fp, args, state, now) do
    when_busy = Map.get(args, :when_busy, "follow_up")
    when_idle = Map.get(args, :when_idle, "start")
    content = State.normalize_content(args.content)

    if State.conversation_busy?(state, cid) do
      if when_busy == "reject" do
        {:immediate, from, {:error, {:conflict, "conversation_busy"}}, [], state}
      else
        {:ok, sub_id, store} = Storage.mint_id(state.store)
        state = %{state | store: store}

        sub =
          Submission.new(%{
            id: sub_id,
            request_id: req_id,
            fingerprint: fp,
            kind: "input",
            status: "queued",
            conversation_id: cid,
            when_busy: when_busy,
            when_idle: when_idle,
            created_at: now
          })

        inbox_item = %{
          "submission_id" => to_string(sub_id),
          "request_id" => req_id,
          "when_busy" => when_busy,
          "content" => content
        }

        prev_inbox = state.docs[cid]["inbox"]
        next_inbox = prev_inbox ++ [inbox_item]
        doc_op = ["set", [length(prev_inbox)], inbox_item]
        state = State.put_doc(state, cid, "inbox", next_inbox)

        writes = [
          {:check, {:unique_request_id, req_id, fp}},
          {:put_submission, sub},
          {:put_doc, {:conversation, cid, "inbox"}, Document.wrap("inbox", next_inbox)}
        ]

        staged = %{
          raw_item:
            {:command, from,
             %{command: "submit", conversation_id: cid, request_id: req_id, args: args}},
          writes: writes,
          conv_events: %{cid => %{entries: [], doc_ops: %{"inbox" => [doc_op]}}},
          submissions: [sub],
          effects: [],
          reply_from: from,
          receipt: Submission.to_receipt(sub, state.seq)
        }

        {:batch, staged, state}
      end
    else
      if when_idle == "reject" do
        {:immediate, from, {:error, {:conflict, "conversation_idle"}}, [], state}
      else
        {:ok, entry_id, store} = Storage.mint_id(state.store)
        {:ok, sub_id, store} = Storage.mint_id(store)
        state = %{state | store: store}

        entry = State.build_entry(entry_id, cid, "user", %{"content" => content}, now)
        state = State.record_entry(state, cid, entry_id)

        sub =
          Submission.new(%{
            id: sub_id,
            request_id: req_id,
            fingerprint: fp,
            kind: "input",
            status: "placed",
            conversation_id: cid,
            entry_id: entry_id,
            when_busy: when_busy,
            when_idle: when_idle,
            created_at: now
          })

        {drained_entries, drained_sub_writes, drained_sub_ids, inbox_ops, state} =
          Submissions.drain_inbox(cid, state, now, nil)

        {gen_task, next_live, state} =
          Submissions.start_pending_generation(cid, drained_sub_ids ++ [sub_id], state, now)

        all_entries = drained_entries ++ [entry]
        {title_writes, state} = Submissions.maybe_derive_initial_title(content, state)

        writes =
          [{:check, {:unique_request_id, req_id, fp}}] ++
            title_writes ++
            Enum.map(all_entries, &{:append_entry, &1}) ++
            drained_sub_writes ++
            [
              {:put_submission, sub},
              {:put_task, gen_task},
              {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
            ] ++
            if(inbox_ops == [],
              do: [],
              else: [{:put_doc, {:conversation, cid, "inbox"}, Document.wrap("inbox", [])}]
            )

        doc_ops =
          %{"live" => [["replace", next_live]]}
          |> then(fn m -> if inbox_ops == [], do: m, else: Map.put(m, "inbox", inbox_ops) end)

        staged = %{
          raw_item:
            {:command, from,
             %{command: "submit", conversation_id: cid, request_id: req_id, args: args}},
          writes: writes,
          conv_events: %{cid => %{entries: all_entries, doc_ops: doc_ops}},
          submissions: [sub],
          effects: [{:spawn_generation, cid, gen_task.id}],
          reply_from: from,
          receipt: Submission.to_receipt(sub, state.seq)
        }

        {:batch, staged, state}
      end
    end
  end

  defp stage_submit_continue(from, cid, req_id, fp, state, now) do
    if State.conversation_busy?(state, cid) do
      {:immediate, from, {:error, {:conflict, "conversation_busy"}}, [], state}
    else
      {:ok, sub_id, store} = Storage.mint_id(state.store)
      state = %{state | store: store}

      {drained_entries, drained_sub_writes, drained_sub_ids, inbox_ops, state} =
        Submissions.drain_inbox(cid, state, now, nil)

      {:ok, has_target, state} = Submissions.has_answerable_context?(cid, drained_entries, state)

      if has_target do
        sub =
          Submission.new(%{
            id: sub_id,
            request_id: req_id,
            fingerprint: fp,
            kind: "continue",
            status: "placed",
            conversation_id: cid,
            created_at: now
          })

        {gen_task, next_live, state} =
          Submissions.start_pending_generation(cid, drained_sub_ids ++ [sub_id], state, now)

        writes =
          [{:check, {:unique_request_id, req_id, fp}}] ++
            Enum.map(drained_entries, &{:append_entry, &1}) ++
            drained_sub_writes ++
            [
              {:put_submission, sub},
              {:put_task, gen_task},
              {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
            ] ++
            if(inbox_ops == [],
              do: [],
              else: [{:put_doc, {:conversation, cid, "inbox"}, Document.wrap("inbox", [])}]
            )

        doc_ops =
          %{"live" => [["replace", next_live]]}
          |> then(fn m -> if inbox_ops == [], do: m, else: Map.put(m, "inbox", inbox_ops) end)

        staged = %{
          raw_item:
            {:command, from,
             %{
               command: "submit",
               conversation_id: cid,
               request_id: req_id,
               args: %{type: "continue"}
             }},
          writes: writes,
          conv_events: %{cid => %{entries: drained_entries, doc_ops: doc_ops}},
          submissions: [sub],
          effects: [{:spawn_generation, cid, gen_task.id}],
          reply_from: from,
          receipt: Submission.to_receipt(sub, state.seq)
        }

        {:batch, staged, state}
      else
        sub =
          Submission.new(%{
            id: sub_id,
            request_id: req_id,
            fingerprint: fp,
            kind: "continue",
            status: "unanswered",
            conversation_id: cid,
            reason: "nothing_to_answer",
            created_at: now
          })

        next_live = %{"run_failure" => %{"reason" => "nothing_to_answer"}}
        state = State.put_doc(state, cid, "live", next_live)

        writes = [
          {:check, {:unique_request_id, req_id, fp}},
          {:put_submission, sub},
          {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
        ]

        staged = %{
          raw_item:
            {:command, from,
             %{
               command: "submit",
               conversation_id: cid,
               request_id: req_id,
               args: %{type: "continue"}
             }},
          writes: writes,
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [sub],
          effects: [],
          reply_from: from,
          receipt: Submission.to_receipt(sub, state.seq)
        }

        {:batch, staged, state}
      end
    end
  end

  defp stage_fork(from, parent_cid, req_id, fp, args, state, submit?) do
    at_entry_id = args.at_entry_id
    now = System.system_time(:millisecond)

    case State.verify_visible_entry(state, parent_cid, at_entry_id) do
      {:ok, at_entry, state} ->
        {:ok, fork_docs, store} =
          Document.fork_docs(state.store, parent_cid, at_entry.seq,
            default_model: state.default_model
          )

        {:ok, child_cid, store} = Storage.mint_id(store)
        state = %{state | store: store}

        child_conv = %{
          id: child_cid,
          parent: %{conversation_id: parent_cid, at: at_entry_id},
          owner: :ownerless,
          entry_ids: []
        }

        state = %{
          state
          | conversations: Map.put(state.conversations, child_cid, child_conv),
            docs: Map.put(state.docs, child_cid, fork_docs)
        }

        base_writes = [
          {:check, {:unique_request_id, req_id, fp}},
          {:put_conversation, child_conv},
          {:put_doc, {:conversation, child_cid, "agent"},
           Document.wrap("agent", fork_docs["agent"])},
          {:put_doc, {:conversation, child_cid, "live"},
           Document.wrap("live", fork_docs["live"])},
          {:put_doc, {:conversation, child_cid, "inbox"},
           Document.wrap("inbox", fork_docs["inbox"])},
          {:put_doc, {:conversation, child_cid, "usage"},
           Document.wrap("usage", fork_docs["usage"])}
        ]

        if submit? do
          {:ok, entry_id, store} = Storage.mint_id(state.store)
          {:ok, sub_id, store} = Storage.mint_id(store)
          state = %{state | store: store}

          content = State.normalize_content(args.content)
          entry = State.build_entry(entry_id, child_cid, "user", %{"content" => content}, now)
          state = State.record_entry(state, child_cid, entry_id)

          sub =
            Submission.new(%{
              id: sub_id,
              request_id: req_id,
              fingerprint: fp,
              kind: "fork_and_submit",
              status: "placed",
              conversation_id: child_cid,
              entry_id: entry_id,
              when_busy: Map.get(args, :when_busy, "follow_up"),
              when_idle: Map.get(args, :when_idle, "start"),
              created_at: now
            })

          {gen_task, next_live, state} =
            Submissions.start_pending_generation(child_cid, [sub_id], state, now)

          writes =
            base_writes ++
              [
                {:append_entry, entry},
                {:put_submission, sub},
                {:put_task, gen_task},
                {:put_doc, {:conversation, child_cid, "live"}, Document.wrap("live", next_live)}
              ]

          doc_ops = %{
            "agent" => [["replace", fork_docs["agent"]]],
            "live" => [["replace", next_live]],
            "inbox" => [["replace", fork_docs["inbox"]]],
            "usage" => [["replace", fork_docs["usage"]]]
          }

          staged = %{
            raw_item:
              {:command, from,
               %{
                 command: "fork_and_submit",
                 conversation_id: parent_cid,
                 request_id: req_id,
                 args: args
               }},
            writes: writes,
            conv_events: %{child_cid => %{entries: [entry], doc_ops: doc_ops}},
            submissions: [sub],
            effects: [{:spawn_generation, child_cid, gen_task.id}],
            reply_from: from,
            receipt: Submission.to_receipt(sub, state.seq)
          }

          {:batch, staged, state}
        else
          {:ok, sub_id, store} = Storage.mint_id(state.store)
          state = %{state | store: store}

          sub =
            Submission.new(%{
              id: sub_id,
              request_id: req_id,
              fingerprint: fp,
              kind: "fork",
              status: "done",
              conversation_id: child_cid,
              entry_id: at_entry_id,
              created_at: now
            })

          writes = base_writes ++ [{:put_submission, sub}]

          doc_ops = %{
            "agent" => [["replace", fork_docs["agent"]]],
            "live" => [["replace", fork_docs["live"]]],
            "inbox" => [["replace", fork_docs["inbox"]]],
            "usage" => [["replace", fork_docs["usage"]]]
          }

          staged = %{
            raw_item:
              {:command, from,
               %{command: "fork", conversation_id: parent_cid, request_id: req_id, args: args}},
            writes: writes,
            conv_events: %{child_cid => %{entries: [], doc_ops: doc_ops}},
            submissions: [sub],
            effects: [],
            reply_from: from,
            receipt: Submission.to_receipt(sub, state.seq)
          }

          {:batch, staged, state}
        end

      {:error, :entry_not_visible, state} ->
        {:immediate, from, {:error, {:bad_request, "entry_not_visible"}}, [], state}
    end
  end

  defp stage_configure(from, cid, req_id, fp, args, state) do
    expected_seq = Map.get(args, :expected_seq)
    conv_seq = Map.get(state.conv_last_seq, cid, state.seq)

    if not is_nil(expected_seq) and
         expected_seq not in [conv_seq, state.seq, state.idle_resume_seq] do
      {:immediate, from, {:error, {:conflict, "expected_seq mismatch"}}, [], state}
    else
      now = System.system_time(:millisecond)
      {:ok, sub_id, store} = Storage.mint_id(state.store)
      state = %{state | store: store}

      prev_agent = state.docs[cid]["agent"]
      {next_agent, doc_ops} = Document.configure_agent(prev_agent, args)
      state = State.put_doc(state, cid, "agent", next_agent)

      sub =
        Submission.new(%{
          id: sub_id,
          request_id: req_id,
          fingerprint: fp,
          kind: "configure",
          status: "done",
          conversation_id: cid,
          created_at: now
        })

      writes = [
        {:check, {:unique_request_id, req_id, fp}},
        {:put_submission, sub},
        {:put_doc, {:conversation, cid, "agent"}, Document.wrap("agent", next_agent)}
      ]

      wake_effects =
        if Map.has_key?(args, :model) and next_agent["model"] != prev_agent["model"] do
          state.tasks
          |> Map.values()
          |> Enum.filter(fn t ->
            t.owner == {:conversation, cid} and
              t.status == "sleeping" and
              t.kind in ["generation", "compaction"] and
              get_in(t.wake, ["reason"]) == "wait"
          end)
          |> Enum.sort_by(& &1.id)
          |> Enum.map(&{:arm_wake_timer, &1.id, 0})
        else
          []
        end

      staged = %{
        raw_item:
          {:command, from,
           %{command: "configure", conversation_id: cid, request_id: req_id, args: args}},
        writes: writes,
        conv_events: %{cid => %{entries: [], doc_ops: %{"agent" => doc_ops}}},
        submissions: [sub],
        effects: wake_effects,
        reply_from: from,
        receipt: Submission.to_receipt(sub, state.seq)
      }

      {:batch, staged, state}
    end
  end

  def stage_abort_all(from, reason, state) do
    now = System.system_time(:millisecond)
    reason = if is_binary(reason) and reason != "", do: reason, else: "stopped"

    cids = state.conversations |> Map.keys() |> Enum.sort()

    {writes, conv_events, effects, aborted_count, state} =
      Enum.reduce(cids, {[], %{}, [], 0, state}, fn cid,
                                                    {acc_w, acc_ev, acc_eff, acc_cnt, acc_st} ->
        {w, ev, eff, aborted?, next_st} = abort_conversation_tasks(cid, reason, acc_st, now)

        if aborted? do
          {acc_w ++ w, Map.put(acc_ev, cid, ev), acc_eff ++ eff, acc_cnt + 1, next_st}
        else
          {acc_w, acc_ev, acc_eff, acc_cnt, next_st}
        end
      end)

    if writes == [] do
      {:immediate, from, {:ok, %{aborted_conversations: 0, seq: state.seq}}, [], state}
    else
      staged = %{
        raw_item: {:abort_all, from, reason},
        writes: writes,
        conv_events: conv_events,
        submissions: [],
        effects: effects,
        reply_from: from,
        receipt: %{aborted_conversations: aborted_count}
      }

      {:batch, staged, state}
    end
  end

  def stage_seed_entries(from, cid, raw_entries, state) do
    if raw_entries == [] do
      {:immediate, from, {:ok, %{seeded: 0, seq: state.seq}}, [], state}
    else
      now = System.system_time(:millisecond)

      {entries, state} =
        Enum.reduce(raw_entries, {[], state}, fn raw, {acc_e, acc_st} ->
          {:ok, entry_id, store} = Storage.mint_id(acc_st.store)
          acc_st = %{acc_st | store: store}
          kind = Map.get(raw, :kind) || Map.get(raw, "kind")
          data = Map.get(raw, :data) || Map.get(raw, "data") || %{}
          created_at = Map.get(raw, :created_at) || Map.get(raw, "created_at") || now

          entry = State.build_entry(entry_id, cid, kind, data, created_at)
          acc_st = State.record_entry(acc_st, cid, entry_id)
          {acc_e ++ [entry], acc_st}
        end)

      writes = Enum.map(entries, &{:append_entry, &1})

      staged = %{
        raw_item: {:seed_entries, from, cid, raw_entries},
        writes: writes,
        conv_events: %{cid => %{entries: entries, doc_ops: %{}}},
        submissions: [],
        effects: [],
        reply_from: from,
        receipt: %{seeded: length(entries)}
      }

      {:batch, staged, state}
    end
  end

  defp abort_conversation_tasks(cid, reason, state, now) do
    active_for = fn kind ->
      state.tasks
      |> Map.values()
      |> Enum.filter(fn t ->
        t.kind == kind and t.owner == {:conversation, cid} and t.status != "terminal"
      end)
    end

    active_gens = active_for.("generation")
    active_shells = active_for.("user_shell")
    active_compactions = active_for.("compaction")

    if active_gens == [] and active_shells == [] and active_compactions == [] do
      {[], %{entries: [], doc_ops: %{}}, [], false, state}
    else
      {abort_writes, state, kill_effects} =
        Enum.reduce(active_gens, {[], state, []}, fn gen_task, {acc_w, acc_s, acc_eff} ->
          {w, st, eff} = Generation.abort_generation_run(gen_task, cid, reason, acc_s, now)
          {acc_w ++ w, st, acc_eff ++ eff}
        end)

      {shell_writes, state, shell_kills} =
        Enum.reduce(active_shells, {[], state, []}, fn shell_task, {acc_w, acc_s, acc_eff} ->
          {w, st, eff} = UserShell.stage_abort(shell_task, cid, reason, acc_s, now)
          {acc_w ++ w, st, acc_eff ++ eff}
        end)

      {comp_writes, state, comp_kills} =
        Enum.reduce(active_compactions, {[], state, []}, fn comp_task, {acc_w, acc_s, acc_eff} ->
          {w, st, eff} = Generation.abort_compaction_run(comp_task, cid, reason, acc_s, now)
          {acc_w ++ w, st, acc_eff ++ eff}
        end)

      all_abort_writes = abort_writes ++ shell_writes ++ comp_writes
      all_kill_effects = kill_effects ++ shell_kills ++ comp_kills
      next_live = Map.delete(state.docs[cid]["live"], "workspace_wait")
      state = State.put_doc(state, cid, "live", next_live)

      all_abort_writes =
        all_abort_writes ++
          [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

      appended =
        Enum.flat_map(all_abort_writes, fn
          {:append_entry, e} -> [e]
          _ -> []
        end)

      ev = %{entries: appended, doc_ops: %{"live" => [["replace", next_live]]}}
      {all_abort_writes, ev, all_kill_effects, true, state}
    end
  end

  def stage_stop_workspace_holder(cwd, {sid, cid} = holder, lease_id, state) do
    if sid == state.session_id and state.held_leases[cid] == cwd and
         H.WorkspaceLease.current?(state.workspace_lease, cwd, holder, lease_id) do
      {writes, ev, effects, _aborted?, state} =
        abort_conversation_tasks(
          cid,
          "workspace_handoff",
          state,
          System.system_time(:millisecond)
        )

      staged = %{
        raw_item: {:stop_workspace_holder, cwd, holder, lease_id},
        writes: writes,
        conv_events: %{cid => ev},
        submissions: [],
        effects: effects,
        reply_from: nil,
        receipt: nil
      }

      {:batch, staged, state}
    else
      {:skip, state}
    end
  end

  defp stage_abort(from, cid, req_id, fp, args, state, command \\ "abort") do
    now = System.system_time(:millisecond)
    reason = Map.get(args, :reason) || "aborted"
    {:ok, sub_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}

    {all_abort_writes, ev, all_kill_effects, _aborted?, state} =
      abort_conversation_tasks(cid, reason, state, now)

    sub =
      Submission.new(%{
        id: sub_id,
        request_id: req_id,
        fingerprint: fp,
        kind: command,
        status: "done",
        conversation_id: cid,
        reason: reason,
        created_at: now
      })

    writes =
      [{:check, {:unique_request_id, req_id, fp}}, {:put_submission, sub}] ++ all_abort_writes

    staged = %{
      raw_item:
        {:command, from,
         %{command: command, conversation_id: cid, request_id: req_id, args: args}},
      writes: writes,
      conv_events: %{cid => ev},
      submissions: [sub],
      effects: all_kill_effects,
      reply_from: from,
      receipt: Submission.to_receipt(sub, state.seq)
    }

    {:batch, staged, state}
  end

  defp stage_withdraw(from, cid, req_id, fp, args, state, staged_rev) do
    inbox = state.docs[cid]["inbox"] || []
    requested_ids = MapSet.new(args.submission_ids, &to_string/1)

    {withdrawn_items, remaining_inbox} =
      Enum.split_with(inbox, fn item ->
        MapSet.member?(requested_ids, Map.get(item, "submission_id"))
      end)

    found_ids = MapSet.new(withdrawn_items, &Map.get(&1, "submission_id"))

    if MapSet.size(found_ids) != MapSet.size(requested_ids) do
      {:immediate, from, {:error, {:conflict, "submission_not_queued"}}, [], state}
    else
      now = System.system_time(:millisecond)
      {:ok, sub_id, store} = Storage.mint_id(state.store)
      state = %{state | store: store}

      pending_subs =
        staged_rev
        |> Enum.flat_map(& &1.submissions)
        |> Map.new(&{&1.request_id, &1})

      {orig_sub_writes, state} =
        Enum.reduce(withdrawn_items, {[], state}, fn item, {acc_w, acc_st} ->
          orig_req_id = Map.get(item, "request_id")

          case Submissions.lookup_with_pending(acc_st, orig_req_id, pending_subs) do
            {:ok, orig_sub, next_st} ->
              withdrawn_orig = Submission.mark_withdrawn(orig_sub, now)
              next_st = Submissions.cache(next_st, [withdrawn_orig], withdrawn_orig.seq)
              {acc_w ++ [{:put_submission, withdrawn_orig}], next_st}

            {:not_found, next_st} ->
              {acc_w, next_st}
          end
        end)

      sub =
        Submission.new(%{
          id: sub_id,
          request_id: req_id,
          fingerprint: fp,
          kind: "withdraw",
          status: "done",
          conversation_id: cid,
          withdrawn: withdrawn_items,
          created_at: now
        })

      state = State.put_doc(state, cid, "inbox", remaining_inbox)

      writes =
        [{:check, {:unique_request_id, req_id, fp}}] ++
          orig_sub_writes ++
          [
            {:put_submission, sub},
            {:put_doc, {:conversation, cid, "inbox"}, Document.wrap("inbox", remaining_inbox)}
          ]

      staged = %{
        raw_item:
          {:command, from,
           %{command: "withdraw", conversation_id: cid, request_id: req_id, args: args}},
        writes: writes,
        conv_events: %{
          cid => %{entries: [], doc_ops: %{"inbox" => [["replace", remaining_inbox]]}}
        },
        submissions: [sub],
        effects: [],
        reply_from: from,
        receipt: Submission.to_receipt(sub, state.seq)
      }

      {:batch, staged, state}
    end
  end

  defp stage_rename(from, cid, req_id, fp, args, state) do
    expected_seq = Map.get(args, :expected_seq)

    if not is_nil(expected_seq) and expected_seq not in [state.seq, state.idle_resume_seq] do
      {:immediate, from, {:error, {:conflict, "expected_seq mismatch"}}, [], state}
    else
      now = System.system_time(:millisecond)
      {:ok, sub_id, store} = Storage.mint_id(state.store)
      state = %{state | store: store}

      next_title = Map.get(args, :title)

      next_meta =
        state.session_meta
        |> Map.put(:title, next_title)
        |> Map.put(:title_explicit, true)

      state = %{state | session_meta: next_meta}

      sub =
        Submission.new(%{
          id: sub_id,
          request_id: req_id,
          fingerprint: fp,
          kind: "rename",
          status: "done",
          conversation_id: cid,
          title: next_title,
          created_at: now
        })

      writes = [
        {:check, {:unique_request_id, req_id, fp}},
        {:put_session_meta, next_meta},
        {:put_submission, sub}
      ]

      staged = %{
        raw_item:
          {:command, from,
           %{command: "rename", conversation_id: cid, request_id: req_id, args: args}},
        writes: writes,
        conv_events: %{cid => %{entries: [], doc_ops: %{}}},
        submissions: [sub],
        effects: [],
        reply_from: from,
        receipt: Submission.to_receipt(sub, state.seq)
      }

      {:batch, staged, state}
    end
  end

  defp stage_compact(from, cid, req_id, fp, args, state) do
    expected_seq = Map.get(args, :expected_seq)
    conv_seq = Map.get(state.conv_last_seq, cid, state.seq)
    inbox = get_in(state.docs, [cid, "inbox"]) || []

    cond do
      not (is_integer(expected_seq) and expected_seq >= 0) ->
        {:immediate, from,
         {:error, {:bad_request, "expected_seq must be a non-negative integer"}}, [], state}

      expected_seq not in [conv_seq, state.seq, state.idle_resume_seq] ->
        {:immediate, from, {:error, {:conflict, "expected_seq mismatch"}}, [], state}

      State.conversation_busy?(state, cid) or inbox != [] ->
        {:immediate, from, {:error, {:conflict, "conversation_busy"}}, [], state}

      true ->
        {:ok, entries, state} = State.load_visible_entries(state, cid)

        prep_opts = [
          keep_recent_chars: state.compaction_keep_recent_chars,
          max_tokens: state.compaction_max_tokens
        ]

        case Compaction.prepare(entries, prep_opts) do
          {:error, reason} ->
            {:immediate, from, {:error, {:conflict, Atom.to_string(reason)}}, [], state}

          {:ok, prep} ->
            now = System.system_time(:millisecond)
            {:ok, sub_id, store} = Storage.mint_id(state.store)
            {:ok, task_id, store} = Storage.mint_id(store)
            state = %{state | store: store}

            instructions = Map.get(args, :instructions)

            sub =
              Submission.new(%{
                id: sub_id,
                request_id: req_id,
                fingerprint: fp,
                kind: "compact",
                status: "placed",
                conversation_id: cid,
                created_at: now
              })

            task =
              Task.new(%{
                id: task_id,
                kind: "compaction",
                owner: {:conversation, cid},
                status: "pending",
                checkpoint: %{
                  "conversation_id" => cid,
                  "kept_from_id" => prep.kept_from_id,
                  "instructions" => instructions,
                  "max_tokens" => prep.max_tokens,
                  "retry_count" => 0,
                  "phase" => "summarize",
                  "submission_ids" => [sub_id]
                },
                created_at: now
              })

            next_live = %{
              "compaction" => %{
                "task_id" => to_string(task_id),
                "kept_from_id" => prep.kept_from_id,
                "status" => "pending"
              }
            }

            state =
              state
              |> State.put_task(task)
              |> State.put_doc(cid, "live", next_live)

            writes = [
              {:check, {:unique_request_id, req_id, fp}},
              {:put_submission, sub},
              {:put_task, task},
              {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
            ]

            staged = %{
              raw_item:
                {:command, from,
                 %{command: "compact", conversation_id: cid, request_id: req_id, args: args}},
              writes: writes,
              conv_events: %{
                cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}
              },
              submissions: [sub],
              effects: [{:spawn_compaction, cid, task_id}],
              reply_from: from,
              receipt: Submission.to_receipt(sub, state.seq)
            }

            {:batch, staged, state}
        end
    end
  end

  defp maybe_drain_inbox_after_user_shell(tid, staged, state) do
    task = Map.get(state.tasks, tid)
    cid = task && task.checkpoint["conversation_id"]
    inbox = (cid && get_in(state.docs, [cid, "inbox"])) || []

    if is_nil(task) or task.cancelled == true or inbox == [] do
      {:batch, staged, state}
    else
      now = System.system_time(:millisecond)

      {drained_entries, drained_sub_writes, next_sub_ids, inbox_ops, state} =
        Submissions.drain_inbox(cid, state, now, nil)

      {next_gen, next_live, state} =
        Submissions.start_pending_generation(cid, next_sub_ids, state, now)

      base_writes =
        Enum.reject(staged.writes, fn
          {:put_doc, {:conversation, ^cid, "live"}, _} -> true
          _ -> false
        end)

      next_writes =
        base_writes ++
          Enum.map(drained_entries, &{:append_entry, &1}) ++
          drained_sub_writes ++
          [
            {:put_task, next_gen},
            {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)},
            {:put_doc, {:conversation, cid, "inbox"}, Document.wrap("inbox", [])}
          ]

      prev_ev = Map.get(staged.conv_events, cid, %{entries: [], doc_ops: %{}})

      next_doc_ops =
        prev_ev.doc_ops
        |> Map.put("live", [["replace", next_live]])
        |> Map.put("inbox", inbox_ops)

      next_staged = %{
        staged
        | writes: next_writes,
          conv_events:
            Map.put(staged.conv_events, cid, %{
              entries: prev_ev.entries ++ drained_entries,
              doc_ops: next_doc_ops
            }),
          effects: staged.effects ++ [{:spawn_generation, cid, next_gen.id}]
      }

      {:batch, next_staged, state}
    end
  end
end
