use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};
use std::fmt;

fn de_string_or_u64<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum StrOrNum {
        Str(String),
        Num(u64),
        Int(i64),
    }

    match StrOrNum::deserialize(deserializer)? {
        StrOrNum::Str(s) => Ok(s),
        StrOrNum::Num(n) => Ok(n.to_string()),
        StrOrNum::Int(n) => Ok(n.to_string()),
    }
}

fn de_opt_string_or_u64<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum OptStrOrNum {
        Str(String),
        Num(u64),
        Int(i64),
    }

    match Option::<OptStrOrNum>::deserialize(deserializer)? {
        None => Ok(None),
        Some(OptStrOrNum::Str(s)) => {
            if s.is_empty() {
                Ok(None)
            } else {
                Ok(Some(s))
            }
        }
        Some(OptStrOrNum::Num(n)) => Ok(Some(n.to_string())),
        Some(OptStrOrNum::Int(n)) => Ok(Some(n.to_string())),
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct EnvironmentInfo {
    pub id: String,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub default_cwd: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct EnvironmentsResponse {
    pub environments: Vec<EnvironmentInfo>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct ModelInfo {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub provider: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct ModelsResponse {
    pub models: Vec<ModelInfo>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct SessionSummary {
    pub session_id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub env_id: Option<String>,
    #[serde(default)]
    pub harness_id: Option<String>,
    pub cwd: String,
    #[serde(default, deserialize_with = "de_opt_string_or_u64")]
    pub root_conversation_id: Option<String>,
    #[serde(default)]
    pub created_at: Option<i64>,
    #[serde(default)]
    pub updated_at: Option<i64>,
    #[serde(default)]
    pub active: bool,
    #[serde(default)]
    pub next_wake_at: Option<i64>,
    #[serde(default)]
    pub status: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct SessionsResponse {
    pub sessions: Vec<SessionSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CreateSessionRequest {
    pub version: u32,
    pub request_id: String,
    pub env_id: String,
    pub cwd: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent: Option<Value>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct CreateSessionResponse {
    pub session: SessionSummary,
    pub seq: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct ConversationParent {
    #[serde(deserialize_with = "de_string_or_u64")]
    pub conversation_id: String,
    #[serde(deserialize_with = "de_string_or_u64")]
    pub at: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct ConversationInfo {
    #[serde(deserialize_with = "de_string_or_u64")]
    pub id: String,
    #[serde(default)]
    pub parent: Option<ConversationParent>,
    #[serde(default)]
    pub owner: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct SessionDetailResponse {
    pub session: SessionSummary,
    #[serde(default)]
    pub conversations: Vec<ConversationInfo>,
    #[serde(default)]
    pub tasks: Vec<Value>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct TranscriptEntry {
    #[serde(deserialize_with = "de_string_or_u64")]
    pub id: String,
    #[serde(default, deserialize_with = "de_opt_string_or_u64")]
    pub conversation_id: Option<String>,
    #[serde(default)]
    pub seq: Option<u64>,
    pub kind: String,
    #[serde(default)]
    pub data: Value,
    #[serde(default)]
    pub created_at: Option<i64>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct EntriesPageResponse {
    pub items: Vec<TranscriptEntry>,
    #[serde(default, deserialize_with = "de_opt_string_or_u64")]
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TextContentBlock {
    #[serde(rename = "type")]
    pub kind: String,
    pub text: String,
}

impl TextContentBlock {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            kind: "text".to_string(),
            text: text.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum WhenBusy {
    FollowUp,
    Steer,
    Reject,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum WhenIdle {
    Start,
    Reject,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CommandEnvelope {
    pub version: u32,
    pub request_id: String,
    pub command: String,
    pub conversation_id: u64,
    pub args: Value,
}

impl CommandEnvelope {
    pub fn submit_input(
        request_id: impl Into<String>,
        conversation_id: u64,
        text: impl Into<String>,
        when_busy: WhenBusy,
        when_idle: WhenIdle,
    ) -> Self {
        Self {
            version: 1,
            request_id: request_id.into(),
            command: "submit".to_string(),
            conversation_id,
            args: serde_json::json!({
                "type": "input",
                "content": [TextContentBlock::text(text)],
                "when_busy": when_busy,
                "when_idle": when_idle,
            }),
        }
    }

    pub fn submit_continue(request_id: impl Into<String>, conversation_id: u64) -> Self {
        Self {
            version: 1,
            request_id: request_id.into(),
            command: "submit".to_string(),
            conversation_id,
            args: serde_json::json!({
                "type": "continue"
            }),
        }
    }

    pub fn abort(
        request_id: impl Into<String>,
        conversation_id: u64,
        reason: Option<&str>,
    ) -> Self {
        let mut args = Map::new();
        if let Some(r) = reason {
            args.insert("reason".to_string(), Value::String(r.to_string()));
        }
        Self {
            version: 1,
            request_id: request_id.into(),
            command: "abort".to_string(),
            conversation_id,
            args: Value::Object(args),
        }
    }

    pub fn fork(request_id: impl Into<String>, conversation_id: u64, at_entry_id: u64) -> Self {
        Self {
            version: 1,
            request_id: request_id.into(),
            command: "fork".to_string(),
            conversation_id,
            args: serde_json::json!({
                "at_entry_id": at_entry_id
            }),
        }
    }

    pub fn configure(
        request_id: impl Into<String>,
        conversation_id: u64,
        model: Option<&str>,
        thinking: Option<&str>,
    ) -> Self {
        let mut args = Map::new();
        if let Some(m) = model {
            args.insert("model".to_string(), Value::String(m.to_string()));
        }
        if let Some(t) = thinking {
            args.insert("thinking".to_string(), Value::String(t.to_string()));
        }
        Self {
            version: 1,
            request_id: request_id.into(),
            command: "configure".to_string(),
            conversation_id,
            args: Value::Object(args),
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct CommandReceipt {
    #[serde(default)]
    pub version: Option<u32>,
    pub request_id: String,
    #[serde(default)]
    pub seq: Option<u64>,
    #[serde(default, deserialize_with = "de_opt_string_or_u64")]
    pub submission_id: Option<String>,
    #[serde(default, deserialize_with = "de_opt_string_or_u64")]
    pub conversation_id: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct ErrorResponse {
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub reason: Option<Value>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct SnapshotFrame {
    #[serde(default)]
    pub version: Option<u32>,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default, deserialize_with = "de_opt_string_or_u64")]
    pub conversation_id: Option<String>,
    pub seq: u64,
    #[serde(default, deserialize_with = "de_opt_string_or_u64")]
    pub before_entry_id: Option<String>,
    #[serde(default)]
    pub has_more: Option<bool>,
    #[serde(default)]
    pub entries: Vec<TranscriptEntry>,
    #[serde(default)]
    pub docs: Option<Value>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct CommitFrame {
    #[serde(default)]
    pub version: Option<u32>,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default, deserialize_with = "de_opt_string_or_u64")]
    pub conversation_id: Option<String>,
    #[serde(default)]
    pub prev_seq: Option<u64>,
    pub seq: u64,
    #[serde(default)]
    pub appended_entries: Vec<TranscriptEntry>,
    #[serde(default)]
    pub doc_ops: Option<Map<String, Value>>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct EphemeralFrame {
    #[serde(default)]
    pub version: Option<u32>,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default, deserialize_with = "de_opt_string_or_u64")]
    pub conversation_id: Option<String>,
    pub base_seq: u64,
    #[serde(default)]
    pub doc_ops: Option<Map<String, Value>>,
    #[serde(default)]
    pub ops: Option<Vec<Value>>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ServerFrame {
    Snapshot(SnapshotFrame),
    Commit(CommitFrame),
    Ephemeral(EphemeralFrame),
    Unknown { event: Option<String>, data: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SseEvent {
    pub id: Option<String>,
    pub event: Option<String>,
    pub data: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum FrameDecodeError {
    InvalidJson(String),
}

impl fmt::Display for FrameDecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FrameDecodeError::InvalidJson(msg) => write!(f, "invalid SSE frame JSON: {msg}"),
        }
    }
}

impl std::error::Error for FrameDecodeError {}

impl SseEvent {
    pub fn decode_frame(&self) -> Result<ServerFrame, FrameDecodeError> {
        match self.event.as_deref() {
            Some("snapshot") => {
                let frame: SnapshotFrame = serde_json::from_str(&self.data)
                    .map_err(|e| FrameDecodeError::InvalidJson(e.to_string()))?;
                Ok(ServerFrame::Snapshot(frame))
            }
            Some("commit") => {
                let frame: CommitFrame = serde_json::from_str(&self.data)
                    .map_err(|e| FrameDecodeError::InvalidJson(e.to_string()))?;
                Ok(ServerFrame::Commit(frame))
            }
            Some("ephemeral") => {
                let frame: EphemeralFrame = serde_json::from_str(&self.data)
                    .map_err(|e| FrameDecodeError::InvalidJson(e.to_string()))?;
                Ok(ServerFrame::Ephemeral(frame))
            }
            _ => Ok(ServerFrame::Unknown {
                event: self.event.clone(),
                data: self.data.clone(),
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SseLimitError {
    LineTooLarge { max_bytes: usize },
    EventTooLarge { max_bytes: usize },
}

impl fmt::Display for SseLimitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SseLimitError::LineTooLarge { max_bytes } => {
                write!(f, "SSE line exceeds {max_bytes} byte limit")
            }
            SseLimitError::EventTooLarge { max_bytes } => {
                write!(f, "SSE event exceeds {max_bytes} byte limit")
            }
        }
    }
}

impl std::error::Error for SseLimitError {}

pub const DEFAULT_MAX_SSE_LINE_BYTES: usize = 16 * 1024 * 1024;
pub const DEFAULT_MAX_SSE_EVENT_BYTES: usize = 32 * 1024 * 1024;
const MAX_SSE_META_BYTES: usize = 4096;

#[derive(Debug)]
pub struct SseParser {
    line_buf: Vec<u8>,
    event_name: Option<String>,
    event_id: Option<String>,
    data_lines: Vec<String>,
    has_fields: bool,
    event_bytes: usize,
    max_line_bytes: usize,
    max_event_bytes: usize,
}

impl Default for SseParser {
    fn default() -> Self {
        Self::with_limits(DEFAULT_MAX_SSE_LINE_BYTES, DEFAULT_MAX_SSE_EVENT_BYTES)
    }
}

impl SseParser {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_limits(max_line_bytes: usize, max_event_bytes: usize) -> Self {
        Self {
            line_buf: Vec::new(),
            event_name: None,
            event_id: None,
            data_lines: Vec::new(),
            has_fields: false,
            event_bytes: 0,
            max_line_bytes: max_line_bytes.max(1),
            max_event_bytes: max_event_bytes.max(1),
        }
    }

    pub fn push_bytes(&mut self, bytes: &[u8]) -> Vec<SseEvent> {
        self.try_push_bytes(bytes).unwrap_or_default()
    }

    pub fn try_push_bytes(&mut self, bytes: &[u8]) -> Result<Vec<SseEvent>, SseLimitError> {
        let mut out = Vec::new();
        for &b in bytes {
            if b == b'\n' {
                if self.line_buf.last() == Some(&b'\r') {
                    self.line_buf.pop();
                }
                let line = String::from_utf8_lossy(&self.line_buf).into_owned();
                self.line_buf.clear();
                if let Some(ev) = self.process_line(&line)? {
                    out.push(ev);
                }
            } else {
                if self.line_buf.len() >= self.max_line_bytes {
                    self.reset_state();
                    return Err(SseLimitError::LineTooLarge {
                        max_bytes: self.max_line_bytes,
                    });
                }
                self.line_buf.push(b);
            }
        }
        Ok(out)
    }

    pub fn finish(&mut self) -> Option<SseEvent> {
        self.try_finish().ok().flatten()
    }

    pub fn try_finish(&mut self) -> Result<Option<SseEvent>, SseLimitError> {
        if !self.line_buf.is_empty() {
            if self.line_buf.last() == Some(&b'\r') {
                self.line_buf.pop();
            }
            let line = String::from_utf8_lossy(&self.line_buf).into_owned();
            self.line_buf.clear();
            if let Some(ev) = self.process_line(&line)? {
                return Ok(Some(ev));
            }
        }
        Ok(self.flush_event())
    }

    fn reset_state(&mut self) {
        self.line_buf.clear();
        self.event_name = None;
        self.event_id = None;
        self.data_lines.clear();
        self.has_fields = false;
        self.event_bytes = 0;
    }

    fn process_line(&mut self, line: &str) -> Result<Option<SseEvent>, SseLimitError> {
        if line.is_empty() {
            return Ok(self.flush_event());
        }
        if line.starts_with(':') {
            return Ok(None);
        }
        let (field, raw_val) = match line.split_once(':') {
            Some((f, v)) => (f, v.strip_prefix(' ').unwrap_or(v)),
            None => (line, ""),
        };

        match field {
            "event" => {
                if raw_val.len() > MAX_SSE_META_BYTES.min(self.max_event_bytes) {
                    self.reset_state();
                    return Err(SseLimitError::EventTooLarge {
                        max_bytes: self.max_event_bytes,
                    });
                }
                let prev_len = self.event_name.as_ref().map_or(0, String::len);
                let next_bytes = self
                    .event_bytes
                    .saturating_sub(prev_len)
                    .saturating_add(raw_val.len());
                if next_bytes > self.max_event_bytes {
                    self.reset_state();
                    return Err(SseLimitError::EventTooLarge {
                        max_bytes: self.max_event_bytes,
                    });
                }
                self.event_bytes = next_bytes;
                self.event_name = Some(raw_val.to_string());
                self.has_fields = true;
            }
            "id" => {
                if !raw_val.contains('\0') {
                    if raw_val.len() > MAX_SSE_META_BYTES.min(self.max_event_bytes) {
                        self.reset_state();
                        return Err(SseLimitError::EventTooLarge {
                            max_bytes: self.max_event_bytes,
                        });
                    }
                    let prev_len = self.event_id.as_ref().map_or(0, String::len);
                    let next_bytes = self
                        .event_bytes
                        .saturating_sub(prev_len)
                        .saturating_add(raw_val.len());
                    if next_bytes > self.max_event_bytes {
                        self.reset_state();
                        return Err(SseLimitError::EventTooLarge {
                            max_bytes: self.max_event_bytes,
                        });
                    }
                    self.event_bytes = next_bytes;
                    self.event_id = Some(raw_val.to_string());
                    self.has_fields = true;
                }
            }
            "data" => {
                let sep = usize::from(!self.data_lines.is_empty());
                let next_bytes = self
                    .event_bytes
                    .saturating_add(raw_val.len())
                    .saturating_add(sep);
                if next_bytes > self.max_event_bytes {
                    self.reset_state();
                    return Err(SseLimitError::EventTooLarge {
                        max_bytes: self.max_event_bytes,
                    });
                }
                self.event_bytes = next_bytes;
                self.data_lines.push(raw_val.to_string());
                self.has_fields = true;
            }
            _ => {}
        }
        Ok(None)
    }

    fn flush_event(&mut self) -> Option<SseEvent> {
        if !self.has_fields && self.data_lines.is_empty() {
            self.event_name = None;
            self.event_id = None;
            self.event_bytes = 0;
            return None;
        }
        let event = self.event_name.take();
        let id = self.event_id.take();
        let data = self.data_lines.join("\n");
        self.data_lines.clear();
        self.has_fields = false;
        self.event_bytes = 0;
        Some(SseEvent { id, event, data })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_envelope_serializes_v1_shape() {
        let env = CommandEnvelope::submit_input(
            "req-1",
            1,
            "hello world",
            WhenBusy::FollowUp,
            WhenIdle::Start,
        );
        let val = serde_json::to_value(&env).unwrap();
        assert_eq!(val["version"], 1);
        assert_eq!(val["request_id"], "req-1");
        assert_eq!(val["command"], "submit");
        assert_eq!(val["conversation_id"], 1);
        assert_eq!(val["args"]["type"], "input");
        assert_eq!(val["args"]["when_busy"], "follow_up");
        assert_eq!(val["args"]["when_idle"], "start");
        assert_eq!(val["args"]["content"][0]["type"], "text");
        assert_eq!(val["args"]["content"][0]["text"], "hello world");
    }

    #[test]
    fn sse_parser_handles_chunked_frames_comments_and_multiline_data() {
        let mut parser = SseParser::new();

        let stream = concat!(
            ": keepalive\n\n",
            "id: 4\r\n",
            "event: snapshot\r\n",
            "data: {\"seq\":4,\"entries\":[],\"docs\":{}}\r\n\r\n",
            "event: ephemeral\n",
            "data: {\"base_seq\":4,\n",
            "data: \"ops\":[[\"set\",[\"x\"],1]]}\n\n"
        );

        let mut events = Vec::new();
        for chunk in stream.as_bytes().chunks(7) {
            events.extend(parser.push_bytes(chunk));
        }
        assert_eq!(events.len(), 2);

        assert_eq!(events[0].id.as_deref(), Some("4"));
        assert_eq!(events[0].event.as_deref(), Some("snapshot"));
        match events[0].decode_frame().unwrap() {
            ServerFrame::Snapshot(s) => assert_eq!(s.seq, 4),
            other => panic!("unexpected frame: {other:?}"),
        }

        assert_eq!(events[1].id, None);
        assert_eq!(events[1].event.as_deref(), Some("ephemeral"));
        match events[1].decode_frame().unwrap() {
            ServerFrame::Ephemeral(e) => {
                assert_eq!(e.base_seq, 4);
                assert!(e.ops.is_some());
            }
            other => panic!("unexpected frame: {other:?}"),
        }
    }

    #[test]
    fn session_and_entry_deserialize_numeric_or_string_ids() {
        let json = r#"{
            "session_id": "proj-1",
            "cwd": "/tmp/proj",
            "root_conversation_id": 1,
            "active": true
        }"#;
        let sess: SessionSummary = serde_json::from_str(json).unwrap();
        assert_eq!(sess.root_conversation_id.as_deref(), Some("1"));
        assert!(sess.active);

        let entry_json =
            r#"{"id": 12, "conversation_id": 1, "kind": "assistant", "data": {"text": "ok"}}"#;
        let entry: TranscriptEntry = serde_json::from_str(entry_json).unwrap();
        assert_eq!(entry.id, "12");
        assert_eq!(entry.conversation_id.as_deref(), Some("1"));
    }

    #[test]
    fn sse_parser_enforces_line_and_event_bounds() {
        let mut line_parser = SseParser::with_limits(16, 128);
        let err = line_parser
            .try_push_bytes(b"data: 0123456789abcdef")
            .unwrap_err();
        assert_eq!(err, SseLimitError::LineTooLarge { max_bytes: 16 });

        // State is clean after error and can parse a valid bounded event.
        let ok = line_parser
            .try_push_bytes(b"event: commit\ndata: ok\n\n")
            .unwrap();
        assert_eq!(ok.len(), 1);
        assert_eq!(ok[0].data, "ok");

        let mut ev_parser = SseParser::with_limits(64, 20);
        let err = ev_parser
            .try_push_bytes(b"data: 1234567890\ndata: 1234567890\n\n")
            .unwrap_err();
        assert_eq!(err, SseLimitError::EventTooLarge { max_bytes: 20 });

        let ok2 = ev_parser.try_push_bytes(b"data: small\n\n").unwrap();
        assert_eq!(ok2.len(), 1);
        assert_eq!(ok2[0].data, "small");
    }
}
