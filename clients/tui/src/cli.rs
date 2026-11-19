use crate::{client, config, protocol, render, transcript};

use clap::{CommandFactory, FromArgMatches, Parser};
use client::{ClientError, DaemonClient};
use config::{resolve_config, ConfigError};
use protocol::{
    CommandEnvelope, CommandReceipt, CreateSessionRequest, ServerFrame, SessionSummary,
    TranscriptEntry, WhenBusy, WhenIdle,
};
use render::{
    extract_entry_text, format_branches_list, format_sessions_list, format_status_line,
    sanitize_single_line, sanitize_terminal_text, InlineRenderer,
};
use std::fmt;
use std::fs::File;
use std::io::{self, BufRead, IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Sender};
use std::thread;
use transcript::{CommitOutcome, EphemeralOutcome, TranscriptState};

static REQUEST_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Parser)]
#[command(
    name = "h",
    version,
    about = "Cooperative terminal client for the H harness daemon"
)]
struct Cli {
    /// Override H data directory (default: $H_DATA_DIR or ~/.local/share/h)
    #[arg(long, value_name = "PATH")]
    data_dir: Option<PathBuf>,

    /// Override daemon URL (literal loopback http://127.0.0.1:<port> or http://[::1]:<port>)
    #[arg(long, value_name = "URL")]
    daemon_url: Option<String>,

    /// hi terminal layout (interactive TTY only)
    #[arg(long, value_parser = ["fullscreen", "regular"], default_value="fullscreen")]
    tui_mode: String,

    /// Execution environment ID
    #[arg(long = "env", value_name = "ID", default_value = "host")]
    env_id: String,

    /// Attach to a specific session ID
    #[arg(short = 's', long = "session", value_name = "ID")]
    session: Option<String>,

    /// Continue the most recent session for the current working directory
    #[arg(short = 'c', long = "continue")]
    continue_latest: bool,

    /// List and resume a session for the current working directory
    #[arg(short = 'r', long = "resume")]
    resume: bool,

    /// Headless print mode: submit prompt, stream assistant text to stdout, and exit
    #[arg(
        short = 'p',
        long = "print",
        value_name = "PROMPT",
        conflicts_with = "prompt"
    )]
    print_prompt: Option<String>,

    /// Initial prompt (runs headless print mode and exits)
    #[arg(value_name = "PROMPT")]
    prompt: Vec<String>,
}

#[derive(Debug)]
enum AppError {
    Config(ConfigError),
    Client(ClientError),
    Message(String),
}

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AppError::Config(e) => write!(f, "{e}"),
            AppError::Client(e) => write!(f, "{}", sanitize_terminal_text(&e.to_string())),
            AppError::Message(msg) => write!(f, "{}", sanitize_terminal_text(msg)),
        }
    }
}

impl From<ConfigError> for AppError {
    fn from(err: ConfigError) -> Self {
        AppError::Config(err)
    }
}

impl From<ClientError> for AppError {
    fn from(err: ClientError) -> Self {
        AppError::Client(err)
    }
}

pub fn main() -> ExitCode {
    entry(false)
}

pub fn hi_main() -> ExitCode {
    entry(true)
}

