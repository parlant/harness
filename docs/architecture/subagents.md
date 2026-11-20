# Subagents and Work Delegation

This primer reflects on how multi-lane work was delegated across real `hi` sessions during the `h`-removal, core Elixir modularization, response-rendering, and multi-session `/inbox` implementation, and separates **what works today** from **proposed primitives** across the H daemon, `hi`, and `HWeb`.

---

## 1. Field Reflection: How Subagents Were Run Today

To execute five interdependent implementation lanes (Step 1 `h` cleanup, Step 2 Elixir core modularization, Step 3a daemon catalog attention & SSE, Step 3b `hi inbox`, Step 3c `HWeb` `/inbox`, and Step 4 `hi` Markdown/theme rendering) against the live local H daemon (`~/.local/share/h/api.sock`), the coordinating session had to assemble the orchestration out-of-band:

1. **Workspace & Build Isolation via `git worktree`:**
   - Each parallel lane required `git worktree add -b lane/<id> /private/tmp/<id> HEAD`, symlinked `deps` (`deps/` and `clients/web/deps`), and private `MIX_BUILD_PATH` / `CARGO_TARGET_DIR` paths so concurrent Mix/Cargo builds and `H.WorkspaceLease` (`{env_id, cwd}`) would not contend.
2. **Pre-Creating Sessions Over Raw UDS HTTP to Select Models & Thinking:**
   - Because `hi -p` does not accept `--model`, `--thinking`, or `--title` CLI flags, the coordinator wrote an ad-hoc Python Unix-socket client reading `~/.local/share/h/auth.token` to `POST /api/v1/sessions` with `agent: %{"model" => "google:gemini-4-...", "thinking" => "high"}` and an explicit `session_id` + `title` before invoking `hi`.
3. **Background Process Spawning for Headless Completion:**
   - Each worker was launched via `subprocess.Popen(["hi", "-s", sid, "-p", prompt], start_new_session=True)` redirecting stdout/stderr to `/private/tmp/<sid>.out` so the coordinator would not block a single `bash` tool call for 8–10 minutes (`@default_timeout_ms 120_000`, max `600_000`) while running two lanes in parallel.
4. **Polling Instead of Event-Driven Settlement:**
   - Because the coordinator's `bash` tool had no park/wait primitive for another session's submission settlement, monitoring required polling `GET /api/v1/sessions/:sid` and `GET /api/v1/sessions/:sid/conversations/1/entries?limit=1` in a sleep loop—and when a long refactor exceeded a single tool timeout window, re-entering a second poll window.
5. **No Recorded Lineage Between Coordinator and Subagent Sessions:**
   - In `H.Catalog` (and therefore in `hi inbox` and Phoenix `/inbox`), the five subagent sessions appeared as top-level ownerless sessions under `/private/tmp/sub-*` working directories rather than as children owned by—or linked back to—the parent coordinating session/task.
6. **Manual Git Cherry-Pick & Worktree Teardown:**
   - Once `active: false` was observed, the coordinator inspected `.out`, `git status`, and `git show`, cherry-picked the lane branch into `main`, ran cross-surface integration suites, and deleted the temporary worktrees and build directories.

### What Already Worked Well Because of H's Durable Architecture

- **Client-detach safety:** Even when a coordinator poll command timed out or closed, the daemon-owned `H.Session.Server` runs continued uninterrupted to completion.
- **Zero-collision workspace leases:** Giving each session its own worktree `cwd` aligned naturally with `H.WorkspaceLease` (`{env_id, cwd}`).
- **Live observability (once Step 3a/b/c landed):** `H.Catalog`'s new `attention` (`running` · `tool: bash` → `idle` / `error`) and `GET /api/v1/sessions/events` stream reflect exactly the state transitions a human or parent coordinator cares about without waking unloaded sessions or tailing full token streams.

---

## 2. Architectural Invariants for Delegation

Any subagent mechanism added to H must preserve the core invariants in [`docs/architecture.md`](../architecture.md):

1. **History ancestry, work ownership, supervision, and client navigation remain separate.**
   - A subagent with its own working directory (e.g., an isolated git worktree) is a **separate `H.Session`** with a recorded delegation link—not a conversation fork pretending to share a different `cwd`.
   - A subagent researching or reviewing within the **same** `{env_id, cwd}` can be either a child conversation in the same session (`owner: {:task, parent_task_id}` or `{:conversation, parent_cid}`) or a separate session; mutating tools still coordinate through `H.WorkspaceLease`.
