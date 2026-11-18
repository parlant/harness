use crate::client::DaemonClient;
use crate::protocol::TranscriptEntry;
use crate::render::{extract_entry_text, extract_tool_calls};
use serde_json::Value;
use std::fs::{self, File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::Path;

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

const PAGE_LIMIT: u32 = 200;

struct FileCleanup<'a> {
    path: &'a Path,
    armed: bool,
}

impl<'a> FileCleanup<'a> {
    fn new(path: &'a Path) -> Self {
        Self { path, armed: true }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for FileCleanup<'_> {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_file(self.path);
        }
    }
}

/// Exports visible entries in ascending order through the pinned `last` entry ID
/// to a newly created private local file (escaped HTML for `.html`, H JSONL otherwise).
pub fn export(
    client: &DaemonClient,
    sid: &str,
    cid: &str,
    last: &str,
    path: &Path,
) -> Result<usize, String> {
    if sid.trim().is_empty() {
        return Err("session_id must not be empty".to_string());
    }
    if cid.trim().is_empty() {
        return Err("conversation_id must not be empty".to_string());
    }
    if last.trim().is_empty() {
        return Err("pinned last entry id must not be empty".to_string());
    }

    let is_html = path
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("html"));

    let file = open_private_new(path)?;
    let mut cleanup = FileCleanup::new(path);
    let mut writer = BufWriter::new(file);

    if is_html {
        write_html_header(&mut writer, sid, cid, last)
            .map_err(|e| format!("failed to write HTML header: {e}"))?;
    }

    let last_num = last.parse::<u64>().ok();
    let mut cursor: Option<String> = None;
    let mut count: usize = 0;
    let mut found_last = false;

    loop {
        let page = client
            .get_entries(sid, cid, Some("asc"), cursor.as_deref(), Some(PAGE_LIMIT))
            .map_err(|e| format!("failed to fetch entries page: {e}"))?;

        let mut stop = false;
        for entry in &page.items {
            if entry.id == last {
                write_entry(&mut writer, entry, is_html)?;
                count += 1;
                found_last = true;
                stop = true;
                break;
            }
            if let (Some(l), Ok(id_num)) = (last_num, entry.id.parse::<u64>()) {
                if id_num > l {
                    stop = true;
                    break;
                }
            }
            write_entry(&mut writer, entry, is_html)?;
            count += 1;
        }

        if stop {
            break;
        }

        match page.next_cursor {
            None => break,
            Some(next) => {
                if page.items.is_empty() || next.is_empty() || cursor.as_deref() == Some(&next) {
                    return Err("pagination cursor did not advance".to_string());
                }
                cursor = Some(next);
            }
        }
    }

    if !found_last {
        return Err(format!(
            "pinned last entry '{last}' not found in conversation {cid}"
        ));
    }

    if is_html {
        write_html_footer(&mut writer, count)
            .map_err(|e| format!("failed to write HTML footer: {e}"))?;
    }

    writer
        .flush()
        .map_err(|e| format!("failed to flush export file: {e}"))?;
    cleanup.disarm();
    Ok(count)
}

fn open_private_new(path: &Path) -> Result<File, String> {
    let mut opts = OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    opts.mode(0o600);
    opts.open(path)
        .map_err(|e| format!("failed to create export file '{}': {e}", path.display()))
}

fn write_entry<W: Write>(
    writer: &mut W,
    entry: &TranscriptEntry,
    is_html: bool,
) -> Result<(), String> {
    if is_html {
        write_html_entry(writer, entry).map_err(|e| format!("failed to write HTML entry: {e}"))
    } else {
        serde_json::to_writer(&mut *writer, entry)
            .map_err(|e| format!("failed to encode JSONL entry: {e}"))?;
        writer
            .write_all(b"\n")
            .map_err(|e| format!("failed to write JSONL newline: {e}"))
    }
}

