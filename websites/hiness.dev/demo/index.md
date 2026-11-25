---
layout: demo
lang: en
title: Two paths from one entry.
description: Follow a parser change through two conversation branches in the same session.
kicker: Study 01 / Line of succession
artwork: goya_charles_iv
artwork_wide: true
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
        text: I'll add a blank-input clause that returns nil and a test for the existing caller.
    note: Entries 03 and 04 continue on the original conversation path while the shared prefix remains untouched.
  - title: Branch · Return an error
    entries:
      - label: "03' · User"
        text: Try the explicit error instead. What changes for callers?
      - label: "04' · Assistant"
        text: Each caller needs to handle the error tuple before formatting the date.
    note: This branch inherits entries 01 and 02 from the shared session store and records its own follow-up turns. Both branches point to the same working directory on disk.
---
Open each continuation below to see what its reader sees. Both paths share the opening question and answer, and each records its own subsequent turns.
