//! Terminal-side state only. All durable mutations go through an effect worker.
use super::secret::SecretInput;
use super::{
    actions::{self, Effect, Reply, Target},
    cards,
    completion::{self, Completion, Token},
    editor::Editor,
    external,
    inbox::{CatalogSubscription, CatalogUpdate, InboxFilter, InboxState},
    login::{self, Login},
    markdown::StyledRow,
    picker::{Choice, Picker},
    preferences::UserConfig,
    prompts::{self, PromptTemplate},
    screen::{EditorOverlay, Screen},
    status::{StatusFields, StatusMetadata},
    stream::{Subscription, Update},
    tree::{TreeChoice, TreeSelection, TreeSelector},
};
use crate::{
    cli::generate_request_id,
    client::{ClientError, DaemonClient},
    protocol::{ApprovalPolicy, CommandEnvelope, RunBudget, ServerFrame, WhenBusy, WhenIdle},
    render::{extract_entry_text, sanitize_single_line},
    transcript::{CommitOutcome, TranscriptState, WorkspaceWaitInfo},
};
use crossterm::event::{
    self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers as Mod, MouseEventKind,
};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    io,
    path::{Path, PathBuf},
    sync::mpsc::{self, Receiver, TryRecvError},
    thread,
    time::{Duration, Instant},
};

