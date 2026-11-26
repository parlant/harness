---
layout: doc
title: 'Architecture'
description: 'How H turns a client command into a committed disk transition, a supervised effect, and synchronized client views.'
lang: en
permalink: /docs/architecture/
figure: lifetimes
---
The `:harness` OTP application owns session state, storage, and tool execution. Both `hiweb` (Phoenix LiveView) and `hi` (Rust TUI) attach as clients to `:harness`, keeping history ancestry, active task ownership, OTP supervision, and client navigation in separate structures.

* Contents
{:toc}

## Four structures, four questions

| Question | Owner | Consequence |
|---|---|---|
| Which entries preceded this one? | Immutable session, conversation, and entry records | Branches share the committed prefix through the split entry. A spawned subagent starts a fresh root conversation linked to its parent's launch entry. |
| Who owns the work? | Task and submission records | An active generation owns its tool calls. Switching branches in a client leaves running tasks attached to the conversation that launched them. |
| What happens when a process dies? | OTP instance and per-session supervisors | The session coordinator and its task supervisor restart together, and repeated crashes quarantine that session while durability comes from committed disk records. |
| What am I looking at? | Client cursor and paged transcript | Each client manages its own selected branch, page cursor, scroll position, and unsent draft locally. |

## Trace one turn

1. `H.Daemon` validates the incoming command. `H.Session.Server`, the single writer for that session, stages entries, documents, tasks, and submissions. Request identity and a payload fingerprint allow safe command retries while rejecting conflicting payloads under the same ID.
2. The store commits intent and replay policy to disk **before** dispatching any provider request or tool call. Workers execute outside the commit transaction. When a worker finishes, the coordinator verifies the incarnation, task ID, and attempt number before committing the outcome.
3. `H.Context` projects visible entries and installed tools for the model provider. When a branch splits across an incomplete tool call, `H.Context` synthesizes an interrupted result for the prompt context while keeping stored history immutable. The provider adapter resolves credentials at dispatch time.
4. Attached clients receive committed updates and ephemeral progress frames. Clients advance their durable reconnect cursor only on committed frames. `hi` connects over the [local HTTP and SSE API](/docs/protocol/), while `hiweb` calls `H.Daemon` directly inside the same BEAM VM.

## Storage and recovery

Each running daemon holds an exclusive lock on its data directory. `H.Catalog` serves workspace summaries without waking dormant session coordinators. `H.Storage.File` writes per-session CRC32-framed commits and atomic rename-based snapshots, truncating any torn final frame on recovery.

On startup, H reconciles stored session checkpoints. Planned shutdowns (`hi daemon stop`, `restart`, or `SIGTERM`) cooperatively drain active tool calls and open provider streams to a turn boundary so active sessions resume cleanly on the next boot. After an unexpected crash, H reruns repeatable read-only tools such as `read`, and records an interrupted outcome (with any captured partial output) for side-effecting tools such as `write`, `edit`, and `bash`. Because an interrupted shell command or file write may already have modified the working tree, inspect the files before running your next turn. Queued workspace lease waits that had not started executing re-enter the queue for their target directory.

## Retries belong to the coordinator

When a provider returns a retryable error, `H.Session.Server.Generation` commits a sleeping task record and its backoff deadline to disk **before** arming a timer, while transport-level retries remain disabled in ReqLLM (`max_retries: 0`). During backoff, the catalog reports the session as `retrying` so operators see that recovery is already scheduled. Sending `/abort` cancels the sleeping task immediately.

## Embed the core in an OTP application

Add [`hiness` from Hex](https://hex.pm/packages/hiness) to an Elixir 1.20 / Erlang/OTP 29 project. Put this entry in your `mix.exs` dependencies and run `mix deps.get`:

```elixir
{:harness, "~> 0.4.0", hex: :hiness}
```

`hiness` is the package name. `:harness` is the OTP application and configuration key. Set `config :harness, data_dir: "/path/to/private/store"` in `config/runtime.exs` to start the supervised daemon without opening an HTTP port or API socket. Call `H.Daemon` in the same BEAM VM. Browse the [Elixir API reference on HexDocs](https://hiness.hexdocs.pm/), or inspect [the OTP application entry point](https://github.com/parlant/harness/blob/main/lib/h/application.ex) and [the Phoenix in-VM backend](https://github.com/parlant/harness/blob/main/clients/web/lib/h_web/backend/in_vm.ex).

Start with the built-in file store and host execution environment. To customize agent instructions and tools for your application, [author a harness profile](/docs/extensions/#author-a-harness-profile). To control how tools read files or execute commands, implement the [`H.ExecutionEnv` behaviour](/docs/extensions/#choose-a-contract). Assign the session a dedicated workspace directory, remembering that the default host environment executes with your BEAM process's OS user permissions.

## Boundaries that aren't sandboxes

A workspace writer lease serializes concurrent mutating tools from H against the same environment and canonical directory. Host tools execute with the daemon OS user's filesystem and shell permissions. `H.ExecutionEnv.Remote` plus `H.RemoteAgent.HTTP` and `h-daemon remote-agent` delegate workspace operations to a separate container or host over bearer-authenticated HTTP or Unix sockets with attempt fencing, lease heartbeats, and OS process-group cleanup. To compare history branching with child session delegation, read [delegate to a subagent](/docs/guides/subagents/).

[Architecture notes](https://github.com/parlant/harness/blob/main/docs/architecture.md) · [VM restart tests](https://github.com/parlant/harness/blob/main/test/h/vm_restart_test.exs) · [Tool crash recovery tests](https://github.com/parlant/harness/blob/main/test/h/tool_crash_recovery_test.exs)
