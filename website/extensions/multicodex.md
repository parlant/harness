---
layout: doc
title: 'MultiCodex'
description: 'Build or enable the MultiCodex account-selection policy, configure your alias pool, and verify account eligibility.'
lang: en
permalink: /extensions/multicodex/
---
MultiCodex polls usage windows for two to eight authorized Codex accounts and ranks eligible candidates for H's Codex provider adapter. H continues to manage device sign-in, token refresh, conversation model selection, and request dispatch. When you use a single Codex account, sign in directly with [stock device login](/docs/providers/#chatgpt-account-via-codex).

* Contents
{:toc}

## Locate the artifact

Point `<data_dir>/extensions.json` at the compiled `extensions/multicodex` artifact included in the native release bundle, or build the artifact from a matching H source checkout:

```sh
cd extensions/multicodex
mix deps.get
mix check
mix test
mix extension.build
```

`mix extension.build` writes the artifact to `dist/multicodex` inside the extension directory, containing `extension.json` and compiled BEAM files under `ebin/`. Build with the same Elixir and Erlang/OTP versions that run your daemon. When building outside the H repository tree, set `H_SOURCE` to the matching H checkout path.

## Configure the pool

Add the compiled artifact path and your alias list to `<data_dir>/extensions.json`:

```json
{
  "version": 1,
  "extensions": [
    {
      "path": "/absolute/path/to/bundle/extensions/multicodex",
      "settings": {
        "sources": ["personal", "work"],
        "poll_ms": 60000,
        "allow_credits": false
      }
    }
  ]
}
```

List two to eight distinct aliases that you are authorized to use in `settings.sources`. Set `poll_ms` between `30000` and `600000` milliseconds (`60000` by default). Keep credentials out of `extensions.json`; H stores tokens in its private credential vault.

Restart the daemon when idle, then authenticate each alias and verify the pool:

```sh
hi login openai_codex personal
hi login openai_codex work
hi account list
```

You can log in missing aliases after startup without restarting the daemon again. Choose an `openai_codex:` model in your conversation to use the pool.

## How selection and rejection work

MultiCodex polls usage for each configured alias serially in the background. When a turn requests a Codex model, MultiCodex ranks candidates from its cache: accounts with fresh quota headroom come first, ordered from lowest usage to highest, breaking ties by the order in `settings.sources`. When you set `allow_credits: true`, accounts with explicit credit capacity qualify after quota-backed accounts. Accounts with unknown, expired, or workspace-blocked observations are excluded.

If the first candidate returns a structured HTTP `401 invalid_token` before streaming any output, H's Codex adapter closes that stream, cools down the rejected alias, and tries at most one alternate candidate from the pool. An HTTP `429` marks the cached usage observation stale for the next poll, while timeouts, EOFs, and cancellations end the attempt immediately.

## Troubleshoot an empty or mismatched pool

Wait one polling cycle after daemon startup or after signing in a new alias. Until at least one configured alias reports eligible quota, H stops Codex turns before dispatch while other providers continue to run.

If H reports `codex_pool_alias_mismatch`, compare the output of `hi account list` against `settings.sources`, update `extensions.json` so the names match, and restart the daemon. While MultiCodex is active, it replaces the single-alias `/account` selector.

To return to single-account mode, set `"enabled": false` on the MultiCodex entry in `extensions.json` and restart the daemon, or start the foreground daemon with `--no-extensions` to bypass all extensions temporarily. For implementation details, read the [package README](https://gitlab.com/parlant-co/harness/-/blob/main/extensions/multicodex/README.md), [selection module](https://gitlab.com/parlant-co/harness/-/blob/main/extensions/multicodex/lib/multicodex.ex), and [provider policy contract](https://gitlab.com/parlant-co/harness/-/blob/main/docs/extensions/providers.md).
