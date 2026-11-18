# Slice 4: `H.ExecutionEnv`, Coding Tools, and Self-Hosting Bootstrap

**Goal:** Implement the pluggable execution environment, the five essential coding/history tools (`read`, `write`, `edit`, `bash`, `search_history`), and reach **full web-based self-hosting**—developing and testing `H` from inside `H`'s own browser client.

---

## 1. Module Layout

```text
lib/h/
  workspace_lease.ex      # Per-cwd writer lease preventing concurrent coding branches from clobbering one checkout
  execution_env.ex        # H.ExecutionEnv behaviour
  execution_env/
    local.ex              # Local filesystem + OTP Port PGID process-group execution
  tool.ex                 # H.Tool behaviour + JSV JSON Schema argument validation + output bounding/spill helper
  tools/
    read.ex               # replay: :safe, bounded line-numbered text + image support
    search_history.ex     # replay: :safe, raw entry search across full un-truncated session history
    write.ex              # replay: :unsafe, atomic parent-mkdir + write
    edit.ex               # replay: :unsafe, multi-hunk exact unique text replacement preserving line endings
    bash.ex               # replay: :unsafe, owned PGID execution, timeout, tail window + spill file
  task/
    tool_call.ex          # Durable tool task (validate -> intent -> execute -> bounded result)
test/
  support/
    env_conformance.ex    # Shared H.ExecutionEnv conformance suite
  h/
    execution_env_local_test.exs
    tools_test.exs
    tool_crash_recovery_test.exs
```

---

## 2. `H.ExecutionEnv` and OTP 29 Process-Group Cleanup (`H.ExecutionEnv.Local`)

### Filesystem Primitives

- Resolve relative paths strictly against the conversation's `cwd`.
- **`read_file_lines/3`:** Bounded positional line scanner (default max `2,000` lines or `50 KiB`), refusing final-component symlinks when `no_follow: true`, handling growing log files cleanly, and refusing binary/non-UTF-8 files with a clear diagnostic (except supported PNG/JPEG/GIF/WebP images).
- **`write_file/3` & `edit`:** Preserve untouched CRLF/LF line endings in `edit`; ensure every `edits[].old_text` matches a unique, non-overlapping span of the original file before writing atomically.

### Subprocess Execution & Grandchild Reaping on macOS and Linux

macOS does not ship a `setsid(1)` binary, and closing an Erlang `Port` alone only closes pipes—leaving background grandchildren (`sleep 60 &` or stray compiler/test workers) alive.

On Erlang/OTP 29, `Port.open({:spawn_executable, executable}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: argv, cd: cwd, env: clean_env])` spawns via OTP's `erl_child_setup`, which calls `setsid()` in the child before `execve`. Consequently, **every `Port` OS child starts as its own session and process-group leader (`SID == PGID == os_pid`)** on both macOS and Linux with zero C NIFs:

1. Immediately read `{:os_pid, os_pid} = Port.info(port, :os_pid)`.
2. Stream output chunks through a **source-side rolling tail window** (e.g. `50 KiB` / `2,000` lines), counting omitted head bytes (`skipped`) and spilling full output to a private temp file when truncated.
3. On normal `{^port, {:exit_status, code}}`, sweep `-os_pid` (`kill -TERM -<os_pid>`) if stray background descendants remain, and return `%{exit_code: code, output: tail, truncated: bool, skipped_bytes: n, full_output_path: path}` (a nonzero `exit_code` returns a structured `is_error: true` tool result with diagnostic `:exit_code`, never crashing the worker).
4. On **abort (`Esc`), deadline timeout, or coordinator shutdown**:
   - Send `System.cmd("/bin/kill", ["-TERM", "-#{os_pid}"])`.
   - Wait up to `grace_ms` (`2_000 ms`) for the port/group to exit; if still alive, send `System.cmd("/bin/kill", ["-KILL", "-#{os_pid}"])` and close the port.
   - Never call `pkill` by pattern (`AGENTS.md` rule: user may run the same binary, including another `beam.smp` or `mix test`!).

---

## 3. Tool Validation and Crash-Window Semantics (`H.Task.ToolCall`)

Each `H.Tool` declares its parameter schema as a standard JSON Schema map (passed directly to `ReqLLM.Tool` in `H.Context` and compiled once with `JSV`—already included via `:req_llm`—for strict local argument validation before intent commit; invalid model arguments commit an `is_error: true` tool-result with diagnostic `"invalid_arguments"` without executing the tool).

Every tool call executes inside its own durable `tool_call` task owned by the `generation` task:

| Crash Window | Recovery Behavior |
|---|---|
| Before intent commit | Generation resumes before scheduling tools or schedules missing tasks cleanly. |
| After intent commit, before `execute/3` starts | `replay: :safe` (`read`, `search_history`) executes; `replay: :unsafe` (`write`, `edit`, `bash`) has already entered its execution checkpoint once started—see below. |
| During `execute/3` (or after OS side effect before outcome commit) | `replay: :safe` re-executes cleanly; `replay: :unsafe` does **not** re-execute—commits an error tool-result (`diagnostic: "interrupted"`, including any partial output flushed via `persist_within_ms`) so the model inspects `git diff` / files before acting. |
| After outcome commit | Reuses the committed tool-result entry; never executes again. |

### Per-Workspace Writer Lease (`H.WorkspaceLease`)

- Chat-only and read-only (`read`, `search_history`) runs require no lease.
- Before executing a mutating tool (`write`, `edit`, `bash`) in `cwd`, `H.WorkspaceLease` ensures no other active conversation/session holds a mutating run lease on the same canonical `cwd` (returning a clear busy/worktree hint rather than racing concurrent edits in one working tree).
- Per-conversation `max_turns` (default e.g. 50 tool rounds) bounds runaway loops, ending `unanswered` with `run_failure: %{reason: "turn_limit"}` resumable via `continue`.

---

## 4. Verification & Self-Hosting Bootstrap Milestone (Slice 4 Done)

1. **Automated test suite (`mix test --no-start`):**
   - `H.ExecutionEnvLocalTest` passes `H.ExecutionEnv.Conformance`: `no_follow` symlink refusal, growing file reads, source-side output windowing + spill file, and **grandchild process-group reaping** (spawns `sh -c '(sleep 300 &) ; sleep 300'`, aborts after 50 ms, asserts both parent and background grandchild PIDs are dead).
   - `H.ToolsTest`: covers `read`, `write`, `edit` (multi-hunk non-overlapping edits, duplicate-match refusal, CRLF preservation), `bash` (nonzero exit code + spill truncation), and `search_history` across forked conversations.
   - `H.ToolCrashRecoveryTest`: exercises all 5 crash windows for both `replay: :safe` and `replay: :unsafe` tools.

2. **Self-Hosting Bootstrap Acceptance Drill:**
   - Start `:harness` pointed at a private `<data_dir>` and open the web client in a browser.
   - Create a session with `cwd: "/Users/partenkirchen/Projects/diy-harness"`.
   - From the browser UI, ask `H` to read `docs/roadmap/05-workspace-browser-and-harness-seam.md`, implement the first post-self-hosting feature + unit test in `lib/h/` and `test/h/` (using `MIX_BUILD_PATH=/private/tmp/h-selfhost-build`), and run `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix test --no-start` via its `bash` tool.
   - Force-kill (`kill -9`) and restart the `:harness` daemon mid-bash call in a disposable scratch branch, reload the browser tab, verify the interrupted `bash` call is reported honestly (not blindly re-executed), click **Continue**, and let `H` inspect and finish the task.
