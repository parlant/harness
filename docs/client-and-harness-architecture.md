# Client, Harness, and Workspace Architecture

**Status:** Proposal for the next architectural evolution and vertical slice (building on the implemented Slices 0–4 durable core).

---

## 1. Core Thesis: Durable Engine vs. Harness vs. Clients

As `H` moves beyond self-hosting, we separate three concerns that are often conflated in agent frameworks:

1. **The Durable Host (`H.*` / `:harness`):**
   A headless, domain-agnostic BEAM runtime for durable conversations, branching history (`Conversation` + `Entry`), effect-sandwiched tasks (`Task`), idempotent command receipts (`Submission`), versioned state documents (`Document`), and zero-copy `ProcBin` event fan-out (`H.PubSub`). The durable core knows **how** to sequence, persist, recover, and broadcast turns—not what persona, tools, or UI a particular agent uses.
2. **A Harness (`H.Harness` profile, e.g. `Pi`):**
   A harness is defined by **its execution environment (including its filesystem), its tool suite, its system instructions/context rules (e.g. `AGENTS.md`, skills), and its client workflow**. Our durable core (`H`) can host any number of harnesses simultaneously without bloating `H.Session.Server`.
3. **Clients (`HWeb.*` Phoenix Web/Mobile, `HTUI.*` Terminal UI):**
   Stateless or view-stateful projections that browse workspaces, attach to durable sessions, submit commands, and render live streams. Because all state lives in the durable daemon and fans out through `H.PubSub`, **Web, Mobile, and TUI clients attached to the same session are synchronized in real time**.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                             Clients (Views)                             │
│                                                                         │
│  ┌──────────────────────────────┐     ┌──────────────────────────────┐  │
│  │   HWeb.* (Phoenix / Web)     │     │     HTUI.* / Pi TUI (CLI)    │  │
│  │  Desktop & Mobile Browser    │     │  Started in `pwd` via tmux   │  │
│  └──────────────┬───────────────┘     └──────────────┬───────────────┘  │
└─────────────────┼────────────────────────────────────┼──────────────────┘
                  │ In-VM H.Daemon + H.PubSub          │ Loopback HTTP + SSE
                  │ (or HTTP + SSE)                    │ (or Unix socket)
                  ▼                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      H.* (:harness Durable Host)                        │
│                                                                         │
│  H.Catalog (ETS cwd index)  ·  H.Workspace (Directory & Session Browser)│
│  H.Session.Server (Drain-Batch Commits, Tasks, Documents,H.PubSub)      │
└─────────────────┬────────────────────────────────────┬──────────────────┘
                  │                                    │
                  ▼                                    ▼
