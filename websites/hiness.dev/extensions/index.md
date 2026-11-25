---
layout: doc
title: 'Extension browser'
description: 'Browse the bundled MultiCodex startup package, enable a trusted local artifact, or write your own extension.'
lang: en
permalink: /extensions/
artwork: charlotte_bonaparte
---
H loads optional startup packages from explicit local directory paths listed in `<data_dir>/extensions.json`. Review the available package below or follow the authoring guide to build your own.

* Contents
{:toc}

## Available package

| Package | Use it when | Activation |
|---|---|---|
| [MultiCodex](/extensions/multicodex/) | You have two to eight authorized Codex aliases and want H to pick the account with the most quota headroom | API 1 path artifact included in the native bundle (disabled by default) or built from source |

Single-account Codex device login, API key management, and custom OpenAI-compatible provider catalogs ship directly in the core daemon; see [providers and credentials](/docs/providers/). The `hi import` command ships as a standalone CLI helper (`hi-import`), and the [greeting template](/docs/extensions/#build-the-greeting-template) serves as a starter project for extension authors.

## Enable or bypass a package

Store reviewed extension artifacts in directories owned by your OS account. Add the built artifact directory to `<data_dir>/extensions.json`, then restart the daemon when idle. Relative paths resolve against `<data_dir>`. If an enabled entry fails compatibility checks, H halts startup so you can fix the configuration before running sessions.

To boot a standalone foreground daemon while ignoring every entry in `extensions.json`, stop the current server and run `hi daemon start --no-extensions`.

## Write one

Follow [build a local extension](/docs/extensions/) and the [extension design notes](https://github.com/parlant/harness/blob/main/docs/extensions.md) to package a harness profile or execution environment. Keep startup registration, package-supervised processes, and daemon-owned session commits separate. Because loaded BEAM modules execute inside the daemon VM with your OS user's authority, load only code you have reviewed.
