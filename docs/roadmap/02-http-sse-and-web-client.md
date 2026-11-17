# Slice 2: `Bandit` + `Plug` HTTP/SSE Daemon, Web Client, and Early `Req` / `ReqLLM` Connection

**Goal:** Bring the HTTP/SSE daemon, the first browser web client, and real streaming model connections online together using **`Bandit`, `Plug`, `Req`, and `ReqLLM`**—skipping boilerplate HTTP/LLM wire plumbing so we can chat with real models in the browser immediately while keeping storage dependency-free (`H.Storage.File`).

---

## 1. Agreed Dependencies Introduced in Slice 2 (`mix.exs`)

```elixir
defp deps do
  [
    {:bandit, "~> 1.14"},
    {:plug, "~> 1.20.4"}, # >= 1.20.4 includes CVE-2026-120287 fix
    {:req, "~> 0.7.5"},
    {:req_llm, "~> 1.30.0"} # >= 1.29.0 includes GHSA-6vww-5m28-f26v fix
  ]
end
```

Why this 4-package stack accelerates self-hosting cleanly:
- **`Bandit` + `Plug`:** Pure-Elixir HTTP/1.1 + HTTP/2 server (`ThousandIsland`), static asset serving with built-in path-traversal protection (`Plug.Static`), bounded JSON parsing (`Plug.Parsers` with `json_decoder: JSON`), loopback TCP **and** Unix domain socket (`{:local, path}`) listeners, and native chunked SSE streaming (`Plug.Conn.send_chunked/2` + `Plug.Conn.chunk/2`). Also gives us a zero-rewrite path to WebSockets (`WebSock`) later if an interactive PTY view needs one.
- **`Req` + `ReqLLM`:**
  - Unified streaming across Vertex AI, Anthropic, OpenAI, OpenRouter, DeepSeek, and Ollama via `ReqLLM.stream_text/3` + `ReqLLM.StreamResponse.events/1` (`:start`, `:reasoning_delta`, `:text_delta`, `:tool_call_start`, `:tool_call_delta`, `:tool_call`, `:usage`, and terminal `:finish | :cancelled | :error`) without auto-executing tools, plus `ReqLLM.StreamResponse.close/1` on `abort` (`Esc`).
  - External `token-exchange` Vertex auth without `goth`: `:google_vertex` accepts `provider_options: [access_token: token, project_id: project, region: region]` from `H.Credentials` in memory.
  - `LLMDB` model catalog (`GET /api/v1/models` for context limits, capabilities, and pricing) + `JSV` JSON Schema validation for Slice 4 tool arguments.
  - In-process `Req.new(plug: {H.HTTP.Router, opts})` route testing alongside real `Bandit` (`port: 0`) SSE socket tests.

---

## 2. Module & Static Asset Layout

```text
lib/h/
  auth.ex                 # 256-bit owner token file (0600) + session cookie mint/verify (Plug.Crypto / :crypto.hash_equals/2)
  credentials.ex          # Short-lived in-memory token resolver (`token-exchange` / env; never persisted)
  provider.ex             # H.Provider behaviour
  provider/
    fake.ex               # Deterministic per-request scripted provider for --no-start tests
    req_llm.ex            # Real model adapter wrapping ReqLLM.stream_text/3 + StreamResponse.events/1 + LLMDB
  daemon.ex               # Transport-agnostic Elixir API wrapping Catalog + Session.Server + model catalog
  http/
    security_plug.ex      # Host allowlist (anti-DNS-rebinding), Bearer / SameSite=Strict cookie + Origin CSRF guard
    router.ex             # Plug.Router: Plug.Static (priv/static), Plug.Parsers (JSON), /api/v1/* endpoints
    sse.ex                # Chunked SSE loop over Plug.Conn (snapshot, ProcBin commit, ephemeral, overflow reset)
priv/static/
  index.html              # App shell + strict CSP (`default-src 'self'`)
  app.css                 # Clean, high-contrast responsive layout (sidebar + branch tree + transcript + composer)
  app.js                  # Native ES module: auth bootstrap, model picker, EventSource + fetch, transcript pager
test/
  h/
    http_auth_test.exs    # Fast Req.new(plug: ...) tests for Host, Bearer, cookie, and Origin CSRF guards
    http_sse_test.exs     # Supervised Bandit (ip: :loopback, port: 0) + Req (into: :self) concurrent SSE tests
    provider_req_llm_test.exs # Unit test projecting ReqLLM.StreamEvent streams without network calls
e2e/
  web_client_smoke.mjs    # Shared Playwright smoke test against a disposable Bandit daemon + H.Provider.Fake
```

---

## 3. `Bandit` + `Plug` Daemon & Security Plug (`H.HTTP`)

Started under `H.Application` (or `start_supervised!` in tests with `ip: :loopback, port: 0`, reading the assigned port via `ThousandIsland.listener_info/1`):

```elixir
{Bandit, plug: {H.HTTP.Router, daemon_opts}, ip: {127, 0, 0, 1}, port: port}
```

### `H.HTTP.SecurityPlug`

