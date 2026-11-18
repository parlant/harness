use crate::cli::generate_request_id;
use crate::client::{ClientError, DaemonClient};
use crate::protocol::{
    CommandEnvelope, CommandReceipt, CreateSessionRequest, CreateSessionResponse,
    EntriesPageResponse, SessionSummary,
};
use crate::render::sanitize_single_line;
use serde_json::{Map, Value};
use std::thread;
use std::time::Duration;

const AMBIGUOUS_IO_MAX_ATTEMPTS: usize = 3;
const RETRY_BACKOFF: Duration = Duration::from_millis(25);
const DEFAULT_ENTRIES_LIMIT: u32 = 50;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub sid: String,
    pub cid: String,
    pub cwd: String,
    pub env_id: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    Submit(CommandEnvelope),
    Sessions,
    Models,
    Branches,
    Earlier(String),
    Attach(String),
    New,
    Fork(u64),
    Configure(String, String),
    Abort,
    Continue,
    Environments,
    Branch(String),
    Export { last: String, path: String },
    Files(String),
    AttachFile(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Reply {
    Receipt(CommandReceipt),
    Menu(String, Vec<(String, String)>),
    Page(EntriesPageResponse),
    Target(Target),
    Message(String),
    Attachment(String, Value),
}

pub fn execute(
    client: &DaemonClient,
    target: &Target,
    seq: Option<u64>,
    effect: Effect,
) -> Result<Reply, String> {
    match effect {
        Effect::Export { last, path } => {
            super::export::export(client, &target.sid, &target.cid, &last, path.as_ref())
                .map(|n| Reply::Message(format!("Exported {n} entries to {path}")))
        }
        Effect::Files(prefix) => super::files::list(std::path::Path::new("."), &prefix)
            .map(|v| Reply::Menu("client files".into(), v))
            .map_err(|e| e.to_string()),
        Effect::AttachFile(path) => super::files::attach(std::path::Path::new("."), &path)
            .map(|v| Reply::Attachment(path, v))
            .map_err(|e| e.to_string()),
        Effect::Submit(envelope) => {
            if target.sid.trim().is_empty() {
                return Err("cannot submit command: missing session_id".to_string());
            }
            let receipt = post_command_with_retry(client, &target.sid, &envelope)?;
            Ok(Reply::Receipt(receipt))
        }

        Effect::Sessions => {
            let env_filter = (!target.env_id.trim().is_empty()).then_some(target.env_id.as_str());
            let mut sessions = if target.cwd.trim().is_empty() {
                client.list_sessions(env_filter, None, None)
            } else {
                client.list_sessions(env_filter, Some(target.cwd.as_str()), Some(false))
            }
            .map_err(|e| format_client_error(&e))?;

            sort_sessions_latest_first(&mut sessions);

            let choices = sessions
                .into_iter()
                .map(|s| {
                    let marker = if s.session_id == target.sid { "* " } else { "" };
                    let title = s
                        .title
                        .as_deref()
                        .map(str::trim)
                        .filter(|t| !t.is_empty())
                        .map(sanitize_single_line)
                        .unwrap_or_else(|| "(untitled)".to_string());
                    let status = if s.status.as_deref() == Some("quarantined") {
                        "quarantined"
                    } else if s.active {
                        "active"
                    } else {
                        "idle"
                    };
                    let label = format!(
                        "{marker}{} — {title} [{status}]",
                        sanitize_single_line(&s.session_id)
                    );
                    (s.session_id, label)
                })
                .collect();

            Ok(Reply::Menu("sessions".to_string(), choices))
        }

        Effect::Models => {
            let models = client.list_models().map_err(|e| format_client_error(&e))?;
            let choices = models
                .into_iter()
                .map(|m| {
                    let id_clean = sanitize_single_line(&m.id);
                    let name_part = m
                        .name
                        .as_deref()
                        .map(str::trim)
                        .filter(|n| !n.is_empty() && *n != m.id)
                        .map(|n| format!(" ({})", sanitize_single_line(n)))
                        .unwrap_or_default();
                    let provider_part = m
                        .provider
                        .as_deref()
                        .map(str::trim)
                        .filter(|p| !p.is_empty())
                        .map(|p| format!(" [{}]", sanitize_single_line(p)))
                        .unwrap_or_default();
                    let label = format!("{id_clean}{name_part}{provider_part}");
                    (m.id, label)
                })
                .collect();

            Ok(Reply::Menu("models".to_string(), choices))
        }

        Effect::Branches => {
            if target.sid.trim().is_empty() {
                return Err("cannot list branches: missing session_id".to_string());
            }
            let detail = client
                .get_session_detail(&target.sid)
                .map_err(|e| format_client_error(&e))?;

            let choices = detail
                .conversations
                .into_iter()
                .map(|c| {
                    let marker = if c.id == target.cid { "*" } else { " " };
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
                    let label = format!(
                        "{marker} #{}{}{}",
                        sanitize_single_line(&c.id),
                        parent,
                        owner
                    );
                    (c.id, label)
                })
                .collect();

            Ok(Reply::Menu("branches".to_string(), choices))
        }

        Effect::Earlier(cursor) => {
            if target.sid.trim().is_empty() || target.cid.trim().is_empty() {
                return Err(
                    "cannot load earlier entries: missing session or conversation".to_string(),
                );
            }
            if cursor.trim().is_empty() {
                return Err("no earlier entries cursor".to_string());
            }
            let page = client
                .get_entries(
                    &target.sid,
                    &target.cid,
                    Some("desc"),
                    Some(cursor.trim()),
                    Some(DEFAULT_ENTRIES_LIMIT),
                )
                .map_err(|e| format_client_error(&e))?;
            Ok(Reply::Page(page))
        }

        Effect::Attach(sid) => {
            if sid.trim().is_empty() {
                return Err("cannot attach: missing session_id".to_string());
            }
            let detail = client
                .get_session_detail(&sid)
                .map_err(|e| format_client_error(&e))?;
            if detail.session.status.as_deref() == Some("quarantined") {
                return Err(format!(
                    "session {} is quarantined",
                    sanitize_single_line(&detail.session.session_id)
                ));
            }
            let cid = detail
                .session
                .root_conversation_id
                .clone()
                .or_else(|| detail.conversations.first().map(|c| c.id.clone()))
                .unwrap_or_else(|| "1".to_string());
            let env_id = detail.session.env_id.unwrap_or_else(|| "host".to_string());
            Ok(Reply::Target(Target {
                sid: detail.session.session_id,
                cid,
                cwd: detail.session.cwd,
                env_id,
            }))
        }

        Effect::New => create_new_session(client, target),

        Effect::Fork(at_entry_id) => {
            if target.sid.trim().is_empty() {
                return Err("cannot fork: missing session_id".to_string());
            }
            let cid_num = parse_cid(&target.cid)?;
            let envelope = CommandEnvelope::fork(generate_request_id(), cid_num, at_entry_id);
            let receipt = post_command_with_retry(client, &target.sid, &envelope)?;
            let new_cid = receipt
                .conversation_id
                .filter(|c| !c.trim().is_empty())
                .ok_or_else(|| "fork receipt missing conversation_id".to_string())?;
            Ok(Reply::Target(Target {
                sid: target.sid.clone(),
                cid: new_cid,
                cwd: target.cwd.clone(),
                env_id: target.env_id.clone(),
            }))
        }

        Effect::Configure(key, val) => {
            if target.sid.trim().is_empty() {
                return Err("cannot configure: missing session_id".to_string());
            }
            let cid_num = parse_cid(&target.cid)?;
            let envelope = build_configure_envelope(cid_num, seq, &key, &val)?;
            let receipt = post_command_with_retry(client, &target.sid, &envelope)?;
            Ok(Reply::Receipt(receipt))
        }

        Effect::Abort => {
            if target.sid.trim().is_empty() {
                return Err("cannot abort: missing session_id".to_string());
            }
            let cid_num = parse_cid(&target.cid)?;
            let envelope =
                CommandEnvelope::abort(generate_request_id(), cid_num, Some("user_abort"));
            let receipt = post_command_with_retry(client, &target.sid, &envelope)?;
            Ok(Reply::Receipt(receipt))
        }

        Effect::Continue => {
            if target.sid.trim().is_empty() {
                return Err("cannot continue: missing session_id".to_string());
            }
            let cid_num = parse_cid(&target.cid)?;
            let envelope = CommandEnvelope::submit_continue(generate_request_id(), cid_num);
            let receipt = post_command_with_retry(client, &target.sid, &envelope)?;
            Ok(Reply::Receipt(receipt))
        }

        Effect::Environments => {
            let envs = client
                .get_environments()
                .map_err(|e| format_client_error(&e))?;
            let choices = envs
                .into_iter()
                .map(|env| {
                    let marker = if env.id == target.env_id { "* " } else { "" };
                    let label_part = env
                        .label
                        .as_deref()
                        .map(str::trim)
                        .filter(|l| !l.is_empty())
                        .map(|l| format!(" ({})", sanitize_single_line(l)))
                        .unwrap_or_default();
                    let kind_part = env
                        .kind
                        .as_deref()
                        .map(str::trim)
                        .filter(|k| !k.is_empty())
                        .map(|k| format!(" [{}]", sanitize_single_line(k)))
                        .unwrap_or_default();
                    let cwd_part = env
                        .default_cwd
                        .as_deref()
                        .map(str::trim)
                        .filter(|c| !c.is_empty())
                        .map(|c| format!(" cwd={}", sanitize_single_line(c)))
                        .unwrap_or_default();
                    let label = format!(
                        "{marker}{}{label_part}{kind_part}{cwd_part}",
                        sanitize_single_line(&env.id)
                    );
                    (env.id, label)
                })
                .collect();

            Ok(Reply::Menu("environments".to_string(), choices))
        }

        Effect::Branch(cid) => {
            if target.sid.trim().is_empty() {
                return Err("cannot switch branch: missing session_id".to_string());
            }
            let cid_trimmed = cid.trim();
            if cid_trimmed.is_empty() {
                return Err("cannot switch branch: missing conversation_id".to_string());
            }
            let detail = client
                .get_session_detail(&target.sid)
                .map_err(|e| format_client_error(&e))?;
            if detail.session.status.as_deref() == Some("quarantined") {
                return Err(format!(
                    "session {} is quarantined",
                    sanitize_single_line(&detail.session.session_id)
                ));
            }
            let found = detail
                .conversations
                .into_iter()
                .find(|c| c.id == cid_trimmed)
                .ok_or_else(|| {
                    format!(
                        "conversation #{} not found in session {}",
                        sanitize_single_line(cid_trimmed),
                        sanitize_single_line(&detail.session.session_id)
                    )
                })?;
            let env_id = detail
                .session
                .env_id
                .unwrap_or_else(|| target.env_id.clone());
            Ok(Reply::Target(Target {
                sid: detail.session.session_id,
                cid: found.id,
                cwd: detail.session.cwd,
                env_id,
            }))
        }
    }
}

fn create_new_session(client: &DaemonClient, target: &Target) -> Result<Reply, String> {
    if target.cwd.trim().is_empty() {
        return Err("cannot create session: missing cwd".to_string());
    }
    let expected_env_id = if target.env_id.trim().is_empty() {
        "host".to_string()
    } else {
        target.env_id.clone()
    };
    let stable_sid = generate_request_id();
    let req = CreateSessionRequest {
        version: 1,
        request_id: generate_request_id(),
        env_id: expected_env_id.clone(),
        cwd: target.cwd.clone(),
        session_id: Some(stable_sid.clone()),
        title: None,
        agent: None,
    };

    let created = create_session_with_retry(client, &req)?;
    verify_created_target(created, &stable_sid, &expected_env_id, &target.cwd)
}

fn verify_created_target(
    created: CreateSessionResponse,
    expected_sid: &str,
    expected_env_id: &str,
    expected_cwd: &str,
) -> Result<Reply, String> {
    if created.session.session_id != expected_sid {
        return Err(format!(
            "created session id mismatch: expected {}, got {}",
            sanitize_single_line(expected_sid),
            sanitize_single_line(&created.session.session_id)
        ));
    }
    if created.session.status.as_deref() == Some("quarantined") {
        return Err(format!(
            "created session {} is quarantined",
            sanitize_single_line(&created.session.session_id)
        ));
    }
    let actual_env_id = created.session.env_id.unwrap_or_else(|| "host".to_string());
    if actual_env_id != expected_env_id {
        return Err(format!(
            "created session env_id mismatch: expected {}, got {}",
            sanitize_single_line(expected_env_id),
            sanitize_single_line(&actual_env_id)
        ));
    }
    if normalize_cwd(&created.session.cwd) != normalize_cwd(expected_cwd) {
        return Err(format!(
            "created session cwd mismatch: expected {}, got {}",
            sanitize_single_line(expected_cwd),
            sanitize_single_line(&created.session.cwd)
        ));
    }
    let cid = created
        .session
        .root_conversation_id
        .unwrap_or_else(|| "1".to_string());

    Ok(Reply::Target(Target {
        sid: created.session.session_id,
        cid,
        cwd: created.session.cwd,
        env_id: actual_env_id,
    }))
}

fn normalize_cwd(path: &str) -> &str {
    if path == "/" {
        "/"
    } else {
        path.trim_end_matches('/')
    }
}

fn build_configure_envelope(
    conversation_id: u64,
    expected_seq: Option<u64>,
    key: &str,
    val: &str,
) -> Result<CommandEnvelope, String> {
    let mut args = Map::new();
    match key.trim() {
        "model" => {
            if val.trim().is_empty() {
                return Err("configure model cannot be empty".to_string());
            }
            args.insert("model".to_string(), Value::String(val.to_string()));
        }
        "thinking" => {
            if val.trim().is_empty() {
                return Err("configure thinking cannot be empty".to_string());
            }
            args.insert("thinking".to_string(), Value::String(val.to_string()));
        }
        "system_prompt" => {
            args.insert("system_prompt".to_string(), Value::String(val.to_string()));
        }
        "instructions" => {
            args.insert("instructions".to_string(), Value::String(val.to_string()));
        }
        "max_turns" => {
            let n: u64 = val
                .trim()
                .parse()
                .ok()
                .filter(|&n| (1..=1000).contains(&n))
                .ok_or_else(|| {
                    format!(
                        "configure max_turns must be an integer between 1 and 1000, got '{}'",
                        sanitize_single_line(val)
                    )
                })?;
            args.insert("max_turns".to_string(), Value::Number(n.into()));
        }
        "tools" => {
            let trimmed = val.trim();
            let list: Vec<Value> = if trimmed.starts_with('[') {
                let parsed: Vec<String> = serde_json::from_str(trimmed).map_err(|e| {
                    format!(
                        "invalid tools list: {}",
                        sanitize_single_line(&e.to_string())
                    )
                })?;
                parsed.into_iter().map(Value::String).collect()
            } else if trimmed.is_empty() {
                Vec::new()
            } else {
                trimmed
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(|s| Value::String(s.to_string()))
                    .collect()
            };
            args.insert("tools".to_string(), Value::Array(list));
        }
        other => {
            return Err(format!(
                "unsupported configure key '{}'",
                sanitize_single_line(other)
            ));
        }
    }

    if let Some(seq) = expected_seq {
        args.insert("expected_seq".to_string(), Value::Number(seq.into()));
    }

    Ok(CommandEnvelope {
        version: 1,
        request_id: generate_request_id(),
        command: "configure".to_string(),
        conversation_id,
        args: Value::Object(args),
    })
}

fn post_command_with_retry(
    client: &DaemonClient,
    session_id: &str,
    envelope: &CommandEnvelope,
) -> Result<CommandReceipt, String> {
    for attempt in 0..AMBIGUOUS_IO_MAX_ATTEMPTS {
        match client.post_command(session_id, envelope) {
            Ok(receipt) => return Ok(receipt),
            Err(err) if is_ambiguous_io_error(&err) => {
                if attempt + 1 < AMBIGUOUS_IO_MAX_ATTEMPTS {
                    thread::sleep(RETRY_BACKOFF);
                    continue;
                }
                return Err(format!(
                    "command outcome unknown (request_id={}): {}",
                    sanitize_single_line(&envelope.request_id),
                    sanitize_single_line(&err.to_string())
                ));
            }
            Err(err) => return Err(format_client_error(&err)),
        }
    }
    unreachable!("retry loop always returns")
}

fn create_session_with_retry(
    client: &DaemonClient,
    req: &CreateSessionRequest,
) -> Result<CreateSessionResponse, String> {
    for attempt in 0..AMBIGUOUS_IO_MAX_ATTEMPTS {
        match client.create_session(req) {
            Ok(resp) => return Ok(resp),
            Err(err) if is_ambiguous_io_error(&err) => {
                if attempt + 1 < AMBIGUOUS_IO_MAX_ATTEMPTS {
                    thread::sleep(RETRY_BACKOFF);
                    continue;
                }
                let sid = req.session_id.as_deref().unwrap_or("");
                return Err(format!(
                    "create session outcome unknown (session_id={}): {}",
                    sanitize_single_line(sid),
                    sanitize_single_line(&err.to_string())
                ));
            }
            Err(err) => return Err(format_client_error(&err)),
        }
    }
    unreachable!("retry loop always returns")
}

fn is_ambiguous_io_error(err: &ClientError) -> bool {
    match err {
        ClientError::Io(_) => true,
        ClientError::InvalidResponse(msg) => {
            msg.contains("unexpected EOF") || msg.contains("missing CRLF after HTTP chunk")
        }
        ClientError::InvalidInput(_)
        | ClientError::ConnectionFailed { .. }
        | ClientError::RedirectDisabled { .. }
        | ClientError::HttpStatus { .. } => false,
    }
}

fn format_client_error(err: &ClientError) -> String {
    match err {
        ClientError::HttpStatus {
            status: 409,
            message,
        } => {
            format!("conflict: {}", sanitize_single_line(message))
        }
        other => sanitize_single_line(&other.to_string()),
    }
}

fn parse_cid(cid: &str) -> Result<u64, String> {
    cid.trim()
        .parse::<u64>()
        .ok()
        .filter(|&n| n > 0)
        .ok_or_else(|| format!("invalid conversation_id '{}'", sanitize_single_line(cid)))
}

fn sort_sessions_latest_first(sessions: &mut [SessionSummary]) {
    sessions.sort_by(|a, b| {
        let ta = a.updated_at.or(a.created_at).unwrap_or(0);
        let tb = b.updated_at.or(b.created_at).unwrap_or(0);
        tb.cmp(&ta).then_with(|| a.session_id.cmp(&b.session_id))
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{DaemonTarget, SecretToken};
    use crate::protocol::{WhenBusy, WhenIdle};
    use serde_json::json;
    use std::io::{Read, Write};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_target() -> Target {
        Target {
            sid: "sess-1".to_string(),
            cid: "1".to_string(),
            cwd: "/tmp/proj".to_string(),
            env_id: "host".to_string(),
        }
    }

    fn bind_test_socket(tag: &str) -> (PathBuf, UnixListener, DaemonClient) {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sock_path = PathBuf::from(format!("/tmp/hi-actions-{tag}-{nanos}.sock"));
        let _ = std::fs::remove_file(&sock_path);
        let listener = UnixListener::bind(&sock_path).unwrap();
        let client = DaemonClient::new(
            DaemonTarget::UnixSocket(sock_path.clone()),
            SecretToken::new("tok-actions-test").unwrap(),
        );
        (sock_path, listener, client)
    }

    fn read_http_request(stream: &mut UnixStream) -> (String, String) {
        let mut buf = Vec::new();
        let mut tmp = [0u8; 1024];
        loop {
            let n = stream.read(&mut tmp).unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
            if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                let head_end = pos + 4;
                let head_str = String::from_utf8_lossy(&buf[..head_end]).to_string();
                let content_len = head_str
                    .lines()
                    .find_map(|l| {
                        let (k, v) = l.split_once(':')?;
                        if k.eq_ignore_ascii_case("content-length") {
                            v.trim().parse::<usize>().ok()
                        } else {
                            None
                        }
                    })
                    .unwrap_or(0);
                while buf.len() < head_end + content_len {
                    let m = stream.read(&mut tmp).unwrap();
                    if m == 0 {
                        break;
                    }
                    buf.extend_from_slice(&tmp[..m]);
                }
                let body =
                    String::from_utf8_lossy(&buf[head_end..head_end + content_len]).to_string();
                return (head_str, body);
            }
        }
        (String::from_utf8_lossy(&buf).to_string(), String::new())
    }

    fn write_json_response(stream: &mut UnixStream, status: &str, body: &str) {
        write!(
            stream,
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        )
        .unwrap();
        stream.flush().unwrap();
    }

    #[test]
    fn submit_retries_ambiguous_io_with_identical_id_and_payload() {
        let (sock_path, listener, client) = bind_test_socket("submit-retry");
        let captured = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured_srv = Arc::clone(&captured);

        let handle = thread::spawn(move || {
            // Attempt 1: read request, drop socket without response (ambiguous I/O EOF)
            let (mut s1, _) = listener.accept().unwrap();
            let (_head1, body1) = read_http_request(&mut s1);
            captured_srv
                .lock()
                .unwrap()
                .push(serde_json::from_str(&body1).unwrap());
            drop(s1);

            // Attempt 2: return 200 receipt
            let (mut s2, _) = listener.accept().unwrap();
            let (head2, body2) = read_http_request(&mut s2);
            assert!(head2.starts_with("POST /api/v1/sessions/sess-1/commands HTTP/1.1"));
            captured_srv
                .lock()
                .unwrap()
                .push(serde_json::from_str(&body2).unwrap());
            let receipt = r#"{"version":1,"request_id":"req-fixed","seq":7,"submission_id":"sub-1","status":"placed"}"#;
            write_json_response(&mut s2, "200 OK", receipt);
        });

        let env = CommandEnvelope::submit_input(
            "req-fixed",
            1,
            "hello",
            WhenBusy::Steer,
            WhenIdle::Start,
        );
        let reply = execute(
            &client,
            &test_target(),
            Some(6),
            Effect::Submit(env.clone()),
        )
        .unwrap();
        match reply {
            Reply::Receipt(r) => {
                assert_eq!(r.request_id, "req-fixed");
                assert_eq!(r.seq, Some(7));
            }
            other => panic!("unexpected reply: {other:?}"),
        }

        handle.join().unwrap();
        let reqs = captured.lock().unwrap();
        assert_eq!(reqs.len(), 2);
        assert_eq!(reqs[0], reqs[1]);
        assert_eq!(reqs[0]["request_id"], "req-fixed");
        let _ = std::fs::remove_file(&sock_path);
    }

    #[test]
    fn submit_reports_unknown_when_ambiguous_io_exhausts_retries() {
        let (sock_path, listener, client) = bind_test_socket("submit-unknown");
        let attempts = Arc::new(Mutex::new(0usize));
        let attempts_srv = Arc::clone(&attempts);

        let handle = thread::spawn(move || {
            for _ in 0..3 {
                let (mut s, _) = listener.accept().unwrap();
                let (_head, body) = read_http_request(&mut s);
                let v: Value = serde_json::from_str(&body).unwrap();
                assert_eq!(v["request_id"], "req-ambig");
                *attempts_srv.lock().unwrap() += 1;
                drop(s);
            }
        });

        let env = CommandEnvelope::submit_input(
            "req-ambig",
            1,
            "draft stays",
            WhenBusy::FollowUp,
            WhenIdle::Start,
        );
        let err = execute(&client, &test_target(), None, Effect::Submit(env)).unwrap_err();
        assert!(err.contains("outcome unknown"), "err={err}");
        assert!(err.contains("req-ambig"), "err={err}");

        handle.join().unwrap();
        assert_eq!(*attempts.lock().unwrap(), 3);
        let _ = std::fs::remove_file(&sock_path);
    }

    #[test]
    fn submit_does_not_retry_http_rejection() {
        let (sock_path, listener, client) = bind_test_socket("submit-422");
        let attempts = Arc::new(Mutex::new(0usize));
        let attempts_srv = Arc::clone(&attempts);

        let handle = thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let _ = read_http_request(&mut s);
            *attempts_srv.lock().unwrap() += 1;
            write_json_response(
                &mut s,
                "422 Unprocessable Entity",
                r#"{"error":"content cannot be empty"}"#,
            );
        });

        let env =
            CommandEnvelope::submit_input("req-bad", 1, "x", WhenBusy::FollowUp, WhenIdle::Start);
        let err = execute(&client, &test_target(), None, Effect::Submit(env)).unwrap_err();
        assert!(!err.contains("outcome unknown"), "err={err}");
        assert!(err.contains("422"), "err={err}");

        handle.join().unwrap();
        assert_eq!(*attempts.lock().unwrap(), 1);
        let _ = std::fs::remove_file(&sock_path);
    }

    #[test]
    fn menus_return_exact_titles_and_sanitized_labels() {
        let (sock_path, listener, client) = bind_test_socket("menus");

        let handle = thread::spawn(move || {
            // 1. Sessions
            let (mut s1, _) = listener.accept().unwrap();
            let (h1, _) = read_http_request(&mut s1);
            assert!(h1.starts_with(
                "GET /api/v1/sessions?env_id=host&cwd=%2Ftmp%2Fproj&subtree=false HTTP/1.1"
            ));
            write_json_response(
                &mut s1,
                "200 OK",
                r#"{"sessions":[
                    {"session_id":"s-old","title":"older","env_id":"host","cwd":"/tmp/proj","updated_at":10,"active":false},
                    {"session_id":"sess-1","title":"evil\u001b[31mtitle","env_id":"host","cwd":"/tmp/proj","updated_at":20,"active":true}
                ]}"#,
            );

            // 2. Models
            let (mut s2, _) = listener.accept().unwrap();
            let (h2, _) = read_http_request(&mut s2);
            assert!(h2.starts_with("GET /api/v1/models HTTP/1.1"));
            write_json_response(
                &mut s2,
                "200 OK",
                r#"{"models":[{"id":"openai/gpt-5.4","name":"GPT 5.4","provider":"openai"}]}"#,
            );

            // 3. Branches
            let (mut s3, _) = listener.accept().unwrap();
            let (h3, _) = read_http_request(&mut s3);
            assert!(h3.starts_with("GET /api/v1/sessions/sess-1 HTTP/1.1"));
            write_json_response(
                &mut s3,
                "200 OK",
                r#"{"session":{"session_id":"sess-1","cwd":"/tmp/proj","root_conversation_id":"1"},"conversations":[{"id":"1","owner":"ownerless"},{"id":"2","parent":{"conversation_id":"1","at":"5"},"owner":"ownerless"}],"tasks":[]}"#,
            );

            // 4. Environments
            let (mut s4, _) = listener.accept().unwrap();
            let (h4, _) = read_http_request(&mut s4);
            assert!(h4.starts_with("GET /api/v1/environments HTTP/1.1"));
            write_json_response(
                &mut s4,
                "200 OK",
                r#"{"environments":[{"id":"host","kind":"host","label":"Local","default_cwd":"/tmp"}]}"#,
            );
        });

        let target = test_target();

        match execute(&client, &target, None, Effect::Sessions).unwrap() {
            Reply::Menu(title, items) => {
                assert_eq!(title, "sessions");
                assert_eq!(items.len(), 2);
                assert_eq!(items[0].0, "sess-1");
                assert!(!items[0].1.contains('\x1b'));
                assert!(items[0].1.contains("\\x1b[31m"));
                assert_eq!(items[1].0, "s-old");
            }
            other => panic!("unexpected: {other:?}"),
        }

        match execute(&client, &target, None, Effect::Models).unwrap() {
            Reply::Menu(title, items) => {
                assert_eq!(title, "models");
                assert_eq!(items[0].0, "openai/gpt-5.4");
                assert!(items[0].1.contains("GPT 5.4"));
            }
            other => panic!("unexpected: {other:?}"),
        }

        match execute(&client, &target, None, Effect::Branches).unwrap() {
            Reply::Menu(title, items) => {
                assert_eq!(title, "branches");
                assert_eq!(items.len(), 2);
                assert_eq!(items[0].0, "1");
                assert!(items[0].1.starts_with("* #1"));
                assert_eq!(items[1].0, "2");
                assert!(items[1].1.contains("forked from #1 @ #5"));
            }
            other => panic!("unexpected: {other:?}"),
        }

        match execute(&client, &target, None, Effect::Environments).unwrap() {
            Reply::Menu(title, items) => {
                assert_eq!(title, "environments");
                assert_eq!(items[0].0, "host");
                assert!(items[0].1.contains("Local"));
            }
            other => panic!("unexpected: {other:?}"),
        }

        handle.join().unwrap();
        let _ = std::fs::remove_file(&sock_path);
    }

    #[test]
    fn new_uses_stable_session_id_across_retry_and_checks_returned_target() {
        let (sock_path, listener, client) = bind_test_socket("new-retry");
        let seen_reqs = Arc::new(Mutex::new(Vec::<Value>::new()));
        let seen_srv = Arc::clone(&seen_reqs);

        let handle = thread::spawn(move || {
            // Attempt 1: ambiguous EOF
            let (mut s1, _) = listener.accept().unwrap();
            let (_h1, b1) = read_http_request(&mut s1);
            seen_srv
                .lock()
                .unwrap()
                .push(serde_json::from_str(&b1).unwrap());
            drop(s1);

            // Attempt 2: returns matching session
            let (mut s2, _) = listener.accept().unwrap();
            let (h2, b2) = read_http_request(&mut s2);
            assert!(h2.starts_with("POST /api/v1/sessions HTTP/1.1"));
            let v2: Value = serde_json::from_str(&b2).unwrap();
            let sid = v2["session_id"].as_str().unwrap().to_string();
            seen_srv.lock().unwrap().push(v2);
            let resp = json!({
                "session": {
                    "session_id": sid,
                    "env_id": "host",
                    "cwd": "/tmp/proj",
                    "root_conversation_id": "1",
                    "status": "ok"
                },
                "seq": 1
            })
            .to_string();
            write_json_response(&mut s2, "200 OK", &resp);

            // Second call: daemon returns mismatched workspace cwd -> must fail check
            let (mut s3, _) = listener.accept().unwrap();
            let (_h3, b3) = read_http_request(&mut s3);
            let v3: Value = serde_json::from_str(&b3).unwrap();
            let sid3 = v3["session_id"].as_str().unwrap().to_string();
            let bad_resp = json!({
                "session": {
                    "session_id": sid3,
                    "env_id": "host",
                    "cwd": "/tmp/other-workspace",
                    "root_conversation_id": "1",
                    "status": "ok"
                },
                "seq": 1
            })
            .to_string();
            write_json_response(&mut s3, "200 OK", &bad_resp);
        });

        let target = test_target();
        let reply = execute(&client, &target, None, Effect::New).unwrap();
        let reqs = seen_reqs.lock().unwrap();
        assert_eq!(reqs.len(), 2);
        assert_eq!(reqs[0], reqs[1]);
        let stable_sid = reqs[0]["session_id"].as_str().unwrap();
        assert!(!stable_sid.is_empty());
        assert_eq!(
            reply,
            Reply::Target(Target {
                sid: stable_sid.to_string(),
                cid: "1".to_string(),
                cwd: "/tmp/proj".to_string(),
                env_id: "host".to_string(),
            })
        );
        drop(reqs);

        let err = execute(&client, &target, None, Effect::New).unwrap_err();
        assert!(err.contains("cwd mismatch"), "err={err}");

        handle.join().unwrap();
        let _ = std::fs::remove_file(&sock_path);
    }

    #[test]
    fn configure_sends_expected_seq_and_surfaces_conflict() {
        let (sock_path, listener, client) = bind_test_socket("configure");

        let handle = thread::spawn(move || {
            // 1. model with expected_seq=12 -> 200
            let (mut s1, _) = listener.accept().unwrap();
            let (_h1, b1) = read_http_request(&mut s1);
            let v1: Value = serde_json::from_str(&b1).unwrap();
            assert_eq!(v1["command"], "configure");
            assert_eq!(v1["conversation_id"], 1);
            assert_eq!(v1["args"]["model"], "fake:coder");
            assert_eq!(v1["args"]["expected_seq"], 12);
            write_json_response(
                &mut s1,
                "200 OK",
                r#"{"version":1,"request_id":"r1","seq":13,"status":"done"}"#,
            );

            // 2. stale expected_seq=12 -> 409 conflict (no retry)
            let (mut s2, _) = listener.accept().unwrap();
            let (_h2, b2) = read_http_request(&mut s2);
            let v2: Value = serde_json::from_str(&b2).unwrap();
            assert_eq!(v2["args"]["thinking"], "high");
            assert_eq!(v2["args"]["expected_seq"], 12);
            write_json_response(
                &mut s2,
                "409 Conflict",
                r#"{"error":"expected_seq mismatch"}"#,
            );
        });

        let target = test_target();
        let ok_reply = execute(
            &client,
            &target,
            Some(12),
            Effect::Configure("model".to_string(), "fake:coder".to_string()),
        )
        .unwrap();
        assert!(matches!(ok_reply, Reply::Receipt(r) if r.seq == Some(13)));

        let err = execute(
            &client,
            &target,
            Some(12),
            Effect::Configure("thinking".to_string(), "high".to_string()),
        )
        .unwrap_err();
        assert!(err.contains("conflict"), "err={err}");
        assert!(err.contains("expected_seq mismatch"), "err={err}");

        handle.join().unwrap();
        let _ = std::fs::remove_file(&sock_path);
    }

    #[test]
    fn fork_attach_earlier_abort_continue_and_branch() {
        let (sock_path, listener, client) = bind_test_socket("misc");

        let handle = thread::spawn(move || {
            // 1. Fork(42)
            let (mut s1, _) = listener.accept().unwrap();
            let (_h1, b1) = read_http_request(&mut s1);
            let v1: Value = serde_json::from_str(&b1).unwrap();
            assert_eq!(v1["command"], "fork");
            assert_eq!(v1["args"]["at_entry_id"], 42);
            write_json_response(
                &mut s1,
                "200 OK",
                r#"{"version":1,"request_id":"rf","seq":9,"conversation_id":"2","status":"done"}"#,
            );

            // 2. Earlier("40")
            let (mut s2, _) = listener.accept().unwrap();
            let (h2, _) = read_http_request(&mut s2);
            assert!(h2.starts_with(
                "GET /api/v1/sessions/sess-1/conversations/1/entries?order=desc&cursor=40&limit=50 HTTP/1.1"
            ));
            write_json_response(
                &mut s2,
                "200 OK",
                r#"{"items":[{"id":"39","kind":"user","data":{"text":"hi"}}],"next_cursor":"38"}"#,
            );

            // 3. Attach("sess-2")
            let (mut s3, _) = listener.accept().unwrap();
            let (h3, _) = read_http_request(&mut s3);
            assert!(h3.starts_with("GET /api/v1/sessions/sess-2 HTTP/1.1"));
            write_json_response(
                &mut s3,
                "200 OK",
                r#"{"session":{"session_id":"sess-2","env_id":"vm-1","cwd":"/work","root_conversation_id":"3","status":"ok"},"conversations":[],"tasks":[]}"#,
            );

            // 4. Abort
            let (mut s4, _) = listener.accept().unwrap();
            let (_h4, b4) = read_http_request(&mut s4);
            let v4: Value = serde_json::from_str(&b4).unwrap();
            assert_eq!(v4["command"], "abort");
            write_json_response(
                &mut s4,
                "200 OK",
                r#"{"version":1,"request_id":"ra","seq":10,"status":"done"}"#,
            );

            // 5. Continue
            let (mut s5, _) = listener.accept().unwrap();
            let (_h5, b5) = read_http_request(&mut s5);
            let v5: Value = serde_json::from_str(&b5).unwrap();
            assert_eq!(v5["command"], "submit");
            assert_eq!(v5["args"]["type"], "continue");
            write_json_response(
                &mut s5,
                "200 OK",
                r#"{"version":1,"request_id":"rc","seq":11,"submission_id":"sub-c","status":"started"}"#,
            );

            // 6. Branch("2")
            let (mut s6, _) = listener.accept().unwrap();
            let (h6, _) = read_http_request(&mut s6);
            assert!(h6.starts_with("GET /api/v1/sessions/sess-1 HTTP/1.1"));
            write_json_response(
                &mut s6,
                "200 OK",
                r#"{"session":{"session_id":"sess-1","env_id":"host","cwd":"/tmp/proj","root_conversation_id":"1"},"conversations":[{"id":"1"},{"id":"2"}],"tasks":[]}"#,
            );
        });

        let target = test_target();

        let forked = execute(&client, &target, None, Effect::Fork(42)).unwrap();
        assert_eq!(
            forked,
            Reply::Target(Target {
                sid: "sess-1".to_string(),
                cid: "2".to_string(),
                cwd: "/tmp/proj".to_string(),
                env_id: "host".to_string(),
            })
        );

        let page = execute(&client, &target, None, Effect::Earlier("40".to_string())).unwrap();
        match page {
            Reply::Page(p) => {
                assert_eq!(p.items.len(), 1);
                assert_eq!(p.next_cursor.as_deref(), Some("38"));
            }
            other => panic!("unexpected: {other:?}"),
        }

        let attached =
            execute(&client, &target, None, Effect::Attach("sess-2".to_string())).unwrap();
        assert_eq!(
            attached,
            Reply::Target(Target {
                sid: "sess-2".to_string(),
                cid: "3".to_string(),
                cwd: "/work".to_string(),
                env_id: "vm-1".to_string(),
            })
        );

        let aborted = execute(&client, &target, None, Effect::Abort).unwrap();
        assert!(matches!(aborted, Reply::Receipt(r) if r.seq == Some(10)));

        let continued = execute(&client, &target, None, Effect::Continue).unwrap();
        assert!(matches!(continued, Reply::Receipt(r) if r.seq == Some(11)));

        let branched = execute(&client, &target, None, Effect::Branch("2".to_string())).unwrap();
        assert_eq!(
            branched,
            Reply::Target(Target {
                sid: "sess-1".to_string(),
                cid: "2".to_string(),
                cwd: "/tmp/proj".to_string(),
                env_id: "host".to_string(),
            })
        );

        handle.join().unwrap();
        let _ = std::fs::remove_file(&sock_path);
    }

    #[test]
    fn validation_and_target_mismatch_checks() {
        let client = DaemonClient::new(
            DaemonTarget::UnixSocket(PathBuf::from("/tmp/does-not-exist-hi-actions.sock")),
            SecretToken::new("tok").unwrap(),
        );
        let target = test_target();

        assert!(
            execute(&client, &target, None, Effect::Earlier("".to_string()))
                .unwrap_err()
                .contains("no earlier entries cursor")
        );

        assert!(execute(
            &client,
            &target,
            None,
            Effect::Configure("unknown_key".to_string(), "v".to_string()),
        )
        .unwrap_err()
        .contains("unsupported configure key"));

        assert!(execute(
            &client,
            &target,
            None,
            Effect::Configure("max_turns".to_string(), "0".to_string()),
        )
        .unwrap_err()
        .contains("max_turns"));

        // verify_created_target rejects sid mismatch, env_id mismatch, quarantined
        let mismatch_sid = CreateSessionResponse {
            session: SessionSummary {
                session_id: "wrong-sid".to_string(),
                title: None,
                env_id: Some("host".to_string()),
                harness_id: None,
                cwd: "/tmp/proj".to_string(),
                root_conversation_id: Some("1".to_string()),
                created_at: None,
                updated_at: None,
                active: false,
                next_wake_at: None,
                status: Some("ok".to_string()),
            },
            seq: 1,
        };
        assert!(
            verify_created_target(mismatch_sid, "expected-sid", "host", "/tmp/proj")
                .unwrap_err()
                .contains("id mismatch")
        );

        let mismatch_env = CreateSessionResponse {
            session: SessionSummary {
                session_id: "expected-sid".to_string(),
                title: None,
                env_id: Some("remote".to_string()),
                harness_id: None,
                cwd: "/tmp/proj".to_string(),
                root_conversation_id: Some("1".to_string()),
                created_at: None,
                updated_at: None,
                active: false,
                next_wake_at: None,
                status: Some("ok".to_string()),
            },
            seq: 1,
        };
        assert!(
            verify_created_target(mismatch_env, "expected-sid", "host", "/tmp/proj")
                .unwrap_err()
                .contains("env_id mismatch")
        );
    }
}
