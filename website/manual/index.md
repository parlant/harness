---
layout: doc
title: 'H manual'
description: 'Run a local coding session, share it between clients, and understand what happens when a turn is interrupted.'
lang: en
permalink: /docs/
---
H keeps a coding conversation in a local daemon, not in a browser tab or terminal. Start a turn in `hi`, inspect the files in the web app, and come back to the same session after disconnecting.

* Contents
{:toc}

## Run your first session

1. [Set up H](/docs/setup/) with one server and one data directory. A native bundle includes the web inbox, terminal client and Erlang runtime.
2. [Connect a provider](/docs/providers/). A Codex device login and an OpenAI API key are different credentials. Choosing a credential does not select a model.
3. Run `hi` in a project directory you trust. Use `/model` to choose a model and send a small question about the project. This can invoke a paid provider and tools with your user's access.
4. Open the same session in the [web inbox](/docs/web/). Use `/quit` to leave the terminal without stopping work.

## Work with a project

Use the [configuration reference](/docs/configuration/) to find which file, command or UI owns a setting. The [session guide](/docs/sessions/) explains when to fork history, start a new workspace or stop a run. The [terminal reference](/docs/terminal/) covers steering, follow-ups and local settings. For step-by-step tasks, see the [recipe index](/docs/guides/).

## Operate or change H

Read the [security boundaries](/docs/security/) before granting workspace or network access. [Daemon management](/docs/daemon/) covers upgrades, services and busy restarts. For client implementations, start with [build a client](/docs/guides/build-a-client/), the [architecture](/docs/architecture/) and [local API](/docs/protocol/). For optional code, browse the [extensions](/extensions/) or [contribute a change](/docs/contributing/).
