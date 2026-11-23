---
layout: features
lang: en
permalink: /features/
title: Features
description: 'See what H gives you: durable coding sessions, synchronized clients, pluggable execution environments, and a lean core you can extend.'
---
H keeps the coding session in a local daemon, separate from the window you use and the environment where tools run. Here’s what that gives you in practice.

* On this page
{:toc}

## Durable and resilient sessions

Close your terminal or browser without stopping the run. H saves session state to local files so you can reopen committed history after a daemon restart. It schedules retries for retryable provider failures; it does not automatically rerun an interrupted shell command that may already have changed your files. **You keep the record and can decide what to do next.** [See what H recovers](/docs/architecture/#storage-and-recovery).

## Responsive, synchronized clients

Start a turn in `hi` and watch replies and tool activity stream in `hiweb`. The clients share session state, but each keeps its own reading position and branch selection. **Review in one window without disrupting what you’re following in the other.** [Switch clients mid-run](/docs/guides/resume/).

## Terminal, web, desktop and mobile

Use `hi` in a fullscreen TUI, regular terminal scrollback, or headless print mode. Use `hiweb` for the workspace inbox, transcripts and file review in a desktop or mobile browser. **Choose the view that suits the job without moving the session.** Desktop and mobile access is through the web client, not separate native apps. [Try the terminal walkthrough](/demo/hi/) or [the browser walkthrough](/demo/hiweb/).

## Branch and resume conversations

Fork at an earlier entry to try another approach without losing the original. The branch shares the earlier history but not running tasks, queued messages or a separate copy of the files. **Compare two lines of reasoning without duplicating the transcript.** For file isolation, use a separate worktree. [Explore a fork](/demo/) or [learn how sessions and workspaces fit together](/docs/sessions/).

## Local or remote execution environments

**Local execution is available today.** H reads files and runs commands in your chosen workspace with the host user’s permissions. The environment is separate from the client, so switching from terminal to browser doesn’t change which checkout the tools use. A workspace lease coordinates H’s writers; it isn’t a sandbox.

**Remote execution is a prototype.** The same environment contract is designed to let tools run closer to a checkout or build dependencies on another machine without changing how clients attach to the session. Today the built-in remote adapter is tested in the same VM; H does not ship an authenticated transport or an agent service for another machine. [Read about the workspace boundary](/docs/architecture/#boundaries-that-arent-sandboxes) and [the remote transport roadmap](https://gitlab.com/parlant-co/harness/-/blob/main/docs/roadmap.md#other-remaining-work-not-shipped).

## Review files and give feedback in context

Browse working files or a pinned Git revision, leave a comment on that revision, or save a working-tree edit with a check for intervening changes. The browser composer can also attach a screenshot or text file. **Point to the code or evidence you mean without pasting it all into the conversation.** [Review a change](/docs/guides/file-review/) or [attach a screenshot or text file](/docs/web/#send-a-screenshot-or-text-attachment).

## Delegate to subagents

Give a child session a focused job, such as a read-only review. The inbox keeps child work grouped under its parent, and you can use prepared worktrees for parallel edits. **Split the work without losing track of where it came from.** [Delegate to a subagent](/docs/guides/subagents/).

## Signal and wake sessions without polling

When a parent session waits for a subagent, H parks the waiting task without tying up a worker. The child’s completion signal wakes the parent with the outcome. **Sessions can cooperate without checking each other’s transcripts or polling for progress.** [Wait for a subagent](/docs/guides/subagents/).

An external workflow or trigger can use the authenticated local API to submit a queued follow-up. **The input waits its turn instead of interrupting a run already in progress.** That uses normal session submissions; a general external signal-and-wake API is not shipped. [Build an integration with the local API](/docs/guides/build-a-client/).

## Choose your model provider

Configure a provider key, use a supported Codex login, or register a compatible endpoint. **Change the model or provider without replacing your client or exporting the session.** Local execution does not mean local inference: a remote provider receives the context needed for its request. [Configure a provider](/docs/providers/).

## Build a client or write an extension

Use H’s local HTTP API and event stream to build a client without reimplementing storage or task recovery. Add a harness profile or execution environment as a trusted startup package, or add a `hi` subcommand without loading code into the daemon. **Use the smallest extension point that fits your workflow.** [Build a client](/docs/guides/build-a-client/), [write an extension](/docs/extensions/), or [extend the CLI](/docs/guides/extend-hi/).

## Embed H in an Elixir/OTP application

Run `:harness` in the same BEAM VM as your application. Use H’s built-in file-backed session store and default host execution environment without running a separate daemon process or database service. `hiweb` uses this approach: its Phoenix backend calls H directly in the same VM.

**Build an agent into your application without writing your own session store, tool runner, or recovery logic.** Add a harness profile to define the agent’s instructions and tools, or implement an execution environment to control how it accesses files and runs commands. The default environment uses the host process’s permissions; it is not a sandbox. [See how embedding works](/docs/architecture/#embed-the-core-in-an-otp-application).

## Lean core, few dependencies

The Elixir/OTP daemon has a small set of direct dependencies and uses file storage by default. **There’s no separate database service to install, run or upgrade.** The native bundle includes the daemon runtime and clients. [Set up H](/docs/setup/) or [see how the core is organized](/docs/architecture/).

## Bring existing conversations along

Import supported pi transcripts as read-only archives. **Keep past work available for reference without editing the source logs or mistaking an imported transcript for a resumable run.** [Import a pi archive](/docs/guides/import/).
