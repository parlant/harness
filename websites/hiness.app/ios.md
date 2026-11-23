---
layout: article
lang: en
permalink: /ios/
title: Mobile web today & native iOS direction
kicker: Apple Ecosystem · macOS Today · iOS Companion Next
lead: Use hiweb from iPhone or iPad over an encrypted tailnet today while native iOS and iPadOS companion views are shaped around H's HTTP and SSE session protocol.
description: How to review and steer H sessions from iPhone and iPad today via hiweb, and the architectural roadmap for a native iOS companion app on hiness.app.
artwork: vigee_lebrun_uffizi
artwork_hook: Portable Easel · Uffizi
specs_title: Mobile access model
specs:
  - label: Shipping Today
    value: hiweb responsive UI
  - label: Transport
    value: HTTP + SSE (/api/v1)
  - label: Recommended Net
    value: Encrypted VPN / Tailnet
  - label: Auth Boundary
    value: Owner token + CSRF
  - label: Planned Native
    value: SwiftUI iOS / iPadOS
---

* On this page
{:toc}

## Use hiweb on iPhone and iPad today

`H.app` runs your coding-agent daemon and workspace tools on your Mac, where your Git checkouts, compilers, and test suites live. Because `hiweb` is a responsive Phoenix LiveView workbench with zero client-side state lock-in, you can already triage workspaces, read streaming turns, comment on diffs, and steer or abort active runs from Safari on iPhone or iPad.

To reach your Mac safely from another device:

1. **Keep plain HTTP off untrusted networks**: by default, `H` binds its listeners to loopback (`127.0.0.1`).
2. **Bind over an encrypted VPN or tailnet**: configure `<data_dir>/network.json` to bind on your machine's encrypted VPN interface (such as Tailscale or WireGuard) or forward through an authenticated HTTPS tunnel.
3. **Sign in with your owner token**: copy the token from `H.app` (**Copy Owner Sign-In Token**, `⌘C`) and sign in from Safari on iOS or iPadOS.

Read [security boundaries on hiness.dev](https://hiness.dev/docs/security/) and [daemon network configuration](https://hiness.dev/docs/daemon/) before exposing a listener beyond loopback.

## Why hiness.app is built for a future native iOS client

`H` keeps history ancestry, work ownership, and client navigation strictly separate in the daemon (`H.Session.Server`). Neither `hi` (Rust TUI) nor `hiweb` (Phoenix LiveView) owns session truth; both subscribe to ordered commits and streaming deltas over the documented `/api/v1` HTTP and Server-Sent Events (SSE) protocol.

**Planned work (not shipped yet):** a native SwiftUI iOS and iPadOS companion under the `hiness.app` umbrella will connect to your Mac's `H` daemon as another stateless view cursor:

- **Inbox triage and push-ready status**: inspect active, retrying, and completed workspace runs across your Mac checkouts without waking dormant sessions.
- **Last-Event-ID SSE resume**: reconnect cleanly across mobile network handoffs using `H`'s sequence replay ring buffer and snapshot fallback.
- **Line-pinned diff review on iPad and iPhone**: review commits, leave file-range notes, and submit follow-up steering turns while away from your desk.

Want to prototype an Apple client against the local API right now? Follow [build a client on hiness.dev](https://hiness.dev/docs/guides/build-a-client/) and inspect the [protocol specification](https://github.com/parlant/harness/blob/main/docs/protocol.md) on GitHub.
