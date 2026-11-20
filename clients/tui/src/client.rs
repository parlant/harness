use crate::config::{DaemonTarget, LoopbackHost, SecretToken};
use crate::protocol::{
    CommandEnvelope, CommandReceipt, CreateSessionRequest, CreateSessionResponse,
    EntriesPageResponse, EnvironmentInfo, EnvironmentsResponse, ErrorResponse, ModelInfo,
    ModelsResponse, SessionDetailResponse, SessionSummary, SessionsResponse, SseEvent, SseParser,
};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::fmt;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

const DEFAULT_IO_TIMEOUT: Duration = Duration::from_secs(30);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_HEADER_BYTES: usize = 64 * 1024;
const MAX_CHUNK_LINE_BYTES: usize = 8 * 1024;
const MAX_UNARY_BODY_BYTES: usize = 32 * 1024 * 1024;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct WorkspaceFileEntry {
    pub path: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub size: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct WorkspaceFilesResponse {
    pub env_id: String,
    pub cwd: String,
    #[serde(default)]
    pub entries: Vec<WorkspaceFileEntry>,
    #[serde(default)]
    pub truncated: bool,
}

fn default_start_line() -> u64 {
    1
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct WorkspaceFileReadResponse {
    pub env_id: String,
    pub cwd: String,
    pub path: String,
    #[serde(default)]
    pub resolved_path: Option<String>,
    #[serde(default)]
    pub lines: Vec<String>,
    #[serde(default = "default_start_line")]
    pub start_line: u64,
    #[serde(default)]
    pub total_lines_read: u64,
    #[serde(default)]
    pub has_more: bool,
    #[serde(default)]
    pub truncated_by_bytes: bool,
}

#[derive(Deserialize)]
pub struct KeyProfile {
    pub provider: String,
    pub active: Option<String>,
    pub sources: Vec<String>,
}

#[derive(Deserialize)]
pub struct LoginProvider {
    pub id: String,
    pub interaction: String,
    pub sources: Vec<LoginSource>,
}

#[derive(Deserialize)]
pub struct LoginSource {
    pub id: String,
    pub state: String,
    #[serde(default)]
    pub active: bool,
}

// Deliberately not Debug: the code and operation are transient.
#[derive(Deserialize)]
pub struct LoginOperation {
    pub operation: String,
    pub source: String,
    pub state: LoginState,
    pub verification_url: Option<String>,
    pub user_code: Option<String>,
    pub expires_in_ms: Option<u64>,
    pub poll_after_ms: Option<u64>,
    pub reason: Option<String>,
}

#[derive(Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LoginState {
    Starting,
    Pending,
    Complete,
    Cancelled,
    Expired,
    Failed,
}

#[derive(Debug)]
pub enum ClientError {
    InvalidInput(String),
    ConnectionFailed { endpoint: String, error: io::Error },
    RedirectDisabled { status: u16 },
    HttpStatus { status: u16, message: String },
    InvalidResponse(String),
    Io(String),
}

impl fmt::Display for ClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ClientError::InvalidInput(msg) => write!(f, "invalid request input: {msg}"),
            ClientError::ConnectionFailed { endpoint, error } => {
                write!(f, "failed to connect to daemon at {endpoint}: {error}")
            }
            ClientError::RedirectDisabled { status } => write!(
                f,
                "refusing HTTP {status} redirect (redirects are disabled for security)"
            ),
            ClientError::HttpStatus { status, message } => {
                write!(f, "daemon returned HTTP {status}: {message}")
            }
            ClientError::InvalidResponse(msg) => write!(f, "invalid daemon response: {msg}"),
            ClientError::Io(msg) => write!(f, "transport I/O error: {msg}"),
        }
    }
}

impl std::error::Error for ClientError {}

enum TransportStream {
    Unix(UnixStream),
    Tcp(TcpStream),
}

impl TransportStream {
    fn try_clone(&self) -> io::Result<Self> {
        match self {
            TransportStream::Unix(s) => Ok(TransportStream::Unix(s.try_clone()?)),
            TransportStream::Tcp(s) => Ok(TransportStream::Tcp(s.try_clone()?)),
        }
    }

    fn shutdown_both(&self) {
        match self {
            TransportStream::Unix(s) => {
                let _ = s.shutdown(Shutdown::Both);
            }
            TransportStream::Tcp(s) => {
                let _ = s.shutdown(Shutdown::Both);
            }
        }
    }

    fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        match self {
            TransportStream::Unix(s) => s.set_read_timeout(timeout),
            TransportStream::Tcp(s) => s.set_read_timeout(timeout),
        }
    }
}

#[derive(Default)]
struct CancelState {
    cancelled: bool,
    active: Option<TransportStream>,
}

#[derive(Clone, Default)]
pub struct StreamCancel {
    inner: Arc<(Mutex<CancelState>, Condvar)>,
}

impl fmt::Debug for StreamCancel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StreamCancel")
            .field("cancelled", &self.is_cancelled())
            .finish()
    }
}

impl StreamCancel {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        let (lock, cvar) = &*self.inner;
        let active = {
            let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
            state.cancelled = true;
            let active = state.active.take();
            cvar.notify_all();
            active
        };
        if let Some(stream) = active {
            stream.shutdown_both();
        }
    }

    pub fn is_cancelled(&self) -> bool {
        let (lock, _) = &*self.inner;
        lock.lock().unwrap_or_else(|e| e.into_inner()).cancelled
    }

    pub fn wait_timeout(&self, dur: Duration) -> bool {
        let (lock, cvar) = &*self.inner;
        let guard = lock.lock().unwrap_or_else(|e| e.into_inner());
        if guard.cancelled {
            return false;
        }
        let (guard, _) = cvar
            .wait_timeout_while(guard, dur, |s| !s.cancelled)
            .unwrap_or_else(|e| e.into_inner());
        !guard.cancelled
    }

    pub fn clear_active(&self) {
        let (lock, _) = &*self.inner;
        let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
        state.active = None;
    }

    fn attach(&self, stream: &TransportStream) -> Result<(), ClientError> {
        let cloned = stream
            .try_clone()
            .map_err(|e| ClientError::Io(e.to_string()))?;
        let (lock, _) = &*self.inner;
        let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
        if state.cancelled {
            drop(state);
            cloned.shutdown_both();
            stream.shutdown_both();
            return Err(ClientError::Io("stream cancelled".to_string()));
        }
        state.active = Some(cloned);
        Ok(())
    }
}

