use ratatui::style::{Color, Modifier, Style};
use serde::Deserialize;
use std::{fs, io::Read, path::Path};

const MAX_THEME_FILE_BYTES: usize = 65_536;
const BUILTIN_THEME_NAMES: [&str; 4] = ["dark", "light", "ansi", "plain"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Theme {
    pub name: String,
    pub is_plain: bool,

    // Role headers & accents
    pub user_header: Style,
    pub user_text: Style,
    pub assistant_header: Style,
    pub system_header: Style,
    pub thinking_header: Style,
    pub thinking_text: Style,
    pub compaction_header: Style,
    pub history_marker: Style,
    pub failure_header: Style,
    pub failure_text: Style,

    // Tool & shell cards
    pub tool_ok: Style,
    pub tool_running: Style,
    pub tool_error: Style,
    pub tool_header: Style,
    pub tool_meta: Style,
    pub tool_output: Style,
    pub shell_header: Style,
    pub queued_header: Style,

    // Markdown tokens
    pub md_h1: Style,
    pub md_h2: Style,
    pub md_h3: Style,
    pub md_code_inline: Style,
    pub md_code_fence: Style,
    pub md_quote_border: Style,
    pub md_quote_text: Style,
    pub md_link_text: Style,
    pub md_link_url: Style,
    pub md_bullet: Style,
    pub md_hr: Style,
    pub md_bold: Style,
    pub md_italic: Style,
    pub md_strike: Style,

    // Diff & syntax tokens
    pub diff_add: Style,
    pub diff_remove: Style,
    pub diff_hunk: Style,
    pub diff_meta: Style,
    pub syn_keyword: Style,
    pub syn_string: Style,
    pub syn_comment: Style,
    pub syn_number: Style,
    pub syn_type: Style,
    pub syn_fn: Style,

    // Inbox browser
    pub inbox_dir: Style,
    pub inbox_idle_new: Style,
    pub inbox_idle: Style,
    pub inbox_processing: Style,
    pub inbox_selected: Style,

    // UI chrome
    pub separator: Style,
    pub scroll_badge: Style,
    pub status_bar: Style,
}

impl Default for Theme {
    fn default() -> Self {
        Self::dark()
    }
}

impl Theme {
    pub fn is_valid_custom_name(name: &str) -> bool {
        let bytes = name.as_bytes();
        !bytes.is_empty()
            && bytes.len() <= 64
            && (bytes[0].is_ascii_lowercase() || bytes[0].is_ascii_digit())
            && bytes[1..]
                .iter()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_' || *b == b'-')
    }

    pub fn available_themes(data_dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = BUILTIN_THEME_NAMES
            .iter()
            .map(|s| (*s).to_string())
            .collect();
        let themes_dir = data_dir.join("themes");
        let Ok(entries) = fs::read_dir(&themes_dir) else {
            return names;
        };
        let mut custom = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if BUILTIN_THEME_NAMES.contains(&stem) || !Self::is_valid_custom_name(stem) {
                continue;
            }
            if let Ok(meta) = fs::symlink_metadata(&path) {
                if meta.is_file() && meta.len() <= MAX_THEME_FILE_BYTES as u64 {
                    custom.push(stem.to_string());
                }
            }
        }
        custom.sort();
        custom.dedup();
        names.extend(custom);
        names
    }

    pub fn from_name(name: &str) -> Result<Self, String> {
        match name {
            "dark" => Ok(Self::dark()),
            "light" => Ok(Self::light()),
            "ansi" => Ok(Self::ansi()),
            "plain" => Ok(Self::plain()),
            other => Err(format!(
                "unknown theme {other:?}: expected \"dark\", \"light\", \"ansi\", or \"plain\""
            )),
        }
    }

    pub fn from_name_in_dir(name: &str, data_dir: Option<&Path>) -> Result<Self, String> {
        if let Ok(builtin) = Self::from_name(name) {
            return Ok(builtin);
        }
        let Some(dir) = data_dir else {
            return Self::from_name(name);
        };
        if !Self::is_valid_custom_name(name) {
            return Err(format!(
                "unknown theme {other:?}: invalid theme name (expected built-in or ^[a-z0-9][a-z0-9_-]{{0,63}}$)",
                other = name
            ));
        }
        let path = dir.join("themes").join(format!("{name}.json"));
        let meta = fs::symlink_metadata(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                format!(
                    "unknown theme {name:?}: expected \"dark\", \"light\", \"ansi\", \"plain\", or {}",
                    path.display()
                )
            } else {
                format!("{}: {e}", path.display())
            }
        })?;
        if !meta.is_file() {
            return Err(format!("{}: theme must be a regular file", path.display()));
        }
        if meta.len() > MAX_THEME_FILE_BYTES as u64 {
            return Err(format!(
                "{}: theme file exceeds {} byte limit",
                path.display(),
                MAX_THEME_FILE_BYTES
            ));
        }
        let file = fs::File::open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        let mut raw = String::new();
        file.take(MAX_THEME_FILE_BYTES as u64 + 1)
            .read_to_string(&mut raw)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        if raw.len() > MAX_THEME_FILE_BYTES {
            return Err(format!(
                "{}: theme file exceeds {} byte limit",
                path.display(),
                MAX_THEME_FILE_BYTES
            ));
        }
        Self::from_json_str(name, &raw).map_err(|e| format!("{}: {e}", path.display()))
    }

    pub fn from_json_str(name: &str, raw: &str) -> Result<Self, String> {
        let syntax = raw.strip_prefix('\u{feff}').unwrap_or(raw);
        if !syntax.trim_start().starts_with('{') {
            return Err("expected a JSON object".to_string());
        }
        let spec: CustomThemeSpec =
            serde_json::from_str(syntax).map_err(|e| format!("invalid theme JSON: {e}"))?;
        spec.into_theme(name)
    }

    pub fn resolve(configured: Option<&str>) -> Result<Self, String> {
        Self::resolve_in_dir(configured, None)
    }

    pub fn resolve_in_dir(
        configured: Option<&str>,
        data_dir: Option<&Path>,
    ) -> Result<Self, String> {
        let no_color = std::env::var_os("NO_COLOR").is_some_and(|v| !v.is_empty());
        Self::resolve_with_no_color_in_dir(configured, no_color, data_dir)
    }

    pub fn resolve_with_no_color(configured: Option<&str>, no_color: bool) -> Result<Self, String> {
        Self::resolve_with_no_color_in_dir(configured, no_color, None)
    }

    pub fn resolve_with_no_color_in_dir(
        configured: Option<&str>,
        no_color: bool,
        data_dir: Option<&Path>,
    ) -> Result<Self, String> {
        match configured {
            Some(name) => Self::from_name_in_dir(name, data_dir),
            None if no_color => Ok(Self::plain()),
            None => Ok(Self::dark()),
        }
    }

    pub fn dark() -> Self {
        Self {
            name: "dark".to_string(),
            is_plain: false,

            user_header: Style::default()
                .fg(Color::Rgb(105, 185, 255))
                .add_modifier(Modifier::BOLD),
            user_text: Style::default()
                .fg(Color::Rgb(232, 236, 242))
                .bg(Color::Rgb(34, 40, 52)),
            assistant_header: Style::default()
                .fg(Color::Rgb(110, 215, 215))
                .add_modifier(Modifier::BOLD),
            system_header: Style::default()
                .fg(Color::Rgb(198, 138, 226))
                .add_modifier(Modifier::BOLD),
            thinking_header: Style::default()
                .fg(Color::Rgb(135, 145, 160))
                .add_modifier(Modifier::DIM | Modifier::ITALIC),
            thinking_text: Style::default()
                .fg(Color::Rgb(140, 150, 165))
                .add_modifier(Modifier::DIM | Modifier::ITALIC),
            compaction_header: Style::default()
                .fg(Color::Rgb(198, 138, 226))
                .add_modifier(Modifier::BOLD),
            history_marker: Style::default()
                .fg(Color::Rgb(135, 145, 160))
                .add_modifier(Modifier::DIM),
            failure_header: Style::default()
                .fg(Color::Rgb(245, 105, 105))
                .add_modifier(Modifier::BOLD),
            failure_text: Style::default().fg(Color::Rgb(235, 160, 160)),

            tool_ok: Style::default().fg(Color::Rgb(130, 210, 130)),
            tool_running: Style::default().fg(Color::Rgb(235, 195, 100)),
            tool_error: Style::default()
                .fg(Color::Rgb(245, 105, 105))
                .add_modifier(Modifier::BOLD),
            tool_header: Style::default()
                .fg(Color::Rgb(110, 200, 225))
                .add_modifier(Modifier::BOLD),
            tool_meta: Style::default()
                .fg(Color::Rgb(135, 145, 160))
                .add_modifier(Modifier::DIM),
            tool_output: Style::default().fg(Color::Rgb(195, 202, 212)),
            shell_header: Style::default()
                .fg(Color::Rgb(235, 175, 95))
                .add_modifier(Modifier::BOLD),
            queued_header: Style::default()
                .fg(Color::Rgb(235, 195, 100))
                .add_modifier(Modifier::BOLD),

            md_h1: Style::default()
                .fg(Color::Rgb(110, 215, 235))
                .add_modifier(Modifier::BOLD | Modifier::UNDERLINED),
            md_h2: Style::default()
                .fg(Color::Rgb(110, 215, 235))
                .add_modifier(Modifier::BOLD),
            md_h3: Style::default()
                .fg(Color::Rgb(220, 230, 242))
                .add_modifier(Modifier::BOLD),
            md_code_inline: Style::default()
                .fg(Color::Rgb(235, 195, 115))
                .bg(Color::Rgb(42, 46, 58)),
            md_code_fence: Style::default()
                .fg(Color::Rgb(130, 140, 155))
                .add_modifier(Modifier::DIM),
            md_quote_border: Style::default()
                .fg(Color::Rgb(100, 195, 210))
                .add_modifier(Modifier::DIM),
            md_quote_text: Style::default()
                .fg(Color::Rgb(168, 178, 192))
                .add_modifier(Modifier::ITALIC),
            md_link_text: Style::default()
                .fg(Color::Rgb(115, 175, 245))
                .add_modifier(Modifier::UNDERLINED),
            md_link_url: Style::default()
                .fg(Color::Rgb(130, 140, 155))
                .add_modifier(Modifier::DIM),
            md_bullet: Style::default()
                .fg(Color::Rgb(110, 215, 235))
                .add_modifier(Modifier::BOLD),
            md_hr: Style::default()
                .fg(Color::Rgb(110, 120, 135))
                .add_modifier(Modifier::DIM),
            md_bold: Style::default().add_modifier(Modifier::BOLD),
            md_italic: Style::default().add_modifier(Modifier::ITALIC),
            md_strike: Style::default().add_modifier(Modifier::CROSSED_OUT | Modifier::DIM),

            diff_add: Style::default().fg(Color::Rgb(130, 210, 130)),
            diff_remove: Style::default().fg(Color::Rgb(245, 105, 105)),
            diff_hunk: Style::default()
                .fg(Color::Rgb(110, 215, 235))
                .add_modifier(Modifier::BOLD),
            diff_meta: Style::default()
                .fg(Color::Rgb(135, 145, 160))
                .add_modifier(Modifier::BOLD),
            syn_keyword: Style::default().fg(Color::Rgb(198, 120, 221)),
            syn_string: Style::default().fg(Color::Rgb(152, 195, 121)),
            syn_comment: Style::default()
                .fg(Color::Rgb(127, 132, 142))
                .add_modifier(Modifier::DIM | Modifier::ITALIC),
            syn_number: Style::default().fg(Color::Rgb(229, 192, 123)),
            syn_type: Style::default().fg(Color::Rgb(86, 182, 194)),
            syn_fn: Style::default().fg(Color::Rgb(97, 175, 239)),

            inbox_dir: Style::default()
                .fg(Color::Rgb(110, 200, 225))
                .add_modifier(Modifier::BOLD),
            inbox_idle_new: Style::default()
                .fg(Color::Rgb(115, 225, 145))
                .add_modifier(Modifier::BOLD),
            inbox_idle: Style::default()
                .fg(Color::Rgb(235, 240, 248))
                .add_modifier(Modifier::BOLD),
            inbox_processing: Style::default()
                .fg(Color::Rgb(135, 145, 160))
                .add_modifier(Modifier::DIM),
            inbox_selected: Style::default()
                .bg(Color::Rgb(42, 52, 70))
                .add_modifier(Modifier::BOLD),

            separator: Style::default().add_modifier(Modifier::DIM),
            scroll_badge: Style::default().add_modifier(Modifier::BOLD),
            status_bar: Style::default().add_modifier(Modifier::REVERSED),
        }
    }

    pub fn light() -> Self {
        Self {
            name: "light".to_string(),
            is_plain: false,

            user_header: Style::default()
                .fg(Color::Rgb(0, 95, 185))
                .add_modifier(Modifier::BOLD),
            user_text: Style::default()
                .fg(Color::Rgb(30, 35, 45))
                .bg(Color::Rgb(235, 240, 248)),
            assistant_header: Style::default()
                .fg(Color::Rgb(0, 120, 145))
                .add_modifier(Modifier::BOLD),
            system_header: Style::default()
                .fg(Color::Rgb(135, 45, 165))
                .add_modifier(Modifier::BOLD),
            thinking_header: Style::default()
                .fg(Color::Rgb(105, 115, 130))
                .add_modifier(Modifier::DIM | Modifier::ITALIC),
            thinking_text: Style::default()
                .fg(Color::Rgb(105, 115, 130))
                .add_modifier(Modifier::DIM | Modifier::ITALIC),
            compaction_header: Style::default()
                .fg(Color::Rgb(135, 45, 165))
                .add_modifier(Modifier::BOLD),
            history_marker: Style::default()
                .fg(Color::Rgb(105, 115, 130))
                .add_modifier(Modifier::DIM),
            failure_header: Style::default()
                .fg(Color::Rgb(195, 35, 45))
                .add_modifier(Modifier::BOLD),
            failure_text: Style::default().fg(Color::Rgb(165, 35, 45)),

            tool_ok: Style::default().fg(Color::Rgb(25, 135, 55)),
            tool_running: Style::default().fg(Color::Rgb(165, 105, 0)),
            tool_error: Style::default()
                .fg(Color::Rgb(195, 35, 45))
                .add_modifier(Modifier::BOLD),
            tool_header: Style::default()
                .fg(Color::Rgb(0, 110, 155))
                .add_modifier(Modifier::BOLD),
            tool_meta: Style::default()
                .fg(Color::Rgb(100, 110, 125))
                .add_modifier(Modifier::DIM),
            tool_output: Style::default().fg(Color::Rgb(55, 62, 75)),
            shell_header: Style::default()
                .fg(Color::Rgb(165, 85, 0))
                .add_modifier(Modifier::BOLD),
            queued_header: Style::default()
                .fg(Color::Rgb(165, 105, 0))
                .add_modifier(Modifier::BOLD),

            md_h1: Style::default()
                .fg(Color::Rgb(0, 110, 155))
                .add_modifier(Modifier::BOLD | Modifier::UNDERLINED),
            md_h2: Style::default()
                .fg(Color::Rgb(0, 110, 155))
                .add_modifier(Modifier::BOLD),
            md_h3: Style::default()
                .fg(Color::Rgb(25, 30, 40))
                .add_modifier(Modifier::BOLD),
            md_code_inline: Style::default()
                .fg(Color::Rgb(145, 65, 0))
                .bg(Color::Rgb(236, 238, 242)),
            md_code_fence: Style::default()
                .fg(Color::Rgb(110, 120, 135))
                .add_modifier(Modifier::DIM),
            md_quote_border: Style::default()
                .fg(Color::Rgb(0, 115, 155))
                .add_modifier(Modifier::DIM),
            md_quote_text: Style::default()
                .fg(Color::Rgb(85, 95, 110))
                .add_modifier(Modifier::ITALIC),
            md_link_text: Style::default()
                .fg(Color::Rgb(0, 90, 195))
                .add_modifier(Modifier::UNDERLINED),
            md_link_url: Style::default()
                .fg(Color::Rgb(110, 120, 135))
                .add_modifier(Modifier::DIM),
            md_bullet: Style::default()
                .fg(Color::Rgb(0, 110, 155))
                .add_modifier(Modifier::BOLD),
            md_hr: Style::default()
                .fg(Color::Rgb(140, 150, 165))
                .add_modifier(Modifier::DIM),
            md_bold: Style::default().add_modifier(Modifier::BOLD),
            md_italic: Style::default().add_modifier(Modifier::ITALIC),
            md_strike: Style::default().add_modifier(Modifier::CROSSED_OUT | Modifier::DIM),

            diff_add: Style::default().fg(Color::Rgb(25, 135, 55)),
            diff_remove: Style::default().fg(Color::Rgb(195, 35, 45)),
            diff_hunk: Style::default()
                .fg(Color::Rgb(0, 110, 155))
                .add_modifier(Modifier::BOLD),
            diff_meta: Style::default()
                .fg(Color::Rgb(100, 110, 125))
                .add_modifier(Modifier::BOLD),
            syn_keyword: Style::default().fg(Color::Rgb(145, 35, 165)),
            syn_string: Style::default().fg(Color::Rgb(30, 130, 55)),
            syn_comment: Style::default()
                .fg(Color::Rgb(110, 120, 135))
                .add_modifier(Modifier::DIM | Modifier::ITALIC),
            syn_number: Style::default().fg(Color::Rgb(165, 95, 0)),
            syn_type: Style::default().fg(Color::Rgb(0, 120, 145)),
            syn_fn: Style::default().fg(Color::Rgb(15, 90, 190)),

            inbox_dir: Style::default()
                .fg(Color::Rgb(0, 105, 150))
                .add_modifier(Modifier::BOLD),
            inbox_idle_new: Style::default()
                .fg(Color::Rgb(20, 140, 60))
                .add_modifier(Modifier::BOLD),
            inbox_idle: Style::default()
                .fg(Color::Rgb(25, 30, 40))
                .add_modifier(Modifier::BOLD),
            inbox_processing: Style::default()
                .fg(Color::Rgb(115, 125, 140))
                .add_modifier(Modifier::DIM),
            inbox_selected: Style::default()
                .bg(Color::Rgb(220, 232, 248))
                .add_modifier(Modifier::BOLD),

            separator: Style::default().add_modifier(Modifier::DIM),
            scroll_badge: Style::default().add_modifier(Modifier::BOLD),
            status_bar: Style::default().add_modifier(Modifier::REVERSED),
        }
    }

    pub fn ansi() -> Self {
        Self {
            name: "ansi".to_string(),
            is_plain: false,

            user_header: Style::default()
                .fg(Color::Blue)
                .add_modifier(Modifier::BOLD),
            user_text: Style::default(),
            assistant_header: Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
            system_header: Style::default()
                .fg(Color::Magenta)
                .add_modifier(Modifier::BOLD),
            thinking_header: Style::default()
                .fg(Color::DarkGray)
                .add_modifier(Modifier::DIM | Modifier::ITALIC),
            thinking_text: Style::default()
                .fg(Color::DarkGray)
                .add_modifier(Modifier::DIM | Modifier::ITALIC),
            compaction_header: Style::default()
                .fg(Color::Magenta)
                .add_modifier(Modifier::BOLD),
            history_marker: Style::default()
                .fg(Color::DarkGray)
                .add_modifier(Modifier::DIM),
            failure_header: Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
            failure_text: Style::default().fg(Color::Red),

            tool_ok: Style::default().fg(Color::Green),
            tool_running: Style::default().fg(Color::Yellow),
            tool_error: Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
            tool_header: Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
            tool_meta: Style::default()
                .fg(Color::DarkGray)
                .add_modifier(Modifier::DIM),
            tool_output: Style::default(),
            shell_header: Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
            queued_header: Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),

            md_h1: Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD | Modifier::UNDERLINED),
            md_h2: Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
            md_h3: Style::default().add_modifier(Modifier::BOLD),
            md_code_inline: Style::default().fg(Color::Yellow),
            md_code_fence: Style::default().add_modifier(Modifier::DIM),
            md_quote_border: Style::default().fg(Color::Cyan).add_modifier(Modifier::DIM),
            md_quote_text: Style::default()
                .fg(Color::Gray)
                .add_modifier(Modifier::ITALIC),
            md_link_text: Style::default()
                .fg(Color::Blue)
                .add_modifier(Modifier::UNDERLINED),
            md_link_url: Style::default().add_modifier(Modifier::DIM),
            md_bullet: Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
            md_hr: Style::default().add_modifier(Modifier::DIM),
            md_bold: Style::default().add_modifier(Modifier::BOLD),
            md_italic: Style::default().add_modifier(Modifier::ITALIC),
            md_strike: Style::default().add_modifier(Modifier::CROSSED_OUT | Modifier::DIM),

            diff_add: Style::default().fg(Color::Green),
            diff_remove: Style::default().fg(Color::Red),
            diff_hunk: Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
            diff_meta: Style::default().add_modifier(Modifier::BOLD),
            syn_keyword: Style::default().fg(Color::Magenta),
            syn_string: Style::default().fg(Color::Green),
            syn_comment: Style::default()
                .fg(Color::DarkGray)
                .add_modifier(Modifier::DIM | Modifier::ITALIC),
            syn_number: Style::default().fg(Color::Yellow),
            syn_type: Style::default().fg(Color::Cyan),
            syn_fn: Style::default().fg(Color::Blue),

            inbox_dir: Style::default()
                .fg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
            inbox_idle_new: Style::default()
                .fg(Color::Green)
                .add_modifier(Modifier::BOLD),
            inbox_idle: Style::default().add_modifier(Modifier::BOLD),
            inbox_processing: Style::default()
                .fg(Color::DarkGray)
                .add_modifier(Modifier::DIM),
            inbox_selected: Style::default().add_modifier(Modifier::REVERSED | Modifier::BOLD),

            separator: Style::default().add_modifier(Modifier::DIM),
            scroll_badge: Style::default().add_modifier(Modifier::BOLD),
            status_bar: Style::default().add_modifier(Modifier::REVERSED),
        }
    }

    pub fn plain() -> Self {
        Self {
            name: "plain".to_string(),
            is_plain: true,

            user_header: Style::default(),
            user_text: Style::default(),
            assistant_header: Style::default(),
            system_header: Style::default(),
            thinking_header: Style::default(),
            thinking_text: Style::default(),
            compaction_header: Style::default(),
            history_marker: Style::default(),
            failure_header: Style::default(),
            failure_text: Style::default(),

            tool_ok: Style::default(),
            tool_running: Style::default(),
            tool_error: Style::default(),
            tool_header: Style::default(),
            tool_meta: Style::default(),
            tool_output: Style::default(),
            shell_header: Style::default(),
            queued_header: Style::default(),

            md_h1: Style::default(),
            md_h2: Style::default(),
            md_h3: Style::default(),
            md_code_inline: Style::default(),
            md_code_fence: Style::default(),
            md_quote_border: Style::default(),
            md_quote_text: Style::default(),
            md_link_text: Style::default(),
            md_link_url: Style::default(),
            md_bullet: Style::default(),
            md_hr: Style::default(),
            md_bold: Style::default(),
            md_italic: Style::default(),
            md_strike: Style::default(),

            diff_add: Style::default(),
            diff_remove: Style::default(),
            diff_hunk: Style::default(),
            diff_meta: Style::default(),
            syn_keyword: Style::default(),
            syn_string: Style::default(),
            syn_comment: Style::default(),
            syn_number: Style::default(),
            syn_type: Style::default(),
            syn_fn: Style::default(),

            inbox_dir: Style::default(),
            inbox_idle_new: Style::default(),
            inbox_idle: Style::default(),
            inbox_processing: Style::default(),
            inbox_selected: Style::default(),

            separator: Style::default(),
            scroll_badge: Style::default(),
            status_bar: Style::default().add_modifier(Modifier::REVERSED),
        }
    }
}