2. **Park, never block an OTP worker.**
   - Waiting 10 minutes for a child session to settle must **never** hold a `Task.Supervisor` BEAM worker process or shell `Port` open. The parent task commits its wait intent (`status: "waiting"` / `"sleeping"` on a typed `SubmissionSettled` signal), releases its worker, and wakes via `H.Session.Server` when the child submission reaches a terminal state (`done` or `unanswered`).
3. **Explicit `request_id` idempotency & non-replay of unsafe setup.**
   - Spawning a subagent commits a task memo (`child_session_id`, `child_submission_request_id`) **before** dispatching to `H.Daemon` so a coordinator restart attaches to the existing child submission rather than spawning duplicate subagents.
4. **Bounded context return, full raw auditability.**
   - Only a bounded outcome summary (final assistant reply or structured handoff artifact, plus `session_id`, `status`, and optional `commit_sha`) enters the parent's LLM context window. The child's full raw tool transcript stays durably inspectable in its own session store via `hi`, `/inbox`, or Phoenix.
5. **No privilege escalation or credential leakage.**
   - Tools never read `auth.token` or talk to `api.sock` over shell scripts when running in-daemon; delegation goes through a typed `H.Daemon` capability authorized by the session's harness profile, with explicit depth/fan-out budgets (e.g., `max_depth: 1` by default so subagents cannot recursively fork-bomb the daemon).

---

## 3. Proposed Capabilities by Layer (Not Yet Implemented)

### 3.1 H Daemon (`:harness`)

1. **Parent Lineage Metadata in `H.Catalog`:**
   - Optional immutable fields on `H.Catalog` entries:
     - `parent_session_id: String.t() | nil`
     - `parent_conversation_id: pos_integer() | nil`
     - `parent_task_id: pos_integer() | nil`
     - `role: String.t() | nil` (e.g., `"subagent"`, `"review"`, `"explore"`)
   - Allows `GET /api/v1/sessions` and `GET /api/v1/sessions/events` to associate delegated runs with their originating session even when `cwd` is a temporary `/private/tmp/...` worktree.
2. **Submission Settlement Wait & Wake (`SubmissionSettled` Signal):**
   - Today `POST /api/v1/sessions/:sid/commands` returns an immediate `200` placement receipt (`status: "placed" | "queued"`).
   - Add a non-blocking subscription / signal hook in `H.Daemon` (`await_submission` / `notify` on `H.Submission`) that fires `{:submission_settled, session_id, submission_id, outcome}` when `settle_submissions/5` commits `:done` (`answer_entry_id`) or `:unanswered` (`reason`).
   - Expose an optional HTTP/SSE wait endpoint (`GET /api/v1/sessions/:sid/submissions/:sub_id/wait` or SSE filter) for external CLI callers (`hi -p`) so headless scripts never need polling loops.
3. **Parked `delegate` / `subagent` Harness Tool (Slice 9 Suspendable Work):**
   - Opt-in tool in `H.Harness.Coding` (disabled for child subagents by default unless `max_depth > 1`):
     - Parameters: `prompt`, optional `title`, `cwd` (must be an existing directory in the bound `env_id`), `model`, `thinking`, `read_only: boolean` (restricts tools to `["read", "search_history"]` for parallel exploration without workspace lease contention!).
     - Execution via parked-tool contract:
       1. Commits memo `%{session_id: minted_sid, request_id: minted_req_id}` on the `tool_call` task.
       2. Calls `H.Daemon.create_session/2` + `H.Daemon.execute_command/3` idempotently.
       3. Parks the parent generation/tool round (`status: "waiting"`, holding **zero** worker processes) until `SubmissionSettled` arrives (or parent `abort` propagates bottom-up cancellation to owned child runs).
       4. Commits the bounded `tool_result` containing the child's final assistant text, `session_id`, terminal status, and duration.
