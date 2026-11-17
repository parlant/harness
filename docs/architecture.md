# Architecture

**Status:**
- **Implemented (Slices 0–4 Self-Hosting Core):** Pure history (`H.Session`, `H.Conversation`, `H.Entry`), pluggable storage (`H.Storage.Memory`, `H.Storage.File`, `H.Storage.Conformance`), `H.StoreLock`, `H.Catalog`, `H.Auth`, `H.Schema`, supervised per-session coordinator (`H.Session.Supervisor`, `H.Session.Server`, `H.Daemon`), `Bandit` + `Plug` HTTP/SSE daemon + zero-build web client (`H.HTTP.*`, `priv/static/*`), `Req` + `ReqLLM` streaming loop (`H.Provider.Fake`, `H.Provider.ReqLLM`, `H.Context`, `H.Credentials`), and `H.ExecutionEnv.Local` + `H.WorkspaceLease` + `JSV`-validated coding tools (`read`, `write`, `edit`, `bash`, `search_history`).
- **Post-Self-Hosting Proposal (Slice 5+):** Background/blocking compaction, subagents & suspendable work (`sleeping` on `signals`, parked tools, 4-stage hooks/gates, `WakeScheduler`), `H.Storage.SQLite` (`exqlite`), and session share grants.

---

## 1. Scope and Self-Hosting Philosophy

One local BEAM OS process (`:harness`) hosts many durable sessions under `H`. A session is a durable workspace-scoped aggregate, not a terminal, socket, PID, or browser tab. Its conversations can be simple request/response chats or tool-using coding agents.

We retain Pi Durable's execution, scheduling, document, and recovery semantics—not its TypeScript object model:
- Where Node-based hosts (`p2`/`p3`) pay ~170–290 MiB RSS per live session worker and wrap objects in JavaScript `Proxy` traps to synthesize immutable state deltas, one BEAM VM hosts hundreds of isolated session processes at kilobyte base overhead and updates immutable structs with pure functions.
- To reach **web-based self-hosting** quickly without bloat, Slice 1 keeps storage dependency-free on **Elixir 1.20 / OTP 29** (`JSON`, `Registry`, `DynamicSupervisor`, `Task.Supervisor`, `:file` `:raw` + `:erlang.crc32/1`, Unix socket lock), and Slice 2 adds only the focused Elixir HTTP + LLM stack (**`Bandit`, `Plug`, `Req`, and `ReqLLM`**) plus vanilla browser ES modules (`EventSource` + `fetch`, zero npm/bundler tooling).
- Every external boundary (`H.Storage`, `H.Provider`, `H.ExecutionEnv`, `H.Tool`) is a small Elixir behaviour so relational storage (`H.Storage.SQLite` via `exqlite`) or remote sandboxes plug in cleanly after self-hosting without touching domain or session code.

The first deployment is one trusted local owner on one host. Clustering, multi-writer failover, downloaded untrusted client code, and a general plugin marketplace are non-goals before self-hosting.

---

## 2. Four Structures, Not One Tree

### History

A conversation's **own** entries are linear. A fork adds `{parent_conversation_id, at_entry_id}` and inherits the parent's visible prefix through that concrete entry, inclusively. The fork's own entries continue after that prefix. Entries remain immutable and are never copied.

```text
session: working directory + conversations
  conversation 1: U1 -> A1 -> U2 -> A2
                         |
  conversation 7:        +--> U3 -> A3
```

This is a conversation ancestry forest, with a message-tree projection for navigation. Independent conversations have no history parent. Conversation `1` is the distinguished root.

A nested fork can cut at an inherited entry (`min(at, ancestor_cutoff)`). Every record and entry ID in a session comes from one **strictly monotonic session-local integer sequence (`mint_id`)**: fork cutoff visibility (`entry.id <= cutoff`) relies on this monotonic causal ordering. Record IDs are not commit revisions (`seq`): one atomic commit (`seq`) may mint and write several entries, tasks, and document updates.

### Work Ownership

A task belongs to a conversation (`{:conversation, id}`) or another task (`{:task, id}`). A subagent conversation can belong to a task, independently of its history parent (`:ownerless` for user-created branches). Ownership is persistent and immutable, and governs cancellation and joins, not authorization.

