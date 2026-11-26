use super::markdown::{diff_line_style, render_markdown_lines, StyledRow, StyledSpan};
use super::theme::Theme;
use crate::protocol::TranscriptEntry;
use crate::render::{sanitize_single_line, sanitize_terminal_text};
use crate::transcript::TranscriptState;
use ratatui::style::Style;
use serde_json::{Map, Value};
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};

const PREVIEW_LINES: usize = 5;
const ERROR_PREVIEW_LINES: usize = 8;
const EXPANDED_OUTPUT_LINES: usize = 200;
const OUTPUT_LINE_BYTES: usize = 1024;
const COMPACT_CHARS: usize = 100;

/// Renders committed transcript entries, live streaming generation/tools, queued
/// inbox items, and run/compaction failures into sanitized single-line display rows.
///
/// Guarantees no ANSI escape sequences, C0/C1 control characters, `\r`, `\t`, or
/// embedded `\n` appear in any returned row.
pub fn rows(state: &TranscriptState, tools_expanded: bool, thinking_expanded: bool) -> Vec<String> {
    let theme = Theme::plain();
    styled_rows(state, tools_expanded, thinking_expanded, &theme)
        .into_iter()
        .map(|row| row.plain_text())
        .collect()
}

/// Renders committed transcript entries, live streaming generation/tools, queued
/// inbox items, and run/compaction failures into styled, sanitized display rows.
///
/// All untrusted text is sanitized before styling so no raw ANSI/control
/// sequences can appear inside any [`StyledSpan`].
pub fn styled_rows(
    state: &TranscriptState,
    tools_expanded: bool,
    thinking_expanded: bool,
    theme: &Theme,
) -> Vec<StyledRow> {
    let mut out = Vec::new();

    if state.has_more {
        let before = state
            .before_entry_id
            .as_deref()
            .filter(|s| !s.is_empty())
            .map(|id| format!(" (before #{})", sanitize_single_line(id)))
            .unwrap_or_default();
        out.push(StyledRow::plain(
            format!("... earlier history available{before}"),
            theme.history_marker,
        ));
    }

    let mut calls_by_id: HashMap<&str, (&str, &Value)> = HashMap::new();
    let mut result_ids: HashSet<&str> = HashSet::new();
    for entry in &state.entries {
        match entry.kind.as_str() {
            "assistant" => {
                for (cid, name, args) in tool_calls_of(&entry.data) {
                    if let Some(id) = cid {
                        calls_by_id.insert(id, (name, args));
                    }
                }
            }
            "tool_result" => {
                if let Some(cid) = str_at(&entry.data, "tool_call_id") {
                    result_ids.insert(cid);
                }
            }
            _ => {}
        }
    }

    let live_tools = collect_live_tools(state, &result_ids);
    let live_ids: HashSet<&str> = live_tools.iter().map(|(id, _)| id.as_str()).collect();

    for entry in &state.entries {
        separate(&mut out);
        render_entry(
            &mut out,
            entry,
            &calls_by_id,
            &result_ids,
            &live_ids,
            tools_expanded,
            thinking_expanded,
            theme,
        );
    }

    render_live(
        &mut out,
        state,
        &calls_by_id,
        &live_tools,
        tools_expanded,
        thinking_expanded,
        theme,
    );
    render_inbox(&mut out, state, theme);
    render_failure(&mut out, state, theme);

    out
}

fn str_at<'a>(val: &'a Value, key: &str) -> Option<&'a str> {
    val.get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
}

fn u64_at(val: &Value, key: &str) -> Option<u64> {
    val.get(key).and_then(Value::as_u64)
}

fn separate(out: &mut Vec<StyledRow>) {
    if !out.is_empty() {
        out.push(StyledRow::plain(String::new(), Style::default()));
    }
}

fn push_lines_styled(out: &mut Vec<StyledRow>, raw: &str, prefix: &str, style: Style) {
    let safe = sanitize_terminal_text(raw).replace('\t', "   ");
    for line in safe.split('\n') {
        out.push(StyledRow::plain(format!("{prefix}{line}"), style));
    }
}

fn push_markdown(out: &mut Vec<StyledRow>, raw: &str, theme: &Theme, base_style: Style) {
    out.extend(render_markdown_lines(raw, theme, base_style));
}

fn push_user_lines(out: &mut Vec<StyledRow>, raw: &str, theme: &Theme) {
    let safe = sanitize_terminal_text(raw).replace('\t', "   ");
    for line in safe.split('\n') {
        let mut row = StyledRow::from_spans(vec![
            StyledSpan::new("▌ ", theme.user_header),
            StyledSpan::new(line, theme.user_text),
        ]);
        if !theme.is_plain && theme.user_text.bg.is_some() {
            row = row.with_fill(theme.user_text);
        }
        out.push(row);
    }
}

fn push_preview(
    out: &mut Vec<StyledRow>,
    raw: &str,
    max_lines: usize,
    tail: bool,
    label: &str,
    theme: &Theme,
) {
    // Pick the rows before sanitizing, and clip before wrapping. A single
    // newline-free stdout line can otherwise dominate the entire redraw.
    let lines = raw.trim_end().lines();
    let omitted = lines.clone().count().saturating_sub(max_lines);
    if tail && omitted > 0 {
        out.push(StyledRow::plain(
            format!("  ... ({omitted} earlier lines)"),
            theme.tool_meta,
        ));
    }
    for line in lines.skip(if tail { omitted } else { 0 }).take(max_lines) {
        let end = line.floor_char_boundary(OUTPUT_LINE_BYTES);
        let safe = sanitize_terminal_text(&line[..end]).replace('\t', "   ");
        let clipped = if end < line.len() {
            " ... [line clipped]"
        } else {
            ""
        };
        let style = if safe.starts_with('+') || safe.starts_with('-') || safe.starts_with("@@ ") {
            let ds = diff_line_style(&safe, theme);
            if ds == Style::default() {
                theme.tool_output
            } else {
                ds
            }
        } else {
            theme.tool_output
        };
        let mut spans = vec![StyledSpan::new(format!("  {safe}"), style)];
        if !clipped.is_empty() {
            spans.push(StyledSpan::new(clipped, theme.tool_meta));
        }
        out.push(StyledRow::from_spans(spans));
    }
    if !tail && omitted > 0 {
        out.push(StyledRow::plain(
            format!("  ... ({omitted} more {label})"),
            theme.tool_meta,
        ));
    }
}

fn truncate(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        return s.to_string();
    }
    let head: String = s.chars().take(max_chars.saturating_sub(3)).collect();
    format!("{head}...")
}