impl Read for TransportStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            TransportStream::Unix(s) => s.read(buf),
            TransportStream::Tcp(s) => s.read(buf),
        }
    }
}

impl Write for TransportStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            TransportStream::Unix(s) => s.write(buf),
            TransportStream::Tcp(s) => s.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            TransportStream::Unix(s) => s.flush(),
            TransportStream::Tcp(s) => s.flush(),
        }
    }
}

#[derive(Clone)]
pub struct DaemonClient {
    target: DaemonTarget,
    token: SecretToken,
}

impl fmt::Debug for DaemonClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DaemonClient")
            .field("target", &self.target.display_endpoint())
            .field("token", &self.token)
            .finish()
    }
}

impl DaemonClient {
    pub fn new(target: DaemonTarget, token: SecretToken) -> Self {
        Self { target, token }
    }

    pub fn target(&self) -> &DaemonTarget {
        &self.target
    }

    pub(crate) fn probe_connection(&self) -> Result<(), ClientError> {
        self.connect(Some(Duration::from_secs(2))).map(drop)
    }

    pub(crate) fn shutdown_if_idle(&self) -> Result<(), ClientError> {
        let reply: serde_json::Value =
            self.post_json("/api/v1/daemon/shutdown", &serde_json::json!({}))?;
        if reply["state"] == "stopping" {
            Ok(())
        } else {
            Err(ClientError::InvalidResponse(
                "shutdown was not acknowledged".into(),
            ))
        }
    }

    pub fn get_environments(&self) -> Result<Vec<EnvironmentInfo>, ClientError> {
        let resp: EnvironmentsResponse = self.get_json("/api/v1/environments")?;
        Ok(resp.environments)
    }

    pub fn key_profiles(&self) -> Result<Vec<KeyProfile>, ClientError> {
        #[derive(Deserialize)]
        struct Discovery {
            providers: Vec<KeyProfile>,
        }
        let response: Discovery = self.get_json("/api/v1/provider-keys")?;
        Ok(response.providers)
    }

    pub fn set_api_key(&self, provider: &str, source: &str, key: &str) -> Result<(), ClientError> {
        // Do not mirror a server's error body on this write-only path.
        let result: Result<serde_json::Value, _> = self.post_json(
            "/api/v1/provider-keys/set",
            &serde_json::json!({"provider": provider, "source": source, "api_key": key}),
        );
        match result {
            Ok(_) => Ok(()),
            Err(ClientError::HttpStatus { status, .. }) => Err(ClientError::HttpStatus {
                status,
                message: "Could not save API key".into(),
            }),
            Err(_) => Err(ClientError::Io(
                "Could not confirm API-key save; check /key list".into(),
            )),
        }
    }

    pub fn use_api_key(&self, provider: &str, source: &str) -> Result<(), ClientError> {
        let _: serde_json::Value = self.post_json(
            "/api/v1/provider-keys/use",
            &serde_json::json!({"provider": provider, "source": source}),
        )?;
        Ok(())
    }

    pub fn login_providers(&self) -> Result<Vec<LoginProvider>, ClientError> {
        #[derive(Deserialize)]
        struct Discovery {
            providers: Vec<LoginProvider>,
        }
        let response: Discovery = self.get_json("/api/v1/provider-logins")?;
        Ok(response.providers)
    }

    pub fn start_login(
        &self,
        provider: &str,
        source: &str,
        request_id: &str,
    ) -> Result<LoginOperation, ClientError> {
        self.start_login_for(provider, Some(source), request_id)
    }

    pub(crate) fn start_login_for(
        &self,
        provider: &str,
        source: Option<&str>,
        request_id: &str,
    ) -> Result<LoginOperation, ClientError> {
        self.post_json(
            "/api/v1/provider-logins/start",
            &serde_json::json!({
                "provider": provider, "source": source, "request_id": request_id
            }),
        )
    }

    pub fn add_codex_account(&self, source: &str) -> Result<(), ClientError> {
        let _: serde_json::Value = self.post_json(
            "/api/v1/provider-accounts/add",
            &serde_json::json!({"source": source}),
        )?;
        Ok(())
    }

    pub fn activate_codex_account(&self, source: &str) -> Result<(), ClientError> {
        let _: serde_json::Value = self.post_json(
            "/api/v1/provider-accounts/activate",
            &serde_json::json!({"source": source}),
        )?;
        Ok(())
    }

    pub fn login_status(&self, operation: &str) -> Result<LoginOperation, ClientError> {
        self.post_json(
            "/api/v1/provider-logins/status",
            &serde_json::json!({"operation": operation}),
        )
    }

    pub fn cancel_login(&self, operation: &str) -> Result<LoginOperation, ClientError> {
        self.post_json(
            "/api/v1/provider-logins/cancel",
            &serde_json::json!({"operation": operation}),
        )
    }

    pub fn list_models(&self) -> Result<Vec<ModelInfo>, ClientError> {
        let resp: ModelsResponse = self.get_json("/api/v1/models")?;
        Ok(resp.models)
    }

    pub fn list_sessions(
        &self,
        env_id: Option<&str>,
        cwd: Option<&str>,
        subtree: Option<bool>,
    ) -> Result<Vec<SessionSummary>, ClientError> {
        let mut params = Vec::new();
        if let Some(env) = env_id.filter(|s| !s.is_empty()) {
            params.push(format!("env_id={}", percent_encode(env)));
        }
        if let Some(c) = cwd.filter(|s| !s.is_empty()) {
            params.push(format!("cwd={}", percent_encode(c)));
        }
        if let Some(sub) = subtree {
            params.push(format!("subtree={}", if sub { "true" } else { "false" }));
        }

        let path = if params.is_empty() {
            "/api/v1/sessions".to_string()
        } else {
            format!("/api/v1/sessions?{}", params.join("&"))
        };

        let resp: SessionsResponse = self.get_json(&path)?;
        Ok(resp.sessions)
    }

