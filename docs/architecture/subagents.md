# Subagents, Subsessions, and Inter-Session Signals

This document describes the **implemented** architecture across the H daemon (`:harness`), terminal client (`hi`), and Phoenix web app (`HWeb`) for step-anchored spawned subsessions, inter-session settlement signals, coordinator-parked `subagent` delegation, and calm root-first inbox/attention surfaces, along with the field reflections that motivated it.

---

## 1. Field Reflection: What Worked and What Was Missing

During multi-lane work (`h` removal, core Elixir modularization, catalog attention & SSE, `hi inbox`, `HWeb` `/inbox`, and Markdown/theme rendering), the coordinating session delegated work to real `hi` sessions over `~/.local/share/h/api.sock`:

### What Already Works Naturally in H's Core
- **Client-detach safety:** Daemon-owned `H.Session.Server` coordinators run work independently of attached clients.
- **Per-workspace lease safety:** Isolated git worktrees (`{env_id, cwd}`) give parallel mutating lanes zero-collision `H.WorkspaceLease` semantics, while read-only tools (`read`, `search_history`) run without acquiring workspace leases.
- **Idempotent command envelopes & inter-session steering:** `H.Submission` (`request_id` + SHA-256 payload fingerprint) already lets any authorized caller—human or parent session—send `submit` (`follow_up`, `steer`, `continue`), `withdraw`, or `abort` commands to another session with conflict-free receipts.
- **Live catalog state without waking sessions:** `H.Catalog` ETS + `:catalog` PubSub (`GET /api/v1/sessions/events`) already broadcasts `attention` (`idle`, `running`, `sleeping`, `error`, `quarantined`), `activity_kind`, `activity_label`, and `queued_count`.

### Pain Points from Out-of-Band Orchestration
1. **No Spawn Lineage at the Launch Step:** Subagent sessions had no recorded link to the parent session, conversation, or exact step (`at_entry_id`) that spawned them.
2. **Inbox & Attention Pollution:** Headless subagent sessions in `/private/tmp/...` worktrees appeared as top-level ownerless sessions in `hi inbox`, `HWeb.InboxLive`, `WorkspaceLive`, and `next_attention_session` badges—competing with root human sessions for user attention even after finishing cleanly.
3. **Polling & Blocked Workers:** Waiting for a subagent required backgrounding `hi -p` via Python `subprocess.Popen` and polling `GET /api/v1/sessions/:sid` in `bash` sleep loops to avoid holding a single tool worker open past `@default_timeout_ms`.
4. **Ad-Hoc UDS Setup Scripts:** `hi -p` lacked `--model`, `--thinking`, `--title`, and `--parent` CLI flags, requiring custom Unix-socket HTTP scripts reading `auth.token` just to pre-configure a worker session.

---

## 2. Core Model: Forking Conversations vs. Spawning Subsessions

H preserves the strict separation in [`docs/architecture.md`](../architecture.md) between **history ancestry**, **work ownership**, **OTP supervision**, and **client navigation**:

| Mechanism | Scope | History Prefix | Workspace (`{env_id, cwd}`) | Primary Use |
|---|---|---|---|---|
| **Conversation `fork`** (`Conversation.parent = %{conversation_id, at}`) | Intra-session (`H.Conversation`) | **Inherits** visible entries `<= at` and `agent` doc `as_of` `at` | Shared with session | Branching a prompt, exploring an alternative turn on the same transcript |
| **Session `spawn`** (`Catalog.parent = %{session_id, conversation_id, at_entry_id, task_id}`) | Inter-session (`H.Session`) | **Fresh** root conversation (`1`) with bounded prompt/handoff | Same `{env_id, cwd}` **or** isolated worktree `{env_id, child_cwd}` | Delegating bounded exploration, review, or parallel worktree implementation |

### 2.1 Step-Anchored `spawn` Lineage (`parent` on `H.Catalog` & `session_meta`)

When a subsession is launched—whether via the in-daemon `subagent` tool or `hi` CLI—the **exact step at which it was launched** becomes its immutable `parent` anchor:

