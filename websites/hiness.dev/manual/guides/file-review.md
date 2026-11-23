---
layout: doc
title: 'Review a change in the browser'
description: 'Pin a review comment to a specific commit and line range, inspect deleted lines, or edit a working file with a revision check.'
lang: en
permalink: /docs/guides/file-review/
---
Open **Review files** in `hiweb` to pin a review comment to an exact file path, Git revision, and line range, or to edit a file in the working tree. Browsing diffs and saving comments updates the local session store immediately without calling a model provider.

* Contents
{:toc}

## Choose where the comment belongs

- From an open session, click **Review files** to record your comments directly in that conversation branch.
- From **Workspaces**, click **Review files** to open a dedicated review session for that directory (H reuses your latest empty review session if one already exists).
- From **Inbox**, click **Files** on any session row to open file review inside that session.

## Comment on a line removed by a commit

1. Switch the review mode to **History** and select a local commit from the list (or enter its commit hash). **Changes** compares the selected commit against its first parent directly from the Git object store.
2. Select a modified file from the tree. In **Diff**, expand any folded context lines as needed. Click **Parent file** to select lines that the commit removed, or **Commit file** to select lines from the resulting version.
3. Highlight the target lines, click **Use selected text**, and type your comment. Click **Save comment** to commit the excerpt, file path, and commit hash to the conversation transcript as a note, or click **Ask agent** to submit the comment as a model prompt (which starts or queues an inference turn).
4. Click back to the conversation view to see your pinned comment in the transcript.

## Make an edit without clobbering another writer

Switch the review mode to **Working tree**, where **HEAD** and **Diff** compare working files against the latest Git commit. Open a text file, make your edit, and click **Save** before leaving the page. Saving verifies that the file on disk still matches the revision you loaded and acquires the workspace writer lease before writing.

If another process or agent turn modified the file while you were editing, `hiweb` blocks the save so you do not overwrite the newer file. Copy your draft text, reload the current file from disk, and apply your change against the updated contents.

The browser file review viewer reads UTF-8 text files up to 512 KiB and skips symlinks and `.git/`. See the [web client reference](https://github.com/parlant/harness/blob/main/clients/web/README.md) for implementation details.
