# Slice 6: Phoenix Web & Mobile Client (`clients/web/` — `HWeb.*`)

**Prerequisite:** Slice 5 (`H.ExecutionEnv.Host` workspace browser, `{env_id, cwd}` `H.Catalog` annotations, and `H.Harness` seam).
**Architecture:** [`docs/architecture/client-web.md`](../architecture/client-web.md)

---

## 1. Goal

Build a first-party, responsive Desktop + Mobile Phoenix LiveView application in `clients/web/` (`app: :harness_web`, namespace `HWeb.*`) while keeping root `:harness` (`H.*`) completely free of Phoenix and frontend asset dependencies:
- Compiling at `/` builds **only** the headless `:harness` daemon.
- Compiling at `clients/web/` (`{:harness, path: "../.."}`) builds a **single-BEAM monolith** running `:harness` and `:harness_web` together with in-memory `H.Daemon` + `H.PubSub` calls.

---

## 2. Scope

1. **Standalone Mix Project (`clients/web/mix.exs`):**
   - `app: :harness_web`, namespace `HWeb.*`, depending on `{:harness, path: "../.."}`, `phoenix`, and `phoenix_live_view`.
   - `HWeb.Backend` behaviour with `HWeb.Backend.InVM` (direct `H.Daemon` + `H.PubSub`) and `HWeb.Backend.HTTP` (`/api/v1/*` fallback).
2. **Bounded-Memory LiveView Projection (`HWeb.SessionLive` + `H.Transcript`):**
   - `Phoenix.LiveView.stream/4` (`@streams.entries`) for committed entries + cursor-paged upward history (`at: 0`).
   - Isolated `<.live_region>` patching `ephemeral_live` on 50 ms deltas (`base_seq == cursor_seq`) without re-diffing committed transcript cards.
3. **Desktop & Mobile Responsive UX:**
   - Environment & directory browser drawer (`H.Daemon.browse_workspace/2`) with project markers, active indicators, and per-folder past session lists (**Resume** or **Start New Session Here**).
   - Conversation fork ancestry tree, inline `Fork here` / `Fork & submit`, model/thinking controls, collapsible thinking traces, unified diffs for `edit`/`write`, formatted `bash` output cards, and mobile touch controls (`Send`, `Steer`, `Stop`, `Continue`, `localStorage` draft hook).
4. **Security & Verification:**
   - Owner-token login -> `HttpOnly` Phoenix session verified on LiveView `on_mount` (HTTP + WebSocket).
   - `Phoenix.LiveViewTest` suite against `H.Provider.Fake` + disposable workspaces (`--no-start` / supervised isolation, zero paid model calls).
