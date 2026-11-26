---
layout: doc
title: 'Local HTTP and SSE API'
description: 'Authenticate an owner client, submit idempotent commands, and stream conversation events over SSE.'
lang: en
permalink: /docs/protocol/
---
The daemon serves its JSON and Server-Sent Events API under `/api/v1` on `<data_dir>/api.sock` and the loopback HTTP listener (`127.0.0.1:4100` by default). Query the catalog to list sessions, post commands to mutate a session, and subscribe to a conversation event stream to render live updates.

* Contents
{:toc}

## Read without creating a session

Send requests over `<data_dir>/api.sock` with a non-empty `Host` header and the owner bearer token from `<data_dir>/auth.token`. When testing with `curl`, turn shell tracing off and pass the header over standard input so the token stays out of process arguments:

```sh
store="${H_DATA_DIR:-$HOME/.local/share/h}"
printf 'Authorization: Bearer %s\n' "$(cat "$store/auth.token")" |
  curl -q --fail --silent --show-error --unix-socket "$store/api.sock" \
    --header @- 'http://localhost/api/v1/sessions?include_subsessions=false'
```

Query `GET /api/v1/sessions` or subscribe to `GET /api/v1/sessions/events` to inspect workspace summaries without loading dormant sessions into memory. The `/api/v1/sessions/events` stream emits an initial catalog snapshot followed by `catalog` upsert and removal events. When connecting over TCP, set `Host` to the listener's bound literal address and port (`127.0.0.1:4100` by default). Cookie-authenticated POST requests must also include a matching `Origin` header and `Content-Type: application/json`.

## Submit once, even after a timeout

Create a session with `POST /api/v1/sessions` and an absolute `cwd`, passing a client-generated `session_id` when you want creation retries to be idempotent. To submit work or record a note, POST a JSON command envelope to `/api/v1/sessions/:sid/commands`. This example appends a review note without starting model inference:

```json
{"version":1,"request_id":"review-note-001","conversation_id":"1","command":"submit","args":{"type":"write","content":"Reviewed the parser change."}}
```

Use `type: "input"` to start or steer a model turn, `command: "approve_tool"` to allow or deny a parked tool approval, or `POST /api/v1/sessions/:sid/signals` to deliver an external wake signal to a parked `wait_signal` tool call. Query `GET /api/v1/harnesses` to list registered harness profiles and `GET /api/v1/sessions/:sid/conversations/:cid/extension-status` to read cached extension status projections. An HTTP `200` receipt confirms that the coordinator accepted the command. If your connection drops before you receive the receipt, retry the request with the **same** `request_id` and normalized payload. H returns the existing receipt for a matching retry and returns `409 Conflict` if the payload changed under the same `request_id`. Poll `GET /api/v1/sessions/:sid/submissions/:request_id` to inspect the submission's committed outcome. When a sequence-guarded configuration command returns a conflict, refresh your view state before reapplying the change.

## Resume a conversation stream

Subscribe to `GET /api/v1/sessions/:sid/conversations/:cid/events` and handle three event types:

- `snapshot`: replace the current transcript window and document state, and set your durable reconnect cursor to `seq`. Fetch earlier pages through the `entries` endpoint.
- `commit`: verify that `prev_seq` matches your current cursor, apply the appended entries and document operations, and advance your cursor to `seq`. Sequence numbers increment across the whole session, so commits on one branch can advance by more than one.
- `ephemeral`: render streaming deltas and tool progress only when `base_seq` matches your committed cursor, and leave your committed cursor unchanged.

To reconnect after a disconnect, send `Last-Event-ID` with your last committed `seq`. H replays missed commits from its ring buffer or sends a fresh `snapshot` when the cursor has aged out. Closing an SSE stream leaves active session work running. See the [protocol specification](https://github.com/parlant/harness/blob/main/docs/protocol.md) for paging parameters, busy policies, workspace lease waits, and error codes.