fn write_html_header<W: Write>(
    writer: &mut W,
    sid: &str,
    cid: &str,
    last: &str,
) -> std::io::Result<()> {
    let esc_sid = escape_html(sid);
    let esc_cid = escape_html(cid);
    let esc_last = escape_html(last);
    write!(
        writer,
        "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n\
         <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n\
         <title>H Export · {esc_sid} #{esc_cid}</title>\n\
         <style>\n\
         :root{{color-scheme:light dark}}\n\
         body{{font-family:system-ui,-apple-system,sans-serif;max-width:56rem;margin:2rem auto;padding:0 1rem;line-height:1.5}}\n\
         header,footer{{border-bottom:1px solid #8884;padding-bottom:.75rem;margin-bottom:1.25rem}}\n\
         footer{{border-bottom:0;border-top:1px solid #8884;padding-top:.75rem;margin-top:1.5rem;font-size:.875rem;opacity:.8}}\n\
         .entry{{border:1px solid #8884;border-radius:6px;padding:.75rem 1rem;margin-bottom:.75rem}}\n\
         .entry-head{{font-size:.85rem;font-weight:600;margin-bottom:.4rem;opacity:.85}}\n\
         .badge{{display:inline-block;padding:0 .35rem;border-radius:4px;border:1px solid #8886;margin-left:.35rem;font-size:.75rem}}\n\
         pre{{white-space:pre-wrap;word-break:break-word;margin:.35rem 0 0;font-family:ui-monospace,SFMono-Regular,monospace;font-size:.9rem}}\n\
         details{{margin-top:.5rem}} summary{{cursor:pointer;font-size:.85rem;opacity:.85}}\n\
         ul.tool-calls{{margin:.4rem 0 0 1.25rem;padding:0;font-family:ui-monospace,monospace;font-size:.85rem}}\n\
         </style>\n</head>\n<body>\n\
         <header><h1>Session {esc_sid}</h1>\n\
         <p>Conversation #{esc_cid} · through entry #{esc_last}</p></header>\n<main>\n"
    )
}

fn write_html_entry<W: Write>(writer: &mut W, entry: &TranscriptEntry) -> std::io::Result<()> {
    let esc_id = escape_html(&entry.id);
    let esc_kind = escape_html(&entry.kind);
    let seq_badge = entry
        .seq
        .map(|s| format!("<span class=\"badge\">seq {s}</span>"))
        .unwrap_or_default();

    write!(
        writer,
        "<article class=\"entry\" id=\"entry-{esc_id}\" data-kind=\"{esc_kind}\">\n\
         <div class=\"entry-head\">{esc_kind} #{esc_id}{seq_badge}"
    )?;

    if entry.data.get("aborted").and_then(Value::as_bool) == Some(true) {
        write!(writer, "<span class=\"badge\">aborted</span>")?;
    }

    if entry.kind == "tool_result" {
        let tool_name = entry
            .data
            .get("tool_name")
            .or_else(|| entry.data.get("name"))
            .and_then(Value::as_str)
            .unwrap_or("tool");
        write!(
            writer,
            "<span class=\"badge\">{}</span>",
            escape_html(tool_name)
        )?;
        let is_err = entry
            .data
            .get("is_error")
            .and_then(Value::as_bool)
            .unwrap_or(false)
            || entry.data.get("error").is_some_and(|v| !v.is_null());
        if is_err {
            write!(writer, "<span class=\"badge\">error</span>")?;
        }
    }

    writeln!(writer, "</div>")?;

    for thinking in extract_thinking_blocks(&entry.data) {
        writeln!(
            writer,
            "<details><summary>Thinking</summary><pre>{}</pre></details>",
            escape_html(&thinking)
        )?;
    }

    let body = entry_body_text(entry);
    if !body.is_empty() {
        writeln!(writer, "<pre>{}</pre>", escape_html(&body))?;
    }

    let tool_calls = extract_tool_calls(&entry.data);
    if !tool_calls.is_empty() {
        writeln!(writer, "<ul class=\"tool-calls\">")?;
        for (name, call_id) in tool_calls {
            match call_id {
                Some(cid) => writeln!(
                    writer,
                    "<li>tool_call: {} ({})</li>",
                    escape_html(&name),
                    escape_html(&cid)
                )?,
                None => writeln!(writer, "<li>tool_call: {}</li>", escape_html(&name))?,
            }
        }
        writeln!(writer, "</ul>")?;
    }

    writeln!(writer, "</article>")
}

fn write_html_footer<W: Write>(writer: &mut W, count: usize) -> std::io::Result<()> {
    writeln!(
        writer,
        "</main>\n<footer>Exported {count} entr{}</footer>\n</body>\n</html>",
        if count == 1 { "y" } else { "ies" }
    )
}

