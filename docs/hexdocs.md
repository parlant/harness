# H (`hiness`) Elixir API Reference

`hiness` packages the `:harness` OTP application (`H.*`): the local coding-agent daemon with branched conversations, file-backed WAL commits, and behaviour contracts for extensions, tools, storage backends, and execution environments.

For binary installation (`hi`, `h-daemon`, `H.app`), interactive walkthroughs, and the full operator manual, visit **[hiness.dev](https://hiness.dev)** and **[hiness.app](https://hiness.app)**. Find published versions and dependency metadata on **[Hex](https://hex.pm/packages/hiness)**.

## Embed `:harness` in an Elixir/OTP application

Use Elixir 1.20 and Erlang/OTP 29. Add this dependency to `mix.exs` and run `mix deps.get`. The dependency key is the OTP application (`:harness`); `hex: :hiness` selects the package on Hex.

```elixir
def deps do
  [
    {:harness, "~> 0.3.0", hex: :hiness}
  ]
end
```

To start an in-VM daemon with your application, configure a dedicated private store in `config/runtime.exs`:

```elixir
import Config

config :harness, data_dir: "/path/to/private/store"
```

With this configuration, `H.Application` starts the daemon without TCP or Unix API listeners by default. Call `H.Daemon` in-VM to create sessions, submit commands, and read conversation or catalog streams. Give the instance its own `:data_dir`; `H.StoreLock` holds the store exclusively. Host tools execute with the OS user's file and shell permissions.

For a standalone listener, leave the embedded configuration unset and call `H.serve/1` instead:

```elixir
{:ok, info} = H.serve(data_dir: "/path/to/private/store", port: 4100)
```

## Install the standalone CLI and web workbench

The Hex package contains the daemon and its Elixir API. To run `hi` and `hiweb`, follow the [signed bundle installation guide](https://hiness.dev/docs/setup/).

## Module map and canonical guides

This HexDocs site documents the Elixir modules, callbacks, and typespecs of `:harness`. Read the architectural guides and operating instructions on **hiness.dev**:

| Topic | Elixir entry points | Guide on hiness.dev |
| --- | --- | --- |
| Daemon lifecycle & commands | `H`, `H.Application`, `H.Daemon`, `H.Catalog` | [Manage the daemon](https://hiness.dev/docs/daemon/) · [Local HTTP and SSE API](https://hiness.dev/docs/protocol/) |
| Session state & recovery | `H.Session`, `H.Conversation`, `H.Entry`, `H.Task`, `H.Submission` | [Architecture and recovery](https://hiness.dev/docs/architecture/) · [Sessions and branches](https://hiness.dev/docs/sessions/) |
| Extensions, harnesses & tools | `H.Extension`, `H.Harness`, `H.Tool`, `H.Harness.Coding` | [Write a startup extension](https://hiness.dev/docs/extensions/) · [Extension directory](https://hiness.dev/extensions/) |
| Execution environments & leases | `H.ExecutionEnv`, `H.ExecutionEnv.Host`, `H.WorkspaceLease`, `H.EnvRegistry` | [Security boundaries](https://hiness.dev/docs/security/) · [Subagents](https://hiness.dev/docs/guides/subagents/) |
| Storage & providers | `H.Storage`, `H.Storage.File`, `H.Storage.Memory`, `H.Provider`, `H.Accounts` | [Configure providers](https://hiness.dev/docs/providers/) · [Configuration](https://hiness.dev/docs/configuration/) |
