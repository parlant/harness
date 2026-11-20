# H standalone bundle

Keep this directory together. `bin/hi` starts the daemon via its sibling
`bin/h-daemon`, using the runtime included here. No Mix or Elixir installation
is needed to run the bundle.

```sh
./bin/hi daemon start       # foreground, Ctrl+C to stop
./bin/hi daemon status      # in a second terminal
./bin/hi login              # optional Codex device login, no session needed
```

The bundled runtime does not put its internal Erlang tools on the `PATH`
used by host shell commands. Supply your normal development toolchain on the
launcher's `PATH` if a workspace needs it.

Run `bin/hi` from the project directory using its full path, or add the bundle's
`bin` directory to PATH. The daemon uses `H_DATA_DIR` or `~/.local/share/h` by
default. Use the same directory to retain your existing sessions, settings and
credentials, and stop any other daemon using that directory before starting.

The same daemon serves the web inbox at <http://127.0.0.1:4200/inbox>.
Sign in with `<data_dir>/auth.token`. Set `H_WEB_PORT` to choose another
port, or `H_WEB=0` to run without the web listener. To bind both services
to specific addresses, set `{"bind_addresses":["127.0.0.1","10.10.10.4"]}` in
`<data_dir>/network.json` and restart. Use non-loopback addresses only on
trusted, encrypted networks; these listeners serve plain HTTP.

On macOS, `bin/hi daemon install-service` installs a per-user LaunchAgent. Move
the bundle to a stable path before installing the service. `daemon restart-service` and
`daemon uninstall-service` manage that job. The job starts at login and after
abnormal exits. `daemon start-service` starts it after an intentional stop. `daemon restart` is for a standalone
foreground daemon and refuses to stop a busy instance.

`extensions/multicodex` is an optional artifact; it is not enabled by the
bundle. Existing configurations are left intact. `bin/hi daemon start
--no-extensions` skips path extensions while keeping stock account management.
