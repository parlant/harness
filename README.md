# H (`:harness`)

An Elixir/OTP experiment: one BEAM OS process hosts many durable agent sessions (`H`), with a web client (and other surfaces) attached to the same daemon.

The aim is Pi Durable's execution semantics, p2's shared session/history surfaces, and mini-swe-agent's small, inspectable turn loop—reaching **self-hosting through a web-based client as soon as possible** without external database dependencies.

## Current state

A dependency-free **pure history core**, not yet a daemon:

- A session has an identity, an absolute working directory, and a root conversation.
- Conversations contain immutable entries and may inherit another conversation's prefix.
- Forks reference a concrete visible entry; later parent entries never leak into a fork.
- Independent conversations and nested forks use one ordered, session-local ID namespace.
- Functions return new values. No persistence, processes, provider calls, tools, or sockets yet.

The current maps are a semantic reference, not a plan to retain every transcript in a production GenServer. Fork validation currently scans visible history; the storage implementation will need indexed, paged traversal.

## Start here

Development target: Elixir 1.20 / OTP 29. No Hex dependencies or services required.

```sh
cd ~/Projects/diy-harness
mix format --check-formatted
mix compile --warnings-as-errors
mix test
iex -S mix
```

In IEx:

```elixir
alias H.Session

session = Session.new("demo", Path.expand("."))
{:ok, session, question} = Session.append(session, 1, "user", %{text: "Try approach A"})
{:ok, session, _answer} = Session.append(session, 1, "assistant", %{text: "Approach A..."})
{:ok, session, branch} = Session.fork(session, 1, question.id)
{:ok, session, _entry} = Session.append(session, branch.id, "user", %{text: "Now consider B"})
Session.entries(session, branch.id)
```

This manually builds history. It does not contact a model or save anything to disk. `append/4` is a trusted low-level primitive, not the future client submission API.

## The important distinctions

**Supervision restarts processes; stored checkpoints resume work.** Neither PIDs nor mailboxes are a durable record.

Keep these structures separate:

1. **History/fork tree:** conversations and immutable inherited prefixes.
2. **Work ownership tree:** tasks/subagents, cancellation, and joins.
3. **Supervision tree:** live processes and restart boundaries.
4. **Client cursor:** what one person is viewing; a zipper can represent this.

A historical fork must not inherit a running task or cancel its parent. Closing a terminal must not cancel daemon work. Navigating in one client must not move another client's cursor.

A chat agent and a coding agent use the same run loop. Chat offers no tools; coding adds a small selected tool set. An agent is configuration plus execution, not a separate persistence system.

## First interfaces and self-hosting goal

- **Now:** plain Elixir API (`H.Session`, `H.Conversation`, `H.Entry`) and IEx, making the domain semantics concrete.
- **First daemon client (for self-hosting):** a minimal **web-based client** served by the daemon over versioned HTTP/JSON commands and SSE committed-state view updates (`ConversationView`). `curl` remains enough to debug every endpoint and stream.
- **Later:** a full-screen TUI or mobile surface over the same protocol. None owns scheduling or persistence.

See the [proposed protocol](docs/protocol.md) and the [self-hosting roadmap](docs/roadmap.md).

## Design

- [Architecture and OTP mapping](docs/architecture.md)
- [Commands, observations, and clients](docs/protocol.md)
- [Roadmap to web-based self-hosting](docs/roadmap.md)
- [Pinned upstream references](docs/references.md)

The architecture/protocol documents distinguish proposals from implemented behavior. Storage is pluggable (`H.Storage`): we start with dependency-free `H.Storage.Memory` and `H.Storage.File` (atomic framed commit logs + snapshots using Elixir's stdlib `JSON`), with `H.Storage.SQLite` agreed as the relational backend to plug in later behind the same conformance suite.
