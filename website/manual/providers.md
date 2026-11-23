---
layout: doc
title: 'Providers and credentials'
description: 'Choose a model, save a write-only API key, or sign into Codex without handing credentials to a session.'
lang: en
permalink: /docs/providers/
---
Credentials belong to the daemon. The browser and `hi` share its catalog, but model selection belongs to a conversation. Adding a credential, selecting an alias and choosing a model are three separate operations.

* Contents
{:toc}

## API keys

In `hi`, run `/key set openai work`. Paste the key only when the **separate masked prompt** opens. `/key list` shows aliases, not key values. The first saved alias becomes active; use `/key use openai work` to select it if another alias was already active. In web **Account settings**, the same actions are write-only. Use `/model` to select the provider's model, or `/continue` after fixing a missing key for a paused input.

This works for `openai`, `anthropic`, `google`, `deepseek` and `openrouter`, plus registered named providers. Stored stock keys take precedence over shell keys without needing a restart; a background LaunchAgent won't normally see your shell exports. Neither saving a key nor seeing a model in the catalog verifies access or billing.

## ChatGPT account via Codex

With H running, enable device-code login for the ChatGPT account (or ask the workspace administrator), then run:

```sh
hi login
hi account list
```

Follow the displayed verification instructions in your browser. First login creates the `default` alias. For a separate alias, run `hi login openai_codex work`, then `hi account use work` if you want stock H to select it for subsequent requests. `/login` also works in a session. Select an `openai_codex:` model explicitly. Codex does not use an `OPENAI_API_KEY`, OpenAI API credits or a Codex executable. Device login is a local opt-in integration, not a hosted identity service.

`accounts.json` records aliases, not tokens. H alone manages its private credential files. After an interrupted refresh, sign in again rather than restoring an old refresh token. Stock H uses one active alias; [MultiCodex](/extensions/multicodex/) adds an optional account selection policy.

## Gemini: Developer API or Vertex AI?

| Route | Configure on the daemon |
|---|---|
| `google:` | `/key set google work` or `GOOGLE_API_KEY` for the Gemini Developer API |
| `google_vertex:` with a project | `GOOGLE_CLOUD_PROJECT` and optional `GOOGLE_CLOUD_LOCATION` (default `global`); provision application-default credentials for the daemon's user and make `gcloud` available |
| `google_vertex:` Express Mode | `GOOGLE_VERTEX_API_KEY` or `GOOGLE_CLOUD_API_KEY`; no project or region required |

For interactive ADC setup, `gcloud auth application-default login` is an operator action, not something H runs on your behalf. A Developer API key does not configure Vertex.

## Register a compatible endpoint

1. Open **Providers** in the web UI. Add a *new* provider ID, the service's HTTPS base URL (including `/v1` if needed), and its exact model IDs with limits and capabilities. H appends `/chat/completions`. Don't assign another service an ID that has keys saved.
2. Save the catalog. This stages `<data_dir>/openai-compatible.json` for next boot; it doesn't probe the endpoint or change the running registry. Alternatively, adapt the [credential-free example](https://gitlab.com/parlant-co/harness/-/blob/main/examples/providers/openai-compatible.json), preserving existing entries. The file must not be group- or world-writable.
3. From a built checkout preflight with `bin/h-daemon --data-dir "${H_DATA_DIR:-$HOME/.local/share/h}" --check-config`. Restart the intended server **when idle**.
4. In `hi`, for provider ID `example-router`, use `/key set example-router default` and enter the secret in the masked prompt. Choose the exact `provider:model-id` in `/model`. Named routes use only the provider's active saved key; they do not try other providers or silently resume an interrupted dispatch.

For manual Codex access tokens and the owner-only `providers.json` format see the [full provider reference](https://gitlab.com/parlant-co/harness/-/blob/main/docs/providers.md).
