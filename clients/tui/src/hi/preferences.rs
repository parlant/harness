use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ActionSpec {
    name: &'static str,
    defaults: &'static [&'static str],
    description: &'static str,
}

const ACTION_SPECS: &[ActionSpec] = &[
    ActionSpec {
        name: "interrupt",
        defaults: &["escape"],
        description: "Cancel or abort",
    },
    ActionSpec {
        name: "clear",
        defaults: &["ctrl+c"],
        description: "Clear editor",
    },
    ActionSpec {
        name: "exit",
        defaults: &["ctrl+d"],
        description: "Exit when editor is empty",
    },
    ActionSpec {
        name: "external",
        defaults: &["ctrl+g"],
        description: "Open external editor",
    },
    ActionSpec {
        name: "model",
        defaults: &["ctrl+l"],
        description: "Open model selector",
    },
    ActionSpec {
        name: "tools",
        defaults: &["ctrl+o"],
        description: "Toggle tool output",
    },
    ActionSpec {
        name: "thinking",
        defaults: &["ctrl+t"],
        description: "Toggle thinking blocks",
    },
    ActionSpec {
        name: "follow_up",
        defaults: &["alt+enter"],
        description: "Queue follow-up message",
    },
    ActionSpec {
        name: "dequeue",
        defaults: &["alt+up"],
        description: "Restore queued messages",
    },
    ActionSpec {
        name: "submit",
        defaults: &["enter"],
        description: "Submit input",
    },
    ActionSpec {
        name: "palette",
        defaults: &["/"],
        description: "Open slash command palette",
    },
    ActionSpec {
        name: "search",
        defaults: &["ctrl+shift+f"],
        description: "Search transcript",
    },
    ActionSpec {
        name: "suspend",
        defaults: &["ctrl+z"],
        description: "Suspend to background",
    },
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct KeyCombo {
    code: KeyCode,
    modifiers: KeyModifiers,
}

impl KeyCombo {
    fn from_event(event: KeyEvent) -> Option<Self> {
        if event.kind == KeyEventKind::Release {
            return None;
        }
        Some(Self::normalize(event.code, event.modifiers))
    }

    fn normalize(code: KeyCode, mut modifiers: KeyModifiers) -> Self {
        let code = match code {
            KeyCode::BackTab => {
                modifiers.insert(KeyModifiers::SHIFT);
                KeyCode::Tab
            }
            KeyCode::Null => {
                modifiers.insert(KeyModifiers::CONTROL);
                KeyCode::Char(' ')
            }
            KeyCode::Char(c) if c.is_ascii_uppercase() => {
                modifiers.insert(KeyModifiers::SHIFT);
                KeyCode::Char(c.to_ascii_lowercase())
            }
            other => other,
        };
        Self { code, modifiers }
    }

    fn parse(raw: &str) -> Result<Self, String> {
        if raw.is_empty() {
            return Err("keybinding cannot be empty".to_string());
        }
        if raw.chars().any(char::is_whitespace) {
            return Err(format!(
                "invalid keybinding {raw:?}: whitespace is not allowed"
            ));
        }

        let lower = raw.to_ascii_lowercase();
        let mut rest = lower.as_str();
        let mut modifiers = KeyModifiers::NONE;

        loop {
            let next = if let Some(after) = rest.strip_prefix("ctrl+") {
                Some((KeyModifiers::CONTROL, "ctrl", after))
            } else if let Some(after) = rest.strip_prefix("shift+") {
                Some((KeyModifiers::SHIFT, "shift", after))
            } else if let Some(after) = rest.strip_prefix("alt+") {
                Some((KeyModifiers::ALT, "alt", after))
            } else {
                rest.strip_prefix("super+")
                    .map(|after| (KeyModifiers::SUPER, "super", after))
            };

            let Some((flag, name, after)) = next else {
                break;
            };
            if modifiers.contains(flag) {
                return Err(format!("duplicate modifier {name:?} in {raw:?}"));
            }
            modifiers.insert(flag);
            rest = after;
        }

        if rest.is_empty() {
            return Err(format!("missing base key in {raw:?}"));
        }
        if rest.contains('+') && rest != "+" {
            return Err(format!("invalid modifier or key in {raw:?}"));
        }

        let code = match rest {
            "escape" | "esc" => KeyCode::Esc,
            "enter" | "return" => KeyCode::Enter,
            "tab" => KeyCode::Tab,
            "backtab" => {
                modifiers.insert(KeyModifiers::SHIFT);
                KeyCode::Tab
            }
            "space" => KeyCode::Char(' '),
            "backspace" => KeyCode::Backspace,
            "delete" | "del" => KeyCode::Delete,
            "insert" | "ins" => KeyCode::Insert,
            "home" => KeyCode::Home,
            "end" => KeyCode::End,
            "pageup" => KeyCode::PageUp,
            "pagedown" => KeyCode::PageDown,
            "up" => KeyCode::Up,
            "down" => KeyCode::Down,
            "left" => KeyCode::Left,
            "right" => KeyCode::Right,
            "f1" => KeyCode::F(1),
            "f2" => KeyCode::F(2),
            "f3" => KeyCode::F(3),
            "f4" => KeyCode::F(4),
            "f5" => KeyCode::F(5),
            "f6" => KeyCode::F(6),
            "f7" => KeyCode::F(7),
            "f8" => KeyCode::F(8),
            "f9" => KeyCode::F(9),
            "f10" => KeyCode::F(10),
            "f11" => KeyCode::F(11),
            "f12" => KeyCode::F(12),
            s if s.len() == 1 => {
                let ch = s.chars().next().expect("checked len == 1");
                if is_valid_char_key(ch) {
                    KeyCode::Char(ch)
                } else {
                    return Err(format!("unsupported key {raw:?}"));
                }
            }
            _ => return Err(format!("unknown key {raw:?}")),
        };

        Ok(Self::normalize(code, modifiers))
    }

    fn display(&self) -> String {
        let mut parts = Vec::new();
        if self.modifiers.contains(KeyModifiers::CONTROL) {
            parts.push("ctrl");
        }
        if self.modifiers.contains(KeyModifiers::SHIFT) {
            parts.push("shift");
        }
        if self.modifiers.contains(KeyModifiers::ALT) {
            parts.push("alt");
        }
        if self.modifiers.contains(KeyModifiers::SUPER) {
            parts.push("super");
        }

        let base = match self.code {
            KeyCode::Esc => "escape".to_string(),
            KeyCode::Enter => "enter".to_string(),
            KeyCode::Tab => "tab".to_string(),
            KeyCode::BackTab => "tab".to_string(),
            KeyCode::Backspace => "backspace".to_string(),
            KeyCode::Delete => "delete".to_string(),
            KeyCode::Insert => "insert".to_string(),
            KeyCode::Home => "home".to_string(),
            KeyCode::End => "end".to_string(),
            KeyCode::PageUp => "pageUp".to_string(),
            KeyCode::PageDown => "pageDown".to_string(),
            KeyCode::Up => "up".to_string(),
            KeyCode::Down => "down".to_string(),
            KeyCode::Left => "left".to_string(),
            KeyCode::Right => "right".to_string(),
            KeyCode::F(n) => format!("f{n}"),
            KeyCode::Char(' ') => "space".to_string(),
            KeyCode::Char(c) => c.to_string(),
            other => format!("{other:?}"),
        };

        if parts.is_empty() {
            base
        } else {
            format!("{}+{base}", parts.join("+"))
        }
    }
}

fn is_valid_char_key(ch: char) -> bool {
    ch.is_ascii_lowercase()
        || ch.is_ascii_digit()
        || matches!(
            ch,
            '`' | '-'
                | '='
                | '['
                | ']'
                | '\\'
                | ';'
                | '\''
                | ','
                | '.'
                | '/'
                | '!'
                | '@'
                | '#'
                | '$'
                | '%'
                | '^'
                | '&'
                | '*'
                | '('
                | ')'
                | '_'
                | '+'
                | '|'
                | '~'
                | '{'
                | '}'
                | ':'
                | '<'
                | '>'
                | '?'
        )
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ActionBinding {
    action: &'static str,
    description: &'static str,
    keys: Vec<KeyCombo>,
}

/// User-configurable keybindings for `hi` actions.
///
/// Conditional editor behavior (such as `Ctrl+D` deleting when the draft is non-empty,
/// `Ctrl+C` clearing before exiting, `Esc` closing an overlay before interrupting,
/// `Enter` confirming completions, and `/` starting a command when at an empty prompt)
/// is resolved by the application around these action mappings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Preferences {
    bindings: Vec<ActionBinding>,
    lookup: HashMap<KeyCombo, &'static str>,
}

impl Default for Preferences {
    fn default() -> Self {
        Self::from_overrides(&HashMap::new()).expect("default keybindings must be valid")
    }
}

impl Preferences {
    /// Load user keybinding preferences from a JSON file.
    ///
    /// Missing files fall back to [`Preferences::default()`].
    /// Malformed JSON, unknown actions, invalid key syntax, or keybinding conflicts
    /// return `Err`, allowing callers to retain their previous configuration.
    pub fn load(path: &Path) -> Result<Self, String> {
        let raw = match fs::read_to_string(path) {
            Ok(contents) => contents,
            Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(err) => {
                return Err(format!(
                    "failed to read keybindings from {}: {err}",
                    path.display()
                ));
            }
        };

        let trimmed = raw.strip_prefix('\u{feff}').unwrap_or(&raw);
        let parsed: Value = serde_json::from_str(trimmed)
            .map_err(|err| format!("invalid keybindings JSON in {}: {err}", path.display()))?;

        Self::from_json_value(&parsed)
    }

    /// Return the action name bound to `key`, if any.
    pub fn action(&self, key: KeyEvent) -> Option<&str> {
        let combo = KeyCombo::from_event(key)?;
        self.lookup.get(&combo).copied()
    }

    /// Return formatted help lines describing the active keybindings.
    pub fn help(&self) -> Vec<String> {
        self.bindings
            .iter()
            .map(|binding| {
                let keys = if binding.keys.is_empty() {
                    "(unbound)".to_string()
                } else {
                    binding
                        .keys
                        .iter()
                        .map(KeyCombo::display)
                        .collect::<Vec<_>>()
                        .join(", ")
                };
                format!("{keys:<14} {:<10} {}", binding.action, binding.description)
            })
            .collect()
    }

    fn from_json_value(value: &Value) -> Result<Self, String> {
        let obj = value
            .as_object()
            .ok_or_else(|| "keybindings config must be a JSON object".to_string())?;

        let mut overrides = HashMap::new();
        for (key, val) in obj {
            if key == "$schema" {
                if !val.is_string() {
                    return Err("\"$schema\" must be a string".to_string());
                }
                continue;
            }

            let spec = ACTION_SPECS
                .iter()
                .find(|spec| spec.name == key)
                .ok_or_else(|| format!("unknown action {key:?}"))?;

            let combos = parse_binding_value(spec.name, val)?;
            overrides.insert(spec.name, combos);
        }

        Self::from_overrides(&overrides)
    }

    fn from_overrides(overrides: &HashMap<&'static str, Vec<KeyCombo>>) -> Result<Self, String> {
        let mut bindings = Vec::with_capacity(ACTION_SPECS.len());
        let mut lookup = HashMap::new();

        for spec in ACTION_SPECS {
            let keys = match overrides.get(spec.name) {
                Some(custom) => custom.clone(),
                None => spec
                    .defaults
                    .iter()
                    .map(|raw| KeyCombo::parse(raw))
                    .collect::<Result<Vec<_>, _>>()?,
            };

            let mut deduped = Vec::with_capacity(keys.len());
            let mut seen_for_action = HashSet::new();
            for combo in keys {
                if !seen_for_action.insert(combo) {
                    continue;
                }
                if let Some(existing) = lookup.insert(combo, spec.name) {
                    return Err(format!(
                        "keybinding conflict for {}: bound to both {existing:?} and {:?}",
                        combo.display(),
                        spec.name
                    ));
                }
                deduped.push(combo);
            }

            bindings.push(ActionBinding {
                action: spec.name,
                description: spec.description,
                keys: deduped,
            });
        }

        Ok(Self { bindings, lookup })
    }
}

fn parse_binding_value(action: &str, value: &Value) -> Result<Vec<KeyCombo>, String> {
    match value {
        Value::Null => Ok(Vec::new()),
        Value::String(s) => {
            Ok(vec![KeyCombo::parse(s).map_err(|err| {
                format!("invalid binding for {action:?}: {err}")
            })?])
        }
        Value::Array(items) => {
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                let s = item.as_str().ok_or_else(|| {
                    format!("invalid binding for {action:?}: array entries must be strings")
                })?;
                let combo = KeyCombo::parse(s)
                    .map_err(|err| format!("invalid binding for {action:?}: {err}"))?;
                out.push(combo);
            }
            Ok(out)
        }
        _ => Err(format!(
            "invalid binding for {action:?}: expected key string, array of key strings, or null"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::KeyEventState;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TempFile {
        path: std::path::PathBuf,
    }

    impl TempFile {
        fn new(name: &str) -> Self {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock after epoch")
                .as_nanos();
            let dir = std::env::temp_dir().join(format!(
                "hi_preferences_test_{}_{}_{}",
                std::process::id(),
                nanos,
                name
            ));
            fs::create_dir_all(&dir).expect("create temp dir");
            Self {
                path: dir.join("keybindings.json"),
            }
        }

        fn write(&self, contents: &str) {
            fs::write(&self.path, contents).expect("write temp config");
        }
    }

    impl Drop for TempFile {
        fn drop(&mut self) {
            if let Some(parent) = self.path.parent() {
                let _ = fs::remove_dir_all(parent);
            }
        }
    }

    fn key(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, modifiers)
    }

    #[test]
    fn default_bindings_match_expected_actions() {
        let prefs = Preferences::default();

        assert_eq!(
            prefs.action(key(KeyCode::Esc, KeyModifiers::NONE)),
            Some("interrupt")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('c'), KeyModifiers::CONTROL)),
            Some("clear")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('d'), KeyModifiers::CONTROL)),
            Some("exit")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('g'), KeyModifiers::CONTROL)),
            Some("external")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('l'), KeyModifiers::CONTROL)),
            Some("model")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('o'), KeyModifiers::CONTROL)),
            Some("tools")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('t'), KeyModifiers::CONTROL)),
            Some("thinking")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Enter, KeyModifiers::ALT)),
            Some("follow_up")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Up, KeyModifiers::ALT)),
            Some("dequeue")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Enter, KeyModifiers::NONE)),
            Some("submit")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('/'), KeyModifiers::NONE)),
            Some("palette")
        );
        assert_eq!(
            prefs.action(key(
                KeyCode::Char('f'),
                KeyModifiers::CONTROL | KeyModifiers::SHIFT
            )),
            Some("search")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('F'), KeyModifiers::CONTROL)),
            Some("search")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('z'), KeyModifiers::CONTROL)),
            Some("suspend")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('a'), KeyModifiers::NONE)),
            None
        );

        let release =
            KeyEvent::new_with_kind(KeyCode::Esc, KeyModifiers::NONE, KeyEventKind::Release);
        assert_eq!(prefs.action(release), None);

        let with_caps = KeyEvent::new_with_kind_and_state(
            KeyCode::Char('c'),
            KeyModifiers::CONTROL,
            KeyEventKind::Press,
            KeyEventState::CAPS_LOCK,
        );
        assert_eq!(prefs.action(with_caps), Some("clear"));
    }

    #[test]
    fn missing_file_loads_defaults() {
        let temp = TempFile::new("missing");
        let prefs = Preferences::load(&temp.path).expect("missing file should yield defaults");
        assert_eq!(prefs, Preferences::default());
    }

    #[test]
    fn loads_overrides_aliases_and_normalizes_shift_tab() {
        let temp = TempFile::new("overrides");
        temp.write(
            "\u{feff}{\n\
              \"$schema\": \"https://pi.dev/schemas/keybindings.schema.json\",\n\
              \"interrupt\": [\"ctrl+q\", \"esc\", \"escape\"],\n\
              \"thinking\": \"shift+tab\",\n\
              \"search\": \"shift+ctrl+s\",\n\
              \"submit\": \"return\"\n\
            }",
        );

        let prefs = Preferences::load(&temp.path).expect("valid overrides should load");
        assert_eq!(
            prefs.action(key(KeyCode::Char('q'), KeyModifiers::CONTROL)),
            Some("interrupt")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Esc, KeyModifiers::NONE)),
            Some("interrupt")
        );
        assert_eq!(
            prefs.action(key(KeyCode::BackTab, KeyModifiers::SHIFT)),
            Some("thinking")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Tab, KeyModifiers::SHIFT)),
            Some("thinking")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('t'), KeyModifiers::CONTROL)),
            None
        );
        assert_eq!(
            prefs.action(key(
                KeyCode::Char('s'),
                KeyModifiers::CONTROL | KeyModifiers::SHIFT
            )),
            Some("search")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Enter, KeyModifiers::NONE)),
            Some("submit")
        );
    }

    #[test]
    fn null_and_empty_array_unbind_actions_and_free_keys() {
        let temp = TempFile::new("unbind");
        temp.write(
            r#"{
                "suspend": null,
                "tools": [],
                "model": "ctrl+z"
            }"#,
        );

        let prefs = Preferences::load(&temp.path).expect("null/empty unbinding should succeed");
        assert_eq!(
            prefs.action(key(KeyCode::Char('z'), KeyModifiers::CONTROL)),
            Some("model")
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('o'), KeyModifiers::CONTROL)),
            None
        );
        assert_eq!(
            prefs.action(key(KeyCode::Char('l'), KeyModifiers::CONTROL)),
            None
        );

        let help = prefs.help();
        assert!(help
            .iter()
            .any(|line| line.contains("(unbound)") && line.contains("suspend")));
        assert!(help
            .iter()
            .any(|line| line.contains("(unbound)") && line.contains("tools")));
    }

    #[test]
    fn rejects_conflicting_bindings() {
        let temp = TempFile::new("conflict");

        // Conflicts with default `clear` (`ctrl+c`)
        temp.write(r#"{ "interrupt": "ctrl+c" }"#);
        let err = Preferences::load(&temp.path).expect_err("conflict with default must fail");
        assert!(err.contains("conflict"), "unexpected error: {err}");

        // Conflicts between two user entries using aliases
        temp.write(r#"{ "interrupt": "esc", "clear": "escape" }"#);
        let err = Preferences::load(&temp.path).expect_err("alias conflict must fail");
        assert!(err.contains("conflict"), "unexpected error: {err}");

        // Conflicts with modifier order normalization against default `search` (`ctrl+shift+f`)
        temp.write(r#"{ "model": "shift+ctrl+f" }"#);
        let err = Preferences::load(&temp.path).expect_err("modifier order conflict must fail");
        assert!(err.contains("conflict"), "unexpected error: {err}");
    }

    #[test]
    fn rejects_invalid_configs() {
        let temp = TempFile::new("invalid");

        let invalid_cases = [
            "{not json",
            "[]",
            "\"escape\"",
            r#"{ "$schema": 123 }"#,
            r#"{ "unknown_action": "ctrl+a" }"#,
            r#"{ "interrupt": 42 }"#,
            r#"{ "interrupt": ["escape", 99] }"#,
            r#"{ "interrupt": "" }"#,
            r#"{ "interrupt": [""] }"#,
            r#"{ "interrupt": "ctrl+" }"#,
            r#"{ "interrupt": "ctrl+ctrl+a" }"#,
            r#"{ "interrupt": "meta+a" }"#,
            r#"{ "interrupt": "ctrl+bogus" }"#,
            r#"{ "interrupt": "f13" }"#,
            r#"{ "interrupt": "ctrl + c" }"#,
        ];

        for raw in invalid_cases {
            temp.write(raw);
            assert!(
                Preferences::load(&temp.path).is_err(),
                "expected invalid config to fail: {raw}"
            );
        }

        let dir_err = Preferences::load(temp.path.parent().expect("temp dir"));
        assert!(dir_err.is_err(), "reading a directory should return Err");
    }

    #[test]
    fn reload_rollback_preserves_previous_valid_preferences() {
        let temp = TempFile::new("rollback");
        temp.write(r#"{ "interrupt": "ctrl+q" }"#);

        let mut active = Preferences::load(&temp.path).expect("initial load");
        let snapshot = active.clone();

        // Failed reload (invalid syntax) -> caller keeps `active`
        temp.write("{broken");
        if let Ok(next) = Preferences::load(&temp.path) {
            active = next;
        }
        assert_eq!(active, snapshot);
        assert_eq!(
            active.action(key(KeyCode::Char('q'), KeyModifiers::CONTROL)),
            Some("interrupt")
        );
        assert_eq!(active.action(key(KeyCode::Esc, KeyModifiers::NONE)), None);

        // Failed reload (conflict) -> caller keeps `active`
        temp.write(r#"{ "interrupt": "ctrl+c" }"#);
        let reload_err = Preferences::load(&temp.path);
        assert!(reload_err.is_err());
        if let Ok(next) = reload_err {
            active = next;
        }
        assert_eq!(active, snapshot);

        // Subsequent valid reload applies cleanly
        temp.write(r#"{ "interrupt": "f5", "clear": "ctrl+x" }"#);
        active = Preferences::load(&temp.path).expect("valid reload");
        assert_eq!(
            active.action(key(KeyCode::F(5), KeyModifiers::NONE)),
            Some("interrupt")
        );
        assert_eq!(
            active.action(key(KeyCode::Char('x'), KeyModifiers::CONTROL)),
            Some("clear")
        );
    }

    #[test]
    fn help_lists_all_actions_and_reflects_overrides() {
        let default_help = Preferences::default().help();
        assert_eq!(default_help.len(), ACTION_SPECS.len());
        assert!(default_help
            .iter()
            .any(|line| line.contains("escape") && line.contains("interrupt")));
        assert!(default_help
            .iter()
            .any(|line| line.contains("ctrl+shift+f") && line.contains("search")));
        assert!(default_help
            .iter()
            .any(|line| line.contains("/") && line.contains("palette")));

        let temp = TempFile::new("help");
        temp.write(r#"{ "interrupt": ["ctrl+q", "f1"], "suspend": null }"#);
        let custom_help = Preferences::load(&temp.path).expect("load custom").help();
        assert_eq!(custom_help.len(), ACTION_SPECS.len());
        assert!(custom_help
            .iter()
            .any(|line| line.contains("ctrl+q, f1") && line.contains("interrupt")));
        assert!(custom_help
            .iter()
            .any(|line| line.contains("(unbound)") && line.contains("suspend")));
    }
}
