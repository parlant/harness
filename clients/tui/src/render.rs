use crate::protocol::{ConversationInfo, SessionSummary, TranscriptEntry};
use crate::transcript::TranscriptState;
use serde_json::Value;
use std::collections::HashSet;
use std::fmt::Write as _;
use std::io::{self, Write};

pub fn sanitize_terminal_text(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();

    while let Some(ch) = chars.next() {
        match ch {
            '\n' | '\t' => out.push(ch),
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    // Normalize CRLF -> LF
                    continue;
                }
                out.push_str("\\r");
            }
            '\x1b' => out.push_str("\\x1b"),
            '\x00'..='\x1f' => {
                let _ = write!(out, "\\x{:02x}", ch as u32);
            }
            '\x7f' => out.push_str("\\x7f"),
            '\u{0080}'..='\u{009f}' => {
                let _ = write!(out, "\\u{{{:04x}}}", ch as u32);
            }
            _ => out.push(ch),
        }
    }

    out
}

pub fn sanitize_single_line(input: &str) -> String {
    let base = sanitize_terminal_text(input);
    let mut out = String::with_capacity(base.len());
    for ch in base.chars() {
        match ch {
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            _ => out.push(ch),
        }
    }
    out
}

pub fn extract_entry_text(data: &Value) -> String {
    let Some(obj) = data.as_object() else {
        return String::new();
    };

    let mut text_parts = Vec::new();
    if let Some(content) = obj.get("content") {
        match content {
            Value::String(s) if !s.is_empty() => text_parts.push(s.clone()),
            Value::Array(items) => {
                for item in items {
                    match item {
                        Value::String(s) => text_parts.push(s.clone()),
                        Value::Object(part)
                            if part.get("type").and_then(Value::as_str) == Some("text") =>
                        {
                            if let Some(t) = part.get("text").and_then(Value::as_str) {
                                text_parts.push(t.to_string());
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }

    if text_parts.is_empty() {
        if let Some(t) = obj.get("text").and_then(Value::as_str) {
            if !t.is_empty() {
                text_parts.push(t.to_string());
            }
        }
    }

    text_parts.join("\n")
}

pub fn extract_tool_calls(data: &Value) -> Vec<(String, Option<String>)> {
    let Some(arr) = data.get("tool_calls").and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|tc| {
            let name = tc.get("name").and_then(Value::as_str)?.to_string();
            let id = tc.get("id").and_then(Value::as_str).map(str::to_string);
            Some((name, id))
        })
        .collect()
}

pub fn extract_live_text(state: &TranscriptState) -> &str {
    state
        .live_doc()
        .and_then(|live| live.get("generation"))
        .and_then(Value::as_object)
        .and_then(|gen| {
            gen.get("message")
                .and_then(Value::as_object)
                .or(Some(gen))
                .and_then(|msg| msg.get("text"))
                .and_then(Value::as_str)
        })
        .unwrap_or("")
}

pub fn format_status_line(state: &TranscriptState) -> String {
    let seq_str = state.seq.map_or_else(|| "-".to_string(), |s| s.to_string());
    let model = state
        .agent_model()
        .map(sanitize_single_line)
        .unwrap_or_else(|| "default".to_string());
    let thinking = state
        .agent_thinking()
        .map(sanitize_single_line)
        .unwrap_or_else(|| "medium".to_string());
    let activity = if state.is_run_active() {
        "busy"
    } else if state.run_failure().is_some() {
        "paused"
    } else {
        "idle"
    };
    let inbox = state.inbox_len();
    let usage = match state.usage_summary() {
        Some((in_t, out_t, cost)) if cost > 0.0 => {
            format!(" · tokens {in_t}/{out_t} (${cost:.4})")
        }
        Some((in_t, out_t, _)) => format!(" · tokens {in_t}/{out_t}"),
        None => String::new(),
    };
    let queued = if inbox > 0 {
        format!(" · queued {inbox}")
    } else {
        String::new()
    };

    format!("[seq {seq_str} · {activity} · {model} ({thinking}){queued}{usage}]")
}

pub struct InlineRenderer<W: Write> {
    out: W,
    printed_entry_ids: HashSet<String>,
    streaming_active: bool,
    streamed_text_bytes: usize,
    reported_tools: HashSet<String>,
}

impl<W: Write> InlineRenderer<W> {
    pub fn new(out: W) -> Self {
        Self {
            out,
            printed_entry_ids: HashSet::new(),
            streaming_active: false,
            streamed_text_bytes: 0,
            reported_tools: HashSet::new(),
        }
    }

    #[cfg(test)]
    pub fn into_inner(self) -> W {
        self.out
    }

    pub fn reset_for_conversation(&mut self) -> io::Result<()> {
        self.finish_streaming_line()?;
        self.printed_entry_ids.clear();
        self.reported_tools.clear();
        Ok(())
    }

    pub fn render_snapshot(&mut self, state: &TranscriptState) -> io::Result<()> {
        self.finish_streaming_line()?;
        for entry in &state.entries {
            if self.printed_entry_ids.insert(entry.id.clone()) {
                self.print_entry(entry, false)?;
            }
        }
        self.print_failure_if_any(state)?;
        writeln!(self.out, "{}", format_status_line(state))?;
        self.out.flush()
    }

    pub fn render_commit(
        &mut self,
        state: &TranscriptState,
        appended: &[TranscriptEntry],
    ) -> io::Result<()> {
        let had_streamed = self.streaming_active && self.streamed_text_bytes > 0;
        self.finish_streaming_line()?;
        self.reported_tools.clear();

        let mut any_printed = false;
        for entry in appended {
            if self.printed_entry_ids.insert(entry.id.clone()) {
                let skip_body = had_streamed && entry.kind == "assistant";
                self.print_entry(entry, skip_body)?;
                any_printed = true;
            }
        }

        self.print_failure_if_any(state)?;
        if any_printed || !state.is_run_active() {
            writeln!(self.out, "{}", format_status_line(state))?;
        }
        self.out.flush()
    }

    pub fn render_ephemeral(&mut self, state: &TranscriptState) -> io::Result<()> {
        let live_text = extract_live_text(state);
        if live_text.len() > self.streamed_text_bytes {
            if !self.streaming_active {
                write!(self.out, "assistant (live): ")?;
                self.streaming_active = true;
            }
            let delta = &live_text[self.streamed_text_bytes..];
            let safe_delta = sanitize_terminal_text(delta);
            write!(self.out, "{safe_delta}")?;
            self.streamed_text_bytes = live_text.len();
            self.out.flush()?;
        }

        if let Some(tools_val) = state.live_doc().and_then(|l| l.get("tools")) {
            if let Some(tools_map) = tools_val.as_object() {
                for (call_id, slot) in tools_map {
                    let status = slot
                        .get("status")
                        .and_then(Value::as_str)
                        .unwrap_or("pending");
                    if status == "running" && self.reported_tools.insert(call_id.clone()) {
                        self.finish_streaming_line()?;
                        let name = slot.get("name").and_then(Value::as_str).unwrap_or("tool");
                        writeln!(
                            self.out,
                            "[tool running: {} ({})]",
                            sanitize_single_line(name),
                            sanitize_single_line(call_id)
                        )?;
                        self.out.flush()?;
                    }
                }
            }
        }

        Ok(())
    }

    fn finish_streaming_line(&mut self) -> io::Result<()> {
        if self.streaming_active {
            writeln!(self.out)?;
            self.streaming_active = false;
        }
        self.streamed_text_bytes = 0;
        Ok(())
    }

    fn print_entry(&mut self, entry: &TranscriptEntry, already_streamed: bool) -> io::Result<()> {
        let id = sanitize_single_line(&entry.id);
        let kind = sanitize_single_line(&entry.kind);

        match entry.kind.as_str() {
            "tool_result" => {
                let tool_name = entry
                    .data
                    .get("tool_name")
                    .or_else(|| entry.data.get("name"))
                    .and_then(Value::as_str)
                    .map(sanitize_single_line)
                    .unwrap_or_else(|| "tool".to_string());
                let is_err = entry
                    .data
                    .get("is_error")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
                    || entry.data.get("error").is_some_and(|v| !v.is_null());
                let err_tag = if is_err { " error" } else { "" };
                let raw_out = extract_entry_text(&entry.data);
                let preview = if raw_out.is_empty() {
                    entry
                        .data
                        .get("output")
                        .or_else(|| entry.data.get("result"))
                        .or_else(|| entry.data.get("error"))
                        .map(|v| match v {
                            Value::String(s) => s.clone(),
                            other => other.to_string(),
                        })
                        .unwrap_or_default()
                } else {
                    raw_out
                };
                let safe_preview = sanitize_terminal_text(&preview);
                let trimmed = safe_preview.trim();
                if trimmed.is_empty() {
                    writeln!(self.out, "[tool_result #{id} {tool_name}{err_tag}]")
                } else {
                    writeln!(
                        self.out,
                        "[tool_result #{id} {tool_name}{err_tag}]\n{trimmed}"
                    )
                }
            }
            "compaction" | "reset" | "handoff" => {
                let note = entry
                    .data
                    .get("summary")
                    .or_else(|| entry.data.get("note"))
                    .or_else(|| entry.data.get("reason"))
                    .and_then(Value::as_str)
                    .map(sanitize_terminal_text)
                    .unwrap_or_else(|| sanitize_terminal_text(&entry.data.to_string()));
                writeln!(self.out, "[{kind} #{id}] {note}")
            }
            _ => {
                let aborted = entry
                    .data
                    .get("aborted")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                let aborted_tag = if aborted { " aborted" } else { "" };
                let text = extract_entry_text(&entry.data);
                let tool_calls = extract_tool_calls(&entry.data);

                if already_streamed && tool_calls.is_empty() && !aborted {
                    writeln!(self.out, "[{kind} #{id} committed]")?;
                } else {
                    writeln!(self.out, "[{kind} #{id}{aborted_tag}]")?;
                    if !already_streamed && !text.is_empty() {
                        writeln!(self.out, "{}", sanitize_terminal_text(&text))?;
                    }
                    for (tc_name, tc_id) in tool_calls {
                        let cid = tc_id
                            .as_deref()
                            .map(sanitize_single_line)
                            .unwrap_or_default();
                        if cid.is_empty() {
                            writeln!(
                                self.out,
                                "  -> tool_call {}",
                                sanitize_single_line(&tc_name)
                            )?;
                        } else {
                            writeln!(
                                self.out,
                                "  -> tool_call {} ({cid})",
                                sanitize_single_line(&tc_name)
                            )?;
                        }
                    }
                }
                Ok(())
            }
        }
    }

    fn print_failure_if_any(&mut self, state: &TranscriptState) -> io::Result<()> {
        if let Some(fail) = state.run_failure() {
            let label = fail.label();
            let reason = sanitize_single_line(&fail.reason);
            let detail = fail
                .message
                .as_deref()
                .map(|m| format!(": {}", sanitize_single_line(m)))
                .unwrap_or_default();
            writeln!(
                self.out,
                "[! {label}: {reason}{detail} — use /continue to resume]"
            )?;
        }
        Ok(())
    }
}

pub fn format_sessions_list(sessions: &[SessionSummary], cwd: &str) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "Sessions for {}:", sanitize_single_line(cwd));
    if sessions.is_empty() {
        let _ = writeln!(out, "  (none)");
        return out;
    }
    for (idx, s) in sessions.iter().enumerate() {
        let title = s
            .title
            .as_deref()
            .filter(|t| !t.trim().is_empty())
            .map(sanitize_single_line)
            .unwrap_or_else(|| "(untitled)".to_string());
        let sid = sanitize_single_line(&s.session_id);
        let activity = if s.status.as_deref() == Some("quarantined") {
            "quarantined"
        } else if s.active {
            "active"
        } else {
            "idle"
        };
        let updated = s
            .updated_at
            .or(s.created_at)
            .map_or_else(|| "-".to_string(), |ts| format!("updated_ms={ts}"));
        let _ = writeln!(
            out,
            "  [{}] {}  title=\"{}\"  [{}]  {}",
            idx + 1,
            sid,
            title,
            activity,
            updated
        );
    }
    out
}

pub fn format_branches_list(conversations: &[ConversationInfo], active_cid: &str) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "Conversations:");
    for c in conversations {
        let marker = if c.id == active_cid { "*" } else { " " };
        let parent = c
            .parent
            .as_ref()
            .map(|p| {
                format!(
                    " (forked from #{} @ #{})",
                    sanitize_single_line(&p.conversation_id),
                    sanitize_single_line(&p.at)
                )
            })
            .unwrap_or_default();
        let owner = c
            .owner
            .as_deref()
            .filter(|o| *o != "ownerless")
            .map(|o| format!(" [{}]", sanitize_single_line(o)))
            .unwrap_or_default();
        let _ = writeln!(
            out,
            "  {marker} #{}{}{}",
            sanitize_single_line(&c.id),
            parent,
            owner
        );
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{CommitFrame, EphemeralFrame, SnapshotFrame};
    use serde_json::json;

    #[test]
    fn sanitize_escapes_ansi_osc_c0_c1_and_cr() {
        let malicious = "hello\x1b[31mred\x1b]0;pwned\x07\rspoof\u{009b}2J\x7f\nnext\tline";
        let safe = sanitize_terminal_text(malicious);
        assert!(!safe.contains('\x1b'));
        assert!(!safe.contains('\x07'));
        assert!(!safe.contains('\r'));
        assert!(!safe.contains('\x7f'));
        assert!(!safe.contains('\u{009b}'));
        assert!(safe.contains("\\x1b[31m"));
        assert!(safe.contains("\\x07"));
        assert!(safe.contains("\\rspoof"));
        assert!(safe.contains("\\u{009b}"));
        assert!(safe.contains("\\x7f"));
        assert!(safe.contains("\nnext\tline"));
    }

    #[test]
    fn sanitize_single_line_escapes_newlines_and_tabs() {
        let raw = "proj\nfake_line\tcol";
        assert_eq!(sanitize_single_line(raw), "proj\\nfake_line\\tcol");
    }

    #[test]
    fn inline_renderer_prints_committed_entries_once_and_streams_ephemeral() {
        let mut t = TranscriptState::default();
        let mut renderer = InlineRenderer::new(Vec::<u8>::new());

        t.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: Some("s1".to_string()),
            conversation_id: Some("1".to_string()),
            seq: 1,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![TranscriptEntry {
                id: "1".to_string(),
                conversation_id: Some("1".to_string()),
                seq: Some(1),
                kind: "user".to_string(),
                data: json!({"content": [{"type": "text", "text": "hi"}]}),
                created_at: None,
            }],
            docs: Some(json!({"live": {"run": {"turns": 1}}, "agent": {"model": "m1"}})),
        });
        renderer.render_snapshot(&t).unwrap();

        // Resnapshot with same entry should not duplicate entry #1
        t.apply_snapshot(SnapshotFrame {
            version: Some(1),
            session_id: Some("s1".to_string()),
            conversation_id: Some("1".to_string()),
            seq: 1,
            before_entry_id: None,
            has_more: Some(false),
            entries: vec![TranscriptEntry {
                id: "1".to_string(),
                conversation_id: Some("1".to_string()),
                seq: Some(1),
                kind: "user".to_string(),
                data: json!({"content": [{"type": "text", "text": "hi"}]}),
                created_at: None,
            }],
            docs: Some(json!({"live": {"run": {"turns": 1}}, "agent": {"model": "m1"}})),
        });
        renderer.render_snapshot(&t).unwrap();

        t.apply_ephemeral(EphemeralFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            base_seq: 1,
            doc_ops: Some(
                json!({"live": [["append_text", ["generation", "message", "text"], "Hel"]]})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
            ops: None,
        });
        renderer.render_ephemeral(&t).unwrap();

        t.apply_ephemeral(EphemeralFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            base_seq: 1,
            doc_ops: Some(
                json!({"live": [["append_text", ["generation", "message", "text"], "lo\x1b[0m"]]})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
            ops: None,
        });
        renderer.render_ephemeral(&t).unwrap();

        let commit = CommitFrame {
            version: Some(1),
            session_id: None,
            conversation_id: None,
            prev_seq: Some(1),
            seq: 2,
            appended_entries: vec![TranscriptEntry {
                id: "2".to_string(),
                conversation_id: Some("1".to_string()),
                seq: Some(2),
                kind: "assistant".to_string(),
                data: json!({"content": [{"type": "text", "text": "Hello\x1b[0m"}]}),
                created_at: None,
            }],
            doc_ops: Some(
                json!({"live": [["replace", {}]]})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        };
        if let crate::transcript::CommitOutcome::Applied { appended_entries } =
            t.apply_commit(commit)
        {
            renderer.render_commit(&t, &appended_entries).unwrap();
        }

        let output = String::from_utf8(renderer.into_inner()).unwrap();
        assert_eq!(output.matches("[user #1]").count(), 1);
        assert!(output.contains("assistant (live): Hello\\x1b[0m"));
        assert!(!output.contains('\x1b'));
    }
}