```elixir
%{
  session_id: "coordinator-a1b2c3",
  conversation_id: 1,        # wire: "1"
  at_entry_id: 42,           # wire: "42" — assistant tool_call entry (or latest visible entry) at launch
  task_id: 43,               # wire: "43" | nil — owning tool_call task when daemon-spawned
  depth: 1                   # integer >= 1 (root sessions have parent: nil, depth: 0)
}
```

- **Why `at_entry_id` matters:** Just as `Conversation.parent` anchors a fork to `%{conversation_id, at}`, anchoring a spawned subsession to `{session_id, conversation_id, at_entry_id}` records *exact causal provenance*: which assistant step or user turn in which branch launched the subagent, even if the parent conversation later forks, compacts, or continues for 50 more turns.
- **Immutability & Persistence:** `parent` (and optional `role: "subagent" | nil`) is validated at `POST /api/v1/sessions` / `H.Daemon.create_session/2`, stored immutably in both `H.Catalog` (`catalog/sessions.json` + ETS) and the child's `session_meta` (`sessions/<child_sid>/`), and included on every `SessionSummary` wire payload.
- **Validation & Cycle/Depth Guards:**
  - If `parent` is supplied on create, `parent.session_id` must exist in `H.Catalog` (cannot equal `session_id`), `depth` is computed server-side as `(parent_entry.depth || 0) + 1`, and `max_subagent_depth` (default `1` for tool-spawned subagents; configurable) prevents recursive fork-bombs.
  - On idempotent `create_session` attach (same `session_id`), mismatched `parent` returns `409 Conflict` just like mismatched `workspace` or `harness_id`.

### 2.2 Root-First Attention & Hierarchical Subsessions Toggle

By distinguishing **root sessions** (`parent == nil`) from **subsessions** (`parent != nil`) in `H.Catalog` and `SessionSummary`:

1. **Default Exemption from User Inbox & Attention Surfaces:**
   - **Root sessions (`parent == nil`)** own human attention. By default (`subsessions_enabled == false`):
     - `hi inbox` / `/inbox`, `HWeb.InboxLive` (`/inbox`), `HWeb.WorkspaceLive` session lists, `GET /api/v1/fs` directory session counts (`direct_session_count`, `active_session_count`, `latest_session`), and `hi -c` (`continue_latest` in a `cwd`) **only include root sessions**.
     - `next_attention_session`, `Tab` ("next attention" cycling in `hi inbox`), `counts.attention`, and `SessionLive`'s header attention badge **exempt subsessions by default**. A subagent settling to `idle` wakes its parent session via signal rather than nagging the human's inbox; if a subagent fails, its parent receives the error tool result and surfaces attention at the root coordinator level (if the parent itself pauses or finishes).
2. **Hierarchical Subsessions View When Enabled (`subsessions` toggle):**
   - Both `hi inbox` (e.g. `t` key toggle / `--subsessions` flag) and `HWeb` (`Show subsessions` toggle in `InboxLive` and `SessionLive` drawer, `?subsessions=1`) let the user reveal subsessions on demand.
   - When enabled, subsessions are **nested hierarchically beneath their ancestor root session** (`├─ ↳` / `└─ ↳` indented tree in `hi inbox`, collapsible/indented child list in `HWeb.InboxComponents`)—**even when the subsession's `cwd` is an isolated `/private/tmp/...` worktree!** When a subsession's `cwd` differs from its parent's `cwd`, its row displays a compact `[cwd: /private/tmp/...]` path badge rather than creating noisy top-level `/private/tmp/*` workspace groups. Orphan subsessions whose parent was deleted fall back cleanly to their own workspace group with a `↳ <parent_sid>` badge.

---

## 3. Leveraging Inter-Session Signals & Parked Tasks

Rather than inventing a heavyweight workflow framework, subagents compose directly out of H's existing `H.Submission`, `H.PubSub`, and `H.Session.Server` drain-batch architecture.

