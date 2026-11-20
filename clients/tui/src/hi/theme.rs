use ratatui::style::{Color, Modifier, Style};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Theme {
    pub name: &'static str,
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

    pub fn resolve(configured: Option<&str>) -> Result<Self, String> {
        let no_color = std::env::var_os("NO_COLOR").is_some_and(|v| !v.is_empty());
        Self::resolve_with_no_color(configured, no_color)
    }

    pub fn resolve_with_no_color(configured: Option<&str>, no_color: bool) -> Result<Self, String> {
        match configured {
            Some(name) => Self::from_name(name),
            None if no_color => Ok(Self::plain()),
            None => Ok(Self::dark()),
        }
    }

    pub fn dark() -> Self {
        Self {
            name: "dark",
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
            name: "light",
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
            name: "ansi",
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
            name: "plain",
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
}
