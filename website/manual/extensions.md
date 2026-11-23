---
layout: doc
title: 'Build a local extension'
description: 'Package a trusted API 1 harness profile or execution environment and test startup against a disposable store.'
lang: en
permalink: /docs/extensions/
figure: extension-path
---
Build a local startup extension when you want to register a custom harness profile, tool set, execution environment, or Codex account policy in the daemon VM. To add a Chat Completions endpoint, use the [provider catalog](/docs/providers/) instead; to customize the terminal status bar, edit your [terminal footer template](/docs/terminal/#configure-the-terminal-footer).

* Contents
{:toc}

## Choose a contract

At startup, H calls `H.Extension.configure/2` with your JSON settings, the extension ID, and the daemon data directory. Validate the settings and return contribution registrations or child specs for H to supervise:

- `H.Harness` defines a profile's initial agent settings and installed tool modules.
- `H.Tool` defines a tool's name, JSON argument schema, execution callback, workspace lease requirement (`mutating?/0`), and crash replay policy (`replay/0`).
- `H.ExecutionEnv` defines workspace binding, file operations, and command execution.
- The Codex account-policy contract powers [MultiCodex](/extensions/multicodex/) for ranking authorized Codex aliases.

## Author a harness profile

A harness profile configures a session's default instructions, model parameters, and available tools. Implement `id/0` with a stable identifier, `descriptor/0` with its public metadata, `tools/1` with its list of tool modules, and `bootstrap_agent/3` with its initial agent configuration. Return the module in your extension's `harnesses` contribution list. H records the selected `harness_id` when creating the session so the profile stays fixed for the life of that session.

To add a custom tool, implement [`H.Tool`](https://gitlab.com/parlant-co/harness/-/blob/main/lib/h/tool.ex). Declare a stable name and JSON argument schema, run file or shell work through the session's bound execution environment in `execute/2`, and return bounded plain-text output. Set `mutating?/0` to `true` when the tool needs the workspace writer lease, and set `replay/0` to declare whether H may automatically rerun an interrupted call after a crash. Default to unsafe replay whenever a tool can modify external state. Test the tool against a fake provider and disposable workspace before adding it to your profile.

## Hooking into core

H keeps its commit path deterministic by using explicit behaviour contracts rather than an arbitrary event-hook registry:

- To observe session state or build an external workflow, subscribe to the [committed conversation SSE stream](/docs/protocol/#resume-a-conversation-stream).
- To enforce a custom file or command boundary, implement or wrap `H.ExecutionEnv`.
- To rank multiple Codex accounts, implement the Codex account-policy contribution.

When a feature requires a new decision point inside the core coordinator, propose a typed call site with a clear owner, bounded inputs and outputs, explicit failure handling, and VM-restart tests. Read the [daemon extension design notes](https://gitlab.com/parlant-co/harness/-/blob/main/docs/extensions/daemon.md) for current contract details and future proposals.

## Build the greeting template

Copy the [greeting extension template](https://gitlab.com/parlant-co/harness/-/blob/main/examples/extension_template/README.md) into a separate directory and compile it with the same Elixir and Erlang/OTP versions that run your daemon:

```sh
export H_SOURCE=/absolute/path/to/matching/h-source
mix deps.get
mix check
mix test
mix extension.build
```

`mix extension.build` writes a self-contained artifact to `dist/greeting/` containing `extension.json` and compiled BEAM modules under `ebin/`. When creating your own package, rename the root module, OTP application name, and profile ID outside the `H.*` namespace.

## Try the built artifact, not the source tree

Create a disposable data directory and point `extensions.json` at the compiled `dist/greeting` directory:

```json
{"version":1,"extensions":[{"path":"/absolute/path/to/dist/greeting","settings":{"instructions":"Prefer short explanations."}}]}
```

Validate the startup configuration from a compiled H checkout:

```sh
bin/h-daemon --data-dir /absolute/path/to/test-store --check-config
```

Start a test daemon against `/absolute/path/to/test-store` on a free port, then create a session through the [local HTTP API](/docs/protocol/) with `harness_id: "example.greeting.v1"` and an absolute test `cwd` to confirm registration without making a provider call.

Relative paths in `extensions.json` resolve from `<data_dir>`, and changes take effect on the next daemon restart. If a configured artifact is missing or registers a conflicting ID, H aborts startup immediately. Pass `--no-extensions` to boot the daemon without loading `extensions.json` when diagnosing a broken package. See the [daemon contract](https://gitlab.com/parlant-co/harness/-/blob/main/docs/extensions/daemon.md) and the [extension browser](/extensions/).
