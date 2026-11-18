# Roadmap

**Current milestone:** Slices 0–4 (**Durable Self-Hosting Core**) are **implemented and verified** (`182` offline ExUnit + Node ESM tests passing under `--no-start`, plus opt-in live OpenAI verification via `mix test --no-start --only live_llm`).

**Next focus:** Evolve along the separated architecture ([`docs/architecture.md`](./architecture.md) -> [`engine.md`](./architecture/engine.md), [`harness.md`](./architecture/harness.md), [`client-web.md`](./architecture/client-web.md), [`client-tui.md`](./architecture/client-tui.md)) without bloating `:harness`—starting with **Slice 5** (workspace directory browser, `ExecutionEnv.Host`, `H.Harness` seam, and `<data_dir>/api.sock` cooperative client socket), which unlocks **Slice 6** (`clients/web/` Phoenix Desktop & Mobile) and **Slice 7** (`clients/tui/` cooperative non-BEAM `h` TUI) as independent workstreams.

---

## Blueprint Index

### Implemented Core (Slices 0–4)
- **Slice 0** — Pure History (`H.Session`, `H.Conversation`, `H.Entry`) — **Implemented**
- **[Slice 1](./roadmap/01-durable-core-and-storage.md)** — Pluggable Storage (`Memory` + `File`), `H.StoreLock`, `H.Catalog`, and `H.Session.Server` — **Implemented**
- **[Slice 2](./roadmap/02-http-sse-and-web-client.md)** — `Bandit` + `Plug` HTTP/SSE Daemon, Reference Web Client, and Curated `ReqLLM` Catalog — **Implemented**
- **[Slice 3](./roadmap/03-provider-and-streaming.md)** — Durable Multi-Turn Generation, `H.Context` Projection, and Crash-Retry Recovery — **Implemented**
- **[Slice 4](./roadmap/04-tools-and-self-hosting.md)** — `H.ExecutionEnv`, Coding Tools (`read`, `write`, `edit`, `bash`, `search_history`), and Self-Hosting — **Implemented**

### Planned Evolution (Slices 5–9)
- **[Slice 5 — Next](./roadmap/05-workspace-browser-and-harness-seam.md)** — Workspace Directory Browser (`GET /api/v1/fs`), `H.ExecutionEnv.Host`, `{env_id, cwd}` Catalog Index, `H.Harness` (`AGENTS.md`), and Cooperative `api.sock` Seam
- **[Slice 6](./roadmap/06-phoenix-web-client.md)** — Phoenix Web & Mobile Application (`clients/web/`, `HWeb.*` LiveView with `{:harness, path: "../.."}` Single-BEAM Monolith Mode)
- **[Slice 7](./roadmap/07-cooperative-tui-client.md)** — Cooperative Non-BEAM Terminal Client (`clients/tui/`, Fast Native `h` Binary in `tmux` Synced Live with `HWeb.*`)
- **[Slice 8](./roadmap/08-remote-execution-environments.md)** — Cooperative Remote Execution Environments (`H.ExecutionEnv.Remote` VM Agent, Lease-Heartbeated PGIDs, Remote Folder Browser)
- **[Slice 9](./roadmap/09-compaction-signals-and-sqlite.md)** — Append-Only Compaction, Suspendable Work (`Signals`, Parked Tools, 4-Stage Approval Hooks, `WakeScheduler`), and `H.Storage.SQLite` (`exqlite`)

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

### 5. Workspace Directory Browser, `ExecutionEnv.Host`, `H.Harness`, & `api.sock` — **Next**
Spec: [`docs/roadmap/05-workspace-browser-and-harness-seam.md`](./roadmap/05-workspace-browser-and-harness-seam.md)

- Zero new Hex dependencies; promotes `H.ExecutionEnv.Host` + marker-aware single-roundtrip `list_dir/3`, scopes `H.Catalog` and `H.WorkspaceLease` by `{env_id, cwd}`, introduces `H.Harness` (`AGENTS.md` discovery via `ExecutionEnv`), auto-mints `session_id` + first-prompt `title`, binds `<data_dir>/api.sock` for local cooperative clients, and ships `GET /api/v1/fs` + interactive reference folder picker.

### 6. Phoenix Web & Mobile Application (`clients/web/` — `HWeb.*`)
Spec: [`docs/roadmap/06-phoenix-web-client.md`](./roadmap/06-phoenix-web-client.md)

- Responsive Desktop + Mobile Phoenix LiveView app using `stream/4` transcript pagination, isolated 50 ms `ephemeral_live` patching, folder/branch drawers, and unified file-edit diff inspectors—running in-VM alongside `:harness` via `{:harness, path: "../.."}`.

### 7. Cooperative Non-BEAM Terminal Client (`clients/tui/` — `h`)
Spec: [`docs/roadmap/07-cooperative-tui-client.md`](./roadmap/07-cooperative-tui-client.md)

- `< 5 ms` native CLI/TUI launched via `cd <dir> && h` inside `tmux` (`h`, `h -c`, `h -r`, `h -p`), auto-starting or attaching to `:harness` over `<data_dir>/api.sock`, preserving native `tmux` scrollback via inline differential rendering, and syncing live with `HWeb.*`.

### 8. Cooperative Remote Execution Environments (`H.ExecutionEnv.Remote`)
Spec: [`docs/roadmap/08-remote-execution-environments.md`](./roadmap/08-remote-execution-environments.md)

- Remote VM/container execution agent + `H.ExecutionEnv.Remote` passing `H.ExecutionEnv.Conformance`, lease-heartbeated remote PGID reaping on disconnect, source-side output windowing, and remote directory/session browsing in both `HWeb.*` and `h`.

### 9. Compaction, Suspendable Work (`Signals` & Hooks), and `H.Storage.SQLite`
Spec: [`docs/roadmap/09-compaction-signals-and-sqlite.md`](./roadmap/09-compaction-signals-and-sqlite.md)

- Background/blocking append-only compaction + `reset`/`handoff` markers, subagent ownership joins, `sleeping` tasks + `signals` + parked tools + 4-stage approval hooks + `H.WakeScheduler`, and optional `H.Storage.SQLite` (`exqlite`) passing `H.Storage.Conformance`.