### 3.1 Durable Submission Settlement & Inter-Session Signal Bus

Today, `H.Submission` already has a `notify` field in storage, and `H.PubSub` (`Registry` with `keys: :duplicate`) dispatches session/catalog events without coupling processes. We formalize two clean, transport-safe primitives:

1. **PubSub Settlement Broadcast + Non-Racy Inspection (`H.Daemon.watch_submission` / `:submission` topic):**
   - Whenever `H.Session.Server` commits a submission transition to a terminal state (`status in ["done", "unanswered", "withdrawn"]` in `Submissions.settle/5`, `Commands.stage_withdraw/7`, or immediate `nothing_to_answer`), **after `Storage.commit/2` succeeds**, `Stream` dispatches on `H.PubSub` topic `{:submission, session_id, request_id}` (and `{:session_signals, session_id}`):
     ```elixir
     {:submission_settled, %{
       session_id: session_id,
       conversation_id: cid,
       submission_id: sub_id,
       request_id: request_id,
       status: "done" | "unanswered" | "withdrawn",
       answer_entry_id: entry_id_or_nil,
       reason: reason_or_nil,
       seq: batch_seq
     }}
     ```
   - **Race-free registration (`H.Daemon.watch_submission/4`):** Just like `subscribe_conversation/5` registers on `H.PubSub` *before* calling `Server.snapshot_or_replay/3`, `watch_submission(session_id, request_id, watcher_pid, opts)` registers on `{:submission, session_id, request_id}` first and then queries `Server.get_submission_outcome(server, request_id)`.
     - If already terminal (`"done"`, `"unanswered"`, `"withdrawn"`), it immediately returns `{:settled, outcome}` (including bounded final assistant text extracted from `answer_entry_id` when `"done"`).
     - Otherwise it returns `{:pending, submission_summary}` and the watcher will deterministically receive `{:submission_settled, outcome}` once committed—even if settlement raced with registration!

2. **Outbound Inter-Session Steering & Coordination Signals (`subagent_signal` / existing Commands):**
   - Because every subsession is a genuine `H.Session`, a parent coordinator (or human) can send typed commands to an existing child session via `H.Daemon.execute_command/3`:
     - **Follow-up / Multi-turn refinement:** `submit` (`when_busy: "follow_up"`, `when_idle: "start"`) on the same `child_session_id` to ask follow-up questions or request fixes after reviewing its diff—preserving the child's full cached context!
     - **Live mid-run steering:** `submit` (`when_busy: "steer"`, `when_idle: "reject"`) to redirect an actively running subsession at its next tool-round boundary without aborting its work.
     - **Bottom-up cancellation:** `abort` (`reason: "parent_aborted"`) propagated automatically when a parent conversation is aborted while waiting on owned child subsessions.

### 3.2 Zero-Worker Task Parking in `H.Session.Server`

Waiting 10 minutes for three parallel subagents must **hold zero `Task.Supervisor` worker processes**.

