# H (`:harness`)

H is a local Elixir/OTP daemon for coding-agent sessions. A session can branch without copying its transcript. The Phoenix LiveView app and native terminal client can work on the same conversation; disconnecting one does not stop a run.

## Start here

Development target: Elixir 1.20 / OTP 29 (plus Rust for `clients/tui`).

```sh
# Web UI: start Phoenix and the daemon together from the repo root
(cd clients/web && mix deps.get && PHX_SERVER=true mix run --no-halt)

# Alternatively, for API and terminal clients only (no browser UI):
mix deps.get
mix compile
bin/h-daemon
```

Run only one server per data directory. For Phoenix, open `http://127.0.0.1:4000` and sign in with the owner token in `${H_DATA_DIR:-$HOME/.local/share/h}/auth.token`.

For live reloading, pane composition and the visual feedback inspector, see [Working on the web UI](clients/web/README.md).

Build the terminal client from the repository, then run it from your project directory. It attaches to either server; it does not start one:

```sh
cargo install --locked --path clients/tui
cd /path/to/project
hi                         # fullscreen editor; Enter steers, Alt-Enter follows up
hi --tui-mode regular      # terminal-owned scrollback
hi -r                      # workspace session picker
h -r                       # original line-oriented client
h -s SESSION_ID            # attach by ID, including when using a symlink to the workspace
```

The standalone daemon prints its API address. Its default data directory is `~/.local/share/h`; override it with `--data-dir DIR` or `H_DATA_DIR`. Phoenix and `h` also honor `H_DATA_DIR`. Use `h-daemon -ne` (or `--no-extensions`) to bypass [configured extensions](docs/extensions/daemon.md). [Managed Codex device login](docs/providers.md#managed-device-login) is built in and opt-in; it needs no Codex executable. [MultiCodex](extensions/multicodex/README.md) is a separate path-loaded extension. Host tools run with your user's filesystem and shell access, not in a sandbox.

## Manage H with `hi`

`hi login` sets up the first Codex alias without creating a session or editing
JSON. It is also available as `/login` during a session and in Phoenix under
**Account settings**. Use `hi account list`, `hi account add <alias>`, or
`hi account use <alias>` to manage the daemon's aliases.

```sh
hi daemon status
hi daemon start --launcher "$PWD/bin/h-daemon"    # foreground, from a built checkout
```

For a standalone bundle with the runtime included:

```sh
mix h.bundle                   # refreshes the tested bundle at dist/harness
dist/harness/bin/hi daemon start
```

For daily use from any project, run `mix h.install --service` after building
with `mix h.bundle` and stopping any manually started daemon. For later
updates, run `mix h.bundle && mix h.install`; no bundle path is needed.
The installer puts `hi` in
`~/.bin` by default; use `--bin-dir` to choose another directory on `PATH`.
This installs a versioned bundle and a per-user macOS service. `hi` resolves
its sibling `h-daemon`; `H_DAEMON_BIN` or `--launcher` can override
it. On macOS, `hi daemon install-service` registers a per-user LaunchAgent.
Use `mix h.build` for a development build of all three applications. See
[local daemon management](docs/hi-management.md) for idle-only restarts and
resuming the same conversation with `/restart-ui`.

See [model provider setup](docs/providers.md) for `/key set` and named API-key
profiles, Codex device login, and Gemini on Vertex AI.

## Test

Run `mix test` at the root and in `clients/web/`; both projects default to `--no-start`. Run `cargo test --locked` in `clients/tui/`. The root suite excludes live LLM calls. To include the Phoenix/Rust sync test, build `h` first and run `H_NATIVE_TEST_BIN=/absolute/path/to/h mix test --include native_client` in `clients/web/`.

## Documentation

- [Architecture](docs/architecture.md) — ownership, commits, recovery and client boundaries
- [Local HTTP/JSON and SSE protocol](docs/protocol.md)
- [Roadmap](docs/roadmap.md) — implemented milestones and remaining work
- [hi build and cutover status](docs/hi-build.md) — shipped workflows, verification and ordered remaining batches
- [hi status lines](docs/hi-status.md) — user templates, available fields and `/reload`
- [hi design and parity target](docs/hi.md) — interaction parity, Rust choices and durable differences
- [Extensions](docs/extensions.md) — daemon packages, profiles, environments, providers and clients
- [Design references](docs/references.md)
