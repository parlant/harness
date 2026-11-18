# Durable Engine Architecture (`H.*` / `:harness`)

**Status:**
- **Implemented (Slices 0–4):** Pure history (`H.Session`, `H.Conversation`, `H.Entry`), pluggable storage (`H.Storage`, `H.Storage.Memory`, `H.Storage.File`, `H.Storage.Conformance`), `H.StoreLock`, `H.Catalog`, `H.Auth`, `H.Schema`, supervised session runtime (`H.Session.Supervisor`, `H.Session.Server`, `H.Daemon`), `H.Provider` (`Fake`, `ReqLLM`), `H.Credentials`, and `H.Context`.
- **Proposed Refinements (Slice 5+):** `{env_id, cwd}` workspace identity in `H.Catalog` (replacing host-coupled `Path.expand/1` in `H.Daemon`), `harness_id` metadata on sessions, and Slice 9 compaction/signals/`WakeScheduler`/`H.Storage.SQLite`.

---

## 1. Role and Non-Goals of the Durable Engine

The durable engine (`:harness`, namespace `H.*`) is a headless, harness-agnostic BEAM runtime that hosts many concurrent durable sessions in a single OS process.

- **What the engine owns:** Conversation ancestry trees, append-only entries, atomic multi-batch storage commits (`seq`), idempotent command admission (`Submission`), effect-sandwiched state machines (`Task`), versioned state documents (`Document`), model provider streaming (`H.Provider`), and zero-copy `ProcBin` event fan-out (`H.PubSub`).
- **What the engine never owns:** Client UI state (Phoenix LiveViews, TUI ANSI layout, scroll cursors, folder picker state), hardcoded coding persona prompts, or direct assumptions that a workspace path lives on the engine's own local filesystem.

To the durable engine, a session's external world is parameterized solely by:
1. A serializable **environment descriptor** (`%{env_id: "host", kind: "host", cwd: "/abs/path"}`) resolved at runtime to an `H.ExecutionEnv.t()` handle.
2. A **`harness_id`** (e.g. `"pi"` / `"coding"`) resolved at runtime via `H.Harness` to a tool list `[module()]` and initial `agent` document defaults.

---

## 2. Four Orthogonal Structures

### 2.1 History Ancestry

A conversation's **own** entries are linear. A fork records `{parent_conversation_id, at_entry_id}` and inherits the parent's visible prefix through `at_entry_id` inclusively (`entry.id <= cutoff`). Entries are immutable and never copied.

```text
session: {env_id, cwd} + conversations
  conversation 1: U1 -> A1 -> U2 -> A2
                         |
  conversation 7:        +--> U3 -> A3
```

Every record and entry ID in a session comes from one **strictly monotonic session-local allocator (`mint_id`)**. Record IDs are distinct from commit revisions (`seq`): a single atomic commit (`seq`) may mint and persist multiple entries, tasks, and document updates.

### 2.2 Work Ownership

A task belongs to a conversation (`{:conversation, id}`) or a parent task (`{:task, id}`). Ownership is persistent, immutable, and governs cancellation and completion joins:
- **Foreground work (default):** Descendants drain before their owner transitions from `completing` to `terminal`. Cancellation flows down ownership edges; normal completion joins bottom-up.
- **Background & suspendable work (Slice 9):** `background: true` detaches side tasks from ordinary `Esc` aborts; `sleeping` tasks wait on deadlines (`until`) or typed `signals` while holding **zero BEAM worker processes**.

### 2.3 Supervision and Per-Session Fault Isolation

OTP supervises live runtime processes; committed checkpoints drive recovery.