fn entry(hi: bool) -> ExitCode {
    let cmd = if hi {
        Cli::command()
            .name("hi")
            .about("Interactive terminal for the durable H daemon")
    } else {
        Cli::command()
    };
    let cli = Cli::from_arg_matches(&cmd.get_matches()).unwrap_or_else(|err| err.exit());
    match run(cli, hi) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            let _ = writeln!(io::stderr(), "error: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli, hi: bool) -> Result<(), AppError> {
    let cfg = resolve_config(cli.data_dir.as_deref(), cli.daemon_url.as_deref())?;
    let client = DaemonClient::new(cfg.target, cfg.token);
    let cwd = current_cwd_string()?;

    let fullscreen = hi
        && cli.print_prompt.is_none()
        && io::stdin().is_terminal()
        && io::stdout().is_terminal()
        && std::env::var("TERM").as_deref() != Ok("dumb");
    if fullscreen {
        let target = resolve_session_for_run(
            &client,
            &cli.env_id,
            &cwd,
            cli.session.as_deref(),
            cli.continue_latest || cli.resume,
        )?;
        return crate::hi::app::run(
            client,
            crate::hi::actions::Target {
                sid: target.session_id,
                cid: target.conversation_id,
                cwd: target.cwd,
                env_id: target.env_id,
                labels: target.labels,
            },
            &cfg.data_dir,
            cli.resume,
            &cli.prompt.join(" "),
            cli.tui_mode == "regular",
        )
        .map_err(AppError::Message);
    }
    let headless_prompt = resolve_prompt(&cli);

    if cli.resume && headless_prompt.is_some() {
        return Err(AppError::Message(
            "--resume cannot be combined with --print or a positional prompt".to_string(),
        ));
    }

    if let Some(prompt) = headless_prompt {
        let target = resolve_session_for_run(
            &client,
            &cli.env_id,
            &cwd,
            cli.session.as_deref(),
            cli.continue_latest,
        )?;
        return run_headless_prompt(
            &client,
            &target.session_id,
            &target.conversation_id,
            &prompt,
        );
    }

    if cli.resume {
        let target = run_resume_picker(&client, &cli.env_id, &cwd, cli.session.as_deref())?;
        return run_interactive(&client, &cfg.data_dir, &cli.env_id, &cwd, target, &[]);
    }

    let folder_sessions = list_cwd_sessions_sorted(&client, &cli.env_id, &cwd)?;
    let target = if let Some(sid) = cli.session.as_deref() {
        attach_named_session(&client, sid)?
    } else if cli.continue_latest {
        continue_or_create_session(&client, &cli.env_id, &cwd, &folder_sessions)?
    } else {
        create_auto_session(&client, &cli.env_id, &cwd)?
    };

    run_interactive(
        &client,
        &cfg.data_dir,
        &cli.env_id,
        &cwd,
        target,
        &folder_sessions,
    )
}

fn resolve_prompt(cli: &Cli) -> Option<String> {
    if let Some(ref p) = cli.print_prompt {
        return Some(p.clone());
    }
    if !cli.prompt.is_empty() {
        return Some(cli.prompt.join(" "));
    }
    None
}

fn current_cwd_string() -> Result<String, AppError> {
    let dir = std::env::current_dir()
        .map_err(|e| AppError::Message(format!("failed to read current working directory: {e}")))?;
    dir.into_os_string()
        .into_string()
        .map_err(|_| AppError::Message("current working directory is not valid UTF-8".to_string()))
}

#[derive(Debug, Clone)]
struct AttachedTarget {
    session_id: String,
    conversation_id: String,
    cwd: String,
    env_id: String,
    labels: crate::hi::actions::SessionLabels,
}

fn list_cwd_sessions_sorted(
    client: &DaemonClient,
    env_id: &str,
    cwd: &str,
) -> Result<Vec<SessionSummary>, AppError> {
    let mut sessions = client.list_sessions(Some(env_id), Some(cwd), Some(false))?;
    sort_sessions_latest_first(&mut sessions);
    Ok(sessions)
}

fn sort_sessions_latest_first(sessions: &mut [SessionSummary]) {
    sessions.sort_by(|a, b| {
        let ta = a.updated_at.or(a.created_at).unwrap_or(0);
        let tb = b.updated_at.or(b.created_at).unwrap_or(0);
        tb.cmp(&ta).then_with(|| a.session_id.cmp(&b.session_id))
    });
}

fn pick_latest_session(sessions: &[SessionSummary]) -> Option<&SessionSummary> {
    sessions
        .iter()
        .find(|s| s.status.as_deref() != Some("quarantined"))
        .or_else(|| sessions.first())
}

fn resolve_session_for_run(
    client: &DaemonClient,
    env_id: &str,
    cwd: &str,
    explicit_sid: Option<&str>,
    continue_latest: bool,
) -> Result<AttachedTarget, AppError> {
    if let Some(sid) = explicit_sid {
        return attach_named_session(client, sid);
    }
    if continue_latest {
        let sessions = list_cwd_sessions_sorted(client, env_id, cwd)?;
        return continue_or_create_session(client, env_id, cwd, &sessions);
    }
    create_auto_session(client, env_id, cwd)
}

fn attach_named_session(client: &DaemonClient, sid: &str) -> Result<AttachedTarget, AppError> {
    let detail = client.get_session_detail(sid)?;
    let cid = detail
        .session
        .root_conversation_id
        .clone()
        .or_else(|| detail.conversations.first().map(|c| c.id.clone()))
        .unwrap_or_else(|| "1".to_string());
    Ok(AttachedTarget {
        labels: (&detail.session).into(),
        session_id: detail.session.session_id,
        conversation_id: cid,
        cwd: detail.session.cwd,
        env_id: detail.session.env_id.unwrap_or_else(|| "host".to_string()),
    })
}

fn continue_or_create_session(
    client: &DaemonClient,
    env_id: &str,
    cwd: &str,
    sorted_sessions: &[SessionSummary],
) -> Result<AttachedTarget, AppError> {
    if let Some(latest) = pick_latest_session(sorted_sessions) {
        let cid = latest
            .root_conversation_id
            .clone()
            .unwrap_or_else(|| "1".to_string());
        return Ok(AttachedTarget {
            labels: latest.into(),
            session_id: latest.session_id.clone(),
            conversation_id: cid,
            cwd: latest.cwd.clone(),
            env_id: latest.env_id.clone().unwrap_or_else(|| env_id.to_string()),
        });
    }
    create_auto_session(client, env_id, cwd)
}

fn create_auto_session(
    client: &DaemonClient,
    env_id: &str,
    cwd: &str,
) -> Result<AttachedTarget, AppError> {
    let req = CreateSessionRequest {
        version: 1,
        request_id: generate_request_id(),
        env_id: env_id.to_string(),
        cwd: cwd.to_string(),
        session_id: Some(generate_request_id()),
        title: None,
        agent: None,
    };
    let created = client.create_session(&req)?;
    let labels = (&created.session).into();
    let cid = created
        .session
        .root_conversation_id
        .unwrap_or_else(|| "1".to_string());
    Ok(AttachedTarget {
        labels,
        session_id: created.session.session_id,
        conversation_id: cid,
        cwd: created.session.cwd,
        env_id: created.session.env_id.unwrap_or_else(|| env_id.to_string()),
    })
}

fn run_resume_picker(
    client: &DaemonClient,
    env_id: &str,
    cwd: &str,
    explicit_sid: Option<&str>,
) -> Result<AttachedTarget, AppError> {
    let sessions = list_cwd_sessions_sorted(client, env_id, cwd)?;
    let mut stdout = io::stdout();
    write!(stdout, "{}", format_sessions_list(&sessions, cwd))
        .map_err(|e| AppError::Message(e.to_string()))?;
    stdout
        .flush()
        .map_err(|e| AppError::Message(e.to_string()))?;

    if let Some(sid) = explicit_sid {
        return attach_named_session(client, sid);
    }

    if sessions.is_empty() {
        return Err(AppError::Message(format!(
            "no sessions found for {}",
            sanitize_single_line(cwd)
        )));
    }

    if !io::stdin().is_terminal() {
        return Err(AppError::Message(
            "session choice unavailable in non-interactive mode; pass -s <session_id> or -c/--continue"
                .to_string(),
        ));
    }

    write!(
        stdout,
        "Select session [1-{}] (or 'q' to quit): ",
        sessions.len()
    )
    .map_err(|e| AppError::Message(e.to_string()))?;
    stdout
        .flush()
        .map_err(|e| AppError::Message(e.to_string()))?;

    let mut line = String::new();
    let n = io::stdin()
        .read_line(&mut line)
        .map_err(|e| AppError::Message(format!("failed to read selection: {e}")))?;
    if n == 0 {
        return Err(AppError::Message("no session selected (EOF)".to_string()));
    }

    let trimmed = line.trim();
    if trimmed.eq_ignore_ascii_case("q") || trimmed.eq_ignore_ascii_case("quit") {
        return Err(AppError::Message("cancelled".to_string()));
    }

    let idx: usize = trimmed.parse().map_err(|_| {
        AppError::Message(format!(
            "invalid session selection '{}'",
            sanitize_single_line(trimmed)
        ))
    })?;
    if idx == 0 || idx > sessions.len() {
        return Err(AppError::Message(format!(
            "selection {idx} out of range (1..={})",
            sessions.len()
        )));
    }

    let chosen = &sessions[idx - 1];
    attach_named_session(client, &chosen.session_id)
}

fn run_headless_prompt(
    client: &DaemonClient,
    session_id: &str,
    conversation_id: &str,
    prompt: &str,
) -> Result<(), AppError> {
    if prompt.trim().is_empty() {
        return Err(AppError::Message("prompt cannot be empty".to_string()));
    }

    let cid_num: u64 = conversation_id
        .parse()
        .map_err(|_| AppError::Message(format!("invalid conversation_id: {conversation_id}")))?;

    let mut sse = client.subscribe_events(session_id, conversation_id, None)?;
    let mut state = TranscriptState::new(
        Some(session_id.to_string()),
        Some(conversation_id.to_string()),
    );

    // Wait for initial snapshot so our PubSub subscription is active before posting command.
    loop {
        match sse.next_event()? {
            Some(ev) => {
                if let ServerFrame::Snapshot(snap) = ev.decode_frame().map_err(decode_app_err)? {
                    state.apply_snapshot(snap);
                    break;
                }
            }
            None => {
                return Err(AppError::Message(
                    "SSE stream closed before initial snapshot".to_string(),
                ));
            }
        }
    }

    let request_id = generate_request_id();
    let envelope = CommandEnvelope::submit_input(
        &request_id,
        cid_num,
        prompt,
        WhenBusy::FollowUp,
        WhenIdle::Start,
    );
    let receipt = post_command_with_retry(client, session_id, &envelope)?;
    let target_seq = receipt.seq.unwrap_or(0);

    let mut last_assistant_entry: Option<TranscriptEntry> = None;
    let mut saw_commit_after_snapshot = false;

    // If an idempotent retry hit an already-completed submission, extract immediately if idle.
    if receipt.status.as_deref() == Some("done") && !state.is_run_active() {
        if let Some(entry) = state.entries.iter().rfind(|e| e.kind == "assistant") {
            return write_final_assistant_stdout(entry);
        }
    }

    let mut reconnect_attempts = 0u8;
    loop {
        let maybe_ev = match sse.next_event() {
            Ok(ev) => ev,
            Err(err) => {
                if reconnect_attempts < 2 {
                    reconnect_attempts += 1;
                    sse = client.subscribe_events(session_id, conversation_id, state.seq)?;
                    continue;
                }
                return Err(AppError::Client(err));
            }
        };

        let Some(ev) = maybe_ev else {
            if reconnect_attempts < 2 {
                reconnect_attempts += 1;
                sse = client.subscribe_events(session_id, conversation_id, state.seq)?;
                continue;
            }
            return Err(AppError::Message(
                "SSE stream closed before assistant response completed".to_string(),
            ));
        };

        match ev.decode_frame().map_err(decode_app_err)? {
            ServerFrame::Snapshot(snap) => {
                let prev_last_id = state.entries.last().map(|e| e.id.clone());
                state.apply_snapshot(snap);
                if let Some(entry) = newest_assistant_after(&state.entries, prev_last_id.as_deref())
                {
                    last_assistant_entry = Some(entry.clone());
                    saw_commit_after_snapshot = true;
                }
            }
            ServerFrame::Commit(commit) => match state.apply_commit(commit) {
                CommitOutcome::Applied { appended_entries } => {
                    saw_commit_after_snapshot = true;
                    for entry in appended_entries {
                        if entry.kind == "assistant" {
                            last_assistant_entry = Some(entry);
                        }
                    }
                }
                CommitOutcome::Gap => {
                    sse = client.subscribe_events(session_id, conversation_id, None)?;
                    continue;
                }
                CommitOutcome::Stale => {}
            },
            ServerFrame::Ephemeral(eph) => {
                let _ = state.apply_ephemeral(eph);
            }
            ServerFrame::Unknown { .. } => {}
        }

        let seq_reached = state.seq.unwrap_or(0) >= target_seq;
        if seq_reached && (saw_commit_after_snapshot || receipt.status.as_deref() == Some("done")) {
            if let Some(fail) = state.run_failure() {
                let msg = match fail.message {
                    Some(m) => format!("run failed ({}): {}", fail.reason, m),
                    None => format!("run failed ({})", fail.reason),
                };
                return Err(AppError::Message(msg));
            }

            if !state.is_run_active() && state.inbox_len() == 0 {
                if let Some(entry) = last_assistant_entry.as_ref() {
                    return write_final_assistant_stdout(entry);
                }
                if receipt.status.as_deref() == Some("done") {
                    if let Some(entry) = state.entries.iter().rfind(|e| e.kind == "assistant") {
                        return write_final_assistant_stdout(entry);
                    }
                }
            }
        }
    }
}

fn newest_assistant_after<'a>(
    entries: &'a [TranscriptEntry],
    prev_last_id: Option<&str>,
) -> Option<&'a TranscriptEntry> {
    match prev_last_id {
        None => entries.iter().rfind(|e| e.kind == "assistant"),
        Some(prev) => {
            let pos = entries.iter().position(|e| e.id == prev);
            let slice = match pos {
                Some(idx) => &entries[idx + 1..],
                None => entries,
            };
            slice.iter().rfind(|e| e.kind == "assistant")
        }
    }
}

