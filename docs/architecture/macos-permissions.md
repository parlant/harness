# macOS permission boundary

## Implemented

H.app owns a native entry point and helper, rather than asking users to approve a
changing release directory:

- Install and update in place at `/Applications/H.app`.
- `Contents/MacOS/HApp` is the menu-bar controller (bundle ID
  `co.parlant.harness`).
- `Contents/MacOS/hi-exec` is our Rust executable (signing identifier
  `co.parlant.harness.hi-exec`). It remains the parent of the embedded daemon,
  forwards termination signals to its own child, and preserves its exit status.
- The embedded standalone bundle's `bin/hi-exec` symlink points to that same
  executable. `H_FS_EXECUTABLE` selects it for host directory enumeration.
  Standalone bundles use their adjacent helper; source-checkout runs without
  that variable use local OTP primitives instead.
- OTP's `erlexec` and `beam.smp` remain real, separately signed runtime binaries.
  `hi-exec` does **not** reimplement or rename OTP, inject into it, or claim its
  privileges. Nested Mach-O signing identifiers are explicit and independent of
  release directory names. Production updates must retain the same Developer ID
  team and identifiers; ad-hoc signing cannot promise permission continuity.

A stable pathname is necessary for an understandable setup, not sufficient proof
of stable TCC authorization. macOS selects the responsible process using its
attribution/signing rules. It can still name H, hi-exec, erlexec, a runtime, or a
terminal depending on how work was launched. Files opened directly by BEAM or a
shell are not magically converted into native-helper access. The helper is not a
sandbox and grants are not agent tool approvals.

### Folder access and daemon responsiveness

A privacy prompt during `File.ls`, `File.stat`, `File.read_link`, or other
workspace operations previously could occupy OTP's shared `file_server_2`.
Unrelated store I/O and code loading then queued behind it. Moving the same call
to a BEAM Task would not isolate that shared server.

Host filesystem operations now avoid that server: metadata and file handles use
raw APIs; operations without a public raw variant use local `:prim_file`
primitives. This internal OTP dependency is deliberately confined to
`H.ExecutionEnv.Host.FileSystem` and covered by a no-file-server regression test.
Persistence is unchanged. No generic platform plugin framework is introduced.

Bundled directory enumeration runs in a separate `hi-exec fs` worker. Its native
parent enforces a two-second deadline and reaps its own worker; the BEAM port has
an additional three-second response deadline and an 8 MiB output cap. Errors
cross as a finite string vocabulary, never input-derived atoms or process
handles. Timeout is not reported as a missing directory or permission denial.
It may be a privacy prompt, unavailable mount, or other slow filesystem.

Automatic project-marker decoration skips macOS Desktop, Documents, Downloads,
and Library beneath the user's home. Browsing a parent folder must not open
these children merely to look for `.git` or `mix.exs`. Explicit access remains
allowed. This is a UX policy, not canonical-path confinement or comprehensive
TCC detection. Raw operations can still block their caller/dirty I/O thread; this
change does not give every filesystem syscall a hard deadline or protect against
unlimited concurrent blocked calls. File contents and mutations are not yet
native-helper capabilities. Interrupted unsafe tools retain existing persisted
intent and no-replay rules.

### User-managed setup

The menu's **Permissions & Setup…** guide explains installation paths, provides
Files & Folders / Full Disk Access settings links and a Finder reveal action,
and flags an external daemon. The app does not silently replace an installed
LaunchAgent or migrate an active store. Users first cooperatively drain and
uninstall the registered service (or stop a standalone daemon), then reopen H.
Permissions granted to the app need not apply to the old CLI service.

Prefer narrow folder decisions. Full Disk Access is optional and broad: it can
expose sensitive user data to the daemon and its tools. H never edits the TCC
database, calls `tccutil reset`, approves a system prompt, or treats a successful
`stat` as evidence of a privacy grant. Restart after changing permissions. Settings
URLs are best-effort; manual System Settings navigation remains supported.

## Planned: computer-control capabilities (not implemented)

The stable native executable is the intended OS-facing home for computer-control
operations, not permission logic in session coordinators. Before adding one:

1. Define its concrete operation and least privilege. Accessibility (assistive
   control), Screen Recording (capture), Apple Events Automation (target-app
   scripting), and filesystem access are **separate** capabilities. Neither
   Full Disk Access nor agent tool approval implies the others.
2. Put the actual protected OS API call in a signed native component. Validate
   attribution on supported macOS versions; a Rust wrapper alone proves nothing.
   If a capability needs a separately bundled helper/XPC service, give it a
   stable identifier and explicit ownership rather than multiplying identities
   accidentally.
3. Expose preflight states such as unknown/not-granted/granted only where public
   OS APIs support them. Request permission only following a clear user action;
   denial must return an actionable result without repeated prompt loops.
4. Use a narrow authenticated/local transport, validate every request, bound
   output/time, and keep process handles and OS objects ephemeral. Do not expose
   a generic arbitrary-native-call endpoint.
5. Keep permission UI/client navigation separate from durable session state.
   Persist tool intent and replay policy before effects. Clicks, keystrokes and
   other ambiguous interrupted effects must not replay on process restart.

The current guide links to Accessibility and Screen Recording for orientation
only and explicitly says they are not used/requested for coding. No computer
control, screen capture, capability grants, or automatic TCC migration ships in
this change.

## Release verification

Automated checks cover native worker success/errors/deadlines, child signal and
exit behavior, raw host filesystem semantics, marker policy, Swift compilation,
and app structure/signatures. Run the signed app packaging smoke check using a
disposable HOME/store; never probe real protected folders in unit tests.

Before claiming permission persistence, manually test a Developer ID signed
release installed at `/Applications/H.app` on each supported macOS version:

- Fresh folder grant, denial, revocation, and restart; note the actual process
  named by macOS and the item shown in System Settings.
- Browse home without incidental child-folder prompts; explicitly open a
  protected folder and leave its prompt unanswered while checking API/storage
  responsiveness.
- Upgrade in place with the same signing identity, then repeat access. Separately
  test relocation, ad-hoc builds, and signing changes; do not promise continuity.
- Compare app-owned and CLI/LaunchAgent launches and exercise the migration guide.
- When computer control exists, test each permission independently; folder-access
  results are not evidence for Accessibility or Screen Recording.
