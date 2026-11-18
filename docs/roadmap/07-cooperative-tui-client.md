# Slice 7: Cooperative Non-BEAM Terminal Client (`clients/tui/` — `h`)

**Prerequisite:** Slice 5 (`GET /api/v1/fs`, `GET /api/v1/sessions?cwd=...`, `<data_dir>/api.sock` Unix-socket listener). Can run in parallel with Slice 6 (`clients/web/`).
**Architecture:** [`docs/architecture/client-tui.md`](../architecture/client-tui.md)

---

## 1. Goal

Build a fast (`< 5 ms` startup), rock-solid **non-BEAM** terminal UI subproject in `clients/tui/` (compiling to the `h` CLI binary) that avoids OTP `prim_tty`/`Logger`/`termios` pitfalls and cooperates with `:harness` over `<data_dir>/api.sock` (or loopback HTTP/SSE)—staying synchronized in real time with `HWeb.*` whenever both are attached to the same session.

---

## 2. Scope

1. **Subproject Setup (`clients/tui/`):**
   - Dedicated Rust Cargo project (`clients/tui/Cargo.toml`, producing `h`) with RAII `Drop` `termios`/raw-mode/bracketed-paste/Kitty-keyboard cleanup and `SIGWINCH` handling.
2. **Daemon Discovery & Auto-Bootstrap:**
   - Connects to `<data_dir>/api.sock` with `Authorization: Bearer <auth.token>` (or `H_DAEMON_URL`).
   - Auto-spawns detached `:harness` daemon when no server holds `H.StoreLock`, and attaches transparently when either standalone `:harness` or the `clients/web` Phoenix monolith is already running.
3. **`pwd`-Scoped Shell & `tmux` Entry Modes:**
   - `h` (new session in `pwd` with hint if past folder sessions exist), `h -c` / `--continue` (latest session in `pwd`), `h -r` / `--resume` (inline fuzzy session/folder picker), `h -s <sid>`, and `h -p "<prompt>"` (scriptable print mode).
4. **Inline Scrollback Viewport & Live Multi-Surface Sync:**
   - Pure `TranscriptState` reducer (`snapshot`, `seq`-fenced `commit`, `base_seq`-fenced `ephemeral`) flushing committed turns into native terminal/`tmux` scrollback while differentially redrawing only the active live stream, status bar, and multiline editor inside `CSI ? 2026 h/l`.
   - Full command support: `Enter` (`start` / `follow_up`), `Alt+Enter` (`steer`), `Esc` (`abort`), `/model`, `/thinking`, `/tree`, `/fork`, `/resume`, `/continue`, and `@path` file completion.
5. **Verification:**
   - Unit tests for SSE frame parsing, `TranscriptState` gap/resnapshot convergence, editor operations, and differential viewport rendering, plus an automated integration test running `h` + a simultaneous HTTP/Web subscriber against a disposable `:harness` daemon.