    pub fn create_session(
        &self,
        req: &CreateSessionRequest,
    ) -> Result<CreateSessionResponse, ClientError> {
        self.post_json("/api/v1/sessions", req)
    }

    pub fn get_session_detail(
        &self,
        session_id: &str,
    ) -> Result<SessionDetailResponse, ClientError> {
        validate_path_segment("session_id", session_id)?;
        let path = format!("/api/v1/sessions/{}", percent_encode(session_id));
        self.get_json(&path)
    }

    pub(crate) fn list_directory_files(
        &self,
        env_id: &str,
        cwd: &str,
        prefix: &str,
    ) -> Result<WorkspaceFilesResponse, ClientError> {
        if env_id.is_empty()
            || !cwd.starts_with('/')
            || [env_id, cwd, prefix].iter().any(|s| s.contains('\0'))
        {
            return Err(ClientError::InvalidInput(
                "invalid completion directory or prefix".into(),
            ));
        }
        let path = format!(
            "/api/v1/fs/files?env_id={}&cwd={}&max_depth=1&limit=500&include_hidden={}{}",
            percent_encode(env_id),
            percent_encode(cwd),
            prefix.starts_with('.'),
            if prefix.is_empty() {
                String::new()
            } else {
                format!("&query={}", percent_encode(prefix))
            },
        );
        self.request_json("GET", &path, None, Duration::from_secs(3))
    }

    pub fn list_session_files(
        &self,
        session_id: &str,
        query: Option<&str>,
        limit: Option<u32>,
    ) -> Result<WorkspaceFilesResponse, ClientError> {
        validate_path_segment("session_id", session_id)?;
        if let Some(q) = query {
            if q.contains('\0') {
                return Err(ClientError::InvalidInput(
                    "query cannot contain NUL byte".to_string(),
                ));
            }
        }
        let mut params = Vec::new();
        if let Some(q) = query.filter(|s| !s.is_empty()) {
            params.push(format!("query={}", percent_encode(q)));
        }
        if let Some(l) = limit {
            params.push(format!("limit={l}"));
        }
        let base = format!("/api/v1/sessions/{}/files", percent_encode(session_id));
        let path = if params.is_empty() {
            base
        } else {
            format!("{base}?{}", params.join("&"))
        };
        self.get_json(&path)
    }

    pub fn read_session_file(
        &self,
        session_id: &str,
        file_path: &str,
        offset: Option<u64>,
        limit: Option<u32>,
        max_bytes: Option<u32>,
    ) -> Result<WorkspaceFileReadResponse, ClientError> {
        validate_path_segment("session_id", session_id)?;
        if file_path.trim().is_empty() {
            return Err(ClientError::InvalidInput(
                "file path cannot be empty".to_string(),
            ));
        }
        if file_path.contains('\0') {
            return Err(ClientError::InvalidInput(
                "file path cannot contain NUL byte".to_string(),
            ));
        }
        let mut params = vec![format!("path={}", percent_encode(file_path))];
        if let Some(o) = offset {
            params.push(format!("offset={o}"));
        }
        if let Some(l) = limit {
            params.push(format!("limit={l}"));
        }
        if let Some(m) = max_bytes {
            params.push(format!("max_bytes={m}"));
        }
        let path = format!(
            "/api/v1/sessions/{}/file?{}",
            percent_encode(session_id),
            params.join("&")
        );
        self.get_json(&path)
    }

    pub fn get_entries(
        &self,
        session_id: &str,
        conversation_id: &str,
        order: Option<&str>,
        cursor: Option<&str>,
        limit: Option<u32>,
    ) -> Result<EntriesPageResponse, ClientError> {
        validate_path_segment("session_id", session_id)?;
        validate_path_segment("conversation_id", conversation_id)?;

        let mut params = Vec::new();
        if let Some(o) = order {
            params.push(format!("order={}", percent_encode(o)));
        }
        if let Some(c) = cursor {
            params.push(format!("cursor={}", percent_encode(c)));
        }
        if let Some(l) = limit {
            params.push(format!("limit={l}"));
        }

        let base = format!(
            "/api/v1/sessions/{}/conversations/{}/entries",
            percent_encode(session_id),
            percent_encode(conversation_id)
        );
        let path = if params.is_empty() {
            base
        } else {
            format!("{base}?{}", params.join("&"))
        };
        self.get_json(&path)
    }

    pub fn post_command(
        &self,
        session_id: &str,
        envelope: &CommandEnvelope,
    ) -> Result<CommandReceipt, ClientError> {
        validate_path_segment("session_id", session_id)?;
        let path = format!("/api/v1/sessions/{}/commands", percent_encode(session_id));
        self.post_json(&path, envelope)
    }

    pub fn subscribe_events(
        &self,
        session_id: &str,
        conversation_id: &str,
        last_event_id: Option<u64>,
    ) -> Result<SseStream, ClientError> {
        self.subscribe_events_inner(session_id, conversation_id, last_event_id, None)
    }

    pub fn subscribe_sessions_cancellable(
        &self,
        cancel: &StreamCancel,
    ) -> Result<SseStream, ClientError> {
        self.subscribe_sse_path("/api/v1/sessions/events", None, Some(cancel))
    }

    pub fn subscribe_events_cancellable(
        &self,
        session_id: &str,
        conversation_id: &str,
        last_event_id: Option<u64>,
        cancel: &StreamCancel,
    ) -> Result<SseStream, ClientError> {
        self.subscribe_events_inner(session_id, conversation_id, last_event_id, Some(cancel))
    }

    fn subscribe_events_inner(
        &self,
        session_id: &str,
        conversation_id: &str,
        last_event_id: Option<u64>,
        cancel: Option<&StreamCancel>,
    ) -> Result<SseStream, ClientError> {
        validate_path_segment("session_id", session_id)?;
        validate_path_segment("conversation_id", conversation_id)?;

        let path = format!(
            "/api/v1/sessions/{}/conversations/{}/events",
            percent_encode(session_id),
            percent_encode(conversation_id)
        );
        self.subscribe_sse_path(&path, last_event_id, cancel)
    }

