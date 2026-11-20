# Harness profiles and tools

[Extensions index](../extensions.md) · [Daemon composition](daemon.md)

## Existing: what a profile can do

A *harness profile* chooses agent bootstrap and installed tool implementations while H keeps session history, task ownership, commit, and recovery. It is not a subclass of the session server. To replace the agent loop or session runtime itself, see [external backends](external-integrations.md#alternate-backends).

[`H.Harness`](../../lib/h/harness.ex) exposes `id/0`, `descriptor/0`, `tools/1`, and `bootstrap_agent/3`. The built-in [`H.Harness.Coding`](../../lib/h/harness/coding.ex) (`coding`, alias `pi`) supplies tools and discovers workspace instructions through the bound environment. Direct `H.Daemon` calls can pass a trusted `:harnesses` map or module list. `POST /sessions` already accepts `harness_id` at creation. Custom registries can now load at boot. Profile discovery in `hi` and profile-owned context/response hooks are not shipped.

[`H.Tool`](../../lib/h/tool.ex) defines a stable name, description, JSON argument schema, `execute/2`, `mutating?/0` and `replay/0`. Execute with the bound [`H.ExecutionEnv`](execution-env.md) rather than a direct host filesystem or shell call. Return bounded plain `content`, `details`, `is_error`, and `diagnostic`. Model inputs and tool outputs are untrusted. `configure.tools` selects names; it does not install tools. Mutating/workspace-lease policy and safe/unsafe replay policy are independent; an effect with unknown repeatability should be `:unsafe`. Tool tasks, argument validation, leases, intent and outcomes remain daemon-owned.

## How to package a profile

Use a stable ID such as `acme.review.v1`. `Acme.Review` implements `H.Harness`, returns a descriptor and a list of tool modules, and builds agent defaults from the bound workspace. `Acme.BufferSummary` implements one read-only `H.Tool` and returns a normal result usable by every client. Test via `H.Daemon` with `harnesses: %{"acme.review.v1" => Acme.Review}` and disposable storage. Build it as an artifact and point [daemon boot config](daemon.md) to its path; do not make core depend on the extension. Bootstrap can read workspace instructions; it should not perform mutations or provisioning. Keep tool descriptors and schema callbacks deterministic and bounded.

When attaching, an explicitly requested profile must match the recorded canonical profile (including recognized aliases); an omitted profile defaults only on creation. H validates new extension tool lists at boot, validates bootstrap output before inserting a new session, and checks the configured selection against installed tools at dispatch as well as in model schemas. `tools: []` selects none. A conversation cannot use `configure` to install a tool. The profile's installed tool map is the ceiling, not a filesystem sandbox. Keep IDs compatible with outstanding work; a removed profile cannot run under `coding` as a substitute.

## Proposed: profile-owned hooks, only when needed

A profile can compose its own hooks inside its existing callbacks without an H change. When only H has the needed call site, add one optional typed behaviour callback for the specific data flow. Coding versions the slots it exposes; other profiles need not implement Coding's contracts. Don't make a profile supply its own process tree, history engine, or effect scheduler.

| Candidate | Inputs and output | Limits and failure |
|---|---|---|
| `prepare_context` | A read-only, profile-specific projection of visible history/config and the request purpose (generation or summary); returns bounded context contributions, not a full arbitrary provider request. | Before request sizing and dispatch, outside the single writer's commit path. Revalidate the projected request. No storage/network/tool effects, authority expansion, or uncounted additions. If required, bad output/timeout fails preparation; do not fall through to an unreviewed request. Define when contributions apply to compaction before exposing the hook. |
| `project_response` | Bounded normalized result and scope; returns a sanitized, optional annotation, not a replacement response. | Pure projection outside commit. Treat annotation as presentation-only unless an explicit domain schema is designed for it. Failure omits it; cannot edit committed history, schedule a tool, or change retries and accounting. Prefer an existing client or post-commit projection for display-only needs. |

Today the coordinator builds context and checks sizing before starting the provider worker. A `prepare_context` hook is therefore not just a call added to `stream_turn/3`: a future design must move extensible preparation off the single writer, then fence its result against the input history/config before proceeding. No committed intent to dispatch may refer to a different prepared request or stale tool policy.

**User interaction:** use existing configuration/submit commands or a concrete owner operation with an explicit schema. Don't intercept keystrokes or rewrite validated commands in a hook. Approval or a long-lived pause needs an explicit durable wait/transition and is outside this slice.

**State:** bootstrap writes only approved agent settings. Per-profile runtime services, if needed, are package-owned; don't hide mutable cross-session state in a callback. A fork inherits agent configuration according to core rules, not package worker state or a new set of credentials.

## Verification

Use a tiny fixture with one bounded read tool and one failure. Verify bootstrap and typed errors, recorded canonical profile, actual tool availability at validation and dispatch, unchanged tool recovery/leases, attach conflict, restart with and without the package, and the same plain output in old and new clients. Only add a hook after a fixture demonstrates why bootstrap/tools or an external projection aren't enough.
