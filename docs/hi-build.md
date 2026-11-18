# hi build sequence

Target: pinned pi coding-agent and pi-tui in [the parity ledger](hi.md). Harness selection, third-party backends, tool hosting and their packaging are deferred. They are **not** prerequisites for terminal cutover. No changes in the reference checkout.

1. **Freeze interfaces and isolate work.** Keep `h` and print compatibility. One feature branch, one worktree per lane, private Cargo/Mix build outputs. Only integration owns Cargo manifests, module declarations, CLI wiring and docs. Assign a separate interactive pi window per lane; pin `google-vertex/gemini-4-hydrogen:high` and request Priority PayGo in each before sending work.
2. **Parallel foundation.** Editor (Unicode readline actions); terminal (mode guard/layout/scroll); cards (transcript presentation); stream (cancellable reconnection); selectors (focused pickers and dispatch); acceptance (PTY scripted fake-daemon journeys). Each lane checks the original pi behavior and tests the corresponding H invariants. Integration owns the event loop combining them.
3. **Reconcile, then parallelize daily workflows.** Review each commit before integrating. Run Cargo suite and real daemon/Phoenix sync, then exercise editing during stream, steer vs follow-up, detach, resize, disconnect and fork. Layer regular mode, external editor, searchable history, settings/keybindings, environment file completion and attachments around the verified loop. Shared server operations (withdrawal, rename, user shell, compaction) require separate dependency-ordered changes and restart/conflict tests; never fake them in the UI.
4. **Cutover audit.** Compare the ledger row by row against pi at the pin, classify implemented/partial/not shipped, port required user workflows and verify both terminal modes. Validate clean install, migration and rollback. Actual daily-driver trial and performance/terminal matrix are release gates, not unit-test results. Keep `h` until the cutover gate passes.

## First batch: module contracts

Paths below are inside `clients/tui/src`. Modules use `crate::client`, `crate::protocol`, `crate::transcript`, `crate::render` for existing code. The coordinator wires `hi/mod.rs` and `cli.rs`; lanes should not add dependencies independently. Shared dependencies: Crossterm 0.28, Ratatui 0.29, unicode-segmentation 1, unicode-width 0.2 (resolve compatible lock).

| Lane / owned files | Required Rust boundary |
|---|---|
| editor · `hi/editor.rs` | `Editor: Default`; `text(&self)->&str`, `cursor(&self)->usize` (UTF-8 byte boundary), `set(&mut self,&str)`, `key(&mut self,KeyEvent)->bool`, `paste(&mut self,&str)`, `submitted(&mut self)` records then clears. App owns submit, Esc, Ctrl-C, Ctrl-D when empty, Ctrl-G, Alt-Enter; editor handles Ctrl-J/Shift-Enter. |
| terminal · `hi/screen.rs` | `Screen::open()->io::Result<Self>`; `draw(&mut self, rows:&[String], editor:&str, cursor:usize, status:&str, overlay:&[String])->io::Result<()>`; `scroll(&mut self, lines:i32)` positive toward older; `bottom(&mut self)`. Renderer handles wrapping, draft cursor placement, resize and safe terminal cleanup; app polls Crossterm. Inputs considered untrusted except renderer-owned spans. |
| cards · `hi/cards.rs` | `rows(state:&TranscriptState, tools_expanded:bool, thinking_expanded:bool)->Vec<String>` sanitizes transcript/live/tool/queue/error data; no ANSI. Must use H's real storage/stream shapes. |
| stream · `hi/stream.rs`, minimal additions to `client.rs`, `protocol.rs` for bounds | `Subscription::start(client:DaemonClient,sid:String,cid:String,from:Option<u64>)->Self`; `next(&self)->Option<Update>` nonblocking, `Update::{Frame(ServerFrame), Offline(String), Online}`. Drop cancels/unblocks. Reconnect from last delivered durable seq (never ephemeral); UI drops/restarts on reducer gap. |
| selector · `hi/picker.rs` | `Picker::new(title:&str, choices:Vec<(String,String)>)->Self` (ID,label); `lines(&self)->Vec<String>`; `key(&mut self,KeyEvent)->Choice`, `Choice::{Stay,Cancel,Pick(String)}`. Searchable, keyboard-first, no focus escape to draft; reusable for model/session/branch/commands. |
| pty · `clients/tui/tests/` | Unix PTY test(s) exercising actual `hi -s demo` against disposable fake daemon (UDS or loopback with temporary H_DATA_DIR). Check raw restore, edit during stream, detach/no abort, Enter `steer`, Alt-Enter `follow_up`; no paid model in tests. May use Python stdlib + documented invocation, no extra system dependencies besides Python. |

The coordinator retains ownership of branch merges, process cleanup and release claims. A lane commit alone is not acceptance.
