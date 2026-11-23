# `h_setup` — Mix Archive Installer for Harness (H)

Zero-dependency Mix archive providing `mix h.setup` to download, cryptographically verify
(Ed25519 OpenSSH `SSHSIG` signature + SHA-256 via Erlang `:crypto`), and install signed
Harness (`hi`, `h-daemon`, `hi-import`) release bundles on macOS and Linux.

## Installation

From Hex (once published):

```sh
mix archive.install hex h_setup
```

From a prebuilt release `.ez` archive:

```sh
mix archive.install https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/h_setup.ez
```

From Git (sparse checkout of `installer/`):

```sh
mix archive.install git https://github.com/parlant/harness.git --sparse installer
```

Or locally from a checkout:

```sh
cd installer
mix do archive.build + archive.install
```

## Usage

```sh
mix h.setup
mix h.setup --version 0.1.0
mix h.setup --bin-dir ~/.local/bin --prefix ~/.local/opt/harness
mix h.setup --service --data-dir ~/.local/share/h
```
