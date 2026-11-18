use crate::protocol::TranscriptEntry;
use crate::render::{sanitize_single_line, sanitize_terminal_text};
use crate::transcript::TranscriptState;
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;

const COLLAPSED_PREVIEW_LINES: usize = 5;
const COLLAPSED_ERROR_LINES: usize = 8;
const COLLAPSED_ARG_CHARS: usize = 80;
const COLLAPSED_CMD_CHARS: usize = 100;

#[derive(Debug, Clone)]
struct ToolCallMeta {
    name: String,
    arguments: Value,
}

#[derive(Debug, Clone)]
struct ExtractedParts {
    thinking: Vec<String>,
    text_blocks: Vec<String>,
    extra_blocks: Vec<ExtraBlock>,
}

#[derive(Debug, Clone)]
enum ExtraBlock {
    Image {
        mime: String,
        approx_bytes: Option<usize>,
        url: Option<String>,
    },
    ImageUrl {
        url: String,
        mime: Option<String>,
    },
    Unknown {
        kind: String,
        payload: Value,
    },
}

/// Renders committed transcript entries, live streaming generation/tools, queued
/// inbox items, and run/compaction failures into sanitized single-line display rows.
///
/// Guarantees no ANSI escape sequences, C0/C1 control characters, `\r`, `\t`, or
/// embedded `\n` appear in any returned row.
pub fn rows(state: &TranscriptState, tools_expanded: bool, thinking_expanded: bool) -> Vec<String> {
    let mut out = Vec::new();

    if state.has_more {
        let cursor_note = state
            .before_entry_id
            .as_deref()
            .filter(|s| !s.is_empty())
            .map(|id| format!(" (before #{})", sanitize_single_line(id)))
            .unwrap_or_default();
        push_single_line(
            &mut out,
            &format!("... earlier history available{cursor_note}"),
        );
    }

    let tool_calls_by_id = collect_tool_calls(&state.entries);
    let committed_result_ids = collect_committed_result_ids(&state.entries);
    let live_tool_ids = collect_live_tool_ids(state);

    for entry in &state.entries {
        if !out.is_empty() {
            out.push(String::new());
        }
        render_entry(
            &mut out,
            entry,
            &tool_calls_by_id,
            &committed_result_ids,
            &live_tool_ids,
            tools_expanded,
            thinking_expanded,
        );
    }

    render_live_section(
        &mut out,
        state,
        &tool_calls_by_id,
        &committed_result_ids,
        tools_expanded,
        thinking_expanded,
    );
    render_inbox_section(&mut out, state);
    render_failure_section(&mut out, state);

    out
}

fn push_single_line(out: &mut Vec<String>, raw: &str) {
    out.push(sanitize_single_line(raw));
}

fn push_multiline_lines(out: &mut Vec<String>, raw: &str, prefix: &str) {
    let safe = sanitize_terminal_text(raw).replace('\t', "   ");
    for line in safe.split('\n') {
        if prefix.is_empty() {
            out.push(line.to_string());
        } else {
            out.push(format!("{prefix}{line}"));
        }
    }
}

fn truncate_chars(s: &str, max_chars: usize) -> String {
    if max_chars == 0 {
        return String::new();
    }
    let count = s.chars().count();
    if count <= max_chars {
        return s.to_string();
    }
    if max_chars <= 3 {
        return s.chars().take(max_chars).collect();
    }
    let mut out: String = s.chars().take(max_chars - 3).collect();
    out.push_str("...");
    out
}

fn collect_tool_calls(entries: &[TranscriptEntry]) -> HashMap<String, ToolCallMeta> {
    let mut map = HashMap::new();
    for entry in entries {
        if entry.kind != "assistant" {
            continue;
        }
        for (id, meta) in parse_tool_calls_from_data(&entry.data) {
            if let Some(call_id) = id {
                map.insert(call_id, meta);
            }
        }
    }
    map
}

fn collect_committed_result_ids(entries: &[TranscriptEntry]) -> HashSet<String> {
    let mut set = HashSet::new();
    for entry in entries {
        if entry.kind == "tool_result" {
            if let Some(call_id) = entry
                .data
                .get("tool_call_id")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            {
                set.insert(call_id.to_string());
            }
        }
    }
    set
}

fn collect_live_tool_ids(state: &TranscriptState) -> HashSet<String> {
    let mut set = HashSet::new();
    let Some(tools) = state.live_doc().and_then(|l| l.get("tools")) else {
        return set;
    };
    match tools {
        Value::Object(map) => {
            for (k, slot) in map {
                let id = slot
                    .as_object()
                    .and_then(|m| m.get("id").or_else(|| m.get("call_id")))
                    .and_then(Value::as_str)
                    .unwrap_or(k.as_str());
                if !id.is_empty() {
                    set.insert(id.to_string());
                }
            }
        }
        Value::Array(items) => {
            for slot in items {
                if let Some(id) = slot
                    .as_object()
                    .and_then(|m| m.get("id").or_else(|| m.get("call_id")))
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                {
                    set.insert(id.to_string());
                }
            }
        }
        _ => {}
    }
    set
}

fn parse_tool_calls_from_data(data: &Value) -> Vec<(Option<String>, ToolCallMeta)> {
    let Some(arr) = data.get("tool_calls").and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|tc| {
            let obj = tc.as_object()?;
            let name = obj
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("tool")
                .to_string();
            let id = obj
                .get("id")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string);
            let raw_args = obj
                .get("arguments")
                .or_else(|| obj.get("args"))
                .or_else(|| obj.get("input"))
                .cloned()
                .unwrap_or_else(|| Value::Object(Map::new()));
            let arguments = normalize_tool_arguments(raw_args);
            Some((id, ToolCallMeta { name, arguments }))
        })
        .collect()
}

fn normalize_tool_arguments(raw: Value) -> Value {
    match raw {
        Value::String(s) => serde_json::from_str::<Value>(&s)
            .ok()
            .filter(|v| v.is_object())
            .unwrap_or(Value::String(s)),
        other => other,
    }
}

