---
layout: doc
title: 'Build a local extension'
description: 'Package a trusted API 1 harness or environment and test startup against a disposable store.'
lang: en
permalink: /docs/extensions/
figure: extension-path
---
Use a package for executable behavior that belongs at daemon startup. If all you need is another Chat Completions endpoint, use the [provider catalog](/docs/providers/) instead; for footer formatting, use local [terminal templates](/docs/terminal/).

* Contents
{:toc}

## Choose a contract

At startup H calls `H.Extension.configure/2` with the operator's settings, the extension ID and the daemon data directory. Validate the package's JSON settings and return registrations or child specs, not already-started processes. `H.Harness` defines the profile's bootstrap and tool set. `H.Tool` describes one tool, including mutation and replay policy; those are separate decisions. `H.ExecutionEnv` supplies environment binding, file operations and command execution. The compiler or loader does not turn these behaviours into a sandbox.

There is one narrow Codex account-policy contribution used by [MultiCodex](/extensions/multicodex/). Generic provider replacement, arbitrary event hooks, hot loading and client plugin forms are not shipped extension APIs.

## Author a harness profile

A harness sets agent defaults and installed tools, not conversation history or task scheduling. Start with the greeting template below. Give your profile a stable `id/0`; return its public description from `descriptor/0`, its installed tool modules from `tools/1` and its initial agent settings from `bootstrap_agent/3`. Return the profile module in the extension's `harnesses` contribution. The session records the profile ID at creation; an existing session must not silently switch to another profile on attach.

For a new tool, implement [H.Tool](https://gitlab.com/parlant-co/harness/-/blob/main/lib/h/tool.ex): provide a stable name and JSON argument schema, run through the bound environment in `execute/2`, and return bounded plain output. Declare `mutating?/0` (workspace lease) and `replay/0` (safe to run twice?) separately. A tool with unknown repeatability should be unsafe. Test with a fake provider and disposable workspace before including the tool in the profile. `configure.tools` selects installed names; it cannot install modules.

## Hooking into core

There is no general command or task hook registry. If the aim is to display state, subscribe to the existing [committed client view](/docs/protocol/#resume-a-conversation-stream) instead of inserting code in the commit path. For an execution constraint, implement or decorate `H.ExecutionEnv`; for provider account ordering, use the existing narrowly scoped Codex policy. Neither owns the session journal or authorizes replay after a crash.

When a feature genuinely needs a new decision from core, propose a typed call site with an owner, inputs, bounded outputs, failure behavior and timing relative to commit. A new durable wait or veto needs a real transition with restart tests; an observer notification cannot provide it. The [daemon hook proposals](https://gitlab.com/parlant-co/harness/-/blob/main/docs/extensions/daemon.md) describe candidates, **not callbacks you can register today**.

## Build the greeting template

Copy the [greeting example](https://gitlab.com/parlant-co/harness/-/blob/main/examples/extension_template/README.md) into a checkout you control. In that directory, using the daemon's Elixir/OTP versions:

```sh
export H_SOURCE=/absolute/path/to/matching/h-source
mix deps.get
mix check
mix test
mix extension.build
```

The default artifact is a **new** `dist/greeting/` directory with `extension.json` and namespaced BEAMs under `ebin/`. For your own package, change the root module, app and IDs consistently, outside `H.*`. Don't bundle the H runtime or dependencies to be installed at boot.

## Try the built artifact, not the source tree

In a disposable daemon data directory, create `extensions.json` with the real absolute artifact path:

```json
{"version":1,"extensions":[{"path":"/absolute/path/to/dist/greeting","settings":{"instructions":"Prefer short explanations."}}]}
```

From a compiled H checkout, check startup configuration using `bin/h-daemon --data-dir /absolute/path/to/test-store --check-config`. This loads trusted code but does not start services or prove a full boot. When running a test instance, use that private store and an available listener port. Create a session through the [owner API](/docs/protocol/) with the unchanged example's `harness_id: "example.greeting.v1"` and an absolute test `cwd`. The example has no tools; no provider call is required to check registration.

H doesn't scan projects for packages. Relative artifact paths resolve from the data directory, and changes require a VM restart. Missing required artifacts or colliding registrations fail startup rather than silently substituting another implementation. Use `--no-extensions` to diagnose boot; a session requiring an absent profile or environment won't execute under a substitute. See the [daemon contract](https://gitlab.com/parlant-co/harness/-/blob/main/docs/extensions/daemon.md) and [available extensions](/extensions/).