#[derive(Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
struct CustomStyleSpec {
    fg: Option<String>,
    bg: Option<String>,
    bold: Option<bool>,
    dim: Option<bool>,
    italic: Option<bool>,
    underline: Option<bool>,
    underlined: Option<bool>,
    reversed: Option<bool>,
    crossed_out: Option<bool>,
    strike: Option<bool>,
}

impl CustomStyleSpec {
    fn apply(&self, base: Style) -> Result<Style, String> {
        let mut style = base;
        if let Some(fg) = self.fg.as_deref() {
            style = style.fg(parse_color(fg)?);
        }
        if let Some(bg) = self.bg.as_deref() {
            style = style.bg(parse_color(bg)?);
        }
        style = apply_modifier(style, Modifier::BOLD, self.bold);
        style = apply_modifier(style, Modifier::DIM, self.dim);
        style = apply_modifier(style, Modifier::ITALIC, self.italic);
        let underline = self.underline.or(self.underlined);
        style = apply_modifier(style, Modifier::UNDERLINED, underline);
        style = apply_modifier(style, Modifier::REVERSED, self.reversed);
        let strike = self.crossed_out.or(self.strike);
        style = apply_modifier(style, Modifier::CROSSED_OUT, strike);
        Ok(style)
    }
}

fn apply_modifier(style: Style, modifier: Modifier, setting: Option<bool>) -> Style {
    match setting {
        Some(true) => style.add_modifier(modifier),
        Some(false) => style.remove_modifier(modifier),
        None => style,
    }
}

