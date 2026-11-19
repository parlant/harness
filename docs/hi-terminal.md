# `hi` terminal validation & `pi` (`d15b2cf43`) comparison

Scope: terminal behavior of `hi` in both `--tui-mode fullscreen` (default) and `--tui-mode regular` against disposable fixtures only (`FakeDaemon`, temporary `/tmp` working directories, isolated `tmux -S` servers with `-f`, and simulated `SSH_CONNECTION` / `SSH_TTY` environment variables). No user terminal configuration is modified, no remote hosts are contacted, and no paid model calls are made.

## Automated disposable validation

Run the terminal validation script or the targeted PTY suite directly:

```sh
HI_BIN=/Users/partenkirchen/Projects/diy-harness/clients/tui/target/release/hi \
  ./scripts/hi-terminal-validate.sh
```

Or run only the terminal-specific suite (`clients/tui/tests/test_hi_terminal_pty.py`):

```sh
HI_PTY_REQUIRE_BIN=1 \
HI_BIN=/Users/partenkirchen/Projects/diy-harness/clients/tui/target/release/hi \
  python3 -m unittest clients/tui/tests/test_hi_terminal_pty.py -v
```

What the automated suite exercises in both `fullscreen` and `regular` modes:

- **Selection & completion:** `/` + `Tab` in-place command completion and `check su` + `Tab` session-path completion (`Esc` restores the typed prefix without `abort`), `/attach <prefix>` + `Tab` client-local file completion with directory drilldown (`sub/` -> `nested.rs`) and attachment, `regular` mode omitting alt-screen (`\x1b[?1049h`) and mouse capture (`\x1b[?1000h`..`\x1b[?1006h`) so native terminal selection works, `fullscreen` mode balancing alt-screen + mouse capture on exit, and `/copy` emitting UTF-8 OSC 52 (`\x1b]52;c;...`).
- **Configurable status lines:** [Templates](hi-status.md) append to or replace the inherited footer, update with live provider/model state, and reload atomically with keybindings in both modes.
- **Inline model & help:** `/help`, `/model`, `Ctrl+L`, `/thinking`, and `/hotkeys` rendered inline in the 7-row editor band while preserving CJK transcript rows above across `SIGWINCH` resizes, `configure` sending `expected_seq`, and `409 Conflict` surfacing cleanly.
- **Isolated `tmux` & simulated SSH:** disposable `tmux -S <tmpdir-socket> -f <tmpconf>` servers with `SSH_CONNECTION`/`SSH_TTY` (`Shift+Enter` `\x1b[13;2u`, `Alt+Enter` `\x1b[13;3u` and `\x1b\r`, `Ctrl+J`, and `/follow-up`), split-ESC packet gap behavior (`\x1b` + 50 ms + `\r`), PTY hangup detach without `abort`, and `TERM=dumb` cooked fallback.
- **Composed Unicode:** NFD combining marks (`e\u{0301}`), NFC (`é`), ZWJ emoji (`👨‍💻`, `🏳️‍🌈`), skin-tone modifiers (`👍🏻`), flag pairs (`🇨🇳`, `🇺🇸`) and partial singleton (`🇨`), CJK (`你好`, `让`), grapheme-atomic `Left` + `Backspace`, exact hardware cursor column emission (`\x1b[row;colH` in fullscreen, `\x1b[colG` in regular), bracketed paste (`\x1b[200~...\x1b[201~`) containing `\n/quit`, and narrow resizes.

### Tab completion in the editor

- At the very start of the draft, `/` + `Tab` shows the command list and inserts the first match. `/h` + `Tab` offers `/help` and `/hotkeys`. Press `Tab` again to cycle; `Esc` restores the original token. `/help` still opens the searchable command palette.
- Elsewhere, `Tab` completes the whitespace-delimited token at the cursor against the session’s working directory. Use `/` for absolute paths after another word, or `./`, `../`, and `dir/` for relative paths. Explicit paths match files and directories; a bare prefix like `sr` only matches directories. No match leaves the draft alone.
- Directories end in `/`. If there’s one directory match, another `Tab` lists its contents. If there are several, cycle to the one you want, press `Right` to keep it, then `Tab` to list its contents. Completion inserts text only; it does not run commands or attach files.

## Comparison against `~/Projects/JavaScript/pi` at `d15b2cf43`

