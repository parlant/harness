# Roadmap: Fastest Path to Web-Based Self-Hosting

**Primary goal:** Reach **self-hosting as soon as possible**—running `:harness` (`H`) locally on Elixir 1.20 / OTP 29 with dependency-free local file storage (`H.Storage.File`), serving a zero-build web client via `Bandit` + `Plug`, connecting to real models early via `Req` + `ReqLLM`, and developing `H` from inside `H`'s own browser UI.

Detailed engineering blueprints for each slice live under [`docs/roadmap/`](./roadmap/):

- [Slice 1 — Pluggable Storage (`Memory` + `File`), Catalog, and Session Coordinator](./roadmap/01-durable-core-and-storage.md)
- [Slice 2 — `Bandit` + `Plug` HTTP/SSE Daemon, Web Client, and Early `Req` / `ReqLLM` Connection](./roadmap/02-http-sse-and-web-client.md)
- [Slice 3 — Durable Multi-Turn Generation, `ReqLLM.Context` Projection, and Crash-Retry Recovery](./roadmap/03-provider-and-streaming.md)
- [Slice 4 — `H.ExecutionEnv`, Coding Tools, and Self-Hosting Bootstrap](./roadmap/04-tools-and-self-hosting.md)
- [Slice 5 — Post-Self-Hosting Evolution & SQLite Adapter (`exqlite`, Compaction, Signals/Gates)](./roadmap/05-post-self-hosting-and-hex.md)

---

## Stack & Dependency Discipline

- **Runtime:** Elixir `~> 1.20` on Erlang/OTP `29`.
- **Slices 0–1 (Durable Core & Storage):** `deps: []` — stdlib `JSON`, `Registry`, `DynamicSupervisor`, `Task.Supervisor`, `:file` (`:raw` + `:erlang.crc32/1`), and Unix domain socket store locking. No database NIF required to reach self-hosting.
- **Slices 2–4 (HTTP/SSE Daemon, Web UI, Real LLMs & Tools):** Agreed pragmatic Hex set:
  - `{:bandit, "~> 1.14"}` + `{:plug, "~> 1.20"}` — pure-Elixir HTTP/1+2 server, static asset serving (`Plug.Static`), and chunked SSE (`send_chunked/2`).
  - `{:req, "~> 0.7.5"}` + `{:req_llm, "~> 1.30"}` — unified multi-provider streaming (`ReqLLM.stream_text/3` + `StreamResponse.events/1`), `LLMDB` model catalog, `JSV` JSON Schema tool-argument validation, external `token-exchange` `access_token` support on Vertex AI, and `Req` HTTP/SSE test clients.
  - Zero frontend build toolchain: `priv/static/` uses vanilla HTML, CSS, and native browser ES modules (`EventSource` + `fetch`).
- **Done criteria per slice:** `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test` (`--no-start` default; isolated `start_supervised!` children, `H.Provider.Fake` with zero paid calls, and real OS VM-restart tests where durability is claimed).

---

## Slice Summary

### 0. Pure History (`H.Session`, `H.Conversation`, `H.Entry`) — **Implemented**

Immutable root, independent, and forked conversations with visible entry cutoffs (`entry.id <= cutoff`) and one session-local monotonic ID allocator (`next_id`). 12 unit tests passing.

### 1. Durable Core, Pluggable Storage (`Memory` + `File`), and `H.Catalog` — **Next**
Spec: [`docs/roadmap/01-durable-core-and-storage.md`](./roadmap/01-durable-core-and-storage.md)

- `H.Storage` behaviour + `H.Storage.Conformance` test suite.
- `H.Storage.Memory` and dependency-free `H.Storage.File` (`:raw` CRC32-framed batch commit log + atomic temp/rename snapshots + torn-tail truncation).
- `H.StoreLock` (`.claim` + kernel-bound Unix domain socket preventing dual-daemon store corruption across `SIGKILL`).
- `H.Catalog` (ETS-backed session index under `<data_dir>/catalog/`, never opening session stores directly).
- `H.Session.Supervisor` (`:one_for_all`, `restart: :temporary` under `DynamicSupervisor` for per-session blast-radius isolation) + `H.Session.Server` (idempotent `request_id` admission, mailbox drain-batch group commit, versioned `live`/`inbox`/`agent`/`usage` documents, fenced workers, `restart_limit` crash-loop guard, cache-evicting idle hibernation/unload).

