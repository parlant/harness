<p align="center">
  <strong><code>h_setup</code></strong> is a zero-dependency Mix archive that downloads, verifies, and installs signed release bundles for <strong>H</strong> (<code>hi</code>, <code>h-daemon</code>, <code>hi-import</code>) on macOS (<code>darwin-arm64</code>) and Linux (<code>linux-arm64</code>, <code>linux-x86_64</code>).
</p>

<p align="center">
  <img src="https://hiness.dev/assets/screenshots/hiweb-inbox.webp" alt="H multi-session inbox in hiweb showing ready and running sessions across workspaces" width="84%" />
</p>

<p align="center">
  <a href="https://hiness.dev">Website &amp; Manual (hiness.dev)</a> ·
  <a href="https://hiness.app">macOS App (hiness.app)</a> ·
  <a href="https://hex.pm/packages/hiness">Core Library (hiness)</a> ·
  <a href="https://hiness.hexdocs.pm/">HexDocs</a>
</p>

---

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
