---
layout: doc
title: 'Practical guides'
description: 'Recipes for resuming work, reviewing diffs, importing transcripts and delegating to a child session.'
lang: en
permalink: /docs/guides/
---
The daily workflows below use an existing local daemon. If `hi daemon status` cannot find it, follow [setup](/docs/setup/) first. None of these workflows needs another server for the same store.

* Contents
{:toc}

## Daily workflows

- [Resume a turn in another client](/docs/guides/resume/): keep the session ID and the conversation ID, not the process ID.
- [Review a change](/docs/guides/file-review/): leave a comment on a pinned commit or save an edit without overwriting a changed file.
- [Delegate to a subagent](/docs/guides/subagents/): use a fresh child context for read-only review or an isolated worktree for parallel edits.
- [Import a pi archive](/docs/guides/import/): inspect old branches in H without changing the source logs.

## Configuration recipes

- [Set up a provider](/docs/providers/): save an API key for a background service, sign in to Codex, or register a compatible endpoint.
- [Adjust the terminal footer](/docs/terminal/#configure-the-terminal-footer): add a local reminder without changing the shared session.
- [Install and upgrade on macOS](/docs/daemon/): activate a versioned release only after the current daemon is idle.
- [Build a local extension](/docs/extensions/): start with a no-tools profile and a disposable store before installing trusted code in your own daemon.

## Development recipes

- [Build a client](/docs/guides/build-a-client/): start with a read-only transcript, then test a saved note and a lost receipt.
- [Author a harness](/docs/extensions/#author-a-harness-profile): choose the starting instructions and available tools without replacing the session runtime.
- [Hooking into core](/docs/extensions/#hooking-into-core): distinguish existing behaviour contracts from proposed observers.
- [Extend the hi CLI](/docs/guides/extend-hi/): add a standalone subcommand without putting code inside H.
