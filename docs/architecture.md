# Architecture

For startup path extensions, managed accounts, and proposed hooks, see [Extensions](extensions.md). For step-anchored subsession delegation, settlement signals, and the `subagent` tool, see [Subagents](architecture/subagents.md).

The engine is the root Mix application (`:harness`, `H.*`). It owns session state and runs work even when no client is attached. Phoenix is a separate Mix application; the terminal client is a separate Rust binary. Neither is required to run the engine.

## Four structures with different lifetimes

| Structure | What it answers |
|---|---|
| `H.Session`, `H.Conversation`, `H.Entry` | Which immutable entries are visible here? A fork inherits its parent's visible prefix through a selected entry; a spawned subsession starts a fresh root conversation anchored immutably to its parent session's launch entry (`Catalog.parent`). |
| `H.Task` ownership | Which run owns this work? A generation can own tool calls; forking history does not copy or cancel them. |
| OTP supervision | Which live processes stop or restart together? A temporary `H.Session.Supervisor` wraps a per-session `:one_for_all` supervisor for the coordinator and its task supervisor. Repeated failures can quarantine one session. |
| Client cursor | Which session, branch and page is this client displaying? Navigation is not a mutation of shared history. |

## From command to effect

1. `H.Daemon` validates the command and routes it to the session's single writer, `H.Session.Server`. The coordinator stages transitions in order and can commit multiple batches in one storage call. A command's `request_id` and fingerprint distinguish a retry from a conflicting submission.
2. A batch can change entries, tasks, submissions and conversation documents together. On a fork, `agent` configuration is inherited as of the fork entry; `live`, `inbox` and `usage` start at their initial values.
3. Provider and tool calls run in supervised workers **after intent is committed**, not inside storage commits. Worker messages are fenced by incarnation, task and attempt. Outcomes are committed by the coordinator. Streaming progress can be published before it is flushed; only committed frames advance the client's durable cursor.
4. `H.Context` projects visible history and selected tools into a model request. For example, if a fork cuts off a tool result, the projection supplies an interrupted result without changing the transcript. `H.Provider.ReqLLM` handles real streams and resolves credentials at runtime; tests use fakes.

## Storage and recovery

`H.StoreLock` takes a Unix-socket lock for the data directory. This is distinct from `api.sock`, the client listener. `H.Catalog` persists session summaries under `catalog/` and serves ETS-backed workspace queries without loading every session. Each coordinator owns its store under `sessions/<session_id>/` with the file backend.

`H.Storage.File` uses a CRC32-framed commit log and rename-based snapshots. It recovers a torn final frame. `H.Storage.Memory` implements the same interface without disk persistence. Domain records must be plain data: runtime handles and provider credentials do not belong in records or client views.

Supervision alone cannot recover an effect. On startup the daemon consults the catalog for active sessions; the coordinator reconciles stored checkpoints. Interrupted model calls have retry accounting. Interrupted safe tools (`read`, `search_history`) can run again; unsafe tools (`write`, `edit`, `bash`) return an interrupted result with any persisted partial output instead. This is **not** exactly-once external execution. See the [file storage](../test/h/storage_file_test.exs), [tool recovery](../test/h/tool_crash_recovery_test.exs) and [VM restart](../test/h/vm_restart_test.exs) tests.

## Account boundary

`H.Accounts` starts under the daemon's store lock. An owner can create the
first alias through login or settings; H writes `accounts.json` before making
provider calls. A worker's managed/manual mode is selected before committing
its attempt policy and does not change mid-attempt. Login and refresh are
bounded external operations owned by this context, not by a session
coordinator, HTTP request, or client SSE subscription. The private vault is
separate from catalog and session stores. ReqLLM resolves an access credential
just before dispatch. The owner API reads only login instructions and
sanitized state, and performs typed account configuration operations. Managed
inference commits a bounded dispatch/no-resume policy before the worker starts. Stock resolves just
one active alias; the optional path-loaded [MultiCodex](extensions/providers.md)
package owns quota polling and account preferences. The adapter alone
authorizes a second dispatch.

Named Chat Completions providers are startup data, not extensions. The
validated catalog supplies the route and limits, while the account service
alone stores and resolves the active API-key profile. Both generation and
compaction commit a one-dispatch, no-auto-resume policy for these routes.
The owner web editor stages catalog writes through the account service under
that same lock. An edit does not mutate the booted registry or change which
endpoint can receive an existing provider's key.

