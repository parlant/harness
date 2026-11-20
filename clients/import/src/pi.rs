use crate::{Result, Revision};
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::io::{BufRead, Read};

const MAX_SOURCE_LINE: usize = 128 * 1024 * 1024;
pub const MAX_LINE: usize = 15 * 1024 * 1024;
const FRAGMENT_BYTES: usize = 512 * 1024;

pub struct Session<R> {
    reader: R,
    buffer: Vec<u8>,
    header: Value,
    first_entry: Option<Value>,
    version: u64,
    ordinal: u64,
    ids: HashMap<String, u64>,
    has_title: bool,
}

impl<R: BufRead> Session<R> {
    pub fn open(mut reader: R) -> Result<Self> {
        let mut buffer = Vec::new();
        let first = read_record(&mut reader, &mut buffer)?.ok_or("empty session file")?;
        let (mut header, first_entry) = if first["type"] == "session" {
            (first, None)
        } else if first["type"] == "message" && first.get("parentId") == Some(&Value::Null) {
            // Old headerless exports start directly with a root message. There is no
            // workspace path or session UUID; the first entry identifies the log.
            let id = first["id"]
                .as_str()
                .filter(|s| !s.is_empty())
                .ok_or("missing root entry id")?;
            let timestamp = first["timestamp"]
                .as_str()
                .ok_or("missing root timestamp")?;
            (
                json!({"version": 2, "id": format!("headerless:{id}:{timestamp}"), "timestamp": timestamp, "cwd": "/"}),
                Some(first),
            )
        } else {
            return Err("invalid pi session header".into());
        };
        let version = header.get("version").map_or(Some(1), Value::as_u64);
        let version = version
            .filter(|v| (1..=3).contains(v))
            .ok_or("unsupported pi session version")?;
        if version == 1 && header["cwd"].is_null() {
            header["cwd"] = json!("/");
        }
        if header["id"].as_str().is_none_or(str::is_empty)
            || header["cwd"]
                .as_str()
                .is_none_or(|cwd| !cwd.starts_with('/'))
            || !header["timestamp"].is_string()
        {
            return Err("invalid pi session header".into());
        }
        Ok(Self {
            reader,
            buffer,
            header,
            first_entry,
            version,
            ordinal: 0,
            ids: HashMap::new(),
            has_title: false,
        })
    }

    pub fn id(&self) -> &str {
        self.header["id"].as_str().unwrap()
    }

    pub fn header(&self, (revision, size): Revision) -> Value {
        json!({"source":"pi", "source_id":self.id(), "cwd":self.header["cwd"], "created_at":self.header["timestamp"], "revision":revision, "size":size})
    }

    pub fn next_rows(&mut self) -> Result<Option<Vec<String>>> {
        let mut raw = match self.first_entry.take() {
            Some(row) => row,
            None => match read_record(&mut self.reader, &mut self.buffer)? {
                Some(row) => row,
                None => return Ok(None),
            },
        };
        let (external, parent) = if self.version == 1 {
            (None, (self.ordinal > 0).then_some(self.ordinal * 2))
        } else {
            let parent = match raw.get("parentId") {
                Some(Value::Null) => None,
                Some(Value::String(p)) => {
                    Some(*self.ids.get(p).ok_or("missing or out-of-order parentId")?)
                }
                _ => return Err("invalid parentId".into()),
            };
            let external = raw["id"]
                .as_str()
                .filter(|s| !s.is_empty())
                .ok_or("missing entry id")?;
            if self.ids.contains_key(external) {
                return Err("duplicate pi entry id".into());
            }
            (Some(external.to_owned()), parent)
        };
        let at = raw["timestamp"].clone();
        let ty = raw["type"].as_str().ok_or("missing entry type")?;
        let mut title = if ty == "session_info" {
            raw["name"].as_str().map(short_title)
        } else {
            None
        };
        let (kind, data) = match ty {
            "message" => message(raw["message"].take())?,
            "compaction" => (
                "compaction",
                json!({"summary": raw["summary"], "tokens_before": raw["tokensBefore"], "source_data": raw}),
            ),
            "branch_summary" => ("system", json!({"text":raw["summary"], "source_data":raw})),
            "custom_message" => (
                "system",
                json!({"content":normalize_content(raw["content"].take()), "custom_type":raw["customType"], "display":raw["display"]}),
            ),
            // Opaque extension state is not transcript content and may contain credentials.
            "custom" => (
                "system",
                json!({"text":"pi: custom extension state omitted", "custom_type":raw["customType"]}),
            ),
            _ => (
                "system",
                json!({"text":format!("pi: {ty}"), "source_data":raw}),
            ),
        };
        if kind == "user" && !self.has_title {
            title = data["content"]
                .as_str()
                .or_else(|| {
                    data["content"]
                        .as_array()?
                        .iter()
                        .find_map(|v| v["text"].as_str())
                })
                .map(short_title);
        }
        let mut row = json!({"parent":parent, "kind":kind, "data":data, "created_at":at});
        if let Some(title) = title.filter(|s| !s.is_empty()) {
            self.has_title = true;
            row["title"] = Value::String(title);
        }
        let rows = encode_rows(row, self.ordinal, MAX_LINE)?;
        self.ordinal += rows.len() as u64;
        if let Some(external) = external {
            self.ids.insert(external, self.ordinal * 2);
        }
        Ok(Some(rows))
    }
}