const COMMANDS: &[(&str, &str)] = &[
    ("/resume", "Workspace sessions"),
    ("/inbox", "Browse all sessions across workspaces"),
    ("/parent", "Jump to parent session"),
    (
        "/cwd",
        "Show workspace directory or fork session into a new directory",
    ),
    (
        "/attention",
        "Toggle or set needs_attention flag on this session",
    ),
    (
        "/archive",
        "Archive and unload this session ('force' to stop work, 'off' to restore)",
    ),
    (
        "/stop",
        "Stop active work across all conversations in this session",
    ),
    ("/new", "New session"),
    (
        "/harness",
        "List harnesses or start a session with a specific harness",
    ),
    ("/name", "Show or rename session title"),
    ("/tree", "Browse turn-step tree across branches"),
    ("/fork", "Edit an earlier prompt on a new branch"),
    ("/branch", "Branch after a visible entry"),
    ("/earlier", "Page older entries"),
    ("/latest", "Return to live transcript"),
    ("/model", "Choose a model"),
    ("/login", "Sign in to a daemon provider account"),
    ("/logout", "Remove a configured Codex account"),
    ("/key", "Manage named provider API keys"),
    ("/account", "Select the stock Codex account"),
    ("/thinking", "Choose thinking level"),
    ("/theme", "List or switch UI themes live"),
    ("/prompts", "Browse prompt templates"),
    ("/file", "Read a session workspace file"),
    ("/attach", "Attach a client-local file"),
    ("/steer", "Steer the active run"),
    ("/follow-up", "Queue follow-up"),
    ("/dequeue", "Withdraw queued prompts"),
    ("/approve", "Approve a pending tool call"),
    ("/deny", "Deny a pending tool call"),
    (
        "/approval",
        "Set tool approval policy (never, mutating, or tools)",
    ),
    ("/budget", "Show, set, or clear run budget"),
    ("/abort", "Interrupt this conversation or a specific task"),
    ("/workspace", "Workspace wait actions"),
    ("/continue", "Continue conversation"),
    ("/compact", "Compact conversation history"),
    ("/tools", "Toggle tool details"),
    ("/thoughts", "Toggle thinking blocks"),
    ("/edit", "Open draft in external editor"),
    ("/envs", "List environments"),
    ("/search", "Search loaded messages"),
    ("/status", "Show connection and run status"),
    ("/help", "Open command palette"),
    ("/hotkeys", "Active shortcuts"),
    ("/reload", "Reload local status templates and keybindings"),
    ("/copy", "Copy last assistant message (OSC 52)"),
    (
        "/export",
        "Export history to a new local .html or .jsonl file",
    ),
    (
        "/restart-ui",
        "Reload hi in this conversation (does not stop the daemon)",
    ),
    ("/quit", "Detach (does not abort)"),
    ("/retry", "Retry a pending submission"),
    ("/discard-retry", "Forget a pending submission retry"),
    ("/conv", "Switch to a conversation by ID"),
    ("/files", "Browse session workspace files"),
    ("/branches", "List conversations in this session"),
    ("/sessions", "Alias for /resume"),
    ("/session", "Alias for /status"),
    ("/exit", "Alias for /quit"),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PickerKind {
    Models,
    Harnesses,
    LoginSources,
    LogoutSources,
    KeyRemove,
    AccountSources,
    Thinking,
    Themes,
    Prompts,
    Sessions,
    Branches,
    Fork,
    RootFork,
    Branch,
    Commands,
    ClientFiles,
    WorkspaceFiles,
    WorkspaceWait,
    Approval,
    Search,
    TreeAction,
    Info,
}

struct PickerState {
    kind: PickerKind,
    picker: Picker,
    scope: Option<(String, String)>,
    workspace_wait: Option<WorkspaceWaitInfo>,
    tree_selection: Option<TreeSelection>,
}

struct TreeState {
    selector: TreeSelector,
    scope: (String, String),
}

struct PendingTreeForkEdit {
    source_sid: String,
    target_cid: String,
    entry_id: String,
}

struct ForkEdit {
    source_sid: String,
    source_cid: String,
    selected_entry_id: String,
    predecessor_id: u64,
    stashed_draft: Box<Draft>,
}

struct PendingRootFork {
    source_sid: String,
    source_cid: String,
    entry_id: String,
    text: String,
    attachments: Vec<Value>,
}

struct PendingCwdFork {
    source_sid: String,
    source_cid: String,
}

#[derive(Default)]
struct Draft {
    editor: Editor,
    attachments: Vec<Value>,
    retry: Option<(String, CommandEnvelope)>,
    fork_edit: Option<ForkEdit>,
}
struct Job {
    result: Receiver<Result<Reply, String>>,
    submitted: Option<(String, CommandEnvelope)>,
    source_target: (String, String),
}
struct PathLookup {
    token: Option<Token>,
    result: Receiver<Result<Vec<(String, String)>, ClientError>>,
}
struct InboxMode {
    state: InboxState,
    sub: CatalogSubscription,
}

struct Ui {
    client: DaemonClient,
    target: Target,
    launch_env_id: String,
    launch_cwd: String,
    state: TranscriptState,
    historical: Option<TranscriptState>,
    sub: Option<Subscription>,
    catalog_sub: Option<CatalogSubscription>,
    inbox: Option<InboxMode>,
    entered_from_inbox: bool,
    online: bool,
    draft: Draft,
    saved: HashMap<(String, String), Draft>,
    picker: Option<PickerState>,
    tree: Option<TreeState>,
    login: Option<Login>,
    secret: Option<SecretInput>,
    completion: Option<Completion>,
    path_lookup: Option<PathLookup>,
    pending_root_fork: Option<PendingRootFork>,
    pending_cwd_fork: Option<PendingCwdFork>,
    pending_tree_fork_edit: Option<PendingTreeForkEdit>,
    config: UserConfig,
    config_gen: u64,
    prompts: Vec<PromptTemplate>,
    status_metadata: StatusMetadata,
    data_dir: PathBuf,
    job: Option<Job>,
    note: String,
    tools: bool,
    thinking: bool,
    cached_rows: Vec<StyledRow>,
    rows_dirty: bool,
    quit: bool,
    restart_ui: Option<PathBuf>,
    last_clear: Option<Instant>,
}

fn local<T>(r: io::Result<T>) -> Result<T, String> {
    r.map_err(|e| e.to_string())
}

pub struct RestartOrigin {
    pub daemon_url: Option<String>,
}

pub fn run(
    client: DaemonClient,
    target: Target,
    data_dir: &Path,
    resume: bool,
    initial: &str,
    regular: bool,
    origin: RestartOrigin,
) -> Result<(), String> {
    let config = UserConfig::load(data_dir)?;
    let prompts = prompts::discover_prompts(data_dir);
    let sub = Subscription::start(client.clone(), target.sid.clone(), target.cid.clone(), None);
    let catalog_sub = CatalogSubscription::start(client.clone());
    let state = TranscriptState::new(Some(target.sid.clone()), Some(target.cid.clone()));
    let launch_env_id = target.env_id.clone();
    let launch_cwd = target.cwd.clone();
    let ui = Ui {
        client,
        target,
        launch_env_id,
        launch_cwd,
        state,
        historical: None,
        sub: Some(sub),
        catalog_sub: Some(catalog_sub),
        inbox: None,
        entered_from_inbox: false,
        online: false,
        draft: Draft::default(),
        saved: HashMap::new(),
        picker: None,
        tree: None,
        login: None,
        secret: None,
        completion: None,
        path_lookup: None,
        pending_root_fork: None,
        pending_cwd_fork: None,
        pending_tree_fork_edit: None,
        config,
        config_gen: 0,
        prompts,
        status_metadata: StatusMetadata::default(),
        data_dir: data_dir.to_owned(),
        job: None,
        note: "Connecting · /help".into(),
        tools: false,
        thinking: false,
        cached_rows: Vec::new(),
        rows_dirty: true,
        quit: false,
        restart_ui: None,
        last_clear: None,
    };
    run_loop(ui, resume, initial, regular, origin)
}

pub fn run_inbox(
    client: DaemonClient,
    env_id: String,
    cwd: String,
    data_dir: &Path,
    regular: bool,
    show_subsessions: bool,
    origin: RestartOrigin,
) -> Result<(), String> {
    let config = UserConfig::load(data_dir)?;
    let prompts = prompts::discover_prompts(data_dir);
    let catalog_sub = CatalogSubscription::start(client.clone());
    let mut inbox_state = InboxState::new(env_id.clone(), cwd.clone(), None);
    inbox_state.set_show_subsessions(show_subsessions);
    let placeholder_target = Target {
        sid: String::new(),
        cid: "1".to_string(),
        cwd: cwd.clone(),
        env_id: env_id.clone(),
        labels: Default::default(),
    };
    let ui = Ui {
        client,
        target: placeholder_target,
        launch_env_id: env_id,
        launch_cwd: cwd,
        state: TranscriptState::default(),
        historical: None,
        sub: None,
        catalog_sub: None,
        inbox: Some(InboxMode {
            state: inbox_state,
            sub: catalog_sub,
        }),
        entered_from_inbox: true,
        online: false,
        draft: Draft::default(),
        saved: HashMap::new(),
        picker: None,
        tree: None,
        login: None,
        secret: None,
        completion: None,
        path_lookup: None,
        pending_root_fork: None,
        pending_cwd_fork: None,
        pending_tree_fork_edit: None,
        config,
        config_gen: 0,
        prompts,
        status_metadata: StatusMetadata::default(),
        data_dir: data_dir.to_owned(),
        job: None,
        note: String::new(),
        tools: false,
        thinking: false,
        cached_rows: Vec::new(),
        rows_dirty: true,
        quit: false,
        restart_ui: None,
        last_clear: None,
    };
    run_loop(ui, false, "", regular, origin)
}

fn run_loop(
    mut ui: Ui,
    resume: bool,
    initial: &str,
    regular: bool,
    origin: RestartOrigin,
) -> Result<(), String> {
    let open_screen = if regular {
        Screen::open_regular
    } else {
        Screen::open
    };
    ui.config.status.validate(&ui.status_fields())?;
    let exiting = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    for signal in [
        signal_hook::consts::SIGTERM,
        signal_hook::consts::SIGINT,
        signal_hook::consts::SIGHUP,
    ] {
        local(signal_hook::flag::register(signal, exiting.clone()))?;
    }
    let mut screen = local(open_screen())?;
    if resume && ui.inbox.is_none() {
        ui.start(Effect::Sessions, None);
    }
    let mut initial = Some(initial).filter(|s| !s.is_empty());
    let mut repaint = true;
    while !ui.quit && !exiting.load(std::sync::atomic::Ordering::Relaxed) {
        if ui.inbox.is_some() {
            repaint |= ui.drain_inbox_updates();
            if let Some(inbox) = ui.inbox.as_mut() {
                repaint |= inbox.state.tick_spinner(Instant::now());
            }
        } else {
            for _ in 0..48 {
                let Some(update) = ui.sub.as_ref().and_then(Subscription::next) else {
                    break;
                };
                ui.update(update);
                repaint = true;
            }
            repaint |= ui.drain_session_catalog_updates();
            repaint |= ui.complete_path_lookup();
            let ext_scope = ui
                .config
                .extension_status
                .then(|| (ui.state.agent_model().unwrap_or("default"), ui.config_gen));
            repaint |= ui.status_metadata.tick(
                &ui.target,
                &ui.client,
                &ui.config.status,
                ui.online,
                ext_scope,
            );
            repaint |= ui.login.as_mut().is_some_and(|flow| flow.tick(&ui.client));
            if ui.online && ui.state.seq.is_some() && ui.job.is_none() {
                if let Some(text) = initial.take() {
                    ui.dismiss_completion();
                    ui.draft.editor.set(text);
                    ui.send(false);
                    repaint = true;
                }
            }
        }
        repaint |= ui.complete(&mut screen);
        if repaint {
            ui.draw(&mut screen)?;
            repaint = false;
        }
        if terminal_disconnected() {
            break;
        }
        if local(event::poll(Duration::from_millis(16)))? {
            match local(event::read())? {
                Event::Key(k) if k.kind != KeyEventKind::Release => {
                    if ui.inbox.is_some() {
                        ui.inbox_key(k);
                    } else if ui.secret.is_some() {
                        ui.secret_key(k);
                    } else if let Some(flow) = &mut ui.login {
                        if (k.code == KeyCode::Esc || (k.code == KeyCode::Enter && flow.is_done()))
                            && flow.cancel()
                        {
                            ui.login = None;
                        }
                    } else if ui.draft.editor.is_searching_history()
                        && ui.picker.is_none()
                        && ui.tree.is_none()
                    {
                        ui.draft.editor.key(k);
                    } else if ui.tree.is_some() {
                        ui.tree_key(k, &mut screen);
                    } else if ui.picker.is_some() {
                        ui.pick_key(k, &mut screen);
                    } else if ui.config.keys.action(k) == Some("external")
                        || (k.code == KeyCode::Enter
                            && k.modifiers.is_empty()
                            && ui.draft.editor.text() == "/edit")
                    {
                        ui.dismiss_completion();
                        if ui.draft.editor.text() == "/edit" {
                            ui.draft.editor.set("");
                        }
                        drop(screen);
                        match external::edit(&ui.draft.editor.expanded_text()) {
                            Ok(s) => ui.draft.editor.set(&s),
                            Err(e) => ui.note = e.to_string(),
                        };
                        screen = local(open_screen())?;
                    } else if ui.config.keys.action(k) == Some("suspend") {
                        ui.dismiss_completion();
                        drop(screen);
                        local(signal_hook::low_level::raise(signal_hook::consts::SIGSTOP))?;
                        screen = local(open_screen())?;
                    } else {
                        ui.key(k, &mut screen);
                    }
                }
                Event::Paste(_) if ui.inbox.is_some() => {}
                Event::Paste(s) if ui.secret.is_some() => {
                    if let Some(secret) = &mut ui.secret {
                        secret.paste(&s);
                    }
                }
                Event::Paste(s)
                    if ui.picker.is_none() && ui.tree.is_none() && ui.login.is_none() =>
                {
                    ui.dismiss_completion();
                    if s.len() > super::files::MAX_TEXT_BYTES {
                        ui.note = "Paste exceeds 1 MiB; use a smaller excerpt".into();
                    } else {
                        ui.draft.editor.paste(&s);
                    }
                }
                Event::Mouse(m) if ui.inbox.is_some() => match m.kind {
                    MouseEventKind::ScrollUp => {
                        if let Some(inbox) = ui.inbox.as_mut() {
                            inbox.state.move_selection(-1);
                        }
                    }
                    MouseEventKind::ScrollDown => {
                        if let Some(inbox) = ui.inbox.as_mut() {
                            inbox.state.move_selection(1);
                        }
                    }
                    _ => {}
                },
                Event::Mouse(m) => match m.kind {
                    MouseEventKind::ScrollUp => screen.scroll(3),
                    MouseEventKind::ScrollDown => screen.scroll(-3),
                    _ => {}
                },
                _ => {}
            }
            repaint = true;
        }
    }
    if let Some(executable) = ui.restart_ui.take() {
        use std::os::unix::process::CommandExt;
        let mut command = std::process::Command::new(executable);
        command
            .arg("--data-dir")
            .arg(&ui.data_dir)
            .arg("--session")
            .arg(&ui.target.sid)
            .arg("--conversation")
            .arg(&ui.target.cid)
            .arg("--tui-mode")
            .arg(if regular { "regular" } else { "fullscreen" });
        if let Some(url) = origin.daemon_url {
            command.arg("--daemon-url").arg(url);
        }
        // Restore terminal modes and cancel the old subscription before exec.
        drop(screen);
        drop(ui);
        return Err(format!("Could not restart hi: {}", command.exec()));
    }
    Ok(())
}

/// Checks whether standard input has lost its controlling terminal / peer (hangup,
/// error, or invalid descriptor).
///
/// Crossterm 0.29's default Unix `mio` event source loops on `tty_fd.read(...)`
/// without breaking on `Ok(0)` (EOF), so calling `crossterm::event::poll` after the
/// PTY master closes causes an infinite 100% CPU busy loop inside `read()`.
#[cfg(unix)]
fn terminal_disconnected() -> bool {
    fd_disconnected(0)
}

#[cfg(unix)]
fn fd_disconnected(fd: i32) -> bool {
    #[repr(C)]
    struct PollFd {
        fd: i32,
        events: i16,
        revents: i16,
    }
    const POLLIN: i16 = 0x0001;
    const POLLERR: i16 = 0x0008;
    const POLLHUP: i16 = 0x0010;
    const POLLNVAL: i16 = 0x0020;

    unsafe extern "C" {
        fn poll(fds: *mut PollFd, nfds: u64, timeout: i32) -> i32;
    }

    let mut pfd = PollFd {
        fd,
        events: POLLIN,
        revents: 0,
    };
    let rc = unsafe { poll(&mut pfd, 1, 0) };
    rc > 0 && (pfd.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0
}

#[cfg(not(unix))]
fn terminal_disconnected() -> bool {
    false
}

impl Ui {
    fn drain_inbox_updates(&mut self) -> bool {
        let mut changed = false;
        for _ in 0..64 {
            let update = {
                let Some(inbox) = self.inbox.as_ref() else {
                    break;
                };
                inbox.sub.next()
            };
            let Some(update) = update else {
                break;
            };
            if let Some(inbox) = self.inbox.as_mut() {
                if let Some(err) = inbox.state.apply(update) {
                    self.note = err;
                } else if inbox.state.online && self.note.contains("catalog") {
                    self.note.clear();
                }
            }
            changed = true;
        }
        changed
    }

    fn drain_session_catalog_updates(&mut self) -> bool {
        let mut changed = false;
        for _ in 0..32 {
            let Some(update) = self
                .catalog_sub
                .as_ref()
                .and_then(CatalogSubscription::next)
            else {
                break;
            };
            match update {
                CatalogUpdate::Snapshot(list) => {
                    if let Some(session) = list.iter().find(|s| s.session_id == self.target.sid) {
                        changed |= self.sync_target_labels(session);
                    }
                }
                CatalogUpdate::Upsert(session) if session.session_id == self.target.sid => {
                    changed |= self.sync_target_labels(&session);
                }
                _ => {}
            }
        }
        changed
    }

    fn sync_target_labels(&mut self, session: &crate::protocol::SessionSummary) -> bool {
        let next = super::actions::SessionLabels::from(session);
        if self.target.labels != next {
            let became_archived = !self.target.labels.archived && next.archived;
            self.target.labels = next;
            if became_archived && !self.target.labels.is_imported_archive() {
                self.note =
                    "Session archived (unloaded) · send a message or /archive off to resume".into();
            }
            true
        } else {
            false
        }
    }

    fn enter_inbox(&mut self) {
        self.dismiss_completion();
        if !self.target.sid.is_empty() {
            let key = (self.target.sid.clone(), self.target.cid.clone());
            self.saved.insert(key, std::mem::take(&mut self.draft));
        }
        self.picker = None;
        self.tree = None;
        self.login = None;
        self.secret = None;
        self.pending_root_fork = None;
        self.pending_cwd_fork = None;
        self.pending_tree_fork_edit = None;
        self.historical = None;
        self.sub = None;
        self.catalog_sub = None;
        let preselect = (!self.target.sid.is_empty()).then(|| self.target.sid.clone());
        let catalog_sub = CatalogSubscription::start(self.client.clone());
        let inbox_state = InboxState::new(
            self.launch_env_id.clone(),
            self.launch_cwd.clone(),
            preselect,
        );
        self.inbox = Some(InboxMode {
            state: inbox_state,
            sub: catalog_sub,
        });
        self.entered_from_inbox = true;
        self.note.clear();
    }

    fn inbox_key(&mut self, k: KeyEvent) {
        let is_ctrl_d = k.code == KeyCode::Char('d') && k.modifiers.contains(Mod::CONTROL);
        let is_ctrl_c = k.code == KeyCode::Char('c') && k.modifiers.contains(Mod::CONTROL);
        if is_ctrl_d
            || is_ctrl_c
            || k.code == KeyCode::Esc
            || (matches!(k.code, KeyCode::Char('q') | KeyCode::Char('Q'))
                && !k.modifiers.contains(Mod::CONTROL)
                && !k.modifiers.contains(Mod::ALT))
        {
            self.quit = true;
            return;
        }

        let Some(inbox) = self.inbox.as_mut() else {
            return;
        };

        match k.code {
            KeyCode::Down => {
                inbox.state.move_selection(1);
                self.note.clear();
            }
            KeyCode::Up => {
                inbox.state.move_selection(-1);
                self.note.clear();
            }
            KeyCode::Char('j' | 'J') if !k.modifiers.intersects(Mod::CONTROL | Mod::ALT) => {
                inbox.state.move_selection(1);
                self.note.clear();
            }
            KeyCode::Char('k' | 'K') if !k.modifiers.intersects(Mod::CONTROL | Mod::ALT) => {
                inbox.state.move_selection(-1);
                self.note.clear();
            }
            KeyCode::Tab => {
                let forward = !k.modifiers.contains(Mod::SHIFT);
                if inbox.state.cycle_attention(forward) {
                    self.note.clear();
                } else {
                    self.note = "No sessions needing attention".into();
                }
            }
            KeyCode::BackTab => {
                if inbox.state.cycle_attention(false) {
                    self.note.clear();
                } else {
                    self.note = "No sessions needing attention".into();
                }
            }
            KeyCode::Char(' ' | 'm' | 'M') if !k.modifiers.intersects(Mod::CONTROL | Mod::ALT) => {
                let selected = inbox.state.selected_session().cloned();
                let Some(session) = selected else {
                    self.note = "No session selected".into();
                    return;
                };
                if session.status.as_deref() == Some("archived") {
                    self.note = "Imported archives are read-only".into();
                    return;
                }
                let next_attention = !session.effective_needs_attention();
                let sid = session.session_id;
                self.note = if next_attention {
                    "Marking as needing attention…".into()
                } else {
                    "Clearing attention…".into()
                };
                self.start(
                    Effect::TriageSession {
                        sid,
                        needs_attention: next_attention,
                    },
                    None,
                );
            }
            KeyCode::Char('s' | 'S') if !k.modifiers.intersects(Mod::CONTROL | Mod::ALT) => {
                let selected = inbox.state.selected_session().cloned();
                let Some(session) = selected else {
                    self.note = "No session selected".into();
                    return;
                };
                if session.status.as_deref() == Some("archived") {
                    self.note = "Imported archives are read-only".into();
                    return;
                }
                let sid = session.session_id;
                self.note = format!("Stopping {}…", sanitize_single_line(&sid));
                self.start(Effect::StopSession { sid }, None);
            }
            KeyCode::Char('x') if !k.modifiers.intersects(Mod::CONTROL | Mod::ALT) => {
                let selected = inbox.state.selected_session().cloned();
                let Some(session) = selected else {
                    self.note = "No session selected".into();
                    return;
                };
                if session.status.as_deref() == Some("archived") {
                    self.note = "Imported archives are read-only".into();
                    return;
                }
                let next_archived = !session.effective_archived();
                let sid = session.session_id;
                self.note = if next_archived {
                    format!("Archiving {}…", sanitize_single_line(&sid))
                } else {
                    format!("Unarchiving {}…", sanitize_single_line(&sid))
                };
                self.start(
                    Effect::ArchiveSession {
                        sid,
                        archived: next_archived,
                        stop: false,
                    },
                    None,
                );
            }
            KeyCode::Char('X') if !k.modifiers.intersects(Mod::CONTROL | Mod::ALT) => {
                let selected = inbox.state.selected_session().cloned();
                let Some(session) = selected else {
                    self.note = "No session selected".into();
                    return;
                };
                if session.status.as_deref() == Some("archived") {
                    self.note = "Imported archives are read-only".into();
                    return;
                }
                let sid = session.session_id;
                self.note = format!("Stopping & archiving {}…", sanitize_single_line(&sid));
                self.start(
                    Effect::ArchiveSession {
                        sid,
                        archived: true,
                        stop: true,
                    },
                    None,
                );
            }
            KeyCode::Char('a' | 'A') if !k.modifiers.intersects(Mod::CONTROL | Mod::ALT) => {
                match inbox.state.toggle_filter() {
                    InboxFilter::All => {
                        self.note = "Showing all sessions (including archived)".into();
                    }
                    InboxFilter::Inbox => {
                        self.note = "Showing active inbox".into();
                    }
                }
            }
            KeyCode::Enter => {
                let selected = inbox.state.selected_session().cloned();
                let Some(session) = selected else {
                    self.note = "No session selected (press n to create one)".into();
                    return;
                };
                if session.effective_attention() == "quarantined" {
                    self.note = format!(
                        "Session {} is quarantined and cannot be attached",
                        sanitize_single_line(&session.session_id)
                    );
                    return;
                }
                let sid = session.session_id;
                self.note = format!("Opening {}…", sanitize_single_line(&sid));
                self.start(Effect::Attach(sid), None);
            }
            KeyCode::Char('n' | 'N') if !k.modifiers.intersects(Mod::CONTROL | Mod::ALT) => {
                let (env_id, cwd, cwd_exists) = inbox.state.new_session_workspace();
                if !cwd_exists {
                    self.note = "Working directory no longer exists".into();
                    return;
                }
                self.note = "Creating new session…".into();
                self.start(Effect::NewIn { env_id, cwd }, None);
            }
            KeyCode::Char('t' | 'T') if !k.modifiers.intersects(Mod::CONTROL | Mod::ALT) => {
                let shown = inbox.state.toggle_subsessions();
                self.note = if shown {
                    "Subsessions: shown".into()
                } else {
                    "Subsessions: hidden".into()
                };
            }
            _ => {}
        }
    }

    fn draw(&mut self, screen: &mut Screen) -> Result<(), String> {
        if let Some(inbox) = &self.inbox {
            let rendered = inbox.state.render(&self.config.theme);
            let status = [inbox.state.status_line(&self.note)];
            return local(screen.draw_inbox(
                &rendered.rows,
                rendered.selected_row,
                &status,
                &self.config.theme,
            ));
        }
        let (width, height) = crossterm::terminal::size().unwrap_or((0, 0));
        if width > 0 {
            self.draft.editor.set_width(usize::from(width));
        }
        if let Some(tree) = &mut self.tree {
            if height > 0 {
                let max_tree = (usize::from(height) * 6 / 10).clamp(7, 16);
                tree.selector
                    .set_max_visible(max_tree.saturating_sub(2).max(1));
            }
        }
        if self.rows_dirty {
            self.cached_rows = cards::styled_rows(
                self.historical.as_ref().unwrap_or(&self.state),
                self.tools,
                self.thinking,
                &self.config.theme,
            );
            self.rows_dirty = false;
        }
        let mut fields = self.status_fields();
        fields.width = width;
        let status = self.config.status.render(&fields);
        let lines;
        let overlay = if let Some(secret) = &self.secret {
            lines = secret.lines();
            EditorOverlay::Picker(&lines)
        } else if let Some(flow) = &self.login {
            lines = flow.lines();
            EditorOverlay::Picker(&lines)
        } else if let Some(tree) = &self.tree {
            lines = tree.selector.lines();
            EditorOverlay::Tree(&lines)
        } else if let Some(picker) = &self.picker {
            lines = picker.picker.lines();
            EditorOverlay::Picker(&lines)
        } else if let Some(completion) = &self.completion {
            lines = completion.lines();
            EditorOverlay::Completion(&lines)
        } else {
            EditorOverlay::None
        };
        local(screen.draw_styled_with_overlay(
            &self.cached_rows,
            self.draft.editor.text(),
            self.draft.editor.cursor(),
            &status,
            overlay,
            &self.config.theme,
        ))
    }
    fn status_fields(&self) -> StatusFields<'_> {
        let mut fields = StatusFields::from_session(&self.target, &self.state);
        fields.note = &self.note;
        fields.connection = if self.online { "online" } else { "offline" };
        fields.online = self.online;
        fields.pending = self.job.is_some();
        fields.attachments = self.draft.attachments.len();
        if let Some(fe) = &self.draft.fork_edit {
            fields.fork_entry_id = Some(&fe.selected_entry_id);
            fields.fork_predecessor_id = Some(fe.predecessor_id);
        }
        fields.retry_pending = self.draft.retry.is_some();
        fields.historical = self.historical.is_some();
        fields.show_tools = self.tools;
        fields.theme = &self.config.theme.name;
        self.status_metadata.apply(&mut fields, &self.state);
        fields.show_thinking = self.thinking;
        fields
    }
    fn update(&mut self, u: Update) {
        match u {
            Update::Online => {
                self.online = true;
                self.note = "Connected · /help".into();
            }
            Update::Offline(msg) => {
                self.online = false;
                self.note = msg;
            }
            Update::Frame(f) => {
                let previous_wait = self.state.workspace_wait();
                let previous_approvals = pending_approval_ids(&self.state);
                match f {
                    ServerFrame::Snapshot(s) => {
                        self.state.apply_snapshot(s);
                        if self.target.labels.is_imported_archive() {
                            self.note =
                                "Imported archive (read-only) · use /cwd <path> to fork".into();
                        } else if self.target.labels.archived && !self.target.labels.cwd_exists {
                            self.note =
                                "Archived [missing cwd] — use /cwd <path> to fork into an existing directory"
                                    .into();
                        } else if self.target.labels.archived {
                            self.note =
                                "Archived (unloaded) · send a message or /archive off to resume"
                                    .into();
                        } else if !self.target.labels.cwd_exists {
                            self.note =
                                "Missing cwd — use /cwd <path> to fork into an existing directory"
                                    .into();
                        } else {
                            self.note = "Ready · /help".into();
                        }
                        if let Some(pending) = self.pending_tree_fork_edit.take() {
                            if pending.source_sid == self.target.sid
                                && pending.target_cid == self.target.cid
                            {
                                self.begin_fork_edit(&pending.entry_id);
                            }
                        }
                    }
                    ServerFrame::Commit(c) => {
                        if self.state.apply_commit(c) == CommitOutcome::Gap {
                            self.sub = Some(Subscription::start(
                                self.client.clone(),
                                self.target.sid.clone(),
                                self.target.cid.clone(),
                                None,
                            ));
                            self.online = false;
                            self.note = "Resyncing".into();
                        }
                    }
                    ServerFrame::Ephemeral(e) => {
                        self.state.apply_ephemeral(e);
                    }
                    ServerFrame::Unknown { .. } => return,
                }
                if self.state.entries.len() > 256 {
                    let n = self.state.entries.len() - 256;
                    for e in self.state.entries.drain(..n) {
                        self.state.entry_ids.remove(&e.id);
                    }
                    self.state.before_entry_id = self.state.entries.first().map(|e| e.id.clone());
                    self.state.has_more = true;
                }
                let wait = self.state.workspace_wait();
                if wait != previous_wait {
                    if wait.is_some()
                        && self.picker.is_none()
                        && self.tree.is_none()
                        && self.login.is_none()
                        && self.secret.is_none()
                    {
                        self.workspace_wait_menu();
                    } else if self
                        .picker
                        .as_ref()
                        .is_some_and(|p| p.kind == PickerKind::WorkspaceWait)
                    {
                        self.picker = None;
                        if wait.is_some() {
                            self.workspace_wait_menu();
                        }
                    }
                }
                let approvals = pending_approvals(&self.state);
                let current_approval_ids: Vec<u64> = approvals.iter().map(|a| a.task_id).collect();
                if current_approval_ids != previous_approvals {
                    let has_new = current_approval_ids
                        .iter()
                        .any(|tid| !previous_approvals.contains(tid));
                    if has_new
                        && self.picker.is_none()
                        && self.tree.is_none()
                        && self.login.is_none()
                        && self.secret.is_none()
                    {
                        self.approval_menu();
                    } else if self
                        .picker
                        .as_ref()
                        .is_some_and(|p| p.kind == PickerKind::Approval)
                    {
                        self.picker = None;
                        if !approvals.is_empty() {
                            self.approval_menu();
                        }
                    }
                }
                self.rows_dirty |= self.historical.is_none();
            }
        }
    }
    fn workspace_wait_menu(&mut self) {
        if let Some(wait) = self.state.workspace_wait() {
            self.scoped_menu(
                PickerKind::WorkspaceWait,
                &format!(
                    "Workspace held by {}:{}",
                    wait.holder_session_id, wait.holder_conversation_id
                ),
                vec![
                    ("cancel".into(), "Cancel wait".into()),
                    ("stop_holder".into(), "Stop holder and acquire".into()),
                ],
            );
            self.picker.as_mut().unwrap().workspace_wait = Some(wait);
        } else {
            self.note = "Not waiting for a workspace".into();
        }
    }
    fn approval_menu(&mut self) {
        let approvals = pending_approvals(&self.state);
        if approvals.is_empty() {
            self.note = "No pending tool approvals".into();
            return;
        }
        let mut choices = Vec::with_capacity(approvals.len() * 2);
        for app in &approvals {
            let tool = sanitize_single_line(&app.tool_name);
            let tid = app.task_id;
            choices.push((format!("allow:{tid}"), format!("Approve {tool} (#{tid})")));
            choices.push((format!("deny:{tid}"), format!("Deny {tool} (#{tid})")));
        }
        let title = if approvals.len() == 1 {
            format!(
                "Tool approval · {} (#{})",
                sanitize_single_line(&approvals[0].tool_name),
                approvals[0].task_id
            )
        } else {
            format!("Tool approvals ({} pending)", approvals.len())
        };
        self.scoped_menu(PickerKind::Approval, &title, choices);
    }
    fn apply_theme_live(&mut self, name: &str) {
        match super::theme::Theme::from_name_in_dir(name, Some(&self.data_dir)) {
            Ok(theme) => {
                let applied = theme.name.clone();
                self.config.theme = theme;
                self.config_gen = self.config_gen.wrapping_add(1);
                self.rows_dirty = true;
                self.note = format!("Theme: {applied}");
            }
            Err(err) => {
                self.note = sanitize_single_line(&err);
            }
        }
    }
    fn handle_approval_command(&mut self, decision: &str, arg: &str) {
        let approvals = pending_approvals(&self.state);
        if arg.is_empty() {
            match approvals.as_slice() {
                [] => {
                    self.note = "No pending tool approvals".into();
                }
                [only] => {
                    self.start(
                        Effect::ApproveTool {
                            task_id: only.task_id,
                            decision: decision.to_string(),
                            reason: None,
                        },
                        None,
                    );
                }
                _ => {
                    self.approval_menu();
                }
            }
            return;
        }
        let mut parts = arg.splitn(2, char::is_whitespace);
        let first = parts.next().unwrap_or("");
        let rest = parts.next().map(str::trim).filter(|s| !s.is_empty());
        let clean_first = first.strip_prefix('#').unwrap_or(first);
        if let Some(tid) = clean_first.parse::<u64>().ok().filter(|&n| n > 0) {
            self.start(
                Effect::ApproveTool {
                    task_id: tid,
                    decision: decision.to_string(),
                    reason: rest.map(str::to_owned),
                },
                None,
            );
        } else if decision == "deny" {
            match approvals.as_slice() {
                [only] => {
                    self.start(
                        Effect::ApproveTool {
                            task_id: only.task_id,
                            decision: decision.to_string(),
                            reason: Some(arg.to_owned()),
                        },
                        None,
                    );
                }
                [] => {
                    self.note = "No pending tool approvals".into();
                }
                _ => {
                    self.note =
                        "Multiple pending approvals · specify task_id: /deny <task_id> [reason]"
                            .into();
                }
            }
        } else {
            self.note = "Usage: /approve [task_id]".into();
        }
    }
    fn menu(&mut self, kind: PickerKind, title: &str, choices: Vec<(String, String)>) {
        self.dismiss_completion();
        self.tree = None;
        self.picker = Some(PickerState {
            kind,
            picker: Picker::new(title, choices),
            scope: None,
            workspace_wait: None,
            tree_selection: None,
        });
    }
    fn scoped_menu(&mut self, kind: PickerKind, title: &str, choices: Vec<(String, String)>) {
        self.dismiss_completion();
        self.tree = None;
        self.picker = Some(PickerState {
            kind,
            picker: Picker::new(title, choices),
            scope: Some((self.target.sid.clone(), self.target.cid.clone())),
            workspace_wait: None,
            tree_selection: None,
        });
    }
    fn current_view(&self) -> &TranscriptState {
        self.historical.as_ref().unwrap_or(&self.state)
    }
    fn start(&mut self, effect: Effect, submitted: Option<(String, CommandEnvelope)>) {
        if self.job.is_some() {
            self.note = "Wait for pending command".into();
            return;
        }
        let (tx, result) = mpsc::sync_channel(1);
        let c = self.client.clone();
        let t = self.target.clone();
        let source_target = (t.sid.clone(), t.cid.clone());
        let seq = self.state.seq;
        thread::spawn(move || {
            let _ = tx.send(actions::execute(&c, &t, seq, effect));
        });
        self.job = Some(Job {
            result,
            submitted,
            source_target,
        });
    }
    fn complete(&mut self, screen: &mut Screen) -> bool {
        let Some(j) = &self.job else { return false };
        let r = match j.result.try_recv() {
            Ok(r) => r,
            Err(TryRecvError::Empty) => return false,
            Err(TryRecvError::Disconnected) => Err("Command worker disconnected".into()),
        };
        let source_target = j.source_target.clone();
        let submitted = self.job.take().and_then(|j| j.submitted);
        match r {
            Err(e) => {
                if self.pending_root_fork.as_ref().is_some_and(|r| {
                    r.source_sid == source_target.0 && r.source_cid == source_target.1
                }) {
                    self.pending_root_fork = None;
                }
                if self.pending_cwd_fork.as_ref().is_some_and(|r| {
                    r.source_sid == source_target.0 && r.source_cid == source_target.1
                }) {
                    self.pending_cwd_fork = None;
                }
                let is_cwd_missing = e.contains("cwd_missing");
                if is_cwd_missing && source_target.0 == self.target.sid {
                    self.target.labels.cwd_exists = false;
                    self.note = "Working directory no longer exists · use /cwd <path> to fork into an existing directory; draft retained".into();
                } else {
                    self.note = e.clone();
                }
                if let Some((text, envelope)) = submitted {
                    if self.draft.editor.text().is_empty() {
                        self.draft.editor.set(&text);
                    }
                    if self.draft.attachments.is_empty() && envelope.command != "user_shell" {
                        self.draft.attachments = extract_non_text_blocks(&envelope.args);
                    }
                    if !is_cwd_missing
                        && envelope.command != "user_shell"
                        && (envelope.command != "fork_and_submit" || is_ambiguous_submit_error(&e))
                    {
                        self.draft.retry = Some((text, envelope));
                        self.note.push_str(" · /retry uses same request");
                    }
                }
            }
            Ok(Reply::Tree(tree)) => {
                if source_target != (self.target.sid.clone(), self.target.cid.clone()) {
                    self.note = "Ignored stale tree after branch switch".into();
                } else {
                    self.dismiss_completion();
                    self.picker = None;
                    let selector = TreeSelector::new(*tree, &self.target.cid);
                    if selector.total_len() == 0 {
                        self.note = "No entries in this session yet".into();
                    } else {
                        self.tree = Some(TreeState {
                            selector,
                            scope: (self.target.sid.clone(), self.target.cid.clone()),
                        });
                    }
                }
            }
            Ok(Reply::Menu(title, items)) => {
                let kind = match title.as_str() {
                    "models" => PickerKind::Models,
                    "harnesses" => PickerKind::Harnesses,
                    "Codex sources" => PickerKind::LoginSources,
                    "Log out Codex account" => PickerKind::LogoutSources,
                    "Remove provider key" => PickerKind::KeyRemove,
                    "Select stock Codex account" => PickerKind::AccountSources,
                    "thinking" => PickerKind::Thinking,
                    "branches" => PickerKind::Branches,
                    "sessions" => PickerKind::Sessions,
                    "client files" => PickerKind::ClientFiles,
                    "workspace files" => PickerKind::WorkspaceFiles,
                    _ => PickerKind::Info,
                };
                let is_scoped = matches!(
                    kind,
                    PickerKind::Models
                        | PickerKind::Harnesses
                        | PickerKind::Thinking
                        | PickerKind::Branches
                        | PickerKind::WorkspaceFiles
                );
                if is_scoped && source_target != (self.target.sid.clone(), self.target.cid.clone())
                {
                    self.note = "Ignored stale picker after branch switch".into();
                } else if is_scoped {
                    self.scoped_menu(kind, &title, items);
                } else {
                    self.menu(kind, &title, items);
                }
            }
            Ok(Reply::Message(m)) => self.note = m,
            Ok(Reply::SessionName { title, note }) => {
                if source_target.0 == self.target.sid {
                    self.target.labels.title = title;
                    self.note = note;
                }
            }
            Ok(Reply::Attachment(path, block)) => {
                if self
                    .draft
                    .attachments
                    .iter()
                    .map(|b| b.to_string().len())
                    .sum::<usize>()
                    .saturating_add(block.to_string().len())
                    > 3_800_000
                {
                    self.note = "Attachment budget exceeded".into();
                } else {
                    self.draft.attachments.push(block);
                    self.note = format!("Attached client-local {path}");
                }
            }
            Ok(Reply::WorkspaceAttachment {
                path,
                env_id,
                truncated,
                block,
            }) => {
                if source_target != (self.target.sid.clone(), self.target.cid.clone()) {
                    self.note = "Ignored stale workspace file after session switch".into();
                } else if self
                    .draft
                    .attachments
                    .iter()
                    .map(|b| b.to_string().len())
                    .sum::<usize>()
                    .saturating_add(block.to_string().len())
                    > 3_800_000
                {
                    self.note = "Attachment budget exceeded".into();
                } else {
                    self.draft.attachments.push(block);
                    self.note = format!(
                        "Attached workspace ({}) {}{}",
                        sanitize_single_line(&env_id),
                        sanitize_single_line(&path),
                        if truncated { " (truncated)" } else { "" }
                    );
                }
            }
            Ok(Reply::Page(p)) => {
                let mut page = TranscriptState::default();
                page.prepend_older_page(p.items, p.next_cursor);
                self.historical = Some(page);
                self.rows_dirty = true;
                self.note = "Earlier page · /latest to follow".into();
                screen.bottom();
            }
            Ok(Reply::CatalogSession { session, note }) => {
                if let Some(inbox) = self.inbox.as_mut() {
                    inbox.state.apply(CatalogUpdate::Upsert(session.clone()));
                }
                if session.session_id == self.target.sid {
                    self.target.labels = super::actions::SessionLabels::from(session.as_ref());
                }
                self.note = note;
            }
            Ok(Reply::ArchivedCurrent { sid }) => {
                if self.entered_from_inbox {
                    self.enter_inbox();
                    self.note = format!("Archived {}", sanitize_single_line(&sid));
                } else {
                    self.quit = true;
                }
            }
            Ok(Reply::Target(t)) => {
                let root = self.pending_root_fork.take().filter(|r| {
                    r.source_sid == source_target.0
                        && r.source_cid == source_target.1
                        && r.source_sid == self.target.sid
                        && r.source_cid == self.target.cid
                });
                let cwd_fork = self.pending_cwd_fork.take().filter(|r| {
                    r.source_sid == source_target.0
                        && r.source_cid == source_target.1
                        && r.source_sid == self.target.sid
                        && r.source_cid == self.target.cid
                });
                let carry_draft = if cwd_fork.is_some()
                    && (!self.draft.editor.text().is_empty() || !self.draft.attachments.is_empty())
                {
                    let text = self.draft.editor.expanded_text();
                    let attachments = std::mem::take(&mut self.draft.attachments);
                    self.draft.editor.set("");
                    Some((text, attachments))
                } else {
                    None
                };
                self.switch(t, screen);
                if let Some(root) = root {
                    self.draft.editor.set(&root.text);
                    self.draft.attachments = root.attachments;
                    self.note = format!(
                        "New session {} for root prompt #{} (files unchanged) · Edit and submit",
                        sanitize_single_line(&self.target.sid),
                        sanitize_single_line(&root.entry_id)
                    );
                } else if cwd_fork.is_some() {
                    if let Some((text, attachments)) = carry_draft {
                        self.draft.editor.set(&text);
                        self.draft.attachments = attachments;
                    }
                    self.note = format!(
                        "Forked into {} ({})",
                        sanitize_single_line(&self.target.cwd),
                        sanitize_single_line(&self.target.sid)
                    );
                }
            }
            Ok(Reply::ForkSubmitted { target, receipt }) => {
                if source_target != (self.target.sid.clone(), self.target.cid.clone()) {
                    self.note = "Ignored stale fork-and-submit result after branch switch".into();
                    return true;
                }
                if let Some(fork_edit) = self.draft.fork_edit.take() {
                    if fork_edit.source_sid == self.target.sid
                        && fork_edit.source_cid == self.target.cid
                    {
                        self.draft = *fork_edit.stashed_draft;
                    }
                }
                if self
                    .draft
                    .retry
                    .as_ref()
                    .is_some_and(|(_, c)| c.request_id == receipt.request_id)
                {
                    self.draft.retry = None;
                }
                self.switch(target, screen);
                if self.target.labels.archived && !self.target.labels.is_imported_archive() {
                    self.target.labels.archived = false;
                }
                self.note = format!(
                    "Forked to #{} · {} · seq {}",
                    sanitize_single_line(&self.target.cid),
                    sanitize_single_line(receipt.status.as_deref().unwrap_or("placed")),
                    receipt.seq.unwrap_or_default()
                );
            }
            Ok(Reply::Receipt(r)) => {
                if self.target.labels.archived && !self.target.labels.is_imported_archive() {
                    self.target.labels.archived = false;
                }
                // Only the daemon can return queue items to a draft. Never fabricate a dequeue from a local inbox snapshot.
                for item in &r.withdrawn {
                    if let Some(blocks) = item.get("content").and_then(Value::as_array) {
                        for b in blocks {
                            if b.get("type") == Some(&Value::String("text".into())) {
                                if let Some(t) = b.get("text").and_then(Value::as_str) {
                                    let sep = if self.draft.editor.text().is_empty() {
                                        ""
                                    } else {
                                        "\n"
                                    };
                                    self.dismiss_completion();
                                    self.draft.editor.set(&format!(
                                        "{}{sep}{t}",
                                        self.draft.editor.expanded_text()
                                    ));
                                }
                            } else {
                                self.draft.attachments.push(b.clone());
                            }
                        }
                    }
                }
                self.note = format!(
                    "{} · seq {}",
                    r.status.as_deref().unwrap_or("accepted"),
                    r.seq.unwrap_or_default()
                );
                if self
                    .draft
                    .retry
                    .as_ref()
                    .is_some_and(|(_, c)| c.request_id == r.request_id)
                {
                    self.draft.retry = None;
                }
            }
        }
        true
    }
    fn switch(&mut self, t: Target, screen: &mut Screen) {
        self.dismiss_completion();
        if let Some(prev_inbox) = self.inbox.take() {
            self.entered_from_inbox = true;
            self.catalog_sub = Some(prev_inbox.sub);
        } else if !self.target.sid.is_empty() {
            let key = (self.target.sid.clone(), self.target.cid.clone());
            self.saved.insert(key, std::mem::take(&mut self.draft));
        }
        self.draft = self
            .saved
            .remove(&(t.sid.clone(), t.cid.clone()))
            .unwrap_or_default();
        if self.picker.as_ref().is_some_and(|p| p.scope.is_some()) {
            self.picker = None;
        }
        self.tree = None;
        self.pending_root_fork = None;
        self.pending_cwd_fork = None;
        if self
            .pending_tree_fork_edit
            .as_ref()
            .is_some_and(|p| p.source_sid != t.sid || p.target_cid != t.cid)
        {
            self.pending_tree_fork_edit = None;
        }
        self.historical = None;
        self.state = TranscriptState::new(Some(t.sid.clone()), Some(t.cid.clone()));
        self.sub = Some(Subscription::start(
            self.client.clone(),
            t.sid.clone(),
            t.cid.clone(),
            None,
        ));
        self.target = t;
        self.online = false;
        self.rows_dirty = true;
        self.note = if self.target.labels.is_imported_archive() {
            "Connecting (imported archive · read-only)".into()
        } else if self.target.labels.archived && !self.target.labels.cwd_exists {
            "Connecting [archived · missing cwd — use /cwd <path> to fork]".into()
        } else if self.target.labels.archived {
            "Connecting (archived · unloaded)".into()
        } else if !self.target.labels.cwd_exists {
            "Connecting [missing cwd — use /cwd <path> to fork into an existing directory]".into()
        } else {
            "Connecting".into()
        };
        screen.bottom();
    }
    fn check_writable_workspace(&mut self, retain_draft: bool) -> bool {
        let suffix = if retain_draft { "; draft retained" } else { "" };
        if self.target.labels.is_imported_archive() {
            self.note = format!(
                "Imported archive is read-only · use /cwd <path> to fork into a live workspace{suffix}"
            );
            return false;
        }
        if !self.target.labels.cwd_exists {
            self.note = format!(
                "Working directory no longer exists · use /cwd <path> to fork into an existing directory{suffix}"
            );
            return false;
        }
        true
    }
    fn send(&mut self, follow: bool) {
        if !self.check_writable_workspace(true) {
            return;
        }
        if !self.online || self.state.seq.is_none() {
            self.note = "Not synchronized; draft retained".into();
            return;
        }
        if self.draft.retry.is_some() {
            self.note = "Resolve previous submit: /retry or /discard-retry".into();
            return;
        }
        let text = self.draft.editor.expanded_text();
        if let Some((include_in_context, shell_cmd)) = parse_user_shell_input(&text) {
            if shell_cmd.is_empty() {
                self.note = "Enter a shell command after ! or !!; draft retained".into();
                return;
            }
            if self.draft.fork_edit.is_some() {
                self.note =
                    "Cancel fork-edit (Esc) before running a shell command; draft retained".into();
                return;
            }
            if self.target.env_id.trim().is_empty()
                || self.target.cwd.trim().is_empty()
                || !self.target.cwd.starts_with('/')
            {
                self.note = "Workspace not bound; shell command not sent, draft retained".into();
                return;
            }
            let Ok(cid) = self.target.cid.parse() else {
                self.note = "Invalid conversation ID".into();
                return;
            };
            if self.job.is_some() {
                self.note = "Previous command pending; draft retained".into();
                return;
            }
            let marker = CommandEnvelope {
                version: 1,
                request_id: String::new(),
                command: "user_shell".to_string(),
                conversation_id: cid,
                args: Value::Null,
            };
            self.start(
                Effect::UserShell {
                    command: shell_cmd.to_string(),
                    include_in_context,
                },
                Some((text, marker)),
            );
            self.draft.editor.submitted();
            return;
        }
        if text.trim().is_empty() && self.draft.attachments.is_empty() {
            return;
        }
        let Ok(cid) = self.target.cid.parse() else {
            self.note = "Invalid conversation ID".into();
            return;
        };
        let when_busy = if follow {
            WhenBusy::FollowUp
        } else {
            WhenBusy::Steer
        };
        let (mut cmd, is_fork_submit) = if let Some(fork_edit) = self.draft.fork_edit.as_ref() {
            if fork_edit.source_sid != self.target.sid || fork_edit.source_cid != self.target.cid {
                self.note = "Fork target no longer matches active branch; draft retained".into();
                return;
            }
            (
                CommandEnvelope::fork_and_submit(
                    generate_request_id(),
                    cid,
                    fork_edit.predecessor_id,
                    text.clone(),
                    when_busy,
                    WhenIdle::Start,
                ),
                true,
            )
        } else {
            (
                CommandEnvelope::submit_input(
                    generate_request_id(),
                    cid,
                    text.clone(),
                    when_busy,
                    WhenIdle::Start,
                ),
                false,
            )
        };
        if let Some(blocks) = cmd.args["content"].as_array_mut() {
            blocks.extend(self.draft.attachments.iter().cloned());
        }
        if self.job.is_some() {
            self.note = "Previous command pending; draft retained".into();
            return;
        }
        if serde_json::to_vec(&cmd)
            .map_or(true, |body| body.len() > super::files::MAX_API_JSON_BYTES)
        {
            self.note = "Prompt + attachments exceed daemon JSON limit; draft retained".into();
            return;
        }
        let effect = if is_fork_submit {
            Effect::ForkAndSubmit(cmd.clone())
        } else {
            Effect::Submit(cmd.clone())
        };
        self.start(effect, Some((text, cmd)));
        self.draft.editor.submitted();
        self.draft.attachments.clear();
    }
    fn entries(&self) -> Vec<(String, String)> {
        self.current_view()
            .entries
            .iter()
            .rev()
            .map(|e| {
                let preview = if e.kind == "user_shell" {
                    let cmd = e.data.get("command").and_then(Value::as_str).unwrap_or("");
                    let include = e
                        .data
                        .get("include_in_context")
                        .and_then(Value::as_bool)
                        .unwrap_or(true);
                    let prefix = if include { "!" } else { "!!" };
                    format!("{prefix}{cmd}")
                } else {
                    extract_entry_text(&e.data)
                };
                (
                    e.id.clone(),
                    format!(
                        "#{} {} {}",
                        e.id,
                        e.kind,
                        sanitize_single_line(&preview)
                            .chars()
                            .take(140)
                            .collect::<String>()
                    ),
                )
            })
            .collect()
    }
    fn fork_candidates(&self) -> Vec<(String, String)> {
        let view = self.current_view();
        view.entries
            .iter()
            .enumerate()
            .rev()
            .filter_map(|(idx, e)| {
                if e.kind != "user" {
                    return None;
                }
                let text = extract_entry_text(&e.data);
                let attachments = extract_entry_attachments(&e.data);
                if text.is_empty() && attachments.is_empty() {
                    return None;
                }
                let tag = if idx > 0 {
                    format!(
                        "fork @ #{}",
                        sanitize_single_line(&view.entries[idx - 1].id)
                    )
                } else if !view.has_more && view.before_entry_id.is_none() {
                    "root · new session".to_string()
                } else {
                    "load /earlier".to_string()
                };
                let preview = if text.is_empty() {
                    "[attachment]".to_string()
                } else {
                    sanitize_single_line(&text).chars().take(120).collect()
                };
                Some((e.id.clone(), format!("#{} [{tag}] {preview}", e.id)))
            })
            .collect()
    }
    fn begin_fork_edit(&mut self, entry_id: &str) {
        if self.job.is_some() {
            self.note = "Wait for pending command".into();
            return;
        }
        if self.draft.retry.is_some() {
            self.note = "Resolve previous submit (/retry or /discard-retry) before /fork".into();
            return;
        }
        let view = self.current_view();
        let resolved = match resolve_fork_target(view, entry_id) {
            Ok(r) => r,
            Err(msg) => {
                self.note = msg;
                return;
            }
        };
        match resolved {
            ForkResolution::Predecessor {
                selected_id,
                predecessor_id,
                text,
                attachments,
            } => {
                let stashed_draft = match self.draft.fork_edit.take() {
                    Some(existing) => existing.stashed_draft,
                    None => Box::new(std::mem::take(&mut self.draft)),
                };
                self.draft = Draft::default();
                self.draft.editor.set(&text);
                self.draft.attachments = attachments;
                self.draft.fork_edit = Some(ForkEdit {
                    source_sid: self.target.sid.clone(),
                    source_cid: self.target.cid.clone(),
                    selected_entry_id: selected_id.clone(),
                    predecessor_id,
                    stashed_draft,
                });
                self.note =
                    format!("Editing #{selected_id} (will fork at #{predecessor_id}; Esc cancels)");
            }
            ForkResolution::RootPrompt {
                selected_id,
                text,
                attachments,
            } => {
                self.pending_root_fork = Some(PendingRootFork {
                    source_sid: self.target.sid.clone(),
                    source_cid: self.target.cid.clone(),
                    entry_id: selected_id.clone(),
                    text,
                    attachments,
                });
                self.scoped_menu(
                    PickerKind::RootFork,
                    &format!("Root prompt #{selected_id} has no predecessor"),
                    vec![
                        (
                            "new_session".to_string(),
                            "Start new session with this prompt (keeps old session & files)"
                                .to_string(),
                        ),
                        (
                            "cancel".to_string(),
                            "Cancel (stay here and keep current draft)".to_string(),
                        ),
                    ],
                );
            }
        }
    }
    fn cancel_fork_edit(&mut self) {
        if let Some(fork_edit) = self.draft.fork_edit.take() {
            self.draft = *fork_edit.stashed_draft;
            self.note = format!(
                "Cancelled fork-edit of #{}; draft restored",
                sanitize_single_line(&fork_edit.selected_entry_id)
            );
        }
    }
    fn secret_key(&mut self, key: KeyEvent) {
        if key.code == KeyCode::Esc
            || (key.code == KeyCode::Char('c') && key.modifiers.contains(Mod::CONTROL))
        {
            self.secret = None;
            self.note = "API-key entry cancelled".into();
        } else if self.secret.as_mut().is_some_and(|secret| secret.key(key)) {
            let mut input = self.secret.take().expect("secret input is open");
            let key = input.take();
            let c = self.client.clone();
            let (tx, result) = mpsc::sync_channel(1);
            thread::spawn(move || {
                let saved = c
                    .set_api_key(&input.provider, &input.source, &key)
                    .map(|_| {
                        Reply::Message(format!(
                            "Saved {} key {} · use /key use to switch aliases",
                            input.provider, input.source
                        ))
                    })
                    .map_err(|err| err.to_string());
                let _ = tx.send(saved);
            });
            self.job = Some(Job {
                result,
                submitted: None,
                source_target: (self.target.sid.clone(), self.target.cid.clone()),
            });
            self.note = "Saving API key…".into();
        }
    }
    fn key(&mut self, k: KeyEvent, screen: &mut Screen) {
        let action = self.config.keys.action(k);
        if action != Some("clear") {
            self.last_clear = None;
        }
        if k.code == KeyCode::Esc && k.modifiers.is_empty() {
            if self.completion.is_some() {
                self.draft.editor.cancel_completion();
                self.dismiss_completion();
                return;
            }
            if self
                .path_lookup
                .as_mut()
                .is_some_and(|lookup| lookup.token.take().is_some())
            {
                return;
            }
        }
        if k.code == KeyCode::Tab && k.modifiers.is_empty() && action.is_none() {
            self.tab();
            return;
        }
        if k.code == KeyCode::Right
            && k.modifiers.is_empty()
            && action.is_none()
            && self.completion.is_some()
        {
            self.dismiss_completion();
            return;
        }
        self.dismiss_completion();
        match action {
            Some("interrupt") => {
                if self.draft.fork_edit.is_some() && self.job.is_none() {
                    self.cancel_fork_edit();
                } else if self.draft.fork_edit.is_some() {
                    self.note = "Wait for pending fork-edit command".into();
                } else if self.state.is_run_active() {
                    self.start(
                        Effect::Abort {
                            task_id: None,
                            reason: None,
                        },
                        None,
                    );
                }
            }
            Some("clear") => {
                if self
                    .last_clear
                    .is_some_and(|t| t.elapsed() < Duration::from_secs(2))
                {
                    self.quit = true;
                } else {
                    self.draft.editor.set("");
                    self.draft.attachments.clear();
                    if self.job.is_none() {
                        self.draft.fork_edit = None;
                    }
                    self.note = "Press Ctrl-C again to detach".into();
                    self.last_clear = Some(Instant::now());
                }
            }
            Some("exit") if self.draft.editor.text().is_empty() => {
                if self.entered_from_inbox {
                    self.enter_inbox();
                } else {
                    self.quit = true;
                }
            }
            Some("inbox") => self.enter_inbox(),
            Some("tools") => {
                self.tools = !self.tools;
                self.rows_dirty = true;
            }
            Some("thinking") => {
                self.thinking = !self.thinking;
                self.rows_dirty = true;
            }
            Some("copy") => self.copy(),
            Some("model") => self.start(Effect::Models, None),
            Some("palette") if k.code == KeyCode::Char('/') && k.modifiers.is_empty() => {
                self.draft.editor.key(k);
            }
            Some("palette") => self.palette(),
            Some("search") => self.scoped_menu(PickerKind::Search, "search", self.entries()),
            Some("dequeue") => self.withdraw(),
            Some("follow_up") => self.send(true),
            Some("submit") => {
                let text = self.draft.editor.text().to_owned();
                if text.starts_with('/') && !text.contains('\n') {
                    self.draft.editor.set("");
                    self.command(&text);
                } else {
                    self.send(false);
                }
            }
            _ => match k.code {
                KeyCode::Char('p' | 'P') if k.modifiers == Mod::ALT => {
                    self.jump_to_parent();
                }
                KeyCode::PageUp => screen.scroll(10),
                KeyCode::PageDown => screen.scroll(-10),
                KeyCode::End if k.modifiers == Mod::CONTROL => screen.bottom(),
                _ => {
                    self.draft.editor.key(k);
                }
            },
        }
    }
    fn dismiss_completion(&mut self) {
        self.completion = None;
        self.draft.editor.finish_completion();
        if let Some(lookup) = &mut self.path_lookup {
            lookup.token = None;
        }
    }
    fn tab(&mut self) {
        if let Some(completion) = &mut self.completion {
            if let Some(directory) = completion.sole_directory() {
                let is_cwd = self.draft.editor.text().starts_with("/cwd ");
                self.dismiss_completion();
                if is_cwd {
                    self.start_cwd_path_lookup(directory);
                } else {
                    self.start_path_lookup(directory);
                }
            } else {
                completion.cycle(&mut self.draft.editor);
            }
            return;
        }
        let editor = &self.draft.editor;
        let text = editor.text();
        if let Some(prefix) = text[..editor.cursor()].strip_prefix("/attach ") {
            let prefix = prefix.trim().to_owned();
            self.file_menu(&prefix);
        } else if let Some(prefix) = text[..editor.cursor()].strip_prefix('@') {
            let prefix = prefix.to_owned();
            self.workspace_file_menu(&prefix);
        } else if text[..editor.cursor()].starts_with("/cwd ") {
            if let Some(token) = Token::at_cursor(editor) {
                self.start_cwd_path_lookup(token);
            }
        } else if let Some(token) = Token::at_cursor(editor) {
            if token.is_command(editor) {
                let prefix = token.prefix(editor);
                let mut choices: Vec<(String, String)> = COMMANDS
                    .iter()
                    .filter(|(name, _)| name.starts_with(prefix))
                    .map(|(name, desc)| (name.to_string(), format!("{name}  {desc}")))
                    .collect();
                for prompt in &self.prompts {
                    let slash = format!("/prompt:{}", prompt.name);
                    if slash.starts_with(prefix) {
                        let label =
                            format!("{slash}  {}", sanitize_single_line(&prompt.description));
                        choices.push((slash, label));
                    }
                }
                self.completion =
                    Completion::start(&mut self.draft.editor, token, "Commands", choices);
            } else {
                self.start_path_lookup(token);
            }
        }
    }
    fn start_cwd_path_lookup(&mut self, token: Token) {
        if self.path_lookup.is_some() {
            return;
        }
        let prefix = token.prefix(&self.draft.editor).to_owned();
        let env_id = if self.target.env_id.trim().is_empty() {
            "host".to_string()
        } else {
            self.target.env_id.clone()
        };
        let fallback_cwd = if self.target.labels.cwd_exists && self.target.cwd.starts_with('/') {
            self.target.cwd.clone()
        } else {
            self.launch_cwd.clone()
        };
        let (tx, result) = mpsc::sync_channel(1);
        let client = self.client.clone();
        thread::spawn(move || {
            let _ = tx.send(completion::directories(
                &client,
                &env_id,
                &fallback_cwd,
                &prefix,
            ));
        });
        self.path_lookup = Some(PathLookup {
            token: Some(token),
            result,
        });
    }
    fn start_path_lookup(&mut self, token: Token) {
        // Keep only one bounded read in flight. Dismissing it invalidates the
        // token, so a late response cannot edit a newer draft or another target.
        if self.path_lookup.is_some() {
            return;
        }
        let editor = &self.draft.editor;
        let prefix = token.prefix(editor).to_owned();
        let text = editor.text();
        let shell = parse_user_shell_input(text).is_some()
            || ["/steer ", "/follow-up "].iter().any(|cmd| {
                text.strip_prefix(cmd)
                    .and_then(parse_user_shell_input)
                    .is_some()
            });
        let (tx, result) = mpsc::sync_channel(1);
        let client = self.client.clone();
        let target = self.target.clone();
        thread::spawn(move || {
            let _ = tx.send(completion::paths(&client, &target, &prefix, shell));
        });
        self.path_lookup = Some(PathLookup {
            token: Some(token),
            result,
        });
    }
    fn complete_path_lookup(&mut self) -> bool {
        let Some(lookup) = &mut self.path_lookup else {
            return false;
        };
        let result = match lookup.result.try_recv() {
            Ok(r) => r,
            Err(TryRecvError::Empty) => return false,
            Err(TryRecvError::Disconnected) => Err(ClientError::Io(
                "Path completion worker disconnected".into(),
            )),
        };
        let token = lookup.token.take();
        self.path_lookup = None;
        let Some(token) = token else { return false };
        match result {
            Ok(choices) => {
                self.completion =
                    Completion::start(&mut self.draft.editor, token, "Paths", choices);
                self.completion.is_some()
            }
            Err(err) => {
                self.note = format!("Path completion: {err}");
                true
            }
        }
    }
    fn palette(&mut self) {
        self.menu(
            PickerKind::Commands,
            "commands",
            COMMANDS
                .iter()
                .map(|(k, d)| (k.to_string(), format!("{k}  {d}")))
                .collect(),
        );
    }
    fn command(&mut self, text: &str) {
        let (cmd, arg) = text
            .split_once(' ')
            .map(|(a, b)| (a, b.trim()))
            .unwrap_or((text, ""));
        match cmd {
            "/" | "/help" => self.palette(),
            "/restart-ui" => {
                let pending = |draft: &Draft| {
                    !draft.editor.text().is_empty()
                        || !draft.attachments.is_empty()
                        || draft.retry.is_some()
                        || draft.fork_edit.is_some()
                };
                if self.job.is_some()
                    || self.login.is_some()
                    || pending(&self.draft)
                    || self.saved.values().any(pending)
                {
                    self.note =
                        "Save or clear drafts and finish pending commands before restarting hi"
                            .into();
                } else if !self.online || self.state.seq.is_none() {
                    self.note = "Reconnect before restarting hi".into();
                } else {
                    use std::os::unix::fs::PermissionsExt;
                    let candidate = if arg.is_empty() {
                        std::env::current_exe()
                    } else {
                        Path::new(arg).canonicalize()
                    };
                    match candidate {
                        Ok(path)
                            if path.metadata().is_ok_and(|m| {
                                m.is_file() && m.permissions().mode() & 0o111 != 0
                            }) =>
                        {
                            self.restart_ui = Some(path);
                            self.quit = true;
                        }
                        _ => self.note = "No executable hi candidate at that path".into(),
                    }
                }
            }
            "/quit" | "/exit" => self.quit = true,
            "/hotkeys" => self.menu(
                PickerKind::Info,
                "shortcuts",
                self.config
                    .keys
                    .help()
                    .into_iter()
                    .map(|s| (String::new(), s))
                    .collect(),
            ),
            "/account" if arg.is_empty() => self.start(Effect::AccountSources, None),
            "/account" if arg.starts_with("add ") && login::source_id(arg[4..].trim()) => {
                self.start(Effect::AddAccount(arg[4..].trim().into()), None)
            }
            "/account" if login::source_id(arg) => {
                self.start(Effect::ActivateAccount(arg.into()), None)
            }
            "/account" => self.note = "Usage: /account [source] or /account add <source>".into(),
            "/key" => {
                let parts: Vec<_> = arg.split_whitespace().take(4).collect();
                match parts.as_slice() {
                    [] | ["list"] => self.start(Effect::KeyProfiles, None),
                    ["set", provider, source] if login::source_id(provider) && login::source_id(source) => {
                        if self.job.is_some() { self.note = "Wait for pending command".into(); }
                        else { self.secret = Some(SecretInput::new(provider, source)); }
                    }
                    ["use", provider, source] if login::source_id(provider) && login::source_id(source) => {
                        self.start(Effect::UseKey((*provider).into(), (*source).into()), None);
                    }
                    ["remove"] => self.start(Effect::KeyRemoveProfiles, None),
                    ["remove", provider, source]
                        if login::source_id(provider) && login::source_id(source) =>
                    {
                        self.start(Effect::RemoveKey((*provider).into(), (*source).into()), None);
                    }
                    _ => self.note = "Usage: /key list | /key set <provider> <alias> | /key use <provider> <alias> | /key remove [<provider> <alias>] (never include the key here)".into(),
                }
            }
            "/logout" if arg.is_empty() => self.start(Effect::LogoutSources, None),
            "/logout" if login::source_id(arg) => {
                self.start(Effect::RemoveCodexAccount(arg.into()), None)
            }
            "/logout" => self.note = "Usage: /logout [source]".into(),
            "/login" => {
                let parts: Vec<_> = arg.split_whitespace().take(3).collect();
                match parts.as_slice() {
                    [] | ["openai_codex" | "openai-codex"] => {
                        self.start(Effect::LoginSources, None)
                    }
                    ["openai_codex" | "openai-codex", source] if login::source_id(source) => {
                        self.login = Some(Login::start(self.client.clone(), (*source).into()));
                    }
                    _ => self.note = "Usage: /login [openai_codex [source]]".into(),
                }
            }
            "/reload" => {
                self.prompts = prompts::discover_prompts(&self.data_dir);
                let candidate = UserConfig::load(&self.data_dir).and_then(|config| {
                    config.status.validate(&self.status_fields())?;
                    Ok(config)
                });
                match candidate {
                    Ok(config) => {
                        self.config = config;
                        self.config_gen = self.config_gen.wrapping_add(1);
                        self.rows_dirty = true;
                        self.note = "Hi configuration reloaded".into();
                    }
                    Err(err) => {
                        self.note = format!("Reload failed: {err}");
                        // Keep failures visible even if a custom footer omits `note`.
                        self.menu(
                            PickerKind::Info,
                            "reload failed (config unchanged)",
                            vec![(String::new(), err)],
                        );
                    }
                }
            }
            "/theme" => {
                if arg.is_empty() {
                    let current = self.config.theme.name.as_str();
                    let choices = super::theme::Theme::available_themes(&self.data_dir)
                        .into_iter()
                        .map(|name| {
                            let label = if name == current {
                                format!("* {name}")
                            } else {
                                name.clone()
                            };
                            (name, label)
                        })
                        .collect();
                    self.menu(PickerKind::Themes, "themes", choices);
                } else {
                    self.apply_theme_live(arg);
                }
            }
            "/prompts" => {
                self.prompts = prompts::discover_prompts(&self.data_dir);
                if self.prompts.is_empty() {
                    self.note = format!(
                        "No prompt templates in {}/prompts/*.md",
                        self.data_dir.display()
                    );
                } else {
                    let choices = self
                        .prompts
                        .iter()
                        .map(|p| {
                            (
                                p.name.clone(),
                                format!(
                                    "/prompt:{}  {}",
                                    p.name,
                                    sanitize_single_line(&p.description)
                                ),
                            )
                        })
                        .collect();
                    self.menu(PickerKind::Prompts, "prompts", choices);
                }
            }
            "/harness" if arg.is_empty() => self.start(Effect::Harnesses, None),
            "/harness" => {
                if arg.split_whitespace().count() > 1 {
                    self.note = "Usage: /harness [id]".into();
                } else {
                    self.start(Effect::NewWithHarness(arg.to_owned()), None);
                }
            }
            "/session" | "/status" => {
                self.note = format!(
                    "{}:{} · {} · env={}",
                    self.target.sid, self.target.cid, self.target.cwd, self.target.env_id
                )
            }
            "/tools" => {
                self.tools = !self.tools;
                self.rows_dirty = true;
            }
            "/thoughts" => {
                self.thinking = !self.thinking;
                self.rows_dirty = true;
            }
            "/inbox" => self.enter_inbox(),
            "/parent" => self.jump_to_parent(),
            "/cwd" if arg.is_empty() => {
                let status = if self.target.labels.is_imported_archive() {
                    " (imported archive — use /cwd <existing-dir> to fork session)"
                } else if !self.target.labels.cwd_exists {
                    " (missing — use /cwd <existing-dir> to fork session)"
                } else if self.target.labels.archived {
                    " (archived)"
                } else {
                    ""
                };
                self.note = format!(
                    "Workspace: {}:{}{status}",
                    sanitize_single_line(&self.target.env_id),
                    sanitize_single_line(&self.target.cwd)
                );
            }
            "/cwd" => {
                if self.job.is_some() {
                    self.note = "Wait for pending command".into();
                    return;
                }
                let base_cwd = if self.target.labels.cwd_exists && self.target.cwd.starts_with('/')
                {
                    self.target.cwd.as_str()
                } else {
                    self.launch_cwd.as_str()
                };
                let resolved = resolve_cwd_input(arg, &self.target.env_id, base_cwd);
                match resolved {
                    Ok(cwd) => {
                        self.pending_cwd_fork = Some(PendingCwdFork {
                            source_sid: self.target.sid.clone(),
                            source_cid: self.target.cid.clone(),
                        });
                        self.note = format!("Forking session into {}…", sanitize_single_line(&cwd));
                        self.start(Effect::ForkSessionCwd { cwd }, None);
                    }
                    Err(msg) => {
                        self.note = msg;
                    }
                }
            }
            "/attention" => {
                if self.target.labels.status.as_deref() == Some("archived") {
                    self.note = "Imported archives are read-only".into();
                    return;
                }
                let next_val = match arg.to_ascii_lowercase().as_str() {
                    "" => !self.target.labels.needs_attention,
                    "on" | "true" | "yes" | "1" => true,
                    "off" | "false" | "no" | "0" => false,
                    _ => {
                        self.note = "Usage: /attention [on|off]".into();
                        return;
                    }
                };
                self.start(
                    Effect::TriageSession {
                        sid: self.target.sid.clone(),
                        needs_attention: next_val,
                    },
                    None,
                );
            }
            "/archive" => {
                if self.target.labels.is_imported_archive() {
                    self.note = "Imported archives are read-only".into();
                    return;
                }
                match arg.to_ascii_lowercase().as_str() {
                    "off" | "false" | "unarchive" | "restore" => {
                        if !self.target.labels.archived {
                            self.note = "Session is already active (not archived)".into();
                            return;
                        }
                        self.note =
                            format!("Unarchiving {}…", sanitize_single_line(&self.target.sid));
                        self.start(
                            Effect::ArchiveSession {
                                sid: self.target.sid.clone(),
                                archived: false,
                                stop: false,
                            },
                            None,
                        );
                    }
                    "" | "on" | "true" => {
                        if self.target.labels.archived {
                            self.note =
                                "Session is already archived · use /archive off to restore or send a message to resume"
                                    .into();
                            return;
                        }
                        self.note = "Archiving session…".into();
                        self.start(Effect::ArchiveCurrent { stop: false }, None);
                    }
                    "force" | "stop" => {
                        self.note = "Stopping & archiving session…".into();
                        self.start(Effect::ArchiveCurrent { stop: true }, None);
                    }
                    _ => {
                        self.note = "Usage: /archive [force|off]".into();
                    }
                }
            }
            "/stop" => {
                if self.target.labels.status.as_deref() == Some("archived") {
                    self.note = "Imported archives are read-only".into();
                    return;
                }
                self.note = format!("Stopping {}…", sanitize_single_line(&self.target.sid));
                self.start(
                    Effect::StopSession {
                        sid: self.target.sid.clone(),
                    },
                    None,
                );
            }
            "/resume" | "/sessions" => self.start(Effect::Sessions, None),
            "/new" => {
                self.pending_root_fork = None;
                self.start(Effect::New, None);
            }
            "/name" if arg.is_empty() => self.start(Effect::ReadName, None),
            "/name" => {
                if self.state.seq.is_none() {
                    self.note = "Not synchronized; wait for snapshot before /name".into();
                } else {
                    self.start(Effect::Rename(Some(arg.to_owned())), None);
                }
            }
            "/tree" => self.start(Effect::Tree, None),
            "/branches" => self.start(Effect::Branches, None),
            "/conv" if arg.parse::<u64>().is_ok() => {
                self.start(Effect::Branch(arg.to_owned()), None)
            }
            "/fork" if arg.is_empty() => {
                if self.draft.retry.is_some() {
                    self.note =
                        "Resolve previous submit (/retry or /discard-retry) before /fork".into();
                } else {
                    let candidates = self.fork_candidates();
                    if candidates.is_empty() {
                        self.note = "No user prompts to fork from".into();
                    } else {
                        self.scoped_menu(PickerKind::Fork, "fork", candidates);
                    }
                }
            }
            "/fork" if arg.eq_ignore_ascii_case("cancel") => {
                if self.draft.fork_edit.is_some() && self.job.is_none() {
                    self.cancel_fork_edit();
                } else if self.draft.fork_edit.is_some() {
                    self.note = "Wait for pending fork-edit command".into();
                } else {
                    self.note = "No active fork-edit to cancel".into();
                }
            }
            "/fork" => {
                let clean_id = arg.strip_prefix('#').unwrap_or(arg).trim();
                if clean_id.parse::<u64>().is_ok_and(|n| n > 0) {
                    self.begin_fork_edit(clean_id);
                } else {
                    self.note = "Usage: /fork [<user_entry_id> | cancel]".into();
                }
            }
            "/branch" if arg.is_empty() => {
                let entries = self.entries();
                if entries.is_empty() {
                    self.note = "No visible entries to branch from".into();
                } else {
                    self.scoped_menu(PickerKind::Branch, "branch", entries);
                }
            }
            "/branch" => {
                let clean_id = arg.strip_prefix('#').unwrap_or(arg).trim();
                if let Some(id) = clean_id.parse::<u64>().ok().filter(|&n| n > 0) {
                    self.start(Effect::Fork(id), None);
                } else {
                    self.note = "Usage: /branch [<entry_id>]".into();
                }
            }
            "/model" if arg.is_empty() => self.start(Effect::Models, None),
            "/model" => self.start(Effect::Configure("model".into(), arg.into()), None),
            "/thinking" if arg.is_empty() => self.scoped_menu(
                PickerKind::Thinking,
                "thinking",
                ["off", "minimal", "low", "medium", "high"]
                    .into_iter()
                    .map(|s| (s.into(), s.into()))
                    .collect(),
            ),
            "/thinking" => self.start(Effect::Configure("thinking".into(), arg.into()), None),
            "/search" => self.scoped_menu(PickerKind::Search, "search", self.entries()),
            "/latest" => {
                self.historical = None;
                self.rows_dirty = true;
                self.note = "Following live transcript".into();
            }
            "/earlier" => {
                if let Some(c) = self
                    .historical
                    .as_ref()
                    .unwrap_or(&self.state)
                    .before_entry_id
                    .clone()
                {
                    self.start(Effect::Earlier(c), None);
                } else {
                    self.note = "No earlier history".into();
                }
            }
            "/envs" => self.start(Effect::Environments, None),
            "/abort" => {
                if arg.is_empty() {
                    self.start(
                        Effect::Abort {
                            task_id: None,
                            reason: None,
                        },
                        None,
                    );
                } else {
                    let mut parts = arg.splitn(2, char::is_whitespace);
                    let first = parts.next().unwrap_or("");
                    let rest = parts.next().map(str::trim).filter(|s| !s.is_empty());
                    let clean_first = first.strip_prefix('#').unwrap_or(first);
                    if let Some(tid) = clean_first.parse::<u64>().ok().filter(|&n| n > 0) {
                        self.start(
                            Effect::Abort {
                                task_id: Some(tid),
                                reason: rest.map(str::to_owned),
                            },
                            None,
                        );
                    } else {
                        self.start(
                            Effect::Abort {
                                task_id: None,
                                reason: Some(arg.to_owned()),
                            },
                            None,
                        );
                    }
                }
            }
            "/approve" => self.handle_approval_command("allow", arg),
            "/deny" => self.handle_approval_command("deny", arg),
            "/approval" => {
                if arg.is_empty() {
                    let current = format_approval_policy(&self.state);
                    self.note = format!(
                        "Approval policy: {current} · Usage: /approval [never|mutating|<tool1,tool2>]"
                    );
                } else {
                    match parse_approval_policy(arg) {
                        Ok(policy) => self.start(Effect::ConfigureApproval(policy), None),
                        Err(msg) => self.note = msg,
                    }
                }
            }
            "/budget" => {
                if arg.is_empty() {
                    self.note = format_run_budget(&self.state);
                } else {
                    match parse_run_budget(arg) {
                        Ok(budget) => self.start(Effect::ConfigureBudget(budget), None),
                        Err(msg) => self.note = msg,
                    }
                }
            }
            "/workspace" => self.workspace_wait_menu(),
            "/continue" => {
                if self.check_writable_workspace(false) {
                    self.start(Effect::Continue, None);
                }
            }
            "/compact" => {
                if !self.check_writable_workspace(false) {
                    return;
                }
                if self.state.seq.is_none() {
                    self.note = "Not synchronized; wait for snapshot before /compact".into();
                } else {
                    let instructions = (!arg.is_empty()).then(|| arg.to_owned());
                    self.start(Effect::Compact(instructions), None);
                }
            }
            "/file" if arg.is_empty() => self.workspace_file_menu(""),
            "/file" => self.start(Effect::ReadWorkspaceFile(arg.to_owned()), None),
            "/files" => self.workspace_file_menu(arg),
            "/attach" if arg.is_empty() => self.file_menu(""),
            "/attach" => self.attach(arg),
            "/steer" | "/follow-up" => {
                self.draft.editor.set(arg);
                self.send(cmd == "/follow-up");
            }
            "/copy" => self.copy(),
            "/export" if arg.is_empty() => self.note = "Usage: /export <new local path>".into(),
            "/export" => {
                if let Some(e) = self.state.entries.last() {
                    self.start(
                        Effect::Export {
                            last: e.id.clone(),
                            path: arg.into(),
                        },
                        None,
                    );
                } else {
                    self.note = "Nothing to export".into();
                }
            }
            "/dequeue" => self.withdraw(),
            "/retry" => {
                if let Some((s, envelope)) = self.draft.retry.clone() {
                    let effect = if envelope.command == "fork_and_submit" {
                        Effect::ForkAndSubmit(envelope.clone())
                    } else {
                        Effect::Submit(envelope.clone())
                    };
                    self.start(effect, Some((s, envelope)));
                }
            }
            "/discard-retry" => {
                self.draft.retry = None;
                self.note = "Forgot retry envelope; check transcript before resubmitting".into();
            }
            _ => {
                if let Some(prompt_name) = cmd.strip_prefix("/prompt:") {
                    if let Some(tpl) = self.prompts.iter().find(|p| p.name == prompt_name).cloned()
                    {
                        let expanded = prompts::expand_prompt(&tpl.body, arg);
                        self.draft.editor.set(&expanded);
                        self.send(false);
                    } else {
                        self.note = format!(
                            "Unknown prompt template /prompt:{} · /prompts",
                            sanitize_single_line(prompt_name)
                        );
                        self.draft.editor.set(text);
                    }
                } else {
                    self.note = format!("Unknown command {cmd} · /help");
                    self.draft.editor.set(text);
                }
            }
        }
    }
    fn withdraw(&mut self) {
        let ids: Vec<_> = self
            .state
            .committed_docs
            .get("inbox")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|i| i.get("submission_id").cloned())
            .collect();
        if ids.is_empty() {
            self.note = "No queued prompts".into();
            return;
        }
        if self.draft.retry.is_some() {
            self.note = "Resolve pending retry before withdrawing".into();
            return;
        }
        if let Ok(cid) = self.target.cid.parse() {
            let envelope = CommandEnvelope {
                version: 1,
                request_id: generate_request_id(),
                command: "withdraw".into(),
                conversation_id: cid,
                args: json!({"submission_ids":ids}),
            };
            self.start(
                Effect::Submit(envelope.clone()),
                Some((String::new(), envelope)),
            );
        }
    }
    fn file_menu(&mut self, prefix: &str) {
        self.start(Effect::Files(prefix.to_owned()), None);
    }
    fn workspace_file_menu(&mut self, prefix: &str) {
        self.start(Effect::WorkspaceFiles(prefix.to_owned()), None);
    }
    fn attach(&mut self, path: &str) {
        self.start(Effect::AttachFile(path.to_owned()), None);
    }
    fn jump_to_parent(&mut self) {
        if let Some(parent) = self.target.labels.parent.clone() {
            self.note = format!(
                "Opening parent {}…",
                sanitize_single_line(&parent.session_id)
            );
            self.start(
                Effect::AttachConversation {
                    sid: parent.session_id,
                    cid: parent.conversation_id,
                },
                None,
            );
        } else {
            self.note = "Current session has no parent session".into();
        }
    }
    fn copy(&mut self) {
        use base64::Engine;
        use std::io::Write;
        let Some(e) = self
            .state
            .entries
            .iter()
            .rev()
            .find(|e| e.kind == "assistant")
        else {
            self.note = "No loaded assistant message".into();
            return;
        };
        let text = extract_entry_text(&e.data);
        if text.len() > 100_000 {
            self.note = "Too large for terminal clipboard; use /export".into();
            return;
        }
        // The only clipboard write is an explicit local user action; encode even hostile output.
        let b64 = base64::engine::general_purpose::STANDARD.encode(text.as_bytes());
        let mut out = io::stdout().lock();
        self.note = match write!(out, "\x1b]52;c;{b64}\x07").and_then(|_| out.flush()) {
            Ok(()) => "Clipboard requested (terminal policy applies)".into(),
            Err(e) => e.to_string(),
        };
    }
    fn tree_key(&mut self, key: KeyEvent, screen: &mut Screen) {
        let Some(state) = self.tree.as_mut() else {
            return;
        };
        let choice = state.selector.key(key);
        let scope = state.scope.clone();
        match choice {
            TreeChoice::Stay => {}
            TreeChoice::Cancel => {
                self.tree = None;
            }
            TreeChoice::Select(sel) => {
                self.tree = None;
                if scope != (self.target.sid.clone(), self.target.cid.clone()) {
                    self.note = "Stale tree selection ignored after branch/session switch".into();
                    return;
                }
                self.handle_tree_selection(*sel, screen);
            }
        }
    }
    fn handle_tree_selection(&mut self, sel: TreeSelection, screen: &mut Screen) {
        if self.job.is_some() {
            self.note = "Wait for pending command".into();
            return;
        }
        let node = &sel.node;
        let is_user = node.kind == "user";

        // 1. Read-only imported archives: only allow switching branches to inspect history.
        if self.target.labels.is_imported_archive() {
            let target_cid = sel
                .leaf_conversations
                .iter()
                .find(|cid| *cid != &self.target.cid)
                .cloned()
                .or_else(|| {
                    (node.conversation_id != self.target.cid).then(|| node.conversation_id.clone())
                });
            if let Some(cid) = target_cid {
                self.switch(
                    Target {
                        cid,
                        ..self.target.clone()
                    },
                    screen,
                );
            } else {
                self.note = format!(
                    "Imported archive (read-only) · viewing #{} on #{}",
                    sanitize_single_line(&node.id),
                    sanitize_single_line(&self.target.cid)
                );
            }
            return;
        }

        // 2. Direct switch if this step is the exact tip of another existing conversation
        //    (e.g. a branch leaf with no children, or an existing empty fork at this cut).
        if let Some(other_cid) = sel
            .leaf_conversations
            .iter()
            .find(|cid| *cid != &self.target.cid)
            .cloned()
        {
            if !sel.has_children || sel.empty_fork_conversations.contains(&other_cid) {
                self.switch(
                    Target {
                        cid: other_cid,
                        ..self.target.clone()
                    },
                    screen,
                );
                return;
            }
        }

        // 3. Current conversation's own latest non-user step: nothing to fork or switch.
        if !is_user
            && sel
                .leaf_conversations
                .iter()
                .any(|cid| cid == &self.target.cid)
            && !sel.has_children
        {
            self.note = format!(
                "Already at latest step #{} on #{}",
                sanitize_single_line(&node.id),
                sanitize_single_line(&self.target.cid)
            );
            return;
        }

        // 4. Offer clear, durable actions for earlier steps or user prompts.
        let mut choices: Vec<(String, String)> = Vec::new();
        let clean_id = sanitize_single_line(&node.id);
        let clean_cid = sanitize_single_line(&node.conversation_id);

        if is_user {
            choices.push((
                "edit_before".to_string(),
                format!("Edit & re-submit from before #{clean_id}"),
            ));
            choices.push((
                "branch_after".to_string(),
                format!("Branch after #{clean_id} (keep prompt, new conversation)"),
            ));
            if node.conversation_id != self.target.cid {
                choices.push((
                    format!("switch:{}", node.conversation_id),
                    format!("Switch to #{clean_cid}"),
                ));
            }
        } else {
            for cid in &sel.empty_fork_conversations {
                if cid != &self.target.cid {
                    choices.push((
                        format!("switch:{cid}"),
                        format!("Switch to existing branch #{}", sanitize_single_line(cid)),
                    ));
                }
            }
            choices.push((
                "branch_after".to_string(),
                format!("Branch after #{clean_id} (new conversation)"),
            ));
            if node.conversation_id != self.target.cid {
                choices.push((
                    format!("switch:{}", node.conversation_id),
                    format!("View #{clean_cid}"),
                ));
            }
        }

        // If only a single branch_after action exists on a non-user step, execute directly.
        if !is_user && choices.len() == 1 && choices[0].0 == "branch_after" {
            self.fork_from_tree_node(node);
            return;
        }

        let title = format!(
            "Step #{clean_id} ({}) on #{clean_cid}",
            sanitize_single_line(&node.kind)
        );
        self.scoped_menu(PickerKind::TreeAction, &title, choices);
        if let Some(p) = self.picker.as_mut() {
            p.tree_selection = Some(sel);
        }
    }
    fn fork_from_tree_node(&mut self, node: &crate::protocol::TreeNode) {
        if !self.check_writable_workspace(false) {
            return;
        }
        let Ok(source_cid) = node.conversation_id.trim().parse::<u64>() else {
            self.note = format!(
                "Invalid conversation ID '{}'",
                sanitize_single_line(&node.conversation_id)
            );
            return;
        };
        let Ok(at_entry_id) = node.id.trim().parse::<u64>() else {
            self.note = format!("Invalid entry ID '{}'", sanitize_single_line(&node.id));
            return;
        };
        if source_cid == 0 || at_entry_id == 0 {
            self.note = "Invalid branch target".into();
            return;
        }
        self.start(
            Effect::ForkFrom {
                cid: source_cid,
                at_entry_id,
            },
            None,
        );
    }
    fn begin_tree_user_edit(&mut self, node: &crate::protocol::TreeNode, screen: &mut Screen) {
        if !self.check_writable_workspace(false) {
            return;
        }
        if self.draft.retry.is_some() {
            self.note = "Resolve previous submit (/retry or /discard-retry) before /fork".into();
            return;
        }
        if node.conversation_id == self.target.cid
            && self.current_view().entries.iter().any(|e| e.id == node.id)
        {
            self.begin_fork_edit(&node.id);
            return;
        }
        // Root user prompt has no predecessor: offer new session directly without inventing entry 0.
        if node.parent_id.is_none() {
            self.pending_root_fork = Some(PendingRootFork {
                source_sid: self.target.sid.clone(),
                source_cid: self.target.cid.clone(),
                entry_id: node.id.clone(),
                text: node.preview.clone(),
                attachments: Vec::new(),
            });
            self.scoped_menu(
                PickerKind::RootFork,
                &format!(
                    "Root prompt #{} has no predecessor",
                    sanitize_single_line(&node.id)
                ),
                vec![
                    (
                        "new_session".to_string(),
                        "Start new session with this prompt (keeps old session & files)"
                            .to_string(),
                    ),
                    (
                        "cancel".to_string(),
                        "Cancel (stay here and keep current draft)".to_string(),
                    ),
                ],
            );
            return;
        }
        if node.conversation_id != self.target.cid {
            // Switch to the owning branch and open fork-edit as soon as its snapshot arrives.
            self.pending_tree_fork_edit = Some(PendingTreeForkEdit {
                source_sid: self.target.sid.clone(),
                target_cid: node.conversation_id.clone(),
                entry_id: node.id.clone(),
            });
            self.switch(
                Target {
                    cid: node.conversation_id.clone(),
                    ..self.target.clone()
                },
                screen,
            );
            return;
        }
        // Entry is on the current branch but older than the loaded snapshot window:
        // stage fork-edit directly using the tree's authoritative parent_id and preview.
        let Some(pred_id) = node
            .parent_id
            .as_deref()
            .and_then(|s| s.trim().parse::<u64>().ok())
            .filter(|&n| n > 0)
        else {
            self.note = format!(
                "Predecessor for #{} is invalid; run /earlier and /fork",
                sanitize_single_line(&node.id)
            );
            return;
        };
        let stashed_draft = match self.draft.fork_edit.take() {
            Some(existing) => existing.stashed_draft,
            None => Box::new(std::mem::take(&mut self.draft)),
        };
        self.draft = Draft::default();
        self.draft.editor.set(&node.preview);
        self.draft.fork_edit = Some(ForkEdit {
            source_sid: self.target.sid.clone(),
            source_cid: self.target.cid.clone(),
            selected_entry_id: node.id.clone(),
            predecessor_id: pred_id,
            stashed_draft,
        });
        self.note = format!(
            "Editing #{} (will fork at #{}; Esc cancels)",
            sanitize_single_line(&node.id),
            pred_id
        );
    }
    fn pick_key(&mut self, key: KeyEvent, screen: &mut Screen) {
        let Some(state) = self.picker.as_mut() else {
            return;
        };
        let choice = state.picker.key(key);
        let kind = state.kind;
        let scope = state.scope.clone();
        let workspace_wait = state.workspace_wait.clone();
        let tree_selection = state.tree_selection.clone();
        match choice {
            Choice::Stay => {}
            Choice::Cancel => {
                self.picker = None;
                if kind == PickerKind::RootFork {
                    self.pending_root_fork = None;
                    self.note = "Cancelled root-prompt fork; draft preserved".into();
                }
            }
            Choice::Pick(id) => {
                self.picker = None;
                if let Some((ref sid, ref cid)) = scope {
                    if sid != &self.target.sid || cid != &self.target.cid {
                        if kind == PickerKind::RootFork {
                            self.pending_root_fork = None;
                        }
                        self.note = "Stale picker ignored after branch/session switch".into();
                        return;
                    }
                }
                match kind {
                    PickerKind::WorkspaceWait => {
                        if let Some(wait) = workspace_wait {
                            self.start(
                                Effect::WorkspaceWait {
                                    action: id,
                                    task_id: wait.task_id,
                                    lease_id: wait.lease_id,
                                },
                                None,
                            );
                        }
                    }
                    PickerKind::Approval => {
                        if let Some((decision, tid_str)) = id.split_once(':') {
                            if let Ok(task_id) = tid_str.parse::<u64>() {
                                self.start(
                                    Effect::ApproveTool {
                                        task_id,
                                        decision: decision.to_string(),
                                        reason: None,
                                    },
                                    None,
                                );
                            }
                        }
                    }
                    PickerKind::Models => self.start(Effect::Configure("model".into(), id), None),
                    PickerKind::Harnesses => self.start(Effect::NewWithHarness(id), None),
                    PickerKind::Themes => self.apply_theme_live(&id),
                    PickerKind::Prompts => {
                        self.draft.editor.set(&format!("/prompt:{id} "));
                        self.note = format!("Enter args or press Enter to run /prompt:{id}");
                    }
                    PickerKind::Thinking => {
                        self.start(Effect::Configure("thinking".into(), id), None)
                    }
                    PickerKind::Sessions => self.start(Effect::Attach(id), None),
                    PickerKind::Branches if self.job.is_none() => self.switch(
                        Target {
                            cid: id,
                            ..self.target.clone()
                        },
                        screen,
                    ),
                    PickerKind::Branches => {
                        self.note = "Wait for pending command".into();
                    }
                    PickerKind::Fork => self.begin_fork_edit(&id),
                    PickerKind::RootFork => {
                        if id == "new_session" {
                            let matches = self.pending_root_fork.as_ref().is_some_and(|r| {
                                r.source_sid == self.target.sid && r.source_cid == self.target.cid
                            });
                            if matches {
                                self.start(Effect::New, None);
                            } else {
                                self.pending_root_fork = None;
                                self.note = "Stale root-prompt fork ignored".into();
                            }
                        } else {
                            self.pending_root_fork = None;
                            self.note = "Cancelled root-prompt fork; draft preserved".into();
                        }
                    }
                    PickerKind::Branch => {
                        let visible = self.current_view().entries.iter().any(|e| e.id == id);
                        if !visible {
                            self.note = format!(
                                "Entry #{} is no longer visible in this branch",
                                sanitize_single_line(&id)
                            );
                        } else if let Ok(n) = id.parse() {
                            self.start(Effect::Fork(n), None);
                        }
                    }
                    PickerKind::Commands => {
                        self.draft.editor.set(&id);
                        self.note = "Enter to run command".into();
                    }
                    PickerKind::ClientFiles if id.ends_with('/') => self.file_menu(&id),
                    PickerKind::ClientFiles => {
                        if self.draft.editor.text().starts_with('@')
                            || self.draft.editor.text().starts_with("/attach")
                        {
                            self.draft.editor.set("");
                        }
                        self.attach(&id);
                    }
                    PickerKind::WorkspaceFiles if id.ends_with('/') => {
                        self.workspace_file_menu(&id);
                    }
                    PickerKind::WorkspaceFiles => {
                        if self.draft.editor.text().starts_with('@')
                            || self.draft.editor.text().starts_with("/file")
                        {
                            self.draft.editor.set("");
                        }
                        self.start(Effect::ReadWorkspaceFile(id), None);
                    }
                    PickerKind::Search => {
                        if let Some(e) = self.current_view().entries.iter().find(|e| e.id == id) {
                            let text = extract_entry_text(&e.data);
                            self.scoped_menu(
                                PickerKind::Info,
                                "message",
                                text.lines()
                                    .map(|l| (String::new(), sanitize_single_line(l)))
                                    .collect(),
                            );
                        }
                    }
                    PickerKind::AccountSources => self.start(Effect::ActivateAccount(id), None),
                    PickerKind::LogoutSources => {
                        self.start(Effect::RemoveCodexAccount(id), None);
                    }
                    PickerKind::KeyRemove => {
                        if let Some((provider, source)) = id.split_once(':') {
                            self.start(
                                Effect::RemoveKey(provider.to_string(), source.to_string()),
                                None,
                            );
                        }
                    }
                    PickerKind::LoginSources => {
                        self.login = Some(Login::start(self.client.clone(), id));
                    }
                    PickerKind::TreeAction => {
                        if let Some(sel) = tree_selection {
                            if id == "edit_before" {
                                self.begin_tree_user_edit(&sel.node, screen);
                            } else if id == "branch_after" {
                                self.fork_from_tree_node(&sel.node);
                            } else if let Some(cid) = id.strip_prefix("switch:") {
                                if self.job.is_some() {
                                    self.note = "Wait for pending command".into();
                                } else {
                                    self.switch(
                                        Target {
                                            cid: cid.to_string(),
                                            ..self.target.clone()
                                        },
                                        screen,
                                    );
                                }
                            }
                        }
                    }
                    PickerKind::Info => {}
                }
            }
        }
    }
}

