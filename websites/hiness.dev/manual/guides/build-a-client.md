---
layout: doc
title: 'Build a client'
description: 'Write a thin client that reads the session catalog, streams conversation events over SSE, and submits idempotent commands.'
lang: en
permalink: /docs/guides/build-a-client/
---
Build your client as a view and command layer over H's local `/api/v1` endpoints. Start with a read-only client that lists sessions from the catalog, renders the latest committed entries in a conversation, and reconnects cleanly across disconnects.

* Contents
{:toc}

## Implement one read-only view

1. Start a test daemon against a disposable data directory and run the [authenticated catalog query](/docs/protocol/#read-without-creating-a-session) (`GET /api/v1/sessions`). Render the returned session titles and status fields as plain text.
2. When the user picks a session, fetch `GET /api/v1/sessions/:sid` to list its conversations, then subscribe to `GET /api/v1/sessions/:sid/conversations/:cid/events`. Store the selected `session_id`, `conversation_id`, page window, and reconnect cursor in your client's local state.
3. Apply `snapshot`, `commit`, and `ephemeral` events according to the [conversation stream rules](/docs/protocol/#resume-a-conversation-stream). When the user switches to another branch, close the old SSE stream first so late frames from the previous branch cannot overwrite the new view.

Test your stream reducer against a recorded fixture containing an initial `snapshot`, a committed frame, a transient `ephemeral` progress frame, and a second committed frame. Simulate a disconnect after the `ephemeral` frame and verify that your client reconnects with `Last-Event-ID` set to the last **committed** sequence number. Test both ring-buffer replay and full snapshot replacement, and verify that closing the client window leaves the session running.

## Add a write without inference

Implement the `submit` command with `type: "write"` using the [JSON command envelope](/docs/protocol/#submit-once-even-after-a-timeout). Generate a `request_id` and keep the normalized payload in memory until the receipt arrives. Simulate a dropped HTTP response and retry with the same `request_id` and payload: confirm that H deduplicates the retry and commits a single note entry to the transcript stream. Once read streaming and idempotent writes pass, add `type: "input"` for model turns.

Inspect the [Rust TUI transcript reducer](https://github.com/parlant/harness/blob/main/clients/tui/src/transcript.rs) for a reference state machine and the [HTTP/SSE integration tests](https://github.com/parlant/harness/blob/main/test/h/http_sse_test.exs) for wire examples.
