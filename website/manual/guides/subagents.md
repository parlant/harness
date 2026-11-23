---
layout: doc
title: 'Delegate to a subagent'
description: 'Spawn a child session for a focused read-only review or run parallel edits across separate Git worktrees.'
lang: en
permalink: /docs/guides/subagents/
---
Use `/branch` or `/fork` when you want to explore an alternative continuation of your current conversation history. Spawn a subagent when you want a separate child session to investigate a focused question or work in its own Git worktree and return a summary to the parent turn.

* Contents
{:toc}

## Run a read-only review in a child session

Ask the parent agent to invoke the `subagent` tool with `read_only: true`. Because the child starts with a fresh conversation transcript, include the relevant file paths, question, and expected output format in the subagent prompt. Note that subagent turns make model requests to your configured provider. Here is the JSON payload the parent passes to the `subagent` tool:

```json
{"mode":"wait","read_only":true,"title":"Parser review","prompt":"Read src/parser.rs. List error cases that lack tests. Cite line numbers; do not edit files."}
```

By default, the child runs in the parent's workspace directory, and `read_only: true` restricts the child's tool set to `read` and `search_history`. With `mode: "wait"`, H parks the parent task in its session coordinator without holding a worker process open, then wakes the parent with the child's final answer as soon as the child completes. H links the child session to the parent entry that launched it, preserving the relationship even if you branch the parent conversation later.

## Run parallel edits in separate worktrees

When spawning multiple subagents that edit files or run shell commands in parallel, create a separate Git worktree for each child **before** launching them:

```sh
git worktree add -b parser-tests ../parser-tests HEAD
```

Pass the worktree's absolute path as `cwd` when spawning the child session, and assign each child clear file ownership and verification commands.

Use `mode: "start"` to launch several children asynchronously and record their returned `session_id` and `request_id` values. Join each child later with `mode: "await"`, passing its `session_id` (and optional `request_id`). You can send a follow-up turn to an existing direct child with `mode: "wait"` and `session_id`, deliver steering input to a running child with `mode: "steer"`, or stop a child with `mode: "abort"`. When the children finish, inspect and merge each worktree's commits using normal Git commands.

## Find a child's transcript

Run `hi inbox --subsessions` in the terminal or toggle **Show subsessions** in `hiweb` to view child sessions nested beneath their parent session. Inside a child session in `hi`, run `/parent` to jump straight to the parent conversation.

[Subagent tool implementation](https://gitlab.com/parlant-co/harness/-/blob/main/lib/h/tools/subagent.ex) · [Subagent settlement and recovery](https://gitlab.com/parlant-co/harness/-/blob/main/docs/architecture/subagents.md)
