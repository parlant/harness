# Mario Zechner on Pi Durable: First-Person Corpus & Elixir/BEAM Architectural Comparison

This document collects public talks, interviews, blog posts, and first-person technical specifications where **Mario Zechner (`@badlogic`) himself speaks or writes** about `pi-durable`, and compares his design with `diy-harness` on Elixir/BEAM.

---

## 1. Primary Sources by Mario Zechner

### 1.1 Talks & Spoken Interviews

1. **"WTF is Pi Durable" — Vienna AI Engineering Meetup (2026-11-10, published 2026-11-15)**
   - **URL:** https://www.youtube.com/watch?v=EreOxs9Vvrg
   - **Local Transcript:** [`research/2026-11-10-mario-zechner-wtf-is-pi-durable-transcript.md`](./2026-11-10-mario-zechner-wtf-is-pi-durable-transcript.md)
   - **Core topics covered by Mario:**
     - Why terminal coding agents (`Ctrl-C` loses in-flight tool state; manual `"continue"` after crash) fail for Slack bots, Cloudflare Durable Objects, mobile phones, and robots (`00:00:50`–`00:03:24`).
     - Why **event sourcing fails** for multi-year agents (cannot replay millions of token/tool events or hold entire session trees in RAM) and why Pi Durable uses **serialized atomic state commits** and **tasks with phases** (`00:05:05`–`00:08:01`).
     - Pluggable **registry** (hot-swapping tools, prompt sections, wrappers, and task versions while running), **storage** (SQLite, Postgres, Cloudflare DO, JSONL) with **group-batched commits**, and **execution environments** (`ExecutionEnv` abstracting local, Termux on Android, Cloudflare computer, or a remote QEMU sandbox on Hetzner) (`00:08:01`–`00:10:52`, `00:30:40`–`00:35:41`).
     - **Multi-conversation sessions & forks:** A single harness instance manages a root conversation (e.g. a Slack channel) and forks child conversations at specific entries (e.g. Slack threads or clean branches before a "poisoned" turn) without copying history or re-instantiating the harness (`00:10:52`–`00:11:55`, `00:37:15`–`00:37:50`).
     - **Submission idempotency (`requestId` / `"job-42"`):** Deduplicating retried client submissions or duplicate Slack mentions and attaching callers to the existing submission handle (`00:11:55`–`00:14:25`).
     - **Documents (`defineDoc`) & Delta Views instead of Events:** Storing agent and application state (`pi.live`, `app.todos`) as versioned, migratable JSON documents with explicit `scope` (`session` vs `conversation`), `history` (`latest` vs `rewindable`), and `fork` (`asOf` vs `current` vs `initial`) semantics; emitting initial snapshots plus delta operations fanned out identically to 50–250+ concurrent viewers (`00:14:25`–`00:15:47`, `00:21:45`–`00:26:40`).
     - **Honest side effects, replay safety, and task memos:** Distinguishing `replay: "safe"` (`search_issues`) from unsafe tools (`bash`, `deploy`), reporting unsafe interrupted tools to the model instead of re-running them, or making side-effecting tools replay-safe via external idempotency keys persisted in task memos (`00:17:31`–`00:20:35`, `00:26:40`–`00:27:41`).
     - **Custom phased tasks & durable timers:** Implementing a 9-hour reminder tool as a two-phase durable task (`wait` -> `deliver`) that survives process crashes (`00:20:35`–`00:21:45`).
     - **Cloudflare Durable Object alarm handoff:** Surviving 15-minute V8 isolate eviction by scheduling an alarm and calling `harness.resume()` on wake (`00:28:06`–`00:30:40`).
     - **Long-term context management:** Combining compaction with a replay-safe `search_history` tool over raw un-truncated storage entries (`00:36:05`–`00:37:15`).
     - **Multiplayer reality check:** Collaborative pair-coding in one session is rare in practice; multiplayer shines for shared team channels (Slack/Discord triage, issue filing, inbox queries) and read-only live observation (`00:37:50`–`00:39:16`).

