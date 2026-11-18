# Phoenix Web & Mobile Client Architecture (`HWeb.*` / `:harness_web`)

**Status:**
- **Implemented Today (Slice 2 Reference UI):** Zero-build vanilla ES-module client (`priv/static/*`) served directly by `:harness` (`H.HTTP.Router`) for bootstrap and API verification.
- **Proposed (Slice 6):** Dedicated Phoenix + LiveView application (`clients/web/`, OTP app `:harness_web`, namespace `HWeb.*`) targeting **Desktop and Mobile browsers**, isolated from `:harness` (`H.*`) at the namespace and Mix project level while able to run inside the **same BEAM VM** as a single monolith.

---

## 1. Namespace & Mix Project Separation (`:harness` vs. `:harness_web`)

The durable agent engine (`:harness`, `H.*`) and the Phoenix web application (`:harness_web`, `HWeb.*`) evolve at different rhythms and have very different dependency trees. Instead of coupling Phoenix into `:harness`—or forcing external daemon users to compile an umbrella full of frontend assets—we invert the dependency direction:

```text
/ (repo root)
├── mix.exs                    # OTP app :harness (H.*) — ZERO Phoenix, LiveView, or CSS/JS bundler deps
├── lib/h/...
└── clients/
    ├── web/
    │   ├── mix.exs            # OTP app :harness_web (HWeb.*), depends on {:harness, path: "../.."}
    │   └── lib/h_web/...
    └── tui/                   # Non-BEAM cooperative terminal client (see client-tui.md)
```

### Two Clean Compilation & Deployment Modes

1. **Daemon-Only Compilation (Repo Root):**
   Running `mix compile` or `mix release` at the repository root compiles **only `:harness` (`H.*`)** (`bandit`, `plug`, `req`, `req_llm`). Developers who only want the headless durable daemon + `h` TUI (or their own custom HTTP/SSE clients) never download or compile Phoenix, LiveView, Tailwind, or esbuild.
