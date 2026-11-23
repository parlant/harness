---
title: H
description: A local daemon for coding-agent sessions. Branch at an earlier answer and follow the same conversation in a terminal or browser.
year: 2026
status: active
order: 1
---

Suppose a coding agent suggests changing the parser. Before it starts editing files, I can go back to that answer and ask whether changing the input would be simpler. H keeps both conversations. The new path refers to the entries they have in common, so branching doesn't require a copy of the transcript. It doesn't make a copy of the working directory either.

I put session ownership in an Elixir/OTP daemon rather than in the terminal client. That lets me start a turn in `hi`, open the session in the browser to review a file, and close the terminal without stopping the run. Selecting an earlier entry in one client doesn't move the other reader's place.

There is a limit to what the daemon can recover. If it stops in the middle of a shell command, the command may already have changed a file. H records the interruption instead of running the command a second time. I can inspect the checkout before deciding what to do next.