2. **"Pi Durable: Agents That Survive Crashes" — 0xSero Interview with Mario Zechner & Armin Ronacher (2026-10-07)**
   - **URL:** https://www.youtube.com/watch?v=ja_7AF54OtE
   - **Key direct quotes and architectural explanations by Mario Zechner:**
     - **Durability in five sentences (`20:36`–`21:44`):**
       > *"Agent starts up in a process, agent calls tools, process dies. What you want is: restart the process, agent continues exactly from where it left off. That is durability. Without you having to type continue and without tool results or assistant streams getting lost, with your application state being also persisted durably and reliably resumed from... And the other thing that Pi Durable solves is that historically Pi has loaded the entire conversation basically, or the entire tree as it is in Pi, into memory, and that obviously also won't work if you have a Slack bot that lives in your Slack for years and years and there's like a gazillion messages in its full conversation trace."*
     - **The "Effect Sandwich" vs Event Sourcing (`22:28`–`26:55`):**
       > *"We don't do event sourcing. That is what everybody else is doing, and we don't do that because there is a lot of problems... The basic problem of durability is that you are executing something; it can break either before you start executing it, while you are executing it, or after you've executed it. And the thing that you execute is commonly referred to as an effect.*
       > *1. Before I execute the thing, I store something in some storage that says: I'm about to execute this thing with these parameters/inputs. If my process dies now before I executed the thing but already stored this intent, I can restart, look into my database, and see there was a thing that's about to happen with these inputs.*
       > *2. The second part where you can crash is when the effect is actually running... With GitHub Actions, I can say I'm about to schedule a run before it runs, and you get a key, and then you can save that before you actually execute that run. If it already runs, GitHub tells me it's already running, fine, I just wait... That is what's called idempotency.*
       > *3. Once that effect has finished, I get a result back and I store that result, and then my effect sandwich of intent, execution of the effect, and storage of the result of the effect is done. And then I never have to think about it again.*
       > *Basically everything that happens in the harness is a task that is just this effect sandwich... One task can spawn another task and wait for it to stop. And that's the whole magic."*
     - **Versioned Document Store & JavaScript Proxies (`27:11`–`31:15`):**
       > *"For application state, we built a tiny little document store with the special feature that... in the transcript at time zero, the document had that value, say a to-do list or a canvas where I can draw strokes... Now, if I want to go back in time, which version of the document do I want at that point? Sometimes you want the version at that time (`asOf`). Other times, I just want the latest version (`current`). Our document store allows these two types of documents to be associated with any position inside of your transcript...*
       > *We looked at JSON Patch (RFC) first and I found it to be lacking for this use case, so we came up with something similar optimized for agentic stuff... We also use a Proxy approach: I say to the storage, give me this document, you get a JavaScript object, I can say `object.x = 10`, and that gets automatically recorded as an operation. Which is basically a hack, a slow hack, to be exact. But it works really well for the things we need to do in an agentic harness."*
     - **Pi Mobile (`PIM`) & Multi-Machine Topologies (`46:30`–`48:05`):**
       > *"I think Pi is an initial proof of concept for self-modifiable agentic software. Worked out. And now we need to evolve that into a direction where it becomes less 'I and the clanker' and more 'many clankers on many machines talking to many humans'... PIM works entirely on my phone except for the LLM. It can also just connect to any of my other machines as the execution environment. So it goes to my Hetzner and then does sysadmin there for me while the brain runs on the phone."*
     - **Security of Agent-Modified Views & Shared Sessions (`48:36`–`51:48`):**
       > *"A few days ago one of the clankers was trying to share a file with another one of my devices and it just put my entire file system on the public internet for like a day... And if we end up in a shared space where I have an account, you have an account, the clanker brings up some user interface that is literally XSS to exfiltrate my cookie... Making an extensible web interface that's also secure is way harder than it looks."*

---

### 1.2 Public Blog Posts & Authored Specifications / Design Docs

1. **Earendil Announcement: "Pi Durable" (`2026-10-01`)**
   - **URL:** https://earendil.com/posts/pi-durable/
   - Introduces Pi Durable (~15,000 LoC without tests) alongside Pi 1.0: `Harness`, `Storage`, `ExecutionEnv`, `root` and `fork` conversations, `requestId` idempotent submissions, extensions (`sections`, `tools`, `wraps`, `hooks`, `tasks`), `memo` for replay-safe hooks/tools, foreground vs `background: true` task ownership, background & manual compaction + `handoff`/`reset` + `search_history`, `defineDoc` (`history: "rewindable"`, `fork: "asOf"`), and multiplayer view watching.

2. **Earendil Post: "Pi Durable on Cloudflare" (`2026-10-16`)**
   - **URL:** https://earendil.com/posts/pi-durable-on-cloudflare/
   - Maps one Pi Durable `Session` to one SQLite-backed Cloudflare Durable Object (`openDurableObjectSqliteStorage`), using `registerStorageConformance` to verify the storage contract, WebSocket hibernation while idle, and Durable Object alarms (`onWake` / `wake().at`) to wake the session for scheduled tasks.