fn tool_calls_of(data: &Value) -> Vec<(Option<&str>, &str, &Value)> {
    static EMPTY: Value = Value::Null;
    let Some(arr) = data.get("tool_calls").and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|tc| {
            let obj = tc.as_object()?;
            let name = obj.get("name").and_then(Value::as_str).unwrap_or("tool");
            let id = str_at(tc, "id");
            let args = obj.get("arguments").unwrap_or(&EMPTY);
            Some((id, name, args))
        })
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn render_entry(
    out: &mut Vec<StyledRow>,
    entry: &TranscriptEntry,
    calls_by_id: &HashMap<&str, (&str, &Value)>,
    result_ids: &HashSet<&str>,
    live_ids: &HashSet<&str>,
    tools_expanded: bool,
    thinking_expanded: bool,
    theme: &Theme,
) {
    let id = sanitize_single_line(&entry.id);
    let kind = sanitize_single_line(&entry.kind);

    match entry.kind.as_str() {
        "user" => {
            out.push(StyledRow::plain(format!("[user #{id}]"), theme.user_header));
            render_blocks(
                out,
                &entry.data,
                tools_expanded,
                thinking_expanded,
                false,
                true,
                theme,
            );
        }
        "system" => {
            out.push(StyledRow::plain(
                format!("[system #{id}]"),
                theme.system_header,
            ));
            render_blocks(
                out,
                &entry.data,
                tools_expanded,
                thinking_expanded,
                false,
                false,
                theme,
            );
        }
        "assistant" => {
            let aborted = entry.data.get("aborted").and_then(Value::as_bool) == Some(true);
            let finish = str_at(&entry.data, "finish_reason");
            let tag = match (aborted, finish) {
                (true, _) | (_, Some("aborted")) => " · aborted",
                (_, Some("length")) => " · truncated",
                (_, Some("content_filter")) => " · filtered",
                (_, Some("error")) => " · error",
                _ => "",
            };
            let mut spans = vec![StyledSpan::new(
                format!("[assistant #{id}"),
                theme.assistant_header,
            )];
            if !tag.is_empty() {
                let tag_style = if aborted
                    || finish == Some("error")
                    || finish == Some("aborted")
                    || finish == Some("content_filter")
                {
                    theme.failure_header
                } else {
                    theme.tool_running
                };
                spans.push(StyledSpan::new(tag, tag_style));
            }
            spans.push(StyledSpan::new("]", theme.assistant_header));
            out.push(StyledRow::from_spans(spans));

            let has_body = render_blocks(
                out,
                &entry.data,
                tools_expanded,
                thinking_expanded,
                false,
                false,
                theme,
            );
            let tcs = tool_calls_of(&entry.data);

            if aborted || finish == Some("aborted") {
                out.push(StyledRow::plain(
                    "! Operation aborted",
                    theme.failure_header,
                ));
            } else if finish == Some("length") {
                out.push(StyledRow::plain(
                    "! Response was truncated before completion.",
                    theme.tool_running,
                ));
            } else if finish == Some("content_filter") {
                let raw = entry
                    .data
                    .get("provider_meta")
                    .and_then(|m| str_at(m, "finish_reason_raw"));
                let msg = entry
                    .data
                    .get("provider_meta")
                    .and_then(|m| str_at(m, "finish_message"));
                let notice = match (raw, msg) {
                    (Some(r), Some(m)) => format!(
                        "! Output blocked by content filter ({}): {}",
                        sanitize_single_line(r),
                        sanitize_single_line(m)
                    ),
                    (Some(r), None) => format!(
                        "! Output blocked by content filter ({})",
                        sanitize_single_line(r)
                    ),
                    (None, Some(m)) => format!(
                        "! Output blocked by content filter: {}",
                        sanitize_single_line(m)
                    ),
                    (None, None) => "! Output blocked by content filter".to_string(),
                };
                out.push(StyledRow::plain(notice, theme.failure_header));
            } else if finish == Some("error") {
                out.push(StyledRow::plain(
                    "! Error: generation failed",
                    theme.failure_header,
                ));
            } else if !has_body && tcs.is_empty() {
                out.push(StyledRow::plain(
                    "! Empty assistant response (no text or tool calls)",
                    theme.tool_meta,
                ));
            }

            for (cid, name, args) in tcs {
                if cid.is_some_and(|c| result_ids.contains(c) || live_ids.contains(c)) {
                    continue;
                }
                let summary = tool_summary(name, args, tools_expanded);
                let id_tag = cid
                    .map(|c| format!(" ({})", sanitize_single_line(c)))
                    .unwrap_or_default();
                out.push(StyledRow::from_spans(vec![
                    StyledSpan::new("[tool ", theme.tool_header),
                    StyledSpan::new(sanitize_single_line(&summary), theme.tool_header),
                    StyledSpan::new(sanitize_single_line(&id_tag), theme.tool_meta),
                    StyledSpan::new(" · no result", theme.tool_meta),
                    StyledSpan::new("]", theme.tool_header),
                ]));
                if tools_expanded {
                    render_expanded_args(out, name, args, theme);
                }
            }
        }
        "tool_result" => {
            render_tool_result(out, &id, &entry.data, calls_by_id, tools_expanded, theme)
        }
        "user_shell" => render_user_shell(out, &id, &entry.data, tools_expanded, theme),
        "compaction" | "reset" => {
            let body = ["summary", "handoff", "note", "reason", "text"]
                .iter()
                .find_map(|k| str_at(&entry.data, k))
                .map(str::to_string)
                .unwrap_or_else(|| entry.data.to_string());
            let toks = u64_at(&entry.data, "tokens_before")
                .map(|t| format!(" · compacted from {t} tokens"))
                .unwrap_or_default();
            let prefix = format!("[{kind} #{id}{toks}]");
            if tools_expanded {
                out.push(StyledRow::plain(prefix, theme.compaction_header));
                if !body.trim().is_empty() {
                    push_lines_styled(out, body.trim(), "  ", theme.tool_output);
                }
            } else {
                let preview = truncate(&sanitize_single_line(body.trim()), COMPACT_CHARS);
                if preview.is_empty() {
                    out.push(StyledRow::plain(prefix, theme.compaction_header));
                } else {
                    out.push(StyledRow::from_spans(vec![
                        StyledSpan::new(prefix, theme.compaction_header),
                        StyledSpan::new(format!(" {preview}"), theme.tool_meta),
                    ]));
                }
            }
        }
        _ => {
            out.push(StyledRow::plain(
                format!("[{kind} #{id}]"),
                theme.system_header,
            ));
            if !render_blocks(
                out,
                &entry.data,
                tools_expanded,
                thinking_expanded,
                false,
                false,
                theme,
            ) {
                let raw = entry.data.to_string();
                if tools_expanded {
                    push_lines_styled(out, &raw, "  ", theme.tool_output);
                } else {
                    out.push(StyledRow::plain(
                        truncate(&sanitize_single_line(&raw), COMPACT_CHARS),
                        theme.tool_meta,
                    ));
                }
            }
        }
    }
}

fn render_blocks(
    out: &mut Vec<StyledRow>,
    data: &Value,
    tools_expanded: bool,
    thinking_expanded: bool,
    streaming: bool,
    is_user: bool,
    theme: &Theme,
) -> bool {
    let Some(obj) = data.as_object() else {
        return false;
    };
    let mut emitted = false;

    if let Some(thinking) = str_at(data, "thinking").filter(|s| !s.trim().is_empty()) {
        render_thinking(out, thinking, streaming, thinking_expanded, theme);
        emitted = true;
    }

    let push_text = |out: &mut Vec<StyledRow>, text: &str| {
        if is_user {
            push_user_lines(out, text, theme);
        } else {
            push_markdown(out, text, theme, Style::default());
        }
    };

    match obj.get("content") {
        Some(Value::String(s)) if !s.is_empty() => {
            push_text(out, s);
            emitted = true;
        }
        Some(Value::Array(blocks)) => {
            for block in blocks {
                if let Some(s) = block.as_str().filter(|s| !s.is_empty()) {
                    push_text(out, s);
                    emitted = true;
                    continue;
                }
                let Some(btype) = str_at(block, "type") else {
                    continue;
                };
                match btype {
                    "text" => {
                        if let Some(t) = str_at(block, "text") {
                            push_text(out, t);
                            emitted = true;
                        }
                    }
                    "thinking" => {
                        if let Some(t) = str_at(block, "thinking").or_else(|| str_at(block, "text"))
                        {
                            if !t.trim().is_empty() {
                                render_thinking(out, t, streaming, thinking_expanded, theme);
                                emitted = true;
                            }
                        }
                    }
                    "image" => {
                        let mime = str_at(block, "mime_type")
                            .or_else(|| str_at(block, "media_type"))
                            .unwrap_or("image/unknown");
                        let size = str_at(block, "data")
                            .map(|d| format!(" ~{} bytes", (d.len() * 3) / 4))
                            .unwrap_or_default();
                        out.push(StyledRow::plain(
                            format!("[image: {}{size}]", sanitize_single_line(mime)),
                            theme.tool_meta,
                        ));
                        emitted = true;
                    }
                    other => {
                        let bkind = sanitize_single_line(other);
                        let mut scrubbed = block.clone();
                        if let Some(m) = scrubbed.as_object_mut() {
                            if let Some(Value::String(s)) = m.get("data") {
                                if s.len() > 256 {
                                    m.insert(
                                        "data".into(),
                                        Value::String(format!("<omitted {} chars>", s.len())),
                                    );
                                }
                            }
                        }
                        if tools_expanded {
                            out.push(StyledRow::plain(
                                format!("[block {bkind}]"),
                                theme.tool_meta,
                            ));
                            push_lines_styled(
                                out,
                                &serde_json::to_string_pretty(&scrubbed).unwrap_or_default(),
                                "  ",
                                theme.tool_output,
                            );
                        } else {
                            let preview = truncate(
                                &sanitize_single_line(&scrubbed.to_string()),
                                COMPACT_CHARS,
                            );
                            out.push(StyledRow::plain(
                                format!("[block {bkind}] {preview}"),
                                theme.tool_meta,
                            ));
                        }
                        emitted = true;
                    }
                }
            }
        }
        _ => {}
    }

    if !emitted {
        if let Some(t) = str_at(data, "text") {
            push_text(out, t);
            emitted = true;
        }
    }
    emitted
}

fn render_thinking(
    out: &mut Vec<StyledRow>,
    raw: &str,
    streaming: bool,
    expanded: bool,
    theme: &Theme,
) {
    let safe = sanitize_terminal_text(raw.trim()).replace('\t', "   ");
    let lines: Vec<&str> = safe.split('\n').collect();
    if expanded {
        out.push(StyledRow::plain(
            if streaming {
                "[thinking (streaming)]"
            } else {
                "[thinking]"
            },
            theme.thinking_header,
        ));
        for line in lines {
            out.push(StyledRow::plain(format!("  | {line}"), theme.thinking_text));
        }
    } else if streaming {
        out.push(StyledRow::plain(
            format!("[thinking (streaming · {} lines, collapsed)]", lines.len()),
            theme.thinking_header,
        ));
    } else {
        out.push(StyledRow::plain(
            format!("[thinking · {} lines (collapsed)]", lines.len()),
            theme.thinking_header,
        ));
    }
}

