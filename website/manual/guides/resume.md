---
layout: doc
title: 'Resume a turn in another client'
description: 'Switch from terminal to browser and back, including when a run has paused or your input receipt was lost.'
lang: en
permalink: /docs/guides/resume/
---
Suppose a review is running in `hi` and you want to inspect its changes in a browser. There is no session transfer: both clients attach to one server.

* Contents
{:toc}

## Start in one client, inspect in the other

1. In the checkout being reviewed, start `hi --title 'Parser review'`. Choose `/model` if needed. Ask a question, then use `/status` or the default footer to identify the session and conversation.
2. Open the same daemon's web inbox. Search for the title or filter by working directory, open the session and select the same branch. Replies and tool activity appear here even if they started in the terminal.
3. In `hi`, use `/quit`. Don't use `/abort` to close a client. Closing the browser tab also leaves work alone.
4. To return, run `hi -r` in the workspace, or `hi -s SESSION_ID --conversation CID` with the IDs from the footer. A different scroll position is expected; it isn't a different run.

## If the reply stopped

Check activity before resubmitting. **Retrying** means the daemon already scheduled a provider retry; no second prompt is needed. After the retry budget is exhausted, read the provider explanation. Waiting won't raise a spending cap. Resolve the credential or quota problem first, then use `/continue` for an unanswered turn. If a manual `/compact` failed, retry `/compact`, not `/continue`; the previous context remains intact.

An interrupted shell or file operation is different: H won't blindly run it again. Inspect the working tree and any partial result before deciding on the next action. See [recovery](/docs/architecture/#storage-and-recovery).

## If only the acknowledgement was lost

If `hi` reports an ambiguous **submission**, `/retry` uses its pending request identity. Typing the same text as a new prompt instead may create another turn. This is command deduplication, not a guarantee that an arbitrary external effect happened once. The [protocol](/docs/protocol/) spells out the receipt and replay rules.