    fn subscribe_sse_path(
        &self,
        path: &str,
        last_event_id: Option<u64>,
        cancel: Option<&StreamCancel>,
    ) -> Result<SseStream, ClientError> {
        if cancel.is_some_and(StreamCancel::is_cancelled) {
            return Err(ClientError::Io("stream cancelled".to_string()));
        }

        let mut stream = self.connect(Some(DEFAULT_IO_TIMEOUT))?;
        if let Some(c) = cancel {
            c.attach(&stream)?;
        }

        let mut extra_headers = Vec::new();
        if let Some(seq) = last_event_id {
            extra_headers.push(("Last-Event-ID", seq.to_string()));
        }
        if let Err(err) = write_request(
            &mut stream,
            "GET",
            path,
            &self.target.host_header(),
            self.token.expose(),
            "text/event-stream",
            &extra_headers,
            None,
        ) {
            if let Some(c) = cancel {
                c.clear_active();
            }
            return Err(err);
        }

        let mut reader = BufReader::new(stream);
        let head = match read_response_head(&mut reader) {
            Ok(h) => h,
            Err(err) => {
                if let Some(c) = cancel {
                    c.clear_active();
                }
                return Err(err);
            }
        };
        if (300..400).contains(&head.status) {
            if let Some(c) = cancel {
                c.clear_active();
            }
            return Err(ClientError::RedirectDisabled {
                status: head.status,
            });
        }
        if head.status != 200 {
            let body = read_unary_body(&mut reader, &head);
            if let Some(c) = cancel {
                c.clear_active();
            }
            return Err(http_status_error(head.status, &body?));
        }
        if let Some(ct) = head.content_type.as_deref() {
            if !ct.to_ascii_lowercase().starts_with("text/event-stream") {
                if let Some(c) = cancel {
                    c.clear_active();
                }
                return Err(ClientError::InvalidResponse(format!(
                    "expected text/event-stream content-type, got {ct}"
                )));
            }
        }

        let _ = reader.get_ref().set_read_timeout(None);

        Ok(SseStream::new(reader, head.chunked, cancel.cloned()))
    }

    fn get_json<T: serde::de::DeserializeOwned>(&self, path: &str) -> Result<T, ClientError> {
        self.request_json("GET", path, None, DEFAULT_IO_TIMEOUT)
    }

    fn post_json<B: serde::Serialize, T: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        body: &B,
    ) -> Result<T, ClientError> {
        let json_bytes = serde_json::to_vec(body)
            .map_err(|e| ClientError::InvalidInput(format!("JSON encode failed: {e}")))?;
        self.request_json("POST", path, Some(&json_bytes), DEFAULT_IO_TIMEOUT)
    }

    fn request_json<T: serde::de::DeserializeOwned>(
        &self,
        method: &str,
        path: &str,
        body: Option<&[u8]>,
        timeout: Duration,
    ) -> Result<T, ClientError> {
        let mut stream = self.connect(Some(timeout))?;
        write_request(
            &mut stream,
            method,
            path,
            &self.target.host_header(),
            self.token.expose(),
            "application/json",
            &[],
            body,
        )?;

        let mut reader = BufReader::new(stream);
        let head = read_response_head(&mut reader)?;
        if (300..400).contains(&head.status) {
            return Err(ClientError::RedirectDisabled {
                status: head.status,
            });
        }

        let body_bytes = read_unary_body(&mut reader, &head)?;
        if !(200..300).contains(&head.status) {
            return Err(http_status_error(head.status, &body_bytes));
        }

        serde_json::from_slice(&body_bytes)
            .map_err(|e| ClientError::InvalidResponse(format!("JSON decode error: {e}")))
    }

    fn connect(&self, read_timeout: Option<Duration>) -> Result<TransportStream, ClientError> {
        let endpoint = self.target.display_endpoint();
        match &self.target {
            DaemonTarget::UnixSocket(path) => {
                let stream = UnixStream::connect(path)
                    .map_err(|error| ClientError::ConnectionFailed { endpoint, error })?;
                stream
                    .set_read_timeout(read_timeout)
                    .map_err(|e| ClientError::Io(e.to_string()))?;
                stream
                    .set_write_timeout(Some(DEFAULT_IO_TIMEOUT))
                    .map_err(|e| ClientError::Io(e.to_string()))?;
                Ok(TransportStream::Unix(stream))
            }
            DaemonTarget::LoopbackHttp { host, port } => {
                let addr = match host {
                    LoopbackHost::Ipv4 => SocketAddr::from(([127, 0, 0, 1], *port)),
                    LoopbackHost::Ipv6 => SocketAddr::from(([0, 0, 0, 0, 0, 0, 0, 1], *port)),
                };
                let stream = TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT)
                    .map_err(|error| ClientError::ConnectionFailed { endpoint, error })?;
                stream
                    .set_read_timeout(read_timeout)
                    .map_err(|e| ClientError::Io(e.to_string()))?;
                stream
                    .set_write_timeout(Some(DEFAULT_IO_TIMEOUT))
                    .map_err(|e| ClientError::Io(e.to_string()))?;
                Ok(TransportStream::Tcp(stream))
            }
        }
    }
}

pub struct SseStream {
    reader: BufReader<TransportStream>,
    chunked: bool,
    chunk_remaining: usize,
    chunk_eof: bool,
    parser: SseParser,
    queued: VecDeque<SseEvent>,
    stream_done: bool,
    cancel: Option<StreamCancel>,
}

impl Drop for SseStream {
    fn drop(&mut self) {
        if let Some(cancel) = &self.cancel {
            cancel.clear_active();
        }
    }
}

impl SseStream {
    fn new(
        reader: BufReader<TransportStream>,
        chunked: bool,
        cancel: Option<StreamCancel>,
    ) -> Self {
        Self {
            reader,
            chunked,
            chunk_remaining: 0,
            chunk_eof: false,
            parser: SseParser::new(),
            queued: VecDeque::new(),
            stream_done: false,
            cancel,
        }
    }

