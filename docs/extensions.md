# Extensions

This is the entry point for extending H. **Existing** sections describe code you can use or test today. **Proposed** sections are design contracts to review, not APIs, route guarantees, or release commitments. For managed and manual Codex setup, see [provider setup](providers.md).

## Choose the smallest boundary that owns the behavior

| I want to… | Start here | Status |
|---|---|---|
| Install a local package and enable it for a daemon | [Daemon composition and core hooks](extensions/daemon.md) | Startup loading, post-commit advisory observers (`command_committed`, `work_settled`), bypass flag, and developer template exist |
| Change instructions, context, or tool set without replacing the session engine | [Harness profiles and tools](extensions/harness.md) | Behaviours, `GET /api/v1/harnesses` discovery, and optional `prepare_context/2` / `project_response/2` callbacks exist |
| Change where or under what constraints tools operate | [Execution environments](extensions/execution-env.md) | Environment behaviour, registry, HTTP/UDS `H.RemoteAgent.HTTP`, and optional `admit_exec/2` / `operation_finished/2` callbacks exist |
| Log a daemon into Codex or use multiple credential sources | [Providers](extensions/providers.md) | Stock device login & logout; MultiCodex path policy polls usage, ranks eligible aliases, and projects cached `account_pool` status |
| Show package status or initiate a daemon operation from `hi`, or extend `hiweb` | [Clients](extensions/clients.md) | Local status templates, opt-in `extension_status` footer polling, custom JSON themes, prompt templates, device login/logout, and `:web` extensions in `hiweb` exist |
| Use a live editor capability or a completely different agent runtime | [External integrations](extensions/external-integrations.md) | Optional `extensions/editor_host` live tool-host broker exists; alternate agent runtimes remain separate |

## First principles

1. **Put policy where it has the facts and authority.** The adapter knows whether an inference request was accepted; the environment knows whether it can launch a process; the coordinator alone can commit session state. The client collects explicit user intent and renders views. For example, a provider credential selector can choose an account, but it cannot re-run a tool or change the transcript.
2. **Installation, activation, and use are different.** Authors build trusted extension artifacts; operators select explicit local paths at daemon boot. A client can select exposed IDs, not packages, modules or filesystem paths. A model or checkout cannot enable executable code. In-VM packages run with daemon authority; an API limit or callback deadline is not a sandbox.
3. **Commit first; replay only under a recorded policy.** The session single writer owns validation, intent, outcomes and fencing. A hook does not run inside a commit or act as a second writer. A lost worker, observer or socket does not authorize another external effect. A fork copies a view of history, not accounts, subscriptions, pending effects or package processes. See [architecture](architecture.md).
4. **Choose a contract before choosing a hook.** Prefer data config, then an existing behaviour, then an explicit decorator. Add a callback only where the caller needs a new decision or projection. Use an ordinary client protocol for cross-process interaction. Do not add an event bus, hot loader, middleware stack, generic state store or scripting ABI in anticipation of future use.
5. **Keep kinds of state separate.** The session journal holds validated domain data and replay policy; a package may own its own supervised runtime state and versioned storage. Credentials go only in a dedicated credential store. Status is disposable and sanitized. Display, selection and keybindings are local to a client. Treat process, attempt and transport handles as runtime-only.

### What “hook” means here

A hook is a call site with one owner, purpose, and stated guarantees, not permission to subscribe to arbitrary internals. A proposed hook must specify its scope, version, inputs, legal outputs, caller and timing relative to commit, bounds and cancellation, missing/failure behavior, and restart semantics. A decision has one configured authority and fails closed on a missing required implementation. A projection may be omitted on failure. An observation cannot alter a result; unless explicitly designed for durable delivery it may be lost or repeated. Owner actions are explicit requests with their own authorization and lifetime, not observers. No implicit ordering between unrelated extensions.

## Audit verdict: what to retain or change

| Earlier idea | Refined decision |
|---|---|
| Load path packages from an H config file | Load explicitly selected, prebuilt local artifacts at daemon startup (`<data_dir>/extensions.json`, `H.Extension` API 1). No BEAM hot-reloading, no custom Mix project for operators, no workspace discovery, and no automatic compilation at boot; apply updates via cooperative draining restart (`hi daemon restart`). |
| One registry of daemon, harness, and env hooks | Keep shared semantics small: `H.Extension.Observer` provides post-commit advisory observations (`command_committed`, `work_settled`), while `H.Harness` (`prepare_context/2`, `project_response/2`) and `H.ExecutionEnv` (`admit_exec/2`, `operation_finished/2`) own their respective domain callbacks. |
| Wrap any provider stream and retry when nothing was rendered | Reuse the credential path at the actual dispatch boundary. No output is not proof of rejection. The adapter must prove both pre-acceptance rejection and account-local scope; the persisted attempt policy governs interruption. |
| A generic owner command and UI engine for `/login` | Ship only a versioned provider-login interaction. Don't invent generic action handlers, client forms or conversation commands for it. |
| Package code in `hi` to render status | One optional snapshot of bounded values, displayed only by local templates. No change to the transcript/SSE cursor and no provider I/O from rendering. |

## Check the design against failure cases

| Change or failure | Expected result |
|---|---|
| Neither packages nor managed accounts are configured | Stock daemon, manual credentials, existing clients and session protocol still work. No empty registries/services have to be started in order to do normal work. |
| Two clients attach to the same conversation, then both leave | One daemon owns the work. Presence doesn't change tool dispatch, account selection or retry policy. |
| A profile/env is removed while its sessions still exist | No substitute runtime for those sessions. Surface unavailability and keep their records intact. |
| The daemon dies after sending a pooled inference request but before receiving its result | Recovery follows the persisted policy and does not send the request again. Not displaying a token is not evidence that a provider did no work. |
| Status is stale, absent or malformed | It is dropped or expires. Even valid-looking but inaccurate status cannot mutate state, dispatch inference, switch credentials or advance the durable cursor. |

## Sequence and implementation gates

1. **Implemented: prove boot composition with a tiny path extension.** One config serves standalone HTTP/UDS, session create/attach, VM recovery and the in-VM backend. Start here for [operator configuration and the developer template](extensions/daemon.md).
2. **Implemented: stock account context and MultiCodex path package.** Core owns device login, a private vault, and explicit manual selection. The package owns polling and ranking; it contributes two narrow callbacks.
3. **Implemented: bounded auth fallback.** One alternate dispatch for a verified pre-output `401 invalid_token`. Quota-error retry is deferred until the provider proves account-local scope and pre-acceptance; no generic provider registration hook.
4. **Implemented: opt-in status projection and narrow domain seams.** `GET /api/v1/sessions/:sid/conversations/:cid/extension-status` exposes cached scalar projections (`MultiCodex` `account_pool` and `EditorHost` `editor_host`), consumed by `hi` when `"extension_status": true` is set in `hi.json` without affecting login, inference, or the client cursor.

Do not replicate Pi’s account-store adoption or unverified retry rules. No new persistence or transport dependency is assumed. Tests use fake services and disposable workspaces and stores; no real account stores or paid calls.