3. **Mario Zechner's Authored Design Docs, Changelogs & Commits in `earendil-works/pi` (`v1.0.0` – `v1.5.2` / `2026-11-11`)**
   - **`packages/durable/docs/spec.md` & `README.md`:** Normative specification of the single session mutation line, record schemas, document engine, scheduler passes, and context reducer.
   - **`packages/durable/docs/group-commit.md` (commits `e5c6182ba`, `fabf916fc`):**
     - Solves single-line storage latency bottlenecks: while one storage write is in flight, non-conflicting commits from concurrent conversations/tasks in the session are batched into a single transaction (`Storage.commit(batches, receive, context)`), keeping individual `seq` numbers and prefix-refusal semantics. Raises 128-conversation throughput at 4 ms storage latency from ~5 runs/s to ~440 runs/s.
     - Introduces **deferred progress commits** (`persistWithinMs: 1000`): streamed model tokens and running tool output update in-memory views immediately for watchers and flush to SQLite with the next structural commit or within 1 second (cutting SQLite transactions 5.7x–27x).
     - Adds **working-set caches with idle eviction**: `contextRetentionMs` (incremental context derivation from the last read entry) and `documentRetentionMs` (evicting unwatched documents after 10 minutes), plus bounding scheduler ownership indexes strictly by **live work**.
   - **`packages/durable/docs/suspendable/book.md` & `spec.md` ("Waiting for the World: suspendable work in pi-durable", commits `815541a14`, `473515f9c`, `2026-11-09`):**
     - **Typed Signals (`defineSignal`, `harness.signal(taskId, token, key, value)`):** External events (webhooks, human approvals/answers, child conversation settlements via `SubmissionSettled`) are delivered as schema-validated, versioned JSON signals stored on the target task (first-writer-wins per key). Early signals arriving before the task enters `sleeping` are buffered on the task so webhook races never lose a wake.
     - **Extended `sleeping` and `waiting` states:** `sleeping` waits on `until` (deadline), `signals` (signal keys), or both; `waiting` adds `policy: "any"` alongside `"failFast"` and `"allSettled"`. Woken code inspects `wake` (`"time" | "expired" | "signal" | "tasks"`).
     - **Tools that park (`ToolPark`):** `execute()` can return `{ sleep }` or `{ wait }`, releasing its in-memory invocation entirely (`wake().active == false`). Waking commits intent before running tool code again so unsafe tools never run twice; `cancel()` cleans up external work if aborted while parked.
     - **Gates & Hook Tasks:** `beforeTool` hooks can return `{ sleep }` to gate execution (re-running all `beforeTool` gates on wake); `afterTools`, `onYield`, and `afterRun` hooks can spawn owned child tasks (`HookTask`) that the generation waits on before continuing or finishing.
   - **`apps/p2/docs/waiting.md`, `apps/p2/docs/plugin-practices.md`, `apps/p3/docs/status-2026-11-09.md`, `apps/p3/docs/efficiency.md`, `apps/p3/docs/sharing.md`, `apps/p3/docs/decisions.md` (`2026-11-06` – `2026-11-11`):**
     - **Deterministic Hook Stages (`waiting.md` §1):** Hooks compose in four strict stages: `transform -> check -> claim -> observe`. Observers are muted (cannot replace results or block calls). Per-conversation tool selection only filters tools offered to the model; **hooks and wraps always apply** so selecting a subset of tools never disables security/approval/telemetry hooks.
     - **Wait Index & Wake Handoff (`waiting.md` §2–§3):** Session workers report `wake()` (`{ active, at }`) and open `WaitRecord`s (person questions/approvals or service webhook correlation keys) to the server before idling out; the server wakes the session on deadline or signal delivery.
     - **Crash-loop and retry hardening (`CHANGELOG.md` v1.4.0–v1.5.0 `#11139`, `#11043`):** `restartLimit` (default 5) ends repeatedly crashing tasks visibly (`restart_limit`) instead of infinite crash loops or wedging conversations; interrupted in-flight model requests count against the retry budget and back off via durable `sleeping` rather than resending forever; `continue` submissions resume unanswered runs cleanly; `whenIdle: "reject"` prevents late steers from starting unintended runs; `abandonOnRestart` aborts in-memory-awaited child tasks of non-replay-safe tools on recovery.
     - **State-over-events (`CHANGELOG.md` v1.5.0 `#11327`):** Removed `watchEvents()`; UIs render directly from windowed `ConversationView` state (`min: 50, max: 100` entries + `before` cursor) merged by a gap-aware client transcript pager (`ConversationTranscript`), with sticky `runFailure` and `compactionFailure` fields on `pi.live`.
     - **Node Worker Memory vs Multi-Session Efficiency (`efficiency.md`):** Measured each Node/V8 session worker in `p2` at **170–290 MiB RSS** just to exist.
     - **Post-Vienna-Meetup Sharing Decisions (`sharing.md`, `decisions.md` `2026-11-10`–`2026-11-11`):** After 53 meetup attendees joined the phone demo via a read/write QR code and spammed steering/artifacts, Mario recorded explicit rules: the instance is the trust boundary (no illusory per-run `origin` tracking against prompt injection); public shares default to **read-only (`Watch`)**; **approvals stay the owner's**; revoking a share fences the grant revision immediately without aborting already-running work ("End share" != "Stop run").

