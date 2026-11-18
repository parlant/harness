# Slice 5: Workspace Directory Browser, `ExecutionEnv.Host`, `H.Harness`, and Live TUI/Web Sync

**Status:** Next vetted vertical slice (prerequisite Slices 0–4 complete).

---

## 1. User Story & Scope

> **As a developer**, I want to browse the directories of my machine (or target execution environment), see at a glance which folders have past or active sessions, and either resume an existing session in a folder or start a new one right there without manually typing paths or session IDs.
>
> From my terminal inside `tmux`, I also want to `cd` into any directory and run the harness CLI/TUI (`mix h` / `h`), automatically scoped to `pwd`—resuming or starting a session in that folder—while staying synchronized live with the Web UI whenever both are viewing the same session.

### Why This Slice First (Approachability & Zero Bloat)

Before introducing Phoenix (`:harness_web`) and a full-screen TUI (`:harness_tui`) as separate Mix apps in Slice 6, Slice 5 establishes and proves the **exact engine & harness seams** those clients need—requiring **zero new Hex dependencies** in `:harness` and keeping every change small, backwards-compatible, and testable in isolation.

---

## 2. Vetted Module-by-Module Changes

### 2.1 `H.ExecutionEnv` & `H.ExecutionEnv.Host` (`lib/h/execution_env.ex`, `lib/h/execution_env/host.ex`)

1. **Promote `H.ExecutionEnv.Host` (keep `H.ExecutionEnv.Local` as a thin compatibility alias):**
   - `H.ExecutionEnv.Host.new(cwd \\ System.user_home!(), opts \\ [])` carries `%{env_id: "host", cwd: canonical_cwd, env_overrides: ...}`.
   - Add `H.ExecutionEnv.env_id/1` (defaulting to `"host"`).
2. **Rich single-roundtrip `list_dir/3` options (backward-compatible with existing `Conformance`):**
   - `only_dirs: boolean()` (default `false`) — returns directories plus symlinks pointing to directories.
   - `include_hidden: boolean()` (default `true` for raw tool calls; `false` by default in workspace browser queries).
   - `markers: [String.t()]` (optional, e.g. `[".git", "mix.exs", "package.json", "Cargo.toml", "pyproject.toml", "AGENTS.md"]`) — checks marker existence inside each returned directory entry (`markers: [".git", "mix.exs"]`), plus `target_type: "dir" | "file" | "other"` on `"symlink"` entries so symlinked project roots are navigable.
3. **Environment registry (`H.EnvRegistry` or `daemon_opts[:environments]`):**
   - Maps `env_id` (`"host"` by default) to its `H.ExecutionEnv` factory and default browse root (`System.user_home!()`), ensuring `H.Daemon` resolves paths through `H.ExecutionEnv.resolve_path/2` instead of host-coupled `Path.expand/1`.

### 2.2 `{env_id, cwd}` Scoping in `H.WorkspaceLease` & `H.Catalog`

1. **`H.WorkspaceLease` (`lib/h/workspace_lease.ex`):**
   - Accept `{env_id, canonical_cwd}` keys (supporting bare `cwd` string as `{"host", Path.expand(cwd)}` for existing callers).
2. **`H.Catalog` (`lib/h/catalog.ex`):**
   - Persist `env_id` (defaulting missing values in existing `sessions.json` records to `"host"`) and optional `harness_id` (default `"coding"`).
   - Add lock-free ETS query helpers (never waking unloaded sessions):
     - `list_sessions_for_cwd(env_id, cwd, opts \\ [])` — filters by exact `cwd` (or `subtree: true` boundary-safe prefix `cwd <> "/"`), sorted by `updated_at` desc.
     - `annotate_directories(env_id, parent_path, dir_entries, table \\ :h_catalog)` — enriches each directory entry in a single pass over ETS sessions with:
       ```elixir
       %{
         direct_session_count: non_neg_integer(),
         subtree_session_count: non_neg_integer(),
         active_session_count: non_neg_integer(),
         latest_session: nil | %{session_id: String.t(), title: nil | String.t(), updated_at: integer(), active: boolean()}
       }
       ```

### 2.3 `H.Harness` Seam & `H.Harness.Coding` (`lib/h/harness.ex`, `lib/h/harness/coding.ex`)

