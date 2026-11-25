---
layout: doc
title: 'H manual'
description: 'Set up H locally, connect a model provider, switch between terminal and browser clients, and extend the daemon.'
lang: en
permalink: /docs/
artwork: farnese_ngi
---
H (`hiness.dev` and `hiness.app`) runs your coding sessions in a local daemon and stores committed history on disk. Start a turn in `hi`, inspect the working tree in `hiweb`, and reconnect to the same session at any time.

* Contents
{:toc}

## Run your first session

1. [Set up H](/docs/setup/) with a single daemon instance for your data directory. The signed release bundle includes the Erlang runtime, the `hi` terminal client, and the `hiweb` browser workbench.
2. [Connect a provider](/docs/providers/) by saving an API key or signing in with Codex device login.
3. Open a project checkout you trust and run `hi`. Use `/model` to select a model for the conversation, then submit a prompt. Note that model turns send context to your selected provider and allow tools to run with your OS user's permissions.
4. Open the same session in the [web client](/docs/web/) at `http://127.0.0.1:4200/inbox`. Run `/quit` in `hi` to close the terminal while the turn continues in the background.

## Work with a project

Check [configuration](/docs/configuration/) to see which command, file, or UI control manages each setting. Read [sessions and workspaces](/docs/sessions/) to branch a conversation, move work to another directory, or resolve a workspace writer wait. Use the [terminal client reference](/docs/terminal/) for steering, queued follow-ups, and status bar templates, or browse the [practical guides](/docs/guides/) for step-by-step workflows.

## Operate or extend H

Review the [security boundaries](/docs/security/) before exposing a network listener or running tools in an unfamiliar directory. Follow [manage the daemon](/docs/daemon/) to register a user service, drain active work, and upgrade releases. When building on H, start with [architecture](/docs/architecture/), the [local HTTP and SSE API](/docs/protocol/), and [build a client](/docs/guides/build-a-client/). To add startup modules or contribute upstream, read [build a local extension](/docs/extensions/), browse the [extension directory](/extensions/), or follow [contribute a change](/docs/contributing/).
