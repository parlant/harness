# Slice 3: Durable Multi-Turn Generation, `ReqLLM.Context` Projection, and Crash-Retry Recovery

**Goal:** Harden the generation loop (`H.Task.Generation` + `H.Context`) on top of Slice 2's `H.Provider.ReqLLM` / `H.Provider.Fake` foundation so multi-turn conversations, reasoning signatures, structured tool-call intents, deferred partial persistence (`persist_within_ms`), steering, and crash-retry accounting are rock-solid before enabling OS coding tools in Slice 4.

---

## 1. Module Layout

```text
lib/h/
  context.ex              # Pure reducer: H.Entry list + agent doc -> ReqLLM.Context & ReqLLM.Tool declarations
  task/
    generation.ex         # Full durable generation task (prepare -> stream -> deferred flush -> tool round / settle)
test/
  h/
    context_test.exs
    generation_recovery_test.exs
```

---

## 2. `H.Context` Reducer -> `ReqLLM.Context` & `ReqLLM.Tool`

`H` keeps its own versioned, JSON-compatible `H.Entry` maps in `H.Storage` and projects them to `ReqLLM.Context` at request preparation time:

1. **Head cut:** Read visible entries from the latest `compaction` or `reset`/`handoff` head marker forward (or from conversation root if none exists), updating incrementally on subsequent rounds within a run (`context_retention_ms`).
2. **System baseline first:** Always place `ReqLLM.Context.system(...)` and offered tool declarations at the leading baseline position so Anthropic / Vertex / OpenAI prompt caches remain valid across turns.
3. **Preserve structured blocks & signatures:** Project text, multimodal images (`ReqLLM.Message.ContentPart`), reasoning/thinking blocks, provider extension metadata (e.g. Vertex/Anthropic thought signatures from `:provider_event` / chunk `metadata`), and structured tool calls + tool results losslessly—never flatten assistant turns to plain display text.
4. **Declare tools without auto-execution:** Build `%ReqLLM.Tool{}` declarations with raw JSON Schema maps (`parameter_schema: tool_json_schema`, `strict: false`, and a stub callback since `ReqLLM.stream_text/3` + `StreamResponse.events/1` emits `:tool_call` events without invoking callbacks). Durable tool execution stays strictly under `H`'s own `H.Task.ToolCall` effect-sandwich scheduler.
5. **Fork tool-call pairing:** When a conversation forks at an assistant entry whose tool calls had not settled at the fork point, `H.Context` synthesizes explicit interrupted tool-result messages (`is_error: true`, `"Tool call interrupted by conversation fork."`) so providers never reject unpaired tool-use blocks.

---

## 3. `H.Task.Generation` Durability, Steering, and Crash-Retry Accounting

1. **Intent commit:** Pin resolved `%LLMDB.Model{}` ID, reasoning effort / thinking budget, context cutoff entry ID, and offered tool names in the `generation` task checkpoint; set `live.run` (`turns: n`) and `live.generation`.
2. **Deferred progress flush (`persist_within_ms`, default `1_000 ms`):**
   - Broadcast `event: ephemeral` deltas (~75 ms cadence, no SSE `id:`) from `:reasoning_delta`, `:text_delta`, and `:tool_call_delta` events.
   - Flush `live.generation` to `H.Storage` at most once per `1_000 ms` or folded into the terminal response commit (`event: commit`, `id: <seq>`).
3. **Crash mid-stream (anti-infinite-spend guard):**
   - On unclean recovery of an in-flight `running` generation task, convert any durably flushed partial into an `assistant` entry marked `aborted: true` (kept visible in raw UI history, omitted from next model prompt).
   - **Count the interrupted attempt against `retry` policy** instead of resending unconditionally on every crash:
     - Retries remaining -> transition task to `sleeping` (`until: now + backoff_ms`, exposed in `live.generation.retry`).
     - Retries exhausted -> end run `unanswered` with sticky `live.run_failure = %{reason: "interrupted"}`.
   - Clean daemon `close` (`terminate(:shutdown, ...)`) cancels the active `ReqLLM.StreamResponse` via `StreamResponse.close/1` and resets the task to `pending` **without** charging a retry or `restarts` count.
4. **Turn boundaries (`steer`, `follow_up`, `continue`):**
   - At the end of a tool round, drain `inbox` items marked `steer` into the transcript before preparing the next `generation` turn; keep `follow_up` items queued until the current run answers.
   - `when_busy: "steer"` + `when_idle: "reject"` either steers an active run or rejects atomically if the run already completed.
   - `{type: "continue"}` on an idle conversation clears `live.run_failure` and resumes from the existing context (including after `:interrupted`, `:model_error`, or `:turn_limit`).

---

## 4. Verification Checklist (Slice 3 Done)

- `H.ContextTest`: verifies leading system baseline, reasoning/thought-signature round-tripping, head-marker slicing, and synthetic interrupted tool-result pairing across fork cuts.
- `H.GenerationRecoveryTest` (`H.Provider.Fake`, `--no-start`, zero paid calls):
  - Multi-turn tool-call intent -> result -> final answer loop.
  - Deferred `persist_within_ms` flush vs crash loss bound (<= 1s uncommitted tail, zero `seq` reuse).
  - Unclean crash mid-stream converts flushed partial to `aborted` entry, charges retry budget, sleeps backoff, and settles `run_failure: "interrupted"` when exhausted; `continue` resumes cleanly.
  - Clean `close` vs explicit `abort` (`StreamResponse.close/1`), plus `steer` vs `follow_up` vs `when_idle: "reject"`.
- Opt-in live verification (outside `mix test`): multi-turn streaming conversation with thinking + structured tool-call emission through `H.Provider.ReqLLM` in the web client.
