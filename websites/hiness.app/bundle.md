---
layout: article
lang: en
permalink: /bundle/
title: Inside the H.app macOS bundle
kicker: macOS Packaging · co.parlant.harness
lead: How H.app packages a native AppKit menu-bar supervisor, an embedded Erlang/OTP 29 release, and native Rust CLI tools into a single relocatable macOS application bundle.
description: Technical reference for the H.app macOS application bundle on hiness.app, covering directory layout, PATH linking, daemon ownership, and code signing.
artwork: maximilian_khm
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

## Install and verify H.app on macOS

Download `H-v0.5.1-darwin-arm64.dmg` (or `H-v0.5.1-darwin-arm64.app.zip`), `SHA256SUMS`, `SHA256SUMS.sig`, and [`release-signers`](https://github.com/parlant/harness/blob/main/packaging/keys/release-signers) from [GitLab Releases](https://gitlab.com/parlant-co/harness/-/releases/permalink/latest) or [GitHub Releases](https://github.com/parlant/harness/releases):

```sh
curl -fLO https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/H-v0.5.1-darwin-arm64.dmg
curl -fLO https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/SHA256SUMS
curl -fLO https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/SHA256SUMS.sig
curl -fLO https://raw.githubusercontent.com/parlant/harness/main/packaging/keys/release-signers

ssh-keygen -Y verify -f release-signers \
  -I bingboombam@parlant.xyz -n file \
  -s SHA256SUMS.sig < SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Mount the disk image, copy `H.app` into `/Applications`, clear the browser quarantine attribute if present, and launch the menu-bar supervisor:

```sh
hdiutil attach H-v0.5.1-darwin-arm64.dmg -nobrowse -mountpoint /Volumes/H
ditto /Volumes/H/H.app /Applications/H.app
hdiutil detach /Volumes/H
xattr -dr com.apple.quarantine /Applications/H.app
open /Applications/H.app
```

After launch, click **H -> Copy Owner Sign-In Token** (`⌘C`) to authenticate `http://127.0.0.1:4200/inbox`, and click **H -> Install 'hi' Command Line Tool...** to symlink `hi` and `hi-import` onto your `PATH`.

## Set up workspace access

Keep `H.app` in `/Applications` before granting folder access. Open **H -> Permissions & Setup** for the native setup guide, links to macOS privacy settings, and **Reveal hi-exec in Finder**. H starts its bundled daemon through this helper.

Open the project folder you intend to use and respond to any macOS folder prompt. Review those decisions under **System Settings -> Privacy & Security -> Files & Folders**. Projects in `~/Projects` avoid many prompts associated with Desktop, Documents, and Downloads.

Full Disk Access is optional and gives H and its tools broad access to sensitive user data. Grant it only when your work requires that access. The setup guide can reveal the exact helper path for the settings file picker. After changing permissions, choose **H -> Drain & Restart Daemon**.

If the menu reports an external daemon, permissions granted to `H.app` may not apply to that process. Follow the setup guide to check and drain the existing service before reopening H. H leaves an existing service under its current owner.

Ordinary coding and folder access require neither Accessibility nor Screen Recording permission. The setup guide links to those settings for future computer-control work; H does not currently request or use them.

Read the [native setup guide implementation](https://github.com/parlant/harness/blob/main/packaging/macos/HApp.swift) for the permission and daemon-ownership checks.

## Upgrade H.app

To upgrade `H.app` to a newer release:

1. Choose **Stop Daemon & Quit H** (`⌘Q`) from the menu bar so active turns drain cleanly.
2. Replace `/Applications/H.app` from the new `.dmg` or `.app.zip`.
3. Reopen `/Applications/H.app`. Existing `hi` and `hi-import` symlinks into `/Applications/H.app/Contents/Resources/harness/bin/` resolve to the upgraded binaries automatically, and `~/.local/share/h` retains all sessions and credentials.

If you prefer the Mix archive bootstrap on an Elixir 1.20 / OTP 29 workstation, install [`h_setup.ez` from the release](https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/h_setup.ez) with `mix archive.install`, then run `mix h.setup --service`; `H.app` and `mix h.setup` share `~/.local/share/h` cooperatively.

## What H.app runs on launch

When you open `/Applications/H.app`, macOS launches the compiled Swift executable at `H.app/Contents/MacOS/HApp` as an accessory status-bar application (`NSApplication.ActivationPolicy.accessory`).

1. **Data directory preparation**: `HApp` resolves `H_DATA_DIR` (defaulting to `~/.local/share/h`) and creates it with owner-only `0700` permissions if absent.
2. **External daemon detection**: `HApp` reads `~/.local/share/h/daemon.json` and checks whether the recorded PID is alive. When a LaunchAgent or terminal daemon is already serving that store, `H.app` attaches to it (`Status: Running (external daemon)`) rather than spawning a conflicting VM.
3. **Managed daemon startup**: When no daemon is active, `H.app` launches `Contents/Resources/harness/bin/h-daemon --data-dir ~/.local/share/h`, routes output to `~/.local/share/h/h-daemon.log` (`0600`), waits for readiness, and opens `http://127.0.0.1:4200/inbox` in your default browser.

Inspect the full launcher implementation in [`packaging/macos/HApp.swift`](https://github.com/parlant/harness/blob/main/packaging/macos/HApp.swift) and the bundle metadata in [`packaging/macos/Info.plist.in`](https://github.com/parlant/harness/blob/main/packaging/macos/Info.plist.in).

## Safe CLI installation onto PATH

Selecting **Install 'hi' Command Line Tool...** from the `H` status menu links both `hi` and `hi-import` from `H.app/Contents/Resources/harness/bin/` into your shell environment without touching system-protected paths.

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

To uninstall `H.app`, choose **Stop Daemon & Quit H** (`⌘Q`) in the menu bar, move `/Applications/H.app` to the Trash, and remove the `hi` and `hi-import` symlinks from your `PATH` bin directory. Your session history and credentials remain in `~/.local/share/h` until you delete that directory explicitly.

For full daemon administration, provider setup, and workspace session commands, continue to the [operator manual on hiness.dev](https://hiness.dev/docs/).
