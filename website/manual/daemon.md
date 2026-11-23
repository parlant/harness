---
layout: doc
title: 'Manage the daemon'
description: 'Install a per-user background service, drain active turns during restarts, and upgrade releases in place.'
lang: en
permalink: /docs/daemon/
---
Upgrading the H release binary leaves your data directory, saved credentials, and project workspaces in place. Install the release into `~/.local/opt/harness/current` while keeping session data in `~/.local/share/h` (or your custom `H_DATA_DIR`).

* Contents
{:toc}

## Install for daily use

Install a signed release with the [POSIX shell installer](/install.sh) or `mix h.setup --service` from the `h_setup` Mix archive; see [Set up H](/docs/setup/). Passing `--service` registers a per-user macOS LaunchAgent or Linux `systemd --user` service.

To build, smoke-test, and install a release directly from a source checkout on macOS, run:

```sh
mix h.local --service
hi daemon status
```

`mix h.local --service` installs the release bundle under `~/.local/opt/harness/current`, links `hi` and `hi-import` into `~/.bin` (or `--bin-dir`), and registers or restarts your user LaunchAgent. Add `~/.bin` to your `PATH`. Omit `--service` if you prefer to start the daemon manually with `hi daemon start`. Pass `--data-dir` on install when you want the service to use a custom data directory, and export the same `H_DATA_DIR` in your shell.

## Choose the right restart

| Situation | Action |
|---|---|
| Restart a foreground standalone daemon after a binary or config change | `hi daemon restart` (drains open tool calls and streams; pass `--idle-only` to refuse if busy) |
| Restart the registered user service | `hi daemon restart-service` (drains open work before restarting) |
| Stop the daemon cleanly | `hi daemon stop` (or `SIGTERM`); run `hi daemon start-service` to start a stopped user service |
| Switch to a newly compiled `hi` binary during a session | `/restart-ui /absolute/path/to/hi` inside `hi` |
| Reload local status templates or keybindings | `/reload` inside `hi` |

When you trigger a cooperative drain (`hi daemon stop`, `restart`, `restart-service`, `mix h.install`, or `SIGTERM`), H stops accepting new commands, runs in-flight tool calls and open provider streams to completion, commits their outcomes, and parks subsequent turns and retry timers on disk. When the new daemon boots against the same store, it resumes active sessions from those committed turn boundaries. Pass `--idle-only` if you prefer the command to exit without stopping when sessions are active (`hi inbox` lists active work). Run daemon restarts from your own terminal or service manager rather than from inside an agent's `bash` tool call, and submit or clear any unsent composer draft before running `/restart-ui`.

## Upgrade or switch back

To upgrade a signed binary release, rerun the [shell installer](/install.sh) or `mix h.setup` (include `--service` when using a background service). From a source checkout, run `mix h.local` to build, test, and activate a new release, or `mix h.install` if `dist/harness` is already built. Activation validates startup configuration, drains the running service, waits for the old BEAM process to exit, and switches the `current` symlink atomically.

If the new release fails its readiness check, inspect `<data_dir>/h-daemon.log`. To switch back to an earlier installed bundle whose store format is compatible, run:

```sh
mix h.install --activate RELEASE_ID
```

## Listener settings

Set `H_WEB_PORT` to change the bundled web port (default `4200`), or set `H_WEB=0` to disable the web listener. By default, the daemon API listens on loopback port `4100` and the Unix socket `<data_dir>/api.sock`. Create `<data_dir>/network.json` to configure explicit bind addresses at startup. Because the standalone listeners serve plain HTTP, keep them bound to loopback or a trusted encrypted VPN. See [security boundaries](/docs/security/) and the [daemon management reference](https://gitlab.com/parlant-co/harness/-/blob/main/docs/hi/management.md).
