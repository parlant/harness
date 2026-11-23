---
layout: home
lang: en
title: "H: a local AI coding harness"
description: H is a local coding-agent daemon with durable sessions, synchronized terminal and web clients, and a lean core you can extend.
sections:
  - layout: hero
    kicker: H  /  Local coding harness
    title: Close your terminal.
    emphasis: Your agent keeps working.
    body: H is a local coding-agent daemon. Start a review in your terminal, quit the client, and follow the same run in your browser. The session is saved to disk.
    primary:
      label: See how to switch clients
      url: /docs/guides/resume/
    secondary:
      label: Set up locally
      url: /docs/setup/
  - layout: principle
    id: recovery
    kicker: 01 / Durable sessions
    title: A restart shouldn’t erase your work.
    body: The daemon keeps running when a client disconnects. If the daemon itself restarts, H restores saved session state from local files. It marks an interrupted shell command instead of rerunning it, because the command may already have changed something.
    links:
      - label: How H recovers work
        url: /docs/architecture/#storage-and-recovery
  - layout: clients
    kicker: 02 / Responsive, synchronized clients
    title: Switch clients. Stay in sync.
    body: Session updates stream to both clients as work happens. Start a turn in the terminal and follow it in the browser without moving the terminal reader’s place.
    note: Use the terminal UI or open hiweb in a desktop or mobile browser.
    demo:
      label: See what happens when you fork a conversation
      url: /demo/
    entries:
      - name: hi
        role: Terminal client
        body: Pick a conversation, inspect its entries, and branch from the keyboard.
        url: /demo/hi/
      - name: hiweb
        role: Web workbench
        body: Move from a workspace inbox to a session, its file review, and its transcript.
        url: /demo/hiweb/
  - layout: principle
    id: extensibility
    kicker: 03 / Extensible by design
    title: Build on a lean core.
    body: Write your own client against the HTTP API and event stream, or add a harness profile or execution environment as a local extension. The Elixir/OTP daemon uses a small set of direct dependencies and stores sessions in local files, with no separate database service.
    links:
      - label: Build a client
        url: /docs/guides/build-a-client/
      - label: Write an extension
        url: /docs/extensions/
      - label: Embed H in an Elixir/OTP application
        url: /features/#embed-h-in-an-elixirotp-application
  - layout: principle
    id: environments
    kicker: 04 / Execution environments
    title: Local or remote execution environments
    body: Run tools in your local checkout today. H separates tool execution from the client and session store, so a remote environment could work where the checkout lives. The built-in remote adapter is an in-VM prototype, not a shipped remote service.
    links:
      - label: Compare local execution and the remote prototype
        url: /features/#local-or-remote-execution-environments
  - layout: principle
    id: signals
    kicker: 05 / Signalling and waking
    title: Let sessions cooperate without polling.
    body: H wakes a waiting parent when its subagent finishes. An external workflow can also queue a follow-up through the local API without interrupting the current turn.
    links:
      - label: See how signalling and queued inputs differ
        url: /features/#signal-and-wake-sessions-without-polling
  - layout: architecture
  - layout: operating
    kicker: Before you start
    title: Run H on your machine.
    body: Start one daemon for your data directory and attach a client. Host tools use your account’s file and shell permissions; they are not sandboxed. If you choose a remote model provider, inference sends conversation context off your machine.
    link:
      label: Follow the local setup guide
      url: /docs/setup/
---