fn parse_color(raw: &str) -> Result<Color, String> {
    let trimmed = raw.trim();
    if let Some(hex) = trimmed.strip_prefix('#') {
        if hex.len() != 6 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(format!("invalid hex color {raw:?}: expected #RRGGBB"));
        }
        let r = u8::from_str_radix(&hex[0..2], 16).map_err(|e| e.to_string())?;
        let g = u8::from_str_radix(&hex[2..4], 16).map_err(|e| e.to_string())?;
        let b = u8::from_str_radix(&hex[4..6], 16).map_err(|e| e.to_string())?;
        return Ok(Color::Rgb(r, g, b));
    }
    match trimmed.to_ascii_lowercase().as_str() {
        "reset" | "default" => Ok(Color::Reset),
        "black" => Ok(Color::Black),
        "red" => Ok(Color::Red),
        "green" => Ok(Color::Green),
        "yellow" => Ok(Color::Yellow),
        "blue" => Ok(Color::Blue),
        "magenta" => Ok(Color::Magenta),
        "cyan" => Ok(Color::Cyan),
        "gray" | "grey" => Ok(Color::Gray),
        "dark_gray" | "dark_grey" | "darkgray" | "darkgrey" => Ok(Color::DarkGray),
        "light_red" | "lightred" => Ok(Color::LightRed),
        "light_green" | "lightgreen" => Ok(Color::LightGreen),
        "light_yellow" | "lightyellow" => Ok(Color::LightYellow),
        "light_blue" | "lightblue" => Ok(Color::LightBlue),
        "light_magenta" | "lightmagenta" => Ok(Color::LightMagenta),
        "light_cyan" | "lightcyan" => Ok(Color::LightCyan),
        "white" => Ok(Color::White),
        _ => Err(format!(
            "invalid color {raw:?}: expected #RRGGBB or named ANSI color"
        )),
    }
}

