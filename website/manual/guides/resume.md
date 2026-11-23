---
layout: doc
title: 'Resume a turn in another client'
description: 'Start a turn in hi, follow the live stream in hiweb, and handle paused retries or dropped submission receipts.'
lang: en
permalink: /docs/guides/resume/
---
Because `hi` and `hiweb` attach to the same local H daemon, you can start a code review in your terminal, close the terminal window, and watch the turn finish in your browser.

* Contents
{:toc}

## Start in one client, inspect in the other

1. In your project checkout, launch `hi --title 'Parser review'`. Select a model with `/model` if needed, submit a prompt, and note the session ID and conversation ID shown in `/status` or the terminal footer.
2. Open the daemon's web inbox (`http://127.0.0.1:4200/inbox` by default). Filter by working directory or search for `Parser review`, open the session, and select the active conversation branch. Replies and tool activity stream live in the browser.
3. Run `/quit` in `hi` to close the terminal client while the daemon continues executing the turn. You can also close the browser tab at any time without interrupting the run.
4. To reattach from the terminal later, run `hi -r` in the project directory and pick the session, or attach directly by ID:

```sh
hi -s SESSION_ID --conversation CID
```

## Resume a paused or interrupted turn

Check the session status in the inbox or footer before sending another prompt:

- **Retrying**: H hit a retryable provider error and has already armed a backoff timer. Wait for the scheduled retry to fire or run `/abort` if you want to cancel it.
- **Failed**: the retry budget ran out or a credential / quota error stopped the turn. Fix the API key, Codex login, or account quota first, then run `/continue` to retry the unanswered turn. (If a manual `/compact` command failed, rerun `/compact` instead.)
- **Interrupted tool call**: if an unexpected daemon crash stopped a `write`, `edit`, or `bash` tool call mid-flight, H records an interrupted result with any captured partial output so it never reruns an ambiguous shell command automatically. Check `git status` and your working files first, then tell the agent how to proceed. See [storage and recovery](/docs/architecture/#storage-and-recovery).

## Retry a dropped submission receipt

If your client connection drops while you submit a prompt and `hi` reports an ambiguous submission, run `/retry`. `/retry` resends the pending command with its original `request_id` so the daemon deduplicates it if the first request had already arrived. Read [submit once, even after a timeout](/docs/protocol/#submit-once-even-after-a-timeout) for the wire-level deduplication contract.
