# Harness Profiles & Pluggable Execution Environments

**Status:**
- **Implemented (Slice 4):** `H.ExecutionEnv` behaviour, `H.ExecutionEnv.Conformance` suite, local host implementation (`H.ExecutionEnv.Local`), `H.WorkspaceLease`, and `JSV`-validated coding tools (`read`, `write`, `edit`, `bash`, `search_history`).
- **Proposed (Slices 5 & 7):** `H.Harness` profile behaviour (e.g. `Pi`-compatible coding harness with `AGENTS.md` discovery via `H.ExecutionEnv`), `H.ExecutionEnv.Host` + pre-session directory browsing enhancements, `{env_id, cwd}` lease/catalog scoping, and cooperative `H.ExecutionEnv.Remote` VM execution agents.

---

## 1. What Is "A Harness"?

In agentic systems, **a harness is not the database or the web server**—a harness is the concrete working environment and operational discipline wrapped around a model:

1. **Execution Environment (`H.ExecutionEnv`):** The filesystem, directory tree, working directory (`cwd`), and OS process/shell boundary the agent inhabits.
2. **Tool Suite (`[H.Tool]`):** The set of actions exposed to the model (`read`, `write`, `edit`, `bash`, `search_history`, or domain-specific tools), including JSON schemas, output windowing, workspace lease rules (`mutating?`), and crash-replay classification (`:safe | :unsafe`).
3. **Context & Instruction Assembly (`H.Harness`):** How workspace rules (`AGENTS.md`), skills, environment facts (OS, shell, git root), system prompts, and default `agent` settings are discovered and projected into `H.Context`.
4. **Workflow Conventions:** Slash/control commands, compaction policies, approval gates, and tool-output presentation hints.

By keeping `H.Session.Server` agnostic to these choices, **one `:harness` durable engine can host multiple harnesses side by side**—for example:
- **`H.Harness.Pi` (Coding Harness):** Full `read`/`write`/`edit`/`bash`/`search_history` toolset, hierarchical `AGENTS.md` + skill discovery, and per-workspace writer leases—allowing a faithful, durable rebuild of `pi` on top of `H`.
- **Read-Only Audit / Research Harness:** Offers only `replay: :safe` read/search tools with zero mutating leases so dozens of branches analyze a codebase concurrently.
- **Remote Ops / Sandbox Harness:** Binds tools to a remote VM or ephemeral container `H.ExecutionEnv` with approval gates on mutating commands.

---

## 2. The `H.Harness` Behaviour Seam

A harness profile is a pure Elixir module resolved by string `harness_id` (persisted on session metadata; never persisted as a function or module atom from untrusted input):

```elixir
defmodule H.Harness do
  @type descriptor :: %{
          id: String.t(),
          name: String.t(),
          description: String.t()
        }

  @callback id() :: String.t()
  @callback descriptor() :: descriptor()
  @callback tools(opts :: keyword()) :: [module()]
  @callback bootstrap_agent(H.ExecutionEnv.t(), initial_overrides :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
```

### Critical Rule: Discover Context Through `H.ExecutionEnv`, Never Host `File.*`

When `H.Harness.Pi.bootstrap_agent/3` discovers workspace instructions (such as walking from `cwd` up toward the workspace/home root for `AGENTS.md`), it **must read via `H.ExecutionEnv.read_file_bytes/3` and `H.ExecutionEnv.resolve_path/2`**, never Elixir's local `File.read/1`. That single rule guarantees that `AGENTS.md` discovery works identically whether the session runs on the local laptop (`ExecutionEnv.Host`) or on a remote Linux VM (`ExecutionEnv.Remote`).

---

## 3. `H.ExecutionEnv`: One Interface for Host, Sandbox, and Remote VMs

`H.ExecutionEnv` (`{mod, state}`) is the sole boundary between `H` (both pre-session workspace browsing and in-session tools) and any filesystem or OS process runner.

### 3.1 Audit Fixes Separating Engine Host from Target Environment

To support non-local execution environments cleanly, three hidden host assumptions are prohibited in `H.Daemon`, `H.Catalog`, and `H.WorkspaceLease`:

1. **Environment Identity (`{env_id, cwd}`):**
   Every workspace is identified by **`{env_id, canonical_cwd}`** (defaulting `env_id` to `"host"`). Two sessions at `"/workspace/app"` on `"host"` vs. `"vm:staging-1"` refer to different machines:
   - `H.Catalog` indexes and filters folder sessions by `{env_id, cwd}`.
   - `H.WorkspaceLease` keys mutating tool locks by `{env_id, canonical_cwd}` so separate VMs never block each other while two sessions targeting the **same** remote VM checkout still serialize mutating tools safely.
2. **Environment-Delegated Path Resolution:**
   `H.Daemon` must **not** call local `Path.expand(cwd)` for arbitrary environments (e.g. a Linux remote path when the engine runs on macOS). Instead, `H.ExecutionEnv.resolve_path(env, path)` is the canonicalizer for that environment's OS path semantics.
