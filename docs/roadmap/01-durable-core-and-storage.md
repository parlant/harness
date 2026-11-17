# Slice 1: Pluggable Storage (`Memory` + `File`), Catalog, and Session Coordinator

**Goal:** Turn the pure `H.Session` history model into a crash-recoverable, multi-session OTP runtime with zero external Hex or NIF dependencies (`deps: []`).

---

## 1. Module Layout

```text
lib/h/
  application.ex          # :rest_for_one root supervisor (started only when daemon runs; tests use --no-start)
  schema.ex               # Boundary input validator (zero String.to_atom/1)
  store_lock.ex           # Single-daemon OS store lock (.claim + Unix domain socket)
  catalog.ex              # Server-owned session metadata index + ETS read table
  document.ex             # Versioned document definitions, pure delta ops, as_of / initial fork rules
  submission.ex           # Idempotent request_id receipt & payload fingerprint struct
  task.ex                 # Versioned durable task struct & status transitions
  storage.ex              # H.Storage behaviour
  storage/
    memory.ex             # In-memory reference backend
    file.ex               # :raw CRC32-framed WAL + atomic snapshot backend
  session/
    supervisor.ex         # Per-session :one_for_all supervisor (restart: :temporary under DynamicSupervisor)
    server.ex             # Serialized session coordinator, drain-batch commits, fenced effect dispatch
test/
  support/
    storage_conformance.ex # Shared H.Storage conformance test macro
  h/
    storage_memory_test.exs
    storage_file_test.exs
    store_lock_test.exs
    catalog_test.exs
    session_server_test.exs
    vm_restart_test.exs   # Spawns real child `elixir` OS process, kills -9 mid-effect, verifies recovery
```

---

## 2. Single-Daemon Store Lock (`H.StoreLock`)

Two BEAM OS processes must never write to the same `data_dir`:
1. Ensure `<data_dir>` exists (`0700`). Compute a short lock socket path (`sun_path <= 104` bytes on macOS): `/tmp/h-#{uid}-#{sha256_hex_16(Path.expand(data_dir))}.lock.sock`, recording the path in `<data_dir>/lock.info`.
2. Acquire short-lived atomic spin directory `File.mkdir("<data_dir>/.claim")`.
3. Probe `:gen_tcp.connect({:local, sock_path}, 0, [:binary, active: false], 100)`:
   - `{:ok, sock}` -> close `sock`, `File.rmdir(".claim")`, return `{:error, :store_locked}`.
   - `{:error, :enoent | :econnrefused}` -> previous owner is absent or dead (even after `SIGKILL`); `File.rm(sock_path)`, bind `:gen_tcp.listen(0, [:binary, {:ip, {:local, sock_path}}, active: false])`, keep the listening socket alive inside `H.StoreLock` `GenServer`, `File.rmdir(".claim")`.

---

## 3. `H.Storage` Behaviour and `H.Storage.File` Layout

### Behaviour Contract (`H.Storage`)

```elixir
@type seq :: non_neg_integer()
@type id :: pos_integer()
@type write ::
        {:put_session_meta, map()}
        | {:put_conversation, map()}
        | {:append_entry, map()}
        | {:put_submission, map()}
        | {:put_task, map()}
        | {:put_doc, doc_address :: tuple(), doc_revision :: map()}
        | {:retire_doc, doc_address :: tuple()}

@callback open(keyword()) :: {:ok, state :: term()} | {:error, term()}
@callback close(state :: term()) :: :ok
@callback mint_id(state :: term()) :: {:ok, id(), state :: term()} | {:error, term()}
@callback commit(state :: term(), batches :: [[write()]]) ::
            {:ok, %{stored: non_neg_integer(), seqs: [seq()], refused: nil | {non_neg_integer(), term()}},
             state :: term()}
            | {:error, term()}
@callback read_bootstrap(state :: term()) :: {:ok, map(), state :: term()} | {:error, term()}
@callback get_submission(state :: term(), request_id :: String.t()) ::
            {:ok, nil | map(), state :: term()} | {:error, term()}
@callback scan_entries(state :: term(), query :: map()) ::
            {:ok, %{items: [map()], next_cursor: nil | id()}, state :: term()} | {:error, term()}
```

### `H.Storage.File` Binary Frame Format

Each session lives in `<data_dir>/sessions/<session_id>/`:
- `commit.log`: opened with `:file.open(path, [:raw, :binary, :read, :append])` exclusively by `H.Session.Server`.
- Frame binary layout:
  ```elixir
  # magic = "HLOG" (0x484C4F47), version = 1
  <<0x484C4F47::32, 1::8, len::unsigned-big-32, crc32::unsigned-big-32, payload::binary-size(len)>>
  ```
  where `payload` is `IO.iodata_to_binary(JSON.encode_to_iodata!(frame_map))` containing all accepted batches of one `commit/2` call (`%{seqs: [...], next_id: n, batches: [...]}`), and `crc32 = :erlang.crc32(payload)`.
