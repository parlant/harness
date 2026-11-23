---
layout: doc
title: 'Practical guides'
description: 'Step-by-step guides for switching clients mid-run, reviewing diffs, delegating to subagents, importing pi archives, and extending H.'
lang: en
permalink: /docs/guides/
---
Each guide below walks through a complete task against your local H daemon. Confirm your server is running with `hi daemon status`, or complete [Set up H](/docs/setup/) first.

* Contents
{:toc}

## Daily workflows

- [Resume a turn in another client](/docs/guides/resume/): start a prompt in `hi`, follow the active stream in `hiweb`, and reattach from the terminal.
- [Review a change in the browser](/docs/guides/file-review/): pin a comment to a specific commit and line range, or edit a working file with a revision check.
- [Delegate to a subagent](/docs/guides/subagents/): spawn a focused child session for read-only review or parallel edits in a separate Git worktree.
- [Import pi transcripts](/docs/guides/import/): bring existing `pi` session logs into H as browsable read-only archives.

## Configuration recipes

- [Set up a provider](/docs/providers/): save write-only API keys, sign in with Codex device login, or register an OpenAI-compatible endpoint.
- [Configure the terminal footer](/docs/terminal/#configure-the-terminal-footer): append custom status lines and reload keybindings in `hi`.
- [Install and upgrade the daemon](/docs/daemon/): register a per-user background service and drain active turns during upgrades.
- [Build a local extension](/docs/extensions/): compile an API 1 startup package and verify it against a disposable data directory.

## Development recipes

- [Build a client](/docs/guides/build-a-client/): connect to `/api/v1`, stream conversation events over SSE, and verify idempotent command retries.
- [Author a harness profile](/docs/extensions/#author-a-harness-profile): define custom agent instructions and tool sets for new sessions.
- [Hooking into core](/docs/extensions/#hooking-into-core): choose between SSE streams, `H.ExecutionEnv`, and startup contracts.
- [Extend the hi CLI](/docs/guides/extend-hi/): add a standalone `hi-<name>` subcommand on your `PATH`.
