use std::borrow::Cow;
use std::env;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_DRAFT_BYTES: usize = 1024 * 1024;
const DEFAULT_EDITOR: &str = "nano";
const TEMP_FILE_NAME: &str = "prompt.md";

static TEMP_DIR_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Launches `$VISUAL` or `$EDITOR` (defaulting to `nano`) against a private
/// temporary file containing `draft`, returning the edited UTF-8 text.
///
/// The caller must drop any terminal `Screen` guard before calling this
/// function, handle status display, and re-open the screen afterwards.
pub fn edit(draft: &str) -> io::Result<String> {
    let visual = read_env_utf8("VISUAL")?;
    let editor = read_env_utf8("EDITOR")?;
    edit_with(
        draft,
        visual.as_deref(),
        editor.as_deref(),
        &env::temp_dir(),
        MAX_DRAFT_BYTES,
    )
}

fn read_env_utf8(name: &str) -> io::Result<Option<String>> {
    match env::var_os(name) {
        None => Ok(None),
        Some(value) => value.into_string().map(Some).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{name} environment variable is not valid UTF-8"),
            )
        }),
    }
}

fn edit_with(
    draft: &str,
    visual: Option<&str>,
    editor: Option<&str>,
    base_temp_dir: &Path,
    max_bytes: usize,
) -> io::Result<String> {
    if draft.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("draft exceeds {max_bytes} byte limit"),
        ));
    }

    let mut argv = resolve_editor_command(visual, editor)?;
    let program = argv.remove(0);

    let temp_dir = create_private_temp_dir(base_temp_dir)?;
    let file_path = temp_dir.path().join(TEMP_FILE_NAME);

    {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&file_path)?;
        file.write_all(draft.as_bytes())?;
        file.flush()?;
    }

    let status = Command::new(&program)
        .args(&argv)
        .arg(&file_path)
        .status()?;
    if !status.success() {
        let detail = match status.code() {
            Some(code) => format!("external editor exited with status {code}"),
            None => "external editor terminated by signal".to_string(),
        };
        return Err(io::Error::other(detail));
    }

    let meta = fs::symlink_metadata(&file_path)?;
    if meta.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "refusing to read symlinked external editor file",
        ));
    }
    if !meta.file_type().is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "external editor path is not a regular file",
        ));
    }

    let file = File::open(&file_path)?;
    let mut bytes = Vec::new();
    file.take((max_bytes as u64).saturating_add(1))
        .read_to_end(&mut bytes)?;
    if bytes.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("external editor output exceeds {max_bytes} byte limit"),
        ));
    }

    normalize_edited_bytes(bytes)
}

fn resolve_editor_command(visual: Option<&str>, editor: Option<&str>) -> io::Result<Vec<String>> {
    let raw = [visual, editor]
        .into_iter()
        .flatten()
        .find(|candidate| !candidate.trim().is_empty())
        .unwrap_or(DEFAULT_EDITOR);

    split_command_args(raw)
}

fn split_command_args(cmd: &str) -> io::Result<Vec<String>> {
    if cmd.contains('\0') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "editor command contains NUL byte",
        ));
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Quote {
        None,
        Single,
        Double,
    }

    let mut args = Vec::new();
    let mut current = String::new();
    let mut in_token = false;
    let mut quote = Quote::None;
    let mut chars = cmd.chars().peekable();

    while let Some(ch) = chars.next() {
        match quote {
            Quote::None => match ch {
                c if c.is_ascii_whitespace() => {
                    if in_token {
                        args.push(std::mem::take(&mut current));
                        in_token = false;
                    }
                }
                '\'' => {
                    quote = Quote::Single;
                    in_token = true;
                }
                '"' => {
                    quote = Quote::Double;
                    in_token = true;
                }
                '\\' => {
                    let next = chars.next().ok_or_else(|| {
                        io::Error::new(
                            io::ErrorKind::InvalidInput,
                            "trailing backslash in editor command",
                        )
                    })?;
                    current.push(next);
                    in_token = true;
                }
                other => {
                    current.push(other);
                    in_token = true;
                }
            },
            Quote::Single => {
                if ch == '\'' {
                    quote = Quote::None;
                } else {
                    current.push(ch);
                }
            }
            Quote::Double => match ch {
                '"' => {
                    quote = Quote::None;
                }
                '\\' => {
                    let Some(&next) = chars.peek() else {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidInput,
                            "unclosed double quote in editor command",
                        ));
                    };
                    if matches!(next, '"' | '\\') {
                        chars.next();
                        current.push(next);
                    } else {
                        current.push('\\');
                    }
                }
                other => current.push(other),
            },
        }
    }

    match quote {
        Quote::Single => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "unclosed single quote in editor command",
            ));
        }
        Quote::Double => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "unclosed double quote in editor command",
            ));
        }
        Quote::None => {}
    }

    if in_token {
        args.push(current);
    }

    if args.is_empty() || args[0].is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "editor command is empty",
        ));
    }

    Ok(args)
}

