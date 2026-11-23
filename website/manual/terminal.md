---
layout: doc
title: 'Terminal client'
description: 'Attach to a session with hi, steer or queue prompts, attach files, and customize your terminal status bar.'
lang: en
permalink: /docs/terminal/
---
`hi` is the Rust terminal client for your local H daemon. Launch `hi` from the project checkout you want the agent to work in. Inside a session, run `/help` to list slash commands or `/hotkeys` to inspect active keybindings.

* Contents
{:toc}

## Choose a target and display

| Invocation | Use it to |
|---|---|
| `hi` | Start a new session in the current directory using the fullscreen TUI |
| `hi -c` or `hi -r` | Continue the most recent session or pick from existing sessions in the current workspace |
| `hi -s SESSION_ID --conversation 1` | Attach directly to a specific session ID and conversation branch |
| `hi --tui-mode regular` | Run with native terminal scrollback and mouse text selection |
| `hi -p 'Summarize the README'` | Submit a prompt, stream the assistant reply to standard output, and exit while saving the turn in H |

## Send now, steer or queue

Press `Enter` to start a turn when the conversation is idle, or to deliver steering input while a turn is running. Press `Alt-Enter` (or run `/follow-up Review the tests next`) to queue a follow-up prompt that waits until the current turn finishes. Press `Ctrl-J` to insert a literal newline in terminals that do not report `Shift-Enter`. Run `/dequeue` to pull a queued follow-up back into the composer before the daemon consumes it. Run `/quit` to close the terminal view while work continues, or `/abort` to stop the active generation.

Use `/tools` to expand or collapse tool output blocks. Run `/earlier` to load older transcript pages, `/latest` to jump back to the live tail, and `/search` to filter currently loaded entries. When you want to explore an alternative approach from an earlier turn, run `/branch` or `/fork` to create a new conversation branch.

## Supply a path, file contents or shell output

- Press `Tab` to complete a workspace-relative file path as plain text in the composer. Type `@` or run `/file` to embed file contents from the session's execution environment. Run `/attach` to attach a file from the local machine running `hi`. Review selected files for secrets before submitting the turn.
- While the conversation is idle, prefix a command with `!` (for example, `!git status --short`) to execute it on the daemon in the session workspace and record the output in model context. Prefix with `!!` (`!!git status --short`) to record the command and output in the transcript for your own reference while excluding it from model prompts and `search_history`.

## Configure the terminal footer

Add custom lines to `<data_dir>/hi.json` to display local reminders below the default status bar:

```json
{"status_lines_append":["Use /cwd to check the session workspace."]}
```

Run `/reload` inside `hi` to apply changes to `hi.json` and `hi-keybindings.json` immediately. If a template or keybinding file contains a syntax error, `hi` reports the error and keeps your previous configuration active. Read the [status template reference](https://gitlab.com/parlant-co/harness/-/blob/main/docs/hi/status.md) and [CLI flags](https://gitlab.com/parlant-co/harness/-/blob/main/clients/tui/src/cli.rs) for all available fields.

To add a standalone `hi-<name>` command on your `PATH`, follow [extend the hi CLI](/docs/guides/extend-hi/). To write a custom client against the HTTP and SSE API, follow [build a client](/docs/guides/build-a-client/).
