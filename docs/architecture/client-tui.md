# Cooperative Terminal Client Architecture (`clients/tui/` — `h`)

**Status:**
- **Implemented:** Standalone Rust `h` client under `clients/tui/`. Line-oriented interaction, folder-scoped session lookup, and print mode over a Unix socket or loopback HTTP/SSE. Start the daemon separately. Use `h -s SESSION_ID` when the same folder is reached under a different path spelling.
- **Planned:** The auto-start, raw-mode renderer, richer keybindings, and completion features discussed below. Timing and binary-size figures are design estimates, not measured results.

---

## 1. Why the TUI Should Not Run Inside the BEAM VM

Prior experiments building full-screen/inline TUIs directly in Elixir on the BEAM (`~/Projects/Elixir/ethan` / `ethan_tui001`..`009`) exposed structural friction between OTP's runtime assumptions and interactive terminal control:

1. **OTP Standard I/O Contention (`user_drv`, `prim_tty`, `:group`):**
   The BEAM VM routes stdin/stdout through an Erlang I/O server hierarchy built for cooked line shells (`iex`) and concurrent process logging. Fighting `prim_tty` for raw-mode byte streams is brittle, and any unexpected OTP `Logger`, SASL, or C-library stderr write corrupts the active terminal buffer.
2. **Terminal State Hygiene (`termios`, Raw Mode, `SIGWINCH`):**
   Interactive TUIs toggle raw mode, bracketed paste (`?2004h`), Kitty keyboard flags (`CSI > u`), and cursor visibility. If a BEAM node crashes or is killed, restoring `termios` reliably requires an external native wrapper anyway; meanwhile `SIGWINCH` resize delivery through OTP's `erl_signal_server` lags native signal handling.
3. **Cold-Start Latency vs. Shell Muscle Memory:**
   Developers work in shells and `tmux` panes: `cd ~/Projects/foo && h`. Waiting 200–400 ms for a BEAM VM boot on every invocation feels sluggish compared to a **< 5 ms** native binary.
4. **Inline Scrollback vs. Alternate-Screen Traps in `tmux`:**
   The best coding-agent TUIs (like `pi`) render **differentially inline** at the bottom of the normal screen buffer—preserving native terminal/`tmux` scrollback, mouse selection, and `tmux` copy-mode—using synchronized output (`CSI ? 2026 h/l`), accurate Unicode/grapheme width tables, and multiline editing. Native TUI ecosystems (Rust, or `pi-tui` itself) solve these low-level terminal mechanics far more cleanly than OTP.

### Architectural Payoff of `H`'s Daemon Split

Because `:harness` (`H.*`) **already** runs all durability, LLM streaming, credentials, and PGID-isolated tool execution inside a long-lived BEAM daemon, **the TUI needs zero agent runtime logic of its own**. Making `h` a separate, non-BEAM subproject (`clients/tui/`) turns every BEAM weakness into a strength:
- **BEAM (`:harness`)** handles massive concurrency, fault-isolated supervision, durable commits, and Phoenix LiveView (`HWeb.*`).
- **Native TUI (`clients/tui/` -> `h`)** handles instant `< 5 ms` startup, rock-solid `termios` RAII cleanup, zero-flicker inline ANSI rendering inside `tmux`, and crisp keyboard responsiveness.

---

## 2. Cooperative Daemon Discovery & Transport

`h` and `:harness` cooperate on the same host through `<data_dir>` (default `~/.local/share/h`, `0700` permissions):

```text
┌─────────────────────────────────────┐         Unix Socket (<data_dir>/api.sock)         ┌──────────────────────────────────────┐
│   `h` TUI Process (in tmux pane)    │ ◄───────────────────────────────────────────────► │   `:harness` BEAM Daemon             │
│   • Started in developer's `pwd`    │         or Loopback HTTP/1.1 + SSE                │   (Standalone OR Phoenix Monolith)   │
│   • Zero API keys, zero DB files    │                                                   │   • Holds H.StoreLock (store.sock)   │
│   • Sends idempotent JSON commands  │  POST /api/v1/sessions/:sid/commands              │   • Runs H.Session.Server + Tools    │
│   • Renders SSE snapshot/commit/eph │  GET  /api/v1/sessions/:sid/conversations/:cid/.. │   • Broadcasts to TUI + Phoenix Web  │
└─────────────────────────────────────┘                                                   └──────────────────────────────────────┘
```

