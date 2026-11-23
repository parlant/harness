//! Live multi-session catalog subscription and tree-grouped Inbox browser state.
use super::markdown::{StyledRow, StyledSpan};
use super::theme::Theme;
use crate::client::{ClientError, DaemonClient, StreamCancel};
use crate::protocol::{CatalogEventKind, CatalogFrame, SessionSummary};
use crate::render::sanitize_single_line;
use ratatui::style::{Modifier, Style};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt;
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const CATALOG_QUEUE_CAP: usize = 64;
const INITIAL_BACKOFF: Duration = Duration::from_millis(50);
const MAX_BACKOFF: Duration = Duration::from_secs(5);
const HEALTHY_CONN_RESET_AGE: Duration = Duration::from_secs(2);
const FALLBACK_POLL_INTERVAL: Duration = Duration::from_secs(2);
const SPINNER_TICK: Duration = Duration::from_millis(100);

const UNICODE_SPINNER: &[char] = &['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
const ASCII_SPINNER: &[char] = &['|', '/', '-', '\\'];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CatalogUpdate {
    Online,
    Offline(String),
    Snapshot(Vec<SessionSummary>),
    Upsert(Box<SessionSummary>),
    Removed(String),
}

/// Cancellable, bounded, auto-reconnecting SSE subscription to `GET /api/v1/sessions/events`.
/// Falls back to periodic `GET /api/v1/sessions` snapshots when the endpoint returns HTTP 404.
pub struct CatalogSubscription {
    rx: Receiver<CatalogUpdate>,
    cancel: StreamCancel,
    worker: Option<JoinHandle<()>>,
}

impl fmt::Debug for CatalogSubscription {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CatalogSubscription")
            .field("cancelled", &self.cancel.is_cancelled())
            .finish()
    }
}

impl CatalogSubscription {
    pub fn start(client: DaemonClient) -> Self {
        Self::start_with_timing(client, INITIAL_BACKOFF, MAX_BACKOFF, FALLBACK_POLL_INTERVAL)
    }

    pub(crate) fn start_with_timing(
        client: DaemonClient,
        initial_backoff: Duration,
        max_backoff: Duration,
        fallback_poll: Duration,
    ) -> Self {
        let (tx, rx) = mpsc::sync_channel(CATALOG_QUEUE_CAP);
        let cancel = StreamCancel::new();
        let worker_cancel = cancel.clone();
        let worker = thread::spawn(move || {
            run_catalog_worker(
                client,
                tx,
                worker_cancel,
                initial_backoff,
                max_backoff,
                fallback_poll,
            );
        });
        Self {
            rx,
            cancel,
            worker: Some(worker),
        }
    }

    pub fn next(&self) -> Option<CatalogUpdate> {
        self.rx.try_recv().ok()
    }
}