fn render_tool_result(
    out: &mut Vec<StyledRow>,
    id: &str,
    data: &Value,
    calls_by_id: &HashMap<&str, (&str, &Value)>,
    tools_expanded: bool,
    theme: &Theme,
) {
    let paired = str_at(data, "tool_call_id").and_then(|cid| calls_by_id.get(cid).copied());
    let name = str_at(data, "name")
        .or_else(|| paired.map(|(n, _)| n))
        .unwrap_or("tool");
    let empty = Value::Null;
    let args = paired.map(|(_, a)| a).unwrap_or(&empty);
    let is_error = data.get("is_error").and_then(Value::as_bool) == Some(true);
    let details = data.get("details").unwrap_or(&empty);

    let status_text = if is_error {
        match str_at(data, "diagnostic") {
            Some(d) => format!("! ERROR: {}", sanitize_single_line(d)),
            None => "! ERROR".into(),
        }
    } else {
        "ok".into()
    };
    let status_style = if is_error {
        theme.tool_error
    } else {
        theme.tool_ok
    };

    let mut header_spans = vec![
        StyledSpan::new(
            sanitize_single_line(&format!("[tool #{id} · ")),
            theme.tool_header,
        ),
        StyledSpan::new(sanitize_single_line(&status_text), status_style),
    ];
    if let Some(badge) = tool_badge(name, is_error, details) {
        header_spans.push(StyledSpan::new(
            sanitize_single_line(&format!(" · {badge}")),
            theme.tool_meta,
        ));
    }
    if let Some(ms) = u64_at(data, "duration_ms") {
        header_spans.push(StyledSpan::new(
            sanitize_single_line(&format!(" · {}", format_duration(ms))),
            theme.tool_meta,
        ));
    }
    let summary = tool_summary(name, args, tools_expanded);
    header_spans.push(StyledSpan::new("] ", theme.tool_header));
    header_spans.push(StyledSpan::new(
        sanitize_single_line(&summary),
        theme.tool_header,
    ));
    out.push(StyledRow::from_spans(header_spans));

    if tools_expanded {
        render_expanded_args(out, name, args, theme);
    }

    let mut text_lines = Vec::new();
    let mut non_text_blocks = Vec::new();
    if let Some(blocks) = data.get("content").and_then(Value::as_array) {
        for b in blocks {
            if str_at(b, "type") == Some("text") {
                if let Some(t) = b.get("text").and_then(Value::as_str) {
                    text_lines.push(t);
                }
            } else {
                non_text_blocks.push(b.clone());
            }
        }
    }

    let text = match text_lines.as_slice() {
        [] => Cow::Borrowed(""),
        [text] => Cow::Borrowed(*text),
        _ => Cow::Owned(text_lines.join("\n")),
    };
    if !text.trim().is_empty() {
        if tools_expanded {
            push_preview(out, &text, EXPANDED_OUTPUT_LINES, false, "lines", theme);
        } else if is_error {
            push_preview(out, &text, ERROR_PREVIEW_LINES, false, "error lines", theme);
        } else {
            match name {
                "read" | "write" => {}
                "bash" => push_preview(out, &text, PREVIEW_LINES, true, "lines", theme),
                _ => push_preview(out, &text, PREVIEW_LINES, false, "lines", theme),
            }
        }
    }

    if !non_text_blocks.is_empty() {
        let synthetic = Value::Object(Map::from_iter([(
            "content".into(),
            Value::Array(non_text_blocks),
        )]));
        render_blocks(out, &synthetic, tools_expanded, false, false, false, theme);
    }

    if tools_expanded
        && (details.get("truncated").and_then(Value::as_bool) == Some(true)
            || details.get("has_more").and_then(Value::as_bool) == Some(true))
    {
        let mut notes = Vec::new();
        if let Some(b) = u64_at(details, "skipped_bytes") {
            notes.push(format!("{b} bytes omitted"));
        }
        if let Some(p) = str_at(details, "full_output_path") {
            notes.push(format!("full output: {}", sanitize_single_line(p)));
        }
        if details.get("has_more").and_then(Value::as_bool) == Some(true) {
            notes.push("more lines available".into());
        }
        if !notes.is_empty() {
            out.push(StyledRow::plain(
                format!("  [{}]", notes.join(" · ")),
                theme.tool_meta,
            ));
        }
    }
}

fn render_user_shell(
    out: &mut Vec<StyledRow>,
    id: &str,
    data: &Value,
    tools_expanded: bool,
    theme: &Theme,
) {
    let command = str_at(data, "command").unwrap_or("");
    let include = data
        .get("include_in_context")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let prefix = if include { "!" } else { "!!" };
    let cancelled = data.get("cancelled").and_then(Value::as_bool) == Some(true);
    let is_error = data.get("is_error").and_then(Value::as_bool) == Some(true);
    let exit_code = data.get("exit_code").and_then(Value::as_i64);
    let diagnostic = str_at(data, "diagnostic");

    let mut header_spans = vec![StyledSpan::new(format!("[shell #{id}"), theme.shell_header)];
    if !include {
        header_spans.push(StyledSpan::new(" · excluded", theme.tool_meta));
    }
    let (status_label, status_style) = if cancelled {
        (" · aborted".to_string(), theme.tool_running)
    } else if let Some(code) = exit_code {
        if is_error || code != 0 {
            (format!(" · ! exit {code}"), theme.tool_error)
        } else {
            (" · exit 0".to_string(), theme.tool_ok)
        }
    } else if let Some(diag) = diagnostic {
        (
            format!(" · ! {}", sanitize_single_line(diag)),
            theme.tool_error,
        )
    } else if is_error {
        (" · ! error".to_string(), theme.tool_error)
    } else {
        (" · ok".to_string(), theme.tool_ok)
    };
    header_spans.push(StyledSpan::new(status_label, status_style));
    if let Some(ms) = u64_at(data, "duration_ms") {
        header_spans.push(StyledSpan::new(
            format!(" · {}", format_duration(ms)),
            theme.tool_meta,
        ));
    }

    let cmd_clean = sanitize_single_line(command);
    let cmd_shown = if tools_expanded {
        cmd_clean
    } else {
        truncate(&cmd_clean, COMPACT_CHARS)
    };
    header_spans.push(StyledSpan::new(
        format!("] {prefix}{cmd_shown}"),
        theme.shell_header,
    ));
    out.push(StyledRow::from_spans(header_spans));

    let output = str_at(data, "output").unwrap_or("");
    if !output.trim_end().is_empty() {
        if tools_expanded {
            push_preview(out, output, EXPANDED_OUTPUT_LINES, false, "lines", theme);
        } else {
            push_preview(out, output, PREVIEW_LINES, true, "lines", theme);
        }
    }

    if data.get("truncated").and_then(Value::as_bool) == Some(true) {
        let mut notes = Vec::new();
        if let Some(skipped) = u64_at(data, "skipped_bytes").filter(|b| *b > 0) {
            notes.push(format!("{skipped} bytes omitted"));
        } else {
            notes.push("truncated".to_string());
        }
        if let Some(path) = str_at(data, "full_output_path") {
            notes.push(format!("full output: {}", sanitize_single_line(path)));
        }
        out.push(StyledRow::plain(
            format!("  [{}]", notes.join(" · ")),
            theme.tool_meta,
        ));
    }
}

fn tool_badge(name: &str, is_error: bool, d: &Value) -> Option<String> {
    if !d.is_object() {
        return None;
    }
    match name {
        "read" => u64_at(d, "lines_read")
            .map(|n| {
                let plus = if d.get("has_more").and_then(Value::as_bool) == Some(true) {
                    "+"
                } else {
                    ""
                };
                format!("{n}{plus} lines")
            })
            .or_else(|| u64_at(d, "bytes").map(|b| format!("{b} bytes"))),
        "write" => u64_at(d, "bytes").map(|b| format!("{b} bytes")),
        "edit" => u64_at(d, "edits_applied").map(|n| format!("{n} edit(s)")),
        "bash" => d
            .get("exit_code")
            .and_then(Value::as_i64)
            .filter(|c| *c != 0 || is_error)
            .map(|c| format!("exit {c}")),
        "search_history" => u64_at(d, "count").map(|n| format!("{n} match(es)")),
        "subagent" => {
            let mut parts = Vec::new();
            if let Some(child_sid) = str_at(d, "child_session_id") {
                parts.push(format!("session {}", sanitize_single_line(child_sid)));
            }
            if let Some(status) = str_at(d, "status") {
                parts.push(sanitize_single_line(status));
            }
            if let Some(at_entry) = d.get("at_entry_id").and_then(|v| match v {
                Value::String(s) if !s.trim().is_empty() => Some(sanitize_single_line(s)),
                Value::Number(n) => Some(n.to_string()),
                _ => None,
            }) {
                parts.push(format!("@#{at_entry}"));
            }
            (!parts.is_empty()).then(|| parts.join(" · "))
        }
        _ => None,
    }
}

