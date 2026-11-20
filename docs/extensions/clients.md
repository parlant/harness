# Clients: owner interactions and extension status

[Extensions index](../extensions.md) · [Current wire protocol](../protocol.md) · [Current `hi` status templates](../hi-status.md)

## Existing: what clients own

`hi` owns editing, navigation and presentation. It calls the owner-authenticated API and follows the durable conversation cursor; Phoenix may call H in-VM. `hi.json` supports local MiniJinja status templates and `/reload`. There is no client plugin ABI or extension status field. A client detaching does not stop a daemon task or become its owner.

## Implemented: device login

`/login [openai_codex [source]]` discovers configured aliases, or directly starts
a login for the selected alias. `openai-codex` is accepted as an alias. H
owns [device authorization and credential management](providers.md#implemented-credentials-in-core-policy-in-the-extension).
`hi` shows the fixed HTTPS URL and one-time user code in a focused overlay;
it never opens a browser or copies the code automatically. Escape requests
cancellation. A late cancel after successful installation shows completion
instead. `/account [source]` switches the stock alias, not the extension's pool order. `/model` is a separate action.

| Owner endpoint under `/api/v1` | Inputs → outputs |
|---|---|
| `GET /provider-logins` | `providers`: configured provider IDs, `device_code_v1` interaction, and source aliases with local availability and stock `active` status. No provider I/O. |
| `POST /provider-logins/start` | `provider`, `request_id`, optional `source` (defaults to the active stock alias or `default` on first login) → operation view; creates a valid missing alias. Same request ID and normalized inputs deduplicate while active and for 60 seconds after completion. |
| `POST /provider-logins/status` | `operation` → current or terminal operation view. No provider I/O. |
| `POST /provider-logins/cancel` | `operation` → terminal view, not necessarily `cancelled` if the result already settled. |
| `POST /provider-accounts/add` | `source` → `{ "source": "alias" }`. Idempotently adds a local alias without provider I/O. |
| `POST /provider-accounts/activate` | `source` → `{ "active": "alias" }`. Persists stock selection for future requests; does not change a pool or login flow. |

An operation view contains `operation`, `source` and `state` (`starting`,
`pending`, `complete`, `expired`, `cancelled`, or `failed`). Active responses
include `expires_in_ms`, `poll_after_ms`, and in the verification phase,
`verification_url` and `user_code`. Failed responses may include a sanitized
`reason`. Responses use `Cache-Control: no-store`. Clients must keep the
operation reference in POST bodies, not log it or put it in URLs. It
correlates a flow; it does not isolate separately attached owners of one daemon.
On ambiguous start retry only the same request ID. If the daemon restarts, the
flow is gone. Closing the terminal does not cancel; an unfinished login expires
under the daemon's independent deadline. Device instructions and credentials do
not enter session records or SSE.

## Proposed: one opt-in status projection

Start with an optional owner-authenticated **snapshot** read (proposed `GET /sessions/:sid/conversations/:cid/extension-status`) for the active conversation and its configured model. Return a version, scope, bounded freshness, and namespaced scalar values from cached package projections. No provider call, synchronous package callback, or transcript mutation on a status read. Failures omit that namespace. A read-only cache accessor is enough for the first status snapshot; don't generalize it into a package state service. This view does not share a sequence, replay buffer or cursor with conversation SSE. Add streaming only if polling is measured to be inadequate.

For the first package, show **pool availability for the selected model**, not a global active account and not an unverified balance. Example payload (names illustrative):

```json
{
  "version": 1,
  "session_id": "demo",
  "conversation_id": "1",
  "model": "openai_codex:gpt-6.1-sol",
  "max_age_ms": 5000,
  "extensions": {
    "account_pool": {"state": "available", "eligible_sources": 2}
  }
}
```

Define `eligible_sources` as locally eligible (configured, not disabled or known blocked); it is not a claim about credit or model access. A later dispatch-specific view may show an opt-in alias, never an email or provider account ID; it must be keyed and fenced to the actual attempt/scope, with explicit current-vs-last-used semantics and clearing rules. Do not publish it until that scope is available and tested. Unknown values stay absent. Validate namespaces, scopes, scalar types, counts and bytes. Freshness is the **remaining lifetime** of the cached projection, not a full TTL renewed on each read; expired data is omitted. The daemon remains the authority for deciding eligibility, not a UI template.

`hi` only polls if local config opts into extension status (e.g. a proposed `extension_status: true`, default `false`). Batch namespaces in one request, keep one in flight, back off on failure, and fence responses by backend, conversation, exact model and client/config generation. Clear expired/offline/unsupported data; any clear or update must leave the conversation cursor alone. An old daemon without the read is usable and should not receive repeated requests for an unsupported feature. Phoenix can consume the same projection; other clients can ignore it.

After implementation, this would be valid `hi.json` (it is not accepted by today's field allowlist):

```json
{
  "extension_status": true,
  "status_lines_append": ["{% if extensions.account_pool is defined and extensions.account_pool.eligible_sources is defined %}Eligible accounts: {{ extensions.account_pool.eligible_sources }}{% endif %}"]
}
```

Give `extensions` an empty-map default so guarded optional namespaces work in strict MiniJinja. Typos in top-level fields remain errors. Keep local template validation, control escaping, output budgets and clipping. Missing data can produce no row; an optional package never supplies executable templates or forces a widget. No dynamically installed Rust libraries, embedded language, arbitrary slash commands or remotely supplied forms. See [dynamic configuration](../hi-dynamic-config.md) for separate, local presentation ideas.

## Verification

Device login tests exercise the owner API, transient terminal rendering in fullscreen and regular mode, cancellation, dedupe and redaction with fake replies. For future status, test with old and new clients/daemons, target and same-provider model changes, absent namespaces/keys, expired cache, malformed/overlarge/control data, `/reload`, and no status polling without opt-in. Simultaneous clients must not share editor state, acquire task ownership or trigger provider quota calls by watching a row.
