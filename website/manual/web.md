---
layout: doc
title: 'Web client'
description: 'Navigate the Phoenix inbox, open a workspace and attach evidence to a conversation.'
lang: en
permalink: /docs/web/
---
The web app calls H in the same VM. Its inbox, workspace browser and conversation views operate on the same store as `hi`; you do not export a chat to switch clients.

* Contents
{:toc}

## From inbox to conversation

For a walkthrough without a running server, try the [illustrated web demo](/demo/hiweb/). On your own daemon, sign in using the owner token for this server's store. In **Workspaces**, browse to a directory and choose **Start New Session**. In **Inbox**, use the working-directory, tag or text filter to return to an existing session. A directory filter matches one environment and directory; tag matches are exact. The URL preserves filters as you move between a session and the inbox. Use **Show subsessions** to inspect delegated work beneath the root session.

## Follow a live turn

A session view keeps the composer in place while replies stream. Scroll back or use **Load earlier** to read without chasing new output. **Latest** returns to the live end. Groups of tool and system entries appear as activity between messages; a group is a display choice, not a deleted tool result. Browser pane widths and file selections are local to the view. Selecting a branch does not change what another client is looking at.

## Send a screenshot or text attachment

Choose **Attach file** next to **Send**. Select a PNG, JPEG or WebP up to 2 MiB, or a UTF-8 file up to 64 KiB. Review the preview, remove private information and add a note. **Remove** discards an unsent selection. **Send** adds the blocks to the conversation and can start a model run. Use a model that accepts images. This does not write a file into the workspace; an unsent attachment is lost on reload or conversation switch.

## Work with files rather than paste a diff

Choose **Review files** for the workspace or current conversation. Browse a working file or pinned commit, then save a revision-anchored comment. [Review a change](/docs/guides/file-review/) walks through a deleted line, a working-tree edit and the difference between saving a note and starting a run. The development-only inspector is a separate feedback workflow; see the [web development reference](https://gitlab.com/parlant-co/harness/-/blob/main/clients/web/README.md).

For a separate client process, follow [build a client](/docs/guides/build-a-client/); it uses the local JSON/SSE API rather than the in-VM backend.
