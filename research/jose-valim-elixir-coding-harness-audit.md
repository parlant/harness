# José Valim on Building an Elixir Coding Harness — Research Corpus & Internal Audit of H

*Compiled: 2026-11-25*
*Primary trigger: https://x.com/josevalim/status/2088186994849468659 (2026-08-14)*

This document collects verified primary sources where **José Valim (`@josevalim`)** writes or speaks about building coding harnesses and agentic tooling on Elixir/BEAM, separates direct statements from adjacent ecosystem reflections, and audits **H (`:harness`)** against each architectural thesis and [`docs/architecture.md`](../docs/architecture.md) / [`docs/extensions.md`](../docs/extensions.md).

---

## 1. Primary Source Corpus (Verified Direct Statements by José Valim)

### 1.1 The Coding Harness Post on X (`2026-08-14`)

- **URL:** https://x.com/josevalim/status/2088186994849468659
- **Timestamp:** `2026-08-14T08:52:30Z`
- **Verbatim text (verified via X syndication / FxTwitter API):**

> People are sleeping on Elixir for a coding harness:
>
> * Hot-code swapping allows you to build an extensible plugin system similar to Pi, which reloads live without dropping state
>
> * Designing a client-server architecture, similar to OpenCode, is basically a byproduct of the actor model (plus you get both IO/CPU concurrency)
>
> * The built-in distribution means you can easily isolate the brains (model + session) from the hands (sandbox + tools). For example, you can the agentic session on your machine which coordinates agents executing inside Docker or a remote node. Or even have one agent session coordinate multiple nodes (this is basically how Livebook works anyway)
>
> Those can definitely be built from scratch in other languages, but in Elixir the building blocks are basically part of the runtime.

