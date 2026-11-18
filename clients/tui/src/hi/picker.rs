use crate::render::sanitize_single_line;
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use unicode_segmentation::UnicodeSegmentation;

// One search row plus six choices fits the seven-row inline picker.
const DEFAULT_MAX_VISIBLE: usize = 6;

/// Outcome of handling a key event inside [`Picker`].
///
/// The picker never escapes focus back to the draft editor: unhandled keys
/// return [`Choice::Stay`], cancellation returns [`Choice::Cancel`], and
/// confirming a highlighted item returns [`Choice::Pick`] with its ID.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Choice {
    Stay,
    Cancel,
    Pick(String),
}

#[derive(Debug, Clone)]
struct PickerItem {
    id: String,
    label: String,
    id_lower: Vec<char>,
    label_lower: Vec<char>,
    combined_lower: Vec<char>,
}

impl PickerItem {
    fn new(id: String, label: String) -> Self {
        let id_lower: Vec<char> = id.to_lowercase().chars().collect();
        let label_lower: Vec<char> = label.to_lowercase().chars().collect();
        let combined_lower: Vec<char> = if id.is_empty() {
            label_lower.clone()
        } else if label.is_empty() {
            id_lower.clone()
        } else {
            let mut combined = Vec::with_capacity(id_lower.len() + 1 + label_lower.len());
            combined.extend_from_slice(&id_lower);
            combined.push(' ');
            combined.extend_from_slice(&label_lower);
            combined
        };

        Self {
            id,
            label,
            id_lower,
            label_lower,
            combined_lower,
        }
    }

    fn display_text(&self) -> String {
        let clean_id = sanitize_single_line(&self.id);
        let clean_label = sanitize_single_line(&self.label);
        if clean_label.is_empty() {
            clean_id
        } else if clean_id.is_empty() || clean_label == clean_id || clean_label.contains(&clean_id)
        {
            clean_label
        } else {
            format!("{clean_label} ({clean_id})")
        }
    }
}

/// Searchable, keyboard-first selector overlay reusable for models, sessions,
/// branches, and slash commands.
#[derive(Debug, Clone)]
pub struct Picker {
    title: String,
    items: Vec<PickerItem>,
    filtered: Vec<usize>,
    selected: usize,
    query: String,
    cursor: usize,
    max_visible: usize,
}

impl Picker {
    /// Creates a new picker from `(id, label)` pairs.
    pub fn new(title: &str, choices: Vec<(String, String)>) -> Self {
        let items: Vec<PickerItem> = choices
            .into_iter()
            .map(|(id, label)| PickerItem::new(id, label))
            .collect();
        let filtered: Vec<usize> = (0..items.len()).collect();

        Self {
            title: title.to_string(),
            items,
            filtered,
            selected: 0,
            query: String::new(),
            cursor: 0,
            max_visible: DEFAULT_MAX_VISIBLE,
        }
    }

    /// Preselects the choice matching `id` if present in the current list.
    pub fn with_selected(mut self, id: &str) -> Self {
        if let Some(pos) = self
            .filtered
            .iter()
            .position(|&idx| self.items[idx].id == id)
        {
            self.selected = pos;
        }
        self
    }

    /// Sets the maximum number of visible rows (clamped to at least 1).
    pub fn set_max_visible(&mut self, max_visible: usize) {
        self.max_visible = max_visible.clamp(1, DEFAULT_MAX_VISIBLE);
    }

    /// Returns the currently highlighted choice ID, if any match exists.
    pub fn selected_id(&self) -> Option<&str> {
        self.filtered
            .get(self.selected)
            .map(|&idx| self.items[idx].id.as_str())
    }

    /// Returns the current search query string.
    pub fn query(&self) -> &str {
        &self.query
    }

    /// Returns the number of items matching the current query.
    pub fn filtered_len(&self) -> usize {
        self.filtered.len()
    }

    /// Returns the total number of items in this picker.
    pub fn total_len(&self) -> usize {
        self.items.len()
    }

