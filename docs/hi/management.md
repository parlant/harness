# Local daemon management with `hi`

`hi` has two entry points in the same binary: open or resume a conversation, or
run a management command without creating a conversation. Use `-p` or `--` for a literal prompt beginning with a
reserved management word. A management command can take `--data-dir` after its
first word, e.g. `hi account list --data-dir /path/to/store`.

| Outside a session | In a session / web |
|---|---|
| `hi inbox [--tui-mode <fullscreen\|regular>] [--env ID]` | `/inbox` or `Alt+I` opens the live multi-session inbox grouped by workspace (`j`/`k` or arrows move, `Tab` cycles attention-needing sessions, `Space`/`m` toggles `needs_attention`, `s` stops active work, `x`/`X` archives & unloads or force-stops-and-archives, `a` toggles Inbox vs All sessions, `Enter` opens, `n` creates a session, `Ctrl+D` returns to the inbox from a session opened through it). Inside a session, `/attention [on\|off]`, `/stop`, `/archive [force]`, and `/cwd [path]` manage triage, lifecycle, and forking missing-directory or archived sessions into an existing directory. |
| `hi login [openai_codex [alias]]` | `/login [openai_codex [alias]]`, or sign in on Phoenix **Account settings**. |
| `hi account list` | `/account` picker, or the accounts page. |
| `hi account add <alias>` | `/account add <alias>`, or the add-alias form. |
| `hi account use <alias>` | `/account <alias>`, or **Use in stock mode**. |
| `hi daemon status` | Authenticated liveness check; no session created. Exits nonzero and reports “not running” if the endpoint is missing or refuses the connection. |
| `hi daemon start [--launcher PATH] [--no-extensions]` | Starts in the foreground. |
| `hi daemon stop [--idle-only] [--timeout SECS]` / `hi daemon restart [...]` | Standalone only; cooperatively drains in-flight tools and open responses before stopping (pass `--idle-only` to refuse when busy; default 300s timeout automatically extends to cover longer running tool deadlines plus 30s commit grace unless `--timeout` is explicitly passed). |
| `hi -s ID --conversation CID` | `/restart-ui [path/to/hi]` reexecs into the same session and branch. |

