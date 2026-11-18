# `hi` Release Trial, Compatibility & Cutover Log

Status: **Pre-cutover trial (H5 gate OPEN — not approved as `pi` default yet).**

This document records isolated install/smoke verification, measured differences against pinned `pi` (`~/Projects/JavaScript/pi` at `d15b2cf43`), a metadata-only inventory of local skills/templates/scripts, exact run/rollback commands, the workweek fallback log, and remaining cutover blockers.

All automated checks in this trial used disposable `H_DATA_DIR` / `HOME` sandboxes under `/tmp`, fake providers (`FakeDaemon` and `H.Provider.Fake`), and disposable working directories. Real `~/.pi` stores, real user projects, and paid LLM endpoints were never touched.

---

## 1. Test Matrix & Measured Verification Results

Verified at branch `hi-trial/migration` (base `e9da729`) against read-only `pi` pin `d15b2cf43367f757832e8257ee5ebac76fce5d69` (`@earendil-works/pi-coding-agent` `1.3.0`, Node `v26.13.1`, Rust `1.100.0`, Elixir `1.20.5` / OTP `29`).

| Check | Exact Command | Outcome & Measured Metrics |
|---|---|---|
| Rust unit suite | `CARGO_TARGET_DIR=/tmp/h-cargo cargo test --locked` (in `clients/tui`) | **127 passed**, 0 failed (`1.09s`) |
| Root Elixir engine suite | `MIX_BUILD_PATH=/private/tmp/h-mix MIX_DEPS_PATH=/tmp/h-deps mix test` | **301 passed, 1 excluded** (`:live_llm`, `4.5s`) |
| Phoenix ↔ native sync (`regular` mode) | `MIX_BUILD_PATH=/private/tmp/h-web-mix MIX_DEPS_PATH=/tmp/h-web-deps H_NATIVE_TEST_BIN="$INST/bin/h" H_INTERACTIVE_TEST_BIN="$INST/bin/hi" HI_TEST_MODE=regular mix test --include native_client` (in `clients/web`) | **12 passed** (`0.8s`), including `MultiSurfaceSyncTest` |
| Existing Unix PTY acceptance suite | `HI_PTY_REQUIRE_BIN=1 HI_BIN="$INST/bin/hi" H_BIN="$INST/bin/h" python3 -m unittest discover -s clients/tui/tests -p 'test_*.py' -v` | **16 passed** (`7.261s`): raw/cooked restore, mid-stream editing, Enter `steer`, Alt-Enter `follow_up`, non-aborting `/quit`/`Ctrl-D`/hangup detach, `SIGWINCH` resize, TCP loopback |
| Release smoke (cold target) | `PI_CLI_JS=~/Projects/JavaScript/pi/packages/coding-agent/dist/bundle/cli.js python3 scripts/hi-release-smoke.py --fresh-target` | **Passed**: cold `cargo install --locked` `10.217s`; `h` `2,655,904` B, `hi` `2,655,904` B; `pi_store_unmodified: true` |
| Release smoke (warm + real Elixir `H.serve`) | `MIX_BUILD_PATH=/private/tmp/h-mix MIX_DEPS_PATH=/tmp/h-deps CARGO_TARGET_DIR=/tmp/h-cargo PI_CLI_JS=~/Projects/JavaScript/pi/packages/coding-agent/dist/bundle/cli.js python3 scripts/hi-release-smoke.py --with-elixir` | **Passed**: warm install `1.297s`; real `H.serve` + `H.Provider.Fake` + `H.Storage.File` persisted `2` sessions via `api.sock`; sentinel `.pi` SHA-256 tree identical (`pi_store_unmodified: true`) |

---

## 2. Measured Differences: `pi` (`d15b2cf43`) vs `h` / `hi`

### Packaging, Footprint & Startup

| Aspect | `pi` (`d15b2cf43`) | `h` / `hi` (`e9da729`) |
|---|---|---|
| Distribution artifact | JS bundle (`dist/bundle/`: **9.1 MiB**, 79 chunk files) + Node.js (`v26.13.1`) + workspace `node_modules` | Two native binaries: `h` (**2,655,904 B**) + `hi` (**2,655,904 B**), **5,311,808 B** total (`5.07 MiB`), zero runtime Node dependency |
| `--version` latency | `0.20s–0.27s` (`PI_OFFLINE=1 node .../cli.js --version`) | `~0.14s` on first post-install exec (OS code-sign verification); `<0.01s` (`real 0.00s`) warm cached |
| Process / durability model | Single Node process owns TUI, agent loop, tools, credentials, and JSONL logs | Client attaches to external Elixir/OTP daemon (`<data_dir>/api.sock` or loopback HTTP); **no daemon auto-start**; disconnecting client never aborts an active run |