fn tool_summary(name: &str, args: &Value, expanded: bool) -> String {
    let sname = sanitize_single_line(name);
    let Some(obj) = args.as_object() else {
        return sname;
    };
    match name {
        "read" => {
            let path = str_at(args, "path").unwrap_or("...");
            let range = match (u64_at(args, "offset"), u64_at(args, "limit")) {
                (Some(s), Some(c)) if c > 0 => format!(":{s}-{}", s.saturating_add(c - 1)),
                (Some(s), _) => format!(":{s}"),
                (None, Some(c)) if c > 0 => format!(":1-{c}"),
                _ => String::new(),
            };
            format!("{sname} {}{range}", sanitize_single_line(path))
        }
        "write" | "edit" => format!(
            "{sname} {}",
            sanitize_single_line(str_at(args, "path").unwrap_or("..."))
        ),
        "bash" => {
            let cmd = sanitize_single_line(str_at(args, "command").unwrap_or("..."));
            let shown = if expanded {
                cmd
            } else {
                truncate(&cmd, COMPACT_CHARS)
            };
            let timeout = u64_at(args, "timeout_ms")
                .map(|ms| format!(" (timeout {})", format_duration(ms)))
                .unwrap_or_default();
            format!("$ {shown}{timeout}")
        }
        "search_history" => format!(
            "{sname} \"{}\"",
            truncate(
                &sanitize_single_line(str_at(args, "query").unwrap_or("")),
                COMPACT_CHARS
            )
        ),
        "subagent" => {
            let mode = sanitize_single_line(str_at(args, "mode").unwrap_or("wait"));
            let target = str_at(args, "title")
                .or_else(|| str_at(args, "session_id"))
                .or_else(|| str_at(args, "prompt"))
                .map(sanitize_single_line)
                .map(|s| {
                    if expanded {
                        s
                    } else {
                        truncate(&s, COMPACT_CHARS)
                    }
                });
            let mut parts = vec![sname, mode];
            if let Some(t) = target.filter(|s| !s.is_empty()) {
                parts.push(t);
            }
            if args.get("read_only").and_then(Value::as_bool) == Some(true) {
                parts.push("[read-only]".to_string());
            }
            if let Some(cwd) = str_at(args, "cwd") {
                let clean_cwd = sanitize_single_line(cwd);
                let shown_cwd = if expanded {
                    clean_cwd
                } else {
                    truncate(&clean_cwd, 48)
                };
                parts.push(format!("[cwd: {shown_cwd}]"));
            }
            parts.join(" ")
        }
        _ if obj.is_empty() || expanded => sname,
        _ => {
            let pairs: Vec<String> = obj
                .iter()
                .map(|(k, v)| {
                    let vs = match v {
                        Value::String(s) => format!("\"{}\"", sanitize_single_line(s)),
                        other => sanitize_single_line(&other.to_string()),
                    };
                    format!("{}={vs}", sanitize_single_line(k))
                })
                .collect();
            format!("{sname} {}", truncate(&pairs.join(" "), COMPACT_CHARS))
        }
    }
}

fn render_expanded_args(out: &mut Vec<StyledRow>, name: &str, args: &Value, theme: &Theme) {
    let Some(obj) = args.as_object() else {
        return;
    };
    if name == "edit" {
        if let Some(edits) = obj.get("edits").and_then(Value::as_array) {
            for (idx, edit) in edits.iter().enumerate() {
                out.push(StyledRow::plain(
                    format!("  hunk #{}:", idx + 1),
                    theme.diff_hunk,
                ));
                push_lines_styled(
                    out,
                    str_at(edit, "old_text").unwrap_or(""),
                    "  - ",
                    theme.diff_remove,
                );
                push_lines_styled(
                    out,
                    str_at(edit, "new_text").unwrap_or(""),
                    "  + ",
                    theme.diff_add,
                );
            }
        }
        return;
    }

    for (k, v) in obj {
        let skip = matches!(
            (name, k.as_str()),
            ("read", "path" | "offset" | "limit")
                | ("write", "path")
                | ("bash", "command" | "timeout_ms")
                | ("search_history", "query")
        );
        if skip {
            continue;
        }
        if name == "write" && k == "content" {
            if let Some(s) = v.as_str() {
                out.push(StyledRow::plain(
                    format!("  content ({} bytes):", s.len()),
                    theme.tool_meta,
                ));
                push_lines_styled(out, s, "    ", theme.tool_output);
            }
            continue;
        }
        let val = match v {
            Value::String(s) => s.clone(),
            other => serde_json::to_string_pretty(other).unwrap_or_else(|_| other.to_string()),
        };
        push_lines_styled(
            out,
            &val,
            &format!("  {}: ", sanitize_single_line(k)),
            theme.tool_output,
        );
    }
}

fn format_duration(ms: u64) -> String {
    if ms < 1_000 {
        format!("{ms}ms")
    } else if ms < 60_000 {
        format!("{:.1}s", ms as f64 / 1000.0)
    } else {
        let secs = ms / 1_000;
        format!("{}m {}s", secs / 60, secs % 60)
    }
}

fn collect_live_tools<'a>(
    state: &'a TranscriptState,
    committed_result_ids: &HashSet<&str>,
) -> Vec<(String, &'a Map<String, Value>)> {
    let Some(Value::Object(map)) = state.live_doc().and_then(|l| l.get("tools")) else {
        return Vec::new();
    };
    let last_order: HashMap<&str, usize> = state
        .entries
        .iter()
        .rev()
        .find(|e| e.kind == "assistant")
        .map(|e| {
            tool_calls_of(&e.data)
                .into_iter()
                .enumerate()
                .filter_map(|(i, (cid, _, _))| cid.map(|id| (id, i)))
                .collect()
        })
        .unwrap_or_default();

    let mut slots: Vec<(String, &Map<String, Value>)> = map
        .iter()
        .filter_map(|(k, v)| {
            let obj = v.as_object()?;
            let id = obj.get("id").and_then(Value::as_str).unwrap_or(k.as_str());
            (!committed_result_ids.contains(id)).then(|| (id.to_string(), obj))
        })
        .collect();

    slots.sort_by(|(a, _), (b, _)| {
        match (last_order.get(a.as_str()), last_order.get(b.as_str())) {
            (Some(ia), Some(ib)) => ia.cmp(ib),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => a.cmp(b),
        }
    });
    slots
}

