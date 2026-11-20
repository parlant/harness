//! Read-only footer fields and compiled, one-row templates. No daemon calls on redraw.
use super::actions::Target;
use crate::{client::DaemonClient, render::sanitize_single_line, transcript::TranscriptState};
use minijinja::{escape_formatter, Environment, UndefinedBehavior, Value};
use serde::Serialize;
use std::{
    collections::HashMap,
    env, fs,
    io::{self, Read},
    path::Path,
    sync::mpsc::{self, Receiver, TryRecvError},
    thread,
    time::{Duration, Instant},
};
use unicode_width::UnicodeWidthStr;

const WORKSPACE_LINE: &str = concat!(
    "{{ align(cwd_short ~ (' (' ~ git_branch ~ ')' if git_branch else ''), ",
    "activity ~ (' (' ~ connection ~ ')' if not online and connection else '')) }}",
);

const DETAILS_LINE: &str = concat!(
    "{{ note }}{% if shell_active %} · shell {{ shell_prefix }}{{ shell_preview }} ({{ shell_status }}){% endif %}",
    " · [seq {{ seq if seq is not none else '-' }} · {{ model }} ({{ thinking }})",
    "{% if queued %} · queued {{ queued }}{% endif %}",
    "{% if has_usage %} · tokens {{ input_tokens }}/{{ output_tokens }}{% if cost > 0 %} (${{ '%.4f'|format(cost) }}){% endif %}{% endif %}]",
    "{% if pending %} · pending{% endif %}{% if attachments %} · attachment{% endif %}",
    "{% if fork_entry_id %} · fork-edit #{{ fork_entry_id }}@{{ fork_predecessor_id }}{% endif %}",
    " · {{ session_id }}:{{ conversation_id }}",
);

#[derive(Default, Serialize)]
pub(super) struct StatusFields<'a> {
    pub note: &'a str,
    pub connection: &'static str,
    pub online: bool,
    pub pending: bool,
    pub attachments: usize,
    pub fork_entry_id: Option<&'a str>,
    pub fork_predecessor_id: Option<u64>,
    pub retry_pending: bool,
    pub historical: bool,
    pub show_tools: bool,
    pub show_thinking: bool,
    session_id: &'a str,
    conversation_id: &'a str,
    cwd: &'a str,
    cwd_short: &'a str,
    git_branch: Option<&'a str>,
    env_id: &'a str,
    session_title: Option<&'a str>,
    session_status: Option<&'a str>,
    harness_id: Option<&'a str>,
    seq: Option<u64>,
    activity: &'static str,
    failure_reason: Option<String>,
    failure_code: Option<String>,
    failure_message: Option<String>,
    compaction_failed: bool,
    compaction_status: Option<&'a str>,
    run_turns: Option<u64>,
    model: &'a str,
    pub width: u16,
    model_name: &'a str,
    provider: Option<&'a str>,
    thinking: &'a str,
    context_window: Option<u64>,
    context_percent: Option<f64>,
    queued: usize,
    has_usage: bool,
    input_tokens: u64,
    output_tokens: u64,
    total_tokens: u64,
    cost: f64,
    shell_active: bool,
    shell_command: Option<&'a str>,
    shell_preview: String,
    shell_status: Option<&'a str>,
    shell_prefix: Option<&'static str>,
}

