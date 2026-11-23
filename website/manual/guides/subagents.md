---
layout: doc
title: 'Delegate to a subagent'
description: 'Ask a child session for a bounded review, let parallel edits use separate worktrees, and find the answer again.'
lang: en
permalink: /docs/guides/subagents/
---
Use a fork to try a different continuation of existing history. Use a subagent when a separate session should answer a bounded question and report back. The child starts with a fresh conversation, not the parent's entire transcript.

* Contents
{:toc}

## Review without another writer

In a coding session, ask the agent to use the `subagent` tool to review a specific file and return its findings **read-only**. Supply the paths, expected behavior and desired answer in the prompt; don't rely on an earlier message in the parent being visible. Delegation can invoke a paid provider even in read-only mode. For example, these are tool arguments, not a shell command:

```json
{"mode":"wait","read_only":true,"title":"Parser review","prompt":"Read src/parser.rs. List error cases that lack tests. Cite line numbers; do not edit files."}
```

The new child uses the parent's workspace by default. `read_only: true` on spawn limits the child's tools to `read` and `search_history`. Waiting parks the parent's task in its coordinator; it does not occupy a shell worker polling the child. H records the launch entry, so the answer can be traced to the right step even if the parent branches later.

## Run parallel edits in separate worktrees

Prepare the directories **before** spawning. For example, in an existing Git checkout with a commit and a free branch and directory name, `git worktree add -b parser-tests ../parser-tests HEAD` creates another checkout. Use its existing absolute root as `cwd` on a new child. Give each writer its own directory, file ownership and expected result. A tool-call `cwd` override on the parent does not change the parent's session binding or the next call's default.

Use `mode: "start"` to launch asynchronously; retain the returned child session and request IDs. With `mode: "await"` pass `session_id` and optionally that `request_id` to join. Follow up using `wait` on the existing direct child with a new prompt (no `cwd`); use `steer` for input to a busy child or `abort` to cancel it. Review the child's diff or commit in its own worktree before merging. H does not create, merge or clean up worktrees for you.

## Find a child's transcript

Open `hi inbox --subsessions` or use **Show subsessions** in the web inbox. Children nest beneath the root session even if they worked in a different directory. Inside a child, `/parent` jumps to the parent. Default root-first attention avoids surfacing each settled child as another human task.

[Subagent tool schema](https://gitlab.com/parlant-co/harness/-/blob/main/lib/h/tools/subagent.ex) · [Settlement and recovery](https://gitlab.com/parlant-co/harness/-/blob/main/docs/architecture/subagents.md)
