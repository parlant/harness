# Harness profiles and tools

[Extensions index](../extensions.md) · [Daemon composition](daemon.md)

## Existing: what a profile can do

A *harness profile* chooses agent bootstrap and installed tool implementations while H keeps session history, task ownership, commit, and recovery. It is not a subclass of the session server. To replace the agent loop or session runtime itself, see [external backends](external-integrations.md#alternate-backends).

[`H.Harness`](../../lib/h/harness.ex) exposes `id/0`, `descriptor/0`, `tools/1`, `bootstrap_agent/3`, and optional callbacks `prepare_context/2` and `project_response/2`. The built-in [`H.Harness.Coding`](../../lib/h/harness/coding.ex) (`coding`, alias `pi`) supplies coding, signal, and subagent tools and discovers workspace instructions through the bound environment. `GET /api/v1/harnesses` (`H.Daemon.list_harnesses/1`) exposes registered profile descriptors for `--harness` / `/harness` selection in `hi` and `hiweb`.

[`H.Tool`](../../lib/h/tool.ex) defines a stable name, description, JSON argument schema, `execute/2`, `mutating?/0` and `replay/0`. Execute with the bound [`H.ExecutionEnv`](execution-env.md) rather than a direct host filesystem or shell call. Return bounded plain `content`, `details`, `is_error`, and `diagnostic`. Model inputs and tool outputs are untrusted. `configure.tools` selects names; it does not install tools. Mutating/workspace-lease policy and safe/unsafe replay policy are independent; an effect with unknown repeatability should be `:unsafe`. Tool tasks, argument validation, leases, intent and outcomes remain daemon-owned.

## How to package a profile

Use a stable ID such as `acme.review.v1`. `Acme.Review` implements `H.Harness`, returns a descriptor and a list of tool modules, and builds agent defaults from the bound workspace. `Acme.BufferSummary` implements one read-only `H.Tool` and returns a normal result usable by every client. Test via `H.Daemon` with `harnesses: %{"acme.review.v1" => Acme.Review}` and disposable storage. Build it as an artifact and point [daemon boot config](daemon.md) to its path; do not make core depend on the extension. Bootstrap can read workspace instructions; it should not perform mutations or provisioning. Keep tool descriptors and schema callbacks deterministic and bounded.

When attaching, an explicitly requested profile must match the recorded canonical profile (including recognized aliases); an omitted profile defaults only on creation. H validates new extension tool lists at boot, validates bootstrap output before inserting a new session, and checks the configured selection against installed tools at dispatch as well as in model schemas. `tools: []` selects none. A conversation cannot use `configure` to install a tool. The profile's installed tool map is the ceiling, not a filesystem sandbox. Keep IDs compatible with outstanding work; a removed profile cannot run under `coding` as a substitute.

## Implemented: optional profile-owned callbacks

| Callback | Inputs and output | Limits and failure |
|---|---|---|
| `prepare_context/2` | Read-only projection (`session_id`, `conversation_id`, `purpose`, `agent`, `request`) inside the inference worker; returns bounded UTF-8 contributions (`prepend_system`, `append_system`, `ephemeral_context`, `<= 32 KiB`). | Runs off `H.Session.Server` inside the supervised inference worker before dispatch. Fails closed (`context_preparation_failed`, `retryable: false`) on error, timeout, exception, or oversized output; never falls through to an unreviewed request or escalates tools. |
| `project_response/2` | Normalized response and scope (`session_id`, `conversation_id`, `model`, `finish_reason`); returns `:ignore` or `{:ok, annotation_map}` (`<= 4 KiB`). | Pure post-turn projection stored under `entry.data["harness_annotation"]` after credential sanitization. Omitted on `:ignore`, error, exception, or oversized payload without altering content, retries, or usage accounting. |

**User interaction:** use existing configuration/submit commands or a concrete owner operation with an explicit schema. Don't intercept keystrokes or rewrite validated commands in a hook. Approval or a long-lived pause needs an explicit durable wait/transition and is outside this slice.

**State:** bootstrap writes only approved agent settings. Per-profile runtime services, if needed, are package-owned; don't hide mutable cross-session state in a callback. A fork inherits agent configuration according to core rules, not package worker state or a new set of credentials.

## Verification

Use a tiny fixture with one bounded read tool and one failure. Verify bootstrap and typed errors, recorded canonical profile, actual tool availability at validation and dispatch, unchanged tool recovery/leases, attach conflict, restart with and without the package, and the same plain output in old and new clients. Only add a hook after a fixture demonstrates why bootstrap/tools or an external projection aren't enough.
