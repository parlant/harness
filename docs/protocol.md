# Local daemon API v1

`H.serve()` serves only the daemon API on loopback TCP and, by default, `<data_dir>/api.sock`. These are daemon routes, not the Phoenix site's login or LiveView routes.

## Authentication

- On TCP, send `Host: 127.0.0.1:<port>` or `[::1]:<port>`; other hosts are rejected with `421` by default. Unix-socket requests need a nonempty `Host` and still require API authentication.
- CLI: send `Authorization: Bearer <owner token>` from `<data_dir>/auth.token`. Send JSON bodies as `Content-Type: application/json`.
- Browser: `POST /api/v1/auth/session` with `{"token":"..."}` as JSON. A supplied `Origin` must be allowed. Success sets `h_owner` (`HttpOnly; SameSite=Strict; Path=/api`). Cookie-authenticated mutations require both an allowed loopback `Origin` and JSON content type. The JSON parser's length limit is 4,000,000 bytes.

## Routes (under `/api/v1`)

| Method and path | Request / response |
|---|---|
| `POST /daemon/shutdown` | Owner idle-only stop for launcher-managed standalone instances. `{}` → `202` `{"state":"stopping"}`. `409` if busy or unsupported. Mutations are fenced after acceptance. |
| `GET /models` | `models` from the configured provider. |
| `GET /provider-keys` | Lists supported API-key providers, alias names and active alias. Never returns a key. |
| `POST /provider-keys/set` | Owner write-only body `{provider,source,api_key}`. Saves or replaces an alias; the first one is active. No provider call. |
| `POST /provider-keys/use` | Body `{provider,source}` persists the active alias for the next request. |
| `POST /provider-accounts/add` | Add a local Codex alias (idempotent, no provider I/O). |
| `POST /provider-accounts/activate` | Persist selection of the stock Codex alias for new requests; independent of a session, no effect on a loaded pool. |
| `GET /provider-logins`; `POST /provider-logins/{start,status,cancel}` | [Owner device login](extensions/clients.md#implemented-device-login), independent of session state. |
| `GET /environments` | Configured `environments` and their default directories. |
| `GET /fs` | Browse `env_id` and `path`; returns the resolved path, parent, annotated directories and sessions rooted there. |
| `GET /fs/files` | Bounded read-only workspace file discovery. Required `env_id` and absolute `cwd` (never falls back to daemon cwd); optional `query`, `include_hidden` (default `false`), `include_dirs` (default `true`), `exclude`, `limit` 1–500 (default 200), `max_depth` 1–32 (default 32). Skips `.git` and does not traverse symlinks. |
| `GET /fs/file` | Bounded read-only UTF-8 file reader. Required `env_id`, absolute `cwd`, and `path`; optional `offset` (default 1), `limit` 1–2000 (default 200), `max_bytes` 1–65536 (default 51200). Confined within workspace (`403` on traversal, `~`, or symlinks; `422` on dirs, non-regular files, or binary/non-UTF-8). |
| `GET /sessions` | Catalog `sessions`; optional filters `env_id`, `cwd`, `subtree`. |
| `POST /sessions` | Required absolute `cwd`; optional `env_id` and `harness_id` (default `host` and `coding` for new sessions only), `title`, `agent`, `session_id`. Returns `session` and `seq`. Supply a stable `session_id` for create-or-attach; an explicit different profile or workspace conflicts, and an omitted profile or environment uses the recorded one when attaching. An unavailable recorded profile or environment returns `503`. Omitting the ID can create a second session on retry. |
| `GET /sessions/:sid` | `session`, `conversations` with ancestry, and `tasks`. No open-waits API. |
| `GET /sessions/:sid/files` | Same bounded file discovery as `GET /fs/files`, strictly scoped to the session's catalog `{env_id, cwd}` (returns `503` if environment unavailable). |
| `GET /sessions/:sid/file` | Same bounded UTF-8 file read as `GET /fs/file`, strictly scoped to the session's catalog `{env_id, cwd}` (returns `503` if environment unavailable). |
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
| `configure` | `model`, `thinking`, `system_prompt`, `instructions`, `tools`; optional `expected_seq` conflict guard. |
| `compact` | Required `expected_seq`, optional `instructions`. Accepts an idle, compactable conversation; the receipt is not a completed summary. On success the daemon appends a compaction marker with the summary and retained boundary. Failure does not discard the previous context. |
| `rename` | `title` sets the session display name; optional session-wide `expected_seq` rejects stale writes. |
| `user_shell` | `command`, boolean `include_in_context`, and required `expected_seq`. Requires an idle conversation. Runs in the bound environment after intent is committed, under the workspace lease. Interrupted unsafe commands are not replayed. Excluded commands and results stay out of model history and `search_history`. |
| `abort` | Abort active generation or user-shell work in the conversation, optionally with `reason`. Although validation accepts `task_id`, the handler does **not** narrow cancellation to that task. |
| `withdraw` | `submission_ids`: non-empty array of queued submission IDs to withdraw atomically from the conversation's `inbox`. All-or-conflict (`409` `"submission_not_queued"` if any ID is missing, already consumed, already withdrawn, or belongs to another conversation). Receipt returns `status: "done"` and `withdrawn`: array of withdrawn inbox items (`submission_id`, `request_id`, `when_busy`, `content`) in original `inbox` order; idempotent retries return the stored `withdrawn` array. |

## Automatic compaction and continuation

Before each generation (including after a completed tool batch), the daemon estimates the size of the **projected** messages and tool schemas: roughly one token per four serialized bytes. This is not cumulative session usage or an exact provider token count. For a known ReqLLM model the default trigger is its context window minus 16,384 tokens (reserve at most half of a small window). Unknown models and other adapters default to 96,000 estimated tokens.

Override thresholds at daemon startup, e.g.:

```elixir
H.serve(auto_compaction: %{
  {:provider, "openai"} => 100_000,
  {:model, "openai:gpt-5.4"} => 150_000,
  {:cwd, "/work/project"} => 80_000,
  {:cwd, "/work/project", "openai:gpt-5.4"} => 60_000
})
```

Exact cwd + qualified model wins, then cwd, model, provider, `:default`, and finally the built-in threshold. Use positive integer token counts, or `:off` at any scope. Changing the threshold does not change the provider's actual context window. A successful automatic summary commits a boundary and resumes the original input; queued follow-ups still wait. No `/continue` or second prompt needed. If there is no safe prefix to summarize, the daemon attempts the original request instead of looping. Failed or aborted summarization does not discard history or start another turn. Manual `/compact` remains available.

There is no built-in tool-round cap. An optional future extension could enforce a round, cost, or elapsed-time budget to bound unattended work or catch a looping model. That is separate from context management. Without that policy a model that keeps calling tools may keep spending until you abort it.

## SSE cursor rules

Each JSON frame identifies the session and conversation. Sequence numbers are session-wide; a jump in numbers alone does not indicate a lost conversation update.

| Event | SSE `id` | Client action |
|---|---|---|
| `snapshot` | `seq` | Replace the window with `entries` (up to 50, oldest first) and `docs` (`live`, `inbox`, `agent`, `usage`). Use `before_entry_id` to page further back. |
| `commit` | `seq` | Ignore stale frames. For a newer frame require `prev_seq` to equal the conversation cursor, append `appended_entries`, apply `doc_ops` and advance the cursor. On mismatch, request a fresh snapshot. |
| `ephemeral` | None | Apply progress `doc_ops` only for a matching `base_seq`. Do not advance the cursor; unflushed progress can be lost on restart. |

`doc_ops` maps document names to ordered operations such as `["replace", value]` or `["set", path, value]`. Reconnect with `Last-Event-ID` (or `last_event_id` query parameter) for replay from the recent commit ring; otherwise expect a snapshot if replay is unavailable. A slow connection can receive a replacement snapshot instead of queued deltas. Disconnecting does not abort a run.

Sources: [router](../lib/h/http/router.ex), [security plug](../lib/h/http/security_plug.ex), [daemon validation](../lib/h/daemon.ex), [SSE transport](../lib/h/http/sse.ex), [transcript reducer](../lib/h/transcript.ex).