---

## 2. Architectural Comparison: `pi-durable` vs `diy-harness` (Elixir / BEAM)

### 2.1 High-Level Alignment Matrix

| Dimension | Mario Zechner's `pi-durable` (+ `p2`/`p3`) | `diy-harness` on Elixir / BEAM | Alignment & Action |
|---|---|---|---|
| **Durability model** | Not event sourcing. Serialized atomic state commits + phased task "effect sandwiches" (`intent -> effect -> outcome`). | Not event sourcing. Serialized per-session coordinator (`Session.Server`) + `commit -> effect -> commit` state machines. | **Aligned.** Flesh out group commit & deferred progress persistence. |
| **Runtime hosting** | In Node (`p2`/`p3`): 1 OS worker process per active session (~170–290 MiB RSS each) or 1 Cloudflare DO V8 isolate (128 MB cap, 15-min eviction). | **1 BEAM OS process** hosting hundreds/thousands of lightweight isolated session supervision trees (~3–10 KiB base heap per GenServer). | **BEAM advantage.** Add explicit idle hibernation/unloading via `WakeScheduler` so inactive sessions cost ~0 RAM. |
| **History & Forking** | Conversation forest in one session; forks reference `{parentConversationId, atEntryId}` without copying entries; shared ID sequence. | Implemented in `H.Session`: root + independent + forked conversations with inherited visible prefix cutoffs and session-local monotonic IDs. | **Aligned & implemented in Slice 0.** Add context-as-of (`context(at: entry_id)`) and head markers (`compaction`, `reset`/`handoff`). |
| **Application & Live State (`Documents`)** | Versioned JSON documents (`defineDoc`) with `scope`, `history` (`latest` \| `rewindable`), `fork` (`asOf` \| `current` \| `initial`), mutated via JS `Proxy` ("a slow hack") to emit delta ops. | Previously deferred in `docs/architecture.md`. Now adopted as **versioned Elixir document structs/maps** updated via pure functions returning `{new_doc, delta_ops}`—no JS `Proxy` needed! | **Updated in architecture.** Adopt scoped, versioned documents (`pi.live`, `pi.agent`, `pi.inbox`, `pi.usage`, plus app docs) with explicit fork/history rules. |
| **Task Scheduling & Ownership** | Phased tasks (`pending`, `running`, `waiting`, `sleeping`, `completing`, `terminal`); ownership tree (`conversation` \| `task`), foreground vs `background: true`, bottom-up abort, `abandonOnRestart`, cycle detection across waits + held owners. | Separate work-ownership tree from OTP supervision; temporary `Task.Supervisor` workers for active effects only; bottom-up foreground drain. | **Updated in architecture.** Add `sleeping` (time + signals), `:any` wait policy, `abandon_on_restart`, `restart_limit` crash-loop guard, and full wait+hold cycle detection. |
| **Waiting on the Outside World** | Suspendable work (`v1.5.2+`): typed `Signal`s with early buffering, tools that park (`{ sleep }` / `{ wait }`) holding no worker, `beforeTool` gates that sleep, `SubmissionSettled` signal, `wake() -> { active, at }`. | Natural fit on BEAM: parked tasks/tools hold **no effect worker process**, persist their checkpoint + signal keys, and wake via `Session.Server.signal/4` or `WakeScheduler`. | **Updated in architecture.** Incorporate signals, parked tools, staged hooks/gates, and `wake()` handoff. |
| **Hooks & Extensions** | Extensions bundle `sections`, `tools`, `wraps`, `hooks`, `tasks`. Host composes hooks in 4 stages: `transform -> check -> claim -> observe`. Conversation tool filtering never disables hooks/wraps. | Behaviour seams (`Provider`, `Tool`, `ExecutionEnv`) + staged pipeline (`transform -> check -> claim -> observe`) where security/check/observe hooks cannot be bypassed by conversation tool selection. | **Updated in architecture.** Adopt the 4-stage hook model and non-bypassable check/observe invariant. |
| **Execution Environment** | Pluggable `ExecutionEnv` (`openBinaryReader` with `scanLines`, `openDirReader`, `listFiles`, `watch`, `exec` with `argv`/shell + source-side output windowing & `skipped` count). | Pluggable `H.ExecutionEnv` behaviour (local, sandbox/container, remote SSH/RPC) with source-side output windowing and OS process-group cleanup. | **Updated in architecture.** Specify source-side output windowing and argv/shell contracts. |
| **Client Observation & Multiplayer** | Killed `watchEvents()`. Clients watch windowed `ConversationView` (`min: 50, max: 100` entries + `before` cursor + `live` docs) with delta ops fanned out once to all viewers; `Watch` (read-only) vs `Join` (read-write) sharing. | HTTP/JSON commands + SSE/WebSocket state-view observation. BEAM reference-counted binaries (`ProcBin`) broadcast one encoded delta frame to N subscribers with zero-copy memory sharing. | **Updated in architecture & protocol.** Adopt windowed `ConversationView` + delta fan-out + `Watch` vs `Join` sharing rules. |

