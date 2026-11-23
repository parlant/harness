---
layout: doc
title: 'Manage the daemon'
description: 'Install a per-user service, update a native release and reconnect without changing session identity.'
lang: en
permalink: /docs/daemon/
---
A release, a data directory and a workspace have different lifetimes. Replacing the executable does not move the conversation, its credentials or its working files.

* Contents
{:toc}

## Install for daily use

Install a signed release with the [shell installer](/install.sh) (`--service` registers a macOS LaunchAgent or Linux `systemd --user` unit) or with `mix h.setup --service` from the `h_setup` Mix archive; see [Set up H](/docs/setup/).

When developing H from a source checkout on macOS, run these from the repository root as the logged-in user:

```sh
mix h.local --service
hi daemon status
```

This builds, smoke-tests and installs a native bundle and registers (or cooperatively restarts) a per-user LaunchAgent. Put `~/.bin` on `PATH` (or pass `--bin-dir` with a directory already on `PATH`). The active install lives at `~/.local/opt/harness/current`, not in `~/.local/share/h`. Omit `--service` for an install without a registered service and use `hi daemon start` in a dedicated terminal. Set a custom store with `--data-dir` on install and use matching `H_DATA_DIR` in clients.

## Choose the right restart

| Situation | Action |
|---|---|
| New binary or startup configuration for a foreground standalone daemon | `hi daemon restart` (cooperatively drains open work; `--idle-only` refuses if busy) |
| Restart the registered macOS service | `hi daemon restart-service` (cooperatively drains open work first) |
| Stop work cleanly (or via OS `SIGTERM`) | `hi daemon stop` drains open tools and responses without starting new turns; `hi daemon start-service` starts a stopped registered service |
| New `hi` binary only | `/restart-ui /absolute/path/to/hi` in the session; `~` is not expanded |
| Updated local status templates or keybindings | `/reload` in `hi`; no process restart |

During a cooperative drain (`hi daemon stop`, `restart`, `restart-service`, `mix h.install`, or `SIGTERM`), H closes command admission immediately, runs all in-flight tools and open provider streams to completion, commits their outcomes, and leaves subsequent tool calls, follow-up turns, and retry timers parked on disk. When the new daemon starts against the same store, it automatically resumes all active sessions from those turn boundaries. Pass `--idle-only` when you want shutdown refused (`hi inbox` shows which sessions still have work). Do **not** launch a foreground restart from an agent's shell tool: run it from your terminal or service manager. Reexec preserves the client target, not drafts; finish submitting or discard unsent changes first.

## Upgrade or switch back

For signed binary releases, rerun the [shell installer](/install.sh) or `mix h.setup` (with `--service` if using a background service). From a source checkout run `mix h.local` to build, smoke-test and install an update; if `dist/harness` is already built and tested, `mix h.install` activates it without rebuilding. Service activation preflights startup config, cooperatively drains the running service, waits for confirmed process exit, and switches `current` atomically. If readiness fails, inspect `<data_dir>/h-daemon.log`; there is no automatic rollback. Use `mix h.install --activate RELEASE_ID` with the printed previous ID only if that release can read the current store and credential formats.

## Listener settings

`H_WEB_PORT` changes the bundled web port; `H_WEB=0` disables the web listener. The default API listens on loopback port 4100 and the local Unix socket `api.sock`. `network.json` in the data directory selects explicit bind addresses at startup. The listeners speak plain HTTP; keep the default unless operating on a trusted encrypted network. See [security](/docs/security/) and the [management reference](https://gitlab.com/parlant-co/harness/-/blob/main/docs/hi/management.md).