    /// Renders the picker into sanitized, ANSI-free lines suitable for overlay display.
    pub fn lines(&self) -> Vec<String> {
        let mut out = Vec::new();
        let clean_title = sanitize_single_line(&self.title);
        let clean_query = sanitize_single_line(&self.query);
        out.push(format!("{clean_title} · Search: {clean_query}"));

        if self.filtered.is_empty() {
            out.push("  (no matches)".to_string());
        } else {
            let (start, end) = self.visible_range();
            for (pos, &item_idx) in self.filtered[start..end].iter().enumerate() {
                let actual_pos = start + pos;
                let prefix = if actual_pos == self.selected {
                    "> "
                } else {
                    "  "
                };
                out.push(format!("{prefix}{}", self.items[item_idx].display_text()));
            }
        }

        out
    }

    /// Handles a terminal key event inside the picker without escaping focus.
    pub fn key(&mut self, key: KeyEvent) -> Choice {
        if key.kind == KeyEventKind::Release {
            return Choice::Stay;
        }

        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let alt = key.modifiers.contains(KeyModifiers::ALT);
        let sup = key.modifiers.contains(KeyModifiers::SUPER);

        match key.code {
            KeyCode::Esc => Choice::Cancel,
            KeyCode::Char(c) if ctrl && !alt && !sup && c.eq_ignore_ascii_case(&'c') => {
                Choice::Cancel
            }
            KeyCode::Enter if !alt && !ctrl && !sup => self.confirm_selection(),
            KeyCode::Up if !alt && !ctrl && !sup => {
                self.move_up();
                Choice::Stay
            }
            KeyCode::Down if !alt && !ctrl && !sup => {
                self.move_down();
                Choice::Stay
            }
            KeyCode::Char(c) if ctrl && !alt && !sup && c.eq_ignore_ascii_case(&'p') => {
                self.move_up();
                Choice::Stay
            }
            KeyCode::Char(c) if ctrl && !alt && !sup && c.eq_ignore_ascii_case(&'n') => {
                self.move_down();
                Choice::Stay
            }
            KeyCode::PageUp if !alt && !ctrl && !sup => {
                self.page_up();
                Choice::Stay
            }
            KeyCode::PageDown if !alt && !ctrl && !sup => {
                self.page_down();
                Choice::Stay
            }
            KeyCode::Home if !alt && !ctrl && !sup => {
                self.cursor = 0;
                Choice::Stay
            }
            KeyCode::End if !alt && !ctrl && !sup => {
                self.cursor = self.query.len();
                Choice::Stay
            }
            KeyCode::Left if !alt && !ctrl && !sup => {
                self.move_cursor_left();
                Choice::Stay
            }
            KeyCode::Right if !alt && !ctrl && !sup => {
                self.move_cursor_right();
                Choice::Stay
            }
            KeyCode::Left if (alt || ctrl) && !sup => {
                self.move_cursor_word_left();
                Choice::Stay
            }
            KeyCode::Right if (alt || ctrl) && !sup => {
                self.move_cursor_word_right();
                Choice::Stay
            }
            KeyCode::Backspace if alt && !ctrl && !sup => {
                if self.delete_word_backward() {
                    self.refilter();
                }
                Choice::Stay
            }
            KeyCode::Backspace if !ctrl && !sup => {
                if self.delete_char_backward() {
                    self.refilter();
                }
                Choice::Stay
            }
            KeyCode::Delete if alt && !ctrl && !sup => {
                if self.delete_word_forward() {
                    self.refilter();
                }
                Choice::Stay
            }
            KeyCode::Delete if !ctrl && !sup => {
                if self.delete_char_forward() {
                    self.refilter();
                }
                Choice::Stay
            }
            KeyCode::Char(c) if ctrl && !alt && !sup => {
                match c.to_ascii_lowercase() {
                    'a' => self.cursor = 0,
                    'e' => self.cursor = self.query.len(),
                    'b' => self.move_cursor_left(),
                    'f' => self.move_cursor_right(),
                    'd' if self.delete_char_forward() => {
                        self.refilter();
                    }
                    'u' if self.delete_to_start() => {
                        self.refilter();
                    }
                    'k' if self.delete_to_end() => {
                        self.refilter();
                    }
                    'w' if self.delete_word_backward() => {
                        self.refilter();
                    }
                    _ => {}
                }
                Choice::Stay
            }
            KeyCode::Char(c) if alt && !ctrl && !sup => {
                match c.to_ascii_lowercase() {
                    'b' => self.move_cursor_word_left(),
                    'f' => self.move_cursor_word_right(),
                    'd' if self.delete_word_forward() => {
                        self.refilter();
                    }
                    _ => {}
                }
                Choice::Stay
            }
            KeyCode::Char(c) if !ctrl && !alt && !sup && !c.is_control() => {
                self.insert_char(c);
                self.refilter();
                Choice::Stay
            }
            _ => Choice::Stay,
        }
    }

