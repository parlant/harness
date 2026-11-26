---
layout: doc
title: 'Configuration'
description: 'Find the command, file, or UI control that owns each setting and check when changes take effect.'
lang: en
permalink: /docs/configuration/
---
Configure H through its data directory (`H_DATA_DIR`, which defaults to `~/.local/share/h`). Your project checkout serves as the working directory for coding tools, while provider credentials, listener settings, and startup extensions live in `<data_dir>`.

* Contents
{:toc}

## Settings by owner

All file paths below resolve relative to your selected `<data_dir>`. Create optional JSON files only when you want to override the defaults.

| Setting | Where to change it | When it takes effect |
|---|---|---|
| Current conversation model, thinking level, budget, and approval policy | `/model`, `/thinking`, `/budget`, and `/approval` in `hi`, or the web session controls | Immediately for that conversation |
| API-key alias or Codex login / logout | `/key set`, `/key use`, `/key remove`, `/login`, `/logout`, `/account` in `hi`, or web **Account settings** | Immediately for subsequent requests through the daemon credential vault |
| Manual provider defaults and new-session default model | Private `providers.json` (regular file, mode `0600`) | Read on demand for new sessions while existing conversations keep their selected model |
| Custom Chat Completions endpoints and model catalog | Web **Providers** page or `openai-compatible.json` | Next daemon boot (save API keys separately via `/key set`) |
| Trusted local startup packages | `extensions.json` | Next daemon boot |
| Standalone listener addresses and web port | `network.json`, `H_WEB_PORT`, or `H_WEB` | Next standalone daemon boot |
| Terminal status bar, custom JSON themes, prompt templates, and keybindings | `hi.json`, `themes/*.json`, `prompts/*.md`, and `hi-keybindings.json` | Immediately when you run `/reload` in `hi` |

## Project instructions and tools

When a session starts, the `coding` harness profile loads `AGENTS.md` instructions from the workspace directory and its parent directories through the execution environment. Keep repository conventions and build commands in `AGENTS.md`. Select active tools for a conversation from the set installed by its harness profile; passing a one-call `cwd` override to a tool leaves the session's workspace binding and `AGENTS.md` source unchanged.

## Apply and check a change

Manage API keys and Codex logins through [providers and credentials](/docs/providers/) and verify them by alias name. After editing `openai-compatible.json`, `extensions.json`, or `network.json`, validate the configuration before restarting:

```sh
hi daemon start --check-config
```

Or from a source checkout:

```sh
bin/h-daemon --data-dir "${H_DATA_DIR:-$HOME/.local/share/h}" --check-config
```

Once `--check-config` succeeds, [restart the daemon](/docs/daemon/#choose-the-right-restart). For client-only display settings, see [configure the terminal footer](/docs/terminal/#configure-the-terminal-footer).
