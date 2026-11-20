# `hi` Unix PTY Acceptance Suite

Python stdlib-only PTY test suite and disposable fake H daemon for verifying `hi -s demo`.

## Files

- `fake_daemon.py` — Disposable H v1 HTTP/1.1 + chunked SSE daemon supporting Unix domain sockets (`<H_DATA_DIR>/api.sock`) and loopback TCP (`http://127.0.0.1:<port>`), bearer auth, idempotent command receipts, `steer`/`follow_up` queueing, gated streaming, and zero external/paid model calls.
- `pty_harness.py` — Unix PTY driver (`pty.openpty`, `TIOCSCTTY`, `TIOCSWINSZ`/`SIGWINCH`, raw/cooked `termios` inspection, atomic `Alt-Enter` `\x1b\r`, hangup simulation).
- `test_hi_pty.py` — Acceptance tests for `hi -s demo`:
  1. Raw mode activation and cooked mode (`ECHO|ICANON`) + private mode escape restore on `/quit`, `Ctrl-D` (empty buffer), and double `Ctrl-C`.
  2. Editing (typing, Backspace, Left-arrow cursor insertion) during an active ephemeral SSE stream without losing or corrupting the draft.
  3. `Enter` during active stream submits `when_busy: "steer"`, `when_idle: "start"`.
  4. `Alt-Enter` (`\x1b\r`) during active stream submits `when_busy: "follow_up"`.
  5. Detaching (`/quit`, `Ctrl-D`, or PTY hangup) during an active stream never sends `abort`; daemon turn completes and persists for re-attach.
  6. Window resize (`SIGWINCH`) during stream and loopback HTTP (`H_DAEMON_URL`) parity.
- `test_hi_terminal_pty.py` — Covers command cycling, inline workspace paths, local attachments, live/reloadable status templates, and terminal encoding and resize behavior in both fullscreen and regular modes.
- `test_fake_daemon_and_pty.py` — Self-tests for `FakeDaemon`, `PtySession`, and `hi -p` print wire compatibility.

## How the coordinator runs it

1. Build `hi` in `clients/tui`:

```sh
CARGO_TARGET_DIR="$(pwd)/clients/tui/target" cargo build --manifest-path clients/tui/Cargo.toml --bin hi
```

2. Run the full PTY acceptance suite requiring the `hi` binary (fail if missing):

```sh
HI_PTY_REQUIRE_BIN=1 \
HI_BIN="$(pwd)/clients/tui/target/debug/hi" \
python3 -m unittest discover -s clients/tui/tests -p 'test_*.py' -v
```

(`HI_BIN` is also auto-discovered from `CARGO_TARGET_DIR/{debug,release}/hi` or `clients/tui/target/{debug,release}/hi`, never from `PATH`.)

Without `HI_PTY_REQUIRE_BIN=1`, `test_hi_pty.py` skips cleanly when `hi` is not yet built while `test_fake_daemon_and_pty.py` runs in full.