fn normalize_edited_bytes(bytes: Vec<u8>) -> io::Result<String> {
    let text = String::from_utf8(bytes).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "external editor output is not valid UTF-8",
        )
    })?;
    let without_bom = text.strip_prefix('\u{FEFF}').unwrap_or(&text);
    let normalized = if without_bom.contains("\r\n") {
        Cow::Owned(without_bom.replace("\r\n", "\n"))
    } else {
        Cow::Borrowed(without_bom)
    };
    let trimmed = normalized.strip_suffix('\n').unwrap_or(&normalized);
    Ok(trimmed.to_string())
}

struct TempDirGuard(Option<PathBuf>);

impl TempDirGuard {
    fn path(&self) -> &Path {
        self.0
            .as_deref()
            .expect("TempDirGuard path accessed before drop")
    }
}

impl Drop for TempDirGuard {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = fs::remove_dir_all(path);
        }
    }
}

fn resolve_base_dir(base_dir: &Path) -> io::Result<PathBuf> {
    if base_dir.is_absolute() {
        Ok(base_dir.to_path_buf())
    } else {
        Ok(env::current_dir()?.join(base_dir))
    }
}

fn create_private_temp_dir(base_dir: &Path) -> io::Result<TempDirGuard> {
    let base = resolve_base_dir(base_dir)?;

    for attempt in 0..64u64 {
        let suffix = random_suffix(attempt);
        let candidate = base.join(format!("hi-editor-{suffix:016x}"));
        let mut builder = DirBuilder::new();
        builder.mode(0o700);
        match builder.create(&candidate) {
            Ok(()) => return Ok(TempDirGuard(Some(candidate))),
            Err(err) if err.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(err),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "failed to allocate unique temporary directory for external editor",
    ))
}