- Flush via `:file.datasync(fd)` (configurable `:datasync | :sync | :none` for test speed vs power-loss contract).
- **Recovery (`open/1`):** Load latest valid `snapshot.<seq>.json` if present, then scan `commit.log` frames past `<seq>`. If the final frame has truncated bytes or a CRC mismatch (torn write on power loss / `SIGKILL`), `:file.position(fd, valid_offset)` + `:file.truncate(fd)` cleanly discards the torn tail and recovers the exact committed prefix.
- **Compaction / Snapshot rotation:** Every `K` commits or `M` MiB of `commit.log`, write `snapshot.<seq>.tmp`, `:file.sync/1`, `File.rename!("snapshot.<seq>.tmp", "snapshot.<seq>.json")`, truncate/rotate `commit.log`, and unlink older snapshots.

---

## 4. `H.Catalog` (Server-Owned Metadata)

- Owns `<data_dir>/catalog/` (atomic snapshot + append log) and an ETS table `:h_catalog` (`[:named_table, :set, :protected, read_concurrency: true]`).
- Stores per session: `session_id`, `title`, `cwd`, `root_conversation_id`, `created_at`, `updated_at`, `active`, `next_wake_at`, `status` (`:ok | :quarantined`), and `pending_edits`.
- HTTP/CLI catalog reads hit `:ets.tab2list(:h_catalog)` / `:ets.lookup/2` directly—never waking unloaded sessions or opening `<data_dir>/sessions/<id>/`.

---

## 5. `H.Session.Supervisor` and `H.Session.Server`

### Supervision Blast-Radius Isolation

- `H.Session.RuntimeSupervisor` is a `DynamicSupervisor`.
- `H.Session.Supervisor` starts with `restart: :temporary` under `DynamicSupervisor`, and internally supervises (`strategy: :one_for_all, max_restarts: 2, max_seconds: 5`):
  1. `Task.Supervisor` (temporary effect workers)
  2. `H.Session.Server` (registered in `H.Registry` under `{:session, session_id}`)
- If `H.Session.Server` exceeds 2 crashes in 5 seconds (or hits unrecoverable storage failure), `H.Session.Supervisor` notifies `H.Catalog.quarantine(session_id, reason)` and exits without affecting other sessions.

### Coordinator State Machine (`H.Session.Server`)

1. **Open & Claim Incarnation:** Open `H.Storage`, increment persisted `incarnation` (`incarnation + 1`), reconcile unfinished tasks:
   - Was last stop clean (`clean_close: true`)? Reset `running` tasks to `pending` **without** incrementing `restarts`.
   - Was last stop unclean (`clean_close: false`)? Increment `task.restarts` on `running` tasks:
     - If `restarts > restart_limit` (default 5): transition task to `terminal` (`:restart_limit`) and settle any active run with `run_failure: %{reason: "restart_limit"}`.
     - Otherwise reconcile according to task kind/phase (Slice 1 controllable fake task: safe vs unsafe replay).
2. **Drain-Batch Group Commit:** When processing mutating calls/worker messages, drain up to 32 ready messages from the mailbox, stage pure transitions sequentially (`[batch_1, batch_2, ...]`), call `H.Storage.commit(store, batches)` once, reply receipts to callers in order, and broadcast per-conversation commit deltas via `H.PubSub`.
3. **Fenced Workers:** Every worker message carries `{incarnation, task_id, attempt_id, msg}`; stale messages are ignored.
4. **Idle Cache Eviction & Shutdown:** When `wake().active == false`, clear rebuildable caches before `:hibernate`; on `terminate(:shutdown, state)`, terminate `Task.Supervisor` children and persist `clean_close: true` + `pending` task reset.

---

## 6. Verification Checklist (Slice 1 Done)

- `H.Storage.MemoryTest` and `H.Storage.FileTest` pass shared `H.Storage.Conformance` (multi-batch prefix refusal, `mint_id` monotonicity across reopen, `asc`/`desc` cursor scans, torn-tail byte truncation at every byte offset of the last frame).
- `H.StoreLockTest` verifies a second contender gets `{:error, :store_locked}` while live, and succeeds immediately after `kill -9` of an external child BEAM process.
- `H.SessionServerTest` verifies idempotent `request_id` deduplication vs `409` payload mismatch, drain-batch group commit, fenced stale worker rejection, clean `close` vs unclean `restart_limit` termination, and session isolation when one session's storage faults.
- `H.VmRestartTest` spawns a separate `elixir` OS process writing to a temp `data_dir`, kills it (`SIGKILL`) mid-task, starts a fresh supervisor tree on `data_dir`, and verifies automatic recovery without client reconnect.
