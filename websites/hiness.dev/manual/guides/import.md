---
layout: doc
title: 'Import pi transcripts'
description: 'Import existing pi session logs into H as browsable read-only archives and rerun the importer incrementally.'
lang: en
permalink: /docs/guides/import/
---
Run `hi import --harness pi` to copy your existing `pi` conversation transcripts into H as read-only archives while leaving the source files in `~/.pi` untouched. Because imported transcripts contain your past prompts, attachments, and tool outputs, import them only into a data directory owned by your account.

* Contents
{:toc}

## Choose the source and destination

Install the [signed release bundle](/docs/setup/) so both `hi` and `hi-import` are on your `PATH`. Start your target H daemon, then run one of the import commands below:

```sh
hi import --harness pi
hi import --harness pi --directory /absolute/path/to/exported/sessions
```

The first command recursively scans `~/.pi/agent/sessions`. The second imports from a specific directory of exported `pi` session logs. Set `H_DATA_DIR` or pass `--data-dir` when you want to import into a specific daemon store. `hi-import` parses each log and uploads the structured archive over the daemon's authenticated Unix socket `<data_dir>/api.sock`.

## Find and inspect the result

Switch to the **All** view in `hi inbox` or `hiweb` to browse imported archives. You can open any imported session and switch across its retained conversation branches even if the original project checkout no longer exists on disk. Imported archives stay read-only (`hi -c` skips them so it always resumes an active native session), and any inline attachments embedded in the `pi` transcript remain visible inside the archive.

## Repeat after more turns

Rerun `hi import --harness pi` whenever you finish new work in `pi`. H tracks each archive by its upstream `pi` session ID and skips files whose size and modification timestamp have not changed. When an upstream log has grown, H replaces the archived snapshot in place under the same H session ID. If a malformed log file fails to parse, fix or remove that file and rerun the command.

[Archive format and revision rules](https://github.com/parlant/harness/blob/main/docs/hi/import.md)