fn write_final_assistant_stdout(entry: &TranscriptEntry) -> Result<(), AppError> {
    if entry.data.get("aborted").and_then(|v| v.as_bool()) == Some(true) {
        return Err(AppError::Message(
            "assistant response was aborted".to_string(),
        ));
    }
    let text = extract_entry_text(&entry.data);
    let safe = sanitize_terminal_text(&text);
    let mut stdout = io::stdout();
    if !safe.is_empty() {
        write!(stdout, "{safe}").map_err(|e| AppError::Message(e.to_string()))?;
        if !safe.ends_with('\n') {
            writeln!(stdout).map_err(|e| AppError::Message(e.to_string()))?;
        }
    }
    stdout
        .flush()
        .map_err(|e| AppError::Message(e.to_string()))?;
    Ok(())
}

enum LoopEvent {
    Sse { generation: u64, frame: ServerFrame },
    SseError { generation: u64, message: String },
    InputLine(String),
    InputEof,
}

fn run_interactive(
    client: &DaemonClient,
    data_dir: &Path,
    env_id: &str,
    cwd: &str,
    mut target: AttachedTarget,
    initial_folder_sessions: &[SessionSummary],
) -> Result<(), AppError> {
    let mut renderer = InlineRenderer::new(io::stdout());
    let mut state = TranscriptState::new(
        Some(target.session_id.clone()),
        Some(target.conversation_id.clone()),
    );

    print_banner(client, data_dir, &target, initial_folder_sessions);

    let (tx, rx) = mpsc::channel::<LoopEvent>();
    let mut sse_gen: u64 = 1;
    spawn_sse_listener(
        client.clone(),
        target.session_id.clone(),
        target.conversation_id.clone(),
        None,
        sse_gen,
        tx.clone(),
    );

    let stdin_tx = tx.clone();
    thread::spawn(move || {
        let stdin = io::stdin();
        let mut reader = stdin.lock();
        let mut buf = String::new();
        loop {
            buf.clear();
            match reader.read_line(&mut buf) {
                Ok(0) => {
                    let _ = stdin_tx.send(LoopEvent::InputEof);
                    break;
                }
                Ok(_) => {
                    if stdin_tx.send(LoopEvent::InputLine(buf.clone())).is_err() {
                        break;
                    }
                }
                Err(_) => {
                    let _ = stdin_tx.send(LoopEvent::InputEof);
                    break;
                }
            }
        }
    });

    for event in rx {
        match event {
            LoopEvent::Sse { generation, frame } => {
                if generation != sse_gen {
                    continue;
                }
                match frame {
                    ServerFrame::Snapshot(snap) => {
                        state.apply_snapshot(snap);
                        renderer
                            .render_snapshot(&state)
                            .map_err(|e| AppError::Message(e.to_string()))?;
                    }
                    ServerFrame::Commit(commit) => match state.apply_commit(commit) {
                        CommitOutcome::Applied { appended_entries } => {
                            renderer
                                .render_commit(&state, &appended_entries)
                                .map_err(|e| AppError::Message(e.to_string()))?;
                        }
                        CommitOutcome::Gap => {
                            sse_gen += 1;
                            spawn_sse_listener(
                                client.clone(),
                                target.session_id.clone(),
                                target.conversation_id.clone(),
                                None,
                                sse_gen,
                                tx.clone(),
                            );
                        }
                        CommitOutcome::Stale => {}
                    },
                    ServerFrame::Ephemeral(eph) => {
                        if state.apply_ephemeral(eph) == EphemeralOutcome::Applied {
                            renderer
                                .render_ephemeral(&state)
                                .map_err(|e| AppError::Message(e.to_string()))?;
                        }
                    }
                    ServerFrame::Unknown { .. } => {}
                }
            }
            LoopEvent::SseError {
                generation,
                message,
            } => {
                if generation != sse_gen {
                    continue;
                }
                let _ = writeln!(
                    io::stderr(),
                    "[sse disconnected: {}]",
                    sanitize_single_line(&message)
                );
            }
            LoopEvent::InputEof => {
                break;
            }
            LoopEvent::InputLine(line) => {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }
                if trimmed == "/quit" || trimmed == "/exit" {
                    break;
                }
                match handle_interactive_line(
                    client,
                    data_dir,
                    env_id,
                    cwd,
                    &mut target,
                    &mut state,
                    &mut renderer,
                    trimmed,
                ) {
                    Ok(Some(new_cid)) => {
                        target.conversation_id = new_cid.clone();
                        state = TranscriptState::new(
                            Some(target.session_id.clone()),
                            Some(new_cid.clone()),
                        );
                        renderer
                            .reset_for_conversation()
                            .map_err(|e| AppError::Message(e.to_string()))?;
                        sse_gen += 1;
                        spawn_sse_listener(
                            client.clone(),
                            target.session_id.clone(),
                            new_cid,
                            None,
                            sse_gen,
                            tx.clone(),
                        );
                    }
                    Ok(None) => {}
                    Err(err) => {
                        let _ = writeln!(io::stderr(), "error: {err}");
                    }
                }
            }
        }
    }

    Ok(())
}