    pub fn next_event(&mut self) -> Result<Option<SseEvent>, ClientError> {
        loop {
            if let Some(ev) = self.queued.pop_front() {
                return Ok(Some(ev));
            }
            if self.stream_done {
                return Ok(None);
            }

            let mut buf = [0u8; 4096];
            let n = if self.chunked {
                self.read_chunked_slice(&mut buf)?
            } else {
                read_retry_intr(&mut self.reader, &mut buf)
                    .map_err(|e| ClientError::Io(e.to_string()))?
            };

            if n == 0 {
                self.stream_done = true;
                if let Some(ev) = self
                    .parser
                    .try_finish()
                    .map_err(|e| ClientError::InvalidResponse(e.to_string()))?
                {
                    self.queued.push_back(ev);
                }
            } else {
                for ev in self
                    .parser
                    .try_push_bytes(&buf[..n])
                    .map_err(|e| ClientError::InvalidResponse(e.to_string()))?
                {
                    self.queued.push_back(ev);
                }
            }
        }
    }

    fn read_chunked_slice(&mut self, out: &mut [u8]) -> Result<usize, ClientError> {
        if self.chunk_eof {
            return Ok(0);
        }

        while self.chunk_remaining == 0 {
            let line = read_crlf_line(&mut self.reader, MAX_CHUNK_LINE_BYTES)?;
            let size_hex = line.split(';').next().unwrap_or("").trim();
            let size = usize::from_str_radix(size_hex, 16).map_err(|_| {
                ClientError::InvalidResponse(format!("invalid chunk size: {size_hex}"))
            })?;
            if size == 0 {
                // Drain trailing headers/empty line after final 0-length chunk
                loop {
                    let trailer = read_crlf_line(&mut self.reader, MAX_CHUNK_LINE_BYTES)?;
                    if trailer.is_empty() {
                        break;
                    }
                }
                self.chunk_eof = true;
                return Ok(0);
            }
            self.chunk_remaining = size;
        }

        let to_read = out.len().min(self.chunk_remaining);
        let n = read_retry_intr(&mut self.reader, &mut out[..to_read])
            .map_err(|e| ClientError::Io(e.to_string()))?;
        if n == 0 {
            return Err(ClientError::InvalidResponse(
                "unexpected EOF inside HTTP chunk".to_string(),
            ));
        }
        self.chunk_remaining -= n;
        if self.chunk_remaining == 0 {
            consume_crlf(&mut self.reader)?;
        }
        Ok(n)
    }
}

struct ResponseHead {
    status: u16,
    content_length: Option<usize>,
    chunked: bool,
    content_type: Option<String>,
}

#[allow(clippy::too_many_arguments)]
fn write_request(
    stream: &mut TransportStream,
    method: &str,
    path: &str,
    host: &str,
    token: &str,
    accept: &str,
    extra_headers: &[(&str, String)],
    body: Option<&[u8]>,
) -> Result<(), ClientError> {
    if path.contains(['\r', '\n', '\0']) || host.contains(['\r', '\n', '\0']) {
        return Err(ClientError::InvalidInput(
            "request target or host contains invalid control characters".to_string(),
        ));
    }

    let mut req = Vec::with_capacity(512 + body.map_or(0, <[u8]>::len));
    let _ = write!(req, "{method} {path} HTTP/1.1\r\n");
    let _ = write!(req, "Host: {host}\r\n");
    let _ = write!(req, "Authorization: Bearer {token}\r\n");
    let _ = write!(req, "Accept: {accept}\r\n");
    for (name, value) in extra_headers {
        if !name.contains(['\r', '\n', ':']) && !value.contains(['\r', '\n']) {
            let _ = write!(req, "{name}: {value}\r\n");
        }
    }
    if let Some(bytes) = body {
        let _ = write!(req, "Content-Type: application/json\r\n");
        let _ = write!(req, "Content-Length: {}\r\n", bytes.len());
    }
    req.extend_from_slice(b"Connection: close\r\n\r\n");
    if let Some(bytes) = body {
        req.extend_from_slice(bytes);
    }

    stream
        .write_all(&req)
        .and_then(|()| stream.flush())
        .map_err(|e| ClientError::Io(e.to_string()))
}

fn read_response_head(
    reader: &mut BufReader<TransportStream>,
) -> Result<ResponseHead, ClientError> {
    let status_line = read_crlf_line(reader, MAX_HEADER_BYTES)?;
    let mut parts = status_line.splitn(3, ' ');
    let version = parts.next().unwrap_or("");
    let status_str = parts.next().unwrap_or("");
    if !version.starts_with("HTTP/1.") {
        return Err(ClientError::InvalidResponse(format!(
            "unexpected HTTP status line: {status_line}"
        )));
    }
    let status: u16 = status_str.parse().map_err(|_| {
        ClientError::InvalidResponse(format!("invalid HTTP status code: {status_str}"))
    })?;

    let mut total_header_bytes = status_line.len();
    let mut content_length = None;
    let mut chunked = false;
    let mut content_type = None;

    loop {
        let line = read_crlf_line(reader, MAX_HEADER_BYTES)?;
        total_header_bytes += line.len() + 2;
        if total_header_bytes > MAX_HEADER_BYTES {
            return Err(ClientError::InvalidResponse(
                "HTTP response headers too large".to_string(),
            ));
        }
        if line.is_empty() {
            break;
        }
        if let Some((name, val)) = line.split_once(':') {
            let lower = name.trim().to_ascii_lowercase();
            let val = val.trim();
            match lower.as_str() {
                "content-length" => {
                    content_length = val.parse::<usize>().ok();
                }
                "transfer-encoding" => {
                    if val.to_ascii_lowercase().contains("chunked") {
                        chunked = true;
                    }
                }
                "content-type" => {
                    content_type = Some(val.to_string());
                }
                _ => {}
            }
        }
    }

    Ok(ResponseHead {
        status,
        content_length,
        chunked,
        content_type,
    })
}

