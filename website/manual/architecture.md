---
layout: doc
title: 'Architecture'
description: 'How a command becomes a committed transition, a supervised effect and a view in two independent clients.'
lang: en
permalink: /docs/architecture/
figure: lifetimes
---
When a terminal disconnects, a worker exits or someone opens a branch, different parts of H change. The core is the `:harness` Mix application; Phoenix and the Rust terminal client depend on its session model, not the other way around.

* Contents
{:toc}

## Four structures, four questions

| Question | Owner | Consequence |
|---|---|---|
| Which entries preceded this one? | Immutable session, conversation and entry records | Forks share the visible prefix through an entry, not live work. A spawned child instead has a fresh root conversation with a launch-step anchor. |
| Who owns the work? | Task and submission records | A generation may own tool calls. Browsing another conversation does not transfer them. |
| What happens when a process dies? | OTP instance and per-session supervisors | The coordinator and its task supervisor restart together; repeated failures can quarantine one session. This is not persistence. |
| What am I looking at? | Client cursor and paged transcript | Branch choice, page, scroll and unsent drafts aren't shared daemon state. |

## Trace one turn

1. `H.Daemon` validates the command. `H.Session.Server`, the single writer for that session, stages entries, documents, tasks and submissions. Request identity plus a fingerprint distinguishes a retry from a conflicting command.
2. The store commits intent and policy **before** any provider or tool call. Workers execute outside the commit. The coordinator checks incarnation, task and attempt before accepting an outcome; a late message cannot settle a different attempt.
3. `H.Context` projects visible entries and tools for the provider. This can synthesize an interrupted result for an incomplete tool pair on a fork without editing history. The provider resolves credentials at dispatch.
4. The client sees committed updates and may see earlier ephemeral progress. Only the former advance its durable cursor. `hi` uses [HTTP and SSE](/docs/protocol/); Phoenix's backend calls the daemon in-VM.

## Storage and recovery

One instance holds the store lock. `H.Catalog` lists workspace summaries without waking every coordinator. `H.Storage.File` keeps per-session CRC32-framed commits and rename-based snapshots; it handles a torn final frame. The in-memory backend does not survive VM exit.

On startup, H reconciles stored checkpoints. Planned shutdowns (`hi daemon stop`, `restart`, `SIGTERM`) cooperatively drain open tool calls and provider responses to a turn boundary so active sessions resume seamlessly on next boot. After an unexpected crash, safe interrupted tools such as `read` can run again, while unsafe `write`, `edit` and `bash` get an interrupted outcome with any persisted partial output, **not another execution**. The filesystem may already have changed. Check the actual files before asking for another edit. A queued workspace wait is different: intent hasn't entered execution and can requeue for its recorded directory.

## Retries belong to the coordinator

For retryable provider failures, `H.Session.Server.Generation` commits a sleeping task and its deadline **before** arming a timer. Transport retries are disabled in ReqLLM. While waiting, the catalog reports `retrying`: active work, not a demand for operator attention. Abort cancels the task; a late timer cannot restart it. Dispatch limits and no-resume policies still apply on managed and named provider routes.

## Embed the core in an OTP application

Add `:harness` as a Mix dependency and configure `:harness, :data_dir` to start its supervised daemon instance inside your application’s VM. Give that instance its own data directory: don’t start a standalone daemon against the same store. The embedded instance doesn’t need HTTP or a Unix socket for in-VM calls. See [the OTP entry point](https://gitlab.com/parlant-co/harness/-/blob/main/lib/h/application.ex) and [the Phoenix backend](https://gitlab.com/parlant-co/harness/-/blob/main/clients/web/lib/h_web/backend/in_vm.ex) for a working example.

Start with the built-in file store and host environment. For application-specific policy, [author a harness profile](/docs/extensions/#author-a-harness-profile); for a different file or command execution boundary, use the [execution environment contract](/docs/extensions/#choose-a-contract). Choose a dedicated workspace and grant it only the permissions it needs: the default host environment does not isolate tools from the embedding application’s OS identity.

## Boundaries that aren't sandboxes

A workspace lease coordinates writers for an environment and canonical directory. The host execution environment still has the daemon user's filesystem and shell access. The remote execution adapter exercises fencing and lease expiry **inside the VM**; it is not an authenticated remote service. For the difference between delegation and a fork, see [subagents](/docs/guides/subagents/).

[Architecture notes](https://gitlab.com/parlant-co/harness/-/blob/main/docs/architecture.md) · [VM restart tests](https://gitlab.com/parlant-co/harness/-/blob/main/test/h/vm_restart_test.exs) · [Tool crash recovery tests](https://gitlab.com/parlant-co/harness/-/blob/main/test/h/tool_crash_recovery_test.exs)
