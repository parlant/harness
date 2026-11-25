# EditorHost Extension

Optional API-1 path-loaded live tool-host broker extension (`"editor_host"`).

Exposes:
- `Extensions.EditorHost`: `H.Extension` and `H.Extension.StatusProjection` (`namespace: "editor_host"`).
- `Extensions.EditorHost.Broker`: owner-paired short-lived single-claim host grants (SHA-256 + `Plug.Crypto.secure_compare/2`), workspace-bound pairing, monotonic `host_generation` fencing, process monitoring, concurrency capping, and invocation timeout/disconnect handling.
- `Extensions.EditorHost.Harness` (`id: "editor_coding"`): standard `H.Harness.Coding` tools plus `editor_buffer_summary`.
- `Extensions.EditorHost.BufferSummaryTool` (`name: "editor_buffer_summary"`): bounded live buffer summary proxy requiring an `expected_revision` precondition.

## Build & Check

```sh
mix check
mix test
mix extension.build
```

Configure in `<data_dir>/extensions.json` using the built artifact path:

```json
{
  "version": 1,
  "extensions": [
    {
      "path": "/absolute/path/to/dist/editor_host",
      "settings": {
        "grant_ttl_ms": 60000,
        "invocation_timeout_ms": 5000,
        "max_summary_bytes": 16384
      }
    }
  ]
}
```