1. **`Host` allowlist (blocks DNS rebinding):** Reject `421 Misdirected Request` unless the `host` header matches the exact bound `127.0.0.1:<port>` (or `[::1]:<port>`).
2. **Owner bootstrap & dual auth:**
   - `H.Auth` generates/loads `<data_dir>/auth.token` (`0600`). Interactive startup prints `http://127.0.0.1:<port>/#token=<owner_token>`; `app.js` reads `location.hash`, strips it with `history.replaceState`, and calls `POST /api/v1/auth/session` to receive `put_resp_cookie("h_owner", session_secret, http_only: true, same_site: "Strict", path: "/api")`.
   - `Authorization: Bearer <owner_token>` (checked via `Plug.Crypto.secure_compare/2`) authenticates CLI / `curl` / `Req` callers on any route.
   - `h_owner` cookie authenticates browser `GET /api/v1/*` (including `EventSource`), and authenticates `POST /api/v1/*` **only** when `Origin == "http://127.0.0.1:#{port}"` and `content-type` is `application/json`.
3. **Parser bounds:** `Plug.Parsers` configured with `parsers: [:json], pass: ["application/json"], json_decoder: JSON, length: 4_000_000`—never converting keys or command names to atoms.

### Chunked SSE Loop (`H.HTTP.SSE`)

`Bandit` runs each HTTP/1.1 or HTTP/2 request in its own isolated BEAM process, so the Plug handler becomes the SSE subscriber directly:
1. Atomically call `H.Session.Server.subscribe_conversation(sid, cid, last_event_id)` to register `self()` in `H.PubSub` (`{:conversation, sid, cid}`) and get either missed `commit` frames (ring hit) or an initial bounded `snapshot` (newest 50 entries + `before_entry_id` + `docs`).
2. Initialize chunked stream:
   ```elixir
   conn =
     conn
     |> put_resp_content_type("text/event-stream")
     |> put_resp_header("cache-control", "no-cache")
     |> put_resp_header("x-accel-buffering", "no")
     |> send_chunked(200)
   ```
3. Loop with a `15_000 ms` `after` keepalive (`chunk(conn, ": keepalive\n\n")`), exiting cleanly as soon as `Plug.Conn.chunk/2` returns `{:error, _}`:
   - `{:commit_frame, seq, json_proc_bin}` -> `chunk(conn, ["id: ", Integer.to_string(seq), "\nevent: commit\ndata: ", json_proc_bin, "\n\n"])` (zero-copy `ProcBin` shared across all watching browser tabs).
   - `{:ephemeral_frame, json_proc_bin}` -> `chunk(conn, ["event: ephemeral\ndata: ", json_proc_bin, "\n\n"])` (**no `id:` line**, preserving `EventSource.lastEventId` across crashes).
   - **Slow-client overflow (> 128 queued messages or > 2 MiB):** Drain queued delta messages, fetch a fresh committed `snapshot` from `H.Session.Server`, and emit `event: snapshot` (`id: <newest_seq>`).

---

## 4. `H.Provider` + `H.Provider.ReqLLM` Early Wiring

`H.Provider` remains a small behaviour returning plain maps so durable records stay storage-neutral:
1. Resolve model via `ReqLLM.model(agent.model)` and list configured/supported models at `GET /api/v1/models` via `LLMDB`.
2. Resolve credentials in memory via `H.Credentials` right before `ReqLLM.stream_text/3` (for `:google_vertex`, invoke `token-exchange google ensure --for adc` and pass `provider_options: [access_token: token, project_id: project, region: region]`).
3. Stream `ReqLLM.StreamResponse.events(stream_resp)` into throttled `ephemeral` progress deltas (`live.generation`) and final assistant + usage records, calling `ReqLLM.StreamResponse.close(stream_resp)` immediately on `abort` or worker exit.

---

## 5. Minimal Zero-Build Web Client (`priv/static/`)

Served via `Plug.Static` (`at: "/", from: {:harness, "priv/static"}`) with zero npm/bundler tooling:
- **Sidebar:** Session catalog (`+ New Session` with `cwd`), model & thinking picker backed by `GET /api/v1/models` (`configure`), and conversation/fork branch tree.
- **Transcript (`ConversationTranscript`):** Upward gap-aware paging (`before_entry_id`), live `reasoning_delta` + `text_delta` rendering, **"Fork from here"** on any visible entry, and sticky `run_failure` banner with **"Continue"**.
- **Composer:** Stable `request_id` (`sessionStorage` reconciliation), `submit`, `"steer"` while busy, and `Esc` / Stop (`abort`).

---

## 6. Verification Checklist (Slice 2 Done)

- `H.HttpAuthTest` (`Req.new(plug: ...)`): verifies `Host` allowlist, `Bearer`, `SameSite=Strict` cookie, `Origin` CSRF rejection, and 4 MiB body limit.
- `H.HttpSseTest` (`start_supervised!({Bandit, ...}, port: 0)` + `Req` `into: :self` against `H.Provider.Fake`): verifies multi-tab SSE `ProcBin` sync, `Last-Event-ID` ring replay, crash-safe `ephemeral` frames without `id:`, and slow-client snapshot replacement.
- `H.ProviderReqLlmTest`: verifies `ReqLLM.StreamEvent` projection and `StreamResponse.close/1` cancellation without paid network calls.
- Shared Playwright E2E smoke check (`playwright-e2e` skill): opens browser against local Bandit instance, creates session, selects model, streams response, forks a branch, aborts mid-stream, and refreshes verifying state convergence.
- Opt-in live check (outside `mix test`): chat with a real model in the web UI via `H.Provider.ReqLLM`.