```text
H.Application supervisor (:rest_for_one)
  H.StoreLock                # OS-level single-daemon lock (.claim + Unix domain socket)
  Registry (H.Registry)      # :unique session coordinator lookup
  Registry (H.PubSub)        # :duplicate zero-copy ProcBin event fan-out
  H.Auth                     # owner token + constant-time session secret table
  H.Catalog                  # server-owned session index + ETS read table (<data_dir>/catalog/)
  H.WorkspaceLease           # per-{env_id, cwd} mutating tool writer leases
  DynamicSupervisor (H.Session.RuntimeSupervisor)
    H.Session.Supervisor (:one_for_all, restart: :temporary, max_restarts: 2, max_seconds: 5)
      Task.Supervisor        # temporary fenced model & tool effect workers
      H.Session.Server       # single mutation authority for one session
  Bandit (H.HTTP.Router)     # optional loopback JSON + SSE API listener
```

Key OTP invariants:
1. **Blast-radius isolation:** Every `H.Session.Supervisor` runs with `restart: :temporary` under `DynamicSupervisor` and enforces its own `:one_for_all` budget (`max_restarts: 2, max_seconds: 5`). If one session store is corrupt or crash-loops, only that session stops and is marked `"quarantined"` in `H.Catalog`; sibling sessions continue uninterrupted.
2. **Non-blocking coordinator:** `H.Session.Server` never blocks on LLM HTTP streams, OS subprocesses, remote VM RPCs, or slow SSE sockets. It performs only pure in-memory transitions and bounded local storage commits.

### 2.4 Client Navigation

Tree cursors, zippers, and directory browser selections are client-side views over persisted IDs, never coordinator process state. Multiple Web, Mobile, and TUI clients can attach to the same conversation simultaneously or operate on separate forks concurrently.

---

## 3. Single-Writer Store Authority Split (`H.Catalog` vs. `H.Session.Server`)

Every durable store has exactly **one writer**:

- **`H.Catalog` (`<data_dir>/catalog/sessions.json` + ETS `:h_catalog`):**
  Holds cross-session index metadata needed while sessions are unloaded: `session_id`, `title`, `env_id` (default `"host"`), `cwd`, `harness_id`, `root_conversation_id`, `created_at`, `updated_at`, `active`, `next_wake_at`, and `status` (`"ok" | "quarantined"`). All list and directory-annotation queries read directly from ETS in `O(1)`/`O(N_sessions)` memory without waking unloaded sessions.
- **`H.Session.Server` (`<data_dir>/sessions/<session_id>/`):**
  Exclusively owns one session's `H.Storage` instance (`commit.log` + atomic `snapshot.json`). Neither `H.Catalog` nor HTTP/LiveView handlers ever open a session's store directly.

### Durability Rules for Records

Persist only plain JSON-compatible data, string names, integer schema versions, and integer/string IDs. **Never** persist PIDs, refs, functions, ports, sockets, or provider/SSH credentials. Validate external input at the boundary via `H.Schema` and `JSV` without calling `String.to_atom/1`.

---

## 4. Documents, Fork Policies, and History Projections

### 4.1 Versioned Pure-Functional Documents (`H.Document`)

Operational state and harness/app state share one pure document reducer `(doc_value, mutation) -> {new_doc_value, [delta_op]}`:

| Document | Scope & History | Fork Policy | Value on `fork(at_entry_id)` |
|---|---|---|---|
| `agent` (`model`, `thinking`, `system_prompt`, `instructions`, `tools`, `max_turns`) | `:conversation`, `:rewindable` | `:as_of` | Exact configuration committed at `seq_of(at_entry_id)`. |
| `live` (`run`, `generation`, `tools`, `run_failure`) & `inbox` (queued inputs) | `:conversation`, `:latest` | `:initial` | Empty (`%{}` / `[]`); in-flight work never leaks into a fork. |
| `usage` (`input_tokens`, `output_tokens`, `total_tokens`, `cost`) | `:conversation`, `:latest` | `:initial` | Zero; inherited turns are not double-counted. |

### 4.2 Three Projections of History

