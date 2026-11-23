---
layout: doc
title: 'Terminal client'
description: 'Open or resume with hi, steer a run, attach a file and change your local footer.'
lang: en
permalink: /docs/terminal/
---
`hi` is a Rust client for an existing local daemon. Start it from the directory you want the session to work on, not necessarily the H checkout. `/help` lists commands and `/hotkeys` shows active bindings.

* Contents
{:toc}

## Choose a target and display

| Invocation | Use it for |
|---|---|
| `hi` | A session in the current workspace, fullscreen by default |
| `hi -c` or `hi -r` | Continue the latest session or pick one in this workspace |
| `hi -s SESSION_ID --conversation 1` | Attach directly to a known session and branch |
| `hi --tui-mode regular` | Native terminal scrollback and selection instead of alternate-screen capture |
| `hi -p 'Summarize the README'` | Submit a real prompt, stream assistant text to stdout and exit; the session lives in H |

## Send now, steer or queue

Enter starts a turn if idle or steers a busy run. Alt-Enter (or `/follow-up Review the tests next`) queues a separate follow-up if busy. Ctrl-J inserts a newline when the terminal doesn't distinguish Shift-Enter. `/dequeue` withdraws selected queued input at the daemon; another client may already have consumed it. `/quit` detaches; `/abort` is a separate, explicit cancellation.

`/tools` toggles tool details. `/earlier` pages back; `/latest` returns to the live end. `/search` searches loaded messages, not every file on disk. Use `/branch` or `/fork` to change history's direction, not to change your scroll position.

## Supply a path, file contents or shell output

- `Tab` completes a path token as **text** relative to the session workspace. `@` completion and `/file` use files in the session's environment. `/attach` instead uses a file on the **client**. Check the selection for private data before sending.
- With an idle conversation, `!git status --short` runs the command on the daemon in the session workspace and includes it in model context. `!!git status --short` keeps the command and result out of model context and `search_history`; it is **not** a secret-entry mode. Neither prefix is a shell running inside `hi`.

## Configure the terminal footer

Merge this field into `<data_dir>/hi.json` to keep the default footer and add a reminder below it:

```json
{"status_lines_append":["Use /cwd to check the session workspace."]}
```

Run `/reload`. Status templates and `hi-keybindings.json` reload together; a validation error leaves the previous settings active. The template cannot read files or call the daemon. This changes only the current client's display. See [status fields and template recipes](https://gitlab.com/parlant-co/harness/-/blob/main/docs/hi/status.md) and the [CLI arguments](https://gitlab.com/parlant-co/harness/-/blob/main/clients/tui/src/cli.rs).

For a separate executable, see [extend the hi CLI](/docs/guides/extend-hi/). To implement another interactive surface, see [build a client](/docs/guides/build-a-client/).
