# `h_setup` Mix Archive Installer

`h_setup` is a zero-dependency Mix archive that downloads, verifies, and installs signed release bundles for **H** (`hi`, `h-daemon`, `hi-import`) on macOS (`darwin-arm64`) and Linux (`linux-arm64`, `linux-x86_64`).

Read the H operator manual, client walkthroughs, and alternative installation methods on **[hiness.dev](https://hiness.dev)** (and macOS `H.app` details on **[hiness.app](https://hiness.app)**).

## Install H with `mix h.setup`

Install the `h_setup` archive from the signed release, then run `mix h.setup`:

```sh
mix archive.install https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/h_setup.ez
mix h.setup --service
hi daemon status
```

`mix h.setup` verifies the OpenSSH Ed25519 signature (`bingboombam@parlant.xyz`) and SHA-256 digest in Erlang `:crypto`, unpacks the self-contained OTP release under `~/.local/opt/harness/current`, symlinks `hi` and `hi-import` into the first writable directory on `PATH` (`/usr/local/bin`, `/opt/local/bin`, `/opt/homebrew/bin`, or `~/.local/bin`, falling back to `~/.bin`), and registers a per-user macOS LaunchAgent or Linux `systemd --user` service when `--service` is passed.

## Next steps on hiness.dev

- [Set up H and make the first connection](https://hiness.dev/docs/setup/)
- [Configure model providers (`/login` and `/key set`)](https://hiness.dev/docs/providers/)
- [Manage and upgrade the background daemon](https://hiness.dev/docs/daemon/)
- [Embed `:harness` in an Elixir/OTP application](https://hiness.hexdocs.pm/overview.html#embed-harness-in-an-elixir-otp-application) · [`hiness` on Hex](https://hex.pm/packages/hiness)