1. **Tool Execution Modes: Worker Tools vs. Coordinator-Managed Parked Tools:**
   - Standard tools (`read`, `write`, `edit`, `bash`, `search_history`) run synchronously inside a short-lived `Task.Supervisor` process.
   - Delegation tools (`subagent`) implement an explicit coordinator-parked lifecycle (`kind: "tool_call"`, `checkpoint["mode"] => "subagent"`):
     1. **Commit Intent & Idempotent Memo First:** Before touching `H.Daemon`, `H.Session.Server` mints deterministic `child_session_id` (when spawning new) and `child_request_id` (`"sub:#{session_id}:#{tool_task_id}"`), and commits them in `tool_task.memos`:
        ```elixir
        %{
          "child_session_id" => child_sid,
          "child_conversation_id" => 1,
          "child_request_id" => child_req_id,
          "at_entry_id" => call_entry_id,
          "propagate_abort" => true
        }
        ```
        Status transitions to `"waiting"` (`wake: %{"on" => "submission_settled", "session_id" => child_sid, "request_id" => child_req_id}`).
     2. **Concurrent Fan-Out in One Tool Round:** Unlike local shell/edit tools (which serialize sequentially within a turn), if an assistant emits **multiple `subagent` tool calls in one turn** (e.g. 3 parallel read-only explorers or 3 isolated worktree lanes), `H.Session.Server` dispatches and parks **all ready `subagent` tool calls concurrently**! Each child session runs under its own `H.Session.Server` and `H.WorkspaceLease`.
     3. **Post-Commit Dispatch & Watch Effect (`{:dispatch_subagent, cid, tool_task_id}`):**
        - Runs outside storage commit: calls `H.Daemon.create_session/2` (with `parent: %{session_id: parent_sid, conversation_id: cid, at_entry_id: call_entry_id, task_id: tool_task_id}`) and `H.Daemon.execute_command/3` using the persisted `child_session_id` and `child_request_id`.
        - Registers `self()` (the parent `H.Session.Server`) via `H.Daemon.watch_submission/4` and subscribes to `:catalog` updates for `child_sid` (or lightweight status forwarding) so the parent's `live.tools[call_id]` can show live child activity (`"running · bash"`).
        - If already settled on attach/recovery, immediately enqueues `{:subagent_settled, tool_task_id, outcome}` into `process_with_drain/2`.
     4. **Wake & Bounded `tool_result` Settlement:**
        - When `{:submission_settled, outcome}` arrives at parent `H.Session.Server`, it stages a normal `tool_result` entry and marks `tool_task` `"terminal"`:
          - `content`: bounded summary (final assistant reply capped to e.g. 32 KiB with truncation pointer to `child_session_id`, plus status/diagnostic).
          - `details`: `%{"child_session_id" => child_sid, "child_conversation_id" => "1", "submission_id" => ..., "status" => outcome.status, "cwd" => child_cwd, "model" => child_model, "at_entry_id" => to_string(call_entry_id)}`.
        - Once all `tool_task_ids` in the parent generation's tool round are `"terminal"`, `Tools.finish_tool_round_stage/3` drains any `"steer"` items and spawns the next parent generation turn automatically!

2. **Crash, Shutdown, and VM Restart Semantics:**
   - **Clean Shutdown & Planned Drain:** Because `status == "waiting"` is non-terminal, `State.session_active?/1` remains `true` (`attention: "running"`, `activity_kind: "tool"`, `activity_label: "subagent"`), fencing idle-only `POST /daemon/shutdown` cleanly. On supervisor stop, no worker PID needs killing; `clean_close: true` is written while `tool_task` stays `"waiting"`.
   - **Unclean Crash / `SIGKILL` Recovery (`Recovery.reconcile_on_open`):**
     - On boot, `H.Daemon.recover_active_sessions/1` starts both active child sessions and waiting parent sessions.
     - For any `tool_task` with `status == "waiting"` and `memos["child_request_id"]`, `Recovery.collect_resume_effects/1` emits `{:watch_subagent, cid, tool_task.id}`:
       - Re-calls `create_session` + `execute_command` with the **exact stored `child_session_id` and `child_request_id`**.
       - If the crash happened *before* child submission committed, idempotent dispatch places it once.
       - If the crash happened *while* the child was running or *after* the child finished, `execute_command` returns the duplicate receipt without re-running anything, and `watch_submission` either attaches to the live run or immediately settles the parent `tool_task`!
       - If the child session was quarantined or deleted, the parent `tool_task` settles cleanly with `is_error: true, diagnostic: "child_quarantined" | "child_not_found"` so the parent never hangs forever.
   - **Bottom-Up `abort` Propagation:**
     - If the user (or an ancestor) aborts the parent conversation while a `subagent` tool task is `"waiting"`, `Tools.abort_child_tools/6` emits `{:abort_subagent, child_sid, child_cid, "parent_aborted"}` in post-commit effects, cancelling the child session's active generation/tools/shell cleanly.

---

## 4. Concrete Tool & API Surface