2. **Monolithic Web Application Compilation (`clients/web/`):**
   Running `mix phx.server` or `mix release` inside `clients/web/` compiles `:harness` and `:harness_web` together into **one BEAM VM**:
   - OTP starts `:harness` (`H.Supervisor` holding `H.StoreLock`, `H.Catalog`, `H.Session.RuntimeSupervisor`, and `:harness`'s local API socket) followed by `:harness_web` (`HWeb.Endpoint`).
   - `HWeb.*` LiveViews communicate with `H.Daemon` and `H.PubSub` **in-memory** inside the BEAM VM, while local `h` TUI processes in `tmux` simultaneously attach to `:harness`'s local API endpoint on the exact same running sessions.

---

## 2. Backend Seam: `HWeb.Backend` (`InVM` vs. `HTTP`)

LiveViews never touch `H.Session.Server` state or storage files directly. All calls go through a thin `HWeb.Backend` behaviour configured on `:harness_web`:

- **`HWeb.Backend.InVM` (Default Monolith Adapter):**
  - Reads/commands invoke `H.Daemon` functions directly (`browse_workspace/2`, `list_sessions/1`, `create_session/2`, `get_session_detail/2`, `scan_entries/4`, `execute_command/3`, `list_models/1`).
  - LiveView `mount/3` (when `connected?(socket)` is `true`) subscribes the LiveView process directly to `H.PubSub` (`{:conversation, session_id, conversation_id}`).
- **`HWeb.Backend.HTTP` (Optional Split-Host Adapter):**
  - Speaks `/api/v1/*` HTTP + SSE via `Req` when `:harness_web` is deployed separately from `:harness`.

---

## 3. LiveView State & Memory Architecture

Long-running coding sessions accumulate hundreds of entries, large unified diffs, and 50 ms streaming deltas. Naive LiveView state keeping full transcripts in `socket.assigns` causes excessive per-tab memory retention and slow diffs. `HWeb.SessionLive` avoids both traps:

### 3.1 `Phoenix.LiveView.stream/4` for Committed Entries

- Committed immutable entries (`user`, `assistant`, `tool_result`, `system`, `compaction`, `reset`) are pushed into **`stream(socket, :entries, items)`** (`dom_id: "entry-#{entry.id}"`).
- Once rendered and sent over the LiveView WebSocket, entry bodies are **freed from LiveView process heap** on the server.
- Scrolling up ("Load earlier" / `phx-viewport-top`) fetches the previous cursor page from `H.Daemon.scan_entries/4` and prepends via `stream(socket, :entries, older_items, at: 0)` while preserving viewport scroll anchor on the client.

### 3.2 Isolated Assigns & LiveComponent for 50 ms Ephemeral Streams

The LiveView process retains only compact operational metadata in `assigns`:

| Assign | Purpose |
|---|---|
| `env_id`, `browse_path` | Current environment (`"host"`, `"vm-..."`) and directory browser cursor |
| `session_id`, `conversation_id` | Currently viewed session and branch |
| `cursor_seq` | Last applied durable commit `seq` (strict monotonicity & gap detection) |
| `before_entry_id`, `has_more` | Backward pagination cursor for older transcript entries |
| `committed_docs` | Latest committed `agent`, `live`, `inbox`, and `usage` maps (`< 10 KB`) |
| `ephemeral_live` | Current in-flight `live` state (`run`, `generation.message`, `tools` stdout) |

When `{:ephemeral_event, sid, cid, frame}` arrives (~20 times/sec during token or `bash` streaming):
- Only `ephemeral_live` changes (validated against `base_seq == cursor_seq`, identical to `ConversationTranscript` rules).
- LiveView diffs **only** the active `<.live_region>` at the bottom of the transcript—zero committed entry cards are re-evaluated or re-sent.
- When `{:commit_event, sid, cid, seq, frame}` arrives:
  - If `seq == cursor_seq + 1`: new entries are appended to `@streams.entries`, `doc_ops` update `committed_docs`, `ephemeral_live` resets to `committed_docs["live"]`, and `cursor_seq` advances to `seq`.
  - If `seq > cursor_seq + 1` (missed frame): `HWeb.SessionLive` calls `resnapshot` (`stream(..., reset: true)`) to converge cleanly.

---

## 4. Desktop & Mobile UX Design

Web is the primary cross-device surface because one Phoenix LiveView codebase serves both **multi-pane desktop development** and **on-the-go mobile monitoring/steering**:

### 4.1 Workspace & Folder Browser (`GET /api/v1/fs` / `H.Daemon.browse_workspace/2`)

- **Environment Switcher:** Select `"host"` (local machine) or any registered remote `ExecutionEnv` (`"vm-..."`).
- **Directory Navigator:**
  - Breadcrumb path bar (`/Users/me/Projects/diy-harness`) + parent `..` + instant filter input.
  - Project root badges (`.git`, `mix.exs`, `Cargo.toml`, `package.json`, `AGENTS.md`).
  - Per-folder session indicators directly from `H.Catalog` ETS:
    - Live pulsing indicator when `active_session_count > 0`,
    - Badge showing `direct_session_count` (and `subtree_session_count` for parent directories),
    - Expandable inline list of past sessions in that folder (`title`, relative `updated_at`, model) with **Resume** + **Start New Session Here** actions.

### 4.2 Conversation, Branching & Tool Inspection

- **Desktop (3-pane responsive layout):**
  - *Left rail:* Pinned/recent workspaces, sessions in current folder, and the conversation fork tree (`#1 -> #4 @ entry 12`).
  - *Center pane:* Virtualized/paged transcript stream, live streaming thinking + markdown response + active tool progress, queued `inbox` pills, sticky `run_failure` recovery banner (`Continue`), and keyboard-first composer (`Enter` send/follow-up, `Shift+Enter` newline, `Alt+Enter` steer, `Esc` abort).
  - *Right inspector (collapsible):* Side-by-side / unified file diff viewer for `edit` and `write` tool calls, full ANSI-stripped/formatted `bash` output viewer, and active `agent` configuration (`model`, `thinking`, discovered `AGENTS.md` instructions, token/cost breakdown).
- **Mobile (Phone / Tablet layout):**
  - Single-column viewport with swipe/button slide-over drawer for folder & session switching.
  - Compact collapsible pills for thinking blocks and tool calls (tap to expand diff or command output in a mobile sheet).
  - Sticky bottom composer with explicit touch buttons for **Send**, **Steer** (visible while a run is active), and **Stop**, plus draft preservation (`phx-hook="ComposerDraft"` in `localStorage`) across mobile network drops or Safari tab suspension.

---

## 5. Authentication & Network Security

1. **WebSocket Mount Verification:** Browser authentication exchanges the owner token (`<data_dir>/auth.token`) for an encrypted, `HttpOnly` Phoenix session cookie. `HWeb.SessionLive` verifies the session token inside `on_mount` on **both** initial HTTP render and LiveView WebSocket upgrade.
2. **Loopback by Default, Explicit Opt-In for Mobile/LAN:**
   - Default bind is `127.0.0.1`.
   - To use `HWeb` from a phone, bind explicitly to a private overlay interface (e.g. Tailscale IP / HTTPS cert via `HWeb.Endpoint` config) with strict `check_origin` enforcement, while `:harness`'s raw daemon socket remains local-only (`127.0.0.1` / `<data_dir>/api.sock`).
