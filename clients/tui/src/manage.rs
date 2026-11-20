//! Owner operations that do not create or attach a conversation.
use crate::{
    cli::generate_request_id,
    client::{ClientError, DaemonClient, LoginState},
    config::ConfigError,
    hi::login::source_id,
};
use clap::{Parser, Subcommand};
use std::{
    io::{self, Write},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};

#[derive(Parser)]
#[command(name = "hi", version, about = "H terminal and local daemon management")]
pub(crate) struct Manage {
    #[arg(long, global = true)]
    pub(crate) data_dir: Option<PathBuf>,
    #[arg(long, global = true)]
    pub(crate) daemon_url: Option<String>,
    #[command(subcommand)]
    pub(crate) command: Command,
}

#[derive(Subcommand)]
pub(crate) enum Command {
    /// Sign into Codex without opening a session
    Login {
        #[arg(default_value = "openai_codex")]
        provider: String,
        source: Option<String>,
    },
    /// List and configure daemon-owned account aliases
    Account {
        #[command(subcommand)]
        action: Account,
    },
    /// Manage the local H daemon, not a conversation
    Daemon {
        #[command(subcommand)]
        action: Daemon,
    },
}

#[derive(Subcommand)]
pub(crate) enum Account {
    List,
    Add { source: String },
    Use { source: String },
}

#[derive(Subcommand)]
pub(crate) enum Daemon {
    /// Check that the configured daemon responds to authenticated requests
    Status,
    /// Install the prebuilt launcher as a per-user macOS LaunchAgent
    InstallService {
        #[arg(long)]
        launcher: Option<PathBuf>,
    },
    /// Stop a standalone daemon only if no session has unfinished work
    Stop,
    /// Restart an idle standalone daemon in the foreground
    Restart {
        #[arg(long)]
        launcher: Option<PathBuf>,
        #[arg(long)]
        port: Option<u16>,
        #[arg(long)]
        no_extensions: bool,
    },
    /// Start the registered per-user macOS service if stopped
    StartService,
    /// Check launchd registration without starting or stopping the service
    CheckService,
    /// Restart an idle hi-managed macOS service
    RestartService,
    /// Unload and remove the hi-managed macOS service
    UninstallService,
    /// Run a packaged daemon in the foreground (Ctrl+C to stop)
    Start {
        /// Path to a prebuilt daemon launcher; default: sibling h-daemon or H_DAEMON_BIN
        #[arg(long)]
        launcher: Option<PathBuf>,
        #[arg(long)]
        port: Option<u16>,
        #[arg(long)]
        no_extensions: bool,
    },
}

