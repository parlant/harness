---
layout: doc
title: 'Contribute a change'
description: 'Choose the implementation boundary, test with fake providers and disposable stores, and describe what the change proves.'
lang: en
permalink: /docs/contributing/
---
Start with one behavior a user can observe, such as reconnecting after a commit or refusing a stale edit. Identify the code that owns that behavior before adding a callback or another process.

* Contents
{:toc}

## Choose the smallest change

| Change | Start in |
|---|---|
| Shared command or history transition | `lib/h/daemon*`, `lib/h/session/` and `test/h/` |
| New terminal interaction | `clients/tui/`; keep drafts and navigation local, use daemon commands for shared effects |
| Web presentation | `clients/web/`; keep pane composition in function components, subscriptions and command dispatch in LiveViews |
| Optional tool set or environment | [Extension authoring](/docs/extensions/) rather than a second session engine |

Read the [project instructions](https://gitlab.com/parlant-co/harness/-/blob/main/AGENTS.md) and [architecture](/docs/architecture/) before touching a process or storage boundary. Use plain data in wire and durable records; don't create atoms from external input. Agree on new persistence or transport dependencies first. Pinned [design references](https://gitlab.com/parlant-co/harness/-/blob/main/docs/references.md) are inputs, not runtime dependencies.

## Run the checks for the affected project

From the repository root with dependencies available:

```sh
mix format
mix compile --warnings-as-errors
mix test
(cd clients/web && mix format && mix compile --warnings-as-errors && mix test)
(cd clients/tui && cargo test --locked && cargo clippy --locked --all-targets -- -D warnings)
```

Both Mix projects default to `test --no-start`. Use disposable storage/workspaces, fake providers and `start_supervised!` for only the children a test needs. Never test against your real account files, start a service from a unit test or spend provider credit to check rendering. On macOS use a private `MIX_BUILD_PATH` under `/private/tmp` for agent-owned builds; use separate paths for separate projects. Do not terminate unrelated processes.

## Verify a client change end to end

For the optional native/Phoenix sync test, build `hi` and provide its absolute path. From the repository root (default Cargo target directory):

```sh
(cd clients/tui && cargo build --locked --bin hi)
hi_bin="$PWD/clients/tui/target/debug/hi"
(cd clients/web && HI_BIN="$hi_bin" mix test --include native_client)
```

With `CARGO_TARGET_DIR` set, adjust `hi_bin` to that directory's binary. Test both committed state and what happens on disconnect. For a new external effect, add interrupted-attempt and VM-restart coverage; a worker restart alone doesn't prove durability. In the change description, list the commands you actually ran, the expected behavior, and what remains unverified. Keep [roadmap proposals](https://gitlab.com/parlant-co/harness/-/blob/main/docs/roadmap.md) separate from shipped functionality.
