use super::{actions::Target, editor::Editor};
use crate::{
    client::{ClientError, DaemonClient},
    render::sanitize_single_line,
};
use std::ops::Range;

pub(super) struct Token {
    range: Range<usize>,
    cursor: usize,
}

impl Token {
    pub(super) fn at_cursor(editor: &Editor) -> Option<Self> {
        let text = editor.text();
        let cursor = editor.cursor();
        let start = text[..cursor]
            .rfind(char::is_whitespace)
            .map_or(0, |i| i + text[i..].chars().next().unwrap().len_utf8());
        if start == cursor {
            return None;
        }
        let end = text[cursor..]
            .find(char::is_whitespace)
            .map_or(text.len(), |i| cursor + i);
        Some(Self {
            range: start..end,
            cursor,
        })
    }

    pub(super) fn prefix<'a>(&self, editor: &'a Editor) -> &'a str {
        &editor.text()[self.range.start..self.cursor]
    }

    pub(super) fn is_command(&self, editor: &Editor) -> bool {
        self.range.start == 0 && self.prefix(editor).starts_with('/')
    }
}

pub(super) struct Completion {
    token: Token,
    choices: Vec<(String, String)>,
    selected: usize,
    end: usize,
    title: &'static str,
}

impl Completion {
    pub(super) fn start(
        editor: &mut Editor,
        token: Token,
        title: &'static str,
        choices: Vec<(String, String)>,
    ) -> Option<Self> {
        let value = &choices.first()?.0;
        let end = token.range.start + value.len();
        editor
            .replace_completion(token.range.clone(), value)
            .then_some(Self {
                token,
                choices,
                selected: 0,
                end,
                title,
            })
    }

    pub(super) fn cycle(&mut self, editor: &mut Editor) {
        let selected = (self.selected + 1) % self.choices.len();
        let value = &self.choices[selected].0;
        let start = self.token.range.start;
        let end = start + value.len();
        if editor.replace_completion(start..self.end, value) {
            self.selected = selected;
            self.end = end;
        }
    }

    pub(super) fn sole_directory(&self) -> Option<Token> {
        (self.choices.len() == 1 && self.choices[0].0.ends_with('/')).then_some(Token {
            range: self.token.range.start..self.end,
            cursor: self.end,
        })
    }

    pub(super) fn lines(&self) -> Vec<String> {
        let mut lines = vec![format!(
            "{} · Tab to cycle ({}/{})",
            self.title,
            self.selected + 1,
            self.choices.len()
        )];
        lines.extend(self.choices.iter().enumerate().map(|(i, (_, label))| {
            let marker = if i == self.selected { "> " } else { "  " };
            format!("{marker}{}", sanitize_single_line(label))
        }));
        lines
    }
}

pub(super) fn directories(
    client: &DaemonClient,
    env_id: &str,
    fallback_cwd: &str,
    prefix: &str,
) -> Result<Vec<(String, String)>, ClientError> {
    let expanded_home = if env_id == "host" && (prefix == "~" || prefix.starts_with("~/")) {
        std::env::var("HOME").ok().filter(|h| !h.is_empty())
    } else {
        None
    };
    let (display_prefix, lookup_prefix) = match &expanded_home {
        Some(home) => {
            let trimmed = home.trim_end_matches('/');
            let rest = prefix.strip_prefix('~').unwrap_or("");
            if rest.is_empty() {
                ("~/", format!("{trimmed}/"))
            } else {
                (prefix, format!("{trimmed}{rest}"))
            }
        }
        None => (prefix, prefix.to_owned()),
    };

    let (dir, basename) = lookup_prefix
        .rfind('/')
        .map_or(("", lookup_prefix.as_str()), |slash| {
            lookup_prefix.split_at(slash + 1)
        });
    let display_dir = display_prefix
        .rfind('/')
        .map_or("", |slash| &display_prefix[..=slash]);

    let parent = if dir.starts_with('/') {
        dir.to_owned()
    } else if !fallback_cwd.starts_with('/') {
        return Err(ClientError::InvalidInput(
            "no absolute base directory for path completion".into(),
        ));
    } else if dir.is_empty() {
        fallback_cwd.to_owned()
    } else {
        format!("{}/{dir}", fallback_cwd.trim_end_matches('/'))
    };

    let response = match client.list_directory_files(env_id, &parent, basename) {
        Err(ClientError::HttpStatus { status: 404, .. }) => return Ok(Vec::new()),
        other => other?,
    };
    let prefix_lower = basename.to_lowercase();
    let mut choices: Vec<_> = response
        .entries
        .into_iter()
        .filter_map(|entry| {
            if entry.kind != "dir" {
                return None;
            }
            let name = entry.path;
            if matches!(name.as_str(), "" | "." | "..")
                || name.contains('/')
                || name.chars().any(char::is_control)
                || !name.to_lowercase().starts_with(&prefix_lower)
            {
                return None;
            }
            Some((format!("{display_dir}{name}/"), format!("{name}/")))
        })
        .collect();
    choices.sort_by(|a, b| a.0.cmp(&b.0));
    choices.dedup();
    Ok(choices)
}

pub(super) fn paths(
    client: &DaemonClient,
    target: &Target,
    prefix: &str,
    shell: bool,
) -> Result<Vec<(String, String)>, ClientError> {
    let (dir, basename) = prefix
        .rfind('/')
        .map_or(("", prefix), |slash| prefix.split_at(slash + 1));
    let parent = if dir.starts_with('/') {
        dir.to_owned()
    } else if !target.cwd.starts_with('/') {
        return Err(ClientError::InvalidInput(
            "session has no absolute working directory".into(),
        ));
    } else if dir.is_empty() {
        target.cwd.clone()
    } else {
        format!("{}/{dir}", target.cwd.trim_end_matches('/'))
    };
    // The request is scoped to the containing directory, not a recursive search of the session.
    let response = match client.list_directory_files(&target.env_id, &parent, basename) {
        Err(ClientError::HttpStatus { status: 404, .. }) => return Ok(Vec::new()),
        other => other?,
    };
    let prefix_lower = basename.to_lowercase();
    let mut choices: Vec<_> = response
        .entries
        .into_iter()
        .filter_map(|entry| {
            let name = entry.path;
            if matches!(name.as_str(), "" | "." | "..")
                || name.contains('/')
                || name.chars().any(char::is_control)
                || !name.to_lowercase().starts_with(&prefix_lower)
            {
                return None;
            }
            // Shell drafts accept only names that need no shell quoting.
            if shell
                && !name
                    .chars()
                    .all(|c| c.is_alphanumeric() || "_-.+".contains(c))
            {
                return None;
            }
            let suffix = match entry.kind.as_str() {
                "dir" => "/",
                "file" if !dir.is_empty() => "",
                _ => return None,
            };
            Some((format!("{dir}{name}{suffix}"), format!("{name}{suffix}")))
        })
        .collect();
    choices.sort_by(|a, b| {
        b.0.ends_with('/')
            .cmp(&a.0.ends_with('/'))
            .then_with(|| a.0.cmp(&b.0))
    });
    choices.dedup();
    Ok(choices)
}