impl<'a> StatusFields<'a> {
    pub(super) fn from_session(target: &'a Target, state: &'a TranscriptState) -> Self {
        let model = state.agent_model().unwrap_or("default");
        // ReqLLM uses provider:model (the model may itself contain slashes).
        // Fake/legacy catalogs can use provider/model instead.
        let (provider, model_name) = model
            .split_once([':', '/'])
            .filter(|(p, m)| !p.is_empty() && !m.is_empty())
            .map_or((None, model), |(p, m)| (Some(p), m));
        let usage = state.usage_summary();
        let (input_tokens, output_tokens, cost) = usage.unwrap_or_default();
        let total_tokens = state
            .docs
            .get("usage")
            .and_then(|v| v.get("total_tokens"))
            .and_then(serde_json::Value::as_u64)
            .unwrap_or_else(|| input_tokens.saturating_add(output_tokens));
        let shell = state.active_user_shell();
        let failure = state.run_failure();
        let live = state.live_doc();
        Self {
            session_id: &target.sid,
            conversation_id: &target.cid,
            cwd: &target.cwd,
            cwd_short: &target.cwd,
            env_id: &target.env_id,
            session_title: target.labels.title.as_deref(),
            session_status: target.labels.status.as_deref(),
            harness_id: target.labels.harness_id.as_deref(),
            seq: state.seq,
            activity: if target.labels.status.as_deref() == Some("archived") {
                "archived"
            } else if state.is_run_active() {
                "busy"
            } else if failure.is_some() {
                "paused"
            } else {
                "idle"
            },
            compaction_failed: failure.as_ref().is_some_and(|f| f.is_compaction),
            failure_reason: failure.as_ref().map(|f| f.reason.clone()),
            failure_code: failure.as_ref().and_then(|f| f.code.clone()),
            failure_message: failure.and_then(|f| f.message),
            compaction_status: live
                .and_then(|l| l.get("compaction"))
                .and_then(|v| v.get("status"))
                .and_then(serde_json::Value::as_str),
            run_turns: live
                .and_then(|l| l.get("run"))
                .and_then(|v| v.get("turns"))
                .and_then(serde_json::Value::as_u64),
            model,
            model_name,
            provider,
            thinking: state.agent_thinking().unwrap_or("medium"),
            queued: state.inbox_len(),
            has_usage: usage.is_some(),
            input_tokens,
            output_tokens,
            total_tokens,
            cost,
            shell_active: shell.is_some(),
            shell_command: shell.map(|(cmd, _, _)| cmd),
            shell_preview: shell.map_or_else(String::new, |(cmd, _, _)| {
                sanitize_single_line(cmd).chars().take(24).collect()
            }),
            shell_status: shell.map(|(_, status, _)| status),
            shell_prefix: shell.map(|(_, _, include)| if include { "!" } else { "!!" }),
            ..Self::default()
        }
    }
}

#[derive(Default)]
pub(super) struct StatusMetadata {
    workspace: (String, String),
    cwd_short: String,
    branch: Option<String>,
    next_branch_check: Option<Instant>,
    branch_job: Option<Receiver<Option<String>>>,
    catalog: HashMap<String, u64>,
    next_catalog_check: Option<Instant>,
    catalog_job: Option<Receiver<Option<HashMap<String, u64>>>>,
}

impl StatusMetadata {
    pub(super) fn tick(
        &mut self,
        target: &Target,
        client: &DaemonClient,
        status: &StatusLines,
        online: bool,
    ) -> bool {
        let mut changed = false;
        if self.workspace.0 != target.env_id || self.workspace.1 != target.cwd {
            self.workspace = (target.env_id.clone(), target.cwd.clone());
            self.cwd_short = if target.env_id == "host" {
                short_cwd(&target.cwd, env::var_os("HOME").as_deref().map(Path::new))
            } else {
                target.cwd.clone()
            };
            self.branch = None;
            self.branch_job = None;
            self.next_branch_check = None;
            changed = true;
        }

        let now = Instant::now();
        if let Some(branch) = take_ready(&mut self.branch_job) {
            changed |= branch != self.branch;
            self.branch = branch;
        }
        if status.needs_branch
            && target.env_id == "host"
            && Path::new(&target.cwd).is_absolute()
            && self.branch_job.is_none()
            && self.next_branch_check.is_none_or(|due| now >= due)
        {
            let cwd = target.cwd.clone();
            self.branch_job = Some(background(move || git_branch(Path::new(&cwd))));
            self.next_branch_check = Some(now + Duration::from_secs(2));
        }

        if let Some(catalog) = take_ready(&mut self.catalog_job).flatten() {
            changed |= catalog != self.catalog;
            self.catalog = catalog;
        }
        if status.needs_context
            && online
            && self.catalog_job.is_none()
            && self.next_catalog_check.is_none_or(|due| now >= due)
        {
            let client = client.clone();
            self.catalog_job = Some(background(move || {
                Some(
                    client
                        .list_models()
                        .ok()?
                        .into_iter()
                        .filter_map(|m| {
                            Some((model_key(&m.id), m.context_window.filter(|n| *n > 0)?))
                        })
                        .collect(),
                )
            }));
            self.next_catalog_check = Some(now + Duration::from_secs(30));
        }
        changed
    }

