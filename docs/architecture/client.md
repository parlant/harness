# Client Architecture, Namespace Isolation & Multi-Surface Sync

**Status:**
- **Implemented (Slice 2):** `H.HTTP.Router` + `H.HTTP.SecurityPlug` + `H.HTTP.SSE` (`Bandit` + `Plug` JSON/SSE transport) and zero-build reference web UI (`priv/static/*` with `ConversationTranscript` ES module).
- **Proposed (Slices 5–6):** Folder-browsing & `pwd`-scoped session UX (Slice 5), followed by standalone client applications in separate namespaces—**`HWeb.*` (`:harness_web`, Phoenix + LiveView for Desktop & Mobile)** and **`HTUI.*` (`:harness_tui`, `Pi`-style Terminal UI)**—compiling either standalone or as a single-BEAM monolith alongside `:harness` (Slice 6).

---

## 1. Namespace & Compilation Separation

The inner workings of the durable agent engine (`H.*`) differ fundamentally from interactive client applications (`HWeb.*`, `HTUI.*`). We separate them into distinct namespaces and Mix OTP applications so neither pollutes the other:

| OTP App | Namespace | Dependencies | Purpose |
|---|---|---|---|
| **`:harness`** | `H.*` | `bandit`, `plug`, `req`, `req_llm` *(zero Phoenix / LiveView / TUI deps)* | Durable engine, storage, catalog, providers, harnesses, `ExecutionEnv`, in-VM `H.Daemon` + `H.PubSub` API, and `/api/v1/*` JSON/SSE wire server. |
| **`:harness_web`** | `HWeb.*` | `phoenix`, `phoenix_live_view`, `{:harness, in_umbrella: true}` *(or `path:`)* | Full responsive Desktop + Mobile web application (folder browser, session/branch workspace, streaming transcript, diff/tool inspectors). |
| **`:harness_tui`** | `HTUI.*` | Lightweight terminal renderer + `req` *(or stdio/HTTP client)* | Fast CLI/TUI launched from any shell directory (`cd ~/repo && h` inside `tmux`), attaching to the local `:harness` daemon over loopback HTTP+SSE. |

### Two First-Class Build & Runtime Topologies

1. **Daemon-Only Build (`:harness` standalone):**
   Compile and boot only `:harness`. Third-party clients, scripts, editor plugins, or `HTUI` connect over `/api/v1/*` HTTP + SSE. Zero Phoenix or frontend asset dependencies are compiled or loaded.
2. **Single-BEAM Monolith Build (`:harness` + `:harness_web` in one VM):**
   Compile a unified release booting both `:harness` and `:harness_web` on the same BEAM VM:
   - Inside the VM, `HWeb.*` Phoenix LiveViews call `H.Daemon` directly as Elixir function calls and subscribe directly to `H.PubSub` (`Registry`)—**zero localhost HTTP roundtrips or extra JSON re-decoding**.
   - Simultaneously, `:harness` binds its loopback `/api/v1/*` listener (or Unix socket) so any `HTUI` instance started in `tmux` attaches to the **exact same live `H.Session.Server` processes**.

*(Note: `HWeb.*` interacts with `:harness` strictly through a thin `HWeb.Backend` adapter wrapping `H.Daemon` + `H.PubSub`, so `:harness_web` can also point at a remote `:harness` HTTP+SSE daemon later without rewriting LiveViews.)*

---

## 2. Client-Local State vs. Durable Daemon State

Clients remain thin, crash-disposable views by keeping view navigation strictly separate from durable session state:

| Owned by Client (`HWeb` LiveView / Browser / `HTUI`) | Owned by Durable Engine (`H.Catalog` & `H.Session.Server`) |
|---|---|
| Current folder-browser path, filter, and expanded tree nodes | Canonical `{env_id, cwd}` session bindings and per-folder session history |
| Selected `(session_id, conversation_id)` cursor | Conversation ancestry forest (`parent: %{conversation_id, at}`) and raw entries |
| Scroll offset, loaded history window, collapsed `<details>` / tool folds | Active tasks (`generation`, `tool_call`), `live` stream state, `inbox` queue |
| Unsent prompt draft, slash-command autocomplete menu, pending retry badge | Committed `agent` config (`model`, `thinking`, `instructions`, `tools`) & `usage` rollups |

