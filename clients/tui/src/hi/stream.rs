use crate::client::{ClientError, DaemonClient, StreamCancel};
use crate::protocol::ServerFrame;
use crate::render::sanitize_single_line;
use serde_json::Value;
use std::collections::VecDeque;
use std::fmt;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const DEFAULT_MAX_QUEUE_LEN: usize = 256;
const DEFAULT_MAX_QUEUE_BYTES: usize = 16 * 1024 * 1024;
const DEFAULT_INITIAL_BACKOFF: Duration = Duration::from_millis(50);
const DEFAULT_MAX_BACKOFF: Duration = Duration::from_secs(5);
const HEALTHY_CONN_RESET_AGE: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, PartialEq)]
pub enum Update {
    Frame(ServerFrame),
    Offline(String),
    Online,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct StreamConfig {
    pub max_queue_len: usize,
    pub max_queue_bytes: usize,
    pub initial_backoff: Duration,
    pub max_backoff: Duration,
}

impl Default for StreamConfig {
    fn default() -> Self {
        Self {
            max_queue_len: DEFAULT_MAX_QUEUE_LEN,
            max_queue_bytes: DEFAULT_MAX_QUEUE_BYTES,
            initial_backoff: DEFAULT_INITIAL_BACKOFF,
            max_backoff: DEFAULT_MAX_BACKOFF,
        }
    }
}

struct QueuedUpdate {
    update: Update,
    bytes: usize,
}

struct QueueState {
    queue: VecDeque<QueuedUpdate>,
    queued_bytes: usize,
    max_len: usize,
    max_bytes: usize,
}

impl QueueState {
    fn new(max_len: usize, max_bytes: usize) -> Self {
        Self {
            queue: VecDeque::new(),
            queued_bytes: 0,
            max_len: max_len.max(1),
            max_bytes: max_bytes.max(1),
        }
    }

    fn pop(&mut self) -> Option<Update> {
        let item = self.queue.pop_front()?;
        self.queued_bytes = self.queued_bytes.saturating_sub(item.bytes);
        Some(item.update)
    }

    fn push_frame(&mut self, frame: ServerFrame) -> bool {
        let update = Update::Frame(frame);
        let bytes = estimate_update_bytes(&update);
        if self.would_overflow(bytes) {
            self.clear();
            return false;
        }
        self.queued_bytes = self.queued_bytes.saturating_add(bytes);
        self.queue.push_back(QueuedUpdate { update, bytes });
        true
    }

    /// Pushes `Online` or `Offline` status. Returns `true` if no buffered frames
    /// had to be evicted, or `false` if older queued frames were cleared to make room
    /// (requiring a fresh snapshot on the next stream).
    fn push_status(&mut self, update: Update) -> bool {
        let bytes = estimate_update_bytes(&update);
        let evicted = if self.would_overflow(bytes) {
            self.clear();
            true
        } else {
            false
        };
        self.queued_bytes = self.queued_bytes.saturating_add(bytes);
        self.queue.push_back(QueuedUpdate { update, bytes });
        !evicted
    }

    fn would_overflow(&self, next_bytes: usize) -> bool {
        self.queue.len() >= self.max_len
            || (!self.queue.is_empty()
                && self.queued_bytes.saturating_add(next_bytes) > self.max_bytes)
    }

    fn clear(&mut self) {
        self.queue.clear();
        self.queued_bytes = 0;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ConnState {
    Initial,
    Online,
    Offline,
}

pub struct Subscription {
    queue: Arc<Mutex<QueueState>>,
    cancel: StreamCancel,
    worker: Option<JoinHandle<()>>,
}

impl fmt::Debug for Subscription {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Subscription")
            .field("cancelled", &self.cancel.is_cancelled())
            .finish()
    }
}

impl Subscription {
    pub fn start(client: DaemonClient, sid: String, cid: String, from: Option<u64>) -> Self {
        Self::start_with_config(client, sid, cid, from, StreamConfig::default())
    }

