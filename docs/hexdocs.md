# H (`hiness`) Elixir API Reference

<p align="center">
  <img src="https://hiness.dev/assets/screenshots/hiweb-inbox.webp" alt="H multi-session inbox in hiweb showing ready and running sessions across workspaces" width="84%" />
</p>

`hiness` packages the `:harness` OTP application (`H.*`): a local coding-agent daemon built on Elixir/OTP with durable branched conversations, file-backed WAL commits, multi-client streaming, and behaviour contracts for extensions, tools, storage backends, providers, and execution environments.

For binary installation (`hi`, `h-daemon`, `hiweb`, `H.app`), interactive walkthroughs, and the full operator manual, visit **[hiness.dev](https://hiness.dev)** and **[hiness.app](https://hiness.app)**. Find published versions and dependency metadata on **[Hex](https://hex.pm/packages/hiness)**, and browse source on **[GitHub](https://github.com/parlant/harness)** or **[GitLab](https://gitlab.com/parlant-co/harness)**.

## Why `:harness`

- **Durable branched sessions**: Every session is backed by an append-only WAL and snapshots (`H.Storage.File`). Conversations branch without copying transcripts, and interrupted work recovers cleanly across daemon restarts without replaying unsafe external side effects.
- **Process-per-session runtime**: Each active session runs under `H.Session.Supervisor` with explicit state transitions, workspace leasing (`H.WorkspaceLease`), cooperative draining, and idle unloading.
- **Multi-client by design**: Terminal (`hi`), web (`hiweb`), and in-VM Elixir callers share the same conversation over `H.Daemon` or local HTTP/SSE; disconnecting a client never stops a run.
- **Pluggable OTP contracts**: Implement `H.Extension`, `H.Harness`, `H.Tool`, `H.Storage`, `H.Provider`, `H.Provider.AccountPolicy`, or `H.ExecutionEnv` to customize behavior without forking the daemon.

## Embed `:harness` in an Elixir/OTP application

Use Elixir 1.20 and Erlang/OTP 29. Add this dependency to `mix.exs` and run `mix deps.get`. The dependency key is the OTP application (`:harness`); `hex: :hiness` selects the package on Hex.

```elixir
def deps do
  [
    {:harness, "~> 0.5.1", hex: :hiness}
  ]
end
```

To start an in-VM daemon with your application, configure a dedicated private store in `config/runtime.exs`:

```elixir
import Config

config :harness, data_dir: "/path/to/private/store"
```

With this configuration, `H.Application` starts the daemon without TCP or Unix API listeners by default. Call `H.Daemon` in-VM to create sessions, submit commands, and read conversation or catalog streams:

```elixir
{:ok, %{session_id: sid}} = H.Daemon.create_session(%{cwd: "/path/to/project"})
{:ok, _} = H.Daemon.submit(sid, %{"content" => "Summarize this repository."})
{:ok, session} = H.Daemon.get_session(sid)
```

Give each instance its own `:data_dir`; `H.StoreLock` holds the store exclusively. Host tools execute with the OS user's file and shell permissions.

For a standalone HTTP/SSE listener, leave the embedded configuration unset and call `H.serve/1` instead:

```elixir
{:ok, info} = H.serve(data_dir: "/path/to/private/store", port: 4100)
```

## Install the standalone CLI, web workbench, and macOS app

The Hex package contains the core daemon and its Elixir API. To install the signed native bundle (`hi`, `hiweb`, `h-daemon`), run the shell installer or Mix archive from **[hiness.dev](https://hiness.dev/docs/setup/)**:

```sh
curl -fsSL https://hiness.dev/install.sh | sh -s -- --service
```

On macOS (`arm64`), download `H.app` from **[hiness.app](https://hiness.app)** or the GitHub/GitLab releases.

## Module map and canonical guides

This HexDocs site documents the Elixir modules, callbacks, and typespecs of `:harness`. Read the architectural guides and operating instructions on **hiness.dev**:

| Topic | Elixir entry points | Guide on hiness.dev |
| --- | --- | --- |
| Daemon lifecycle & commands | `H`, `H.Application`, `H.Daemon`, `H.Catalog` | [Manage the daemon](https://hiness.dev/docs/daemon/) · [Local HTTP and SSE API](https://hiness.dev/docs/protocol/) |
| Session state & recovery | `H.Session`, `H.Conversation`, `H.Entry`, `H.Task`, `H.Submission` | [Architecture and recovery](https://hiness.dev/docs/architecture/) · [Sessions and branches](https://hiness.dev/docs/sessions/) |
| Extensions, harnesses & tools | `H.Extension`, `H.Harness`, `H.Tool`, `H.Harness.Coding` | [Write a startup extension](https://hiness.dev/docs/extensions/) · [Extension directory](https://hiness.dev/extensions/) |
| Execution environments & leases | `H.ExecutionEnv`, `H.ExecutionEnv.Host`, `H.ExecutionEnv.Remote`, `H.RemoteAgent.HTTP`, `H.WorkspaceLease`, `H.EnvRegistry` | [Security boundaries](https://hiness.dev/docs/security/) · [Subagents](https://hiness.dev/docs/guides/subagents/) |
| Storage & providers | `H.Storage`, `H.Storage.File`, `H.Storage.Memory`, `H.Provider`, `H.Accounts` | [Configure providers](https://hiness.dev/docs/providers/) · [Configuration](https://hiness.dev/docs/configuration/) |
