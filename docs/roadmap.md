# Roadmap

## Implemented scope

| Slice | What exists | Where to check |
|---|---|---|
| 0–1 · History and storage | Forked conversations, memory/file stores, catalog, per-session coordinator, commit receipts and restart recovery. | [Storage contract](../lib/h/storage.ex) · [session tests](../test/h/session_server_test.exs) |
| 2 · Local daemon | Owner-authenticated HTTP/JSON and SSE over loopback. | [Protocol](protocol.md) · [SSE tests](../test/h/http_sse_test.exs) |
| 3 · Generation | ReqLLM adapter, model catalog, context projection, streaming and retry accounting. | [Provider](../lib/h/provider/req_llm.ex) · [generation recovery](../test/h/generation_recovery_test.exs) |
| 4 · Coding loop | Browser-accessible read, write, edit, shell and history tools with replay policy and workspace leases. | [Integration test](../test/h/full_stack_integration_test.exs) |
| 5 · Workspaces | Environment-qualified directory browser and session lookup, coding harness bootstrap and Unix API socket. | [Workspace integration](../test/h/workspace_browser_integration_test.exs) |
| 6 · Phoenix | Responsive workspace and session LiveViews; direct in-VM backend, paged history and branch controls. | [Web client](../clients/web/) · [LiveView tests](../clients/web/test/h_web/live/) |
| 7 · Terminal | Rust `h` attaches, resumes, streams and submits in line-oriented or print mode. No raw-mode viewport or daemon auto-start. | [CLI](../clients/tui/src/main.rs) · [cross-client test](../clients/web/test/h_web/live/multi_surface_sync_test.exs) |
| 8 · Remote prototype | In-VM agent and execution adapter with fences and heartbeat leases. Not a deployed remote service. | [Agent tests](../test/h/remote_agent_test.exs) · [adapter tests](../test/h/execution_env_remote_test.exs) |

## Next vertical slice — hi replaces pi (planned)

Priority over remote deployment, SQLite and general suspendable workflows. See the [pi parity ledger, editor contract and Rust decisions](hi.md) and [profile/tool-host packaging](hi-extensions.md). Each milestone ends in a usable workflow, not a new framework.

| Gate | Deliverable and dependencies | Evidence to exit |
|---|---|---|
| H0 · Freeze the target | Pair a pi user and contributor: record representative launch → edit → tool → follow-up → fork → resume journeys at the pinned checkout. Inventory required local commands, skills, input bindings, extensions, scripts and terminal modes **without copying private sessions or secrets**. Mark each ledger item required, intentionally different, or optional with user sign-off. Spike widget vs pure editor and fullscreen vs inline redraw on fake SSE. | Replay same key/event fixtures in a PTY; choose editor and renderer from cursor accuracy, cleanup and typing under streaming load. Record baseline timings, terminal/OS, versions, licenses, MSRV and binary sizes before pinning crates. |
| H1 · First usable hi | On v1 only: preserve `h` and headless behavior; add `hi` with a fixed editor/footer and live transcript. Create/attach, multiline edit/paste, submit, see a real daemon tool result via fake provider, steer/follow up, detach and reattach. Cancellable subscription and bounded reconnect belong here, not after polish. | PTY types during a tool stream, exits without abort, reconnects through ring replay and snapshot fallback; Phoenix sees exactly the same committed entries. No keystroke loss, duplicate submissions or raw terminal left behind on normal error. |
| H2 · Daily terminal ergonomics | Complete readline action set, regular scrollback mode, searchable overlays, hotkeys/themes, external editor, syntax/diff rendering, expansions, copy/selection, search/prompt jumps, mouse and degraded modes. Add a fixture for every required H0 action. | Golden cell buffers + actual PTY (not screenshots alone): narrow/wide resize, paste burst, Unicode, focus, suspend/fg, panic cleanup; manual IME, Kitty/legacy keys, tmux and SSH. On a recorded 10k-entry paged trace with streaming updates, target p95 key-to-paint <50 ms on a named reference machine; memory bounded by configured page/output limits, not total session length. Publish observations, not a language benchmark. |
| H3 · Full working session | Workspace/session/model selectors, tree, fork-and-edit, rich tool and failure states. Add only ledger-proven missing operations (e.g. guarded dequeue, env file completion, session naming, user shell, compaction). Each new shared operation gets a daemon owner, idempotency/conflict rules and a v1-compatible optional capability before a binding. | Two clients race configure/queue/navigate; kill daemon during safe and unsafe tools; no stale updates across branch switch or replay of unsafe work. Run large-session, attachment and context-limit scenarios; compare required results to H0. |
| H4 · Workflow migration | Port required terminal workflows using built-in H capabilities and client-side preferences. Harness selection, tool hosting and packaging are deferred, not prerequisites for cutover. | Exercise the required workflows without a third-party daemon package. Track any that cannot migrate yet as explicit gaps. |
| H5 · Cutover | Package locked binaries for supported macOS/Linux targets and document daemon install/discovery, first-run credentials, config/keymap migration, pi session export/import limits and rollback. Keep `h` scripts stable; test invocation/flags separately from `hi` (pi positional prompts are not an excuse to break `h` print). | Complete required H0 journeys on the user's actual terminal for a working week without falling back to pi. Track each fallback against a ledger row; no open required workflows, ambiguous writes or terminal corruption. Only then recommend `hi` as default. Don't alias over `pi` or modify its store; rollback by launching pi again, not by pointing it at H storage. |

See the [grouped implementation steps and ownership boundaries](hi-build.md). Start with **H1's narrow end-to-end path after H0**, not an extension broker or a complete UI toolkit. Keep `cargo test --locked` green in `clients/tui`; extend the [native/Phoenix sync test](../clients/web/test/h_web/live/multi_surface_sync_test.exs) rather than mocking both ends. New daemon behavior must also pass its root Mix tests with disposable storage/fake provider. A successful demo is not a replacement release.

## Other remaining work (not shipped)

- **Web:** an HTTP backend if Phoenix needs to run outside the daemon VM.
- **Remote transport:** choose an authenticated transport, deploy a separate agent, and verify disconnect, lease expiry and ambiguous unsafe effects across an actual network boundary.
- **Slice 9 — long-running sessions:** automate append-only compaction and handoff. `H.Context` already interprets `compaction` and `reset` entries; that is not a summarization worker or a client command.
- **Slice 9 — suspendable work:** subagent joins, durable external signals, parked tools, approval gates and a wake scheduler. Existing generation retries and tool tasks are not a general workflow engine.
- **Slice 9 — relational storage:** an optional `H.Storage.SQLite` backend behind the existing storage conformance suite. No database dependency is required today.
