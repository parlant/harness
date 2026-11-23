# Import pi session archives

Build and install with `mix h.local`. With the H daemon running:

```sh
hi import --harness pi
hi import --harness pi --directory /path/to/pi/sessions
```

The first form scans `~/.pi/agent/sessions` recursively. Use `--data-dir` or
`H_DATA_DIR` to select a different local daemon. The importer uses its owner
token and Unix socket, never writes directly to the daemon store, and never
modifies pi files. The bundle installs the standalone `hi-import` binary
alongside `hi`. `hi <name>` looks up executable `hi-<name>` commands on absolute
`PATH` entries after checking built-in commands. Use `hi -- <prompt>` for a
literal prompt that starts with an extension name.

H uses the pi session header ID, not the filename, as the source identity.
Older headerless exports use their first entry's ID and timestamp; logs with
no recorded workspace appear under `/`.
On repeat runs it skips unchanged files (same modification time and size),
imports missing sessions, and replaces the archived snapshot for newer versions
without creating a second H session. Older revisions are ignored. Deleting a
pi file does not remove its archive. Each session is published only after a
complete upload. Failures are reported per file; rerun to catch up after fixing
malformed files or after pi finishes writing. If you intentionally edit or
restore a file while preserving its modification time, give it a newer mtime.

Find archives in **All** in the web or terminal inbox, not in the attention
queue. Open any retained branch, even if its original directory is gone.
Archives are read-only: no tools or model calls run and `hi -c` skips them.
Reopen an archive to load a newly imported version. Attachments contained in
pi logs are imported with the transcripts; paths pointing to separate files
are not followed. Very large individual records are retained as numbered JSON
fragments rather than overflowing a transcript page. Only import logs into a
store whose owner you trust: transcripts can contain private prompts, tool
output, and attachments. No pi account or credential stores are read.
Opaque extension state and deferred provider handles are not imported.

## Continue a pi conversation in H

Fork a branch into an existing workspace to continue it as a native H session.
The archive and fork retain the original history. When building a provider
request, H gives oversized or nonportable historical tool IDs bounded aliases
and uses the same alias for the call and its result. Pi bookkeeping, prior
system instructions, and failed assistant turns stay visible in history but
are not sent as live context. Pi custom messages and branch summaries are
included as historical user context, not as system instructions. Missing
results get an interruption marker. Unpaired outputs and numbered fragments
of oversized records stay in the transcript. None of this reruns historical
tools or restores old provider state.

This also applies to pi forks created before the compatibility fix. After
upgrading the daemon, use **Continue** or `/continue` to resume a paused turn;
there is no need to re-import the session. Model context limits and attachment
support still depend on the selected model.