### CLI & Print Compatibility

| Behavior | `pi` (`d15b2cf43`) | `h` | `hi` |
|---|---|---|---|
| Version short flag | `-v, --version` | `-V, --version` (`-v` fails) | `-V, --version` (`-v` fails) |
| `-p` / `--print` signature | Boolean flag; supports `pi -p "msg"` and piped `echo msg \| pi -p` | `-p, --print <PROMPT>` (requires `<PROMPT>` arg; ignores piped stdin) | `-p, --print <PROMPT>` (requires `<PROMPT>` arg; ignores piped stdin) |
| Positional prompt on TTY | Opens TUI and submits initial prompt | Runs headless print mode and exits | Opens TUI and submits initial prompt (**doc bug**: `hi --help` says `[PROMPT]...` runs headless print mode and exits) |
| Positional prompt piped / `TERM=dumb` | Runs headless print mode and exits | Runs headless print mode and exits | Runs headless print mode and exits (no alt screen / raw mode) |
| `--tui-mode <fullscreen\|regular>` | Supported (`fullscreen` default, `regular` terminal scrollback) | Accepted in `--help` but unused | Supported (`fullscreen` default, `regular` skips alt-screen `\x1b[?1049h` and mouse capture) |
| Target selection flags | `--session`, `--session-id`, `-c`, `-r`, `--fork`, `--session-dir`, `--no-session`, `-n/--name` | `--data-dir`, `--daemon-url`, `--env`, `-s`, `-c`, `-r` | `--data-dir`, `--daemon-url`, `--env`, `-s`, `-c`, `-r` |
| Model/tool/resource/automation CLI | `--model`, `--provider`, `--api-key`, `--thinking`, `--models`, `--list-models`, `-t`/`-xt`/`-nt`/`-nbt`, `-e`/`-ne`/`--no-mcp`, `--skill`, `--prompt-template`, `--theme`, `--use-theme`, `-nc`, `--mode json\|rpc`, `--export`, `--offline`, `-a`/`-na`, `install`/`remove`/`update`/`list`/`config`/`auth`/`mcp` | Not present (configured via daemon or interactive slash commands/pickers) | Not present (configured via daemon or interactive slash commands/pickers) |

### Interactive Surface, Tools & Persistence

| Area | `pi` (`d15b2cf43`) | `hi` (`e9da729`) |
|---|---|---|
| Built-in slash commands | **20** built-ins (`/settings`, `/model`, `/thinking`, `/scoped-models`, `/login`, `/logout`, `/llama`, `/new`, `/resume`, `/name`, `/session`, `/tree`, `/fork`, `/clone`, `/compact`, `/import`, `/copy`, `/export`, `/share`, `/bug`, `/trust`, `/reload`, `/hotkeys`, `/changelog`, `/quit`) + dynamic `/skill:name`, template, and extension commands | **25** built-in palette items (`/resume`, `/new`, `/tree`, `/fork`, `/earlier`, `/latest`, `/model`, `/thinking`, `/attach`, `/steer`, `/follow-up`, `/dequeue`, `/abort`, `/continue`, `/tools`, `/thoughts`, `/edit`, `/envs`, `/search`, `/status`, `/hotkeys`, `/reload`, `/copy`, `/export`, `/quit`) plus `/conv`, `/retry`, `/discard-retry` |
| Keybindings config | `keybindings.json` (`APP_KEYBINDINGS` + TUI editor actions, `shift+tab` cycle thinking, `ctrl+p`/`shift+ctrl+p` cycle model, `ctrl+v` clipboard/image paste, `ctrl+s` save thinking, `ctrl+n` named session filter) | `<data_dir>/hi-keybindings.json` (`14` `ACTION_SPECS`: `escape`, `ctrl+c`, `ctrl+d`, `ctrl+g`, `ctrl+l`, `ctrl+o`, `ctrl+t`, `ctrl+x`, `alt+enter`, `alt+up`, `enter`, `/`, `ctrl+shift+f`, `ctrl+z`) |
| Default coding tools | `read`, `bash`, `edit`, `write` (optional `grep`, `find`, `ls`, `codemode`, `tool_search`, MCP) | `H.Harness.Coding`: `read`, `write`, `edit`, `bash`, `search_history` with workspace leases (`{env_id, cwd}`) and safe (`read`, `search_history`) vs unsafe (`write`, `edit`, `bash`) crash replay policy |
| File attachment (`@` / `Tab`) | Workspace `@` fuzzy search + `Tab` path completion + inline image paste | Client-local bounded `@` / `/attach` picker (`3.8 MiB` attachment budget inside `4 MB` daemon JSON cap); no env-wide daemon `@file` search yet |
| Session tree & fork | JSONL tree with entry-editor/labels/clone/import/compaction | Conversation branches (`/tree` switches conversation, `/fork` branches at a visible entry); no `/name`, `/clone`, `/compact`, or `pi` JSONL `/import` yet |
| Session store isolation | `~/.pi/agent/sessions/` JSONL | `<data_dir>/sessions/` CRC32-framed log + snapshots + `catalog/` (`H.StoreLock`); strictly disjoint from `~/.pi` |

