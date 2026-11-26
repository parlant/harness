---
layout: doc
title: 'H v0.4.0 release walkthrough'
description: 'Explore coordinator-parked tool approvals and external wake signals, guarded run budgets, HTTP remote execution, HWeb.Backend.HTTP, and startup extension seams in H v0.4.0.'
lang: en
permalink: /releases/v0.4.0/
---
H `v0.4.0` extends the `:harness` OTP daemon, the `hi` Rust terminal client, and the `hiweb` Phoenix workbench while preserving the four-package core dependency tree (`bandit`, `plug`, `req`, `req_llm`). Install the signed release from [hiness.dev/#install](/#install) or inspect the [release artifacts and checksums](/releases/#v0-4-0).

* Contents
{:toc}

## Park tool approvals and external signals in the coordinator

Set an approval policy per conversation with `/approval mutating` in `hi` or the **Approval policy** selector in `hiweb`. Before acquiring a workspace writer lease or spawning a `Task.Supervisor` worker, `H.Session.Server` commits a waiting checkpoint (`wake: {"on": "approval"}`) and publishes the pending call in `live.approvals`. Review the arguments in `hi` or `hiweb` and send `/approve` or `/deny` to continue. Across an unexpected crash or `SIGKILL` restart, unapproved mutating calls stay parked on disk and wait for explicit owner confirmation.

External automation and CI scripts can wake a session through `POST /api/v1/sessions/:sid/signals` with a `request_id`, a `topic`, and a JSON `payload` up to 16 KiB. Inside a turn, the `wait_signal` tool consumes a queued signal immediately or parks the task in `H.Session.Server` with zero worker processes until a matching signal arrives or `timeout_ms` expires.

[Inspect session protocol commands and signals](/docs/protocol/).

## Bound unattended runs and cancel individual tasks

Configure a per-run budget with `/budget turns=10 cost=2.00 elapsed=300s` in `hi` or the budget form in `hiweb`. `H.Session.Server` checks turn count, cumulative run cost, and elapsed time at turn boundaries. When a run reaches a limit, H settles active tool results, records `live.run_failure.reason = "budget_exceeded"`, marks the session for operator attention in the inbox, and lets you resume with `/continue` under a fresh run window.

Pass a `task_id` to `/abort <task_id>` (or click **Abort** on a running tool or subagent card in `hiweb`) to cancel one child `tool_call` or delegated subagent while sibling parallel subagents keep running.

[Configure conversation budgets and policies](/docs/configuration/).

## Execute tools on a standalone remote agent

Start a standalone execution agent in a container, VM, or companion host over loopback TCP, a private VPN, or a Unix domain socket:

```sh
h-daemon remote-agent --cwd /srv/workspace --id sandbox --bind 127.0.0.1 --port 4300 --token-file /etc/h/agent.token
```

`H.RemoteAgent.HTTP` authenticates every `/v1/*` request in constant time (`Plug.Crypto.secure_compare/2` over SHA-256 digests) and enforces `{session_id, incarnation, task_id, attempt_id}` fences before spawning an OS process. `H.RemoteAgent.Client` streams base64 output chunks over NDJSON and renews execution leases on a background heartbeat. If the network drops or the brain daemon crashes mid-command, lease expiry reaps the remote OS process group (`SIGTERM` followed by `SIGKILL`), and the restarted session coordinator marks the interrupted command without replaying it.

[Review execution boundaries](/docs/architecture/#boundaries-that-arent-sandboxes).

## Run hiweb outside the daemon VM

Set `H_WEB_BACKEND=http` (or configure `:harness_web, :backend, HWeb.Backend.HTTP`) to connect `hiweb` to a separate `h-daemon` process over `<data_dir>/api.sock` or loopback HTTP. `HWeb.Backend.HTTP` supervises `:catalog` and `:conversation` SSE bridges so `InboxLive`, `WorkspaceLive`, `SessionLive`, `ReviewLive`, `AccountsLive`, and `ProvidersLive` stream live frames without sharing a BEAM node with the daemon.

[Explore the web workbench guide](/docs/web/).

## Startup extension seams and the EditorHost package

Extensions load at daemon startup (`H.Extension` API 1) from `<data_dir>/extensions.json`:

- Query `GET /api/v1/harnesses` or run `hi --harness <id>` and `/harness` to pick a registered `H.Harness` profile when creating a session.
- Implement `H.Extension.Observer` (`command_committed/1`, `work_settled/1`) to receive sanitized post-commit summaries in a bounded, non-blocking consumer process off `H.Session.Server`.
- Implement optional `H.Harness` callbacks `prepare_context/2` (evaluated inside the inference worker, failing closed on error or timeout) and `project_response/2` (post-turn annotation).
- Implement optional `H.ExecutionEnv` callbacks `admit_exec/2` (pre-launch gate that can deny execution or tighten resource limits) and `operation_finished/2` (sanitized timing metrics).
- Enable `"extension_status": true` in `<data_dir>/hi.json` to render cached scalar projections from `GET /api/v1/sessions/:sid/conversations/:cid/extension-status` (including `MultiCodex` `account_pool` headroom) in MiniJinja status templates.
- Enable the bundled [EditorHost extension](/extensions/editor-host/) to pair a live editor process using a short-lived single-claim grant and read unsaved buffer summaries through `editor_buffer_summary` with an `expected_revision` check.

[Author a startup extension](/docs/extensions/) or [browse bundled extensions](/extensions/).

## Complete the daily hi terminal workflow

`hi` adds credential removal (`hi logout`, `hi key remove`, `/logout`, and `/key remove`), user-authored JSON themes under `<data_dir>/themes/<name>.json` with atomic `/reload` rollback, reusable markdown prompt templates under `<data_dir>/prompts/<name>.md` invoked via `/prompt:<name>`, and validated inline PNG/JPEG image previews in `--tui-mode regular` on Kitty, Ghostty, iTerm2, and WezTerm (with text captions in fullscreen alternate-screen mode).

[Customize the hi terminal client](/docs/terminal/).
