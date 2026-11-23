---
layout: doc
title: 'Extend the hi CLI'
description: 'Add a client-side subcommand on PATH without loading code into the daemon.'
lang: en
permalink: /docs/guides/extend-hi/
---
A `hi` subcommand can be a separate executable. This is a local command lookup, not a startup package, an in-session slash command or a way to register a model tool.

* Contents
{:toc}

## Try a disposable command

In a Unix shell with `hi` installed, run this from a directory you control:

```sh
tools=$(mktemp -d "${TMPDIR:-/tmp}/hi-guide.XXXXXX")
printf '%s\n' '#!/bin/sh' 'printf "workspace: %s\n" "$PWD"' > "$tools/hi-workspace"
chmod 700 "$tools/hi-workspace"
PATH="$tools:$PATH" hi workspace
```

The result should print the current directory. No daemon or provider is involved. `mktemp -d` must return an absolute path; `hi` ignores relative `PATH` entries for this lookup. The `PATH` change applies only to the last command. To clean up, remove the example executable and its now-empty temporary directory.

## Dispatch rules

Built-in `inbox`, `login`, `account` and `daemon` commands win first. For an external name starting with a lowercase ASCII letter and containing only lowercase letters, digits or hyphens, `hi` searches for `hi-<name>` on absolute `PATH` entries and passes remaining arguments to the executable. Use `hi -- workspace` when you mean a **prompt** rather than the executable. That form can submit input; it isn't a discovery command.

Keep helper directories trusted: these executables run as your OS user. A real bundled example is [pi archive import](/docs/guides/import/). To add a helper that talks to H, follow [build a client](/docs/guides/build-a-client/) rather than modifying the store directly. [Dispatch implementation](https://gitlab.com/parlant-co/harness/-/blob/main/clients/tui/src/cli.rs)
