use crate::protocol::TranscriptEntry;
use crate::render::{sanitize_single_line, sanitize_terminal_text};
use crate::transcript::TranscriptState;
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
    let mut out = Vec::new();

    if state.has_more {
        let before = state
            .before_entry_id
            .as_deref()
            .filter(|s| !s.is_empty())
            .map(|id| format!(" (before #{})", sanitize_single_line(id)))
            .unwrap_or_default();
        out.push(format!("... earlier history available{before}"));
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
        );
    }

    render_live(
        &mut out,
        state,
        &calls_by_id,
        &live_tools,
        tools_expanded,
        thinking_expanded,
    );
    render_inbox(&mut out, state);
    render_failure(&mut out, state);

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

fn separate(out: &mut Vec<String>) {
    if !out.is_empty() {
        out.push(String::new());
    }
}

fn push_lines(out: &mut Vec<String>, raw: &str, prefix: &str) {
    let safe = sanitize_terminal_text(raw).replace('\t', "   ");
    for line in safe.split('\n') {
        out.push(format!("{prefix}{line}"));
    }
}

fn push_preview(out: &mut Vec<String>, raw: &str, max_lines: usize, tail: bool, label: &str) {
    // Pick the rows before sanitizing, and clip before wrapping. A single
    // newline-free stdout line can otherwise dominate the entire redraw.
    let lines = raw.trim_end().lines();
    let omitted = lines.clone().count().saturating_sub(max_lines);
    if tail && omitted > 0 {
        out.push(format!("  ... ({omitted} earlier lines)"));
    }
    for line in lines.skip(if tail { omitted } else { 0 }).take(max_lines) {
        let end = line.floor_char_boundary(OUTPUT_LINE_BYTES);
        let safe = sanitize_terminal_text(&line[..end]).replace('\t', "   ");
        let clipped = if end < line.len() {
            " ... [line clipped]"
        } else {
            ""
        };
        out.push(format!("  {safe}{clipped}"));
    }
    if !tail && omitted > 0 {
        out.push(format!("  ... ({omitted} more {label})"));
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

fn render_entry(
    out: &mut Vec<String>,
    entry: &TranscriptEntry,
    calls_by_id: &HashMap<&str, (&str, &Value)>,
    result_ids: &HashSet<&str>,
    live_ids: &HashSet<&str>,
    tools_expanded: bool,
    thinking_expanded: bool,
) {
    let id = sanitize_single_line(&entry.id);
    let kind = sanitize_single_line(&entry.kind);

    match entry.kind.as_str() {
        "user" | "system" => {
            out.push(format!("[{kind} #{id}]"));
            render_blocks(out, &entry.data, tools_expanded, thinking_expanded, false);
        }
        "assistant" => {
            let aborted = entry.data.get("aborted").and_then(Value::as_bool) == Some(true);
            let finish = str_at(&entry.data, "finish_reason");
            let tag = match (aborted, finish) {
                (true, _) | (_, Some("aborted")) => " · aborted",
                (_, Some("length")) => " · truncated",
                (_, Some("error")) => " · error",
                _ => "",
            };
            out.push(format!("[assistant #{id}{tag}]"));
            render_blocks(out, &entry.data, tools_expanded, thinking_expanded, false);

            if aborted || finish == Some("aborted") {
                out.push("! Operation aborted".to_string());
            } else if finish == Some("length") {
                out.push("! Response was truncated before completion.".to_string());
            } else if finish == Some("error") {
                out.push("! Error: generation failed".to_string());
            }

            for (cid, name, args) in tool_calls_of(&entry.data) {
                if cid.is_some_and(|c| result_ids.contains(c) || live_ids.contains(c)) {
                    continue;
                }
                let summary = tool_summary(name, args, tools_expanded);
                let id_tag = cid
                    .map(|c| format!(" ({})", sanitize_single_line(c)))
                    .unwrap_or_default();
                out.push(sanitize_single_line(&format!(
                    "[tool {summary}{id_tag} · no result]"
                )));
                if tools_expanded {
                    render_expanded_args(out, name, args);
                }
            }
        }
        "tool_result" => render_tool_result(out, &id, &entry.data, calls_by_id, tools_expanded),
        "user_shell" => render_user_shell(out, &id, &entry.data, tools_expanded),
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
                out.push(prefix);
                if !body.trim().is_empty() {
                    push_lines(out, body.trim(), "  ");
                }
            } else {
                let preview = truncate(&sanitize_single_line(body.trim()), COMPACT_CHARS);
                out.push(if preview.is_empty() {
                    prefix
                } else {
                    format!("{prefix} {preview}")
                });
            }
        }
        _ => {
            out.push(format!("[{kind} #{id}]"));
            if !render_blocks(out, &entry.data, tools_expanded, thinking_expanded, false) {
                let raw = entry.data.to_string();
                if tools_expanded {
                    push_lines(out, &raw, "  ");
                } else {
                    out.push(truncate(&sanitize_single_line(&raw), COMPACT_CHARS));
                }
            }
        }
    }
}

