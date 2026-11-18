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

## Remaining work (not shipped)

- **Client follow-ons:** raw-mode terminal editing and viewport; an HTTP backend if Phoenix needs to run outside the daemon VM.
- **Remote transport:** choose an authenticated transport, deploy a separate agent, and verify disconnect, lease expiry and ambiguous unsafe effects across an actual network boundary.
- **Slice 9 — long-running sessions:** automate append-only compaction and handoff. `H.Context` already interprets `compaction` and `reset` entries; that is not a summarization worker or a client command.
- **Slice 9 — suspendable work:** subagent joins, durable external signals, parked tools, approval gates and a wake scheduler. Existing generation retries and tool tasks are not a general workflow engine.
- **Slice 9 — relational storage:** an optional `H.Storage.SQLite` backend behind the existing storage conformance suite. No database dependency is required today.
