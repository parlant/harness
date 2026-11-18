# Architecture Overview

**Status:**
- **Implemented (Slices 0–4 Self-Hosting Core):** Pure history (`H.Session`, `H.Conversation`, `H.Entry`), dependency-free storage (`H.Storage.Memory`, `H.Storage.File`, `H.Storage.Conformance`), `H.StoreLock`, `H.Catalog`, `H.Auth`, `H.Schema`, supervised per-session coordinator (`H.Session.Supervisor`, `H.Session.Server`, `H.Daemon`), `Bandit` + `Plug` HTTP/SSE daemon + zero-build reference web UI (`H.HTTP.*`, `priv/static/*`), `Req` + `ReqLLM` multi-provider streaming (`H.Provider.Fake`, `H.Provider.ReqLLM`, `H.Context`, `H.Credentials`), and `H.ExecutionEnv.Local` + `H.WorkspaceLease` + `JSV`-validated coding tools (`read`, `write`, `edit`, `bash`, `search_history`).
- **Proposed Next Evolution (Slices 5–9):** Clean separation into the **Durable Engine** (`H.*`), **Harness Profiles & Pluggable Execution Environments** (`H.Harness`, `H.ExecutionEnv.{Host,Remote}`), the **Phoenix Web & Mobile Application** (`clients/web/`, `HWeb.*`), and the **Cooperative Non-BEAM Terminal Client** (`clients/tui/`, `h`), followed by append-only compaction, suspendable `signals`/gates, and `H.Storage.SQLite`.

---

## 1. Architectural Separation

`H` separates the headless durable runtime, the harness/environment definition, and interactive client surfaces into independent layers and build targets:

```text
┌────────────────────────────────────┐   ┌────────────────────────────────────┐
│  3a. PHOENIX WEB & MOBILE CLIENT   │   │  3b. COOPERATIVE TUI CLIENT (`h`)  │
│      (`clients/web/`, `HWeb.*`)    │   │      (`clients/tui/`, non-BEAM)    │
│  • Desktop & Mobile LiveView UI    │   │  • < 5ms native boot in `pwd`/tmux │
│  • Compiles into same BEAM VM via  │   │  • Inline ANSI scrollback + RAII   │
│    {:harness, path: "../.."}       │   │    termios; zero BEAM tty friction │
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
   Separate **non-BEAM** subproject (`clients/tui/`, e.g. Rust native binary `h`) avoiding OTP `prim_tty`/`Logger`/`termios` friction and BEAM startup latency. Discovers or auto-starts the local `:harness` daemon via `<data_dir>/api.sock` (or loopback HTTP/SSE), scopes to `pwd` inside `tmux` (`h`, `h -c`, `h -r`), renders inline preserving terminal scrollback, and stays synchronized in real time with `HWeb.*`.

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
- **[`docs/architecture/client-tui.md`](./architecture/client-tui.md)** — Cooperative non-BEAM terminal client (`clients/tui/`, `h`), lessons from BEAM TTY experiments, `<data_dir>/api.sock` discovery & auto-start, `pwd` workflow in `tmux`, inline scrollback rendering, and live sync with `HWeb.*`.
- **[`docs/protocol.md`](./protocol.md)** — HTTP/JSON + SSE wire protocol (`v1`).
- **[`docs/roadmap.md`](./roadmap.md)** — Implementation status (Slices 0–4 complete) and vetted roadmap for Slices 5–9.
