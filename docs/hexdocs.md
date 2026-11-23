# H (`hiness`) Elixir API Reference

`hiness` packages the `:harness` OTP application (`H.*`): the local coding-agent daemon with branched conversations, file-backed WAL commits, and behaviour contracts for extensions, tools, storage backends, and execution environments.

For binary installation (`hi`, `h-daemon`, `H.app`), interactive walkthroughs, and the full operator manual, visit **[hiness.dev](https://hiness.dev)** and **[hiness.app](https://hiness.app)**.

## Embed `:harness` in an Elixir/OTP application

Add `hiness` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:hiness, "~> 0.2.0"}
  ]
end
```

Start the daemon under your application's supervision tree by configuring a dedicated private `:data_dir` for `:harness` (see `H.Application`), or launch a standalone listener with `H.serve/1`:

```elixir
{:ok, info} = H.serve(data_dir: "/path/to/private/store", port: 4100)
```

Call `H.Daemon` in-VM to create sessions, submit idempotent commands, and subscribe to live conversation or catalog streams. Give each embedded instance its own `:data_dir` so `H.StoreLock` owns the store exclusively. Host tools execute with the OS user's file and shell permissions.

## Install the standalone CLI and web workbench

To run `hi` and `hiweb` as a standalone local tool without adding `:hiness` to a project's `mix.exs`, install a signed release bundle via `h_setup` on Hex or from [hiness.dev/#install](https://hiness.dev/#install):

```sh
mix archive.install hex h_setup
mix h.setup --service
```

## Module map and canonical guides

This HexDocs site documents the Elixir modules, callbacks, and typespecs of `:harness`. Read the architectural guides and operating instructions on **hiness.dev**:

| Topic | Elixir entry points | Guide on hiness.dev |
| --- | --- | --- |
| Daemon lifecycle & commands | `H`, `H.Application`, `H.Daemon`, `H.Catalog` | [Manage the daemon](https://hiness.dev/docs/daemon/) · [Local HTTP and SSE API](https://hiness.dev/docs/protocol/) |
| Session state & recovery | `H.Session`, `H.Conversation`, `H.Entry`, `H.Task`, `H.Submission` | [Architecture and recovery](https://hiness.dev/docs/architecture/) · [Sessions and branches](https://hiness.dev/docs/sessions/) |
| Extensions, harnesses & tools | `H.Extension`, `H.Harness`, `H.Tool`, `H.Harness.Coding` | [Write a startup extension](https://hiness.dev/docs/extensions/) · [Extension directory](https://hiness.dev/extensions/) |
| Execution environments & leases | `H.ExecutionEnv`, `H.ExecutionEnv.Host`, `H.WorkspaceLease`, `H.EnvRegistry` | [Security boundaries](https://hiness.dev/docs/security/) · [Subagents](https://hiness.dev/docs/guides/subagents/) |
| Storage & providers | `H.Storage`, `H.Storage.File`, `H.Storage.Memory`, `H.Provider`, `H.Accounts` | [Configure providers](https://hiness.dev/docs/providers/) · [Configuration](https://hiness.dev/docs/configuration/) |