- **Foreground work (default):** Descendants drain before their owner transitions from `completing` to `terminal`. Failure/cancellation flows down ownership edges bottom-up; successful completion waits.
- **Background work (`background: true`, Slice 5):** Belongs to a conversation for lifecycle tracking, but the conversation goes idle while it runs and ordinary `Esc`/abort leaves it alone unless `{background: true}` is passed or the task itself is aborted.
- **Ephemeral caller waits (`abandon_on_restart: true`, Slice 5):** Child tasks awaited only in memory by a non-replay-safe caller are aborted on crash recovery (`abort_reason: :restart`) before scheduling resumes.

Waiting introduces a separate dependency graph (`waiting` on task IDs with `:fail_fast`, `:all_settled`, or `:any`). Reject cycles across durable waits and held owners at commit time; never express durable waits as OTP supervisor links. Tasks and tools can also park in `sleeping` status waiting on a deadline (`until`), typed external `signals` (Slice 5), or both, holding **zero worker processes** while parked.

### Supervision and Session Fault Isolation

OTP supervises live runtime machinery; stored checkpoints drive durable recovery.

```text
H.Application supervisor (:rest_for_one)
  H.StoreLock                # OS-level single-daemon lock (.claim + Unix domain socket)
  Registry (H.Registry)      # :unique coordinator lookup
  Registry (H.PubSub)        # :duplicate zero-copy ProcBin SSE fan-out
  H.Catalog                  # server-owned session index + ETS read table (<data_dir>/catalog/)
  H.WakeScheduler            # durable next_wake_at timers + WaitIndex routing (Slice 5)
  DynamicSupervisor (H.Session.RuntimeSupervisor)
    H.Session.Supervisor (:one_for_all, restart: :temporary, max_restarts: 2, max_seconds: 5)
      Task.Supervisor        # temporary in-flight model/tool effect workers
      H.Session.Server       # single mutation authority for one session
  H.HTTP.Supervisor          # loopback HTTP/JSON + SSE listener & connection pool
```

Critical OTP invariants:
1. **Per-session blast-radius isolation:** `DynamicSupervisor` shares one `max_restarts` budget across all children. Therefore each `H.Session.Supervisor` is registered under `DynamicSupervisor` as **`restart: :temporary`** and enforces its own `:one_for_all` restart budget (`max_restarts: 2, max_seconds: 5`) internally. A transient crash in `H.Session.Server` terminates its `Task.Supervisor` effect workers and recovers under a new fenced incarnation; if a session's store is corrupt or hits 3 crashes in 5 seconds, only that `H.Session.Supervisor` stops and marks the session `:quarantined` in `H.Catalog`, leaving all other sessions untouched.
2. **True idle hibernation and unloading:** Calling `:hibernate` on a `GenServer` whose state still references large maps only compacts those maps at high CPU cost without freeing RAM. When `wake() -> %{active: false, at: next_at}`, `H.Session.Server` reports `{active: false, next_wake_at: next_at}` to `H.Catalog` / `H.WakeScheduler`, evicts rebuildable caches (`context_cache` and unwatched `doc_cache`), and either hibernates with minimal state (while SSE watchers are attached) or stops cleanly (`{:stop, :normal, state}`) after an idle grace window when no watchers remain.
3. **Never block the coordinator:** `H.Session.Server` never awaits a model call, tool execution, human approval, or slow SSE socket. It executes only in-memory validation/reduction and short local storage commits.

### Client Navigation

A zipper or tree cursor is a client-side view over persisted conversation and entry IDs, never stored server process state.

Each browser tab or CLI client owns its selected session, conversation, scroll cursor, folds, and unsent draft. Navigating history changes no agent state. Continuing from an earlier turn explicitly creates or selects a fork; every mutating command names its target `conversation_id`. Multiple browser tabs can watch the same branch in lockstep or work on different branches concurrently.

---

## 3. Domain Records and Separate Store Authorities

### Store Authority Split (`H.Catalog` vs `H.Session.Server`)

Every store has **one writer**:
- **`H.Catalog`** owns `<data_dir>/catalog/` (backed by an ETS read table for `O(1)` concurrent reads). It holds session metadata needed while a session is unloaded: `session_id`, `title`, `cwd`, `root_conversation_id`, `created_at`, `updated_at`, `active`, `next_wake_at`, and `status` (`:ok | :quarantined`), plus pending server-side metadata edits (such as a title rename made while unloaded).
- **`H.Session.Server`** exclusively owns `<data_dir>/sessions/<session_id>/`. `H.Catalog` and HTTP handlers **never** open a session's storage directly for writes. When `H.Session.Server` opens or updates session summary fields, it pushes only the fields it owns to `H.Catalog`.

### Session Domain Records