    pub(crate) fn start_with_config(
        client: DaemonClient,
        sid: String,
        cid: String,
        from: Option<u64>,
        config: StreamConfig,
    ) -> Self {
        let queue = Arc::new(Mutex::new(QueueState::new(
            config.max_queue_len,
            config.max_queue_bytes,
        )));
        let cancel = StreamCancel::new();

        let worker_queue = Arc::clone(&queue);
        let worker_cancel = cancel.clone();
        let worker = thread::spawn(move || {
            run_worker(client, sid, cid, from, config, worker_queue, worker_cancel);
        });

        Self {
            queue,
            cancel,
            worker: Some(worker),
        }
    }

    pub fn next(&self) -> Option<Update> {
        let mut state = self.queue.lock().unwrap_or_else(|e| e.into_inner());
        state.pop()
    }
}

impl Drop for Subscription {
    fn drop(&mut self) {
        self.cancel.cancel();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn run_worker(
    client: DaemonClient,
    sid: String,
    cid: String,
    from: Option<u64>,
    config: StreamConfig,
    queue: Arc<Mutex<QueueState>>,
    cancel: StreamCancel,
) {
    let mut last_durable_seq = from;
    let mut conn_state = ConnState::Initial;
    let mut backoff = config.initial_backoff;

    while !cancel.is_cancelled() {
        let mut sse =
            match client.subscribe_events_cancellable(&sid, &cid, last_durable_seq, &cancel) {
                Ok(stream) => stream,
                Err(err) => {
                    if cancel.is_cancelled() {
                        break;
                    }
                    if conn_state != ConnState::Offline {
                        let msg = sanitize_single_line(&err.to_string());
                        let kept = queue
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .push_status(Update::Offline(msg));
                        if !kept {
                            last_durable_seq = None;
                        }
                        conn_state = ConnState::Offline;
                    }
                    if matches!(err, ClientError::InvalidInput(_)) {
                        while cancel.wait_timeout(config.max_backoff) {}
                        break;
                    }
                    if !cancel.wait_timeout(backoff) {
                        break;
                    }
                    backoff = next_backoff(backoff, config.max_backoff);
                    continue;
                }
            };

        let connected_at = Instant::now();
        let mut saw_frame = false;
        let mut overflowed = false;

        if conn_state != ConnState::Online {
            let kept = queue
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push_status(Update::Online);
            if !kept {
                last_durable_seq = None;
            }
            conn_state = ConnState::Online;
        }

        let disconnect_reason: Option<String> = loop {
            if cancel.is_cancelled() {
                break None;
            }
            match sse.next_event() {
                Ok(Some(ev)) => match ev.decode_frame() {
                    Ok(frame) => {
                        saw_frame = true;
                        backoff = config.initial_backoff;
                        let next_durable = durable_seq_for_frame(&frame, last_durable_seq);
                        let pushed = queue
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .push_frame(frame);
                        if pushed {
                            if let Some(seq) = next_durable {
                                last_durable_seq = Some(seq);
                            }
                        } else {
                            // Queue overflow: abandon current stream, clear buffered
                            // deltas, and reconnect from None for a fresh snapshot.
                            last_durable_seq = None;
                            overflowed = true;
                            break None;
                        }
                    }
                    Err(err) => {
                        break Some(sanitize_single_line(&err.to_string()));
                    }
                },
                Ok(None) => {
                    break Some("stream closed".to_string());
                }
                Err(err) => {
                    break Some(sanitize_single_line(&err.to_string()));
                }
            }
        };

        drop(sse);
        cancel.clear_active();

        if cancel.is_cancelled() {
            break;
        }

        if overflowed {
            backoff = config.initial_backoff;
            continue;
        }

        if saw_frame || connected_at.elapsed() >= HEALTHY_CONN_RESET_AGE {
            backoff = config.initial_backoff;
        }

        if let Some(reason) = disconnect_reason {
            if conn_state != ConnState::Offline {
                let kept = queue
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .push_status(Update::Offline(reason));
                if !kept {
                    last_durable_seq = None;
                }
                conn_state = ConnState::Offline;
            }
        }

        if !cancel.wait_timeout(backoff) {
            break;
        }
        backoff = next_backoff(backoff, config.max_backoff);
    }
}

fn durable_seq_for_frame(frame: &ServerFrame, current: Option<u64>) -> Option<u64> {
    match frame {
        ServerFrame::Snapshot(snap) => Some(snap.seq),
        ServerFrame::Commit(commit) => {
            Some(current.map_or(commit.seq, |prev| prev.max(commit.seq)))
        }
        ServerFrame::Ephemeral(_) | ServerFrame::Unknown { .. } => None,
    }
}

fn next_backoff(current: Duration, max_backoff: Duration) -> Duration {
    let base = if current.is_zero() {
        Duration::from_millis(1)
    } else {
        current
    };
    base.saturating_mul(2).min(max_backoff)
}

fn estimate_update_bytes(update: &Update) -> usize {
    match update {
        Update::Online => 16,
        Update::Offline(msg) => 32 + msg.len(),
        Update::Frame(frame) => match frame {
            ServerFrame::Snapshot(s) => {
                64 + s
                    .entries
                    .iter()
                    .map(|e| e.id.len() + e.kind.len() + estimate_value_bytes(&e.data) + 32)
                    .sum::<usize>()
                    + s.docs.as_ref().map_or(0, estimate_value_bytes)
            }
            ServerFrame::Commit(c) => {
                64 + c
                    .appended_entries
                    .iter()
                    .map(|e| e.id.len() + e.kind.len() + estimate_value_bytes(&e.data) + 32)
                    .sum::<usize>()
                    + c.doc_ops
                        .as_ref()
                        .map_or(0, |m| m.values().map(estimate_value_bytes).sum())
            }
            ServerFrame::Ephemeral(e) => {
                48 + e
                    .doc_ops
                    .as_ref()
                    .map_or(0, |m| m.values().map(estimate_value_bytes).sum())
                    + e.ops
                        .as_ref()
                        .map_or(0, |ops| ops.iter().map(estimate_value_bytes).sum())
            }
            ServerFrame::Unknown { event, data } => {
                32 + event.as_ref().map_or(0, String::len) + data.len()
            }
        },
    }
}

fn estimate_value_bytes(v: &Value) -> usize {
    match v {
        Value::Null => 4,
        Value::Bool(_) => 5,
        Value::Number(_) => 16,
        Value::String(s) => s.len() + 2,
        Value::Array(arr) => 2 + arr.iter().map(estimate_value_bytes).sum::<usize>(),
        Value::Object(map) => {
            2 + map
                .iter()
                .map(|(k, val)| k.len() + 4 + estimate_value_bytes(val))
                .sum::<usize>()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{DaemonTarget, LoopbackHost, SecretToken};
    use crate::transcript::{CommitOutcome, EphemeralOutcome, TranscriptState};
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn read_http_req(stream: &mut impl Read) -> String {
        let mut buf = Vec::new();
        let mut tmp = [0u8; 1024];
        loop {
            let n = stream.read(&mut tmp).unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
            if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                break;
            }
        }
        String::from_utf8_lossy(&buf).into_owned()
    }

    fn extract_last_event_id(req: &str) -> Option<String> {
        req.lines().find_map(|line| {
            let (k, v) = line.split_once(':')?;
            if k.eq_ignore_ascii_case("last-event-id") {
                Some(v.trim().to_string())
            } else {
                None
            }
        })
    }

    fn wait_for_next(sub: &Subscription, timeout: Duration) -> Update {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(u) = sub.next() {
                return u;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for Subscription::next()"
            );
            thread::sleep(Duration::from_millis(5));
        }
    }

    fn write_sse_headers(stream: &mut impl Write) {
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
        )
        .unwrap();
        stream.flush().unwrap();
    }

    fn write_sse_chunk(stream: &mut impl Write, payload: &str) {
        write!(stream, "{:x}\r\n{}\r\n", payload.len(), payload).unwrap();
        stream.flush().unwrap();
    }

    #[test]
    fn subscription_delivers_frames_nonblocking_and_reconnects_from_durable_seq_only() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        let seen_last_ids = Arc::new(Mutex::new(Vec::<Option<String>>::new()));
        let seen_clone = Arc::clone(&seen_last_ids);

        let srv = thread::spawn(move || {
            // Connection 1: initial (from = Some(5)), sends Snapshot(10), Commit(11), Ephemeral(base_seq=11), then drops.
            let (mut s1, _) = listener.accept().unwrap();
            let req1 = read_http_req(&mut s1);
            assert!(req1.starts_with("GET /api/v1/sessions/s1/conversations/1/events "));
            seen_clone
                .lock()
                .unwrap()
                .push(extract_last_event_id(&req1));

            write_sse_headers(&mut s1);
            write_sse_chunk(
                &mut s1,
                "id: 10\nevent: snapshot\ndata: {\"seq\":10,\"entries\":[],\"docs\":{\"live\":{},\"inbox\":[],\"agent\":{},\"usage\":{}}}\n\n",
            );
            write_sse_chunk(
                &mut s1,
                "id: 11\nevent: commit\ndata: {\"seq\":11,\"prev_seq\":10,\"appended_entries\":[{\"id\":\"1\",\"kind\":\"user\",\"data\":{\"text\":\"hi\"}}],\"doc_ops\":{\"live\":[[\"replace\",{\"run\":{\"turns\":1}}]]}}\n\n",
            );
            write_sse_chunk(
                &mut s1,
                "event: ephemeral\ndata: {\"base_seq\":11,\"doc_ops\":{\"live\":[[\"append_text\",[\"generation\",\"message\",\"text\"],\"Hel\"]]}}\n\n",
            );
            drop(s1);

            // Connection 2: must reconnect with Last-Event-ID: 11 (durable Commit), NOT ephemeral.
            let (mut s2, _) = listener.accept().unwrap();
            let req2 = read_http_req(&mut s2);
            seen_clone
                .lock()
                .unwrap()
                .push(extract_last_event_id(&req2));

            write_sse_headers(&mut s2);
            // Send only an ephemeral with base_seq=99 (stale/mismatched) before dropping again!
            write_sse_chunk(
                &mut s2,
                "event: ephemeral\ndata: {\"base_seq\":99,\"doc_ops\":{\"live\":[[\"append_text\",[\"generation\",\"message\",\"text\"],\"BAD\"]]}}\n\n",
            );
            drop(s2);

            // Connection 3: must STILL reconnect with Last-Event-ID: 11 (never 99 from ephemeral).
            let (mut s3, _) = listener.accept().unwrap();
            let req3 = read_http_req(&mut s3);
            seen_clone
                .lock()
                .unwrap()
                .push(extract_last_event_id(&req3));

            write_sse_headers(&mut s3);
            write_sse_chunk(
                &mut s3,
                "id: 12\nevent: commit\ndata: {\"seq\":12,\"prev_seq\":11,\"appended_entries\":[{\"id\":\"2\",\"kind\":\"assistant\",\"data\":{\"text\":\"Hello!\"}}],\"doc_ops\":{\"live\":[[\"replace\",{}]]}}\n\n",
            );
            // Stay open until client drops.
            let mut tmp = [0u8; 16];
            let _ = s3.read(&mut tmp);
        });

        let client = DaemonClient::new(
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            },
            SecretToken::new("tok-stream").unwrap(),
        );