### 2.1 Transport: Unix Domain Socket (`api.sock`) + Loopback HTTP/SSE

`Bandit` natively supports binding `{:local, "<data_dir>/api.sock"}` (`0600` owner-only permissions) using the exact same `H.HTTP.Router` HTTP/1.1 JSON + SSE endpoints (`/api/v1/*`):
- **Zero TCP port discovery or port collisions.**
- **OS kernel filesystem permission boundary (`0600` inside `0700` `<data_dir>`),** plus `<data_dir>/auth.token` `Authorization: Bearer <token>`.
- Also supports remote/TCP attach (`H_DAEMON_URL=http://127.0.0.1:4100`) using the exact same HTTP/SSE client code.

### 2.2 Race-Free Auto-Start Lifecycle

When the developer runs `h` in any terminal:
1. `h` attempts `GET /api/v1/environments` over `<data_dir>/api.sock` (or configured `H_DAEMON_URL`).
2. **Already running (standalone `:harness` OR `:harness_web` Phoenix monolith):** `h` connects immediately (< 5 ms).
3. **Not running (`ENOENT` / `ECONNREFUSED`):** `h` spawns the `:harness` background daemon detached (`nohup` / setsid), polling `api.sock` with 25 ms backoff until ready. If two `tmux` panes launch `h` at the exact same millisecond, `H.StoreLock` guarantees exactly one daemon wins the lock while the loser exits cleanly and both `h` clients attach to the winner.
4. **TUI exit / `tmux` pane close / crash:** `h` simply closes its SSE socket (and restores `termios` via RAII guard). Active model streams and `bash` tools keep running uninterrupted inside `:harness`.

---

## 3. Directory-Scoped (`pwd`) Developer Workflow

Starting `h` from a shell directory mirrors `pi` while leveraging `H.Catalog`'s `{env_id: "host", cwd}` index:

| Invocation | Behavior |
|---|---|
| `cd ~/Projects/app && h` | Canonicalizes `pwd` via `/api/v1/fs`, queries `GET /api/v1/sessions?env_id=host&cwd=<pwd>`. Creates a new session in `pwd` immediately (showing a subtle header hint if past/active sessions exist for `pwd`, reachable via `/resume`). |
| `h -c` / `h --continue` | Attaches directly to the most recently updated session rooted at `pwd` (or creates one if none exists). |
| `h -r` / `h --resume` | Opens an interactive inline fuzzy picker of past & active sessions for `pwd` (showing `title`, active run status, branch count, and relative age; `Tab` toggles between `pwd`-only and all workspaces/folders). |
| `h -s <session_id>` | Attaches to a named session regardless of current shell directory (including sessions bound to a remote `ExecutionEnv`, e.g. `env_id: "vm-eu-1"`). |
| `h "Run tests and fix warnings"` | Creates/attaches session in `pwd` and immediately submits the initial prompt. |
| `h -p "Summarize git diff"` | Headless/scriptable print mode: submits prompt, streams assistant text to stdout, and exits `0` when the run settles (`done`). |

---

## 4. State Synchronization & Parity with Phoenix Web (`HWeb.*`)

`h` implements the exact same pure 3-event state reducer (`TranscriptState`) as `priv/static/transcript.js` and `HWeb.SessionLive`:

1. **`snapshot`:** Initializes `cursor_seq`, visible `entries`, `before_entry_id`, and `committed_docs` (`agent`, `live`, `inbox`, `usage`).
2. **`commit` (`id: <seq>`):** Requires `prev_seq == cursor_seq` for a newer commit (reconnects with `Last-Event-ID` or fresh snapshot on gap); flushes newly committed entries into the static scrollback/timeline above the active viewport, applies `doc_ops`, resets `ephemeral_live`, and sets `cursor_seq = seq`.
3. **`ephemeral` (no `id:`, carries `base_seq`):** Applied when `base_seq == cursor_seq`; updates the live active region (streaming thinking summary, streaming markdown text, live `bash` tail output) redrawing only the dynamic bottom viewport lines inside `CSI ? 2026 h ... CSI ? 2026 l`.

### Live Multi-Surface Co-Editing Behavior