| Record | Slice | Meaning |
|---|---|---|
| `Session` | 0 (pure), 1 (durable) | Stable identity; default absolute `cwd`; root conversation `1`; monotonic `seq` revision, `next_id`, and runtime `incarnation`. |
| `Conversation` | 0 (pure), 1 (durable) | Own ordered entry segment; optional history `parent: %{conversation_id, at}`; explicit `owner` (`:ownerless`, `{:conversation, id}`, `{:task, id}`). |
| `Entry` | 0 (pure), 1 (durable) | Immutable `id`, `conversation_id`, `seq`, `kind`, and JSON-compatible `data` (including optional head markers for `compaction` and `reset`/`handoff`). |
| `Submission` | 1 | Idempotent receipt keyed by `request_id`: kind (`input`, `continue`, `write`), payload `fingerprint`, `status` (`queued`, `placed`, `done`, `unanswered`), `entry_id`, `answer_entry_id`, failure `reason`, optional `notify: {task_id, key}` (Slice 5). |
| `Task` | 1 (core), 5 (ext) | Versioned durable state machine (`pending`, `running`, `waiting`, `sleeping`, `completing`, `terminal`): `kind`, `version`, `owner`, `checkpoint`, `outcome`, `restarts` counter, first-writer-wins `memos`, cancellation intent, `started_at`/`ended_at`, plus `wake` reason, `signals`, `background`, and `abandon_on_restart` in Slice 5. |
| `Document` | 1 | Versioned JSON-compatible state (`kind`, `version`, `scope: :session \| :conversation \| :task`, `history: :latest \| :rewindable`, `fork: :as_of \| :current \| :initial`), updated in the same atomic commit as entries and tasks. |
| `Signal` | 5 | Typed, versioned external payload delivered idempotently by `{task_id, token, key}` to wake a `sleeping` task or buffer an early arrival. |

Persist plain data, string names, integer versions, and IDs. Never persist PIDs, references, functions, ports, sockets, or provider credentials. Validate external JSON at the boundary without calling `String.to_atom/1`.

### Three Projections of History

1. **Raw transcript entries:** Append-only and never truncated by compaction or reset. `search_history` (Slice 4) scans raw entries by range or substring so long-running sessions never lose detail after compaction.
2. **Model request context (`H.Context`):** Derived from the conversation root or latest head marker (`compaction` summary or `reset`/`handoff` note), always leading with the initial system baseline so provider prompt caches stay valid. Aborted partial responses remain auditable in raw entries, and the context reducer synthesizes interrupted tool results whenever a fork cut leaves a tool call unpaired.
3. **UI state view:** Bounded newest-entry window plus committed conversation documents (`live`, `inbox`, `agent`, `usage`) and gap-aware paging of older entries.

---

## 4. Fork Semantics and Pure Functional Documents

Both built-in operational state (`agent`, `live`, `inbox`, `usage`) and later application state (`todos`, artifacts, per-task nested calls) use the same **versioned document** model:

| Document | Scope & History | Fork policy (`fork`) | Child value on `fork(at_entry_id)` |
|---|---|---|---|
| `agent` (provider/model, thinking, instructions, selected tools, `max_turns`, compaction) | `:conversation`, `:rewindable` | `:as_of` | Value committed as of `at_entry_id`. |
| Provider cache/session identity | `:conversation`, `:latest` | `:initial` | Fresh, generated once per conversation. |
| `inbox` (queued inputs) & `live` (active `run`, streaming `generation`, active `tools`, sticky `run_failure` / `compaction_failure`) | `:conversation`, `:latest` | `:initial` | Empty; live tasks, queued prompts, and partials never leak into a fork. |
| `usage` (token/cost/duration rollups) | `:conversation`, `:latest` | `:initial` | Zero; inherited history is not billed twice. |
| Rewindable app documents (e.g. `app.todos`, canvas) | `:conversation`, `:rewindable` | `:as_of` or `:current` | Explicit per document definition. |
| Session-wide preferences/state | `:session`, `:latest` | N/A (shared) | Shared across the session. |
| Working tree / files | `H.ExecutionEnv` | Unchanged | Forking history never clones or rewinds git/files. |

In Elixir, documents need no `Proxy` draft machinery: a document transition is a pure function `(doc_value, mutation) -> {new_doc_value, [delta_op]}`. `:latest` documents store their current snapshot (plus compact deltas on the log); `:rewindable` documents (`agent`, and later `:as_of` app docs) tag revisions with commit `seq` so `snapshot_as_of(seq_of(at_entry_id))` is exact.