┌──────────────────────────────────┐ ┌────────────────────────────────────┐
│     Harness Profile (e.g. Pi)    │ │          H.Provider                │
│  • H.ExecutionEnv (Local/Remote) │ │  • H.Provider.ReqLLM (OpenAI,      │
│  • H.Tool suite (read/edit/bash) │ │    Anthropic, Vertex, DeepSeek)    │
│  • Workspace AGENTS.md & skills  │ │  • H.Credentials                   │
└──────────────────────────────────┘ └────────────────────────────────────┘
```

---

## 2. Namespace & Compilation Separation

The durable agent daemon (`H.*`) and client applications (`HWeb.*`, `HTUI.*`) have fundamentally different lifecycles and dependency footprints. We enforce strict separation so they can be compiled and deployed either standalone or together on a single BEAM node:

| Layer | Namespace | OTP App / Target | Responsibilities & Dependencies |
|---|---|---|---|
| **Durable Core & Daemon** | `H.*` | `:harness` | Pure history, `H.Storage.{Memory,File}`, `H.Catalog`, `H.Session.Server`, `H.Provider.ReqLLM`, `H.ExecutionEnv`, and the lightweight `H.HTTP` JSON/SSE API (`Bandit` + `Plug`). **Zero Phoenix, LiveView, or UI asset dependencies.** |
| **Harness Profiles** | `H.Harness.*` (or `Pi.*`) | `:harness` (or `:pi_harness`) | Bundles an `H.ExecutionEnv`, `[H.Tool]`, workspace instruction discovery (`AGENTS.md`), and default agent document settings. |
| **Phoenix Web Application** | `HWeb.*` | `:harness_web` | Full desktop + mobile web client (`Phoenix`, `Phoenix.LiveView`). Calls `H.Daemon` and subscribes to `H.PubSub`. Can run **inside the same BEAM VM** as `:harness` (monolith mode) or connect remotely. |
| **Terminal Client (TUI)** | `HTUI.*` | `:harness_tui` | Lightweight terminal UI started from any shell directory (`cd ~/repo && h`). Connects to the local `:harness` daemon (auto-starting it via `H.StoreLock` if not yet running) over loopback HTTP/SSE. |

### Two Supported Deployment Topologies

1. **Headless Daemon + External Clients:**
   Compile and run `:harness` alone. Any TUI, CLI, editor integration, or custom web app talks to `H.HTTP` (`/api/v1/*` JSON + SSE).
2. **Single-BEAM Monolith (`:harness` + `:harness_web`):**
   Compile and boot `:harness` and `:harness_web` (`HWeb.Endpoint`) in one BEAM OS process. Inside the VM, `HWeb` LiveViews invoke `H.Daemon` functions directly and subscribe to `H.PubSub` (`Registry`) with zero localhost HTTP serialization overhead—while `:harness` simultaneously serves `/api/v1/*` so a TUI in `tmux` attaches to the exact same running sessions.

---

## 3. Relation Between Client, Server, Durable Host, and ExecutionEnv

To keep the durable core small and prevent client concerns from leaking into `H.Session.Server`, each boundary has a single authority:

1. **Client (`HWeb.*`, `HTUI.*`):**
   - Owns **ephemeral view state**: current directory browser path, selected `session_id` and `conversation_id`, scroll position, collapsed tool/thinking blocks, and unsent input drafts.
   - Never mutates session files or executes tools directly. Every state change goes through an idempotent `H.Daemon.execute_command/3` envelope (`submit`, `steer`, `configure`, `abort`, `fork`, `fork_and_submit`).
2. **Server / Transport (`H.HTTP.*` or `HWeb.*` LiveView):**
   - Authenticates the user (`H.Auth`), translates wire requests into `H.Daemon` calls, and forwards `H.PubSub` events (`{:commit_event, ...}` and `{:ephemeral_event, ...}`) to connected sockets.
3. **Durable Host (`H.Daemon`, `H.Catalog`, `H.Session.Server`):**
   - **`H.Catalog`** is the authority for cross-session metadata (`session_id`, `title`, canonical `cwd`, `active`, `updated_at`, `status`) backed by ETS for `O(1)` lock-free reads without waking unloaded sessions.
   - **`H.Session.Server`** is the single writer for one session (`<data_dir>/sessions/<sid>/`), sequencing entries, tasks, and documents via drain-batch commits.
4. **Execution Environment (`H.ExecutionEnv`):**
   - Owns **workspace filesystem & OS process access** scoped to a root directory (`cwd`).
   - Used both **before** a session starts (by the workspace directory browser to list folders) and **during** a session (by `H.Tools.*` and workspace instruction discovery such as reading `AGENTS.md`).
   - Because filesystem browsing goes through `H.ExecutionEnv`, the exact same folder-browsing UX works whether the execution environment is `H.ExecutionEnv.Local` (the developer's laptop) or a future remote/sandboxed `H.ExecutionEnv.SSH` / container environment.

---

## 4. Multi-Surface Live Synchronization (Web + Mobile + TUI)

Because `H.Session.Server` is the single source of truth and broadcasts every committed state transition and ephemeral stream delta over `H.PubSub`, **TUI and Web/Mobile are peers on the same durable bus**:

```text
Developer in tmux (HTUI)                      Developer on Phone / Browser (HWeb)
       │                                                     │
       │  1. Types prompt & hits Enter                       │
       ├─────────────────────────────┐                       │
       │                             ▼                       │
       │                     H.Session.Server                │
       │                     (Commit seq = 14)               │
       │                             │                       │
       │         ┌───────────────────┴───────────────────┐   │
       │         ▼ {:commit_event, seq=14}               ▼   │
       │  HTUI renders user message              HWeb renders user message
       │         │                                       │   │
       │         ▼ {:ephemeral_event} (50ms throttle)    ▼   │
       │  HTUI streams tokens & tool output      HWeb streams tokens & tool output
       │                                                     │
       │                          2. Hits Stop (Esc) or Steer│
       │                             ┌───────────────────────┘
       │                             ▼
       │                     H.Session.Server
       │                     (Commit seq = 15)
```

- **Zero client-to-client state sync:** Clients never talk to each other. Both apply the same snapshot + `seq`-ordered commit deltas (`ConversationTranscript` semantics in JS and Elixir).
- **Mid-stream attach:** Opening a phone browser or starting the TUI in `tmux` while a generation or `bash` tool is already running immediately delivers the latest committed snapshot (`seq`) plus current in-memory `live.generation` / `live.tools` progress, then continues streaming live `ephemeral` and `commit` events.

---

## 5. Next Vertical Slice: Workspace Directory Browser & Folder-Scoped Sessions

### User Story

> **As a developer**, I want to browse the directories on my machine, pick a folder, and start a new session rooted there. While browsing folders, I can immediately see which folders have past or active sessions, and either resume an existing session for that folder or start a fresh one.
>
> Equally, from my terminal (inside `tmux`), I can `cd` into any project folder and launch the harness TUI (`h`), which automatically scopes to `pwd`—letting me resume a recent session in that folder or start a new one—while staying 100% synchronized with the Web UI if both are open on the same session.

### Minimal Core Additions Required (Without Bloating `H`)

#### 5.1 `H.ExecutionEnv.list_dir/2` — Safe Directory Enumeration
Extend `H.ExecutionEnv` (and `H.ExecutionEnv.Local` + `H.ExecutionEnv.Conformance`) with a non-recursive directory listing callback:
```elixir
@callback list_dir(t(), Path.t(), keyword()) ::
            {:ok, [%{name: String.t(), path: String.t(), type: :directory | :file | :symlink}]}
            | {:error, term()}
```
- Returns sorted entries (`:directory` first, hidden dotfiles optional via `include_hidden: boolean()`).
- Detects project markers (`.git`, `mix.exs`, `package.json`, `Cargo.toml`, `AGENTS.md`) so the folder browser can highlight project roots.

#### 5.2 `H.Catalog` Folder Index (`sessions_by_cwd` & Subtree Counts)
`H.Catalog` already stores canonical expanded `cwd` (`Path.expand/1`) in ETS. Add pure ETS read helpers (never waking unloaded sessions):
- `H.Catalog.list_sessions_for_cwd(cwd, opts)`: Returns all sessions whose `cwd == Path.expand(cwd)` (or under `cwd` when `recursive: true`), sorted by `updated_at` descending.
- `H.Catalog.AnnotateDirectories`: Given a parent directory and its child directory paths from `list_dir/2`, annotates each child folder with:
  - `direct_session_count` (sessions rooted at that exact folder),
  - `subtree_session_count` (sessions rooted in that folder or any subfolder),
  - `active_session_count` (currently running sessions in that subtree),
  - `latest_session` (`%{session_id, title, updated_at, active}`).

#### 5.3 Optional `session_id` & Automatic First-Prompt Title
 friction-free session creation from a folder or TUI startup:
- When `POST /api/v1/sessions` (or `H.Daemon.create_session/2`) is called with `%{"cwd" => "/Users/me/Projects/foo"}` and **no `session_id`**, `H.Daemon` automatically generates a clean, collision-free ID derived from the folder basename and timestamp/random suffix (e.g. `foo-20261118-a4f9`).
- When `title` is `nil` on session creation, `H.Session.Server` automatically sets the session `title` (and reports it to `H.Catalog`) from the first user prompt's opening line (truncated cleanly to ~72 chars).

#### 5.4 `H.Harness` Profile & Workspace `AGENTS.md` Discovery
Introduce `H.Harness` as a pure configuration seam when initializing a session in `cwd`:
- Discovers `AGENTS.md` (walking up from `cwd` to `$HOME` plus `~/.pi/agent/AGENTS.md` when using the `pi`-compatible coding harness profile) and injects it into the initial `agent.instructions` document field at session creation.
- Registers the harness's tool modules (`[H.Tools.Read, H.Tools.Write, H.Tools.Edit, H.Tools.Bash, H.Tools.SearchHistory]`) and `H.ExecutionEnv`.

#### 5.5 HTTP / Daemon Endpoints for the Workspace Browser
Add two read-only endpoints to `H.Daemon` and `H.HTTP.Router`:
1. `GET /api/v1/fs?path=<abs_path>&include_hidden=false`
   - Calls `H.Daemon.browse_workspace(path, opts)` -> lists subdirectories via `H.ExecutionEnv.Local.list_dir/3`, enriches each directory with `H.Catalog` session counts/recency, and returns the sessions rooted directly at `path`.
2. `GET /api/v1/sessions?cwd=<abs_path>`
   - Filters `H.Daemon.list_sessions/1` to sessions matching `cwd` (exact or prefix), used by both the Web folder picker and the TUI on startup in `pwd`.

---

## 6. Verification Plan for the Next Vertical Slice

1. **`H.ExecutionEnv.Conformance`:** Test `list_dir/3` on nested folders, symlinks, permission errors, and hidden-file filtering.
2. **`H.Catalog` CWD Indexing Tests:** Verify exact-match and subtree session counts, active indicators, and `O(1)` ETS reads without starting `H.Session.Server`.
3. **Auto-ID & Auto-Title Tests:** Create a session with only `%{"cwd" => cwd}`, submit a prompt, and verify the minted `session_id` and auto-derived `title` in `H.Catalog`.
4. **Dual-Client Sync Test (Web + TUI Simulation):** Attach two independent subscribers (simulating `HWeb` and `HTUI`) to the same folder session, submit from one, steer/abort from the other, and assert identical `ConversationTranscript` state at every committed `seq`.