struct PendingApproval {
    task_id: u64,
    tool_name: String,
}

fn pending_approvals(state: &TranscriptState) -> Vec<PendingApproval> {
    let Some(approvals) = state
        .live_doc()
        .and_then(|live| live.get("approvals"))
        .and_then(Value::as_object)
    else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for (key_tid, rec) in approvals {
        let tid_str = rec
            .get("task_id")
            .and_then(Value::as_str)
            .unwrap_or(key_tid);
        let Some(task_id) = tid_str.parse::<u64>().ok().filter(|&n| n > 0) else {
            continue;
        };
        let tool_name = rec
            .get("tool_name")
            .and_then(Value::as_str)
            .unwrap_or("tool")
            .to_string();
        out.push(PendingApproval { task_id, tool_name });
    }
    out.sort_by_key(|a| a.task_id);
    out
}

fn pending_approval_ids(state: &TranscriptState) -> Vec<u64> {
    pending_approvals(state)
        .into_iter()
        .map(|a| a.task_id)
        .collect()
}

fn parse_approval_policy(raw: &str) -> Result<ApprovalPolicy, String> {
    let trimmed = raw.trim();
    match trimmed {
        "never" => Ok(ApprovalPolicy::never()),
        "mutating" => Ok(ApprovalPolicy::mutating()),
        _ => {
            let tools: Vec<String> = trimmed
                .split([',', ' '])
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect();
            if tools.is_empty() {
                Err("Usage: /approval [never|mutating|<tool1,tool2>]".into())
            } else {
                Ok(ApprovalPolicy::Tools(tools))
            }
        }
    }
}