        let sub = Subscription::start_with_config(
            client,
            "s1".to_string(),
            "1".to_string(),
            Some(5),
            StreamConfig {
                initial_backoff: Duration::from_millis(10),
                max_backoff: Duration::from_millis(50),
                ..StreamConfig::default()
            },
        );

        let mut transcript = TranscriptState::new(Some("s1".to_string()), Some("1".to_string()));

        // Online, Snapshot(10), Commit(11), Ephemeral(11)
        assert_eq!(wait_for_next(&sub, Duration::from_secs(2)), Update::Online);
        match wait_for_next(&sub, Duration::from_secs(2)) {
            Update::Frame(ServerFrame::Snapshot(s)) => {
                assert_eq!(s.seq, 10);
                transcript.apply_snapshot(s);
            }
            other => panic!("expected snapshot, got {other:?}"),
        }
        match wait_for_next(&sub, Duration::from_secs(2)) {
            Update::Frame(ServerFrame::Commit(c)) => {
                assert_eq!(c.seq, 11);
                assert!(matches!(
                    transcript.apply_commit(c),
                    CommitOutcome::Applied { .. }
                ));
            }
            other => panic!("expected commit 11, got {other:?}"),
        }
        match wait_for_next(&sub, Duration::from_secs(2)) {
            Update::Frame(ServerFrame::Ephemeral(e)) => {
                assert_eq!(e.base_seq, 11);
                assert_eq!(transcript.apply_ephemeral(e), EphemeralOutcome::Applied);
            }
            other => panic!("expected ephemeral, got {other:?}"),
        }

