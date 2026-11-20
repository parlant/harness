# Model providers

The daemon resolves provider credentials, not the browser or terminal client.
Use the daemon's write-only credential profiles for API keys or device login
for Codex. Environment credentials and private `providers.json` are also
available for manual setups. For Phoenix this is
`${H_DATA_DIR:-$HOME/.local/share/h}`; for `H.serve()` it is the `data_dir`
option or `~/.local/share/h`. Both clients use the same model catalog.

## API keys for a background daemon

A LaunchAgent does not inherit exports from your interactive shell. H does not
copy those exports into launchd or into its vault. In `hi` use
`/key set openai work` and paste the key into the **separate masked prompt**;
never put a key in a slash-command argument or a conversation message.
`/key list` shows provider and alias names only. To choose among saved aliases,
use `/key use openai work`. The first saved alias becomes active; later ones
are selected explicitly. Phoenix has the same controls in **Account settings**.

Supports API keys for `openai`, `anthropic`, `google` (Gemini Developer API),
`deepseek`, and `openrouter`, with up to eight aliases per provider. Codex
continues to use `/login`, and Vertex keeps its existing Express/ADC setup.
The active stored key takes precedence over the corresponding daemon
environment variable; without a stored profile the environment still works.
Explicit server-side `credentials_opts[:api_key]` takes precedence over both.
The daemon resolves the key on the next request, so saving or switching does
not require a restart. If a run paused for missing credentials, use `/continue`
after setup. Presence of a key is not a provider-side validation check.

The vault is `<data_dir>/credentials/api-keys.json`, an owner-only, atomically
replaced file. Keys do not go into the transcript, account listings, the
LaunchAgent plist, or `accounts.json`. This is OS-user protection, not a
keychain or a sandbox for tools running as the same user. Revoke old keys in
the provider dashboard when rotating them.

## H-owned settings

`providers.json` must be a regular file (not a symlink) with no group or other
access, for example mode `0600`. H reads it on demand and does not write it.
The file is optional; omit sections and fields you don't use.

```json
{
  "version": 1,
  "default_model": "openai_codex:gpt-6.1-sol",
  "openai_codex": {
    "access_token": "REPLACE_WITH_OAUTH_ACCESS_TOKEN",
    "account_id": "REPLACE_WITH_ACCOUNT_ID",
    "expires_at_ms": 0,
    "transport": "websocket"
  },
  "google_vertex": {
    "project_id": "your-gcp-project",
    "location": "global"
  }
}
```

Set `expires_at_ms` to the real Unix expiry in milliseconds; `0` is already
expired. For Vertex Express Mode, use `"google_vertex": {"api_key": "..."}`
in place of the project and location. Environment credentials and explicit
provider options can override the file. Keep it out of Git.

## OpenAI Codex

Codex uses ChatGPT OAuth, not `OPENAI_API_KEY` or the OpenAI API credit
balance. Use managed device login on a local daemon, or provision a current
access token manually.

### Managed device login

With a running daemon, use `hi login` without a session, `/login` in a session,
or **Account settings** in Phoenix. On a fresh daemon, choose “Set up Codex
device login” in the UI or run `hi login` directly. The daemon creates
`accounts.json` with an alias named `default`; it does not need a restart. To
choose a different first alias or add another one and sign in, run
`hi login openai_codex work` (inside a session: `/login openai_codex work`).
`openai-codex` is also accepted. Enable device-code login in your ChatGPT
security settings or ask your workspace administrator. Use `/model` to select
a Codex model; login does not change the conversation's model.

`hi account list`, `hi account add work`, and `hi account use work` also work
without a session. Inside a session use `/account`, `/account add work`, or
`/account work`. Phoenix exposes the same operations at `/settings/accounts`.
The daemon validates and atomically writes the shared configuration. The first
alias becomes active; signing into additional aliases does not select them.
Stock H uses only the active alias. An explicit switch persists across restart
and affects future stock requests, not a loaded MultiCodex pool. A slot cannot
be silently rebound to another account or workspace identity.

The file contains no tokens. An equivalent hand-written file (edit only while
H is stopped) looks like this:

```json
{
  "version": 1,
  "openai_codex": {
    "sources": ["personal", "work"],
    "active": "personal"
  }
}
```