fn format_approval_policy(state: &TranscriptState) -> String {
    match state
        .docs
        .get("agent")
        .and_then(Value::as_object)
        .and_then(|a| a.get("approval_policy"))
    {
        Some(Value::String(s)) => sanitize_single_line(s),
        Some(Value::Array(arr)) => {
            let list: Vec<String> = arr
                .iter()
                .filter_map(Value::as_str)
                .map(sanitize_single_line)
                .collect();
            if list.is_empty() {
                "never".to_string()
            } else {
                list.join(",")
            }
        }
        _ => "never".to_string(),
    }
}

fn parse_elapsed_ms(raw: &str) -> Result<u64, String> {
    let trimmed = raw.trim();
    let ms = if let Some(s) = trimmed.strip_suffix("ms") {
        s.parse::<u64>().map_err(|_| {
            format!(
                "Invalid elapsed budget '{}'; expected e.g. 60000 or 60s",
                sanitize_single_line(raw)
            )
        })?
    } else if let Some(s) = trimmed.strip_suffix('s') {
        let secs = s.parse::<u64>().map_err(|_| {
            format!(
                "Invalid elapsed budget '{}'; expected e.g. 60000 or 60s",
                sanitize_single_line(raw)
            )
        })?;
        secs.saturating_mul(1000)
    } else {
        trimmed.parse::<u64>().map_err(|_| {
            format!(
                "Invalid elapsed budget '{}'; expected milliseconds or <N>s",
                sanitize_single_line(raw)
            )
        })?
    };
    if ms == 0 {
        return Err("elapsed budget must be > 0".into());
    }
    Ok(ms)
}