*(Note: Quoted in full and discussed on Elixir Forum in [`t/76373`](https://elixirforum.com/t/can-the-ideas-from-deepseek-harness-be-transferred-to-elixir-eco/76373) on 2026-08-15 and [`t/76497`](https://elixirforum.com/t/yoke-the-deepseek-harness-former-dsh/76497) on 2026-08-30; José did not post replies in those two threads.)*

---

### 1.2 Adjacent Primary Sources by José Valim (Dashbit Blog & Elixir Forum, 2025–2026)

To ensure we did not miss related architectural suggestions from José on coding agents, harnesses, tools, protocols, and BEAM distribution, we also audited his 2025–2026 Dashbit blog posts and Elixir Forum activity (`@josevalim`):

1. **"Evolving programming languages in the AI era"** — Dashbit Blog (`2026-09-24`)
   - **URL:** https://dashbit.co/blog/evolving-ai-era
   - **Elixir Forum discussion (`@josevalim` replies):** https://elixirforum.com/t/thoughts-on-evolving-programming-languages-in-the-ai-era/76825 (posts `#2`, `#8`, `#16`)
   - **Key points relevant to coding harnesses:**
     - **Stronger guarantees across four layers:** correct by construction, statically established (types/proofs), **runtime-enforced** (isolated processes, capability boundaries, supervision), and empirically validated (tests, property tests, fuzzing).
     - **Locality matters for agents:** explicitly warns against monkey-patching, **implicit hooks**, dynamic rebinding, and action-at-a-distance that make code hard to trace.
     - **Program databases over LSPs:** agents work poorly with cursor/line/column LSP lookups; structured symbol/reference/call-graph queries are a better fit.
     - **Runtime observability over debuggers:** expose processes, supervisors, ETS tables, sockets, message queues, and live state safely to agents as queryable tools rather than human breakpoint debuggers.

2. **"WebSockets vs. SSE should be about ordering and correctness"** — Dashbit Blog (`2026-08-25`)
   - **URL:** https://dashbit.co/blog/websockets-vs-sse
   - **Key points relevant to harness client-server protocols:**
     - Warns against dual-stream UI races when `Fetch` mutations and `SSE` event streams both deliver UI state without causal ordering.
     - Notes the exact two clean fixes: (a) a single bidirectional stream (WebSockets / LiveView), or (b) making HTTP mutations return receipts/acks only while all state updates flow through one ordered SSE stream (which is exactly how H's `POST /commands` receipt + monotonic `seq` SSE stream works).

3. **"Distributed Python dataframes and machine learning with Livebook and Elixir"** — Dashbit Blog (`2026-03-11`)
   - **URL:** https://dashbit.co/blog/distributed-python-livebook
   - **Key points relevant to "brains vs. hands":**
     - Illustrates the exact Livebook model José cited in his X post: a local Elixir controller coordinating remote execution nodes (Docker, Kubernetes, Fly.io) over Erlang distribution, with lifecycle cleanup when references/leases end.

4. **"Why Elixir is the best language for AI"** — Dashbit Blog (`2026-02-05`)
   - **URL:** https://dashbit.co/blog/why-elixir-best-language-for-ai
   - **Key points:**
     - Immutability & explicit data flow prevent spooky action at a distance and keep context small.
     - Low operational complexity (single BEAM runtime rather than Redis + RabbitMQ + workers) makes agent debugging dramatically simpler.
     - Fast parallel compilation + `--warnings-as-errors` + gradual types (Elixir 1.20) + runtime introspection (Tidewave MCP).

5. **Elixir Forum posts by `@josevalim` on LLM / agent architecture (2025–2026):**
   - **ReqLLM (`2025-09-14`, `t/72514` post `#2`):** *"Elixir does come with many of the building blocks for rolling your own agentic system but the 'talking to different LLMs' is definitely one of the more time consuming bits. I also like that you have a purely data driven API for defining tools. My only request would be to make the bit where providers automatically fetch keys optional (either opt-in or opt-out)..."*
   - **Anubis MCP (`2025-08-11`, `t/71410` post `#23`):** Separate protocol negotiation from tool definition/execution; distinguish stateless tools (run in their own worker/request process) from stateful tools (run in a dedicated owner process with a registry).
   - **Tidewave Web (`2025-08-19`..`2025-12-01`, `t/72164`):** Per-tool allow/deny configuration (`#39`), detecting runaway/long tool runs (`#44`), automatic compaction (`#56`), and reusing conversations across turns (`t/72461` `#3`).
   - **Phoenix `AGENTS.md` evals (`2026-07-29`, `t/71850` post `#7`):** Evaluate `AGENTS.md` instructions empirically on full end-to-end app generation tasks with and without rules.

---

## 2. Internal Audit: H (`:harness`) vs. José Valim's Coding Harness Blueprint

### Summary Scorecard

| # | Valim Thesis / Suggestion | Status in H (before this change) | Audit Verdict & Gap |
|---|---|---|---|
| **1** | **Client-server architecture as a byproduct of the actor model (OpenCode-style) + IO/CPU concurrency** | **Implemented cleanly** | Strongest match. `H.Daemon` + per-session `H.Session.Supervisor` / `H.Session.Server` + `Task.Supervisor` + `H.PubSub` + `H.Catalog` + Bandit HTTP/UDS + Phoenix LiveView (`HWeb.Backend.InVM`) + Rust TUI (`hi`). Survives client disconnect; single writer per session; concurrent generation/tool/subagent/user-shell execution. |
| **2** | **Hot-code swapping for an extensible plugin system (Pi-style) that reloads live without dropping state** | **Missing (explicitly disabled before this change)** | **Primary gap.** `H.Extensions` previously loaded BEAMs once at daemon boot, rejected replacing loaded modules (`compatible_module?/3`), fixed `daemon_opts` in Bandit router opts and session coordinators at boot, and required a full VM restart (`docs/extensions/daemon.md`). |
| **3** | **Isolate brains (model + session) from hands (sandbox + tools), incl. Docker / remote BEAM node & multi-node coordination (Livebook-style)** | **Partially implemented (in-VM seam only)** | `H.ExecutionEnv` + `H.EnvRegistry` + `H.ExecutionEnv.Remote` + `H.RemoteAgent` already cleanly separate session/model logic from tool execution, with attempt fencing, lease-TTL heartbeats, and PGID cleanup — **and** a single session can already coordinate multiple workspaces/subagents. **Gap:** `H.RemoteAgent` is only exercised in-VM; there is no distributed BEAM node / multi-node transport helper (`H.ExecutionEnv.Remote` over Erlang distribution / Docker / remote node) yet. |
| **4** | **Ordering & correctness across client-server streams (Dashbit 2026-08-25)** | **Implemented cleanly** | `POST /api/v1/sessions/:sid/commands` returns an idempotent receipt only; all durable transcript/document updates flow through one monotonic-`seq` SSE stream (or LiveView in-VM PubSub), avoiding fetch-vs-SSE state races. |
| **5** | **Data-driven tools, opt-in credentials, no implicit hooks / action-at-a-distance (EF `t/72514`, `t/71410`, Dashbit 2026-09-24)** | **Implemented cleanly** | `H.Tool` uses JSON Schema (`JSV`), `H.Provider.ReqLLM` resolves credentials explicitly at dispatch (`load_dotenv: false` in tests, isolated vault in `H.Accounts`), and `docs/extensions.md` explicitly rejects implicit monkey-patching/middleware stacks in favor of explicit behaviours and single-writer commits. |
| **6** | **Runtime observability & bounded agent introspection (Dashbit 2026-02-05, 2026-09-24)** | **Implemented for daemon/session state; read-only status routes exist** | `GET /api/v1/daemon/status`, `GET /api/v1/sessions/:sid`, `/tree`, `/events`, `search_history`, and `H.Catalog` ETS snapshots expose live daemon/session state cleanly without waking idle sessions. Extension inspection (`GET /api/v1/extensions`) should be exposed alongside hot reload. |

---

## 3. Deep-Dive Audit Against `docs/architecture.md` & `docs/extensions.md`

### 3.1 Actor-Model Client-Server Architecture (Already Clean)

Verified across:
- `lib/h/daemon/instance.ex`: `H.Daemon.Instance` (`:rest_for_one`: `H.StoreLock` → `H.Auth` → `H.Catalog` → `H.Daemon.Runtime`), `H.Daemon.Runtime` (services, `H.Registry`, `H.PubSub`, `H.WorkspaceLease`, `H.Session.RuntimeSupervisor`, `H.Daemon.Boot`, Bandit TCP + `H.HTTP.UnixListener`).
- `lib/h/session/supervisor.ex` & `lib/h/session/server.ex`: Per-session `:temporary` wrapper around `:one_for_all` (`Task.Supervisor` + `H.Session.Server`) with quarantine on repeated crashes, idle session unloading (`@idle_timeout_ms = 5m`), drain-batch atomic WAL commits (`H.Storage.File`), and fenced workers (`{incarnation, task_id, attempt_id}`).
- `lib/h/session/subagents.ex`: Coordinator-parked subagent delegation using `H.PubSub` settlement signals with zero held worker processes while waiting.
- `clients/web/lib/h_web/backend/in_vm.ex` & `clients/tui/src/`: Both Phoenix LiveView (`hiweb`) and the Rust TUI (`hi`) attach to the same daemon sessions simultaneously, matching OpenCode's client-server decoupling while going further via OTP supervision and durable recovery.

### 3.2 Hot-Code Swapping for Extensions (Key Gap & Design Constraints)

Previously, [`docs/extensions/daemon.md`](../docs/extensions/daemon.md) stated:
> *"H does not search workspaces, compile Mix projects, install dependencies, add extension directories to the VM code path, or provide hot reload. Restart the VM to change config or code."*

And `lib/h/extensions.ex` enforced that in `compatible_module?/3`:
```elixir
loaded == String.to_charlist(path) and :code.is_loaded(module) != false and
  module.module_info(:md5) == md5
```

**Why hot-reloading extensions fits H's architecture *without* breaking H's invariants:**

Checking every invariant in `docs/architecture.md`, `docs/extensions.md`, and `AGENTS.md`:
1. **Explicit owner action, never workspace discovery or automatic code loading:** Reloading must be an explicit authenticated owner operation (`H.Daemon.reload_extensions/1`, `POST /api/v1/extensions/reload`, and `hi daemon reload-extensions` or programmatic call). A workspace checkout or model output still cannot install or activate executable code on its own — `extensions.json` in `<data_dir>` remains the single trusted operator manifest.
2. **Never drop live session state or kill in-flight workers:**
   - Existing `H.Session.Server` coordinators stay alive with all conversation state, open SSE streams, queued inbox items, and in-flight workers untouched.
   - BEAM supports two module versions simultaneously (current + old). Using `:code.soft_purge/1` + `:code.atomic_load/1` (after validating all manifests and BEAM binaries first) swaps module bytecode cleanly:
     - If an in-flight worker is still executing code from a *previously* replaced version (`old` code) and cannot be soft-purged yet, reject the reload safely (`{:error, {:extensions, {:modules_in_use, mods}}}`) rather than hard-killing workers with `:code.purge/1`!
     - Active workers running the just-superseded version continue on `old` code until they finish naturally, while new calls dispatch to `current` code.
3. **No stale `daemon_opts` snapshots:**
   - Currently `H.Daemon.Runtime` passes a static `daemon_opts: opts` into `H.HTTP.Router`, and `H.Session.Server` caches `tools`, `provider_config`, and `daemon_opts` from startup.
   - Making `H.HTTP.Router` read live `H.Daemon.instance_options()` when bound to a booted daemon (while keeping static `daemon_opts` fallback for isolated unit tests), separating extension children into their own dedicated `H.Extensions.Supervisor` (distinct from `H.Accounts`!), and sending a `{:extensions_reloaded, ...}` update to live `H.Session.Server` coordinators refreshes:
     - Registered harnesses & tools (new tools appear on the next turn/context build; updated tool modules run new code immediately on the next call)
     - Registered execution environments (`H.EnvRegistry`)
     - `codex_account_policy`
     - Extension supervised children (reconciled cleanly under `H.Extensions.Supervisor`: stop removed/changed extension children, start new/updated ones, leaving `H.Accounts`, `H.Catalog`, `H.WorkspaceLease`, and all `H.Session.Server` processes untouched).
4. **Never violate effect durability or replay safety:**
   - Starting/restarting an extension child during hot reload still follows `H.Extension`'s contract: child startup must never replay external effects.
   - An in-flight tool call continues under its committed intent and fence; reloading cannot mutate committed history or re-dispatch an unsafe tool.
   - If a reload fails validation (invalid `extensions.json`, corrupt BEAM, failing `configure/2`, duplicate IDs, modules still pinned in old code, or child start failure), **nothing changes** (or the previous state is preserved/rolled back cleanly) and the daemon continues running with zero dropped sessions.
5. **No atom creation from untrusted input:**
   - Keep `H.Extensions`'s existing security property: module atoms are obtained only from `:beam_lib.md5/1` on trusted `.beam` files under configured extension `ebin/` directories, never via `String.to_atom/1` on JSON input.
6. **Clean removal of modules when an extension is disabled/removed:**
   - Only soft-purge/delete modules previously tracked as loaded by `H.Extensions` (never touch core `H.*` or dependency modules). If a removed module is still referenced by a running process, report `:modules_in_use` instead of killing the process.

### 3.3 Brains vs. Hands & Distributed BEAM Execution (`H.ExecutionEnv.Remote` + `H.RemoteAgent`)

Auditing `lib/h/execution_env.ex`, `lib/h/execution_env/remote.ex`, and `lib/h/remote_agent.ex` against José's third bullet (*"isolate the brains (model + session) from the hands (sandbox + tools)... Docker or a remote node... coordinate multiple nodes"*):

- **What already works cleanly:**
  - `H.ExecutionEnv` completely decouples all tools (`read`, `write`, `edit`, `bash`, `search_history`), workspace browsing (`H.Daemon.Workspace`), git review (`H.Daemon.Review`), and `AGENTS.md` discovery (`H.Harness.Coding`) from local filesystem/OS calls.
  - `H.RemoteAgent` already implements GenServer RPC for every `H.ExecutionEnv` operation plus attempt fencing (`{session_id, incarnation, task_id, attempt_id}`), lease-TTL heartbeats (`renew_lease/3`), caller-down reaping (`Process.monitor(caller_pid)`), and OS process-group cleanup.
  - `H.EnvRegistry` already supports multiple named environments simultaneously (`host`, plus any number of `remote` environments), and `H.WorkspaceLease` keys leases by `{env_id, canonical_cwd}`, meaning **one daemon and even one parent session with subagents can already coordinate multiple environments/nodes concurrently**.
- **What is missing for true distributed BEAM "brains vs. hands":**
  1. `H.RemoteAgent` works over Erlang distribution **almost** out of the box (`GenServer.call({name, remote_node}, ...)` and `Process.monitor(remote_pid)` are built into OTP!), **except** for two concrete details we found during audit:
     - `H.RemoteAgent.exec/3` passes `{:start_exec, self(), command, opts}` where `self()` is the brain's local PID and the remote agent sends `{:remote_exec_output, op_ref, chunk}` back to `caller_pid` and monitors `caller_pid` — this *does* work transparently across connected Erlang nodes!
     - **However**, `H.RemoteAgent` currently lacks:
       - A dedicated remote-node connection / bootstrap helper (e.g., `H.ExecutionEnv.Node` or `H.ExecutionEnv.Remote.connect_node/3` / `H.RemoteAgent` distributed node support) that connects to an authenticated Erlang node (e.g. inside Docker or on another host using cookie/TLS distribution), verifies `H.RemoteAgent` availability (or starts a supervised `H.RemoteAgent` on the target node), handles `:nodedown` / disconnect cleanly as `{:error, {:agent_down, :nodedown}}`, and surfaces node connectivity as an `H.EnvRegistry` environment spec.
       - Multi-node coordination tests using OTP `:peer` nodes (OTP 25–29 built-in `:peer` module!) proving real cross-VM isolation: brain VM runs `H.Session.Server` + model calls, hands VM(s) run `H.RemoteAgent` + `H.ExecutionEnv.Host` tools, verifying:
         - File I/O and `bash` execute in the hands node's OS process/VM, not the brain VM.
         - One session (or parent + subagents) can coordinate multiple distinct remote hands nodes simultaneously.
         - Killing / disconnecting the hands node fails safely without unsafe replay, and killing the brain caller reaps the running OS process group on the hands node via OTP monitor `:DOWN` + lease expiry.
  - Note per `docs/architecture.md` & `AGENTS.md`: We must keep documentation honest about security boundaries — Erlang distribution over a shared cookie is authenticated within a trusted local/Docker/VPN/TLS-dist boundary, and full internet-facing mTLS/SSH transport remains distinct.

---

## 4. Implemented Changes & Verification

1. **Live Hot-Code Reloading for Extensions (`lib/h/extensions.ex`, `lib/h/daemon/instance.ex`, `lib/h/daemon/maintenance.ex`, `lib/h/daemon.ex`, `lib/h/http/router.ex`, `lib/h/session/server.ex`, `lib/h/session/server/recovery.ex`, `clients/tui/src/{client.rs,manage.rs}`):**
   - Separated extension children into their own dedicated `H.Extensions.Supervisor` (sibling to account services, independent of `H.Session.RuntimeSupervisor`).
   - Added transactional `H.Extensions.reload_code/2` + `rollback_code/1` using `:code.soft_purge/1`, `:code.prepare_loading/1`, and `:code.finish_loading/1` — never hard-killing in-flight workers with `:code.purge/1`.
   - Added `H.Daemon.list_extensions/1`, `H.Daemon.reload_extensions/1`, `GET /api/v1/extensions`, `POST /api/v1/extensions/reload`, and `hi daemon extensions` / `hi daemon reload-extensions`.
   - Switched `H.HTTP.Router` (when bound to a booted daemon) to read live `H.Daemon.instance_options()` and notified live `H.Session.Server` coordinators via `{:extensions_reloaded, opts}` so tools, environments, and account policy refresh without dropping conversation state or active SSE streams.
   - Verified in [`test/h/extensions_hot_reload_test.exs`](../test/h/extensions_hot_reload_test.exs) (v1 → v2 live reload across continuous session turns, new tool + environment discovery, broken JSON / failing child rollback, lingering old-code process `409 modules_in_use` safety, clean unload on disable, and `--no-extensions` refusal).

2. **Real Distributed BEAM "Brains vs. Hands" (`lib/h/execution_env/remote.ex`):**
   - Added `H.ExecutionEnv.Remote.connect_node/3` and `H.ExecutionEnv.Remote.env_spec_for_node/3` for connecting a local brain daemon to `H.RemoteAgent` processes running on one or more remote Erlang nodes (e.g. Docker containers or remote hosts over Erlang distribution).
   - Verified in [`test/h/distributed_execution_env_test.exs`](../test/h/distributed_execution_env_test.exs) using real OTP `:peer` nodes: one local brain daemon coordinates tool runs across two separate hands BEAM VMs simultaneously, handles hands-node disconnect cleanly without affecting other nodes, and reaps remote OS process groups when a brain caller crashes mid-exec.

3. **Documentation Alignment:**
   - Updated [`docs/architecture.md`](../docs/architecture.md), [`docs/extensions.md`](../docs/extensions.md), [`docs/extensions/daemon.md`](../docs/extensions/daemon.md), [`docs/extensions/execution-env.md`](../docs/extensions/execution-env.md), and [`docs/protocol.md`](../docs/protocol.md) to reflect implemented behavior accurately while keeping deferred items (internet-facing mTLS/SSH remote transport, generic event-bus hooks) clearly marked.
