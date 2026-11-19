# Dynamic configuration in `hi` (design discussion)

[`hi` ships data-only status templates](hi-status.md). The options here are proposals, not extension hooks that exist today.

## What other clients do

- [Neovim's `statusline`](https://neovim.io/doc/user/options/#'statusline') mixes printf-style text and fields, with an opt-in expression for when a format isn't enough. It resets a failing expression to the default so redraw doesn't loop on the failure. The useful lesson for `hi` is that a string format can remain the common case even if executable customization is possible.
- [WezTerm's Lua configuration](https://wezterm.org/config/files.html) reloads when the file changes. Its [`update-status` event](https://wezterm.org/config/lua/window-events/update-status.html) receives a window and pane and allows only one invocation outstanding; a slow callback doesn't queue up work. The useful lessons are a small state input and backpressure. `hi` should not copy the broad window/pane API or put a callback on the redraw path.

## Choices

| Option | Good fit | Cost or limitation |
| --- | --- | --- |
| MiniJinja strings (shipped) | Conditions, fallbacks, formatting; can show or hide whole rows based on the current provider, model, workspace or run. Easy to share and review. | Not a general-purpose API for deriving data or talking to other programs. This is intentional. |
| Generate JSON externally (works today) | A dotfiles script in any language, including Lua, can write `hi.json`; save atomically, then `/reload`. No new runtime or output protocol in `hi`. | Generation is a separate, explicit step. Only the templates in the resulting JSON respond to live state. `hi` does not run the generator. |
| Embedded Lua via [`mlua`](https://docs.rs/mlua/latest/mlua/struct.Lua.html) | Familiar from Neovim and WezTerm; tables are a natural fit for the same settings and rows. Useful for reusable functions and composing local configuration. | VM/build choice and host API become maintenance commitments. `mlua` offers hooks and memory limits; its `sandbox` API is Luau-specific. Neither the binding nor omitting a few standard libraries is a complete OS security boundary. |
| [Rhai](https://rhai.rs/book/safety/) | Rust-native embedding with host-selected functions and configurable [operation limits](https://rhai.rs/book/safety/max-operations.html). Worth considering if avoiding a Lua/C toolchain is important. | Less familiar for editor dotfiles, and still requires a capability boundary, memory/output limits, and reload semantics. |

**Recommendation:** Keep JSON + templates as the default. Yes, Lua is a good candidate for an **opt-in, user-owned configuration language**, but the first use should be a settings generator, not a plugin API. Try external generation first. If a concrete use needs embedding, start with `hi.lua` returning the same settings as JSON on explicit `/reload`; validate them through the same path before swapping. This also supports composing upstream lists in the user's own code without inventing a new include/merge language.

If a later use really needs script-level decisions on live state, start with one narrow, read-only function such as `status(snapshot) -> list of strings`, not general lifecycle hooks. Give it a versioned copy of the documented status fields, no daemon handle. Evaluate only when relevant fields change, off the terminal paint loop, with one job in flight and coalesced updates. Associate each result with its config generation and target, discard stale results after reload or target switch, and fall back to the declarative rows if it fails or times out. Put limits on execution time, instructions, memory and returned text; don't expose raw terminal output or re-interpret returned text as code.

## Trust and scope

- Opt in at the user level. Never discover or run code from the session CWD, a checkout, a remote environment, a model reply or the daemon stream. Never source a project Lua file automatically.
- Do not pass bearer tokens, provider credentials, raw draft/transcript content, or process handles to executable config. Expose no shell, filesystem, network, process, native module/FFI or daemon mutation APIs to a status callback. A worker thread keeps the UI responsive; it is not isolation. A subprocess running with the user's permissions is not a sandbox either.
- Keep changes local to the client. Appearance and keymaps aren't authority to add tools, override execution policy or mutate shared history. Grow the script API only around actual user workflows, and test bad reloads, slow callbacks, and stale results before making it available.
