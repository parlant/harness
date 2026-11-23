---
layout: doc
title: 'Review a change in the browser'
description: 'Pin a comment to the text you read, review a deleted line, or edit a working file under a revision check.'
lang: en
permalink: /docs/guides/file-review/
---
Use **Review files** when you want a comment to name an exact path, revision and excerpt. Reading a diff or saving a note on its own doesn't send a request to a model.

* Contents
{:toc}

## Choose where the comment belongs

From a session, choose **Review files** to keep comments in that conversation (including a fork). From a workspace, **Review files** opens a dedicated review session: H reuses its latest empty review session, not a session with an existing exchange. From the inbox, **Files** uses the row's session.

## Comment on a line removed by a commit

1. Choose **History**. Select a local commit or jump to its hash. **Changes** compares the selected commit with its first parent; no checkout, fetch or working-tree write occurs.
2. Pick the changed file. In **Diff**, expand a folded section for more context. Use **Parent file** to select the deleted text, or **Commit file** for the replacement.
3. Select the lines, choose **Use selected text**, and write the concern or question. **Save comment** records the verified excerpt and commit hash without inference. **Ask agent** sends input to the session and can start or queue a paid, tool-using turn. A saved note is history and may be in context later.
4. Return to the session to see the comment. The selection highlight was local, not a persistent inline thread.

## Make an edit without clobbering another writer

Switch back to **Working tree**. Here **HEAD** and **Diff** compare with the last commit, **not the index**. Edit a text file and save before leaving the view. Save checks the source revision and acquires the workspace writer lease; it doesn't stage or commit. If another writer changed the file, preserve your proposed text separately, discard the stale draft to reload, and reconcile it with the new contents. Never assume that a displayed historical snapshot is the current file.

Review supports UTF-8 text up to 512 KiB; browsing skips symlinks and `.git`. This is a limit on the review UI, not a sandbox around coding tools. [Web file review reference](https://gitlab.com/parlant-co/harness/-/blob/main/clients/web/README.md)