fn render_live(
    out: &mut Vec<StyledRow>,
    state: &TranscriptState,
    calls_by_id: &HashMap<&str, (&str, &Value)>,
    live_tools: &[(String, &Map<String, Value>)],
    tools_expanded: bool,
    thinking_expanded: bool,
    theme: &Theme,
) {
    let Some(live) = state.live_doc() else {
        return;
    };
    if let Some(wait) = state.workspace_wait() {
        separate(out);
        out.push(StyledRow::plain(
            sanitize_single_line(&format!(
                "[waiting for workspace · held by {}:{} · /workspace for actions]",
                wait.holder_session_id, wait.holder_conversation_id
            )),
            theme.tool_running,
        ));
    }
    if let Some(approvals) = live.get("approvals").and_then(Value::as_object) {
        let mut items: Vec<(&str, &Value)> =
            approvals.iter().map(|(k, v)| (k.as_str(), v)).collect();
        items.sort_by(
            |(a, _), (b, _)| match (a.parse::<u64>(), b.parse::<u64>()) {
                (Ok(na), Ok(nb)) => na.cmp(&nb),
                _ => a.cmp(b),
            },
        );
        for (key_tid, rec) in items {
            let tid = str_at(rec, "task_id").unwrap_or(key_tid);
            let tool_name = str_at(rec, "tool_name").unwrap_or("tool");
            let args = rec.get("arguments").unwrap_or(&Value::Null);
            let summary = tool_summary(tool_name, args, tools_expanded);
            separate(out);
            out.push(StyledRow::from_spans(vec![
                StyledSpan::new(
                    sanitize_single_line(&format!("[approval required · #{tid}] ")),
                    theme.tool_running,
                ),
                StyledSpan::new(sanitize_single_line(&summary), theme.tool_header),
            ]));
            if let Some(cwd) = str_at(rec, "cwd").filter(|c| !c.is_empty()) {
                out.push(StyledRow::plain(
                    format!("  cwd: {}", sanitize_single_line(cwd)),
                    theme.tool_meta,
                ));
            }
            out.push(StyledRow::plain(
                sanitize_single_line(&format!("  Use /approve {tid} or /deny {tid} [reason]")),
                theme.tool_meta,
            ));
        }
    }
    let turn_tag = live
        .get("run")
        .and_then(|r| u64_at(r, "turns"))
        .map(|t| format!(" · turn {t}"))
        .unwrap_or_default();

    let inf_wait = state.inference_wait();
    let inf_waiting = inf_wait.and_then(|w| str_at(w, "status")) == Some("waiting");
    if let Some(wait) = inf_wait {
        separate(out);
        let title = str_at(wait, "title").unwrap_or("Waiting to continue");
        let code = str_at(wait, "code");
        let header = match code {
            Some(c) if !c.is_empty() => format!("[{title} · {c}]"),
            _ => format!("[{title}]"),
        };
        out.push(StyledRow::plain(
            sanitize_single_line(&header),
            theme.tool_running,
        ));
        if let Some(message) = str_at(wait, "message").filter(|m| !m.is_empty()) {
            out.push(StyledRow::plain(
                format!("  {}", sanitize_single_line(message)),
                theme.tool_meta,
            ));
        }
        let phase = if inf_waiting {
            match str_at(wait, "detail").filter(|d| !d.is_empty()) {
                Some(detail) => format!("  {} · Esc to abort", sanitize_single_line(detail)),
                None => "  Waiting in background · Esc to abort".to_string(),
            }
        } else {
            "  Rechecking availability · Esc to abort".to_string()
        };
        out.push(StyledRow::plain(phase, theme.tool_meta));
    }

    let retry = state.inference_retry();
    let waiting = retry.and_then(|r| str_at(r, "status")) == Some("waiting");
    if let Some(retry) = retry {
        separate(out);
        let attempt = u64_at(retry, "attempt").unwrap_or(0);
        let limit = u64_at(retry, "max_attempts").unwrap_or(0);
        let code = str_at(retry, "code").unwrap_or("provider_error");
        let message = str_at(retry, "message").unwrap_or("Provider request failed");
        out.push(StyledRow::plain(
            sanitize_single_line(&format!(
                "[Retrying after provider error {attempt}/{limit} · {code}]"
            )),
            theme.tool_running,
        ));
        out.push(StyledRow::plain(
            format!("  {}", sanitize_single_line(message)),
            theme.tool_meta,
        ));
        let phase = if waiting {
            let seconds = u64_at(retry, "delay_ms").unwrap_or(0).div_ceil(1000);
            format!("  Waiting {seconds}s before retry · Esc to abort")
        } else {
            "  Retry request in progress · Esc to abort".into()
        };
        out.push(StyledRow::plain(phase, theme.tool_meta));
    }

    if let Some(gen) = live
        .get("generation")
        .and_then(Value::as_object)
        .filter(|_| !waiting && !inf_waiting)
    {
        separate(out);
        out.push(StyledRow::from_spans(vec![
            StyledSpan::new("[assistant ", theme.assistant_header),
            StyledSpan::new(format!("(live{turn_tag})"), theme.tool_meta),
            StyledSpan::new("]", theme.assistant_header),
        ]));
        let msg = gen.get("message").and_then(Value::as_object).unwrap_or(gen);
        let msg_val = Value::Object(msg.clone());
        let has_body = render_blocks(
            out,
            &msg_val,
            tools_expanded,
            thinking_expanded,
            true,
            false,
            theme,
        );
        let tcs = tool_calls_of(&msg_val);
        for (cid, name, args) in &tcs {
            let summary = tool_summary(name, args, tools_expanded);
            let id_tag = cid
                .map(|c| format!(" ({})", sanitize_single_line(c)))
                .unwrap_or_default();
            out.push(StyledRow::from_spans(vec![
                StyledSpan::new("  -> tool_call ", theme.tool_meta),
                StyledSpan::new(sanitize_single_line(&summary), theme.tool_header),
                StyledSpan::new(sanitize_single_line(&id_tag), theme.tool_meta),
            ]));
        }
        if !has_body && tcs.is_empty() {
            out.push(StyledRow::plain("  ... streaming", theme.tool_meta));
        }
    }

    for (call_id, slot) in live_tools {
        separate(out);
        let paired = calls_by_id.get(call_id.as_str()).copied();
        let name = slot
            .get("name")
            .and_then(Value::as_str)
            .or_else(|| paired.map(|(n, _)| n))
            .unwrap_or("tool");
        let empty = Value::Null;
        let args = paired.map(|(_, a)| a).unwrap_or(&empty);
        let status = slot
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("pending");

        let summary = tool_summary(name, args, tools_expanded);
        let mut live_spans = vec![
            StyledSpan::new("[tool (", theme.tool_header),
            StyledSpan::new(
                sanitize_single_line(&format!("live · {status}")),
                theme.tool_running,
            ),
        ];
        if name == "subagent" {
            if let Some(child_sid) = slot
                .get("child_session_id")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            {
                live_spans.push(StyledSpan::new(
                    sanitize_single_line(&format!(" · session {child_sid}")),
                    theme.tool_meta,
                ));
            }
        }
        live_spans.push(StyledSpan::new(")] ", theme.tool_header));
        live_spans.push(StyledSpan::new(
            sanitize_single_line(&summary),
            theme.tool_header,
        ));
        out.push(StyledRow::from_spans(live_spans));

        let partial = slot.get("output").and_then(Value::as_str).unwrap_or("");
        if !partial.trim_end().is_empty() {
            if tools_expanded {
                push_preview(out, partial, EXPANDED_OUTPUT_LINES, false, "lines", theme);
            } else {
                push_preview(out, partial, PREVIEW_LINES, true, "lines", theme);
            }
        }
    }

    if let Some(shell) = live.get("user_shell").and_then(Value::as_object) {
        separate(out);
        let cmd = shell.get("command").and_then(Value::as_str).unwrap_or("");
        let status = shell
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("running");
        let include = shell
            .get("include_in_context")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let prefix = if include { "!" } else { "!!" };
        let ctx_tag = if include { "" } else { " · excluded" };
        out.push(StyledRow::from_spans(vec![
            StyledSpan::new("[shell (", theme.shell_header),
            StyledSpan::new(
                sanitize_single_line(&format!("live · {status}{ctx_tag}")),
                theme.tool_running,
            ),
            StyledSpan::new(
                sanitize_single_line(&format!(")] {prefix}{cmd}")),
                theme.shell_header,
            ),
        ]));
        let partial = shell.get("output").and_then(Value::as_str).unwrap_or("");
        if !partial.trim_end().is_empty() {
            if tools_expanded {
                push_preview(out, partial, EXPANDED_OUTPUT_LINES, false, "lines", theme);
            } else {
                push_preview(out, partial, PREVIEW_LINES, true, "lines", theme);
            }
        }
    }
}

fn render_inbox(out: &mut Vec<StyledRow>, state: &TranscriptState, theme: &Theme) {
    let Some(inbox) = state.docs.get("inbox").and_then(Value::as_array) else {
        return;
    };
    if inbox.is_empty() {
        return;
    }
    separate(out);
    out.push(StyledRow::plain(
        format!("[queued ({})]", inbox.len()),
        theme.queued_header,
    ));
    for item in inbox {
        let mode = str_at(item, "when_busy")
            .map(|m| format!("[{}] ", sanitize_single_line(m)))
            .unwrap_or_default();
        let mut lines = Vec::new();
        render_blocks(&mut lines, item, false, false, false, false, theme);
        let preview = if lines.is_empty() {
            truncate(&sanitize_single_line(&item.to_string()), COMPACT_CHARS)
        } else {
            let joined: Vec<String> = lines.iter().map(StyledRow::plain_text).collect();
            truncate(&sanitize_single_line(&joined.join(" ")), COMPACT_CHARS)
        };
        out.push(StyledRow::from_spans(vec![
            StyledSpan::new(format!("  {mode}"), theme.queued_header),
            StyledSpan::new(preview, theme.tool_output),
        ]));
    }
}