Without configured aliases or an enabled pool, the manual credential chain is
unchanged. An enabled MultiCodex pool can boot before its accounts exist or
are signed in. Until a pool alias is ready, only Codex inference is unavailable;
there is no fallback to a different billing identity. Once an
alias exists, managed Codex uses SSE without opaque continuation history and
won't fall through to a different alias or a manual token on error. Remove
`accounts.json` with H stopped and restart to return to manual credentials
(disable any configured pool first).

Device login needs no Codex executable, SDK, or Pi files. This **local-only,
opt-in** integration speaks the first-party Codex device protocol, not a stable
third-party API. Provider changes can break it. Don't deploy it as a hosted
sign-in service. To automatically select from accounts with observed quota or
credits, separately build and enable the [MultiCodex path extension](../extensions/multicodex/README.md).
`bin/h-daemon -ne` disables the extension but keeps stock account handling.

H alone reads/writes `credentials/` in its data directory, using `0700`
for the directory and versioned `0600` files. Do not edit or copy live files or
restore an old refresh-token backup after rotation; sign in again. If a
refresh was interrupted or its result was lost, H requires sign-in rather than
reusing the old grant. This is OS-user protection, not a sandbox or keychain:
host tools and other processes under the same user can access the files. Removing
an alias does not revoke it or delete its credential file. Use ChatGPT account
controls to revoke access; H has no `/logout` yet. See [design and limits](extensions/providers.md).

### Manual access token

1. Provision a **current Codex OAuth access token** in the running daemon's
   `providers.json` (above), or in its process environment (below). Use the
   data directory of the daemon you actually attach to, not the workspace.
2. Start the daemon if needed (from a built checkout, `bin/h-daemon`),
   then launch `hi` from the project. In an existing conversation use `/model`
   and pick `openai_codex:gpt-6.1-sol` or another model your account can use.
   `default_model` in the file applies to new sessions; an explicit daemon
   model setting takes precedence. `openai-codex:<model>` is also accepted.
   If the picker shows **Codex sign-in required**, check the daemon's data
   directory, file permissions and token expiry. Listing a model is not an auth check.
3. Use SSE first (the default). If the copied token expires, replace the
   H-owned copy. Setting `"transport": "websocket"` is optional, not required
   for Codex setup.

If moving from Pi, copy only the selected account's values into H's file:
`access` → `access_token`, `accountId` → `account_id`, and `expires` →
`expires_at_ms` (MultiCodex uses `accessToken` and `expiresAt`). Do not copy
refresh tokens, the whole account store, or a symlink to it. H does not read Pi
files, run Pi, or refresh a copied token. Replace the H-owned copy when it
expires. Alternatively set `OPENAI_CODEX_ACCESS_TOKEN` and, if the account ID
cannot be derived from the token, `OPENAI_CODEX_ACCOUNT_ID`.

## Google Vertex AI

Model IDs are `google_vertex:gemini-4-hydrogen`, `google_vertex:gemini-4-argon`,
and `google_vertex:gemini-4-carbon` (`google-vertex:` also works). These use
Vertex AI, not the Gemini Developer API (`google:`).

- **Project-scoped ADC:** set `GOOGLE_CLOUD_PROJECT` and optionally
  `GOOGLE_CLOUD_LOCATION` or `GOOGLE_CLOUD_REGION` (default `global`), or use the
  H file's `project_id` and `location`. Set up ADC with `gcloud auth
  application-default login`, or point `GOOGLE_APPLICATION_CREDENTIALS` at an
  ADC file explicitly provisioned for the daemon. H uses `gcloud` to obtain
  an access token; it does not initiate interactive login or reauth.
- **Vertex Express Mode:** set `GOOGLE_VERTEX_API_KEY` or `GOOGLE_CLOUD_API_KEY`,
  or put `api_key` in the H file. No project or region is needed. Remove the
  key from both the environment and the file to use ADC. `GOOGLE_API_KEY` is not
  used for Vertex.

Listing a model does not guarantee that the account, region, or project can use
it. Provider credentials are not stored in session records or sent to clients.
Host tools are not a sandbox; give the daemon OS user only the access you intend.
