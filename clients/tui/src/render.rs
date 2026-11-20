use serde_json::Value;
use std::fmt::Write as _;

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

#[cfg(test)]
mod tests {
    use super::*;

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
}