fn encode_rows(row: Value, ordinal: u64, max_line: usize) -> Result<Vec<String>> {
    let content = serde_json::to_string(&row)?;
    if content.len() <= max_line {
        return Ok(vec![content]);
    }
    // Keep large source records losslessly, without exceeding H's page/SSE limits.
    // Subsequent pi children inherit the entire chain, not just the first fragment.
    let mut rows = Vec::new();
    let mut parent = row["parent"].clone();
    let mut rest = content.as_str();
    while !rest.is_empty() {
        let split = rest.floor_char_boundary(FRAGMENT_BYTES.min(rest.len()));
        let (part, tail) = rest.split_at(split);
        let mut fragment = json!({"parent":parent, "kind":"system", "created_at":row["created_at"],
            "data":{"text":part, "archive_fragment":rows.len() + 1, "archive_fragment_last":tail.is_empty()}});
        if rows.is_empty() && row.get("title").is_some() {
            fragment["title"] = row["title"].clone();
        }
        rows.push(serde_json::to_string(&fragment)?);
        parent = json!((ordinal + rows.len() as u64) * 2);
        rest = tail;
    }
    Ok(rows)
}

fn read_record(reader: &mut impl BufRead, buffer: &mut Vec<u8>) -> Result<Option<Value>> {
    loop {
        buffer.clear();
        let count = (&mut *reader)
            .take((MAX_SOURCE_LINE + 1) as u64)
            .read_until(b'\n', buffer)?;
        if count == 0 {
            return Ok(None);
        }
        if count > MAX_SOURCE_LINE {
            return Err("pi record exceeds 128 MiB".into());
        }
        if buffer.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        return Ok(Some(serde_json::from_slice(buffer)?));
    }
}

fn short_title(value: &str) -> String {
    value
        .chars()
        .filter(|c| !c.is_control())
        .take(200)
        .collect::<String>()
        .trim()
        .to_owned()
}

fn message(message: Value) -> Result<(&'static str, Value)> {
    let mut data = match message {
        Value::Object(map) => map,
        _ => return Err("invalid message".into()),
    };
    let role = data.get("role").and_then(Value::as_str);
    let kind = match role {
        Some("user") => "user",
        Some("assistant") => "assistant",
        Some("toolResult") => "tool_result",
        Some("bashExecution") => "user_shell",
        Some(_) => "system",
        None => return Err("missing message role".into()),
    };
    // A deferred handle is provider state, not a transcript block.
    data.remove("deferred");
    if let Some(content) = data.remove("content") {
        let mut content = normalize_content(content);
        if kind == "assistant"
            && let Some(blocks) = content.as_array_mut()
        {
            let mut tools = Vec::new();
            blocks.retain(|block| {
                if block["type"] == "toolCall" {
                    tools.push(block.clone());
                    false
                } else {
                    true
                }
            });
            if !tools.is_empty() {
                data.insert("tool_calls".into(), Value::Array(tools));
            }
        }
        data.insert("content".into(), content);
    }
    match kind {
        "assistant" => rename(&mut data, "stopReason", "finish_reason"),
        "tool_result" => {
            rename(&mut data, "toolCallId", "tool_call_id");
            rename(&mut data, "toolName", "name");
            let error = data
                .get("isError")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            data.insert("is_error".into(), json!(error));
            data.insert("status".into(), json!(if error { "error" } else { "ok" }));
        }
        "user_shell" => {
            rename(&mut data, "exitCode", "exit_code");
            if let Some(exclude) = data.remove("excludeFromContext") {
                data.insert(
                    "include_in_context".into(),
                    json!(!exclude.as_bool().unwrap_or(false)),
                );
            }
        }
        _ => (),
    }
    Ok((kind, Value::Object(data)))
}