fn parse_run_budget(raw: &str) -> Result<Option<RunBudget>, String> {
    let trimmed = raw.trim();
    if matches!(
        trimmed.to_ascii_lowercase().as_str(),
        "off" | "clear" | "none"
    ) {
        return Ok(None);
    }
    let mut budget = RunBudget::default();
    let mut any = false;
    for token in trimmed.split_whitespace() {
        let Some((k, v)) = token.split_once('=') else {
            return Err("Usage: /budget [off|clear|turns=N cost=X elapsed=MS_OR_SECS]".into());
        };
        match k {
            "turns" | "max_turns" => {
                let n = v.parse::<u64>().ok().filter(|&n| n > 0).ok_or_else(|| {
                    format!("Invalid turns '{}': must be > 0", sanitize_single_line(v))
                })?;
                budget.max_turns = Some(n);
                any = true;
            }
            "cost" | "max_cost_usd" => {
                let c = v
                    .parse::<f64>()
                    .ok()
                    .filter(|&c| c.is_finite() && c > 0.0)
                    .ok_or_else(|| {
                        format!("Invalid cost '{}': must be > 0", sanitize_single_line(v))
                    })?;
                budget.max_cost_usd = Some(c);
                any = true;
            }
            "elapsed" | "max_elapsed_ms" => {
                budget.max_elapsed_ms = Some(parse_elapsed_ms(v)?);
                any = true;
            }
            other => {
                return Err(format!(
                    "Unknown budget field '{}'; expected turns=, cost=, or elapsed=",
                    sanitize_single_line(other)
                ));
            }
        }
    }
    if !any {
        return Err("Usage: /budget [off|clear|turns=N cost=X elapsed=MS_OR_SECS]".into());
    }
    Ok(Some(budget))
}

fn format_run_budget(state: &TranscriptState) -> String {
    let Some(budget) = state
        .docs
        .get("agent")
        .and_then(Value::as_object)
        .and_then(|a| a.get("budget"))
        .and_then(Value::as_object)
    else {
        return "Budget: off · Usage: /budget [off|clear|turns=N cost=X elapsed=MS_OR_SECS]"
            .to_string();
    };
    let mut parts = Vec::new();
    if let Some(t) = budget.get("max_turns").and_then(Value::as_u64) {
        parts.push(format!("turns={t}"));
    }
    if let Some(c) = budget.get("max_cost_usd").and_then(Value::as_f64) {
        parts.push(format!("cost=${c:.4}"));
    }
    if let Some(ms) = budget.get("max_elapsed_ms").and_then(Value::as_u64) {
        parts.push(format!("elapsed={ms}ms"));
    }
    if parts.is_empty() {
        "Budget: off".to_string()
    } else {
        format!("Budget: {}", parts.join(" "))
    }
}

enum ForkResolution {
    Predecessor {
        selected_id: String,
        predecessor_id: u64,
        text: String,
        attachments: Vec<Value>,
    },
    RootPrompt {
        selected_id: String,
        text: String,
        attachments: Vec<Value>,
    },
}

fn extract_entry_attachments(data: &Value) -> Vec<Value> {
    data.get("content")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter(|item| {
                    item.is_object() && item.get("type").and_then(Value::as_str) != Some("text")
                })
                .cloned()
                .collect()
        })
        .unwrap_or_default()
}

fn extract_non_text_blocks(args: &Value) -> Vec<Value> {
    extract_entry_attachments(args)
}

fn is_ambiguous_submit_error(err: &str) -> bool {
    err.contains("outcome unknown") || err.contains("disconnected")
}

fn resolve_cwd_input(raw: &str, env_id: &str, base_cwd: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("Usage: /cwd <existing-dir>".into());
    }
    if trimmed.contains('\0') {
        return Err("Directory path cannot contain NUL bytes".into());
    }
    let expanded = if env_id == "host" && (trimmed == "~" || trimmed.starts_with("~/")) {
        let home = std::env::var("HOME")
            .ok()
            .filter(|h| !h.trim().is_empty())
            .ok_or_else(|| "Cannot expand ~: HOME is not set".to_string())?;
        if trimmed == "~" {
            home
        } else {
            format!("{}{}", home.trim_end_matches('/'), &trimmed[1..])
        }
    } else if trimmed.starts_with('/') {
        trimmed.to_string()
    } else if base_cwd.starts_with('/') {
        format!("{}/{}", base_cwd.trim_end_matches('/'), trimmed)
    } else {
        return Err("Provide an absolute path for /cwd <path>".into());
    };
    Ok(normalize_abs_path(&expanded))
}

fn normalize_abs_path(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for seg in path.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    if parts.is_empty() {
        "/".to_string()
    } else {
        format!("/{}", parts.join("/"))
    }
}

fn parse_user_shell_input(text: &str) -> Option<(bool, &str)> {
    let trimmed = text.trim_start();
    if let Some(rest) = trimmed.strip_prefix("!!") {
        Some((false, rest.trim()))
    } else {
        trimmed.strip_prefix('!').map(|rest| (true, rest.trim()))
    }
}

