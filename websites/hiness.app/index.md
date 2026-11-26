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
    body: Download the signed disk image for drag-and-drop installation into /Applications, unpack the .app.zip archive in automation scripts, or pair H.app with the standalone CLI installer from hiness.dev.
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
        heading: Drag H.app to /Applications
        platform: H-v0.4.0-darwin-arm64.dmg · macOS 14.0+
        body: Download H-v0.4.0-darwin-arm64.dmg from GitHub Releases or GitLab Releases, open the disk image, and drag H.app into /Applications. On first launch, H.app prepares ~/.local/share/h (mode 0700), starts the embedded OTP daemon, places the bold H item in your macOS menu bar, and opens http://127.0.0.1:4200/inbox in your default browser.
        verify: codesign --verify --deep --strict --verbose=2 /Applications/H.app
        links:
          - label: Download from GitHub Releases
            url: https://github.com/parlant/harness/releases
          - label: Download from GitLab Releases
            url: https://gitlab.com/parlant-co/harness/-/releases/permalink/latest
      - id: zip
        label: App Archive (.app.zip)
        meta: Dotfiles & Automation
        heading: Unpack H.app with ditto on macOS
        platform: H-v0.4.0-darwin-arm64.app.zip
        command: |
          curl -fLO https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/H-v0.4.0-darwin-arm64.app.zip
          ditto -x -k H-v0.4.0-darwin-arm64.app.zip /Applications
          open /Applications/H.app
        body: Use Apple's ditto utility so Mach-O code signatures, symbolic links, and extended attributes inside Contents/Resources/harness stay intact when extracting from the terminal.
        links:
          - label: View release checksums & changelog
            url: /releases/
          - label: Verify Ed25519 signatures
            url: /bundle/#code-signing-and-checksum-verification
      - id: cli
        label: CLI + LaunchAgent
        meta: Headless Mac / Terminal-first
        heading: Install standalone CLI via hiness.dev
        platform: darwin-arm64 tarball
        command: |
          curl -fsSL https://hiness.dev/install.sh | sh -s -- --service
          hi daemon status
        body: Prefer a pure background LaunchAgent without a menu-bar item? Run the POSIX installer from hiness.dev. H.app detects an external daemon automatically via ~/.local/share/h/daemon.json and attaches without starting a duplicate server.
        links:
          - label: Open hiness.dev documentation
            url: https://hiness.dev/docs/daemon/
      - id: build-app
        label: Build H.app locally
        meta: Xcode CLT + Elixir + Rust
        heading: Compile H.app from source on your Mac
        platform: scripts/build-macos-app.sh
        command: |
          git clone https://github.com/parlant/harness.git
          cd harness
          scripts/build-bundle.sh dist/bundle-darwin-arm64
          scripts/build-macos-app.sh dist/bundle-darwin-arm64 dist/release
        body: Compiles the BEAM release, hiweb assets, Rust hi binaries, and Swift AppKit launcher (packaging/macos/HApp.swift), performs inside-out Mach-O code signing across every dylib, NIF, and executable, and outputs both .dmg and .app.zip.
        links:
          - label: Inspect packaging/macos/HApp.swift on GitHub
            url: https://github.com/parlant/harness/blob/main/packaging/macos/HApp.swift

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
