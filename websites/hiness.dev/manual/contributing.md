---
layout: doc
title: 'Contribute a change'
description: 'Pick the right module boundary, test with fake providers and disposable stores, and verify client synchronization.'
lang: en
permalink: /docs/contributing/
---
Start with an observable user behavior, such as reconnecting after a commit or rejecting a stale file edit. Locate the module that already owns that transition before adding a new process or callback.

* Contents
{:toc}

## Choose the smallest change

| Change | Start in |
|---|---|
| Shared command or history transition | `lib/h/daemon*`, `lib/h/session/`, and `test/h/` |
| Terminal interaction or display | `clients/tui/`; keep drafts and navigation in the client and send daemon commands for shared state |
| Web presentation or LiveView behavior | `clients/web/`; render panes in function components and keep subscriptions and command dispatch in LiveViews |
| Optional tool set or execution environment | [Build a local extension](/docs/extensions/) against `H.Extension`, `H.Harness`, `H.Tool`, or `H.ExecutionEnv` |

Read the [project instructions](https://github.com/parlant/harness/blob/main/AGENTS.md) and [architecture](/docs/architecture/) before modifying a process or storage boundary. Store plain serializable data in wire payloads and disk records, and validate external input without creating runtime atoms. Discuss any new persistence or transport dependency with the maintainer before adding it. Check [design references](https://github.com/parlant/harness/blob/main/docs/references.md) for prior art.

## Run the checks for the affected project

Run the formatter, compiler, and test suite from the repository root:

```sh
mix format
mix compile --warnings-as-errors
mix test
(cd clients/web && mix format && mix compile --warnings-as-errors && mix test)
(cd clients/tui && cargo test --locked && cargo clippy --locked --all-targets -- -D warnings)
```

Both Mix projects run `mix test --no-start` by default. Write tests against disposable storage directories, temporary workspaces, fake model providers, and `start_supervised!` for only the processes under test. On macOS, set a unique `MIX_BUILD_PATH` under `/private/tmp` for agent-run builds, and stop only processes that your own session started.

## Verify a client change end to end

To run the native terminal and Phoenix synchronization test, compile `hi` and pass its absolute binary path to `HI_BIN`:

```sh
(cd clients/tui && cargo build --locked --bin hi)
hi_bin="$PWD/clients/tui/target/debug/hi"
(cd clients/web && HI_BIN="$hi_bin" mix test --include native_client)
```

If you set `CARGO_TARGET_DIR`, point `hi_bin` at the resulting binary in that target directory. When you add or modify an external side effect, include both interrupted-attempt and full VM-restart recovery tests. In your change description, list the verification commands you ran, the observed output, and any remaining follow-up work. Keep [roadmap proposals](https://github.com/parlant/harness/blob/main/docs/roadmap.md) clearly labeled as future work.
