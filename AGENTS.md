# H (`:harness`)

- Namespace is `H.*` (`app: :harness`), targeting Elixir 1.20 / Erlang/OTP 29 with dependency-free local file storage (`H.Storage.File`) and the agreed Slice 2 web/LLM stack (`bandit`, `plug`, `req`, `req_llm`) on the path to web-based self-hosting (`docs/roadmap.md`).
- Keep the core small: immutable domain data, explicit transitions, short atomic commits, effects outside commits. No generic plugin/workflow framework before concrete uses require it.
- Read `docs/architecture.md` before changing domain or process boundaries. Keep implemented behavior distinct from proposals in documentation.
- History ancestry, work ownership, supervision, and client navigation are separate structures. A zipper is a view cursor, not stored process state.
- Supervision is not persistence. Do not claim durability before storage, VM-restart, and ambiguous-effect tests pass.
- Never replay an external side effect merely because an OTP worker restarted. Persist intent and replay policy first; unsafe interrupted work stays interrupted.
- No PIDs, refs, functions, ports, secrets, or provider credentials in durable records or client payloads. Validate external data without creating atoms from input.
- Tests use fake providers and disposable workspaces/storage. No real account stores, paid model calls, external shells with uncontrolled effects, or full-app startup in unit tests. Start only required children with `start_supervised!`.
- Read the Elixir skill before editing `.ex`/`.exs` or adding Hex dependencies. Done means `mix format`, `mix compile --warnings-as-errors`, and relevant `mix test`. Tests default to `--no-start`.
- Use `MIX_BUILD_PATH=/private/tmp/<unique-own-build>` for agent-owned runs on macOS. Track and stop only processes this agent started.
- Agree on persistence/transport dependencies before adding them. Keep reference repositories read-only; pinned source links are design inputs, not runtime dependencies.