pub(crate) fn run(args: Manage) -> Result<(), String> {
    match args.command {
        Command::Daemon {
            action:
                Daemon::Start {
                    launcher,
                    port,
                    no_extensions,
                },
        } => {
            reject_remote(args.daemon_url.as_deref())?;
            return start(data_dir(args.data_dir)?, launcher, port, no_extensions);
        }
        Command::Daemon {
            action: Daemon::InstallService { launcher },
        } => {
            reject_remote(args.daemon_url.as_deref())?;
            let dir = data_dir(args.data_dir)?;
            // Don't ask launchd to race a daemon that the owner launched manually.
            if let Ok(cfg) = crate::config::resolve_config(Some(&dir), None) {
                if DaemonClient::new(cfg.target, cfg.token)
                    .get_environments()
                    .is_ok()
                {
                    return Err(
                        "Stop the current daemon yourself before installing its service".into(),
                    );
                }
            }
            return crate::service::control("install", &dir, launcher);
        }
        Command::Daemon {
            action: Daemon::Stop,
        } => {
            reject_remote(args.daemon_url.as_deref())?;
            stop_if_idle(&data_dir(args.data_dir)?)?;
            println!("Daemon stopped.");
            return Ok(());
        }
        Command::Daemon {
            action:
                Daemon::Restart {
                    launcher,
                    port,
                    no_extensions,
                },
        } => {
            reject_remote(args.daemon_url.as_deref())?;
            let dir = data_dir(args.data_dir)?;
            let launcher = daemon_launcher(launcher, false)?;
            if crate::service::is_installed(&dir) {
                return Err("This store has a hi-managed LaunchAgent. Use `hi daemon restart-service`, not foreground restart.".into());
            }
            preflight(&launcher, &dir, no_extensions)?;
            stop_if_idle(&dir)?;
            return start(dir, Some(launcher), port, no_extensions);
        }
        Command::Daemon {
            action:
                Daemon::StartService
                | Daemon::CheckService
                | Daemon::RestartService
                | Daemon::UninstallService,
        } => {
            reject_remote(args.daemon_url.as_deref())?;
            let dir = data_dir(args.data_dir)?;
            let action = match args.command {
                Command::Daemon {
                    action: Daemon::StartService,
                } => "start",
                Command::Daemon {
                    action: Daemon::CheckService,
                } => "check",
                Command::Daemon {
                    action: Daemon::RestartService,
                } => "restart",
                _ => "uninstall",
            };
            return crate::service::control(action, &dir, None);
        }
        _ => {}
    }

    let status = matches!(
        args.command,
        Command::Daemon {
            action: Daemon::Status
        }
    );
    let cfg = crate::config::resolve_config(args.data_dir.as_deref(), args.daemon_url.as_deref())
        .map_err(|err| match err {
        ConfigError::DaemonNotFound { .. } if status => {
            "Daemon is not running (no local endpoint found). Start it with `hi daemon start`."
                .into()
        }
        _ => err.to_string(),
    })?;
    let client = DaemonClient::new(cfg.target, cfg.token);
    let result = match args.command {
        Command::Login { provider, source } => return login(&client, &provider, source),
        Command::Account {
            action: Account::List,
        } => client.login_providers().map(|providers| {
            let mut found = false;
            for source in providers
                .into_iter()
                .filter(|p| p.id == "openai_codex")
                .flat_map(|p| p.sources.into_iter().take(8))
            {
                if source_id(&source.id) {
                    found = true;
                    let status = crate::render::sanitize_single_line(&source.state);
                    println!(
                        "{}\t{}{}",
                        source.id,
                        status,
                        if source.active { " (stock active)" } else { "" }
                    );
                }
            }
            if !found {
                println!("No configured accounts. Run hi login.");
            }
        }),
        Command::Account {
            action: Account::Add { source },
        } => {
            validate_source(&source)?;
            client
                .add_codex_account(&source)
                .map(|_| println!("Added {source}"))
        }
        Command::Account {
            action: Account::Use { source },
        } => {
            validate_source(&source)?;
            client
                .activate_codex_account(&source)
                .map(|_| println!("Stock Codex account: {source}"))
        }
        Command::Daemon {
            action: Daemon::Status,
        } => client.get_environments().map(|_| {
            println!("Running: {}", client.target().display_endpoint());
        }),
        Command::Daemon {
            action:
                Daemon::Start { .. }
                | Daemon::InstallService { .. }
                | Daemon::Stop
                | Daemon::Restart { .. }
                | Daemon::StartService
                | Daemon::CheckService
                | Daemon::RestartService
                | Daemon::UninstallService,
        } => unreachable!(),
    };
    result.map_err(|err| match err {
        ClientError::ConnectionFailed { endpoint, error }
            if status
                && matches!(
                    error.kind(),
                    io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
                ) =>
        {
            format!("Daemon is not running at {endpoint}. Start it with `hi daemon start`.")
        }
        _ => err.to_string(),
    })
}

fn validate_source(source: &str) -> Result<(), String> {
    if source_id(source) {
        Ok(())
    } else {
        Err("Invalid account alias (use lowercase letters, digits, '-' or '_'; start with a letter).".into())
    }
}

