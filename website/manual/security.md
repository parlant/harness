---
layout: doc
title: 'Security boundaries'
description: 'What the owner token, OS permissions, workspace leases and provider credential vault do and do not protect.'
lang: en
permalink: /docs/security/
---
H runs locally, but model inference can send conversation context to an external provider. A host tool runs with the daemon user's filesystem and shell access. Choose the OS identity, working directory and provider **before** submitting a turn.

* Contents
{:toc}

## Protect the owner and the store

- Treat `<data_dir>/auth.token` as a credential for the whole daemon, not a read-only chat link. The owner can submit work that runs host tools. Don't put the token in a URL, screenshot, issue report or conversation. Unix-socket requests still require authentication.
- Keep the data directory private to its owner. `credentials/` is private (`0700` directory, `0600` credential files), but this is OS-user protection, not encryption at rest, a keychain or isolation from same-user processes. Never point H at someone else's account store.
- Enter API keys through the masked `/key set` prompt or the web's write-only account controls. Don't record them in shell commands or `extensions.json`. If one is disclosed, revoke it with the provider, then replace the profile. For Codex, sign in again when required; restoring an old rotated refresh credential isn't a recovery procedure.

## Minimize network exposure

Keep the API and web listeners on loopback. The standalone listener uses plain HTTP; owner auth and strict Host/Origin checks do not encrypt traffic. If explicit additional IPv4 binds are needed, use only a trusted encrypted network such as a private VPN. Don't expose the listeners or development reloader/inspector to the public internet. `hi` uses a local socket or literal loopback HTTP, not a remote daemon URL.

Register a new named provider ID for a new service, not a new endpoint for an ID with an active key. The service receives both its key and the requests you send it. Choose models whose data policies match the workspace.

## Understand what can leave a workspace

Read tools, shell output and attachments can put private data into conversation history and provider context. Review screenshots, imported transcripts and review excerpts as carefully as source files. **Save comment** does not call a model now, but a later question can include the saved comment. There is no automatic redaction of arbitrary secrets in your files or prompts.

The bounded API file reader and the web file browser have path checks. They don't restrict what `bash` or other host tools can do. A workspace lease serializes H writers for a directory; it does not confine paths or lock out another OS process. For untrusted code, use real OS-level isolation and a least-privileged identity; a prompt saying “read only” is not such a boundary.

## Review executable extensions before enabling them

A path-loaded BEAM package runs **in the daemon VM**. Load only reviewed artifacts from directories controlled by trusted owners. Startup validation catches format and compatibility errors, not malicious behavior. The client cannot install from a workspace or enable packages on a model's behalf. CLI `hi-<name>` executables are another trust decision, based on your `PATH`. See the [extension browser](/extensions/) and [HTTP security implementation](https://gitlab.com/parlant-co/harness/-/blob/main/lib/h/http/security_plug.ex).