## Planned shutdown

The standalone launcher accepts an owner-authenticated, idle-only shutdown.
The boot process tracks command admission; closing the gate fences new writes
at both the daemon and session coordinator. Shutdown is refused during an
admitted mutation or any known unfinished session work. The launcher stops its
own instance in supervision order; the caller does not signal an OS PID.
Client reexec restores terminal modes and attaches with the same session and
conversation IDs. Neither mechanism changes how crash recovery treats external
effects.

## Workspace boundary

`H.EnvRegistry` resolves an environment for browsing or binds it to a session's working directory. The catalog keeps a session’s original `{env_id, cwd}` for grouping and provenance. Mutating tool leases use the effective `{env_id, canonical_cwd}` instead. `H.Harness.Coding` supplies `read`, `write`, `edit`, `bash`, `search_history`, and depth-gated `subagent` delegation (holding zero worker processes while parked on `H.PubSub` submission-settlement signals) and discovers ancestor `AGENTS.md` files through `H.ExecutionEnv` unless instructions are overridden. `H.ExecutionEnv.Host` operates with the host user's access; a lease coordinates writers, **not** filesystem confinement. `Local` is a compatibility wrapper.

The coding tools (`bash`, `read`, `write`, `edit`) accept a per-call `cwd` in the same environment. When omitted, they use the session workspace. An override never changes the default for other calls or the session’s catalog binding. A new subagent defaults to the parent’s session workspace or can be given a separate prepared worktree; its lineage records the parent’s workspace and its own session records its starting directory.

Mutating tools and user-shell commands queue at `H.WorkspaceLease` when another conversation owns the workspace. The manager monitors waiters and reserves the next lease before signalling its session coordinator; the coordinator stays responsive while waiting. A persisted `workspace_wait` checkpoint pins the resolved directory but has no execution attempt, so it can safely requeue after restart. Runtime lease ownership and handoff use the captured key, not a recomputation from the session’s original directory. Client actions can cancel the waiting run or request cancellation of the specific current holder, with a lease-generation token fencing stale stop requests. Stop-holder prioritizes that waiter but does not revoke the lease: the owning coordinator commits cancellation, stops its workers, and releases normally. Running unsafe effects retain the interruption policy above.

`H.ExecutionEnv.Remote` delegates to `H.RemoteAgent`. The implementation exercises stale-attempt fencing, lease renewal, expiry and process-group cleanup **in the same VM**. It is not an authenticated transport to another machine.

## Client boundary

- **Phoenix** (`clients/web/`): `:harness_web` depends on `:harness` by path. `HWeb.Backend.InVM` calls the daemon in the same VM; there is no HTTP backend. `WorkspaceLive` browses folders, `InboxLive` (`/inbox`) provides a live workspace-grouped attention overview across sessions via `:catalog` PubSub without waking unloaded sessions, and `SessionLive` streams entry rows and retains document and cursor state rather than every rendered entry body. The session file review view polls bounded workspace listings and reads through the session's `H.ExecutionEnv`; its edits use a revision check and workspace writer lease. Review comments use normal session submissions. File selections and edit drafts are client state, not new engine records.
- **Terminal (`clients/tui/`, `hi`)**: `hi` discovers an existing daemon via `api.sock` or literal loopback HTTP, sends the owner bearer token, and consumes the [JSON/SSE API](protocol.md). It supports fullscreen and regular scrollback modes, `hi inbox` / `/inbox` multi-session browsing over `GET /api/v1/sessions/events`, and headless `-p` print mode, sharing the same sessions as Phoenix. A single terminal loop renders the editor, styled transcript and focused picker; cancellable SSE subscriptions and background command workers do not own stdout. Explicit queue withdrawal is a shared daemon mutation returning a durable receipt, not a local inbox edit. See [build status](hi/build.md) for implemented scope versus the [pi parity target](hi.md), and [client extension surfaces](extensions/clients.md) for device login and daemon management.

The web workbench is a slotted function component, not a process tree. A separate,
owner-authenticated sticky `InspectorLive` follows recent entries in the dedicated
web feedback conversation while its panel is open. It records notes using the normal
`submit/write` path; `Ask agent` uses `submit/input`. Browser-only selection and
pane widths are not daemon state. See [web development and pane composition](../clients/web/README.md).
