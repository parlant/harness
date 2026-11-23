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

On macOS, after the manually started server is idle and stopped, run these from the checkout as the logged-in user:

```sh
mix h.local --service
hi daemon status
```

This builds, smoke-tests and installs a native bundle and registers a per-user LaunchAgent. Put `~/.bin` on `PATH` (or pass `--bin-dir` with a directory already on `PATH`). The active install lives at `~/.local/opt/harness/current`, not in `~/.local/share/h`. Omit `--service` for an install without a registered service and use `hi daemon start` in a dedicated terminal. Set a custom store with `--data-dir` on install and use matching `H_DATA_DIR` in clients.

## Choose the right restart

| Situation | Action |
|---|---|
| New binary or startup configuration for a foreground standalone daemon | `hi daemon restart` (idle only) |
| Restart the registered macOS service | `hi daemon restart-service` (guarded shutdown first) |
| Stop work for the day | `hi daemon stop` on an idle standalone instance; `hi daemon start-service` starts a stopped registered service |
| New `hi` binary only | `/restart-ui /absolute/path/to/hi` in the session; `~` is not expanded |
| Updated local status templates or keybindings | `/reload` in `hi`; no process restart |

A refused shutdown is useful: `hi inbox` shows which sessions still have work. Wait for completion, or explicitly stop the intended run, then retry. A waiting retry is work too. Do **not** launch a foreground restart from an agent's shell tool: that command itself keeps the daemon busy. Reexec preserves the client target, not drafts; finish submitting or discard unsent changes first.

## Upgrade or switch back

From the checkout run `mix h.local` to build, smoke-test and install an update. If `dist/harness` is already built and tested, `mix h.install` installs it without rebuilding. Service activation preflights startup config, refuses a busy service, and selects a versioned release. If readiness fails, inspect `<data_dir>/h-daemon.log`; there is no automatic rollback. Use `mix h.install --activate RELEASE_ID` with the printed previous ID only if that release can read the current store and credential formats.

## Listener settings

`H_WEB_PORT` changes the bundled web port; `H_WEB=0` disables the web listener. The default API listens on loopback port 4100 and the local Unix socket `api.sock`. `network.json` in the data directory selects explicit bind addresses at startup. The listeners speak plain HTTP; keep the default unless operating on a trusted encrypted network. See [security](/docs/security/) and the [management reference](https://gitlab.com/parlant-co/harness/-/blob/main/docs/hi/management.md).
