//! Read-only footer fields and compiled, one-row templates. No daemon calls on redraw.
use super::actions::Target;
use crate::{render::sanitize_single_line, transcript::TranscriptState};
use minijinja::{escape_formatter, Environment, UndefinedBehavior, Value};
use serde::Serialize;
use std::io;

const DEFAULT_LINE: &str = concat!(
    "{{ note }}{% if shell_active %} · shell {{ shell_prefix }}{{ shell_preview }} ({{ shell_status }}){% endif %}",
    " · {{ connection }} · [seq {{ seq if seq is not none else '-' }} · {{ activity }} · {{ model }} ({{ thinking }})",
    "{% if queued %} · queued {{ queued }}{% endif %}",
    "{% if has_usage %} · tokens {{ input_tokens }}/{{ output_tokens }}{% if cost > 0 %} (${{ '%.4f'|format(cost) }}){% endif %}{% endif %}]",
    "{% if pending %} · pending{% endif %}{% if attachments %} · attachment{% endif %}",
    "{% if fork_entry_id %} · fork-edit #{{ fork_entry_id }}@{{ fork_predecessor_id }}{% endif %}",
    " · {{ session_id }}:{{ conversation_id }} · {{ cwd }}",
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
    model_name: &'a str,
    provider: Option<&'a str>,
    thinking: &'a str,
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
            env_id: &target.env_id,
            session_title: target.labels.title.as_deref(),
            session_status: target.labels.status.as_deref(),
            harness_id: target.labels.harness_id.as_deref(),
            seq: state.seq,
            activity: if state.is_run_active() {
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

pub(super) struct StatusLines {
    env: Environment<'static>,
    names: Vec<String>,
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
        env.set_formatter(|out, state, value| {
            // An unavailable field prints nothing, but is still `none` in conditions.
            if value.is_none() {
                Ok(())
            } else {
                escape_formatter(out, state, value)
            }
        });
        let fields = Value::from_serialize(StatusFields::default());
        let base = base.unwrap_or_else(|| vec![DEFAULT_LINE.into()]);
        let mut names = Vec::with_capacity(base.len() + append.len());
        for (section, lines) in [("status_lines", base), ("status_lines_append", append)] {
            for (i, line) in lines.into_iter().enumerate() {
                let name = format!("{section}[{}]", i + 1);
                if line.contains(['\n', '\r']) {
                    return Err(format!("{name}: use one template string per line"));
                }
                env.add_template_owned(name.clone(), line)
                    .map_err(|e| format!("{name}: {e}"))?;
                let template = env.get_template(&name).expect("compiled above");
                let mut unknown: Vec<_> = template
                    .undeclared_variables(false)
                    .into_iter()
                    .filter(|key| fields.get_attr(key).is_ok_and(|v| v.is_undefined()))
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
        Ok(Self { env, names })
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
    fn default_is_compatible_and_can_be_extended() {
        let target = target();
        let mut state = TranscriptState::default();
        let mut fields = StatusFields::from_session(&target, &state);
        fields.note = "Connecting · /help";
        fields.connection = "offline";
        assert_eq!(StatusLines::default().render(&fields), [
            "Connecting · /help · offline · [seq - · idle · default (medium)] · demo:3 · /remote/工作",
        ]);

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
        fields.pending = true;
        fields.attachments = 2;
        fields.fork_entry_id = Some("12");
        fields.fork_predecessor_id = Some(11);
        let status =
            StatusLines::compile(None, vec!["{{ provider }} · {{ model_name }}".into()]).unwrap();
        assert_eq!(status.render(&fields), [
            "Ready · /help · shell !!echo hi (running) · online · [seq 42 · busy · openrouter:vendor/model (high) · queued 1 · tokens 123/456 ($0.9877)] · pending · attachment · fork-edit #12@11 · demo:3 · /remote/工作",
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
