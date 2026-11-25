---
layout: features
lang: en
permalink: /features/
kicker: Gallery of capabilities
title: Features
lead: "Your Hiness runs durable coding sessions in a local Elixir/OTP daemon, independent of any single terminal window or browser tab. Start a task in one client, inspect diffs in another, and keep every committed turn on disk."
description: "Run durable coding sessions in a local daemon, switch between terminal and browser clients, delegate to subagents, and extend or embed the Elixir/OTP core."
gallery:
  - artwork: margarita_khm
  - artwork: goya_charles_iv
    wide: true
  - artwork: henry_stuart_ngi
  - artwork: william_silent_rijks
---

* On this page
{:toc}

## Durable and resilient sessions

Close your terminal or browser tab while a turn is running. H continues executing active work and writes every committed entry to local files in your data directory. Planned daemon restarts drain open tool calls and provider streams to a turn boundary before exiting. After an unexpected crash, H reloads committed history, schedules backoff timers for retryable provider failures, and marks any interrupted `write`, `edit`, or `bash` call so you can check your working tree before running the next command.

[Inspect how H stores and recovers work](/docs/architecture/#storage-and-recovery).

## Responsive, synchronized clients

Attach `hi` in your terminal and `hiweb` in your browser to the same running daemon. Replies, tool calls, and status updates stream to both views as they happen, while each client keeps its own scroll position, page cursor, and selected branch. Start a prompt from the keyboard and review the resulting file changes in the browser while the turn continues.

[Switch clients during an active run](/docs/guides/resume/).

## Terminal, web, desktop and mobile

Run `hi` in fullscreen terminal mode, in regular scrollback mode, or as a one-shot command with `hi -p`. Open `hiweb` in a desktop or mobile browser to triage sessions across workspaces, read transcripts, and review diffs without installing a separate desktop or mobile app.

[Walk through the terminal demo](/demo/hi/) or [explore the browser workbench demo](/demo/hiweb/).

## Branch and resume conversations

Fork a conversation at an earlier entry to test a second approach while keeping your first path intact. The new branch shares the committed prefix up to the split point and records its own subsequent turns. Both branches operate on the same working directory on disk; prepare a separate Git worktree when two branches need isolated files.

[Compare two branches in the interactive demo](/demo/) or [learn how sessions and workspaces fit together](/docs/sessions/).

## Local or remote execution environments

Run file reads, edits, and shell commands in your local project directory today. H routes all tool calls through an execution environment contract that stays separate from client connections and the session store. A workspace writer lease serializes concurrent mutating tools from H against the same directory, while tools run with your OS user's permissions.

H also includes an in-VM remote execution adapter that tests lease fencing and expiry across a simulated boundary. Off-machine transport and a standalone remote agent service are planned on the roadmap and do not ship yet.

[Review the execution boundary](/docs/architecture/#boundaries-that-arent-sandboxes) or [check the remote transport roadmap](https://github.com/parlant/harness/blob/main/docs/roadmap.md#other-remaining-work-not-shipped).

## Review files and give feedback in context

Open **Review files** in `hiweb` to inspect the working tree or compare a local Git commit against its parent. Select lines from a current or deleted block, pin a comment directly to that revision and file path, or edit a working file with a revision check that prevents overwriting newer changes. You can also attach a PNG, JPEG, WebP, or UTF-8 text file directly in the composer.

[Review and comment on a change](/docs/guides/file-review/) or [attach a screenshot or text file](/docs/web/#send-a-screenshot-or-text-attachment).

## Delegate to subagents

Spawn a child session with the `subagent` tool to run a focused task such as a read-only code audit or a test pass in a separate Git worktree. The child starts with a clean conversation context and reports its final answer back to the parent step that launched it. The inbox groups child sessions under their parent so your main attention queue stays clear.

[Delegate a task to a subagent](/docs/guides/subagents/).

## Signal and wake sessions without polling

Wait on a child subagent without holding a worker process open. H parks the parent task in the session coordinator and wakes it automatically as soon as the child commits its final outcome.

External scripts and local automation can also submit queued follow-up turns through the authenticated local HTTP API while a session is busy. H holds the queued input until the current turn settles, then runs it in order.

[Coordinate parent and child sessions](/docs/guides/subagents/) or [submit commands through the local API](/docs/guides/build-a-client/).

## Choose your model provider

Save write-only API keys for OpenAI, Anthropic, Google Gemini, DeepSeek, or OpenRouter, sign in with a ChatGPT account via Codex device login, use Google Cloud Vertex AI, or register an OpenAI-compatible Chat Completions endpoint. Switch models per conversation with `/model` or the web header while keeping the same transcript and tool history. When you select a remote provider, H sends the conversation context required for each inference request to that service.

[Configure your model providers and credentials](/docs/providers/).

## Build a client or write an extension

Connect a custom UI or automation script to H's `/api/v1` JSON commands and Server-Sent Events stream. Package a custom harness profile or execution environment as a local startup extension, or place an executable `hi-<name>` script on your `PATH` to add a client-side subcommand.

[Build a custom client](/docs/guides/build-a-client/), [package a local startup extension](/docs/extensions/), or [add a subcommand to the hi CLI](/docs/guides/extend-hi/).

## Embed H in an Elixir/OTP application

Add [`hiness` from Hex](https://hex.pm/packages/hiness) and run the supervised `:harness` daemon directly inside your application's BEAM VM. You get H's file-backed session store, recovery coordinator, and default host execution environment in-process, using the same pattern that powers `hiweb`. Supply a custom harness profile to define your application's agent instructions and tools, or implement `H.ExecutionEnv` to control how tools access files and commands.

[Embed `:harness` in your OTP application](/docs/architecture/#embed-the-core-in-an-otp-application) or [browse the Elixir API on HexDocs](https://hiness.hexdocs.pm/).

## Lean core, few dependencies

Run H from a single native release bundle that includes the BEAM runtime, the `hi` terminal client, and the `hiweb` Phoenix workbench. The core `:harness` application relies on a small set of direct Elixir dependencies and writes CRC32-framed commits and atomic snapshots directly to local disk, so you can install and upgrade H without managing an external database server.

[Install H on your machine](/docs/setup/) or [trace a turn through the architecture](/docs/architecture/).

## Bring existing conversations along

Import your existing `pi` session transcripts into H as read-only archives with `hi import --harness pi`. Browse every imported branch in the terminal or web **All** view, and rerun the importer at any time to pick up newer turns from disk.

[Import a pi transcript archive](/docs/guides/import/).
