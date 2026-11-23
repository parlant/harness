---
layout: doc
title: 'Sessions and workspaces'
description: 'Branch a conversation, switch between paths, move work to another directory, and manage workspace writer leases.'
lang: en
permalink: /docs/sessions/
---
Each H session binds to a workspace (an execution environment and starting directory) and holds a tree of conversations. Multiple clients can browse earlier turns or switch branches while the daemon runs active tasks.

* Contents
{:toc}

## Try an alternative without losing the original

In `hi`, run `/branch` and pick the entry **after which** you want history to diverge. For example, branch after a code review so you can ask for a minimal patch on one branch and a deeper refactor on the other. The new branch inherits the visible conversation prefix and agent settings from that entry, and starts with a clean task queue. Run `/tree` at any time to switch between branches. To edit and resubmit an earlier user prompt from its **predecessor** entry, run `/fork` instead (editing the first prompt in a session offers to create a new session).

Conversation branches live in the H session store while both branches continue to work against the same directory on disk. When you want a branch or subagent to edit an isolated copy of the files, create a separate Git worktree first. To explore a conversation fork in your browser, open the [illustrated terminal demo](/demo/hi/).

## Move a conversation to another directory

Run `/cwd` in `hi` to check the session's bound workspace path. If a checkout has moved or you want to continue the conversation in a new worktree, create the target directory on disk and run:

```text
/cwd /absolute/path/to/project
```

`/cwd <path>` forks the current visible conversation history into a **new session** bound to `/absolute/path/to/project`, leaving the original session and directory untouched.

## Keep the inbox useful

Run `hi inbox` or open the web inbox to see workspace summaries without waking dormant sessions. The catalog distinguishes four runtime states:

- `running`: a model turn or tool call is actively executing.
- `retrying`: a retryable provider error occurred and H has already armed a backoff timer for the next attempt.
- `failed`: a turn stopped on an error that requires your action.
- `idle`: no generation is active.

H tracks `needs_attention` as a separate triage flag so you can clear items you have reviewed (`/attention off`) without stopping active work. In `hi inbox`, press `Tab` to jump between attention rows, `Space` to toggle the attention flag, `Enter` to open the selected session, and `a` to switch between **Inbox** and **All**.

Inside a session, run `/abort` to stop the active generation on the current branch, or `/stop` to stop work across **all** branches in the session. Run `/archive` to unload an idle session from the active inbox while keeping its history in **All** (`/archive force` stops active work first). You can resume any native archived session by sending a new prompt, whereas [imported pi archives](/docs/guides/import/) remain read-only for reference.

## Manage workspace writer leases

Mutating coding tools (`write`, `edit`, and `bash`) acquire a workspace writer lease for their target directory while read-only tools proceed concurrently. When another session holds the lease for your directory, H queues your mutating tool call and shows the active holder. Run `/workspace` to inspect the lease and choose how to proceed:

- Dismiss the dialog to leave your turn queued until the current holder finishes.
- Choose **Cancel wait** to abort your waiting turn while letting the current holder continue.
- Choose **Stop holder and acquire** to request cancellation of the holding turn and take the lease once it exits.

When two sessions need to edit files in parallel, give each session its own [Git worktree](/docs/guides/subagents/#run-parallel-edits-in-separate-worktrees).

[Session and workspace protocol specification](https://gitlab.com/parlant-co/harness/-/blob/main/docs/protocol.md)