fn entry_body_text(entry: &TranscriptEntry) -> String {
    let text = extract_entry_text(&entry.data);
    if !text.is_empty() {
        return text;
    }
    match entry.kind.as_str() {
        "tool_result" => entry
            .data
            .get("output")
            .or_else(|| entry.data.get("result"))
            .or_else(|| entry.data.get("error"))
            .map(value_to_string)
            .unwrap_or_default(),
        "compaction" | "reset" | "handoff" => entry
            .data
            .get("summary")
            .or_else(|| entry.data.get("note"))
            .or_else(|| entry.data.get("reason"))
            .map(value_to_string)
            .unwrap_or_else(|| entry.data.to_string()),
        _ => {
            if extract_tool_calls(&entry.data).is_empty()
                && !entry.data.is_null()
                && entry.data != Value::Object(Default::default())
            {
                entry.data.to_string()
            } else {
                String::new()
            }
        }
    }
}

fn value_to_string(val: &Value) -> String {
    match val {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn extract_thinking_blocks(data: &Value) -> Vec<String> {
    let Some(items) = data.get("content").and_then(Value::as_array) else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| {
            let obj = item.as_object()?;
            if obj.get("type").and_then(Value::as_str) != Some("thinking") {
                return None;
            }
            obj.get("thinking")
                .or_else(|| obj.get("text"))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        })
        .collect()
}

pub fn escape_html(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{DaemonTarget, SecretToken};
    use serde_json::json;
    use std::io::Read;
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::thread;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    fn temp_path(name: &str, ext: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("h-export-test-{name}-{nanos}.{ext}"))
    }

    fn write_http_json(stream: &mut std::os::unix::net::UnixStream, status: &str, body: &str) {
        write!(
            stream,
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
            body.len(),
            body
        )
        .unwrap();
        stream.flush().unwrap();
    }

    fn read_request_line(stream: &mut std::os::unix::net::UnixStream) -> String {
        let mut buf = [0u8; 4096];
        let n = stream.read(&mut buf).unwrap();
        String::from_utf8_lossy(&buf[..n])
            .lines()
            .next()
            .unwrap_or_default()
            .to_string()
    }

    #[test]
    fn escape_html_escapes_all_special_characters() {
        let raw = r#"<script>alert("xss" & 'evil')</script>"#;
        assert_eq!(
            escape_html(raw),
            "&lt;script&gt;alert(&quot;xss&quot; &amp; &#39;evil&#39;)&lt;/script&gt;"
        );
    }

    #[test]
    fn export_jsonl_walks_asc_pages_only_through_pinned_last_and_sets_private_mode() {
        let sock = temp_path("jsonl", "sock");
        let out_path = temp_path("out", "jsonl");
        let _ = fs::remove_file(&sock);
        let _ = fs::remove_file(&out_path);
        let listener = UnixListener::bind(&sock).unwrap();

        let server = thread::spawn(move || {
            // Page 1: no cursor, returns entries 1 and 2, next_cursor = "2"
            let (mut s1, _) = listener.accept().unwrap();
            let req1 = read_request_line(&mut s1);
            assert!(
                req1.contains("order=asc") && !req1.contains("cursor="),
                "unexpected first request: {req1}"
            );
            let body1 = json!({
                "items": [
                    {"id": "1", "conversation_id": "1", "seq": 1, "kind": "user", "data": {"content": [{"type": "text", "text": "one"}]}},
                    {"id": "2", "conversation_id": "1", "seq": 2, "kind": "assistant", "data": {"content": [{"type": "text", "text": "two"}]}}
                ],
                "next_cursor": "2"
            })
            .to_string();
            write_http_json(&mut s1, "200 OK", &body1);

            // Page 2: cursor=2, returns entries 3, 4, 5 with next_cursor = "5".
            // Caller pinned last="4", so entry 5 must be excluded and page 3 must never be fetched.
            let (mut s2, _) = listener.accept().unwrap();
            let req2 = read_request_line(&mut s2);
            assert!(
                req2.contains("order=asc") && req2.contains("cursor=2"),
                "unexpected second request: {req2}"
            );
            let body2 = json!({
                "items": [
                    {"id": "3", "conversation_id": "1", "seq": 3, "kind": "user", "data": {"content": [{"type": "text", "text": "three"}]}},
                    {"id": "4", "conversation_id": "1", "seq": 4, "kind": "assistant", "data": {"content": [{"type": "text", "text": "four"}]}},
                    {"id": "5", "conversation_id": "1", "seq": 5, "kind": "user", "data": {"content": [{"type": "text", "text": "concurrent-after-last"}]}}
                ],
                "next_cursor": "5"
            })
            .to_string();
            write_http_json(&mut s2, "200 OK", &body2);
        });

        let client = DaemonClient::new(
            DaemonTarget::UnixSocket(sock.clone()),
            SecretToken::new("tok-export").unwrap(),
        );
        let count = export(&client, "demo", "1", "4", &out_path).unwrap();
        assert_eq!(count, 4);

        server.join().unwrap();

        #[cfg(unix)]
        {
            let mode = fs::metadata(&out_path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }

        let content = fs::read_to_string(&out_path).unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(lines.len(), 4);
        let parsed: Vec<TranscriptEntry> = lines
            .iter()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        let ids: Vec<&str> = parsed.iter().map(|e| e.id.as_str()).collect();
        assert_eq!(ids, vec!["1", "2", "3", "4"]);
        assert!(!content.contains("concurrent-after-last"));

        let _ = fs::remove_file(&sock);
        let _ = fs::remove_file(&out_path);
    }

    #[test]
    fn export_html_escapes_untrusted_entries_and_attributes() {
        let sock = temp_path("html", "sock");
        let out_path = temp_path("out", "html");
        let _ = fs::remove_file(&sock);
        let _ = fs::remove_file(&out_path);
        let listener = UnixListener::bind(&sock).unwrap();

        let server = thread::spawn(move || {
            let (mut s1, _) = listener.accept().unwrap();
            let _ = read_request_line(&mut s1);
            let body = json!({
                "items": [
                    {
                        "id": "1\" onclick=\"alert(1)",
                        "conversation_id": "1",
                        "seq": 1,
                        "kind": "user<img src=x onerror=alert(1)>",
                        "data": {"content": [{"type": "text", "text": "<script>alert('xss')</script> & \"quoted\""}]}
                    },
                    {
                        "id": "2",
                        "conversation_id": "1",
                        "seq": 2,
                        "kind": "assistant",
                        "data": {
                            "content": [
                                {"type": "thinking", "thinking": "<svg onload=alert(1)>"},
                                {"type": "text", "text": "ok"}
                            ],
                            "tool_calls": [{"id": "c<1>", "name": "bash\"x"}]
                        }
                    },
                    {
                        "id": "3",
                        "conversation_id": "1",
                        "seq": 3,
                        "kind": "tool_result",
                        "data": {"tool_name": "<bad>", "is_error": true, "output": "err & <tag>"}
                    }
                ],
                "next_cursor": null
            })
            .to_string();
            write_http_json(&mut s1, "200 OK", &body);
        });

        let client = DaemonClient::new(
            DaemonTarget::UnixSocket(sock.clone()),
            SecretToken::new("tok-html").unwrap(),
        );
        let count = export(&client, "demo", "1", "3", &out_path).unwrap();
        assert_eq!(count, 3);
        server.join().unwrap();

        let html = fs::read_to_string(&out_path).unwrap();
        assert!(html.starts_with("<!DOCTYPE html>"));
        assert!(!html.contains("<script>"));
        assert!(!html.contains("<svg "));
        assert!(!html.contains("<img "));
        assert!(!html.contains("onclick=\"alert(1)"));
        assert!(html.contains("&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"));
        assert!(html.contains("&lt;svg onload=alert(1)&gt;"));
        assert!(html.contains("bash&quot;x"));
        assert!(html.contains("err &amp; &lt;tag&gt;"));

        let _ = fs::remove_file(&sock);
        let _ = fs::remove_file(&out_path);
    }

    #[test]
    fn export_refuses_overwrite_and_cleans_up_on_errors() {
        // 1. Existing file is never overwritten
        let existing = temp_path("existing", "jsonl");
        fs::write(&existing, "keep-intact\n").unwrap();
        let unused_sock = temp_path("unused", "sock");
        let client = DaemonClient::new(
            DaemonTarget::UnixSocket(unused_sock),
            SecretToken::new("tok").unwrap(),
        );
        let err = export(&client, "demo", "1", "1", &existing).unwrap_err();
        assert!(err.contains("failed to create export file"));
        assert_eq!(fs::read_to_string(&existing).unwrap(), "keep-intact\n");
        let _ = fs::remove_file(&existing);

        // 2. Empty inputs fail without creating file
        let never_created = temp_path("empty-last", "jsonl");
        assert!(export(&client, "demo", "1", "", &never_created).is_err());
        assert!(!never_created.exists());

        // 3. Mid-stream HTTP 500 cleans up partial file
        let sock_err = temp_path("err", "sock");
        let partial_path = temp_path("partial", "jsonl");
        let _ = fs::remove_file(&sock_err);
        let _ = fs::remove_file(&partial_path);
        let listener = UnixListener::bind(&sock_err).unwrap();

        let server_err = thread::spawn(move || {
            let (mut s1, _) = listener.accept().unwrap();
            let _ = read_request_line(&mut s1);
            let body1 = json!({
                "items": [{"id": "1", "kind": "user", "data": {"text": "hi"}}],
                "next_cursor": "1"
            })
            .to_string();
            write_http_json(&mut s1, "200 OK", &body1);

            let (mut s2, _) = listener.accept().unwrap();
            let _ = read_request_line(&mut s2);
            write_http_json(&mut s2, "500 Internal Server Error", r#"{"error":"boom"}"#);
        });

        let client_err = DaemonClient::new(
            DaemonTarget::UnixSocket(sock_err.clone()),
            SecretToken::new("tok").unwrap(),
        );
        let err = export(&client_err, "demo", "1", "5", &partial_path).unwrap_err();
        assert!(err.contains("500"));
        assert!(!partial_path.exists());
        server_err.join().unwrap();
        let _ = fs::remove_file(&sock_err);

        // 4. Missing pinned last entry cleans up partial file
        let sock_missing = temp_path("missing", "sock");
        let missing_path = temp_path("missing", "html");
        let _ = fs::remove_file(&sock_missing);
        let _ = fs::remove_file(&missing_path);
        let listener2 = UnixListener::bind(&sock_missing).unwrap();

        let server_missing = thread::spawn(move || {
            let (mut s1, _) = listener2.accept().unwrap();
            let _ = read_request_line(&mut s1);
            let body = json!({
                "items": [{"id": "1", "kind": "user", "data": {"text": "hi"}}],
                "next_cursor": null
            })
            .to_string();
            write_http_json(&mut s1, "200 OK", &body);
        });

        let client_missing = DaemonClient::new(
            DaemonTarget::UnixSocket(sock_missing.clone()),
            SecretToken::new("tok").unwrap(),
        );
        let err = export(&client_missing, "demo", "1", "99", &missing_path).unwrap_err();
        assert!(err.contains("not found"));
        assert!(!missing_path.exists());
        server_missing.join().unwrap();
        let _ = fs::remove_file(&sock_missing);

        // 5. Stalled pagination cursor fails and cleans up partial file
        let sock_stall = temp_path("stall", "sock");
        let stall_path = temp_path("stall", "jsonl");
        let _ = fs::remove_file(&sock_stall);
        let _ = fs::remove_file(&stall_path);
        let listener3 = UnixListener::bind(&sock_stall).unwrap();

        let server_stall = thread::spawn(move || {
            let (mut s1, _) = listener3.accept().unwrap();
            let _ = read_request_line(&mut s1);
            let body1 = json!({
                "items": [{"id": "1", "kind": "user", "data": {"text": "hi"}}],
                "next_cursor": "1"
            })
            .to_string();
            write_http_json(&mut s1, "200 OK", &body1);

            let (mut s2, _) = listener3.accept().unwrap();
            let _ = read_request_line(&mut s2);
            let body2 = json!({
                "items": [],
                "next_cursor": "1"
            })
            .to_string();
            write_http_json(&mut s2, "200 OK", &body2);
        });

        let client_stall = DaemonClient::new(
            DaemonTarget::UnixSocket(sock_stall.clone()),
            SecretToken::new("tok").unwrap(),
        );
        let err = export(&client_stall, "demo", "1", "99", &stall_path).unwrap_err();
        assert!(err.contains("cursor"));
        assert!(!stall_path.exists());
        server_stall.join().unwrap();
        let _ = fs::remove_file(&sock_stall);
    }
}
