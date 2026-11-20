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
    "{% if has_usage %}Tokens {{ input_tokens | compact }}/{{ output_tokens | compact }} · ${{ '%.2f' | format(cost) }}{% endif %}",
    "{% if total_tokens > 0 %}Output share: {{ '%.1f' | format(100 * output_tokens / total_tokens) }}%{% endif %}"
  ]
}
```

- `status_lines` replaces the entire inherited list. Today the inherited list is the built-in footer; there is no workspace or site-config discovery. Omit the key (or set it to `null`) to inherit. Set it to `[]` to have no base lines.
- `status_lines_append` is an optional array of strings added after either the inherited or replacement list. For example, `{"status_lines_append": ["{{ env_id }} · {{ cwd }}"]}` keeps the default and adds one line.
- Whitespace-only output takes up no row. Lines do not wrap: they are clipped to terminal width. There is no fixed row count. If not all rows fit, the first ones take priority; put the most important lines first. The editor and its focused picker have priority over extra status rows. Terminal control characters are escaped, including ones in substituted values.
- Save the file and run `/reload`. `hi` reloads this file and the existing `hi-keybindings.json` together. Malformed JSON, bad template syntax, unknown fields, or a keybinding conflict leave both previous settings active. Templates are also checked against current state before applying; a state-dependent error that first occurs later is shown on the affected row without taking down the UI. A failed reload opens an error picker even if the footer is empty. Include `{{ note }}` if you want normal client feedback (including successful reloads and command results) in the footer.

Only these user config files are read. Templates can't read files, invoke a shell, call the daemon, or look up credentials. They receive the fields below, not the raw transcript, draft, or protocol documents.

## Two-line workspace and context footer

```json
{
  "status_lines": [
    "{{ cwd_short }}{% if git_branch %} ({{ git_branch }}){% endif %}",
    "{% set meter %}{% if context_window %}{{ '%.0f' | format(context_percent) if context_percent is not none else '—' }}%/{{ context_window | compact }}{% else %}—{% endif %}{% endset %}{{ align(meter, model ~ ':' ~ thinking) }}"
  ]
}
```

`cwd_short` shortens a local workspace under `$HOME` to `~/…`. `git_branch`
reads the local checkout's branch (including linked worktrees); it's absent
outside Git, in detached HEAD, or for non-host environments. `align(left,
right)` spaces the two values to opposite edges of the terminal using display
width, or puts one space between them if they don't fit. Workspace and model
metadata are read in the background, not on redraw or by the template.

The meter is the latest completed assistant reply's reported token usage
(input plus output, or the provider's total) divided by the selected model's
catalog context window. It is **not** cumulative usage or an estimate of
unsubmitted text or the next request. An empty conversation starts at 0%; an
unknown limit or unavailable usage is shown as `—`. A reset starts again at
0%; after compaction the usage is unknown until another reply reports it.
This layout omits `note`;
append `{{ note }}` if you want regular command feedback in the footer.

## MiniJinja primer

`{{ expression }}` prints a value; `{% if … %}…{% endif %}` controls what appears. `|` pipes a value into a filter. Use single quotes inside expressions to avoid escaping JSON's double quotes. These examples are individual template strings: put each one in quotes in your `status_lines` or `status_lines_append` array. The [MiniJinja 2.24 documentation](https://docs.rs/minijinja/2.24.0/minijinja/) describes the underlying syntax; `compact` is specific to `hi`.

### Numbers: money, percentages, and counts

**Show dollars and cents.** `format` takes a printf-style format string on the left and the value to format as its argument:

```jinja
${{ '%.2f' | format(cost) }}
```

`2.4305` displays as `$2.43`, `2.439` as `$2.44`, and `2.5` as `$2.50`. `%.2f` **rounds** and always shows two decimal places; it doesn't simply cut off the remaining digits. For four places, use `%.4f`. If you want rounding without padding to two places, `${{ cost | round(2) }}` displays `$2.5` instead of `$2.50`. Use `format` instead of `round` when you need a fixed number of digits.

**Calculate a percentage.** Use `+`, `-`, `*`, and `/` in expressions. Guard the denominator: token counts can be zero before the first reply.

```jinja
{% if total_tokens > 0 %}Output share: {{ '%.1f' | format(100 * output_tokens / total_tokens) }}%{% endif %}
```

For 253 output tokens out of 1,000, this shows `Output share: 25.3%`. Use `%.0f` for `25%`, or add `{% else %}Output share: —` before `{% endif %}` to show a placeholder instead of hiding the row. This is a share of reported usage, **not** a context-window percentage; use `context_percent` for the latter. When filtering the result of a calculation, group it first: `{{ (100 * output_tokens / total_tokens) | round(1) }}` (inside the same guard).

**Abbreviate counts.** `{{ total_tokens | compact }}` keeps `0–999` as-is and shows whole `k`, `m`, or `b` units above that: `1,999` → `1k`, `999,999` → `999k`, `1,000,000` → `1m`, `1,000,000,000` → `1b`. It preserves a minus sign and prints nothing for an unavailable value. Do math with the raw count before formatting it; `compact` and `format` return text.

### Text: fallbacks, optional labels, and conditions

| Want to… | Template |
| --- | --- |
| Fall back from a missing or empty title | `{{ session_title or session_id }}` |
| Show `—` when a value is missing, but keep zero | `seq {{ seq if seq is not none else '—' }}` |
| Show just the last directory name (keep `/` for the root) | `{{ (cwd \| trim('/') \| split('/') \| last) or cwd }}` |
| Uppercase a label | `{{ activity \| upper }}` |
| Add a separator only when there's something to show | `{{ activity }}{% if queued %} · {{ queued }} queued{% endif %}` |
| Show a row only in a matching session | `{% if provider == 'openai' and thinking == 'high' %}{{ model }} · {{ activity }}{% endif %}` |
| Choose between messages | `{% if not online %}Offline{% elif pending %}Waiting for command{% else %}{{ activity }}{% endif %}` |

Unavailable fields print as empty; the labels around them don't disappear automatically. Wrap the label and value together in a condition, such as `{% if shell_active %}Shell {{ shell_prefix }}{{ shell_preview }} ({{ shell_status }}){% endif %}`. Use `is none` to distinguish an unavailable field from `0`, `false`, or an empty string. An unknown field name is a configuration error, not a missing value.

## Available fields

| Group | Fields |
| --- | --- |
| Client feedback | `note`, `connection` (`online`/`offline`), `online` (boolean), `seq` (latest committed sequence, absent before a snapshot), `pending` (local command in flight) |
| Session and workspace | `session_id`, `conversation_id`, `session_title`, `session_status` (catalog status, e.g. `ok` or `quarantined`), `cwd` (session directory, not the `hi` process directory), `cwd_short`, `git_branch`, `env_id`, `harness_id` |
| Model | `model` (full configured ID), `provider` (prefix of `provider:model` or `provider/model`, absent if unqualified), `model_name` (model part of that ID), `thinking` (configured level), `context_window` (catalog capacity), `context_percent` (latest reply's reported usage as a percentage of that capacity) |
| Live conversation | `activity` (`busy`, `paused`, or `idle`), `queued` (inbox count), `run_turns`, `compaction_status`, `compaction_failed`, `failure_reason`, `failure_code`, `failure_message` |
| Usage | `has_usage`, `input_tokens`, `output_tokens`, `total_tokens`, `cost` (reported cumulative dollars; may be zero) |
| Active user shell | `shell_active`, `shell_prefix` (`!` or `!!`), `shell_command`, `shell_preview` (24 characters of escaped command text), `shell_status` |
| Editor and view | `width` (terminal columns), `attachments` (count), `fork_entry_id`, `fork_predecessor_id`, `retry_pending`, `historical` (viewing an earlier page), `show_tools`, `show_thinking` (display toggles) |

`activity`, model, thinking level, queue and usage follow the live conversation even while browsing earlier entries. `session_title`, `session_status`, and `harness_id` come from the session metadata `hi` last read on attach/create or a metadata-fetching switch. `/name` also refreshes or changes the local title; updates to catalog metadata from another client aren't streamed in the conversation feed. Use `activity`, not `session_status`, to distinguish an active turn from an idle one.

## What the inherited line shows

The template system keeps the previous built-in layout for now. A typical idle line is:

```text
Ready · /help · online · [seq 42 · idle · openai:gpt-5.2-codex (medium)] · demo:1 · /work/project
```

From left to right: the latest local message and help hint; a shell preview if a user shell command is active; the connection; then the committed sequence, run activity, model and thinking level. The bracket also shows the queue count when nonzero and input/output token totals and cost when available. `pending`, `attachment`, and `fork-edit #entry@predecessor` are local indicators that appear only when relevant. The final fields are the session/conversation IDs and the session's working directory. At narrow widths, fields on the right can disappear; they aren't dropped from the state. The built-in template is in [`status.rs`](../clients/tui/src/hi/status.rs).

For proposed data from optional daemon packages, see [one opt-in status projection](extensions/clients.md#proposed-one-opt-in-status-projection). For possible local executable configuration, see [Dynamic configuration in `hi`](hi-dynamic-config.md). Neither is enabled today.