    fn confirm_selection(&self) -> Choice {
        match self.filtered.get(self.selected) {
            Some(&idx) => Choice::Pick(self.items[idx].id.clone()),
            None => Choice::Stay,
        }
    }

    fn move_up(&mut self) {
        if self.filtered.is_empty() {
            return;
        }
        self.selected = if self.selected == 0 {
            self.filtered.len() - 1
        } else {
            self.selected - 1
        };
    }

    fn move_down(&mut self) {
        if self.filtered.is_empty() {
            return;
        }
        self.selected = if self.selected + 1 >= self.filtered.len() {
            0
        } else {
            self.selected + 1
        };
    }

    fn page_up(&mut self) {
        if self.filtered.is_empty() {
            return;
        }
        self.selected = self.selected.saturating_sub(self.max_visible);
    }

    fn page_down(&mut self) {
        if self.filtered.is_empty() {
            return;
        }
        self.selected = (self.selected + self.max_visible).min(self.filtered.len() - 1);
    }

    fn visible_range(&self) -> (usize, usize) {
        let len = self.filtered.len();
        if len <= self.max_visible {
            return (0, len);
        }
        let half = self.max_visible / 2;
        let start = self
            .selected
            .saturating_sub(half)
            .min(len.saturating_sub(self.max_visible));
        let end = (start + self.max_visible).min(len);
        (start, end)
    }

    fn insert_char(&mut self, ch: char) {
        self.query.insert(self.cursor, ch);
        self.cursor += ch.len_utf8();
    }

    fn move_cursor_left(&mut self) {
        if self.cursor == 0 {
            return;
        }
        if let Some((idx, _)) = self.query[..self.cursor].grapheme_indices(true).next_back() {
            self.cursor = idx;
        } else {
            self.cursor = 0;
        }
    }

    fn move_cursor_right(&mut self) {
        if self.cursor >= self.query.len() {
            return;
        }
        if let Some((_, g)) = self.query[self.cursor..].grapheme_indices(true).next() {
            self.cursor += g.len();
        }
    }

    fn move_cursor_word_left(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let before = &self.query[..self.cursor];
        let mut graphemes: Vec<(usize, &str)> = before.grapheme_indices(true).collect();
        while let Some(&(_, g)) = graphemes.last() {
            if is_whitespace_grapheme(g) {
                graphemes.pop();
            } else {
                break;
            }
        }
        let mut target = 0;
        if let Some(&(_, g)) = graphemes.last() {
            if is_word_separator_grapheme(g) {
                while let Some(&(idx, g2)) = graphemes.last() {
                    if is_word_separator_grapheme(g2) {
                        target = idx;
                        graphemes.pop();
                    } else {
                        break;
                    }
                }
            } else {
                while let Some(&(idx, g2)) = graphemes.last() {
                    if is_whitespace_grapheme(g2) || is_word_separator_grapheme(g2) {
                        break;
                    }
                    target = idx;
                    graphemes.pop();
                }
            }
        }
        self.cursor = target;
    }

    fn move_cursor_word_right(&mut self) {
        if self.cursor >= self.query.len() {
            return;
        }
        let after = &self.query[self.cursor..];
        let mut iter = after.grapheme_indices(true).peekable();
        while let Some(&(_, g)) = iter.peek() {
            if is_whitespace_grapheme(g) {
                iter.next();
            } else {
                break;
            }
        }
        if let Some(&(_, g)) = iter.peek() {
            if is_word_separator_grapheme(g) {
                while let Some(&(_, g2)) = iter.peek() {
                    if is_word_separator_grapheme(g2) {
                        iter.next();
                    } else {
                        break;
                    }
                }
            } else {
                while let Some(&(_, g2)) = iter.peek() {
                    if is_whitespace_grapheme(g2) || is_word_separator_grapheme(g2) {
                        break;
                    }
                    iter.next();
                }
            }
        }
        self.cursor = match iter.peek() {
            Some(&(offset, _)) => self.cursor + offset,
            None => self.query.len(),
        };
    }

