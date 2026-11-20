# MultiCodex

A separately built, trusted H extension for an explicitly configured pool of
Codex accounts. H still owns `/login`, credentials, refresh, and inference.
Nothing requires a Codex executable, Pi, or another SDK.

## Install

1. From this directory, build with the matching H source and Elixir/OTP:

   ```sh
   mix deps.get
   mix check
   mix test
   mix extension.build
   ```

   `H_SOURCE` can point to a matching H checkout. The default output is a new
   `dist/multicodex` directory containing only the manifest and namespaced BEAMs.
2. Add the **built artifact path**, not this source directory, to `extensions.json`
   in the daemon's data directory, then restart the daemon:

   ```json
   {
     "version": 1,
     "extensions": [
       {
         "path": "/absolute/path/to/dist/multicodex",
         "settings": {
           "sources": ["personal", "work"],
           "poll_ms": 60000,
           "allow_credits": false
         }
       }
     ]
   }
   ```

   List two to eight distinct aliases that you're authorized to use together.
   Set `poll_ms` between 30,000 and 600,000. The daemon can boot even if
   `accounts.json` is missing. `bin/h-daemon -ne` disables the pool but keeps
   device login and stock account selection.
3. Sign in with `/login openai_codex <alias>` for the matching aliases. The
   daemon creates missing aliases in [`accounts.json`](../../docs/providers.md#managed-device-login)
   without a restart. Until the pool has an eligible account, Codex requests
   fail without dispatch; other providers are unaffected.

## Policy

The extension polls the first-party Codex usage endpoint serially in the
background, using the [upstream usage schema](https://github.com/openai/codex/blob/ac784eb10e6d02486b00d383b64822b69473c0e8/codex-rs/codex-backend-openapi-models/src/models/rate_limit_status_payload.rs) as a compatibility reference. At inference time it only reads a cache: fresh quota headroom
first (least used first, ties in config order), then explicit credit capacity
if enabled. Unknown, expired, and workspace-blocked observations are not
eligible. Startup and fresh sign-in may need a polling cycle before an alias
becomes eligible. Provider balances and permissions can change before dispatch;
these observations aren't reservations or a guarantee of model access.
`allow_credits: false` excludes known credit-only accounts, but cannot cap
provider billing if quota changes between observation and dispatch.

H permits one alternate dispatch only after a structured HTTP `401 invalid_token`
that precedes all inference output. H closes the rejected stream, notifies the
extension to cool down that source, and asks for another candidate. H never
switches the in-flight request on `429`, unknown errors, timeout, cancellation,
or EOF. A transport `429` invalidates the pool's cached observations; selection
can resume on a later request after a fresh poll. This is not a means to work
around shared account/workspace limits. The first-party device and usage APIs
are not stable third-party contracts. Run this on a local daemon only.