4. **Managed Worktree Helper (Optional Opt-In):**
   - Because parallel mutating coding tasks in one repo almost always want separate git worktrees, an explicit environment-scoped helper (never implicit magic) can create/prune disposable worktrees under `<data_dir>/worktrees/<parent_sid>/<slug>` and record `base_sha` / `head_sha` on the child session summary for one-step reconciliation.

---

### 3.2 `hi` Terminal Client (`clients/tui/`)

1. **Ergonomic Headless Delegation Flags on `hi` CLI:**
   - Even before parked in-daemon tools land, `hi` itself is used from scripts, skills, and terminals. Add first-class creation/configuration flags for `-p` and interactive launch:
     - `--model <PROVIDER:MODEL>` and `--thinking <LEVEL>` (passed in `CreateSessionRequest.agent` when creating, or `configure` when attaching if explicitly requested).
     - `--title <TITLE>` and `--parent-session <SID>` for clean catalog labeling.
   - Eliminates 100% of the custom Unix-socket Python boilerplate required today to configure model/thinking before `hi -p`.
2. **Subagent Grouping & Steering in `hi inbox` / `/inbox`:**
   - Render delegated child sessions indented beneath their `parent_session_id` (or badged `↳ subagent of <parent>` when grouped under a separate worktree `cwd` root).
   - Keep the same calm-attention rule: running subagents show the dimmed spinner (`⠋ refactor-server · bash`), while a subagent that hit an `error` (`!`) or paused waiting for input highlights immediately so the human can press `Tab` → `Enter`, steer it (`Enter` / `Alt+Enter`) or `/continue`, and press `Ctrl-D` to pop right back to the inbox or parent session (`Alt+P` / `/parent` to jump to `parent_session_id`).
3. **Inline Delegation Cards in Transcript (`cards.rs`):**
   - When a parent session uses a `delegate` tool, render a live status card (`[subagent · running · bash] Step 2: Modularize Elixir core (sub-040455-step2)`) with a direct hint/action to open and watch that child session in `hi` without losing the parent draft.

---

### 3.3 Phoenix Web Application (`clients/web/`, `HWeb`)

1. **Parent ↔ Child Lineage in `InboxLive` & `SessionLive`:**
   - In `/inbox` (`InboxLive`) and `SessionLive`'s sidebar switcher, display a compact `↳ from <parent>` badge (or collapsible child list under the parent session) so temporary `/private/tmp/...` worktree paths don't obscure *why* five sessions exist or which coordinator spawned them.
   - Provide a **Hide settled subagents** toggle in `/inbox` so completed headless worker sessions (`role == "subagent"` and `attention == "idle"`) don't clutter the user's primary human-driven inbox once their parent has reconciled their work!
2. **One-Click Jump & Split Inspection in `SessionLive`:**
   - Render `delegate` tool calls in `ConversationComponents` with a live status pill (fed by `SessionLive`'s existing `:catalog` PubSub subscription!) and an **Open subagent session →** link (`?from=parent&parent_sid=...`) with a `← Parent session` breadcrumb in the header.
   - On wide desktop screens, `Workbench.split` can optionally preview a selected subagent's live tail without navigating away from the coordinator conversation.

---

## 4. Recommended Implementation Sequence

Keep each step small, testable with `H.Provider.Fake` and disposable stores, and independent of general workflow-engine sprawl:

1. **S1 · CLI & Catalog Lineage (Low risk, immediate daily value):**
   - Add `--model`, `--thinking`, and `--title` flags to `hi` (`CreateSessionRequest`), plus optional `parent_session_id` / `role` metadata on `H.Catalog` (`POST /api/v1/sessions` and `SessionSummary`), with subagent badging/filtering in `hi inbox` and `HWeb.InboxLive`.
2. **S2 · Event-Driven Submission Settlement (`SubmissionSettled`):**
   - Broadcast submission settlement notifications from `H.Session.Server.Submissions.settle/5` so callers (and `hi -p`) wait deterministically on `submission_id` completion without polling `entries`.
3. **S3 · Parked `delegate` Tool & Bottom-Up Abort (Slice 9):**
   - Implement task parking on `SubmissionSettled` in `H.Session.Server`, wire a bounded `delegate` tool (starting with `read_only: true` parallel explorers and explicit-worktree workers), and verify across `SIGKILL` VM restart that parked parent runs neither leak workers nor double-spawn child sessions.