### 4.1 `H.Tools.Subagent` (`name: "subagent"`)
Offered in `H.Harness.Coding` when `session_depth < max_subagent_depth` (default `max_subagent_depth: 1`, so root sessions get `"subagent"` in their default tools, while depth-1 subsessions do **not** get `"subagent"` unless explicitly configured higher):

- **Parameters:**
  - `prompt` (required non-empty string): Task instructions and context for the subsession.
  - `session_id` (optional `session_id` string): Omit to spawn a new child subsession anchored at this tool-call entry; provide an existing child `session_id` owned by this session to send a follow-up turn (`submit`) or steer it!
  - `mode` (optional enum `"wait"` | `"start"` | `"await"` | `"steer"` | `"abort"`, default `"wait"`):
    - `"wait"`: Spawn (or submit follow-up to `session_id`) and park this tool call until the submission settles, returning the child's final assistant reply.
    - `"start"`: Spawn/submit asynchronously and return `{child_session_id, submission_id, status}` immediately so the parent can do other local work or coordinate multiple waves, then later call `subagent` with `mode: "await"` or `"steer"`.
    - `"await"`: Park until an already-started child `session_id`'s latest/given `request_id` settles.
    - `"steer"`: Deliver a live `"steer"` input to a busy child `session_id` and return the placement/queue receipt immediately.
    - `"abort"`: Abort active work in an owned child `session_id`.
  - `title` (optional string): Display title for the subsession.
  - `cwd` (optional absolute path): Working directory in the parent's `env_id` (defaults to parent's `cwd`; pass a worktree path for isolated parallel mutations).
  - `model` (optional `provider:model` string): Defaults to parent conversation's current `agent["model"]`.
  - `thinking` (optional thinking level string): Defaults to parent conversation's current `agent["thinking"]`.
  - `read_only` (optional boolean, default `false`): When `true`, restricts the child's tools to `["read", "search_history"]` so N explorers can run in the same `cwd` with zero `WorkspaceLease` contention and zero mutation risk.

> **Why unifying spawn + follow-up + steer + await in one `subagent` tool is clean:** Models don't have to juggle 4 separate tool schemas. For 90% of delegations, `{prompt, cwd?, read_only?, model?, thinking?, title?}` (default `mode: "wait"`) spawns a subsession (or 3 in parallel in one assistant turn!), parks with zero BEAM workers, and returns the answers. When advanced coordination is needed, `mode: "start" | "steer" | "await" | "abort"` unlocks full asynchronous signal-passing between parent and child sessions!

### 4.2 Daemon HTTP/JSON & `hi` / `HWeb` Additions
- **`POST /api/v1/sessions` (`CreateSessionRequest`):**
  - Accepts optional `"parent"`: `%{"session_id" => sid, "conversation_id" => cid_optional, "at_entry_id" => entry_id_optional}` and optional `"role"` (`"subagent"`). When `conversation_id` is given without `at_entry_id`, daemon resolves the latest visible entry ID in that conversation (if any) so CLI-launched subsessions also anchor to the current step!
- **`GET /api/v1/sessions` & `SessionSummary`:**
  - Every `SessionSummary` includes `"parent"` (`null` for root sessions, or `%{"session_id" => ..., "conversation_id" => ..., "at_entry_id" => ..., "task_id" => ..., "depth" => ...}`) and `"role"` (`null | "subagent"`).
  - Optional query param `include_subsessions=true|false` on `GET /api/v1/sessions` when filtering by `cwd` (default `true` on raw `/sessions` snapshot so clients have the full graph for toggles/cards; `GET /api/v1/fs` directory counts exclude `parent != nil` by default).
- **`GET /api/v1/sessions/:sid/submissions/:request_id` (or SSE settlement frame):**
  - Lightweight status/settlement lookup so external callers can inspect submission completion cleanly.