When a developer has `h` open inside `tmux` on their workstation **and** `HWeb` open on their desktop browser or phone on the same `(session_id, conversation_id)`:
- Submitting a prompt from the phone immediately renders the user turn in `h` (`commit` event) and begins streaming the response in both views simultaneously.
- Typing a prompt in `h` while a run is busy (`Enter` -> `follow_up`, `Alt+Enter` -> `steer`) immediately shows up in the `Queued` inbox region on both Web and TUI.
- Pressing `Esc` in `h` (or tapping `Stop` on mobile) dispatches `abort` to `H.Daemon`, halting the model stream and reaping any running tool process group cleanly across both surfaces.
- Pending idempotency: before `POST /api/v1/sessions/:sid/commands`, `h` generates a UUID `request_id` and retries transient socket drops with the identical `request_id` so network blips never duplicate prompts.

---

## 5. TUI Ergonomics, Keybindings & Slash Commands

### 5.1 Inline Viewport Layout (Preserving `tmux` Scrollback)

Rather than locking the terminal in `CSI ? 1049 h` alternate screen (which breaks `tmux` scrollback and native copy/paste), `h` uses an **inline bottom viewport** pattern:
- Finalized committed entries (`user`, `assistant`, collapsed `tool_result` summaries) are printed permanently into terminal scrollback once committed.
- Only the **active dynamic region** at the bottom is differentially redrawn on resize or 50 ms `ephemeral` ticks:
  1. Active live stream (thinking indicator/preview, streaming assistant markdown, active tool spinner + bounded tail lines).
  2. Queued `inbox` items & sticky `run_failure` banner (`Press Ctrl+R or /continue to resume`).
  3. Status bar (`session_id` · `conv #cid` · `model (thinking)` · `tokens / $cost` · connection state).
  4. Multiline prompt editor (with `@path` fuzzy workspace file completion via `/api/v1/fs` and `/command` popup selector).

### 5.2 Keybindings & Local Commands

| Key / Command | Action |
|---|---|
| `Enter` | Submit prompt (`start` when idle; queue `follow_up` when busy) |
| `Shift+Enter` / `Ctrl+J` | Insert newline in multiline editor (CSI-u / Kitty + fallback) |
| `Alt+Enter` / `/steer <msg>` | Steer active run at next tool-round boundary (`when_busy: "steer"`) |
| `Esc` | Abort active run (`command: "abort"`) while keeping editor text intact |
| `Ctrl+O` | Toggle expanded/collapsed view of recent tool call outputs & diffs |
| `/model`, `/thinking` | Inline fuzzy selector backed by `GET /api/v1/models` -> `command: "configure"` |
| `/tree`, `/fork` | Browse conversation ancestry forest (`conversations`), switch branch, or fork at an earlier entry |
| `/resume`, `/new` | Switch to another session in `pwd` (or browse folders via `/cd`) |
| `/continue` | Resume after an `:interrupted`, `:model_error`, or `:turn_limit` `run_failure` |
| `Ctrl+C` (twice) / `Ctrl+D` (empty) | Detach TUI cleanly (daemon session continues in background) |

---

## 6. Implementation Stack Options for `clients/tui/`

Because the boundary between `h` and `:harness` is strictly `/api/v1/*` HTTP/JSON + SSE over `api.sock` / loopback, `clients/tui/` is completely decoupled from Elixir:

1. **Option A — Rust (`clients/tui/Cargo.toml`, Recommended Primary Path):**
   - Zero runtime dependencies; compiles to a single ~4 MB static binary `h` with `< 5 ms` startup.
   - Strict RAII `Drop` guard around `crossterm` raw mode / Kitty keyboard / bracketed paste so even panics restore the `tmux` pane cleanly.
   - `tokio` + `hyper`/`hyperlocal` (Unix domain socket HTTP/SSE) + inline differential ANSI viewport (`ratatui` `Viewport::Inline` or focused custom line-diff renderer modeled on `pi-tui`) + `similar` for colored unified diffs.
2. **Option B — TypeScript on `@mariozechner/pi-tui` (`clients/tui/package.json`):**
   - Directly reuses `pi`'s battle-tested inline differential renderer, `Editor`, `SelectList`, markdown/code blocks, and Kitty keyboard parser wired to `H`'s HTTP+SSE endpoints.
   - Fastest prototype path to exact `pi` visual parity, trade-off being a Node/Bun runtime dependency (~60–90 ms startup).

Slice 7 validates the wire UX and picks one concrete `clients/tui/` implementation (defaulting to **Rust** for zero-runtime native speed and clean `termios` lifecycle, while keeping `@mariozechner/pi-tui` as a reference for inline rendering ergonomics).
