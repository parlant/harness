# Local daemon API v1

`H.serve()` serves only the daemon API on loopback TCP and, by default, `<data_dir>/api.sock`. These are daemon routes, not the Phoenix site's login or LiveView routes.

## Authentication

- On TCP, send `Host: 127.0.0.1:<port>` or `[::1]:<port>`; other hosts are rejected with `421` by default. Unix-socket requests need a nonempty `Host` and still require API authentication.
- CLI: send `Authorization: Bearer <owner token>` from `<data_dir>/auth.token`. Send JSON bodies as `Content-Type: application/json`.
- Browser: `POST /api/v1/auth/session` with `{"token":"..."}` as JSON. A supplied `Origin` must be allowed. Success sets `h_owner` (`HttpOnly; SameSite=Strict; Path=/api`). Cookie-authenticated mutations require both an allowed loopback `Origin` and JSON content type. The JSON parser's length limit is 4,000,000 bytes.

## Routes (under `/api/v1`)

| Method and path | Request / response |
|---|---|
| `GET /models` | `models` from the configured provider. |
| `GET /environments` | Configured `environments` and their default directories. |
| `GET /fs` | Browse `env_id` and `path`; returns the resolved path, parent, annotated directories and sessions rooted there. |
| `GET /sessions` | Catalog `sessions`; optional filters `env_id`, `cwd`, `subtree`. |
| `POST /sessions` | Required absolute `cwd`; optional `env_id` (default `host`), `harness_id` (default `coding`), `title`, `agent`, `session_id`. Returns `session` and `seq`. Supply a stable `session_id` for create-or-attach; a different workspace conflicts. Omitting the ID can create a second session on retry. |
| `GET /sessions/:sid` | `session`, `conversations` with ancestry, and `tasks`. No open-waits API. |
| `GET /sessions/:sid/conversations/:cid/entries` | `items` and `next_cursor` through the visible lineage. `order=desc` (default) or `asc`; `cursor` optional, `limit` 1–200 (default 50). |
| `GET /sessions/:sid/conversations/:cid/events` | Conversation view as `text/event-stream` (below). |
| `POST /sessions/:sid/commands` | Command envelope → receipt. |

## Commands

```json
{"version":1,"request_id":"demo-1","conversation_id":"1","command":"submit","args":{"type":"input","content":"Explain this project"}}
```

A `200` receipt acknowledges the command, not a completed model reply. It includes `version`, `request_id`, integer `seq`, and command-specific fields such as `submission_id`, `status`, or the new `conversation_id`. Retry an ambiguous request with the **same request ID and normalized command**: it returns a receipt without repeating the command. Reusing the ID for another payload returns `409`.

| Command | `args` |
|---|---|
| `submit` | `type: "input"` with nonempty `content` (string or block list). `when_busy`: `follow_up` (default), `steer`, `reject`; `when_idle`: `start` (default), `reject`. Also accepts `type: "continue"` or display-only `type: "write"`. |
| `fork` | `at_entry_id`: visible entry at which to branch. |
| `fork_and_submit` | `at_entry_id` and input `content` in one commit; accepts input busy/idle policies. |
| `configure` | `model`, `thinking`, `system_prompt`, `instructions`, `tools`, `max_turns`; optional `expected_seq` conflict guard. |
| `abort` | Abort active generation work in the conversation, optionally with `reason`. Although validation accepts `task_id`, the handler does **not** narrow cancellation to that task. |
| `withdraw` | `submission_ids`: non-empty array of queued submission IDs to withdraw atomically from the conversation's `inbox`. All-or-conflict (`409` `"submission_not_queued"` if any ID is missing, already consumed, already withdrawn, or belongs to another conversation). Receipt returns `status: "done"` and `withdrawn`: array of withdrawn inbox items (`submission_id`, `request_id`, `when_busy`, `content`) in original `inbox` order; idempotent retries return the stored `withdrawn` array. |

## SSE cursor rules

Each JSON frame identifies the session and conversation. Sequence numbers are session-wide; a jump in numbers alone does not indicate a lost conversation update.

| Event | SSE `id` | Client action |
|---|---|---|
| `snapshot` | `seq` | Replace the window with `entries` (up to 50, oldest first) and `docs` (`live`, `inbox`, `agent`, `usage`). Use `before_entry_id` to page further back. |
| `commit` | `seq` | Ignore stale frames. For a newer frame require `prev_seq` to equal the conversation cursor, append `appended_entries`, apply `doc_ops` and advance the cursor. On mismatch, request a fresh snapshot. |
| `ephemeral` | None | Apply progress `doc_ops` only for a matching `base_seq`. Do not advance the cursor; unflushed progress can be lost on restart. |

`doc_ops` maps document names to ordered operations such as `["replace", value]` or `["set", path, value]`. Reconnect with `Last-Event-ID` (or `last_event_id` query parameter) for replay from the recent commit ring; otherwise expect a snapshot if replay is unavailable. A slow connection can receive a replacement snapshot instead of queued deltas. Disconnecting does not abort a run.

Sources: [router](../lib/h/http/router.ex), [security plug](../lib/h/http/security_plug.ex), [daemon validation](../lib/h/daemon.ex), [SSE transport](../lib/h/http/sse.ex), [transcript reducer](../lib/h/transcript.ex).
