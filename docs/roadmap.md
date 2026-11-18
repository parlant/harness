# Roadmap

**Current milestone:** Workspace browsing, Phoenix LiveView, and the native line-oriented `h` client share one [durable engine](./architecture.md). The remote execution adapter is an in-VM prototype, not a network service.

---

## Blueprint Index

### Implemented and prototyped (Slices 0–8)
- **Slice 0** — Pure History (`H.Session`, `H.Conversation`, `H.Entry`) — **Implemented**
- **[Slice 1](./roadmap/01-durable-core-and-storage.md)** — Pluggable Storage (`Memory` + `File`), `H.StoreLock`, `H.Catalog`, and `H.Session.Server` — **Implemented**
- **[Slice 2](./roadmap/02-http-sse-and-web-client.md)** — `Bandit` + `Plug` HTTP/SSE Daemon, Reference Web Client, and Curated `ReqLLM` Catalog — **Implemented**
- **[Slice 3](./roadmap/03-provider-and-streaming.md)** — Durable Multi-Turn Generation, `H.Context` Projection, and Crash-Retry Recovery — **Implemented**
- **[Slice 4](./roadmap/04-tools-and-self-hosting.md)** — `H.ExecutionEnv`, Coding Tools (`read`, `write`, `edit`, `bash`, `search_history`), and Self-Hosting — **Implemented**
- **[Slice 5](./roadmap/05-workspace-browser-and-harness-seam.md)** — Workspace Directory Browser (`GET /api/v1/fs`), `H.ExecutionEnv.Host`, `{env_id, cwd}` Catalog Index, `H.Harness` (`AGENTS.md`), and `<data_dir>/api.sock` — **Implemented**
- **[Slice 6](./roadmap/06-phoenix-web-client.md)** — Phoenix Web & Mobile Application (`clients/web/`, `HWeb.*` LiveView with `{:harness, path: "../.."}` Single-BEAM Monolith Mode) — **Implemented**
- **[Slice 7](./roadmap/07-cooperative-tui-client.md)** — Cooperative Non-BEAM Terminal Client (`clients/tui/`, Native Rust `h` Binary over `api.sock` / Loopback HTTP+SSE) — **Line-oriented milestone implemented**; raw-mode TUI is a follow-on
- **[Slice 8](./roadmap/08-remote-execution-environments.md)** — Cooperative Remote Execution Environments (`H.ExecutionEnv.Remote` + `H.RemoteAgent` Fenced/Lease-Reaped Conformance Seam) — **Implemented (in-VM seam)**; network mTLS/SSH transport planned

### Planned Next (Slice 9+)
- **[Slice 9 — Next](./roadmap/09-compaction-signals-and-sqlite.md)** — Append-Only Compaction, Suspendable Work (`Signals`, Parked Tools, 4-Stage Approval Hooks, `WakeScheduler`), and `H.Storage.SQLite` (`exqlite`)

---

## Stack & Compilation Discipline

- **Durable Engine (Root `/mix.exs`, `:harness` / `H.*`):** Elixir `~> 1.20` on Erlang/OTP `29`. Keeps its small, UI-free dependency footprint (`bandit`, `plug`, `req`, `req_llm`; dependency-free `H.Storage.{Memory,File}`). Compiles standalone for headless daemon + TUI deployments.
- **Phoenix Web & Mobile Client (`clients/web/mix.exs`, `:harness_web` / `HWeb.*`):** Separate Mix project depending on `{:harness, path: "../.."}`. Compiles `:harness` + `:harness_web` into one monolithic BEAM VM (`HWeb` LiveViews calling `H.Daemon` + `H.PubSub` directly in-memory) without adding a single dependency to root `:harness`.
- **Terminal Client (`clients/tui/`, `h`):** Separate non-BEAM native subproject (Rust) communicating cooperatively with `:harness` over `<data_dir>/api.sock` / loopback HTTP+SSE—avoiding OTP TTY/raw-mode friction and BEAM startup latency while sharing 100% live session sync with `HWeb.*`.
- **Done criteria per slice:** `mix format --check-formatted` (and `cargo fmt`/`clippy`/`test` in `clients/tui/`), `mix compile --warnings-as-errors`, and offline automated test suites (`--no-start` default on Elixir, zero paid LLM calls).

---

## Slice Summary

### 0–4. Self-Hosting Durable Core — **Implemented**
Specs: [`01`](./roadmap/01-durable-core-and-storage.md) · [`02`](./roadmap/02-http-sse-and-web-client.md) · [`03`](./roadmap/03-provider-and-streaming.md) · [`04`](./roadmap/04-tools-and-self-hosting.md)

- Pure fork-forest history, `:raw` CRC32-framed `H.Storage.File` + snapshots, `H.StoreLock` Unix socket fencing, ETS-backed `H.Catalog`, per-session `:temporary` `H.Session.Supervisor` + drain-batch `H.Session.Server`, `Bandit`+`Plug` loopback HTTP/SSE security, credential-aware curated `ReqLLM` streaming, and PGID-reaped local coding tools.

### 5. Workspace Directory Browser, `ExecutionEnv.Host`, `H.Harness`, & `api.sock` — **Implemented**
Spec: [`docs/roadmap/05-workspace-browser-and-harness-seam.md`](./roadmap/05-workspace-browser-and-harness-seam.md)

- Zero new Hex dependencies; promotes `H.ExecutionEnv.Host` + marker-aware single-roundtrip `list_dir/3`, scopes `H.Catalog` and `H.WorkspaceLease` by `{env_id, cwd}`, introduces `H.Harness` (`AGENTS.md` discovery via `ExecutionEnv`), auto-mints `session_id` + first-prompt `title`, binds `<data_dir>/api.sock` for local cooperative clients, and ships `GET /api/v1/fs` + interactive reference folder picker.

### 6. Phoenix Web & Mobile Application (`clients/web/` — `HWeb.*`)
Spec: [`docs/roadmap/06-phoenix-web-client.md`](./roadmap/06-phoenix-web-client.md)

- Responsive Phoenix LiveView app with workspace browsing, paged transcripts, live run progress and branch controls. Runs in-VM alongside `:harness` via `{:harness, path: "../.."}`.

### 7. Cooperative Non-BEAM Terminal Client (`clients/tui/` — `h`)
Spec: [`docs/roadmap/07-cooperative-tui-client.md`](./roadmap/07-cooperative-tui-client.md)

- Native terminal client with folder-scoped attach/resume, line-oriented interaction and scriptable print mode. Connects to an already running daemon over Unix socket or loopback HTTP; no raw-mode viewport or auto-start yet.

### 8. Cooperative Remote Execution Environments (`H.ExecutionEnv.Remote`)
Spec: [`docs/roadmap/08-remote-execution-environments.md`](./roadmap/08-remote-execution-environments.md)

- In-VM `H.RemoteAgent` and `H.ExecutionEnv.Remote` pass execution-environment conformance tests and exercise fencing and lease expiry. Deployment to a separate VM, transport authentication, and network partition tests remain planned.

### 9. Compaction, Suspendable Work (`Signals` & Hooks), and `H.Storage.SQLite`
Spec: [`docs/roadmap/09-compaction-signals-and-sqlite.md`](./roadmap/09-compaction-signals-and-sqlite.md)

- Background/blocking append-only compaction + `reset`/`handoff` markers, subagent ownership joins, `sleeping` tasks + `signals` + parked tools + 4-stage approval hooks + `H.WakeScheduler`, and optional `H.Storage.SQLite` (`exqlite`) passing `H.Storage.Conformance`.