    pub(super) fn apply<'a>(&'a self, fields: &mut StatusFields<'a>, state: &TranscriptState) {
        if self.workspace.0 == fields.env_id && self.workspace.1 == fields.cwd {
            fields.cwd_short = &self.cwd_short;
            fields.git_branch = self.branch.as_deref();
        }
        if self.catalog.is_empty() {
            return;
        }
        fields.context_window = self.catalog.get(&model_key(fields.model)).copied();
        fields.context_percent = fields.context_window.and_then(|window| {
            state
                .context_tokens()
                .map(|tokens| 100.0 * tokens as f64 / window as f64)
        });
    }
}

fn background<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Receiver<T> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let _ = tx.send(f());
    });
    rx
}

fn take_ready<T>(job: &mut Option<Receiver<T>>) -> Option<T> {
    let value = match job.as_ref()?.try_recv() {
        Ok(value) => Some(value),
        Err(TryRecvError::Empty) => return None,
        Err(TryRecvError::Disconnected) => None,
    };
    *job = None;
    value
}

fn model_key(model: &str) -> String {
    match model.split_once([':', '/']) {
        Some((provider, id)) => format!(
            "{}:{id}",
            match provider {
                "openai-codex" => "openai_codex",
                "google-vertex" => "google_vertex",
                _ => provider,
            }
        ),
        None => model.to_owned(),
    }
}

fn short_cwd(cwd: &str, home: Option<&Path>) -> String {
    if let Some(rest) = home.and_then(|home| Path::new(cwd).strip_prefix(home).ok()) {
        if rest.as_os_str().is_empty() {
            "~".into()
        } else {
            format!("~/{}", rest.display())
        }
    } else {
        cwd.into()
    }
}

fn git_branch(cwd: &Path) -> Option<String> {
    for dir in cwd.ancestors() {
        let dot_git = dir.join(".git");
        let git_dir = match fs::metadata(&dot_git) {
            Ok(meta) if meta.is_dir() => dot_git,
            Ok(meta) if meta.is_file() => {
                let pointer = read_git_file(&dot_git)?;
                dir.join(pointer.trim_end().strip_prefix("gitdir: ")?)
            }
            Err(err) if err.kind() == io::ErrorKind::NotFound => continue,
            _ => return None,
        };
        let head = read_git_file(&git_dir.join("HEAD"))?;
        let branch = head.trim_end().strip_prefix("ref: refs/heads/")?;
        return (!branch.is_empty() && !branch.chars().any(char::is_control))
            .then(|| branch.to_owned());
    }
    None
}

fn read_git_file(path: &Path) -> Option<String> {
    if !fs::metadata(path).ok()?.is_file() {
        return None;
    }
    let mut text = String::new();
    fs::File::open(path)
        .ok()?
        .take(4097)
        .read_to_string(&mut text)
        .ok()?;
    (text.len() <= 4096).then_some(text)
}

pub(super) struct StatusLines {
    env: Environment<'static>,
    names: Vec<String>,
    needs_branch: bool,
    needs_context: bool,
}

impl Default for StatusLines {
    fn default() -> Self {
        Self::compile(None, vec![]).expect("valid built-in footer")
    }
}