    fn delete_char_backward(&mut self) -> bool {
        if self.cursor == 0 {
            return false;
        }
        let prev = self.query[..self.cursor]
            .grapheme_indices(true)
            .next_back()
            .map_or(0, |(idx, _)| idx);
        self.query.drain(prev..self.cursor);
        self.cursor = prev;
        true
    }

    fn delete_char_forward(&mut self) -> bool {
        if self.cursor >= self.query.len() {
            return false;
        }
        let next = self.query[self.cursor..]
            .grapheme_indices(true)
            .next()
            .map_or(self.query.len(), |(idx, g)| self.cursor + idx + g.len());
        self.query.drain(self.cursor..next);
        true
    }

    fn delete_to_start(&mut self) -> bool {
        if self.cursor == 0 {
            return false;
        }
        self.query.drain(..self.cursor);
        self.cursor = 0;
        true
    }

    fn delete_to_end(&mut self) -> bool {
        if self.cursor >= self.query.len() {
            return false;
        }
        self.query.truncate(self.cursor);
        true
    }

    fn delete_word_backward(&mut self) -> bool {
        let end = self.cursor;
        if end == 0 {
            return false;
        }
        self.move_cursor_word_left();
        let start = self.cursor;
        if start == end {
            return false;
        }
        self.query.drain(start..end);
        true
    }

    fn delete_word_forward(&mut self) -> bool {
        let start = self.cursor;
        if start >= self.query.len() {
            return false;
        }
        self.move_cursor_word_right();
        let end = self.cursor;
        self.cursor = start;
        if end == start {
            return false;
        }
        self.query.drain(start..end);
        true
    }

    fn refilter(&mut self) {
        let tokens: Vec<&str> = self.query.split_whitespace().collect();

        if tokens.is_empty() {
            self.filtered = (0..self.items.len()).collect();
            self.selected = 0;
            return;
        }

        let mut scored: Vec<(i64, usize)> = Vec::new();
        for (idx, item) in self.items.iter().enumerate() {
            let mut total_score = 0i64;
            let mut all_match = true;

            for &raw_tok in &tokens {
                let tok_chars: Vec<char> = raw_tok.to_lowercase().chars().collect();
                if let Some(score) = best_token_score(&tok_chars, item) {
                    total_score += score;
                    continue;
                }

                if raw_tok.contains('/') {
                    let sub_tokens: Vec<Vec<char>> = raw_tok
                        .split('/')
                        .filter(|s| !s.is_empty())
                        .map(|s| s.to_lowercase().chars().collect())
                        .collect();
                    if !sub_tokens.is_empty() {
                        let mut sub_total = 10i64;
                        let mut sub_ok = true;
                        for sub in &sub_tokens {
                            match best_token_score(sub, item) {
                                Some(s) => sub_total += s,
                                None => {
                                    sub_ok = false;
                                    break;
                                }
                            }
                        }
                        if sub_ok {
                            total_score += sub_total;
                            continue;
                        }
                    }
                }

                all_match = false;
                break;
            }

            if all_match {
                scored.push((total_score, idx));
            }
        }

        scored.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
        self.filtered = scored.into_iter().map(|(_, idx)| idx).collect();
        self.selected = 0;
    }
}

fn best_token_score(token: &[char], item: &PickerItem) -> Option<i64> {
    [
        fuzzy_match_chars(token, &item.id_lower),
        fuzzy_match_chars(token, &item.label_lower),
        fuzzy_match_chars(token, &item.combined_lower),
    ]
    .into_iter()
    .flatten()
    .min()
}

fn is_whitespace_grapheme(g: &str) -> bool {
    g.chars().all(char::is_whitespace)
}

fn is_word_separator_grapheme(g: &str) -> bool {
    matches!(g, "-" | "_" | "." | "/" | ":")
}

fn is_word_boundary_char(ch: char) -> bool {
    ch.is_whitespace() || matches!(ch, '-' | '_' | '.' | '/' | ':')
}