fn read_unary_body(
    reader: &mut BufReader<TransportStream>,
    head: &ResponseHead,
) -> Result<Vec<u8>, ClientError> {
    if head.chunked {
        let mut body = Vec::new();
        loop {
            let size_line = read_crlf_line(reader, MAX_CHUNK_LINE_BYTES)?;
            let size_hex = size_line.split(';').next().unwrap_or("").trim();
            let size = usize::from_str_radix(size_hex, 16).map_err(|_| {
                ClientError::InvalidResponse(format!("invalid chunk size: {size_hex}"))
            })?;
            if size == 0 {
                loop {
                    let trailer = read_crlf_line(reader, MAX_CHUNK_LINE_BYTES)?;
                    if trailer.is_empty() {
                        break;
                    }
                }
                break;
            }
            if body.len().saturating_add(size) > MAX_UNARY_BODY_BYTES {
                return Err(ClientError::InvalidResponse(
                    "HTTP response body exceeds size limit".to_string(),
                ));
            }
            let start = body.len();
            body.resize(start + size, 0);
            reader
                .read_exact(&mut body[start..])
                .map_err(|e| ClientError::Io(e.to_string()))?;
            consume_crlf(reader)?;
        }
        return Ok(body);
    }

    if let Some(len) = head.content_length {
        if len > MAX_UNARY_BODY_BYTES {
            return Err(ClientError::InvalidResponse(
                "HTTP response body exceeds size limit".to_string(),
            ));
        }
        let mut body = vec![0u8; len];
        reader
            .read_exact(&mut body)
            .map_err(|e| ClientError::Io(e.to_string()))?;
        return Ok(body);
    }

    let mut body = Vec::new();
    reader
        .take((MAX_UNARY_BODY_BYTES + 1) as u64)
        .read_to_end(&mut body)
        .map_err(|e| ClientError::Io(e.to_string()))?;
    if body.len() > MAX_UNARY_BODY_BYTES {
        return Err(ClientError::InvalidResponse(
            "HTTP response body exceeds size limit".to_string(),
        ));
    }
    Ok(body)
}

