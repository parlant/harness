# H extension template: Greeting

Copy this directory to an extension checkout you control. Rename the modules, Mix app and IDs in `extension.json` and `lib/greeting.ex`. Keep all shipped modules under the root module named in the manifest. Keep the profile ID stable across compatible upgrades. This example registers one profile and starts one supervised `Agent` that supplies a deterministic instruction. It never calls a provider or edits a workspace.

From the extension checkout, using the same Elixir/OTP versions as your daemon:

```sh
export H_SOURCE=/absolute/path/to/h-source   # unnecessary inside the H examples directory
mix deps.get
mix format
mix check                                  # check formatting and compile with warnings as errors
mix test                                   # no daemon or provider starts
mix extension.build                        # writes dist/greeting/{extension.json,ebin/}
```

`mix extension.build /absolute/path/to/new-install-dir` builds to a different, **new** directory. The task copies only the extension's own modules; H is a development dependency, not another copy of the daemon. There is no dependency installer at daemon startup. Stick to H's public behaviours and the standard library in API 1. Use the H source that matches the running daemon.

Set `extensions.json` in the daemon data directory (not the workspace):

```json
{
  "version": 1,
  "extensions": [
    {
      "path": "/absolute/path/to/extension/dist/greeting",
      "settings": {"instructions": "Prefer short explanations."}
    }
  ]
}
```

Start `h-daemon` and create a session via the owner API with `"harness_id": "example.greeting.v1"` and an absolute `cwd`. The profile has no tools and does not change the provider or model. `hi` can attach to that session by ID; it doesn't install or select extension packages. For development use a disposable `--data-dir` and don't submit to a real provider. See [Daemon extensions](../../docs/extensions/daemon.md) for bypass, restart and contribution rules.