fn spawn_sse_listener(
    client: DaemonClient,
    session_id: String,
    conversation_id: String,
    last_event_id: Option<u64>,
    generation: u64,
    tx: Sender<LoopEvent>,
) {
    thread::spawn(move || {
        let mut sse = match client.subscribe_events(&session_id, &conversation_id, last_event_id) {
            Ok(s) => s,
            Err(err) => {
                let _ = tx.send(LoopEvent::SseError {
                    generation,
                    message: err.to_string(),
                });
                return;
            }
        };

        loop {
            match sse.next_event() {
                Ok(Some(ev)) => match ev.decode_frame() {
                    Ok(frame) => {
                        if tx.send(LoopEvent::Sse { generation, frame }).is_err() {
                            break;
                        }
                    }
                    Err(err) => {
                        let _ = tx.send(LoopEvent::SseError {
                            generation,
                            message: err.to_string(),
                        });
                    }
                },
                Ok(None) => {
                    let _ = tx.send(LoopEvent::SseError {
                        generation,
                        message: "stream closed".to_string(),
                    });
                    break;
                }
                Err(err) => {
                    let _ = tx.send(LoopEvent::SseError {
                        generation,
                        message: err.to_string(),
                    });
                    break;
                }
            }
        }
    });
}

#[allow(clippy::too_many_arguments)]
fn handle_interactive_line<W: Write>(
    client: &DaemonClient,
    data_dir: &Path,
    env_id: &str,
    cwd: &str,
    target: &mut AttachedTarget,
    state: &mut TranscriptState,
    _renderer: &mut InlineRenderer<W>,
    line: &str,
) -> Result<Option<String>, AppError> {
    let cid_num: u64 = target.conversation_id.parse().map_err(|_| {
        AppError::Message(format!(
            "invalid conversation_id: {}",
            target.conversation_id
        ))
    })?;

    if line == "/help" {
        print_help();
        return Ok(None);
    }
    if line == "/status" {
        println!(
            "Session: {} · env={} · conv #{} · cwd={} · daemon={} · data_dir={}",
            sanitize_single_line(&target.session_id),
            sanitize_single_line(&target.env_id),
            sanitize_single_line(&target.conversation_id),
            sanitize_single_line(&target.cwd),
            sanitize_single_line(&client.target().display_endpoint()),
            sanitize_single_line(&data_dir.display().to_string()),
        );
        println!("{}", format_status_line(state));
        return Ok(None);
    }
    if line == "/envs" {
        let envs = client.get_environments()?;
        println!("Environments:");
        for env in envs {
            let label = env
                .label
                .as_deref()
                .map(|l| format!(" ({})", sanitize_single_line(l)))
                .unwrap_or_default();
            let kind = env
                .kind
                .as_deref()
                .map(|k| format!(" [{}]", sanitize_single_line(k)))
                .unwrap_or_default();
            let default_cwd = env
                .default_cwd
                .as_deref()
                .map(|c| format!(" cwd={}", sanitize_single_line(c)))
                .unwrap_or_default();
            println!(
                "  {}{}{}{}",
                sanitize_single_line(&env.id),
                label,
                kind,
                default_cwd
            );
        }
        return Ok(None);
    }
    if line == "/earlier" {
        let Some(cursor) = state.before_entry_id.clone() else {
            println!("No earlier entries.");
            return Ok(None);
        };
        let page = client.get_entries(
            &target.session_id,
            &target.conversation_id,
            Some("desc"),
            Some(&cursor),
            Some(50),
        )?;
        let added = state.prepend_older_page(page.items, page.next_cursor);
        println!(
            "Loaded {added} earlier entr{} (has_more={}).",
            if added == 1 { "y" } else { "ies" },
            state.has_more
        );
        return Ok(None);
    }
    if line == "/sessions" {
        let sessions = list_cwd_sessions_sorted(client, env_id, cwd)?;
        print!("{}", format_sessions_list(&sessions, cwd));
        return Ok(None);
    }
    if line == "/branches" {
        let detail = client.get_session_detail(&target.session_id)?;
        print!(
            "{}",
            format_branches_list(&detail.conversations, &target.conversation_id)
        );
        return Ok(None);
    }
    if let Some(arg) = line.strip_prefix("/conv ") {
        let new_cid = arg.trim();
        let _: u64 = new_cid
            .parse()
            .map_err(|_| AppError::Message("usage: /conv <conversation_id>".to_string()))?;
        return Ok(Some(new_cid.to_string()));
    }
    if let Some(arg) = line.strip_prefix("/fork ") {
        let entry_id: u64 = arg
            .trim()
            .parse()
            .map_err(|_| AppError::Message("usage: /fork <entry_id>".to_string()))?;
        let env = CommandEnvelope::fork(generate_request_id(), cid_num, entry_id);
        let receipt = post_command_with_retry(client, &target.session_id, &env)?;
        if let Some(new_cid) = receipt.conversation_id {
            println!("Forked to conversation #{}", sanitize_single_line(&new_cid));
            return Ok(Some(new_cid));
        }
        return Ok(None);
    }
    if line == "/model" {
        let models = client.list_models()?;
        println!("Available models:");
        for m in models {
            let name = m
                .name
                .as_deref()
                .map(|n| format!(" ({})", sanitize_single_line(n)))
                .unwrap_or_default();
            println!("  {}{}", sanitize_single_line(&m.id), name);
        }
        return Ok(None);
    }
    if let Some(arg) = line.strip_prefix("/model ") {
        let model = arg.trim();
        if model.is_empty() {
            return Err(AppError::Message("usage: /model <model_id>".to_string()));
        }
        let env = CommandEnvelope::configure(generate_request_id(), cid_num, Some(model), None);
        let _ = post_command_with_retry(client, &target.session_id, &env)?;
        return Ok(None);
    }
    if let Some(arg) = line.strip_prefix("/thinking ") {
        let level = arg.trim();
        if level.is_empty() {
            return Err(AppError::Message(
                "usage: /thinking <off|minimal|low|medium|high>".to_string(),
            ));
        }
        let env = CommandEnvelope::configure(generate_request_id(), cid_num, None, Some(level));
        let _ = post_command_with_retry(client, &target.session_id, &env)?;
        return Ok(None);
    }
    if line == "/abort" {
        let env = CommandEnvelope::abort(generate_request_id(), cid_num, Some("user_abort"));
        let _ = client.post_command(&target.session_id, &env)?;
        return Ok(None);
    }
    if line == "/continue" {
        let env = CommandEnvelope::submit_continue(generate_request_id(), cid_num);
        let _ = post_command_with_retry(client, &target.session_id, &env)?;
        return Ok(None);
    }
    if let Some(steer_text) = line.strip_prefix("/steer ") {
        let text = steer_text.trim();
        if text.is_empty() {
            return Err(AppError::Message("usage: /steer <message>".to_string()));
        }
        let env = CommandEnvelope::submit_input(
            generate_request_id(),
            cid_num,
            text,
            WhenBusy::Steer,
            WhenIdle::Reject,
        );
        let _ = post_command_with_retry(client, &target.session_id, &env)?;
        return Ok(None);
    }
    if line.starts_with('/') {
        return Err(AppError::Message(format!(
            "unknown command '{}'; type /help for commands",
            sanitize_single_line(line)
        )));
    }

    let env = CommandEnvelope::submit_input(
        generate_request_id(),
        cid_num,
        line,
        WhenBusy::FollowUp,
        WhenIdle::Start,
    );
    let _ = post_command_with_retry(client, &target.session_id, &env)?;
    Ok(None)
}

