---
layout: doc
title: 'Configuration'
description: 'Find the owner and lifetime of each setting before editing a store, changing a model or restarting a service.'
lang: en
permalink: /docs/configuration/
---
First identify the daemon you are configuring. A project checkout is the working directory for tools; it isn't where H looks for provider credentials or startup packages. `H_DATA_DIR` selects the store, defaulting to `~/.local/share/h`.

* Contents
{:toc}

## Settings by owner

All paths below are relative to the selected data directory. Omit optional files when you don't need the feature.

| Setting | Where to change it | When it takes effect |
|---|---|---|
| Current conversation model and thinking | `/model` and `/thinking`, or the web session controls | Configure the conversation; changing a key does not select a model |
| Stock API-key alias or managed Codex login | `/key set`, `/key use`, `/login`, `/account` or web **Account settings** | Daemon-managed, for subsequent requests; don't edit live vault files |
| Manual provider settings and new-session default model | Private `providers.json` (regular file, mode `0600`) | Read on demand; an existing conversation retains its model |
| Named Chat Completions routes and model catalog | Web **Providers** or `openai-compatible.json` | Next daemon boot; keep credentials out of this file |
| Trusted local package paths | `extensions.json` | Next daemon boot; client-side `/reload` does not load code |
| Standalone listener addresses | `network.json`; launcher environment for `H_WEB_PORT` or `H_WEB` | Next standalone boot |
| Terminal appearance and shortcuts | `hi.json` and `hi-keybindings.json` | `/reload` in `hi`; no shared session mutation |

## Project instructions and tools

The `coding` harness collects `AGENTS.md` instructions from the workspace and its ancestors through the execution environment at session bootstrap unless instructions were explicitly overridden. Use this for review conventions, not for secrets or for installing code. A conversation can select only tools its profile installed; selecting none is different from promising in a prompt not to use them. A one-call directory override does not change the session's instruction source.

## Apply and check a change

For keys and accounts, follow [providers and credentials](/docs/providers/) and inspect alias names, never the secret value. For startup data, use the built launcher's `--check-config` with the intended `--data-dir`, then [restart when idle](/docs/daemon/). A successful preflight verifies startup configuration, not provider access, available billing or complete recovery of a live store. For client-only settings see [terminal preferences](/docs/terminal/#configure-the-terminal-footer).
