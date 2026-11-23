---
layout: doc
title: 'Local HTTP and SSE API'
description: 'Authenticate an owner client, submit idempotent commands and reconnect a paged conversation view.'
lang: en
permalink: /docs/protocol/
---
The daemon API lives under `/api/v1`. These are not Phoenix login or LiveView routes. Use the catalog to discover sessions, the command endpoint to change one, and its conversation stream to watch results.

* Contents
{:toc}

## Read without creating a session

Use `<data_dir>/api.sock` with a nonempty Host and the owner bearer token, even on Unix sockets. For example, with curl, in a private terminal with shell tracing **off**, feed the header over stdin rather than putting its value in curl's arguments:

```sh
store="${H_DATA_DIR:-$HOME/.local/share/h}"
printf 'Authorization: Bearer %s\n' "$(cat "$store/auth.token")" |
  curl -q --fail --silent --show-error --unix-socket "$store/api.sock" \
    --header @- 'http://localhost/api/v1/sessions?include_subsessions=false'
```

Catalog queries and `GET /api/v1/sessions/events` do not activate unloaded sessions. The latter sends a catalog snapshot, then `catalog` upserts/removals; it is not a transcript stream. For TCP use the listener's bound literal address and port in `Host` (default `127.0.0.1:4100`). Cookie-authenticated mutations require the exact listener Origin and JSON content type.

## Submit once, even after a timeout

Create with `POST /api/v1/sessions` and an absolute `cwd`. Supply a stable `session_id` if creation needs to be retried. Given a session, POST JSON with `Content-Type: application/json` to `/api/v1/sessions/:sid/commands`. This example writes a note **without inference**:

```json
{"version":1,"request_id":"review-note-001","conversation_id":"1","command":"submit","args":{"type":"write","content":"Reviewed the parser change."}}
```

For model input use `type: "input"` instead. A `200` receipt acknowledges the command, not a finished reply. If the response is lost, retry the **same** request ID and normalized payload. A different payload under that ID conflicts (`409`); inventing a new ID can submit twice. Query `GET /api/v1/sessions/:sid/submissions/:request_id` for the submission's durable outcome. A sequence-guarded configuration conflict is different: refresh the view and decide whether the edit still applies.

## Resume a conversation stream

Subscribe to `GET /api/v1/sessions/:sid/conversations/:cid/events`:

- `snapshot`: replace the window and documents; set the cursor to `seq`. Page earlier history through the corresponding `entries` route.
- `commit`: ignore a stale frame. Require `prev_seq` to match your cursor, apply appended entries and document operations, then advance to `seq`. Sequence numbers are **session-wide**; don't require them to be consecutive in one conversation.
- `ephemeral`: apply progress only against a matching `base_seq`; do **not** advance the cursor. It may disappear after interruption.

Reconnect with `Last-Event-ID` set to the last committed cursor. Accept a replacement snapshot when ring replay is unavailable; on a mismatch request a fresh snapshot. Closing a subscription never means abort. Use the [route and command tables](https://gitlab.com/parlant-co/harness/-/blob/main/docs/protocol.md) for paging limits, busy policies, workspace waits, lifecycle codes and auth flows.