impl StatusLines {
    pub(super) fn compile(base: Option<Vec<String>>, append: Vec<String>) -> Result<Self, String> {
        let mut env = Environment::new();
        env.set_fuel(Some(10_000));
        env.set_undefined_behavior(UndefinedBehavior::Strict);
        env.add_filter("compact", compact_number);
        env.add_function("align", align);
        env.set_formatter(|out, state, value| {
            // An unavailable field prints nothing, but is still `none` in conditions.
            if value.is_none() {
                Ok(())
            } else {
                escape_formatter(out, state, value)
            }
        });
        let fields = Value::from_serialize(StatusFields::default());
        let base = base.unwrap_or_else(|| vec![WORKSPACE_LINE.into(), DETAILS_LINE.into()]);
        let mut names = Vec::with_capacity(base.len() + append.len());
        let mut needs_branch = false;
        let mut needs_context = false;
        for (section, lines) in [("status_lines", base), ("status_lines_append", append)] {
            for (i, line) in lines.into_iter().enumerate() {
                let name = format!("{section}[{}]", i + 1);
                if line.contains(['\n', '\r']) {
                    return Err(format!("{name}: use one template string per line"));
                }
                env.add_template_owned(name.clone(), line)
                    .map_err(|e| format!("{name}: {e}"))?;
                let template = env.get_template(&name).expect("compiled above");
                let variables = template.undeclared_variables(false);
                needs_branch |= variables.contains("git_branch");
                needs_context |=
                    variables.contains("context_window") || variables.contains("context_percent");
                let mut unknown: Vec<_> = variables
                    .into_iter()
                    .filter(|key| {
                        fields.get_attr(key).is_ok_and(|v| v.is_undefined()) && key != "align"
                    })
                    .collect();
                if !unknown.is_empty() {
                    unknown.sort();
                    return Err(format!(
                        "{name}: unknown status field(s): {}",
                        unknown.join(", ")
                    ));
                }
                names.push(name);
            }
        }
        Ok(Self {
            env,
            names,
            needs_branch,
            needs_context,
        })
    }

    fn lines<'a>(
        &'a self,
        fields: &StatusFields<'_>,
    ) -> impl Iterator<Item = Result<String, String>> + 'a {
        let fields = Value::from_serialize(fields);
        self.names.iter().map(move |name| {
            let mut out = LineOutput::default();
            self.env
                .get_template(name)
                .expect("compiled at load")
                .render_captured_to(&fields, &mut out)
                .map_err(|e| {
                    if e.kind() == minijinja::ErrorKind::WriteFailure {
                        format!("{name}: exceeded 16 KiB of output")
                    } else {
                        format!("{name}: {e}")
                    }
                })?;
            Ok(String::from_utf8(out.0).expect("templates write UTF-8"))
        })
    }

    pub(super) fn validate(&self, fields: &StatusFields<'_>) -> Result<(), String> {
        self.lines(fields).try_for_each(|line| line.map(|_| ()))
    }

    pub(super) fn render(&self, fields: &StatusFields<'_>) -> Vec<String> {
        self.lines(fields)
            .filter_map(|line| match line {
                Ok(line) if line.trim().is_empty() => None,
                Ok(line) => Some(line),
                Err(err) => Some(format!("Status template: {err}")),
            })
            .collect()
    }
}

fn align(state: &minijinja::State<'_, '_>, left: String, right: String) -> String {
    let width = state
        .lookup("width")
        .and_then(|v| u16::try_from(v).ok())
        .unwrap_or(0);
    let left = sanitize_single_line(&left);
    let right = sanitize_single_line(&right);
    let gap = usize::from(width)
        .saturating_sub(left.width().saturating_add(right.width()))
        .clamp(1, 16_384);
    format!("{left}{:gap$}{right}", "")
}

/// Abbreviate integer counts without rounding across a unit boundary.
fn compact_number(number: Option<i128>) -> String {
    let Some(number) = number else {
        return String::new();
    };
    let (divisor, suffix) = match number.unsigned_abs() {
        0..=999 => (1, ""),
        1_000..=999_999 => (1_000, "k"),
        1_000_000..=999_999_999 => (1_000_000, "m"),
        _ => (1_000_000_000, "b"),
    };
    format!("{}{suffix}", number / divisor)
}

// Bound generated output per line, independently of the number of configured rows.
#[derive(Default)]
struct LineOutput(Vec<u8>);

impl io::Write for LineOutput {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > 16_384 - self.0.len() {
            return Err(io::Error::other(
                "status template exceeded 16 KiB of output",
            ));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hi::actions::SessionLabels;
    use serde_json::json;

