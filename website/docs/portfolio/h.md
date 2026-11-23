---
title: H
description: A local daemon for coding-agent sessions. Start a turn in the terminal, branch from an earlier answer, and follow the same session in the browser.
year: 2026
status: active
order: 1
---

When a coding agent proposes a parser change, I often want to test an alternative before it touches the files. In H, I branch from that earlier answer and ask whether changing the caller input would be simpler. H keeps both paths in the same session. The new branch points to the shared prefix of committed entries while both branches work against the same project checkout on disk.

I placed session ownership in a local Elixir/OTP daemon so the conversation lives independently of any open window. I start a turn in `hi`, open `hiweb` in the browser to inspect a diff, and quit the terminal while the run continues. Each client keeps its own scroll position and selected branch.

Recovery stops where external side effects become ambiguous. If the daemon crashes while a shell command is running, that command may already have modified the working tree. H records the interrupted tool call and any captured output on disk so I can inspect the checkout before deciding what to run next.