        // Offline -> Online -> Ephemeral(99) -> Offline -> Online -> Commit(12)
        assert!(matches!(
            wait_for_next(&sub, Duration::from_secs(2)),
            Update::Offline(_)
        ));
        assert_eq!(wait_for_next(&sub, Duration::from_secs(2)), Update::Online);
        match wait_for_next(&sub, Duration::from_secs(2)) {
            Update::Frame(ServerFrame::Ephemeral(e)) => {
                assert_eq!(e.base_seq, 99);
                assert_eq!(transcript.apply_ephemeral(e), EphemeralOutcome::Ignored);
            }
            other => panic!("expected ephemeral 99, got {other:?}"),
        }
        assert!(matches!(
            wait_for_next(&sub, Duration::from_secs(2)),
            Update::Offline(_)
        ));
        assert_eq!(wait_for_next(&sub, Duration::from_secs(2)), Update::Online);
        match wait_for_next(&sub, Duration::from_secs(2)) {
            Update::Frame(ServerFrame::Commit(c)) => {
                assert_eq!(c.seq, 12);
                assert!(matches!(
                    transcript.apply_commit(c),
                    CommitOutcome::Applied { .. }
                ));
            }
            other => panic!("expected commit 12, got {other:?}"),
        }

        // Nonblocking next() returns None when caught up.
        assert_eq!(sub.next(), None);
        assert_eq!(transcript.seq, Some(12));
        assert_eq!(transcript.entries.len(), 2);

