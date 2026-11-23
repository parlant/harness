---
layout: doc
title: 'MultiCodex'
description: 'Build or enable the optional Codex account policy, configure aliases, and diagnose an empty or mismatched pool.'
lang: en
permalink: /extensions/multicodex/
---
MultiCodex ranks authorized Codex accounts using cached usage observations. It does not log users in, keep refresh grants, change a session's model, or dispatch inference. H owns those operations. For a single account use [stock device login](/docs/providers/#chatgpt-account-via-codex) instead.

* Contents
{:toc}

## Locate the artifact

The native bundle includes a matching artifact in its `extensions/multicodex` directory. Point to that **artifact**, not the repository source directory with the same name. To build your own from the matching H checkout:

```sh
cd extensions/multicodex
mix deps.get
mix check
mix test
mix extension.build
```

The default new output is `dist/multicodex` **under the extension project**, containing `extension.json` and `ebin/`. Use the same Elixir/OTP versions as the daemon. If building outside the H repository, set `H_SOURCE` to the matching H checkout.

## Configure the pool

Merge the entry into `<data_dir>/extensions.json`, substituting the absolute built path:

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

List two to eight distinct aliases you are authorized to use together. `poll_ms` accepts 30000–600000 milliseconds; the default is 60000. No secrets belong here. Restart the daemon when idle, then sign in the configured aliases with `hi login openai_codex personal` and `hi login openai_codex work`. Check `hi account list` for the exact names. Missing aliases can be created at login without another restart. Select a Codex model for the conversation.

## How selection and rejection work

The supervised package polls usage serially in the background. When H asks for candidates, the package reads its cache: fresh quota headroom first, least used first, ties in configuration order. With `allow_credits: true` an explicit credit capacity can qualify after quota-backed accounts. Unknown, expired or workspace-blocked observations don't qualify. Observations are neither reservations nor a spending cap, even when credit-only candidates are excluded.

Only the adapter can authorize a second dispatch: at most one alternate on a structured HTTP `401 invalid_token` **before any inference output**, after closing the rejected stream and cooling down the source. A `429` invalidates cached observations, not permission to reroute the in-flight request. Timeout, EOF, cancellation and unknown failures do not switch accounts. The provider's first-party device and usage APIs may change; run this integration locally, not as a hosted sign-in or rate-limit workaround.

## If sign-in works but no alias is eligible

Wait for a polling cycle after startup or sign-in. The daemon may boot with no signed-in pool aliases; Codex inference fails without dispatch until an eligible account exists. Other providers aren't disabled. If H reports `codex_pool_alias_mismatch`, compare `hi account list` with `settings.sources`, correct the names and restart. `/account` only changes stock selection, not a loaded policy.

To return to stock mode, disable the entry (`"enabled": false`) and restart; for diagnosis, `--no-extensions` bypasses **all** configured packages without deleting accounts. Consult the [package README](https://gitlab.com/parlant-co/harness/-/blob/main/extensions/multicodex/README.md), [selection code](https://gitlab.com/parlant-co/harness/-/blob/main/extensions/multicodex/lib/multicodex.ex) and [provider boundary](https://gitlab.com/parlant-co/harness/-/blob/main/docs/extensions/providers.md).