---

### 2.2 Why Elixir / BEAM Is Uniquely Suited to What Mario Is Building

In his talks and design notes, Mario candidly highlights four pain points he had to fight in JavaScript/TypeScript:

1. **Per-Session Worker Memory Overhead (`apps/p3/docs/efficiency.md`):**
   - In Node.js (`p2`/`p3`), isolating sessions into worker processes costs **170–290 MiB RSS per live session worker** (V8 isolate heap, duplicated code space, source maps). On a phone or a team server with 100 active sessions, V8 worker processes exhaust RAM.
   - **On BEAM:** All sessions share a single OS process, a single loaded BEAM code server, and preemptive per-process reduction scheduling. An active `Session.Server` + supervisor costs a few kilobytes beyond its working-set data; an idle session can `:hibernate` (shrinking its heap to minimal state) or unload to SQLite/Postgres while `WakeScheduler` holds only its `{session_id, next_wake_at}` timer in ETS.

2. **Immutable State & Delta Generation Without JS Proxy Hacks (`0xSero` `29:31`–`31:15`, Vienna Talk `25:10`–`25:45`):**
   - Because JavaScript objects are mutable by default, `pi-durable` wraps document state in recursive ES6 `Proxy` traps (`Chord` draft tracking) to intercept mutations (`doc.items.push(x)`) and synthesize delta operations + structural copies—which Mario calls *"a hack, a slow hack, to be exact"* that required repeated optimization (e.g. `#9265` 100 MB string-append retention bug, `091bcc099` O(N²) array append walks).
   - **On BEAM:** Elixir data structures are natively immutable and structurally shared on the process heap. State transitions are explicit pure functions (`Document.apply_op(doc, op) -> {new_doc, delta}`) and binary text appends (`<<acc::binary, chunk::binary>>`) use the VM's native sub-binary and append optimizations without proxy interception or defensive deep-cloning (`plugin-practices.md` Rule 5).

3. **Zero-Copy Multiplayer Fan-Out (Vienna Talk `23:11`–`23:55`, `sharing.md`):**
   - When 50–250 clients watch a live session, encoding updates per client is a bottleneck.
   - **On BEAM:** Any serialized JSON/delta frame larger than 64 bytes is allocated once as a reference-counted binary (`ProcBin`) on the global shared binary heap. Broadcasting `{:commit_frame, rev, bin}` via `Registry` to 250 SSE/WebSocket connection processes sends only a 24-byte pointer per process—true zero-copy fan-out.

4. **Supervision vs Cloudflare DO 15-Minute Eviction (Vienna Talk `02:08`–`02:45`, `29:15`–`30:05`):**
   - In Cloudflare Durable Objects, the platform forcibly kills the V8 isolate after 15 minutes of execution, requiring alarm chaining to keep long runs alive.
   - **On BEAM:** Long-running coordinators and effect workers run natively for arbitrary durations under OTP supervision without artificial 15-minute eviction, while still using the exact same checkpoint + `wake()` alarm handoff architecture so that VM restarts, deploys, or idle session unloading are 100% seamless.

