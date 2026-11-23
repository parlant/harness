---
layout: demo
lang: en
title: Two paths from one entry.
description: Follow a small parser change through two conversations in the same session.
kicker: Study 01  /  Conversation
record:
  label: Shared prefix
  title: Fix a date parser
  entries:
    - label: '01 · User'
      text: A blank release date crashes the parser. What should it return?
    - label: '02 · Assistant'
      text: The caller accepts a missing date. We can return nil, or make an invalid date explicit with an error tuple.
scenarios_title: Inspect a continuation
scenarios:
  - title: Original · Return nil
    entries:
      - label: '03 · User'
        text: Keep the caller unchanged. Treat blank input as a missing date.
      - label: '04 · Assistant'
        text: I’ll add a blank-input clause that returns nil and a test for the existing caller.
    note: Entries after the fork stay visible here, on the original path.
  - title: Branch · Return an error
    entries:
      - label: '03′ · User'
        text: Try the explicit error instead. What changes for callers?
      - label: '04′ · Assistant'
        text: Each caller needs to handle the error tuple before formatting the date.
    note: This conversation inherits entries 01 and 02, not the later exchange about nil. The fork is in history, not in the filesystem.
---
Select a continuation to see what its reader sees. Both begin with the same question and answer; neither includes the other’s later entries.
