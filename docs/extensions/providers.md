# Providers: stock accounts and MultiCodex

[Extensions index](../extensions.md) · [Stock account setup](../providers.md#managed-device-login) · [Install MultiCodex](../../extensions/multicodex/README.md)

## Implemented: credentials in core, policy in the extension

- [`H.Accounts`](../../lib/h/accounts.ex) owns configured aliases, login, refresh
  and private files. Stock uses one active alias. `/account` is an explicit
  persisted selection for future requests in that daemon; no core fallback to another
  stored alias or manual token. `/login` creates a missing alias; only the first alias is selected implicitly.
- `H.Accounts` also owns [write-only API-key profiles](../providers.md#api-keys-for-a-background-daemon)
  for providers that use API keys instead of Codex OAuth. These profiles do
  not participate in MultiCodex selection.
- The [Codex auth client](../../lib/h/accounts/codex.ex) speaks the first-party
  device HTTP protocol used by [upstream Codex](https://github.com/openai/codex/blob/ac784eb10e6d02486b00d383b64822b69473c0e8/codex-rs/login/src/device_code_auth.rs).
  It does not read a Codex or Pi auth store. A token returned directly by the
  fixed TLS endpoint provides routing metadata, not proof of an H login identity.
  The device and usage endpoints are first-party compatibility surfaces, not a
  published third-party OAuth contract. Keep this opt-in and local-only.
- [`H.Accounts.Vault`](../../lib/h/accounts/vault.ex) is a single-writer store
  under the daemon's data-dir lock. Before a refresh consumes a rotating grant,
  H stores a reauthentication marker. An interrupted refresh or an ambiguous
  grant result requires a new login; it doesn't authorize replay. The private
  files are separate from session/catalog storage and not a same-UID security
  boundary.
- [MultiCodex](../../extensions/multicodex/README.md) is a path-loaded package.
  It owns the quota/spend parsing, polling cadence, cache and ordering. It uses
  the context's normal credential resolver in a background worker for usage
  requests. No polling in stock mode or on an owner's discovery read.

## Narrow adapter contract

The package contributes `codex_account_policy: %{module: mod, sources: aliases}`
through `H.Extension.configure/2`. Only one contribution is allowed. Its two
or more aliases can be configured before login. Boot does not require those
aliases or credentials to exist yet; only eligible signed-in aliases can be
selected, and an empty pool fails the Codex request without dispatch. The
module implements
[`H.Provider.AccountPolicy`](../../lib/h/provider/account_policy.ex):

| Callback | Inputs / authority |
|---|---|
| `order/2` | Canonical model ID and candidate aliases. Return a subset in preference order, using only cached data. No tools, transcript, transport options or token passed here. |
| `rejected/3` | Model, alias, and a sanitized `:invalid_token` or `:rate_limited` fact. May update eligibility. Cannot approve dispatch or reinterpret the failure. |
| `unavailable/2` *(optional)* | Model ID and candidate aliases. Returns a cached diagnostic (`:credits_disabled`, `:quota_exhausted`, `:workspace_blocked`, `:checking_usage`, or `:auth_cooldown`), whether to auto-wait (`wait: boolean()`), and an optional Unix-millisecond `wait_until_ms`. Never performs provider I/O. |
| `pool_status/1` *(optional)* | Configured aliases. Returns cached sanitized pool settings (`allow_credits`, `wait_when_exhausted`) and per-alias eligibility (`:eligible`, `:credits_only`, `:credits_disabled`, `:quota_exhausted`, `:workspace_blocked`, `:auth_cooldown`, `:checking`, `:unavailable`) with optional Unix-millisecond `reset_at_ms`. Never exposes credentials, account IDs, emails, or balances. |

These callbacks run in the provider worker or read-only status/catalog views, never in a
session commit. MultiCodex uses bounded calls to its own supervised cache. A
missing, invalid, or failing required policy does not fall through to stock or
ambient auth. When `order/2` returns `[]` before any dispatch is attempted and
`unavailable/2` returns `wait: true`, H returns a typed `pool_wait` diagnostic
(`codex_pool_credits_disabled`, `codex_pool_quota_exhausted`,
`codex_pool_workspace_blocked`, `codex_pool_auth_cooldown`, or
`codex_pool_checking_usage`). The session coordinator parks the task as
`sleeping` with `wake.reason == "pool_wait"`, subscribes to
`{:account_pool, :openai_codex}` on `H.PubSub`, arms a bounded fallback timer,
and wakes automatically when MultiCodex broadcasts
`{:account_pool_available, :openai_codex}` or when the conversation switches
models. Because zero external dispatches occurred, `pool_wait` never replays an
in-flight request; a VM crash during an active dispatch still settles as
`interrupted`. This is a trusted in-VM extension, not a sandbox. There is no
broad effect hook, provider-registration API, or extension-driven retry loop.

[`H.Provider.ReqLLM`](../../lib/h/provider/req_llm.ex) owns dispatch:

1. Walk the returned candidate list within a credential-resolution deadline.
   Skip a source only for typed local credential unavailability. The extension
   can filter on usage; core never observes balances to make this decision.
2. Send SSE to the existing Codex endpoint with one isolated token/account pair
   and no transport retries. Use portable instruction/text/image and ordinary
   tool history, not opaque reasoning, continuation IDs, or reusable WebSockets.
3. Retry at most once, on a **different account**, only when the pinned transport
   identifies an explicit HTTP `401 invalid_token` before any inference output.
   Close the first stream before reporting the fact and asking for an alternate.
   A bare 401, quota/credit error, `429`, timeout, cancellation, transport loss,
   incomplete stream, or failure after output cannot trigger fallback. A `429`
   reports unknown-scope rate limiting so the extension can discard stale usage
   observations for future requests, not rotate around a possible shared limit.
4. [`H.Session.Server`](../../lib/h/session/server.ex) persists a versioned
   one-dispatch (stock) or two-dispatch (pool) budget and no-auto-resume policy
   before managed generation or compaction. Worker loss, clean close, or VM
   restart does not replay either dispatch, even after disabling the extension.
   Older daemons don't honor the checkpoint; settle work before a downgrade.

**Not implemented:** retry after a quota rejection on the same request. That
requires a provider signal establishing both pre-acceptance and account-local
scope, not error text, absence of tokens, or a recently polled usage balance.
Cache ranking does not prove either fact. Use only identities authorized for
this use, and do not use a pool to bypass workspace/provider controls.

Tests cover a real path artifact, fixture usage, mocked auth and refresh,
ReqLLM's actual transport with local HTTP/SSE replies, terminal account
selection, and restart without replay. No live provider compatibility or
exactly-once billing claim.
