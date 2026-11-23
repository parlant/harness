---
layout: demo
lang: en
title: Review the session in hiweb.
description: Follow the same parser discussion into the Phoenix web workbench. Use the inbox to find the session, then inspect the conversation or its files.
kicker: Study 03  /  Browser
specimen:
  client: browser
  label: Browser illustration · hiweb
  strip: Workspace  /  release-parser
  sidebar: Conversations
  items:
    - label: Original
    - label: Branch
      selected: true
  context: Branch · Explicit error
  entries:
    - label: User
      text: Try the explicit error instead. What changes for callers?
    - label: Assistant
      text: Each caller needs to handle the error tuple before formatting the date.
  caption: An illustrated workbench, not a screenshot. The conversation list sits beside the transcript. This reader is on the branch while the terminal reader stays on the original.
scenarios_title: Inspect a workbench action
scenarios:
  - title: Compare the transcript
    entries:
      - label: Original
        text: Read the plan to return nil for blank input. The assistant proposes a test for the existing caller.
      - label: Branch
        text: Switch to the other conversation and read the plan for explicit errors. Switching does not start another generation.
    note: The web workbench and hi are clients of the same daemon, not copies of a session.
  - title: Check the actual file
    entries:
      - label: File review
        text: Open the parser in the working tree. A plan in the transcript is not proof that the file changed.
      - label: Comparison
        text: Select a pinned Git snapshot to inspect its version. That selection belongs to this view, not to conversation ancestry.
    note: A conversation branch does not create a Git branch or a second working tree.
---
Open a scenario to distinguish what the browser shows from what the daemon stores. No local files are read by this page.
