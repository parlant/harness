# Local daemon API v1

`H.serve()` serves the daemon API on TCP (loopback by default; see [bind settings](hi/management.md#bind-api-and-web-to-additional-addresses)) and `<data_dir>/api.sock` by default. These are daemon routes, not the Phoenix site's login or LiveView routes.

## Authentication

- On TCP, send `Host: <bound IPv4 address>:<port>` (normally `127.0.0.1:4100`). Other hosts are rejected with `421`. Unix-socket requests need a nonempty `Host` and still require API authentication.
- CLI: send `Authorization: Bearer <owner token>` from `<data_dir>/auth.token`. Send JSON bodies as `Content-Type: application/json`.
- Browser: `POST /api/v1/auth/session` with `{"token":"..."}` as JSON. A supplied `Origin` must be allowed. Success sets `h_owner` (`HttpOnly; SameSite=Strict; Path=/api`). Cookie-authenticated mutations require both the listener's exact HTTP `Origin` and JSON content type. The JSON parser's length limit is 4,000,000 bytes.

## Routes (under `/api/v1`)

| Method and path | Request / response |
|---|---|
| `POST /daemon/shutdown` | Owner idle-only stop for launcher-managed standalone instances. `{}` → `202` `{"state":"stopping"}`. `409` if busy or unsupported. Mutations are fenced after acceptance. |
| `GET /models` | `models` from the configured adapter. Named Chat Completions entries use the exact `provider:model-id` and also include `provider_name`, `supports_images`, and `price_per_million_tokens`. Missing stored keys are indicated by `unavailable_reason`. |
| `GET /provider-keys` | Lists supported API-key providers, alias names and active alias. Never returns a key. |
| `POST /provider-keys/set` | Owner write-only body `{provider,source,api_key}`. Saves or replaces an alias; the first one is active. No provider call. |
| `POST /provider-keys/use` | Body `{provider,source}` persists the active alias for the next request. |
| `POST /provider-accounts/add` | Add a local Codex alias (idempotent, no provider I/O). |
| `POST /provider-accounts/activate` | Persist selection of the stock Codex alias for new requests; independent of a session, no effect on a loaded pool. |
| `GET /provider-logins`; `POST /provider-logins/{start,status,cancel}` | [Owner device login](extensions/clients.md#implemented-device-login), independent of session state. |
| `GET /environments` | Configured `environments` and their default directories. |
| `GET /fs` | Browse `env_id` and `path`; returns the resolved path, parent, annotated directories and sessions rooted there. Excludes subsessions (`parent != null`) by default unless `include_subsessions=true`. |
| `GET /fs/files` | Bounded read-only workspace file discovery. Required `env_id` and absolute `cwd` (never falls back to daemon cwd); optional `query`, `include_hidden` (default `false`), `include_dirs` (default `true`), `exclude`, `limit` 1–500 (default 200), `max_depth` 1–32 (default 32). Skips `.git` and does not traverse symlinks. |
| `GET /fs/file` | Bounded read-only UTF-8 file reader. Required `env_id`, absolute `cwd`, and `path`; optional `offset` (default 1), `limit` 1–2000 (default 200), `max_bytes` 1–65536 (default 51200). Confined within workspace (`403` on traversal, `~`, or symlinks; `422` on dirs, non-regular files, or binary/non-UTF-8). |
| `GET /archives` | Source identity, revision (file modification time in nanoseconds), size, generation, and H session ID of each imported archive. |
| `POST /archives` | Owner bearer only. Stream `application/x-ndjson`: one header `{source,source_id,cwd,created_at,revision,size}`, then ordered entries `{parent,kind,data,created_at,title?}`, then `{end: <entry count>}`. Parent is `null` or the earlier entry's even ID (`2 × ordinal`, 1-based). Returns `{session_id,status}` with `created`, `updated`, `unchanged`, or `stale`. Archives are read-only and do not create a session worker. |
| `GET /sessions` | Catalog `sessions` (`SessionSummary` entries); optional filters `env_id`, `cwd`, `subtree`, `archived`, `include_subsessions` (default `true`; pass `false` for root sessions only). Reads `H.Catalog` without waking unloaded sessions. |
| `GET /sessions/events` | Catalog-level SSE stream (`text/event-stream`) across all sessions without waking unloaded sessions. Emits an initial `snapshot` event (`{"version":1,"seq":N,"sessions":[...]}`) followed by live `catalog` events (`{"version":1,"seq":N,"type":"upsert","session":...}` or `{"version":1,"seq":N,"type":"removed","session_id":"..."}`). |
| `POST /sessions` | Required absolute `cwd`; optional `env_id` and `harness_id` (default `host` and `coding` for new sessions only), `title`, `tags`, `agent`, `session_id`, `parent` (`{session_id, conversation_id?, at_entry_id?, task_id?}`), and `role` (defaults to `"subagent"` when `parent` is present). Returns `session` and `seq`. Supply a stable `session_id` for create-or-attach; an explicit different profile, workspace, or parent conflicts (`409`), and an omitted profile, environment, or parent uses the recorded one when attaching. An unavailable recorded profile or environment returns `503`. Omitting the ID can create a second session on retry. |
| `GET /sessions/:sid` | `session`, `conversations` with ancestry, and `tasks`. No open-waits API. |
| `POST /sessions/:sid/triage` | Body `{needs_attention?, tags?}` with at least one field. Updates catalog triage state (boolean `needs_attention`) or replaces tags without waking unloaded sessions → `200` `{"session":...}`. |
| `POST /sessions/:sid/stop` | Optional `{reason}`. Aborts active generation, tool, compaction, and user-shell work across all conversations in the session → `200` `{"session":...}`. |
| `POST /sessions/:sid/archive` | Optional `{archived, stop}` (defaults `archived: true`, `stop: false`). When archiving, returns `409` `{"error":"session_busy"}` if busy unless `stop: true` (or `force: true`), cleanly unloads the session supervisor from RAM, and sets `archived: true`, `attention: "archived"`, `needs_attention: false`, `loaded: false`. Read endpoints (`GET /sessions/:sid`, `/entries`, `/events`) and `POST /sessions/:sid/fork` inspect archived sessions directly from storage without waking OTP or unarchiving; `POST /sessions/:sid/commands` or `POST /sessions` (attach) automatically unarchives and starts native archived sessions. |
| `POST /sessions/:sid/fork` | Required existing target `cwd`; optional `env_id`, `conversation_id`, `at_entry_id`, `title`, `session_id`. Copies visible branch entries and session tags into a new session bound to `cwd` → `200` `{"session":...,"seq":N}`. |
| `GET /sessions/:sid/files` | Same bounded file discovery as `GET /fs/files`, strictly scoped to the session's catalog `{env_id, cwd}` (returns `503` if environment unavailable). |
| `GET /sessions/:sid/file` | Same bounded UTF-8 file read as `GET /fs/file`, strictly scoped to the session's catalog `{env_id, cwd}` (returns `503` if environment unavailable). |
| `GET /sessions/:sid/submissions/:request_id` | Durable submission outcome (`session_id`, `conversation_id`, `submission_id`, `request_id`, `kind`, `status`, `entry_id`, `answer_entry_id`, `answer_text`, `reason`, `seq`), or `404` when unknown. |
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
| `workspace_wait` | `action: "cancel"` or `"stop_holder"`, plus `task_id` and opaque `lease_id` from `live.workspace_wait`. Cancel aborts the waiting conversation's active run; stop-holder requests cancellation of the holding conversation and prioritizes this waiter for handoff after cleanup. Stale stop targets return `409` `"stale_workspace_wait"`. Idempotent by request ID. |
| `abort` | Abort active generation or user-shell work in the conversation, optionally with `reason`. Although validation accepts `task_id`, the handler does **not** narrow cancellation to that task. |
| `withdraw` | `submission_ids`: non-empty array of queued submission IDs to withdraw atomically from the conversation's `inbox`. All-or-conflict (`409` `"submission_not_queued"` if any ID is missing, already consumed, already withdrawn, or belongs to another conversation). Receipt returns `status: "done"` and `withdrawn`: array of withdrawn inbox items (`submission_id`, `request_id`, `when_busy`, `content`) in original `inbox` order; idempotent retries return the stored `withdrawn` array. |

If a session's bound working directory no longer exists (`cwd_exists: false`), read endpoints (`GET /sessions/:sid`, `GET /sessions/:sid/conversations/:cid/entries`, `GET /sessions/:sid/conversations/:cid/events`) and management commands (`abort`, `withdraw`, `rename`, `configure`, `fork`, `submit/write`) remain available, while work-starting commands (`submit/input`, `submit/continue`, `fork_and_submit`, `user_shell`, `compact`) return `409` `{"error":"cwd_missing"}`. Use `POST /sessions/:sid/fork` to continue the conversation in an existing working directory.

## Workspace mutation waits

Coding tools `bash`, `read`, `write`, and `edit` take an optional `cwd`: an existing absolute directory in the session's environment. Relative file paths and shell commands use that directory for the call. Mutating tools (including every `bash` call) automatically queue when another conversation holds the effective `{env_id, canonical_cwd}` lease. User-shell commands still use the session workspace. Admission is FIFO, with a reserved handoff signalled by the daemon on release or owner exit. Non-mutating tools do not wait. Shell `cd`, `git -C`, and absolute file arguments do not change the lease key; use `cwd` at the worktree root to coordinate writes there.

Overrides apply to one call only. Every call that omits `cwd` uses the session workspace. Catalog `cwd`, `AGENTS.md` instructions, session file browsing, and `!`/`!!` are unchanged. Results for workspace-bound coding calls record the resolved directory in `details.cwd`.

For parallel subagent edits, prepare separate Git worktrees first, then pass each root as `subagent.cwd`. Omit it to use the parent's session workspace; `read_only: true` is suitable for shared-directory exploration. `cwd` is for new children only, not follow-ups. H does not create, merge, or remove worktrees automatically.

While queued, `live.workspace_wait` contains `env_id`, `cwd` (the effective lease target), `task_id`, `holder_session_id`, `holder_conversation_id`, and an opaque `lease_id`. Tool or user-shell live status is `"waiting"`; no execution attempt has started. Holder changes update the wait document. It disappears when execution starts or the wait is cancelled. Pending persisted workspace waits can rejoin the queue for the recorded directory after restart; interrupted **running** unsafe commands are still never replayed.

Both clients offer **Cancel wait** and **Stop holder and acquire**. hi opens an action picker on entering a wait; `/workspace` reopens it. Dismissing the picker keeps waiting. Cancelling does not stop the holder. Stop-holder targets that specific lease, not an arbitrary session or a later command; it never clears a live lock underneath a worker. The owner commits cancellation and stops its work before releasing. The receipt acknowledges the request, not completion of cleanup or acquisition.

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

Exact cwd + qualified model wins, then cwd, model, provider, `:default`, and finally the built-in threshold. Use positive integer token counts, or `:off` at any scope. Changing the threshold does not change the provider's actual context window. A successful automatic summary commits a boundary and resumes the original input; queued follow-ups still wait. No `/continue` or second prompt needed. If there is no safe prefix to summarize, the daemon attempts the original request instead of looping. Failed or aborted summarization does not discard history or start another turn. Automatic failures carry `automatic: true` in `live.compaction_failure`, so clients can distinguish a paused prompt from a failed `/compact`. Manual `/compact` remains available. A failed manual compaction leaves the transcript intact; retry `/compact` with a fresh request, optionally with instructions for a shorter summary. `/continue` resumes an unanswered turn, not a partial summary.

There is no built-in tool-round cap. An optional future extension could enforce a round, cost, or elapsed-time budget to bound unattended work or catch a looping model. That is separate from context management. Without that policy a model that keeps calling tools may keep spending until you abort it.

## Provider retries

Retryable generation and compaction failures keep the run active. The coordinator commits the retry deadline before arming its timer. Defaults are three retries, waiting 2, 4, then 8 seconds; exponential backoff is capped at 60 seconds. Startup options `retry_limit` and `retry_backoff_ms` override the budget and base delay. A provider's `Retry-After` header (seconds or HTTP date) can lengthen a wait, up to 24 hours.

During backoff and the retry request, session summaries report `attention: "retrying"`, `active: true`, and `activity_kind: "retry"`. This is processing work, not an operator-attention error. `activity_label` identifies the attempt and error code. `next_wake_at` is the Unix-millisecond deadline while waiting, otherwise `null`. Other running work in the same session can take display priority.

Conversation snapshots and commits carry `live.generation.retry` or `live.compaction.retry`: `attempt` (one-based retry number), `max_attempts`, `delay_ms`, `until` (Unix milliseconds), `status` (`"waiting"` or `"running"`), `code`, and a sanitized provider `message`. Clients show the reason and scheduled wait rather than implying that output is streaming. Success clears the retry display. Reopening a sleeping task preserves its deadline and retry count. Abort cancels the work; a late timer cannot restart it.

HTTP 429 messages explain rate limits versus quota or spending-cap restrictions and retain the provider's explanation. Waiting cannot lift a spending cap: raise the applicable limit, wait for its reset, or change provider/project. Once the retry budget is exhausted, the run becomes an error with the explanation and retry count intact. Resolve the restriction before using Continue, or retry `/compact` for a failed manual compaction. Managed-account dispatch/no-resume policies still take precedence; this does not authorize replay of tools or unsafe external effects.

## SessionSummary lineage, attention, and lifecycle fields

Each `SessionSummary` returned by `GET /sessions`, `GET /sessions/events`, `POST /sessions`, `GET /sessions/:sid`, `POST /sessions/:sid/{triage,stop,archive,fork}`, and `GET /fs` (`sessions` and `directories[*].latest_session`) includes immutable spawn lineage, attention, and lifecycle metadata:

- `parent`: `null` for root sessions, or `{"session_id": "...", "conversation_id": "1", "at_entry_id": "42" | null, "task_id": "43" | null, "depth": 1}` anchoring a subsession to its parent step. New subsessions also record the launch workspace as `parent.env_id` and `parent.cwd`: the parent's bound directory and environment. Older records may omit the launch workspace.
- `role`: `null` or a short role string (max 64 chars, no control characters), defaulting to `"subagent"` when spawned with `parent`.
- `attention`: `"idle"` | `"running"` | `"sleeping"` | `"retrying"` | `"error"` | `"quarantined"` | `"archived"` (always `"quarantined"` when `status == "quarantined"`, and `"archived"` when `archived == true` and not quarantined).
- Imported sessions have `status: "archived"`, `archived: true`, `attention: "archived"`, and `active: false`.
- `activity_kind`: `null` | `"generation"` | `"tool"` | `"user_shell"` | `"compaction"` | `"retry"`.
- `activity_label`: `null` or a sanitized short string (max 120 chars, no control characters), e.g. active tool name (`"bash"`), `"shell"`, `"compact"`, `"retrying"`, or failure reason/code when `attention == "error"`.
- `queued_count`: non-negative integer count of queued inbox items across conversations in the session.
- `tags`: case-sensitive labels, default `[]`. At most 32 tags, each 1–64 characters without commas or control characters. Surrounding whitespace is trimmed and duplicates are removed. Set `tags: []` to clear all tags.
- `needs_attention`: boolean triage flag persisted in `H.Catalog` (`true` on creation and when a run settles to `"idle"`, `"error"`, or `"quarantined"`; `false` while `"running"`/`"sleeping"`/`"retrying"`, when `archived == true`, or when manually dismissed via `POST /sessions/:sid/triage`).
- `archived`: boolean persisted in `H.Catalog` (`false` by default).
- `loaded`: live boolean indicating whether the session's `H.Session.Server` coordinator is currently running in OTP RAM (never persisted to disk).
- `cwd`: the original session working directory, not a turn-scoped tool override.
- `cwd_exists`: live boolean indicating whether the session's original working directory currently exists (`false` when a host `cwd` was deleted).

## SSE cursor rules

Each JSON frame identifies the session and conversation. Sequence numbers are session-wide; a jump in numbers alone does not indicate a lost conversation update.

| Event | SSE `id` | Client action |
|---|---|---|
| `snapshot` | `seq` | Replace the window with `entries` (up to 50, oldest first) and `docs` (`live`, `inbox`, `agent`, `usage`). Use `before_entry_id` to page further back. |
| `commit` | `seq` | Ignore stale frames. For a newer frame require `prev_seq` to equal the conversation cursor, append `appended_entries`, apply `doc_ops` and advance the cursor. On mismatch, request a fresh snapshot. |
| `ephemeral` | None | Apply progress `doc_ops` only for a matching `base_seq`. Do not advance the cursor; unflushed progress can be lost on restart. |

`doc_ops` maps document names to ordered operations such as `["replace", value]` or `["set", path, value]`. Reconnect with `Last-Event-ID` (or `last_event_id` query parameter) for replay from the recent commit ring; otherwise expect a snapshot if replay is unavailable. A slow connection can receive a replacement snapshot instead of queued deltas. Disconnecting does not abort a run.

Live tool and user-shell output previews stop after the first 50 KiB per attempt and include `[Live output capped]` if more was produced. This also bounds the partial shell output saved in live checkpoints for recovery. The final result and any full-output spill file use the execution environment's normal output policy.

Sources: [router](../lib/h/http/router.ex), [security plug](../lib/h/http/security_plug.ex), [daemon validation](../lib/h/daemon.ex), [SSE transport](../lib/h/http/sse.ex), [transcript reducer](../lib/h/transcript.ex).
