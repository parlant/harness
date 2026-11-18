# Slice 6: Separate Client Applications (`HWeb.*` Phoenix Desktop/Mobile & `HTUI.*`)

**Prerequisite:** Slice 5 (`H.ExecutionEnv.Host` workspace browser, `H.Catalog` `{env_id, cwd}` index, and `H.Harness` seam).

---

## 1. Goal: Clean Namespace & Build Separation

Evolve the repository layout so the durable daemon (`:harness`, `H.*`) and rich interactive clients (`:harness_web` under `HWeb.*` and `:harness_tui` under `HTUI.*`) live in cleanly separated Mix OTP applications:

```text
apps/
  harness/       # OTP app :harness     (H.*)    — zero Phoenix, LiveView, or TUI deps
  harness_web/   # OTP app :harness_web (HWeb.*) — Phoenix + LiveView Desktop & Mobile app
  harness_tui/   # OTP app :harness_tui (HTUI.*) — Pi-ergonomic terminal client (`h`)
```

### Supported Build Targets

1. **Daemon-only (`apps/harness` / `:harness` release):** Compiles only `H.*` (`bandit`, `plug`, `req`, `req_llm`). Serves `/api/v1/*` JSON + SSE for `HTUI` or custom external clients.
2. **Monolithic Web + Daemon (`:harness` + `:harness_web` release in one BEAM VM):** Runs `H.Supervisor` and `HWeb.Endpoint` in the same BEAM node. `HWeb` LiveViews call `H.Daemon` and subscribe to `H.PubSub` directly in-memory while `:harness` simultaneously exposes loopback `/api/v1/*` for `HTUI` sessions in `tmux`.
3. **Standalone TUI (`:harness_tui` escript / release `h`):** Fast-starting terminal binary invoked from any `pwd` inside `tmux`.

---

## 2. `HWeb.*` (`:harness_web`) — Phoenix LiveView Desktop & Mobile Client

1. **`HWeb.Backend` Behaviour:** Thin adapter with `HWeb.Backend.Local` (direct `H.Daemon` + `H.PubSub` in-VM calls) and optional `HWeb.Backend.HTTP` (remote `/api/v1/*` client).
2. **`H.Transcript` Elixir Reducer:** Pure Elixir counterpart to `ConversationTranscript` folding `snapshot`, `commit`, and `ephemeral` events into LiveView `stream(:entries, ...)` and document assigns so long transcripts render in `O(delta)` DOM patches on mobile and desktop.
3. **Responsive Mobile + Desktop Workspace UX:**
   - Directory browser drawer with environment switcher (`host`, remote VMs), project markers, and per-folder session history.
   - Branch ancestry navigator & inline `Fork here` / `Fork & submit`.
   - Collapsible thinking traces, structured file-edit diffs (`edit`/`write`), streaming `bash` terminal cards, sticky `run_failure` `Continue` bar, and mobile-friendly `Steer` / `Stop` controls.

---

## 3. `HTUI.*` (`:harness_tui`) — `Pi`-Class Terminal Client

1. **Instant `pwd` startup (`h`, `h -c`, `h -r`):**
   - Auto-ensures local `:harness` daemon is running via `H.StoreLock` / loopback health check.
   - Queries `/api/v1/sessions?env_id=host&cwd=<pwd>` to resume or create a folder-bound session.
2. **Full keyboard-driven coding workflow:**
   - Multi-line editor, slash commands (`/model`, `/thinking`, `/fork`, `/tree`, `/resume`, `/new`), `Esc` to abort, `Enter` while busy to queue/steer, and collapsible tool output—synchronized live with `HWeb` whenever both are open on the same session.
