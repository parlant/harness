---
layout: doc
title: 'Web client'
description: 'Triage workspaces in the Phoenix inbox, stream live turns, review diffs, and attach files in the browser.'
lang: en
permalink: /docs/web/
---
The `hiweb` Phoenix workbench calls H directly inside the same BEAM VM and shares the session store with `hi`. Open any session in your browser to follow live replies, inspect diffs, or attach files without exporting or migrating your chat.

* Contents
{:toc}

## From inbox to conversation

To preview the interface before installing H, open the [illustrated browser walkthrough](/demo/hiweb/). On your own machine, open `http://127.0.0.1:4200/inbox` and sign in with the owner token from `<data_dir>/auth.token`.

- Open **Workspaces**, browse to a project directory, and click **Start New Session** to launch a conversation there.
- Open **Inbox** and filter by working directory, exact tag, or search text to return to an active session. `hiweb` keeps your active filters in the URL as you move between the inbox and a session.
- Toggle **Show subsessions** to expand delegated subagent runs beneath their parent session.

## Follow a live turn

The session view pins the composer at the bottom while assistant replies and tool calls stream in above it. Scroll up or click **Load earlier** to read older turns at your own pace, then click **Latest** to jump back to the live stream. Consecutive tool and system entries collapse into compact activity groups that you can expand on demand. Pane widths, selected files, and your active conversation branch stay local to your browser tab, so another client attached to the same session keeps its own reading position.

## Send a screenshot or text attachment

Click **Attach file** next to **Send** and select a PNG, JPEG, or WebP image up to 2 MiB, or a UTF-8 text file up to 64 KiB. Check the preview for sensitive data, add your prompt in the composer, or click **Remove** to clear the selection. Make sure your selected model supports image inputs when attaching screenshots. Clicking **Send** commits the attachment and prompt to the conversation transcript and starts the turn.

## Review files and pin comments to diffs

Click **Review files** from a workspace or conversation to open the file browser and diff viewer. Inspect the current working tree or select a local Git commit to pin a comment to an exact file path, revision, and line range. Follow [review a change in the browser](/docs/guides/file-review/) to comment on a deleted line, edit a working-tree file with a revision check, or save a review note before starting a model turn. For contributor details on the Phoenix app, read the [web client README](https://github.com/parlant/harness/blob/main/clients/web/README.md).

To build an external client process against the HTTP and SSE API, follow [build a client](/docs/guides/build-a-client/).