fn random_suffix(attempt: u64) -> u64 {
    if let Ok(mut file) = File::open("/dev/urandom") {
        let mut buf = [0u8; 8];
        if file.read_exact(&mut buf).is_ok() {
            return u64::from_le_bytes(buf);
        }
    }

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos() as u64);
    let seq = TEMP_DIR_COUNTER.fetch_add(1, Ordering::Relaxed);
    let pid = u64::from(std::process::id());
    let mut x = nanos
        ^ seq.wrapping_mul(0x9E37_79B9_7F4A_7C15)
        ^ pid.rotate_left(17)
        ^ attempt.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    x = (x ^ (x >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    x = (x ^ (x >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    x ^ (x >> 31)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestSandbox(PathBuf);

    impl TestSandbox {
        fn new(label: &str) -> Self {
            let suffix = random_suffix(0);
            let dir = env::temp_dir().join(format!("hi-external-test-{label}-{suffix:016x}"));
            DirBuilder::new()
                .mode(0o700)
                .create(&dir)
                .expect("create test sandbox");
            Self(dir)
        }

        fn path(&self) -> &Path {
            &self.0
        }

        fn write_script(&self, rel: &str, body: &str) -> PathBuf {
            let path = self.0.join(rel);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).expect("create script parent dir");
            }
            {
                let mut file = OpenOptions::new()
                    .write(true)
                    .create(true)
                    .truncate(true)
                    .mode(0o700)
                    .open(&path)
                    .expect("create test script");
                file.write_all(body.as_bytes())
                    .expect("write test script body");
                file.flush().expect("flush test script");
            }
            path
        }

        fn has_editor_temp_dirs(&self) -> bool {
            fs::read_dir(&self.0)
                .expect("read sandbox dir")
                .filter_map(Result::ok)
                .any(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .starts_with("hi-editor-")
                })
        }
    }

    impl Drop for TestSandbox {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn resolve_editor_precedence_and_fallback() {
        assert_eq!(
            resolve_editor_command(Some("nvim -u NONE"), Some("vim")).unwrap(),
            vec!["nvim", "-u", "NONE"]
        );
        assert_eq!(
            resolve_editor_command(Some("   "), Some("vim")).unwrap(),
            vec!["vim"]
        );
        assert_eq!(
            resolve_editor_command(None, Some("emacs -nw")).unwrap(),
            vec!["emacs", "-nw"]
        );
        assert_eq!(
            resolve_editor_command(None, Some("")).unwrap(),
            vec![DEFAULT_EDITOR]
        );
        assert_eq!(
            resolve_editor_command(None, None).unwrap(),
            vec![DEFAULT_EDITOR]
        );
    }

    #[test]
    fn split_command_args_quotes_escapes_and_rejects_malformed() {
        assert_eq!(
            split_command_args(r#"'/path/with spaces/ed' --flag "two words" a\ b"#).unwrap(),
            vec!["/path/with spaces/ed", "--flag", "two words", "a b"]
        );
        assert_eq!(
            split_command_args(r#""quoted \"inner\" \\" '$NOT_EXPANDED'"#).unwrap(),
            vec![r#"quoted "inner" \"#, "$NOT_EXPANDED"]
        );
        assert_eq!(
            split_command_args("echo $(id); rm -rf /").unwrap(),
            vec!["echo", "$(id);", "rm", "-rf", "/"]
        );

        assert_eq!(
            split_command_args("'unclosed").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
        assert_eq!(
            split_command_args("\"unclosed").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
        assert_eq!(
            split_command_args("trailing\\").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
        assert_eq!(
            split_command_args("bad\0cmd").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
        assert_eq!(
            split_command_args("   ").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
    }

    #[test]
    fn edit_with_uses_private_dir_and_file_normalizes_and_cleans_up() {
        let sandbox = TestSandbox::new("basic");
        let capture_path = sandbox.path().join("capture.txt");
        let meta_path = sandbox.path().join("meta.txt");
        let script = sandbox.write_script(
            "editor.sh",
            &format!(
                "#!/bin/sh\nset -eu\nfile=\"$2\"\ndir=$(dirname \"$file\")\nls -A \"$dir\" > \"{}\"\ncp \"$file\" \"{}\"\nprintf '  edited line 1  \\r\\nedited line 2\\n' > \"$file\"\n",
                meta_path.display(),
                capture_path.display(),
            ),
        );

        let cmd = format!("'{}' --wait", script.display());
        let out = edit_with(
            "  original draft  \nline2",
            Some(&cmd),
            Some("/usr/bin/false"),
            sandbox.path(),
            MAX_DRAFT_BYTES,
        )
        .expect("edit should succeed");

        assert_eq!(out, "  edited line 1  \nedited line 2");
        assert_eq!(
            fs::read_to_string(&capture_path).unwrap(),
            "  original draft  \nline2"
        );
        assert_eq!(fs::read_to_string(&meta_path).unwrap(), "prompt.md\n");
        assert!(!sandbox.has_editor_temp_dirs());
    }

    #[test]
    fn edit_with_enforces_private_permissions() {
        let sandbox = TestSandbox::new("perms");
        let dir_mode_path = sandbox.path().join("dir_mode.txt");
        let file_mode_path = sandbox.path().join("file_mode.txt");
        let script = sandbox.write_script(
            "perms.sh",
            &format!(
                "#!/bin/sh\nset -eu\nfile=\"$1\"\ndir=$(dirname \"$file\")\nif stat -f '%Lp' \"$dir\" >/dev/null 2>&1; then\n  stat -f '%Lp' \"$dir\" > \"{}\"\n  stat -f '%Lp' \"$file\" > \"{}\"\nelse\n  stat -c '%a' \"$dir\" > \"{}\"\n  stat -c '%a' \"$file\" > \"{}\"\nfi\n",
                dir_mode_path.display(),
                file_mode_path.display(),
                dir_mode_path.display(),
                file_mode_path.display(),
            ),
        );

        let cmd = format!("'{}'", script.display());
        let out = edit_with("secret", None, Some(&cmd), sandbox.path(), MAX_DRAFT_BYTES)
            .expect("edit should succeed");
        assert_eq!(out, "secret");

        let dir_mode = u32::from_str_radix(fs::read_to_string(&dir_mode_path).unwrap().trim(), 8)
            .expect("parse dir mode");
        let file_mode = u32::from_str_radix(fs::read_to_string(&file_mode_path).unwrap().trim(), 8)
            .expect("parse file mode");
        assert_eq!(
            dir_mode & 0o077,
            0,
            "dir mode {dir_mode:o} exposes group/other"
        );
        assert_eq!(
            file_mode & 0o077,
            0,
            "file mode {file_mode:o} exposes group/other"
        );
        assert!(!sandbox.has_editor_temp_dirs());
    }

    #[test]
    fn edit_with_strips_bom_and_handles_empty_or_double_newline() {
        let sandbox = TestSandbox::new("normalize");
        let script =
            sandbox.write_script("write.sh", "#!/bin/sh\nset -eu\nprintf \"$1\" > \"$2\"\n");

        let bom_cmd = format!("'{}' '\\357\\273\\277hello\\n'", script.display());
        assert_eq!(
            edit_with("", Some(&bom_cmd), None, sandbox.path(), MAX_DRAFT_BYTES).unwrap(),
            "hello"
        );

        let empty_cmd = format!("'{}' ''", script.display());
        assert_eq!(
            edit_with(
                "before",
                Some(&empty_cmd),
                None,
                sandbox.path(),
                MAX_DRAFT_BYTES
            )
            .unwrap(),
            ""
        );

        let double_nl_cmd = format!("'{}' 'a\\n\\n'", script.display());
        assert_eq!(
            edit_with(
                "",
                Some(&double_nl_cmd),
                None,
                sandbox.path(),
                MAX_DRAFT_BYTES
            )
            .unwrap(),
            "a\n"
        );
        assert!(!sandbox.has_editor_temp_dirs());
    }

    #[test]
    fn edit_with_supports_quoted_editor_with_spaces_and_visual_priority() {
        let sandbox = TestSandbox::new("spaces");
        let script = sandbox.write_script(
            "dir with spaces/my editor.sh",
            "#!/bin/sh\nset -eu\n[ \"$1\" = \"--wait\" ]\nprintf 'ok\\n' > \"$2\"\n",
        );
        let cmd = format!("\"{}\" --wait", script.display());
        let out = edit_with(
            "hi",
            Some(&cmd),
            Some("/nonexistent/editor"),
            sandbox.path(),
            MAX_DRAFT_BYTES,
        )
        .unwrap();
        assert_eq!(out, "ok");
        assert!(!sandbox.has_editor_temp_dirs());
    }

    #[test]
    fn edit_with_deletes_temp_dir_on_editor_failure_or_missing_binary() {
        let sandbox = TestSandbox::new("fail");
        let fail_script = sandbox.write_script("fail.sh", "#!/bin/sh\nexit 7\n");
        let fail_cmd = format!("'{}'", fail_script.display());

        let err = edit_with(
            "keep me",
            Some(&fail_cmd),
            None,
            sandbox.path(),
            MAX_DRAFT_BYTES,
        )
        .unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::Other);
        assert!(!sandbox.has_editor_temp_dirs());

        let missing = sandbox.path().join("does-not-exist");
        let missing_cmd = format!("'{}'", missing.display());
        let err = edit_with(
            "keep me",
            None,
            Some(&missing_cmd),
            sandbox.path(),
            MAX_DRAFT_BYTES,
        )
        .unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::NotFound);
        assert!(!sandbox.has_editor_temp_dirs());
    }

    #[test]
    fn edit_with_enforces_size_cap_on_input_and_output_and_cleans_up() {
        let sandbox = TestSandbox::new("cap");
        let marker = sandbox.path().join("ran");
        let script = sandbox.write_script(
            "grow.sh",
            &format!(
                "#!/bin/sh\nset -eu\ntouch \"{}\"\nprintf '123456789' > \"$1\"\n",
                marker.display()
            ),
        );
        let cmd = format!("'{}'", script.display());

        // Oversized input is rejected before spawning editor.
        let err = edit_with("123456789", Some(&cmd), None, sandbox.path(), 8).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert!(!marker.exists());
        assert!(!sandbox.has_editor_temp_dirs());

        // Oversized edited output is rejected and temp dir is deleted.
        let err = edit_with("ok", Some(&cmd), None, sandbox.path(), 8).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(marker.exists());
        assert!(!sandbox.has_editor_temp_dirs());
    }

    #[test]
    fn edit_with_rejects_invalid_utf8_and_symlinks_with_cleanup() {
        let sandbox = TestSandbox::new("invalid");
        let bad_utf8 = sandbox.write_script(
            "bad_utf8.sh",
            "#!/bin/sh\nset -eu\nprintf '\\377\\376' > \"$1\"\n",
        );
        let err = edit_with(
            "ok",
            Some(&format!("'{}'", bad_utf8.display())),
            None,
            sandbox.path(),
            MAX_DRAFT_BYTES,
        )
        .unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(!sandbox.has_editor_temp_dirs());

        let target = sandbox.path().join("outside.txt");
        fs::write(&target, "secret").unwrap();
        let symlink_script = sandbox.write_script(
            "symlink.sh",
            &format!(
                "#!/bin/sh\nset -eu\nrm -f \"$1\"\nln -s \"{}\" \"$1\"\n",
                target.display()
            ),
        );
        let err = edit_with(
            "ok",
            Some(&format!("'{}'", symlink_script.display())),
            None,
            sandbox.path(),
            MAX_DRAFT_BYTES,
        )
        .unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(!sandbox.has_editor_temp_dirs());
    }

    #[test]
    fn edit_with_prevents_prompt_interpolation_and_shell_injection() {
        let sandbox = TestSandbox::new("injection");
        let pwned = sandbox.path().join("pwned");
        let noop = sandbox.write_script("noop.sh", "#!/bin/sh\nexit 0\n");
        let noop_cmd = format!("'{}'", noop.display());

        let hostile_draft = format!(
            "$(touch {}) `touch {}` ; touch {} $HOME %s {{draft}}",
            pwned.display(),
            pwned.display(),
            pwned.display()
        );
        let out = edit_with(
            &hostile_draft,
            Some(&noop_cmd),
            None,
            sandbox.path(),
            MAX_DRAFT_BYTES,
        )
        .unwrap();
        assert_eq!(out, hostile_draft);
        assert!(!pwned.exists());
        assert!(!sandbox.has_editor_temp_dirs());

        let hostile_cmd = format!("true; touch {}", pwned.display());
        let err = edit_with(
            "ok",
            Some(&hostile_cmd),
            None,
            sandbox.path(),
            MAX_DRAFT_BYTES,
        )
        .unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::NotFound);
        assert!(!pwned.exists());
        assert!(!sandbox.has_editor_temp_dirs());
    }

    #[test]
    fn resolve_base_dir_makes_relative_paths_absolute() {
        let cwd = env::current_dir().unwrap();
        let resolved = resolve_base_dir(Path::new("rel-tmp")).unwrap();
        assert!(resolved.is_absolute());
        assert_eq!(resolved, cwd.join("rel-tmp"));

        let abs = resolve_base_dir(Path::new("/tmp/hi-abs")).unwrap();
        assert_eq!(abs, Path::new("/tmp/hi-abs"));
    }
}
