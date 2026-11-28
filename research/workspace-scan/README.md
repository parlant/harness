# Workspace: progressive directory browsing spike

**Status: design and standalone probe, not implemented product behavior.** Nothing here is built by Mix or loaded by H. The branded launcher, installed bundles, and current browse API are unchanged.

## Why change the current path?

`HWeb.WorkspaceLive` waits synchronously for `Backend.browse_workspace/1`. `H.Daemon.Workspace.browse/3` binds the path and waits for `ExecutionEnv.list_dir/3` before returning any directories or sessions. On the host, `only_dirs` enumerates and sorts all names and inspects each candidate before slicing the page. In a bundle, `hi-exec fs ls` isolates enumeration but still sends the whole listing back; it does not isolate subsequent metadata lookups. `File.ls/1` uses OTP's shared file server; a Task around it does not change that. The local OTP primitive avoids that shared server but, like the public OTP listing APIs, returns an entire list rather than a directory iterator.

This separates two requirements: H's launcher can retain a stable native parent and signing identity, while Workspace takes responsibility for incremental scanning and partial results. Moving the actual protected operation into BEAM can change macOS prompt attribution. Naming, signing, app vs service ancestry, and permission continuity need their own signed-app verification; none follows from a filesystem benchmark.

## Proposed first production slice

1. **Local scanner.** Use a small native primitive only for `open`, bounded `next`, and `close`, using libc `opendir/readdir/closedir` on macOS and Linux. Use `d_type` where available; it is a hint, and `DT_UNKNOWN` and symlink handling need raw OTP metadata. Keep filtering, budgets, symlink behavior, markers, and catalog annotations in Elixir. Do not `stat` every ordinary file or open each child just to populate the parent. Verify the same behavior on both local install paths and provide a build/fallback strategy before wiring the NIF into releases. No new Hex dependency or port is required by this design.
2. **Bounded per-navigation work.** Put validation that touches disk (including cwd binding), enumeration and metadata outside the LiveView and daemon coordinators. Emit bounded batches in filesystem order and stop on backpressure, budget exhaustion, or when the client navigates away. Read session counts from the catalog independently of filesystem access, without rescanning the whole catalog for every row. Use directory paths as stable UI keys; merge/sort batches client-side without losing selection or moving keyboard focus. Report partial results as partial, not empty or complete. Directory mutation while scanning does not produce a consistent snapshot; refresh starts a fresh scan.
3. **Permission behavior.** A parent listing may show the name it learned from the parent; that is not a grant to enumerate that child's contents. Do not open children to discover grants. Keep the protected-home marker skip and avoid speculative probes that could raise prompts. On a stalled explicit open, keep the previous picker usable, show a neutral waiting state (not “permission required”: it could be a mount), and emit no rows for that open until it succeeds. A delayed metadata probe must not stall publication of otherwise known rows or sibling results. If the user grants access while the navigation is still current, continue that attempt; if they navigate away, ignore its result. A denial is distinct from not found and from a wait/deadline. After a terminal error, require an explicit retry instead of repeatedly opening the path.
4. **Admission and cleanup.** Dirty I/O NIFs do not block normal schedulers, but they use a finite pool also needed by unrelated filesystem work. Cap outstanding native calls and open handles globally, and pending work per view; leave dirty I/O headroom for ordinary filesystem calls and other scans. On exhaustion, return a recoverable busy state rather than queue indefinitely. Do not release a native-call slot on a UI timeout, or assume terminating its BEAM caller cancels the syscall. Detach the view and let the worker finish and close; if forced worker termination is supported, capacity accounting must still reflect actual native completion. Test cursor cleanup on owner exit, bounds on expired cursors, and the dirty scheduler configuration. Closing on a normal scheduler in a resource destructor is not a production cleanup strategy. A hard guarantee against arbitrary stuck kernel calls or native crashes is not possible in-process; reassess if the in-process limits cannot meet the availability target.
5. **Wire only Workspace first.** Render the shell, catalog data, and navigation without waiting for the filesystem. Give each navigation an ephemeral request identity; deliver batches and terminal status to that view, ignoring stale batches. In-VM can use messages. The HTTP backend needs an authenticated, request-scoped stream or batched protocol with disconnect cleanup; design that contract before changing the existing snapshot endpoint. Leave TUI, remote-agent transport, recursive `list_files`, tool execution and review browsing unchanged in the first slice. Retire or relocate the bundled launcher `fs ls` behavior only after its other callers are accounted for and permission attribution is checked separately.

