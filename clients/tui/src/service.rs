//! Local launchd integration. Never signals a PID read from daemon.json.
use std::path::{Path, PathBuf};
use std::time::Duration;

#[cfg(not(target_os = "macos"))]
pub(crate) fn control(
    _action: &str,
    _dir: &Path,
    _launcher: Option<PathBuf>,
) -> Result<(), String> {
    Err("Per-user service management is available on macOS only".into())
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn control_with_stop(
    _action: &str,
    _dir: &Path,
    _mode: &str,
    _timeout: Duration,
) -> Result<(), String> {
    Err("Per-user service management is available on macOS only".into())
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn is_installed(_dir: &Path) -> bool {
    false
}

#[cfg(target_os = "macos")]
pub(crate) fn is_installed(dir: &Path) -> bool {
    let Some(home) = std::env::var_os("HOME") else {
        return false;
    };
    let Ok(dir) = dir.canonicalize() else {
        return false;
    };
    PathBuf::from(home)
        .join("Library/LaunchAgents")
        .join(format!("{}.plist", label(&dir)))
        .is_file()
}

#[cfg(target_os = "macos")]
fn label(dir: &Path) -> String {
    format!(
        "local.harness.daemon.{}",
        dir.as_os_str()
            .as_encoded_bytes()
            .iter()
            .fold(0xcbf29ce484222325u64, |hash, byte| (hash
                ^ u64::from(*byte))
            .wrapping_mul(0x100000001b3))
    )
}

#[cfg(target_os = "macos")]
pub(crate) fn control(action: &str, dir: &Path, launcher: Option<PathBuf>) -> Result<(), String> {
    control_inner(action, dir, launcher, "drain", Duration::from_secs(300))
}

#[cfg(target_os = "macos")]
pub(crate) fn control_with_stop(
    action: &str,
    dir: &Path,
    mode: &str,
    timeout: Duration,
) -> Result<(), String> {
    control_inner(action, dir, None, mode, timeout)
}

#[cfg(target_os = "macos")]
fn control_inner(
    action: &str,
    dir: &Path,
    launcher: Option<PathBuf>,
    stop_mode: &str,
    stop_timeout: Duration,
) -> Result<(), String> {
    use std::{
        fs,
        io::Write,
        os::unix::fs::{MetadataExt, OpenOptionsExt},
        process::Command,
    };

    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or("HOME is unset")?;
    let launch_agents = home.join("Library/LaunchAgents");
    let dir = dir
        .canonicalize()
        .map_err(|_| "Data directory must exist before installing a service")?;
    let metadata = fs::metadata(&dir).map_err(|e| e.to_string())?;
    let output = Command::new("/usr/bin/id")
        .arg("-u")
        .output()
        .map_err(|e| e.to_string())?;
    let uid = std::str::from_utf8(&output.stdout)
        .ok()
        .and_then(|s| s.trim().parse::<u32>().ok())
        .filter(|uid| *uid != 0)
        .ok_or("Run service management as your desktop user, not root")?;
    if !output.status.success()
        || !metadata.is_dir()
        || metadata.uid() != uid
        || metadata.mode() & 0o077 != 0
    {
        return Err("The daemon data directory must be private and owned by your user".into());
    }
    let label = label(&dir);
    let domain = format!("gui/{uid}");
    let target = format!("{domain}/{label}");
    let plist = launch_agents.join(format!("{label}.plist"));
    let launchctl = |args: &[&std::ffi::OsStr]| {
        Command::new("/bin/launchctl")
            .args(args)
            .status()
            .map_err(|e| e.to_string())
            .and_then(|s| {
                if s.success() {
                    Ok(())
                } else {
                    Err(format!(
                        "launchctl failed ({s}); check your user service and h-daemon.log"
                    ))
                }
            })
    };
    match action {
        "install" => {
            let executable = crate::manage::daemon_launcher(launcher, true)?;
            // Homebrew installations commonly keep the BEAM launcher off launchd's default PATH.
            let path = std::env::var_os("PATH")
                .map(|path| {
                    std::env::split_paths(&path)
                        .filter(|p| p.is_absolute())
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let path = std::env::join_paths(path).map_err(|e| e.to_string())?;
            let path = path.to_str().ok_or("The service PATH must be UTF-8")?;
            let body = plist_text(&label, &executable, &dir, path)?;
            let log = dir.join("h-daemon.log");
            match fs::symlink_metadata(&log) {
                Ok(meta)
                    if meta.is_file()
                        && meta.uid() == uid
                        && meta.mode() & 0o077 == 0
                        && meta.nlink() == 1 => {}
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                    fs::OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .mode(0o600)
                        .open(&log)
                        .map_err(|e| e.to_string())?;
                }
                _ => {
                    return Err(
                        "Service log must be a private regular file owned by your user".into(),
                    )
                }
            }
            fs::create_dir_all(&launch_agents).map_err(|e| e.to_string())?;
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&plist)
                .map_err(|e| format!("Cannot create {}: {e}", plist.display()))?;
            if let Err(error) = file
                .write_all(body.as_bytes())
                .and_then(|_| file.sync_all())
            {
                let _ = fs::remove_file(&plist);
                return Err(error.to_string());
            }
            if let Err(error) =
                launchctl(&["bootstrap".as_ref(), domain.as_ref(), plist.as_os_str()])
            {
                // Keep the file for diagnosis/removal: a failed or interrupted launchctl
                // call does not establish that the job was never registered.
                return Err(format!("{error}; saved {}", plist.display()));
            }
            println!(
                "Installed {label} (per-user LaunchAgent); check hi daemon status for readiness."
            );
            Ok(())
        }
        "check" => {
            if !plist.is_file() {
                return Err("No hi-managed LaunchAgent".into());
            }
            let status = Command::new("/bin/launchctl")
                .arg("print")
                .arg(&target)
                .stdout(std::process::Stdio::null())
                .status()
                .map_err(|err| err.to_string())?;
            if status.success() {
                Ok(())
            } else {
                Err("LaunchAgent is not registered in this login session".into())
            }
        }
        "start" | "restart" => {
            if !plist.is_file() {
                return Err("No hi-managed LaunchAgent; install it first".into());
            }
            // Never send an unconditional kill to a running service.
            if action == "restart" {
                crate::manage::stop_daemon(&dir, stop_mode, stop_timeout)?;
                wait_until_launchd_stopped(&target, Duration::from_secs(60))?;
            }
            launchctl(&["kickstart".as_ref(), target.as_ref()])
        }
        "uninstall" => {
            if !plist.is_file() {
                return Err("No hi-managed LaunchAgent to uninstall".into());
            }
            // Do not unload a service while it still has unfinished work.
            crate::manage::stop_daemon(&dir, stop_mode, stop_timeout)?;
            // Don't remove the installation if we cannot confirm it was unloaded.
            launchctl(&["bootout".as_ref(), target.as_ref()])?;
            fs::remove_file(&plist).map_err(|e| e.to_string())
        }
        _ => unreachable!(),
    }
}

#[cfg(target_os = "macos")]
fn wait_until_launchd_stopped(target: &str, timeout: Duration) -> Result<(), String> {
    use std::process::Command;
    use std::thread;
    use std::time::Instant;

    let deadline = Instant::now() + timeout;
    let mut last = "no launchd status received".to_string();
    while Instant::now() < deadline {
        let output = Command::new("/bin/launchctl")
            .args(["print", target])
            .output()
            .map_err(|e| e.to_string())?;
        if !output.status.success() {
            return Err(format!(
                "Cannot establish LaunchAgent shutdown for {target}: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        let (stopped, summary) = parse_launchd_stopped(&stdout);
        if stopped {
            return Ok(());
        }
        last = summary;
        thread::sleep(Duration::from_millis(200));
    }
    Err(format!(
        "LaunchAgent shutdown did not finish for {target} ({last})"
    ))
}

#[cfg(any(target_os = "macos", test))]
fn parse_launchd_stopped(stdout: &str) -> (bool, String) {
    let mut state: Option<&str> = None;
    let mut active_count: Option<&str> = None;
    let mut pid: Option<&str> = None;
    let mut last_exit: Option<&str> = None;
    for line in stdout.lines() {
        let trimmed = line.trim();
        if let Some((k, v)) = trimmed.split_once('=') {
            let k = k.trim();
            let v = v.trim();
            match k {
                "state" => state = Some(v),
                "active count" => active_count = Some(v),
                "pid" => pid = Some(v),
                "last exit code" => last_exit = Some(v),
                _ => {}
            }
        }
    }
    let stopped = matches!(state, Some("not running" | "exited"))
        && active_count == Some("0")
        && pid.is_none();
    let summary = format!(
        "state={}, active count={}, pid={}, last exit code={}",
        state.unwrap_or("unreported"),
        active_count.unwrap_or("unreported"),
        pid.unwrap_or("unreported"),
        last_exit.unwrap_or("unreported"),
    );
    (stopped, summary)
}

#[cfg(any(target_os = "macos", test))]
fn plist_text(
    label: &str,
    executable: &Path,
    dir: &Path,
    search_path: &str,
) -> Result<String, String> {
    fn xml(s: &str) -> Result<String, String> {
        if s.chars().any(char::is_control) {
            return Err("Service paths and labels must not contain control characters".into());
        }
        Ok(s.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;")
            .replace('\'', "&apos;"))
    }
    let path = |value: &Path| xml(value.to_str().ok_or("Service paths must be UTF-8")?);
    let label = xml(label)?;
    let executable = path(executable)?;
    let log = path(&dir.join("h-daemon.log"))?;
    let search_path = xml(search_path)?;
    let dir = path(dir)?;
    Ok(format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{label}</string>
<key>ProgramArguments</key><array><string>{executable}</string><string>--data-dir</string><string>{dir}</string></array>
<key>WorkingDirectory</key><string>{dir}</string>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>{search_path}</string></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>10</integer>
<key>ExitTimeOut</key><integer>300</integer>
<key>StandardOutPath</key><string>{log}</string>
<key>StandardErrorPath</key><string>{log}</string>
</dict></plist>
"#
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn service_file_escapes_paths_and_does_not_shell_expand() {
        let body = plist_text(
            "test",
            Path::new("/a & b/hi"),
            Path::new("/data dir/<x>"),
            "/usr/bin",
        )
        .unwrap();
        assert!(body.contains("<string>/a &amp; b/hi</string>"));
        assert!(body.contains("<string>/data dir/&lt;x&gt;</string>"));
        assert!(!body.contains("/bin/sh"));
        assert!(body.contains("<key>SuccessfulExit</key><false/>"));
        assert!(body.contains("<key>ExitTimeOut</key><integer>300</integer>"));
        assert!(plist_text(
            "test",
            Path::new("/opt/h/current/bin/h-daemon"),
            Path::new("/data"),
            "/usr/bin"
        )
        .unwrap()
        .contains("/opt/h/current/bin/h-daemon"));
        assert!(plist_text("test", Path::new("/a\nb"), Path::new("/data"), "/usr/bin").is_err());
    }

    #[test]
    fn parse_launchd_stopped_checks_state_active_count_and_pid() {
        let running =
            "job = {\n\tactive count = 1\n\tstate = running\n\tpid = 321\n\tlast exit code = 0\n}\n";
        assert!(!parse_launchd_stopped(running).0);

        let stale_pid =
            "job = {\n\tactive count = 0\n\tstate = not running\n\tpid = 321\n\tlast exit code = 0\n}\n";
        assert!(!parse_launchd_stopped(stale_pid).0);

        let stopped =
            "job = {\n\tactive count = 0\n\tstate = not running\n\tlast exit code = 0\n}\n";
        assert!(parse_launchd_stopped(stopped).0);

        let exited = "job = {\n\tactive count = 0\n\tstate = exited\n\tlast exit code = 0\n}\n";
        assert!(parse_launchd_stopped(exited).0);
    }
}
