---
layout: doc
title: 'Sessions and workspaces'
description: 'Branch a conversation, find an earlier run, and move work to a different directory without rewriting its history.'
lang: en
permalink: /docs/sessions/
---
A session has a workspace (an environment and starting directory) and one or more conversations. Each client can browse an older page or another branch while the daemon continues running work.

* Contents
{:toc}

## Try an alternative without losing the original

In `hi`, use `/branch` and choose the entry **after which** history should diverge. For instance, branch after a code review, then ask for a minimal fix on one branch and a redesign on the other. The new conversation sees the prefix through that entry and inherits agent settings from that point. It doesn't copy running tools, queued messages or usage counters. `/tree` switches between conversations. Editing a historical prompt with `/fork` instead starts from its **predecessor**, so the original prompt isn't in context twice. Editing the very first prompt offers a new session.

A branch is not a Git checkout. Both conversations still operate on the same files. If one already wrote a file, branching before the write will not undo it. For a fork walkthrough without starting a server, try the [illustrated terminal demo](/demo/hi/).

## Move a conversation to another directory

Use `/cwd` to inspect the original binding. If a checkout was deleted, the transcript can still be read, but a new model/tool run cannot start there. Prepare an existing directory, then use `/cwd /absolute/path/to/project` to fork the visible history into a **new session** there. It does not move the old session or copy the old working tree.

## Keep the inbox useful

`hi inbox` and the web inbox group summaries by workspace without waking every session. Running, waiting for retry, failed and idle are not the same state: a retry already has work scheduled. `needs_attention` is a separate triage flag; `/attention off` dismisses the flag, not the work. In the terminal inbox, `Tab` cycles attention rows, `Space` toggles attention, `Enter` opens a session and `a` switches between Inbox and All.

`/abort` interrupts the current conversation; `/stop` targets **all** work in the session. `/archive` unloads an idle session rather than deleting its history. `/archive force` also stops its work. Read an archive from All; a native session can resume, whereas an [imported archive](/docs/guides/import/) stays read-only.

## When a writer is waiting

Mutating coding tools, including `bash`, take a lease for the **effective** workspace. Reads can proceed. Open `/workspace` to see the holder. Dismissing the picker leaves the run queued. **Cancel wait** cancels the waiting run, not the holder. **Stop holder and acquire** requests cancellation of the identified holder; it does not steal a lock from a live writer. Use [separate worktrees](/docs/guides/subagents/) when work really should run in parallel.

[Session and workspace semantics](https://gitlab.com/parlant-co/harness/-/blob/main/docs/protocol.md)
