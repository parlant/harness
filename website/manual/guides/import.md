---
layout: doc
title: 'Import pi transcripts'
description: 'Bring pi logs into the All sessions view as read-only archives and safely repeat a partial import.'
lang: en
permalink: /docs/guides/import/
---
Import copies conversation history, not accounts, tools or a running agent. Use a store whose owner may see the prompts, attachments and tool output. The import does not modify pi files.

* Contents
{:toc}

## Choose the source and destination

Install the [native bundle](/docs/setup/) with its `hi` and `hi-import` binaries on `PATH`. An install of the Rust terminal client alone does not supply `hi-import`. `hi` finds executable `hi-<name>` commands in absolute `PATH` entries after checking built-ins; keep those directories trusted. With the target daemon running, choose **one** form:

```sh
hi import --harness pi
hi import --harness pi --directory /absolute/path/to/exported/sessions
```

The first scans `~/.pi/agent/sessions` recursively. The second selects a different source directory. Set `H_DATA_DIR` or pass `--data-dir` to choose a **destination daemon**, not a source. The importer uploads complete archives over the owner's Unix socket; don't copy log files directly into `sessions/`.

## Find and inspect the result

Open **All** in the web or terminal inbox, not the attention queue. You can read retained branches even if the original directory is gone. No tools or model requests run in an archive, and `hi -c` skips it. Embedded attachments travel with the transcript; paths to separate files aren't followed. Opaque provider handles and extension state aren't restored.

## Repeat after more turns

Import again after pi finishes writing. H tracks pi's session identity rather than the filename and skips unchanged size/mtime pairs. A newer revision replaces that archived snapshot, not the H session ID; older revisions are ignored. Reopen the archive to see it. After a per-file error fix the file and retry. Deleting the source doesn't remove the H archive.

[Archive format and revision rules](https://gitlab.com/parlant-co/harness/-/blob/main/docs/hi/import.md)