fn print_banner(
    client: &DaemonClient,
    data_dir: &Path,
    target: &AttachedTarget,
    folder_sessions: &[SessionSummary],
) {
    println!(
        "H session {} (env={}, conv #{}, cwd={}, daemon={}, data_dir={})",
        sanitize_single_line(&target.session_id),
        sanitize_single_line(&target.env_id),
        sanitize_single_line(&target.conversation_id),
        sanitize_single_line(&target.cwd),
        sanitize_single_line(&client.target().display_endpoint()),
        sanitize_single_line(&data_dir.display().to_string())
    );
    let others: Vec<_> = folder_sessions
        .iter()
        .filter(|s| s.session_id != target.session_id)
        .collect();
    if !others.is_empty() {
        println!(
            "Found {} existing session(s) in this folder (use /sessions, `h -c`, or `h -r`).",
            others.len()
        );
    }
    print_help();
}

fn print_help() {
    println!(
        "Commands: /help, /status, /envs, /sessions, /branches, /earlier, /conv <id>, /fork <entry_id>, /model [id], /thinking <lvl>, /steer <msg>, /abort, /continue, /quit"
    );
    println!("Type any prompt and press Enter to submit.");
}

fn post_command_with_retry(
    client: &DaemonClient,
    session_id: &str,
    envelope: &CommandEnvelope,
) -> Result<CommandReceipt, AppError> {
    let mut last_err = None;
    for attempt in 0..3 {
        match client.post_command(session_id, envelope) {
            Ok(receipt) => return Ok(receipt),
            Err(err @ ClientError::ConnectionFailed { .. }) | Err(err @ ClientError::Io(_)) => {
                last_err = Some(err);
                if attempt < 2 {
                    thread::sleep(std::time::Duration::from_millis(50));
                }
            }
            Err(err @ ClientError::HttpStatus { status, .. })
                if status == 408 || status == 429 || status >= 500 =>
            {
                last_err = Some(err);
                if attempt < 2 {
                    thread::sleep(std::time::Duration::from_millis(50));
                }
            }
            Err(err) => return Err(AppError::Client(err)),
        }
    }
    Err(AppError::Client(
        last_err.expect("retry loop always captures error"),
    ))
}

