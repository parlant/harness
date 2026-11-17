# Slice 5: Post-Self-Hosting Evolution and Optional Hex Adapters

**Prerequisite:** Slice 4 self-hosting milestone complete. Everything in this slice is developed **using `H` itself** through its web client.

---

## 1. Append-Only Compaction and `handoff` / `reset`

Long-lived sessions stay fast in memory without ever truncating raw entries:
- **Background & blocking compaction (`H.Task.Compaction`):**
  - `background_tokens` starts summarizing older active-context turns in the background while the conversation keeps running, placing a `compaction` head-marker entry at the next turn boundary.
  - `reserve_tokens` holds the next generation only when the prompt would exceed `context_window - reserve_tokens` (and retries once on provider context-overflow error).
  - Summarization requests omit replayed thinking blocks so large reasoning traces never cause the summarization call itself to overflow.
  - Failed compactions record sticky `live.compaction_failure`; a failed blocking compaction ends the generation with `:model_error` rather than sending an oversized request.
- **`handoff` / `reset`:** Appends a `reset` head-marker entry carrying an explicit handoff note (`H.Context` starts the new window there with the leading system baseline), while `search_history` continues to query every raw entry before the reset.

---

## 2. Subagents, Suspendable Work, and 4-Stage Hooks

Extend `H.Task` and `H.Tool` so sessions can wait hours or days for people, webhooks, or subagents with **zero active BEAM worker processes**:

1. **Ownership & joins:**
   - Tools spawn owned child conversations (`subagent` tool) or child tasks (`waiting` policies `:fail_fast`, `:all_settled`, `:any`), rejecting cycles across both `waiting` edges and held `completing` owners at commit time.
   - `background: true` detaches side work (reminders, background triage) from ordinary `Esc` conversation aborts; `abandon_on_restart: true` cleans up in-memory-awaited children of non-replay-safe tools after crashes.
2. **Signals & parked tools:**
   - `H.Signal` (`define_signal` with version + `H.Schema`): delivered idempotently via `H.Daemon.signal(sid, task_id, token, key, value)` (first-writer-wins; early signals arriving before `sleeping` are buffered on the task).
   - Tools return `{:park, {:sleep, signals: [...], until: ts, checkpoint: state} | {:wait, on: [...], policy: p, checkpoint: state}}`. Waking commits wake intent before invoking tool code again so unsafe tools never execute twice; `cancel/3` cleans up parked external work on abort.
3. **4-Stage hooks & web approval gates:**
   - Compose registered hooks strictly as `transform -> check -> claim -> observe` (observers muted; per-conversation tool filtering never disables `check`/`observe` hooks).
   - An approval `check` hook sleeps on an `approvals.decision` signal (keyed by canonical argument digest) and registers an open `PersonWait` in `H.Catalog` / `H.WakeScheduler`, rendered as an **Allow / Deny** card directly in the web client.
4. **`H.WakeScheduler` & idle session unloading:**
   - `H.Session.Server` reports `wake() -> %{active: boolean(), at: integer() | nil}` to `H.WakeScheduler`. When `active == false` and no SSE watchers remain past the idle grace window, `H.Session.Server` unloads (`{:stop, :normal, state}`); `H.WakeScheduler` restarts the session automatically when `at` arrives or a `signal` is delivered.

---

## 3. Agreed SQLite Backend and Optional Hex Ecosystem Adapters

Remember `AGENTS.md`: **agree before adding persistence/transport Hex dependencies**, verify `elixir:` version compatibility, and prefer mature release ages over brand-new same-day publishes.

### 3.1 `H.Storage.SQLite` (`{:exqlite, "~> 0.43"}`) — Agreed Relational Storage

When single-file SQLite session stores, lower working-set memory on 100k+ entry histories, or SQL-indexed scans are wanted:
- Add `{:exqlite, "~> 0.43"}` (direct SQLite3 NIF without pulling in full Ecto SQL migrations unless desired).
- Configure `PRAGMA journal_mode = WAL`, `PRAGMA synchronous = NORMAL` (or `FULL` per durability setting), `PRAGMA busy_timeout = 5000`, and `PRAGMA foreign_keys = ON`.
- Implement `H.Storage.SQLite` behind `H.Storage` (multi-row batched writes per table in one `BEGIN IMMEDIATE ... COMMIT` transaction for `commit(batches)`) and verify it against the exact same **`H.Storage.Conformance`** suite as `H.Storage.Memory` and `H.Storage.File`.
- Provide a 30-line import/export task between `H.Storage.File` and `H.Storage.SQLite` so existing self-hosted sessions migrate losslessly.

### 3.2 Optional Later Extensions (Only When Concrete Needs Arise)

| Need | Hex Package Candidates | Seam |
|---|---|---|
| Bidirectional WebSockets (e.g. interactive PTY terminal or live voice) | `{:websock_adapter, "~> 0.7"}` (runs directly on Slice 2's `Bandit` server) | Upgrade route in `H.HTTP.Router` calling `H.Daemon` / `H.PubSub`. |
| Multi-host shared relational database | `{:postgrex, "~> 0.20"}` | `H.Storage.Postgres` passing `H.Storage.Conformance` + advisory/lease fencing. |
| Remote / sandboxed tool execution | SSH (`:ssh` OTP stdlib or RPC daemon) / container / QEMU | `H.ExecutionEnv.SSH` / `H.ExecutionEnv.Sandbox` passing `H.ExecutionEnv.Conformance`. |