/// Fuzzy match a lowercased query against lowercased target characters.
/// Returns `Some(score)` where lower scores are better, or `None` if no match.
fn fuzzy_match_chars(query: &[char], target: &[char]) -> Option<i64> {
    if let Some(score) = match_chars_in_order(query, target) {
        return Some(score);
    }

    if let Some(swapped) = swap_alpha_numeric(query) {
        if let Some(score) = match_chars_in_order(&swapped, target) {
            return Some(score + 50);
        }
    }

    None
}

fn match_chars_in_order(query: &[char], target: &[char]) -> Option<i64> {
    if query.is_empty() {
        return Some(0);
    }
    if query.len() > target.len() {
        return None;
    }

    let mut q_idx = 0usize;
    let mut score = 0i64;
    let mut last_match: Option<usize> = None;
    let mut consecutive = 0i64;

    for (i, &ch) in target.iter().enumerate() {
        if ch != query[q_idx] {
            continue;
        }

        let is_boundary = i == 0 || is_word_boundary_char(target[i - 1]);
        match last_match {
            Some(prev) if prev + 1 == i => {
                consecutive += 1;
                score -= consecutive * 50;
            }
            Some(prev) => {
                consecutive = 0;
                score += ((i - prev - 1) as i64) * 20;
            }
            None => {
                consecutive = 0;
            }
        }

        if is_boundary {
            score -= 100;
        }

        score += i as i64;
        last_match = Some(i);
        q_idx += 1;

        if q_idx == query.len() {
            if query == target {
                score -= 1000;
            }
            return Some(score);
        }
    }

    None
}