impl Drop for CatalogSubscription {
    fn drop(&mut self) {
        self.cancel.cancel();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ConnState {
    Initial,
    Online,
    Offline,
}

fn send_update(
    tx: &SyncSender<CatalogUpdate>,
    cancel: &StreamCancel,
    update: CatalogUpdate,
) -> bool {
    let mut item = update;
    loop {
        if cancel.is_cancelled() {
            return false;
        }
        match tx.try_send(item) {
            Ok(()) => return true,
            Err(TrySendError::Full(returned)) => {
                item = returned;
                if !cancel.wait_timeout(Duration::from_millis(10)) {
                    return false;
                }
            }
            Err(TrySendError::Disconnected(_)) => return false,
        }
    }
}

fn run_catalog_worker(
    client: DaemonClient,
    tx: SyncSender<CatalogUpdate>,
    cancel: StreamCancel,
    initial_backoff: Duration,
    max_backoff: Duration,
    fallback_poll: Duration,
) {
    let mut conn_state = ConnState::Initial;
    let mut backoff = initial_backoff;

    while !cancel.is_cancelled() {
        let mut sse = match client.subscribe_sessions_cancellable(&cancel) {
            Ok(stream) => stream,
            Err(ClientError::HttpStatus { status: 404, .. }) => {
                // Graceful fallback for older/minimal daemon stubs without /api/v1/sessions/events.
                match client.list_sessions(None, None, None) {
                    Ok(sessions) => {
                        backoff = initial_backoff;
                        if conn_state != ConnState::Online {
                            if !send_update(&tx, &cancel, CatalogUpdate::Online) {
                                break;
                            }
                            conn_state = ConnState::Online;
                        }
                        if !send_update(&tx, &cancel, CatalogUpdate::Snapshot(sessions)) {
                            break;
                        }
                        if !cancel.wait_timeout(fallback_poll) {
                            break;
                        }
                    }
                    Err(err) => {
                        if cancel.is_cancelled() {
                            break;
                        }
                        if conn_state != ConnState::Offline {
                            let msg = sanitize_single_line(&err.to_string());
                            if !send_update(&tx, &cancel, CatalogUpdate::Offline(msg)) {
                                break;
                            }
                            conn_state = ConnState::Offline;
                        }
                        if !cancel.wait_timeout(backoff) {
                            break;
                        }
                        backoff = next_backoff(backoff, max_backoff);
                    }
                }
                continue;
            }
            Err(err) => {
                if cancel.is_cancelled() {
                    break;
                }
                if conn_state != ConnState::Offline {
                    let msg = sanitize_single_line(&err.to_string());
                    if !send_update(&tx, &cancel, CatalogUpdate::Offline(msg)) {
                        break;
                    }
                    conn_state = ConnState::Offline;
                }
                if !cancel.wait_timeout(backoff) {
                    break;
                }
                backoff = next_backoff(backoff, max_backoff);
                continue;
            }
        };

        let connected_at = Instant::now();
        let mut saw_frame = false;
        let mut last_seq: Option<u64> = None;

        if conn_state != ConnState::Online {
            if !send_update(&tx, &cancel, CatalogUpdate::Online) {
                drop(sse);
                cancel.clear_active();
                break;
            }
            conn_state = ConnState::Online;
        }

        let disconnect_reason: Option<String> = loop {
            if cancel.is_cancelled() {
                break None;
            }
            match sse.next_event() {
                Ok(Some(ev)) => match ev.decode_catalog_frame() {
                    Ok(CatalogFrame::Snapshot(snap)) => {
                        saw_frame = true;
                        backoff = initial_backoff;
                        last_seq = Some(snap.seq);
                        if !send_update(&tx, &cancel, CatalogUpdate::Snapshot(snap.sessions)) {
                            break None;
                        }
                    }
                    Ok(CatalogFrame::Event(frame)) => {
                        saw_frame = true;
                        backoff = initial_backoff;
                        if last_seq.is_some_and(|prev| frame.seq <= prev) {
                            continue;
                        }
                        last_seq = Some(frame.seq);
                        let update = match frame.kind {
                            CatalogEventKind::Upsert { session } => CatalogUpdate::Upsert(session),
                            CatalogEventKind::Removed { session_id } => {
                                CatalogUpdate::Removed(session_id)
                            }
                        };
                        if !send_update(&tx, &cancel, update) {
                            break None;
                        }
                    }
                    Ok(CatalogFrame::Unknown { .. }) => {}
                    Err(err) => break Some(sanitize_single_line(&err.to_string())),
                },
                Ok(None) => break Some("catalog stream closed".to_string()),
                Err(err) => break Some(sanitize_single_line(&err.to_string())),
            }
        };

        drop(sse);
        cancel.clear_active();

        if cancel.is_cancelled() {
            break;
        }

        if saw_frame || connected_at.elapsed() >= HEALTHY_CONN_RESET_AGE {
            backoff = initial_backoff;
        }

        if let Some(reason) = disconnect_reason {
            if conn_state != ConnState::Offline {
                if !send_update(&tx, &cancel, CatalogUpdate::Offline(reason)) {
                    break;
                }
                conn_state = ConnState::Offline;
            }
        }

        if !cancel.wait_timeout(backoff) {
            break;
        }
        backoff = next_backoff(backoff, max_backoff);
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum InboxFilter {
    #[default]
    Inbox,
    All,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InboxRendered {
    pub rows: Vec<StyledRow>,
    pub selected_row: Option<usize>,
}

#[derive(Debug, Clone)]
pub struct InboxRowItem<'a> {
    pub session: &'a SessionSummary,
    pub depth: usize,
    pub is_last: bool,
    pub parent_cwd: Option<&'a str>,
    pub orphan_parent_sid: Option<&'a str>,
}

/// Pure view model for the multi-session Inbox browser.
#[derive(Debug)]
pub struct InboxState {
    sessions: HashMap<String, SessionSummary>,
    filter: InboxFilter,
    selected_id: Option<String>,
    launch_env_id: String,
    launch_cwd: String,
    home_dir: Option<String>,
    show_subsessions: bool,
    pub online: bool,
    pub loaded: bool,
    spinner_frame: usize,
    last_tick: Instant,
}

impl InboxState {
    pub fn new(launch_env_id: String, launch_cwd: String, preselect_sid: Option<String>) -> Self {
        Self::with_home(
            launch_env_id,
            launch_cwd,
            preselect_sid,
            std::env::var("HOME").ok().filter(|h| !h.is_empty()),
        )
    }

    pub(crate) fn with_home(
        launch_env_id: String,
        launch_cwd: String,
        preselect_sid: Option<String>,
        home_dir: Option<String>,
    ) -> Self {
        Self {
            sessions: HashMap::new(),
            filter: InboxFilter::Inbox,
            selected_id: preselect_sid,
            launch_env_id,
            launch_cwd,
            home_dir,
            show_subsessions: false,
            online: false,
            loaded: false,
            spinner_frame: 0,
            last_tick: Instant::now(),
        }
    }

    pub fn set_show_subsessions(&mut self, enabled: bool) {
        self.show_subsessions = enabled;
        self.reconcile_selection();
    }

    pub fn toggle_subsessions(&mut self) -> bool {
        self.show_subsessions = !self.show_subsessions;
        self.reconcile_selection();
        self.show_subsessions
    }

    pub fn show_subsessions(&self) -> bool {
        self.show_subsessions
    }

    pub fn subsession_count(&self) -> usize {
        self.sessions.values().filter(|s| s.is_subsession()).count()
    }

    pub fn filter(&self) -> InboxFilter {
        self.filter
    }

    pub fn toggle_filter(&mut self) -> InboxFilter {
        self.filter = match self.filter {
            InboxFilter::Inbox => InboxFilter::All,
            InboxFilter::All => InboxFilter::Inbox,
        };
        self.reconcile_selection();
        self.filter
    }

    pub fn apply(&mut self, update: CatalogUpdate) -> Option<String> {
        match update {
            CatalogUpdate::Online => {
                self.online = true;
                None
            }
            CatalogUpdate::Offline(msg) => {
                self.online = false;
                Some(msg)
            }
            CatalogUpdate::Snapshot(list) => {
                let mut next = HashMap::with_capacity(list.len());
                for session in list {
                    next.insert(session.session_id.clone(), session);
                }
                self.sessions = next;
                self.loaded = true;
                self.reconcile_selection();
                None
            }
            CatalogUpdate::Upsert(session) => {
                let session = *session;
                self.sessions.insert(session.session_id.clone(), session);
                self.loaded = true;
                self.reconcile_selection();
                None
            }
            CatalogUpdate::Removed(session_id) => {
                self.sessions.remove(&session_id);
                self.reconcile_selection();
                None
            }
        }
    }

    pub fn has_processing_sessions(&self) -> bool {
        self.sessions
            .values()
            .any(|s| self.is_visible(s) && s.effective_attention() == "running")
    }

    /// Advances the spinner animation when any session is running.
    /// Returns `true` if a repaint is needed.
    pub fn tick_spinner(&mut self, now: Instant) -> bool {
        if !self.has_processing_sessions() {
            return false;
        }
        if now.duration_since(self.last_tick) >= SPINNER_TICK {
            self.spinner_frame = self.spinner_frame.wrapping_add(1);
            self.last_tick = now;
            return true;
        }
        false
    }

    pub fn spinner_char(&self, plain: bool) -> char {
        if plain {
            ASCII_SPINNER[self.spinner_frame % ASCII_SPINNER.len()]
        } else {
            UNICODE_SPINNER[self.spinner_frame % UNICODE_SPINNER.len()]
        }
    }

    pub fn selected_session(&self) -> Option<&SessionSummary> {
        let sid = self.selected_id.as_deref()?;
        self.sessions.get(sid).filter(|s| self.is_visible(s))
    }

    pub fn selected_id(&self) -> Option<&str> {
        self.selected_id.as_deref()
    }

    fn is_visible(&self, session: &SessionSummary) -> bool {
        if session.is_subsession() && !self.show_subsessions {
            return false;
        }
        match self.filter {
            InboxFilter::All => true,
            InboxFilter::Inbox => {
                if session.is_subsession() {
                    !session.effective_archived()
                } else {
                    !session.effective_archived()
                        && (session.effective_loaded()
                            || session.effective_needs_attention()
                            || matches!(
                                session.effective_attention(),
                                "running" | "sleeping" | "retrying" | "quarantined"
                            ))
                }
            }
        }
    }

    pub fn new_session_workspace(&self) -> (String, String, bool) {
        if let Some(s) = self.selected_session() {
            (
                s.env_id
                    .clone()
                    .filter(|e| !e.trim().is_empty())
                    .unwrap_or_else(|| "host".to_string()),
                s.cwd.clone(),
                s.effective_cwd_exists(),
            )
        } else {
            (self.launch_env_id.clone(), self.launch_cwd.clone(), true)
        }
    }

    /// Returns groups sorted deterministically:
    /// 1. Launch workspace first (if present), then lexicographically by `(env_id, cwd)`.
    /// 2. Root sessions within each group sorted by triage tier (0..=4), then `(created_at asc, session_id asc)`.
    /// 3. When `show_subsessions` is `false`, subsessions are excluded. When `true`, child
    ///    subsessions are nested directly beneath their parent inside the parent's workspace group
    ///    (even across different cwds), and orphan subsessions fall back to their own workspace group.
    pub fn grouped_sessions(&self) -> Vec<((String, String), Vec<&SessionSummary>)> {
        self.grouped_rows()
            .into_iter()
            .map(|(k, rows)| (k, rows.into_iter().map(|r| r.session).collect()))
            .collect()
    }

    pub fn grouped_rows(&self) -> Vec<((String, String), Vec<InboxRowItem<'_>>)> {
        let mut by_root: BTreeMap<(String, String), Vec<&SessionSummary>> = BTreeMap::new();
        let mut children_by_parent: HashMap<&str, Vec<&SessionSummary>> = HashMap::new();

        for session in self.sessions.values().filter(|s| self.is_visible(s)) {
            if let Some(parent) = session.parent.as_ref() {
                let parent_visible = self
                    .sessions
                    .get(parent.session_id.as_str())
                    .is_some_and(|p| self.is_visible(p));
                if parent_visible && parent.session_id != session.session_id {
                    children_by_parent
                        .entry(parent.session_id.as_str())
                        .or_default()
                        .push(session);
                } else {
                    let env_id = session_env_id(session);
                    by_root
                        .entry((env_id, session.cwd.clone()))
                        .or_default()
                        .push(session);
                }
            } else {
                let env_id = session_env_id(session);
                by_root
                    .entry((env_id, session.cwd.clone()))
                    .or_default()
                    .push(session);
            }
        }

        for list in children_by_parent.values_mut() {
            sort_sessions_deterministically(list);
        }

        let mut raw_groups: Vec<((String, String), Vec<&SessionSummary>)> =
            by_root.into_iter().collect();
        let launch_key = (self.launch_env_id.clone(), self.launch_cwd.clone());
        raw_groups.sort_by(|(ka, _), (kb, _)| {
            let a_launch = ka == &launch_key;
            let b_launch = kb == &launch_key;
            b_launch.cmp(&a_launch).then_with(|| ka.cmp(kb))
        });

        let mut out = Vec::with_capacity(raw_groups.len());
        for (key, mut roots) in raw_groups {
            roots.sort_by(|a, b| {
                triage_tier(a)
                    .cmp(&triage_tier(b))
                    .then_with(|| a.created_at.unwrap_or(0).cmp(&b.created_at.unwrap_or(0)))
                    .then_with(|| a.session_id.cmp(&b.session_id))
            });
            let mut rows = Vec::new();
            let root_count = roots.len();
            let mut visited = HashSet::new();
            for (idx, root) in roots.into_iter().enumerate() {
                let is_last = idx + 1 == root_count;
                let orphan_parent_sid = root.parent.as_ref().map(|p| p.session_id.as_str());
                rows.push(InboxRowItem {
                    session: root,
                    depth: 0,
                    is_last,
                    parent_cwd: None,
                    orphan_parent_sid,
                });
                visited.insert(root.session_id.as_str());
                if self.show_subsessions {
                    append_children(&mut rows, root, 1, &children_by_parent, &mut visited);
                }
            }
            out.push((key, rows));
        }

        out
    }

    pub fn ordered_session_ids(&self) -> Vec<String> {
        self.grouped_rows()
            .into_iter()
            .flat_map(|(_, list)| list.into_iter().map(|r| r.session.session_id.clone()))
            .collect()
    }

    fn reconcile_selection(&mut self) {
        let ordered = self.ordered_session_ids();
        if self
            .selected_id
            .as_deref()
            .is_some_and(|sid| ordered.iter().any(|id| id == sid))
        {
            return;
        }
        self.selected_id = ordered
            .iter()
            .find(|sid| {
                self.sessions
                    .get(sid.as_str())
                    .is_some_and(session_needs_user_attention)
            })
            .cloned()
            .or_else(|| ordered.into_iter().next());
    }

    pub fn move_selection(&mut self, delta: isize) {
        let ordered = self.ordered_session_ids();
        if ordered.is_empty() {
            self.selected_id = None;
            return;
        }
        let current = self
            .selected_id
            .as_deref()
            .and_then(|sid| ordered.iter().position(|id| id == sid));
        let len = ordered.len() as isize;
        let next_idx = match current {
            Some(idx) => (idx as isize + delta).rem_euclid(len) as usize,
            None if delta >= 0 => 0,
            None => ordered.len() - 1,
        };
        self.selected_id = Some(ordered[next_idx].clone());
    }

    /// Cycles selection across visible root sessions needing user attention
    /// (`!is_subsession() && !effective_archived() && effective_needs_attention() && !is_processing_attention`).
    pub fn cycle_attention(&mut self, forward: bool) -> bool {
        let ordered = self.ordered_session_ids();
        let candidates: Vec<(usize, &String)> = ordered
            .iter()
            .enumerate()
            .filter(|(_, sid)| {
                self.sessions
                    .get(sid.as_str())
                    .is_some_and(session_needs_user_attention)
            })
            .collect();
        if candidates.is_empty() {
            return false;
        }

        let current_pos = self
            .selected_id
            .as_deref()
            .and_then(|sid| ordered.iter().position(|id| id == sid));

        let next_sid = match current_pos {
            None => {
                if forward {
                    candidates[0].1
                } else {
                    candidates[candidates.len() - 1].1
                }
            }
            Some(pos) => {
                if forward {
                    candidates
                        .iter()
                        .find(|(idx, _)| *idx > pos)
                        .unwrap_or(&candidates[0])
                        .1
                } else {
                    candidates
                        .iter()
                        .rev()
                        .find(|(idx, _)| *idx < pos)
                        .unwrap_or(&candidates[candidates.len() - 1])
                        .1
                }
            }
        };
        self.selected_id = Some(next_sid.clone());
        true
    }

    pub fn counts(&self) -> (usize, usize, usize, usize, usize) {
        let mut total = 0usize;
        let mut attention_count = 0usize;
        let mut errors = 0usize;
        let mut running = 0usize;
        let mut archived = 0usize;
        for session in self
            .sessions
            .values()
            .filter(|s| !s.is_subsession() && self.is_visible(s))
        {
            total += 1;
            if session.effective_archived() {
                archived += 1;
            } else if is_processing_attention(session.effective_attention()) {
                running += 1;
            } else if session.effective_needs_attention() {
                if matches!(session.effective_attention(), "error" | "quarantined") {
                    errors += 1;
                } else {
                    attention_count += 1;
                }
            }
        }
        (total, errors, attention_count, running, archived)
    }

    pub fn render(&self, theme: &Theme) -> InboxRendered {
        let mut rows = Vec::new();
        let mut selected_row = None;

        let (total, errors, attention_count, running, archived) = self.counts();
        let sub_count = self.subsession_count();
        let title = match self.filter {
            InboxFilter::Inbox => "Inbox",
            InboxFilter::All => "Inbox [All]",
        };
        let mut header_spans = vec![StyledSpan::new(title, theme.inbox_dir)];
        let mut summary = if !self.loaded {
            "  loading sessions…".to_string()
        } else if total == 0 {
            match self.filter {
                InboxFilter::Inbox => "  no active sessions (press a for all)".to_string(),
                InboxFilter::All => "  no sessions".to_string(),
            }
        } else {
            let mut parts = Vec::new();
            if errors > 0 {
                parts.push(format!("{errors} error"));
            }
            if attention_count > 0 {
                parts.push(format!("{attention_count} attention"));
            }
            if running > 0 {
                parts.push(format!("{running} processing"));
            }
            if archived > 0 {
                parts.push(format!("{archived} archived"));
            }
            if parts.is_empty() {
                format!("  {total} sessions")
            } else {
                format!("  {total} sessions ({})", parts.join(" · "))
            }
        };
        if self.loaded && sub_count > 0 {
            let noun = if sub_count == 1 {
                "subsession"
            } else {
                "subsessions"
            };
            let state = if self.show_subsessions {
                "shown"
            } else {
                "hidden"
            };
            summary.push_str(&format!(" · {sub_count} {noun} ({state})"));
        }
        header_spans.push(StyledSpan::new(summary, theme.tool_meta));
        rows.push(StyledRow::from_spans(header_spans));
        rows.push(StyledRow::plain(String::new(), Style::default()));

        let groups = self.grouped_rows();
        if groups.is_empty() {
            let msg = if self.loaded {
                if sub_count > 0 && !self.show_subsessions {
                    "No root sessions yet. Press t to show subsessions or n to start a new session."
                } else {
                    match self.filter {
                        InboxFilter::Inbox => {
                            "No active sessions. Press a to show all sessions or n to start a new one."
                        }
                        InboxFilter::All => {
                            "No sessions yet. Press n to start a new session in this workspace."
                        }
                    }
                }
            } else {
                "Connecting to daemon catalog…"
            };
            rows.push(StyledRow::plain(format!("  {msg}"), theme.tool_meta));
            return InboxRendered { rows, selected_row };
        }

        for (group_idx, ((env_id, cwd), list)) in groups.into_iter().enumerate() {
            if group_idx > 0 {
                rows.push(StyledRow::plain(String::new(), Style::default()));
            }
            let dir_label = format_workspace_root(&env_id, &cwd, self.home_dir.as_deref());
            rows.push(StyledRow::from_spans(vec![
                StyledSpan::new("  ", Style::default()),
                StyledSpan::new(sanitize_single_line(&dir_label), theme.inbox_dir),
            ]));

            for item in list {
                let is_selected =
                    self.selected_id.as_deref() == Some(item.session.session_id.as_str());
                if is_selected {
                    selected_row = Some(rows.len());
                }
                rows.push(self.render_session_row(&item, is_selected, theme));
            }
        }

        InboxRendered { rows, selected_row }
    }

    fn render_session_row(
        &self,
        item: &InboxRowItem<'_>,
        is_selected: bool,
        theme: &Theme,
    ) -> StyledRow {
        let session = item.session;
        let tier = triage_tier(session);
        let attention = session.effective_attention();
        let processing = tier == 2;
        let dimmed = matches!(tier, 2..=4);

        let cursor_prefix = if is_selected { "> " } else { "  " };
        let connector = if item.depth == 0 {
            if item.is_last {
                "└─ ".to_string()
            } else {
                "├─ ".to_string()
            }
        } else {
            let indent = "   ".repeat(item.depth);
            let branch = if item.is_last { "└─ " } else { "├─ " };
            let arrow = if theme.is_plain { "> " } else { "↳ " };
            format!("{indent}{branch}{arrow}")
        };

        let (glyph, glyph_style) = match tier {
            0 => ("!".to_string(), theme.tool_error),
            1 => (
                if theme.is_plain { "*" } else { "●" }.to_string(),
                theme.inbox_idle_new,
            ),
            2 => match attention {
                "retrying" => (
                    if theme.is_plain { "~" } else { "↻" }.to_string(),
                    theme.inbox_processing,
                ),
                "sleeping" => (
                    if theme.is_plain { "~" } else { "◷" }.to_string(),
                    theme.inbox_processing,
                ),
                _ => (
                    self.spinner_char(theme.is_plain).to_string(),
                    theme.inbox_processing,
                ),
            },
            3 => (
                if theme.is_plain { "o" } else { "○" }.to_string(),
                theme.inbox_processing,
            ),
            _ => (
                if theme.is_plain { "-" } else { "·" }.to_string(),
                theme.inbox_processing,
            ),
        };

        let title = session
            .title
            .as_deref()
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .map(sanitize_single_line);
        let sid_clean = sanitize_single_line(&session.session_id);
        let display_name = match title {
            Some(t) if t != sid_clean => format!("{t} ({sid_clean})"),
            Some(t) => t,
            None => sid_clean,
        };

        let detail = format_attention_detail(session, attention);

        let base_sel = if is_selected {
            theme.inbox_selected
        } else {
            Style::default()
        };

        let tree_style = if is_selected {
            base_sel
        } else if dimmed {
            theme.inbox_processing
        } else {
            theme.tool_meta
        };

        let title_style = match tier {
            0 => {
                if is_selected {
                    base_sel.patch(theme.tool_error)
                } else {
                    theme.tool_error
                }
            }
            1 => {
                if is_selected {
                    base_sel.add_modifier(Modifier::BOLD)
                } else {
                    theme.inbox_idle_new
                }
            }
            2..=4 => {
                if is_selected {
                    base_sel.add_modifier(Modifier::DIM)
                } else {
                    theme.inbox_processing
                }
            }
            _ => theme.inbox_idle,
        };

        let detail_style = match tier {
            0 => {
                if is_selected {
                    base_sel.patch(theme.failure_text)
                } else {
                    theme.failure_text
                }
            }
            2..=4 => {
                if is_selected {
                    base_sel.add_modifier(Modifier::DIM)
                } else {
                    theme.inbox_processing
                }
            }
            _ => {
                if is_selected {
                    base_sel
                } else {
                    theme.tool_meta
                }
            }
        };

        let meta_style = if is_selected {
            base_sel
        } else {
            theme.tool_meta
        };

        let indicator_style = if is_selected {
            base_sel.patch(glyph_style)
        } else {
            glyph_style
        };

        let mut spans = vec![
            StyledSpan::new(cursor_prefix, tree_style),
            StyledSpan::new(connector, tree_style),
            StyledSpan::new(glyph, indicator_style),
            StyledSpan::new(" ", base_sel),
            StyledSpan::new(display_name, title_style),
        ];

        if let Some(orphan_parent) = item.orphan_parent_sid {
            let arrow = if theme.is_plain { "-> " } else { "↳ " };
            spans.push(StyledSpan::new(
                format!("  [{arrow}{}]", sanitize_single_line(orphan_parent)),
                meta_style,
            ));
        }

        if let Some(at_entry) = session
            .parent
            .as_ref()
            .and_then(|p| p.at_entry_id.as_deref())
            .filter(|e| !e.trim().is_empty())
        {
            spans.push(StyledSpan::new(
                format!("  @#{}", sanitize_single_line(at_entry)),
                meta_style,
            ));
        }

        if let Some(parent_cwd) = item.parent_cwd {
            if session.cwd != parent_cwd {
                let env_id = session_env_id(session);
                let short_cwd =
                    format_workspace_root(&env_id, &session.cwd, self.home_dir.as_deref());
                spans.push(StyledSpan::new(
                    format!("  [cwd: {}]", sanitize_single_line(&short_cwd)),
                    meta_style,
                ));
            }
        }

        if !detail.is_empty() {
            spans.push(StyledSpan::new(format!("  {detail}"), detail_style));
        }

        if !session.effective_cwd_exists() && session.status.as_deref() != Some("archived") {
            let missing_style = if is_selected {
                base_sel.patch(theme.tool_error)
            } else {
                theme.tool_error
            };
            spans.push(StyledSpan::new("  [missing cwd]", missing_style));
        }

        if session.queued_count > 0 {
            let q_style = if is_selected {
                base_sel.patch(theme.queued_header)
            } else if processing {
                theme.inbox_processing
            } else {
                theme.queued_header
            };
            spans.push(StyledSpan::new(
                format!("  [+{} queued]", session.queued_count),
                q_style,
            ));
        }

        let mut row = StyledRow::from_spans(spans);
        if is_selected && !theme.is_plain && theme.inbox_selected != Style::default() {
            row = row.with_fill(theme.inbox_selected);
        }
        row
    }

    pub fn status_line(&self, note: &str) -> String {
        let conn = if self.online { "online" } else { "offline" };
        let mode = match self.filter {
            InboxFilter::Inbox => "Inbox",
            InboxFilter::All => "Inbox [All]",
        };
        let mut line = format!(
            "{mode} · j/k move · Tab next · Space attention · s stop · x archive · a all · t subsessions · Enter open · q quit"
        );
        if !note.trim().is_empty() {
            line.push_str(" · ");
            line.push_str(&sanitize_single_line(note));
        }
        line.push_str(" · ");
        line.push_str(conn);
        line
    }
}

fn session_env_id(session: &SessionSummary) -> String {
    session
        .env_id
        .as_deref()
        .filter(|e| !e.trim().is_empty())
        .unwrap_or("host")
        .to_string()
}

fn sort_sessions_deterministically(list: &mut [&SessionSummary]) {
    list.sort_by(|a, b| {
        a.created_at
            .unwrap_or(0)
            .cmp(&b.created_at.unwrap_or(0))
            .then_with(|| a.session_id.cmp(&b.session_id))
    });
}

fn append_children<'a>(
    rows: &mut Vec<InboxRowItem<'a>>,
    parent: &'a SessionSummary,
    depth: usize,
    children_by_parent: &HashMap<&'a str, Vec<&'a SessionSummary>>,
    visited: &mut HashSet<&'a str>,
) {
    let Some(children) = children_by_parent.get(parent.session_id.as_str()) else {
        return;
    };
    let unvisited: Vec<&'a SessionSummary> = children
        .iter()
        .copied()
        .filter(|c| !visited.contains(c.session_id.as_str()))
        .collect();
    let child_count = unvisited.len();
    for (idx, child) in unvisited.into_iter().enumerate() {
        if !visited.insert(child.session_id.as_str()) {
            continue;
        }
        rows.push(InboxRowItem {
            session: child,
            depth,
            is_last: idx + 1 == child_count,
            parent_cwd: Some(parent.cwd.as_str()),
            orphan_parent_sid: None,
        });
        append_children(rows, child, depth + 1, children_by_parent, visited);
    }
}

pub fn triage_tier(session: &SessionSummary) -> u8 {
    if session.effective_archived() {
        return 4;
    }
    let attention = session.effective_attention();
    if is_processing_attention(attention) {
        return 2;
    }
    if session.is_subsession() {
        if matches!(attention, "error" | "quarantined") {
            0
        } else {
            3
        }
    } else if session.effective_needs_attention() {
        if matches!(attention, "error" | "quarantined") {
            0
        } else {
            1
        }
    } else {
        3
    }
}

pub fn session_needs_user_attention(session: &SessionSummary) -> bool {
    !session.is_subsession()
        && !session.effective_archived()
        && session.effective_needs_attention()
        && !is_processing_attention(session.effective_attention())
}

pub fn is_processing_attention(attention: &str) -> bool {
    matches!(attention, "running" | "sleeping" | "retrying")
}

fn format_attention_detail(session: &SessionSummary, attention: &str) -> String {
    if session.effective_archived() {
        return "archived".to_string();
    }
    let label = session
        .activity_label
        .as_deref()
        .map(sanitize_single_line)
        .filter(|s| !s.is_empty());
    let kind = session
        .activity_kind
        .as_deref()
        .map(sanitize_single_line)
        .filter(|s| !s.is_empty());

    match attention {
        "quarantined" => match label {
            Some(l) => format!("quarantined: {l}"),
            None => "quarantined".to_string(),
        },
        "error" => match label {
            Some(l) => format!("paused: {l}"),
            None => "paused: error".to_string(),
        },
        "running" => match (label, kind) {
            (Some(l), _) => l,
            (None, Some(k)) => match k.as_str() {
                "generation" => "generating".to_string(),
                "user_shell" => "shell".to_string(),
                "compaction" => "compact".to_string(),
                other => other.to_string(),
            },
            (None, None) => "running".to_string(),
        },
        "sleeping" | "retrying" => label.unwrap_or_else(|| "retrying".to_string()),
        "archived" => "archived".to_string(),
        _ => "idle".to_string(),
    }
}

pub fn format_workspace_root(env_id: &str, cwd: &str, home_dir: Option<&str>) -> String {
    if env_id != "host" {
        return format!("{env_id}:{cwd}");
    }
    if let Some(home) = home_dir.filter(|h| !h.is_empty() && *h != "/") {
        let home_trimmed = home.trim_end_matches('/');
        if cwd == home_trimmed {
            return "~".to_string();
        }
        if let Some(rest) = cwd.strip_prefix(home_trimmed) {
            if rest.starts_with('/') {
                return format!("~{rest}");
            }
        }
    }
    cwd.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{DaemonTarget, SecretToken};
    use std::io::{Read, Write};
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[allow(clippy::too_many_arguments)]
    fn make_session(
        id: &str,
        cwd: &str,
        env_id: &str,
        title: Option<&str>,
        attention: &str,
        activity_kind: Option<&str>,
        activity_label: Option<&str>,
        created_at: i64,
    ) -> SessionSummary {
        SessionSummary {
            session_id: id.to_string(),
            title: title.map(str::to_string),
            env_id: Some(env_id.to_string()),
            harness_id: Some("coding".to_string()),
            cwd: cwd.to_string(),
            root_conversation_id: Some("1".to_string()),
            created_at: Some(created_at),
            updated_at: Some(created_at),
            active: matches!(attention, "running" | "sleeping" | "retrying"),
            attention: Some(attention.to_string()),
            activity_kind: activity_kind.map(str::to_string),
            activity_label: activity_label.map(str::to_string),
            queued_count: 0,
            next_wake_at: None,
            status: Some(
                if attention == "quarantined" {
                    "quarantined"
                } else if attention == "archived" {
                    "archived"
                } else {
                    "ok"
                }
                .to_string(),
            ),
            parent: None,
            role: None,
            needs_attention: None,
            archived: attention == "archived",
            loaded: Some(attention != "archived"),
            cwd_exists: Some(true),
        }
    }

    #[test]
    fn format_workspace_root_shortens_home_and_prefixes_non_host_envs() {
        assert_eq!(
            format_workspace_root("host", "/Users/alice/Projects/h", Some("/Users/alice")),
            "~/Projects/h"
        );
        assert_eq!(
            format_workspace_root("host", "/Users/alice", Some("/Users/alice")),
            "~"
        );
        assert_eq!(
            format_workspace_root("host", "/Users/alice2/foo", Some("/Users/alice")),
            "/Users/alice2/foo"
        );
        assert_eq!(
            format_workspace_root("docker-dev", "/workspace/app", Some("/Users/alice")),
            "docker-dev:/workspace/app"
        );
    }

    #[test]
    fn tree_groups_by_workspace_and_anchors_selection_across_live_upserts() {
        let mut inbox = InboxState::with_home(
            "host".into(),
            "/Users/alice/proj-a".into(),
            None,
            Some("/Users/alice".into()),
        );
        inbox.apply(CatalogUpdate::Online);
        inbox.apply(CatalogUpdate::Snapshot(vec![
            make_session(
                "s-run",
                "/Users/alice/proj-a",
                "host",
                Some("Running Task"),
                "running",
                Some("tool"),
                Some("bash"),
                10,
            ),
            make_session(
                "s-idle",
                "/Users/alice/proj-a",
                "host",
                Some("Ready Task"),
                "idle",
                None,
                None,
                20,
            ),
            make_session(
                "s-err",
                "/Users/alice/proj-b",
                "host",
                Some("Broken Task"),
                "error",
                None,
                Some("model_error"),
                15,
            ),
        ]));

        // Initial auto-selection picks first attention-needing session ("s-idle")
        assert_eq!(inbox.selected_id(), Some("s-idle"));

        // Live upsert that updates s-run's updated_at does not shift selection away from s-idle
        let mut updated_run = make_session(
            "s-run",
            "/Users/alice/proj-a",
            "host",
            Some("Running Task"),
            "running",
            Some("generation"),
            None,
            10,
        );
        updated_run.updated_at = Some(999);
        inbox.apply(CatalogUpdate::Upsert(Box::new(updated_run)));
        assert_eq!(inbox.selected_id(), Some("s-idle"));

        // Render checks directory headers, connectors, indicators, and attention styling
        let theme = Theme::dark();
        let rendered = inbox.render(&theme);
        let texts: Vec<String> = rendered.rows.iter().map(StyledRow::plain_text).collect();
        let joined = texts.join("\n");
        assert!(joined.contains("~/proj-a"), "{joined}");
        assert!(joined.contains("~/proj-b"), "{joined}");
        assert!(joined.contains("├─ "), "{joined}");
        assert!(joined.contains("└─ "), "{joined}");
        assert!(
            joined.contains("! Broken Task (s-err)  paused: model_error"),
            "{joined}"
        );
        assert!(joined.contains("● Ready Task (s-idle)  idle"), "{joined}");
        assert!(
            joined.contains("⠋ Running Task (s-run)  generating"),
            "{joined}"
        );

        // Processing row uses dimmed style, while error uses tool_error
        let run_row = rendered
            .rows
            .iter()
            .find(|r| r.plain_text().contains("Running Task"))
            .unwrap();
        assert!(run_row.spans.iter().any(
            |s| s.text.contains("Running Task") && s.style.add_modifier.contains(Modifier::DIM)
        ));
    }

    #[test]
    fn retrying_is_processing_not_operator_attention() {
        let session = make_session(
            "retry",
            "/tmp/a",
            "host",
            None,
            "retrying",
            Some("retry"),
            Some("Retry 1/3 · http_429 · waiting 2s"),
            1,
        );
        assert_eq!(session.effective_attention(), "retrying");
        assert!(is_processing_attention(session.effective_attention()));
        assert!(!session.effective_needs_attention());
        assert!(format_attention_detail(&session, "retrying").contains("http_429"));
    }

    #[test]
    fn tab_cycles_only_attention_sessions_and_j_k_navigate_all() {
        let mut inbox = InboxState::with_home("host".into(), "/work/a".into(), None, None);
        inbox.apply(CatalogUpdate::Snapshot(vec![
            make_session(
                "s1",
                "/work/a",
                "host",
                Some("One"),
                "running",
                Some("tool"),
                Some("bash"),
                1,
            ),
            make_session("s2", "/work/a", "host", Some("Two"), "idle", None, None, 2),
            make_session(
                "s3",
                "/work/a",
                "host",
                Some("Three"),
                "sleeping",
                Some("retry"),
                Some("retrying"),
                3,
            ),
            make_session(
                "s4",
                "/work/b",
                "host",
                Some("Four"),
                "error",
                None,
                Some("rate_limit"),
                4,
            ),
            make_session("s5", "/work/b", "host", Some("Five"), "idle", None, None, 5),
        ]));

        // Ordered IDs by triage tier within each group:
        // /work/a: s2(tier 1 idle), s1(tier 2 running), s3(tier 2 sleeping)
        // /work/b: s4(tier 0 error), s5(tier 1 idle)
        assert_eq!(
            inbox.ordered_session_ids(),
            vec!["s2", "s1", "s3", "s4", "s5"]
        );
        assert_eq!(inbox.selected_id(), Some("s2"));

        // Tab skips s1 (running) and s3 (sleeping)
        assert!(inbox.cycle_attention(true));
        assert_eq!(inbox.selected_id(), Some("s4"));
        assert!(inbox.cycle_attention(true));
        assert_eq!(inbox.selected_id(), Some("s5"));
        assert!(inbox.cycle_attention(true));
        assert_eq!(inbox.selected_id(), Some("s2"));

        // Shift+Tab cycles backwards
        assert!(inbox.cycle_attention(false));
        assert_eq!(inbox.selected_id(), Some("s5"));

        // j / k move across ALL sessions including running/sleeping and wrap around
        inbox.move_selection(1);
        assert_eq!(inbox.selected_id(), Some("s2"));
        inbox.move_selection(1);
        assert_eq!(inbox.selected_id(), Some("s1"));
        inbox.move_selection(-2);
        assert_eq!(inbox.selected_id(), Some("s5"));
    }

    #[test]
    fn triage_tiers_ordering_explicit_needs_attention_and_inbox_vs_all_filter() {
        let mut inbox = InboxState::with_home("host".into(), "/work".into(), None, None);

        let mut s_dismissed = make_session(
            "s-dismiss",
            "/work",
            "host",
            Some("Dismissed"),
            "idle",
            None,
            None,
            1,
        );
        s_dismissed.needs_attention = Some(false);
        s_dismissed.loaded = Some(true);

        let mut s_cold_dismissed = make_session(
            "s-cold",
            "/work",
            "host",
            Some("Cold"),
            "idle",
            None,
            None,
            2,
        );
        s_cold_dismissed.needs_attention = Some(false);
        s_cold_dismissed.loaded = Some(false);

        let mut s_cold_attn = make_session(
            "s-cold-attn",
            "/work",
            "host",
            Some("Unloaded Attn"),
            "idle",
            None,
            None,
            3,
        );
        s_cold_attn.needs_attention = Some(true);
        s_cold_attn.loaded = Some(false);

        let s_run = make_session(
            "s-run",
            "/work",
            "host",
            Some("Running"),
            "running",
            Some("generation"),
            None,
            4,
        );

        let mut s_err = make_session(
            "s-err",
            "/work",
            "host",
            Some("Errored"),
            "error",
            None,
            Some("boom"),
            5,
        );
        s_err.needs_attention = Some(true);
        s_err.cwd_exists = Some(false);

        let mut s_arch = make_session(
            "s-arch",
            "/work",
            "host",
            Some("Archived"),
            "idle",
            None,
            None,
            6,
        );
        s_arch.archived = true;
        s_arch.needs_attention = Some(false);
        s_arch.loaded = Some(false);

        let s_imported = make_session(
            "s-imp",
            "/work",
            "host",
            Some("Imported"),
            "archived",
            None,
            None,
            7,
        );

        inbox.apply(CatalogUpdate::Snapshot(vec![
            s_dismissed.clone(),
            s_cold_dismissed,
            s_cold_attn,
            s_run,
            s_err,
            s_arch,
            s_imported,
        ]));

        // Default Inbox filter hides s-cold (unloaded + !needs_attention), s-arch, and s-imp,
        // while keeping s-cold-attn (unloaded + needs_attention) and ordering by Tier 0..3.
        assert_eq!(
            inbox.ordered_session_ids(),
            vec!["s-err", "s-cold-attn", "s-run", "s-dismiss"]
        );

        let rendered_inbox = inbox.render(&Theme::dark());
        let joined_inbox = rendered_inbox
            .rows
            .iter()
            .map(StyledRow::plain_text)
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            joined_inbox.contains("! Errored (s-err)  paused: boom  [missing cwd]"),
            "{joined_inbox}"
        );
        assert!(
            joined_inbox.contains("● Unloaded Attn (s-cold-attn)  idle"),
            "{joined_inbox}"
        );
        assert!(
            joined_inbox.contains("○ Dismissed (s-dismiss)  idle"),
            "{joined_inbox}"
        );

        // Tab cycling visits only Tier 0 & Tier 1 (skips Tier 2 running and Tier 3 dismissed)
        assert_eq!(inbox.selected_id(), Some("s-err"));
        assert!(inbox.cycle_attention(true));
        assert_eq!(inbox.selected_id(), Some("s-cold-attn"));
        assert!(inbox.cycle_attention(true));
        assert_eq!(inbox.selected_id(), Some("s-err"));

        // Toggle filter to All: reveals cold unloaded, user-archived, and imported archives in Tier 3 & 4
        assert_eq!(inbox.toggle_filter(), InboxFilter::All);
        assert_eq!(
            inbox.ordered_session_ids(),
            vec![
                "s-err",
                "s-cold-attn",
                "s-run",
                "s-dismiss",
                "s-cold",
                "s-arch",
                "s-imp"
            ]
        );
        let rendered_all = inbox.render(&Theme::dark());
        let joined_all = rendered_all
            .rows
            .iter()
            .map(StyledRow::plain_text)
            .collect::<Vec<_>>()
            .join("\n");
        assert!(joined_all.contains("Inbox [All]"), "{joined_all}");
        assert!(
            joined_all.contains("· Archived (s-arch)  archived"),
            "{joined_all}"
        );
        assert!(
            joined_all.contains("· Imported (s-imp)  archived"),
            "{joined_all}"
        );
        // Imported archive does NOT show [missing cwd] even if cwd_exists were false
        assert!(
            !joined_all.contains("Imported (s-imp)  archived  [missing cwd]"),
            "{joined_all}"
        );

        // Explicit catalog triage upsert updates indicator from ○ to ● and moves session up to Tier 1
        let mut s_retagged = s_dismissed;
        s_retagged.needs_attention = Some(true);
        inbox.apply(CatalogUpdate::Upsert(Box::new(s_retagged)));
        assert_eq!(
            inbox.ordered_session_ids(),
            vec![
                "s-err",
                "s-dismiss",
                "s-cold-attn",
                "s-run",
                "s-cold",
                "s-arch",
                "s-imp"
            ]
        );
    }

    #[test]
    fn spinner_advances_on_tick_and_uses_ascii_in_plain_theme() {
        let mut inbox = InboxState::with_home("host".into(), "/work".into(), None, None);
        inbox.apply(CatalogUpdate::Snapshot(vec![make_session(
            "s1",
            "/work",
            "host",
            Some("Run"),
            "running",
            Some("generation"),
            None,
            1,
        )]));

        let first_uni = inbox.spinner_char(false);
        let first_ascii = inbox.spinner_char(true);
        assert_eq!(first_uni, '⠋');
        assert_eq!(first_ascii, '|');

        let future = Instant::now() + SPINNER_TICK + Duration::from_millis(5);
        assert!(inbox.tick_spinner(future));
        assert_eq!(inbox.spinner_char(false), '⠙');
        assert_eq!(inbox.spinner_char(true), '/');
    }

    fn bind_test_socket(tag: &str) -> (PathBuf, UnixListener, DaemonClient) {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sock_path = std::env::temp_dir().join(format!("hi-inbox-{tag}-{nanos}.sock"));
        let _ = std::fs::remove_file(&sock_path);
        let listener = UnixListener::bind(&sock_path).unwrap();
        let client = DaemonClient::new(
            DaemonTarget::UnixSocket(sock_path.clone()),
            SecretToken::new("tok-inbox-test").unwrap(),
        );
        (sock_path, listener, client)
    }

    fn wait_catalog_update(sub: &CatalogSubscription, timeout: Duration) -> CatalogUpdate {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(u) = sub.next() {
                return u;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for CatalogUpdate"
            );
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn catalog_subscription_streams_snapshot_upsert_removed_and_cancels_cleanly() {
        let (sock_path, listener, client) = bind_test_socket("sse");
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 1024];
            let n = stream.read(&mut buf).unwrap();
            let req = String::from_utf8_lossy(&buf[..n]);
            assert!(
                req.starts_with("GET /api/v1/sessions/events HTTP/1.1"),
                "{req}"
            );

            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
            )
            .unwrap();
            let snap = "id: 1\nevent: snapshot\ndata: {\"version\":1,\"seq\":1,\"sessions\":[{\"session_id\":\"s1\",\"cwd\":\"/tmp/a\",\"active\":true,\"attention\":\"running\",\"activity_kind\":\"tool\",\"activity_label\":\"bash\"}]}\n\n";
            write!(stream, "{:x}\r\n{snap}\r\n", snap.len()).unwrap();
            let upsert = "id: 2\nevent: catalog\ndata: {\"version\":1,\"seq\":2,\"type\":\"upsert\",\"session\":{\"session_id\":\"s1\",\"cwd\":\"/tmp/a\",\"active\":false,\"attention\":\"idle\"}}\n\n";
            write!(stream, "{:x}\r\n{upsert}\r\n", upsert.len()).unwrap();
            let removed = "id: 3\nevent: catalog\ndata: {\"version\":1,\"seq\":3,\"type\":\"removed\",\"session_id\":\"s1\"}\n\n";
            write!(stream, "{:x}\r\n{removed}\r\n", removed.len()).unwrap();
            stream.flush().unwrap();

            // Hold open until client cancels on Drop
            let mut drain = [0u8; 16];
            let _ = stream.read(&mut drain);
        });

