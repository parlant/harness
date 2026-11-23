---
layout: doc
title: 'Extend the hi CLI'
description: 'Add a client-side hi-<name> executable on your PATH to create a custom subcommand.'
lang: en
permalink: /docs/guides/extend-hi/
---
Add a custom subcommand to `hi` by placing an executable named `hi-<name>` on an absolute `PATH` directory. `hi` dispatches external subcommands directly on the client machine.

* Contents
{:toc}

## Try a disposable command

In a Unix shell with `hi` installed, create a temporary `hi-workspace` script and run it via `hi workspace`:

```sh
tools=$(mktemp -d "${TMPDIR:-/tmp}/hi-guide.XXXXXX")
printf '%s\n' '#!/bin/sh' 'printf "workspace: %s\n" "$PWD"' > "$tools/hi-workspace"
chmod 700 "$tools/hi-workspace"
PATH="$tools:$PATH" hi workspace
```

`hi workspace` prints your current working directory and exits immediately without contacting the daemon or a model provider. Make sure `mktemp -d` returns an absolute path, because `hi` checks only absolute `PATH` entries when resolving external subcommands. Remove `$tools/hi-workspace` and the temporary directory when you finish testing.

## Dispatch rules

`hi` checks its built-in subcommands (`inbox`, `login`, `account`, and `daemon`) first. When the first argument starts with a lowercase ASCII letter and contains only lowercase letters, digits, or hyphens, `hi` searches absolute `PATH` directories for an executable named `hi-<name>` and invokes it with the remaining arguments. To send a literal word such as `workspace` as an initial session prompt instead of running a subcommand, pass `--` before the prompt (`hi -- workspace`).

Keep directories on your `PATH` writable only by trusted accounts, since `hi-<name>` executables run with your OS user's permissions. Inspect the bundled [`hi-import` helper](/docs/guides/import/) for a production example, or follow [build a client](/docs/guides/build-a-client/) when your subcommand needs to query or mutate sessions over H's local API. See the [CLI dispatch source](https://gitlab.com/parlant-co/harness/-/blob/main/clients/tui/src/cli.rs).