fn swap_alpha_numeric(query: &[char]) -> Option<Vec<char>> {
    let first_digit = query.iter().position(|c| c.is_ascii_digit());
    let first_alpha = query.iter().position(|c| c.is_ascii_alphabetic());

    match (first_alpha, first_digit) {
        (Some(0), Some(split)) => {
            if query[..split].iter().all(|c| c.is_ascii_alphabetic())
                && query[split..].iter().all(|c| c.is_ascii_digit())
            {
                let mut swapped = Vec::with_capacity(query.len());
                swapped.extend_from_slice(&query[split..]);
                swapped.extend_from_slice(&query[..split]);
                return Some(swapped);
            }
            None
        }
        (Some(split), Some(0)) => {
            if query[..split].iter().all(|c| c.is_ascii_digit())
                && query[split..].iter().all(|c| c.is_ascii_alphabetic())
            {
                let mut swapped = Vec::with_capacity(query.len());
                swapped.extend_from_slice(&query[split..]);
                swapped.extend_from_slice(&query[..split]);
                return Some(swapped);
            }
            None
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::KeyEventState;

    fn press(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn press_mod(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, modifiers)
    }

    fn type_text(picker: &mut Picker, text: &str) {
        for ch in text.chars() {
            assert_eq!(picker.key(press(KeyCode::Char(ch))), Choice::Stay);
        }
    }

    #[test]
    fn empty_picker_handles_navigation_confirm_and_cancel_safely() {
        let mut picker = Picker::new("Sessions", vec![]);
        let rendered = picker.lines();
        assert_eq!(rendered[0], "Sessions · Search: ");
        assert!(rendered.iter().any(|l| l.contains("(no matches)")));

        assert_eq!(picker.key(press(KeyCode::Up)), Choice::Stay);
        assert_eq!(picker.key(press(KeyCode::Down)), Choice::Stay);
        assert_eq!(picker.key(press(KeyCode::PageUp)), Choice::Stay);
        assert_eq!(picker.key(press(KeyCode::PageDown)), Choice::Stay);
        assert_eq!(picker.key(press(KeyCode::Enter)), Choice::Stay);
        assert_eq!(picker.key(press(KeyCode::Esc)), Choice::Cancel);
    }

    #[test]
    fn arrow_navigation_wraps_and_enter_picks_selected_id() {
        let choices = vec![
            ("m1".to_string(), "Model One".to_string()),
            ("m2".to_string(), "Model Two".to_string()),
            ("m3".to_string(), "Model Three".to_string()),
        ];
        let mut picker = Picker::new("Select Model", choices);

        assert_eq!(picker.selected_id(), Some("m1"));
        assert_eq!(picker.key(press(KeyCode::Up)), Choice::Stay);
        assert_eq!(picker.selected_id(), Some("m3"));
        assert_eq!(picker.key(press(KeyCode::Down)), Choice::Stay);
        assert_eq!(picker.selected_id(), Some("m1"));
        assert_eq!(picker.key(press(KeyCode::Down)), Choice::Stay);
        assert_eq!(picker.selected_id(), Some("m2"));

        assert_eq!(
            picker.key(press(KeyCode::Enter)),
            Choice::Pick("m2".to_string())
        );
    }

    #[test]
    fn ctrl_p_and_ctrl_n_navigate_without_leaking_to_query() {
        let choices = vec![
            ("a".to_string(), "Alpha".to_string()),
            ("b".to_string(), "Beta".to_string()),
        ];
        let mut picker = Picker::new("Test", choices);

        assert_eq!(
            picker.key(press_mod(KeyCode::Char('n'), KeyModifiers::CONTROL)),
            Choice::Stay
        );
        assert_eq!(picker.selected_id(), Some("b"));
        assert_eq!(picker.query(), "");

        assert_eq!(
            picker.key(press_mod(KeyCode::Char('p'), KeyModifiers::CONTROL)),
            Choice::Stay
        );
        assert_eq!(picker.selected_id(), Some("a"));
        assert_eq!(picker.query(), "");
    }

    #[test]
    fn esc_and_ctrl_c_cancel_even_with_active_search_query() {
        let choices = vec![("id1".to_string(), "Label 1".to_string())];

        let mut p1 = Picker::new("Models", choices.clone());
        type_text(&mut p1, "lab");
        assert_eq!(p1.query(), "lab");
        assert_eq!(p1.key(press(KeyCode::Esc)), Choice::Cancel);

        let mut p2 = Picker::new("Models", choices);
        type_text(&mut p2, "lab");
        assert_eq!(
            p2.key(press_mod(KeyCode::Char('c'), KeyModifiers::CONTROL)),
            Choice::Cancel
        );
    }

    #[test]
    fn no_focus_escape_on_unhandled_or_app_level_chords() {
        let choices = vec![("s1".to_string(), "Session 1".to_string())];
        let mut picker = Picker::new("Sessions", choices);

        for ev in [
            press(KeyCode::Tab),
            press(KeyCode::BackTab),
            press(KeyCode::F(1)),
            press_mod(KeyCode::Enter, KeyModifiers::ALT),
            press_mod(KeyCode::Char('z'), KeyModifiers::CONTROL),
            press_mod(KeyCode::Char('d'), KeyModifiers::CONTROL),
            press_mod(KeyCode::Char('g'), KeyModifiers::CONTROL),
            press_mod(KeyCode::Char('o'), KeyModifiers::CONTROL),
            press_mod(KeyCode::Char('t'), KeyModifiers::CONTROL),
        ] {
            assert_eq!(picker.key(ev), Choice::Stay);
        }
        assert_eq!(picker.query(), "");
    }

    #[test]
    fn key_release_events_are_ignored() {
        let choices = vec![("id1".to_string(), "Alpha".to_string())];
        let mut picker = Picker::new("Pick", choices);

        let release = KeyEvent {
            code: KeyCode::Enter,
            modifiers: KeyModifiers::NONE,
            kind: KeyEventKind::Release,
            state: KeyEventState::NONE,
        };
        assert_eq!(picker.key(release), Choice::Stay);
    }

    #[test]
    fn fuzzy_search_filters_and_ranks_models_sessions_branches_and_commands() {
        // Model picker: slash-separated provider/model and alphanumeric swap
        let models = vec![
            (
                "openai/gpt-5.2-codex".to_string(),
                "gpt-5.2-codex [openai]".to_string(),
            ),
            (
                "anthropic/claude-sonnet".to_string(),
                "claude-sonnet [anthropic]".to_string(),
            ),
            ("cl".to_string(), "Custom Lite".to_string()),
        ];
        let mut model_picker = Picker::new("Model", models);
        type_text(&mut model_picker, "openai/codex52");
        assert_eq!(model_picker.filtered_len(), 1);
        assert_eq!(
            model_picker.key(press(KeyCode::Enter)),
            Choice::Pick("openai/gpt-5.2-codex".to_string())
        );

        // Exact ID match ranks above longer prefix matches
        let cmds = vec![
            ("/clone".to_string(), "Clone session".to_string()),
            ("/cl".to_string(), "Clear".to_string()),
            ("plain".to_string(), "Plain item".to_string()),
        ];
        let mut cmd_picker = Picker::new("Commands", cmds);
        type_text(&mut cmd_picker, "/");
        assert_eq!(cmd_picker.filtered_len(), 2);
        type_text(&mut cmd_picker, "cl");
        assert_eq!(cmd_picker.selected_id(), Some("/cl"));

        // Reordered provider/model slash query
        let reordered_models = vec![
            ("gpt-5.5".to_string(), "gpt-5.5 [openai-codex]".to_string()),
            ("claude-4".to_string(), "claude-4 [anthropic]".to_string()),
        ];
        let mut reordered_picker = Picker::new("Model", reordered_models);
        type_text(&mut reordered_picker, "openai-codex/gpt-5.5");
        assert_eq!(reordered_picker.filtered_len(), 1);
        assert_eq!(reordered_picker.selected_id(), Some("gpt-5.5"));

        // No-match Enter stays open, backspace restores match
        type_text(&mut reordered_picker, "zzz");
        assert_eq!(reordered_picker.filtered_len(), 0);
        assert_eq!(reordered_picker.key(press(KeyCode::Enter)), Choice::Stay);
        for _ in 0..3 {
            assert_eq!(
                reordered_picker.key(press(KeyCode::Backspace)),
                Choice::Stay
            );
        }
        assert_eq!(reordered_picker.filtered_len(), 1);
        assert_eq!(
            reordered_picker.key(press(KeyCode::Enter)),
            Choice::Pick("gpt-5.5".to_string())
        );

        // Branch picker: filter by branch details
        let branches = vec![
            ("1".to_string(), "#1 main".to_string()),
            ("2".to_string(), "#2 forked from #1 @ #4".to_string()),
        ];
        let mut branch_picker = Picker::new("Branches", branches).with_selected("1");
        assert_eq!(branch_picker.selected_id(), Some("1"));
        type_text(&mut branch_picker, "forked");
        assert_eq!(
            branch_picker.key(press(KeyCode::Enter)),
            Choice::Pick("2".to_string())
        );

        // Session picker: multi-token search
        let sessions = vec![
            (
                "sess-1".to_string(),
                "Refactor editor · /repo/a · idle".to_string(),
            ),
            (
                "sess-2".to_string(),
                "Build picker · /repo/b · active".to_string(),
            ),
        ];
        let mut session_picker = Picker::new("Sessions", sessions);
        type_text(&mut session_picker, "picker active");
        assert_eq!(session_picker.filtered_len(), 1);
        assert_eq!(
            session_picker.key(press(KeyCode::Enter)),
            Choice::Pick("sess-2".to_string())
        );
    }

    #[test]
    fn search_editing_supports_cursor_movement_kills_and_unicode_graphemes() {
        let choices = vec![
            ("cafe".to_string(), "café latte".to_string()),
            ("sci".to_string(), "👩\u{200d}🔬 science".to_string()),
        ];
        let mut picker = Picker::new("Unicode", choices);

        // Insert combining accent + ZWJ emoji + ASCII
        type_text(&mut picker, "e\u{0301} 👩\u{200d}🔬");
        assert_eq!(picker.query(), "e\u{0301} 👩\u{200d}🔬");

        // Backspace deletes entire ZWJ emoji grapheme cluster cleanly
        assert_eq!(picker.key(press(KeyCode::Backspace)), Choice::Stay);
        assert_eq!(picker.query(), "e\u{0301} ");

        // Ctrl+U clears from cursor to start
        assert_eq!(
            picker.key(press_mod(KeyCode::Char('u'), KeyModifiers::CONTROL)),
            Choice::Stay
        );
        assert_eq!(picker.query(), "");

        // Type two words, test cursor movement + Ctrl+K / Ctrl+W / Alt+B / Alt+D
        type_text(&mut picker, "hello world");
        assert_eq!(
            picker.key(press_mod(KeyCode::Char('a'), KeyModifiers::CONTROL)),
            Choice::Stay
        );
        assert_eq!(
            picker.key(press_mod(KeyCode::Char('f'), KeyModifiers::ALT)),
            Choice::Stay
        );
        assert_eq!(
            picker.key(press_mod(KeyCode::Char('k'), KeyModifiers::CONTROL)),
            Choice::Stay
        );
        assert_eq!(picker.query(), "hello");

        assert_eq!(
            picker.key(press_mod(KeyCode::Char('w'), KeyModifiers::CONTROL)),
            Choice::Stay
        );
        assert_eq!(picker.query(), "");

        // Test Left/Right + Delete forward
        type_text(&mut picker, "caf");
        assert_eq!(picker.key(press(KeyCode::Left)), Choice::Stay);
        assert_eq!(picker.key(press(KeyCode::Delete)), Choice::Stay);
        assert_eq!(picker.query(), "ca");
        assert_eq!(picker.selected_id(), Some("cafe"));

        // Word-left / word-right across dotted/slashed separators
        assert_eq!(
            picker.key(press_mod(KeyCode::Char('u'), KeyModifiers::CONTROL)),
            Choice::Stay
        );
        type_text(&mut picker, "foo...bar");
        assert_eq!(picker.cursor, 9);
        assert_eq!(
            picker.key(press_mod(KeyCode::Char('b'), KeyModifiers::ALT)),
            Choice::Stay
        );
        assert_eq!(picker.cursor, 6);
        assert_eq!(
            picker.key(press_mod(KeyCode::Char('b'), KeyModifiers::ALT)),
            Choice::Stay
        );
        assert_eq!(picker.cursor, 3);
        assert_eq!(
            picker.key(press_mod(KeyCode::Char('b'), KeyModifiers::ALT)),
            Choice::Stay
        );
        assert_eq!(picker.cursor, 0);
        assert_eq!(
            picker.key(press_mod(KeyCode::Char('d'), KeyModifiers::ALT)),
            Choice::Stay
        );
        assert_eq!(picker.query(), "...bar");
    }

    #[test]
    fn lines_sanitize_untrusted_ansi_osc_and_control_sequences() {
        let choices = vec![(
            "id\x1b[31m1".to_string(),
            "evil\x1b]0;pwn\x07\nline\rspoof\u{009b}2J\x7f".to_string(),
        )];
        let mut picker = Picker::new("Pick\x1b[2J Title\nBreak", choices);
        type_text(&mut picker, "evil");

        let lines = picker.lines();
        let joined = lines.join("\n");
        assert!(!joined.contains('\x1b'));
        assert!(!joined.contains('\x07'));
        assert!(!joined.contains('\r'));
        assert!(!joined.contains('\x7f'));
        assert!(!joined.contains('\u{009b}'));
        assert!(lines[0].contains("\\x1b[2J"));
        assert!(lines[0].contains("\\nBreak"));
        assert!(lines[1].starts_with("> "));
        assert!(lines[1].contains("\\x1b]0;pwn\\x07"));
    }

    #[test]
    fn long_list_windows_visible_rows_and_supports_paging() {
        let choices: Vec<(String, String)> = (1..=25)
            .map(|i| (format!("id-{i:02}"), format!("Choice {i:02}")))
            .collect();
        let mut picker = Picker::new("Long List", choices);
        assert_eq!(picker.lines().len(), 7);
        picker.set_max_visible(5);

        let initial = picker.lines();
        let item_lines: Vec<&String> = initial
            .iter()
            .filter(|l| l.starts_with("> ") || l.starts_with("  Choice"))
            .collect();
        assert_eq!(item_lines.len(), 5);
        assert_eq!(initial.len(), 6);

        assert_eq!(picker.key(press(KeyCode::PageDown)), Choice::Stay);
        assert_eq!(picker.selected_id(), Some("id-06"));
        assert_eq!(picker.key(press(KeyCode::PageUp)), Choice::Stay);
        assert_eq!(picker.selected_id(), Some("id-01"));

        // Wrap to end with Up
        assert_eq!(picker.key(press(KeyCode::Up)), Choice::Stay);
        assert_eq!(picker.selected_id(), Some("id-25"));
        let at_end = picker.lines();
        assert!(at_end.iter().any(|l| l.contains("Choice 25")));
        assert_eq!(at_end.len(), 6);
    }
}
