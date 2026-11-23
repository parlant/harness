---
layout: demo
lang: en
title: Read the fork in hi.
description: Follow the date parser discussion from the terminal and switch branches or detach while the daemon keeps running.
kicker: Study 02 / Terminal
specimen:
  client: terminal
  label: Terminal illustration · hi
  strip: hi / release-parser
  context: Conversation · Original
  prompt: /tree
  hint: Choose a conversation
  entries:
    - label: User
      text: Keep the caller unchanged. Treat blank input as a missing date.
    - label: Assistant
      text: I'll add a blank-input clause that returns nil and a test for the existing caller.
  caption: The hi transcript fills the terminal while /tree opens the conversation picker at the bottom.
scenarios_title: Inspect a terminal action
scenarios:
  - title: Read another path
    entries:
      - label: Selection
        text: Select the branch that explores an explicit error tuple. The shared opening entries remain visible at the top of the thread.
      - label: Result
        text: The transcript switches to the error-tuple reply while keeping the original nil discussion saved on its own branch.
    note: Switching branches in hi updates only this terminal's cursor. Any browser window attached to the same session stays on its own view.
  - title: Leave during a run
    entries:
      - label: Action
        code: /quit
        text: Detach the terminal client while the turn continues in the background daemon.
      - label: Return
        code: hi -r
        text: Reattach to the session from the same workspace and read the entries committed while the terminal was closed.
    note: Use /quit to close the terminal view and /abort when you want to stop an active generation.
---
Open a scenario below to trace how `hi` switches branches, detaches, and reattaches to a running session.