For API-key profiles in the LaunchAgent, use `/key set <provider> <alias>`
with its masked prompt or Phoenix **Account settings**. The daemon need not
inherit provider secrets from your shell. See [API-key setup](../providers.md#api-keys-for-a-background-daemon).

The daemon is the only runtime writer of `accounts.json`. First login creates
an alias and the configuration before talking to OpenAI. It can be cancelled;
a cancelled login leaves the alias, not a credential. No client can write raw
credential JSON or a server-side file path. `extensions.json` stays an operator
file because it enables trusted executable code. [Account setup](../providers.md#managed-device-login)
explains how to keep using manual credentials or enable MultiCodex.

## Install for use in any project

Keep the checkout, installed releases and data separate:

- `<bin_dir>/hi` → `~/.local/opt/harness/current/bin/hi` (`<bin_dir>` cascades writable `PATH` locations: `/usr/local/bin`, `/opt/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`, other user-writable `PATH` dirs, falling back to `~/.bin` last).
- `~/.local/opt/harness/releases/<id>` contains a complete built bundle.
  `current` selects one release for the client and daemon together.
- `~/.local/share/h` continues to hold sessions, credentials, configuration,
  and service logs. It is not part of an upgrade.

From the checkout, install a **tested** bundle once (stop any manually started
or embedded daemon first, after its work finishes):

```sh
mix h.local --service
hi daemon status
```

`mix h.install` uses the tested bundle at `dist/harness` by default. It does
not build the checkout. Pass a bundle directory explicitly to install from
another path. By default it cascades writable `PATH` locations (preferring
`/usr/local/bin`, `/opt/local/bin`, `/opt/homebrew/bin`, and `~/.local/bin`,
resorting to `~/.bin` only last), or pass `--bin-dir` to pin a specific directory. `--service` installs a macOS per-user
LaunchAgent that starts at login and restarts on abnormal exit. An explicit
idle `hi daemon stop` exits successfully and stays stopped until the next
login or `hi daemon start-service`. No `sudo` or auto-build on attach. Run
`hi` from your projects as usual. For CLI-only installation, omit `--service`
and start manually. A custom `--data-dir` selects the service's store; use the
matching `H_DATA_DIR` or `--data-dir` in other terminals.

To build, smoke-test, and install an upgrade from the checkout:

```sh
mix h.local
```

This runs `mix h.build --release` and then `mix h.install` only if the
build and smoke test pass. It accepts `--service`, `--data-dir`, and
`--bin-dir` as install options.

`mix h.build --release` (also `mix h.bundle`) builds and tests a candidate, then atomically updates the
`dist/harness` symlink. A failed build or smoke test leaves the previous
candidate selected. If an older build left a real directory at `dist/harness`,
move it aside once it is no longer in use. Older candidates remain under
`dist/.harness-builds/` and may be deleted when nothing is using them.
For an explicit artifact directory, `mix h.bundle dist/NAME` still requires
that the target not exist and does not change `dist/harness`.

Activation preflights startup configuration (`--check-config`), then cooperatively
drains the existing service (`hi daemon stop`, which finishes in-flight tools and
open responses without starting new tools or turns), waits for launchd to confirm
process exit, switches `current` atomically, and starts the registered service
so active sessions automatically resume from their persisted checkpoints. The old bundle stays
installed. The task prints the previous release ID for explicit rollback:
`mix h.install --activate <id>`. A readiness failure is reported, not forcibly
rolled back; inspect the daemon log before deciding whether to switch back.
If launchd does not confirm that the old process exited, `current` stays on
the old bundle, which may already be stopped. The error shows the last observed
job state and the staged release ID. Once the job is stopped, retry with
`mix h.install --activate <staged-id>` without rebuilding or copying again.
Do not roll back across incompatible storage changes without a migration plan.
An already-open `hi` can reconnect to the new daemon and switch its own
binary with `/restart-ui /absolute/path/to/.bin/hi`. The slash command
does not expand `~`.

If switching from an earlier LaunchAgent pinned to a particular bundle,
uninstall it safely with a current `hi` first. The installer won't rewrite a
pinned service or take over an already-running standalone/embedded process.

## Develop H while using it

From the root checkout:

```sh
mix h.build    # compile daemon, Phoenix dev and hi; start nothing
mix h.bundle   # build, smoke-test, and refresh dist/harness
mix h.restart  # restart from dist/harness in a separate pane after the turn finishes
```

`mix h.build` prints the debug binary path and the Phoenix dev command.
Its `--output` option selects the Cargo target directory; with `--release`
it instead selects a new bundle directory. Phoenix dev embeds its own daemon;
stop the bundled daemon first or use a separate `H_DATA_DIR`.

You can run the build tasks from a session working on H. **Do not run the
foreground restart from a session tool:** the tool itself is unfinished work
and will block the guard (and a long-lived foreground process belongs in a
terminal or service). Let the turn finish, then run the restart in another pane.
`hi` can stay attached and reconnect across a standalone daemon restart using
the same data directory and socket. When ready to switch the client too, type
`/restart-ui /absolute/path/to/dist/harness/bin/hi`. With no path it reexecs the
current binary. This preserves the exact session and conversation, not scroll
position or unsaved local drafts; it refuses to restart while a draft,
attachment, ambiguous submission, or client command still needs attention.

On restart the candidate validates startup configuration before the old daemon
is asked to stop. By default, the old daemon closes command admission and
cooperatively drains in-flight workers (running tools, open provider streams,
and active token refreshes) without spawning subsequent tools or turns; pass
`--idle-only` to refuse immediately when busy. The drain timeout defaults to
300s (`H_SHUTDOWN_TIMEOUT_MS` floor) and automatically scales to
`max(default_timeout_ms, max_remaining_worker_ms + 30_000)` when a running tool
has a longer remaining deadline (for example, a 10-minute `bash` call), with
LaunchAgent `ExitTimeOut` and systemd `TimeoutStopSec` set to `660` seconds.
Once active workers finish, it exits through OTP shutdown (normal `SIGTERM`
follows the same cooperative drain).
The client waits for its listener to close and its store lock to be released
before launching the replacement with the **same** store, where active sessions
resume automatically; it never kills a PID from a manifest. The preflight is not
a full boot rehearsal of the live store or an automatic rollback. Keep the prior
bundle; if startup fails, start the known-good launcher again after correcting
the issue. An older standalone launcher or an embedded Phoenix VM does not
support this operation. For the first upgrade from an embedded server, stop it
manually once after work finishes.

An autonomous *restart later* request from an agent is not implemented. It
would need an out-of-process supervisor to own the handoff, readiness check
and rollback after the initiating turn has committed; a shell tool cannot
safely be that supervisor.

## Build or run the bundle

`cargo build` builds the client only. To package a native release from a
checkout, run this once with the pinned build tools installed (Elixir 1.20,
OTP 29, Rust, and Python 3 on macOS):

```sh
mix h.bundle dist/export
```

Then move the **entire** output directory (`dist/export` in this example) to
a stable location. Run `path/to/harness/bin/hi daemon start` without a launcher override. The sibling
`h-daemon` uses the bundled Erlang VM, Elixir, and dependency BEAMs, not Mix or
Elixir on PATH. The bundle is built for the host OS and architecture; on macOS
it includes the linked OpenSSL crypto library when using Homebrew OTP. Linux
builds still depend on compatible system native libraries. This is a native
build, not a cross-compiled or notarized installer.

The bundle's internal Erlang binaries are not put on the `PATH` seen by host
shell commands. Commands such as `mix` still need your development toolchain
on the daemon launcher's `PATH`.

The release also ships the optional `extensions/multicodex` artifact. It is
**not auto-enabled**; point your existing extension entry at that directory
if you want to use the bundled copy. No accounts, credentials, session files,
or local configuration travel with the bundle.

The bundled daemon starts Phoenix in the same VM and serves the web inbox at
<http://127.0.0.1:4200/inbox> with the same sessions as `hi`. Sign in using
`<data_dir>/auth.token`; the browser session expires on daemon restart. Set
`H_WEB_PORT` in the launcher's environment to change the port or `H_WEB=0`
to disable the web listener. If running the dev server with a different
store, use a separate browser profile (cookies are not scoped by port).

### Bind API and web to additional addresses

The launcher reads `<data_dir>/network.json` on startup. For example:

```json
{"bind_addresses": ["127.0.0.1", "10.10.10.4"]}
```

Without this file both services bind only `127.0.0.1`. Entries must be
unique literal IPv4 addresses assigned to the host, not hostnames or
wildcards. Each address gets the API (port `4100` by default) and, in the
bundle, the web inbox (port `4200` by default). Restart to apply changes.
An unavailable address prevents startup; bring up the interface or remove
its address first. `hi` still uses the local Unix socket by default and
restricts its HTTP connections to loopback.

These listeners use plain HTTP and the owner token grants access to sessions
and host tools. Bind non-loopback addresses only on a trusted, encrypted
network such as a private VPN; don't expose these ports to the internet.

For a source checkout without the bundle, use `hi daemon start --launcher
"$PWD/bin/h-daemon"` after `mix compile`.

## Releases, signing, and GitLab CI

Prebuilt signed releases target `darwin-arm64`, `linux-arm64`, and `linux-x86_64`:

- **Shell installer (`scripts/install.sh`, hosted at `/install.sh`)**: verifies
  `SHA256SUMS.sig` with `ssh-keygen -Y verify -f packaging/keys/release-signers -I bingboombam@parlant.xyz -n file`,
  verifies the archive SHA-256, extracts to `~/.local/opt/harness/releases/<id>`,
  switches `current` atomically, and links `hi` and `hi-import` into the first
  writable `PATH` bin directory (`/usr/local/bin`, `/opt/local/bin`,
  `/opt/homebrew/bin`, `~/.local/bin`, or other writable `PATH` dirs, falling
  back to `~/.bin` last; with optional `--service` for macOS LaunchAgent or
  Linux `systemd --user`).
- **Mix archive installer (`installer/`, `h_setup`)**: zero-dependency Mix
  archive (`mix archive.install hex h_setup` or `mix archive.install <url>/h_setup.ez`)
  providing `mix h.setup`, which verifies the same Ed25519 OpenSSH signature and
  SHA-256 in pure Erlang/OTP `:crypto`.
- **macOS application bundle (`H.app`, packaged as `.dmg` and `.app.zip`)**:
  built by `scripts/build-macos-app.sh` from a tested `darwin-arm64` bundle,
  embedding `Contents/Resources/harness` with a menu-bar controller for web UI
  launch, owner token copy, CLI linking, and cooperative daemon restart.
- **Multi-arch Linux builds (`Dockerfile.release`, `scripts/build-linux-bundles.sh`)**:
  uses `docker buildx` on a Debian Bookworm (glibc 2.36) baseline, vendors `libcrypto.so.3` and
  `libtinfo.so.6` into `native/` with relative `$ORIGIN` `RUNPATH` (leaving host
  `LD_LIBRARY_PATH` untouched), runs `scripts/smoke-bundle.py`, and verifies
  artifacts in clean Debian runtime containers.
- **GitLab CI (`.gitlab-ci.yml`)**: runs Elixir, Rust, installer, and website
  checks on every push, builds native `linux-x86_64`, `linux-arm64`,
  `darwin-arm64`, and `h_setup.ez` release artifacts on `v*` tags (or manually on
  branches), signs and verifies `SHA256SUMS` + `release-manifest.json`, and
  publishes to GitLab Releases (plus optional GitHub Release mirroring to
  `parlant/harness`).

## macOS per-user service

Run once in your logged-in macOS user session, from a stable bundle. With a
checkout, run `mix compile` first and add `--launcher "$PWD/bin/h-daemon"` to
the install command:

```sh
hi daemon install-service
hi daemon status
hi daemon restart-service
hi daemon uninstall-service
```

`restart-service` and `uninstall-service` cooperatively drain in-flight work
before stopping the service (pass `--idle-only` to refuse when busy) and wait for
`launchctl print` to confirm process exit before kickstarting or unloading. Stop any manually started daemon first; `hi` does not take over or signal a PID from a manifest. The service uses
that user's `~/Library/LaunchAgents`, runs at login and after abnormal exits, and writes a private log to
`<data_dir>/h-daemon.log`. It captures absolute PATH entries for the launcher,
not credential variables or build overrides from the calling shell. The data
folder must already exist, be private and owned by the user. After a failed
bootstrap the plist may remain for diagnosis; confirm it is not registered in
launchd before manually removing that file.

This does not install a root LaunchDaemon, restart an embedded Phoenix VM,
enable automatic start on normal session attach, or install build tools.
