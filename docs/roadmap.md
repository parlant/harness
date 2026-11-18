# Roadmap

**Current milestone:** Slices 0–4 (**Durable Self-Hosting Core**) are **implemented and verified** (`182` offline ExUnit + Node ESM tests passing under `--no-start`, plus opt-in live OpenAI verification via `mix test --no-start --only live_llm`).

**Next focus:** Evolve along the three-way architecture ([`docs/architecture.md`](./architecture.md) -> [`engine.md`](./architecture/engine.md), [`harness.md`](./architecture/harness.md), [`client.md`](./architecture/client.md)) without bloating `:harness`—starting with **Slice 5**, the vetted workspace directory browser, `ExecutionEnv.Host`, `H.Harness` seam, and live TUI/Web session synchronization.

---

## Blueprint Index

### Implemented Core (Slices 0–4)
- **Slice 0** — Pure History (`H.Session`, `H.Conversation`, `H.Entry`) — **Implemented**
- **[Slice 1](./roadmap/01-durable-core-and-storage.md)** — Pluggable Storage (`Memory` + `File`), `H.StoreLock`, `H.Catalog`, and `H.Session.Server` — **Implemented**
- **[Slice 2](./roadmap/02-http-sse-and-web-client.md)** — `Bandit` + `Plug` HTTP/SSE Daemon, Reference Web Client, and Curated `ReqLLM` Catalog — **Implemented**
- **[Slice 3](./roadmap/03-provider-and-streaming.md)** — Durable Multi-Turn Generation, `H.Context` Projection, and Crash-Retry Recovery — **Implemented**
- **[Slice 4](./roadmap/04-tools-and-self-hosting.md)** — `H.ExecutionEnv`, Coding Tools (`read`, `write`, `edit`, `bash`, `search_history`), and Self-Hosting — **Implemented**

### Planned Evolution (Slices 5–8)
- **[Slice 5 — Next](./roadmap/05-workspace-browser-and-harness-seam.md)** — Workspace Directory Browser (`GET /api/v1/fs`), `H.ExecutionEnv.Host`, `{env_id, cwd}` Catalog Index, `H.Harness` (`AGENTS.md`), and `pwd`-Scoped CLI/TUI + Web Live Sync
- **[Slice 6](./roadmap/06-phoenix-web-and-tui-clients.md)** — Separate Namespace & Mix Targets: `:harness_web` (`HWeb.*` Phoenix LiveView Desktop & Mobile) + `:harness_tui` (`HTUI.*` `Pi`-Class Terminal Client)
- **[Slice 7](./roadmap/07-remote-execution-environments.md)** — Cooperative Remote Execution Environments (`H.ExecutionEnv.Remote` VM Agent, Lease-Heartbeated PGIDs, Remote Folder Browser)
- **[Slice 8](./roadmap/08-compaction-signals-and-sqlite.md)** — Append-Only Compaction, Suspendable Work (`Signals`, Parked Tools, 4-Stage Approval Hooks, `WakeScheduler`), and `H.Storage.SQLite` (`exqlite`)

---

## Stack & Dependency Discipline

- **Runtime:** Elixir `~> 1.20` on Erlang/OTP `29`.
- **Durable Engine (`:harness` / `H.*`):** Keeps its small, UI-free dependency footprint (`bandit`, `plug`, `req`, `req_llm`; dependency-free `H.Storage.{Memory,File}`). Compiles standalone for headless daemon deployments or runs inside the same BEAM VM alongside `:harness_web`.
- **Client Apps (Slice 6):** `:harness_web` (`HWeb.*`, Phoenix + LiveView) and `:harness_tui` (`HTUI.*`) live in separate Mix OTP applications so client dependencies never leak into `:harness`.
- **Done criteria per slice:** `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test` (`--no-start` default; isolated `start_supervised!` children, `H.Provider.Fake` with zero paid calls by default, and real OS VM-restart / conformance tests wherever durability or `ExecutionEnv` semantics are claimed).

---

## Slice Summary

### 0–4. Self-Hosting Durable Core — **Implemented**
Specs: [`01`](./roadmap/01-durable-core-and-storage.md) · [`02`](./roadmap/02-http-sse-and-web-client.md) · [`03`](./roadmap/03-provider-and-streaming.md) · [`04`](./roadmap/04-tools-and-self-hosting.md)

- Pure fork-forest history, `:raw` CRC32-framed `H.Storage.File` + snapshots, `H.StoreLock` Unix socket fencing, ETS-backed `H.Catalog`, per-session `:temporary` `H.Session.Supervisor` + drain-batch `H.Session.Server`, `Bandit`+`Plug` loopback HTTP/SSE security, credential-aware curated `ReqLLM` streaming, and PGID-reaped local coding tools.

### 5. Workspace Directory Browser, `ExecutionEnv.Host`, `H.Harness`, & `pwd` Live Sync — **Next**
Spec: [`docs/roadmap/05-workspace-browser-and-harness-seam.md`](./roadmap/05-workspace-browser-and-harness-seam.md)

- Zero new Hex dependencies; refines `H.ExecutionEnv` (`Host` + single-roundtrip `list_dir` with `only_dirs`, symlink target types, and project markers), scopes `H.Catalog` and `H.WorkspaceLease` by `{env_id, cwd}`, introduces `H.Harness` (`AGENTS.md` discovery via `ExecutionEnv`), auto-mints `session_id` + first-prompt `title`, exposes `GET /api/v1/fs` + `GET /api/v1/sessions?cwd=...`, and delivers folder-browsing in Web plus `pwd`-scoped `mix h` terminal attach synchronized in real time.

### 6. Separate Client Applications (`HWeb.*` Phoenix Desktop/Mobile & `HTUI.*`)
Spec: [`docs/roadmap/06-phoenix-web-and-tui-clients.md`](./roadmap/06-phoenix-web-and-tui-clients.md)

- Mix Umbrella / multi-app split (`apps/harness`, `apps/harness_web`, `apps/harness_tui`) supporting both daemon-only builds and single-BEAM monolith releases (`HWeb` LiveViews calling `H.Daemon` + `H.PubSub` directly in-VM while `HTUI` inside `tmux` syncs over loopback HTTP+SSE).

### 7. Cooperative Remote Execution Environments (`H.ExecutionEnv.Remote`)
Spec: [`docs/roadmap/07-remote-execution-environments.md`](./roadmap/07-remote-execution-environments.md)

- Remote VM/container execution agent + `H.ExecutionEnv.Remote` passing `H.ExecutionEnv.Conformance`, lease-heartbeated remote PGID reaping on disconnect, source-side output windowing, and remote directory/session browsing.

### 8. Compaction, Suspendable Work (`Signals` & Hooks), and `H.Storage.SQLite`
Spec: [`docs/roadmap/08-compaction-signals-and-sqlite.md`](./roadmap/08-compaction-signals-and-sqlite.md)

- Background/blocking append-only compaction + `reset`/`handoff` markers, subagent ownership joins, `sleeping` tasks + `signals` + parked tools + 4-stage approval hooks + `H.WakeScheduler`, and optional `H.Storage.SQLite` (`exqlite`) passing `H.Storage.Conformance`.