#[derive(Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
struct CustomThemeSpec {
    #[serde(rename = "$schema")]
    schema: Option<String>,
    base: Option<String>,
    is_plain: Option<bool>,
    user_header: Option<CustomStyleSpec>,
    user_text: Option<CustomStyleSpec>,
    assistant_header: Option<CustomStyleSpec>,
    system_header: Option<CustomStyleSpec>,
    thinking_header: Option<CustomStyleSpec>,
    thinking_text: Option<CustomStyleSpec>,
    compaction_header: Option<CustomStyleSpec>,
    history_marker: Option<CustomStyleSpec>,
    failure_header: Option<CustomStyleSpec>,
    failure_text: Option<CustomStyleSpec>,
    tool_ok: Option<CustomStyleSpec>,
    tool_running: Option<CustomStyleSpec>,
    tool_error: Option<CustomStyleSpec>,
    tool_header: Option<CustomStyleSpec>,
    tool_meta: Option<CustomStyleSpec>,
    tool_output: Option<CustomStyleSpec>,
    shell_header: Option<CustomStyleSpec>,
    queued_header: Option<CustomStyleSpec>,
    md_h1: Option<CustomStyleSpec>,
    md_h2: Option<CustomStyleSpec>,
    md_h3: Option<CustomStyleSpec>,
    md_code_inline: Option<CustomStyleSpec>,
    md_code_fence: Option<CustomStyleSpec>,
    md_quote_border: Option<CustomStyleSpec>,
    md_quote_text: Option<CustomStyleSpec>,
    md_link_text: Option<CustomStyleSpec>,
    md_link_url: Option<CustomStyleSpec>,
    md_bullet: Option<CustomStyleSpec>,
    md_hr: Option<CustomStyleSpec>,
    md_bold: Option<CustomStyleSpec>,
    md_italic: Option<CustomStyleSpec>,
    md_strike: Option<CustomStyleSpec>,
    diff_add: Option<CustomStyleSpec>,
    diff_remove: Option<CustomStyleSpec>,
    diff_hunk: Option<CustomStyleSpec>,
    diff_meta: Option<CustomStyleSpec>,
    syn_keyword: Option<CustomStyleSpec>,
    syn_string: Option<CustomStyleSpec>,
    syn_comment: Option<CustomStyleSpec>,
    syn_number: Option<CustomStyleSpec>,
    syn_type: Option<CustomStyleSpec>,
    syn_fn: Option<CustomStyleSpec>,
    inbox_dir: Option<CustomStyleSpec>,
    inbox_idle_new: Option<CustomStyleSpec>,
    inbox_idle: Option<CustomStyleSpec>,
    inbox_processing: Option<CustomStyleSpec>,
    inbox_selected: Option<CustomStyleSpec>,
    separator: Option<CustomStyleSpec>,
    scroll_badge: Option<CustomStyleSpec>,
    status_bar: Option<CustomStyleSpec>,
}