---

## 5. Durability: Effect Sandwiches, Drain-Batch Commits, and Ephemeral Progress

Every side-effecting step in `H` is an **effect sandwich**:
1. **Intent (commit before):** Validate inputs and atomically persist the task checkpoint/intent before touching any external system.
2. **Effect (execute outside commit):** Run the LLM stream or tool execution in a temporary `Task.Supervisor` worker carrying `{session_incarnation, task_id, attempt_id}` (and an external idempotency key if supported).
3. **Outcome (commit after):** Atomically persist the result entry, document updates, submission settlement, and next task phase.

### Drain-Batch Group Commit (Simple, Non-Speculative)

We do **not** run speculative transaction callbacks over uncommitted keys. Instead, `H.Session.Server` achieves group-commit batching cleanly via OTP mailbox draining:
- Commands and worker completions arrive in `H.Session.Server`'s mailbox.
- In one turn of its loop, `H.Session.Server` drains up to `N` (e.g. 32) ready messages from its mailbox, stages each against the evolving pure state as an ordered list of logical commit batches `[batch_1, batch_2, ...]`, and calls `H.Storage.commit(store, batches)` **once** (one disk `datasync` / SQLite transaction for the whole drained group).
- Each accepted batch gets its own monotonic `seq`. If a batch fails a domain check, earlier batches in the prefix stand and that caller receives `{:error, reason}`. If `H.Storage.commit/2` returns an I/O error, nothing is published as committed and `H.Session.Server` stops closed (`{:stop, {:storage_failed, err}, state}`).

### Durable `seq` vs Ephemeral Streaming Progress (`persist_within_ms`)

Streaming every LLM token to disk synchronously wastes I/O, while assigning durable `seq` numbers to unpersisted chunks breaks SSE `Last-Event-ID` if the VM crashes before flush. `H` separates them cleanly:
1. **Ephemeral live progress (every ~50–100 ms):** Worker chunks update in-memory `live.generation` / `live.tools` state and broadcast an SSE `event: ephemeral` frame (**no SSE `id:` line**, carrying `base_seq` + `doc_ops`). Browser `EventSource` renders live tokens immediately while keeping `lastEventId == base_seq`.
2. **Deferred durable checkpoint (`persist_within_ms`, default `1_000 ms`):** Unflushed `live` progress is folded into the next structural commit (message end, tool end, run end) or flushed by a 1-second timer as a real durable commit (`seq + 1`), emitting `event: commit` with `id: <seq>`. A VM crash loses at most ~1 second of partial stream text and **never** creates duplicate or rolled-back `seq` IDs.

### Working-Set Bounds

- **Active window, not full history:** `H.Session.Server` holds conversation metadata, live tasks, active documents, and an incremental derived context cache per active conversation (evicted after `context_retention_ms`, default 10 min). Raw historical entries are paged from `H.Storage` on demand.
- **Bounded request-ID cache + durable lookup:** Recent `request_id` receipts stay cached in memory; older retries look up the persisted `Submission` index in `H.Storage`.

### Crash Recovery, Retry Accounting, and `restart_limit`

| Scenario | Behavior |
|---|---|
| Client disconnects or HTTP request times out | Admitted work continues; retrying the same `request_id` + payload returns the existing `Submission` receipt. |
| Clean daemon shutdown (`close`) | Terminates active effect workers and writes `running` tasks back as `pending` **without** incrementing `restarts`. |
| Unclean crash before/during effect | On reopen, `running` tasks increment `restarts`. At `restart_limit` (default 5 consecutive cutoffs without advancing phase), the task/run terminates visibly with `:restart_limit` instead of crash-looping forever. |
| Model stream interrupted by crash | Committed partial output is preserved as an aborted entry; the interrupted attempt counts against the retry budget and enters `sleeping` backoff, ending the run with sticky `run_failure: :interrupted` when retries exhaust. |
| Tool execution interrupted by crash | Re-runs automatically **only** if the tool declares `replay: :safe` (or reattaches via persisted task `memos`); unsafe tools (`write`, `edit`, `bash`) record an `:interrupted` error tool-result carrying any output flushed so far so the model can inspect the workspace and decide next steps. |

---

## 6. Submissions, Concurrency, and Workspace Leases

Every mutating command carries a client-generated `request_id`. Same `(session_id, request_id)` + identical payload fingerprint returns the original receipt; a different payload returns `409 Conflict`.

