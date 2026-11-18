# Slice 8: Cooperative Remote Execution Environments (`H.ExecutionEnv.Remote`)

**Prerequisite:** Slice 5 (`{env_id, cwd}` scoping + `H.ExecutionEnv` conformance) and client environment switcher (`HWeb.*` / `h`).
**Architecture:** [`docs/architecture/harness.md`](../architecture/harness.md)

---

## 1. Goal

Allow the durable engine (`:harness`) to browse directories, discover `AGENTS.md`, and run coding/ops harnesses against **remote VMs, cloud devboxes, or isolated containers** with the exact same `H.Tools.*`, crash safety, and Web/Mobile/TUI UX as `H.ExecutionEnv.Host`.

---

## 2. Scope

1. **Remote Execution Agent (`H.RemoteAgent`):**
   - Minimal standalone service deployed on a target VM exposing the 7 `H.ExecutionEnv` operations (`cwd`, `resolve_path`, `list_dir` with markers, `read_file_lines`, `read_file_bytes`, `write_file`, and streaming `exec`) over an authenticated transport (mTLS WebSocket/HTTPS or SSH subsystem).
2. **`H.ExecutionEnv.Remote` Adapter:**
   - Implements `@behaviour H.ExecutionEnv` and passes the entire **`H.ExecutionEnv.Conformance`** suite over a real loopback socket transport in `mix test --no-start`.
   - Keeps connection PIDs, sockets, and auth credentials strictly inside runtime `H.EnvRegistry` state; durable session records store only `%{"env_id" => id, "kind" => "remote", "cwd" => remote_cwd}`.
3. **Lease-Heartbeated Remote Process Groups & Partition Safety:**
   - Every remote `exec/3` runs in its own OS process group (`SID == PGID == os_pid`) tagged with `{session_id, incarnation, task_id, attempt_id}` and a heartbeat lease (e.g. 5s interval, 15s expiry).
   - Explicit `abort_ref` signals `-PGID` immediately; prolonged disconnect expires the lease and reaps `-PGID` on the remote VM automatically.
   - Ambiguous disconnects during `replay: :unsafe` tools (`write`, `edit`, `bash`) commit `diagnostic: "interrupted"` with partial streamed output—never blindly re-executing remote mutations.
4. **Multi-Environment Workspace Browser:**
   - Selecting `env_id: "vm-dev-1"` in `HWeb` or `h` browses the remote VM's directories via `GET /api/v1/fs?env_id=vm-dev-1&path=...`, overlays `H.Catalog` past sessions for `"vm-dev-1"`, and starts or resumes remote sessions seamlessly.