fn login(client: &DaemonClient, provider: &str, source: Option<String>) -> Result<(), String> {
    if !matches!(provider, "openai_codex" | "openai-codex") {
        return Err("Only openai_codex supports device login".into());
    }
    let id = generate_request_id();
    if let Some(source) = &source {
        validate_source(source)?;
    }
    let interrupted = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGINT, Arc::clone(&interrupted))
        .map_err(|e| e.to_string())?;
    let mut flow = match client.start_login_for(provider, source.as_deref(), &id) {
        Err(ClientError::Io(_)) if !interrupted.load(Ordering::Relaxed) => {
            client.start_login_for(provider, source.as_deref(), &id)
        }
        result => result,
    }
    .map_err(|_| {
        "Login start could not be confirmed; check hi account list before starting another flow."
            .to_string()
    })?;
    let reference = flow.operation.clone();
    if reference.len() != 43
        || !reference
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        || !source_id(&flow.source)
    {
        return Err("Invalid login operation".into());
    }
    let alias = flow.source.clone();
    let mut deadline = Instant::now() + Duration::from_secs(910);
    let mut shown = false;
    loop {
        if flow.operation != reference || flow.source != alias {
            return Err("Invalid login operation".into());
        }
        match flow.state {
            LoginState::Complete => {
                println!("Signed in to {alias}.");
                return Ok(());
            }
            LoginState::Cancelled => return Err("Login cancelled".into()),
            LoginState::Expired => return Err("Login expired".into()),
            LoginState::Failed => {
                return Err(
                    "Codex login failed. Check device login permissions and account status.".into(),
                )
            }
            _ => {}
        }
        if interrupted.load(Ordering::Relaxed) {
            flow = client
                .cancel_login(&reference)
                .map_err(|_| "Cancellation not confirmed; check hi account list.".to_string())?;
            if matches!(flow.state, LoginState::Starting | LoginState::Pending) {
                return Err("Cancellation not confirmed".into());
            }
            continue;
        }
        if let Some(ms) = flow.expires_in_ms {
            deadline = deadline.min(Instant::now() + Duration::from_millis(ms.min(900_000) + 3000));
        }
        if Instant::now() >= deadline {
            return Err("Login deadline reached; check hi account list".into());
        }
        if !shown {
            if let (Some(url), Some(code)) = (&flow.verification_url, &flow.user_code) {
                if url != "https://auth.openai.com/codex/device"
                    || !(4..=24).contains(&code.len())
                    || !code
                        .bytes()
                        .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'-')
                {
                    return Err("Invalid device verification instructions".into());
                }
                eprintln!("Open {url}\nEnter code: {code}\nApprove only the login you initiated. Ctrl+C cancels.");
                let _ = io::stderr().flush();
                shown = true;
            }
        }
        let next = Instant::now()
            + Duration::from_millis(flow.poll_after_ms.unwrap_or(1000).clamp(500, 5000));
        while Instant::now() < next && !interrupted.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(50));
        }
        if interrupted.load(Ordering::Relaxed) {
            continue;
        }
        flow = client
            .login_status(&reference)
            .map_err(|_| "Login status lost; check hi account list.".to_string())?;
    }
}