| Area | `pi` (`d15b2cf43`) | `hi` (observed behavior in both modes) | Operational implication |
|---|---|---|---|
| **Slash, path & `@file` completion** | Typing `/` or `@` opens autocomplete immediately (`packages/tui/src/autocomplete.ts`); `@` uses `fd` or local walk; supports extension/template argument completion. | `Tab` completes the token at the cursor and cycles through matches. `@prefix` opens the session file picker; `/attach prefix` opens the client-local picker. | Use inline path completion to insert a path as text, or a file picker to attach its contents. |
| **Transcript selection & copy** | `tui-alt-screen.ts` implements in-app char/word/line mouse selection with `/` and `-` word joiners; `tui-main-screen.ts` leaves selection to terminal; `/copy` copies last reply. | `regular` leaves mouse/scrollback to the native terminal. `fullscreen` enables Crossterm mouse capture for wheel scrolling only (no in-app mouse drag selection); `/copy` (`Ctrl+X`) emits OSC 52. | Use `--tui-mode regular`, `Shift+drag` / `Option+drag` terminal override, or `/copy` (`Ctrl+X`) in `fullscreen`. |
| **Inline model / help pickers** | Modal/overlay components (`ModelSelectorComponent`, `SettingsSelectorComponent`) composited over the viewport with `CURSOR_MARKER` tracking (`tui.ts`). | Inline 7-row picker (`1` search row + `6` items) in the editor band (`screen.rs` `render_editor_area`), preserving transcript lines above. Hardware cursor is hidden while picker is open. `/model` sends `configure` with `expected_seq`. | Transcript rows (including CJK) stay intact above the picker; concurrent model edits report `409 conflict` instead of silent overwrite. |
| **`tmux` extended keys** | `packages/coding-agent/docs/tmux.md` recommends `set -g extended-keys on` + `extended-keys-format csi-u`; `terminal.ts` queries Kitty flags and falls back to xterm `modifyOtherKeys`. | Crossterm pushes Kitty `DISAMBIGUATE_ESCAPE_CODES` (`\x1b[>1u`) without `modifyOtherKeys`. Under `tmux 3.8` with `extended-keys on` alone (when outer terminal didn't negotiate Kitty), tmux downgrades `Shift+Enter` to `\r`; `extended-keys always` + `extended-keys-format csi-u` forwards `\x1b[13;2u` and `\x1b[13;3u`. | Set `set -g extended-keys always` and `set -g extended-keys-format csi-u` in tmux 3.5+, or use `Ctrl+J` (newline) and `/follow-up` (queued follow-up). |
| **SSH split-ESC & exit drain** | `StdinBuffer` (`terminal.ts`) waits `100 ms` when `SSH_CONNECTION`/`SSH_TTY` is set (`PI_TUI_ESC_TIMEOUT`), and drains stdin up to `1000 ms` on exit so Kitty key releases don't leak to the shell. | Crossterm dispatches a lone `\x1b` immediately when `\x1b` and `\r` arrive 50 ms apart (`Alt+Enter` splits into `Esc` abort + `Enter` steer). No SSH-specific escape reassembly delay or exit drain. | Over high-latency SSH, prefer CSI-u `Alt+Enter` (`\x1b[13;3u`) or `/follow-up <text>` rather than raw `\x1b\r` while a run is active. |
| **Composed Unicode & cursor** | Custom `visibleWidth` + `sliceByColumn` + `CURSOR_MARKER` (`utils.ts`, `regression-regional-indicator-width.test.ts`, `regression-overlay-cjk-boundary.test.ts`). | `unicode-segmentation` + `unicode-width` with explicit regional-indicator singleton (`🇨`) and ZWJ/VS16 width-2 rules (`screen.rs`), plus padding space cell in `Buffer`. Hardware cursor placed directly at focused editor cell. | Both `fullscreen` and `regular` keep grapheme edits atomic and cursor columns aligned on tested ASCII/NFD/CJK/ZWJ/flag clusters. |

## Items that require a person (cannot be proven in PTY automation)

PTY tests inject UTF-8 bytes and inspect escape sequences; they cannot render pixels, drive OS input methods, or traverse real WAN TCP/SSH stacks. A human operator must verify:

1. **Live OS IME preedit & candidate window placement**
   - Preedit underline / uncommitted composition text (macOS Kotoeri/Japanese, Pinyin, Korean 2-Set, Linux IBus/fcitx5) before commit.
   - Candidate popup tracking the hardware cursor on wrapped lines, multi-line drafts, and narrow panes in **both** `--tui-mode fullscreen` and `--tui-mode regular` (and confirming expected behavior when an inline picker hides the hardware cursor).
2. **macOS `Option`/dead-key composition vs `Alt` bindings**
   - `Option+e` `e` (`é`) vs `Option+Enter` (`Alt+Enter` follow-up) and `Option+B`/`F`/`D`/`Y` across your actual terminal settings (iTerm2 Left/Right Option = `Esc+`, Ghostty `macos-option-as-alt`, Kitty `macos_option_as_alt`, WezTerm `SendString('\x1b[13;3u')`, Alacritty).
3. **Real terminal font & glyph-width rendering**
   - Visual inspection that `é`, `你好`, `👨‍💻`, `🏳️‍🌈`, `👍🏻`, `🇨🇳`, `⚡️`, and partial streaming `🇨` do not overlap, clip, or drift against the cursor in your terminal font (especially `fullscreen` vs `regular` tail redraws).
4. **Real multi-hop SSH + outer `tmux` behavior**
   - Actual high-latency SSH (`ssh -t <host>`): whether `Alt+Enter` splits into `Esc` (abort) + `Enter`, whether exiting `hi` leaks any Kitty key-release bytes into the remote shell prompt, and whether `SIGHUP` from a dropped SSH session leaves the remote daemon turn running cleanly for re-attach.
5. **Native mouse, wheel speed, and OSC 52 clipboard policy**
   - Fullscreen trackpad wheel speed (e.g., iTerm2 *Trackpad scrolls fast?*), `Shift+drag` / `Option+drag` native text selection override in fullscreen, plain drag selection in regular mode during active streaming, and `/copy` (`Ctrl+X`) actually updating the OS clipboard (including `tmux` `set -g set-clipboard on` and terminal OSC 52 permissions).

## Actionable steps for human verification

Run these against a disposable local or test-host daemon session (never a production session):

1. **IME & composed Unicode (`fullscreen` and `regular`):**
   - Launch `hi -s <disposable-id> --tui-mode fullscreen`, then repeat with `--tui-mode regular`.
   - Switch to an IME (e.g. Japanese/Pinyin/Korean), type a multi-syllable composition on row 1 and again after wrapping past column 80: confirm preedit renders cleanly and the candidate window appears beside the cursor without obscuring typed text.
   - Commit `é 你好 👨‍💻 🏳️‍🌈 👍🏻 🇨🇳`, press `Left` twice and `Backspace` once, and confirm `👨‍💻` is deleted atomically with no leftover half-cell artifacts.
2. **Inline model, help & `@` completion under load:**
   - Trigger a long streaming reply containing CJK text, press `Ctrl+L`, type a partial `provider/model`, resize the window smaller and back larger, then press `Esc` (verify the stream continues uninterrupted).
   - Type `@` + prefix + `Tab`, drill into a subdirectory, press `Esc`, then `/help` and `/hotkeys`.
3. **SSH + `tmux` verification:**
   - In your `~/.tmux.conf` (tmux 3.5+), verify `set -g extended-keys always` and `set -g extended-keys-format csi-u` (or rely on `Ctrl+J` and `/follow-up`), restart tmux, and inside `ssh -t <host> tmux`:
     - Verify `Shift+Enter` (or `Ctrl+J`) inserts a newline, `Enter` submits/steers, and `/follow-up <text>` (or CSI-u `Alt+Enter`) queues a follow-up during an active stream without triggering `Esc` abort.
     - Run `/copy` on a Unicode reply and paste into another local app to confirm OSC 52 is enabled end-to-end.
     - Drop the SSH client (`~.`) mid-stream, reconnect, and run `hi -s <disposable-id>` to confirm the turn completed without abort.
4. **Selection & scrollback in both modes:**
   - In `--tui-mode regular`, drag-select text across flushed scrollback while a stream is running and copy with your terminal shortcut.
   - In `--tui-mode fullscreen`, scroll with trackpad/wheel and `PageUp`/`PageDown`, and select text with your terminal's mouse-bypass modifier (`Shift+drag` or `Option+drag`).