        let sub = CatalogSubscription::start_with_timing(
            client,
            Duration::from_millis(10),
            Duration::from_millis(50),
            Duration::from_millis(100),
        );

        assert_eq!(
            wait_catalog_update(&sub, Duration::from_secs(2)),
            CatalogUpdate::Online
        );
        match wait_catalog_update(&sub, Duration::from_secs(2)) {
            CatalogUpdate::Snapshot(list) => {
                assert_eq!(list.len(), 1);
                assert_eq!(list[0].session_id, "s1");
                assert_eq!(list[0].effective_attention(), "running");
            }
            other => panic!("expected Snapshot, got {other:?}"),
        }
        match wait_catalog_update(&sub, Duration::from_secs(2)) {
            CatalogUpdate::Upsert(s) => assert_eq!(s.effective_attention(), "idle"),
            other => panic!("expected Upsert, got {other:?}"),
        }
        assert_eq!(
            wait_catalog_update(&sub, Duration::from_secs(2)),
            CatalogUpdate::Removed("s1".into())
        );

        let started_drop = Instant::now();
        drop(sub);
        assert!(started_drop.elapsed() < Duration::from_secs(1));

        let _ = server.join();
        let _ = std::fs::remove_file(&sock_path);
    }

    #[test]
    fn catalog_subscription_falls_back_to_list_sessions_on_404() {
        let (sock_path, listener, client) = bind_test_socket("fallback-404");
        let server = thread::spawn(move || {
            // 1. /api/v1/sessions/events -> 404
            let (mut s1, _) = listener.accept().unwrap();
            let mut buf = [0u8; 1024];
            let n = s1.read(&mut buf).unwrap();
            let req1 = String::from_utf8_lossy(&buf[..n]);
            assert!(
                req1.starts_with("GET /api/v1/sessions/events HTTP/1.1"),
                "{req1}"
            );
            let body404 = r#"{"error":"not found"}"#;
            write!(
                s1,
                "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body404}",
                body404.len()
            )
            .unwrap();
            s1.flush().unwrap();

            // 2. Fallback GET /api/v1/sessions -> 200
            let (mut s2, _) = listener.accept().unwrap();
            let n2 = s2.read(&mut buf).unwrap();
            let req2 = String::from_utf8_lossy(&buf[..n2]);
            assert!(req2.starts_with("GET /api/v1/sessions HTTP/1.1"), "{req2}");
            let body200 =
                r#"{"sessions":[{"session_id":"legacy-1","cwd":"/tmp/legacy","active":false}]}"#;
            write!(
                s2,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body200}",
                body200.len()
            )
            .unwrap();
            s2.flush().unwrap();
        });

        let sub = CatalogSubscription::start_with_timing(
            client,
            Duration::from_millis(10),
            Duration::from_millis(50),
            Duration::from_secs(10),
        );

        assert_eq!(
            wait_catalog_update(&sub, Duration::from_secs(2)),
            CatalogUpdate::Online
        );
        match wait_catalog_update(&sub, Duration::from_secs(2)) {
            CatalogUpdate::Snapshot(list) => {
                assert_eq!(list.len(), 1);
                assert_eq!(list[0].session_id, "legacy-1");
            }
            other => panic!("expected fallback Snapshot, got {other:?}"),
        }

        drop(sub);
        let _ = server.join();
        let _ = std::fs::remove_file(&sock_path);
    }

    #[test]
    fn subsessions_hidden_by_default_and_exempt_from_counts_tab_and_newly_idle() {
        let mut inbox = InboxState::with_home(
            "host".into(),
            "/Users/alice/repo".into(),
            None,
            Some("/Users/alice".into()),
        );
        inbox.apply(CatalogUpdate::Online);

        let root_run = make_session(
            "root-run",
            "/Users/alice/repo",
            "host",
            Some("Coordinator"),
            "running",
            Some("tool"),
            Some("subagent"),
            10,
        );
        let root_idle = make_session(
            "root-idle",
            "/Users/alice/repo",
            "host",
            Some("Other Root"),
            "idle",
            None,
            None,
            20,
        );
        let mut sub_running = make_session(
            "sub-1",
            "/private/tmp/wt-1",
            "host",
            Some("Lane 1"),
            "running",
            Some("tool"),
            Some("bash"),
            15,
        );
        sub_running.parent = Some(crate::protocol::SessionParent {
            session_id: "root-run".into(),
            conversation_id: Some("1".into()),
            at_entry_id: Some("42".into()),
            task_id: Some("43".into()),
            depth: Some(1),
        });
        sub_running.role = Some("subagent".into());

        let mut sub_err = make_session(
            "sub-err",
            "/private/tmp/wt-2",
            "host",
            Some("Failed Lane"),
            "error",
            None,
            Some("tool_error"),
            16,
        );
        sub_err.parent = Some(crate::protocol::SessionParent {
            session_id: "root-run".into(),
            conversation_id: Some("1".into()),
            at_entry_id: Some("42".into()),
            task_id: None,
            depth: Some(1),
        });
        sub_err.role = Some("subagent".into());

        inbox.apply(CatalogUpdate::Snapshot(vec![
            root_run,
            root_idle,
            sub_running.clone(),
            sub_err,
        ]));

        // Default: subsessions hidden
        assert!(!inbox.show_subsessions());
        assert_eq!(inbox.subsession_count(), 2);
        // Counts only count root sessions: 2 total, 0 errors, 1 attention, 1 running, 0 archived
        assert_eq!(inbox.counts(), (2, 0, 1, 1, 0));
        // Root-idle (tier 1) sorts before root-run (tier 2)
        assert_eq!(inbox.ordered_session_ids(), vec!["root-idle", "root-run"]);
        assert_eq!(inbox.selected_id(), Some("root-idle"));

        // Subsession transitioning from running -> idle stays calm (tier 3 ○)
        let mut sub_done = sub_running;
        sub_done.attention = Some("idle".into());
        sub_done.active = false;
        inbox.apply(CatalogUpdate::Upsert(Box::new(sub_done)));

        // Header shows hidden subsessions count; status line mentions `t subsessions`
        let hidden_text: String = inbox
            .render(&Theme::dark())
            .rows
            .iter()
            .map(StyledRow::plain_text)
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            hidden_text.contains("2 subsessions (hidden)"),
            "{hidden_text}"
        );
        assert!(!hidden_text.contains("Lane 1"), "{hidden_text}");
        assert!(!hidden_text.contains("/private/tmp/wt-1"), "{hidden_text}");
        assert!(inbox.status_line("").contains("t subsessions"));

        // Toggle subsessions ON -> hierarchical rendering under root-run even with different cwd!
        assert!(inbox.toggle_subsessions());
        assert!(inbox.show_subsessions());
        // Counts STILL only count root sessions
        assert_eq!(inbox.counts(), (2, 0, 1, 1, 0));
        // Order: root-idle -> root-run -> sub-1 -> sub-err (all inside ~/repo group!)
        assert_eq!(
            inbox.ordered_session_ids(),
            vec!["root-idle", "root-run", "sub-1", "sub-err"]
        );

        // Tab (`cycle_attention`) skips sub-1 (idle) and sub-err (error), landing only on root-idle!
        assert!(inbox.cycle_attention(true));
        assert_eq!(inbox.selected_id(), Some("root-idle"));
        assert!(inbox.cycle_attention(false));
        assert_eq!(inbox.selected_id(), Some("root-idle"));

        // j/k CAN navigate through visible subsessions
        inbox.move_selection(1);
        assert_eq!(inbox.selected_id(), Some("root-run"));
        inbox.move_selection(1);
        assert_eq!(inbox.selected_id(), Some("sub-1"));
        inbox.move_selection(1);
        assert_eq!(inbox.selected_id(), Some("sub-err"));

        // Rendered output nests sub-1 and sub-err under root-run with ↳, @#42, and [cwd: /private/tmp/...]
        // And sub-1 uses ○ (idle), NOT ● (newly_idle)!
        let shown_text: String = inbox
            .render(&Theme::dark())
            .rows
            .iter()
            .map(StyledRow::plain_text)
            .collect::<Vec<_>>()
            .join("\n");
        assert!(shown_text.contains("2 subsessions (shown)"), "{shown_text}");
        assert!(
            shown_text.contains("   ├─ ↳ ○ Lane 1 (sub-1)  @#42  [cwd: /private/tmp/wt-1]  idle"),
            "{shown_text}"
        );
        assert!(!shown_text.contains("● Lane 1"), "{shown_text}");
        assert!(
            shown_text.contains("   └─ ↳ ! Failed Lane (sub-err)  @#42  [cwd: /private/tmp/wt-2]"),
            "{shown_text}"
        );
        // No top-level /private/tmp/wt-1 workspace header group was created
        assert_eq!(inbox.grouped_rows().len(), 1);

        // Toggling subsessions back OFF while a subsession is selected reconciles back to a root session
        assert!(!inbox.toggle_subsessions());
        assert_eq!(inbox.selected_id(), Some("root-idle"));
    }

    #[test]
    fn orphan_subsession_renders_in_own_workspace_group_with_parent_badge() {
        let mut inbox = InboxState::with_home("host".into(), "/work/main".into(), None, None);
        inbox.apply(CatalogUpdate::Online);
        inbox.set_show_subsessions(true);

        let mut orphan = make_session(
            "sub-orphan",
            "/private/tmp/wt-orphan",
            "host",
            Some("Detached Worker"),
            "idle",
            None,
            None,
            50,
        );
        orphan.parent = Some(crate::protocol::SessionParent {
            session_id: "deleted-parent".into(),
            conversation_id: Some("1".into()),
            at_entry_id: Some("7".into()),
            task_id: None,
            depth: Some(1),
        });
        orphan.role = Some("subagent".into());

        inbox.apply(CatalogUpdate::Snapshot(vec![orphan]));
        assert_eq!(inbox.counts(), (0, 0, 0, 0, 0));
        assert_eq!(inbox.subsession_count(), 1);
        assert_eq!(inbox.ordered_session_ids(), vec!["sub-orphan"]);
        // Tab never selects orphan subsession
        assert!(!inbox.cycle_attention(true));

        let rendered: String = inbox
            .render(&Theme::dark())
            .rows
            .iter()
            .map(StyledRow::plain_text)
            .collect::<Vec<_>>()
            .join("\n");
        assert!(rendered.contains("/private/tmp/wt-orphan"), "{rendered}");
        assert!(
            rendered.contains("Detached Worker (sub-orphan)  [↳ deleted-parent]  @#7"),
            "{rendered}"
        );
    }
}
