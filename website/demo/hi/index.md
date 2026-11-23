---
layout: demo
lang: en
title: Read the fork in hi.
description: Follow the date parser discussion from the terminal. A cursor chooses what to display; it does not own the run.
kicker: Study 02  /  Terminal
specimen:
  client: terminal
  label: Terminal illustration · hi
  strip: hi  /  release-parser
  context: Conversation · Original
  prompt: /tree
  hint: Choose a conversation
  entries:
    - label: User
      text: Keep the caller unchanged. Treat blank input as a missing date.
    - label: Assistant
      text: I’ll add a blank-input clause that returns nil and a test for the existing caller.
  caption: An illustrated terminal, not a screenshot. The transcript fills the screen; the command line below it opens the conversation picker.
scenarios_title: Inspect a terminal action
scenarios:
  - title: Read another path
    entries:
      - label: Selection
        text: Choose the branch that explores an explicit error. The shared opening entries are still visible.
      - label: Result
        text: The next reply explains the cost to callers. The nil discussion is on the original path, not erased.
    note: Navigation in this terminal does not switch another reader’s browser tab.
  - title: Leave during a run
    entries:
      - label: Action
        code: /quit
        text: Detach the terminal while work is underway. This is different from interrupting the run.
      - label: Return
        code: hi -r
        text: Pick the same session again. Read the entries committed while the terminal was closed.
    note: The daemon must remain running. A terminal reconnect is not a daemon restart.
---
These are annotated terminal actions, not a shell. Open a scenario to inspect its effect on the session.