    fn target() -> Target {
        Target {
            sid: "demo".into(),
            cid: "3".into(),
            cwd: "/remote/工作".into(),
            env_id: "remote".into(),
            labels: SessionLabels {
                title: Some("Title".into()),
                status: Some("ok".into()),
                harness_id: Some("coding".into()),
            },
        }
    }

    #[test]
    fn compact_number_uses_whole_units_at_each_boundary() {
        for (number, expected) in [
            (0, "0"),
            (999, "999"),
            (1_000, "1k"),
            (999_999, "999k"),
            (1_000_000, "1m"),
            (999_999_999, "999m"),
            (1_000_000_000, "1b"),
            (1_000_000_000_000, "1000b"),
            (-12_345, "-12k"),
            (i128::from(u64::MAX), "18446744073b"),
        ] {
            assert_eq!(compact_number(Some(number)), expected);
        }
    }

    #[test]
    fn alignment_counts_terminal_columns_and_escapes_control_characters() {
        let status =
            StatusLines::compile(Some(vec!["{{ align(note, cwd) }}".into()]), vec![]).unwrap();
        let mut fields = StatusFields {
            note: "界",
            cwd: "a\tb",
            width: 10,
            ..StatusFields::default()
        };
        assert_eq!(status.render(&fields), ["界    a\\tb"]);
        fields.width = 3;
        assert_eq!(status.render(&fields), ["界 a\\tb"]);
    }

    #[test]
    fn home_shortening_is_based_on_path_components() {
        let home = Some(Path::new("/Users/al"));
        assert_eq!(short_cwd("/Users/al", home), "~");
        assert_eq!(short_cwd("/Users/al/work", home), "~/work");
        assert_eq!(short_cwd("/Users/alex/work", home), "/Users/alex/work");
    }

    #[test]
    fn status_templates_can_compact_optional_and_unsigned_counts() {
        let status = StatusLines::compile(
            Some(vec![
                "seq={{ seq | compact }} · tokens={{ total_tokens | compact }}".into(),
            ]),
            vec![],
        )
        .unwrap();
        let mut fields = StatusFields {
            total_tokens: u64::MAX,
            ..StatusFields::default()
        };
        assert_eq!(status.render(&fields), ["seq= · tokens=18446744073b"]);
        fields.seq = Some(999_999);
        assert_eq!(status.render(&fields), ["seq=999k · tokens=18446744073b"]);
    }

    #[test]
    fn status_templates_format_money_and_guard_percentage_calculations() {
        let status = StatusLines::compile(
            Some(vec![
                "${{ '%.2f' | format(cost) }}".into(),
                "${{ cost | round(2) }}".into(),
                "{% if total_tokens > 0 %}Output share: {{ '%.1f' | format(100 * output_tokens / total_tokens) }}%{% endif %}".into(),
            ]),
            vec![],
        )
        .unwrap();
        let mut fields = StatusFields {
            cost: 2.4305,
            output_tokens: 253,
            total_tokens: 1_000,
            ..StatusFields::default()
        };
        assert_eq!(
            status.render(&fields),
            ["$2.43", "$2.43", "Output share: 25.3%"]
        );
        fields.cost = 2.5;
        fields.total_tokens = 0;
        assert_eq!(status.render(&fields), ["$2.50", "$2.5"]);
        fields.cost = 2.439;
        assert_eq!(status.render(&fields), ["$2.44", "$2.44"]);
    }

    #[test]
    fn status_templates_handle_path_labels_and_missing_numbers() {
        let status = StatusLines::compile(
            Some(vec![
                "{{ (cwd | trim('/') | split('/') | last) or cwd }}".into(),
                "seq {{ seq if seq is not none else '—' }}".into(),
            ]),
            vec![],
        )
        .unwrap();
        let mut fields = StatusFields {
            cwd: "/remote/工作/",
            ..StatusFields::default()
        };
        assert_eq!(status.render(&fields), ["工作", "seq —"]);
        fields.cwd = "/";
        fields.seq = Some(0);
        assert_eq!(status.render(&fields), ["/", "seq 0"]);
    }

