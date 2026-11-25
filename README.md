# H (`:harness`)

H is a local Elixir/OTP daemon for coding-agent sessions. A session can branch without copying its transcript. The Phoenix LiveView app and native terminal client can work on the same conversation; disconnecting one does not stop a run.

## Install a release

Prebuilt signed releases are published for **macOS (`darwin-arm64`)** and **Linux (`linux-arm64`, `linux-x86_64`)** on [GitHub Releases](https://github.com/parlant/harness/releases) and [GitLab Releases](https://gitlab.com/parlant-co/harness/-/releases), with full documentation on **[hiness.dev](https://hiness.dev)** and the macOS `H.app` bundle showcase on **[hiness.app](https://hiness.app)**. Every release embeds a `BUILD_MANIFEST.json` tied to its exact Git commit and is signed with OpenSSH (`packaging/keys/release-signers`).

### Shell installer (`macOS` and `Linux`)

Review [`scripts/install.sh`](scripts/install.sh) (also served at [`https://hiness.dev/install.sh`](https://hiness.dev/install.sh)), then run:

```sh
curl -fsSL https://hiness.dev/install.sh | sh -s -- --service
```

The script verifies `SHA256SUMS.sig` with `ssh-keygen -Y verify` (`bingboombam@parlant.xyz` in `packaging/keys/release-signers`), checks the archive SHA-256, installs the bundle under `~/.local/opt/harness/current`, cascades writable `PATH` locations (preferring `/usr/local/bin`, `/opt/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`, or other writable `PATH` directories, falling back to `~/.bin` last; override with `--bin-dir`), and optionally registers a per-user macOS LaunchAgent or Linux `systemd --user` service (`--service`).

### Elixir / Mix archive (`mix h.setup`)

If Elixir and Mix are already installed, install the zero-dependency `h_setup` archive from the signed release and run `mix h.setup`:

```sh
mix archive.install https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/h_setup.ez
mix h.setup --service
```

### Embed H in an Elixir project

Once `hiness` is available on Hex, use Elixir 1.20 / OTP 29 and add `{:harness, "~> 0.3.0", hex: :hiness}` to `mix.exs`. `hiness` is the Hex package; `:harness` is the OTP application and configuration key. See the [embedding guide](docs/hexdocs.md) and [HexDocs](https://hexdocs.pm/hiness).

### macOS application bundle (`H.app`)

On macOS (`arm64`), visit **[hiness.app](https://hiness.app)** or download `H-v<version>-darwin-arm64.dmg` from [GitHub Releases](https://github.com/parlant/harness/releases) / [GitLab Releases](https://gitlab.com/parlant-co/harness/-/releases/permalink/latest), drag **`H.app`** to `/Applications`, and open it. `H.app` starts its embedded daemon on `~/.local/share/h`, opens the web workbench at `http://127.0.0.1:4200/inbox`, and provides `[H]` menu-bar actions to copy your owner sign-in token, link `hi` into the first writable standard `PATH` bin directory (falling back to `~/.bin` last), or cooperatively drain and restart the daemon.

## Build from source

Development target: Elixir 1.20 / OTP 29, plus Rust for `clients/tui` and Node/npm to build the Monaco editor assets.

```sh
# Web UI: build the optional Monaco assets, then start Phoenix and the daemon
(cd clients/web/assets && npm ci && npm run build)
(cd clients/web && mix deps.get && PHX_SERVER=true mix run --no-halt)

# Alternatively, for API and terminal clients only (no browser UI):
mix deps.get
mix compile
bin/h-daemon
```

Run only one server per data directory. For Phoenix, open `http://127.0.0.1:4000` and sign in with the owner token in `${H_DATA_DIR:-$HOME/.local/share/h}/auth.token`.

For file review, live reloading, pane composition, and the visual feedback inspector, see [Working on the web UI](clients/web/README.md).

Build the terminal client from the repository, then run it from your project directory. It attaches to either server; it does not start one:

```sh
cargo install --locked --path clients/tui
cd /path/to/project
hi                         # fullscreen editor; Enter steers, Alt-Enter follows up
hi inbox                   # live multi-session inbox across workspaces (/inbox or Alt-I in session)
hi --tui-mode regular      # terminal-owned scrollback
hi -r                      # workspace session picker
hi -s SESSION_ID           # attach by ID, including when using a symlink to the workspace
```

The standalone daemon prints its API address. Its default data directory is `~/.local/share/h`; override it with `--data-dir DIR` or `H_DATA_DIR`. Phoenix and `hi` also honor `H_DATA_DIR`. Use `h-daemon -ne` (or `--no-extensions`) to bypass [configured extensions](docs/extensions/daemon.md). [Managed Codex device login](docs/providers.md#managed-device-login) is built in and opt-in; it needs no Codex executable. [MultiCodex](extensions/multicodex/README.md) is a separate path-loaded extension. Host tools run with your user's filesystem and shell access, not in a sandbox.

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
mix h.build --release          # refreshes the tested bundle at dist/harness
dist/harness/bin/hi daemon start
```

The bundled daemon also serves the owner-authenticated web inbox at
<http://127.0.0.1:4200/inbox>. Sign in with your store's `auth.token`.

For daily use from any project, run `mix h.local --service` for first-time
service setup after stopping any manually started daemon. For later updates,
run `mix h.local` to build, smoke-test, and install. If the bundle is already
built, run `mix h.install` alone. `mix h.bundle` is equivalent to
`mix h.build --release`.
By default the installer cascades writable `PATH` directories (preferring `/usr/local/bin`, `/opt/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`, and other user-writable `PATH` directories before falling back to `~/.bin` last); pass `--bin-dir` to pin a specific directory.
This installs a versioned bundle and a per-user macOS service. `hi` resolves
its sibling `h-daemon`; `H_DAEMON_BIN` or `--launcher` can override
it. On macOS, `hi daemon install-service` registers a per-user LaunchAgent.
Use `mix h.build` for a development build of all three applications. On shutdown (`hi daemon stop`, `restart`, `restart-service`, `mix h.install`, or `SIGTERM`), the daemon cooperatively drains open tools and provider streams without starting new tools or turns (automatically extending the 300s default drain timeout to cover active tool deadlines plus a 30s commit grace), then resumes active sessions on next boot. See
[local daemon management](docs/hi/management.md) for cooperative restarts, `--idle-only` guards, and
resuming the same conversation with `/restart-ui`.

Import pi transcripts as read-only sessions with `hi import --harness pi`.
See [archive import](docs/hi/import.md) for overrides and repeat imports.

See [model provider setup](docs/providers.md) for `/key set` and named API-key
profiles, Codex device login, and Gemini on Vertex AI.

## Test

Run `mix test` at the root and in `clients/web/`; both projects default to `--no-start`. Run `cargo test --locked` in `clients/tui/`. The root suite excludes live LLM calls. To include the Phoenix/Rust sync test, build `hi` first and run `HI_BIN=/absolute/path/to/hi mix test --include native_client` in `clients/web/`.

## Documentation

- [Hex release checklist](docs/releasing.md) — build, verify, and publish `hiness` and the separate `h_setup` installer
- [Architecture](docs/architecture.md) — ownership, commits, recovery and client boundaries
- [Subagents and work delegation](docs/architecture/subagents.md) — multi-session orchestration reflection and proposed delegation primitives
- [Local HTTP/JSON and SSE protocol](docs/protocol.md)
- [Roadmap](docs/roadmap.md) — implemented milestones and remaining work
- [hi build and cutover status](docs/hi/build.md) — shipped workflows, verification and ordered remaining batches
- [hi status lines](docs/hi/status.md) — user templates, available fields and `/reload`
- [Session performance](docs/hi/session-performance.md) — catalog scale, tool latency, and idle memory
- [hi design and parity target](docs/hi.md) — interaction parity, Rust choices and durable differences
- [Extensions](docs/extensions.md) — daemon packages, profiles, environments, providers and clients
- [Design references](docs/references.md)

The project websites ([`websites/hiness.dev`](websites/hiness.dev/README.md) and [`websites/hiness.app`](websites/hiness.app/README.md)) build separately with Jekyll and share synchronized release and legal records under `websites/shared/`. Their demos are static walkthroughs; no running daemon or provider account is required.
