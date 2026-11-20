use crate::{client, config, protocol, render, transcript};

use clap::{CommandFactory, FromArgMatches, Parser};
use client::{ClientError, DaemonClient};
use config::{resolve_config, ConfigError};
use protocol::{
    CommandEnvelope, CommandReceipt, CreateSessionRequest, ServerFrame, SessionParent,
    SessionSummary, TranscriptEntry, WhenBusy, WhenIdle,
};
use render::{extract_entry_text, sanitize_terminal_text};
use serde_json::{Map, Value};
use std::fmt;
use std::fs::File;
use std::io::{self, IsTerminal, Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use transcript::{CommitOutcome, TranscriptState};

static REQUEST_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Parser)]
#[command(
    name = "hi inbox",
    version,
    about = "Browse all H sessions across workspaces in an interactive inbox"
)]
struct InboxCli {
    /// Override H data directory (default: $H_DATA_DIR or ~/.local/share/h)
    #[arg(long, value_name = "PATH")]
    data_dir: Option<PathBuf>,

    /// Override daemon URL (literal loopback http://127.0.0.1:<port> or http://[::1]:<port>)
    #[arg(long, value_name = "URL")]
    daemon_url: Option<String>,

    /// hi terminal layout (interactive TTY only)
    #[arg(long, value_parser = ["fullscreen", "regular"], default_value = "fullscreen")]
    tui_mode: String,

    /// Default execution environment ID for new sessions created from the inbox
    #[arg(long = "env", value_name = "ID", default_value = "host")]
    env_id: String,

    /// Show hierarchical subsessions nested beneath their parent sessions on startup
    #[arg(long)]
    subsessions: bool,
}

#[derive(Debug, Parser)]
#[command(
    name = "hi",
    version,
    about = "Interactive terminal for the durable H daemon"
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

    /// Attach to this conversation in the named session
    #[arg(long, requires = "session")]
    conversation: Option<u64>,

    /// Continue the most recent session for the current working directory
    #[arg(short = 'c', long = "continue")]
    continue_latest: bool,

    /// List and resume a session for the current working directory
    #[arg(short = 'r', long = "resume")]
    resume: bool,

    /// Model ID to configure on the session (e.g. provider:model)
    #[arg(long, value_name = "MODEL")]
    model: Option<String>,

    /// Thinking level to configure on the session (e.g. off, minimal, low, medium, high)
    #[arg(long, value_name = "LEVEL")]
    thinking: Option<String>,

    /// Session display title
    #[arg(long, value_name = "TITLE")]
    title: Option<String>,

    /// Parent session ID when spawning a subsession
    #[arg(long, value_name = "SESSION_ID")]
    parent: Option<String>,

    /// Parent conversation ID when spawning a subsession
    #[arg(long = "parent-conversation", value_name = "CID", requires = "parent")]
    parent_conversation: Option<u64>,

    /// Parent entry ID anchor when spawning a subsession
    #[arg(long = "parent-entry", value_name = "ENTRY_ID", requires = "parent")]
    parent_entry: Option<u64>,

    /// Headless print mode: submit prompt, stream assistant text to stdout, and exit
    #[arg(
        short = 'p',
        long = "print",
        value_name = "PROMPT",
        conflicts_with = "prompt"
    )]
    print_prompt: Option<String>,

    /// Initial prompt (opens interactive TUI and submits on a TTY, or runs headless print mode when piped or TERM=dumb)
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

pub fn hi_main() -> ExitCode {
    let args: Vec<_> = std::env::args_os().collect();
    // Reserve these first words for hi management and inbox browser. `--` and -p
    // keep literal prompts possible.
    if args
        .get(1)
        .and_then(|arg| arg.to_str())
        .is_some_and(|arg| matches!(arg, "login" | "account" | "daemon"))
    {
        return report(
            crate::manage::run(crate::manage::Manage::parse_from(args)).map_err(AppError::Message),
        );
    }
    if args.get(1).and_then(|arg| arg.to_str()) == Some("inbox") {
        let mut inbox_args = Vec::with_capacity(args.len().saturating_sub(1));
        if let Some(bin) = args.first() {
            inbox_args.push(bin.clone());
        }
        inbox_args.extend(args.into_iter().skip(2));
        let inbox_cli = InboxCli::parse_from(inbox_args);
        return report(run_inbox_cli(inbox_cli));
    }
    let cmd = Cli::command()
        .after_help("Subcommands: hi inbox, hi login, hi account, hi daemon (each accepts --help)");
    let cli = Cli::from_arg_matches(&cmd.get_matches_from(args)).unwrap_or_else(|err| err.exit());
    report(run(cli))
}

