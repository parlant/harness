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
      label: Switch clients mid-run
      url: /docs/guides/resume/
    secondary:
      label: Set up H locally
      url: /docs/setup/
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