fn render_blocks(
    out: &mut Vec<String>,
    data: &Value,
    tools_expanded: bool,
    thinking_expanded: bool,
    streaming: bool,
) -> bool {
    let Some(obj) = data.as_object() else {
        return false;
    };
    let mut emitted = false;

    if let Some(thinking) = str_at(data, "thinking").filter(|s| !s.trim().is_empty()) {
        render_thinking(out, thinking, streaming, thinking_expanded);
        emitted = true;
    }

    match obj.get("content") {
        Some(Value::String(s)) if !s.is_empty() => {
            push_lines(out, s, "");
            emitted = true;
        }
        Some(Value::Array(blocks)) => {
            for block in blocks {
                if let Some(s) = block.as_str().filter(|s| !s.is_empty()) {
                    push_lines(out, s, "");
                    emitted = true;
                    continue;
                }
                let Some(btype) = str_at(block, "type") else {
                    continue;
                };
                match btype {
                    "text" => {
                        if let Some(t) = str_at(block, "text") {
                            push_lines(out, t, "");
                            emitted = true;
                        }
                    }
                    "thinking" => {
                        if let Some(t) = str_at(block, "thinking").or_else(|| str_at(block, "text"))
                        {
                            if !t.trim().is_empty() {
                                render_thinking(out, t, streaming, thinking_expanded);
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
                        out.push(format!("[image: {}{size}]", sanitize_single_line(mime)));
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
                            out.push(format!("[block {bkind}]"));
                            push_lines(
                                out,
                                &serde_json::to_string_pretty(&scrubbed).unwrap_or_default(),
                                "  ",
                            );
                        } else {
                            let preview = truncate(
                                &sanitize_single_line(&scrubbed.to_string()),
                                COMPACT_CHARS,
                            );
                            out.push(format!("[block {bkind}] {preview}"));
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
            push_lines(out, t, "");
            emitted = true;
        }
    }
    emitted
}

fn render_thinking(out: &mut Vec<String>, raw: &str, streaming: bool, expanded: bool) {
    let safe = sanitize_terminal_text(raw.trim()).replace('\t', "   ");
    let lines: Vec<&str> = safe.split('\n').collect();
    if expanded {
        out.push(if streaming {
            "[thinking (streaming)]".into()
        } else {
            "[thinking]".into()
        });
        for line in lines {
            out.push(format!("  | {line}"));
        }
    } else if streaming {
        out.push(format!(
            "[thinking (streaming · {} lines, collapsed)]",
            lines.len()
        ));
    } else {
        out.push(format!("[thinking · {} lines (collapsed)]", lines.len()));
    }
}

fn render_tool_result(
    out: &mut Vec<String>,
    id: &str,
    data: &Value,
    calls_by_id: &HashMap<&str, (&str, &Value)>,
    tools_expanded: bool,
) {
    let paired = str_at(data, "tool_call_id").and_then(|cid| calls_by_id.get(cid).copied());
    let name = str_at(data, "name")
        .or_else(|| paired.map(|(n, _)| n))
        .unwrap_or("tool");
    let empty = Value::Null;
    let args = paired.map(|(_, a)| a).unwrap_or(&empty);
    let is_error = data.get("is_error").and_then(Value::as_bool) == Some(true);
    let details = data.get("details").unwrap_or(&empty);

    let mut status = vec![if is_error {
        match str_at(data, "diagnostic") {
            Some(d) => format!("! ERROR: {}", sanitize_single_line(d)),
            None => "! ERROR".into(),
        }
    } else {
        "ok".into()
    }];
    if let Some(badge) = tool_badge(name, is_error, details) {
        status.push(badge);
    }
    if let Some(ms) = u64_at(data, "duration_ms") {
        status.push(format_duration(ms));
    }

    let summary = tool_summary(name, args, tools_expanded);
    out.push(sanitize_single_line(&format!(
        "[tool #{id} · {}] {summary}",
        status.join(" · ")
    )));

    if tools_expanded {
        render_expanded_args(out, name, args);
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
            push_preview(out, &text, EXPANDED_OUTPUT_LINES, false, "lines");
        } else if is_error {
            push_preview(out, &text, ERROR_PREVIEW_LINES, false, "error lines");
        } else {
            match name {
                "read" | "write" => {}
                "bash" => push_preview(out, &text, PREVIEW_LINES, true, "lines"),
                _ => push_preview(out, &text, PREVIEW_LINES, false, "lines"),
            }
        }
    }

    if !non_text_blocks.is_empty() {
        let synthetic = Value::Object(Map::from_iter([(
            "content".into(),
            Value::Array(non_text_blocks),
        )]));
        render_blocks(out, &synthetic, tools_expanded, false, false);
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
            out.push(format!("  [{}]", notes.join(" · ")));
        }
    }
}

fn render_user_shell(out: &mut Vec<String>, id: &str, data: &Value, tools_expanded: bool) {
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

    let mut header_parts = vec![format!("shell #{id}")];
    if !include {
        header_parts.push("excluded".to_string());
    }
    if cancelled {
        header_parts.push("aborted".to_string());
    } else if let Some(code) = exit_code {
        if is_error || code != 0 {
            header_parts.push(format!("! exit {code}"));
        } else {
            header_parts.push("exit 0".to_string());
        }
    } else if let Some(diag) = diagnostic {
        header_parts.push(format!("! {}", sanitize_single_line(diag)));
    } else if is_error {
        header_parts.push("! error".to_string());
    } else {
        header_parts.push("ok".to_string());
    }
    if let Some(ms) = u64_at(data, "duration_ms") {
        header_parts.push(format_duration(ms));
    }

    let cmd_clean = sanitize_single_line(command);
    let cmd_shown = if tools_expanded {
        cmd_clean
    } else {
        truncate(&cmd_clean, COMPACT_CHARS)
    };
    out.push(format!(
        "[{}] {prefix}{cmd_shown}",
        header_parts.join(" · ")
    ));

    let output = str_at(data, "output").unwrap_or("");
    if !output.trim_end().is_empty() {
        if tools_expanded {
            push_preview(out, output, EXPANDED_OUTPUT_LINES, false, "lines");
        } else {
            push_preview(out, output, PREVIEW_LINES, true, "lines");
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
        out.push(format!("  [{}]", notes.join(" · ")));
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

fn render_expanded_args(out: &mut Vec<String>, name: &str, args: &Value) {
    let Some(obj) = args.as_object() else {
        return;
    };
    if name == "edit" {
        if let Some(edits) = obj.get("edits").and_then(Value::as_array) {
            for (idx, edit) in edits.iter().enumerate() {
                out.push(format!("  hunk #{}:", idx + 1));
                push_lines(out, str_at(edit, "old_text").unwrap_or(""), "  - ");
                push_lines(out, str_at(edit, "new_text").unwrap_or(""), "  + ");
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
                out.push(format!("  content ({} bytes):", s.len()));
                push_lines(out, s, "    ");
            }
            continue;
        }
        let val = match v {
            Value::String(s) => s.clone(),
            other => serde_json::to_string_pretty(other).unwrap_or_else(|_| other.to_string()),
        };
        push_lines(out, &val, &format!("  {}: ", sanitize_single_line(k)));
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
    out: &mut Vec<String>,
    state: &TranscriptState,
    calls_by_id: &HashMap<&str, (&str, &Value)>,
    live_tools: &[(String, &Map<String, Value>)],
    tools_expanded: bool,
    thinking_expanded: bool,
) {
    let Some(live) = state.live_doc() else {
        return;
    };
    let turn_tag = live
        .get("run")
        .and_then(|r| u64_at(r, "turns"))
        .map(|t| format!(" · turn {t}"))
        .unwrap_or_default();

    if let Some(gen) = live.get("generation").and_then(Value::as_object) {
        separate(out);
        out.push(format!("[assistant (live{turn_tag})]"));
        let msg = gen.get("message").and_then(Value::as_object).unwrap_or(gen);
        let msg_val = Value::Object(msg.clone());
        let has_body = render_blocks(out, &msg_val, tools_expanded, thinking_expanded, true);
        let tcs = tool_calls_of(&msg_val);
        for (cid, name, args) in &tcs {
            let summary = tool_summary(name, args, tools_expanded);
            let id_tag = cid
                .map(|c| format!(" ({})", sanitize_single_line(c)))
                .unwrap_or_default();
            out.push(sanitize_single_line(&format!(
                "  -> tool_call {summary}{id_tag}"
            )));
        }
        if !has_body && tcs.is_empty() {
            out.push("  ... streaming".to_string());
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
        out.push(sanitize_single_line(&format!(
            "[tool (live · {})] {summary}",
            sanitize_single_line(status)
        )));

        let partial = slot.get("output").and_then(Value::as_str).unwrap_or("");
        if !partial.trim_end().is_empty() {
            if tools_expanded {
                push_preview(out, partial, EXPANDED_OUTPUT_LINES, false, "lines");
            } else {
                push_preview(out, partial, PREVIEW_LINES, true, "lines");
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
        out.push(sanitize_single_line(&format!(
            "[shell (live · {status}{ctx_tag})] {prefix}{cmd}"
        )));
        let partial = shell.get("output").and_then(Value::as_str).unwrap_or("");
        if !partial.trim_end().is_empty() {
            if tools_expanded {
                push_preview(out, partial, EXPANDED_OUTPUT_LINES, false, "lines");
            } else {
                push_preview(out, partial, PREVIEW_LINES, true, "lines");
            }
        }
    }
}

fn render_inbox(out: &mut Vec<String>, state: &TranscriptState) {
    let Some(inbox) = state.docs.get("inbox").and_then(Value::as_array) else {
        return;
    };
    if inbox.is_empty() {
        return;
    }
    separate(out);
    out.push(format!("[queued ({})]", inbox.len()));
    for item in inbox {
        let mode = str_at(item, "when_busy")
            .map(|m| format!("[{}] ", sanitize_single_line(m)))
            .unwrap_or_default();
        let mut lines = Vec::new();
        render_blocks(&mut lines, item, false, false, false);
        let preview = if lines.is_empty() {
            truncate(&sanitize_single_line(&item.to_string()), COMPACT_CHARS)
        } else {
            truncate(&sanitize_single_line(&lines.join(" ")), COMPACT_CHARS)
        };
        out.push(format!("  {mode}{preview}"));
    }
}

fn render_failure(out: &mut Vec<String>, state: &TranscriptState) {
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
    out.push(format!(
        "[! {label}: {}{code}]",
        sanitize_single_line(&fail.reason)
    ));
    if let Some(msg) = fail.message.as_deref().filter(|m| !m.trim().is_empty()) {
        push_lines(out, msg.trim(), "  ");
    }
    out.push("  Use /continue to resume.".to_string());
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
        assert!(text.contains("[! Compaction failed: context_too_large (413)]\n  Exceeded\n  Use /continue to resume."));

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
}
