# Model providers

The daemon resolves provider credentials, not the browser or terminal client.
Use environment variables on the daemon process, or create a private
`providers.json` in its data directory. For Phoenix this is
`${H_DATA_DIR:-$HOME/.local/share/h}`; for `H.serve()` it is the `data_dir`
option or `~/.local/share/h`. Both clients use the same model catalog.

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

Select `openai_codex:gpt-6.1-sol` or another bundled Codex model.
`openai-codex:<model>` is accepted too. Codex uses ChatGPT OAuth, not
`OPENAI_API_KEY` or the OpenAI API credit balance. SSE is the default; set
`"transport": "websocket"` to opt into WebSockets. An explicit daemon model
setting takes precedence over the file's `default_model` for new sessions.

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
