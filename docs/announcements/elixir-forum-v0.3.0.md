# hiness 0.3.0 on Hex: a local Elixir/OTP daemon for coding-agent sessions

Hi Elixir Forum!

I built H because I wanted to close my terminal in the middle of a coding-agent run without stopping it. Now I can start a session in `hi`, close the client, and pick up the same conversation in the Phoenix LiveView workbench. The daemon keeps running; the terminal and browser are two ways to work with it.

You can also edit an earlier prompt and send it down a new branch without copying the transcript or losing the original. The branches share conversation history and still work in the same checkout.

## Embed it in an Elixir app

The core daemon is now available as [`hiness` 0.3.0 on Hex](https://hex.pm/packages/hiness), with an [Elixir API reference on HexDocs](https://hiness.hexdocs.pm/). On Elixir 1.20 / OTP 29, add this to your `mix.exs` dependencies:

```elixir
{:harness, "~> 0.3.0", hex: :hiness}
```

`hiness` is the package name; `:harness` is the OTP application and configuration key. Give it a private data directory and call `H.Daemon` in the same VM without opening an HTTP port. See the [embedding guide](https://hiness.hexdocs.pm/overview.html#embed-harness-in-an-elixir-otp-application) for the configuration and extension points.

## Try the terminal and web clients

The [signed v0.3.0 bundles on GitHub](https://github.com/parlant/harness/releases/tag/v0.3.0) and [GitLab](https://gitlab.com/parlant-co/harness/-/releases/v0.3.0) include `hi`, `hiweb`, and the runtime for macOS Apple Silicon and Linux x86-64/ARM64. You don't need Elixir installed to try a bundle. In v0.3.0, the web workbench gained a session sidebar, drag-and-drop attachments, expandable tool-call groups, and live subagent cards. The daemon also unloads idle sessions and wakes them when a request needs them.

The OTP part was the most interesting to build. A session coordinator commits intent to a local log before dispatching work. If the daemon crashes during a shell command or file write, it records the interruption instead of automatically running the operation again. Host tools run with your OS user's permissions, and model requests send conversation context to the provider you configure.

I'd love feedback on the [architecture](https://github.com/parlant/harness/blob/v0.3.0/docs/architecture.md), especially from folks who've built systems that resume work after a crash. Where do you draw the line between retrying automatically and asking the user to inspect what happened?
