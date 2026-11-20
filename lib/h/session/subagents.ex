defmodule H.Session.Subagents do
  @moduledoc """
  Coordinator-managed subagent delegation lifecycle for `H.Session.Server`.

  Persists idempotent child intent (`memos`) and `"waiting"` state before
  calling `H.Daemon`, dispatches child sessions and submissions outside storage
  commits, holds zero `Task.Supervisor` workers while parked, wakes on
  `{:submission_settled, outcome}`, and recovers idempotently across crashes
  and VM restarts.
  """

  alias H.{Catalog, Daemon, Document, Storage, Task}
  alias H.Session.Server.{State, Stream, Tools}

  @max_answer_bytes 32_768
  @read_only_tools ["read", "search_history"]

  @doc """
  Validates semantic arguments for a `"subagent"` tool call and dispatches or
  parks it according to `mode` (`"wait"`, `"start"`, `"await"`, `"steer"`, `"abort"`).
  """
  def spawn_or_dispatch(cid, tool_task, validated_args, state, apply_effects_fn) do
    now = System.system_time(:millisecond)
    mode = Map.get(validated_args, "mode") || "wait"
    prompt = Map.get(validated_args, "prompt")
    target_sid = Map.get(validated_args, "session_id")

    with :ok <- validate_mode_args(mode, prompt, target_sid, validated_args),
         {:ok, target_entry} <- resolve_target_and_guards(mode, target_sid, state) do
      case mode do
        "wait" ->
          dispatch_wait(
            cid,
            tool_task,
            validated_args,
            target_entry,
            state,
            now,
            apply_effects_fn
          )

        "start" ->
          dispatch_start(
            cid,
            tool_task,
            validated_args,
            target_entry,
            state,
            now,
            apply_effects_fn
          )

        "await" ->
          dispatch_await(
            cid,
            tool_task,
            validated_args,
            target_entry,
            state,
            now,
            apply_effects_fn
          )

        "steer" ->
          dispatch_steer(
            cid,
            tool_task,
            validated_args,
            target_entry,
            state,
            now,
            apply_effects_fn
          )

        "abort" ->
          dispatch_abort(
            cid,
            tool_task,
            validated_args,
            target_entry,
            state,
            now,
            apply_effects_fn
          )
      end
    else
      {:error, diagnostic, message} ->
        commit_tool_result(
          cid,
          tool_task,
          %{
            content: [%{"type" => "text", "text" => message}],
            details: %{"diagnostic" => diagnostic, "mode" => mode},
            is_error: true,
            diagnostic: diagnostic
          },
          state,
          now,
          apply_effects_fn
        )
    end
  end

  @doc """
  Re-attaches and re-watches a parked `"waiting"` subagent tool task after
  coordinator crash or VM restart.
  """
  def resume_waiting(_cid, tool_task_id, state) do
    case Map.get(state.tasks, tool_task_id) do
      %{kind: "tool_call", status: "waiting", memos: memos} = tool_task when is_map(memos) ->
        mode = memos["mode"]
        child_sid = memos["child_session_id"]
        child_req_id = memos["child_request_id"]

        cond do
          not (is_binary(child_sid) and is_binary(child_req_id)) ->
            send(self(), {:subagent_failed, tool_task.id, :invalid_subagent_memo})
            state

          mode == "wait" ->
            dispatch_and_watch(tool_task, state)

          mode == "await" ->
            watch_and_track(child_sid, child_req_id, tool_task.id, state)

          true ->
            state
        end

      _ ->
        state
    end
  end

  @doc """
  Stages settlement for a waiting `"subagent"` tool task when
  `{:submission_settled, outcome}` arrives.
  """
  def stage_settled(outcome, state) when is_map(outcome) do
    child_sid = Map.get(outcome, :session_id)
    child_req_id = Map.get(outcome, :request_id)

    matching =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn t ->
        t.kind == "tool_call" and t.status == "waiting" and
          t.checkpoint["name"] == "subagent" and
          t.memos["child_session_id"] == child_sid and
          t.memos["child_request_id"] == child_req_id
      end)
      |> Enum.sort_by(& &1.id)

    case matching do
      [] ->
        {:skip, state}

      [tool_task | remaining] ->
        now = System.system_time(:millisecond)
        cid = tool_task.checkpoint["conversation_id"]
        call_id = tool_task.checkpoint["call_id"]
        memos = tool_task.memos || %{}

        state = remove_watch(state, child_sid, child_req_id, tool_task.id)

        unwatch_effects =
          if remaining == [] do
            [{:unwatch_subagent, child_sid, child_req_id}]
          else
            send(self(), {:submission_settled, outcome})
            []
          end

        {is_error, diagnostic, text, details} = build_settled_payload(outcome, memos)

        {:ok, entry_id, store} = Storage.mint_id(state.store)
        state = %{state | store: store}

        duration_ms =
          if is_integer(tool_task.started_at),
            do: max(0, now - tool_task.started_at),
            else: 0

        entry_data = %{
          "tool_call_id" => call_id,
          "name" => "subagent",
          "content" => [%{"type" => "text", "text" => text}],
          "details" => details,
          "is_error" => is_error,
          "diagnostic" => diagnostic,
          "duration_ms" => duration_ms
        }

        entry = State.build_entry(entry_id, cid, "tool_result", entry_data, now)
        state = State.record_entry(state, cid, entry_id)

        done_task =
          Task.complete(
            tool_task,
            %{"entry_id" => entry_id, "is_error" => is_error, "diagnostic" => diagnostic},
            now
          )

        live = State.put_tool_status(state.docs[cid]["live"], call_id, "done")
        state = state |> State.put_task(done_task) |> State.put_doc(cid, "live", live)

        Tools.stage_after_tool_settled(cid, done_task, entry, live, state, now, unwatch_effects)
    end
  end

  @doc """
  Stages an error tool result when subagent dispatch, attach, or watch fails.
  """
  def stage_failed(tool_task_id, reason, state) do
    case Map.get(state.tasks, tool_task_id) do
      %{kind: "tool_call", status: status} = tool_task
      when status in ["waiting", "running", "pending"] ->
        now = System.system_time(:millisecond)
        cid = tool_task.checkpoint["conversation_id"]
        call_id = tool_task.checkpoint["call_id"]
        memos = tool_task.memos || %{}
        child_sid = memos["child_session_id"]
        child_req_id = memos["child_request_id"]

        state =
          if is_binary(child_sid) and is_binary(child_req_id),
            do: remove_watch(state, child_sid, child_req_id, tool_task.id),
            else: state

        unwatch_effects =
          if is_binary(child_sid) and is_binary(child_req_id),
            do: [{:unwatch_subagent, child_sid, child_req_id}],
            else: []

        diagnostic = format_diagnostic(reason)
        message = format_error_message(child_sid, reason)

        {:ok, entry_id, store} = Storage.mint_id(state.store)
        state = %{state | store: store}

        entry_data = %{
          "tool_call_id" => call_id,
          "name" => "subagent",
          "content" => [%{"type" => "text", "text" => message}],
          "details" =>
            %{
              "child_session_id" => child_sid,
              "request_id" => child_req_id,
              "mode" => memos["mode"],
              "diagnostic" => diagnostic
            }
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Map.new(),
          "is_error" => true,
          "diagnostic" => diagnostic
        }

        entry = State.build_entry(entry_id, cid, "tool_result", entry_data, now)
        state = State.record_entry(state, cid, entry_id)

        done_task =
          Task.complete(
            tool_task,
            %{"entry_id" => entry_id, "is_error" => true, "diagnostic" => diagnostic},
            now
          )

        live = State.put_tool_status(state.docs[cid]["live"], call_id, "done")
        state = state |> State.put_task(done_task) |> State.put_doc(cid, "live", live)

        Tools.stage_after_tool_settled(cid, done_task, entry, live, state, now, unwatch_effects)

      _ ->
        {:skip, state}
    end
  end

  @doc """
  Removes watch tracking for `{child_sid, child_req_id}` from coordinator state.
  """
  def remove_watch(state, child_sid, child_req_id, task_id) do
    watches = Map.get(state, :subagent_watches, %{})
    key = {child_sid, child_req_id}

    next_watches =
      case Map.get(watches, key) do
        nil ->
          watches

        set ->
          reduced = MapSet.delete(set, task_id)

          if MapSet.size(reduced) == 0,
            do: Map.delete(watches, key),
            else: Map.put(watches, key, reduced)
      end

    %{state | subagent_watches: next_watches}
  end

  @doc """
  Unregisters `self()` from PubSub submission settlement for `{child_sid, child_req_id}`.
  """
  def unwatch(child_sid, child_req_id, state) do
    if is_binary(child_sid) and is_binary(child_req_id) do
      key = {child_sid, child_req_id}
      remaining = get_in(state, [:subagent_watches, key])

      if is_nil(remaining) or MapSet.size(remaining) == 0 do
        Daemon.unwatch_submission(child_sid, child_req_id, child_daemon_opts(state))
      end
    end

    state
  end

  @doc """
  Propagates a parent conversation abort to an owned child session.
  """
  def abort_child(child_sid, child_cid, reason, state) do
    req_id = "abort:#{state.session_id}:#{System.unique_integer([:positive])}"
    abort_reason = if is_binary(reason) and reason != "", do: reason, else: "parent_aborted"

    envelope = %{
      "version" => 1,
      "request_id" => req_id,
      "conversation_id" => to_string(child_cid || 1),
      "command" => "abort",
      "args" => %{"reason" => abort_reason}
    }

    try do
      _ = Daemon.execute_command(child_sid, envelope, child_daemon_opts(state))
    catch
      :exit, _ -> :ok
    end

    state
  end

  @doc """
  Builds `H.Daemon` options targeting the same isolated runtime/catalog/provider
  as the parent session.
  """
  def child_daemon_opts(state) do
    base =
      state
      |> Map.get(:daemon_opts, [])
      |> Keyword.put_new(:registry, state.registry)
      |> Keyword.put_new(:pubsub, state.pubsub)
      |> Keyword.put_new(:catalog, state.catalog)
      |> Keyword.put_new(:catalog_table, Map.get(state, :catalog_table, :h_catalog))
      |> Keyword.put_new(:workspace_lease, state.workspace_lease)
      |> Keyword.put_new(:runtime_sup, Map.get(state, :runtime_sup, H.Session.RuntimeSupervisor))
      |> Keyword.put_new(:provider, state.provider_mod)
      |> Keyword.put_new(:provider_config, state.provider_config)
      |> Keyword.put_new(:default_model, state.default_model)
      |> Keyword.put_new(:max_subagent_depth, Map.get(state, :max_subagent_depth, 1))
      |> Keyword.put(:internal_dispatch, true)
      |> Keyword.put(:parent_verified, true)

    {explicit_tools, base} = Keyword.pop(base, :explicit_tools)

    if is_list(explicit_tools) do
      child_depth = parent_depth(state) + 1
      max_depth = Map.get(state, :max_subagent_depth, 1)

      filtered =
        if child_depth >= max_depth do
          Enum.reject(explicit_tools, &(&1 == H.Tools.Subagent))
        else
          explicit_tools
        end

      Keyword.put(base, :tools, filtered)
    else
      base
    end
  end

  # Mode handlers

  defp dispatch_wait(cid, tool_task, validated_args, target_entry, state, now, _apply_effects_fn) do
    spawning_new? = is_nil(target_entry)

    child_sid =
      if target_entry,
        do: target_entry.session_id,
        else: mint_child_session_id(state.session_id, tool_task.id)

    child_req_id = "sub:#{state.session_id}:#{tool_task.id}"
    child_cwd = validated_args["cwd"] || if(target_entry, do: target_entry.cwd, else: state.cwd)
    agent = state.docs[cid]["agent"] || %{}
    child_model = validated_args["model"] || agent["model"]
    child_thinking = validated_args["thinking"] || agent["thinking"]
    read_only? = validated_args["read_only"] == true
    title = validated_args["title"]
    at_entry_id = tool_task.checkpoint["assistant_entry_id"]

    memos = %{
      "mode" => "wait",
      "spawning_new" => spawning_new?,
      "child_session_id" => child_sid,
      "child_conversation_id" => 1,
      "child_request_id" => child_req_id,
      "at_entry_id" => at_entry_id,
      "cwd" => child_cwd,
      "model" => child_model,
      "thinking" => child_thinking,
      "read_only" => read_only?,
      "title" => title,
      "prompt" => validated_args["prompt"]
    }

    waiting_task = %{
      Task.start_waiting(tool_task, now, %{"phase" => "waiting", "replay" => "unsafe"})
      | memos: memos,
        wake: %{
          "on" => "submission_settled",
          "session_id" => child_sid,
          "request_id" => child_req_id
        },
        started_at: tool_task.started_at || now
    }

    case commit_waiting_tool(cid, waiting_task, child_sid, "wait", state) do
      {:ok, state} -> dispatch_and_watch(waiting_task, state)
      {:error, state} -> state
    end
  end

  defp dispatch_await(cid, tool_task, validated_args, target_entry, state, now, apply_effects_fn) do
    child_sid = target_entry.session_id

    child_req_id =
      Map.get(validated_args, "request_id") || latest_tracked_request_id(state, child_sid)

    if is_nil(child_req_id) do
      commit_tool_result(
        cid,
        tool_task,
        %{
          content: [
            %{
              "type" => "text",
              "text" =>
                "No tracked submission request_id found for child session #{child_sid}; pass request_id explicitly."
            }
          ],
          details: %{
            "child_session_id" => child_sid,
            "mode" => "await",
            "diagnostic" => "missing_request_id"
          },
          is_error: true,
          diagnostic: "missing_request_id"
        },
        state,
        now,
        apply_effects_fn
      )
    else
      memos = %{
        "mode" => "await",
        "spawning_new" => false,
        "child_session_id" => child_sid,
        "child_conversation_id" => 1,
        "child_request_id" => child_req_id,
        "at_entry_id" => tool_task.checkpoint["assistant_entry_id"],
        "cwd" => target_entry.cwd
      }

      waiting_task = %{
        Task.start_waiting(tool_task, now, %{"phase" => "waiting", "replay" => "unsafe"})
        | memos: memos,
          wake: %{
            "on" => "submission_settled",
            "session_id" => child_sid,
            "request_id" => child_req_id
          },
          started_at: tool_task.started_at || now
      }

      case commit_waiting_tool(cid, waiting_task, child_sid, "await", state) do
        {:ok, state} -> watch_and_track(child_sid, child_req_id, waiting_task.id, state)
        {:error, state} -> state
      end
    end
  end

  defp dispatch_start(cid, tool_task, validated_args, target_entry, state, now, apply_effects_fn) do
    spawning_new? = is_nil(target_entry)

    child_sid =
      if target_entry,
        do: target_entry.session_id,
        else: mint_child_session_id(state.session_id, tool_task.id)

    child_req_id = "sub:#{state.session_id}:#{tool_task.id}"
    child_cwd = validated_args["cwd"] || if(target_entry, do: target_entry.cwd, else: state.cwd)
    agent = state.docs[cid]["agent"] || %{}
    child_model = validated_args["model"] || agent["model"]
    child_thinking = validated_args["thinking"] || agent["thinking"]
    read_only? = validated_args["read_only"] == true
    title = validated_args["title"]
    at_entry_id = tool_task.checkpoint["assistant_entry_id"]

    memos = %{
      "mode" => "start",
      "spawning_new" => spawning_new?,
      "child_session_id" => child_sid,
      "child_conversation_id" => 1,
      "child_request_id" => child_req_id,
      "at_entry_id" => at_entry_id,
      "cwd" => child_cwd,
      "model" => child_model,
      "thinking" => child_thinking,
      "read_only" => read_only?,
      "title" => title,
      "prompt" => validated_args["prompt"]
    }

    case commit_running_intent(cid, tool_task, memos, now, state) do
      {:error, state} ->
        state

      {:ok, running_task, state} ->
        child_opts = child_daemon_opts(state)

        with :ok <- maybe_create_child_session(cid, running_task, child_opts, state),
             {:ok, receipt} <-
               submit_child_input(
                 child_sid,
                 1,
                 child_req_id,
                 memos["prompt"],
                 "follow_up",
                 "start",
                 child_opts
               ) do
          commit_tool_result(
            cid,
            running_task,
            %{
              content: [
                %{
                  "type" => "text",
                  "text" =>
                    "Started subagent #{child_sid} (request_id: #{child_req_id}, status: #{receipt.status})."
                }
              ],
              details: %{
                "child_session_id" => child_sid,
                "child_conversation_id" => "1",
                "request_id" => child_req_id,
                "submission_id" => to_string(receipt.submission_id),
                "status" => receipt.status,
                "mode" => "start",
                "cwd" => child_cwd,
                "model" => child_model,
                "read_only" => read_only?
              },
              is_error: false,
              diagnostic: nil
            },
            state,
            System.system_time(:millisecond),
            apply_effects_fn
          )
        else
          {:error, reason} ->
            diagnostic = format_diagnostic(reason)

            commit_tool_result(
              cid,
              running_task,
              %{
                content: [%{"type" => "text", "text" => format_error_message(child_sid, reason)}],
                details: %{
                  "child_session_id" => child_sid,
                  "request_id" => child_req_id,
                  "mode" => "start",
                  "diagnostic" => diagnostic
                },
                is_error: true,
                diagnostic: diagnostic
              },
              state,
              System.system_time(:millisecond),
              apply_effects_fn
            )
        end
    end
  end

  defp dispatch_steer(cid, tool_task, validated_args, target_entry, state, now, apply_effects_fn) do
    child_sid = target_entry.session_id
    child_req_id = "sub:#{state.session_id}:#{tool_task.id}"
    prompt = validated_args["prompt"]

    memos = %{
      "mode" => "steer",
      "spawning_new" => false,
      "child_session_id" => child_sid,
      "child_conversation_id" => 1,
      "child_request_id" => child_req_id,
      "prompt" => prompt
    }

    case commit_running_intent(cid, tool_task, memos, now, state) do
      {:error, state} ->
        state

      {:ok, running_task, state} ->
        child_opts = child_daemon_opts(state)

        case submit_child_input(child_sid, 1, child_req_id, prompt, "steer", "reject", child_opts) do
          {:ok, receipt} ->
            commit_tool_result(
              cid,
              running_task,
              %{
                content: [
                  %{
                    "type" => "text",
                    "text" =>
                      "Steered subagent #{child_sid} (request_id: #{child_req_id}, status: #{receipt.status})."
                  }
                ],
                details: %{
                  "child_session_id" => child_sid,
                  "child_conversation_id" => "1",
                  "request_id" => child_req_id,
                  "submission_id" => to_string(receipt.submission_id),
                  "status" => "steered",
                  "queue_status" => receipt.status,
                  "mode" => "steer"
                },
                is_error: false,
                diagnostic: nil
              },
              state,
              System.system_time(:millisecond),
              apply_effects_fn
            )

          {:error, {:conflict, "conversation_idle"}} ->
            commit_tool_result(
              cid,
              running_task,
              %{
                content: [
                  %{
                    "type" => "text",
                    "text" =>
                      "Subagent #{child_sid} is currently idle; use mode \"wait\" or \"start\" to send a follow-up turn."
                  }
                ],
                details: %{
                  "child_session_id" => child_sid,
                  "request_id" => child_req_id,
                  "mode" => "steer",
                  "diagnostic" => "conversation_idle"
                },
                is_error: true,
                diagnostic: "conversation_idle"
              },
              state,
              System.system_time(:millisecond),
              apply_effects_fn
            )

          {:error, reason} ->
            diagnostic = format_diagnostic(reason)

            commit_tool_result(
              cid,
              running_task,
              %{
                content: [%{"type" => "text", "text" => format_error_message(child_sid, reason)}],
                details: %{
                  "child_session_id" => child_sid,
                  "request_id" => child_req_id,
                  "mode" => "steer",
                  "diagnostic" => diagnostic
                },
                is_error: true,
                diagnostic: diagnostic
              },
              state,
              System.system_time(:millisecond),
              apply_effects_fn
            )
        end
    end
  end

  defp dispatch_abort(cid, tool_task, validated_args, target_entry, state, now, apply_effects_fn) do
    child_sid = target_entry.session_id
    child_req_id = "sub:#{state.session_id}:#{tool_task.id}"
    reason = validated_args["reason"] || "aborted_by_parent"

    memos = %{
      "mode" => "abort",
      "spawning_new" => false,
      "child_session_id" => child_sid,
      "child_conversation_id" => 1,
      "child_request_id" => child_req_id,
      "reason" => reason
    }

    case commit_running_intent(cid, tool_task, memos, now, state) do
      {:error, state} ->
        state

      {:ok, running_task, state} ->
        child_opts = child_daemon_opts(state)

        envelope = %{
          "version" => 1,
          "request_id" => child_req_id,
          "conversation_id" => "1",
          "command" => "abort",
          "args" => %{"reason" => reason}
        }

        case Daemon.execute_command(child_sid, envelope, child_opts) do
          {:ok, _receipt} ->
            commit_tool_result(
              cid,
              running_task,
              %{
                content: [
                  %{
                    "type" => "text",
                    "text" => "Aborted subagent #{child_sid} (reason: #{reason})."
                  }
                ],
                details: %{
                  "child_session_id" => child_sid,
                  "child_conversation_id" => "1",
                  "request_id" => child_req_id,
                  "status" => "aborted",
                  "reason" => reason,
                  "mode" => "abort"
                },
                is_error: false,
                diagnostic: nil
              },
              state,
              System.system_time(:millisecond),
              apply_effects_fn
            )

          {:error, err} ->
            diagnostic = format_diagnostic(err)

            commit_tool_result(
              cid,
              running_task,
              %{
                content: [%{"type" => "text", "text" => format_error_message(child_sid, err)}],
                details: %{
                  "child_session_id" => child_sid,
                  "request_id" => child_req_id,
                  "mode" => "abort",
                  "diagnostic" => diagnostic
                },
                is_error: true,
                diagnostic: diagnostic
              },
              state,
              System.system_time(:millisecond),
              apply_effects_fn
            )
        end
    end
  end

  # Dispatch, watch, and persistence helpers

  defp dispatch_and_watch(tool_task, state) do
    cid = tool_task.checkpoint["conversation_id"]
    memos = tool_task.memos
    child_sid = memos["child_session_id"]
    child_cid = memos["child_conversation_id"] || 1
    child_req_id = memos["child_request_id"]
    child_opts = child_daemon_opts(state)

    with :ok <- maybe_create_child_session(cid, tool_task, child_opts, state),
         {:ok, _receipt} <-
           submit_child_input(
             child_sid,
             child_cid,
             child_req_id,
             memos["prompt"],
             "follow_up",
             "start",
             child_opts
           ) do
      watch_and_track(child_sid, child_req_id, tool_task.id, state)
    else
      {:error, reason} ->
        send(self(), {:subagent_failed, tool_task.id, reason})
        state
    end
  end

  defp watch_and_track(child_sid, child_req_id, task_id, state) do
    child_opts = child_daemon_opts(state)

    case Daemon.watch_submission(child_sid, child_req_id, self(), child_opts) do
      {:ok, {:settled, outcome}} ->
        send(self(), {:submission_settled, outcome})
        state

      {:ok, {:pending, _summary}} ->
        watches = Map.get(state, :subagent_watches, %{})
        key = {child_sid, child_req_id}
        updated = Map.update(watches, key, MapSet.new([task_id]), &MapSet.put(&1, task_id))
        %{state | subagent_watches: updated}

      {:error, reason} ->
        send(self(), {:subagent_failed, task_id, reason})
        state
    end
  end

  defp maybe_create_child_session(cid, tool_task, child_opts, state) do
    memos = tool_task.memos

    if memos["spawning_new"] do
      child_agent =
        %{}
        |> maybe_put("model", memos["model"])
        |> maybe_put("thinking", memos["thinking"])
        |> then(fn m ->
          if memos["read_only"] == true, do: Map.put(m, "tools", @read_only_tools), else: m
        end)

      parent_param =
        %{
          "session_id" => state.session_id,
          "conversation_id" => to_string(cid),
          "task_id" => to_string(tool_task.id)
        }
        |> maybe_put("at_entry_id", if(memos["at_entry_id"], do: to_string(memos["at_entry_id"])))

      create_params =
        %{
          "session_id" => memos["child_session_id"],
          "env_id" => state.env_id,
          "cwd" => memos["cwd"] || state.cwd,
          "role" => "subagent",
          "parent" => parent_param
        }
        |> maybe_put("title", memos["title"])
        |> then(fn m ->
          if map_size(child_agent) > 0, do: Map.put(m, "agent", child_agent), else: m
        end)

      case Daemon.create_session(create_params, child_opts) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp submit_child_input(
         child_sid,
         child_cid,
         child_req_id,
         prompt,
         when_busy,
         when_idle,
         child_opts
       ) do
    envelope = %{
      "version" => 1,
      "request_id" => child_req_id,
      "conversation_id" => to_string(child_cid),
      "command" => "submit",
      "args" => %{
        "type" => "input",
        "content" => prompt,
        "when_busy" => when_busy,
        "when_idle" => when_idle
      }
    }

    Daemon.execute_command(child_sid, envelope, child_opts)
  end

  defp commit_waiting_tool(cid, waiting_task, child_sid, mode, state) do
    call_id = waiting_task.checkpoint["call_id"]
    live = put_subagent_live(state.docs[cid]["live"], call_id, "waiting", child_sid, mode)

    state =
      state
      |> State.put_task(waiting_task)
      |> State.put_doc(cid, "live", live)

    case Storage.commit(state.store, [
           [
             {:put_task, waiting_task},
             {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", live)}
           ]
         ]) do
      {:ok, %{seqs: [batch_seq]}, committed_store} ->
        state = %{state | store: committed_store, seq: batch_seq}

        state =
          Stream.broadcast_commit_frame(state, cid, batch_seq, [], %{
            "live" => [["set", ["tools", call_id], get_in(live, ["tools", call_id])]]
          })

        {:ok, state}

      {:error, io_err} ->
        send(self(), {:stop_storage_failed, io_err})
        {:error, %{state | storage_failed: true}}
    end
  end

  defp commit_running_intent(cid, tool_task, memos, now, state) do
    {:ok, attempt_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}
    call_id = tool_task.checkpoint["call_id"]

    running_task = %{
      Task.start_running(tool_task, attempt_id, now, %{
        "phase" => "dispatch",
        "replay" => "unsafe"
      })
      | memos: memos
    }

    live =
      put_subagent_live(
        state.docs[cid]["live"],
        call_id,
        "running",
        memos["child_session_id"],
        memos["mode"]
      )

    state =
      state
      |> State.put_task(running_task)
      |> State.put_doc(cid, "live", live)

    case Storage.commit(state.store, [
           [
             {:put_task, running_task},
             {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", live)}
           ]
         ]) do
      {:ok, %{seqs: [batch_seq]}, committed_store} ->
        state = %{state | store: committed_store, seq: batch_seq}

        state =
          Stream.broadcast_commit_frame(state, cid, batch_seq, [], %{
            "live" => [["set", ["tools", call_id], get_in(live, ["tools", call_id])]]
          })

        {:ok, running_task, state}

      {:error, io_err} ->
        send(self(), {:stop_storage_failed, io_err})
        {:error, %{state | storage_failed: true}}
    end
  end

  defp commit_tool_result(cid, tool_task, out_map, state, now, apply_effects_fn) do
    call_id = tool_task.checkpoint["call_id"]
    {:ok, entry_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}

    entry_data = %{
      "tool_call_id" => call_id,
      "name" => "subagent",
      "content" => State.stringify_json(Map.get(out_map, :content, [])),
      "details" => State.stringify_json(Map.get(out_map, :details, %{})),
      "is_error" => Map.get(out_map, :is_error, false) == true,
      "diagnostic" => Map.get(out_map, :diagnostic)
    }

    entry = State.build_entry(entry_id, cid, "tool_result", entry_data, now)
    state = State.record_entry(state, cid, entry_id)

    done_task =
      Task.complete(
        tool_task,
        %{
          "entry_id" => entry_id,
          "is_error" => entry_data["is_error"],
          "diagnostic" => entry_data["diagnostic"]
        },
        now
      )

    live = State.put_tool_status(state.docs[cid]["live"], call_id, "done")
    state = state |> State.put_task(done_task) |> State.put_doc(cid, "live", live)

    {:batch, staged, state} =
      Tools.stage_after_tool_settled(cid, done_task, entry, live, state, now, [])

    case Storage.commit(state.store, [staged.writes]) do
      {:ok, %{seqs: [batch_seq]}, committed_store} ->
        state =
          Stream.apply_committed_batches([staged], [batch_seq], %{state | store: committed_store})

        apply_effects_fn.(staged.effects, state)

      {:error, io_err} ->
        send(self(), {:stop_storage_failed, io_err})
        %{state | storage_failed: true}
    end
  end

  # Validation, payload formatting, and lookup helpers

  defp validate_mode_args(mode, prompt, target_sid, validated_args) do
    cond do
      mode in ["wait", "start", "steer"] and
          not (is_binary(prompt) and byte_size(String.trim(prompt)) > 0) ->
        {:error, "invalid_arguments", "prompt must be a non-empty string for mode #{mode}"}

      mode in ["await", "steer", "abort"] and not (is_binary(target_sid) and target_sid != "") ->
        {:error, "invalid_arguments", "session_id is required for mode #{mode}"}

      is_nil(target_sid) and is_binary(validated_args["cwd"]) and
          not String.starts_with?(validated_args["cwd"], "/") ->
        {:error, "invalid_arguments", "cwd must be an absolute path"}

      true ->
        :ok
    end
  end

  defp resolve_target_and_guards(_mode, nil, state) do
    depth = parent_depth(state)
    max_depth = Map.get(state, :max_subagent_depth, 1)

    if depth >= max_depth do
      {:error, "max_depth_exceeded",
       "Subagent depth limit exceeded (current depth #{depth}, max #{max_depth})."}
    else
      {:ok, nil}
    end
  end

  defp resolve_target_and_guards(_mode, target_sid, state) when is_binary(target_sid) do
    table = Map.get(state, :catalog_table, :h_catalog)

    case Catalog.get_session(target_sid, table) do
      {:error, :not_found} ->
        {:error, "child_not_found", "Child session not found: #{target_sid}"}

      {:ok, entry} ->
        cond do
          get_in(entry, [:parent, :session_id]) != state.session_id ->
            {:error, "forbidden_target",
             "Session #{target_sid} is not a direct child of #{state.session_id}."}

          entry.status == "quarantined" ->
            {:error, "child_quarantined",
             "Child session #{target_sid} is quarantined: #{entry.quarantine_reason || "quarantined"}"}

          true ->
            {:ok, entry}
        end
    end
  end

  defp latest_tracked_request_id(state, target_sid) do
    candidates =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn t ->
        t.kind == "tool_call" and t.checkpoint["name"] == "subagent" and
          t.memos["child_session_id"] == target_sid and
          is_binary(t.memos["child_request_id"]) and
          t.memos["mode"] in ["start", "wait", "steer"]
      end)
      |> Enum.sort_by(& &1.id, :desc)

    preferred =
      Enum.find(candidates, &(&1.memos["mode"] in ["start", "wait"])) || List.first(candidates)

    if preferred, do: preferred.memos["child_request_id"], else: nil
  end

  defp build_settled_payload(outcome, memos) do
    base_details = %{
      "child_session_id" => outcome.session_id,
      "child_conversation_id" => to_string(outcome.conversation_id),
      "request_id" => outcome.request_id,
      "submission_id" => to_string(outcome.submission_id),
      "answer_entry_id" =>
        if(outcome.answer_entry_id, do: to_string(outcome.answer_entry_id), else: nil),
      "status" => outcome.status,
      "cwd" => memos["cwd"],
      "model" => memos["model"],
      "read_only" => memos["read_only"] == true,
      "at_entry_id" => if(memos["at_entry_id"], do: to_string(memos["at_entry_id"]), else: nil)
    }

    if outcome.status == "done" do
      text = bound_answer_text(outcome.answer_text || "", outcome.session_id)
      {false, nil, text, base_details}
    else
      reason_str = outcome.reason || outcome.status
      text = "Subagent #{outcome.session_id} finished without answer (#{reason_str})."
      {true, reason_str, text, Map.put(base_details, "reason", outcome.reason)}
    end
  end

  defp bound_answer_text(text, child_sid) when is_binary(text) do
    if byte_size(text) <= @max_answer_bytes do
      text
    else
      truncate_utf8_bytes(text, @max_answer_bytes) <>
        "\n\n[Subagent output truncated — inspect full transcript in session #{child_sid}]"
    end
  end

  defp truncate_utf8_bytes(bin, max_bytes) do
    prefix = binary_part(bin, 0, min(byte_size(bin), max_bytes))
    drop_incomplete_utf8_tail(prefix)
  end

  defp drop_incomplete_utf8_tail(<<>>), do: <<>>

  defp drop_incomplete_utf8_tail(bin) do
    if String.valid?(bin) do
      bin
    else
      drop_incomplete_utf8_tail(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  defp put_subagent_live(live, call_id, status, child_sid, mode) do
    existing =
      get_in(live, ["tools", call_id]) ||
        %{"id" => call_id, "name" => "subagent", "output" => ""}

    updated_slot =
      existing
      |> Map.put("status", status)
      |> maybe_put("child_session_id", child_sid)
      |> maybe_put("mode", mode)

    tools = Map.get(live || %{}, "tools") || %{}
    Map.put(live || %{}, "tools", Map.put(tools, call_id, updated_slot))
  end

  defp mint_child_session_id(parent_sid, task_id) do
    suffix = "-sub-#{task_id}"
    max_prefix = 128 - byte_size(suffix)
    prefix = String.slice(parent_sid, 0, max_prefix)
    "#{prefix}#{suffix}"
  end

  defp parent_depth(state) do
    get_in(state, [:session_meta, :parent, :depth]) ||
      get_in(state, [:session_meta, :parent, "depth"]) || 0
  end

  defp format_diagnostic(:not_found), do: "child_not_found"
  defp format_diagnostic({:quarantined, _}), do: "child_quarantined"
  defp format_diagnostic({:bad_request, _}), do: "invalid_arguments"
  defp format_diagnostic({:conflict, msg}) when is_binary(msg), do: msg
  defp format_diagnostic(:daemon_draining), do: "daemon_draining"
  defp format_diagnostic(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp format_diagnostic(_), do: "subagent_error"

  defp format_error_message(child_sid, :not_found),
    do: "Subagent session #{child_sid || "unknown"} was not found."

  defp format_error_message(child_sid, {:quarantined, reason}),
    do: "Subagent session #{child_sid || "unknown"} is quarantined (#{reason})."

  defp format_error_message(_child_sid, {:bad_request, msg}),
    do: "Subagent request rejected: #{msg}"

  defp format_error_message(_child_sid, {:conflict, msg}), do: "Subagent conflict: #{msg}"

  defp format_error_message(child_sid, reason),
    do: "Subagent #{child_sid || "unknown"} failed: #{inspect(reason)}"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