fn extract_parts(data: &Value) -> ExtractedParts {
    let mut thinking = Vec::new();
    let mut text_blocks = Vec::new();
    let mut extra_blocks = Vec::new();

    if let Some(obj) = data.as_object() {
        for key in ["thinking", "reasoning"] {
            if let Some(s) = obj.get(key).and_then(Value::as_str) {
                if !s.trim().is_empty() {
                    thinking.push(s.to_string());
                }
            }
        }

        match obj.get("content") {
            Some(Value::String(s)) => {
                if !s.is_empty() {
                    text_blocks.push(s.clone());
                }
            }
            Some(Value::Array(blocks)) => {
                for block in blocks {
                    match block {
                        Value::String(s) => {
                            if !s.is_empty() {
                                text_blocks.push(s.clone());
                            }
                        }
                        Value::Object(map) => {
                            let btype = map.get("type").and_then(Value::as_str).unwrap_or("");
                            match btype {
                                "text" => {
                                    if let Some(t) = map.get("text").and_then(Value::as_str) {
                                        if !t.is_empty() {
                                            text_blocks.push(t.to_string());
                                        }
                                    }
                                }
                                "thinking" | "reasoning" => {
                                    if let Some(t) = map
                                        .get("thinking")
                                        .or_else(|| map.get("text"))
                                        .and_then(Value::as_str)
                                    {
                                        if !t.trim().is_empty() {
                                            thinking.push(t.to_string());
                                        }
                                    }
                                }
                                "image" => {
                                    let mime = map
                                        .get("media_type")
                                        .or_else(|| map.get("mime_type"))
                                        .or_else(|| map.get("mimeType"))
                                        .and_then(Value::as_str)
                                        .unwrap_or("image/unknown")
                                        .to_string();
                                    let approx_bytes = map
                                        .get("data")
                                        .and_then(Value::as_str)
                                        .map(|b64| (b64.len() * 3) / 4);
                                    let url =
                                        map.get("url").and_then(Value::as_str).map(str::to_string);
                                    extra_blocks.push(ExtraBlock::Image {
                                        mime,
                                        approx_bytes,
                                        url,
                                    });
                                }
                                "image_url" => {
                                    let url = map
                                        .get("url")
                                        .and_then(Value::as_str)
                                        .unwrap_or("(missing url)")
                                        .to_string();
                                    let mime = map
                                        .get("media_type")
                                        .or_else(|| map.get("mime_type"))
                                        .and_then(Value::as_str)
                                        .map(str::to_string);
                                    extra_blocks.push(ExtraBlock::ImageUrl { url, mime });
                                }
                                other => {
                                    extra_blocks.push(ExtraBlock::Unknown {
                                        kind: if other.is_empty() {
                                            "block".to_string()
                                        } else {
                                            other.to_string()
                                        },
                                        payload: Value::Object(map.clone()),
                                    });
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }

        if text_blocks.is_empty() {
            if let Some(t) = obj.get("text").and_then(Value::as_str) {
                if !t.is_empty() {
                    text_blocks.push(t.to_string());
                }
            }
        }
    }

    ExtractedParts {
        thinking,
        text_blocks,
        extra_blocks,
    }
}

fn render_extra_blocks(out: &mut Vec<String>, blocks: &[ExtraBlock], expanded: bool) {
    for block in blocks {
        match block {
            ExtraBlock::Image {
                mime,
                approx_bytes,
                url,
            } => {
                let mut desc = format!("[image: {}", sanitize_single_line(mime));
                if let Some(bytes) = approx_bytes {
                    let _ = write!(desc, " ~{} bytes", bytes);
                }
                if let Some(u) = url {
                    let _ = write!(desc, " {}", sanitize_single_line(u));
                }
                desc.push(']');
                out.push(desc);
            }
            ExtraBlock::ImageUrl { url, mime } => {
                let mut desc = format!("[image_url: {}", sanitize_single_line(url));
                if let Some(m) = mime {
                    let _ = write!(desc, " ({})", sanitize_single_line(m));
                }
                desc.push(']');
                out.push(desc);
            }
            ExtraBlock::Unknown { kind, payload } => {
                let safe_kind = sanitize_single_line(kind);
                let redacted = redact_large_binary_fields(payload);
                if expanded {
                    push_single_line(out, &format!("[block {safe_kind}]"));
                    if let Ok(pretty) = serde_json::to_string_pretty(&redacted) {
                        push_multiline_lines(out, &pretty, "  ");
                    }
                } else {
                    let preview = serde_json::to_string(&redacted).unwrap_or_default();
                    let short =
                        truncate_chars(&sanitize_single_line(&preview), COLLAPSED_ARG_CHARS);
                    out.push(format!("[block {safe_kind}] {short}"));
                }
            }
        }
    }
}

fn redact_large_binary_fields(val: &Value) -> Value {
    match val {
        Value::Object(map) => {
            let mut out = Map::new();
            for (k, v) in map {
                if k == "data" {
                    if let Value::String(s) = v {
                        if s.len() > 256 {
                            out.insert(
                                k.clone(),
                                Value::String(format!("<omitted {} chars>", s.len())),
                            );
                            continue;
                        }
                    }
                }
                out.insert(k.clone(), redact_large_binary_fields(v));
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.iter().map(redact_large_binary_fields).collect()),
        other => other.clone(),
    }
}

fn render_entry(
    out: &mut Vec<String>,
    entry: &TranscriptEntry,
    tool_calls_by_id: &HashMap<String, ToolCallMeta>,
    committed_result_ids: &HashSet<String>,
    live_tool_ids: &HashSet<String>,
    tools_expanded: bool,
    thinking_expanded: bool,
) {
    let id = sanitize_single_line(&entry.id);
    let kind = sanitize_single_line(&entry.kind);

    match entry.kind.as_str() {
        "user" | "system" => {
            out.push(format!("[{kind} #{id}]"));
            let parts = extract_parts(&entry.data);
            for t in &parts.text_blocks {
                push_multiline_lines(out, t, "");
            }
            render_extra_blocks(out, &parts.extra_blocks, tools_expanded);
        }
        "assistant" => {
            render_assistant_entry(
                out,
                &id,
                &entry.data,
                committed_result_ids,
                live_tool_ids,
                tools_expanded,
                thinking_expanded,
            );
        }
        "tool_result" => {
            render_tool_result_entry(out, &id, &entry.data, tool_calls_by_id, tools_expanded);
        }
        "compaction" | "reset" | "handoff" => {
            render_marker_entry(out, &id, &kind, &entry.data, tools_expanded);
        }
        _ => {
            out.push(format!("[{kind} #{id}]"));
            let parts = extract_parts(&entry.data);
            if !parts.text_blocks.is_empty() || !parts.extra_blocks.is_empty() {
                for t in &parts.text_blocks {
                    push_multiline_lines(out, t, "");
                }
                render_extra_blocks(out, &parts.extra_blocks, tools_expanded);
            } else {
                let redacted = redact_large_binary_fields(&entry.data);
                if tools_expanded {
                    if let Ok(pretty) = serde_json::to_string_pretty(&redacted) {
                        push_multiline_lines(out, &pretty, "  ");
                    }
                } else {
                    let compact = serde_json::to_string(&redacted).unwrap_or_default();
                    push_single_line(out, &truncate_chars(&compact, COLLAPSED_CMD_CHARS));
                }
            }
        }
    }
}

fn render_assistant_entry(
    out: &mut Vec<String>,
    id: &str,
    data: &Value,
    committed_result_ids: &HashSet<String>,
    live_tool_ids: &HashSet<String>,
    tools_expanded: bool,
    thinking_expanded: bool,
) {
    let aborted = data
        .get("aborted")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let finish_reason = data.get("finish_reason").and_then(Value::as_str);

    let mut header = format!("[assistant #{id}");
    if aborted || finish_reason == Some("aborted") {
        header.push_str(" · aborted");
    } else if finish_reason == Some("length") {
        header.push_str(" · truncated");
    } else if finish_reason == Some("error") {
        header.push_str(" · error");
    }
    header.push(']');
    out.push(header);

    let parts = extract_parts(data);

    if !parts.thinking.is_empty() {
        let joined = parts.thinking.join("\n\n");
        render_thinking_block(out, &joined, false, thinking_expanded);
    }

    for text in &parts.text_blocks {
        push_multiline_lines(out, text, "");
    }
    render_extra_blocks(out, &parts.extra_blocks, tools_expanded);

    let error_msg = data
        .get("error_message")
        .or_else(|| data.get("error"))
        .and_then(Value::as_str);

    if aborted || finish_reason == Some("aborted") {
        let msg = error_msg
            .filter(|m| !m.is_empty() && *m != "Request was aborted")
            .unwrap_or("Operation aborted");
        push_single_line(out, &format!("! {msg}"));
    } else if finish_reason == Some("length") {
        out.push("! Response was truncated before completion.".to_string());
    } else if finish_reason == Some("error") || error_msg.is_some() {
        let msg = error_msg.unwrap_or("Unknown error");
        push_single_line(out, &format!("! Error: {msg}"));
    }

    // Only render orphaned tool_calls here (ones without a committed tool_result or live tool slot).
    for (call_id_opt, meta) in parse_tool_calls_from_data(data) {
        let covered = call_id_opt
            .as_deref()
            .is_some_and(|cid| committed_result_ids.contains(cid) || live_tool_ids.contains(cid));
        if covered {
            continue;
        }
        let call_summary = format_tool_call_summary(&meta.name, &meta.arguments, tools_expanded);
        let id_suffix = call_id_opt
            .as_deref()
            .map(|cid| format!(" ({})", sanitize_single_line(cid)))
            .unwrap_or_default();
        push_single_line(
            out,
            &format!("[tool {call_summary}{id_suffix} · no result]"),
        );
        if tools_expanded {
            render_expanded_args(out, &meta.name, &meta.arguments);
        }
    }
}

fn render_thinking_block(
    out: &mut Vec<String>,
    raw_thinking: &str,
    streaming: bool,
    thinking_expanded: bool,
) {
    let trimmed = raw_thinking.trim();
    if trimmed.is_empty() {
        return;
    }
    let safe = sanitize_terminal_text(trimmed).replace('\t', "   ");
    let lines: Vec<&str> = safe.split('\n').collect();
    if thinking_expanded {
        if streaming {
            out.push("[thinking (streaming)]".to_string());
        } else {
            out.push("[thinking]".to_string());
        }
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

fn render_tool_result_entry(
    out: &mut Vec<String>,
    id: &str,
    data: &Value,
    tool_calls_by_id: &HashMap<String, ToolCallMeta>,
    tools_expanded: bool,
) {
    let call_id = data
        .get("tool_call_id")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty());
    let paired = call_id.and_then(|cid| tool_calls_by_id.get(cid));

    let tool_name = data
        .get("name")
        .or_else(|| data.get("tool_name"))
        .and_then(Value::as_str)
        .or_else(|| paired.map(|p| p.name.as_str()))
        .unwrap_or("tool");

    let empty_args = Value::Object(Map::new());
    let args = paired.map(|p| &p.arguments).unwrap_or(&empty_args);

    let is_error = data
        .get("is_error")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || data.get("error").is_some_and(|v| !v.is_null());

    let diagnostic = data
        .get("diagnostic")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty());

    let duration_ms = data.get("duration_ms").and_then(Value::as_u64);

    let details = data.get("details").and_then(Value::as_object);
    let call_summary = format_tool_call_summary(tool_name, args, tools_expanded);

    let mut status_parts = Vec::new();
    if is_error {
        match diagnostic {
            Some(diag) => status_parts.push(format!("! ERROR: {}", sanitize_single_line(diag))),
            None => status_parts.push("! ERROR".to_string()),
        }
    } else {
        status_parts.push("ok".to_string());
    }

    if let Some(meta_badge) = compact_tool_result_badge(tool_name, data, details) {
        status_parts.push(meta_badge);
    }

    if let Some(ms) = duration_ms {
        status_parts.push(format_duration_ms(ms));
    }

    push_single_line(
        out,
        &format!("[tool #{id} · {}] {call_summary}", status_parts.join(" · ")),
    );

    if tools_expanded {
        render_expanded_args(out, tool_name, args);
    }

    let parts = extract_parts(data);
    let mut output_text = parts.text_blocks.join("\n");
    if output_text.is_empty() {
        if let Some(fallback) = data
            .get("output")
            .or_else(|| data.get("result"))
            .or_else(|| data.get("error"))
            .or_else(|| details.and_then(|d| d.get("partial_output")))
        {
            output_text = match fallback {
                Value::String(s) => s.clone(),
                other => serde_json::to_string(other).unwrap_or_default(),
            };
        }
    }

    // Edit diff details if provided.
    if let Some(diff) = details.and_then(|d| d.get("diff")).and_then(Value::as_str) {
        if !diff.trim().is_empty() && !output_text.contains(diff) {
            if !output_text.is_empty() {
                output_text.push('\n');
            }
            output_text.push_str(diff);
        }
    }

    let trimmed = output_text.trim_end();
    if !trimmed.is_empty() {
        let safe = sanitize_terminal_text(trimmed).replace('\t', "   ");
        let lines: Vec<&str> = safe.split('\n').collect();

        if tools_expanded {
            for line in lines {
                out.push(format!("  {line}"));
            }
        } else if is_error {
            // Errors must remain legible even when collapsed.
            let shown = lines.len().min(COLLAPSED_ERROR_LINES);
            for line in &lines[..shown] {
                out.push(format!("  {line}"));
            }
            if lines.len() > shown {
                out.push(format!("  ... ({} more error lines)", lines.len() - shown));
            }
        } else {
            render_collapsed_tool_output(out, tool_name, &lines, details);
        }
    }

    render_extra_blocks(out, &parts.extra_blocks, tools_expanded);

    if let Some(d) = details {
        let truncated = d.get("truncated").and_then(Value::as_bool).unwrap_or(false)
            || d.get("has_more").and_then(Value::as_bool).unwrap_or(false);
        if truncated && tools_expanded {
            let mut notes = Vec::new();
            if let Some(skipped) = d.get("skipped_bytes").and_then(Value::as_u64) {
                notes.push(format!("{skipped} bytes omitted"));
            }
            if let Some(path) = d.get("full_output_path").and_then(Value::as_str) {
                notes.push(format!("full output: {}", sanitize_single_line(path)));
            }
            if d.get("has_more").and_then(Value::as_bool) == Some(true) {
                notes.push("more lines available".to_string());
            }
            if !notes.is_empty() {
                out.push(format!("  [{}]", notes.join(" · ")));
            }
        }
    }
}

fn render_collapsed_tool_output(
    out: &mut Vec<String>,
    tool_name: &str,
    lines: &[&str],
    details: Option<&Map<String, Value>>,
) {
    match tool_name {
        // Successful read/write summarize concisely in the header when collapsed.
        "read" | "write" => {}
        "bash" => {
            // Keep the tail for shell commands, mirroring pi's BASH_PREVIEW_LINES.
            let total = lines.len();
            if total > COLLAPSED_PREVIEW_LINES {
                out.push(format!(
                    "  ... ({} earlier lines)",
                    total - COLLAPSED_PREVIEW_LINES
                ));
            }
            let start = total.saturating_sub(COLLAPSED_PREVIEW_LINES);
            for line in &lines[start..] {
                out.push(format!("  {line}"));
            }
        }
        "edit" => {
            // Show diff preview lines if details contain a diff, otherwise keep concise.
            let has_diff = details
                .and_then(|d| d.get("diff"))
                .and_then(Value::as_str)
                .is_some_and(|s| !s.trim().is_empty());
            if has_diff {
                let shown = lines.len().min(COLLAPSED_PREVIEW_LINES);
                for line in &lines[..shown] {
                    out.push(format!("  {line}"));
                }
                if lines.len() > shown {
                    out.push(format!("  ... ({} more lines)", lines.len() - shown));
                }
            }
        }
        _ => {
            let shown = lines.len().min(COLLAPSED_PREVIEW_LINES);
            for line in &lines[..shown] {
                out.push(format!("  {line}"));
            }
            if lines.len() > shown {
                out.push(format!("  ... ({} more lines)", lines.len() - shown));
            }
        }
    }
}

fn compact_tool_result_badge(
    tool_name: &str,
    data: &Value,
    details: Option<&Map<String, Value>>,
) -> Option<String> {
    let d = details?;
    match tool_name {
        "read" => {
            if let Some(lines) = d.get("lines_read").and_then(Value::as_u64) {
                let more = if d.get("has_more").and_then(Value::as_bool) == Some(true) {
                    "+"
                } else {
                    ""
                };
                return Some(format!("{lines}{more} lines"));
            }
            if let Some(bytes) = d.get("bytes").and_then(Value::as_u64) {
                return Some(format!("{bytes} bytes"));
            }
            None
        }
        "write" => d
            .get("bytes")
            .and_then(Value::as_u64)
            .map(|bytes| format!("{bytes} bytes")),
        "edit" => d
            .get("edits_applied")
            .and_then(Value::as_u64)
            .map(|n| format!("{n} edit(s)")),
        "bash" => d
            .get("exit_code")
            .and_then(Value::as_i64)
            .filter(|code| *code != 0 || data.get("is_error") == Some(&Value::Bool(true)))
            .map(|code| format!("exit {code}")),
        "search_history" => d
            .get("count")
            .and_then(Value::as_u64)
            .map(|n| format!("{n} match(es)")),
        _ => None,
    }
}

fn format_tool_call_summary(tool_name: &str, args: &Value, expanded: bool) -> String {
    let name = sanitize_single_line(tool_name);
    let obj = args.as_object();

    match tool_name {
        "read" => {
            let path = obj
                .and_then(|m| m.get("path").or_else(|| m.get("file_path")))
                .and_then(Value::as_str)
                .map(sanitize_single_line)
                .unwrap_or_else(|| "...".to_string());
            let range = format_read_range(
                obj.and_then(|m| m.get("offset")),
                obj.and_then(|m| m.get("limit")),
            );
            format!("{name} {path}{range}")
        }
        "write" | "edit" => {
            let path = obj
                .and_then(|m| m.get("path").or_else(|| m.get("file_path")))
                .and_then(Value::as_str)
                .map(sanitize_single_line)
                .unwrap_or_else(|| "...".to_string());
            format!("{name} {path}")
        }
        "bash" => {
            let cmd = obj
                .and_then(|m| m.get("command"))
                .and_then(Value::as_str)
                .map(sanitize_single_line)
                .unwrap_or_else(|| "...".to_string());
            let shown_cmd = if expanded {
                cmd
            } else {
                truncate_chars(&cmd, COLLAPSED_CMD_CHARS)
            };
            let timeout = obj
                .and_then(|m| m.get("timeout_ms"))
                .and_then(Value::as_u64)
                .map(|ms| format!(" (timeout {})", format_duration_ms(ms)))
                .unwrap_or_default();
            format!("$ {shown_cmd}{timeout}")
        }
        "search_history" => {
            let query = obj
                .and_then(|m| m.get("query"))
                .and_then(Value::as_str)
                .map(sanitize_single_line)
                .unwrap_or_default();
            format!("{name} \"{}\"", truncate_chars(&query, COLLAPSED_ARG_CHARS))
        }
        _ => {
            let Some(m) = obj else {
                if args.is_null() {
                    return name;
                }
                let raw = sanitize_single_line(&args.to_string());
                return format!("{name} {}", truncate_chars(&raw, COLLAPSED_ARG_CHARS));
            };
            if m.is_empty() || expanded {
                return name;
            }
            let pairs: Vec<String> = m
                .iter()
                .map(|(k, v)| {
                    let v_str = match v {
                        Value::String(s) => format!("\"{}\"", sanitize_single_line(s)),
                        other => sanitize_single_line(&other.to_string()),
                    };
                    format!("{}={v_str}", sanitize_single_line(k))
                })
                .collect();
            let joined = truncate_chars(&pairs.join(" "), COLLAPSED_ARG_CHARS);
            format!("{name} {joined}")
        }
    }
}

fn render_expanded_args(out: &mut Vec<String>, tool_name: &str, args: &Value) {
    let Some(obj) = args.as_object() else {
        if !args.is_null() {
            push_multiline_lines(out, &args.to_string(), "  args: ");
        }
        return;
    };
    if obj.is_empty() {
        return;
    }

    match tool_name {
        "read" | "write" | "bash" | "search_history" => {
            // Summary already carries the primary scalar args; show remaining/extra args if any.
            for (k, v) in obj {
                if tool_name == "write" && k == "content" {
                    if let Some(s) = v.as_str() {
                        out.push(format!("  content ({} bytes):", s.len()));
                        push_multiline_lines(out, s, "    ");
                    }
                    continue;
                }
                if (tool_name == "read" && (k == "path" || k == "offset" || k == "limit"))
                    || (tool_name == "write" && k == "path")
                    || (tool_name == "bash" && (k == "command" || k == "timeout_ms"))
                    || (tool_name == "search_history" && k == "query")
                {
                    continue;
                }
                let val_str = format_arg_value(v);
                push_multiline_lines(out, &val_str, &format!("  {}: ", sanitize_single_line(k)));
            }
        }
        "edit" => {
            if let Some(edits) = obj.get("edits").and_then(Value::as_array) {
                for (idx, edit) in edits.iter().enumerate() {
                    let Some(em) = edit.as_object() else {
                        continue;
                    };
                    let old_t = em
                        .get("old_text")
                        .or_else(|| em.get("oldText"))
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    let new_t = em
                        .get("new_text")
                        .or_else(|| em.get("newText"))
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    out.push(format!("  hunk #{}:", idx + 1));
                    push_multiline_lines(out, old_t, "  - ");
                    push_multiline_lines(out, new_t, "  + ");
                }
            }
        }
        _ => {
            for (k, v) in obj {
                let val_str = format_arg_value(v);
                push_multiline_lines(out, &val_str, &format!("  {}: ", sanitize_single_line(k)));
            }
        }
    }
}

fn format_arg_value(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => serde_json::to_string_pretty(other).unwrap_or_else(|_| other.to_string()),
    }
}

fn format_read_range(offset: Option<&Value>, limit: Option<&Value>) -> String {
    let start = offset.and_then(Value::as_u64);
    let count = limit.and_then(Value::as_u64);
    match (start, count) {
        (None, None) => String::new(),
        (Some(s), None) => format!(":{s}"),
        (None, Some(c)) if c > 0 => format!(":1-{c}"),
        (Some(s), Some(c)) if c > 0 => format!(":{s}-{}", s.saturating_add(c - 1)),
        (Some(s), Some(_)) => format!(":{s}"),
        (None, Some(_)) => String::new(),
    }
}

fn format_duration_ms(ms: u64) -> String {
    if ms < 1_000 {
        format!("{ms}ms")
    } else if ms < 60_000 {
        format!("{:.1}s", ms as f64 / 1000.0)
    } else {
        let total_secs = ms / 1_000;
        let mins = total_secs / 60;
        let rem_secs = total_secs % 60;
        format!("{mins}m {rem_secs}s")
    }
}

fn render_marker_entry(
    out: &mut Vec<String>,
    id: &str,
    kind: &str,
    data: &Value,
    tools_expanded: bool,
) {
    let body = data
        .get("summary")
        .or_else(|| data.get("handoff"))
        .or_else(|| data.get("note"))
        .or_else(|| data.get("reason"))
        .or_else(|| data.get("text"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| serde_json::to_string(data).unwrap_or_default());

    let tokens_before = data.get("tokens_before").and_then(Value::as_u64);
    let prefix = match tokens_before {
        Some(toks) => format!("[{kind} #{id} · compacted from {toks} tokens]"),
        None => format!("[{kind} #{id}]"),
    };

    if tools_expanded {
        out.push(prefix);
        if !body.trim().is_empty() {
            push_multiline_lines(out, body.trim(), "  ");
        }
    } else {
        let preview = truncate_chars(&sanitize_single_line(body.trim()), COLLAPSED_CMD_CHARS);
        if preview.is_empty() {
            out.push(prefix);
        } else {
            out.push(format!("{prefix} {preview}"));
        }
    }
}

fn render_live_section(
    out: &mut Vec<String>,
    state: &TranscriptState,
    tool_calls_by_id: &HashMap<String, ToolCallMeta>,
    committed_result_ids: &HashSet<String>,
    tools_expanded: bool,
    thinking_expanded: bool,
) {
    let Some(live) = state.live_doc() else {
        return;
    };

    let run = live.get("run").and_then(Value::as_object);
    let gen = live.get("generation").and_then(Value::as_object);
    let live_tools = normalize_live_tools(live.get("tools"), committed_result_ids);

    if let Some(gen_obj) = gen {
        if !out.is_empty() {
            out.push(String::new());
        }
        let turn_tag = run
            .and_then(|r| r.get("turns"))
            .and_then(Value::as_u64)
            .map(|t| format!(" · turn {t}"))
            .unwrap_or_default();
        out.push(format!("[assistant (live{turn_tag})]"));

        let msg = gen_obj
            .get("message")
            .and_then(Value::as_object)
            .unwrap_or(gen_obj);
        let msg_val = Value::Object(msg.clone());
        let parts = extract_parts(&msg_val);
        let has_thinking = !parts.thinking.is_empty();
        let has_text = !parts.text_blocks.is_empty();
        let tool_calls = parse_tool_calls_from_data(&msg_val);

        if has_thinking {
            render_thinking_block(out, &parts.thinking.join("\n\n"), true, thinking_expanded);
        }
        for text in &parts.text_blocks {
            push_multiline_lines(out, text, "");
        }
        render_extra_blocks(out, &parts.extra_blocks, tools_expanded);

        for (cid_opt, meta) in &tool_calls {
            let summary = format_tool_call_summary(&meta.name, &meta.arguments, tools_expanded);
            let id_suffix = cid_opt
                .as_deref()
                .map(|c| format!(" ({})", sanitize_single_line(c)))
                .unwrap_or_default();
            push_single_line(out, &format!("  -> tool_call {summary}{id_suffix}"));
        }

        if !has_thinking && !has_text && tool_calls.is_empty() && parts.extra_blocks.is_empty() {
            out.push("  ... streaming".to_string());
        }
    } else if let Some(run_obj) = run {
        if live_tools.is_empty()
            && live.get("run_failure").is_none()
            && live.get("compaction_failure").is_none()
        {
            if !out.is_empty() {
                out.push(String::new());
            }
            let turn_tag = run_obj
                .get("turns")
                .and_then(Value::as_u64)
                .map(|t| format!(" · turn {t}"))
                .unwrap_or_default();
            out.push(format!("[assistant (live{turn_tag})] ... active"));
        }
    }

    if !live_tools.is_empty() {
        let ordered = order_live_tools(live_tools, &state.entries);
        for (call_id, slot) in ordered {
            if !out.is_empty() {
                out.push(String::new());
            }
            let paired = tool_calls_by_id.get(&call_id);
            let name = slot
                .get("name")
                .and_then(Value::as_str)
                .or_else(|| paired.map(|p| p.name.as_str()))
                .unwrap_or("tool");
            let empty_args = Value::Object(Map::new());
            let args = slot
                .get("arguments")
                .or_else(|| slot.get("args"))
                .or_else(|| paired.map(|p| &p.arguments))
                .unwrap_or(&empty_args);
            let status = slot
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("pending");

            let summary = format_tool_call_summary(name, args, tools_expanded);
            push_single_line(
                out,
                &format!("[tool (live · {})] {summary}", sanitize_single_line(status)),
            );

            let partial_out = slot
                .get("output")
                .or_else(|| slot.get("stdout"))
                .or_else(|| slot.get("text"))
                .and_then(Value::as_str)
                .unwrap_or("");
            let trimmed = partial_out.trim_end();
            if !trimmed.is_empty() {
                let safe = sanitize_terminal_text(trimmed).replace('\t', "   ");
                let lines: Vec<&str> = safe.split('\n').collect();
                if tools_expanded {
                    for line in lines {
                        out.push(format!("  {line}"));
                    }
                } else {
                    if lines.len() > COLLAPSED_PREVIEW_LINES {
                        out.push(format!(
                            "  ... ({} earlier lines)",
                            lines.len() - COLLAPSED_PREVIEW_LINES
                        ));
                    }
                    let start = lines.len().saturating_sub(COLLAPSED_PREVIEW_LINES);
                    for line in &lines[start..] {
                        out.push(format!("  {line}"));
                    }
                }
            }
        }
    }
}

fn normalize_live_tools<'a>(
    tools_val: Option<&'a Value>,
    committed_result_ids: &HashSet<String>,
) -> Vec<(String, &'a Map<String, Value>)> {
    let mut out = Vec::new();
    let Some(val) = tools_val else {
        return out;
    };
    match val {
        Value::Object(map) => {
            for (k, v) in map {
                if let Some(obj) = v.as_object() {
                    let id = obj
                        .get("id")
                        .or_else(|| obj.get("call_id"))
                        .and_then(Value::as_str)
                        .unwrap_or(k.as_str())
                        .to_string();
                    if !committed_result_ids.contains(&id) {
                        out.push((id, obj));
                    }
                }
            }
        }
        Value::Array(items) => {
            for (idx, v) in items.iter().enumerate() {
                if let Some(obj) = v.as_object() {
                    let id = obj
                        .get("id")
                        .or_else(|| obj.get("call_id"))
                        .and_then(Value::as_str)
                        .map(str::to_string)
                        .unwrap_or_else(|| format!("live_{idx}"));
                    if !committed_result_ids.contains(&id) {
                        out.push((id, obj));
                    }
                }
            }
        }
        _ => {}
    }
    out
}

fn order_live_tools<'a>(
    mut slots: Vec<(String, &'a Map<String, Value>)>,
    entries: &[TranscriptEntry],
) -> Vec<(String, &'a Map<String, Value>)> {
    let last_order: HashMap<String, usize> = entries
        .iter()
        .rev()
        .find(|e| e.kind == "assistant")
        .map(|e| {
            parse_tool_calls_from_data(&e.data)
                .into_iter()
                .enumerate()
                .filter_map(|(idx, (cid, _))| cid.map(|id| (id, idx)))
                .collect()
        })
        .unwrap_or_default();

    slots.sort_by(
        |(id_a, _), (id_b, _)| match (last_order.get(id_a), last_order.get(id_b)) {
            (Some(a), Some(b)) => a.cmp(b),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => id_a.cmp(id_b),
        },
    );
    slots
}

fn render_inbox_section(out: &mut Vec<String>, state: &TranscriptState) {
    let Some(inbox) = state.docs.get("inbox").and_then(Value::as_array) else {
        return;
    };
    if inbox.is_empty() {
        return;
    }

    if !out.is_empty() {
        out.push(String::new());
    }
    out.push(format!("[queued ({})]", inbox.len()));

    for item in inbox {
        let mode = item
            .get("when_busy")
            .and_then(Value::as_str)
            .map(|m| format!("[{}] ", sanitize_single_line(m)))
            .unwrap_or_default();

        let parts = extract_parts(item);
        let text = parts.text_blocks.join(" ");
        let preview = if !text.trim().is_empty() {
            truncate_chars(&sanitize_single_line(text.trim()), COLLAPSED_CMD_CHARS)
        } else if !parts.extra_blocks.is_empty() {
            let mut tmp = Vec::new();
            render_extra_blocks(&mut tmp, &parts.extra_blocks, false);
            tmp.join(" ")
        } else {
            let raw = serde_json::to_string(item).unwrap_or_default();
            truncate_chars(&sanitize_single_line(&raw), COLLAPSED_CMD_CHARS)
        };
        out.push(format!("  {mode}{preview}"));
    }
}

fn render_failure_section(out: &mut Vec<String>, state: &TranscriptState) {
    let Some(fail) = state.run_failure() else {
        return;
    };
    if !out.is_empty() {
        out.push(String::new());
    }
    let label = if fail.is_compaction {
        "Compaction failed"
    } else {
        "Run paused"
    };
    let reason = sanitize_single_line(&fail.reason);
    let code_tag = fail
        .code
        .as_deref()
        .filter(|c| !c.is_empty())
        .map(|c| format!(" ({})", sanitize_single_line(c)))
        .unwrap_or_default();

    out.push(format!("[! {label}: {reason}{code_tag}]"));
    if let Some(msg) = fail.message.as_deref().filter(|m| !m.trim().is_empty()) {
        push_multiline_lines(out, msg.trim(), "  ");
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

    fn assert_no_unsafe_terminal_chars(rows: &[String]) {
        for (idx, row) in rows.iter().enumerate() {
            assert!(!row.contains('\x1b'), "row {idx} contains ESC: {row:?}");
            assert!(!row.contains('\r'), "row {idx} contains CR: {row:?}");
            assert!(
                !row.contains('\n'),
                "row {idx} contains embedded LF: {row:?}"
            );
            assert!(!row.contains('\t'), "row {idx} contains raw TAB: {row:?}");
            for ch in row.chars() {
                assert!(
                    !('\x00'..='\x1f').contains(&ch)
                        && ch != '\x7f'
                        && !('\u{0080}'..='\u{009f}').contains(&ch),
                    "row {idx} contains control char {ch:?}: {row:?}"
                );
            }
        }
    }

    #[test]
    fn empty_state_returns_empty_rows() {
        let state = TranscriptState::default();
        assert!(rows(&state, false, false).is_empty());
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
                        "message": {
                            "thinking": "live_t\x1b[1m",
                            "text": "live_txt\x07"
                        }
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
            assert_no_unsafe_terminal_chars(&rendered);
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
                    "generation": {
                        "message": {
                            "thinking": "live step",
                            "text": "partial"
                        }
                    }
                }
            })),
        });

        let collapsed = rows(&state, false, false).join("\n");
        assert!(collapsed.contains("[thinking · 2 lines (collapsed)]"));
        assert!(!collapsed.contains("step 1"));
        assert!(collapsed.contains("[thinking (streaming · 1 lines, collapsed)]"));
        assert!(!collapsed.contains("live step"));
        assert!(collapsed.contains("Final answer"));

        let expanded = rows(&state, false, true).join("\n");
        assert!(expanded.contains("  | step 1"));
        assert!(expanded.contains("  | step 2"));
        assert!(expanded.contains("  | live step"));
    }

    #[test]
    fn tool_call_and_result_pair_into_single_card_and_live_tool_never_duplicates() {
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

        // While both are live, assistant does not duplicate them; live section shows both in call order with args.
        let live_rows = rows(&state, false, false);
        let live_text = live_rows.join("\n");
        assert_eq!(live_text.matches("src/main.rs:10-29").count(), 1);
        assert_eq!(live_text.matches("$ cargo test").count(), 1);
        assert!(live_text.contains("[tool (live · running)] read src/main.rs:10-29"));
        assert!(live_text.contains("[tool (live · pending)] $ cargo test"));

        // Now call_1 commits as tool_result while live.tools still holds call_1 as "done".
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

        let mid_rows = rows(&state, false, false).join("\n");
        // call_1 appears ONCE as a committed card (not duplicated in live.tools!)
        assert_eq!(mid_rows.matches("src/main.rs:10-29").count(), 1);
        assert!(mid_rows.contains("[tool #11 · ok · 1 lines · 14ms] read src/main.rs:10-29"));
        // Collapsed read hides file contents, expanded shows them.
        assert!(!mid_rows.contains("fn main()"));
        assert!(mid_rows.contains("[tool (live · running)] $ cargo test"));

        let expanded_mid = rows(&state, true, false).join("\n");
        assert!(expanded_mid.contains("  10: fn main() {}"));
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
                        "tool_calls": [
                            {
                                "id": "e1",
                                "name": "edit",
                                "arguments": {
                                    "path": "src/lib.rs",
                                    "edits": [{"old_text": "foo", "new_text": "bar"}]
                                }
                            }
                        ]
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
        assert!(expanded.contains("  hunk #1:"));
        assert!(expanded.contains("  - foo"));
        assert!(expanded.contains("  + bar"));
    }

    #[test]
    fn bash_live_and_committed_tail_preview_and_truncation_expand() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            seq: 4,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![make_entry(
                "1",
                "tool_result",
                json!({
                    "tool_call_id": "b1",
                    "name": "bash",
                    "content": [{"type": "text", "text": "l1\nl2\nl3\nl4\nl5\nl6\nl7"}],
                    "details": {
                        "exit_code": 1,
                        "truncated": true,
                        "skipped_bytes": 1200,
                        "full_output_path": "/tmp/full.log"
                    },
                    "is_error": true,
                    "diagnostic": "exit_code",
                    "duration_ms": 2300
                }),
            )],
            docs: Some(json!({
                "live": {
                    "tools": [
                        {"id": "b2", "name": "bash", "status": "running", "output": "a\nb\nc\nd\ne\nf\ng"}
                    ]
                }
            })),
        });

        let collapsed = rows(&state, false, false).join("\n");
        assert!(collapsed.contains("[tool #1 · ! ERROR: exit_code · exit 1 · 2.3s] $ ..."));
        assert!(collapsed.contains("  ... (2 earlier lines)"));
        assert!(collapsed.contains("  g"));
        assert!(!collapsed.contains("  a\n"));

        let expanded = rows(&state, true, false).join("\n");
        assert!(expanded.contains("  l1"));
        assert!(expanded.contains("  l7"));
        assert!(expanded.contains("1200 bytes omitted"));
        assert!(expanded.contains("full output: /tmp/full.log"));
        assert!(expanded.contains("  a"));
    }

    #[test]
    fn compaction_images_unknown_blocks_inbox_and_failures_render_safely() {
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
                            {"type": "text", "text": "Check this"},
                            {"type": "image", "media_type": "image/png", "data": "AAAA".repeat(200)},
                            {"type": "custom_widget", "foo": "bar", "data": "B".repeat(500)}
                        ]
                    }),
                ),
                make_entry(
                    "2",
                    "compaction",
                    json!({
                        "summary": "Summary line 1\nSummary line 2",
                        "tokens_before": 42000
                    }),
                ),
                make_entry(
                    "3",
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
                    "compaction_failure": {
                        "reason": "context_too_large",
                        "code": "413",
                        "message": "Exceeded window"
                    }
                },
                "inbox": [
                    {"submission_id": "10", "when_busy": "follow_up", "content": [{"type": "text", "text": "next task"}]}
                ]
            })),
        });

        let collapsed = rows(&state, false, false).join("\n");
        assert!(collapsed.contains("[image: image/png ~600 bytes]"));
        assert!(!collapsed.contains(&"AAAA".repeat(20)));
        assert!(collapsed.contains("[block custom_widget]"));
        assert!(collapsed.contains("[compaction #2 · compacted from 42000 tokens]"));
        assert!(collapsed.contains("[assistant #3 · aborted]"));
        assert!(collapsed.contains("! Operation aborted"));
        assert!(collapsed.contains("[tool write x.txt (orphan_1) · no result]"));
        assert!(collapsed.contains("[queued (1)]"));
        assert!(collapsed.contains("  [follow_up] next task"));
        assert!(collapsed.contains("[! Compaction failed: context_too_large (413)]"));
        assert!(collapsed.contains("  Exceeded window"));
        assert!(collapsed.contains("  Use /continue to resume."));

        let expanded = rows(&state, true, true).join("\n");
        assert!(expanded.contains("  Summary line 1"));
        assert!(expanded.contains("  Summary line 2"));
        assert!(expanded.contains("<omitted 500 chars>"));
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

        let initial = rows(&state, false, false).join("\n");
        assert!(initial.contains("[assistant (live · turn 1)]"));
        assert!(initial.contains("  ... streaming"));

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
        assert!(final_view.contains("[assistant #2]"));
        assert!(final_view.contains("Hello!"));
    }

    #[test]
    fn handles_system_reset_handoff_write_search_history_string_args_and_flat_live() {
        let mut state = TranscriptState::default();
        state.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            seq: 9,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![
                make_entry("1", "system", json!({"text": "System rule"})),
                make_entry(
                    "2",
                    "assistant",
                    json!({
                        "content": [],
                        "tool_calls": [
                            {"id": "w1", "name": "write", "arguments": "{\"path\":\"out.txt\",\"content\":\"hello\"}"},
                            {"id": "s1", "name": "search_history", "arguments": {"query": "needle"}},
                            {"id": "img1", "name": "read", "arguments": {"path": "logo.png"}},
                            {"id": "u1", "name": "custom_tool", "arguments": {"alpha": 1, "beta": "two"}}
                        ]
                    }),
                ),
                make_entry(
                    "3",
                    "tool_result",
                    json!({
                        "tool_call_id": "w1",
                        "name": "write",
                        "content": [{"type": "text", "text": "Wrote 5 bytes to out.txt"}],
                        "details": {"path": "out.txt", "bytes": 5},
                        "is_error": false
                    }),
                ),
                make_entry(
                    "4",
                    "tool_result",
                    json!({
                        "tool_call_id": "s1",
                        "name": "search_history",
                        "content": [{"type": "text", "text": "[#1 system] System rule"}],
                        "details": {"query": "needle", "count": 1},
                        "is_error": false
                    }),
                ),
                make_entry(
                    "5",
                    "tool_result",
                    json!({
                        "tool_call_id": "img1",
                        "name": "read",
                        "content": [{"type": "image", "mime_type": "image/png", "data": "QUJDRA=="}],
                        "details": {"path": "logo.png", "mime_type": "image/png", "bytes": 4},
                        "is_error": false
                    }),
                ),
                make_entry(
                    "6",
                    "tool_result",
                    json!({
                        "tool_call_id": "u1",
                        "name": "custom_tool",
                        "content": [{"type": "text", "text": "custom ok"}],
                        "is_error": false
                    }),
                ),
                make_entry("7", "reset", json!({"handoff": "Fresh start note"})),
                make_entry("8", "mystery_kind", json!({"foo": "bar"})),
            ],
            docs: Some(json!({
                "live": {
                    "generation": {
                        "text": "flat live text",
                        "tool_calls": [{"id": "live_tc", "name": "bash", "arguments": {"command": "ls"}}]
                    },
                    "run_failure": "interrupted"
                }
            })),
        });

        let collapsed = rows(&state, false, false);
        assert_no_unsafe_terminal_chars(&collapsed);
        let text = collapsed.join("\n");
        assert!(text.contains("[system #1]\nSystem rule"));
        assert!(text.contains("[tool #3 · ok · 5 bytes] write out.txt"));
        assert!(text.contains("[tool #4 · ok · 1 match(es)] search_history \"needle\""));
        assert!(text.contains("[tool #5 · ok · 4 bytes] read logo.png"));
        assert!(text.contains("[image: image/png ~6 bytes]"));
        assert!(!text.contains("QUJDRA=="));
        assert!(text.contains("[tool #6 · ok] custom_tool alpha=1 beta=\"two\""));
        assert!(text.contains("[reset #7] Fresh start note"));
        assert!(text.contains("[mystery_kind #8]"));
        assert!(text.contains("flat live text"));
        assert!(text.contains("-> tool_call $ ls (live_tc)"));
        assert!(text.contains("[! Run paused: interrupted]"));

        let expanded = rows(&state, true, true);
        assert_no_unsafe_terminal_chars(&expanded);
        let exp_text = expanded.join("\n");
        assert!(exp_text.contains("  content (5 bytes):"));
        assert!(exp_text.contains("    hello"));
        assert!(exp_text.contains("  alpha: 1"));
    }
}