3. **Durable Descriptor vs. Runtime Handle:**
   Durable records (`H.Catalog`, `session_meta`) persist only plain JSON descriptors:
   ```json
   {"env_id": "host", "kind": "host", "cwd": "/Users/dev/Projects/app"}
   ```
   or
   ```json
   {"env_id": "vm-eu-1", "kind": "remote", "cwd": "/home/ubuntu/app"}
   ```
   Live sockets, node names, SSH channels, and auth tokens live exclusively in runtime `H.EnvRegistry` state, never in `commit.log`.

### 3.2 Two Lifecycle Scopes on `H.ExecutionEnv`

1. **Environment-Level Browsing (Pre-Session):**
   Before a session is created, clients browse an environment (`env_id`) starting from its default root (`default_cwd/1`, e.g. `$HOME` on `Host` or `/home/dev` on `Remote`) via `H.ExecutionEnv.list_dir(env, path, opts)`:
   - `only_dirs: boolean()` — filter to navigable directories (including symlinks whose target is a directory, reported as `type: "symlink", target_type: "dir"`).
   - `include_hidden: boolean()` — hide dotfiles by default while still checking project markers.
   - `markers: [String.t()]` — return matched project markers present inside each child directory (e.g. `[".git", "mix.exs", "AGENTS.md"]`) **in the same `list_dir` call** so remote environments render rich folder pickers in **one network roundtrip**, never `N + 1` stat calls.
2. **Workspace-Bound Execution (In-Session):**
   Once a folder is chosen, `H.ExecutionEnv` is bound to `cwd` (`bind_cwd/2`) and executes `read_file_lines/3`, `read_file_bytes/3`, `write_file/3`, `list_dir/3`, and `exec/3` for `H.Tools.*`.

---

## 4. `H.ExecutionEnv` Implementations

Every implementation must pass the shared `H.ExecutionEnv.Conformance` test suite.

| Implementation | `kind` | Execution Mechanism & Use Case |
|---|---|---|
| **`H.ExecutionEnv.Host`** *(alias: `Local`)* | `"host"` | Direct local `:file` `:raw` I/O, `File.ls`/`lstat`/`stat`, and OTP `Port.open` (`SID == PGID == os_pid`) with negative-PGID (`kill -TERM/-KILL -<os_pid>`) process-group reaping on the same machine as `:harness`. |
| **`H.ExecutionEnv.Worktree` / `Sandbox`** | `"worktree"` / `"sandbox"` | Scoped local checkout (e.g. isolated Git worktree or local container root) enabling parallel mutating branches on one machine without workspace lease contention. |
| **`H.ExecutionEnv.Remote`** *(Slice 7)* | `"remote"` | Cooperative lightweight execution agent running on a remote VM/container, speaking a versioned RPC protocol over authenticated mTLS WebSocket/HTTPS, SSH subsystem, or Distributed Erlang. |

### 4.1 Cooperative Remote `ExecutionEnv` Design (`Slice 7`)

When `:harness` runs locally (or on a central server) and cooperates with a remote VM's `ExecutionEnv.Remote` agent, network partitions and independent crashes become possible. `H`'s existing effect-sandwich architecture handles this cleanly when paired with three remote-agent rules:

```text
┌─────────────────────────────┐         Authenticated Stream / RPC         ┌─────────────────────────────┐
│   Durable Engine (:harness) │ ◄────────────────────────────────────────► │ Remote Execution Agent (VM) │
│                             │  1. list_dir / read / write / exec         │                             │
│ • Commits tool intent first │  2. Fencing token: {incarnation, tid, aid} │ • Executes local Host ops   │
│ • Streams on_output deltas  │  3. Lease heartbeat (e.g. every 5s)        │ • Tracks PGID per attempt   │
│ • Never auto-replays unsafe │  4. Explicit abort(attempt_id) -> -PGID    │ • Reaps PGID on lease loss  │
└─────────────────────────────┘                                            └─────────────────────────────┘
```

1. **Lease-Heartbeated Remote Process Groups:**
   Every `exec/3` call on the remote agent spawns a dedicated OS process group (`PGID`) bound to `{session_id, incarnation, task_id, attempt_id}` with a short lease TTL renewed by the engine worker's stream connection. If the engine crashes or the network drops beyond the grace window, the remote agent automatically terminates `-PGID` (`SIGTERM -> SIGKILL`) so orphan builds or servers never leak on the remote VM.
2. **Source-Side Windowing Over the Wire:**
   The remote agent enforces `max_bytes` / `window_bytes` / `window_lines` truncation **before** transmitting over the network (spilling full output to a temp path on the remote VM), keeping wire bandwidth bounded even if a remote command prints 500 MiB of logs.
3. **Ambiguous Network Failure = Interrupted, Never Blindly Replayed:**
   If the connection to the remote VM drops mid-`write`, mid-`edit`, or mid-`bash`, the engine worker fails; because those tools declare `replay: :unsafe`, `H.Session.Server` records an `"interrupted"` tool result with any partial output received before disconnect rather than re-running a mutating command whose remote completion status is unknown. Read-only calls (`read`, `list_dir`, `replay: :safe`) retry safely.
