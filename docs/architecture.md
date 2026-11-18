# Architecture Overview

**Status:**
- **Implemented (Slices 0–6, line-oriented Slice 7, and in-VM Slice 8 prototype):**
  - **Root Durable Engine (`:harness` / `H.*`):** Pure fork-forest history (`H.Session`, `H.Conversation`, `H.Entry`), storage (`H.Storage.{Memory,File,Conformance}`), `H.StoreLock`, `{env_id, cwd}`-indexed `H.Catalog`, `H.Auth`, `H.Schema`, supervised session coordinator (`H.Session.{Supervisor,Server}`, `H.Daemon`), pure Elixir `H.Transcript` reducer, `Bandit` + `Plug` loopback TCP & `<data_dir>/api.sock` Unix-socket HTTP/SSE daemon (`H.HTTP.*`), `ReqLLM` multi-provider streaming (`H.Provider.{Fake,ReqLLM}`, `H.Context`, `H.Credentials`).
  - **Harnesses & Execution Environments:** `H.Harness` + `H.Harness.Coding` (`AGENTS.md` discovery via `ExecutionEnv`), `H.EnvRegistry`, `H.ExecutionEnv.{Host,Local,Remote}`, in-VM cooperative `H.RemoteAgent` (fenced & lease-heartbeated execution passing `H.ExecutionEnv.Conformance`), `H.WorkspaceLease` (`{env_id, cwd}`), and `JSV`-validated coding tools (`read`, `write`, `edit`, `bash`, `search_history`).
  - **Phoenix Web & Mobile Client (`clients/web/` — `:harness_web` / `HWeb.*`):** Standalone Mix project depending on `{:harness, path: "../.."}` with `HWeb.Backend.InVM`, `HWeb.WorkspaceLive` folder browser, and bounded-memory `HWeb.SessionLive` (`Phoenix.LiveView.stream/4`).
  - **Cooperative Non-BEAM Terminal Client (`clients/tui/` — Rust `h`):** Native Rust Cargo binary communicating over `<data_dir>/api.sock` or literal loopback HTTP/SSE (`h`, `h -c`, `h -r`, `h -s`, `h -p`) with control-character sanitization and `prev_seq`/`base_seq` `TranscriptState` sync.
- **Proposed Next Evolution (Slice 8 Network Transport & Slice 9 Durable Extensions):** Network transport adapter (mTLS/SSH) for `H.RemoteAgent`, full raw-mode inline viewport polish in `clients/tui/`, append-only compaction, suspendable `signals`/gates/`WakeScheduler`, and `H.Storage.SQLite`.

---

## 1. Architectural Separation

`H` separates the headless durable runtime, the harness/environment definition, and interactive client surfaces into independent layers and build targets:

```text
┌────────────────────────────────────┐   ┌────────────────────────────────────┐
│  3a. PHOENIX WEB & MOBILE CLIENT   │   │  3b. COOPERATIVE TUI CLIENT (`h`)  │
│      (`clients/web/`, `HWeb.*`)    │   │      (`clients/tui/`, non-BEAM)    │
│  • Desktop & Mobile LiveView UI    │   │  • Native client in `pwd`/tmux     │
│  • Compiles into same BEAM VM via  │   │  • Line-oriented and print modes  │
│    {:harness, path: "../.."}       │   │                                    │
└─────────────────┬──────────────────┘   └─────────────────┬──────────────────┘
                  │ In-BEAM (H.Daemon + H.PubSub)          │ Unix socket (api.sock)
                  │ or HTTP + SSE                          │ or Loopback HTTP + SSE
                  ▼                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  1. DURABLE ENGINE (Root OTP App `:harness`, Namespace `H.*`, Zero UI Deps) │
│     • H.Catalog (ETS `{env_id, cwd}` session index)  • H.StoreLock & H.Auth │
│     • H.Session.Server (history forest, drain-batch commits, Tasks, Docs)   │
│     • H.Provider.ReqLLM + H.Context + H.Credentials + H.HTTP (/api/v1/*)    │
└───────────────────────────────────────┬─────────────────────────────────────┘
                                        │ H.Harness + H.ExecutionEnv seams
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  2. HARNESS PROFILES & EXECUTION ENVIRONMENTS (`H.Harness`, `ExecutionEnv`) │
│     • Harness = ExecutionEnv + Tool Suite + AGENTS.md/Skills + Agent Rules  │
│     • Pluggable ExecutionEnv: Host (local machine), Worktree/Sandbox,       │
│       and cooperative Remote VM execution agents (`ExecutionEnv.Remote`)    │
└─────────────────────────────────────────────────────────────────────────────┘
```