Three submission kinds handle conversation turns:
1. **`input`:** Appends a user entry and starts/joins a run. `when_busy` is `:follow_up` (queue for next run), `:steer` (inject at next tool-round boundary), or `:reject`. Passing `when_idle: :reject` with `when_busy: :steer` steers an active run or rejects atomically if the run already ended.
2. **`continue`:** Admitted only when idle; starts a new run on existing context without adding a user message (used after `:interrupted`, `:model_error`, or `:turn_limit` `run_failure`).
3. **`write`:** Display-only entry with no model turn; settles `done` immediately.

One active run at a time per conversation, bounded by optional `max_turns`. Because concurrent coding runs editing the same checkout clobber each other, mutating coding tools (`write`, `edit`, `bash`) acquire a **per-workspace writer lease** (`cwd` binding) by default; read-only forks (`read`, `search_history`, chat) run freely in parallel, and parallel coding branches use separate Git worktrees.

---

## 7. Behaviour Seams and OTP 29 / Hex.pm Alignment

### Core Behaviours

1. **`H.Storage`:** `open/1`, `close/1`, `mint_id/1`, `commit/2` (multi-batch prefix commit), record/document getters, and bidirectional (`:asc | :desc`) cursor-paged scans. Verified by `H.Storage.Conformance`.
2. **`H.Provider`:** `stream_chat/3` emitting structured deltas (`:thinking_delta`, `:text_delta`, `:tool_call_delta`, `:usage`, `:done`, `:error`), keeping provider thought signatures and structured tool calls intact. Credentials come from `H.Credentials` (`token-exchange` CLI / env in memory), never from durable session state.
3. **`H.ExecutionEnv`:** Pluggable filesystem and command boundary (`read_file_lines/3` with `no_follow` symlink check, `write_file/3`, `list_dir/3`, `exec/3` accepting direct `argv` or shell command with deadlines and source-side `window` + `skipped` byte truncation). Verified by `H.ExecutionEnv.Conformance`.
4. **`H.Tool`:** Name, description, parameter JSON schema, `replay: :safe | :unsafe`, and `execute/3`.

### Elixir 1.20 / OTP 29 + Pragmatic Hex Stack Alignment

Slices 0–1 use zero external packages (`deps: []`). Slice 2 introduces the agreed 4-package HTTP + LLM stack (`{:bandit, "~> 1.14"}`, `{:plug, "~> 1.20"}`, `{:req, "~> 0.7.5"}`, `{:req_llm, "~> 1.30"}`) so we get production HTTP/SSE serving and multi-provider LLM streaming right away without database NIFs or frontend bundlers:

| Layer | Self-Hosting Stack (Slices 0–4) | Post-Self-Hosting Seam (Slice 5+, Optional) |
|---|---|---|
| **JSON** | `Elixir.JSON` (OTP native C/JIT `:json`, iodata encoding) | None needed |
| **PubSub & Lookup** | OTP `Registry` (`:unique` coordinators + `:duplicate` zero-copy `ProcBin` broadcast) | `phoenix_pubsub` only if multi-node clustering is added |
| **Durable Storage** | `H.Storage.Memory` + `H.Storage.File` (`:file` `:raw` CRC32-framed commit log + atomic temp-file/rename snapshots + Unix-socket `.claim` lock — zero DB NIFs) | `exqlite` (`~> 0.43`) for agreed `H.Storage.SQLite`; `postgrex` for multi-host |
| **HTTP + SSE Daemon** | `Bandit` (`~> 1.14`) + `Plug` (`~> 1.20`): `Plug.Router`, `Plug.Static` (`priv/static/`), `Plug.Parsers` (`json_decoder: JSON`), and chunked SSE (`send_chunked/2` + `chunk/2`) | `websock_adapter` (`~> 0.7`) on `Bandit` if interactive PTY/voice WebSockets are needed |
| **Web Client** | Vanilla HTML + CSS + native browser ES modules (`EventSource` + `fetch`, zero npm/bundler step) in `priv/static/` | Richer UI / TUI surfaces over the same HTTP/SSE contract |
| **LLM Streaming & Catalog** | `Req` (`~> 0.7.5`) + `ReqLLM` (`~> 1.30`): `ReqLLM.stream_text/3` + `StreamResponse.events/1` over Finch, `LLMDB` catalog, `StreamResponse.close/1` on abort, and external `token-exchange` `access_token` injection on `:google_vertex` | Custom `H.Provider` adapters if bespoke transports arise |
| **Process Execution** | OTP `Port.open({:spawn_executable, ...}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, ...])` — OTP's `erl_child_setup` calls `setsid()`, making `SID == PGID == os_pid` on macOS & Linux so `kill -TERM -<os_pid>` -> `kill -KILL -<os_pid>` reaps all grandchildren cleanly without C NIFs | Remote SSH / container / QEMU sandbox `H.ExecutionEnv` adapters |
| **Validation** | Pattern-matched `H.Schema` envelope checks + `JSV` JSON Schema tool-argument validation (included via `:req_llm`, zero dynamic atom creation) | `ecto` (`~> 3.14` embedded schemas) only if needed |