pub(crate) fn stop_if_idle(dir: &std::path::Path) -> Result<(), String> {
    let cfg = match crate::config::resolve_config(Some(dir), None) {
        Ok(cfg) => cfg,
        Err(ConfigError::DaemonNotFound { .. }) => return Ok(()),
        Err(err) => return Err(err.to_string()),
    };
    let client = DaemonClient::new(cfg.target, cfg.token);
    match client.shutdown_if_idle() {
        Ok(()) => (),
        Err(ClientError::ConnectionFailed { error, .. }) if matches!(error.kind(), io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound) => return Ok(()),
        Err(ClientError::HttpStatus { status: 409, message }) if message == "daemon_busy" => return Err("Daemon is busy; finish session work and account operations before restarting. Nothing was stopped.".into()),
        Err(ClientError::HttpStatus { status: 404 | 409, .. }) => return Err("This daemon does not support guarded shutdown. Stop it manually once before using the new launcher.".into()),
        Err(err) => return Err(format!("Could not confirm daemon shutdown: {err}")),
    }
    let deadline = Instant::now() + Duration::from_secs(12);
    let lock = dir.join("lock.json");
    loop {
        match client.probe_connection() {
            Err(ClientError::ConnectionFailed { error, .. })
                if matches!(
                    error.kind(),
                    io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
                ) =>
            {
                match std::fs::symlink_metadata(&lock) {
                    Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(()),
                    Err(err) => return Err(format!("Could not check store lock release: {err}")),
                    Ok(_) => (),
                }
            }
            Err(err) => return Err(err.to_string()),
            Ok(()) => (),
        }
        if Instant::now() >= deadline {
            return Err("Daemon shutdown did not finish; not starting another daemon".into());
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn preflight(
    launcher: &std::path::Path,
    dir: &std::path::Path,
    bypass: bool,
) -> Result<(), String> {
    let mut command = std::process::Command::new(launcher);
    command.arg("--check-config").arg("--data-dir").arg(dir);
    if bypass {
        command.arg("--no-extensions");
    }
    let status = command.status().map_err(|err| err.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err("Candidate failed configuration preflight; nothing was stopped".into())
    }
}

fn reject_remote(url: Option<&str>) -> Result<(), String> {
    if url.is_some() || std::env::var_os("H_DAEMON_URL").is_some_and(|url| !url.is_empty()) {
        Err("Local daemon lifecycle commands do not accept --daemon-url or H_DAEMON_URL".into())
    } else {
        Ok(())
    }
}

fn data_dir(cli: Option<PathBuf>) -> Result<PathBuf, String> {
    let home = std::env::var("HOME").ok();
    let env_dir = std::env::var("H_DATA_DIR").ok();
    crate::config::resolve_data_dir(cli.as_deref(), env_dir.as_deref(), home.as_deref())
        .map_err(|e| e.to_string())
}

pub(crate) fn daemon_launcher(
    launcher: Option<PathBuf>,
    preserve_path: bool,
) -> Result<PathBuf, String> {
    let executable = launcher
        .or_else(|| std::env::var_os("H_DAEMON_BIN").map(PathBuf::from))
        .or_else(|| {
            std::env::current_exe()
                .ok()
                .and_then(|p| p.canonicalize().ok())
                .map(|p| p.with_file_name("h-daemon"))
        })
        .ok_or("No daemon launcher; use --launcher /path/to/bin/h-daemon")?;
    // A launchd entry can point through the installation's stable `current`
    // link. Validate its target, but don't pin the entry to that release.
    let resolved = executable.canonicalize().map_err(|_| "No prebuilt daemon launcher. Run a bundled bin/hi, or pass --launcher /path/to/bin/h-daemon for a built checkout.")?;
    use std::os::unix::fs::PermissionsExt;
    if !resolved
        .metadata()
        .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    {
        return Err("Daemon launcher must be an executable file".into());
    }
    if preserve_path {
        std::path::absolute(executable).map_err(|e| e.to_string())
    } else {
        Ok(resolved)
    }
}

fn start(
    dir: PathBuf,
    launcher: Option<PathBuf>,
    port: Option<u16>,
    bypass: bool,
) -> Result<(), String> {
    use std::os::unix::process::CommandExt;
    let mut command = std::process::Command::new(daemon_launcher(launcher, false)?);
    command.arg("--data-dir").arg(dir);
    if let Some(port) = port {
        command.arg("--port").arg(port.to_string());
    }
    if bypass {
        command.arg("--no-extensions");
    }
    Err(format!("Could not start daemon: {}", command.exec()))
}
