# Wire Protocol and First Web Client

**Status:** proposal for Slice 2. Only the pure Elixir history API (`H.Session`, `H.Conversation`, `H.Entry`) exists today.

---

## 1. Separate Domain API from Transport

`H` owns sessions, admission, scheduling, persistence, and cancellation. Clients send commands, read bounded history pages, and observe committed state updates. Closing a browser tab or `curl` stream never cancels admitted work.

The first network surface is **HTTP JSON commands + SSE (`text/event-stream`) state observation** served by `Bandit` + `Plug` (`H.HTTP.Router`), calling the transport-agnostic `H.Daemon` API.

The first human client is a **zero-build web client** (`priv/static/index.html`, `app.js`, `app.css` using native browser ES modules, `fetch`, and `EventSource`, served by `Plug.Static`) so `H` can chat with real models via `ReqLLM` in Slice 2 and self-host in the browser by Slice 4. Every route and stream stays plain JSON so `curl`, `hurl`, and `Req` tests drive the daemon directly without a browser.

---

## 2. Endpoints

| Method & Path | Purpose |
|---|---|
| `GET /` & `GET /assets/*` | Serve the local web client (`index.html`, `app.js`, `app.css`) with strict `Content-Security-Policy` (`default-src 'self'`). |
| `POST /api/v1/auth/session` | Exchange owner token (`{"token": "..."}`) for an `HttpOnly; SameSite=Strict` cookie so browser `EventSource` authenticates without tokens in URLs. |
| `GET /api/v1/models` | List available models, capabilities, and context limits from `LLMDB` (`ReqLLM`). |
| `GET /api/v1/sessions` | List sessions from `H.Catalog` ETS table (`id`, `title`, `cwd`, `root_conversation_id`, `active`, `next_wake_at`, `status`) without waking unloaded sessions. |
| `POST /api/v1/sessions` | Idempotently create a session (`request_id`, `session_id`, `cwd`, optional initial `agent`). |
| `GET /api/v1/sessions/:sid` | Session detail: conversation ancestry forest (`id`, `parent`, `owner`), task graph summary, and open waits. |
| `GET /api/v1/sessions/:sid/conversations/:cid/entries` | Cursor-paged raw entries (`order=desc\|asc`, `cursor`, `limit <= 200`), respecting fork cutoffs. |
| `GET /api/v1/sessions/:sid/conversations/:cid/events` | SSE stream: atomic initial `snapshot` followed by `commit` and `ephemeral` delta frames. Supports `Last-Event-ID`. |
| `POST /api/v1/sessions/:sid/commands` | Mutating session/conversation command envelope returning an idempotent receipt. |

---

## 3. Authentication, Anti-CSRF, and Anti-DNS-Rebinding

1. **`Host` allowlist:** Every request must carry `Host: 127.0.0.1:<port>` (or `[::1]:<port>`). Any other `Host` is rejected `421 Misdirected Request` before dispatch (blocks DNS rebinding).
2. **CLI / test auth:** `Authorization: Bearer <owner_token>` (verified via `:crypto.hash_equals/2`) works on all `GET` and `POST` routes.
3. **Browser auth:** Browser exchanges the owner token once at `POST /api/v1/auth/session` to set `Cookie: h_owner=<session_token>; HttpOnly; SameSite=Strict; Path=/api`.
   - `GET /api/v1/...` (including `EventSource`) accepts `Authorization: Bearer` or `Cookie: h_owner`.
   - Mutating `POST /api/v1/...` requires `Authorization: Bearer` **or** (`Cookie: h_owner` **AND** `Origin: http://127.0.0.1:<port>` **AND** `Content-Type: application/json`).
4. **Input safety:** Enforce header cap (16 KiB), body cap (e.g. 4 MiB), idle socket read timeout, and `H.Schema` validation without `String.to_atom/1`.

---

## 4. Command Envelope and Idempotent Receipts

Request (`POST /api/v1/sessions/demo/commands`):

```json
{
  "version": 1,
  "request_id": "client-generated-stable-id",
  "command": "submit",
  "conversation_id": "1",
  "args": {
    "type": "input",
    "content": [{"type": "text", "text": "Explain H.Session.fork/3"}],
    "when_busy": "follow_up",
    "when_idle": "start"
  }
}
```

Receipt (`200 OK`):

```json
{
  "version": 1,
  "request_id": "client-generated-stable-id",
  "seq": 42,
  "submission_id": "17",
  "status": "queued"
}
```

- Wire IDs are strings (`"1"`, `"17"`) even when internal session-local IDs are positive integers; `seq` is a monotonic integer.
- Returning `200 OK` means admission is durable in `H.Storage`, not that the model has finished answering.
- Retrying the same `(session_id, request_id)` with the same normalized payload returns the original receipt (with its latest `status`); a different payload returns `409 Conflict`.

### Commands