impl CustomThemeSpec {
    fn into_theme(self, name: &str) -> Result<Theme, String> {
        let mut theme = match self.base.as_deref().unwrap_or("dark") {
            "dark" => Theme::dark(),
            "light" => Theme::light(),
            "ansi" => Theme::ansi(),
            "plain" => Theme::plain(),
            other => {
                return Err(format!(
                    "invalid base theme {other:?}: expected \"dark\", \"light\", \"ansi\", or \"plain\""
                ))
            }
        };
        theme.name = name.to_string();
        if let Some(is_plain) = self.is_plain {
            theme.is_plain = is_plain;
        }
        macro_rules! apply_fields {
            ($($field:ident),+ $(,)?) => {
                $(
                    if let Some(spec) = self.$field {
                        theme.$field = spec
                            .apply(theme.$field)
                            .map_err(|e| format!("{}: {e}", stringify!($field)))?;
                    }
                )+
            };
        }
        apply_fields!(
            user_header,
            user_text,
            assistant_header,
            system_header,
            thinking_header,
            thinking_text,
            compaction_header,
            history_marker,
            failure_header,
            failure_text,
            tool_ok,
            tool_running,
            tool_error,
            tool_header,
            tool_meta,
            tool_output,
            shell_header,
            queued_header,
            md_h1,
            md_h2,
            md_h3,
            md_code_inline,
            md_code_fence,
            md_quote_border,
            md_quote_text,
            md_link_text,
            md_link_url,
            md_bullet,
            md_hr,
            md_bold,
            md_italic,
            md_strike,
            diff_add,
            diff_remove,
            diff_hunk,
            diff_meta,
            syn_keyword,
            syn_string,
            syn_comment,
            syn_number,
            syn_type,
            syn_fn,
            inbox_dir,
            inbox_idle_new,
            inbox_idle,
            inbox_processing,
            inbox_selected,
            separator,
            scroll_badge,
            status_bar,
        );
        Ok(theme)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_builtin_themes_and_rejects_invalid_names() {
        assert_eq!(Theme::from_name("dark").unwrap().name, "dark");
        assert_eq!(Theme::from_name("light").unwrap().name, "light");
        assert_eq!(Theme::from_name("ansi").unwrap().name, "ansi");
        let plain = Theme::from_name("plain").unwrap();
        assert_eq!(plain.name, "plain");
        assert!(plain.is_plain);

        let err = Theme::from_name("neon").unwrap_err();
        assert!(err.contains("unknown theme"));
    }

    #[test]
    fn no_color_selects_plain_only_when_theme_not_explicitly_set() {
        assert_eq!(
            Theme::resolve_with_no_color(None, false).unwrap().name,
            "dark"
        );
        assert_eq!(
            Theme::resolve_with_no_color(None, true).unwrap().name,
            "plain"
        );
        assert_eq!(
            Theme::resolve_with_no_color(Some("light"), true)
                .unwrap()
                .name,
            "light"
        );
        assert_eq!(
            Theme::resolve_with_no_color(Some("ansi"), true)
                .unwrap()
                .name,
            "ansi"
        );
    }

    #[test]
    fn plain_theme_has_no_colors_on_any_transcript_token() {
        let plain = Theme::plain();
        for style in [
            plain.user_header,
            plain.user_text,
            plain.assistant_header,
            plain.system_header,
            plain.thinking_header,
            plain.thinking_text,
            plain.compaction_header,
            plain.tool_ok,
            plain.tool_running,
            plain.tool_error,
            plain.tool_header,
            plain.tool_meta,
            plain.shell_header,
            plain.queued_header,
            plain.md_h1,
            plain.md_h2,
            plain.md_h3,
            plain.md_code_inline,
            plain.md_code_fence,
            plain.md_quote_border,
            plain.md_quote_text,
            plain.md_link_text,
            plain.md_link_url,
            plain.md_bullet,
            plain.md_hr,
            plain.diff_add,
            plain.diff_remove,
            plain.diff_hunk,
            plain.syn_keyword,
            plain.syn_string,
            plain.syn_comment,
            plain.syn_number,
            plain.syn_type,
            plain.syn_fn,
        ] {
            assert_eq!(style, Style::default());
        }
    }

    #[test]
    fn custom_json_theme_validates_names_colors_bases_and_available_discovery() {
        use std::time::{SystemTime, UNIX_EPOCH};

        assert!(Theme::is_valid_custom_name("nord"));
        assert!(Theme::is_valid_custom_name("my_theme-1"));
        assert!(!Theme::is_valid_custom_name("../evil"));
        assert!(!Theme::is_valid_custom_name("BadCase"));
        assert!(!Theme::is_valid_custom_name("-dash"));

        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let data_dir = std::env::temp_dir().join(format!("hi_theme_test_{nanos}"));
        let themes_dir = data_dir.join("themes");
        fs::create_dir_all(&themes_dir).unwrap();

        fs::write(
            themes_dir.join("ocean.json"),
            r##"{
                "base": "light",
                "user_header": { "fg": "#112233", "bg": "cyan", "bold": true, "italic": true },
                "status_bar": { "reversed": false }
            }"##,
        )
        .unwrap();
        // Ignored entries: built-in shadow, invalid name, oversized file, non-json
        fs::write(themes_dir.join("dark.json"), "{}").unwrap();
        fs::write(themes_dir.join("BadName.json"), "{}").unwrap();
        fs::write(themes_dir.join("readme.txt"), "hi").unwrap();
        fs::write(themes_dir.join("huge.json"), "x".repeat(65_537)).unwrap();

        let available = Theme::available_themes(&data_dir);
        assert_eq!(available, vec!["dark", "light", "ansi", "plain", "ocean"]);

        let ocean = Theme::resolve_with_no_color_in_dir(Some("ocean"), true, Some(&data_dir))
            .expect("custom theme loads");
        assert_eq!(ocean.name, "ocean");
        assert!(!ocean.is_plain);
        assert_eq!(
            ocean.user_header,
            Style::default()
                .fg(Color::Rgb(17, 34, 51))
                .bg(Color::Cyan)
                .add_modifier(Modifier::BOLD | Modifier::ITALIC)
        );
        assert_eq!(
            ocean.status_bar,
            Style::default().remove_modifier(Modifier::REVERSED)
        );

        // Rejects unknown fields, bad hex, bad base, oversized files
        fs::write(themes_dir.join("bad_field.json"), r#"{ "nope": 1 }"#).unwrap();
        assert!(Theme::from_name_in_dir("bad_field", Some(&data_dir)).is_err());

        fs::write(
            themes_dir.join("bad_hex.json"),
            r##"{ "user_header": { "fg": "#12345" } }"##,
        )
        .unwrap();
        assert!(Theme::from_name_in_dir("bad_hex", Some(&data_dir)).is_err());

        fs::write(themes_dir.join("bad_base.json"), r#"{ "base": "neon" }"#).unwrap();
        assert!(Theme::from_name_in_dir("bad_base", Some(&data_dir)).is_err());

        assert!(Theme::from_name_in_dir("huge", Some(&data_dir))
            .unwrap_err()
            .contains("65536"));

        let _ = fs::remove_dir_all(&data_dir);
    }
}