---

## 3. Metadata-Only Inventory of Available Skills, Templates, Extensions & Scripts

**Important:** This inventory was collected read-only at metadata level (names, paths, frontmatter descriptions, and supporting script filenames only; no credentials, `auth.json`, or private session transcripts were read). **Presence in user directories does not imply every item is required for `hi` cutover**; H0/H4 sign-off must classify each item as *required*, *different/port*, or *optional/deferred*.

### Prompt Templates (`~/.pi/agent/prompts/`, `~/.agents/prompts/`)

- **0 templates found** (neither directory exists on this machine).

### User Skills (`~/.pi/agent/skills/` — 13 discovered)

| Skill Name | Supporting Files / Scripts (filenames only) | Porting / Cutover Note |
|---|---|---|
| `cavemen` | `SKILL.md` only | Style instruction; portable as `AGENTS.md` / session instructions |
| `elixir` | `SKILL.md` only | Language/test workflow instructions |
| `gitlab-follow-builds` | `SKILL.md` only | CLI/workflow instructions |
| `gitlab-implement-issue` | `SKILL.md` only | Issue workflow instructions |
| `gitlab-refine-issue` | `SKILL.md` only | Issue workflow instructions |
| `jira-implement-issue` | `SKILL.md` only | Ticket workflow instructions |
| `mix-gettext-extract-translate` | `SKILL.md` only | Localization workflow instructions |
| `playwright-e2e` | `scripts/install.sh`, `scripts/pi_playwright_e2e.py` | Bundled Python/shell E2E helper; callable via `bash` if skill discovery/path is provided |
| `software-tour-video` | `scripts/package_tour.py` | Video packaging helper |
| `terraform` | `scripts/tf-plan-summary`, `scripts/tf-pane-summary` | Bundled plan/pane summary scripts |
| `transcribe` | `SKILL.md` only | Local ASR (`sayneat`) workflow instructions |
| `video-edit-prep` | `scripts/video_prep.py`, `scripts/face_landmarks.swift`, `scripts/still_faces.swift`, `tests/test_video_prep.py`, `references/{WORKFLOW,PLAN}.md` | Multi-script media prep skill |
| `wrapup` | `SKILL.md` only | Diff-review / check wrapup instructions |

### Shared Agent Skills (`~/.agents/skills/` — 12 discovered)

| Skill Name | Supporting Script / Template Footprint | Note |
|---|---|---|
| `general-video` | `scripts/frame-packets.mjs`, `frame-packets.test.mjs`, `scripts/lib/*`, `sub-agents/frame-worker.md` | Media composition skill |
| `hyperframes` | `scripts/{locate,plugin-cli,bake-basemap}.mjs`, `scripts/lib/*`, `references/*` | HyperFrames video creation skill |
| `hyperframes-animation` | `scripts/{animation-map,animation-map-sampling,package-loader}.mjs`, `blueprints/*`, `rules/*`, `transitions/*`, `examples/*` | Animation rules/adapters |
| `hyperframes-audio` | `scripts/carve.mjs`, `scripts/lib/*`, `references/*` | Audio mixing skill |
| `hyperframes-cli` | `references/*` | CLI reference skill |
| `hyperframes-core` | `references/*` | Composition contract skill |
| `hyperframes-creative` | `scripts/{package-loader,contrast-report}.mjs`, `extract-audio-data.py`, `templates/design-picker.html`, `frame-presets/*`, `palettes/*` | Design spec & presets |
| `hyperframes-keyframes` | `references/keyframe-patterns.md`, `agents/openai.yaml` | Keyframe patterns |
| `hyperframes-registry` | `references/*`, `examples/*` | Registry lookup skill |
| `hyperframes-studio` | `SKILL.md` only | Studio workflow skill |
| `media-use` | `scripts/*` (`audio-duck.mjs`, `dither.mjs`, `eval.mjs`, `prefs.mjs`, `recipe.mjs`, `resolve.mjs`, `transcribe.mjs`, `transcript-cut.mjs`, `lib/*`), `audio/scripts/*`, `luts/*` | Media/audio pipeline scripts |
| `talking-head-recut` | `media-contract.test.mjs`, `references/*`, `assets/*` | Overlay packaging skill |

