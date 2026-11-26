use std::fs;
use std::io::BufRead;
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

static NEXT: AtomicU64 = AtomicU64::new(0);

struct Workspace(std::path::PathBuf);
impl Workspace {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "hi-exec-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn fs_call(op: &str, path: &std::path::Path) -> serde_json::Value {
    let output = Command::new(env!("CARGO_BIN_EXE_hi-exec"))
        .args(["fs", op])
        .arg(path)
        .output()
        .unwrap();
    assert!(output.status.success(), "{:?}", output);
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn directory_listing_and_errors_use_the_native_helper() {
    let workspace = Workspace::new();
    fs::write(workspace.0.join("hello"), b"hello").unwrap();
    fs::create_dir(workspace.0.join("project")).unwrap();
    std::os::unix::fs::symlink("project", workspace.0.join("link")).unwrap();

    let mut names = fs_call("ls", &workspace.0)["ok"]
        .as_array()
        .unwrap()
        .clone();
    names.sort_by_key(|v| v.as_str().unwrap().to_owned());
    assert_eq!(
        serde_json::Value::Array(names),
        serde_json::json!(["hello", "link", "project"])
    );
    assert_eq!(
        fs_call("ls", &workspace.0.join("missing"))["error"],
        "enoent"
    );
    assert_eq!(
        fs_call("ls", &workspace.0.join("hello"))["error"],
        "enotdir"
    );
}

#[test]
fn daemon_forwards_termination_and_preserves_the_child_exit_code() {
    let workspace = Workspace::new();
    let launcher = workspace.0.join("launcher");
    // Disposable child with a bounded lifetime; no live daemon or account store.
    fs::write(&launcher, "#!/bin/sh\ntrap 'exit 23' TERM\necho ready\ni=0\nwhile [ $i -lt 100 ]; do /bin/sleep 0.02; i=$((i+1)); done\n").unwrap();
    fs::set_permissions(&launcher, fs::Permissions::from_mode(0o700)).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_hi-exec"))
        .args(["daemon", "--launcher"])
        .arg(launcher)
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut line = String::new();
    std::io::BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut line)
        .unwrap();
    assert_eq!(line.trim(), "ready");
    unsafe extern "C" {
        fn kill(pid: i32, signal: i32) -> i32;
    }
    assert_eq!(
        unsafe { kill(child.id() as i32, signal_hook::consts::SIGTERM) },
        0
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("hi-exec did not forward termination");
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(status.code(), Some(23));
}

#[test]
fn rejects_unknown_operations_and_reports_launch_failure() {
    let workspace = Workspace::new();
    assert_eq!(fs_call("unknown", &workspace.0)["error"], "einval");
    let output = Command::new(env!("CARGO_BIN_EXE_hi-exec"))
        .args(["daemon", "--launcher"])
        .arg(workspace.0.join("missing"))
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("hi-exec:"));
}