1. **[Durable Engine (`docs/architecture/engine.md`)](./architecture/engine.md)**
   The headless BEAM runtime (`:harness`, `H.*` at repository root). Sequences immutable entries and fork trees, runs effect-sandwiched `Task` state machines with mailbox drain-batch commits, manages versioned `Document` deltas (`agent`, `live`, `inbox`, `usage`), streams LLM turns through `ReqLLM`, and fans out `ProcBin` events via `H.PubSub` and `/api/v1/*`. Compiles standalone with **zero Phoenix or TUI dependencies**.
2. **[Harness Profiles & Execution Environments (`docs/architecture/harness.md`)](./architecture/harness.md)**
   Defines what makes an agent a specific product (such as a `pi` rebuild on top of `H`): its `H.ExecutionEnv` (`Host`, `Sandbox`, or cooperative `Remote` VM agent), its `[H.Tool]` suite, its `{env_id, cwd}` workspace leases, and its `AGENTS.md`/skill context discovery—allowing multiple harnesses to share one durable engine without bloating `H.Session.Server`.
3. **[Phoenix Web & Mobile Client (`docs/architecture/client-web.md`)](./architecture/client-web.md)**
   Separate Mix project (`clients/web/`, `app: :harness_web`, namespace `HWeb.*`) depending on `{:harness, path: "../.."}`. Compiles `:harness` + `:harness_web` into a **single monolithic BEAM application** when desired (LiveViews calling `H.Daemon` + `H.PubSub` directly in-memory with `stream/4` transcript projection), while leaving root `:harness` 100% standalone.
4. **[Cooperative Terminal Client (`docs/architecture/client-tui.md`)](./architecture/client-tui.md)**
   Separate **non-BEAM** subproject (`clients/tui/`, e.g. Rust native binary `h`) avoiding OTP `prim_tty`/`Logger`/`termios` friction and BEAM startup latency. Attaches to an already running local `:harness` daemon via `<data_dir>/api.sock` (or loopback HTTP/SSE), scopes to `pwd` inside `tmux`, and shares the live transcript with `HWeb.*`.

Wire framing, authentication headers/cookies, idempotency receipts, and SSE event shapes are specified in **[`docs/protocol.md`](./protocol.md)**.

---

## 2. Core Invariants Across All Layers

1. **Four separate structures, never one tree:** History ancestry (`Conversation` + `Entry`), work ownership (`Task` hierarchy), OTP supervision (`H.Session.Supervisor` with `:temporary` per-session blast-radius isolation), and client navigation cursors remain strictly distinct.
2. **Single writer per store:** `H.Catalog` owns `<data_dir>/catalog/` (backed by ETS for lock-free reads and folder annotations without waking unloaded sessions); each `H.Session.Server` exclusively owns `<data_dir>/sessions/<session_id>/`.
3. **Environment-qualified workspaces (`{env_id, cwd}`):** Path resolution (`resolve_path/2`), directory browsing (`list_dir/3`), `AGENTS.md` discovery, and `H.WorkspaceLease` mutating locks are always scoped by `{env_id, cwd}` through `H.ExecutionEnv`—never assuming the target workspace lives on the durable engine's own OS filesystem.
4. **Supervision is not persistence; never blindly replay unsafe effects:** Intent is committed before every external call. On crash or remote network drop, `replay: :safe` tools (`read`, `search_history`) may re-run, whereas `replay: :unsafe` tools (`write`, `edit`, `bash`) record `"interrupted"` with flushed partial output so the model inspects reality first.
5. **Plain data at durable & wire boundaries:** No PIDs, refs, functions, ports, sockets, or credentials in durable storage or client payloads; external inputs are validated via `H.Schema` and `JSV` without creating atoms dynamically.

---

## 3. Architecture Sub-Documents & Roadmap

- **[`docs/architecture/engine.md`](./architecture/engine.md)** — History, ownership, OTP supervision, store split, pure documents, drain-batch commits, ephemeral vs. durable `seq`, crash recovery, and loopback security.
- **[`docs/architecture/harness.md`](./architecture/harness.md)** — `H.Harness` profile contract (`Pi` rebuild seam), `H.ExecutionEnv` pre-session browsing vs. bound execution, `{env_id, cwd}` scoping, `ExecutionEnv.Host`, and cooperative `ExecutionEnv.Remote` VMs.
- **[`docs/architecture/client-web.md`](./architecture/client-web.md)** — Phoenix + LiveView Desktop & Mobile application (`clients/web/`, `HWeb.*`), `{:harness, path: "../.."}` single-BEAM monolith vs. daemon-only builds, `stream/4` memory bounds, and responsive workspace/diff UX.
- **[`docs/architecture/client-tui.md`](./architecture/client-tui.md)** — Cooperative non-BEAM terminal client (`clients/tui/`, `h`), lessons from BEAM TTY experiments, `<data_dir>/api.sock` discovery, `pwd` workflow in `tmux`, live sync, and planned terminal improvements.
- **[`docs/protocol.md`](./protocol.md)** — HTTP/JSON + SSE wire protocol (`v1`).
- **[`docs/roadmap.md`](./roadmap.md)** — Implementation milestones and remaining work.
