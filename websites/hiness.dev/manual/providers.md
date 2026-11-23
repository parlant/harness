---
layout: doc
title: 'Providers and credentials'
description: 'Save write-only API keys, sign in with Codex device login, or register an OpenAI-compatible model endpoint.'
lang: en
permalink: /docs/providers/
---
H stores provider credentials in `<data_dir>/credentials/` and shares the model catalog across `hi` and `hiweb`. Connect a provider in three steps: save a key or login alias, mark that alias active for the provider, and select a model in your conversation with `/model` or the web header.

* Contents
{:toc}

## API keys

In `hi`, run `/key set openai work` and paste the secret when the **masked input prompt** opens. Run `/key list` to view saved aliases. The first saved alias for a provider becomes active automatically; run `/key use openai work` to switch when you have multiple aliases. You can perform the same write-only actions in `hiweb` under **Account settings**. After saving a key, run `/model` to select a model from that provider, or run `/continue` to resume a turn that paused on a missing key.

Built-in API-key support covers `openai`, `anthropic`, `google`, `deepseek`, and `openrouter`, as well as any custom endpoints you register in `openai-compatible.json`. Keys stored in the daemon vault take effect immediately and override environment variables from the daemon's launch shell.

## ChatGPT account via Codex

With the daemon running, enable device-code login for your ChatGPT account (or ask your workspace administrator to enable it), then sign in from your terminal:

```sh
hi login
hi account list
```

Open the printed verification URL in your browser and enter the device code. Your first login creates the `default` alias. To add another account, run `hi login openai_codex work`, then run `hi account use work` to make it the active alias for subsequent turns. You can also start device login from inside an active session with `/login`. Select an `openai_codex:` model in `/model` to route turns through your ChatGPT subscription.

H records alias metadata in `accounts.json` and stores tokens in `<data_dir>/credentials/` with mode `0600`. If a token refresh fails or expires, run `hi login` again for that alias. To balance turns across two to eight authorized Codex accounts automatically, enable the [MultiCodex extension](/extensions/multicodex/).

## Gemini: Developer API or Vertex AI?

| Route | Configure on the daemon |
|---|---|
| `google:` | Run `/key set google work` or export `GOOGLE_API_KEY` for the Gemini Developer API |
| `google_vertex:` with a Google Cloud project | Export `GOOGLE_CLOUD_PROJECT` and optional `GOOGLE_CLOUD_LOCATION` (defaults to `global`), install `gcloud`, and configure Application Default Credentials for the daemon OS user |
| `google_vertex:` Express Mode | Export `GOOGLE_VERTEX_API_KEY` or `GOOGLE_CLOUD_API_KEY` |

When using Application Default Credentials with Vertex AI, run `gcloud auth application-default login` as the OS user that runs the H daemon before starting a `google_vertex:` turn.

## Register a compatible endpoint

1. Open **Providers** in `hiweb`. Enter a new provider ID, the service's HTTPS base URL (including `/v1` when required), and the exact model IDs with their context limits and capabilities. H appends `/chat/completions` to the base URL when dispatching requests.
2. Save the provider catalog to write `<data_dir>/openai-compatible.json` for the next daemon boot, or edit `<data_dir>/openai-compatible.json` directly from the [credential-free example](https://github.com/parlant/harness/blob/main/examples/providers/openai-compatible.json) (keep permissions owner-only).
3. Validate the updated catalog before restarting:

```sh
hi daemon start --check-config
```

4. Restart the daemon when idle, then save an API key for the new provider ID in `hi` (for example, `/key set example-router default`) and choose `example-router:<model-id>` in `/model`.

For manual Codex token files and the owner-only `providers.json` schema, read the [provider configuration reference](https://github.com/parlant/harness/blob/main/docs/providers.md).