fn render_failure(out: &mut Vec<StyledRow>, state: &TranscriptState, theme: &Theme) {
    let Some(fail) = state.run_failure() else {
        return;
    };
    separate(out);
    let label = fail.label();
    let code = fail
        .code
        .as_deref()
        .filter(|c| !c.is_empty() && *c != fail.reason)
        .map(|c| format!(" ({})", sanitize_single_line(c)))
        .unwrap_or_default();
    out.push(StyledRow::plain(
        format!("[! {label}: {}{code}]", sanitize_single_line(&fail.reason)),
        theme.failure_header,
    ));
    if let Some(msg) = fail.message.as_deref().filter(|m| !m.trim().is_empty()) {
        push_lines_styled(out, msg.trim(), "  ", theme.failure_text);
    }
    out.push(StyledRow::plain(
        if fail.is_compaction && !fail.automatic {
            "  History preserved. Use /compact to retry."
        } else if fail.reason == "budget_exceeded" {
            "  Budget limit reached. Use /budget off or /budget turns=N, then /continue to resume."
        } else {
            "  Use /continue to resume."
        },
        theme.tool_meta,
    ));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{CommitFrame, EphemeralFrame, SnapshotFrame};
    use crate::transcript::CommitOutcome;
    use serde_json::json;

    fn make_entry(id: &str, kind: &str, data: Value) -> TranscriptEntry {
        TranscriptEntry {
            id: id.to_string(),
            conversation_id: Some("1".to_string()),
            seq: None,
            kind: kind.to_string(),
            data,
            created_at: None,
        }
    }

    fn assert_clean_rows(rows: &[String]) {
        for (idx, row) in rows.iter().enumerate() {
            assert!(!row.contains('\x1b'), "row {idx} has ESC: {row:?}");
            assert!(!row.contains('\r'), "row {idx} has CR: {row:?}");
            assert!(!row.contains('\n'), "row {idx} has LF: {row:?}");
            assert!(!row.contains('\t'), "row {idx} has TAB: {row:?}");
            for ch in row.chars() {
                assert!(
                    !('\x00'..='\x1f').contains(&ch)
                        && ch != '\x7f'
                        && !('\u{0080}'..='\u{009f}').contains(&ch),
                    "row {idx} has control char {ch:?}: {row:?}"
                );
            }
        }
    }

    #[test]
    fn empty_state_returns_empty_rows() {
        assert!(rows(&TranscriptState::default(), false, false).is_empty());
    }

    #[test]
    fn sanitizes_ansi_osc_c0_c1_cr_and_newlines_across_all_surfaces() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: Some("s1".to_string()),
            conversation_id: Some("1".to_string()),
            seq: 5,
            before_entry_id: Some("1\x1b[31m\nspoof".to_string()),
            has_more: Some(true),
            entries: vec![
                make_entry(
                    "2",
                    "user",
                    json!({"content": [{"type": "text", "text": "hi\x1b[31mred\x1b]0;pwn\x07\r\nline2\ttab\u{009b}2J"}]}),
                ),
                make_entry(
                    "3",
                    "assistant",
                    json!({
                        "content": [
                            {"type": "thinking", "text": "think\x1b[2J\x7f"},
                            {"type": "text", "text": "ans\rspoof"}
                        ],
                        "tool_calls": [
                            {"id": "c1", "name": "bash\nfake", "arguments": {"command": "echo \x1b[33mhi"}}
                        ]
                    }),
                ),
                make_entry(
                    "4",
                    "tool_result",
                    json!({
                        "tool_call_id": "c1",
                        "name": "bash\nfake",
                        "content": [{"type": "text", "text": "out\x1b[0m\u{0085}done"}],
                        "is_error": true,
                        "diagnostic": "exit\n_code"
                    }),
                ),
            ],
            docs: Some(json!({
                "live": {
                    "run": {"turns": 1},
                    "generation": {
                        "message": {"thinking": "live_t\x1b[1m", "text": "live_txt\x07"}
                    },
                    "tools": {
                        "c2": {"id": "c2", "name": "read\x1b[31m", "status": "running\nspoof", "output": "chunk\x1b[2K\r"}
                    },
                    "run_failure": {"reason": "model\n_error", "code": "500\x1b", "message": "bad\x1b[31merr"}
                },
                "inbox": [
                    {"submission_id": "9", "when_busy": "steer\nspoof", "content": [{"type": "text", "text": "queued\x1b[0m"}]}
                ]
            })),
        });

        for &(tools_exp, think_exp) in &[(false, false), (true, true)] {
            let rendered = rows(&state, tools_exp, think_exp);
            assert_clean_rows(&rendered);
            let joined = rendered.join("\n");
            assert!(joined.contains("\\x1b[31m"));
            assert!(joined.contains("\\x07"));
            assert!(joined.contains("\\rspoof"));
            assert!(joined.contains("\\u{009b}"));
        }
    }

    #[test]
    fn thinking_toggle_collapses_and_expands_committed_and_live() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            seq: 2,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![make_entry(
                "1",
                "assistant",
                json!({
                    "content": [
                        {"type": "thinking", "text": "step 1\nstep 2"},
                        {"type": "text", "text": "Final answer"}
                    ]
                }),
            )],
            docs: Some(json!({
                "live": {
                    "run": {"turns": 2},
                    "generation": {"message": {"thinking": "live step", "text": "partial"}}
                }
            })),
        });

        let collapsed = rows(&state, false, false).join("\n");
        assert!(collapsed.contains("[thinking · 2 lines (collapsed)]"));
        assert!(!collapsed.contains("step 1"));
        assert!(collapsed.contains("[thinking (streaming · 1 lines, collapsed)]"));
        assert!(!collapsed.contains("live step"));

        let expanded = rows(&state, false, true).join("\n");
        assert!(expanded.contains("  | step 1"));
        assert!(expanded.contains("  | step 2"));
        assert!(expanded.contains("  | live step"));
    }

    #[test]
    fn tool_call_and_result_pair_and_live_tools_never_duplicate() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            seq: 10,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![make_entry(
                "10",
                "assistant",
                json!({
                    "content": [{"type": "text", "text": "Checking files."}],
                    "tool_calls": [
                        {"id": "call_1", "name": "read", "arguments": {"path": "src/main.rs", "offset": 10, "limit": 20}},
                        {"id": "call_2", "name": "bash", "arguments": {"command": "cargo test"}}
                    ]
                }),
            )],
            docs: Some(json!({
                "live": {
                    "run": {"turns": 1},
                    "tools": {
                        "call_1": {"id": "call_1", "name": "read", "status": "running", "output": ""},
                        "call_2": {"id": "call_2", "name": "bash", "status": "pending", "output": ""}
                    }
                }
            })),
        });

        let live_text = rows(&state, false, false).join("\n");
        assert_eq!(live_text.matches("src/main.rs:10-29").count(), 1);
        assert_eq!(live_text.matches("$ cargo test").count(), 1);
        assert!(live_text.contains("[tool (live · running)] read src/main.rs:10-29"));
        assert!(live_text.contains("[tool (live · pending)] $ cargo test"));

        let commit = CommitFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            prev_seq: Some(10),
            seq: 11,
            appended_entries: vec![make_entry(
                "11",
                "tool_result",
                json!({
                    "tool_call_id": "call_1",
                    "name": "read",
                    "content": [{"type": "text", "text": "10: fn main() {}"}],
                    "details": {"path": "src/main.rs", "start_line": 10, "lines_read": 1, "has_more": false},
                    "is_error": false,
                    "duration_ms": 14
                }),
            )],
            doc_ops: Some(
                json!({"live": [["set", ["tools", "call_1", "status"], "done"], ["set", ["tools", "call_2", "status"], "running"]]})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        };
        assert!(matches!(
            state.apply_commit(commit),
            CommitOutcome::Applied { .. }
        ));

        let mid = rows(&state, false, false).join("\n");
        assert_eq!(mid.matches("src/main.rs:10-29").count(), 1);
        assert!(mid.contains("[tool #11 · ok · 1 lines · 14ms] read src/main.rs:10-29"));
        assert!(!mid.contains("fn main()"));
        assert!(mid.contains("[tool (live · running)] $ cargo test"));

        assert!(rows(&state, true, false)
            .join("\n")
            .contains("  10: fn main() {}"));
    }

    #[test]
    fn failed_edit_remains_legible_when_collapsed_and_expands_hunks() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            seq: 3,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![
                make_entry(
                    "1",
                    "assistant",
                    json!({
                        "content": [],
                        "tool_calls": [{
                            "id": "e1",
                            "name": "edit",
                            "arguments": {"path": "src/lib.rs", "edits": [{"old_text": "foo", "new_text": "bar"}]}
                        }]
                    }),
                ),
                make_entry(
                    "2",
                    "tool_result",
                    json!({
                        "tool_call_id": "e1",
                        "name": "edit",
                        "content": [{"type": "text", "text": "Edit 0 old_text was not found in \"foo\"."}],
                        "details": {"index": 0},
                        "is_error": true,
                        "diagnostic": "old_text_not_found",
                        "duration_ms": 5
                    }),
                ),
            ],
            docs: None,
        });

        let collapsed = rows(&state, false, false).join("\n");
        assert!(collapsed.contains("[tool #2 · ! ERROR: old_text_not_found · 5ms] edit src/lib.rs"));
        assert!(collapsed.contains("Edit 0 old_text was not found"));

        let expanded = rows(&state, true, false).join("\n");
        assert!(expanded.contains("  hunk #1:\n  - foo\n  + bar"));
    }

    #[test]
    fn bash_tail_preview_truncation_images_compaction_inbox_and_failures() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            seq: 8,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![
                make_entry(
                    "1",
                    "user",
                    json!({
                        "content": [
                            {"type": "text", "text": "Check"},
                            {"type": "image", "mime_type": "image/png", "data": "AAAA".repeat(200)},
                            {"type": "custom_widget", "data": "B".repeat(500)}
                        ]
                    }),
                ),
                make_entry(
                    "2",
                    "tool_result",
                    json!({
                        "tool_call_id": "b1",
                        "name": "bash",
                        "content": [{"type": "text", "text": "l1\nl2\nl3\nl4\nl5\nl6\nl7"}],
                        "details": {"exit_code": 1, "truncated": true, "skipped_bytes": 1200, "full_output_path": "/tmp/full.log"},
                        "is_error": true,
                        "diagnostic": "exit_code",
                        "duration_ms": 2300
                    }),
                ),
                make_entry(
                    "3",
                    "compaction",
                    json!({"summary": "Summary 1\nSummary 2", "tokens_before": 42000}),
                ),
                make_entry(
                    "4",
                    "assistant",
                    json!({
                        "content": [{"type": "text", "text": "partial"}],
                        "tool_calls": [{"id": "orphan_1", "name": "write", "arguments": {"path": "x.txt"}}],
                        "aborted": true
                    }),
                ),
            ],
            docs: Some(json!({
                "live": {
                    "tools": {
                        "b2": {"id": "b2", "name": "bash", "status": "running", "output": "a\nb\nc\nd\ne\nf\ng"}
                    },
                    "compaction_failure": {"reason": "context_too_large", "code": "413", "message": "Exceeded"}
                },
                "inbox": [
                    {"submission_id": "10", "when_busy": "follow_up", "content": [{"type": "text", "text": "next"}]}
                ]
            })),
        });

        let collapsed = rows(&state, false, false);
        assert_clean_rows(&collapsed);
        let text = collapsed.join("\n");
        assert!(text.contains("[image: image/png ~600 bytes]"));
        assert!(!text.contains(&"AAAA".repeat(20)));
        assert!(text.contains("[block custom_widget]"));
        assert!(text.contains("[tool #2 · ! ERROR: exit_code · exit 1 · 2.3s]"));
        assert!(text.contains("[compaction #3 · compacted from 42000 tokens]"));
        assert!(text.contains("[assistant #4 · aborted]"));
        assert!(text.contains("[tool write x.txt (orphan_1) · no result]"));
        assert!(text.contains("  ... (2 earlier lines)\n  c\n  d\n  e\n  f\n  g"));
        assert!(text.contains("[queued (1)]\n  [follow_up] next"));
        assert!(text.contains("[! Compaction failed: context_too_large (413)]\n  Exceeded\n  History preserved. Use /compact to retry."));

        let expanded = rows(&state, true, true).join("\n");
        assert_clean_rows(&rows(&state, true, true));
        assert!(expanded.contains("1200 bytes omitted · full output: /tmp/full.log"));
        assert!(expanded.contains("  Summary 1\n  Summary 2"));
        assert!(expanded.contains("<omitted 500 chars>"));
    }

    #[test]
    fn automatic_compaction_failure_explains_the_pause_without_repeating_the_code() {
        let mut state = TranscriptState::default();
        state.docs.insert(
            "live".into(),
            json!({"compaction_failure": {
                "reason": "codex_pool_alias_mismatch",
                "code": "codex_pool_alias_mismatch",
                "message": "Update the pool sources in extensions.json",
                "automatic": true
            }}),
        );

        let text = rows(&state, false, false).join("\n");
        assert!(
            text.contains("[! Run paused during automatic compaction: codex_pool_alias_mismatch]")
        );
        assert!(text.contains("Update the pool sources in extensions.json"));
    }

    #[test]
    fn retries_explain_backoff_without_implying_streaming_or_failure() {
        for kind in ["generation", "compaction"] {
            let mut state = TranscriptState {
                docs: json!({"live": {kind: {"retry": {
                    "attempt": 1, "max_attempts": 3, "code": "http_429",
                    "message": "Monthly spending cap reached\x1b[31m", "delay_ms": 2000, "status": "waiting"
                }}}}).as_object().unwrap().clone(),
                ..Default::default()
            };
            let text = rows(&state, false, false).join("\n");
            assert!(text.contains("Retrying after provider error 1/3"));
            assert!(text.contains("http_429"));
            assert!(text.contains("Monthly spending cap reached"));
            assert!(text.contains("Waiting 2s before retry"));
            assert!(!text.contains("... streaming"));
            assert!(!text.contains('\x1b'));
            assert!(state.is_run_active());
            state.docs["live"][kind]["retry"]["status"] = json!("running");
            assert!(rows(&state, false, false)
                .join("\n")
                .contains("Retry request in progress"));
        }
    }

    #[test]
    fn ephemeral_streaming_updates_live_rows_then_commit_replaces_with_final_card() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            seq: 1,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![make_entry("1", "user", json!({"content": "hi"}))],
            docs: Some(json!({"live": {"run": {"turns": 1}, "generation": {"message": {"thinking": "", "text": ""}}}})),
        });

        assert!(rows(&state, false, false)
            .join("\n")
            .contains("  ... streaming"));

        state.apply_ephemeral(EphemeralFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            base_seq: 1,
            doc_ops: Some(
                json!({"live": [["append_text", ["generation", "message", "text"], "Hello"]]})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
            ops: None,
        });
        let streaming = rows(&state, false, false).join("\n");
        assert!(streaming.contains("Hello"));
        assert!(!streaming.contains("... streaming"));

        state.apply_commit(CommitFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            prev_seq: Some(1),
            seq: 2,
            appended_entries: vec![make_entry(
                "2",
                "assistant",
                json!({"content": [{"type": "text", "text": "Hello!"}]}),
            )],
            doc_ops: Some(
                json!({"live": [["replace", {}]]})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        });
        let final_view = rows(&state, false, false).join("\n");
        assert!(!final_view.contains("(live"));
        assert!(final_view.contains("[assistant #2]\nHello!"));
    }

    #[test]
    fn long_shell_output_lines_are_clipped_even_when_expanded() {
        let mut state = TranscriptState::default();
        let output = format!("start\n{}\r\nend", "é\x1b".repeat(50_000));
        state.docs.insert(
            "live".into(),
            json!({"user_shell": {"command": "example", "output": output}}),
        );

        for expanded in [false, true] {
            let rendered = rows(&state, expanded, false);
            assert_clean_rows(&rendered);
            assert!(rendered.iter().any(|r| r == "  end"));
            assert!(rendered.iter().any(|r| r.ends_with("[line clipped]")));
            assert!(rendered.iter().all(|r| r.len() < 4096));
        }
    }

    #[test]
    fn user_shell_live_and_committed_cards_sanitize_and_render_results() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            seq: 1,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![],
            docs: Some(json!({
                "live": {
                    "user_shell": {
                        "task_id": "5",
                        "command": "echo \u{001b}[31msecret",
                        "include_in_context": false,
                        "status": "running",
                        "output": "line1\nline2"
                    }
                }
            })),
        });

        let live_rows = rows(&state, false, false);
        assert_clean_rows(&live_rows);
        let live_text = live_rows.join("\n");
        assert!(live_text.contains("[shell (live · running · excluded)] !!echo \\x1b[31msecret"));
        assert!(live_text.contains("  line1\n  line2"));

        state.apply_commit(CommitFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            prev_seq: Some(1),
            seq: 2,
            appended_entries: vec![make_entry(
                "2",
                "user_shell",
                json!({
                    "command": "ls -la",
                    "output": "out1\nout2",
                    "exit_code": 0,
                    "cancelled": false,
                    "truncated": true,
                    "skipped_bytes": 512,
                    "full_output_path": "/tmp/shell.log",
                    "include_in_context": true,
                    "is_error": false,
                    "duration_ms": 120
                }),
            )],
            doc_ops: Some(
                json!({"live": [["replace", {}]]})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        });

        let final_rows = rows(&state, false, false);
        assert_clean_rows(&final_rows);
        let final_text = final_rows.join("\n");
        assert!(final_text.contains("[shell #2 · exit 0 · 120ms] !ls -la"));
        assert!(final_text.contains("  out1\n  out2"));
        assert!(final_text.contains("512 bytes omitted · full output: /tmp/shell.log"));
    }

    #[test]
    fn styled_rows_apply_semantic_card_and_markdown_styles() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            seq: 3,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![
                make_entry("1", "user", json!({"content": "Hello **literal**"})),
                make_entry(
                    "2",
                    "assistant",
                    json!({
                        "content": [
                            {"type": "thinking", "text": "ponder"},
                            {"type": "text", "text": "# Heading\nUse `code` and **bold**"}
                        ],
                        "tool_calls": [
                            {"id": "t1", "name": "edit", "arguments": {"path": "a.rs", "edits": [{"old_text": "a", "new_text": "b"}]}}
                        ]
                    }),
                ),
                make_entry(
                    "3",
                    "tool_result",
                    json!({
                        "tool_call_id": "t1",
                        "name": "edit",
                        "content": [{"type": "text", "text": "done"}],
                        "is_error": false,
                        "duration_ms": 10
                    }),
                ),
            ],
            docs: None,
        });

        let theme = Theme::dark();
        let srows = styled_rows(&state, true, true, &theme);

        // User header + user text accent bar
        assert_eq!(srows[0].plain_text(), "[user #1]");
        assert_eq!(srows[0].spans[0].style, theme.user_header);
        assert_eq!(srows[1].spans[0].text, "▌ ");
        assert_eq!(srows[1].spans[0].style, theme.user_header);
        assert_eq!(srows[1].spans[1].text, "Hello **literal**");
        assert_eq!(srows[1].spans[1].style, theme.user_text);

        // Assistant header, thinking, markdown heading + inline code/bold
        let asst = srows
            .iter()
            .find(|r| r.plain_text() == "[assistant #2]")
            .unwrap();
        assert_eq!(asst.spans[0].style, theme.assistant_header);
        let think = srows
            .iter()
            .find(|r| r.plain_text() == "[thinking]")
            .unwrap();
        assert_eq!(think.spans[0].style, theme.thinking_header);
        let h1 = srows
            .iter()
            .find(|r| r.plain_text() == "# Heading")
            .unwrap();
        assert_eq!(h1.spans[0].style, theme.md_h1);
        let inline_line = srows
            .iter()
            .find(|r| r.plain_text() == "Use code and bold")
            .unwrap();
        assert!(inline_line
            .spans
            .iter()
            .any(|s| s.text == "code" && s.style == theme.md_code_inline));
        assert!(inline_line
            .spans
            .iter()
            .any(|s| s.text == "bold" && s.style == theme.md_bold));

        // Tool ok badge & edit hunk diff colors
        let tool_hdr = srows
            .iter()
            .find(|r| r.plain_text().starts_with("[tool #3 · ok"))
            .unwrap();
        assert!(tool_hdr
            .spans
            .iter()
            .any(|s| s.text == "ok" && s.style == theme.tool_ok));
        let minus = srows.iter().find(|r| r.plain_text() == "  - a").unwrap();
        assert_eq!(minus.spans[0].style, theme.diff_remove);
        let plus = srows.iter().find(|r| r.plain_text() == "  + b").unwrap();
        assert_eq!(plus.spans[0].style, theme.diff_add);
    }

    #[test]
    fn subagent_tool_call_live_waiting_and_result_cards_render_cleanly() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: Some("coord-1".to_string()),
            conversation_id: Some("1".to_string()),
            seq: 5,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![
                make_entry(
                    "1",
                    "assistant",
                    json!({
                        "content": [{"type": "text", "text": "Delegating work."}],
                        "tool_calls": [
                            {
                                "id": "call-live",
                                "name": "subagent",
                                "arguments": {
                                    "mode": "wait",
                                    "title": "Explore\x1b[31m\nRepo",
                                    "prompt": "Find auth routes",
                                    "read_only": true,
                                    "cwd": "/private/tmp/wt-1"
                                }
                            },
                            {
                                "id": "call-done",
                                "name": "subagent",
                                "arguments": {
                                    "mode": "start",
                                    "session_id": "sub-existing",
                                    "prompt": "Check tests"
                                }
                            },
                            {
                                "id": "call-orphan",
                                "name": "subagent",
                                "arguments": {
                                    "prompt": "Inspect\tbuild\nscript"
                                }
                            }
                        ]
                    }),
                ),
                make_entry(
                    "2",
                    "tool_result",
                    json!({
                        "tool_call_id": "call-done",
                        "name": "subagent",
                        "content": [{"type": "text", "text": "All 12 tests passed."}],
                        "is_error": false,
                        "duration_ms": 1500,
                        "details": {
                            "child_session_id": "sub-child-99\x1b[32m",
                            "status": "done",
                            "at_entry_id": "1"
                        }
                    }),
                ),
            ],
            docs: Some(json!({
                "live": {
                    "tools": {
                        "call-live": {
                            "id": "call-live",
                            "name": "subagent",
                            "status": "waiting",
                            "child_session_id": "sub-live-77"
                        }
                    }
                }
            })),
        });

        let plain = rows(&state, false, false);
        assert_clean_rows(&plain);
        let text = plain.join("\n");

        // Orphan call without result renders clean summary (not raw JSON)
        assert!(
            text.contains(r"[tool subagent wait Inspect\tbuild\nscript (call-orphan) · no result]"),
            "{text}"
        );

        // Live waiting subagent shows `live · waiting` and `session sub-live-77` with flags
        assert!(
            text.contains(
                r"[tool (live · waiting · session sub-live-77)] subagent wait Explore\x1b[31m\nRepo [read-only] [cwd: /private/tmp/wt-1]"
            ),
            "{text}"
        );

        // Completed tool_result shows sanitized child_session_id, status, and at_entry_id badge
        assert!(
            text.contains(
                r"[tool #2 · ok · session sub-child-99\x1b[32m · done · @#1 · 1.5s] subagent start sub-existing"
            ),
            "{text}"
        );
        assert!(text.contains("  All 12 tests passed."), "{text}");

        // Live waiting badge uses theme.tool_running
        let theme = Theme::dark();
        let srows = styled_rows(&state, false, false, &theme);
        let live_row = srows
            .iter()
            .find(|r| r.plain_text().contains("sub-live-77"))
            .unwrap();
        assert!(live_row
            .spans
            .iter()
            .any(|s| s.text == "live · waiting" && s.style == theme.tool_running));
    }

    #[test]
    fn inference_wait_live_renders_generic_waiting_and_rechecking_cards() {
        let mut waiting_state = TranscriptState::default();
        waiting_state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: Some("s-wait".to_string()),
            conversation_id: Some("1".to_string()),
            seq: 2,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![],
            docs: Some(json!({
                "live": {
                    "generation": {
                        "message": {"thinking": "", "text": "", "tool_calls": []},
                        "wait": {
                            "status": "waiting",
                            "code": "capacity_waiting",
                            "title": "Waiting for capacity",
                            "message": "Temporarily at capacity; waiting for next available slot.",
                            "detail": "Will continue automatically when ready.",
                            "until": 1_800_000_060_000u64,
                            "resumes_at": 1_800_003_600_000u64
                        }
                    }
                }
            })),
        });

        let waiting_rows = rows(&waiting_state, false, false);
        assert_clean_rows(&waiting_rows);
        let waiting_text = waiting_rows.join("\n");
        assert!(
            waiting_text.contains("[Waiting for capacity · capacity_waiting]"),
            "{waiting_text}"
        );
        assert!(
            waiting_text.contains("Temporarily at capacity; waiting for next available slot."),
            "{waiting_text}"
        );
        assert!(
            waiting_text.contains("Will continue automatically when ready. · Esc to abort"),
            "{waiting_text}"
        );
        assert!(!waiting_text.contains("Retrying after provider error"));
        assert!(!waiting_text.contains("... streaming"));

        let mut running_state = TranscriptState::default();
        running_state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: Some("s-wait".to_string()),
            conversation_id: Some("1".to_string()),
            seq: 3,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![],
            docs: Some(json!({
                "live": {
                    "generation": {
                        "message": {"thinking": "", "text": "", "tool_calls": []},
                        "wait": {
                            "status": "running",
                            "code": "capacity_waiting",
                            "title": "Waiting for capacity",
                            "message": "Checking readiness",
                            "until": 1_800_000_060_000u64
                        }
                    }
                }
            })),
        });

        let running_text = rows(&running_state, false, false).join("\n");
        assert!(
            running_text.contains("Rechecking availability · Esc to abort"),
            "{running_text}"
        );
    }

    #[test]
    fn content_filtered_and_empty_assistant_entries_render_explicit_notices() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: Some("s-filter".to_string()),
            conversation_id: Some("1".to_string()),
            seq: 3,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![
                make_entry(
                    "1",
                    "assistant",
                    json!({
                        "content": [],
                        "tool_calls": [],
                        "finish_reason": "content_filter",
                        "provider_meta": {
                            "finish_reason_raw": "PROHIBITED_CONTENT",
                            "finish_message": "The model output could not be generated."
                        }
                    }),
                ),
                make_entry(
                    "2",
                    "assistant",
                    json!({
                        "content": [],
                        "tool_calls": [],
                        "finish_reason": "stop"
                    }),
                ),
            ],
            docs: None,
        });

        let rendered = rows(&state, false, false);
        assert_clean_rows(&rendered);
        let text = rendered.join("\n");
        assert!(text.contains("[assistant #1 · filtered]"), "{text}");
        assert!(
            text.contains("! Output blocked by content filter (PROHIBITED_CONTENT): The model output could not be generated."),
            "{text}"
        );
        assert!(
            text.contains("! Empty assistant response (no text or tool calls)"),
            "{text}"
        );
    }

    #[test]
    fn live_approvals_and_budget_exceeded_hint_render_cleanly() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: Some("s-app".to_string()),
            conversation_id: Some("1".to_string()),
            seq: 4,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![],
            docs: Some(json!({
                "live": {
                    "approvals": {
                        "42": {
                            "task_id": "42",
                            "call_id": "call_42",
                            "tool_name": "bash",
                            "arguments": {"command": "rm -rf /tmp/x\x1b[31m"},
                            "cwd": "/tmp/proj\nline"
                        }
                    },
                    "run_failure": {
                        "reason": "budget_exceeded",
                        "message": "Run paused: turn budget (2/2) reached."
                    }
                }
            })),
        });

        let rendered = rows(&state, false, false);
        assert_clean_rows(&rendered);
        let text = rendered.join("\n");
        assert!(
            text.contains(r"[approval required · #42] $ rm -rf /tmp/x\x1b[31m"),
            "{text}"
        );
        assert!(text.contains(r"cwd: /tmp/proj\nline"), "{text}");
        assert!(
            text.contains("Use /approve 42 or /deny 42 [reason]"),
            "{text}"
        );
        assert!(
            text.contains("Use /budget off or /budget turns=N, then /continue to resume."),
            "{text}"
        );
    }
}
