# Local daemon management with `hi`

`hi` has two entry points in the same binary: open or resume a conversation, or
run a management command without creating a conversation. Use `-p` or `--` for a literal prompt beginning with a
reserved management word. A management command can take `--data-dir` after its
first word, e.g. `hi account list --data-dir /path/to/store`.

| Outside a session | In a session / web |
|---|---|
| `hi inbox [--tui-mode <fullscreen\|regular>] [--env ID]` | `/inbox` or `Alt+I` opens the live multi-session inbox grouped by workspace (`j`/`k` or arrows move, `Tab` cycles idle/error sessions, `Enter` opens, `n` creates a session, `Ctrl+D` returns to the inbox from a session opened through it). |
| `hi login [openai_codex [alias]]` | `/login [openai_codex [alias]]`, or sign in on Phoenix **Account settings**. |
| `hi account list` | `/account` picker, or the accounts page. |
| `hi account add <alias>` | `/account add <alias>`, or the add-alias form. |
| `hi account use <alias>` | `/account <alias>`, or **Use in stock mode**. |
| `hi daemon status` | Authenticated liveness check; no session created. Exits nonzero and reports “not running” if the endpoint is missing or refuses the connection. |
| `hi daemon start [--launcher PATH] [--no-extensions]` | Starts in the foreground. |
| `hi daemon stop` / `hi daemon restart` | Standalone only; refuses while any session has unfinished work. |
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

- `~/.bin/hi` → `~/.local/opt/harness/current/bin/hi`.
- `~/.local/opt/harness/releases/<id>` contains a complete built bundle.
  `current` selects one release for the client and daemon together.
- `~/.local/share/h` continues to hold sessions, credentials, configuration,
  and service logs. It is not part of an upgrade.

From the checkout, install a **tested** bundle once (stop any manually started
or embedded daemon first, after its work finishes):

```sh
mix h.bundle
mix h.install --service
hi daemon status
```

`mix h.install` uses the tested bundle at `dist/harness` by default. It does
not build the checkout. Pass a bundle directory explicitly to install from
another path. Make sure `~/.bin` is already on `PATH`, or pass `--bin-dir`
to use a different directory on `PATH`. `--service` installs a macOS per-user
LaunchAgent that starts at login and restarts on abnormal exit. An explicit
idle `hi daemon stop` exits successfully and stays stopped until the next
login or `hi daemon start-service`. No `sudo` or auto-build on attach. Run
`hi` from your projects as usual. For CLI-only installation, omit `--service`
and start manually. A custom `--data-dir` selects the service's store; use the
matching `H_DATA_DIR` or `--data-dir` in other terminals.

To upgrade from the checkout without picking a new path:

```sh
mix h.bundle && mix h.install
```

`mix h.bundle` builds and tests a candidate, then atomically updates the
`dist/harness` symlink. A failed build or smoke test leaves the previous
candidate selected. If an older build left a real directory at `dist/harness`,
move it aside once it is no longer in use. Older candidates remain under
`dist/.harness-builds/` and may be deleted when nothing is using them.
For an explicit artifact directory, `mix h.bundle dist/NAME` still requires
that the target not exist and does not change `dist/harness`.

Activation refuses if the existing service is busy. It validates startup
configuration, then stops the old daemon via its guarded endpoint, switches
`current` atomically, and starts the registered service. The old bundle stays
installed. The task prints the previous release ID for explicit rollback:
`mix h.install --activate <id>`. A readiness failure is reported, not forcibly
rolled back; inspect the daemon log before deciding whether to switch back.
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

`mix h.build --release` puts the terminal binary in `target/release` rather
than `target/debug`. It prints the output paths and the Phoenix dev command.
Phoenix embeds its daemon; stop the standalone daemon first or give Phoenix a
separate `H_DATA_DIR`. The standalone bundle does not include Phoenix.

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
is asked to stop. The old daemon fences new commands only after admission is
clear, checks live sessions and catalog work, and refuses if busy. On success
it exits through OTP shutdown. The client waits for its listener to close
and its store lock to be released before launching the replacement with the
**same** store; it never kills a PID
from a manifest. The preflight is not a full boot rehearsal of the live store
or an automatic rollback. Keep the prior bundle; if startup fails, start the
known-good launcher again after correcting the issue. An older standalone
launcher or an embedded Phoenix VM does not support this operation. For the
first upgrade, stop that daemon manually once after work finishes.

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
or local configuration travel with the bundle. Phoenix is still a separate
application; this bundle provides the standalone daemon and `hi` terminal client.

For a source checkout without the bundle, use `hi daemon start --launcher
"$PWD/bin/h-daemon"` after `mix compile`.

## GitLab artifact

The optional manual `bundle` job in `.gitlab-ci.yml` runs `mix h.bundle` and
retains the native output as an artifact. Assign the `h-native` tag to a runner
with the build tools installed; its OS and architecture determine the artifact.
It does not deploy or restart any daemon. The job has not been run against a
GitLab instance here.

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

`restart-service` uses guarded shutdown before asking launchd to start the
registered executable again. It does not change the registered bundle path.
Uninstall also refuses to stop a busy daemon. Stop any manually started daemon first; `hi` does not take over or signal a PID from a manifest. The service uses
that user's `~/Library/LaunchAgents`, runs at login and after abnormal exits, and writes a private log to
`<data_dir>/h-daemon.log`. It captures absolute PATH entries for the launcher,
not credential variables or build overrides from the calling shell. The data
folder must already exist, be private and owned by the user. After a failed
bootstrap the plist may remain for diagnosis; confirm it is not registered in
launchd before manually removing that file.

This does not install a root LaunchDaemon, restart an embedded Phoenix VM,
enable automatic start on normal session attach, or install build tools.