fn decode_app_err(err: protocol::FrameDecodeError) -> AppError {
    AppError::Message(err.to_string())
}

pub fn generate_request_id() -> String {
    let mut bytes = [0u8; 16];
    let urandom_ok = File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .is_ok();

    if !urandom_ok {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        let seq = REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed) as u128;
        let pid = std::process::id() as u128;
        let mixed = nanos ^ (seq.wrapping_mul(0x9E37_79B9_7F4A_7C15)) ^ (pid << 64);
        bytes = mixed.to_le_bytes();
    }

    // Set UUIDv4 version and variant bits
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{DaemonTarget, SecretToken};
    use std::os::unix::net::UnixListener;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn cli_parses_all_required_flags() {
        let cli = Cli::try_parse_from([
            "h",
            "--data-dir",
            "/tmp/h-data",
            "--daemon-url",
            "http://127.0.0.1:4100",
            "--env",
            "vm-1",
            "-s",
            "sess-9",
            "-c",
            "-p",
            "hello",
        ])
        .unwrap();

        assert_eq!(cli.data_dir, Some(PathBuf::from("/tmp/h-data")));
        assert_eq!(cli.daemon_url.as_deref(), Some("http://127.0.0.1:4100"));
        assert_eq!(cli.env_id, "vm-1");
        assert_eq!(cli.session.as_deref(), Some("sess-9"));
        assert!(cli.continue_latest);
        assert_eq!(cli.print_prompt.as_deref(), Some("hello"));

        let cli_pos = Cli::try_parse_from(["h", "summarize", "diff"]).unwrap();
        assert_eq!(resolve_prompt(&cli_pos).as_deref(), Some("summarize diff"));

        let cli_resume = Cli::try_parse_from(["h", "-r"]).unwrap();
        assert!(cli_resume.resume);
    }

    #[test]
    fn request_ids_are_unique_uuid_v4_format() {
        let r1 = generate_request_id();
        let r2 = generate_request_id();
        assert_ne!(r1, r2);
        assert_eq!(r1.len(), 36);
        assert_eq!(&r1[14..15], "4");
    }

    #[test]
    fn pick_latest_session_skips_quarantined_when_healthy_available() {
        let mut sessions = vec![
            SessionSummary {
                session_id: "old".to_string(),
                title: None,
                env_id: Some("host".to_string()),
                harness_id: None,
                cwd: "/tmp/p".to_string(),
                root_conversation_id: Some("1".to_string()),
                created_at: Some(100),
                updated_at: Some(100),
                active: false,
                next_wake_at: None,
                status: Some("ok".to_string()),
            },
            SessionSummary {
                session_id: "quar".to_string(),
                title: None,
                env_id: Some("host".to_string()),
                harness_id: None,
                cwd: "/tmp/p".to_string(),
                root_conversation_id: Some("1".to_string()),
                created_at: Some(200),
                updated_at: Some(200),
                active: false,
                next_wake_at: None,
                status: Some("quarantined".to_string()),
            },
        ];
        sort_sessions_latest_first(&mut sessions);
        assert_eq!(pick_latest_session(&sessions).unwrap().session_id, "old");
    }

    #[test]
    fn headless_prompt_flow_end_to_end_over_unix_socket() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sock_path = PathBuf::from(format!("/private/tmp/h-e2e-test-{nanos}.sock"));
        let _ = std::fs::remove_file(&sock_path);
        let listener = UnixListener::bind(&sock_path).unwrap();

        let handle = thread::spawn(move || {
            // 1. GET /api/v1/sessions/:sid/conversations/1/events
            let (mut sse_sock, _) = listener.accept().unwrap();
            let mut buf = [0u8; 2048];
            let _ = sse_sock.read(&mut buf).unwrap();
            write!(
                sse_sock,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
            )
            .unwrap();
            let snap = "id: 1\nevent: snapshot\ndata: {\"seq\":1,\"entries\":[],\"docs\":{\"live\":{},\"inbox\":[],\"agent\":{},\"usage\":{}}}\n\n";
            write!(sse_sock, "{:x}\r\n{}\r\n", snap.len(), snap).unwrap();
            sse_sock.flush().unwrap();

            // 2. POST /api/v1/sessions/demo/commands
            let (mut cmd_sock, _) = listener.accept().unwrap();
            let n = cmd_sock.read(&mut buf).unwrap();
            let req_str = String::from_utf8_lossy(&buf[..n]).to_string();
            assert!(req_str.starts_with("POST /api/v1/sessions/demo/commands HTTP/1.1"));
            let receipt = r#"{"version":1,"request_id":"r1","seq":2,"submission_id":"sub1","status":"placed"}"#;
            write!(
                cmd_sock,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                receipt.len(),
                receipt
            )
            .unwrap();
            cmd_sock.flush().unwrap();

            // 3. Emit commit seq 2 (user + live.run active), ephemeral, then commit seq 3 (assistant done + live empty)
            let c2 = "id: 2\nevent: commit\ndata: {\"seq\":2,\"prev_seq\":1,\"appended_entries\":[{\"id\":\"1\",\"kind\":\"user\",\"data\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}],\"doc_ops\":{\"live\":[[\"replace\",{\"run\":{\"turns\":1}}]]}}\n\n";
            write!(sse_sock, "{:x}\r\n{}\r\n", c2.len(), c2).unwrap();
            let eph = "event: ephemeral\ndata: {\"base_seq\":2,\"doc_ops\":{\"live\":[[\"append_text\",[\"generation\",\"message\",\"text\"],\"Done\"]]}}\n\n";
            write!(sse_sock, "{:x}\r\n{}\r\n", eph.len(), eph).unwrap();
            let c3 = "id: 3\nevent: commit\ndata: {\"seq\":3,\"prev_seq\":2,\"appended_entries\":[{\"id\":\"2\",\"kind\":\"assistant\",\"data\":{\"content\":[{\"type\":\"text\",\"text\":\"Done!\"}]}}],\"doc_ops\":{\"live\":[[\"replace\",{}]]}}\n\n";
            write!(sse_sock, "{:x}\r\n{}\r\n", c3.len(), c3).unwrap();
            write!(sse_sock, "0\r\n\r\n").unwrap();
            sse_sock.flush().unwrap();
        });

        let client = DaemonClient::new(
            DaemonTarget::UnixSocket(sock_path.clone()),
            SecretToken::new("tok-e2e").unwrap(),
        );
        run_headless_prompt(&client, "demo", "1", "hi").unwrap();

        handle.join().unwrap();
        let _ = std::fs::remove_file(&sock_path);
    }
}
