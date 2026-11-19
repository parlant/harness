# `hi` status lines

Status lines are ordered, plain-text rows below the editor in both fullscreen and regular mode. They are local to `hi`; changing them does not change the session or another client.

## Configure and reload

Create `<data_dir>/hi.json`, where `data_dir` is selected by `--data-dir`, `H_DATA_DIR`, or (by default) `~/.local/share/h`. For example:

```json
{
  "status_lines": [
    "{{ note }}",
    "{{ session_title or session_id }} #{{ conversation_id }} · {{ cwd }}",
    "{{ model }} ({{ thinking }}) · {{ connection }} · {{ activity }}{% if queued %} · {{ queued }} queued{% endif %}",
    "{% if provider == 'openai' and has_usage %}Tokens {{ input_tokens }}/{{ output_tokens }} · ${{ '%.4f'|format(cost) }}{% endif %}"
  ]
}
```

- `status_lines` replaces the entire inherited list. Today the inherited list is the built-in footer; there is no workspace or site-config discovery. Omit the key (or set it to `null`) to inherit. Set it to `[]` to have no base lines.
- `status_lines_append` is an optional array of strings added after either the inherited or replacement list. For example, `{"status_lines_append": ["{{ env_id }} · {{ cwd }}"]}` keeps the default and adds one line.
- Each string is a [MiniJinja](https://docs.rs/minijinja/2.24.0/minijinja/) template. Insert a field with `{{ field }}`, choose text or whole rows with `{% if … %}…{% elif … %}…{% else %}…{% endif %}`, and format a number with `{{ '%.4f'|format(cost) }}`. Conditions can combine any of the fields below; they are reevaluated when `hi` redraws. Optional fields print as empty and can be tested with `is none` or supplied a fallback with `or`.
- Whitespace-only output takes up no row. Lines do not wrap: they are clipped to terminal width. There is no fixed row count. If not all rows fit, the first ones take priority; put the most important lines first. The editor and its focused picker have priority over extra status rows. Terminal control characters are escaped, including ones in substituted values.
- Save the file and run `/reload`. `hi` reloads this file and the existing `hi-keybindings.json` together. Malformed JSON, bad template syntax, unknown fields, or a keybinding conflict leave both previous settings active. Templates are also checked against current state before applying; a state-dependent error that first occurs later is shown on the affected row without taking down the UI. A failed reload opens an error picker even if the footer is empty. Include `{{ note }}` if you want normal client feedback (including successful reloads and command results) in the footer.

Only these user config files are read. Templates can't read files, invoke a shell, call the daemon, or look up credentials. They receive the fields below, not the raw transcript, draft, or protocol documents.

## Available fields

| Group | Fields |
| --- | --- |
| Client feedback | `note`, `connection` (`online`/`offline`), `online` (boolean), `seq` (latest committed sequence, absent before a snapshot), `pending` (local command in flight) |
| Session and workspace | `session_id`, `conversation_id`, `session_title`, `session_status` (catalog status, e.g. `ok` or `quarantined`), `cwd` (session directory, not the `hi` process directory), `env_id`, `harness_id` |
| Model | `model` (full configured ID), `provider` (prefix of `provider:model` or `provider/model`, absent if unqualified), `model_name` (model part of that ID), `thinking` (configured level) |
| Live conversation | `activity` (`busy`, `paused`, or `idle`), `queued` (inbox count), `run_turns`, `compaction_status`, `compaction_failed`, `failure_reason`, `failure_code`, `failure_message` |
| Usage | `has_usage`, `input_tokens`, `output_tokens`, `total_tokens`, `cost` (reported cumulative dollars; may be zero) |
| Active user shell | `shell_active`, `shell_prefix` (`!` or `!!`), `shell_command`, `shell_preview` (24 characters of escaped command text), `shell_status` |
| Editor and view | `attachments` (count), `fork_entry_id`, `fork_predecessor_id`, `retry_pending`, `historical` (viewing an earlier page), `show_tools`, `show_thinking` (display toggles) |

`activity`, model, thinking level, queue and usage follow the live conversation even while browsing earlier entries. `session_title`, `session_status`, and `harness_id` come from the session metadata `hi` last read on attach/create or a metadata-fetching switch. `/name` also refreshes or changes the local title; updates to catalog metadata from another client aren't streamed in the conversation feed. Use `activity`, not `session_status`, to distinguish an active turn from an idle one.

## What the inherited line shows

The template system keeps the previous built-in layout for now. A typical idle line is:

```text
Ready · /help · online · [seq 42 · idle · openai:gpt-5.2-codex (medium)] · demo:1 · /work/project
```

From left to right: the latest local message and help hint; a shell preview if a user shell command is active; the connection; then the committed sequence, run activity, model and thinking level. The bracket also shows the queue count when nonzero and input/output token totals and cost when available. `pending`, `attachment`, and `fork-edit #entry@predecessor` are local indicators that appear only when relevant. The final fields are the session/conversation IDs and the session's working directory. At narrow widths, fields on the right can disappear; they aren't dropped from the state. The built-in template is in [`status.rs`](../clients/tui/src/hi/status.rs).

For possible executable configuration, see [Dynamic configuration in `hi`](hi-dynamic-config.md). No executable configuration is enabled today.