        drop(sub);
        srv.join().unwrap();

        let ids = seen_last_ids.lock().unwrap().clone();
        assert_eq!(
            ids,
            vec![
                Some("5".to_string()),
                Some("11".to_string()),
                Some("11".to_string()),
            ]
        );
    }

    #[test]
    fn initial_connection_failure_emits_offline_once_then_online_when_server_recovers() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sock_path = PathBuf::from(format!("/tmp/h-stream-offline-{nanos}.sock"));
        let _ = std::fs::remove_file(&sock_path);

        let client = DaemonClient::new(
            DaemonTarget::UnixSocket(sock_path.clone()),
            SecretToken::new("tok-offline").unwrap(),
        );

        let sub = Subscription::start_with_config(
            client,
            "s1".to_string(),
            "1".to_string(),
            None,
            StreamConfig {
                initial_backoff: Duration::from_millis(15),
                max_backoff: Duration::from_millis(30),
                ..StreamConfig::default()
            },
        );

        // First update must be Offline since socket doesn't exist yet.
        assert!(matches!(
            wait_for_next(&sub, Duration::from_secs(2)),
            Update::Offline(_)
        ));

        // Let a couple retries happen while still down, confirming Offline is not spammed.
        thread::sleep(Duration::from_millis(80));
        assert_eq!(sub.next(), None);

