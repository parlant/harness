---
layout: home
lang: en
title: "H: a local AI coding harness"
description: H is a local coding-agent daemon with durable sessions, synchronized terminal and web clients, and a lean Elixir/OTP core you can extend.
sections:
  - layout: hero
    kicker: H / Local coding harness
    title: Close your terminal.
    emphasis: Your agent keeps working.
    body: H runs your coding-agent sessions in a local daemon. Start a code review in your terminal, quit the client, and follow the active run in your browser while H writes every turn to disk.
    primary:
      label: Install H
      url: "#install"
    secondary:
      label: Switch clients mid-run
      url: /docs/guides/resume/
  - layout: install
    id: install
    kicker: Install H
    title: Pick your installation method.
    body: Install a signed release bundle for macOS or Linux, run the Mix archive, drag the macOS app to Applications, or compile from a checkout. Every release verifies its OpenSSH signature and SHA-256 checksum before activating ~/.local/opt/harness/current.
    tablist_label: Installation methods
    links:
      - label: Read the full setup guide
        url: /docs/setup/
      - label: Manage the background daemon
        url: /docs/daemon/
    tabs:
      - id: shell
        label: Shell script
        meta: macOS & Linux
        heading: Install with the POSIX shell script
        platform: darwin-arm64 · linux-arm64 · linux-x86_64
        command: |
          curl -fsSL https://gitlab.com/parlant-co/harness/-/raw/main/scripts/install.sh | sh -s -- --service
        body: The script verifies the OpenSSH Ed25519 signature (bingboombam@parlant.xyz) and SHA-256 digest, unpacks the release under ~/.local/opt/harness/current, links hi and hi-import into the first writable directory on PATH (/usr/local/bin, /opt/local/bin, /opt/homebrew/bin, or ~/.local/bin, falling back to ~/.bin), and registers a per-user macOS LaunchAgent or Linux systemd --user service.
        verify: hi daemon status
        links:
          - label: Review /install.sh
            url: /install.sh
          - label: Verify release signatures manually
            url: /docs/setup/#install-a-signed-release
      - id: hex
        label: Hex / Mix
        meta: Elixir 1.18+
        heading: Install with the h_setup Mix archive
        platform: Erlang :crypto verification
        command: |
          mix archive.install https://gitlab.com/parlant-co/harness/-/releases/permalink/latest/downloads/h_setup.ez
          mix h.setup --service
          hi daemon status
        alt_label: "Or install the archive from Hex:"
        alt_command: |
          mix archive.install hex h_setup
        body: The Mix task verifies the same Ed25519 signature and SHA-256 checksum in Erlang :crypto, installs the self-contained runtime bundle under ~/.local/opt/harness/current so H runs independently of your project's Elixir version, and links hi onto PATH.
        links:
          - label: Configure providers after setup
            url: /docs/providers/
      - id: macos-app
        label: macOS app
        meta: Apple Silicon
        heading: Install H.app from the disk image
        platform: H-v0.1.0-darwin-arm64.dmg
        body: Download H-v0.1.0-darwin-arm64.dmg from GitLab Releases (or the GitHub Releases mirror), drag H.app to /Applications, and open it. H.app starts the bundled daemon on ~/.local/share/h, opens hiweb at http://127.0.0.1:4200/inbox, and adds the H menu-bar item to copy your sign-in token, link hi onto PATH, or drain and restart the daemon.
        links:
          - label: Download from GitLab Releases
            url: https://gitlab.com/parlant-co/harness/-/releases/permalink/latest
          - label: View GitHub Releases mirror
            url: https://github.com/parlant/harness/releases
      - id: source
        label: From source
        meta: Elixir 1.20 / OTP 29 + Rust
        heading: Build and install from a checkout
        platform: macOS & Linux
        command: |
          git clone https://gitlab.com/parlant-co/harness.git
          cd harness
          mix h.local --service
          hi daemon status
        body: This task compiles the OTP daemon, hiweb assets, and Rust hi client, runs the offline smoke suite, and activates the bundle under ~/.local/opt/harness/current. You can also clone from the GitHub mirror at https://github.com/parlant/harness.git.
        links:
          - label: Follow source build steps
            url: /docs/setup/#build-a-bundle-from-source-terminal-and-web
          - label: Run the live Phoenix dev server
            url: /docs/setup/#develop-from-source-instead
  - layout: principle
    id: recovery
    kicker: 01 / Durable sessions
    title: Keep your session across restarts.
    body: Disconnect a client at any time while the daemon keeps running. When the daemon itself restarts, H reloads committed session state from local files. If an unexpected crash interrupts a shell command or file edit, H records the interruption so you can inspect the checkout before deciding what to run next.
    links:
      - label: Inspect how H recovers work
        url: /docs/architecture/#storage-and-recovery
  - layout: clients
    kicker: 02 / Responsive, synchronized clients
    title: Switch clients. Stay in sync.
    body: Watch replies and tool calls stream to the terminal and browser at the same time. Start a turn in hi, open hiweb to review a diff, and keep each window on its own scroll position and branch.
    note: Run hi in your terminal or open hiweb in a desktop or mobile browser.
    demo:
      label: Walk through a conversation fork
      url: /demo/
    entries:
      - name: hi
        role: Terminal client
        body: Open a session from your checkout, browse earlier turns, and branch from the keyboard.
        url: /demo/hi/
      - name: hiweb
        role: Web workbench
        body: Triage workspaces in the inbox, comment on diffs, and follow live transcripts in the browser.
        url: /demo/hiweb/
  - layout: principle
    id: extensibility
    kicker: 03 / Extensible by design
    title: Build on a lean core.
    body: Connect your own client to the local HTTP and SSE API, package a harness profile or execution environment as a startup extension, or embed the :harness OTP application directly in your own BEAM VM. H uses a small set of direct dependencies and stores sessions in local files without an external database service.
    links:
      - label: Build a custom client
        url: /docs/guides/build-a-client/
      - label: Write a startup extension
        url: /docs/extensions/
      - label: Embed H in an Elixir/OTP application
        url: /features/#embed-h-in-an-elixirotp-application
  - layout: principle
    id: environments
    kicker: 04 / Execution environments
    title: Separate session state from tool execution.
    body: Run file and shell tools in your local checkout through H's execution environment contract. Because the session store and client connections stay independent of the workspace adapter, you can switch views freely while tools run in place. A built-in remote adapter exercises lease fencing inside the VM as the prototype for future off-machine execution.
    links:
      - label: Compare local execution and the remote prototype
        url: /features/#local-or-remote-execution-environments
  - layout: principle
    id: signals
    kicker: 05 / Signalling and waking
    title: Coordinate sessions without polling.
    body: Delegate a bounded task to a subagent and let the parent session park until the child finishes. H wakes the waiting parent on completion without occupying a worker process. External scripts can also queue follow-up turns through the authenticated local API while a run is active.
    links:
      - label: Delegate work and queue follow-ups
        url: /features/#signal-and-wake-sessions-without-polling
  - layout: architecture
  - layout: operating
    kicker: Before you start
    title: Run H on your machine.
    body: Start one daemon for your data directory and attach hi or hiweb. Host tools run with your OS user's file and shell permissions, and remote model providers receive the conversation context required for each request.
    link:
      label: Follow the local setup guide
      url: /docs/setup/
---
