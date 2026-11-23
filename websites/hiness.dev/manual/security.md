---
layout: doc
title: 'Security boundaries'
description: 'Protect the owner token and credential store, keep listeners on loopback, and review workspace permissions before running tools.'
lang: en
permalink: /docs/security/
---
H runs on your machine, executes host tools with your OS user's filesystem and shell permissions, and sends prompt context to the model provider you select. Check your OS user, working directory, and active model provider before submitting a turn.

* Contents
{:toc}

## Protect the owner and the store

- Guard `<data_dir>/auth.token` as full owner authority for the daemon. Anyone holding the token can start turns that execute host tools. Keep the token out of URLs, screenshots, issue reports, and transcripts. Every request over `<data_dir>/api.sock` and the HTTP listener requires authentication.
- Keep `<data_dir>` owned by your OS account. H creates `<data_dir>/credentials/` with mode `0700` and credential files with mode `0600` so other local users cannot read them; processes running under your own OS user share the same account boundary.
- Enter API keys only through the masked `/key set` prompt in `hi` or the write-only controls in `hiweb` **Account settings**. Keep secrets out of shell history and `extensions.json`. If a key leaks, revoke it with the provider and save a new one. When a Codex token expires, run `hi login` to issue a fresh grant.

## Minimize network exposure

Keep the API and web listeners bound to loopback (`127.0.0.1`). Because the standalone listeners serve plain HTTP, bind additional addresses in `network.json` only across a trusted encrypted network such as a private WireGuard or Tailscale interface. Keep the daemon listeners and development tools off public networks.

When adding a custom endpoint in `openai-compatible.json`, give each service a distinct provider ID so H sends each saved API key only to its matching host. Choose model providers whose data-handling policies match the repository you are working in.

## Understand what can leave a workspace

File reads, shell output, review comments, and composer attachments enter the session transcript and travel to the active model provider on subsequent turns. Check files, screenshots, and imported transcripts for secrets before attaching them or asking the agent to read them.

The web file browser and bounded file API enforce workspace path checks, while host coding tools such as `bash`, `read`, `write`, and `edit` execute with your OS user's permissions. A workspace writer lease coordinates concurrent mutating tools inside H for a target directory; run untrusted repositories inside a dedicated OS account, container, or virtual machine when you need hard process isolation.

## Review executable extensions before enabling them

Startup packages listed in `extensions.json` load compiled BEAM modules directly into the daemon VM, and `hi-<name>` CLI helpers on your `PATH` execute as your OS user. Review the source of any extension or CLI helper before enabling it, and store built artifacts in directories writable only by your account. See the [extension browser](/extensions/) and [HTTP security plug](https://github.com/parlant/harness/blob/main/lib/h/http/security_plug.ex).
