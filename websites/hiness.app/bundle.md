---
layout: article
lang: en
permalink: /bundle/
title: Inside the H.app macOS bundle
kicker: macOS Packaging · co.parlant.harness
lead: How H.app packages a native AppKit menu-bar supervisor, an embedded Erlang/OTP 29 release, and native Rust CLI tools into a single relocatable macOS application bundle.
description: Technical reference for the H.app macOS application bundle on hiness.app, covering directory layout, PATH linking, daemon ownership, and code signing.
artwork: maximilian_khm
artwork_hook: Imperial Seal · KHM Vienna
specs_title: H.app technical profile
specs:
  - label: Bundle ID
    value: co.parlant.harness
  - label: Minimum OS
    value: macOS 14.0 (Sonoma)
  - label: Architecture
    value: arm64 (Apple Silicon)
  - label: App Policy
    value: LSUIElement (Menu Bar)
  - label: Data Store
    value: ~/.local/share/h
  - label: Web Inbox
    value: 127.0.0.1:4200/inbox
---

* On this page
{:toc}

## What H.app runs on launch

When you open `/Applications/H.app`, macOS launches the compiled Swift executable at `H.app/Contents/MacOS/HApp` as an accessory status-bar application (`NSApplication.ActivationPolicy.accessory`).

1. **Data directory preparation**: `HApp` resolves `H_DATA_DIR` (defaulting to `~/.local/share/h`) and creates it with owner-only `0700` permissions if absent.
2. **External daemon detection**: `HApp` reads `~/.local/share/h/daemon.json` and checks whether the recorded PID is alive. When a LaunchAgent or terminal daemon is already serving that store, `H.app` attaches to it (`Status: Running (external daemon)`) rather than spawning a conflicting VM.
3. **Managed daemon startup**: When no daemon is active, `H.app` launches `Contents/Resources/harness/bin/h-daemon --data-dir ~/.local/share/h`, routes output to `~/.local/share/h/h-daemon.log` (`0600`), waits for readiness, and opens `http://127.0.0.1:4200/inbox` in your default browser.

Inspect the full launcher implementation in [`packaging/macos/HApp.swift`](https://github.com/parlant/harness/blob/main/packaging/macos/HApp.swift) and the bundle metadata in [`packaging/macos/Info.plist.in`](https://github.com/parlant/harness/blob/main/packaging/macos/Info.plist.in).

## Safe CLI installation onto PATH

Selecting **Install `hi` Command Line Tool...** from the `H` status menu links both `hi` and `hi-import` from `H.app/Contents/Resources/harness/bin/` into your shell environment without touching system-protected paths.

`H.app` inspects your `PATH` and selects the first writable directory in this priority order:

1. Explicit `H_BIN_DIR` override when set in the environment.
2. Standard local prefixes already on `PATH`: `/usr/local/bin`, `/opt/local/bin`, `/opt/homebrew/bin`.
3. `~/.local/bin` when present on `PATH` and writable (or creatable).
4. Any other writable user directory on `PATH`, excluding `/System/*`, `/Library/*`, `Cellar`, version-manager `shims`, `.cargo/bin`, and `node_modules/.bin`.
5. Fallback to `~/.bin`.

If a target filename already exists and is a regular file rather than a symbolic link, `H.app` aborts and alerts you instead of overwriting it.

## Environment variables respected by H.app

Configure custom ports or isolated stores before launching `H.app`:

- `H_DATA_DIR`: override the default `~/.local/share/h` session and credential directory.
- `H_WEB_PORT`: change the loopback port opened by **Open H Web UI** (default `4200`).
- `H_BIN_DIR`: force a specific target directory when installing the `hi` and `hi-import` symbolic links.

`H.app` automatically prepends `/opt/homebrew/bin` and `/usr/local/bin` to the daemon's `PATH` if absent so workspace tools (`git`, `rg`, language toolchains) remain available when launched from Finder or Spotlight.

## Code signing and checksum verification

Every `H-v<version>-darwin-arm64.dmg` and `H-v<version>-darwin-arm64.app.zip` artifact is built by [`scripts/build-macos-app.sh`](https://github.com/parlant/harness/blob/main/scripts/build-macos-app.sh), which signs embedded `.dylib` and `.so` NIF libraries first, signs the ERTS and Rust executables next, and seals `H.app` last.

Verify the downloaded disk image against the repository's OpenSSH release signer key ([`packaging/keys/release-signers`](https://github.com/parlant/harness/blob/main/packaging/keys/release-signers)) and macOS `codesign`:

```sh
ssh-keygen -Y verify -f release-signers \
  -I bingboombam@parlant.xyz -n file \
  -s SHA256SUMS.sig < SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
codesign --verify --deep --strict --verbose=2 /Applications/H.app
```

For full daemon administration, provider setup, and workspace session commands, continue to the [operator manual on hiness.dev](https://hiness.dev/docs/).
