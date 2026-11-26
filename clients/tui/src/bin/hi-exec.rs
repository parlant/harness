//! Native macOS permission identity and bounded host filesystem worker.
//! Keep this executable inside H.app; do not replace OTP's erlexec.
use serde_json::{json, Value};
use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
use std::fs;
use std::io::{self, Read};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const FS_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_OUTPUT: u64 = 8 * 1024 * 1024;

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            eprintln!("hi-exec: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> io::Result<u8> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    match args.first().and_then(|s| s.to_str()) {
        Some("daemon") => {
            let executable = std::env::current_exe()?;
            let parent = executable.parent().unwrap();
            let launcher = if args.get(1).is_some_and(|s| s == "--launcher") {
                PathBuf::from(
                    args.get(2)
                        .ok_or_else(|| io::Error::other("missing launcher"))?,
                )
            } else if parent.file_name().is_some_and(|s| s == "MacOS") {
                parent.join("../Resources/harness/bin/h-daemon")
            } else {
                parent.join("h-daemon")
            };
            let skip = if args.get(1).is_some_and(|s| s == "--launcher") {
                3
            } else {
                1
            };
            let mut command = Command::new(launcher);
            command
                .args(&args[skip..])
                .env("H_FS_EXECUTABLE", executable);
            supervise(&mut command, None)
        }
        Some("fs") if args.len() == 3 => {
            let mut command = Command::new(std::env::current_exe()?);
            command
                .arg("fs-worker")
                .args(&args[1..])
                .stdout(Stdio::piped());
            supervise(&mut command, Some(FS_TIMEOUT))
        }
        Some("fs-worker") if args.len() == 3 => {
            let result = fs_operation(args[1].to_str().unwrap_or(""), Path::new(&args[2]));
            println!("{}", result.unwrap_or_else(|e| json!({"error": errno(&e)})));
            Ok(0)
        }
        _ => Err(io::Error::other(
            "usage: hi-exec daemon [--launcher PATH] [ARGS...] | fs OP PATH",
        )),
    }
}

fn supervise(command: &mut Command, timeout: Option<Duration>) -> io::Result<u8> {
    let mut signals = Vec::new();
    for number in [SIGTERM, SIGINT, SIGHUP] {
        let flag = Arc::new(AtomicBool::new(false));
        let id = signal_hook::flag::register(number, Arc::clone(&flag))?;
        signals.push((number, flag, id));
    }
    command.stdin(Stdio::null());
    let mut child = command.spawn()?;
    let reader = child.stdout.take().map(|stdout| {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            stdout
                .take(MAX_OUTPUT + 1)
                .read_to_end(&mut bytes)
                .map(|_| bytes)
        })
    });
    let start = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break Some(status);
        }
        if timeout.is_some_and(|limit| start.elapsed() >= limit) {
            child.kill()?;
            child.wait()?;
            break None;
        }
        for (number, flag, _) in &signals {
            if flag.swap(false, Ordering::Relaxed) {
                signal_child(&child, *number);
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    for (_, _, id) in signals {
        signal_hook::low_level::unregister(id);
    }
    if let Some(reader) = reader {
        let bytes = reader
            .join()
            .map_err(|_| io::Error::other("filesystem reader failed"))??;
        if status.is_none() {
            println!("{}", json!({"error": "timeout"}));
        } else if bytes.len() as u64 > MAX_OUTPUT {
            println!("{}", json!({"error": "file_too_large"}));
        } else if status.is_some_and(|s| s.success()) {
            use std::io::Write;
            io::stdout().write_all(&bytes)?;
        } else {
            println!("{}", json!({"error": "eio"}));
        }
        return Ok(0);
    }
    Ok(status.map_or(1, |s| {
        s.code().unwrap_or(128 + s.signal().unwrap_or(1)) as u8
    }))
}

fn signal_child(child: &Child, signal: i32) {
    // The child has not been reaped, so its PID cannot have been reused.
    unsafe extern "C" {
        fn kill(pid: i32, signal: i32) -> i32;
    }
    unsafe {
        kill(child.id() as i32, signal);
    }
}

fn fs_operation(op: &str, path: &Path) -> io::Result<Value> {
    let value = match op {
        "ls" => {
            let mut names = Vec::new();
            let mut bytes = 2;
            for entry in fs::read_dir(path)? {
                let name = entry?.file_name().into_string().map_err(|_| {
                    io::Error::new(io::ErrorKind::InvalidData, "non-UTF-8 filename")
                })?;
                bytes += serde_json::to_string(&name)?.len() as u64 + 1;
                if bytes > MAX_OUTPUT - 16 {
                    return Ok(json!({"error": "file_too_large"}));
                }
                names.push(name);
            }
            json!(names)
        }
        _ => return Ok(json!({"error": "einval"})),
    };
    Ok(json!({"ok": value}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filesystem_deadline_kills_and_reaps_its_worker() {
        let start = Instant::now();
        let mut command = Command::new("/bin/sleep");
        command.arg("30").stdout(Stdio::piped());
        assert_eq!(
            supervise(&mut command, Some(Duration::from_millis(50))).unwrap(),
            0
        );
        assert!(start.elapsed() < Duration::from_secs(2));
    }
}

fn errno(error: &io::Error) -> &'static str {
    match error.kind() {
        io::ErrorKind::NotFound => "enoent",
        io::ErrorKind::PermissionDenied => "eacces",
        io::ErrorKind::NotADirectory => "enotdir",
        io::ErrorKind::InvalidInput => "einval",
        io::ErrorKind::InvalidData => "einval",
        _ if error.raw_os_error() == Some(1) => "eperm",
        _ if error.raw_os_error() == Some(if cfg!(target_os = "macos") { 62 } else { 40 }) => {
            "eloop"
        }
        _ => "eio",
    }
}