### Post-Self-Hosting Extensions (Slice 5+)

Once `H` is self-hosting in Slice 4, Slice 5 extends the task/tool loop without changing Slice 1–4 record layouts:
- **Suspendable work:** `sleeping` tasks waiting on `signals` (`H.Session.signal/4` with early-arrival buffering), tools returning `{:park, {:sleep, ...} | {:wait, ...}}` (holding zero processes and committing wake intent before resuming), and `H.WakeScheduler` / `WaitIndex` waking unloaded sessions on timer or webhook/human answer.
- **Deterministic 4-stage hooks:** Extensions register hooks composed strictly as `transform -> check -> claim -> observe` (observers muted; `check` hooks may block or sleep as approval gates; per-conversation tool filtering never disables `check`/`observe` hooks).
- **Nested & deferred tools:** `execute_tool` keyed child tool calls with `structured_output`, and `deferred: true` tools loaded on demand via `tool_search`.

---

## 8. Upgradeability and Malleability

Start with controlled restart/recovery, not transparent OTP `code_change/3` hot upgrades:
- Version storage envelopes, task checkpoints, documents, and the HTTP wire protocol independently (`version: 1`).
- Tasks and documents persist string `kind` names and integer `version`s. Missing or newer definitions block the affected task (`blocked: :missing_task | :task_too_old | :migration_failed`) without deleting its state or crashing the session.
- Pin each running attempt's model options, tool set, replay policy, and `cwd` binding when preparing the attempt; apply `configure` changes at the next turn boundary.

---

## 9. Security Boundary

BEAM processes isolate faults, not hostile OS actions: a local `cwd` is not a sandbox.

### Localhost HTTP/Browser Security (`H.HTTP`)

Loopback alone is **not** authentication or CSRF protection (another local user can connect to `127.0.0.1`, and a malicious website open in another browser tab can attempt cross-origin `POST` or DNS rebinding against `localhost`):
1. **Store & token permissions:** `<data_dir>` (`0700`) holds a generated 256-bit owner secret (`<data_dir>/auth.token`, `0600`).
2. **Anti-DNS-rebinding `Host` guard:** Reject every HTTP request whose `Host` header is not the exact bound loopback literal (`127.0.0.1:<port>` or `[::1]:<port>`).
3. **Dual auth for CLI (`Bearer`) and Browser (`EventSource` Cookie + CSRF):**
   - `curl`, scripts, and tests authenticate via `Authorization: Bearer <token>` (compared in constant time via `:crypto.hash_equals/2`).
   - Because browser `EventSource` cannot send custom headers, the web UI exchanges the owner token once at `POST /api/v1/auth/session` for `Set-Cookie: h_owner=<random_session_secret>; HttpOnly; SameSite=Strict; Path=/api` (never passing secrets in SSE query strings).
   - Every mutating `POST` requires **either** a valid `Authorization: Bearer` header **or** (`h_owner` cookie **AND** exact `Origin: http://127.0.0.1:<port>` **AND** `Content-Type: application/json`).

### OS Subprocess Hygiene (`H.ExecutionEnv.Local`)

- Spawn commands via `Port.open({:spawn_executable, ...})` (`erl_child_setup` sets `SID == PGID == os_pid`).
- Track the exact `os_pid` per invocation; on timeout, abort, or worker exit, signal the negative PGID (`kill -TERM -<os_pid>`, grace wait, `kill -KILL -<os_pid>`)—never `pkill` by pattern.
- Strip daemon-internal secrets (such as `H` auth tokens) from child environment variables.

### Sharing Boundary (Post-Self-Hosting)

When session sharing is added later: anyone granted `Join` (`may_send`) reaches everything that session's tools and `ExecutionEnv` reach; shares default to read-only `Watch` (`may_view` only) with expiry; approvals remain strictly owner-only; revoking a share fences its revision immediately without aborting already-running work.
