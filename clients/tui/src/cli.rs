use crate::{client, config, protocol, render, transcript};

use clap::{CommandFactory, FromArgMatches, Parser};
use client::{ClientError, DaemonClient};
use config::{resolve_config, ConfigError};
use protocol::{
    CommandEnvelope, CommandReceipt, CreateSessionRequest, ServerFrame, SessionSummary,
    TranscriptEntry, WhenBusy, WhenIdle,
};
use render::{extract_entry_text, sanitize_terminal_text};
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
    if let Some(name) = args.get(1).and_then(|arg| arg.to_str()) {
        if let Some(result) = exec_extension(name, &args[2..]) {
            return report(Err(AppError::Message(result)));
        }
        if name == "import" {
            return report(Err(AppError::Message(
                "hi import requires hi-import on PATH".into(),
            )));
        }
    }
    let cmd = Cli::command().after_help(
        "Subcommands: hi inbox, hi login, hi account, hi daemon. Extensions: hi <name> runs hi-<name> from PATH (e.g. hi import). Use -- for a literal prompt.",
    );
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
        reexec,
    )
    .map_err(AppError::Message)
}

fn exec_extension(name: &str, args: &[std::ffi::OsString]) -> Option<String> {
    use std::os::unix::{fs::PermissionsExt, process::CommandExt};

    if !name.starts_with(|c: char| c.is_ascii_lowercase())
        || !name
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
    {
        return None;
    }
    let executable = format!("hi-{name}");
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path).filter(|dir| dir.is_absolute()) {
        let command = dir.join(&executable);
        if command
            .metadata()
            .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        {
            let err = std::process::Command::new(command).args(args).exec();
            return Some(format!("could not run {executable}: {err}"));
        }
    }
    None
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
            target_from_detail(detail, cid)
        } else {
            resolve_session_for_run(
                &client,
                &cli.env_id,
                &cwd,
                cli.session.as_deref(),
                cli.continue_latest || cli.resume,
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
        .filter(|s| s.status.as_deref() != Some("archived"))
        .min_by_key(|s| s.status.as_deref() == Some("quarantined"))
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