1. **Raw transcript entries:** Append-only and never truncated. `search_history` queries raw entries across the full lineage, including turns prior to `compaction` or `reset` markers.
2. **Model request context (`H.Context`):** Pure projection from the root or latest `compaction`/`reset` head marker, preserving a stable leading system message for provider prompt caching, carrying reasoning signatures, and synthesizing interrupted `tool_result` blocks when a fork cuts between an assistant `tool_calls` turn and its results.
3. **Client state view (`ConversationTranscript`):** Bounded newest-entry window + committed documents (`agent`, `live`, `inbox`, `usage`) + cursor-paged older entry loading.

---

## 5. Effect Sandwiches, Drain-Batch Commits, and Crash Recovery

### 5.1 Effect Sandwiches & Worker Fencing

Every external side effect (LLM stream or tool invocation) executes in three steps:
1. **Commit intent:** Persist the `running` task checkpoint before starting external I/O.
2. **Execute outside coordinator:** Spawn a temporary worker under `Task.Supervisor` tagged with `{incarnation, task_id, attempt_id}`. Stale messages from prior incarnations are dropped.
3. **Commit outcome:** Persist resulting entries, document deltas, submission settlement, and next task state atomically.

### 5.2 Mailbox Drain-Batch Group Commit

`H.Session.Server` drains up to 32 ready messages from its mailbox per loop turn, stages each against pure evolving state `[batch_1, batch_2, ...]`, and calls `H.Storage.commit(store, batches)` **once** (a single `:file.datasync` or SQLite transaction for the entire drained group).

### 5.3 Durable `seq` vs. Ephemeral Streaming (`persist_within_ms`)

1. **Ephemeral stream frames (~50 ms throttle):** Emit `{:ephemeral_event, ...}` on `H.PubSub` (SSE `event: ephemeral` **without** `id:`) carrying `base_seq` + `doc_ops` so clients render tokens and tool stdout immediately without advancing durable cursors.
2. **Deferred durable flush (`persist_within_ms`, default `1_000 ms`):** Unflushed `live` progress folds into the next structural commit or flushes on timer as `seq + 1` (`event: commit` with `id: <seq>`).

### 5.4 Recovery & Replay Guarantees

- **Boot recovery without client reconnect:** `H.Daemon.recover_active_sessions/1` wakes unfinished active sessions automatically when a fresh BEAM VM starts.
- **Retry & `restart_limit` guards:** Unclean crashes increment `task.restarts` (halting at `restart_limit` instead of crash-looping). Interrupted model streams record an `aborted` partial entry and count against `retry_limit`.
- **No blind side-effect replay:** Tools with `replay: :safe` (`read`, `search_history`) auto-replay after a crash; tools with `replay: :unsafe` (`write`, `edit`, `bash`) **never** auto-replay—they commit an `is_error: true, diagnostic: "interrupted"` result with any flushed partial output so the model can inspect the workspace first.

---

## 6. Security Invariants of the Local Daemon

1. **Filesystem permissions:** `<data_dir>` is `0700`; `<data_dir>/auth.token` is `0600` (256-bit random owner token).
2. **Single-daemon store lock (`H.StoreLock`):** Kernel-bound Unix domain socket (`store.sock`) + `store.claim` prevents two BEAM VMs from corrupting `<data_dir>`, recovering cleanly even after `kill -9`.
3. **Loopback HTTP defenses (`H.HTTP.SecurityPlug`):** Exact `Host` allowlist (`127.0.0.1:<port>` / `[::1]:<port>`) blocks DNS rebinding; constant-time `Bearer` token check for CLI/TUI clients; `HttpOnly; SameSite=Strict` session cookie + exact `Origin` & `Content-Type: application/json` CSRF enforcement for browsers.
4. **Credential isolation (`H.Credentials`):** Provider keys and short-lived OAuth tokens (`token-exchange`) live exclusively in memory, are redacted on inspect/errors, and are stripped (`H_AUTH*`, `H_TOKEN*`, `HARNESS_*`) from tool child environments.