### 2. `Bandit` + `Plug` HTTP/SSE Daemon, Web Client, and Early `Req` / `ReqLLM` Connection
Spec: [`docs/roadmap/02-http-sse-and-web-client.md`](./roadmap/02-http-sse-and-web-client.md)

- Add `{:bandit, "~> 1.14"}`, `{:plug, "~> 1.20"}`, `{:req, "~> 0.7.5"}`, and `{:req_llm, "~> 1.30"}`.
- `H.HTTP.Router` + `SecurityPlug`: `Host` anti-DNS-rebinding allowlist, `Bearer` auth (`Plug.Crypto.secure_compare/2`), `HttpOnly; SameSite=Strict` cookie + `Origin` anti-CSRF check, `Plug.Static` (`priv/static/`), and chunked SSE (`snapshot`, shared `ProcBin` `commit` with `id: <seq>`, `ephemeral` without `id:`, slow-client snapshot fallback).
- `H.Provider` (`H.Provider.Fake` + `H.Provider.ReqLLM` + `H.Credentials` via `token-exchange` + `GET /api/v1/models` from `LLMDB`) so the browser web client chats with **real streaming models right in Slice 2**.
- Zero-build ES-module web UI (`priv/static/index.html`, `app.js`, `app.css`): session catalog, model picker, conversation/fork switcher, gap-aware `ConversationTranscript` pager, live streaming reasoning/text, and `submit` / `steer` / `continue` / `abort` / `fork` controls. Verified with `Req` HTTP/SSE tests + shared Playwright E2E smoke test.

### 3. Durable Multi-Turn Generation, `ReqLLM.Context` Projection, and Crash-Retry Recovery
Spec: [`docs/roadmap/03-provider-and-streaming.md`](./roadmap/03-provider-and-streaming.md)

- `H.Context` reducer projecting `H.Entry` history to `ReqLLM.Context` + `ReqLLM.Tool` declarations (leading system baseline for prompt-cache stability, lossless reasoning/thought-signature metadata, synthetic interrupted tool results across fork cuts, and no tool auto-execution inside `ReqLLM`).
- `H.Task.Generation`: deferred `persist_within_ms` progress flushes, crash-recovery retry accounting (`aborted` partial entry + `sleeping` backoff + sticky `run_failure: "interrupted"` + `continue` resume), and `steer` / `follow_up` / `when_idle: "reject"` turn boundaries.

### 4. `H.ExecutionEnv`, Coding Tools, and **Self-Hosting Milestone**
Spec: [`docs/roadmap/04-tools-and-self-hosting.md`](./roadmap/04-tools-and-self-hosting.md)

- `H.ExecutionEnv` behaviour + `H.ExecutionEnv.Conformance` + `H.ExecutionEnv.Local` (`no_follow` bounded line scanner, atomic file writes, OTP `Port.open` `SID == PGID == os_pid` process-group reaper, source-side `window` + `skipped` output truncation).
- Core tools validated with `JSV` JSON Schemas: `read` (`replay: :safe`), `search_history` (`:safe`), `write` (`:unsafe`), `edit` (`:unsafe`, exact unique replacement), and `bash` (`:unsafe`, nonzero exit diagnostic + bounded output spill file), plus per-workspace (`cwd`) writer lease and `max_turns`.
- **Self-Hosting Milestone:** Open `H`'s web client in a browser pointed at `/Users/partenkirchen/Projects/diy-harness`, inspect code, implement a feature + test through the browser UI, run `mix format` / `mix compile --warnings-as-errors` / `mix test --no-start`, and survive a forced BEAM VM restart mid-run.

### 5. Post-Self-Hosting Evolution (Built Inside `H`)
Spec: [`docs/roadmap/05-post-self-hosting-and-hex.md`](./roadmap/05-post-self-hosting-and-hex.md)

- Background & blocking compaction (`background_tokens`, `reserve_tokens`, thinking omitted from summarization) + `handoff`/`reset` markers.
- Child tasks, subagent conversations, `sleeping` + typed `signals`, tools that park (`{:park, ...}`), 4-stage hooks (`transform -> check -> claim -> observe`) + web UI approval gates, and `H.WakeScheduler` / `WaitIndex`.
- Agreed `H.Storage.SQLite` adapter (`{:exqlite, "~> 0.43"}`) behind `H.Storage.Conformance`, plus optional `WebSock` PTY/voice and `Watch`/`Join` session sharing.