fn normalize_content(mut content: Value) -> Value {
    if let Some(blocks) = content.as_array_mut() {
        for block in blocks {
            if let Some(map) = block.as_object_mut() {
                match map.get("type").and_then(Value::as_str) {
                    Some("image") => rename(map, "mimeType", "media_type"),
                    Some("thinking") => rename(map, "thinking", "text"),
                    _ => (),
                }
            }
        }
    }
    content
}

fn rename(map: &mut Map<String, Value>, from: &str, to: &str) {
    if let Some(value) = map.remove(from) {
        map.insert(to.into(), value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_tree_tools_and_unknown_records() {
        let mut session = Session::open(&br#"{"type":"session","version":3,"id":"one","cwd":"/gone","timestamp":"2026-01-01T00:00:00Z"}
{"type":"message","id":"a","parentId":null,"timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":"hello"}}
{"type":"message","id":"b","parentId":"a","timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"},{"type":"toolCall","id":"call","name":"read","arguments":{}}]}}
{"type":"future","id":"c","parentId":"a","timestamp":"2026-01-01T00:00:02Z","anything":[1,2]}
"#[..]).unwrap();
        assert_eq!(session.id(), "one");
        let mut next = || {
            session
                .next_rows()
                .unwrap()
                .map(|rows| serde_json::from_str::<Value>(&rows[0]).unwrap())
        };
        let user = next().unwrap();
        assert_eq!(user["parent"], Value::Null);
        assert_eq!(user["title"], "hello");
        let assistant = next().unwrap();
        assert_eq!(assistant["parent"], 2);
        assert_eq!(assistant["data"]["tool_calls"][0]["id"], "call");
        let unknown = next().unwrap();
        assert_eq!(unknown["parent"], 2);
        assert_eq!(unknown["data"]["source_data"]["anything"], json!([1, 2]));
        assert!(next().is_none());
    }

    #[test]
    fn accepts_legacy_linear_and_headerless_sessions() {
        let rows = br#"{"type":"session","id":"v1","timestamp":"2026-01-01T00:00:00Z"}
{"type":"message","timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":"one"}}
{"type":"message","timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","content":"two"}}"#;
        let mut legacy = Session::open(&rows[..]).unwrap();
        assert_eq!(legacy.header((1, 1))["cwd"], "/");
        assert!(legacy.next_rows().unwrap().is_some());
        let second: Value = serde_json::from_str(&legacy.next_rows().unwrap().unwrap()[0]).unwrap();
        assert_eq!(second["parent"], 2);

        let mut headerless = Session::open(&br#"{"type":"message","id":"root","parentId":null,"timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":"root"}}"#[..]).unwrap();
        assert_eq!(headerless.id(), "headerless:root:2026-01-01T00:00:00Z");
        let first: Value =
            serde_json::from_str(&headerless.next_rows().unwrap().unwrap()[0]).unwrap();
        assert_eq!(first["data"]["content"], "root");
    }

    #[test]
    fn oversized_records_are_lossless_chained_fragments() {
        let row = json!({"parent":2, "kind":"tool_result", "created_at":7,
            "data":{"content":"界".repeat(FRAGMENT_BYTES)}});
        let rows = encode_rows(row.clone(), 1, 100).unwrap();
        assert!(rows.len() > 1);
        let mut original = String::new();
        for (i, part) in rows.iter().enumerate() {
            let part: Value = serde_json::from_str(part).unwrap();
            assert_eq!(part["parent"], (i + 1) * 2);
            assert_eq!(part["data"]["archive_fragment_last"], i + 1 == rows.len());
            original.push_str(part["data"]["text"].as_str().unwrap());
        }
        assert_eq!(serde_json::from_str::<Value>(&original).unwrap(), row);
    }
}
