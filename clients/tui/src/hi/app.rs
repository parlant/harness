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
    ("/tree", "Conversations and fork points"),
    ("/fork", "Fork from a visible entry"),
    ("/earlier", "Page older entries"),
    ("/latest", "Return to live transcript"),
    ("/model", "Choose a model"),
    ("/thinking", "Choose thinking level"),
    ("/attach", "Attach a client-local file"),
    ("/steer", "Steer the active run"),
    ("/follow-up", "Queue follow-up"),
    ("/dequeue", "Withdraw queued prompts"),
    ("/abort", "Interrupt this conversation"),
    ("/continue", "Continue conversation"),
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

#[derive(Default)]
struct Draft {
    editor: Editor,
    attachments: Vec<Value>,
    retry: Option<(String, CommandEnvelope)>,
}
struct Job {
    result: Receiver<Result<Reply, String>>,
    submitted: Option<(String, CommandEnvelope)>,
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
    picker: Option<(String, Picker)>,
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
        let status = format!(
            "{} · {} · {}{}{} · {}:{} · {}",
            self.note,
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
            self.target.sid,
            self.target.cid,
            self.target.cwd
        );
        let overlay = self
            .picker
            .as_ref()
            .map(|(_, p)| p.lines())
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
    fn menu(&mut self, title: &str, choices: Vec<(String, String)>) {
        self.picker = Some((title.into(), Picker::new(title, choices)));
    }
    fn start(&mut self, effect: Effect, submitted: Option<(String, CommandEnvelope)>) {
        if self.job.is_some() {
            self.note = "Wait for pending command".into();
            return;
        }
        let (tx, result) = mpsc::sync_channel(1);
        let c = self.client.clone();
        let t = self.target.clone();
        let seq = self.state.seq;
        thread::spawn(move || {
            let _ = tx.send(actions::execute(&c, &t, seq, effect));
        });
        self.job = Some(Job { result, submitted });
    }
    fn complete(&mut self, screen: &mut Screen) -> bool {
        let Some(j) = &self.job else { return false };
        let r = match j.result.try_recv() {
            Ok(r) => r,
            Err(TryRecvError::Empty) => return false,
            Err(TryRecvError::Disconnected) => Err("Command worker disconnected".into()),
        };
        let submitted = self.job.take().and_then(|j| j.submitted);
        match r {
            Err(e) => {
                self.note = e;
                if let Some(item) = submitted {
                    if self.draft.editor.text().is_empty() {
                        self.draft.editor.set(&item.0);
                    }
                    self.draft.retry = Some(item);
                    self.note.push_str(" · /retry uses same request");
                }
            }
            Ok(Reply::Menu(title, items)) => self.menu(&title, items),
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
            Ok(Reply::Page(p)) => {
                let mut page = TranscriptState::default();
                page.prepend_older_page(p.items, p.next_cursor);
                self.historical = Some(page);
                self.rows_dirty = true;
                self.note = "Earlier page · /latest to follow".into();
                screen.bottom();
            }
            Ok(Reply::Target(t)) => self.switch(t, screen),
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
        if text.trim().is_empty() && self.draft.attachments.is_empty() {
            return;
        }
        let Ok(cid) = self.target.cid.parse() else {
            self.note = "Invalid conversation ID".into();
            return;
        };
        let mut cmd = CommandEnvelope::submit_input(
            generate_request_id(),
            cid,
            text.clone(),
            if follow {
                WhenBusy::FollowUp
            } else {
                WhenBusy::Steer
            },
            WhenIdle::Start,
        );
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
        self.start(Effect::Submit(cmd.clone()), Some((text, cmd)));
        self.draft.editor.submitted();
        self.draft.attachments.clear();
    }
    fn entries(&self) -> Vec<(String, String)> {
        self.historical
            .as_ref()
            .unwrap_or(&self.state)
            .entries
            .iter()
            .rev()
            .map(|e| {
                (
                    e.id.clone(),
                    format!(
                        "#{} {} {}",
                        e.id,
                        e.kind,
                        sanitize_single_line(&extract_entry_text(&e.data))
                            .chars()
                            .take(140)
                            .collect::<String>()
                    ),
                )
            })
            .collect()
    }
    fn key(&mut self, k: KeyEvent, screen: &mut Screen) {
        if self.prefs.action(k) != Some("clear") {
            self.last_clear = None;
        }
        match self.prefs.action(k) {
            Some("interrupt") => {
                if self.state.is_run_active() {
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
            Some("search") => self.menu("search", self.entries()),
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
                KeyCode::Tab if self.draft.editor.text().starts_with('/') => self.palette(),
                KeyCode::Tab if self.draft.editor.text().starts_with('@') => {
                    let prefix = self.draft.editor.text()[1..].to_owned();
                    self.file_menu(&prefix);
                }
                _ => {
                    self.draft.editor.key(k);
                }
            },
        }
    }
    fn palette(&mut self) {
        self.menu(
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
            "/new" => self.start(Effect::New, None),
            "/tree" | "/branches" => self.start(Effect::Branches, None),
            "/conv" if arg.parse::<u64>().is_ok() => {
                self.start(Effect::Branch(arg.to_owned()), None)
            }
            "/fork" if arg.is_empty() => self.menu("fork", self.entries()),
            "/fork" => {
                if let Ok(id) = arg.parse() {
                    self.start(Effect::Fork(id), None);
                } else {
                    self.note = "Usage: /fork <entry_id>".into();
                }
            }
            "/model" if arg.is_empty() => self.start(Effect::Models, None),
            "/model" => self.start(Effect::Configure("model".into(), arg.into()), None),
            "/thinking" if arg.is_empty() => self.menu(
                "thinking",
                ["off", "minimal", "low", "medium", "high"]
                    .into_iter()
                    .map(|s| (s.into(), s.into()))
                    .collect(),
            ),
            "/thinking" => self.start(Effect::Configure("thinking".into(), arg.into()), None),
            "/search" => self.menu("search", self.entries()),
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
                    self.start(Effect::Submit(envelope.clone()), Some((s, envelope)));
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
        let (title, p) = self.picker.as_mut().unwrap();
        match p.key(key) {
            Choice::Stay => {}
            Choice::Cancel => self.picker = None,
            Choice::Pick(id) => {
                let title = title.clone();
                self.picker = None;
                match title.as_str() {
                    "models" => self.start(Effect::Configure("model".into(), id), None),
                    "thinking" => self.start(Effect::Configure("thinking".into(), id), None),
                    "sessions" => self.start(Effect::Attach(id), None),
                    "branches" if self.job.is_none() => self.switch(
                        Target {
                            cid: id,
                            ..self.target.clone()
                        },
                        screen,
                    ),
                    "fork" => {
                        if let Ok(n) = id.parse() {
                            self.start(Effect::Fork(n), None)
                        }
                    }
                    "commands" => {
                        self.draft.editor.set(&id);
                        self.note = "Enter to run command".into();
                    }
                    "client files" if id.ends_with('/') => self.file_menu(&id),
                    "client files" => {
                        if self.draft.editor.text().starts_with('@') {
                            self.draft.editor.set("");
                        }
                        self.attach(&id);
                    }
                    "search" => {
                        if let Some(e) = self
                            .historical
                            .as_ref()
                            .unwrap_or(&self.state)
                            .entries
                            .iter()
                            .find(|e| e.id == id)
                        {
                            let text = extract_entry_text(&e.data);
                            self.menu(
                                "message",
                                text.lines()
                                    .map(|l| (String::new(), sanitize_single_line(l)))
                                    .collect(),
                            );
                        }
                    }
                    _ => {}
                }
            }
        }
    }
}