        // Now bind the Unix socket and serve a snapshot.
        let listener = UnixListener::bind(&sock_path).unwrap();
        let srv = thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let req = read_http_req(&mut s);
            assert!(extract_last_event_id(&req).is_none());
            write_sse_headers(&mut s);
            write_sse_chunk(
                &mut s,
                "id: 1\nevent: snapshot\ndata: {\"seq\":1,\"entries\":[],\"docs\":{}}\n\n",
            );
            let mut tmp = [0u8; 16];
            let _ = s.read(&mut tmp);
        });

        assert_eq!(wait_for_next(&sub, Duration::from_secs(2)), Update::Online);
        assert!(matches!(
            wait_for_next(&sub, Duration::from_secs(2)),
            Update::Frame(ServerFrame::Snapshot(s)) if s.seq == 1
        ));

        drop(sub);
        srv.join().unwrap();
        let _ = std::fs::remove_file(&sock_path);
    }

    #[test]
    fn drop_cancels_blocked_stream_and_backoff_immediately() {
        // 1. Drop while blocked in SSE read()
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let srv = thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let _ = read_http_req(&mut s);
            write_sse_headers(&mut s);
            let mut tmp = [0u8; 16];
            let _ = s.read(&mut tmp);
        });

        let client = DaemonClient::new(
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            },
            SecretToken::new("tok-drop").unwrap(),
        );
        let sub = Subscription::start(client.clone(), "s1".to_string(), "1".to_string(), None);
        assert_eq!(wait_for_next(&sub, Duration::from_secs(2)), Update::Online);

        let started = Instant::now();
        drop(sub);
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "Drop blocked waiting for idle SSE read"
        );
        srv.join().unwrap();

        // 2. Drop while sleeping in long backoff
        let dead_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let dead_port = dead_listener.local_addr().unwrap().port();
        drop(dead_listener);

        let dead_client = DaemonClient::new(
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port: dead_port,
            },
            SecretToken::new("tok-drop2").unwrap(),
        );
        let sub2 = Subscription::start_with_config(
            dead_client,
            "s1".to_string(),
            "1".to_string(),
            None,
            StreamConfig {
                initial_backoff: Duration::from_secs(30),
                max_backoff: Duration::from_secs(30),
                ..StreamConfig::default()
            },
        );
        assert!(matches!(
            wait_for_next(&sub2, Duration::from_secs(2)),
            Update::Offline(_)
        ));
        let started2 = Instant::now();
        drop(sub2);
        assert!(
            started2.elapsed() < Duration::from_secs(1),
            "Drop blocked waiting for backoff sleep"
        );
    }

    #[test]
    fn queue_overflow_abandons_stream_and_requests_fresh_snapshot() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        let conn_count = Arc::new(AtomicUsize::new(0));
        let conn_count_srv = Arc::clone(&conn_count);
        let second_req_last_id = Arc::new(Mutex::new(Some("UNSET".to_string())));
        let second_req_last_id_srv = Arc::clone(&second_req_last_id);

        let srv = thread::spawn(move || {
            // Connection 1: send Online + Snapshot(1) + 10 commits (exceeds max_queue_len = 4).
            let (mut s1, _) = listener.accept().unwrap();
            conn_count_srv.fetch_add(1, Ordering::SeqCst);
            let _ = read_http_req(&mut s1);
            write_sse_headers(&mut s1);
            write_sse_chunk(
                &mut s1,
                "id: 1\nevent: snapshot\ndata: {\"seq\":1,\"entries\":[],\"docs\":{}}\n\n",
            );
            for seq in 2..=12 {
                let frame = format!(
                    "id: {seq}\nevent: commit\ndata: {{\"seq\":{seq},\"prev_seq\":{},\"appended_entries\":[{{\"id\":\"{seq}\",\"kind\":\"assistant\",\"data\":{{\"text\":\"m{seq}\"}}}}],\"doc_ops\":{{}}}}\n\n",
                    seq - 1
                );
                write_sse_chunk(&mut s1, &frame);
            }
            // Wait until client abandons s1
            let mut tmp = [0u8; 32];
            let _ = s1.read(&mut tmp);

            // Connection 2: must NOT send Last-Event-ID (must be None for fresh snapshot).
            let (mut s2, _) = listener.accept().unwrap();
            conn_count_srv.fetch_add(1, Ordering::SeqCst);
            let req2 = read_http_req(&mut s2);
            *second_req_last_id_srv.lock().unwrap() = extract_last_event_id(&req2);
            write_sse_headers(&mut s2);
            write_sse_chunk(
                &mut s2,
                "id: 12\nevent: snapshot\ndata: {\"seq\":12,\"entries\":[{\"id\":\"12\",\"kind\":\"assistant\",\"data\":{\"text\":\"m12\"}}],\"docs\":{}}\n\n",
            );
            let _ = s2.read(&mut tmp);
        });

        let client = DaemonClient::new(
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            },
            SecretToken::new("tok-ovf").unwrap(),
        );

        let sub = Subscription::start_with_config(
            client,
            "s1".to_string(),
            "1".to_string(),
            None,
            StreamConfig {
                max_queue_len: 4,
                max_queue_bytes: 1024 * 1024,
                initial_backoff: Duration::from_millis(10),
                max_backoff: Duration::from_millis(20),
            },
        );

        // Wait until connection 2 has sent the fresh snapshot.
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut saw_snapshot_12 = false;
        while Instant::now() < deadline {
            if let Some(Update::Frame(ServerFrame::Snapshot(s))) = sub.next() {
                if s.seq == 12 {
                    saw_snapshot_12 = true;
                    break;
                }
            }
            thread::sleep(Duration::from_millis(5));
        }

        assert!(
            saw_snapshot_12,
            "expected fresh snapshot seq=12 after overflow"
        );
        assert_eq!(conn_count.load(Ordering::SeqCst), 2);
        assert_eq!(*second_req_last_id.lock().unwrap(), None);

        drop(sub);
        srv.join().unwrap();
    }

    #[test]
    fn reducer_gap_triggers_ui_drop_and_restart_from_none() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        let srv = thread::spawn(move || {
            // Subscription 1: sends snapshot(10) then gapped commit(13, prev_seq=12).
            let (mut s1, _) = listener.accept().unwrap();
            let req1 = read_http_req(&mut s1);
            assert!(extract_last_event_id(&req1).is_none());
            write_sse_headers(&mut s1);
            write_sse_chunk(
                &mut s1,
                "id: 10\nevent: snapshot\ndata: {\"seq\":10,\"entries\":[],\"docs\":{}}\n\n",
            );
            write_sse_chunk(
                &mut s1,
                "id: 13\nevent: commit\ndata: {\"seq\":13,\"prev_seq\":12,\"appended_entries\":[],\"doc_ops\":{}}\n\n",
            );
            let mut tmp = [0u8; 16];
            let _ = s1.read(&mut tmp);

            // Subscription 2 (after UI drops & restarts with from = None): sends snapshot(13).
            let (mut s2, _) = listener.accept().unwrap();
            let req2 = read_http_req(&mut s2);
            assert!(extract_last_event_id(&req2).is_none());
            write_sse_headers(&mut s2);
            write_sse_chunk(
                &mut s2,
                "id: 13\nevent: snapshot\ndata: {\"seq\":13,\"entries\":[{\"id\":\"5\",\"kind\":\"assistant\",\"data\":{\"text\":\"recovered\"}}],\"docs\":{}}\n\n",
            );
            let _ = s2.read(&mut tmp);
        });

        let client = DaemonClient::new(
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            },
            SecretToken::new("tok-gap").unwrap(),
        );

        let mut transcript = TranscriptState::new(Some("s1".to_string()), Some("1".to_string()));
        let sub1 = Subscription::start(client.clone(), "s1".to_string(), "1".to_string(), None);

        assert_eq!(wait_for_next(&sub1, Duration::from_secs(2)), Update::Online);
        match wait_for_next(&sub1, Duration::from_secs(2)) {
            Update::Frame(ServerFrame::Snapshot(s)) => transcript.apply_snapshot(s),
            other => panic!("expected snapshot, got {other:?}"),
        }
        let saw_gap = match wait_for_next(&sub1, Duration::from_secs(2)) {
            Update::Frame(ServerFrame::Commit(c)) => {
                transcript.apply_commit(c) == CommitOutcome::Gap
            }
            other => panic!("expected commit, got {other:?}"),
        };
        assert!(saw_gap);

        // UI drops and restarts on reducer gap.
        drop(sub1);
        let sub2 = Subscription::start(client, "s1".to_string(), "1".to_string(), None);
        assert_eq!(wait_for_next(&sub2, Duration::from_secs(2)), Update::Online);
        match wait_for_next(&sub2, Duration::from_secs(2)) {
            Update::Frame(ServerFrame::Snapshot(s)) => transcript.apply_snapshot(s),
            other => panic!("expected snapshot 13, got {other:?}"),
        }
        assert_eq!(transcript.seq, Some(13));
        assert_eq!(transcript.entries.len(), 1);
        assert_eq!(transcript.entries[0].data["text"], "recovered");

        drop(sub2);
        srv.join().unwrap();
    }

    #[test]
    fn malformed_frame_triggers_offline_and_reconnects_from_durable_seq() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        let srv = thread::spawn(move || {
            let (mut s1, _) = listener.accept().unwrap();
            let _ = read_http_req(&mut s1);
            write_sse_headers(&mut s1);
            write_sse_chunk(
                &mut s1,
                "id: 7\nevent: snapshot\ndata: {\"seq\":7,\"entries\":[],\"docs\":{}}\n\n",
            );
            write_sse_chunk(&mut s1, "id: 8\nevent: commit\ndata: {not valid json\n\n");
            let mut tmp = [0u8; 16];
            let _ = s1.read(&mut tmp);

            let (mut s2, _) = listener.accept().unwrap();
            let req2 = read_http_req(&mut s2);
            assert_eq!(extract_last_event_id(&req2).as_deref(), Some("7"));
            write_sse_headers(&mut s2);
            write_sse_chunk(
                &mut s2,
                "id: 8\nevent: commit\ndata: {\"seq\":8,\"prev_seq\":7,\"appended_entries\":[],\"doc_ops\":{}}\n\n",
            );
            let _ = s2.read(&mut tmp);
        });

        let client = DaemonClient::new(
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            },
            SecretToken::new("tok-badjson").unwrap(),
        );

        let sub = Subscription::start_with_config(
            client,
            "s1".to_string(),
            "1".to_string(),
            None,
            StreamConfig {
                initial_backoff: Duration::from_millis(10),
                max_backoff: Duration::from_millis(30),
                ..StreamConfig::default()
            },
        );

        assert_eq!(wait_for_next(&sub, Duration::from_secs(2)), Update::Online);
        assert!(matches!(
            wait_for_next(&sub, Duration::from_secs(2)),
            Update::Frame(ServerFrame::Snapshot(s)) if s.seq == 7
        ));
        assert!(matches!(
            wait_for_next(&sub, Duration::from_secs(2)),
            Update::Offline(_)
        ));
        assert_eq!(wait_for_next(&sub, Duration::from_secs(2)), Update::Online);
        assert!(matches!(
            wait_for_next(&sub, Duration::from_secs(2)),
            Update::Frame(ServerFrame::Commit(c)) if c.seq == 8
        ));

        drop(sub);
        srv.join().unwrap();
    }

    #[test]
    fn queue_byte_budget_overflow_abandons_stream_and_resnapshots() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();

        let second_req_last_id = Arc::new(Mutex::new(Some("UNSET".to_string())));
        let second_req_last_id_srv = Arc::clone(&second_req_last_id);

        let srv = thread::spawn(move || {
            let (mut s1, _) = listener.accept().unwrap();
            let _ = read_http_req(&mut s1);
            write_sse_headers(&mut s1);
            write_sse_chunk(
                &mut s1,
                "id: 1\nevent: snapshot\ndata: {\"seq\":1,\"entries\":[],\"docs\":{}}\n\n",
            );
            let big_text = "x".repeat(400);
            for seq in 2..=4 {
                let frame = format!(
                    "id: {seq}\nevent: commit\ndata: {{\"seq\":{seq},\"prev_seq\":{},\"appended_entries\":[{{\"id\":\"{seq}\",\"kind\":\"assistant\",\"data\":{{\"text\":\"{big_text}\"}}}}],\"doc_ops\":{{}}}}\n\n",
                    seq - 1
                );
                write_sse_chunk(&mut s1, &frame);
            }
            let mut tmp = [0u8; 32];
            let _ = s1.read(&mut tmp);

            let (mut s2, _) = listener.accept().unwrap();
            let req2 = read_http_req(&mut s2);
            *second_req_last_id_srv.lock().unwrap() = extract_last_event_id(&req2);
            write_sse_headers(&mut s2);
            write_sse_chunk(
                &mut s2,
                "id: 4\nevent: snapshot\ndata: {\"seq\":4,\"entries\":[],\"docs\":{}}\n\n",
            );
            let _ = s2.read(&mut tmp);
        });

        let client = DaemonClient::new(
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            },
            SecretToken::new("tok-bytes-ovf").unwrap(),
        );

        let sub = Subscription::start_with_config(
            client,
            "s1".to_string(),
            "1".to_string(),
            None,
            StreamConfig {
                max_queue_len: 100,
                max_queue_bytes: 512,
                initial_backoff: Duration::from_millis(10),
                max_backoff: Duration::from_millis(20),
            },
        );

        let deadline = Instant::now() + Duration::from_secs(3);
        let mut saw_snapshot_4 = false;
        while Instant::now() < deadline {
            if let Some(Update::Frame(ServerFrame::Snapshot(s))) = sub.next() {
                if s.seq == 4 {
                    saw_snapshot_4 = true;
                    break;
                }
            }
            thread::sleep(Duration::from_millis(5));
        }

        assert!(
            saw_snapshot_4,
            "expected fresh snapshot seq=4 after byte-budget overflow"
        );
        assert_eq!(*second_req_last_id.lock().unwrap(), None);

        drop(sub);
        srv.join().unwrap();
    }
}
