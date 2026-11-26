# Daemon composition and core hooks

[Extensions index](../extensions.md) · [Architecture](../architecture.md)

## Existing: start with local artifacts, not a custom distribution

Run [`h-daemon`](../../bin/h-daemon) with `--data-dir DIR` (or `H_DATA_DIR`, default `~/.local/share/h`). H reads `extensions.json` there at boot. If the file is absent, no extensions load. End users do not assemble a Mix project or release per set of extensions. Extension authors build and test their own code separately using the [extension template](../../examples/extension_template/README.md).

```json
{
  "version": 1,
  "extensions": [
    {"path": "extensions/greeting", "settings": {"instructions": "Prefer short explanations."}},
    {"path": "/opt/local/h-extensions/other", "enabled": false}
  ]
}
```

- `path` points to a **built directory**, not a checkout or `mix.exs`. Relative paths are relative to the daemon data directory. Absolute and `~/` paths also work. `enabled` defaults to `true`; a disabled entry's artifact is not inspected. `settings` defaults to an empty object. Keep secrets out of this file.
- `h-daemon -ne` and `h-daemon --no-extensions` bypass `extensions.json`, even if it is malformed. They do not edit it or disable core [device login and the stock account](../providers.md#managed-device-login). Use `H.serve(no_extensions: true)` programmatically, or `H_NO_EXTENSIONS=1` for the supplied Phoenix startup.
- An enabled artifact is required. A missing file, incompatible API, malformed artifact, duplicate registration, or failed child start blocks boot rather than serving a partly configured daemon. Remove/disable the entry or use the bypass to restore stock startup. In stock mode, execution of sessions that recorded an unavailable profile or environment reports unavailability; it does not substitute the builtin or rewrite their records. Catalog listing remains available. This is not a read-only history/export API.
- Only install artifacts and config from trusted owners and in directories those owners control. BEAM code runs with daemon authority, not in a sandbox. H does not search workspaces, compile Mix projects, install dependencies, add extension directories to the VM code path, or hot-reload BEAM code into a running daemon. Build new versions into a new directory (for example `mix extension.build dist/my-ext-v2`), update `extensions.json`, and run a cooperative draining restart (`hi daemon restart` or `hi daemon restart-service`). Inspect startup-loaded extensions at any time with `GET /api/v1/extensions` (`hi daemon extensions` / `H.Daemon.list_extensions/1`).

## Existing: API 1 artifact and ownership

An artifact has a regular `extension.json` with `id`, `api_version: 1`, and the fully qualified BEAM `module` name (for example `Elixir.Example.Greeting`). Its `ebin/` holds the root module and any submodules under that namespace. Use a unique namespace outside `H.*`. The daemon checks the API, duplicate extension IDs, and module collisions before loading the BEAMs. It obtains module names from trusted built artifacts, not by converting JSON strings to atoms. Use the matching Elixir/OTP build target and H API. Arbitrary app startup, packaged third-party dependencies and `@on_load` are not part of API 1.

The entry module implements [`H.Extension.configure/2`](../../lib/h/extension.ex). Validate the JSON settings and return `{:ok, %{harnesses: [...], environments: [...], children: [...]}}`, using only the fields needed, or a safe `{:error, :invalid_settings}`. The context has the extension `id` and daemon `data_dir`. Declare existing [harness](harness.md) and [environment](execution-env.md) registrations; do not start processes or perform effects in `configure/2`. Use normal OTP child specs for needed services. H validates registered IDs, profile/tool callbacks and tool schemas, and rejects collisions with `coding`, `pi`, and `host`. Installing an artifact does not change which harness ID a new session defaults to. Provider replacement is not part of this API.

[`H.serve`](../../lib/h.ex) and embedded [`H.Application`](../../lib/h/application.ex) share [instance boot](../../lib/h/daemon/instance.ex): acquire the store lock, start auth and catalog, load/validate extensions, start account services and `H.Extensions.Supervisor`, run session recovery, then bind listeners. Losing the instance lock or runtime fails the instance rather than silently rebinding identities. The owner API (`H.HTTP.Router`), Phoenix (`HWeb.Backend.InVM` / `HWeb.Backend.HTTP`), and `H.Daemon` read the startup-validated effective options. `H.Daemon` remains the command boundary; `H.Session.Server` alone commits transitions and starts effects after intent. Extension children restart under supervision; starting a child is not an instruction to replay an effect. Changing persisted identity semantics requires a new profile/env ID or an explicit migration.

The [MultiCodex extension](../../extensions/multicodex/README.md) also demonstrates
one optional `codex_account_policy` contribution. Its two callbacks are consumed
only by the Codex adapter; they are not generic hooks or provider replacement.

## Implemented: post-commit advisory daemon observers (`H.Extension.Observer`)

“Core” means semantics are the same for all H profiles, not that listeners or an extension registry must always be running. An extension can register `:observers => [MyObserver]` in `H.Extension.configure/2` implementing optional callbacks in `H.Extension.Observer`:

| Callback | Payload and timing | Semantics |
|---|---|---|
| `command_committed/1` | Session/conversation, sequence, command kind, sanitized receipt summary for a newly committed command. Strictly after `Storage.commit/2`, never on a dedupe lookup. | Observe only. No raw command, draft, provider credential, or unfiltered arguments. A receipt is not execution completion. |
| `work_settled/1` | Same scope and sequence, task identity/kind, and a bounded, sanitized terminal outcome. Strictly after terminal commit (including recovery outcomes). | Observe only. Not for partial output, attempts, or timers. |

`H.Extensions.Observers` fans out asynchronously (`GenServer.cast/2`) after successful commit into a supervised consumer off `H.Session.Server` with a bounded 256-event queue and `try/rescue/catch` isolation. Delivery is advisory: it can drop under saturation and never advances a client's durable cursor or mutates session state.

**Not hooks:** input vetoes, response rewrites after commit, arbitrary command injection, and long-lived tool approval. To guarantee any of these semantics would require an explicit typed transition and conflict/revalidation rules, or a durable wait, not an observer return value.

## State and verification

Use explicit package-owned supervised children only when needed. A package may own per-instance state in memory and versioned storage under its own directory if persistence is required. Define state scope, expiry, restart/rollback and migration in that package. No shared package document in H's journal, client-issued writes to package internals, or generic `init/handle_event` extension lifecycle. Status and transient login flows are not persisted; credential persistence is the narrow exception described in [Providers](providers.md).

Verification uses a deterministic path package and lifecycle probe with disposable storage and fake effects. The [daemon integration tests](../../test/h/extensions_test.exs) exercise TCP, UDS, VM recovery, and no substitution if a recorded identity is unavailable. The [in-VM test](../../clients/web/test/h_web/extension_boot_test.exs) uses the template artifact with the embedded daemon and Phoenix backend. Neither needs an observer or a profile hook.