---

### 2.3 Concrete Refinements Incorporated into `diy-harness` Docs

Based on this research, we refine `docs/architecture.md`, `docs/protocol.md`, `docs/roadmap.md`, and `docs/references.md` in the following ways:

1. **First-Class Versioned Documents (`docs/architecture.md` §3, §4):**
   - Replace the earlier dismissal of documents with a small, explicit **Versioned Document** model (`kind`, `version`, `scope: :session | :conversation | :task`, `history: :latest | :rewindable`, `fork: :as_of | :current | :initial`, `checkpoint_when`, `migrate/2`).
   - Built-in operational state (`pi.live`, `pi.agent`, `pi.inbox`, `pi.usage`) and application state (`todos`, artifacts, nested tool call records) use this unified model, updated functionally (no proxies) inside the same atomic commit as entries and tasks.
2. **Group Commit, Deferred Progress Persistence, and Working-Set Eviction (`docs/architecture.md` §5):**
   - Specify **group commit** on `Session.Server`: while one storage transaction is in flight, non-conflicting commits from concurrent conversations/tasks in the session accumulate and execute in one batched storage transaction, preserving per-batch `seq` and prefix-refusal rules.
   - Distinguish **immediate structural commits** from **deferred progress commits** (`persist_within_ms`, default 1,000 ms) for high-frequency token streaming and tool output windows.
   - Bound in-memory working sets with incremental context derivation (`context_retention_ms`), unwatched document eviction (`document_retention_ms`), and live-work-only ownership indexes.
3. **Suspendable Work: Signals, Parked Tools, Gates, and `WakeScheduler` (`docs/architecture.md` §2, §5, §7):**
   - Add `sleeping` task status waiting on `until` (deadline), `signals` (typed first-writer-wins signal keys with early-arrival buffering), or both; add `:any` to `waiting` policies; record `wake` reason (`:time | :expired | :signal | :tasks`).
   - Allow tools to **park** (`{:park, {:sleep, ...} | {:wait, ...}}`) without holding a BEAM task process, committing wake intent before resuming so unsafe tools never double-execute.
   - Define the **wake handoff** (`wake() -> %{active: boolean(), at: integer() | nil}`) between `Session.Server` and a daemon-level `WakeScheduler` + `WaitIndex` (routing webhooks and human approvals/questions to parked tasks and waking unloaded/hibernated sessions on demand).
4. **Crash-Loop Guards, Interrupted Model Retries, `continue` Submissions, and `abandon_on_restart` (`docs/architecture.md` §5, §6):**
   - Track `restarts` per task phase on unclean recovery (clean `close` does not increment `restarts`); end tasks visibly at `restart_limit` (default 5) instead of looping forever.
   - Charge interrupted in-flight model requests against the retry policy (persisting partial output as an aborted entry and sleeping for retry backoff) rather than resending infinitely on crash loops.
   - Add `continue` submissions (`type: "continue"`) and `when_idle: :reject` (for race-free `when_busy: :steer`).
   - Add `abandon_on_restart: true` for child tasks awaited only in memory by non-replay-safe tools.
5. **Deterministic Hook Stages, Nested Tool Calls, Deferred Tools, and History Search (`docs/architecture.md` §7):**
   - Order hooks in four stages (`transform -> check -> claim -> observe`) with muted observers, and enforce that per-conversation tool selection filters offered tools only—never disabling installed `check`/`observe` hooks or wraps.
   - Specify nested tool calls (`execute_tool` with replay keys and `structured_output`), deferred tool loading (`tool_search`), and the combination of background/blocking compaction + `handoff`/`reset` + `search_history` over raw un-truncated entries.
6. **Windowed State Views, Zero-Copy Fan-Out, and `Watch` vs `Join` Sharing (`docs/protocol.md`):**
   - Replace raw event-stream reconstruction with windowed `ConversationView` snapshots (`min: 50, max: 100` entries + `before` cursor) + folded delta operations, sticky `run_failure` / `compaction_failure` state, and zero-copy `ProcBin` fan-out.
   - Incorporate the post-meetup sharing rules: instance trust boundary, read-only `Watch` shares by default vs authenticated `Join`, owner-only approvals, and separating share revocation from run abort.
