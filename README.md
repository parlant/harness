<p align="center">
  <strong>H (<code>:harness</code>)</strong> is a local Elixir/OTP coding-agent daemon with durable branched sessions, a native terminal client (<code>hi</code>), and a Phoenix LiveView workbench (<code>hiweb</code>).
</p>

<p align="center">
  <img src="https://hiness.dev/assets/screenshots/hiweb-inbox.webp" alt="H multi-session inbox in hiweb showing ready and running sessions across workspaces" width="84%" />
</p>

<p align="center">
  <a href="https://hiness.dev">Website &amp; Manual (hiness.dev)</a> ·
  <a href="https://hiness.app">macOS App (hiness.app)</a> ·
  <a href="https://hex.pm/packages/hiness">Hex (hiness)</a> ·
  <a href="https://hiness.hexdocs.pm/">HexDocs</a> ·
  <a href="https://gitlab.com/parlant-co/harness/-/releases">GitLab Releases</a> ·
  <a href="https://github.com/parlant/harness/releases">GitHub Releases</a>
</p>

<p align="center">
  Sessions branch without copying transcripts. Terminal and browser clients share the same live conversation, and disconnecting one never stops a run.
</p>

---

## Quickstart

### Install H on macOS or Linux

Review [`scripts/install.sh`](scripts/install.sh) (also served at [`https://hiness.dev/install.sh`](https://hiness.dev/install.sh)), then run:

```sh
curl -fsSL https://hiness.dev/install.sh | sh -s -- --service
```

Then connect a model provider and launch the terminal client in any project:

```sh
hi login        # or configure an API key with /key set
cd /path/to/project
hi              # fullscreen TUI (hi inbox for multi-session triage)
```

The bundled daemon also serves the owner-authenticated web workbench at `http://127.0.0.1:4200/inbox` (sign in with `~/.local/share/h/auth.token`).

### Other install options

- **macOS menu-bar app (`H.app`)** — Visit **[hiness.app](https://hiness.app)** or download `H-v<version>-darwin-arm64.dmg` from [GitLab Releases](https://gitlab.com/parlant-co/harness/-/releases/permalink/latest) / [GitHub Releases](https://github.com/parlant/harness/releases), drag **`H.app`** to `/Applications`, and open it. `H.app` starts the bundled daemon on `~/.local/share/h`, opens `http://127.0.0.1:4200/inbox`, and adds `[H]` menu-bar actions to copy your owner sign-in token, link `hi` onto `PATH`, or cooperatively drain and restart the daemon.
- **Elixir / Mix archive (`mix h.setup`)** — If Elixir and Mix are already installed:

  ```sh
  mix archive.install https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/h_setup.ez
  mix h.setup --service
  ```

- **Embed `:harness` in an Elixir project** — With Elixir 1.20 / OTP 29, add the core daemon from [Hex](https://hex.pm/packages/hiness) to `mix.exs`:

  ```elixir
  {:harness, "~> 0.5.1", hex: :hiness}
  ```

  `hiness` is the Hex package name; `:harness` is the OTP application and configuration key. See the [embedding guide](https://hiness.hexdocs.pm/overview.html#embed-harness-in-an-elixir-otp-application) and [Elixir API reference on HexDocs](https://hiness.hexdocs.pm/).

<details>
<summary>Signed release verification, platforms, and installer paths</summary>

Prebuilt signed releases are published for **macOS (`darwin-arm64`)** and **Linux (`linux-arm64`, `linux-x86_64`)**. Every release embeds a `BUILD_MANIFEST.json` tied to its exact Git commit and is signed with OpenSSH (`bingboombam@parlant.xyz` in [`packaging/keys/release-signers`](packaging/keys/release-signers)).

`install.sh` verifies `SHA256SUMS.sig` with `ssh-keygen -Y verify`, checks the archive SHA-256, installs under `~/.local/opt/harness/current`, links `hi` and `hi-import` into the first writable standard `PATH` directory (`/usr/local/bin`, `/opt/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`, or other writable `PATH` directories, falling back to `~/.bin` last; override with `--bin-dir`), and optionally registers a per-user macOS LaunchAgent or Linux `systemd --user` service (`--service`).

</details>

---

## Everyday `hi` workflow

```sh
hi                         # fullscreen editor; Enter steers, Alt-Enter follows up
hi inbox                   # live multi-session inbox across workspaces (/inbox or Alt-I)
hi --tui-mode regular      # terminal-owned scrollback
hi -r                      # workspace session picker
hi -s SESSION_ID           # attach by ID (works through workspace symlinks)
hi daemon status           # check daemon health and active sessions
hi import --harness pi     # import pi transcripts as read-only sessions
```

**Accounts & providers:** `hi login` sets up a managed Codex device login without needing a Codex executable (also `/login` in session or **Account settings** in `hiweb`). Manage profiles with `hi account list|add|use|remove`, `hi logout [alias]`, or `hi key remove <provider> <alias>`. See [model provider setup](docs/providers.md) for `/key set`, named API-key profiles, Codex device login, and Gemini on Vertex AI.

**Cooperative restarts:** On shutdown (`hi daemon stop`, `restart`, `restart-service`, `mix h.install`, or `SIGTERM`), the daemon drains open tools and provider streams without starting new turns (extending the 300s default drain timeout for active tool deadlines plus a 30s commit grace), then resumes active sessions on next boot. See [local daemon management](docs/hi/management.md) for `--idle-only` guards and `/restart-ui`.

> **Security note:** Host tools execute with your OS user's filesystem and shell permissions, not in a sandbox.

---

## Build from source

<details>
<summary>Development setup, local bundles, and test commands (Elixir 1.20 / OTP 29, Rust, Node)</summary>

### Run from a checkout

```sh
# Web UI (optional Monaco assets) + Phoenix + embedded daemon
(cd clients/web/assets && npm ci && npm run build)
(cd clients/web && mix deps.get && PHX_SERVER=true mix run --no-halt)

# Or daemon only (API + terminal clients, no browser UI)
mix deps.get
mix compile
bin/h-daemon
```

Run only one server per data directory (`~/.local/share/h` by default; override with `--data-dir DIR` or `H_DATA_DIR`). For Phoenix dev, open `http://127.0.0.1:4000` and sign in with `${H_DATA_DIR:-$HOME/.local/share/h}/auth.token`. Use `h-daemon -ne` (`--no-extensions`) to bypass [configured extensions](docs/extensions/daemon.md). [MultiCodex](extensions/multicodex/README.md) is a separate path-loaded extension. See [Working on the web UI](clients/web/README.md) for LiveView development details.

Build and install the Rust terminal client from source (attaches to either server; does not start one):

```sh
cargo install --locked --path clients/tui
hi daemon start --launcher "$PWD/bin/h-daemon"    # foreground, from a built checkout
```

### Build and install local release bundles

```sh
mix h.build                    # development build of all three apps
mix h.build --release          # tested standalone bundle at dist/harness (alias: mix h.bundle)
dist/harness/bin/hi daemon start

mix h.local --service          # first-time build + smoke-test + service install
mix h.local                    # subsequent updates (or mix h.install if already built)
```

`hi` resolves its sibling `h-daemon` by default (`H_DAEMON_BIN` or `--launcher` overrides it). On macOS, `hi daemon install-service` registers a per-user LaunchAgent.

### Test

```sh
mix test                                    # root daemon suite (defaults to --no-start, no live LLM calls)
(cd clients/web && mix test)                # web client suite (--no-start)
cargo test --locked --manifest-path clients/tui/Cargo.toml
```

To include the Phoenix/Rust sync test, build `hi` first and run `HI_BIN=/absolute/path/to/hi mix test --include native_client` in `clients/web/`.

</details>

---

## Documentation

- [**hiness.dev**](https://hiness.dev) — operator manual, setup guides, and walkthroughs
- [**hiness.app**](https://hiness.app) — macOS `H.app` bundle showcase and download guide
- [**HexDocs (`hiness`)**](https://hiness.hexdocs.pm/) — Elixir API reference and embedding guide
- [**Architecture**](docs/architecture.md) — ownership, atomic commits, crash recovery, and client boundaries
- [**Subagents and work delegation**](docs/architecture/subagents.md) — multi-session orchestration and delegation primitives
- [**Local HTTP/JSON and SSE protocol**](docs/protocol.md) — daemon API and streaming contract
- [**Model providers**](docs/providers.md) — `/key set`, Codex device login, and Vertex AI
- [**Extensions**](docs/extensions.md) — daemon packages, profiles, environments, providers, and clients
- [**Local daemon management**](docs/hi/management.md) · [**Archive import**](docs/hi/import.md) · [**hi status lines**](docs/hi/status.md)
- [**hi design and parity target**](docs/hi.md) · [**hi build status**](docs/hi/build.md) · [**Session performance**](docs/hi/session-performance.md)
- [**Roadmap**](docs/roadmap.md) · [**Hex release checklist**](docs/releasing.md) · [**Design references**](docs/references.md)

The project websites ([`websites/hiness.dev`](websites/hiness.dev/README.md) and [`websites/hiness.app`](websites/hiness.app/README.md)) build separately with Jekyll and share synchronized release and legal records under `websites/shared/`.

This repository is licensed under the [MIT License](LICENSE).