- **`hi` Terminal Client (`clients/tui/`):**
  - CLI flags on `hi`: `--model <ID>`, `--thinking <LEVEL>`, `--title <TITLE>`, `--parent <SID>` (and optional `--parent-entry <EID>`), working seamlessly in both interactive and `-p` headless modes, plus `hi inbox --subsessions`.
  - `hi -c` (`continue_latest`): skips subsessions (`parent.is_some()`) so running subagents in a repo never hijack `hi -c` from the user's root session.
  - `InboxState` (`hi/inbox.rs`): hides subsessions by default and excludes them from `counts()`, `reconcile_selection()`, and `cycle_attention()` (`Tab`). Pressing `t` toggles hierarchical subsession display directly underneath their parent session (`├─ ↳` / `└─ ↳`), with `Alt+P` / `/parent` in session view to jump to `parent.session_id` (at the parent conversation!).
  - `cards.rs`: renders `[subagent ...]` tool calls and results as clean delegation cards showing child title/ID, workspace/read-only badge, status, and `/sub` or hint to inspect.
- **`HWeb` Phoenix Client (`clients/web/`):**
  - `CatalogState`: parses `parent` and `role`; `root_session?/1` helper; `counts/2`, `filter_sessions/4`, `group_by_workspace/2`, and `next_attention_session/3` exclude subsessions by default (`include_subsessions: false`), and when `include_subsessions: true`, attach child subsessions hierarchically (`children: [...]`) under their ancestor root session inside the parent's workspace group!
  - `InboxLive` & `SessionLive` drawer: `Subsessions` toggle pill (`Show subsessions (N)`) next to `Needs Attention` / `All Sessions`.
  - `SessionLive` & `ConversationComponents`: header `← Parent session (<sid> #entry)` breadcrumb when viewing a subsession, and a rich `subagent` tool card with live child status pill (driven by `SessionLive`'s existing `@catalog.by_id[child_sid]`!) and one-click **Open subsession →** navigation.

---

## 5. Parallel Implementation Plan (Ready for Last-Time Legacy Subagent Lanes)

All lanes branch off a clean baseline after **Wave 1** lands the shared protocol/catalog contract, allowing **Wave 2** lanes to execute in parallel isolated git worktrees with zero file overlap:

### Wave 1 — Shared Lineage Contract & Settlement Signals (Foundation)
- **Lane L1 (`daemon-lineage-signals`):**
  - **Files:** `lib/h/catalog.ex`, `lib/h/daemon.ex`, `lib/h/daemon/validation.ex`, `lib/h/daemon/workspace.ex`, `lib/h/session/server.ex`, `lib/h/session/server/recovery.ex`, `lib/h/session/server/submissions.ex`, `lib/h/session/server/stream.ex`, `docs/protocol.md`, plus `test/h/catalog_lineage_test.exs` and `test/h/submission_signal_test.exs`.
  - **Scope:**
    1. Add immutable `parent` (`%{session_id, conversation_id, at_entry_id, task_id, depth}`) and `role` to `H.Catalog` (`validate_put_attrs`, `wire_session`, `sessions.json` encode/decode) and `session_meta`.
    2. Validate `parent` in `H.Daemon.Validation.validate_create_session_params/1` & `H.Daemon.create_new_session/3`: verify parent exists, resolve latest `at_entry_id` if omitted, compute `depth`, enforce attach conflict check, and exclude subsessions (`parent != nil`) from `Catalog.annotate_directories/3` and `Workspace.browse/3` root folder session lists by default.
    3. Emit `{:submission_settled, outcome}` on `H.PubSub` topic `{:submission, session_id, request_id}` after `Storage.commit` whenever submissions settle (`done`, `unanswered`, `withdrawn`), and expose race-free `H.Daemon.watch_submission/4` + `Server.get_submission_outcome/2`.

### Wave 2 — Parallel Engine & Client Lanes (3 Concurrent Worktrees)

- **Lane L2a (`engine-parked-subagent` — depends on L1):**
  - **Files:** `lib/h/tools/subagent.ex` (new), `lib/h/harness/coding.ex`, `lib/h/session/server.ex`, `lib/h/session/server/tools.ex`, `lib/h/session/server/generation.ex`, `lib/h/session/server/recovery.ex`, `lib/h/session/server/state.ex`, `lib/h/document.ex`, plus `test/h/subagent_tool_test.exs` and `test/h/subagent_recovery_test.exs`.
  - **Scope:**
    1. Implement coordinator-parked `H.Tools.Subagent` (`wait`, `start`, `await`, `steer`, `abort`, `read_only`, `cwd`, `model`, `thinking`, `title`, `session_id`) with depth-gated offering (`depth < max_subagent_depth`, default `1`).
    2. Support concurrent fan-out for multiple `subagent` calls in a single assistant turn (holding zero `Task.Supervisor` workers while `status == "waiting"`), committing `memos` (`child_session_id`, `child_request_id`, `at_entry_id`) before dispatch.
    3. Wire `:submission_settled` wake-ups into `H.Session.Server`'s drain-batch loop, propagate parent `abort` bottom-up to active owned child sessions, and prove crash + `SIGKILL` VM-restart idempotency (zero duplicate spawns, clean settlement).

- **Lane L2b (`tui-subsessions-cli` — depends on L1):**
  - **Files:** `clients/tui/src/protocol.rs`, `clients/tui/src/cli.rs`, `clients/tui/src/hi/inbox.rs`, `clients/tui/src/hi/app.rs`, `clients/tui/src/hi/cards.rs`, `clients/tui/src/hi/actions.rs`, plus Rust unit/PTY tests in `clients/tui/`.
  - **Scope:**
    1. Decode `SessionParent` & `role` on `SessionSummary` and serialize `parent` / `agent` / `title` on `CreateSessionRequest`.
    2. Add `--model`, `--thinking`, `--title`, `--parent`, `--parent-entry` to `hi` CLI (interactive + `-p` print mode) and `--subsessions` to `hi inbox`; skip subsessions in `pick_latest_session` (`hi -c`).
    3. Update `InboxState`: exempt subsessions by default from display, `counts()`, and `Tab` `cycle_attention()`; add `s` keybind to toggle hierarchical child rendering (`↳`) beneath parent sessions; add `/parent` (`Alt+P`) navigation and `[subagent ...]` transcript cards in `cards.rs`.

- **Lane L2c (`web-subsessions-ui` — depends on L1):**
  - **Files:** `clients/web/lib/h_web/catalog_state.ex`, `clients/web/lib/h_web/live/inbox_live.ex`, `clients/web/lib/h_web/live/inbox_live.html.heex`, `clients/web/lib/h_web/live/workspace_live.ex`, `clients/web/lib/h_web/live/session_live.ex`, `clients/web/lib/h_web/live/session_live.html.heex`, `clients/web/lib/h_web/components/inbox_components.ex`, `clients/web/lib/h_web/components/conversation_components.ex`, `clients/web/assets/css/app.css`, plus LiveView tests in `clients/web/test/h_web/`.
  - **Scope:**
    1. Normalize `parent` and `role` in `HWeb.CatalogState`; exempt subsessions by default from `counts`, `next_attention_session`, `other_attention_count`, and workspace groups.
    2. Add `Show subsessions` toggle in `InboxLive` and `SessionLive` drawer that nests subsessions hierarchically under their parent root session (with cross-cwd worktree badge when `child.cwd != parent.cwd`).
    3. Render `← Parent session` header breadcrumb on subsessions and live-status `subagent` delegation cards with one-click jump links in `ConversationComponents`.

### Wave 3 — Cross-Surface Integration & Cutover Verification
- Cherry-pick L1 → L2a, L2b, L2c into `arch/subagents` (and `main`), run `mix format --check-formatted`, `mix compile --warnings-as-errors`, root `mix test`, `clients/web` `mix test` (extending `multi_surface_sync_test.exs`), and `cargo test --locked` in `clients/tui`.
- Update `docs/architecture.md` and `docs/roadmap.md` to move subagent delegation from proposed to implemented once all storage, crash, and VM-restart tests pass.