### User Extensions (`~/.pi/agent/extensions/` — 10 discovered)

- `auto-profile.ts`, `empty-response-guard.ts`, `google-token-exchange.ts`, `multicodex.ts`, `notify.ts`, `openai-coding-agent.ts`, `pi-meta.ts`, `retry.ts`, `tmux-session.ts`, `touch-grass.ts`.
- `hi` intentionally does **not** load TypeScript `pi` extensions (`docs/hi.md` parity category C). Any required behaviors (e.g., retry/guard, token exchange, model/profile routing, notifications) must live in H's daemon (`H.Credentials`, `H.Harness`, `H.Session.Server`) or be explicitly classified optional/deferred.

### Scripts in Repo & Pinned Checkout

- **H repository (`scripts/`, `clients/tui/tests/`)**:
  - `scripts/hi-release-smoke.py` — isolated release install, print/start/resume/detach/rollback, and zero-`pi`-store-mutation smoke test.
  - `clients/tui/tests/{fake_daemon,pty_harness,live_session,test_fake_daemon_and_pty,test_hi_pty}.py` — PTY acceptance suite and Phoenix sync driver.
- **Pinned `pi` checkout (`~/Projects/JavaScript/pi`)**:
  - `packages/coding-agent/scripts/{generate-schemas.ts,migrate-sessions.sh}` and `60+` repo build/release/check scripts under `scripts/` (packaging/CI tooling for `pi` itself, not end-user `hi` workflows).

---

## 4. Exact Commands: Install, Start, Resume, Detach, Print, Smoke & Rollback

### Clean Isolated Install (`h` and `hi`)

```sh
SMOKE_ROOT="$(mktemp -d /tmp/hi-install.XXXXXX)"
CARGO_TARGET_DIR=/tmp/hi-cargo cargo install --locked --path clients/tui --root "$SMOKE_ROOT"
export PATH="$SMOKE_ROOT/bin:$PATH"
h --version && hi --version
```

### Start a Disposable Daemon (Fake Provider, Isolated Store)

Keep `H_DATA_DIR` short on macOS so `<H_DATA_DIR>/api.sock` stays within the 104-byte Unix `sun_path` limit, and use `MIX_BUILD_PATH=/private/tmp/<unique>` per `AGENTS.md`:

```sh
export H_DATA_DIR="$(mktemp -d /tmp/hdata.XXXXXX)"
WORKDIR="$(mktemp -d /tmp/hwork.XXXXXX)"
MIX_BUILD_PATH=/private/tmp/h-smoke-mix mix run --no-halt -e '
  {:ok, _} = Application.ensure_all_started(:harness)
  {:ok, fake} = H.Provider.Fake.start_link(script: [
    {:reply, [%{type: :text_delta, text: "Hello from H.Provider.Fake", metadata: %{}}],
      %{content: [%{type: "text", text: "Hello from H.Provider.Fake"}], finish_reason: "stop"}}
  ])
  {:ok, _} = H.serve(data_dir: System.fetch_env!("H_DATA_DIR"), port: 0,
    provider: H.Provider.Fake, provider_config: %{server: fake})
  Process.sleep(:infinity)
'
```

### Print, Start, Resume, Regular Mode & Detach

```sh
# Print compatibility (does not enter raw mode, exits after final reply)
(cd "$WORKDIR" && H_DATA_DIR="$H_DATA_DIR" h -p "Check print mode")
(cd "$WORKDIR" && H_DATA_DIR="$H_DATA_DIR" hi -p "Check hi print mode")

# Interactive start (auto-creates workspace session in $WORKDIR)
(cd "$WORKDIR" && H_DATA_DIR="$H_DATA_DIR" hi)

# Interactive regular scrollback mode (no alt-screen)
(cd "$WORKDIR" && H_DATA_DIR="$H_DATA_DIR" hi --tui-mode regular)

# Resume latest session (-c) or workspace session picker (-r) or by ID (-s)
(cd "$WORKDIR" && H_DATA_DIR="$H_DATA_DIR" hi -c)
(cd "$WORKDIR" && H_DATA_DIR="$H_DATA_DIR" hi -r)
(cd "$WORKDIR" && H_DATA_DIR="$H_DATA_DIR" hi -s <SESSION_ID>)

# Detach without aborting active work:
#   /quit | Ctrl-D (empty buffer) | double Ctrl-C (within 2s) | PTY close
# Explicit interrupt only: Esc (when no overlay/search is open) or /abort
```

