# Execution environments

[Extensions index](../extensions.md) · [Harness profiles and tools](harness.md)

## Existing: what the environment owns

[`H.ExecutionEnv`](../../lib/h/execution_env.ex) is the boundary for path resolution, workspace binding, filesystem operations and command execution. [`H.EnvRegistry`](../../lib/h/env_registry.ex) builds runtime handles from trusted `:environments` specs and publishes plain descriptors (`id`, `kind`, `label`, `default_cwd`). A session binds an environment and a working directory. Catalog queries and leases distinguish workspaces by `{env_id, cwd}`; an environment ID is not just a display label. The handle (`{module, state}`) is runtime data, never a session record or client value.

`Host` uses the daemon user's access, not an OS sandbox. A workspace lease coordinates writers; it does not confine paths or stop arbitrary commands. Session file browse/read has its own path checks. Those checks do not imply containment for `exec`. `Remote` plus `H.RemoteAgent` exercise attempt fencing, heartbeat leases, and cleanup both in-VM and across connected Erlang nodes (`H.ExecutionEnv.Remote.connect_node/3`, `env_spec_for_node/3`), allowing one local daemon ("brains") to coordinate tools on one or more separate BEAM nodes ("hands", e.g., inside Docker or on remote hosts over Erlang distribution). An internet-facing mTLS/SSH network transport across untrusted networks remains a separate future step.

## How to add one

1. Implement the required behaviour callbacks. Give the environment an explicit stable ID and default workspace root; bind and canonicalize CWD using the environment's semantics, not the client or daemon's CWD. Implement optional capabilities only when supported, and report unsupported distinctly. No fallback from an unavailable environment to `host`.
2. Register an environment spec with a trusted `build` function or a static runtime handle via [daemon composition](daemon.md). For an example fixture, decorate a disposable local env to measure `exec` duration without recording commands or output. Preserve the underlying CWD, identity, errors, deadlines, output limits and cancellation semantics. If the target or security policy changes incompatibly, give it a new ID; do not bind old sessions to a different machine or privilege set.
3. Confirm contact with the environment is bounded during bind/browse as well as dispatch. Allowlist required capabilities and preserve confinement for **all** relevant paths, including canonicalization and symlinks. OS-level boundaries for untrusted code belong in the env implementation or a separate OS identity, not in H callbacks. Filtering known token variables does not prevent same-user filesystem/secret access.

## Proposed: env-owned hooks

Prefer a decorated or new behaviour implementation to a daemon-level `before_exec` hook. When an environment has a second real policy consumer, the environment can expose a typed slot, versioned by that implementation; it does not become a slot in all environments.

| Candidate | Timing and output | Constraints |
|---|---|---|
| `admit_exec` | Environment-owned execution gate after workspace binding and applicable core intent/lease checks, before launch. Inspect a normalized launch plan and return allow, deny, or tighter resource limits. | A required policy error/timeout denies launch. Can't add privileges, change target or widen paths; revalidate before launch. This is not a generic hook on all `H.ExecutionEnv` operations. |
| `operation_finished` | Optional sanitized metrics (kind, duration, bounded result class), emitted off the environment's hot path. | Lossy; omit on failure. No raw command, path, stdin, stdout or credentials by default. This is not evidence that H committed an outcome. Observe the daemon milestone if a committed result is required. |

Neither changes core tool replay policy, leases, task intent or outcome. Worker cancellation and env-side termination are distinct: ignore stale progress/results and stop work according to the env's deadline or lease. Fencing a late result cannot undo an external write. A failure after possible launch does not permit an env decorator to repeat the call. Admission of a tool via human approval would require a durable H transition, not a callback parked in an env server.

## Verification

Exercise binding/canonicalization, distinct environment-qualified sessions, unavailable targets, confinement for the actual operations claimed, deadline/cancel cleanup, stale results and ambiguous termination. Use fake/no-op execution or tightly scoped disposable fixtures. For a network environment, additionally prove authentication, process-group termination or lease expiry across disconnect, and no unsafe replay after VM restart before advertising that guarantee. See [external integrations](external-integrations.md) for live client-supplied tools; they are not registered as environments.
