//! Terminal-side state only. All durable mutations go through an effect worker.
use super::{
    actions::{self, Effect, Reply, Target},
    cards,
    editor::Editor,
    external,
    picker::{Choice, Picker},
    preferences::Preferences,
    screen::Screen,
    stream::{Subscription, Update},
};
use crate::{
    cli::generate_request_id,
    client::DaemonClient,
    protocol::{CommandEnvelope, ServerFrame, WhenBusy, WhenIdle},
    render::{extract_entry_text, format_status_line, sanitize_single_line},
    transcript::{CommitOutcome, TranscriptState},
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
    ("/new", "New session"),
    ("/name", "Show or rename session title"),
    ("/tree", "Conversations and branch history"),
    ("/fork", "Edit an earlier prompt on a new branch"),
    ("/branch", "Branch after a visible entry"),
    ("/earlier", "Page older entries"),
    ("/latest", "Return to live transcript"),
    ("/model", "Choose a model"),
    ("/thinking", "Choose thinking level"),
    ("/file", "Read a session workspace file"),
    ("/attach", "Attach a client-local file"),
    ("/steer", "Steer the active run"),
    ("/follow-up", "Queue follow-up"),
    ("/dequeue", "Withdraw queued prompts"),
    ("/abort", "Interrupt this conversation"),
    ("/continue", "Continue conversation"),
    ("/compact", "Compact conversation history"),
    ("/tools", "Toggle tool details"),
    ("/thoughts", "Toggle thinking blocks"),
    ("/edit", "Open draft in external editor"),
    ("/envs", "List environments"),
    ("/search", "Search loaded messages"),
    ("/status", "Show connection and run status"),
    ("/hotkeys", "Active shortcuts"),
    ("/reload", "Reload local keybindings"),
    ("/copy", "Copy last assistant message (OSC 52)"),
    (
        "/export",
        "Export history to a new local .html or .jsonl file",
    ),
    ("/quit", "Detach (does not abort)"),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PickerKind {
    Models,
    Thinking,
    Sessions,
    Branches,
    Fork,
    RootFork,
    Branch,
    Commands,
    ClientFiles,
    WorkspaceFiles,
    Search,
    Info,
}

struct PickerState {
    kind: PickerKind,
    picker: Picker,
    scope: Option<(String, String)>,
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
struct Ui {
    client: DaemonClient,
    target: Target,
    state: TranscriptState,
    historical: Option<TranscriptState>,
    sub: Subscription,
    online: bool,
    draft: Draft,
    saved: HashMap<(String, String), Draft>,
    picker: Option<PickerState>,
    pending_root_fork: Option<PendingRootFork>,
    prefs: Preferences,
    pref_path: PathBuf,
    job: Option<Job>,
    note: String,
    tools: bool,
    thinking: bool,
    cached_rows: Vec<String>,
    rows_dirty: bool,
    quit: bool,
    last_clear: Option<Instant>,
}

fn local<T>(r: io::Result<T>) -> Result<T, String> {
    r.map_err(|e| e.to_string())
}

pub fn run(
    client: DaemonClient,
    target: Target,
    data_dir: &Path,
    resume: bool,
    initial: &str,
    regular: bool,
) -> Result<(), String> {
    let open_screen = if regular {
        Screen::open_regular
    } else {
        Screen::open
    };
    let pref_path = data_dir.join("hi-keybindings.json");
    let prefs = Preferences::load(&pref_path)?;
    let sub = Subscription::start(client.clone(), target.sid.clone(), target.cid.clone(), None);
    let state = TranscriptState::new(Some(target.sid.clone()), Some(target.cid.clone()));
    let mut ui = Ui {
        client,
        target,
        state,
        historical: None,
        sub,
        online: false,
        draft: Draft::default(),
        saved: HashMap::new(),
        picker: None,
        pending_root_fork: None,
        prefs,
        pref_path,
        job: None,
        note: "Connecting · /help".into(),
        tools: false,
        thinking: false,
        cached_rows: Vec::new(),
        rows_dirty: true,
        quit: false,
        last_clear: None,
    };
    let exiting = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    for signal in [signal_hook::consts::SIGTERM, signal_hook::consts::SIGINT] {
        local(signal_hook::flag::register(signal, exiting.clone()))?;
    }
    let mut screen = local(open_screen())?;
    if resume {
        ui.start(Effect::Sessions, None);
    }
    let mut initial = Some(initial).filter(|s| !s.is_empty());
    let mut repaint = true;
    while !ui.quit && !exiting.load(std::sync::atomic::Ordering::Relaxed) {
        for _ in 0..48 {
            let Some(update) = ui.sub.next() else { break };
            ui.update(update);
            repaint = true;
        }
        if ui.complete(&mut screen) {
            repaint = true;
        }
        if ui.online && ui.state.seq.is_some() && ui.job.is_none() {
            if let Some(text) = initial.take() {
                ui.draft.editor.set(text);
                ui.send(false);
                repaint = true;
            }
        }
        if repaint {
            ui.draw(&mut screen)?;
            repaint = false;
        }
        if local(event::poll(Duration::from_millis(16)))? {
            match local(event::read())? {
                Event::Key(k) if k.kind != KeyEventKind::Release => {
                    if ui.draft.editor.is_searching_history() && ui.picker.is_none() {
                        ui.draft.editor.key(k);
                    } else if ui.picker.is_some() {
                        ui.pick_key(k, &mut screen);
                    } else if ui.prefs.action(k) == Some("external")
                        || (k.code == KeyCode::Enter
                            && k.modifiers.is_empty()
                            && ui.draft.editor.text() == "/edit")
                    {
                        if ui.draft.editor.text() == "/edit" {
                            ui.draft.editor.set("");
                        }
                        drop(screen);
                        match external::edit(&ui.draft.editor.expanded_text()) {
                            Ok(s) => ui.draft.editor.set(&s),
                            Err(e) => ui.note = e.to_string(),
                        };
                        screen = local(open_screen())?;
                    } else if ui.prefs.action(k) == Some("suspend") {
                        drop(screen);
                        local(signal_hook::low_level::raise(signal_hook::consts::SIGSTOP))?;
                        screen = local(open_screen())?;
                    } else {
                        ui.key(k, &mut screen);
                    }
                }
                Event::Paste(s) if ui.picker.is_none() => {
                    if s.len() > super::files::MAX_TEXT_BYTES {
                        ui.note = "Paste exceeds 1 MiB; use a smaller excerpt".into();
                    } else {
                        ui.draft.editor.paste(&s);
                    }
                }
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
    Ok(())
}

impl Ui {
    fn draw(&mut self, screen: &mut Screen) -> Result<(), String> {
        if let Ok((width, _)) = crossterm::terminal::size() {
            self.draft.editor.set_width(usize::from(width).max(1));
        }
        if self.rows_dirty {
            self.cached_rows = cards::rows(
                self.historical.as_ref().unwrap_or(&self.state),
                self.tools,
                self.thinking,
            );
            self.rows_dirty = false;
        }
        let fork_tag = self
            .draft
            .fork_edit
            .as_ref()
            .map(|fe| {
                format!(
                    " · fork-edit #{}@{}",
                    sanitize_single_line(&fe.selected_entry_id),
                    fe.predecessor_id
                )
            })
            .unwrap_or_default();
        let shell_tag = self
            .state
            .active_user_shell()
            .map(|(cmd, status, include)| {
                let prefix = if include { "!" } else { "!!" };
                format!(
                    " · shell {prefix}{} ({})",
                    sanitize_single_line(cmd)
                        .chars()
                        .take(24)
                        .collect::<String>(),
                    sanitize_single_line(status)
                )
            })
            .unwrap_or_default();
        let status = format!(
            "{}{} · {} · {}{}{}{} · {}:{} · {}",
            self.note,
            shell_tag,
            if self.online { "online" } else { "offline" },
            format_status_line(&self.state),
            if self.job.is_some() {
                " · pending"
            } else {
                ""
            },
            if !self.draft.attachments.is_empty() {
                " · attachment"
            } else {
                ""
            },
            fork_tag,
            self.target.sid,
            self.target.cid,
            self.target.cwd
        );
        let overlay = self
            .picker
            .as_ref()
            .map(|p| p.picker.lines())
            .unwrap_or_default();
        local(screen.draw(
            &self.cached_rows,
            self.draft.editor.text(),
            self.draft.editor.cursor(),
            &sanitize_single_line(&status),
            &overlay,
        ))
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
                match f {
                    ServerFrame::Snapshot(s) => {
                        self.state.apply_snapshot(s);
                        self.note = "Ready · /help".into();
                    }
                    ServerFrame::Commit(c) => {
                        if self.state.apply_commit(c) == CommitOutcome::Gap {
                            self.sub = Subscription::start(
                                self.client.clone(),
                                self.target.sid.clone(),
                                self.target.cid.clone(),
                                None,
                            );
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
                self.rows_dirty |= self.historical.is_none();
            }
        }
    }
    fn menu(&mut self, kind: PickerKind, title: &str, choices: Vec<(String, String)>) {
        self.picker = Some(PickerState {
            kind,
            picker: Picker::new(title, choices),
            scope: None,
        });
    }
    fn scoped_menu(&mut self, kind: PickerKind, title: &str, choices: Vec<(String, String)>) {
        self.picker = Some(PickerState {
            kind,
            picker: Picker::new(title, choices),
            scope: Some((self.target.sid.clone(), self.target.cid.clone())),
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
                self.note = e.clone();
                if let Some((text, envelope)) = submitted {
                    if self.draft.editor.text().is_empty() {
                        self.draft.editor.set(&text);
                    }
                    if self.draft.attachments.is_empty() && envelope.command != "user_shell" {
                        self.draft.attachments = extract_non_text_blocks(&envelope.args);
                    }
                    if envelope.command != "user_shell"
                        && (envelope.command != "fork_and_submit" || is_ambiguous_submit_error(&e))
                    {
                        self.draft.retry = Some((text, envelope));
                        self.note.push_str(" · /retry uses same request");
                    }
                }
            }
            Ok(Reply::Menu(title, items)) => {
                let kind = match title.as_str() {
                    "models" => PickerKind::Models,
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
            Ok(Reply::Target(t)) => {
                let root = self.pending_root_fork.take().filter(|r| {
                    r.source_sid == source_target.0
                        && r.source_cid == source_target.1
                        && r.source_sid == self.target.sid
                        && r.source_cid == self.target.cid
                });
                self.switch(t, screen);
                if let Some(root) = root {
                    self.draft.editor.set(&root.text);
                    self.draft.attachments = root.attachments;
                    self.note = format!(
                        "New session {} for root prompt #{} (files unchanged) · Edit and submit",
                        sanitize_single_line(&self.target.sid),
                        sanitize_single_line(&root.entry_id)
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
                self.note = format!(
                    "Forked to #{} · {} · seq {}",
                    sanitize_single_line(&self.target.cid),
                    sanitize_single_line(receipt.status.as_deref().unwrap_or("placed")),
                    receipt.seq.unwrap_or_default()
                );
            }
            Ok(Reply::Receipt(r)) => {
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
        let key = (self.target.sid.clone(), self.target.cid.clone());
        self.saved.insert(key, std::mem::take(&mut self.draft));
        self.draft = self
            .saved
            .remove(&(t.sid.clone(), t.cid.clone()))
            .unwrap_or_default();
        if self.picker.as_ref().is_some_and(|p| p.scope.is_some()) {
            self.picker = None;
        }
        self.pending_root_fork = None;
        self.historical = None;
        self.state = TranscriptState::new(Some(t.sid.clone()), Some(t.cid.clone()));
        self.sub = Subscription::start(self.client.clone(), t.sid.clone(), t.cid.clone(), None);
        self.target = t;
        self.online = false;
        self.rows_dirty = true;
        self.note = "Connecting".into();
        screen.bottom();
    }
    fn send(&mut self, follow: bool) {
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
    fn key(&mut self, k: KeyEvent, screen: &mut Screen) {
        if self.prefs.action(k) != Some("clear") {
            self.last_clear = None;
        }
        match self.prefs.action(k) {
            Some("interrupt") => {
                if self.draft.fork_edit.is_some() && self.job.is_none() {
                    self.cancel_fork_edit();
                } else if self.draft.fork_edit.is_some() {
                    self.note = "Wait for pending fork-edit command".into();
                } else if self.state.is_run_active() {
                    self.start(Effect::Abort, None);
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
            Some("exit") if self.draft.editor.text().is_empty() => self.quit = true,
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
                KeyCode::PageUp => screen.scroll(10),
                KeyCode::PageDown => screen.scroll(-10),
                KeyCode::End if k.modifiers == Mod::CONTROL => screen.bottom(),
                KeyCode::Tab if self.draft.editor.text().starts_with("/attach ") => {
                    let prefix = self.draft.editor.text()["/attach ".len()..]
                        .trim()
                        .to_owned();
                    self.file_menu(&prefix);
                }
                KeyCode::Tab if self.draft.editor.text().starts_with('/') => self.palette(),
                KeyCode::Tab if self.draft.editor.text().starts_with('@') => {
                    let prefix = self.draft.editor.text()[1..].to_owned();
                    self.workspace_file_menu(&prefix);
                }
                _ => {
                    self.draft.editor.key(k);
                }
            },
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
            "/quit" | "/exit" => self.quit = true,
            "/hotkeys" => self.menu(
                PickerKind::Info,
                "shortcuts",
                self.prefs
                    .help()
                    .into_iter()
                    .map(|s| (String::new(), s))
                    .collect(),
            ),
            "/reload" => match Preferences::load(&self.pref_path) {
                Ok(p) => {
                    self.prefs = p;
                    self.note = "Keybindings reloaded".into();
                }
                Err(e) => self.note = e,
            },
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
            "/tree" | "/branches" => self.start(Effect::Branches, None),
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
            "/abort" => self.start(Effect::Abort, None),
            "/continue" => self.start(Effect::Continue, None),
            "/compact" => {
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
                self.note = format!("Unknown command {cmd} · /help");
                self.draft.editor.set(text);
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
    fn pick_key(&mut self, key: KeyEvent, screen: &mut Screen) {
        let Some(state) = self.picker.as_mut() else {
            return;
        };
        let choice = state.picker.key(key);
        let kind = state.kind;
        let scope = state.scope.clone();
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
                    PickerKind::Models => self.start(Effect::Configure("model".into(), id), None),
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
                    PickerKind::Info => {}
                }
            }
        }
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
            let sock_path = PathBuf::from(format!("/private/tmp/hi-app-{tag}-{nanos}.sock"));
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

    fn make_ui(client: DaemonClient, sid: &str, cid: &str) -> (Ui, Screen) {
        let target = Target {
            sid: sid.to_string(),
            cid: cid.to_string(),
            cwd: "/tmp/proj".to_string(),
            env_id: "host".to_string(),
        };
        let sub = Subscription::start(client.clone(), target.sid.clone(), target.cid.clone(), None);
        let state = TranscriptState::new(Some(target.sid.clone()), Some(target.cid.clone()));
        let ui = Ui {
            client,
            target,
            state,
            historical: None,
            sub,
            online: true,
            draft: Draft::default(),
            saved: HashMap::new(),
            picker: None,
            pending_root_fork: None,
            prefs: Preferences::default(),
            pref_path: PathBuf::from("/private/tmp/hi-app-nonexistent-keybindings.json"),
            job: None,
            note: "Ready".into(),
            tools: false,
            thinking: false,
            cached_rows: Vec::new(),
            rows_dirty: true,
            quit: false,
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
            scope: Some(("sess-1".into(), "1".into())),
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
}
