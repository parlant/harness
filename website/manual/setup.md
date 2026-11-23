---
layout: doc
title: 'Set up H'
description: 'Install a signed release via shell script, Mix archive, or macOS app bundle, or build from source.'
lang: en
permalink: /docs/setup/
---
Run one H server for each data directory. The bundled daemon and the Phoenix development server both host `:harness` in their BEAM VM and take an exclusive lock on the store.

* Contents
{:toc}

## Install a signed release

Download a prebuilt release for **macOS (`darwin-arm64`)** or **Linux (`linux-arm64`, `linux-x86_64`)** from [GitLab Releases](https://gitlab.com/parlant-co/harness/-/releases) or the [GitHub mirror](https://github.com/parlant/harness). Every release archive includes a `BUILD_MANIFEST.json` pinned to its source commit and an OpenSSH signature verified against `packaging/keys/release-signers`.

- **Install with the POSIX shell script**: review [`/install.sh`](/install.sh), then run it to verify the OpenSSH signature and SHA-256 digest, unpack `~/.local/opt/harness/current`, symlink `hi` and `hi-import` into the first writable directory on `PATH` (preferring `/usr/local/bin`, `/opt/local/bin`, `/opt/homebrew/bin`, and `~/.local/bin`, falling back to `~/.bin` last, or overriding with `--bin-dir`), and register a per-user macOS LaunchAgent or Linux `systemd --user` service with `--service`:

```sh
curl -fsSL https://gitlab.com/parlant-co/harness/-/raw/main/scripts/install.sh | sh -s -- --service
```

- **Install with the Mix archive**: when Elixir and Mix are installed on your machine, install the `h_setup` archive and run `mix h.setup`:

```sh
mix archive.install https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/h_setup.ez
mix h.setup --service
```

- **Install the macOS application bundle (`H.app`)**: download `H-v<version>-darwin-arm64.dmg` from the [latest release](https://gitlab.com/parlant-co/harness/-/releases/permalink/latest), drag `H.app` to `/Applications`, and launch it. `H.app` starts its embedded daemon on `~/.local/share/h`, opens `http://127.0.0.1:4200/inbox`, and provides menu-bar commands to copy the owner sign-in token, link `hi` into a writable directory on `PATH`, or drain and restart the daemon.

To verify a release archive manually before extracting, check `SHA256SUMS.sig` against [`packaging/keys/release-signers`](https://gitlab.com/parlant-co/harness/-/blob/main/packaging/keys/release-signers):

```sh
ssh-keygen -Y verify -f release-signers -I bingboombam@parlant.xyz -n file -s SHA256SUMS.sig < SHA256SUMS
shasum -a 256 -c SHA256SUMS
```

## Build a bundle from source (terminal and web)

Clone the [H repository on GitLab](https://gitlab.com/parlant-co/harness) or [GitHub](https://github.com/parlant/harness) on macOS or Linux. Building from source requires Elixir 1.20 with Erlang/OTP 29, Rust with Cargo, Node with npm for the web assets, and Python 3 for packaging and smoke checks. Build the self-contained release bundle and start the foreground daemon:

```sh
mix h.build --release
export PATH="$PWD/dist/harness/bin:$PATH"
hi daemon start
```

Keep `hi daemon start` running in its terminal. Open a second terminal, add the bundle's absolute `dist/harness/bin` directory to `PATH`, and run `hi daemon status` to confirm the client reaches the daemon. Open `http://127.0.0.1:4200/inbox` in your browser and sign in with the token stored in `${H_DATA_DIR:-$HOME/.local/share/h}/auth.token`.

To install your source build into `~/.local/opt/harness/current` for daily use, follow [manage the daemon](/docs/daemon/).

## Develop from source instead

To run the Phoenix web workbench with live reloading from the repository root, build the editor assets and start `mix phx.server`:

```sh
(cd clients/web/assets && npm ci && npm run build)
(cd clients/web && mix deps.get && mix phx.server)
```

Open `http://127.0.0.1:4000` in your browser. If you only need the headless daemon HTTP and socket API during development, run `bin/h-daemon` instead of `mix phx.server`:

```sh
mix deps.get
mix compile
bin/h-daemon
```

`bin/h-daemon` loads compiled beams from `_build/dev` by default; set `H_BUILD_PATH` when you compile into a custom Mix build directory. Install the `hi` terminal binary from the checkout root with `cargo install --locked --path clients/tui` and ensure Cargo's bin directory is on your `PATH`.

## Make the first connection

1. Confirm your store path. H stores session data and credentials in `~/.local/share/h` by default. When you override `H_DATA_DIR`, pass the same absolute path to the daemon and to every `hi` client.
2. [Configure a model provider](/docs/providers/). Run `hi login` for a ChatGPT Codex account, or save an API key through `/key set` in `hi` or **Account settings** in `hiweb`.
3. Change into a project checkout you trust, run `hi`, and select a model with `/model`. Submitting a prompt sends project context to your chosen provider and lets tools execute with your OS user's permissions. Press Enter to send your first prompt.
4. Close the client with `/quit`, then run `hi -r` in the same project directory to reattach, or run `hi inbox` to browse sessions across all workspaces.

## Troubleshoot startup

If startup reports an address in use or a locked store, another daemon or Phoenix server is already running against that data directory. Run `hi daemon status` with your target `H_DATA_DIR` to inspect the active server. When running a second development instance alongside your daily daemon, give the second instance its own `H_DATA_DIR`, a separate web `PORT`, and a separate browser profile so localhost cookies stay isolated. If a model appears in `/model` but refuses to run, check [providers and credentials](/docs/providers/) to ensure an active key or login is saved for that provider.

[Checkout quickstart](https://gitlab.com/parlant-co/harness/-/blob/main/README.md) · [Bundle layout](https://gitlab.com/parlant-co/harness/-/blob/main/rel/README.md)