1. Define `H.Harness` behaviour (`id/0`, `descriptor/0`, `tools/1`, `bootstrap_agent/3`).
2. Implement `H.Harness.Coding` (`id: "coding"`, default `pi`-compatible harness):
   - Tools: `[H.Tools.Read, H.Tools.Write, H.Tools.Edit, H.Tools.Bash, H.Tools.SearchHistory]`.
   - `AGENTS.md` discovery via `H.ExecutionEnv`: walks ancestor directories up to home/root reading `AGENTS.md` through `H.ExecutionEnv.read_file_bytes/3`, concatenating discovered instructions into `agent["instructions"]` when not explicitly overridden.

### 2.4 Frictionless Folder Creation, Auto-Titling & Daemon/HTTP Endpoints

1. **Optional `session_id` on `H.Daemon.create_session/2`:**
   - When `session_id` is omitted or empty, mint `<slug(Path.basename(cwd))>-<short_random>` (e.g. `harness-9f3a2c`) and verify uniqueness in `H.Catalog`.
2. **Automatic first-prompt session `title` in `H.Session.Server`:**
   - On the first user `input` submission when `session_meta.title` is `nil`, derive a concise single-line title (~72 chars max) from the prompt text and report it via `H.Catalog.report_runtime/3`.
3. **Workspace Browsing & CWD Filter Endpoints (`H.Daemon` + `H.HTTP.Router`):**
   - `GET /api/v1/environments` -> `%{environments: [%{id: "host", kind: "host", default_cwd: "/Users/..."}]}`
   - `GET /api/v1/fs?env_id=host&path=/Users/...&include_hidden=false` ->
     ```json
     {
       "env_id": "host",
       "path": "/Users/me/Projects",
       "parent_path": "/Users/me",
       "directories": [
         {
           "name": "diy-harness",
           "path": "/Users/me/Projects/diy-harness",
           "markers": [".git", "mix.exs", "AGENTS.md"],
           "direct_session_count": 2,
           "subtree_session_count": 2,
           "active_session_count": 1,
           "latest_session": {"session_id": "diy-harness-a1b2", "title": "Fix model list", "updated_at": 1763420000000, "active": true}
         }
       ],
       "sessions": []
     }
     ```
   - `GET /api/v1/sessions?env_id=host&cwd=/Users/me/Projects/diy-harness` -> filtered session list for `pwd`.

### 2.5 Cooperative Daemon Socket & Usable Reference Folder Picker

1. **Unix Domain Socket Listener (`<data_dir>/api.sock`):**
   - Allow `H.Application` / `H.serve/1` to bind an owner-only (`0600`) Unix domain socket (`{:local, Path.join(data_dir, "api.sock")}`) alongside loopback TCP and adjust `H.HTTP.SecurityPlug` to permit authenticated local Unix-socket `Bearer` requests from cooperative local clients (such as `clients/tui/`).
2. **Interactive Folder Browser in Reference Web UI (`priv/static/`):**
   - Replace manual `/path/to/repo` typing in `+ New Session` with an interactive folder picker backed by `GET /api/v1/fs` showing parent `..`, clickable subdirectories, project markers, per-folder past session badges, 1-click **Resume**, and 1-click **Start New Session Here**—proving the full workspace-browsing UX before building `clients/web/` (Slice 6) and `clients/tui/` (Slice 7).

---

## 3. Acceptance & Verification Criteria

1. **`H.ExecutionEnv.Conformance`:** New tests for `list_dir/3` with `only_dirs: true`, `include_hidden: false`, symlinked directories, and `markers`.
2. **`H.Catalog` Folder Annotation Tests:** Exact vs. prefix boundary tests (`/path/app` must never match `/path/app-v2`!), subtree rollups, and active counts without starting `H.Session.Server`.
3. **`H.Harness.Coding` Tests:** Ancestor `AGENTS.md` discovery through `H.ExecutionEnv` (verified on disposable temp workspaces without touching the user's home directory).
4. **Auto-ID, Auto-Title & HTTP `/api/v1/fs` Tests:** `POST /api/v1/sessions` with `%{"cwd" => cwd}` only -> auto-minted `session_id` -> first prompt sets `title` in `GET /api/v1/fs` and `GET /api/v1/sessions?cwd=...`.
5. **Unix-Socket + TCP Multi-Client Sync Test:** Simultaneous Unix-socket `Bearer` SSE subscriber (modeling the cooperative TUI) and loopback cookie/Origin HTTP+SSE subscriber (modeling the browser) attached to the same folder session observe identical `seq` commits and `ephemeral` deltas across `submit`, `steer`, and `abort`.