Production `readdir` should emit byte strings with limits on visited entries and returned bytes. At the Elixir/wire boundary, handle non-UTF-8 names deliberately; do not change the bytes used to access a file. Reuse the existing finite error vocabulary where it applies. Native handles must stay ephemeral and never be serialized to clients.

## Run the probe

OTP 29, `erlc`, and the system C compiler are sufficient. No dependencies are fetched. The runner only creates a disposable build directory and workspace fixture.

```sh
sh research/workspace-scan/run.sh

# Optional Linux run with a locally available OTP 29 image and a C compiler:
docker run --rm --pull=never --network none \
  --mount "type=bind,source=$PWD/research/workspace-scan,target=/probe,readonly" \
  elixir:1.20.5-otp-29 sh /probe/run.sh
```

The test-only native gate uses `poll` on a pipe immediately before `opendir`. While it holds one of two dirty I/O schedulers, the probe asserts that no rows appear for that open, an unrelated OTP file-server read and sibling scan complete, and the open can resume after the test grants it. Separate assertions cover simulated denial and a real missing path. The fixture does not need a real protected directory, mount, privileges, or a macOS dialog. It models the wait at the syscall boundary, not TCC's attribution or a filesystem/kernel that is entirely unresponsive. The probe also checks complete incremental enumeration against OTP's listing, batch size, file types on the test filesystems, and explicit close. The fixture-only functions and gate do not belong in a production NIF.

### Observed results

One sample run on macOS 15.8.1 arm64 and Debian 13 arm64 in Docker, both OTP 29, with 20,000 entries (5,000 directories) on disposable local filesystem paths:

| Operation | macOS | Linux |
| --- | ---: | ---: |
| OTP whole-directory enumerate | 8.10 ms | 4.37 ms |
| Sort + raw directory-type check on all names (after enumeration) | 626.56 ms | 132.52 ms |
| Sort + raw type checks until 33 directory matches (after enumeration) | 8.83 ms | 6.21 ms |
| NIF open + first 126 names/type hints | 0.162 ms | 0.233 ms |
| NIF enumeration of remaining names/type hints | 8.19 ms | 4.20 ms |
| Unrelated file-server read, sibling scan and error checks during the gate | 0.186 ms | 0.102 ms |

The short-page OTP variant shows how much work we can save without a NIF if a full-list fallback is needed, but still waits for full enumeration and sorting. The NIF first batch measures names and type hints, not fully decorated Workspace rows; these are not UI benchmarks or cold filesystem tests. Both runs passed the blocked-open assertions; this is evidence that one wait did not block unrelated work with spare capacity, **not** evidence that the VM cannot be stalled under saturation.

## Next tests before shipping

- Exercise bounded admission with several concurrent gated paths, duplicate/retry attempts, client disconnect/navigation, and clean native completion after detaching. Add a gate for fallback metadata; inspect scheduler headroom and verify disposable H storage and unrelated API requests continue working. Assert the UI receives a first batch and handles navigation before the old scan finishes, in both backends.
- Benchmark time to initial Workspace render, first selectable row, and completion with a large directory, a sparse mix of directory candidates, symlinks, `DT_UNKNOWN`, and both cheap and slow metadata. Verify no incidental access to protected home children. Measure on macOS and Linux outside Docker as available, and track memory/FD limits as well as latency.
- Manually test actual macOS grant, denial, revocation, and an unanswered prompt with a Developer ID signed app installed in place, then compare an app-owned launch and a standalone LaunchAgent. Record the identity in prompts/settings; repeat after an in-place signed upgrade. Do not make real prompts a unit test or promise permission continuity before this passes.
