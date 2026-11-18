defmodule H.Session.UserShell do
  @moduledoc """
  Durable backend lifecycle for user-invoked shell commands (`!` / `!!`).

  Enforces `expected_seq` conflict guards, persists `"user_shell"` task intent
  before spawning workers on the bound `H.ExecutionEnv`, coordinates per-workspace
  mutating leases via `H.WorkspaceLease`, supports cooperative and immediate
  `abort_ref` cancellation, and never replays unsafe interrupted work across
  worker crashes or VM restarts.
  """

  require Logger

  alias H.{Document, ExecutionEnv, Schema, Storage, Submission, Task, WorkspaceLease}

  @default_timeout_ms 120_000
  @max_replay_ring 64
  @max_recent_submissions 256

  @doc "Validates external `user_shell` command arguments."
  @spec validate_args(term()) :: {:ok, map()} | {:error, String.t()}
  def validate_args(raw_args) do
    Schema.validate_map(raw_args, [
      {:command, :non_empty_string, required: true},
      {:include_in_context, :boolean, required: true},
      {:expected_seq, {:int, min: 0}, required: true}
    ])
  end

  @doc "Returns `true` if a `user_shell` or `generation` run is active in `cid`."
  @spec busy?(map(), pos_integer()) :: boolean()
  def busy?(state, cid) when is_map(state) and is_integer(cid) do
    live = get_in(state, [:docs, cid, "live"]) || %{}

    Map.get(live, "run") != nil or
      Map.get(live, "user_shell") != nil or
      Enum.any?(Map.get(state, :tasks, %{}), fn {_id, t} ->
        t.kind in ["generation", "user_shell"] and
          t.owner == {:conversation, cid} and
          t.status != "terminal"
      end)
  end

  @doc "Returns `true` for unsafe `user_shell` tasks that must never replay on recovery."
  @spec unsafe_task?(map()) :: boolean()
  def unsafe_task?(%{kind: "user_shell"}), do: true
  def unsafe_task?(_task), do: false

  @doc """
  Stages a `user_shell` command batch after verifying `expected_seq` and
  conversation idle state. Persists task intent (`status: "pending"`,
  `replay: "unsafe"`) before spawning.
  """
  @spec stage(
          term(),
          pos_integer(),
          String.t(),
          String.t(),
          map(),
          map(),
          integer()
        ) ::
          {:immediate, term(), {:error, term()}, [term()], map()}
          | {:batch, map(), map()}
  def stage(
        from,
        cid,
        req_id,
        fp,
        args,
        state,
        now \\ System.system_time(:millisecond)
      ) do
    expected_seq = Map.get(args, :expected_seq)
    conv_seq = Map.get(state.conv_last_seq, cid, state.seq)

    cond do
      not (is_integer(expected_seq) and expected_seq >= 0) ->
        {:immediate, from,
         {:error, {:bad_request, "expected_seq must be a non-negative integer"}}, [], state}

      expected_seq != conv_seq and expected_seq != state.seq ->
        {:immediate, from, {:error, {:conflict, "expected_seq mismatch"}}, [], state}

      busy?(state, cid) ->
        {:immediate, from, {:error, {:conflict, "conversation_busy"}}, [], state}

      true ->
        {:ok, sub_id, store} = Storage.mint_id(state.store)
        {:ok, task_id, store} = Storage.mint_id(store)
        state = %{state | store: store}

        command = args.command
        include_in_context = args.include_in_context == true

        sub =
          Submission.new(%{
            id: sub_id,
            request_id: req_id,
            fingerprint: fp,
            kind: "user_shell",
            status: "placed",
            conversation_id: cid,
            created_at: now
          })

        task =
          Task.new(%{
            id: task_id,
            kind: "user_shell",
            owner: {:conversation, cid},
            status: "pending",
            checkpoint: %{
              "conversation_id" => cid,
              "command" => command,
              "include_in_context" => include_in_context,
              "phase" => "pending",
              "replay" => "unsafe",
              "submission_ids" => [sub_id]
            },
            created_at: now
          })

        next_live = %{
          "user_shell" => %{
            "task_id" => to_string(task_id),
            "command" => command,
            "include_in_context" => include_in_context,
            "status" => "pending",
            "output" => ""
          }
        }

        state =
          state
          |> put_task(task)
          |> put_doc(cid, "live", next_live)

        writes = [
          {:check, {:unique_request_id, req_id, fp}},
          {:put_submission, sub},
          {:put_task, task},
          {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}
        ]

        staged = %{
          raw_item:
            {:command, from,
             %{command: "user_shell", conversation_id: cid, request_id: req_id, args: args}},
          writes: writes,
          conv_events: %{cid => %{entries: [], doc_ops: %{"live" => [["replace", next_live]]}}},
          submissions: [sub],
          effects: [{:spawn_user_shell, cid, task_id}],
          reply_from: from,
          receipt: Submission.to_receipt(sub, state.seq)
        }

        {:batch, staged, state}
    end
  end

  @doc """
  Acquires the workspace lease, persists `"running"` task state before spawning,
  and launches the supervised worker executing on `state.execution_env`.
  """
  @spec spawn_worker(pos_integer(), pos_integer(), map(), keyword()) :: map()
  def spawn_worker(cid, task_id, state, opts \\ []) do
    case Map.get(state.tasks, task_id) do
      %{kind: "user_shell", status: "pending"} = task ->
        now = System.system_time(:millisecond)
        cp = task.checkpoint
        command = cp["command"]

        case validate_bound_env(state.execution_env) do
          {:error, reason} ->
            commit_immediate_failure(
              cid,
              task,
              reason,
              "Bound execution environment is unavailable (#{reason}).",
              state,
              now
            )

          {:ok, env} ->
            case acquire_lease(cid, env, state) do
              {:error, {:workspace_busy, holder_key}} ->
                commit_immediate_failure(
                  cid,
                  task,
                  "workspace_busy",
                  "Workspace #{workspace_cwd(env, state)} is currently busy with mutating work by #{inspect(holder_key)}.",
                  state,
                  now
                )

              {:ok, state} ->
                {:ok, attempt_id, store} = Storage.mint_id(state.store)
                state = %{state | store: store}

                running_task =
                  Task.start_running(task, attempt_id, now, %{
                    "phase" => "execute",
                    "replay" => "unsafe"
                  })

                live = put_user_shell_status(state.docs[cid]["live"], "running")

                state =
                  state
                  |> put_task(running_task)
                  |> put_doc(cid, "live", live)

                case Storage.commit(state.store, [
                       [
                         {:put_task, running_task},
                         {:put_doc, {:conversation, cid, "live"}, Document.wrap("live", live)}
                       ]
                     ]) do
                  {:error, io_err} ->
                    Logger.error(
                      "Session #{state.session_id} user_shell intent commit failed: #{inspect(io_err)}"
                    )

                    state = release_lease(cid, env, state)
                    send(self(), {:stop_storage_failed, io_err})
                    %{state | storage_failed: true}

                  {:ok, %{seqs: [batch_seq]}, committed_store} ->
                    state = %{state | store: committed_store, seq: batch_seq}

                    state =
                      broadcast_commit_frame(state, cid, batch_seq, [], %{
                        "live" => [["set", ["user_shell", "status"], "running"]]
                      })

                    server_pid = self()
                    inc = state.incarnation
                    abort_ref = make_ref()

                    timeout_ms =
                      Keyword.get(
                        opts,
                        :timeout_ms,
                        Map.get(state, :user_shell_timeout_ms, @default_timeout_ms)
                      )

                    exec_opts =
                      [
                        timeout_ms: timeout_ms,
                        abort_ref: abort_ref,
                        session_id: state.session_id,
                        incarnation: inc,
                        task_id: task_id,
                        attempt_id: attempt_id,
                        on_output: fn chunk ->
                          send(
                            server_pid,
                            {:user_shell_output, inc, task_id, attempt_id, cid, chunk}
                          )
                        end
                      ]
                      |> maybe_put_kw(
                        :lease_ms,
                        Keyword.get(opts, :lease_ms, Map.get(state, :user_shell_lease_ms))
                      )

                    {:ok, worker_pid} =
                      Elixir.Task.Supervisor.start_child(state.task_sup, fn ->
                        t0 = System.monotonic_time(:millisecond)
                        res = ExecutionEnv.exec(env, {:shell, command}, exec_opts)
                        dur = max(0, System.monotonic_time(:millisecond) - t0)

                        send(
                          server_pid,
                          {:worker_done, inc, task_id, attempt_id, {:user_shell_result, dur, res}}
                        )
                      end)

                    ref = Process.monitor(worker_pid)

                    worker_info = %{
                      task_id: task_id,
                      conv_id: cid,
                      kind: :user_shell,
                      pid: worker_pid,
                      monitor_ref: ref,
                      abort_ref: abort_ref,
                      started_at: now
                    }

                    %{state | workers: Map.put(state.workers, attempt_id, worker_info)}
                end
            end
        end

      _ ->
        state
    end
  end

  @doc "Requests cooperative cancellation of an active `user_shell` worker via `abort_ref`."
  @spec cancel_worker(pos_integer(), map()) :: :ok | :not_found
  def cancel_worker(task_id, state) when is_map(state) do
    case Enum.find(state.workers, fn {_aid, w} ->
           w.task_id == task_id and w.kind == :user_shell
         end) do
      {_aid, %{pid: pid, abort_ref: abort_ref}} when is_pid(pid) and not is_nil(abort_ref) ->
        send(pid, {:abort_exec, abort_ref})
        :ok

      _ ->
        :not_found
    end
  end

  @doc "Buffers streamed `user_shell` output chunks into ephemeral `live` state."
  @spec handle_output(map(), pos_integer(), pos_integer(), term()) :: map()
  def handle_output(state, cid, _tid, chunk) when is_binary(chunk) and chunk != "" do
    eph = get_or_init_ephemeral(state, cid)
    prev_out = Map.get(eph, :user_shell_output) || user_shell_live_output(state, cid)
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

  def handle_output(state, _cid, _tid, _chunk), do: state

  @doc "Merges buffered ephemeral `user_shell` output into `live`."
  @spec merge_ephemeral(map(), map() | nil) :: map()
  def merge_ephemeral(live, nil), do: live

  def merge_ephemeral(%{"user_shell" => shell_live} = live, eph)
      when is_map(shell_live) and is_map(eph) do
    case Map.get(eph, :user_shell_output) do
      output when is_binary(output) ->
        put_in(live, ["user_shell", "output"], output)

      _ ->
        live
    end
  end

  def merge_ephemeral(live, _eph), do: live

  @doc "Stages completion of a `user_shell` worker result."
  @spec stage_done(
          pos_integer(),
          pos_integer(),
          {:user_shell_result, non_neg_integer(), term()},
          map()
        ) ::
          {:skip, map()} | {:batch, map(), map()}
  def stage_done(tid, attempt_id, {:user_shell_result, duration_ms, exec_res}, state) do
    {worker, workers} = Map.pop(state.workers, attempt_id)
    if worker, do: Process.demonitor(worker.monitor_ref, [:flush])
    state = %{state | workers: workers}

    case Map.get(state.tasks, tid) do
      nil ->
        {:skip, state}

      %{status: "terminal"} ->
        {:skip, state}

      shell_task ->
        now = System.system_time(:millisecond)
        cid = shell_task.checkpoint["conversation_id"]
        command = shell_task.checkpoint["command"]
        include_in_context = shell_task.checkpoint["include_in_context"] == true

        eph = Map.get(state.ephemeral, cid)
        live = merge_ephemeral(state.docs[cid]["live"], eph)
        state = clear_ephemeral_for_conv(state, cid)

        partial_fallback = get_in(live, ["user_shell", "output"]) || ""

        entry_data =
          build_result_entry_data(
            command,
            include_in_context,
            exec_res,
            duration_ms,
            partial_fallback
          )

        {:ok, entry_id, store} = Storage.mint_id(state.store)
        state = %{state | store: store}

        entry = build_entry_record(entry_id, cid, "user_shell", entry_data, now)
        state = record_entry_in_conv(state, cid, entry_id)

        {settled_task, sub_mode, sub_val} =
          if entry_data["cancelled"] do
            {
              %{
                Task.abort(shell_task, "aborted", now)
                | outcome: %{"status" => "aborted", "reason" => "aborted", "entry_id" => entry_id}
              },
              :unanswered,
              "aborted"
            }
          else
            diagnostic = entry_data["diagnostic"]

            task =
              Task.complete(
                shell_task,
                %{
                  "status" => "done",
                  "entry_id" => entry_id,
                  "is_error" => entry_data["is_error"],
                  "diagnostic" => diagnostic
                },
                now
              )

            if diagnostic in ["timeout", "lease_expired", "exec_failed"] do
              {task, :unanswered, diagnostic}
            else
              {task, :done, entry_id}
            end
          end

        sub_ids = shell_task.checkpoint["submission_ids"] || []
        {sub_writes, state} = settle_submissions(sub_ids, sub_mode, sub_val, state, now)

        next_live = Map.delete(live, "user_shell")

        state =
          state
          |> put_task(settled_task)
          |> put_doc(cid, "live", next_live)

        writes =
          [{:append_entry, entry}, {:put_task, settled_task}] ++
            sub_writes ++
            [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

        staged = %{
          raw_item: {:worker_done, tid, attempt_id, {:user_shell_result, duration_ms, exec_res}},
          writes: writes,
          conv_events: %{
            cid => %{entries: [entry], doc_ops: %{"live" => [["replace", next_live]]}}
          },
          submissions: [],
          effects: [{:release_lease, cid}],
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}
    end
  end

  @doc """
  Stages failure when a `user_shell` worker crashes abnormally. Never replays
  unsafe work; preserves any streamed partial output.
  """
  @spec stage_crashed(pos_integer(), pos_integer(), term(), map()) ::
          {:skip, map()} | {:batch, map(), map()}
  def stage_crashed(tid, attempt_id, _reason, state) do
    {worker, workers} = Map.pop(state.workers, attempt_id)
    if worker, do: Process.demonitor(worker.monitor_ref, [:flush])
    state = %{state | workers: workers}

    case Map.get(state.tasks, tid) do
      nil ->
        {:skip, state}

      %{status: "terminal"} ->
        {:skip, state}

      shell_task ->
        now = System.system_time(:millisecond)
        cid = shell_task.checkpoint["conversation_id"]
        eph = Map.get(state.ephemeral, cid)
        live = merge_ephemeral(state.docs[cid]["live"], eph)
        state = clear_ephemeral_for_conv(state, cid)

        {writes, state} = settle_interrupted(shell_task, live, state, now)
        next_live = state.docs[cid]["live"]

        appended =
          Enum.flat_map(writes, fn
            {:append_entry, e} -> [e]
            _ -> []
          end)

        staged = %{
          raw_item: {:worker_crashed, tid, attempt_id, :crash},
          writes: writes,
          conv_events: %{
            cid => %{entries: appended, doc_ops: %{"live" => [["replace", next_live]]}}
          },
          submissions: [],
          effects: [{:release_lease, cid}],
          reply_from: nil,
          receipt: nil
        }

        {:batch, staged, state}
    end
  end

  @doc """
  Stages immediate cancellation of an active `user_shell` task during session `abort`.
  Captures partial output, marks entry cancelled, aborts task, and returns worker
  termination + lease release effects.
  """
  @spec stage_abort(map(), pos_integer(), String.t(), map(), integer()) ::
          {[H.Storage.write()], map(), [term()]}
  def stage_abort(shell_task, cid, reason, state, now) do
    eph = Map.get(state.ephemeral, cid)
    live = merge_ephemeral(state.docs[cid]["live"], eph)
    state = clear_ephemeral_for_conv(state, cid)

    command = shell_task.checkpoint["command"]
    include_in_context = shell_task.checkpoint["include_in_context"] == true
    partial_out = get_in(live, ["user_shell", "output"]) || ""

    {:ok, entry_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}

    entry_data = %{
      "command" => command,
      "output" => partial_out,
      "exit_code" => nil,
      "cancelled" => true,
      "truncated" => false,
      "skipped_bytes" => 0,
      "full_output_path" => nil,
      "include_in_context" => include_in_context,
      "is_error" => true,
      "diagnostic" => "aborted",
      "duration_ms" => nil
    }

    entry = build_entry_record(entry_id, cid, "user_shell", entry_data, now)
    state = record_entry_in_conv(state, cid, entry_id)

    aborted_task = %{
      Task.abort(shell_task, reason, now)
      | outcome: %{"status" => "aborted", "reason" => reason, "entry_id" => entry_id}
    }

    sub_ids = shell_task.checkpoint["submission_ids"] || []
    {sub_writes, state} = settle_submissions(sub_ids, :unanswered, reason, state, now)

    next_live = Map.delete(live, "user_shell")

    state =
      state
      |> put_task(aborted_task)
      |> put_doc(cid, "live", next_live)

    writes =
      [{:append_entry, entry}, {:put_task, aborted_task}] ++
        sub_writes ++
        [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

    kill_effects =
      state.workers
      |> Enum.filter(fn {_aid, w} -> w.task_id == shell_task.id end)
      |> Enum.map(fn {aid, w} ->
        if Map.get(w, :abort_ref) && is_pid(w.pid) && Process.alive?(w.pid) do
          send(w.pid, {:abort_exec, w.abort_ref})
        end

        {:kill_worker, aid, w.pid, w.monitor_ref}
      end)

    {writes, state, kill_effects ++ [{:release_lease, cid}]}
  end

  @doc """
  Reconciles a non-terminal `user_shell` task (`"running"` or `"pending"`) on
  session open / VM restart. Because `user_shell` is unsafe, it NEVER replays;
  any persisted partial output is recorded in an interrupted entry.
  """
  @spec recover_on_open(map(), map(), integer()) :: {[H.Storage.write()], map()}
  def recover_on_open(shell_task, state, now) do
    cid = shell_task.checkpoint["conversation_id"]
    live = state.docs[cid]["live"] || %{}
    settle_interrupted(shell_task, live, state, now)
  end

  # Internal helpers

  defp settle_interrupted(shell_task, live, state, now) do
    cid = shell_task.checkpoint["conversation_id"]
    command = shell_task.checkpoint["command"]
    include_in_context = shell_task.checkpoint["include_in_context"] == true
    partial_out = get_in(live, ["user_shell", "output"]) || ""

    {:ok, entry_id, store} = Storage.mint_id(state.store)
    state = %{state | store: store}

    entry_data = %{
      "command" => command,
      "output" => partial_out,
      "exit_code" => nil,
      "cancelled" => false,
      "truncated" => false,
      "skipped_bytes" => 0,
      "full_output_path" => nil,
      "include_in_context" => include_in_context,
      "is_error" => true,
      "diagnostic" => "interrupted",
      "duration_ms" => nil
    }

    entry = build_entry_record(entry_id, cid, "user_shell", entry_data, now)
    state = record_entry_in_conv(state, cid, entry_id)

    done_task =
      Task.complete(
        shell_task,
        %{"status" => "interrupted", "reason" => "interrupted", "entry_id" => entry_id},
        now
      )

    sub_ids = shell_task.checkpoint["submission_ids"] || []
    {sub_writes, state} = settle_submissions(sub_ids, :unanswered, "interrupted", state, now)

    next_live = Map.delete(live, "user_shell")

    state =
      state
      |> put_task(done_task)
      |> put_doc(cid, "live", next_live)

    writes =
      [{:append_entry, entry}, {:put_task, done_task}] ++
        sub_writes ++
        [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

    {writes, state}
  end

  defp commit_immediate_failure(cid, task, reason, message, state, now) do
    done_task =
      Task.complete(task, %{"status" => "failed", "reason" => reason}, now)

    sub_ids = task.checkpoint["submission_ids"] || []
    {sub_writes, state} = settle_submissions(sub_ids, :unanswered, reason, state, now)

    next_live =
      (state.docs[cid]["live"] || %{})
      |> Map.delete("user_shell")
      |> Map.put("run_failure", %{"reason" => reason, "message" => message})

    state =
      state
      |> put_task(done_task)
      |> put_doc(cid, "live", next_live)

    writes =
      [{:put_task, done_task}] ++
        sub_writes ++
        [{:put_doc, {:conversation, cid, "live"}, Document.wrap("live", next_live)}]

    case Storage.commit(state.store, [writes]) do
      {:ok, %{seqs: [batch_seq]}, committed_store} ->
        state = %{state | store: committed_store, seq: batch_seq}

        broadcast_commit_frame(state, cid, batch_seq, [], %{
          "live" => [["replace", next_live]]
        })

      {:error, io_err} ->
        send(self(), {:stop_storage_failed, io_err})
        %{state | storage_failed: true}
    end
  end

  defp build_result_entry_data(command, include_in_context, {:ok, result}, duration_ms, _fallback) do
    exit_code = Map.get(result, :exit_code)
    is_error = exit_code != 0

    %{
      "command" => command,
      "output" => Map.get(result, :output) || "",
      "exit_code" => exit_code,
      "cancelled" => false,
      "truncated" => Map.get(result, :truncated, false) == true,
      "skipped_bytes" => Map.get(result, :skipped_bytes, 0) || 0,
      "full_output_path" => Map.get(result, :full_output_path),
      "include_in_context" => include_in_context,
      "is_error" => is_error,
      "diagnostic" => if(is_error, do: "exit_code", else: nil),
      "duration_ms" => duration_ms
    }
  end

  defp build_result_entry_data(
         command,
         include_in_context,
         {:error, %{reason: reason} = err},
         duration_ms,
         _fallback
       ) do
    cancelled? = reason == :aborted

    diagnostic =
      case reason do
        :aborted -> "aborted"
        :timeout -> "timeout"
        :lease_expired -> "lease_expired"
        other -> to_string(other)
      end

    %{
      "command" => command,
      "output" => Map.get(err, :output) || "",
      "exit_code" => nil,
      "cancelled" => cancelled?,
      "truncated" => Map.get(err, :truncated, false) == true,
      "skipped_bytes" => Map.get(err, :skipped_bytes, 0) || 0,
      "full_output_path" => Map.get(err, :full_output_path),
      "include_in_context" => include_in_context,
      "is_error" => true,
      "diagnostic" => diagnostic,
      "duration_ms" => duration_ms
    }
  end

  defp build_result_entry_data(
         command,
         include_in_context,
         {:error, reason},
         duration_ms,
         partial_fallback
       ) do
    output =
      if partial_fallback != "" do
        partial_fallback <> "\n\nCommand failed: #{inspect(reason)}"
      else
        "Command failed to start: #{inspect(reason)}"
      end

    %{
      "command" => command,
      "output" => output,
      "exit_code" => nil,
      "cancelled" => false,
      "truncated" => false,
      "skipped_bytes" => 0,
      "full_output_path" => nil,
      "include_in_context" => include_in_context,
      "is_error" => true,
      "diagnostic" => "exec_failed",
      "duration_ms" => duration_ms
    }
  end

  defp validate_bound_env({mod, _env_state} = env) when is_atom(mod), do: {:ok, env}
  defp validate_bound_env(_), do: {:error, "missing_execution_env"}

  defp workspace_cwd(env, state) do
    Map.get(state, :cwd) || ExecutionEnv.cwd(env)
  end

  defp acquire_lease(cid, env, state) do
    lease_server = Map.get(state, :workspace_lease)

    if not is_nil(lease_server) and GenServer.whereis(lease_server) != nil do
      env_id = Map.get(state, :env_id) || ExecutionEnv.env_id(env)
      cwd = workspace_cwd(env, state)
      ws_key = {env_id, cwd}
      holder_key = {state.session_id, cid}

      case WorkspaceLease.acquire(lease_server, ws_key, holder_key, self()) do
        :ok ->
          held = Map.get(state, :held_leases, MapSet.new())
          {:ok, Map.put(state, :held_leases, MapSet.put(held, cid))}

        {:error, _} = err ->
          err
      end
    else
      {:ok, state}
    end
  end

  defp release_lease(cid, env, state) do
    lease_server = Map.get(state, :workspace_lease)
    held = Map.get(state, :held_leases, MapSet.new())

    if MapSet.member?(held, cid) and not is_nil(lease_server) and
         GenServer.whereis(lease_server) != nil do
      env_id = Map.get(state, :env_id) || ExecutionEnv.env_id(env)
      cwd = workspace_cwd(env, state)
      WorkspaceLease.release(lease_server, {env_id, cwd}, {state.session_id, cid})
      %{state | held_leases: MapSet.delete(held, cid)}
    else
      state
    end
  end

  defp get_or_init_ephemeral(state, cid) do
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

  defp user_shell_live_output(state, cid) do
    get_in(state.docs, [cid, "live", "user_shell", "output"]) || ""
  end

  defp arm_ephemeral_timers(eph, cid, emit_ms, flush_ms) do
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

  defp clear_ephemeral_for_conv(state, cid) do
    case Map.pop(state.ephemeral, cid) do
      {nil, _} ->
        state

      {eph, rest} ->
        if eph.emit_timer, do: Process.cancel_timer(eph.emit_timer)
        if eph.flush_timer, do: Process.cancel_timer(eph.flush_timer)
        %{state | ephemeral: rest}
    end
  end

  defp broadcast_commit_frame(state, cid, batch_seq, wire_entries, doc_ops) do
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

    if pubsub = Map.get(state, :pubsub) do
      Registry.dispatch(pubsub, {:conversation, state.session_id, cid}, fn entries ->
        for {pid, _val} <- entries, do: send(pid, {:commit_frame, batch_seq, commit_bin})
      end)
    end

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

  defp settle_submissions([], _mode, _val, state, _now), do: {[], state}

  defp settle_submissions(sub_ids, mode, val, state, now) do
    by_id =
      Map.new(state.recent_submissions, fn {_rid, s} -> {s.id, s} end)

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

          next_cache = cache_submission(acc_s.recent_submissions, updated)
          {acc_w ++ [{:put_submission, updated}], %{acc_s | recent_submissions: next_cache}}
      end
    end)
  end

  defp cache_submission(recent, sub) do
    updated = Map.put(recent, sub.request_id, sub)

    if map_size(updated) > @max_recent_submissions do
      updated
      |> Enum.sort_by(fn {_k, v} -> v.updated_at || 0 end, :desc)
      |> Enum.take(@max_recent_submissions)
      |> Map.new()
    else
      updated
    end
  end

  defp put_task(state, task) do
    %{state | tasks: Map.put(state.tasks, task.id, task)}
  end

  defp put_doc(state, cid, kind, value) do
    conv_docs = state.docs |> Map.get(cid, %{}) |> Map.put(kind, value)
    %{state | docs: Map.put(state.docs, cid, conv_docs)}
  end

  defp put_user_shell_status(live, status) when is_map(live) do
    if is_map(Map.get(live, "user_shell")) do
      put_in(live, ["user_shell", "status"], status)
    else
      live
    end
  end

  defp record_entry_in_conv(state, cid, entry_id) do
    conv = Map.fetch!(state.conversations, cid)
    updated_conv = %{conv | entry_ids: [entry_id | conv.entry_ids]}
    %{state | conversations: Map.put(state.conversations, cid, updated_conv)}
  end

  defp build_entry_record(id, cid, kind, data, now) do
    %{
      id: id,
      conversation_id: cid,
      kind: kind,
      data: data,
      created_at: now
    }
  end

  defp maybe_put_kw(opts, _key, nil), do: opts
  defp maybe_put_kw(opts, key, val), do: Keyword.put(opts, key, val)
end
