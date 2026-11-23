---
layout: doc
title: 'Build a client'
description: 'Prove a thin client with a read-only catalog list, a paged transcript and a reconnectable conversation stream.'
lang: en
permalink: /docs/guides/build-a-client/
---
Start with a reader, not another session engine. A useful first client can list sessions, show the latest committed messages in one conversation, disconnect and attach again without submitting a turn.

* Contents
{:toc}

## Implement one read-only view

1. On a disposable store, use the [authenticated catalog read](/docs/protocol/#read-without-creating-a-session) as a known-good request. Don't scan `sessions/` or pass a token via the session transcript. Render the returned catalog titles as plain text.
2. On selection, fetch `GET /api/v1/sessions/:sid` to choose a conversation. Subscribe to `GET /api/v1/sessions/:sid/conversations/:cid/events`. Keep the selected IDs, page and cursor in client state; don't persist navigation via a daemon command.
3. Follow the [stream rules](/docs/protocol/#resume-a-conversation-stream) for snapshots, commits and ephemeral output. Dispose of the old subscription on a branch change. A late frame from a previous branch must not redraw this one.

For a fixture, record a snapshot and two committed frames with a transient progress frame between them. Disconnect after the progress frame; check that the next subscription uses the preceding **committed** cursor. Exercise both ring replay and replacement snapshot. Confirm that closing the view never sends `abort`.

## Add a write without inference

Implement `submit` with `type: "write"` using the [note envelope](/docs/protocol/#submit-once-even-after-a-timeout). Hold the same request ID and normalized payload through a simulated dropped receipt. A retry should yield one note in the committed transcript, not a duplicated entry or a model request. Treat the receipt as an acknowledgement and render from the stream. Only then consider adding paid input or tools.

For a concrete reducer, read the [Rust transcript implementation](https://gitlab.com/parlant-co/harness/-/blob/main/clients/tui/src/transcript.rs). For API coverage, see the [SSE tests](https://gitlab.com/parlant-co/harness/-/blob/main/test/h/http_sse_test.exs). You don't need Phoenix, an extension package or access to H's storage backend to build a client.
