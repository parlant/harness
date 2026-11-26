---
layout: doc
title: 'EditorHost'
description: 'Pair a live editor process with a short-lived workspace grant and expose bounded unsaved buffer summaries through editor_buffer_summary.'
lang: en
permalink: /extensions/editor-host/
---
EditorHost (`extensions/editor_host`) is an optional startup package (`H.Extension` API 1) that registers the `editor_coding` harness profile, the `editor_buffer_summary` read-only tool, and a supervised local broker (`Extensions.EditorHost.Broker`). Pair an editor process for a specific workspace so an agent turn can inspect an unsaved buffer with a strict revision check while keeping viewer SSE connections separate from tool execution.

* Contents
{:toc}

## Locate or build the artifact

Native release bundles include a precompiled `extensions/editor_host` artifact (disabled by default). You can also build it from a matching H source checkout:

```sh
cd extensions/editor_host
mix deps.get
mix check
mix test
mix extension.build
```

`mix extension.build` writes `extension.json` and compiled BEAM modules under `dist/editor_host/ebin/`.

## Enable the extension at startup

Add the artifact directory to `<data_dir>/extensions.json` with optional broker timeouts and listener settings:

```json
{
  "version": 1,
  "extensions": [
    {
      "path": "/absolute/path/to/bundle/extensions/editor_host",
      "settings": {
        "grant_ttl_ms": 60000,
        "invocation_timeout_ms": 10000,
        "max_summary_bytes": 16384
      }
    }
  ]
}
```

Validate startup configuration with `hi daemon start --check-config`, then restart the daemon cooperatively (`hi daemon restart` or `hi daemon restart-service`). Start a session under the `editor_coding` profile with `hi --harness editor_coding` or select `editor_coding` when creating a session in `hiweb`.

## Pair one live host generation per workspace

1. Issue a short-lived, single-claim pairing grant for the target workspace directory (`Extensions.EditorHost.issue_grant/2` or the optional private broker socket). Grants expire after `grant_ttl_ms` and remain separate from the daemon's owner token.
2. Claim the grant from the live editor host for that exact canonical workspace directory and the `editor_buffer_summary` capability.
3. The broker increments a monotonic `host_generation` counter, supersedes any earlier host connection for that workspace, and monitors the live host process or stream. When the editor disconnects, the broker revokes routing immediately and subsequent calls return `tool_unavailable`.

## Read buffers with an explicit revision check

When a turn invokes `editor_buffer_summary` with `path`, `expected_revision`, and optional `max_lines`, the broker dispatches a single one-use `invocation_id` to the active host generation, even when both `hi` and `hiweb` are attached to the conversation. If the editor's current buffer revision differs from `expected_revision`, the tool returns `revision_mismatch` so changing buffers stay explicit across retries.

Inspect the [package README](https://github.com/parlant/harness/blob/main/extensions/editor_host/README.md) and [broker implementation](https://github.com/parlant/harness/blob/main/extensions/editor_host/lib/editor_host/broker.ex) for pairing endpoints and test fixtures.
