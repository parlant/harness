//! Deliberately separate from the conversation editor and its history/clipboard.
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

pub(super) struct SecretInput {
    pub provider: String,
    pub source: String,
    value: String,
}

impl SecretInput {
    pub fn new(provider: &str, source: &str) -> Self {
        Self {
            provider: provider.into(),
            source: source.into(),
            value: String::new(),
        }
    }

    pub fn paste(&mut self, value: &str) {
        if self.value.len() + value.len() <= 2048
            && value.bytes().all(|b| (b'!'..=b'~').contains(&b))
        {
            self.value.push_str(value);
        }
    }

    pub fn key(&mut self, key: KeyEvent) -> bool {
        match key.code {
            KeyCode::Backspace => {
                self.value.pop();
            }
            KeyCode::Char(ch)
                if !key.modifiers.intersects(
                    KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER,
                ) && ch.is_ascii_graphic()
                    && self.value.len() < 2048 =>
            {
                self.value.push(ch)
            }
            KeyCode::Enter if !self.value.is_empty() => return true,
            _ => (),
        }
        false
    }

    pub fn take(&mut self) -> String {
        std::mem::take(&mut self.value)
    }

    pub fn lines(&self) -> Vec<String> {
        vec![
            format!("Save {} API key as {}", self.provider, self.source),
            format!("Key: {}", "*".repeat(self.value.len().min(40))),
            "Enter saves · Esc cancels · not sent to the conversation".into(),
        ]
    }
}
