# Execution environments

[Extensions index](../extensions.md) · [Harness profiles and tools](harness.md)

## Existing: what the environment owns

[`H.ExecutionEnv`](../../lib/h/execution_env.ex) is the boundary for path resolution, workspace binding, filesystem operations and command execution. [`H.EnvRegistry`](../../lib/h/env_registry.ex) builds runtime handles from trusted `:environments` specs and publishes plain descriptors (`id`, `kind`, `label`, `default_cwd`). A session binds an environment and a working directory. Catalog queries and leases distinguish workspaces by `{env_id, cwd}`; an environment ID is not just a display label. The handle (`{module, state}`) is runtime data, never a session record or client value.

`Host` uses the daemon user's access, not an OS sandbox. A workspace lease coordinates writers; it does not confine paths or stop arbitrary commands. Session file browse/read has its own path checks. Those checks do not imply containment for `exec`. `Remote` plus `H.RemoteAgent`, `H.RemoteAgent.HTTP`, and `H.RemoteAgent.Client` implement attempt fencing, heartbeat leases, streaming output, and OS process-group reaping in-VM, across connected Erlang nodes (`connect_node/3`, `env_spec_for_node/3`), and over authenticated HTTP or Unix sockets (`connect_http/3`, `env_spec_for_http/3`, and standalone `h-daemon remote-agent`). Internet-facing mTLS/SSH across untrusted public networks remains a separate step.

## How to add one

1. Implement the required behaviour callbacks. Give the environment an explicit stable ID and default workspace root; bind and canonicalize CWD using the environment's semantics, not the client or daemon's CWD. Implement optional capabilities only when supported, and report unsupported distinctly. No fallback from an unavailable environment to `host`.
2. Register an environment spec with a trusted `build` function or a static runtime handle via [daemon composition](daemon.md). For an example fixture, decorate a disposable local env to measure `exec` duration without recording commands or output. Preserve the underlying CWD, identity, errors, deadlines, output limits and cancellation semantics. If the target or security policy changes incompatibly, give it a new ID; do not bind old sessions to a different machine or privilege set.
3. Confirm contact with the environment is bounded during bind/browse as well as dispatch. Allowlist required capabilities and preserve confinement for **all** relevant paths, including canonicalization and symlinks. OS-level boundaries for untrusted code belong in the env implementation or a separate OS identity, not in H callbacks. Filtering known token variables does not prevent same-user filesystem/secret access.

## Implemented: optional environment callbacks

| Callback | Timing and output | Constraints |
|---|---|---|
| `admit_exec/2` | Environment-owned pre-launch gate in `H.ExecutionEnv.exec/3` (`:allow`, `{:allow, tighter_opts}`, or `{:deny, reason}`). | Fails closed (`{:error, {:exec_denied, reason}}`) on deny, exception, or invalid options before launching any OS process. `{:allow, tighter_opts}` may only tighten `timeout_ms`, `window_bytes`, `window_lines`, or `spill_output`. |
| `operation_finished/2` | Sanitized lossy metrics (`env_id`, `kind`, `duration_ms`, `result_class`) emitted after filesystem and `exec` operations. | Lossy; errors are ignored. Contains zero raw commands, file paths, stdin, stdout, or credentials. |

Neither changes core tool replay policy, leases, task intent or outcome. Worker cancellation and env-side termination are distinct: ignore stale progress/results and stop work according to the env's deadline or lease. Fencing a late result cannot undo an external write. A failure after possible launch does not permit an env decorator to repeat the call. Admission of a tool via human approval would require a durable H transition, not a callback parked in an env server.

## Verification

Exercise binding/canonicalization, distinct environment-qualified sessions, unavailable targets, confinement for the actual operations claimed, deadline/cancel cleanup, stale results and ambiguous termination. Use fake/no-op execution or tightly scoped disposable fixtures. For a network environment, additionally prove authentication, process-group termination or lease expiry across disconnect, and no unsafe replay after VM restart before advertising that guarantee. See [external integrations](external-integrations.md) for live client-supplied tools; they are not registered as environments.