fn run_inbox_cli(cli: InboxCli) -> Result<(), AppError> {
    let interactive = io::stdin().is_terminal()
        && io::stdout().is_terminal()
        && std::env::var("TERM").as_deref() != Ok("dumb");
    if !interactive {
        return Err(AppError::Message(
            "hi inbox requires an interactive TTY".into(),
        ));
    }
    let cfg = resolve_config(cli.data_dir.as_deref(), cli.daemon_url.as_deref())?;
    let client = DaemonClient::new(cfg.target, cfg.token);
    let cwd = current_cwd_string()?;
    let reexec = crate::hi::app::RestartOrigin {
        daemon_url: cli.daemon_url.clone(),
    };
    crate::hi::app::run_inbox(
        client,
        cli.env_id,
        cwd,
        &cfg.data_dir,
        cli.tui_mode == "regular",
        cli.subsessions,
        reexec,
    )
    .map_err(AppError::Message)
}

fn report(result: Result<(), AppError>) -> ExitCode {
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            let _ = writeln!(io::stderr(), "error: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<(), AppError> {
    let cfg = resolve_config(cli.data_dir.as_deref(), cli.daemon_url.as_deref())?;
    let client = DaemonClient::new(cfg.target, cfg.token);
    let cwd = current_cwd_string()?;

    let create_opts = SessionCreateOptions::from_cli(&cli);

    let interactive = cli.print_prompt.is_none()
        && io::stdin().is_terminal()
        && io::stdout().is_terminal()
        && std::env::var("TERM").as_deref() != Ok("dumb");
    if interactive {
        let target = if let (Some(sid), Some(cid)) = (cli.session.as_deref(), cli.conversation) {
            let detail = client.get_session_detail(sid)?;
            let cid = cid.to_string();
            if !detail.conversations.iter().any(|c| c.id == cid) {
                return Err(AppError::Message(
                    "Conversation is not in that session".into(),
                ));
            }
            let target = target_from_detail(detail, cid);
            apply_attached_overrides(&client, &target, &create_opts)?;
            target
        } else {
            resolve_session_for_run(
                &client,
                &cli.env_id,
                &cwd,
                cli.session.as_deref(),
                cli.continue_latest || cli.resume,
                &create_opts,
            )?
        };
        let reexec = crate::hi::app::RestartOrigin {
            daemon_url: cli.daemon_url.clone(),
        };
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
            reexec,
        )
        .map_err(AppError::Message);
    }
    if cli.conversation.is_some() {
        return Err(AppError::Message(
            "--conversation is supported in interactive mode only".into(),
        ));
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
            &create_opts,
        )?;
        return run_headless_prompt(
            &client,
            &target.session_id,
            &target.conversation_id,
            &prompt,
        );
    }

    Err(AppError::Message(
        "interactive mode requires a TTY (pass -p <PROMPT> for headless print mode)".into(),
    ))
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

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct SessionCreateOptions {
    model: Option<String>,
    thinking: Option<String>,
    title: Option<String>,
    parent: Option<SessionParent>,
}

