---
layout: home
lang: en
title: "H.app (hiness.app): Native macOS Menu-Bar Bundle for H"
description: Drag H.app to Applications on macOS Sonoma or later to launch the local H coding-agent daemon, open hiweb in your browser, and link hi onto PATH without installing Erlang or Rust.
sections:
  - layout: app-hero
    kicker: H.app · macOS Sonoma 14+ · Apple Silicon
    title: Run H from
    emphasis: your Mac menu bar.
    body: Drag H.app to Applications and open it. The app starts the local H daemon, opens your hiweb session inbox, and lets you install the bundled hi command from the menu bar.
    requirements: Requires macOS 14.0+ on Apple Silicon (arm64) · Signed .dmg & .app.zip · Bundle ID co.parlant.harness
    domain_links:
      - label: hiness.app · macOS H.app bundle
        url: "#download"
        current: true
      - label: hiness.dev · CLI, Daemon & Manual
        url: https://hiness.dev
    primary:
      label: Download H.app for macOS
      url: "#download"
    secondary:
      label: Inspect bundle architecture
      url: /bundle/

  - layout: install
    id: download
    kicker: Install H.app
    title: Choose how to install H on your Mac.
    body: Download the signed disk image for drag-and-drop setup into /Applications, unpack the .app.zip archive in dotfiles scripts, run the POSIX LaunchAgent installer, or build H.app locally.
    note: Requires macOS 14.0 (Sonoma) or newer on Apple Silicon (arm64). H.app bundles its own Erlang/OTP 29 runtime and Rust CLI tools inside Contents/Resources/harness.
    tablist_label: macOS installation options
    links:
      - label: Inspect the H.app bundle layout
        url: /bundle/
      - label: Read full CLI & Linux setup on hiness.dev
        url: https://hiness.dev/docs/setup/
    tabs:
      - id: dmg
        label: Disk Image (.dmg)
        meta: Recommended · Apple Silicon
        heading: Install H.app from the disk image
        platform: H-v0.5.0-darwin-arm64.dmg · macOS 14.0+
        primary:
          label: Download H-v0.5.0-darwin-arm64.dmg
          url: https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/H-v0.5.0-darwin-arm64.dmg
        steps:
          - title: Mount the disk image and copy H.app to /Applications
            body: Open H-v0.5.0-darwin-arm64.dmg in Finder and drag H.app onto the Applications folder shortcut.
          - title: Open H.app and sign into the web workbench
            body: Launch /Applications/H.app (if macOS Gatekeeper asks about an unnotarized download, Control-click H.app and choose Open once, or clear com.apple.quarantine below). H.app creates ~/.local/share/h, places H in your menu bar, and opens http://127.0.0.1:4200/inbox. Click H -> Copy Owner Sign-In Token (Command-C) and paste it on the login page.
          - title: Link hi onto PATH and connect a model provider
            body: "Click H -> Install 'hi' Command Line Tool... in the menu bar, then open any terminal in a project directory to sign in and start a session."
            code: hi login && hi
        alt_label: Optional Terminal install, quarantine clear & signature check
        alt_command: |
          curl -fLO https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/H-v0.5.0-darwin-arm64.dmg
          hdiutil attach H-v0.5.0-darwin-arm64.dmg -nobrowse -mountpoint /Volumes/H
          ditto /Volumes/H/H.app /Applications/H.app
          hdiutil detach /Volumes/H
          xattr -dr com.apple.quarantine /Applications/H.app
          open /Applications/H.app
        verify: codesign --verify --deep --strict --verbose=2 /Applications/H.app && hi daemon status
        links:
          - label: Mirror on GitHub Releases
            url: https://github.com/parlant/harness/releases
          - label: Verify Ed25519 release signatures
            url: /bundle/#code-signing-and-checksum-verification
      - id: zip
        label: App Archive (.app.zip)
        meta: Dotfiles & Automation
        heading: Unpack H.app with ditto and link hi
        platform: H-v0.5.0-darwin-arm64.app.zip · Apple Silicon
        command: |
          curl -fLO https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/H-v0.5.0-darwin-arm64.app.zip
          ditto -x -k H-v0.5.0-darwin-arm64.app.zip /Applications
          xattr -dr com.apple.quarantine /Applications/H.app
          open /Applications/H.app
        alt_label: Link hi and hi-import into ~/.local/bin from a script
        alt_command: |
          mkdir -p "$HOME/.local/bin"
          ln -sfn /Applications/H.app/Contents/Resources/harness/bin/hi "$HOME/.local/bin/hi"
          ln -sfn /Applications/H.app/Contents/Resources/harness/bin/hi-import "$HOME/.local/bin/hi-import"
        body: Extract with Apple's ditto command so Mach-O code signatures, symbolic links, and extended attributes inside Contents/Resources/harness remain intact, then clear the browser quarantine attribute before first launch.
        verify: /Applications/H.app/Contents/Resources/harness/bin/hi daemon status
        links:
          - label: View release checksums & changelog
            url: /releases/
          - label: Verify Ed25519 signatures
            url: /bundle/#code-signing-and-checksum-verification
      - id: cli
        label: CLI + LaunchAgent
        meta: install.sh or Hex
        heading: Install the LaunchAgent bundle from your terminal
        platform: harness-v0.5.0-darwin-arm64.tar.gz · h_setup 0.5.0
        command: |
          curl -fsSL https://hiness.dev/install.sh | sh -s -- --service
          hi daemon status
        alt_label: Or install via Hex (Elixir 1.20 / OTP 29) and open a session
        alt_command: |
          mix archive.install hex h_setup
          mix h.setup --service
          hi login && hi
        body: Installs ~/.local/opt/harness/current after verifying the OpenSSH Ed25519 signature, symlinks hi and hi-import into the first writable directory on PATH, and registers ~/Library/LaunchAgents/co.parlant.h.daemon.plist. If you also open H.app later, it detects the running LaunchAgent via ~/.local/share/h/daemon.json and attaches without starting a second daemon.
        verify: launchctl print "gui/$(id -u)/co.parlant.h.daemon"
        links:
          - label: Open daemon service guide on hiness.dev
            url: https://hiness.dev/docs/daemon/
          - label: View h_setup on Hex.pm
            url: https://hex.pm/packages/h_setup
          - label: Configure API keys & Codex login
            url: https://hiness.dev/docs/providers/
      - id: build-app
        label: Build from Source
        meta: Xcode CLT + Elixir + Rust
        heading: Compile and package H.app from source
        platform: scripts/build-macos-app.sh · Elixir 1.20 / OTP 29
        command: |
          git clone https://github.com/parlant/harness.git
          cd harness
          scripts/build-bundle.sh dist/bundle-darwin-arm64
          H_KEEP_APP=1 scripts/build-macos-app.sh dist/bundle-darwin-arm64 dist/release
          ditto dist/release/H.app /Applications/H.app
          open /Applications/H.app
        body: Compiles the OTP 29 release, hiweb assets, Rust hi and hi-import binaries, and Swift AppKit launcher (packaging/macos/HApp.swift), signs every embedded dylib, NIF, and executable inside-out, and writes H.app, .dmg, and .app.zip into dist/release/.
        verify: codesign --verify --deep --strict --verbose=2 /Applications/H.app
        links:
          - label: Inspect packaging/macos/HApp.swift on GitHub
            url: https://github.com/parlant/harness/blob/main/packaging/macos/HApp.swift
          - label: Read bundle architecture details
            url: /bundle/

  - layout: menubar
    id: menubar
    kicker: 01 / Native AppKit Menu-Bar Control
    title: Control the local daemon from your macOS status bar.
    artwork: margarita_khm
    body: H.app runs with LSUIElement enabled so your Dock and application switcher stay clear while you work in Xcode, Neovim, Zed, or Terminal. Every three seconds it inspects ~/.local/share/h/daemon.json and updates the status indicator between H (running) and H· (stopped).
    items:
      - title: Open H Web UI
        shortcut: ⌘O
        body: Ensures the local daemon is healthy and opens your multi-workspace session inbox and diff reviewer in Safari, Arc, Chrome, or Firefox.
        code: http://127.0.0.1:4200/inbox
      - title: Copy Owner Sign-In Token
        shortcut: ⌘C
        body: Copies the local owner authentication token from ~/.local/share/h/auth.token straight to your macOS Universal Clipboard so you can sign into hiweb immediately.
        code: ~/.local/share/h/auth.token
      - title: Install hi Command Line Tool
        body: Links the bundled hi and hi-import binaries into the first writable directory on your PATH (/usr/local/bin, /opt/local/bin, /opt/homebrew/bin, or ~/.local/bin) while refusing to overwrite non-symlinks.
        code: H.app/Contents/Resources/harness/bin/hi
      - title: Drain & Restart Daemon
        shortcut: ⌘R
        body: Invokes hi daemon stop to wait safely for active model turns or tool calls to settle before restarting the embedded OTP process.
        code: hi daemon stop

  - layout: bundle-anatomy
    id: anatomy
    kicker: 02 / Self-Contained macOS Bundle
    title: One .app folder. Zero Homebrew or runtime prerequisites.
    body: Everything H needs to run lives inside H.app/Contents/Resources/harness. Moving H.app or upgrading macOS leaves your sessions, workspaces, and provider credentials untouched in ~/.local/share/h.
    pillars:
      - tag: Native Launcher
        title: Swift + AppKit supervisor
        body: Compiled directly with swiftc targeting arm64-apple-macosx14.0. Polls daemon.json liveness, streams daemon logs to ~/.local/share/h/h-daemon.log (mode 0600), and adopts external daemons cleanly.
      - tag: Embedded BEAM & Rust
        title: Bundled ERTS, hiweb, and hi
        body: Ships its own Erlang/OTP 29 runtime, Elixir :harness coordinator, Bandit + Phoenix LiveView workbench, and native arm64 Rust terminal binaries with rewritten @rpath dylibs.
      - tag: Inside-Out Signing
        title: Strict Mach-O verification
        body: Every embedded .dylib, .so NIF, ERTS binary, Rust tool, and the outer H.app bundle is signed inside-out and verified with codesign --verify --deep --strict before packaging.
    cta:
      label: Read the complete bundle architecture guide
      url: /bundle/

  - layout: principle
    id: continuity
    kicker: 03 / Terminal and browser clients
    title: Start in Terminal. Review diffs in Safari.
    motto: One local store under ~/.local/share/h.
    artwork: leopold_gallery_khm
    artwork_wide: true
    body: Once H.app links hi onto your PATH, any terminal tab in Ghostty, iTerm2, Kitty, or Terminal.app connects to the exact same daemon that powers hiweb. Kick off a refactor from your repository checkout, close the terminal window, and comment on line-pinned diffs in the browser.
    links:
      - label: Walk through hi + hiweb on hiness.dev
        url: https://hiness.dev/demo/
      - label: Explore the iOS & iPadOS companion roadmap
        url: /ios/

  - layout: news-pulse
    id: news

  - layout: operating
    kicker: Companion Documentation & Source
    title: Looking for Linux bundles, Mix tasks, or extension APIs?
    body: Visit hiness.dev for the complete 16-chapter operator manual, extension authoring guides, HTTP/SSE wire specification, and Linux release tarballs. Host tools execute locally with your macOS user's permissions.
    link:
      label: Open the full manual on hiness.dev
      url: https://hiness.dev/docs/
---
