---
layout: doc
title: 'Set up H'
description: 'Build a native bundle or run one development server, then connect both clients to the same store.'
lang: en
permalink: /docs/setup/
---
Choose **one** of the server options below. Phoenix already runs the daemon in its VM; starting `bin/h-daemon` alongside it is neither necessary nor supported for the same store.

* Contents
{:toc}

## Build a bundle (terminal and web)

These source build instructions assume you already have access to the [H source checkout on GitLab](https://gitlab.com/parlant-co/harness/-/blob/main/README.md); anonymous requests currently return 404. Start at the repository root on macOS or Linux. Building requires Elixir 1.20 / Erlang/OTP 29, Rust with Cargo, Node with npm for the editor assets, and Python 3 for packaging and smoke checks. The resulting bundle targets the build machine's OS and architecture. Keep the entire directory together; running it does not require Mix, Node or Cargo.

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
