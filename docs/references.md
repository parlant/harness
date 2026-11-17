# Design references

These are research inputs, not runtime dependencies. No upstream application code has been copied into this project. Reading unreleased p2 source does not mean installing or executing it outside the release-age policy.

## Pi Durable

Stable reference: Pi **v1.3.0**, commit `71023aec1546d6d677a65669c5665c0927ce0dd0`, plus post-1.3.0 upstream commits through `aca89cfe1` (`v1.5.2` / `2026-11-11`).

- [README](https://github.com/earendil-works/pi/blob/71023aec1546d6d677a65669c5665c0927ce0dd0/packages/durable/README.md)
- [Normative specification](https://github.com/earendil-works/pi/blob/71023aec1546d6d677a65669c5665c0927ce0dd0/packages/durable/docs/spec.md)
- [Group commit design (`e5c6182ba`)](https://github.com/earendil-works/pi/blob/e5c6182ba/packages/durable/docs/group-commit.md)
- [Suspendable work: signals, parked tools, gates, hook tasks (`815541a14`, `473515f9c`)](https://github.com/earendil-works/pi/blob/815541a146e7123bba4942a181eb09b61cb99455/packages/durable/docs/suspendable/book.md)
- [Recovery example](https://github.com/earendil-works/pi/blob/71023aec1546d6d677a65669c5665c0927ce0dd0/packages/durable/test/examples/13-recovery.ts)
- [Background subagents](https://github.com/earendil-works/pi/blob/71023aec1546d6d677a65669c5665c0927ce0dd0/packages/durable/test/examples/23-subagent-background.ts)
- [Child tasks](https://github.com/earendil-works/pi/blob/71023aec1546d6d677a65669c5665c0927ce0dd0/packages/durable/test/examples/24-child-tasks.ts)

### Public talks and writings by Mario Zechner on Pi Durable

- [Vienna AI Engineering Meetup talk: "WTF is Pi Durable" (`2026-11-10`)](https://www.youtube.com/watch?v=EreOxs9Vvrg) — local transcript in [`research/2026-11-10-mario-zechner-wtf-is-pi-durable-transcript.md`](../research/2026-11-10-mario-zechner-wtf-is-pi-durable-transcript.md)
- [0xSero interview: "Pi Durable: Agents That Survive Crashes — Mario Zechner & Armin Ronacher" (`2026-10-07`)](https://www.youtube.com/watch?v=ja_7AF54OtE)
- [Earendil announcement: "Pi Durable" (`2026-10-01`)](https://earendil.com/posts/pi-durable/)
- [Earendil post: "Pi Durable on Cloudflare" (`2026-10-16`)](https://earendil.com/posts/pi-durable-on-cloudflare/)
- [First-person corpus and BEAM architectural comparison](../research/mario-zechner-pi-durable-sources-and-beam-comparison.md)

Local read-only source: `~/Projects/JavaScript/pi/packages/durable`. That working checkout can change; use the pinned Git objects above for reproducible comparisons.

Retain:

- One mutation line per session with group-committed storage batches and deferred progress persistence (`persist_within_ms`); atomic entries, documents, operational state, and receipt commits.
- External effects outside transactions ("effect sandwiches": intent, effect, outcome); `restart_limit` crash-loop guards and retry-accounted interrupted model calls.
- Conversation ancestry distinct from explicit task/conversation ownership (`foreground` vs `background: true`, `abandon_on_restart`, cycle rejection across waits and held owners).
- Scoped, versioned documents (`:session`, `:conversation`, `:task`) with explicit `history` (`:latest` \| `:rewindable`) and `fork` (`:as_of` \| `:current` \| `:initial`) policies, implemented via pure Elixir reducers rather than JS `Proxy` traps.
- Suspendable work (`sleeping` on deadlines and/or typed `signals` with early-arrival buffering, tools that park without holding a process, 4-stage `transform -> check -> claim -> observe` hooks and gates, and `wake()` handoff to `WakeScheduler` / `WaitIndex`).
- Pluggable `ExecutionEnv` with source-side output windowing, plus append-only compaction paired with `search_history` over raw un-truncated entries.
- Windowed `ConversationView` state and delta fan-out (replacing raw event-stream reconstruction); missing/incompatible definitions block work without deleting durable state.

Do not port automatically: JavaScript `Proxy` mutable draft tracking, numeric TypeScript brands, all public convenience APIs, or the legacy 40-event flat coding-agent hook bus.

## p2

Prototype reference: upstream Pi commit `90ed3e3b14b58c48193a467e4d5af035570ce56d`.

- [README and explicit unsupported-prototype warning](https://github.com/earendil-works/pi/blob/90ed3e3b14b58c48193a467e4d5af035570ce56d/apps/p2/README.md)
- [Tree/branch design](https://github.com/earendil-works/pi/blob/90ed3e3b14b58c48193a467e4d5af035570ce56d/apps/p2/docs/tree.md)

The browser and terminal attach to the same underlying conversations. `/tree` is implemented using Durable conversation forks, not by copying transcripts or repointing the head marker. The same insight transfers directly to the history core here.

Deliberate departures:

- One BEAM daemon instead of a JavaScript worker host per session.
- Per-client navigation rather than p2's globally selected main conversation and read-only inactive branches.
- Ordinary versioned command/read/observation interfaces rather than distributed Chord objects and downloaded UI facets.
- A small set of domain records/behaviours before a general application/plugin platform.

`apps/p2/docs/target-design.md` and `durable-request.md` were also inspected. Both explicitly mark themselves superseded; their design reasoning is not a current implementation contract. Do not implement those historical proposals as though they were p2's settled API.

## mini-swe-agent

Reference: commit `04d809ceab9df28f9adaed044884180159172930`.

- [README](https://github.com/SWE-agent/mini-swe-agent/blob/04d809ceab9df28f9adaed044884180159172930/README.md)
- [Default agent](https://github.com/SWE-agent/mini-swe-agent/blob/04d809ceab9df28f9adaed044884180159172930/src/minisweagent/agents/default.py)

Retain the small query/action/observation loop, explicit model/environment separation, bounded execution, and independent shell invocations. Do not assume its linear in-memory trajectory or whole-file trajectory save provides the durable multi-session guarantees we want.

## OTP

- [Supervision principles](https://www.erlang.org/doc/system/sup_princ.html)
- [GenServer](https://hexdocs.pm/elixir/GenServer.html)
- [Task.Supervisor](https://hexdocs.pm/elixir/Task.Supervisor.html)
- [DynamicSupervisor](https://hexdocs.pm/elixir/DynamicSupervisor.html)

Use supervision for live fault containment and stored checkpoints for recovery. Process links, mailboxes, ETS, and runtime state cannot replace a committed domain record. OTP does not confer exactly-once external execution or an OS sandbox.