Every mutating action from any client sends an idempotent command envelope (`version: 1`, client-generated `request_id`, `command`, `conversation_id`, `args`) to `H.Daemon.execute_command/3`.

---

## 3. Real-Time Multi-Surface Synchronization (Web + Mobile + TUI)

Because `H.Session.Server` is the single mutation authority per session and broadcasts every committed batch and throttled live stream delta over `H.PubSub`, **all connected clients stay in lockstep automatically**:

```text
  tmux Terminal (HTUI in ~/Projects/foo)           Mobile / Desktop Browser (HWeb LiveView)
  ──────────────────────────────────────           ────────────────────────────────────────
  1. `cd ~/Projects/foo && h`                      1. Browse to ~/Projects/foo -> tap session
     GET /api/v1/sessions?cwd=...                     H.Daemon.subscribe_conversation(sid, "1")
     GET /api/v1/sessions/:sid/.../events (SSE)       Receives {:snapshot, seq, state}
                  │                                                │
                  └──────────────────────┬─────────────────────────┘
                                         ▼
                           H.Session.Server (sid, conv #1)
                                         │
        ┌────────────────────────────────┴────────────────────────────────┐
        ▼                                                                 ▼
  • Prompt typed on Web immediately appears as a committed user entry in TUI (`seq + 1`).
  • Ephemeral thinking deltas, assistant tokens, and live `bash` stdout stream to both (~50 ms).
  • Pressing `Esc` (abort) or sending a `steer` message from TUI updates Web/Mobile instantly.
  • Closing the browser tab or detaching `tmux` interrupts nothing; reattaching replays missed
    commits from the 64-entry replay ring (or falls back cleanly to a fresh snapshot).
```

### Projection Parity Across Surfaces

Both JavaScript (`ConversationTranscript` in `priv/static/transcript.js`), Elixir LiveView (`H.Transcript` pure reducer feeding LiveView `stream/3` + document assigns), and `HTUI` implement the exact same three-message state fold:
1. **`snapshot(seq, entries, has_more, before_entry_id, docs)`:** Replaces view state and sets `cursor_seq = seq`.
2. **`commit(seq, entries, doc_ops)`:** Applied iff `seq == cursor_seq + 1` (otherwise triggers resnapshot); appends immutable entries, applies `doc_ops` to `committed_docs`, resets `ephemeral_live = committed_docs.live`, and advances `cursor_seq = seq`.
3. **`ephemeral(base_seq, live_ops)`:** Applied iff `base_seq == cursor_seq`; patches `ephemeral_live` in place without advancing `cursor_seq`.

---

## 4. Two Complementary Developer Entry Flows

### 4.1 Folder-First Flow in Web & Mobile (`HWeb.*`)

1. Open the workspace picker (defaulting to the selected environment's home/projects root, e.g. `env_id: "host"`).
2. Browse directories (`H.Daemon.browse_workspace/2`):
   - Folders with project markers (`.git`, `mix.exs`, `package.json`, `Cargo.toml`, `AGENTS.md`) are highlighted.
   - Each folder displays badges from `H.Catalog` ETS: **active running indicator**, **direct/subtree past session count**, and **most recent session title + timestamp**.
3. Either click a past session in that folder to resume it immediately, or click **New Session Here** (auto-generating `session_id`, discovering `AGENTS.md` via `H.Harness`, and pre-selecting the default model).

### 4.2 Shell & `tmux`-First Flow in Terminal (`HTUI.*`)

1. In a terminal / `tmux` pane, `cd ~/Projects/my-app` and run `h`:
   - `h` checks whether a local `:harness` daemon holds `H.StoreLock`; if not, it starts the background daemon automatically (or connects to the already-running monolith VM).
   - `h` queries `GET /api/v1/sessions?env_id=host&cwd=/Users/.../Projects/my-app`.
2. Behaviour matches `pi` ergonomics backed by durable daemon sessions:
   - `h` — starts a fresh session in `pwd` (while showing a 1-key hint if recent sessions exist for `pwd`).
   - `h -c` / `h --continue` — resumes the most recently updated session in `pwd`.
   - `h -r` / `h --resume` — opens a compact picker of past sessions in `pwd` (with branch counts and active status).
3. Once attached, the session is visible in `HWeb` on desktop and mobile under `~/Projects/my-app`, so the developer can walk away from their desk and continue or monitor the exact same run from their phone.