impl SessionCreateOptions {
    fn from_cli(cli: &Cli) -> Self {
        let model = cli
            .model
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let thinking = cli
            .thinking
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let title = cli
            .title
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let parent = cli
            .parent
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|sid| SessionParent {
                session_id: sid.to_string(),
                conversation_id: cli.parent_conversation.map(|cid| cid.to_string()),
                at_entry_id: cli.parent_entry.map(|eid| eid.to_string()),
                task_id: None,
                depth: None,
            });
        Self {
            model,
            thinking,
            title,
            parent,
        }
    }

    fn has_creation_flags(&self) -> bool {
        self.model.is_some()
            || self.thinking.is_some()
            || self.title.is_some()
            || self.parent.is_some()
    }

    fn agent_value(&self) -> Option<Value> {
        let mut map = Map::new();
        if let Some(m) = self.model.as_ref() {
            map.insert("model".to_string(), Value::String(m.clone()));
        }
        if let Some(t) = self.thinking.as_ref() {
            map.insert("thinking".to_string(), Value::String(t.clone()));
        }
        (!map.is_empty()).then_some(Value::Object(map))
    }

    fn role(&self) -> Option<String> {
        self.parent.as_ref().map(|_| "subagent".to_string())
    }
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
        .filter(|s| s.is_root_session())
        .find(|s| s.status.as_deref() != Some("quarantined"))
        .or_else(|| sessions.iter().find(|s| s.is_root_session()))
}

fn resolve_session_for_run(
    client: &DaemonClient,
    env_id: &str,
    cwd: &str,
    explicit_sid: Option<&str>,
    continue_latest: bool,
    opts: &SessionCreateOptions,
) -> Result<AttachedTarget, AppError> {
    if let Some(sid) = explicit_sid {
        return match attach_named_session(client, sid) {
            Ok(target) => {
                apply_attached_overrides(client, &target, opts)?;
                Ok(target)
            }
            Err(AppError::Client(ClientError::HttpStatus { status: 404, .. }))
                if opts.has_creation_flags() =>
            {
                create_session_with_options(client, env_id, cwd, Some(sid.to_string()), opts)
            }
            Err(err) => Err(err),
        };
    }
    if continue_latest {
        let sessions = list_cwd_sessions_sorted(client, env_id, cwd)?;
        return continue_or_create_session(client, env_id, cwd, &sessions, opts);
    }
    create_auto_session(client, env_id, cwd, opts)
}

fn apply_attached_overrides(
    client: &DaemonClient,
    target: &AttachedTarget,
    opts: &SessionCreateOptions,
) -> Result<(), AppError> {
    if opts.model.is_none() && opts.thinking.is_none() && opts.title.is_none() {
        return Ok(());
    }
    let cid_num: u64 = target.conversation_id.parse().map_err(|_| {
        AppError::Message(format!(
            "invalid conversation_id: {}",
            target.conversation_id
        ))
    })?;
    if opts.model.is_some() || opts.thinking.is_some() {
        let env = CommandEnvelope::configure(
            generate_request_id(),
            cid_num,
            opts.model.as_deref(),
            opts.thinking.as_deref(),
        );
        post_command_with_retry(client, &target.session_id, &env)?;
    }
    if let Some(title) = opts.title.as_deref() {
        let env = CommandEnvelope::rename(generate_request_id(), cid_num, Some(title));
        post_command_with_retry(client, &target.session_id, &env)?;
    }
    Ok(())
}

fn attach_named_session(client: &DaemonClient, sid: &str) -> Result<AttachedTarget, AppError> {
    let detail = client.get_session_detail(sid)?;
    let cid = detail
        .session
        .root_conversation_id
        .clone()
        .or_else(|| detail.conversations.first().map(|c| c.id.clone()))
        .unwrap_or_else(|| "1".to_string());
    Ok(target_from_detail(detail, cid))
}

fn target_from_detail(detail: protocol::SessionDetailResponse, cid: String) -> AttachedTarget {
    AttachedTarget {
        labels: (&detail.session).into(),
        session_id: detail.session.session_id,
        conversation_id: cid,
        cwd: detail.session.cwd,
        env_id: detail.session.env_id.unwrap_or_else(|| "host".to_string()),
    }
}