fn read_crlf_line(
    reader: &mut BufReader<TransportStream>,
    max_len: usize,
) -> Result<String, ClientError> {
    let mut buf = Vec::new();
    loop {
        let avail = match reader.fill_buf() {
            Ok(b) => b,
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(ClientError::Io(e.to_string())),
        };
        if avail.is_empty() {
            if buf.is_empty() {
                return Err(ClientError::InvalidResponse(
                    "unexpected EOF while reading HTTP line".to_string(),
                ));
            }
            break;
        }
        if let Some(pos) = avail.iter().position(|&b| b == b'\n') {
            if buf.len().saturating_add(pos) > max_len {
                return Err(ClientError::InvalidResponse(
                    "HTTP line exceeds size limit".to_string(),
                ));
            }
            buf.extend_from_slice(&avail[..pos]);
            reader.consume(pos + 1);
            break;
        }
        let n = avail.len();
        if buf.len().saturating_add(n) > max_len {
            return Err(ClientError::InvalidResponse(
                "HTTP line exceeds size limit".to_string(),
            ));
        }
        buf.extend_from_slice(avail);
        reader.consume(n);
    }
    while buf.last().is_some_and(|&b| b == b'\n' || b == b'\r') {
        buf.pop();
    }
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

fn consume_crlf(reader: &mut BufReader<TransportStream>) -> Result<(), ClientError> {
    let mut crlf = [0u8; 2];
    reader
        .read_exact(&mut crlf)
        .map_err(|e| ClientError::Io(e.to_string()))?;
    if &crlf != b"\r\n" {
        return Err(ClientError::InvalidResponse(
            "missing CRLF after HTTP chunk".to_string(),
        ));
    }
    Ok(())
}

fn read_retry_intr<R: Read>(reader: &mut R, buf: &mut [u8]) -> io::Result<usize> {
    loop {
        match reader.read(buf) {
            Ok(n) => return Ok(n),
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
}

fn http_status_error(status: u16, body: &[u8]) -> ClientError {
    if let Ok(err_resp) = serde_json::from_slice::<ErrorResponse>(body) {
        if let Some(msg) = err_resp.error {
            let full = match err_resp.reason {
                Some(reason) => format!("{msg} ({reason})"),
                None => msg,
            };
            return ClientError::HttpStatus {
                status,
                message: full,
            };
        }
    }
    let raw = String::from_utf8_lossy(body).trim().to_string();
    let message = if raw.is_empty() {
        format!("status {status}")
    } else {
        raw
    };
    ClientError::HttpStatus { status, message }
}

fn validate_path_segment(name: &str, value: &str) -> Result<(), ClientError> {
    if value.is_empty() || value.contains(['/', '\\', '\r', '\n', '\0']) {
        return Err(ClientError::InvalidInput(format!(
            "invalid {name} path segment"
        )));
    }
    Ok(())
}

pub fn percent_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char);
            }
            _ => {
                let _ = fmt::Write::write_fmt(&mut out, format_args!("%{byte:02X}"));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ServerFrame;
    use std::net::TcpListener;
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::thread;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn read_http_req(mut stream: impl Read) -> String {
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
                break;
            }
        }
        String::from_utf8_lossy(&buf).into_owned()
    }

    #[test]
    fn unix_socket_client_handles_api_and_chunked_sse() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sock_path = PathBuf::from(format!("/private/tmp/h-cli-test-{nanos}.sock"));
        let _ = std::fs::remove_file(&sock_path);
        let listener = UnixListener::bind(&sock_path).unwrap();

        let handle = thread::spawn(move || {
            // 1. GET /api/v1/environments
            let (mut s1, _) = listener.accept().unwrap();
            let req1 = read_http_req(&mut s1);
            assert!(req1.starts_with("GET /api/v1/environments HTTP/1.1"));
            assert!(req1.contains("Authorization: Bearer tok-test\r\n"));
            assert!(req1.contains("Host: localhost\r\n"));
            let body1 = r#"{"environments":[{"id":"host","kind":"host"}]}"#;
            write!(
                s1,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                body1.len(),
                body1
            )
            .unwrap();

            // 2. GET /api/v1/sessions?env_id=host&cwd=%2Ftmp%2Fmy%20proj
            let (mut s2, _) = listener.accept().unwrap();
            let req2 = read_http_req(&mut s2);
            assert!(req2.starts_with("GET /api/v1/sessions?env_id=host&cwd=%2Ftmp%2Fmy%20proj "));
            let body2 = r#"{"sessions":[{"session_id":"s1","cwd":"/tmp/my proj","active":false}]}"#;
            write!(
                s2,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                body2.len(),
                body2
            )
            .unwrap();

            // 3. POST /api/v1/sessions
            let (mut s3, _) = listener.accept().unwrap();
            let req3 = read_http_req(&mut s3);
            assert!(req3.starts_with("POST /api/v1/sessions HTTP/1.1"));
            let body3 = r#"{"session":{"session_id":"s1","cwd":"/tmp/my proj","root_conversation_id":"1"},"seq":1}"#;
            write!(
                s3,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                body3.len(),
                body3
            )
            .unwrap();

            // 4. POST /api/v1/sessions/s1/commands
            let (mut s4, _) = listener.accept().unwrap();
            let req4 = read_http_req(&mut s4);
            assert!(req4.starts_with("POST /api/v1/sessions/s1/commands HTTP/1.1"));
            assert!(req4.contains(r#""request_id":"req-123""#));
            let body4 = r#"{"version":1,"request_id":"req-123","seq":2,"submission_id":"sub-1","status":"placed"}"#;
            write!(
                s4,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                body4.len(),
                body4
            )
            .unwrap();

            // 5. GET SSE events (chunked)
            let (mut s5, _) = listener.accept().unwrap();
            let req5 = read_http_req(&mut s5);
            assert!(req5.starts_with("GET /api/v1/sessions/s1/conversations/1/events HTTP/1.1"));
            write!(
                s5,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
            )
            .unwrap();

            let chunk1 = "id: 1\nevent: snapshot\ndata: {\"seq\":1,\"entries\":[],\"docs\":{}}\n\n";
            write!(s5, "{:x}\r\n{}\r\n", chunk1.len(), chunk1).unwrap();
            let chunk2 = ": keepalive\n\nid: 2\nevent: commit\ndata: {\"seq\":2,\"prev_seq\":1,\"appended_entries\":[],\"doc_ops\":{}}\n\n";
            write!(s5, "{:x}\r\n{}\r\n", chunk2.len(), chunk2).unwrap();
            write!(s5, "0\r\n\r\n").unwrap();
        });

        let client = DaemonClient::new(
            DaemonTarget::UnixSocket(sock_path.clone()),
            SecretToken::new("tok-test").unwrap(),
        );

        let envs = client.get_environments().unwrap();
        assert_eq!(envs.len(), 1);
        assert_eq!(envs[0].id, "host");

        let sessions = client
            .list_sessions(Some("host"), Some("/tmp/my proj"), None)
            .unwrap();
        assert_eq!(sessions[0].session_id, "s1");

        let created = client
            .create_session(&CreateSessionRequest {
                version: 1,
                request_id: "c1".to_string(),
                env_id: "host".to_string(),
                cwd: "/tmp/my proj".to_string(),
                session_id: None,
                title: None,
                agent: None,
                parent: None,
                role: None,
            })
            .unwrap();
        assert_eq!(created.seq, 1);

        let cmd = CommandEnvelope::submit_input(
            "req-123",
            1,
            "hi",
            crate::protocol::WhenBusy::FollowUp,
            crate::protocol::WhenIdle::Start,
        );
        let receipt = client.post_command("s1", &cmd).unwrap();
        assert_eq!(receipt.seq, Some(2));

        let mut sse = client.subscribe_events("s1", "1", None).unwrap();
        let ev1 = sse.next_event().unwrap().unwrap();
        assert!(matches!(ev1.decode_frame().unwrap(), ServerFrame::Snapshot(s) if s.seq == 1));
        let ev2 = sse.next_event().unwrap().unwrap();
        assert!(matches!(ev2.decode_frame().unwrap(), ServerFrame::Commit(c) if c.seq == 2));
        assert!(sse.next_event().unwrap().is_none());

        handle.join().unwrap();
        let _ = std::fs::remove_file(&sock_path);
    }

    #[test]
    fn tcp_loopback_client_refuses_redirects() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        let handle = thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let req = read_http_req(&mut s);
            assert!(req.contains(&format!("Host: 127.0.0.1:{port}\r\n")));
            write!(
                s,
                "HTTP/1.1 302 Found\r\nLocation: http://evil.example/steal\r\nContent-Length: 0\r\n\r\n"
            )
            .unwrap();
        });

        let client = DaemonClient::new(
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            },
            SecretToken::new("tok-secret").unwrap(),
        );

        let err = client.get_environments().unwrap_err();
        assert!(matches!(err, ClientError::RedirectDisabled { status: 302 }));
        handle.join().unwrap();
    }

    #[test]
    fn stream_cancel_unblocks_blocked_unix_and_tcp_sse_reads() {
        // 1. Unix socket
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sock_path = PathBuf::from(format!("/private/tmp/h-cancel-test-{nanos}.sock"));
        let _ = std::fs::remove_file(&sock_path);
        let listener = UnixListener::bind(&sock_path).unwrap();

        let srv = thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let _ = read_http_req(&mut s);
            write!(
                s,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
            )
            .unwrap();
            s.flush().unwrap();
            // Keep server socket open without sending data until client disconnects.
            let mut tmp = [0u8; 16];
            let _ = s.read(&mut tmp);
        });

        let client = DaemonClient::new(
            DaemonTarget::UnixSocket(sock_path.clone()),
            SecretToken::new("tok-cancel").unwrap(),
        );
        let cancel = StreamCancel::new();
        let mut sse = client
            .subscribe_events_cancellable("s1", "1", None, &cancel)
            .unwrap();

        let cancel_clone = cancel.clone();
        let stopper = thread::spawn(move || {
            thread::sleep(Duration::from_millis(30));
            cancel_clone.cancel();
        });

        let started = std::time::Instant::now();
        let res = sse.next_event();
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(matches!(res, Ok(None) | Err(_)));
        stopper.join().unwrap();
        srv.join().unwrap();
        let _ = std::fs::remove_file(&sock_path);

        // 2. TCP loopback
        let tcp_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = tcp_listener.local_addr().unwrap().port();
        let tcp_srv = thread::spawn(move || {
            let (mut s, _) = tcp_listener.accept().unwrap();
            let _ = read_http_req(&mut s);
            write!(
                s,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
            )
            .unwrap();
            s.flush().unwrap();
            let mut tmp = [0u8; 16];
            let _ = s.read(&mut tmp);
        });

        let tcp_client = DaemonClient::new(
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            },
            SecretToken::new("tok-cancel").unwrap(),
        );
        let tcp_cancel = StreamCancel::new();
        let mut tcp_sse = tcp_client
            .subscribe_events_cancellable("s1", "1", None, &tcp_cancel)
            .unwrap();

        let tcp_cancel_clone = tcp_cancel.clone();
        let tcp_stopper = thread::spawn(move || {
            thread::sleep(Duration::from_millis(30));
            tcp_cancel_clone.cancel();
        });

        let tcp_started = std::time::Instant::now();
        let tcp_res = tcp_sse.next_event();
        assert!(tcp_started.elapsed() < Duration::from_secs(1));
        assert!(matches!(tcp_res, Ok(None) | Err(_)));
        tcp_stopper.join().unwrap();
        tcp_srv.join().unwrap();
    }

    #[test]
    fn oversized_http_header_and_chunk_lines_are_rejected() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        let handle = thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let _ = read_http_req(&mut s);
            write!(s, "HTTP/1.1 200 OK\r\nX-Big: ").unwrap();
            let big = vec![b'a'; MAX_HEADER_BYTES + 128];
            let _ = s.write_all(&big);
            let _ = s.write_all(b"\r\n\r\n");
        });

        let client = DaemonClient::new(
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            },
            SecretToken::new("tok-test").unwrap(),
        );
        let err = client.get_environments().unwrap_err();
        assert!(matches!(err, ClientError::InvalidResponse(_)));
        handle.join().unwrap();
    }

    #[test]
    fn oversized_chunk_size_line_is_rejected() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        let handle = thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let _ = read_http_req(&mut s);
            write!(
                s,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
            )
            .unwrap();
            let big_chunk_line = vec![b'0'; MAX_CHUNK_LINE_BYTES + 64];
            let _ = s.write_all(&big_chunk_line);
            let _ = s.write_all(b"\r\n");
        });

        let client = DaemonClient::new(
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            },
            SecretToken::new("tok-test").unwrap(),
        );
        let mut sse = client.subscribe_events("s1", "1", None).unwrap();
        let err = sse.next_event().unwrap_err();
        assert!(matches!(err, ClientError::InvalidResponse(_)));
        handle.join().unwrap();
    }

    #[test]
    fn session_scoped_workspace_files_and_file_read_encode_query_and_decode_responses() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sock_path = PathBuf::from(format!("/private/tmp/h-ws-client-{nanos}.sock"));
        let _ = std::fs::remove_file(&sock_path);
        let listener = UnixListener::bind(&sock_path).unwrap();

        let handle = thread::spawn(move || {
            // 1. GET /sessions/s1/files?query=lib%2F&limit=50
            let (mut s1, _) = listener.accept().unwrap();
            let req1 = read_http_req(&mut s1);
            assert!(
                req1.starts_with("GET /api/v1/sessions/s1/files?query=lib%2F&limit=50 HTTP/1.1"),
                "req1={req1}"
            );
            let body1 = r#"{"env_id":"vm-1","cwd":"/work","entries":[{"path":"lib","type":"dir","size":0},{"path":"lib/app.ex","type":"file","size":42}],"truncated":false}"#;
            write!(
                s1,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body1}",
                body1.len()
            )
            .unwrap();

            // 2. GET /sessions/s1/file?path=lib%2Fapp.ex&offset=1&limit=200
            let (mut s2, _) = listener.accept().unwrap();
            let req2 = read_http_req(&mut s2);
            assert!(
                req2.starts_with(
                    "GET /api/v1/sessions/s1/file?path=lib%2Fapp.ex&offset=1&limit=200 HTTP/1.1"
                ),
                "req2={req2}"
            );
            let body2 = r#"{"env_id":"vm-1","cwd":"/work","path":"lib/app.ex","resolved_path":"/work/lib/app.ex","lines":["defmodule App do","end"],"start_line":1,"total_lines_read":2,"has_more":false,"truncated_by_bytes":false}"#;
            write!(
                s2,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body2}",
                body2.len()
            )
            .unwrap();

            // 3. 503 workspace unavailable surfaces HTTP error directly
            let (mut s3, _) = listener.accept().unwrap();
            let _req3 = read_http_req(&mut s3);
            let body3 = r#"{"error":"workspace unavailable"}"#;
            write!(
                s3,
                "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body3}",
                body3.len()
            )
            .unwrap();
        });

        let client = DaemonClient::new(
            DaemonTarget::UnixSocket(sock_path.clone()),
            SecretToken::new("tok-ws").unwrap(),
        );

        assert!(matches!(
            client.list_session_files("s1", Some("a\0b"), None),
            Err(ClientError::InvalidInput(_))
        ));
        assert!(matches!(
            client.read_session_file("s1", "", None, None, None),
            Err(ClientError::InvalidInput(_))
        ));

        let files = client
            .list_session_files("s1", Some("lib/"), Some(50))
            .unwrap();
        assert_eq!(files.env_id, "vm-1");
        assert_eq!(files.cwd, "/work");
        assert_eq!(files.entries.len(), 2);
        assert_eq!(files.entries[0].kind, "dir");
        assert_eq!(files.entries[1].path, "lib/app.ex");

        let read = client
            .read_session_file("s1", "lib/app.ex", Some(1), Some(200), None)
            .unwrap();
        assert_eq!(read.env_id, "vm-1");
        assert_eq!(read.lines, vec!["defmodule App do", "end"]);
        assert!(!read.has_more);

        let err = client.list_session_files("s1", None, None).unwrap_err();
        assert!(matches!(err, ClientError::HttpStatus { status: 503, .. }));

        handle.join().unwrap();
        let _ = std::fs::remove_file(&sock_path);
    }
}