fn resolve_fork_target(view: &TranscriptState, entry_id: &str) -> Result<ForkResolution, String> {
    let Some(idx) = view.entries.iter().position(|e| e.id == entry_id) else {
        return Err(format!(
            "Entry #{} is not visible in this branch",
            sanitize_single_line(entry_id)
        ));
    };
    let entry = &view.entries[idx];
    if entry.kind != "user" {
        return Err(format!(
            "Entry #{} is not a user prompt; use /branch {} to branch after it",
            sanitize_single_line(entry_id),
            sanitize_single_line(entry_id)
        ));
    }
    let text = extract_entry_text(&entry.data);
    let attachments = extract_entry_attachments(&entry.data);
    if text.is_empty() && attachments.is_empty() {
        return Err(format!(
            "Entry #{} has no editable prompt content",
            sanitize_single_line(entry_id)
        ));
    }
    if idx > 0 {
        let pred = &view.entries[idx - 1];
        let predecessor_id = pred
            .id
            .trim()
            .parse::<u64>()
            .ok()
            .filter(|&n| n > 0)
            .ok_or_else(|| {
                format!(
                    "Invalid predecessor entry ID '{}'",
                    sanitize_single_line(&pred.id)
                )
            })?;
        Ok(ForkResolution::Predecessor {
            selected_id: entry.id.clone(),
            predecessor_id,
            text,
            attachments,
        })
    } else if view.has_more || view.before_entry_id.is_some() {
        Err(format!(
            "Predecessor for #{} is not loaded; run /earlier first",
            sanitize_single_line(entry_id)
        ))
    } else {
        Ok(ForkResolution::RootPrompt {
            selected_id: entry.id.clone(),
            text,
            attachments,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{DaemonTarget, SecretToken};
    use crate::protocol::{SnapshotFrame, TranscriptEntry};
    use serde_json::json;
    use std::io::{Read, Write};
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::sync::{Arc, Mutex};
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TestServer {
        sock_path: PathBuf,
        listener: UnixListener,
    }

    impl TestServer {
        fn bind(tag: &str) -> (Self, DaemonClient) {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let sock_path = std::env::temp_dir().join(format!("hi-app-{tag}-{nanos}.sock"));
            let _ = std::fs::remove_file(&sock_path);
            let listener = UnixListener::bind(&sock_path).unwrap();
            let client = DaemonClient::new(
                DaemonTarget::UnixSocket(sock_path.clone()),
                SecretToken::new("tok-app-test").unwrap(),
            );
            (
                Self {
                    sock_path,
                    listener,
                },
                client,
            )
        }
    }

    impl Drop for TestServer {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.sock_path);
        }
    }

    fn read_http_request(stream: &mut UnixStream) -> (String, String) {
        let mut buf = Vec::new();
        let mut tmp = [0u8; 1024];
        while let Ok(n) = stream.read(&mut tmp) {
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
                    let Ok(m) = stream.read(&mut tmp) else {
                        break;
                    };
                    if m == 0 {
                        break;
                    }
                    buf.extend_from_slice(&tmp[..m]);
                }
                let end = (head_end + content_len).min(buf.len());
                let body = String::from_utf8_lossy(&buf[head_end..end]).to_string();
                return (head_str, body);
            }
        }
        (String::from_utf8_lossy(&buf).to_string(), String::new())
    }

    fn write_json_response(stream: &mut UnixStream, status: &str, body: &str) {
        let _ = write!(
            stream,
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.flush();
    }

    fn make_ui(client: DaemonClient, sid: &str, cid: &str) -> (Ui, Screen) {
        let target = Target {
            sid: sid.to_string(),
            cid: cid.to_string(),
            cwd: "/tmp/proj".to_string(),
            env_id: "host".to_string(),
            labels: Default::default(),
        };
        let sub = Subscription::start(client.clone(), target.sid.clone(), target.cid.clone(), None);
        let state = TranscriptState::new(Some(target.sid.clone()), Some(target.cid.clone()));
        let ui = Ui {
            client,
            launch_env_id: target.env_id.clone(),
            launch_cwd: target.cwd.clone(),
            target,
            state,
            historical: None,
            sub: Some(sub),
            catalog_sub: None,
            inbox: None,
            entered_from_inbox: false,
            online: true,
            draft: Draft::default(),
            saved: HashMap::new(),
            picker: None,
            tree: None,
            login: None,
            secret: None,
            completion: None,
            path_lookup: None,
            pending_root_fork: None,
            pending_cwd_fork: None,
            pending_tree_fork_edit: None,
            config: UserConfig::default(),
            config_gen: 0,
            prompts: Vec::new(),
            status_metadata: StatusMetadata::default(),
            data_dir: std::env::temp_dir().join("hi-app-nonexistent-config"),
            job: None,
            note: "Ready".into(),
            tools: false,
            thinking: false,
            cached_rows: Vec::new(),
            rows_dirty: true,
            quit: false,
            restart_ui: None,
            last_clear: None,
        };
        let screen = Screen::with_test_backend(80, 24).unwrap();
        (ui, screen)
    }

    fn user_entry(id: &str, text: &str) -> TranscriptEntry {
        TranscriptEntry {
            id: id.to_string(),
            conversation_id: Some("1".to_string()),
            seq: Some(id.parse().unwrap_or(1)),
            kind: "user".to_string(),
            data: json!({ "content": [{ "type": "text", "text": text }] }),
            created_at: None,
        }
    }

    fn assistant_entry(id: &str, text: &str) -> TranscriptEntry {
        TranscriptEntry {
            id: id.to_string(),
            conversation_id: Some("1".to_string()),
            seq: Some(id.parse().unwrap_or(1)),
            kind: "assistant".to_string(),
            data: json!({ "content": [{ "type": "text", "text": text }] }),
            created_at: None,
        }
    }

    fn load_snapshot(ui: &mut Ui, seq: u64, entries: Vec<TranscriptEntry>, has_more: bool) {
        let before_entry_id = if has_more {
            entries.first().map(|e| e.id.clone())
        } else {
            None
        };
        ui.update(Update::Online);
        ui.update(Update::Frame(ServerFrame::Snapshot(SnapshotFrame {
            version: Some(1),
            session_id: Some(ui.target.sid.clone()),
            conversation_id: Some(ui.target.cid.clone()),
            seq,
            before_entry_id,
            has_more: Some(has_more),
            entries,
            docs: Some(json!({
                "live": {},
                "inbox": [],
                "agent": { "model": "fake/model", "thinking": "medium" },
                "usage": {}
            })),
        })));
    }

    fn wait_job_complete(ui: &mut Ui, screen: &mut Screen) {
        let deadline = Instant::now() + Duration::from_secs(3);
        while ui.job.is_some() {
            if ui.complete(screen) {
                continue;
            }
            assert!(Instant::now() < deadline, "timed out waiting for ui.job");
            thread::sleep(Duration::from_millis(5));
        }
    }

    fn press_enter(ui: &mut Ui, screen: &mut Screen) {
        let key = KeyEvent::new(KeyCode::Enter, Mod::NONE);
        if ui.picker.is_some() {
            ui.pick_key(key, screen);
        } else {
            ui.key(key, screen);
        }
    }

    fn press_esc(ui: &mut Ui, screen: &mut Screen) {
        let key = KeyEvent::new(KeyCode::Esc, Mod::NONE);
        if ui.picker.is_some() {
            ui.pick_key(key, screen);
        } else {
            ui.key(key, screen);
        }
    }

    fn press_down(ui: &mut Ui, screen: &mut Screen) {
        ui.pick_key(KeyEvent::new(KeyCode::Down, Mod::NONE), screen);
    }

    #[test]
    fn named_router_uses_masked_key_prompt_and_sends_only_to_provider_key_endpoint() {
        let (server, client) = TestServer::bind("router-key");
        let secret = "fixture-router-key";
        let listener = server.listener.try_clone().unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let (header, body) = read_http_request(&mut stream);
            let (mut stream, header, body) = if header.starts_with("GET ") {
                drop(stream);
                let (mut stream, _) = listener.accept().unwrap();
                let (header, body) = read_http_request(&mut stream);
                (stream, header, body)
            } else {
                (stream, header, body)
            };
            assert!(header.starts_with("POST /api/v1/provider-keys/set HTTP/1.1"));
            assert_eq!(
                serde_json::from_str::<Value>(&body).unwrap(),
                json!({"provider": "example-router", "source": "work", "api_key": secret})
            );
            write_json_response(
                &mut stream,
                "200 OK",
                r#"{"provider":"example-router","active":"work"}"#,
            );
        });

        let (mut ui, mut screen) = make_ui(client, "s", "1");
        ui.command("/key set example-router work");
        let prompt = ui.secret.as_mut().expect("masked key prompt");
        prompt.paste(secret);
        assert!(prompt
            .lines()
            .join(" ")
            .contains(&format!("Key: {}", "*".repeat(secret.len()))));
        assert!(!prompt.lines().join(" ").contains(secret));
        ui.secret_key(KeyEvent::new(KeyCode::Enter, Mod::NONE));
        wait_job_complete(&mut ui, &mut screen);
        assert!(ui.secret.is_none());
        assert!(ui.note.contains("Saved example-router key work"));
        assert!(!ui.note.contains(secret));
        handle.join().unwrap();
    }

    #[test]
    fn predecessor_fork_and_edit_uses_fork_and_submit_without_duplicating_or_rewinding() {
        let (srv, client) = TestServer::bind("predecessor-fork");
        let recorded = Arc::new(Mutex::new(Vec::<Value>::new()));
        let recorded_srv = Arc::clone(&recorded);
        let listener = srv.listener.try_clone().unwrap();

        let handle = thread::spawn(move || {
            // Only accept POST /commands (Subscription SSE threads may also connect and fail harmlessly after)
            loop {
                let (mut stream, _) = listener.accept().unwrap();
                let (head, body) = read_http_request(&mut stream);
                if head.starts_with("POST /api/v1/sessions/sess-1/commands ") {
                    let val: Value = serde_json::from_str(&body).unwrap();
                    let req_id = val["request_id"].as_str().unwrap().to_string();
                    recorded_srv.lock().unwrap().push(val);
                    let resp = json!({
                        "version": 1,
                        "request_id": req_id,
                        "seq": 20,
                        "conversation_id": "2",
                        "submission_id": "sub-20",
                        "status": "placed"
                    })
                    .to_string();
                    write_json_response(&mut stream, "200 OK", &resp);
                    break;
                } else {
                    write_json_response(&mut stream, "404 Not Found", "{}");
                }
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        load_snapshot(
            &mut ui,
            15,
            vec![
                user_entry("10", "first prompt"),
                assistant_entry("11", "first reply"),
                user_entry("12", "second prompt"),
                assistant_entry("13", "second reply"),
            ],
            false,
        );

        // User has an unsent draft + attachment on conv #1
        ui.draft.editor.set("unsent wip");
        ui.draft
            .attachments
            .push(json!({"type": "text", "text": "note"}));

        ui.command("/fork");
        let picker = ui.picker.as_ref().expect("fork picker should open");
        assert_eq!(picker.kind, PickerKind::Fork);
        let lines = picker.picker.lines();
        let joined = lines.join("\n");
        // Only user prompts appear, with explicit fork cut point or root indicator
        assert!(
            joined.contains("#12 [fork @ #11] second prompt"),
            "{joined}"
        );
        assert!(
            joined.contains("#10 [root · new session] first prompt"),
            "{joined}"
        );
        assert!(!joined.contains("#11 "), "{joined}");
        assert!(!joined.contains("#13 "), "{joined}");

        // Pick #12 -> loads "second prompt" into editor, stages predecessor #11
        press_enter(&mut ui, &mut screen);
        assert!(ui.picker.is_none());
        assert_eq!(ui.draft.editor.text(), "second prompt");
        let fe = ui.draft.fork_edit.as_ref().expect("fork_edit staged");
        assert_eq!(fe.selected_entry_id, "12");
        assert_eq!(fe.predecessor_id, 11);

        // Draw to verify fork-edit indicator renders in status
        ui.draw(&mut screen).unwrap();
        let status_row: String = (0..80)
            .map(|x| {
                screen
                    .test_backend()
                    .buffer()
                    .cell((x, 23))
                    .map(|c| c.symbol())
                    .unwrap_or(" ")
            })
            .collect();
        assert!(
            status_row.contains("fork-edit #12@11") || ui.note.contains("#11"),
            "status={status_row:?} note={:?}",
            ui.note
        );

        // Edit the prompt and submit
        ui.draft.editor.set("second prompt edited");
        press_enter(&mut ui, &mut screen);
        wait_job_complete(&mut ui, &mut screen);

        handle.join().unwrap();
        let cmds = recorded.lock().unwrap();
        assert_eq!(cmds.len(), 1);
        assert_eq!(cmds[0]["command"], "fork_and_submit");
        assert_eq!(cmds[0]["conversation_id"], 1);
        assert_eq!(cmds[0]["args"]["at_entry_id"], 11);
        assert_eq!(
            cmds[0]["args"]["content"][0]["text"],
            "second prompt edited"
        );

        // Switched to new child conversation #2 with empty draft
        assert_eq!(ui.target.cid, "2");
        assert!(ui.draft.editor.text().is_empty());
        assert!(ui.draft.fork_edit.is_none());

        // Original unsent draft on conv #1 was preserved in saved
        let saved_c1 = ui.saved.get(&("sess-1".into(), "1".into())).unwrap();
        assert_eq!(saved_c1.editor.text(), "unsent wip");
        assert_eq!(saved_c1.attachments.len(), 1);
    }

    #[test]
    fn branch_after_selected_entry_is_distinct_from_fork_edit() {
        let (srv, client) = TestServer::bind("branch-after");
        let recorded = Arc::new(Mutex::new(Vec::<Value>::new()));
        let recorded_srv = Arc::clone(&recorded);
        let listener = srv.listener.try_clone().unwrap();

        let handle = thread::spawn(move || loop {
            let (mut stream, _) = listener.accept().unwrap();
            let (head, body) = read_http_request(&mut stream);
            if head.starts_with("POST /api/v1/sessions/sess-1/commands ") {
                let val: Value = serde_json::from_str(&body).unwrap();
                let req_id = val["request_id"].as_str().unwrap().to_string();
                recorded_srv.lock().unwrap().push(val);
                let resp = json!({
                    "version": 1,
                    "request_id": req_id,
                    "seq": 21,
                    "conversation_id": "3",
                    "status": "done"
                })
                .to_string();
                write_json_response(&mut stream, "200 OK", &resp);
                break;
            } else {
                write_json_response(&mut stream, "404 Not Found", "{}");
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        load_snapshot(
            &mut ui,
            15,
            vec![
                user_entry("10", "first prompt"),
                assistant_entry("11", "first reply"),
                user_entry("12", "second prompt"),
                assistant_entry("13", "second reply"),
            ],
            false,
        );

        ui.command("/branch");
        let picker = ui.picker.as_ref().expect("branch picker should open");
        assert_eq!(picker.kind, PickerKind::Branch);
        // Includes assistant #13 as top item; picking it branches AFTER #13 via command: "fork"
        press_enter(&mut ui, &mut screen);
        wait_job_complete(&mut ui, &mut screen);

        handle.join().unwrap();
        let cmds = recorded.lock().unwrap();
        assert_eq!(cmds.len(), 1);
        assert_eq!(cmds[0]["command"], "fork");
        assert_eq!(cmds[0]["conversation_id"], 1);
        assert_eq!(cmds[0]["args"]["at_entry_id"], 13);
        assert!(cmds[0]["args"].get("content").is_none());
        assert_eq!(ui.target.cid, "3");
    }

    #[test]
    fn root_prompt_policy_explicit_confirm_cancel_and_paged_boundary() {
        let (srv, client) = TestServer::bind("root-policy");
        let created_reqs = Arc::new(Mutex::new(Vec::<Value>::new()));
        let created_srv = Arc::clone(&created_reqs);
        let listener = srv.listener.try_clone().unwrap();

        let handle = thread::spawn(move || loop {
            let (mut stream, _) = listener.accept().unwrap();
            let (head, body) = read_http_request(&mut stream);
            if head.starts_with("POST /api/v1/sessions ") {
                let val: Value = serde_json::from_str(&body).unwrap();
                let sid = val["session_id"].as_str().unwrap().to_string();
                created_srv.lock().unwrap().push(val);
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
                write_json_response(&mut stream, "200 OK", &resp);
                break;
            } else {
                write_json_response(&mut stream, "404 Not Found", "{}");
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");

        // 1. Paged boundary: entries[0] has has_more=true -> NOT treated as root prompt!
        load_snapshot(
            &mut ui,
            20,
            vec![
                user_entry("51", "paged prompt"),
                assistant_entry("52", "paged reply"),
            ],
            true,
        );
        ui.draft.editor.set("keep draft");
        ui.command("/fork 51");
        assert!(ui.picker.is_none());
        assert!(ui.pending_root_fork.is_none());
        assert!(ui.note.contains("/earlier"), "note={}", ui.note);
        assert_eq!(ui.draft.editor.text(), "keep draft");

        // 2. True root prompt (idx=0, has_more=false, before_entry_id=None)
        load_snapshot(
            &mut ui,
            5,
            vec![
                user_entry("10", "initial root prompt"),
                assistant_entry("11", "root reply"),
            ],
            false,
        );
        ui.command("/fork 10");
        let picker = ui.picker.as_ref().expect("explicit root-fork confirmation");
        assert_eq!(picker.kind, PickerKind::RootFork);
        assert!(ui.pending_root_fork.is_some());
        // Original draft untouched while confirmation is open
        assert_eq!(ui.draft.editor.text(), "keep draft");

        // 2a. Cancelling root-fork preserves draft and creates no session
        press_esc(&mut ui, &mut screen);
        assert!(ui.picker.is_none());
        assert!(ui.pending_root_fork.is_none());
        assert_eq!(ui.target.sid, "sess-1");
        assert_eq!(ui.draft.editor.text(), "keep draft");
        assert!(created_reqs.lock().unwrap().is_empty());

        // 2b. Confirming "new_session" creates new session with root prompt loaded in editor
        ui.command("/fork");
        assert_eq!(ui.picker.as_ref().unwrap().kind, PickerKind::Fork);
        press_enter(&mut ui, &mut screen); // picks #10 -> opens RootFork confirmation
        assert_eq!(ui.picker.as_ref().unwrap().kind, PickerKind::RootFork);
        press_enter(&mut ui, &mut screen); // picks "new_session"
        wait_job_complete(&mut ui, &mut screen);

        handle.join().unwrap();
        let reqs = created_reqs.lock().unwrap();
        assert_eq!(reqs.len(), 1);
        assert_ne!(ui.target.sid, "sess-1");
        assert_eq!(ui.target.cid, "1");
        assert_eq!(ui.draft.editor.text(), "initial root prompt");
        assert!(ui.note.contains("files unchanged"), "note={}", ui.note);
        // Old session's draft is preserved in saved
        assert_eq!(
            ui.saved
                .get(&("sess-1".into(), "1".into()))
                .unwrap()
                .editor
                .text(),
            "keep draft"
        );
    }

    #[test]
    fn draft_preservation_across_esc_abort_and_retry_and_error() {
        let (srv, client) = TestServer::bind("draft-pres");
        let seen = Arc::new(Mutex::new(Vec::<Value>::new()));
        let seen_srv = Arc::clone(&seen);
        let listener = srv.listener.try_clone().unwrap();

        let handle = thread::spawn(move || {
            let mut post_count = 0usize;
            loop {
                let (mut stream, _) = listener.accept().unwrap();
                let (head, body) = read_http_request(&mut stream);
                if head.starts_with("POST /api/v1/sessions/sess-1/commands ") {
                    post_count += 1;
                    let val: Value = serde_json::from_str(&body).unwrap();
                    let req_id = val["request_id"].as_str().unwrap().to_string();
                    seen_srv.lock().unwrap().push(val);
                    match post_count {
                        // First 3 attempts (initial + 2 auto-retries) drop -> ambiguous outcome unknown
                        1..=3 => drop(stream),
                        // 4th attempt (/retry) succeeds idempotently
                        4 => {
                            let resp = json!({
                                "version": 1,
                                "request_id": req_id,
                                "seq": 30,
                                "conversation_id": "2",
                                "submission_id": "sub-30",
                                "status": "placed"
                            })
                            .to_string();
                            write_json_response(&mut stream, "200 OK", &resp);
                            break;
                        }
                        _ => unreachable!(),
                    }
                } else {
                    write_json_response(&mut stream, "404 Not Found", "{}");
                }
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        load_snapshot(
            &mut ui,
            15,
            vec![
                user_entry("10", "first"),
                assistant_entry("11", "first reply"),
                user_entry("12", "second"),
                assistant_entry("13", "second reply"),
            ],
            false,
        );
        // Simulate active run in live doc to prove Esc during fork_edit does NOT send abort
        ui.update(Update::Frame(ServerFrame::Ephemeral(
            crate::protocol::EphemeralFrame {
                version: Some(1),
                session_id: Some("sess-1".into()),
                conversation_id: Some("1".into()),
                base_seq: 15,
                doc_ops: Some(
                    serde_json::from_value(json!({
                        "live": [["replace", {"run": {"turns": 1}}]]
                    }))
                    .unwrap(),
                ),
                ops: None,
            },
        )));
        assert!(ui.state.is_run_active());

        ui.draft.editor.set("original draft");
        ui.command("/fork 12");
        assert_eq!(ui.draft.editor.text(), "second");

        // Esc cancels fork-edit and restores original draft WITHOUT sending abort
        press_esc(&mut ui, &mut screen);
        assert!(
            ui.job.is_none(),
            "Esc must cancel fork_edit before aborting"
        );
        assert!(ui.draft.fork_edit.is_none());
        assert_eq!(ui.draft.editor.text(), "original draft");

        // Stage again, edit, submit -> ambiguous I/O exhausts auto-retries
        ui.command("/fork 12");
        ui.draft.editor.set("edited retryable");
        press_enter(&mut ui, &mut screen);
        wait_job_complete(&mut ui, &mut screen);

        assert_eq!(ui.target.cid, "1", "must stay on conv #1 on error");
        assert_eq!(ui.draft.editor.text(), "edited retryable");
        assert!(ui.note.contains("outcome unknown"), "note={}", ui.note);
        let retry_req_id = ui
            .draft
            .retry
            .as_ref()
            .expect("retry envelope retained")
            .1
            .request_id
            .clone();

        // /retry re-sends exact same fork_and_submit envelope with identical request_id
        ui.command("/retry");
        wait_job_complete(&mut ui, &mut screen);
        handle.join().unwrap();

        let reqs = seen.lock().unwrap();
        assert_eq!(reqs.len(), 4);
        for r in reqs.iter() {
            assert_eq!(r["command"], "fork_and_submit");
            assert_eq!(r["request_id"], retry_req_id);
            assert_eq!(r["args"]["at_entry_id"], 11);
        }

        assert_eq!(ui.target.cid, "2");
        assert!(ui.draft.retry.is_none());
        assert!(ui.draft.editor.text().is_empty());
        assert_eq!(
            ui.saved
                .get(&("sess-1".into(), "1".into()))
                .unwrap()
                .editor
                .text(),
            "original draft"
        );
    }

    #[test]
    fn concurrency_stale_picker_and_wrong_branch_guards() {
        let (srv, client) = TestServer::bind("stale-picker");
        let posted = Arc::new(Mutex::new(0usize));
        let posted_srv = Arc::clone(&posted);
        let listener = srv.listener.try_clone().unwrap();

        thread::spawn(move || {
            while let Ok((mut stream, _)) = listener.accept() {
                let (head, _body) = read_http_request(&mut stream);
                if head.contains("/commands") {
                    *posted_srv.lock().unwrap() += 1;
                }
                write_json_response(&mut stream, "404 Not Found", "{}");
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        load_snapshot(
            &mut ui,
            15,
            vec![
                user_entry("10", "first"),
                assistant_entry("11", "first reply"),
                user_entry("12", "second"),
                assistant_entry("13", "second reply"),
            ],
            false,
        );
        ui.draft.editor.set("conv1 draft");

        // 1. Open /fork picker on conv #1, then concurrent branch switch to conv #2 occurs
        ui.command("/fork");
        assert!(ui.picker.is_some());
        ui.switch(
            Target {
                sid: "sess-1".into(),
                cid: "2".into(),
                cwd: "/tmp/proj".into(),
                env_id: "host".into(),
                labels: Default::default(),
            },
            &mut screen,
        );
        assert!(
            ui.picker.is_none(),
            "switch() must invalidate conversation-scoped fork picker"
        );

        // Even if a stale PickerState from conv #1 existed, pick_key rejects it
        ui.picker = Some(PickerState {
            kind: PickerKind::Fork,
            picker: Picker::new("fork", vec![("12".into(), "#12 second".into())]),
            workspace_wait: None,
            scope: Some(("sess-1".into(), "1".into())),
            tree_selection: None,
        });
        press_enter(&mut ui, &mut screen);
        assert!(ui.note.contains("Stale picker ignored"), "note={}", ui.note);
        assert!(ui.draft.fork_edit.is_none());

        // 2. Open /fork picker on conv #2, then SSE snapshot replaces lineage without #12
        load_snapshot(
            &mut ui,
            25,
            vec![
                user_entry("10", "first"),
                assistant_entry("11", "first reply"),
                user_entry("12", "second"),
            ],
            false,
        );
        ui.draft.editor.set("conv2 draft");
        ui.command("/fork");
        assert_eq!(ui.picker.as_ref().unwrap().kind, PickerKind::Fork);

        // Snapshot arrives without #12 before user presses Enter
        load_snapshot(
            &mut ui,
            26,
            vec![
                user_entry("10", "first"),
                assistant_entry("11", "first reply"),
            ],
            false,
        );
        press_enter(&mut ui, &mut screen); // tries to pick #12 which disappeared
        assert!(ui.note.contains("not visible"), "note={}", ui.note);
        assert!(ui.draft.fork_edit.is_none());
        assert_eq!(ui.draft.editor.text(), "conv2 draft");

        // 3. Concurrent SSE Commit appends tail entries while /fork picker is open -> still valid!
        ui.command("/fork"); // top item is #10 (root)
        ui.update(Update::Frame(ServerFrame::Commit(
            crate::protocol::CommitFrame {
                version: Some(1),
                session_id: Some("sess-1".into()),
                conversation_id: Some("2".into()),
                prev_seq: Some(26),
                seq: 27,
                appended_entries: vec![user_entry("30", "new tail prompt")],
                doc_ops: None,
            },
        )));
        // Picker still has #10 which is still valid in conv #2
        press_enter(&mut ui, &mut screen);
        assert_eq!(ui.picker.as_ref().unwrap().kind, PickerKind::RootFork);
        press_down(&mut ui, &mut screen); // move to "cancel"
        press_enter(&mut ui, &mut screen);
        assert!(ui.pending_root_fork.is_none());
        assert_eq!(ui.draft.editor.text(), "conv2 draft");

        // 4. Wrong-branch guard on staged ForkEdit
        ui.draft.fork_edit = Some(ForkEdit {
            source_sid: "sess-1".into(),
            source_cid: "1".into(), // mismatch vs ui.target.cid == "2"
            selected_entry_id: "12".into(),
            predecessor_id: 11,
            stashed_draft: Box::new(Draft::default()),
        });
        ui.draft.editor.set("should not send to conv 2");
        ui.send(false);
        assert!(
            ui.note.contains("no longer matches active branch"),
            "note={}",
            ui.note
        );
        assert_eq!(ui.draft.editor.text(), "should not send to conv 2");
        assert!(ui.job.is_none());
        assert_eq!(*posted.lock().unwrap(), 0);

        // 5. While ForkAndSubmit job is in-flight, Esc and Ctrl-C cannot wipe fork_edit/stashed_draft
        ui.draft = Draft::default();
        ui.draft.editor.set("conv2 original");
        load_snapshot(
            &mut ui,
            30,
            vec![user_entry("40", "p1"), user_entry("41", "p2")],
            false,
        );
        ui.command("/fork 41");
        assert!(ui.draft.fork_edit.is_some());
        let (tx, rx) = mpsc::sync_channel(1);
        ui.job = Some(Job {
            result: rx,
            submitted: None,
            source_target: ("sess-1".into(), "2".into()),
        });
        press_esc(&mut ui, &mut screen);
        assert!(ui.note.contains("Wait for pending fork-edit"));
        assert!(ui.draft.fork_edit.is_some());
        ui.key(KeyEvent::new(KeyCode::Char('c'), Mod::CONTROL), &mut screen);
        assert!(ui.draft.fork_edit.is_some());
        tx.send(Ok(Reply::ForkSubmitted {
            target: Target {
                sid: "sess-1".into(),
                cid: "3".into(),
                cwd: "/tmp/proj".into(),
                env_id: "host".into(),
                labels: Default::default(),
            },
            receipt: crate::protocol::CommandReceipt {
                version: Some(1),
                request_id: "r-inflight".into(),
                seq: Some(31),
                submission_id: Some("sub-31".into()),
                conversation_id: Some("3".into()),
                status: Some("placed".into()),
                withdrawn: Vec::new(),
                reason: None,
            },
        }))
        .unwrap();
        wait_job_complete(&mut ui, &mut screen);
        assert_eq!(ui.target.cid, "3");
        assert_eq!(
            ui.saved
                .get(&("sess-1".into(), "2".into()))
                .unwrap()
                .editor
                .text(),
            "conv2 original"
        );
    }

    #[test]
    fn definite_fork_error_preserves_edited_prompt_and_stashed_draft() {
        let (srv, client) = TestServer::bind("definite-err");
        let listener = srv.listener.try_clone().unwrap();

        let handle = thread::spawn(move || loop {
            let (mut stream, _) = listener.accept().unwrap();
            let (head, _body) = read_http_request(&mut stream);
            if head.starts_with("POST /api/v1/sessions/sess-1/commands ") {
                write_json_response(
                    &mut stream,
                    "400 Bad Request",
                    r#"{"error":"entry_not_visible"}"#,
                );
                break;
            } else {
                write_json_response(&mut stream, "404 Not Found", "{}");
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        load_snapshot(
            &mut ui,
            15,
            vec![
                user_entry("10", "first"),
                assistant_entry("11", "first reply"),
                user_entry("12", "second"),
            ],
            false,
        );
        ui.draft.editor.set("keep original");
        ui.command("/fork 12");
        ui.draft.editor.set("my edited replacement");
        press_enter(&mut ui, &mut screen);
        wait_job_complete(&mut ui, &mut screen);
        handle.join().unwrap();

        assert_eq!(ui.target.cid, "1");
        assert!(ui.note.contains("entry_not_visible"), "note={}", ui.note);
        // Definite 400 rejection preserves edited text without trapping user in retry lock
        assert!(ui.draft.retry.is_none());
        assert_eq!(ui.draft.editor.text(), "my edited replacement");
        // Pressing Esc still restores the original stashed draft
        press_esc(&mut ui, &mut screen);
        assert_eq!(ui.draft.editor.text(), "keep original");
    }

    #[test]
    fn name_command_reads_current_name_and_renames_with_expected_seq_and_conflict() {
        let (srv, client) = TestServer::bind("name-cmd");
        let seen_cmds = Arc::new(Mutex::new(Vec::<Value>::new()));
        let seen_srv = Arc::clone(&seen_cmds);
        let listener = srv.listener.try_clone().unwrap();

        let handle = thread::spawn(move || {
            let mut rename_calls = 0usize;
            loop {
                let (mut stream, _) = listener.accept().unwrap();
                let (head, body) = read_http_request(&mut stream);
                if head.starts_with("GET /api/v1/sessions/sess-1 ") {
                    write_json_response(
                        &mut stream,
                        "200 OK",
                        r#"{"session":{"session_id":"sess-1","title":"Current Title","cwd":"/tmp/proj","root_conversation_id":"1"},"conversations":[],"tasks":[]}"#,
                    );
                } else if head.starts_with("POST /api/v1/sessions/sess-1/commands ") {
                    rename_calls += 1;
                    let val: Value = serde_json::from_str(&body).unwrap();
                    let req_id = val["request_id"].as_str().unwrap().to_string();
                    seen_srv.lock().unwrap().push(val);
                    if rename_calls == 1 {
                        let resp = json!({
                            "version": 1,
                            "request_id": req_id,
                            "seq": 16,
                            "status": "done",
                            "title": "Updated Title"
                        })
                        .to_string();
                        write_json_response(&mut stream, "200 OK", &resp);
                    } else {
                        write_json_response(
                            &mut stream,
                            "409 Conflict",
                            r#"{"error":"expected_seq mismatch"}"#,
                        );
                        break;
                    }
                } else {
                    write_json_response(&mut stream, "404 Not Found", "{}");
                }
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");

        // /name before snapshot sync refuses to rename without expected_seq
        ui.command("/name Premature");
        assert!(ui.note.contains("wait for snapshot"), "note={}", ui.note);
        assert!(ui.job.is_none());

        load_snapshot(&mut ui, 15, vec![user_entry("10", "hi")], false);

        // /name with no arg reads current name from GET /sessions/:sid
        ui.command("/name");
        wait_job_complete(&mut ui, &mut screen);
        assert_eq!(ui.note, "Session name: Current Title");

        // /name <title> sends rename command with expected_seq=15
        ui.command("/name Updated Title");
        wait_job_complete(&mut ui, &mut screen);
        assert!(
            ui.note.contains("Renamed session to Updated Title"),
            "note={}",
            ui.note
        );
        assert!(ui.note.contains("seq 16"), "note={}", ui.note);

        // Conflict on stale seq=15 is surfaced cleanly
        ui.command("/name Conflicting Title");
        wait_job_complete(&mut ui, &mut screen);
        assert!(ui.note.contains("conflict"), "note={}", ui.note);
        assert!(
            ui.note.contains("expected_seq mismatch"),
            "note={}",
            ui.note
        );

        handle.join().unwrap();
        let cmds = seen_cmds.lock().unwrap();
        assert_eq!(cmds.len(), 2);
        assert_eq!(cmds[0]["command"], "rename");
        assert_eq!(cmds[0]["args"]["title"], "Updated Title");
        assert_eq!(cmds[0]["args"]["expected_seq"], 15);
        assert_eq!(cmds[1]["args"]["expected_seq"], 15);
    }

    #[test]
    fn slash_tab_filters_cycles_wraps_and_cancels_in_the_editor() {
        let (_srv, client) = TestServer::bind("command-completion");
        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        let tab = KeyEvent::new(KeyCode::Tab, Mod::NONE);
        ui.draft.editor.set("/");
        ui.key(tab, &mut screen);
        assert_eq!(ui.draft.editor.text(), COMMANDS[0].0);
        assert_eq!(
            ui.completion.as_ref().unwrap().lines().len(),
            COMMANDS.len() + 1
        );
        assert!(ui.picker.is_none());
        assert!(ui.job.is_none());
        press_esc(&mut ui, &mut screen);
        assert_eq!(ui.draft.editor.text(), "/");

        // Cursor inside the first token: complete from its prefix, preserve arguments.
        ui.draft.editor.set("/hx argument");
        for _ in 0.."x argument".len() {
            ui.draft.editor.key(KeyEvent::new(KeyCode::Left, Mod::NONE));
        }
        for cmd in ["/harness", "/help", "/hotkeys", "/harness"] {
            ui.key(tab, &mut screen);
            assert_eq!(ui.draft.editor.text(), format!("{cmd} argument"));
            assert_eq!(ui.draft.editor.cursor(), cmd.len());
            assert_eq!(ui.completion.as_ref().unwrap().lines().len(), 4);
        }
        ui.key(KeyEvent::new(KeyCode::Char(' '), Mod::NONE), &mut screen);
        assert!(ui.completion.is_none());
        assert_eq!(ui.draft.editor.text(), "/harness  argument");
        assert!(ui.draft.editor.undo());
        assert!(ui.draft.editor.undo());
        assert_eq!(ui.draft.editor.text(), "/hx argument");
        assert_eq!(ui.draft.editor.cursor(), 2);

        ui.draft.editor.set("/nonexistent");
        ui.key(tab, &mut screen);
        assert_eq!(ui.draft.editor.text(), "/nonexistent");
        assert!(ui.completion.is_none());
        assert!(ui.path_lookup.is_none());
    }

    fn wait_path_lookup(ui: &mut Ui) {
        let deadline = Instant::now() + Duration::from_secs(3);
        while ui.path_lookup.is_some() {
            ui.complete_path_lookup();
            assert!(
                Instant::now() < deadline,
                "timed out waiting for path completion"
            );
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn path_tab_queries_the_target_directory_and_replaces_only_the_current_token() {
        let (srv, client) = TestServer::bind("inline-paths");
        let listener = srv.listener.try_clone().unwrap();
        let server = thread::spawn(move || {
            for (dir, prefix, entries) in [
                (
                    "%2Fremote",
                    "s",
                    json!([
                        {"path": "src", "type": "dir"}, {"path": "scripts", "type": "dir"},
                        {"path": "some.txt", "type": "file"}, {"path": "assets", "type": "dir"},
                        {"path": "sym", "type": "symlink"}
                    ]),
                ),
                (
                    "%2Fremote",
                    "some",
                    json!([{"path": "some.txt", "type": "file"}]),
                ),
                ("%2Fremote%2F", "s", json!([{"path": "src", "type": "dir"}])),
                (
                    "%2Fremote%2Fsrc%2F",
                    "",
                    json!([{"path": "main.rs", "type": "file"}]),
                ),
                (
                    "%2Fremote%2F.%2Fsrc%2F",
                    "m",
                    json!([{"path": "main.rs", "type": "file"}]),
                ),
                (
                    "%2Fremote%2F..%2F",
                    "s",
                    json!([{"path": "sibling", "type": "dir"}]),
                ),
                (
                    "%2Ftmp%2F",
                    "uni",
                    json!([{"path": "unicode 📁", "type": "dir"}]),
                ),
            ] {
                loop {
                    let (mut stream, _) = listener.accept().unwrap();
                    let (head, _) = read_http_request(&mut stream);
                    if !head.starts_with("GET /api/v1/fs/files?") {
                        write_json_response(&mut stream, "404 Not Found", "{}");
                        continue;
                    }
                    let query = if prefix.is_empty() {
                        String::new()
                    } else {
                        format!("&query={prefix}")
                    };
                    assert!(head.starts_with(&format!(
                        "GET /api/v1/fs/files?env_id=vm-1&cwd={dir}&max_depth=1&limit=500&include_hidden=false{query} "
                    )), "{head}");
                    write_json_response(
                        &mut stream,
                        "200 OK",
                        &json!({
                            "env_id": "vm-1", "cwd": "/remote", "entries": entries
                        })
                        .to_string(),
                    );
                    break;
                }
            }
        });
        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        ui.target.cwd = "/remote".into();
        ui.target.env_id = "vm-1".into();
        let tab = KeyEvent::new(KeyCode::Tab, Mod::NONE);
        ui.draft.editor.set("s");
        ui.key(tab, &mut screen);
        wait_path_lookup(&mut ui);
        assert_eq!(ui.draft.editor.text(), "scripts/");
        ui.key(tab, &mut screen);
        assert_eq!(ui.draft.editor.text(), "src/");
        press_esc(&mut ui, &mut screen);
        assert_eq!(ui.draft.editor.text(), "s");

        ui.draft.editor.set("inspect some");
        ui.key(tab, &mut screen);
        wait_path_lookup(&mut ui);
        assert!(ui.completion.is_none());
        assert_eq!(ui.draft.editor.text(), "inspect some");

        ui.draft.editor.set("inspect /remote/s");
        ui.key(tab, &mut screen);
        wait_path_lookup(&mut ui);
        assert_eq!(ui.draft.editor.text(), "inspect /remote/src/");
        ui.key(tab, &mut screen);
        wait_path_lookup(&mut ui);
        assert_eq!(ui.draft.editor.text(), "inspect /remote/src/main.rs");

        for (draft, expected) in [
            ("./src/m", "./src/main.rs"),
            ("/file ../s", "/file ../sibling/"),
            ("👋\n/tmp/uni", "👋\n/tmp/unicode 📁/"),
        ] {
            ui.key(KeyEvent::new(KeyCode::Right, Mod::NONE), &mut screen);
            ui.draft.editor.set(draft);
            ui.key(tab, &mut screen);
            wait_path_lookup(&mut ui);
            assert_eq!(ui.draft.editor.text(), expected);
        }
        server.join().unwrap();
    }

    #[test]
    fn late_path_results_never_overwrite_an_edit_or_a_switched_draft() {
        let (_srv, client) = TestServer::bind("stale-completion");
        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        for switch in [false, true] {
            ui.draft.editor.set("check sr");
            let (tx, result) = mpsc::sync_channel(1);
            ui.path_lookup = Some(PathLookup {
                token: Token::at_cursor(&ui.draft.editor),
                result,
            });
            if switch {
                ui.switch(
                    Target {
                        cid: "2".into(),
                        ..ui.target.clone()
                    },
                    &mut screen,
                );
            } else {
                ui.key(KeyEvent::new(KeyCode::Char('z'), Mod::NONE), &mut screen);
            }
            tx.send(Ok(vec![("src/".into(), "src/".into())])).unwrap();
            assert!(!ui.complete_path_lookup());
            assert!(ui.completion.is_none());
            assert_eq!(
                ui.draft.editor.text(),
                if switch { "" } else { "check srz" }
            );
        }
    }

    #[test]
    fn workspace_tab_and_file_use_session_endpoints_while_attach_stays_client_local() {
        let (srv, client) = TestServer::bind("ws-vs-local");
        let listener = srv.listener.try_clone().unwrap();

        let handle = thread::spawn(move || {
            let mut file_calls = 0usize;
            loop {
                let (mut stream, _) = listener.accept().unwrap();
                let (head, _body) = read_http_request(&mut stream);
                if head.starts_with("GET /api/v1/sessions/sess-1/files?query=su ") {
                    write_json_response(
                        &mut stream,
                        "200 OK",
                        r#"{"env_id":"vm-1","cwd":"/remote","entries":[{"path":"sub","type":"dir","size":0}],"truncated":false}"#,
                    );
                } else if head.starts_with("GET /api/v1/sessions/sess-1/files?query=sub%2F ") {
                    write_json_response(
                        &mut stream,
                        "200 OK",
                        r#"{"env_id":"vm-1","cwd":"/remote","entries":[{"path":"sub/remote.rs","type":"file","size":30}],"truncated":false}"#,
                    );
                } else if head.starts_with("GET /api/v1/sessions/sess-1/file?path=sub%2Fremote.rs ")
                {
                    write_json_response(
                        &mut stream,
                        "200 OK",
                        r#"{"env_id":"vm-1","cwd":"/remote","path":"sub/remote.rs","lines":["pub fn remote() {}"],"start_line":1,"total_lines_read":1,"has_more":false,"truncated_by_bytes":false}"#,
                    );
                } else if head.starts_with("GET /api/v1/sessions/sess-1/files") {
                    file_calls += 1;
                    write_json_response(
                        &mut stream,
                        "503 Service Unavailable",
                        r#"{"error":"workspace unavailable"}"#,
                    );
                    if file_calls >= 1 {
                        break;
                    }
                } else {
                    write_json_response(&mut stream, "404 Not Found", "{}");
                }
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        load_snapshot(&mut ui, 10, vec![user_entry("1", "hi")], false);

        // 1. `@su` + Tab uses GET /sessions/sess-1/files -> workspace files picker, drill into sub/, read remote.rs
        ui.draft.editor.set("@su");
        ui.key(KeyEvent::new(KeyCode::Tab, Mod::NONE), &mut screen);
        wait_job_complete(&mut ui, &mut screen);
        assert_eq!(ui.picker.as_ref().unwrap().kind, PickerKind::WorkspaceFiles);
        press_enter(&mut ui, &mut screen); // picks "sub/" -> drills down
        wait_job_complete(&mut ui, &mut screen);
        assert_eq!(ui.picker.as_ref().unwrap().kind, PickerKind::WorkspaceFiles);
        press_enter(&mut ui, &mut screen); // picks "sub/remote.rs" -> clears @su and reads workspace file
        wait_job_complete(&mut ui, &mut screen);
        assert!(ui.draft.editor.text().is_empty());
        assert_eq!(ui.draft.attachments.len(), 1);
        assert!(
            ui.note.contains("Attached workspace (vm-1) sub/remote.rs"),
            "note={}",
            ui.note
        );
        assert!(
            ui.draft.attachments[0]["text"]
                .as_str()
                .unwrap()
                .contains("pub fn remote() {}"),
            "attachment={:?}",
            ui.draft.attachments[0]
        );

        // 2. `/attach Cargo` + Tab stays strictly client-local ("client files" picker)
        ui.draft.editor.set("/attach Cargo");
        ui.key(KeyEvent::new(KeyCode::Tab, Mod::NONE), &mut screen);
        wait_job_complete(&mut ui, &mut screen);
        let local_picker = ui.picker.as_ref().expect("client files picker");
        assert_eq!(local_picker.kind, PickerKind::ClientFiles);
        assert!(
            local_picker
                .picker
                .lines()
                .join("\n")
                .contains("Cargo.toml"),
            "lines={:?}",
            local_picker.picker.lines()
        );
        press_esc(&mut ui, &mut screen);
        ui.draft.editor.set("");

        // 3. Failure on `@` + Tab (503) never falls back to client-local files
        ui.draft.editor.set("@");
        ui.key(KeyEvent::new(KeyCode::Tab, Mod::NONE), &mut screen);
        wait_job_complete(&mut ui, &mut screen);
        assert!(ui.picker.is_none());
        assert!(ui.note.contains("503"), "note={}", ui.note);

        handle.join().unwrap();
    }

    #[test]
    fn workspace_wait_picker_sends_fenced_actions_and_closes_on_resume() {
        let (srv, client) = TestServer::bind("workspace-wait");
        let listener = srv.listener.try_clone().unwrap();
        let handle = thread::spawn(move || {
            let mut commands = Vec::new();
            while commands.len() < 2 {
                let (mut stream, _) = listener.accept().unwrap();
                let (head, body) = read_http_request(&mut stream);
                if head.starts_with("POST /api/v1/sessions/sess-1/commands ") {
                    let command: Value = serde_json::from_str(&body).unwrap();
                    write_json_response(&mut stream, "200 OK", &json!({
                        "version": 1, "request_id": command["request_id"], "seq": 12, "status": "done"
                    }).to_string());
                    commands.push(command);
                } else {
                    write_json_response(&mut stream, "404 Not Found", "{}");
                }
            }
            commands
        });
        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        let snapshot = |seq, wait: Value| {
            ServerFrame::Snapshot(SnapshotFrame {
                version: Some(1),
                session_id: Some("sess-1".into()),
                conversation_id: Some("1".into()),
                seq,
                before_entry_id: None,
                has_more: Some(false),
                entries: vec![],
                docs: Some(
                    json!({"live": {"run": {}, "workspace_wait": wait}, "agent": {}, "inbox": []}),
                ),
            })
        };
        let wait = json!({"task_id": "42", "lease_id": "lease-a", "holder_session_id": "holder", "holder_conversation_id": "2"});
        ui.update(Update::Frame(snapshot(10, wait.clone())));
        assert_eq!(ui.picker.as_ref().unwrap().kind, PickerKind::WorkspaceWait);
        let lines = ui.picker.as_ref().unwrap().picker.lines().join("\n");
        assert!(lines.contains("Cancel wait"));
        assert!(lines.contains("Stop holder and acquire"));
        let rows = cards::rows(&ui.state, false, false).join("\n");
        assert!(rows.contains("held by holder:2"));
        press_enter(&mut ui, &mut screen);
        wait_job_complete(&mut ui, &mut screen);

        ui.workspace_wait_menu();
        ui.pick_key(KeyEvent::new(KeyCode::Down, Mod::NONE), &mut screen);
        press_enter(&mut ui, &mut screen);
        wait_job_complete(&mut ui, &mut screen);
        ui.workspace_wait_menu();
        ui.update(Update::Frame(snapshot(13, Value::Null)));
        assert!(ui.picker.is_none(), "stale actions close after resume");
        let commands = handle.join().unwrap();
        for (command, action) in commands.iter().zip(["cancel", "stop_holder"]) {
            assert_eq!(command["command"], "workspace_wait");
            assert_eq!(
                command["args"],
                json!({"action": action, "task_id": "42", "lease_id": "lease-a"})
            );
        }
    }

    #[test]
    fn user_shell_wiring_excludes_attachments_never_falls_back_or_retries_and_supports_esc_cancel()
    {
        let (srv, client) = TestServer::bind("app-shell");
        let seen_cmds = Arc::new(Mutex::new(Vec::<Value>::new()));
        let seen_srv = Arc::clone(&seen_cmds);
        let listener = srv.listener.try_clone().unwrap();

        let handle = thread::spawn(move || {
            let mut post_count = 0usize;
            loop {
                let (mut stream, _) = listener.accept().unwrap();
                let (head, body) = read_http_request(&mut stream);
                if head.starts_with("POST /api/v1/sessions/sess-1/commands ") {
                    post_count += 1;
                    let val: Value = serde_json::from_str(&body).unwrap();
                    let req_id = val["request_id"].as_str().unwrap().to_string();
                    seen_srv.lock().unwrap().push(val);
                    match post_count {
                        1 => {
                            write_json_response(
                                &mut stream,
                                "200 OK",
                                &json!({
                                    "version": 1,
                                    "request_id": req_id,
                                    "seq": 11,
                                    "submission_id": "sub-s1",
                                    "status": "placed"
                                })
                                .to_string(),
                            );
                        }
                        2 => {
                            // Abort from Esc
                            write_json_response(
                                &mut stream,
                                "200 OK",
                                &json!({
                                    "version": 1,
                                    "request_id": req_id,
                                    "seq": 12,
                                    "status": "done"
                                })
                                .to_string(),
                            );
                        }
                        3 => {
                            // Ambiguous I/O drop on !!cmd -> must NOT set retry or fall back to submit
                            drop(stream);
                            break;
                        }
                        _ => unreachable!(),
                    }
                } else {
                    write_json_response(&mut stream, "404 Not Found", "{}");
                }
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        load_snapshot(&mut ui, 10, vec![user_entry("1", "hi")], false);
        ui.draft
            .attachments
            .push(json!({"type": "text", "text": "<file name=\"a.txt\">secret</file>"}));

        // Empty ! or !! never submits to model
        ui.draft.editor.set("!");
        ui.send(false);
        assert!(
            ui.note.contains("Enter a shell command"),
            "note={}",
            ui.note
        );
        assert!(ui.job.is_none());
        ui.draft.editor.set("!!");
        ui.send(true);
        assert!(
            ui.note.contains("Enter a shell command"),
            "note={}",
            ui.note
        );
        assert!(ui.job.is_none());

        // !ls -la sends user_shell with include_in_context=true, expected_seq=10, and keeps attachments excluded
        ui.draft.editor.set("!ls -la");
        press_enter(&mut ui, &mut screen);
        wait_job_complete(&mut ui, &mut screen);
        assert_eq!(
            ui.draft.attachments.len(),
            1,
            "attachment kept in draft, excluded from shell"
        );
        assert!(ui.draft.editor.text().is_empty());

        // Live user_shell commit renders active status & allows Esc abort
        ui.update(Update::Frame(ServerFrame::Commit(
            crate::protocol::CommitFrame {
                version: Some(1),
                session_id: Some("sess-1".into()),
                conversation_id: Some("1".into()),
                prev_seq: Some(10),
                seq: 11,
                appended_entries: vec![],
                doc_ops: Some(
                    serde_json::from_value(json!({
                        "live": [["replace", {
                            "user_shell": {
                                "task_id": "5",
                                "command": "ls -la",
                                "include_in_context": true,
                                "status": "running",
                                "output": "file1\n"
                            }
                        }]]
                    }))
                    .unwrap(),
                ),
            },
        )));
        assert!(ui.state.is_run_active());
        ui.draw(&mut screen).unwrap();
        let rendered: String = (0..24)
            .map(|y| {
                (0..80)
                    .map(|x| {
                        screen
                            .test_backend()
                            .buffer()
                            .cell((x, y))
                            .map(|c| c.symbol())
                            .unwrap_or(" ")
                    })
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert!(rendered.contains("shell !ls -la (running)"), "{rendered}");
        assert!(
            rendered.contains("[shell (live · running)] !ls -la"),
            "{rendered}"
        );

        // Esc sends Abort while live.user_shell is active
        press_esc(&mut ui, &mut screen);
        wait_job_complete(&mut ui, &mut screen);

        // Update state seq=12 (live cleared), then !!cmd suffers ambiguous drop -> no blind retry
        ui.update(Update::Frame(ServerFrame::Commit(
            crate::protocol::CommitFrame {
                version: Some(1),
                session_id: Some("sess-1".into()),
                conversation_id: Some("1".into()),
                prev_seq: Some(11),
                seq: 12,
                appended_entries: vec![],
                doc_ops: Some(
                    serde_json::from_value(json!({ "live": [["replace", {}]] })).unwrap(),
                ),
            },
        )));
        ui.draft.editor.set("!!rm -rf /tmp/x");
        ui.send(true); // Alt-Enter path
        wait_job_complete(&mut ui, &mut screen);
        assert!(ui.note.contains("outcome unknown"), "note={}", ui.note);
        assert!(
            ui.draft.retry.is_none(),
            "must NOT set retry for unsafe user_shell"
        );
        assert_eq!(ui.draft.editor.text(), "!!rm -rf /tmp/x");

        handle.join().unwrap();
        let cmds = seen_cmds.lock().unwrap();
        assert_eq!(cmds.len(), 3);
        assert_eq!(cmds[0]["command"], "user_shell");
        assert_eq!(cmds[0]["args"]["command"], "ls -la");
        assert_eq!(cmds[0]["args"]["include_in_context"], true);
        assert_eq!(cmds[0]["args"]["expected_seq"], 10);
        assert_eq!(cmds[1]["command"], "abort");
        assert_eq!(cmds[2]["command"], "user_shell");
        assert_eq!(cmds[2]["args"]["command"], "rm -rf /tmp/x");
        assert_eq!(cmds[2]["args"]["include_in_context"], false);
        assert_eq!(cmds[2]["args"]["expected_seq"], 12);
    }

    #[test]
    fn compact_command_sends_expected_seq_and_optional_instructions() {
        let (srv, client) = TestServer::bind("app-compact");
        let seen_cmds = Arc::new(Mutex::new(Vec::<Value>::new()));
        let seen_srv = Arc::clone(&seen_cmds);
        let listener = srv.listener.try_clone().unwrap();

        let handle = thread::spawn(move || {
            let mut count = 0usize;
            loop {
                let (mut stream, _) = listener.accept().unwrap();
                let (head, body) = read_http_request(&mut stream);
                if head.starts_with("POST /api/v1/sessions/sess-1/commands ") {
                    count += 1;
                    let val: Value = serde_json::from_str(&body).unwrap();
                    let req_id = val["request_id"].as_str().unwrap().to_string();
                    seen_srv.lock().unwrap().push(val);
                    write_json_response(
                        &mut stream,
                        "200 OK",
                        &json!({
                            "version": 1,
                            "request_id": req_id,
                            "seq": 10 + count,
                            "status": "started"
                        })
                        .to_string(),
                    );
                    if count == 2 {
                        break;
                    }
                } else {
                    write_json_response(&mut stream, "404 Not Found", "{}");
                }
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        ui.command("/compact");
        assert!(ui.note.contains("wait for snapshot"), "note={}", ui.note);

        load_snapshot(&mut ui, 10, vec![user_entry("1", "hi")], false);
        ui.command("/compact");
        wait_job_complete(&mut ui, &mut screen);
        assert!(ui.note.contains("seq 11"), "note={}", ui.note);

        ui.update(Update::Frame(ServerFrame::Commit(
            crate::protocol::CommitFrame {
                version: Some(1),
                session_id: Some("sess-1".into()),
                conversation_id: Some("1".into()),
                prev_seq: Some(10),
                seq: 11,
                appended_entries: vec![],
                doc_ops: None,
            },
        )));
        ui.command("/compact focus on API contract");
        wait_job_complete(&mut ui, &mut screen);
        assert!(ui.note.contains("seq 12"), "note={}", ui.note);

        handle.join().unwrap();
        let cmds = seen_cmds.lock().unwrap();
        assert_eq!(cmds.len(), 2);
        assert_eq!(cmds[0]["command"], "compact");
        assert_eq!(cmds[0]["args"], json!({"expected_seq": 10}));
        assert_eq!(cmds[1]["command"], "compact");
        assert_eq!(
            cmds[1]["args"],
            json!({"expected_seq": 11, "instructions": "focus on API contract"})
        );
    }

    #[test]
    fn inbox_navigation_ctrl_d_contract_and_draft_preservation() {
        let (srv, client) = TestServer::bind("app-inbox");
        let listener = srv.listener.try_clone().unwrap();
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop_srv = Arc::clone(&stop);

        let handle = thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            while !stop_srv.load(std::sync::atomic::Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let _ = stream.set_nonblocking(false);
                        let (head, _body) = read_http_request(&mut stream);
                        let (status, body) = if head.starts_with("GET /api/v1/sessions/sess-2 ") {
                            (
                                "200 OK",
                                json!({
                                    "session": {
                                        "session_id": "sess-2",
                                        "title": "Second",
                                        "env_id": "host",
                                        "harness_id": "coding",
                                        "cwd": "/tmp/proj",
                                        "root_conversation_id": "1",
                                        "active": false,
                                        "attention": "idle",
                                        "status": "ok"
                                    },
                                    "conversations": [{"id": "1", "parent": null, "owner": "ownerless"}],
                                    "tasks": []
                                })
                                .to_string(),
                            )
                        } else {
                            ("404 Not Found", "{}".to_string())
                        };
                        let _ = write!(
                            stream,
                            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
                            body.len()
                        );
                        let _ = stream.flush();
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        });

        // 1. Direct session launch (entered_from_inbox == false): Ctrl-D exits immediately
        let (mut ui_direct, mut screen_direct) = make_ui(client.clone(), "sess-1", "1");
        assert!(!ui_direct.entered_from_inbox);
        ui_direct.key(
            KeyEvent::new(KeyCode::Char('d'), Mod::CONTROL),
            &mut screen_direct,
        );
        assert!(ui_direct.quit);
        assert!(ui_direct.inbox.is_none());

        // 2. Entering inbox via Alt+I saves draft, drops conversation sub, preselects sess-1
        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        ui.draft.editor.set("wip draft");
        ui.key(KeyEvent::new(KeyCode::Char('i'), Mod::ALT), &mut screen);
        assert!(ui.inbox.is_some());
        assert!(ui.sub.is_none());
        assert!(ui.entered_from_inbox);
        assert_eq!(
            ui.saved
                .get(&("sess-1".into(), "1".into()))
                .unwrap()
                .editor
                .text(),
            "wip draft"
        );

        // Inject catalog snapshot with running, idle, quarantined sessions
        {
            let inbox = ui.inbox.as_mut().unwrap();
            inbox
                .state
                .apply(super::super::inbox::CatalogUpdate::Online);
            inbox
                .state
                .apply(super::super::inbox::CatalogUpdate::Snapshot(vec![
                    crate::protocol::SessionSummary {
                        session_id: "sess-1".into(),
                        title: Some("First".into()),
                        env_id: Some("host".into()),
                        harness_id: Some("coding".into()),
                        cwd: "/tmp/proj".into(),
                        root_conversation_id: Some("1".into()),
                        created_at: Some(1),
                        updated_at: Some(1),
                        active: false,
                        attention: Some("idle".into()),
                        activity_kind: None,
                        activity_label: None,
                        queued_count: 0,
                        next_wake_at: None,
                        status: Some("ok".into()),
                        parent: None,
                        role: None,
                        needs_attention: Some(true),
                        archived: false,
                        loaded: Some(true),
                        cwd_exists: Some(true),
                    },
                    crate::protocol::SessionSummary {
                        session_id: "sess-run".into(),
                        title: Some("Busy".into()),
                        env_id: Some("host".into()),
                        harness_id: Some("coding".into()),
                        cwd: "/tmp/proj".into(),
                        root_conversation_id: Some("1".into()),
                        created_at: Some(2),
                        updated_at: Some(2),
                        active: true,
                        attention: Some("running".into()),
                        activity_kind: Some("tool".into()),
                        activity_label: Some("bash".into()),
                        queued_count: 0,
                        next_wake_at: None,
                        status: Some("ok".into()),
                        parent: None,
                        role: None,
                        needs_attention: Some(false),
                        archived: false,
                        loaded: Some(true),
                        cwd_exists: Some(true),
                    },
                    crate::protocol::SessionSummary {
                        session_id: "sess-2".into(),
                        title: Some("Second".into()),
                        env_id: Some("host".into()),
                        harness_id: Some("coding".into()),
                        cwd: "/tmp/proj".into(),
                        root_conversation_id: Some("1".into()),
                        created_at: Some(3),
                        updated_at: Some(3),
                        active: false,
                        attention: Some("idle".into()),
                        activity_kind: None,
                        activity_label: None,
                        queued_count: 0,
                        next_wake_at: None,
                        status: Some("ok".into()),
                        parent: None,
                        role: None,
                        needs_attention: Some(true),
                        archived: false,
                        loaded: Some(true),
                        cwd_exists: Some(true),
                    },
                    crate::protocol::SessionSummary {
                        session_id: "sess-q".into(),
                        title: Some("Broken".into()),
                        env_id: Some("host".into()),
                        harness_id: Some("coding".into()),
                        cwd: "/tmp/proj".into(),
                        root_conversation_id: Some("1".into()),
                        created_at: Some(4),
                        updated_at: Some(4),
                        active: false,
                        attention: Some("quarantined".into()),
                        activity_kind: None,
                        activity_label: Some("corrupt".into()),
                        queued_count: 0,
                        next_wake_at: None,
                        status: Some("quarantined".into()),
                        parent: None,
                        role: None,
                        needs_attention: Some(true),
                        archived: false,
                        loaded: Some(true),
                        cwd_exists: Some(true),
                    },
                ]));
            // Ordered by tier: sess-q (tier 0), sess-1 (tier 1), sess-2 (tier 1), sess-run (tier 2)
            assert_eq!(inbox.state.selected_id(), Some("sess-1"));
        }

        // Tab skips sess-run and lands on sess-2
        ui.inbox_key(KeyEvent::new(KeyCode::Tab, Mod::NONE));
        assert_eq!(
            ui.inbox.as_ref().unwrap().state.selected_id(),
            Some("sess-2")
        );

        // Next Tab wraps to sess-q (tier 0 quarantined)
        ui.inbox_key(KeyEvent::new(KeyCode::Tab, Mod::NONE));
        assert_eq!(
            ui.inbox.as_ref().unwrap().state.selected_id(),
            Some("sess-q")
        );
        // Enter on quarantined session shows clear note and stays in inbox
        ui.inbox_key(KeyEvent::new(KeyCode::Enter, Mod::NONE));
        assert!(ui.inbox.is_some());
        assert!(ui.note.contains("quarantined"), "note={}", ui.note);

        // Move down twice (sess-q -> sess-1 -> sess-2) and press Enter -> attaches to sess-2
        ui.inbox_key(KeyEvent::new(KeyCode::Char('j'), Mod::NONE));
        ui.inbox_key(KeyEvent::new(KeyCode::Char('j'), Mod::NONE));
        assert_eq!(
            ui.inbox.as_ref().unwrap().state.selected_id(),
            Some("sess-2")
        );
        ui.inbox_key(KeyEvent::new(KeyCode::Enter, Mod::NONE));
        wait_job_complete(&mut ui, &mut screen);
        assert!(ui.inbox.is_none());
        assert!(ui.sub.is_some());
        assert_eq!(ui.target.sid, "sess-2");
        assert!(ui.entered_from_inbox);

        // Ctrl-D in session mode returns to inbox (since entered_from_inbox == true)
        ui.key(KeyEvent::new(KeyCode::Char('d'), Mod::CONTROL), &mut screen);
        assert!(!ui.quit);
        assert!(ui.inbox.is_some());
        assert_eq!(
            ui.inbox.as_ref().unwrap().state.selected_id(),
            Some("sess-2")
        );

        // Ctrl-D in inbox mode exits cleanly
        ui.inbox_key(KeyEvent::new(KeyCode::Char('d'), Mod::CONTROL));
        assert!(ui.quit);

        // /quit in session mode always exits even when entered_from_inbox == true
        ui.quit = false;
        ui.inbox = None;
        ui.entered_from_inbox = true;
        ui.command("/quit");
        assert!(ui.quit);

        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        drop(ui);
        drop(ui_direct);
        let _ = handle.join();
    }

    #[test]
    fn inbox_t_toggles_subsessions_and_parent_command_and_alt_p_jump_to_parent_conversation() {
        let (srv, client) = TestServer::bind("app-parent-subsessions");
        let listener = srv.listener.try_clone().unwrap();
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop_srv = Arc::clone(&stop);

        let handle = thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            while !stop_srv.load(std::sync::atomic::Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let _ = stream.set_nonblocking(false);
                        let (head, _body) = read_http_request(&mut stream);
                        if head.starts_with("GET /api/v1/sessions/parent-1 ") {
                            let body = r#"{"session":{"session_id":"parent-1","title":"Parent Root","env_id":"host","cwd":"/tmp/proj","root_conversation_id":"1","active":false,"status":"ok"},"conversations":[{"id":"1"},{"id":"2"}],"tasks":[]}"#;
                            write_json_response(&mut stream, "200 OK", body);
                        } else {
                            write_json_response(&mut stream, "200 OK", r#"{"sessions":[]}"#);
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        });

        // 1. Root session: /parent and Alt+P show clear note when no parent exists
        let (mut ui, mut screen) = make_ui(client.clone(), "root-1", "1");
        ui.command("/parent");
        assert_eq!(ui.note, "Current session has no parent session");
        ui.note.clear();
        ui.key(KeyEvent::new(KeyCode::Char('p'), Mod::ALT), &mut screen);
        assert_eq!(ui.note, "Current session has no parent session");

        // 2. Subsession: /parent jumps to parent session & conversation #2
        ui.target.sid = "sub-1".into();
        ui.target.cid = "1".into();
        ui.target.labels.parent = Some(crate::protocol::SessionParent {
            session_id: "parent-1".into(),
            conversation_id: Some("2".into()),
            at_entry_id: Some("10".into()),
            task_id: None,
            depth: Some(1),
        });
        ui.command("/parent");
        wait_job_complete(&mut ui, &mut screen);
        assert_eq!(ui.target.sid, "parent-1");
        assert_eq!(ui.target.cid, "2");
        assert!(ui.target.labels.parent.is_none());

        // 3. Alt+P from subsession also jumps to parent session & conversation #2
        ui.target.sid = "sub-2".into();
        ui.target.cid = "1".into();
        ui.target.labels.parent = Some(crate::protocol::SessionParent {
            session_id: "parent-1".into(),
            conversation_id: Some("2".into()),
            at_entry_id: None,
            task_id: None,
            depth: Some(1),
        });
        ui.key(KeyEvent::new(KeyCode::Char('p'), Mod::ALT), &mut screen);
        wait_job_complete(&mut ui, &mut screen);
        assert_eq!(ui.target.sid, "parent-1");
        assert_eq!(ui.target.cid, "2");

        // 4. In inbox mode, `t` toggles show_subsessions and sets clear note
        ui.enter_inbox();
        assert!(!ui.inbox.as_ref().unwrap().state.show_subsessions());
        ui.inbox_key(KeyEvent::new(KeyCode::Char('t'), Mod::NONE));
        assert!(ui.inbox.as_ref().unwrap().state.show_subsessions());
        assert_eq!(ui.note, "Subsessions: shown");
        ui.inbox_key(KeyEvent::new(KeyCode::Char('t'), Mod::NONE));
        assert!(!ui.inbox.as_ref().unwrap().state.show_subsessions());
        assert_eq!(ui.note, "Subsessions: hidden");

        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        drop(ui);
        let _ = handle.join();
    }

    #[test]
    fn missing_cwd_guard_and_cwd_fork_preserves_draft_and_switches_session() {
        let (srv, client) = TestServer::bind("cwd-fork");
        let seen_reqs = Arc::new(Mutex::new(Vec::<(String, Value)>::new()));
        let seen_srv = Arc::clone(&seen_reqs);
        let listener = srv.listener.try_clone().unwrap();
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop_srv = Arc::clone(&stop);

        let handle = thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            while !stop_srv.load(std::sync::atomic::Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let _ = stream.set_nonblocking(false);
                        let (head, body) = read_http_request(&mut stream);
                        if head.starts_with("POST /api/v1/sessions/sess-1/fork ") {
                            let val: Value = serde_json::from_str(&body).unwrap();
                            let new_cwd = val["cwd"].as_str().unwrap().to_string();
                            seen_srv.lock().unwrap().push((head.clone(), val));
                            let resp = json!({
                                "session": {
                                    "session_id": "sess-forked",
                                    "title": "Demo",
                                    "env_id": "host",
                                    "harness_id": "coding",
                                    "cwd": new_cwd,
                                    "root_conversation_id": "1",
                                    "active": false,
                                    "attention": "idle",
                                    "needs_attention": true,
                                    "archived": false,
                                    "loaded": true,
                                    "cwd_exists": true,
                                    "status": "ok"
                                },
                                "seq": 5
                            })
                            .to_string();
                            write_json_response(&mut stream, "200 OK", &resp);
                        } else if head.starts_with("POST /api/v1/sessions/sess-1/commands ") {
                            let val: Value = serde_json::from_str(&body).unwrap();
                            seen_srv.lock().unwrap().push((head.clone(), val));
                            write_json_response(
                                &mut stream,
                                "409 Conflict",
                                r#"{"error":"cwd_missing"}"#,
                            );
                        } else {
                            write_json_response(&mut stream, "404 Not Found", "{}");
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        load_snapshot(&mut ui, 10, vec![user_entry("1", "hi")], false);

        // 1. Live session encounters 409 cwd_missing from daemon -> flips cwd_exists=false, retains draft, no retry lock
        ui.draft.editor.set("unsent prompt after delete");
        ui.send(false);
        wait_job_complete(&mut ui, &mut screen);
        assert!(!ui.target.labels.cwd_exists);
        assert_eq!(ui.draft.editor.text(), "unsent prompt after delete");
        assert!(ui.draft.retry.is_none());
        assert!(ui.note.contains("/cwd <path>"), "note={}", ui.note);

        // 2. Subsequent local sends/continue/compact are immediately blocked with /cwd hint
        ui.send(false);
        assert!(ui.job.is_none());
        assert!(ui.note.contains("/cwd <path>"), "note={}", ui.note);

        ui.command("/continue");
        assert!(ui.job.is_none());
        assert!(ui.note.contains("/cwd <path>"), "note={}", ui.note);

        ui.command("/compact");
        assert!(ui.job.is_none());
        assert!(ui.note.contains("/cwd <path>"), "note={}", ui.note);

        // /cwd with no args prints missing status
        ui.command("/cwd");
        assert!(ui.note.contains("missing"), "note={}", ui.note);

        // 3. /cwd /tmp/valid-dir forks session, switches to sess-forked, AND carries over the unsent draft!
        ui.command("/cwd /tmp/valid-dir");
        wait_job_complete(&mut ui, &mut screen);
        assert_eq!(ui.target.sid, "sess-forked");
        assert_eq!(ui.target.cwd, "/tmp/valid-dir");
        assert!(ui.target.labels.cwd_exists);
        assert_eq!(ui.draft.editor.text(), "unsent prompt after delete");
        assert!(ui.note.contains("/tmp/valid-dir"), "note={}", ui.note);

        // 4. Native archived session shows activity="archived" (not "idle") while allowing /archive off or prompts;
        //    imported archive (status == "archived") is read-only.
        ui.target.labels.status = Some("ok".into());
        ui.target.labels.archived = true;
        let rendered_status = ui.config.status.render(&ui.status_fields());
        assert!(
            rendered_status[0].contains("archived"),
            "status={rendered_status:?}"
        );
        ui.command("/archive");
        assert!(ui.note.contains("already archived"), "note={}", ui.note);

        ui.target.labels.status = Some("archived".into());
        let rendered_imported = ui.config.status.render(&ui.status_fields());
        assert!(
            rendered_imported[0].contains("archived"),
            "status={rendered_imported:?}"
        );
        ui.send(false);
        assert!(ui.job.is_none());
        assert!(
            ui.note.contains("Imported archive is read-only"),
            "note={}",
            ui.note
        );

        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        drop(ui);
        let _ = handle.join();

        let reqs = seen_reqs.lock().unwrap();
        assert_eq!(reqs.len(), 2);
        assert!(reqs[1].0.starts_with("POST /api/v1/sessions/sess-1/fork "));
        assert_eq!(reqs[1].1["cwd"], "/tmp/valid-dir");
        assert_eq!(reqs[1].1["conversation_id"], 1);
    }

    #[test]
    fn attention_archive_and_stop_commands_return_to_inbox_or_quit() {
        let (srv, client) = TestServer::bind("triage-archive");
        let seen = Arc::new(Mutex::new(Vec::<(String, Value)>::new()));
        let seen_srv = Arc::clone(&seen);
        let listener = srv.listener.try_clone().unwrap();
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop_srv = Arc::clone(&stop);

        let handle = thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            let mut archive_calls = 0usize;
            while !stop_srv.load(std::sync::atomic::Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let _ = stream.set_nonblocking(false);
                        let (head, body) = read_http_request(&mut stream);
                        if head.starts_with("POST /api/v1/sessions/sess-1/triage ") {
                            let val: Value = serde_json::from_str(&body).unwrap();
                            let na = val["needs_attention"].as_bool().unwrap();
                            seen_srv.lock().unwrap().push((head.clone(), val));
                            write_json_response(
                                &mut stream,
                                "200 OK",
                                &json!({
                                    "session": {
                                        "session_id": "sess-1",
                                        "cwd": "/tmp/proj",
                                        "active": false,
                                        "attention": "idle",
                                        "needs_attention": na,
                                        "archived": false,
                                        "loaded": true,
                                        "cwd_exists": true,
                                        "status": "ok"
                                    }
                                })
                                .to_string(),
                            );
                        } else if head.starts_with("POST /api/v1/sessions/sess-1/archive ") {
                            archive_calls += 1;
                            let val: Value = serde_json::from_str(&body).unwrap();
                            seen_srv.lock().unwrap().push((head.clone(), val.clone()));
                            if archive_calls == 1 && !val["stop"].as_bool().unwrap_or(false) {
                                write_json_response(
                                    &mut stream,
                                    "409 Conflict",
                                    r#"{"error":"session_busy"}"#,
                                );
                            } else {
                                write_json_response(
                                    &mut stream,
                                    "200 OK",
                                    &json!({
                                        "session": {
                                            "session_id": "sess-1",
                                            "cwd": "/tmp/proj",
                                            "active": false,
                                            "attention": "idle",
                                            "needs_attention": false,
                                            "archived": true,
                                            "loaded": false,
                                            "cwd_exists": true,
                                            "status": "ok"
                                        }
                                    })
                                    .to_string(),
                                );
                            }
                        } else {
                            write_json_response(&mut stream, "404 Not Found", "{}");
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        ui.entered_from_inbox = true;

        // /attention off updates target.labels.needs_attention
        ui.command("/attention off");
        wait_job_complete(&mut ui, &mut screen);
        assert!(!ui.target.labels.needs_attention);
        assert_eq!(ui.note, "Marked as not needing attention");

        // /archive when busy surfaces helpful hint
        ui.command("/archive");
        wait_job_complete(&mut ui, &mut screen);
        assert!(ui.note.contains("/archive force"), "note={}", ui.note);
        assert!(ui.inbox.is_none());

        // /archive force succeeds and returns to Inbox since entered_from_inbox == true
        ui.command("/archive force");
        wait_job_complete(&mut ui, &mut screen);
        assert!(ui.inbox.is_some());
        assert!(!ui.quit);
        assert!(ui.note.contains("Archived sess-1"), "note={}", ui.note);

        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        drop(ui);
        let _ = handle.join();

        let reqs = seen.lock().unwrap();
        assert_eq!(reqs.len(), 3);
        assert_eq!(reqs[0].1["needs_attention"], false);
        assert_eq!(reqs[1].1["stop"], false);
        assert_eq!(reqs[2].1["stop"], true);
    }

    #[test]
    fn cwd_tab_completes_directories_using_launch_cwd_when_session_cwd_is_missing() {
        let (srv, client) = TestServer::bind("cwd-tab");
        let listener = srv.listener.try_clone().unwrap();
        let server = thread::spawn(move || loop {
            let (mut stream, _) = listener.accept().unwrap();
            let (head, _) = read_http_request(&mut stream);
            if !head.starts_with("GET /api/v1/fs/files?") {
                write_json_response(&mut stream, "404 Not Found", "{}");
                continue;
            }
            assert!(
                    head.starts_with(
                        "GET /api/v1/fs/files?env_id=host&cwd=%2Ftmp%2Flaunch&max_depth=1&limit=500&include_hidden=false&query=pr "
                    ),
                    "{head}"
                );
            write_json_response(
                &mut stream,
                "200 OK",
                &json!({
                    "env_id": "host",
                    "cwd": "/tmp/launch",
                    "entries": [
                        {"path": "project-a", "type": "dir"},
                        {"path": "prompt.txt", "type": "file"}
                    ]
                })
                .to_string(),
            );
            break;
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        ui.launch_cwd = "/tmp/launch".into();
        ui.target.cwd = "/tmp/deleted".into();
        ui.target.labels.cwd_exists = false;

        ui.draft.editor.set("/cwd pr");
        ui.key(KeyEvent::new(KeyCode::Tab, Mod::NONE), &mut screen);
        wait_path_lookup(&mut ui);
        // Only directories are offered for /cwd completion (files like prompt.txt are filtered out)
        assert_eq!(ui.draft.editor.text(), "/cwd project-a/");
        assert_eq!(ui.completion.as_ref().unwrap().lines().len(), 2);

        server.join().unwrap();
    }

    #[test]
    fn tree_command_fetches_step_tree_branches_from_sibling_and_keeps_branches_list() {
        let (srv, client) = TestServer::bind("tree-flow");
        let listener = srv.listener.try_clone().unwrap();
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop_srv = Arc::clone(&stop);
        let posted = Arc::new(Mutex::new(Vec::<Value>::new()));
        let posted_srv = Arc::clone(&posted);

        let handle = thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            while !stop_srv.load(std::sync::atomic::Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let _ = stream.set_nonblocking(false);
                        let (head, body) = read_http_request(&mut stream);
                        if head.starts_with("GET /api/v1/sessions/sess-1/tree ") {
                            let resp = json!({
                                "session": {
                                    "session_id": "sess-1",
                                    "cwd": "/tmp/proj",
                                    "root_conversation_id": "1",
                                    "active": false
                                },
                                "conversations": [
                                    {"id": "1", "parent": null, "owner": "ownerless", "leaf_entry_id": "4"},
                                    {"id": "2", "parent": {"conversation_id": "1", "at": "2"}, "owner": "ownerless", "leaf_entry_id": "6"}
                                ],
                                "nodes": [
                                    {"id": "1", "parent_id": null, "conversation_id": "1", "kind": "user", "preview": "Root", "has_text": true},
                                    {"id": "2", "parent_id": "1", "conversation_id": "1", "kind": "assistant", "preview": "Shared", "has_text": true},
                                    {"id": "3", "parent_id": "2", "conversation_id": "1", "kind": "user", "preview": "Main step", "has_text": true},
                                    {"id": "4", "parent_id": "3", "conversation_id": "1", "kind": "assistant", "preview": "Main leaf", "has_text": true},
                                    {"id": "5", "parent_id": "2", "conversation_id": "2", "kind": "user", "preview": "Sibling prompt", "has_text": true},
                                    {"id": "6", "parent_id": "5", "conversation_id": "2", "kind": "assistant", "preview": "Sibling leaf", "has_text": true}
                                ],
                                "truncated": false
                            });
                            write_json_response(&mut stream, "200 OK", &resp.to_string());
                        } else if head.starts_with("GET /api/v1/sessions/sess-1 ") {
                            let resp = json!({
                                "session": {
                                    "session_id": "sess-1",
                                    "cwd": "/tmp/proj",
                                    "root_conversation_id": "1",
                                    "active": false
                                },
                                "conversations": [
                                    {"id": "1", "parent": null, "owner": "ownerless"},
                                    {"id": "2", "parent": {"conversation_id": "1", "at": "2"}, "owner": "ownerless"}
                                ],
                                "tasks": []
                            });
                            write_json_response(&mut stream, "200 OK", &resp.to_string());
                        } else if head.starts_with("POST /api/v1/sessions/sess-1/commands ") {
                            let val: Value = serde_json::from_str(&body).unwrap();
                            posted_srv.lock().unwrap().push(val);
                            let receipt = json!({
                                "version": 1,
                                "request_id": "r-fork",
                                "seq": 9,
                                "conversation_id": "3",
                                "status": "forked"
                            });
                            write_json_response(&mut stream, "200 OK", &receipt.to_string());
                        } else {
                            write_json_response(&mut stream, "404 Not Found", "{}");
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        load_snapshot(
            &mut ui,
            4,
            vec![
                user_entry("1", "Root"),
                assistant_entry("2", "Shared"),
                user_entry("3", "Main step"),
                assistant_entry("4", "Main leaf"),
            ],
            false,
        );

        // 1. /branches still opens flat conversation picker
        ui.command("/branches");
        wait_job_complete(&mut ui, &mut screen);
        assert_eq!(
            ui.picker.as_ref().map(|p| p.kind),
            Some(PickerKind::Branches)
        );
        ui.pick_key(KeyEvent::new(KeyCode::Esc, Mod::NONE), &mut screen);
        assert!(ui.picker.is_none());

        // 2. /tree opens step TreeSelector focused on current leaf #4
        ui.command("/tree");
        wait_job_complete(&mut ui, &mut screen);
        assert!(ui.tree.is_some());
        assert_eq!(
            ui.tree
                .as_ref()
                .and_then(|t| t.selector.selected_node())
                .map(|n| n.id.as_str()),
            Some("4")
        );

        // 3. Move down to sibling user step #5 (owned by conversation #2, NOT active #1)
        ui.tree_key(KeyEvent::new(KeyCode::Down, Mod::NONE), &mut screen);
        assert_eq!(
            ui.tree
                .as_ref()
                .and_then(|t| t.selector.selected_node())
                .map(|n| n.id.as_str()),
            Some("5")
        );
        // Enter opens TreeAction picker for user step #5
        ui.tree_key(KeyEvent::new(KeyCode::Enter, Mod::NONE), &mut screen);
        assert!(ui.tree.is_none());
        assert_eq!(
            ui.picker.as_ref().map(|p| p.kind),
            Some(PickerKind::TreeAction)
        );
        // Move down to "Branch after #5 (keep prompt, new conversation)" and confirm
        ui.pick_key(KeyEvent::new(KeyCode::Down, Mod::NONE), &mut screen);
        ui.pick_key(KeyEvent::new(KeyCode::Enter, Mod::NONE), &mut screen);
        wait_job_complete(&mut ui, &mut screen);

        // Verify fork command targeted conversation_id = 2 (owner of #5), not active #1!
        let cmds = posted.lock().unwrap();
        assert_eq!(cmds.len(), 1);
        assert_eq!(cmds[0]["command"], "fork");
        assert_eq!(cmds[0]["conversation_id"], 2);
        assert_eq!(cmds[0]["args"]["at_entry_id"], 5);
        assert_eq!(ui.target.cid, "3");

        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        drop(ui);
        let _ = handle.join();
    }

    #[test]
    fn r6b1_ui_commands_prompts_theme_approval_overlay_budget_and_abort() {
        use std::time::{SystemTime, UNIX_EPOCH};

        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let data_dir =
            std::env::temp_dir().join(format!("hi_app_r6b1_{}_{}", std::process::id(), nanos));
        std::fs::create_dir_all(data_dir.join("prompts")).unwrap();
        std::fs::create_dir_all(data_dir.join("themes")).unwrap();
        std::fs::write(
            data_dir.join("prompts/review.md"),
            "# Review\nInspect {{args}} now.",
        )
        .unwrap();
        std::fs::write(data_dir.join("themes/mint.json"), r#"{"base":"dark"}"#).unwrap();

        let (srv, client) = TestServer::bind("r6b1-ui");
        let posted = Arc::new(Mutex::new(Vec::<Value>::new()));
        let posted_srv = Arc::clone(&posted);
        let listener = srv.listener.try_clone().unwrap();
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop_srv = Arc::clone(&stop);

        let handle = thread::spawn(move || {
            while !stop_srv.load(std::sync::atomic::Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let (head, body) = read_http_request(&mut stream);
                        if head.starts_with("POST /api/v1/sessions/sess-1/commands ") {
                            let val: Value = serde_json::from_str(&body).unwrap();
                            let req_id = val["request_id"].as_str().unwrap().to_string();
                            posted_srv.lock().unwrap().push(val);
                            let resp = json!({
                                "version": 1,
                                "request_id": req_id,
                                "seq": 30,
                                "status": "ok"
                            })
                            .to_string();
                            write_json_response(&mut stream, "200 OK", &resp);
                        } else {
                            write_json_response(&mut stream, "404 Not Found", "{}");
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        });

        let (mut ui, mut screen) = make_ui(client, "sess-1", "1");
        ui.data_dir = data_dir.clone();
        load_snapshot(&mut ui, 20, vec![], false);

        // /reload discovers prompt templates and /theme lists custom JSON themes + applies live
        ui.command("/reload");
        assert_eq!(ui.prompts.len(), 1);
        ui.command("/theme");
        let picker = ui.picker.as_ref().expect("theme picker");
        assert_eq!(picker.kind, PickerKind::Themes);
        assert!(picker.picker.lines().join("\n").contains("mint"));
        ui.command("/theme mint");
        assert_eq!(ui.config.theme.name, "mint");

        // Tab completion lists /prompt:review and executing it submits expanded prompt
        ui.draft.editor.set("/prompt:");
        ui.key(KeyEvent::new(KeyCode::Tab, Mod::NONE), &mut screen);
        assert_eq!(ui.draft.editor.text(), "/prompt:review");
        press_esc(&mut ui, &mut screen);

        ui.command("/prompt:review src/lib.rs");
        wait_job_complete(&mut ui, &mut screen);

        // /prompts picker pre-fills /prompt:review
        ui.command("/prompts");
        assert_eq!(
            ui.picker.as_ref().map(|p| p.kind),
            Some(PickerKind::Prompts)
        );
        ui.pick_key(KeyEvent::new(KeyCode::Enter, Mod::NONE), &mut screen);
        assert_eq!(ui.draft.editor.text(), "/prompt:review ");
        ui.draft.editor.set("");

        // Auto-open approval overlay on new live.approvals entry; Esc dismisses without denying
        ui.update(Update::Frame(ServerFrame::Commit(
            crate::protocol::CommitFrame {
                version: Some(1),
                session_id: None,
                conversation_id: None,
                prev_seq: Some(20),
                seq: 21,
                appended_entries: vec![],
                doc_ops: serde_json::from_value(json!({
                    "live": [["replace", {
                        "approvals": {
                            "99": {
                                "task_id": "99",
                                "call_id": "call_99",
                                "tool_name": "bash",
                                "arguments": {"command": "ls"}
                            }
                        }
                    }]]
                }))
                .unwrap(),
            },
        )));
        assert_eq!(
            ui.picker.as_ref().map(|p| p.kind),
            Some(PickerKind::Approval)
        );
        ui.pick_key(KeyEvent::new(KeyCode::Esc, Mod::NONE), &mut screen);
        assert!(ui.picker.is_none());
        assert!(posted.lock().unwrap().len() == 1);

        // /approve without args approves sole pending task 99
        ui.command("/approve");
        wait_job_complete(&mut ui, &mut screen);

        // /approval, /budget, and task-scoped /abort
        ui.command("/approval mutating");
        wait_job_complete(&mut ui, &mut screen);
        ui.command("/budget turns=4 cost=1.25 elapsed=15s");
        wait_job_complete(&mut ui, &mut screen);
        ui.command("/budget off");
        wait_job_complete(&mut ui, &mut screen);
        ui.command("/abort 99 cancel tool");
        wait_job_complete(&mut ui, &mut screen);

        let cmds = posted.lock().unwrap();
        assert_eq!(cmds.len(), 6);
        assert_eq!(cmds[0]["command"], "submit");
        assert_eq!(
            cmds[0]["args"]["content"][0]["text"],
            "# Review\nInspect src/lib.rs now."
        );
        assert_eq!(cmds[1]["command"], "approve_tool");
        assert_eq!(cmds[1]["args"]["task_id"], 99);
        assert_eq!(cmds[1]["args"]["decision"], "allow");
        assert_eq!(cmds[2]["command"], "configure");
        assert_eq!(cmds[2]["args"]["approval_policy"], "mutating");
        assert_eq!(cmds[3]["command"], "configure");
        assert_eq!(cmds[3]["args"]["budget"]["max_turns"], 4);
        assert_eq!(cmds[3]["args"]["budget"]["max_cost_usd"], 1.25);
        assert_eq!(cmds[3]["args"]["budget"]["max_elapsed_ms"], 15_000);
        assert_eq!(cmds[4]["command"], "configure");
        assert_eq!(cmds[4]["args"]["budget"], Value::Null);
        assert_eq!(cmds[5]["command"], "abort");
        assert_eq!(cmds[5]["args"]["task_id"], 99);
        assert_eq!(cmds[5]["args"]["reason"], "cancel tool");

        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        drop(ui);
        let _ = handle.join();
        let _ = std::fs::remove_dir_all(&data_dir);
    }

    #[cfg(unix)]
    #[test]
    fn fd_disconnected_detects_peer_hangup_and_invalid_fd() {
        use std::os::unix::io::AsRawFd;
        use std::os::unix::net::UnixStream;

        let (a, b) = UnixStream::pair().unwrap();
        assert!(
            !fd_disconnected(a.as_raw_fd()),
            "connected peer must not be reported as disconnected"
        );
        drop(b);
        assert!(
            fd_disconnected(a.as_raw_fd()),
            "closed peer must be reported as disconnected"
        );
        drop(a);
        assert!(
            fd_disconnected(999_999),
            "invalid fd must be reported as disconnected"
        );
    }
}
