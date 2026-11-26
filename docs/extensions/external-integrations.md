# External runtimes and live tool hosts

[Extensions index](../extensions.md) · [Harness profiles](harness.md) · [Client projections](clients.md)

These are **deferred designs**, not prerequisites for packages, Codex, or `hi` status. If code can run without a UI, use an installed [`H.Tool`](harness.md) or an operator-installed daemon-owned companion first. A bridge is justified only for a capability with an external lifetime (for example an editor's unsaved buffer). A backend is a different runtime, not a profile.

## Alternate backends

**What:** use H's UI with a different agent runtime. That runtime owns its history, task and restart guarantees; it does not gain H durability by returning similarly shaped JSON.

**How:** prefer a separate adapter executable on explicitly selected local HTTP/UDS over loading foreign code in either client or H. The minimum client contract is workspace-qualified create/attach, a session view, idempotent commands, paged history and a cursor/reconnect story. Select endpoint, credentials and saved session references by backend profile; never reuse H's bearer token or remembered IDs across backends. No automatic execution of a checkout adapter or adapter chosen by a server frame. Known H v1 with no capability discovery remains the baseline; for an alternate backend require explicit compatibility and hide unsupported optional actions. A process-bound adapter that can't survive detach must say so.

**Gate:** before claiming compatibility, test the same language-neutral vectors for duplicate receipts, conflict, gaps, replay-to-snapshot, branch ownership, stale progress, detach, restart and offline. Freeze the smallest backend interface against H plus a deterministic fixture. Don't extract an SDK before a second real backend uses it.

## Implemented: live tool hosts (`extensions/editor_host`)

**What:** a daemon-owned tool call that needs inherently live external data (such as an editor's unsaved buffer). A client viewing SSE is **not** a worker; otherwise two watchers could both run one invocation. A host disconnect makes its capability unavailable (`tool_unavailable` / `host_disconnected`), not the entire daemon.

**Package (`extensions/editor_host`):** ships as an optional startup-loaded API-1 artifact registering the `editor_coding` harness profile, the `editor_buffer_summary` read-only `H.Tool` (requiring `path` and `expected_revision`), the `Extensions.EditorHost.Broker` process, and an `editor_host` status projection.

1. Pair through a trusted owner operation. A host uses a short-lived tool-host-only grant, never the owner token, and connects to the broker. Verify host/tool/schema/scope against installed config, bind one live host generation, cap concurrency, and revoke routing on loss/expiry. A host can't claim another workspace, install a tool, or choose replay policy. Persist only approved plain policy/identity if needed, never live handles or grants.
2. Core checks effective tool availability, schema, lease, and commits intent as for any tool. After intent the proxy dispatches a one-use invocation ID, binding, validated args and deadline. Bind it to the current worker in the broker; H already fences the worker return. `H.Tool` exposes a task ID and `on_output`, not a stable external deduplication/attempt token. A durable external deduplication ID needs its own contract.
3. Validate scope, generation, sequence, size and deadline on bounded progress and one terminal result. Use normal tool content/details; do not relay active HTML, controls or credentials. Cancel/expire on worker or host loss, and require the host to honor lease/deadline. No eligible host before dispatch means a prompt `tool_unavailable` outcome. If dispatch may have occurred, ignore late results and report interruption when outcome is unknown. Never resend unsafe work or redirect it to another viewer. Even a read of a changing buffer needs a revision precondition before it can be called safely replayable.

**Gate:** with both `hi` and Phoenix attached, observe exactly one dispatch and normal result. Test unauthorized pairing, duplicate claim, stale host generation, malformed/overlarge results, timeouts, and host/client/VM loss before and after dispatch. Explicitly test replay policy; don't enable mutating external hosts until cancellation/lease expiry and ambiguous effects are verified. This is not a general MCP gateway, UI callback, or durable human-approval mechanism.