    #[test]
    fn default_shows_workspace_and_activity_first_and_can_be_extended() {
        let target = target();
        let mut state = TranscriptState::default();
        let mut fields = StatusFields::from_session(&target, &state);
        fields.note = "Connecting · /help";
        fields.connection = "offline";
        fields.width = 32;
        assert_eq!(
            StatusLines::default().render(&fields),
            [
                "/remote/工作      idle (offline)",
                "Connecting · /help · [seq - · default (medium)] · demo:3",
            ]
        );

        state.seq = Some(42);
        state.docs = json!({
            "agent": {"model": "openrouter:vendor/model", "thinking": "high"},
            "live": {"user_shell": {"command": "echo hi", "include_in_context": false}},
            "inbox": [{}],
            "usage": {"input_tokens": 123, "output_tokens": 456, "cost": 0.98765}
        })
        .as_object()
        .unwrap()
        .clone();
        let mut fields = StatusFields::from_session(&target, &state);
        fields.note = "Ready · /help";
        fields.connection = "online";
        fields.online = true;
        fields.cwd_short = "~/work";
        fields.git_branch = Some("main");
        fields.width = 24;
        fields.pending = true;
        fields.attachments = 2;
        fields.fork_entry_id = Some("12");
        fields.fork_predecessor_id = Some(11);
        let status =
            StatusLines::compile(None, vec!["{{ provider }} · {{ model_name }}".into()]).unwrap();
        assert_eq!(status.render(&fields), [
            "~/work (main)       busy",
            "Ready · /help · shell !!echo hi (running) · [seq 42 · openrouter:vendor/model (high) · queued 1 · tokens 123/456 ($0.9877)] · pending · attachment · fork-edit #12@11 · demo:3",
            "openrouter · vendor/model",
        ]);
    }

    #[test]
    fn conditional_lines_follow_state_and_support_replacement() {
        let target = target();
        let mut state = TranscriptState::default();
        let status = StatusLines::compile(Some(vec![
            "{{ session_title }} · {{ env_id }} · {{ cwd }}".into(),
            "{% if provider == 'fake' and model_name == 'test' and thinking == 'high' and session_status == 'ok' %}{{ activity }} {{ failure_reason }}{% endif %}".into(),
            "  ".into(),
        ]), vec!["{{ run_turns }}".into()]).unwrap();
        assert_eq!(
            status.render(&StatusFields::from_session(&target, &state)),
            ["Title · remote · /remote/工作"]
        );
        state.docs.insert(
            "agent".into(),
            json!({"model": "fake/test", "thinking": "high"}),
        );
        state.docs.insert(
            "live".into(),
            json!({"run_failure": {"reason": "rate limit"}}),
        );
        assert_eq!(
            status.render(&StatusFields::from_session(&target, &state)),
            ["Title · remote · /remote/工作", "paused rate limit"]
        );
        assert!(StatusLines::compile(Some(vec![]), vec![])
            .unwrap()
            .render(&StatusFields::default())
            .is_empty());
    }

    #[test]
    fn invalid_templates_are_diagnosed_and_output_is_bounded() {
        for (line, expected) in [
            ("{% if online %}", "syntax error"),
            (
                "{% if online %}{{ typo }}{% endif %}",
                "unknown status field(s): typo",
            ),
            ("literal\nnext line", "one template string per line"),
        ] {
            let err = StatusLines::compile(Some(vec![line.into()]), vec![])
                .err()
                .unwrap();
            assert!(
                err.starts_with("status_lines[1]:") && err.contains(expected),
                "{err}"
            );
        }
        let lines =
            StatusLines::compile(Some(vec!["{{ note }}".into(), "still here".into()]), vec![])
                .unwrap();
        let note = "a".repeat(16_385);
        let fields = StatusFields {
            note: &note,
            ..StatusFields::default()
        };
        assert!(lines.validate(&fields).unwrap_err().contains("16 KiB"));
        let rows = lines.render(&fields);
        assert!(rows[0].starts_with("Status template: status_lines[1]:"));
        assert_eq!(rows[1], "still here");
    }
}
