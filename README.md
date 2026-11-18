# H (`:harness`)

H is a local Elixir/OTP daemon for coding-agent sessions. A session can branch without copying its transcript. The Phoenix LiveView app and native terminal client can work on the same conversation; disconnecting one does not stop a run.

## Start here

Development target: Elixir 1.20 / OTP 29 (plus Rust for `clients/tui`).

```sh
# Web UI: start Phoenix and the daemon together from the repo root
(cd clients/web && mix deps.get && PHX_SERVER=true mix run --no-halt)

# Alternatively, for API and terminal clients only (no browser UI):
mix deps.get
mix run --no-halt -e 'H.serve()'
```

Run only one server per data directory. For Phoenix, open `http://127.0.0.1:4000` and sign in with the owner token in `${H_DATA_DIR:-$HOME/.local/share/h}/auth.token`.

Build the terminal client from the repository, then run it from your project directory. It attaches to either server; it does not start one:

```sh
cargo install --locked --path clients/tui
cd /path/to/project
h -r                       # select a session in this folder
h -s SESSION_ID            # attach by ID, including when using a symlink to the workspace
```

The standalone daemon prints its API address. Its default data directory is `~/.local/share/h`; override it with `H.serve(data_dir: "...")`. Phoenix and `h` honor `H_DATA_DIR`. Host tools run with your user's filesystem and shell access, not in a sandbox.

## Test

Run `mix test` at the root and in `clients/web/`; both projects default to `--no-start`. Run `cargo test --locked` in `clients/tui/`. The root suite excludes live LLM calls. To include the Phoenix/Rust sync test, build `h` first and run `H_NATIVE_TEST_BIN=/absolute/path/to/h mix test --include native_client` in `clients/web/`.

## Documentation

- [Architecture](docs/architecture.md) — ownership, commits, recovery and client boundaries
- [Local HTTP/JSON and SSE protocol](docs/protocol.md)
- [Roadmap](docs/roadmap.md) — implemented milestones and remaining work
- [Design references](docs/references.md)