### Run the Automated Release Smoke Script

```sh
# Standalone (cargo install + FakeDaemon PTY lifecycle + sentinel ~/.pi integrity check)
python3 scripts/hi-release-smoke.py --fresh-target

# Also exercise real Elixir H.serve + H.Provider.Fake + H.Storage.File
MIX_BUILD_PATH=/private/tmp/h-smoke-mix \
PI_CLI_JS=~/Projects/JavaScript/pi/packages/coding-agent/dist/bundle/cli.js \
python3 scripts/hi-release-smoke.py --with-elixir
```

### Rollback Procedure

H session history lives in `H_DATA_DIR` (default `~/.local/share/h`), not in pi's session store. To roll back from `hi`:

1. Detach from `hi` (`/quit` or `Ctrl-D`) and stop any running `H.serve` / Phoenix process if no longer needed.
2. Remove the installed `hi`/`h` binary directory or leave it off `PATH` (do **not** alias `pi` to `hi` during the trial).
3. Launch `pi` directly as before against its untouched `~/.pi/agent` store. **Never** pass `H_DATA_DIR` to `pi` or point `hi` at `~/.pi/agent`.

---

## 5. Workweek Fallback Log (H5 Cutover Gate)

Per `docs/roadmap.md` (H5), `hi` cannot be recommended as the default until required H0 journeys run on the user's actual terminal for a full working week without falling back to `pi`.

**Current Gate Progress:** `0 / 5` live workweek days completed (isolated pre-cutover smoke verified; live workweek trial pending).

| Date / Day | Surface / Session | H0 Journey / Ledger Row | Fallback Trigger | Fell Back to `pi`? | Exact Command / Workaround | Disposition / Tracking |
|---|---|---|---|---|---|---|
| Day 0 (pre-cutover smoke) | Disposable `FakeDaemon` + `H.serve` (`H.Provider.Fake`), `/tmp` sandboxes | Clean install, `-p`, start, `-c`/`-r`, `--tui-mode regular`, non-aborting `/quit` detach, rollback isolation | N/A (automated smoke) | No | `python3 scripts/hi-release-smoke.py --with-elixir` | Passed; sentinel `.pi` store unchanged |
| Day 1 | _pending_ | | | | | |
| Day 2 | _pending_ | | | | | |
| Day 3 | _pending_ | | | | | |
| Day 4 | _pending_ | | | | | |
| Day 5 | _pending_ | | | | | |

---

## 6. Unresolved Requirements (Cutover Blockers)

1. **H5 live working-week validation:** Complete 5 real working days on the target terminal with zero unlogged fallbacks, terminal corruptions, or ambiguous writes.
2. **H0 sign-off on local resources:** Classify which items in Section 3 (skills, scripts, `tmux-session`, `notify`, `auto-profile`, `multicodex`, `google-token-exchange`, `retry`, `empty-response-guard`) are required for cutover vs optional/deferred.
3. **Daemon-discovered resources & workspace `@file` search (`docs/hi-build.md` Batch 2):** `hi` currently supports client-local `@` / `/attach` only; daemon-owned skill/template discovery (`/skill:name`) and environment-scoped file search/read are missing.
4. **Session lifecycle & context parity (`docs/hi-build.md` Batches 2–3):** Missing `/name` (rename), `/clone`, `/compact` (persisted compaction intent/recovery), `/fork`-before-edit (`fork_and_submit` for editing an earlier prompt), user shell `!` / `!!` in `H.ExecutionEnv`, and a validated `pi` JSONL `/import` tool.
5. **Auth / provider UX parity:** Missing interactive `/login` / `/logout`, `/model` capability details (context window / cost metadata), and `/scoped-models` cycling (`Shift+Tab` thinking cycle, `Ctrl+P` model cycle).
6. **H2 performance & terminal matrix:** Measure p95 key-to-paint `<50 ms` on the recorded 10k-entry trace and complete manual verification across macOS/Linux, `tmux`, SSH, and real IME / CJK / Kitty-vs-legacy key chords.
7. **CLI / help / packaging polish:** Fix `hi --help` positional `[PROMPT]...` description (claims headless print mode even though TTY `hi "msg"` starts the interactive TUI), drop or gate unused `--tui-mode` from `h --help`, reconcile `-v` vs `-V` and piped-stdin `-p` expectations if scripts require them, and package locked release binaries for macOS/Linux.
