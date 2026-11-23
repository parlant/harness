---
layout: doc
title: 'Set up H'
description: 'Install a signed release via shell script, Mix archive, or macOS app bundle, or build from source.'
lang: en
permalink: /docs/setup/
---
Choose **one** of the server options below. Phoenix already runs the daemon in its VM; starting `bin/h-daemon` alongside it is neither necessary nor supported for the same store.

* Contents
{:toc}

## Install a signed release

Prebuilt releases are published for **macOS (`darwin-arm64`)** and **Linux (`linux-arm64`, `linux-x86_64`)** on [GitLab Releases](https://gitlab.com/parlant-co/harness/-/releases) and mirrored on [GitHub](https://github.com/parlant/harness). Each release archive embeds a `BUILD_MANIFEST.json` tied to its source commit and is signed with OpenSSH (`packaging/keys/release-signers`).

- **Shell installer**: review the [short POSIX installer script](/install.sh), then run it to verify the OpenSSH signature and SHA-256 digest, unpack `~/.local/opt/harness/current`, link `hi` and `hi-import` into `~/.bin` (override with `--bin-dir`), and optionally register a per-user macOS LaunchAgent or Linux `systemd --user` service (`--service`):

```sh
curl -fsSL https://gitlab.com/parlant-co/harness/-/raw/main/scripts/install.sh | sh -s -- --service
```

- **Local Mix / Hex archive**: if Elixir and Mix are on your machine, install the zero-dependency `h_setup` archive (or `mix archive.install hex h_setup` once published on Hex.pm) and run `mix h.setup`:

```sh
mix archive.install https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/h_setup.ez
mix h.setup --service
```

- **macOS application bundle (`H.app`)**: download `H-v<version>-darwin-arm64.dmg` from the [latest release](https://gitlab.com/parlant-co/harness/-/releases/permalink/latest), drag `H.app` to `/Applications`, and open it. `H.app` starts its embedded daemon on `~/.local/share/h`, opens `http://127.0.0.1:4200/inbox`, and exposes menu-bar controls to copy the owner sign-in token, link `hi` into `~/.bin`, or cooperatively drain and restart the daemon.

To verify a downloaded release manually before extracting, check `SHA256SUMS.sig` against [`packaging/keys/release-signers`](https://gitlab.com/parlant-co/harness/-/blob/main/packaging/keys/release-signers):

```sh
ssh-keygen -Y verify -f release-signers -I l.rieder@gmail.com -n file -s SHA256SUMS.sig < SHA256SUMS
shasum -a 256 -c SHA256SUMS
```

## Build a bundle from source (terminal and web)

Start at the [H source checkout on GitLab](https://gitlab.com/parlant-co/harness) (mirrored on [GitHub](https://github.com/parlant/harness)) on macOS or Linux. Building requires Elixir 1.20 / Erlang/OTP 29, Rust with Cargo, Node with npm for the editor assets, and Python 3 for packaging and smoke checks. The resulting bundle targets the build machine's OS and architecture. Keep the entire directory together; running it does not require Mix, Node or Cargo.

```sh
mix h.build --release
export PATH="$PWD/dist/harness/bin:$PATH"
hi daemon start
```

Leave the foreground process in its own terminal. In another terminal, also add the bundle's **absolute** `bin` directory to `PATH` before changing directories. `hi daemon status` should find the running daemon without creating a session. The bundled web inbox is at `http://127.0.0.1:4200/inbox`. Sign in locally with the contents of `${H_DATA_DIR:-$HOME/.local/share/h}/auth.token`.

For a persistent installation rather than a checkout-relative path, see [install and update](/docs/daemon/).

## Develop from source instead

For the live-reloading web app, from the repository root:

```sh
(cd clients/web/assets && npm ci && npm run build)
(cd clients/web && mix deps.get && mix phx.server)
```

Visit `http://127.0.0.1:4000`. The assets add Monaco for file review; plain-text review also works without them. To run just the daemon API, **instead of Phoenix**, use:

```sh
mix deps.get
mix compile
bin/h-daemon
```

The checkout launcher looks in `_build/dev` by default. If you compiled elsewhere, set `H_BUILD_PATH` to that Mix build directory. For either source option install the client from the repository root with `cargo install --locked --path clients/tui`; ensure Cargo's install bin directory is on `PATH`.

## Make the first connection

- The store defaults to `~/.local/share/h`, **not** the project directory. If using `H_DATA_DIR`, set it to the same absolute path for server and clients. The socket and owner token identify the store; `hi` will not launch a missing daemon.
- Follow [provider setup](/docs/providers/). For a first Codex account use `hi login`; for an API key use **Account settings** in the browser or `/key set` in a session.
- Change to the project directory, run `hi`, then `/model`. Sending input can transmit project context to a provider, incur charges and run tools with your OS permissions. Submit a prompt with Enter. Run `hi -r` in the same workspace to pick the session again. Use `hi inbox` to find sessions across workspaces.

## If setup stalls

A port already bound or a locked store usually means a server is already using it. Check `hi daemon status` with the intended `H_DATA_DIR` before starting another. For an independent Phoenix dev preview, use a fresh private store, a different web `PORT`, and a separate browser profile (cookies aren't scoped by port). A listed model with a missing key is a provider setup issue, not a missing session.

[Checkout quickstart](https://gitlab.com/parlant-co/harness/-/blob/main/README.md) · [Bundle layout](https://gitlab.com/parlant-co/harness/-/blob/main/rel/README.md)