fn continue_or_create_session(
    client: &DaemonClient,
    env_id: &str,
    cwd: &str,
    sorted_sessions: &[SessionSummary],
    opts: &SessionCreateOptions,
) -> Result<AttachedTarget, AppError> {
    if let Some(latest) = pick_latest_session(sorted_sessions) {
        let cid = latest
            .root_conversation_id
            .clone()
            .unwrap_or_else(|| "1".to_string());
        let target = AttachedTarget {
            labels: latest.into(),
            session_id: latest.session_id.clone(),
            conversation_id: cid,
            cwd: latest.cwd.clone(),
            env_id: latest.env_id.clone().unwrap_or_else(|| env_id.to_string()),
        };
        apply_attached_overrides(client, &target, opts)?;
        return Ok(target);
    }
    create_auto_session(client, env_id, cwd, opts)
}

fn create_auto_session(
    client: &DaemonClient,
    env_id: &str,
    cwd: &str,
    opts: &SessionCreateOptions,
) -> Result<AttachedTarget, AppError> {
    create_session_with_options(client, env_id, cwd, Some(generate_request_id()), opts)
}

fn create_session_with_options(
    client: &DaemonClient,
    env_id: &str,
    cwd: &str,
    session_id: Option<String>,
    opts: &SessionCreateOptions,
) -> Result<AttachedTarget, AppError> {
    let req = CreateSessionRequest {
        version: 1,
        request_id: generate_request_id(),
        env_id: env_id.to_string(),
        cwd: cwd.to_string(),
        session_id,
        title: opts.title.clone(),
        agent: opts.agent_value(),
        parent: opts.parent.clone(),
        role: opts.role(),
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
            "hi",
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

        let inbox = InboxCli::try_parse_from([
            "hi",
            "--data-dir",
            "/tmp/h-data",
            "--daemon-url",
            "http://127.0.0.1:4100",
            "--tui-mode",
            "regular",
            "--env",
            "vm-1",
        ])
        .unwrap();
        assert_eq!(inbox.data_dir, Some(PathBuf::from("/tmp/h-data")));
        assert_eq!(inbox.daemon_url.as_deref(), Some("http://127.0.0.1:4100"));
        assert_eq!(inbox.tui_mode, "regular");
        assert_eq!(inbox.env_id, "vm-1");

        // Literal prompt starting with "inbox" still works via `-- inbox` or `-p "inbox ..."`
        let literal = Cli::try_parse_from(["hi", "--", "inbox", "status"]).unwrap();
        assert_eq!(literal.prompt, vec!["inbox", "status"]);
        let printed = Cli::try_parse_from(["hi", "-p", "inbox check"]).unwrap();
        assert_eq!(printed.print_prompt.as_deref(), Some("inbox check"));

        let cli_pos = Cli::try_parse_from(["hi", "summarize", "diff"]).unwrap();
        assert_eq!(resolve_prompt(&cli_pos).as_deref(), Some("summarize diff"));

        let cli_resume = Cli::try_parse_from(["hi", "-r"]).unwrap();
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
                attention: None,
                activity_kind: None,
                activity_label: None,
                queued_count: 0,
                next_wake_at: None,
                status: Some("ok".to_string()),
                parent: None,
                role: None,
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
                attention: None,
                activity_kind: None,
                activity_label: None,
                queued_count: 0,
                next_wake_at: None,
                status: Some("quarantined".to_string()),
                parent: None,
                role: None,
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

    #[test]
    fn cli_parses_delegation_and_inbox_subsessions_flags() {
        let cli = Cli::try_parse_from([
            "hi",
            "--model",
            "google:gemini-4-neon",
            "--thinking",
            "high",
            "--title",
            "Worker Lane",
            "--parent",
            "coord-1",
            "--parent-conversation",
            "2",
            "--parent-entry",
            "42",
            "-p",
            "implement feature",
        ])
        .unwrap();

        assert_eq!(cli.model.as_deref(), Some("google:gemini-4-neon"));
        assert_eq!(cli.thinking.as_deref(), Some("high"));
        assert_eq!(cli.title.as_deref(), Some("Worker Lane"));
        assert_eq!(cli.parent.as_deref(), Some("coord-1"));
        assert_eq!(cli.parent_conversation, Some(2));
        assert_eq!(cli.parent_entry, Some(42));
        assert_eq!(cli.print_prompt.as_deref(), Some("implement feature"));

        let opts = SessionCreateOptions::from_cli(&cli);
        assert!(opts.has_creation_flags());
        assert_eq!(opts.role().as_deref(), Some("subagent"));
        assert_eq!(
            opts.agent_value(),
            Some(serde_json::json!({"model": "google:gemini-4-neon", "thinking": "high"}))
        );
        assert_eq!(
            opts.parent,
            Some(SessionParent {
                session_id: "coord-1".to_string(),
                conversation_id: Some("2".to_string()),
                at_entry_id: Some("42".to_string()),
                task_id: None,
                depth: None,
            })
        );

        // --parent-conversation and --parent-entry require --parent
        assert!(Cli::try_parse_from(["hi", "--parent-conversation", "2"]).is_err());
        assert!(Cli::try_parse_from(["hi", "--parent-entry", "42"]).is_err());

        // hi inbox --subsessions
        let inbox_default = InboxCli::try_parse_from(["hi"]).unwrap();
        assert!(!inbox_default.subsessions);
        let inbox_sub = InboxCli::try_parse_from(["hi", "--subsessions"]).unwrap();
        assert!(inbox_sub.subsessions);
    }

    #[test]
    fn pick_latest_session_skips_subsessions() {
        let mut sessions = vec![
            SessionSummary {
                session_id: "root-old".to_string(),
                title: Some("Root".to_string()),
                env_id: Some("host".to_string()),
                harness_id: None,
                cwd: "/tmp/p".to_string(),
                root_conversation_id: Some("1".to_string()),
                created_at: Some(100),
                updated_at: Some(100),
                active: false,
                attention: None,
                activity_kind: None,
                activity_label: None,
                queued_count: 0,
                next_wake_at: None,
                status: Some("ok".to_string()),
                parent: None,
                role: None,
            },
            SessionSummary {
                session_id: "sub-newer".to_string(),
                title: Some("Subagent".to_string()),
                env_id: Some("host".to_string()),
                harness_id: None,
                cwd: "/tmp/p".to_string(),
                root_conversation_id: Some("1".to_string()),
                created_at: Some(300),
                updated_at: Some(300),
                active: false,
                attention: None,
                activity_kind: None,
                activity_label: None,
                queued_count: 0,
                next_wake_at: None,
                status: Some("ok".to_string()),
                parent: Some(SessionParent {
                    session_id: "root-old".to_string(),
                    conversation_id: Some("1".to_string()),
                    at_entry_id: Some("10".to_string()),
                    task_id: None,
                    depth: Some(1),
                }),
                role: Some("subagent".to_string()),
            },
        ];
        sort_sessions_latest_first(&mut sessions);
        assert_eq!(sessions[0].session_id, "sub-newer");
        assert_eq!(
            pick_latest_session(&sessions).unwrap().session_id,
            "root-old"
        );

        // When only subsessions exist, pick_latest_session returns None (so hi -c starts a root session)
        let only_subs = vec![sessions[0].clone()];
        assert!(pick_latest_session(&only_subs).is_none());
    }

    #[test]
    fn resolve_session_creates_with_agent_title_parent_and_named_fallback() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sock_path = PathBuf::from(format!("/private/tmp/h-cli-create-{nanos}.sock"));
        let _ = std::fs::remove_file(&sock_path);
        let listener = UnixListener::bind(&sock_path).unwrap();

        let captured = std::sync::Arc::new(std::sync::Mutex::new(Vec::<(String, Value)>::new()));
        let captured_srv = std::sync::Arc::clone(&captured);

        let handle = thread::spawn(move || {
            let read_req = |sock: &mut std::os::unix::net::UnixStream| -> (String, String) {
                let mut raw = Vec::new();
                let mut buf = [0u8; 4096];
                let mut header_end = None;
                let mut content_len = 0usize;
                loop {
                    let n = sock.read(&mut buf).unwrap();
                    if n == 0 {
                        break;
                    }
                    raw.extend_from_slice(&buf[..n]);
                    if header_end.is_none() {
                        if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                            header_end = Some(pos + 4);
                            let headers = String::from_utf8_lossy(&raw[..pos]);
                            for line in headers.lines() {
                                if let Some((k, v)) = line.split_once(':') {
                                    if k.eq_ignore_ascii_case("content-length") {
                                        content_len = v.trim().parse().unwrap_or(0);
                                    }
                                }
                            }
                        }
                    }
                    if let Some(end) = header_end {
                        if raw.len() >= end + content_len {
                            break;
                        }
                    }
                }
                let end = header_end.unwrap_or(raw.len());
                let head = String::from_utf8_lossy(&raw[..end]).to_string();
                let body = String::from_utf8_lossy(&raw[end..]).to_string();
                (head, body)
            };

            // 1. Auto session create with model/thinking/title/parent
            let (mut s1, _) = listener.accept().unwrap();
            let (h1, b1) = read_req(&mut s1);
            let req_line1 = h1.lines().next().unwrap_or("").to_string();
            let body_json1: Value = serde_json::from_str(&b1).unwrap();
            captured_srv
                .lock()
                .unwrap()
                .push((req_line1, body_json1.clone()));
            let resp1 = serde_json::json!({
                "seq": 1,
                "session": {
                    "session_id": body_json1["session_id"],
                    "title": body_json1["title"],
                    "env_id": "host",
                    "cwd": "/tmp/wt-1",
                    "root_conversation_id": "1",
                    "active": false,
                    "parent": body_json1["parent"],
                    "role": "subagent"
                }
            })
            .to_string();
            write!(
                s1,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{resp1}",
                resp1.len()
            )
            .unwrap();
            s1.flush().unwrap();

            // 2. Named session -s sub-named with creation flags: GET returns 404 -> POST creates it
            let (mut s2, _) = listener.accept().unwrap();
            let (h2, _) = read_req(&mut s2);
            assert!(h2.starts_with("GET /api/v1/sessions/sub-named HTTP/1.1"));
            let not_found = r#"{"error":"not_found"}"#;
            write!(
                s2,
                "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{not_found}",
                not_found.len()
            )
            .unwrap();
            s2.flush().unwrap();

            let (mut s3, _) = listener.accept().unwrap();
            let (h3, b3) = read_req(&mut s3);
            let req_line3 = h3.lines().next().unwrap_or("").to_string();
            let body_json3: Value = serde_json::from_str(&b3).unwrap();
            captured_srv.lock().unwrap().push((req_line3, body_json3));
            let resp3 = r#"{"seq":1,"session":{"session_id":"sub-named","title":"Named Sub","env_id":"host","cwd":"/tmp/wt-1","root_conversation_id":"1","active":false,"parent":{"session_id":"coord-1","conversation_id":"1","at_entry_id":"42","depth":1},"role":"subagent"}}"#;
            write!(
                s3,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{resp3}",
                resp3.len()
            )
            .unwrap();
            s3.flush().unwrap();

            // 3. Unknown named session WITHOUT creation flags still fails with 404
            let (mut s4, _) = listener.accept().unwrap();
            let (h4, _) = read_req(&mut s4);
            assert!(h4.starts_with("GET /api/v1/sessions/missing-sid HTTP/1.1"));
            write!(
                s4,
                "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{not_found}",
                not_found.len()
            )
            .unwrap();
            s4.flush().unwrap();

            // 4. Existing named session WITH --model/--thinking/--title sends configure + rename
            let (mut s5, _) = listener.accept().unwrap();
            let (h5, _) = read_req(&mut s5);
            assert!(h5.starts_with("GET /api/v1/sessions/existing HTTP/1.1"));
            let detail = r#"{"session":{"session_id":"existing","env_id":"host","cwd":"/tmp/wt-1","root_conversation_id":"1","active":false},"conversations":[{"id":"1"}],"tasks":[]}"#;
            write!(
                s5,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{detail}",
                detail.len()
            )
            .unwrap();
            s5.flush().unwrap();

            let (mut s6, _) = listener.accept().unwrap();
            let (h6, b6) = read_req(&mut s6);
            captured_srv.lock().unwrap().push((
                h6.lines().next().unwrap_or("").to_string(),
                serde_json::from_str(&b6).unwrap(),
            ));
            let r6 = r#"{"version":1,"request_id":"r6","seq":2,"status":"ok"}"#;
            write!(
                s6,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{r6}",
                r6.len()
            )
            .unwrap();
            s6.flush().unwrap();

            let (mut s7, _) = listener.accept().unwrap();
            let (h7, b7) = read_req(&mut s7);
            captured_srv.lock().unwrap().push((
                h7.lines().next().unwrap_or("").to_string(),
                serde_json::from_str(&b7).unwrap(),
            ));
            let r7 = r#"{"version":1,"request_id":"r7","seq":3,"status":"ok"}"#;
            write!(
                s7,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{r7}",
                r7.len()
            )
            .unwrap();
            s7.flush().unwrap();
        });

        let client = DaemonClient::new(
            DaemonTarget::UnixSocket(sock_path.clone()),
            SecretToken::new("tok-cli").unwrap(),
        );

        let opts = SessionCreateOptions {
            model: Some("google:gemini-4-neon".to_string()),
            thinking: Some("high".to_string()),
            title: Some("Worker".to_string()),
            parent: Some(SessionParent {
                session_id: "coord-1".to_string(),
                conversation_id: Some("1".to_string()),
                at_entry_id: Some("42".to_string()),
                task_id: None,
                depth: None,
            }),
        };

        let t1 = resolve_session_for_run(&client, "host", "/tmp/wt-1", None, false, &opts).unwrap();
        assert_eq!(t1.labels.title.as_deref(), Some("Worker"));
        assert_eq!(
            t1.labels.parent.as_ref().map(|p| p.session_id.as_str()),
            Some("coord-1")
        );

        let named_opts = SessionCreateOptions {
            title: Some("Named Sub".to_string()),
            parent: opts.parent.clone(),
            ..SessionCreateOptions::default()
        };
        let t2 = resolve_session_for_run(
            &client,
            "host",
            "/tmp/wt-1",
            Some("sub-named"),
            false,
            &named_opts,
        )
        .unwrap();
        assert_eq!(t2.session_id, "sub-named");

        let err = resolve_session_for_run(
            &client,
            "host",
            "/tmp/wt-1",
            Some("missing-sid"),
            false,
            &SessionCreateOptions::default(),
        )
        .unwrap_err();
        assert!(matches!(
            err,
            AppError::Client(ClientError::HttpStatus { status: 404, .. })
        ));

        let t4 =
            resolve_session_for_run(&client, "host", "/tmp/wt-1", Some("existing"), false, &opts)
                .unwrap();
        assert_eq!(t4.session_id, "existing");

        handle.join().unwrap();
        let _ = std::fs::remove_file(&sock_path);

        let reqs = captured.lock().unwrap();
        assert_eq!(reqs.len(), 4);
        assert_eq!(reqs[0].0, "POST /api/v1/sessions HTTP/1.1");
        assert_eq!(reqs[0].1["title"], "Worker");
        assert_eq!(reqs[0].1["agent"]["model"], "google:gemini-4-neon");
        assert_eq!(reqs[0].1["agent"]["thinking"], "high");
        assert_eq!(reqs[0].1["parent"]["session_id"], "coord-1");
        assert_eq!(reqs[0].1["parent"]["conversation_id"], "1");
        assert_eq!(reqs[0].1["parent"]["at_entry_id"], "42");
        assert_eq!(reqs[0].1["role"], "subagent");

        assert_eq!(reqs[1].0, "POST /api/v1/sessions HTTP/1.1");
        assert_eq!(reqs[1].1["session_id"], "sub-named");
        assert_eq!(reqs[1].1["role"], "subagent");

        assert_eq!(
            reqs[2].0,
            "POST /api/v1/sessions/existing/commands HTTP/1.1"
        );
        assert_eq!(reqs[2].1["command"], "configure");
        assert_eq!(reqs[2].1["args"]["model"], "google:gemini-4-neon");
        assert_eq!(reqs[2].1["args"]["thinking"], "high");

        assert_eq!(
            reqs[3].0,
            "POST /api/v1/sessions/existing/commands HTTP/1.1"
        );
        assert_eq!(reqs[3].1["command"], "rename");
        assert_eq!(reqs[3].1["args"]["title"], "Worker");
    }
}
