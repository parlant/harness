---
layout: doc
title: 'Extension browser'
description: 'Browse the optional H package, identify built-in features, and choose a trusted startup artifact.'
lang: en
permalink: /extensions/
---
H loads optional packages from explicit local paths at startup. This directory describes what is available in the repository; it is not a download registry or a one-click installer.

* Contents
{:toc}

## Available package

| Package | Use it when | Activation |
|---|---|---|
| [MultiCodex](/extensions/multicodex/) | You have two to eight authorized Codex aliases and want selection based on recent quota observations | API 1 path artifact, shipped with the native bundle but **off by default**, or built from source |

Ordinary Codex device login, one active alias, API keys and named provider catalogs are **built in**; see [providers and credentials](/docs/providers/). Likewise, `hi import` runs a client-side executable; it is not a daemon package. The [greeting template](/docs/extensions/#build-the-greeting-template) is an authoring example, not an account manager or a recommended install.

## Enable or bypass a package

Keep reviewed artifacts in owner-controlled directories. Add the built directory to `<data_dir>/extensions.json`, then restart when idle. Relative paths resolve against the daemon store, not the project. Incompatible enabled entries block boot. For a standalone foreground bundle use `hi daemon start --no-extensions` while the previous server is stopped to bypass the entire extensions file, even a malformed one. This does not edit the file or turn off stock accounts.

## Write one

Start with [build a local extension](/docs/extensions/) and the [extension design notes](https://gitlab.com/parlant-co/harness/-/blob/main/docs/extensions.md). Separate the startup registration, any package-owned processes, and daemon-owned session transitions. A package runs with daemon authority; API checks don't isolate untrusted code.
