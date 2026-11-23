---
layout: demo
lang: en
title: Review the session in hiweb.
description: Open the same parser session in the Phoenix web workbench, switch between conversation branches, and inspect the working tree.
kicker: Study 03 / Gallery workbench
artwork: leopold_gallery_khm
artwork_hook: Browser gallery · hiweb
artwork_wide: true
specimen:
  client: browser
  label: Browser illustration · hiweb
  strip: Workspace / release-parser
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
  caption: The conversation list sits beside the active transcript. The browser displays the error-tuple branch while the terminal remains on the original path.
scenarios_title: Inspect a workbench action
scenarios:
  - title: Compare the transcript
    entries:
      - label: Original
        text: Select Original in the sidebar to read the nil-return plan and its proposed caller test.
      - label: Branch
        text: Select Branch to read the explicit-error plan immediately from committed history.
    note: Both hiweb and hi read from the same daemon session store and keep independent view state.
  - title: Check the actual file
    entries:
      - label: File review
        text: Open Review files to inspect the parser in the working tree and verify whether a tool call has modified the file on disk.
      - label: Comparison
        text: Pick a local Git commit in History to compare the file against its parent revision and pin a review comment to exact lines.
    note: Conversation branches live in the H session store while file review reads your Git checkout on disk.
---
Open a scenario below to see how `hiweb` switches between conversation branches and inspects files in the workspace.