| Command | Slice | Meaning |
|---|---|---|
| `submit` | 1–2 | Admit `type: "input"` (`when_busy`: `"follow_up" \| "steer" \| "reject"`, `when_idle`: `"start" \| "reject"`), idle `type: "continue"`, or display-only `type: "write"`. |
| `fork` | 1–2 | Create a branch inheriting history through visible `at_entry_id`, applying document `fork` rules (`as_of`, `current`, `initial`). |
| `fork_and_submit` | 1–2 | Atomically fork at `at_entry_id` and admit the branch's first input in one commit. |
| `configure` | 1–2 | Update `agent` document (`model`, `thinking`, `instructions`, `tools`, `max_turns`, `compaction`) for subsequent turns; optional `expected_seq` guard. |
| `abort` | 1–2 | Persist cancellation of a conversation or task scope (`background: true` optional in Slice 5). |
| `signal` | 5 | Deliver a typed external signal (`{task_id, token, key, value}`) to wake a parked task/gate (`delivered \| duplicate \| invalid \| closed \| not_found`). |

---

## 5. SSE State-View Stream (`snapshot`, `commit`, `ephemeral`)

Clients render committed state views rather than assembling UI state from raw event streams.

To keep **zero-copy `ProcBin` fan-out** across all subscribers of a conversation while letting each client scroll/page its own transcript window independently, `H.Session.Server` never tracks per-client scroll windows. Instead:

1. **Atomic subscribe + bounded `snapshot` (`event: snapshot`, `id: <seq>`):**
   On `GET .../conversations/:cid/events` (when no `Last-Event-ID` is supplied, or when `Last-Event-ID` is older than `H.Session.Server`'s bounded recent-commit ring), `H.Session.Server` atomically registers the SSE worker PID in `H.PubSub` (`{:conversation, sid, cid}`) and returns the current `seq`, the newest `window_limit` entries (default 50) + `before_entry_id` cursor, and current conversation documents (`live`, `inbox`, `agent`, `usage`):
   ```text
   id: 42
   event: snapshot
   data: {"version":1,"session_id":"demo","conversation_id":"1","seq":42,"before_entry_id":"12","entries":[...],"docs":{"live":{...},"inbox":[...],"agent":{...},"usage":{...}}}
   ```
   If `Last-Event-ID: <last_seq>` hits the recent-commit ring, the SSE worker replays the exact missed `commit` frames `(last_seq + 1)..seq` with zero gap.

2. **Durable commit frame (`event: commit`, `id: <seq>`):**
   For every durable batch committed on `(sid, cid)`, `H.Session.Server` encodes the commit payload **once** as a shared refc binary (`ProcBin`) and broadcasts `{:commit_frame, seq, bin}` via `H.PubSub`:
   ```text
   id: 43
   event: commit
   data: {"version":1,"session_id":"demo","conversation_id":"1","seq":43,"appended_entries":[...],"doc_ops":{"live":[...],"usage":[...]}}
   ```
   Every live watcher receives the exact same `ProcBin` pointer (zero re-encoding, zero copying) and appends `appended_entries` / applies `doc_ops` to its local `ConversationTranscript`.

3. **Deferred streaming progress (`event: ephemeral`, NO `id:` line):**
   Between durable flushes (`persist_within_ms`, default 1,000 ms), throttled LLM token chunks and tool output chunks broadcast as `event: ephemeral` **without an SSE `id:` field**:
   ```text
   event: ephemeral
   data: {"version":1,"session_id":"demo","conversation_id":"1","base_seq":43,"doc_ops":{"live":[...]}}
   ```
   Per the SSE standard, omitting `id:` leaves `EventSource.lastEventId` at `43` (the last durable commit on disk). If the BEAM VM crashes before the 1-second flush, `EventSource` reconnects with `Last-Event-ID: 43`—never colliding with post-recovery `seq` numbers.

4. **Bounded slow-client backpressure (state replacement, never producer blocking):**
   Each SSE connection worker bounds its pending queue by frame count (e.g. 128 frames) and byte size (e.g. 2 MiB). If a slow browser tab exceeds either bound, the SSE worker drops its queued deltas, fetches a fresh committed `snapshot` from `H.Session.Server`, and sends `event: snapshot` (`id: <newest_seq>`). `H.Session.Server` never blocks on a slow client.

---

## 6. Web Client Responsibilities (`priv/static/`)

- Generate and persist pending `request_id`s in `sessionStorage` until admission is confirmed, reconciling on reconnect.
- Maintain `ConversationTranscript` locally: merge live `snapshot`/`commit` windows with older pages loaded on scroll via `GET .../entries?cursor=<before_entry_id>&order=desc`.
- Render `docs.live` directly: active run status (`turns`), streaming `generation.message` (thinking + text + tool calls), running `tools` output slots, and sticky `run_failure` / `compaction_failure` banners with a one-click `Continue` action.
- Keep selected session, selected conversation/branch, history tree cursor, and unsent per-branch drafts purely client-local (URL hash / `localStorage`), naming `conversation_id` explicitly on every command.
