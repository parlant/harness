use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use std::collections::{BTreeMap, VecDeque};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

const DEFAULT_WRAP_WIDTH: usize = 80;
const DEFAULT_MAX_HISTORY: usize = 100;
const MAX_KILL_RING: usize = 64;
const LARGE_PASTE_LINES: usize = 10;
const LARGE_PASTE_CHARS: usize = 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LastAction {
    Kill,
    Yank,
    TypeWord,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum JumpDirection {
    Forward,
    Backward,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Snapshot {
    buf: String,
    cursor: usize,
    pastes: BTreeMap<usize, String>,
    paste_counter: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct HistorySearch {
    query: String,
    match_idx: Option<usize>,
    draft: Snapshot,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct MarkerSpan {
    start: usize,
    end: usize,
    id: usize,
    suffix: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Segment {
    start: usize,
    end: usize,
    is_atomic_paste: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct VisualLine {
    logical_line: usize,
    byte_start: usize,
    byte_end: usize,
    is_last_in_logical_line: bool,
}

#[derive(Debug, Clone, Default)]
struct KillRing {
    entries: Vec<String>,
}

impl KillRing {
    fn push(&mut self, text: &str, prepend: bool, accumulate: bool) {
        if text.is_empty() {
            return;
        }
        if accumulate {
            if let Some(last) = self.entries.pop() {
                let merged = if prepend {
                    format!("{text}{last}")
                } else {
                    format!("{last}{text}")
                };
                self.entries.push(merged);
                return;
            }
        }
        if self.entries.len() >= MAX_KILL_RING {
            self.entries.remove(0);
        }
        self.entries.push(text.to_string());
    }

    fn peek(&self) -> Option<&str> {
        self.entries.last().map(String::as_str)
    }

    fn rotate(&mut self) {
        if self.entries.len() > 1 {
            let last = self.entries.pop().expect("len > 1");
            self.entries.insert(0, last);
        }
    }

    fn len(&self) -> usize {
        self.entries.len()
    }
}

#[derive(Debug, Clone)]
pub struct Editor {
    buf: String,
    cursor: usize,
    wrap_width: usize,

    pastes: BTreeMap<usize, String>,
    paste_counter: usize,

    history: VecDeque<String>,
    history_enabled: bool,
    max_history: usize,
    history_index: Option<usize>,
    history_draft: Option<(String, usize)>,
    search: Option<HistorySearch>,

    kill_ring: KillRing,
    yank_start: Option<usize>,
    last_action: Option<LastAction>,
    jump_mode: Option<JumpDirection>,

    preferred_visual_col: Option<usize>,
    snapped_from_byte: Option<usize>,

    undo_stack: Vec<Snapshot>,
    redo_stack: Vec<Snapshot>,
}

impl Default for Editor {
    fn default() -> Self {
        Self::new()
    }
}

impl Editor {
    pub fn new() -> Self {
        Self {
            buf: String::new(),
            cursor: 0,
            wrap_width: DEFAULT_WRAP_WIDTH,
            pastes: BTreeMap::new(),
            paste_counter: 0,
            history: VecDeque::new(),
            history_enabled: true,
            max_history: DEFAULT_MAX_HISTORY,
            history_index: None,
            history_draft: None,
            search: None,
            kill_ring: KillRing::default(),
            yank_start: None,
            last_action: None,
            jump_mode: None,
            preferred_visual_col: None,
            snapped_from_byte: None,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
        }
    }

    pub fn text(&self) -> &str {
        &self.buf
    }

    pub fn cursor(&self) -> usize {
        self.cursor
    }

    pub fn set(&mut self, text: &str) {
        self.search = None;
        self.jump_mode = None;
        self.last_action = None;
        self.yank_start = None;
        self.exit_history_browsing();

        let normalized = normalize_text(text, false);
        if self.buf != normalized {
            self.push_undo_snapshot();
        }
        self.pastes.clear();
        self.paste_counter = 0;
        self.buf = normalized;
        self.set_cursor(self.buf.len());
    }

    pub fn set_width(&mut self, width: usize) {
        self.wrap_width = width.max(1);
    }

    pub fn expanded_text(&self) -> String {
        expand_paste_markers(&self.buf, &self.pastes)
    }

    pub fn set_history_enabled(&mut self, enabled: bool) {
        self.history_enabled = enabled;
        if !enabled {
            self.history.clear();
            self.history_index = None;
            self.history_draft = None;
            self.search = None;
        }
    }

    pub fn set_max_history(&mut self, max: usize) {
        self.max_history = max;
        while self.history.len() > self.max_history {
            self.history.pop_back();
        }
    }

    pub fn history(&self) -> &VecDeque<String> {
        &self.history
    }

    pub fn add_to_history(&mut self, text: &str) {
        if !self.history_enabled || self.max_history == 0 {
            return;
        }
        if text.trim().is_empty() {
            return;
        }
        if self.history.front().is_some_and(|head| head == text) {
            return;
        }
        self.history.push_front(text.to_string());
        while self.history.len() > self.max_history {
            self.history.pop_back();
        }
    }

    pub fn is_searching_history(&self) -> bool {
        self.search.is_some()
    }

    pub fn search_query(&self) -> Option<&str> {
        self.search.as_ref().map(|s| s.query.as_str())
    }

    pub fn paste(&mut self, text: &str) {
        self.search = None;
        self.jump_mode = None;
        self.exit_history_browsing();
        self.last_action = None;
        self.yank_start = None;

        let clean = normalize_text(text, true);
        if clean.is_empty() {
            return;
        }

        self.push_undo_snapshot();

        let line_count = clean.split('\n').count();
        let char_count = clean.chars().count();

        if line_count > LARGE_PASTE_LINES || char_count > LARGE_PASTE_CHARS {
            self.paste_counter += 1;
            let id = self.paste_counter;
            let marker = if line_count > LARGE_PASTE_LINES {
                format!("[paste #{id} +{line_count} lines]")
            } else {
                format!("[paste #{id} {char_count} chars]")
            };
            self.pastes.insert(id, clean);
            self.insert_str_at_cursor(&marker);
        } else {
            self.insert_str_at_cursor(&clean);
        }
    }

    pub fn submitted(&mut self) -> String {
        let expanded = self.expanded_text();
        self.add_to_history(&expanded);

        self.buf.clear();
        self.cursor = 0;
        self.pastes.clear();
        self.paste_counter = 0;
        self.history_index = None;
        self.history_draft = None;
        self.search = None;
        self.yank_start = None;
        self.last_action = None;
        self.jump_mode = None;
        self.preferred_visual_col = None;
        self.snapped_from_byte = None;
        self.undo_stack.clear();
        self.redo_stack.clear();

        expanded
    }

    pub fn key(&mut self, event: KeyEvent) -> bool {
        if event.kind == KeyEventKind::Release {
            return false;
        }

        // 1. Character jump mode (Ctrl+] / Ctrl+Alt+])
        if let Some(dir) = self.jump_mode {
            if is_jump_forward(event) || is_jump_backward(event) {
                self.jump_mode = None;
                return true;
            }
            if event.code == KeyCode::Esc {
                self.jump_mode = None;
                return false;
            }
            if let Some(ch) = printable_char(event) {
                self.jump_mode = None;
                self.jump_to_char(ch, dir);
                return true;
            }
            self.jump_mode = None;
        }

        // 2. Incremental history search mode (Ctrl+R)
        if self.search.is_some() {
            return self.handle_search_key(event);
        }

        // 3. App-owned keys (do not consume)
        if is_app_owned_key(event, self.buf.is_empty()) {
            return false;
        }

        // 4. Newline (Ctrl+J / Shift+Enter)
        if is_newline_key(event) {
            self.insert_newline();
            return true;
        }

        // 5. Incremental history search trigger (Ctrl+R)
        if is_ctrl_char(event, 'r') {
            self.start_history_search();
            return true;
        }

        // 6. Redo / Undo
        if is_redo_key(event) {
            self.redo();
            return true;
        }
        if is_undo_key(event) {
            self.undo();
            return true;
        }

        // 7. Deletion actions
        if is_ctrl_char(event, 'k') {
            self.delete_to_line_end();
            return true;
        }
        if is_ctrl_char(event, 'u') {
            self.delete_to_line_start();
            return true;
        }
        if is_delete_word_backward(event) {
            self.delete_word_backward();
            return true;
        }
        if is_delete_word_forward(event) {
            self.delete_word_forward();
            return true;
        }
        if is_delete_char_backward(event) {
            self.delete_char_backward();
            return true;
        }
        if is_delete_char_forward(event, !self.buf.is_empty()) {
            self.delete_char_forward();
            return true;
        }

        // 8. Kill ring yank / yank-pop
        if is_ctrl_char(event, 'y') {
            self.yank();
            return true;
        }
        if is_alt_char(event, 'y') {
            self.yank_pop();
            return true;
        }

        // 9. Line start / end
        if is_line_start(event) {
            self.move_to_line_start();
            return true;
        }
        if is_line_end(event) {
            self.move_to_line_end();
            return true;
        }

        // 10. Word navigation
        if is_word_left(event) {
            self.move_word_backward();
            return true;
        }
        if is_word_right(event) {
            self.move_word_forward();
            return true;
        }

        // 11. Character jump mode triggers
        if is_jump_forward(event) {
            self.jump_mode = Some(JumpDirection::Forward);
            return true;
        }
        if is_jump_backward(event) {
            self.jump_mode = Some(JumpDirection::Backward);
            return true;
        }

        // 12. Cursor movement & history arrows
        if is_cursor_up(event) {
            self.handle_up();
            return true;
        }
        if is_cursor_down(event) {
            self.handle_down();
            return true;
        }
        if is_cursor_left(event) {
            self.move_left();
            return true;
        }
        if is_cursor_right(event) {
            self.move_right();
            return true;
        }

        // 13. Printable character insertion
        if let Some(ch) = printable_char(event) {
            self.insert_char(ch);
            return true;
        }

        false
    }

    pub fn undo(&mut self) -> bool {
        self.search = None;
        self.exit_history_browsing();
        let Some(snapshot) = self.undo_stack.pop() else {
            return false;
        };
        self.redo_stack.push(self.snapshot());
        self.restore_snapshot(snapshot);
        self.last_action = None;
        self.yank_start = None;
        self.preferred_visual_col = None;
        self.snapped_from_byte = None;
        true
    }

    pub fn redo(&mut self) -> bool {
        self.search = None;
        self.exit_history_browsing();
        let Some(snapshot) = self.redo_stack.pop() else {
            return false;
        };
        self.undo_stack.push(self.snapshot());
        self.restore_snapshot(snapshot);
        self.last_action = None;
        self.yank_start = None;
        self.preferred_visual_col = None;
        self.snapped_from_byte = None;
        true
    }

    fn snapshot(&self) -> Snapshot {
        Snapshot {
            buf: self.buf.clone(),
            cursor: self.cursor,
            pastes: self.pastes.clone(),
            paste_counter: self.paste_counter,
        }
    }

    fn restore_snapshot(&mut self, snapshot: Snapshot) {
        self.buf = snapshot.buf;
        self.cursor = snapshot.cursor.min(self.buf.len());
        self.pastes = snapshot.pastes;
        self.paste_counter = snapshot.paste_counter;
    }

    fn push_undo_snapshot(&mut self) {
        self.undo_stack.push(self.snapshot());
        self.redo_stack.clear();
    }

    fn set_cursor(&mut self, pos: usize) {
        self.cursor = pos.min(self.buf.len());
        self.preferred_visual_col = None;
        self.snapped_from_byte = None;
    }

    fn current_line_bounds(&self) -> (usize, usize) {
        let start = self.buf[..self.cursor].rfind('\n').map_or(0, |i| i + 1);
        let end = self.buf[self.cursor..]
            .find('\n')
            .map_or(self.buf.len(), |i| self.cursor + i);
        (start, end)
    }

    fn insert_str_at_cursor(&mut self, s: &str) {
        self.buf.insert_str(self.cursor, s);
        self.set_cursor(self.cursor + s.len());
    }

    fn insert_char(&mut self, ch: char) {
        self.exit_history_browsing();
        self.yank_start = None;

        if ch.is_whitespace() || self.last_action != Some(LastAction::TypeWord) {
            self.push_undo_snapshot();
        }
        self.last_action = Some(LastAction::TypeWord);

        let mut tmp = [0u8; 4];
        let s = ch.encode_utf8(&mut tmp);
        self.insert_str_at_cursor(s);
    }

    fn insert_newline(&mut self) {
        self.exit_history_browsing();
        self.last_action = None;
        self.yank_start = None;
        self.push_undo_snapshot();
        self.insert_str_at_cursor("\n");
    }

    fn delete_char_backward(&mut self) {
        self.exit_history_browsing();
        self.last_action = None;
        self.yank_start = None;

        if self.cursor == 0 {
            return;
        }

        self.push_undo_snapshot();

        let (line_start, _) = self.current_line_bounds();
        if self.cursor == line_start {
            // Merge with previous line by removing the preceding '\n'
            self.buf.remove(self.cursor - 1);
            self.set_cursor(self.cursor - 1);
            return;
        }

        let before = &self.buf[line_start..self.cursor];
        let segments = segment_line(before, &self.pastes);
        let last = segments
            .last()
            .copied()
            .expect("before is non-empty so at least one segment exists");
        let abs_start = line_start + last.start;
        let abs_end = line_start + last.end;

        if last.is_atomic_paste {
            self.remove_paste_span(abs_start, abs_end);
        } else {
            self.buf.replace_range(abs_start..abs_end, "");
            self.set_cursor(abs_start);
        }
    }

    fn delete_char_forward(&mut self) {
        self.exit_history_browsing();
        self.last_action = None;
        self.yank_start = None;

        if self.cursor >= self.buf.len() {
            return;
        }

        self.push_undo_snapshot();

        let (_, line_end) = self.current_line_bounds();
        if self.cursor == line_end {
            // Merge with next line by removing the '\n' at cursor
            self.buf.remove(self.cursor);
            return;
        }

        let after = &self.buf[self.cursor..line_end];
        let segments = segment_line(after, &self.pastes);
        let first = segments
            .first()
            .copied()
            .expect("after is non-empty so at least one segment exists");
        let abs_start = self.cursor + first.start;
        let abs_end = self.cursor + first.end;

        if first.is_atomic_paste {
            self.remove_paste_span(abs_start, abs_end);
        } else {
            self.buf.replace_range(abs_start..abs_end, "");
        }
    }

    fn remove_paste_span(&mut self, abs_start: usize, abs_end: usize) {
        let marker_text = &self.buf[abs_start..abs_end];
        let removed_id = parse_paste_marker_at(marker_text, 0).map(|m| m.id);

        self.buf.replace_range(abs_start..abs_end, "");
        let mut new_cursor = abs_start;

        if let Some(target_id) = removed_id {
            self.pastes.remove(&target_id);
            self.paste_counter = self.paste_counter.saturating_sub(1);

            let higher_ids: Vec<usize> = self
                .pastes
                .keys()
                .copied()
                .filter(|&id| id > target_id)
                .collect();
            for id in higher_ids {
                if let Some(val) = self.pastes.remove(&id) {
                    self.pastes.insert(id - 1, val);
                }
            }

            // Renumber markers in buffer with id > target_id
            let mut spans = find_marker_spans(&self.buf);
            spans.sort_by_key(|s| s.start);
            // Apply replacements from right to left so byte offsets stay valid,
            // tracking delta for cursor if span is before new_cursor.
            for span in spans.into_iter().rev() {
                if span.id > target_id {
                    let replacement = format!("[paste #{}{}]", span.id - 1, span.suffix);
                    let old_len = span.end - span.start;
                    let new_len = replacement.len();
                    self.buf.replace_range(span.start..span.end, &replacement);
                    if span.end <= new_cursor {
                        new_cursor = new_cursor + new_len - old_len;
                    }
                }
            }
        }

        self.set_cursor(new_cursor);
    }

    fn delete_to_line_start(&mut self) {
        self.exit_history_browsing();
        self.yank_start = None;

        let (line_start, _) = self.current_line_bounds();
        let accumulate = self.last_action == Some(LastAction::Kill);

        if self.cursor > line_start {
            self.push_undo_snapshot();
            let deleted = self.buf[line_start..self.cursor].to_string();
            self.kill_ring.push(&deleted, true, accumulate);
            self.last_action = Some(LastAction::Kill);
            self.buf.replace_range(line_start..self.cursor, "");
            self.set_cursor(line_start);
        } else if line_start > 0 {
            self.push_undo_snapshot();
            self.kill_ring.push("\n", true, accumulate);
            self.last_action = Some(LastAction::Kill);
            self.buf.remove(line_start - 1);
            self.set_cursor(line_start - 1);
        }
    }

    fn delete_to_line_end(&mut self) {
        self.exit_history_browsing();
        self.yank_start = None;

        let (_, line_end) = self.current_line_bounds();
        let accumulate = self.last_action == Some(LastAction::Kill);

        if self.cursor < line_end {
            self.push_undo_snapshot();
            let deleted = self.buf[self.cursor..line_end].to_string();
            self.kill_ring.push(&deleted, false, accumulate);
            self.last_action = Some(LastAction::Kill);
            self.buf.replace_range(self.cursor..line_end, "");
        } else if line_end < self.buf.len() {
            self.push_undo_snapshot();
            self.kill_ring.push("\n", false, accumulate);
            self.last_action = Some(LastAction::Kill);
            self.buf.remove(line_end);
        }
    }

    fn delete_word_backward(&mut self) {
        self.exit_history_browsing();
        self.yank_start = None;

        let (line_start, _) = self.current_line_bounds();
        let accumulate = self.last_action == Some(LastAction::Kill);

        if self.cursor == line_start {
            if line_start > 0 {
                self.push_undo_snapshot();
                self.kill_ring.push("\n", true, accumulate);
                self.last_action = Some(LastAction::Kill);
                self.buf.remove(line_start - 1);
                self.set_cursor(line_start - 1);
            }
            return;
        }

        self.push_undo_snapshot();
        let rel_cursor = self.cursor - line_start;
        let line = &self.buf[line_start..self.cursor];
        let rel_from = find_word_backward(line, rel_cursor, &self.pastes);
        let abs_from = line_start + rel_from;

        let deleted = self.buf[abs_from..self.cursor].to_string();
        self.kill_ring.push(&deleted, true, accumulate);
        self.last_action = Some(LastAction::Kill);
        self.buf.replace_range(abs_from..self.cursor, "");
        self.set_cursor(abs_from);
    }

    fn delete_word_forward(&mut self) {
        self.exit_history_browsing();
        self.yank_start = None;

        let (_, line_end) = self.current_line_bounds();
        let accumulate = self.last_action == Some(LastAction::Kill);

        if self.cursor >= line_end {
            if line_end < self.buf.len() {
                self.push_undo_snapshot();
                self.kill_ring.push("\n", false, accumulate);
                self.last_action = Some(LastAction::Kill);
                self.buf.remove(line_end);
            }
            return;
        }

        self.push_undo_snapshot();
        let line = &self.buf[self.cursor..line_end];
        let rel_to = find_word_forward(line, 0, &self.pastes);
        let abs_to = self.cursor + rel_to;

        let deleted = self.buf[self.cursor..abs_to].to_string();
        self.kill_ring.push(&deleted, false, accumulate);
        self.last_action = Some(LastAction::Kill);
        self.buf.replace_range(self.cursor..abs_to, "");
    }

    fn yank(&mut self) {
        let Some(text) = self.kill_ring.peek().map(str::to_string) else {
            return;
        };
        self.exit_history_browsing();
        self.push_undo_snapshot();
        let start = self.cursor;
        self.insert_str_at_cursor(&text);
        self.yank_start = Some(start);
        self.last_action = Some(LastAction::Yank);
    }

    fn yank_pop(&mut self) {
        if self.last_action != Some(LastAction::Yank) || self.kill_ring.len() <= 1 {
            return;
        }
        let Some(start) = self.yank_start else {
            return;
        };
        if start > self.cursor || self.cursor > self.buf.len() {
            return;
        }

        self.push_undo_snapshot();
        self.kill_ring.rotate();
        let next_text = self
            .kill_ring
            .peek()
            .expect("kill_ring.len() > 1")
            .to_string();
        self.buf.replace_range(start..self.cursor, &next_text);
        self.set_cursor(start + next_text.len());
        self.yank_start = Some(start);
        self.last_action = Some(LastAction::Yank);
    }

    fn move_to_line_start(&mut self) {
        self.last_action = None;
        self.yank_start = None;
        let (line_start, _) = self.current_line_bounds();
        self.set_cursor(line_start);
    }

    fn move_to_line_end(&mut self) {
        self.last_action = None;
        self.yank_start = None;
        let (_, line_end) = self.current_line_bounds();
        self.set_cursor(line_end);
    }

    fn move_left(&mut self) {
        self.last_action = None;
        self.yank_start = None;
        if self.cursor == 0 {
            return;
        }

        let (line_start, _) = self.current_line_bounds();
        if self.cursor == line_start {
            // Wrap to end of previous logical line
            self.set_cursor(line_start - 1);
            return;
        }

        let before = &self.buf[line_start..self.cursor];
        let segments = segment_line(before, &self.pastes);
        let len = segments.last().map_or(1, |s| s.end - s.start);
        self.set_cursor(self.cursor - len);
    }

    fn move_right(&mut self) {
        self.last_action = None;
        self.yank_start = None;

        if self.cursor >= self.buf.len() {
            // At end of last line: establish preferred_visual_col for subsequent Up navigation
            let vls = self.build_visual_lines();
            let current_vl = find_visual_line_at(&vls, self.cursor);
            if let Some(vl) = vls.get(current_vl) {
                self.preferred_visual_col =
                    Some(display_width(&self.buf[vl.byte_start..self.cursor]));
            }
            return;
        }

        let (_, line_end) = self.current_line_bounds();
        if self.cursor == line_end {
            // Wrap to start of next logical line
            self.set_cursor(line_end + 1);
            return;
        }

        let after = &self.buf[self.cursor..line_end];
        let segments = segment_line(after, &self.pastes);
        let len = segments.first().map_or(1, |s| s.end - s.start);
        self.set_cursor(self.cursor + len);
    }

    fn move_word_backward(&mut self) {
        self.last_action = None;
        self.yank_start = None;

        let (line_start, _) = self.current_line_bounds();
        if self.cursor == line_start {
            if line_start > 0 {
                self.set_cursor(line_start - 1);
            }
            return;
        }

        let rel_cursor = self.cursor - line_start;
        let line = &self.buf[line_start..self.cursor];
        let rel_pos = find_word_backward(line, rel_cursor, &self.pastes);
        self.set_cursor(line_start + rel_pos);
    }

    fn move_word_forward(&mut self) {
        self.last_action = None;
        self.yank_start = None;

        let (_, line_end) = self.current_line_bounds();
        if self.cursor >= line_end {
            if line_end < self.buf.len() {
                self.set_cursor(line_end + 1);
            }
            return;
        }

        let after = &self.buf[self.cursor..line_end];
        let delta = find_word_forward(after, 0, &self.pastes);
        self.set_cursor(self.cursor + delta);
    }

    fn jump_to_char(&mut self, target: char, dir: JumpDirection) {
        self.last_action = None;
        self.yank_start = None;

        match dir {
            JumpDirection::Forward => {
                if self.cursor >= self.buf.len() {
                    return;
                }
                let mut iter = self.buf[self.cursor..].char_indices();
                let _ = iter.next(); // skip current char
                for (offset, ch) in iter {
                    if ch == target {
                        self.set_cursor(self.cursor + offset);
                        return;
                    }
                }
            }
            JumpDirection::Backward => {
                if self.cursor == 0 {
                    return;
                }
                if let Some((offset, _)) = self.buf[..self.cursor]
                    .char_indices()
                    .rev()
                    .find(|&(_, ch)| ch == target)
                {
                    self.set_cursor(offset);
                }
            }
        }
    }

    fn handle_up(&mut self) {
        self.last_action = None;
        self.yank_start = None;

        let vls = self.build_visual_lines();
        let current_vl = find_visual_line_at(&vls, self.cursor);

        if current_vl == 0 {
            if self.buf.is_empty() || self.history_index.is_some() || self.cursor == 0 {
                self.navigate_history(-1);
            } else {
                self.move_to_line_start();
            }
        } else {
            self.move_to_visual_line(&vls, current_vl, current_vl - 1);
        }
    }

    fn handle_down(&mut self) {
        self.last_action = None;
        self.yank_start = None;

        let vls = self.build_visual_lines();
        let current_vl = find_visual_line_at(&vls, self.cursor);

        if current_vl + 1 >= vls.len() {
            if self.history_index.is_some() {
                self.navigate_history(1);
            } else {
                self.move_to_line_end();
            }
        } else {
            self.move_to_visual_line(&vls, current_vl, current_vl + 1);
        }
    }

    fn build_visual_lines(&self) -> Vec<VisualLine> {
        let mut visual_lines = Vec::new();
        let mut line_start = 0usize;

        for (logical_line, line) in self.buf.split('\n').enumerate() {
            let line_end = line_start + line.len();
            if line.is_empty() || display_width(line) <= self.wrap_width {
                visual_lines.push(VisualLine {
                    logical_line,
                    byte_start: line_start,
                    byte_end: line_end,
                    is_last_in_logical_line: true,
                });
            } else {
                let segments = segment_line(line, &self.pastes);
                let chunks = word_wrap_line(line, self.wrap_width, &segments);
                let num_chunks = chunks.len();
                for (idx, (start, end)) in chunks.into_iter().enumerate() {
                    visual_lines.push(VisualLine {
                        logical_line,
                        byte_start: line_start + start,
                        byte_end: line_start + end,
                        is_last_in_logical_line: idx + 1 == num_chunks,
                    });
                }
            }
            line_start = line_end + 1;
        }

        if visual_lines.is_empty() {
            visual_lines.push(VisualLine {
                logical_line: 0,
                byte_start: 0,
                byte_end: 0,
                is_last_in_logical_line: true,
            });
        }
        visual_lines
    }

    fn move_to_visual_line(
        &mut self,
        vls: &[VisualLine],
        current_vl_idx: usize,
        target_vl_idx: usize,
    ) {
        let Some(&current_vl) = vls.get(current_vl_idx) else {
            return;
        };
        let Some(&target_vl) = vls.get(target_vl_idx) else {
            return;
        };

        let current_visual_col = if let Some(snapped_byte) = self.snapped_from_byte {
            let snapped_vl_idx = find_visual_line_at(vls, snapped_byte);
            let snapped_vl = vls[snapped_vl_idx];
            display_width(&self.buf[snapped_vl.byte_start..snapped_byte])
        } else {
            display_width(&self.buf[current_vl.byte_start..self.cursor])
        };

        let source_slice = &self.buf[current_vl.byte_start..current_vl.byte_end];
        let source_segments = segment_line(source_slice, &self.pastes);
        let source_max_col = max_visual_col_in_vl(
            source_slice,
            &source_segments,
            current_vl.is_last_in_logical_line,
        );

        let target_slice = &self.buf[target_vl.byte_start..target_vl.byte_end];
        let target_segments = segment_line(target_slice, &self.pastes);
        let target_max_col = max_visual_col_in_vl(
            target_slice,
            &target_segments,
            target_vl.is_last_in_logical_line,
        );

        let move_to_col = Self::compute_vertical_move_col(
            &mut self.preferred_visual_col,
            current_visual_col,
            source_max_col,
            target_max_col,
        );
        let rel_byte = byte_offset_at_visual_col(target_slice, &target_segments, move_to_col);
        self.cursor = (target_vl.byte_start + rel_byte).min(self.buf.len());

        // Snap cursor to start of multi-byte or atomic paste segment if inside one
        let target_line_start = self.buf[..target_vl.byte_start]
            .rfind('\n')
            .map_or(0, |i| i + 1);
        let target_line_end = self.buf[target_vl.byte_start..]
            .find('\n')
            .map_or(self.buf.len(), |i| target_vl.byte_start + i);
        let logical_line = &self.buf[target_line_start..target_line_end];
        let line_segments = segment_line(logical_line, &self.pastes);

        for seg in line_segments {
            let abs_start = target_line_start + seg.start;
            let abs_end = target_line_start + seg.end;
            if abs_start > self.cursor {
                break;
            }
            if seg.is_atomic_paste && self.cursor > abs_start && self.cursor < abs_end {
                let is_continuation = abs_start < target_vl.byte_start;
                let is_moving_down = target_vl_idx > current_vl_idx;
                if is_continuation && is_moving_down {
                    let mut next = target_vl_idx + 1;
                    while next < vls.len()
                        && vls[next].logical_line == target_vl.logical_line
                        && vls[next].byte_start < abs_end
                    {
                        next += 1;
                    }
                    if next < vls.len() {
                        self.move_to_visual_line(vls, current_vl_idx, next);
                        return;
                    }
                }

                self.snapped_from_byte = Some(self.cursor);
                self.cursor = abs_start;
                return;
            }
        }

        self.snapped_from_byte = None;
    }

    fn compute_vertical_move_col(
        preferred_visual_col: &mut Option<usize>,
        current_col: usize,
        source_max_col: usize,
        target_max_col: usize,
    ) -> usize {
        let cursor_in_middle = current_col < source_max_col;
        let target_too_short = target_max_col < current_col;

        if preferred_visual_col.is_none() || cursor_in_middle {
            if target_too_short {
                *preferred_visual_col = Some(current_col);
                return target_max_col;
            }
            *preferred_visual_col = None;
            return current_col;
        }

        let preferred = preferred_visual_col.expect("checked is_some");
        if target_too_short || target_max_col < preferred {
            return target_max_col;
        }

        *preferred_visual_col = None;
        preferred
    }

    fn navigate_history(&mut self, direction: isize) {
        self.last_action = None;
        self.yank_start = None;
        if self.history.is_empty() {
            return;
        }

        let cur: isize = match self.history_index {
            Some(i) => i as isize,
            None => -1,
        };
        let next = cur - direction; // Up (-1) increases index; Down (+1) decreases index
        if next < -1 || next >= self.history.len() as isize {
            return;
        }

        if self.history_index.is_none() && next >= 0 {
            self.push_undo_snapshot();
            self.history_draft = Some((self.buf.clone(), self.cursor));
        }

        if next == -1 {
            self.history_index = None;
            if let Some((draft_buf, draft_cursor)) = self.history_draft.take() {
                self.pastes.clear();
                self.paste_counter = 0;
                self.buf = draft_buf;
                self.set_cursor(draft_cursor);
            } else {
                self.buf.clear();
                self.set_cursor(0);
            }
        } else {
            let idx = next as usize;
            self.history_index = Some(idx);
            self.pastes.clear();
            self.paste_counter = 0;
            self.buf = self.history[idx].clone();
            let cursor_pos = if direction < 0 { 0 } else { self.buf.len() };
            self.set_cursor(cursor_pos);
        }
    }

    fn exit_history_browsing(&mut self) {
        self.history_index = None;
        self.history_draft = None;
    }

    fn start_history_search(&mut self) {
        self.last_action = None;
        self.yank_start = None;
        self.exit_history_browsing();

        if self.history.is_empty() {
            return;
        }

        self.search = Some(HistorySearch {
            query: String::new(),
            match_idx: None,
            draft: self.snapshot(),
        });
    }

    fn handle_search_key(&mut self, event: KeyEvent) -> bool {
        if event.code == KeyCode::Esc || is_ctrl_char(event, 'g') || is_ctrl_char(event, 'c') {
            if let Some(search) = self.search.take() {
                self.restore_snapshot(search.draft);
            }
            return true;
        }

        if event.code == KeyCode::Enter
            && !event
                .modifiers
                .intersects(KeyModifiers::SHIFT | KeyModifiers::ALT)
        {
            self.search = None;
            return true;
        }

        if is_ctrl_char(event, 'r') {
            self.step_search_older();
            return true;
        }

        if is_ctrl_char(event, 's') {
            self.step_search_newer();
            return true;
        }

        if is_delete_char_backward(event) {
            let query_empty = {
                let search = self.search.as_mut().expect("search is active");
                search.query.pop();
                search.query.is_empty()
            };
            if query_empty {
                let draft = self
                    .search
                    .as_ref()
                    .expect("search is active")
                    .draft
                    .clone();
                self.search.as_mut().expect("search is active").match_idx = None;
                self.restore_snapshot(draft);
            } else {
                self.reapply_search_from(0);
            }
            return true;
        }

        if let Some(ch) = printable_char(event) {
            {
                let search = self.search.as_mut().expect("search is active");
                search.query.push(ch);
            }
            let start = self.search.as_ref().and_then(|s| s.match_idx).unwrap_or(0);
            self.reapply_search_from(start);
            return true;
        }

        // Navigation keys exit search keeping the matched text and execute the movement
        if is_cursor_left(event)
            || is_cursor_right(event)
            || is_cursor_up(event)
            || is_cursor_down(event)
            || is_line_start(event)
            || is_line_end(event)
        {
            self.search = None;
            return self.key(event);
        }

        false
    }

    fn step_search_older(&mut self) {
        let Some(search) = self.search.as_ref() else {
            return;
        };
        let start = match search.match_idx {
            Some(idx) => idx + 1,
            None => 0,
        };
        self.reapply_search_from(start);
    }

    fn step_search_newer(&mut self) {
        let Some(search) = self.search.as_ref() else {
            return;
        };
        let Some(cur) = search.match_idx else {
            return;
        };
        let query = search.query.clone();
        for idx in (0..cur).rev() {
            if matches_search_query(&self.history[idx], &query) {
                if let Some(s) = self.search.as_mut() {
                    s.match_idx = Some(idx);
                }
                self.pastes.clear();
                self.paste_counter = 0;
                self.buf = self.history[idx].clone();
                self.set_cursor(self.buf.len());
                return;
            }
        }
    }

    fn reapply_search_from(&mut self, start_idx: usize) {
        let Some(query) = self.search.as_ref().map(|s| s.query.clone()) else {
            return;
        };
        for idx in start_idx..self.history.len() {
            if matches_search_query(&self.history[idx], &query) {
                if let Some(s) = self.search.as_mut() {
                    s.match_idx = Some(idx);
                }
                self.pastes.clear();
                self.paste_counter = 0;
                self.buf = self.history[idx].clone();
                self.set_cursor(self.buf.len());
                return;
            }
        }
    }
}

fn matches_search_query(entry: &str, query: &str) -> bool {
    if query.is_empty() {
        return true;
    }
    if query.chars().any(char::is_uppercase) {
        entry.contains(query)
    } else {
        entry.to_lowercase().contains(&query.to_lowercase())
    }
}

fn normalize_text(input: &str, decode_tmux_csi_u: bool) -> String {
    let maybe_decoded = if decode_tmux_csi_u && input.contains("\x1b[") {
        decode_tmux_ctrl_csi_u(input)
    } else {
        input.to_string()
    };

    let mut out = String::with_capacity(maybe_decoded.len());
    let mut chars = maybe_decoded.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    let _ = chars.next();
                }
                out.push('\n');
            }
            '\n' | '\t' => out.push(ch),
            c if (c as u32) < 0x20 || c == '\x7f' || ('\u{0080}'..='\u{009f}').contains(&c) => {}
            c => out.push(c),
        }
    }
    out
}

fn decode_tmux_ctrl_csi_u(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(pos) = rest.find("\x1b[") {
        out.push_str(&rest[..pos]);
        let after = &rest[pos + 2..];
        if let Some(u_pos) = after.find('u') {
            let body = &after[..u_pos];
            if let Some(code_str) = body.strip_suffix(";5") {
                if let Ok(cp) = code_str.parse::<u32>() {
                    if (97..=122).contains(&cp) {
                        out.push(char::from((cp - 96) as u8));
                        rest = &after[u_pos + 1..];
                        continue;
                    }
                    if (65..=90).contains(&cp) {
                        out.push(char::from((cp - 64) as u8));
                        rest = &after[u_pos + 1..];
                        continue;
                    }
                }
            }
        }
        out.push_str("\x1b[");
        rest = after;
    }
    out.push_str(rest);
    out
}

fn find_marker_spans(text: &str) -> Vec<MarkerSpan> {
    if !text.contains("[paste #") {
        return Vec::new();
    }
    let mut spans = Vec::new();
    let mut offset = 0usize;
    while let Some(rel) = text[offset..].find("[paste #") {
        let start = offset + rel;
        if let Some(span) = parse_paste_marker_at(text, start) {
            offset = span.end;
            spans.push(span);
        } else {
            offset = start + 8;
        }
    }
    spans
}

fn parse_paste_marker_at(text: &str, start: usize) -> Option<MarkerSpan> {
    let rest = text.get(start..)?.strip_prefix("[paste #")?;
    let id_len = rest.bytes().take_while(u8::is_ascii_digit).count();
    if id_len == 0 {
        return None;
    }
    let id: usize = rest[..id_len].parse().ok()?;
    let after_id = &rest[id_len..];

    let suffix_len = if after_id.starts_with(']') {
        0
    } else if let Some(s) = after_id.strip_prefix(" +") {
        let digits = s.bytes().take_while(u8::is_ascii_digit).count();
        if digits == 0 || !s[digits..].starts_with(" lines]") {
            return None;
        }
        2 + digits + " lines".len()
    } else {
        let s = after_id.strip_prefix(' ')?;
        let digits = s.bytes().take_while(u8::is_ascii_digit).count();
        if digits == 0 || !s[digits..].starts_with(" chars]") {
            return None;
        }
        1 + digits + " chars".len()
    };

    let suffix = after_id[..suffix_len].to_string();
    let end = start + "[paste #".len() + id_len + suffix_len + 1;
    Some(MarkerSpan {
        start,
        end,
        id,
        suffix,
    })
}

fn expand_paste_markers(text: &str, pastes: &BTreeMap<usize, String>) -> String {
    if pastes.is_empty() || !text.contains("[paste #") {
        return text.to_string();
    }
    let spans = find_marker_spans(text);
    if spans.is_empty() {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len());
    let mut pos = 0usize;
    for span in spans {
        if let Some(replacement) = pastes.get(&span.id) {
            out.push_str(&text[pos..span.start]);
            out.push_str(replacement);
            pos = span.end;
        }
    }
    out.push_str(&text[pos..]);
    out
}

fn segment_line(line: &str, pastes: &BTreeMap<usize, String>) -> Vec<Segment> {
    if line.is_empty() {
        return Vec::new();
    }
    let markers: Vec<MarkerSpan> = if pastes.is_empty() || !line.contains("[paste #") {
        Vec::new()
    } else {
        find_marker_spans(line)
            .into_iter()
            .filter(|m| pastes.contains_key(&m.id))
            .collect()
    };

    if markers.is_empty() {
        return line
            .grapheme_indices(true)
            .map(|(idx, g)| Segment {
                start: idx,
                end: idx + g.len(),
                is_atomic_paste: false,
            })
            .collect();
    }

    let mut out = Vec::new();
    let mut marker_idx = 0usize;
    for (idx, g) in line.grapheme_indices(true) {
        while marker_idx < markers.len() && markers[marker_idx].end <= idx {
            marker_idx += 1;
        }
        if let Some(marker) = markers.get(marker_idx) {
            if idx >= marker.start && idx < marker.end {
                if idx == marker.start {
                    out.push(Segment {
                        start: marker.start,
                        end: marker.end,
                        is_atomic_paste: true,
                    });
                }
                continue;
            }
        }
        out.push(Segment {
            start: idx,
            end: idx + g.len(),
            is_atomic_paste: false,
        });
    }
    out
}

fn display_width(text: &str) -> usize {
    if !text.contains('\t') {
        return text.width();
    }
    text.split('\t').map(UnicodeWidthStr::width).sum::<usize>() + text.matches('\t').count() * 4
}

fn segment_width(line: &str, seg: Segment) -> usize {
    display_width(&line[seg.start..seg.end])
}

fn is_whitespace_segment(s: &str) -> bool {
    !s.is_empty() && s.chars().all(char::is_whitespace)
}

fn is_cjk_char(ch: char) -> bool {
    matches!(
        ch as u32,
        0x1100..=0x11FF
            | 0x3040..=0x309F
            | 0x30A0..=0x30FF
            | 0x3100..=0x312F
            | 0x3130..=0x318F
            | 0x31A0..=0x31BF
            | 0x31F0..=0x31FF
            | 0x3400..=0x4DBF
            | 0x4E00..=0x9FFF
            | 0xAC00..=0xD7AF
            | 0xF900..=0xFAFF
            | 0xFF65..=0xFF9F
            | 0x20000..=0x2CEAF
    )
}

fn is_cjk_segment(s: &str) -> bool {
    s.chars().any(is_cjk_char)
}

fn word_wrap_line(line: &str, max_width: usize, segments: &[Segment]) -> Vec<(usize, usize)> {
    if line.is_empty() || max_width == 0 {
        return vec![(0, 0)];
    }
    if display_width(line) <= max_width {
        return vec![(0, line.len())];
    }

    let mut chunks = Vec::new();
    let mut current_width = 0usize;
    let mut chunk_start = 0usize;
    let mut wrap_opp_idx: Option<usize> = None;
    let mut wrap_opp_width = 0usize;

    for (i, &seg) in segments.iter().enumerate() {
        let seg_str = &line[seg.start..seg.end];
        let g_width = segment_width(line, seg);
        let is_ws = !seg.is_atomic_paste && is_whitespace_segment(seg_str);

        if current_width + g_width > max_width {
            if let Some(opp) = wrap_opp_idx {
                if current_width - wrap_opp_width + g_width <= max_width {
                    chunks.push((chunk_start, opp));
                    chunk_start = opp;
                    current_width -= wrap_opp_width;
                } else if chunk_start < seg.start {
                    chunks.push((chunk_start, seg.start));
                    chunk_start = seg.start;
                    current_width = 0;
                }
            } else if chunk_start < seg.start {
                chunks.push((chunk_start, seg.start));
                chunk_start = seg.start;
                current_width = 0;
            }
            wrap_opp_idx = None;
        }

        if g_width > max_width {
            let sub_segs: Vec<Segment> = seg_str
                .grapheme_indices(true)
                .map(|(idx, g)| Segment {
                    start: idx,
                    end: idx + g.len(),
                    is_atomic_paste: false,
                })
                .collect();
            let sub_chunks = word_wrap_line(seg_str, max_width, &sub_segs);
            for (j, &(sc_start, sc_end)) in sub_chunks.iter().enumerate() {
                if j + 1 < sub_chunks.len() {
                    chunks.push((seg.start + sc_start, seg.start + sc_end));
                } else {
                    chunk_start = seg.start + sc_start;
                    current_width = display_width(&seg_str[sc_start..sc_end]);
                }
            }
            wrap_opp_idx = None;
            continue;
        }

        current_width += g_width;

        if let Some(&next) = segments.get(i + 1) {
            let next_str = &line[next.start..next.end];
            if is_ws && (next.is_atomic_paste || !is_whitespace_segment(next_str)) {
                wrap_opp_idx = Some(next.start);
                wrap_opp_width = current_width;
            } else if !is_ws && !is_whitespace_segment(next_str) {
                let cur_cjk = !seg.is_atomic_paste && is_cjk_segment(seg_str);
                let next_cjk = !next.is_atomic_paste && is_cjk_segment(next_str);
                if cur_cjk || next_cjk {
                    wrap_opp_idx = Some(next.start);
                    wrap_opp_width = current_width;
                }
            }
        }
    }

    chunks.push((chunk_start, line.len()));
    chunks
}

fn find_visual_line_at(vls: &[VisualLine], cursor: usize) -> usize {
    for (idx, vl) in vls.iter().enumerate() {
        if cursor >= vl.byte_start
            && (cursor < vl.byte_end || (vl.is_last_in_logical_line && cursor == vl.byte_end))
        {
            return idx;
        }
    }
    vls.len().saturating_sub(1)
}

fn max_visual_col_in_vl(slice: &str, segments: &[Segment], is_last_segment: bool) -> usize {
    let total = display_width(slice);
    if is_last_segment || slice.is_empty() {
        total
    } else if let Some(&last) = segments.last() {
        total.saturating_sub(segment_width(slice, last))
    } else {
        total
    }
}

fn byte_offset_at_visual_col(slice: &str, segments: &[Segment], target_col: usize) -> usize {
    let mut col = 0usize;
    for &seg in segments {
        if col >= target_col {
            return seg.start;
        }
        col += segment_width(slice, seg);
    }
    slice.len()
}

fn is_ascii_word_punctuation(ch: char) -> bool {
    matches!(
        ch,
        '(' | ')'
            | '{'
            | '}'
            | '['
            | ']'
            | '<'
            | '>'
            | '.'
            | ','
            | ';'
            | ':'
            | '\''
            | '"'
            | '!'
            | '?'
            | '+'
            | '-'
            | '='
            | '*'
            | '/'
            | '\\'
            | '|'
            | '&'
            | '%'
            | '^'
            | '$'
            | '#'
            | '@'
            | '~'
            | '`'
    )
}

fn is_word_like(s: &str) -> bool {
    s.chars().any(char::is_alphanumeric)
}

#[derive(Debug, Clone, Copy)]
struct WordSeg<'a> {
    text: &'a str,
    is_atomic: bool,
    word_like: bool,
    whitespace: bool,
}

fn word_segments_with_markers<'a>(
    text: &'a str,
    pastes: &BTreeMap<usize, String>,
) -> Vec<WordSeg<'a>> {
    let markers: Vec<MarkerSpan> = if pastes.is_empty() || !text.contains("[paste #") {
        Vec::new()
    } else {
        find_marker_spans(text)
            .into_iter()
            .filter(|m| pastes.contains_key(&m.id))
            .collect()
    };

    if markers.is_empty() {
        return text
            .split_word_bound_indices()
            .map(|(_, seg)| WordSeg {
                text: seg,
                is_atomic: false,
                word_like: is_word_like(seg),
                whitespace: is_whitespace_segment(seg),
            })
            .collect();
    }

    let mut out = Vec::new();
    let mut pos = 0usize;
    for marker in markers {
        if marker.start > pos {
            for (_, seg) in text[pos..marker.start].split_word_bound_indices() {
                out.push(WordSeg {
                    text: seg,
                    is_atomic: false,
                    word_like: is_word_like(seg),
                    whitespace: is_whitespace_segment(seg),
                });
            }
        }
        out.push(WordSeg {
            text: &text[marker.start..marker.end],
            is_atomic: true,
            word_like: true,
            whitespace: false,
        });
        pos = marker.end;
    }
    if pos < text.len() {
        for (_, seg) in text[pos..].split_word_bound_indices() {
            out.push(WordSeg {
                text: seg,
                is_atomic: false,
                word_like: is_word_like(seg),
                whitespace: is_whitespace_segment(seg),
            });
        }
    }
    out
}

fn find_word_backward(line: &str, cursor: usize, pastes: &BTreeMap<usize, String>) -> usize {
    if cursor == 0 {
        return 0;
    }
    let before = &line[..cursor];
    let mut segs = word_segments_with_markers(before, pastes);
    let mut new_cursor = cursor;

    while let Some(&last) = segs.last() {
        if !last.is_atomic && last.whitespace {
            new_cursor -= last.text.len();
            segs.pop();
        } else {
            break;
        }
    }

    let Some(last) = segs.last().copied() else {
        return new_cursor;
    };

    if last.is_atomic {
        return new_cursor - last.text.len();
    }

    if last.word_like {
        if let Some((punct_idx, punct_ch)) = last
            .text
            .char_indices()
            .rev()
            .find(|&(_, c)| is_ascii_word_punctuation(c))
        {
            let after_punct = punct_idx + punct_ch.len_utf8();
            if after_punct < last.text.len() {
                return new_cursor - (last.text.len() - after_punct);
            }
            return new_cursor - punct_ch.len_utf8();
        }
        return new_cursor - last.text.len();
    }

    while let Some(&last) = segs.last() {
        if !last.is_atomic && !last.word_like && !last.whitespace {
            new_cursor -= last.text.len();
            segs.pop();
        } else {
            break;
        }
    }
    new_cursor
}

fn find_word_forward(line: &str, cursor: usize, pastes: &BTreeMap<usize, String>) -> usize {
    if cursor >= line.len() {
        return line.len();
    }
    let after = &line[cursor..];
    let segs = word_segments_with_markers(after, pastes);
    let mut idx = 0usize;
    let mut new_cursor = cursor;

    while let Some(&seg) = segs.get(idx) {
        if !seg.is_atomic && seg.whitespace {
            new_cursor += seg.text.len();
            idx += 1;
        } else {
            break;
        }
    }

    let Some(&seg) = segs.get(idx) else {
        return new_cursor;
    };

    if seg.is_atomic {
        return new_cursor + seg.text.len();
    }

    if seg.word_like {
        if let Some((punct_idx, _)) = seg
            .text
            .char_indices()
            .find(|&(_, c)| is_ascii_word_punctuation(c))
        {
            if punct_idx > 0 {
                return new_cursor + punct_idx;
            }
        }
        return new_cursor + seg.text.len();
    }

    while let Some(&s) = segs.get(idx) {
        if !s.is_atomic && !s.word_like && !s.whitespace {
            new_cursor += s.text.len();
            idx += 1;
        } else {
            break;
        }
    }
    new_cursor
}

fn is_ctrl_char(event: KeyEvent, target: char) -> bool {
    matches!(event.code, KeyCode::Char(c) if c.to_ascii_lowercase() == target)
        && event.modifiers.contains(KeyModifiers::CONTROL)
        && !event
            .modifiers
            .intersects(KeyModifiers::ALT | KeyModifiers::SUPER)
}

fn is_alt_char(event: KeyEvent, target: char) -> bool {
    matches!(event.code, KeyCode::Char(c) if c.to_ascii_lowercase() == target)
        && event.modifiers.contains(KeyModifiers::ALT)
        && !event
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::SUPER)
}

fn printable_char(event: KeyEvent) -> Option<char> {
    if event
        .modifiers
        .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER)
    {
        return None;
    }
    match event.code {
        KeyCode::Char(c) => Some(c),
        _ => None,
    }
}

fn is_app_owned_key(event: KeyEvent, buf_empty: bool) -> bool {
    match event.code {
        KeyCode::Esc | KeyCode::Tab | KeyCode::BackTab | KeyCode::PageUp | KeyCode::PageDown => {
            true
        }
        KeyCode::Enter => {
            !event.modifiers.contains(KeyModifiers::SHIFT)
                || event
                    .modifiers
                    .intersects(KeyModifiers::ALT | KeyModifiers::CONTROL)
        }
        KeyCode::Char(c) if event.modifiers == KeyModifiers::CONTROL => {
            let lower = c.to_ascii_lowercase();
            matches!(lower, 'c' | 'g' | 'l' | 'o' | 'p' | 't' | 'v' | 'x' | 'z')
                || (lower == 'd' && buf_empty)
        }
        _ => false,
    }
}

fn is_newline_key(event: KeyEvent) -> bool {
    (event.code == KeyCode::Enter
        && event.modifiers.contains(KeyModifiers::SHIFT)
        && !event
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER))
        || is_ctrl_char(event, 'j')
}

fn is_undo_key(event: KeyEvent) -> bool {
    matches!(event.code, KeyCode::Char('-' | '_'))
        && event.modifiers.contains(KeyModifiers::CONTROL)
        && !event.modifiers.contains(KeyModifiers::SHIFT)
        && !event
            .modifiers
            .intersects(KeyModifiers::ALT | KeyModifiers::SUPER)
}

fn is_redo_key(event: KeyEvent) -> bool {
    (matches!(event.code, KeyCode::Char('-' | '_'))
        && event
            .modifiers
            .contains(KeyModifiers::CONTROL | KeyModifiers::SHIFT)
        && !event
            .modifiers
            .intersects(KeyModifiers::ALT | KeyModifiers::SUPER))
        || (matches!(event.code, KeyCode::Char('z' | 'Z'))
            && event
                .modifiers
                .contains(KeyModifiers::CONTROL | KeyModifiers::SHIFT)
            && !event
                .modifiers
                .intersects(KeyModifiers::ALT | KeyModifiers::SUPER))
}

fn is_delete_word_backward(event: KeyEvent) -> bool {
    is_ctrl_char(event, 'w')
        || (event.code == KeyCode::Backspace
            && event.modifiers.contains(KeyModifiers::ALT)
            && !event
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::SUPER))
}

fn is_delete_word_forward(event: KeyEvent) -> bool {
    is_alt_char(event, 'd')
        || (event.code == KeyCode::Delete
            && event.modifiers.contains(KeyModifiers::ALT)
            && !event
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::SUPER))
}

fn is_delete_char_backward(event: KeyEvent) -> bool {
    event.code == KeyCode::Backspace
        && !event
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER)
}

fn is_delete_char_forward(event: KeyEvent, buf_non_empty: bool) -> bool {
    (event.code == KeyCode::Delete
        && !event
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER))
        || (buf_non_empty && is_ctrl_char(event, 'd'))
}

fn is_line_start(event: KeyEvent) -> bool {
    (event.code == KeyCode::Home
        && !event
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER))
        || is_ctrl_char(event, 'a')
}

fn is_line_end(event: KeyEvent) -> bool {
    (event.code == KeyCode::End
        && !event
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER))
        || is_ctrl_char(event, 'e')
}

fn is_word_left(event: KeyEvent) -> bool {
    (event.code == KeyCode::Left
        && (event.modifiers == KeyModifiers::ALT || event.modifiers == KeyModifiers::CONTROL))
        || is_alt_char(event, 'b')
}

fn is_word_right(event: KeyEvent) -> bool {
    (event.code == KeyCode::Right
        && (event.modifiers == KeyModifiers::ALT || event.modifiers == KeyModifiers::CONTROL))
        || is_alt_char(event, 'f')
}

fn is_jump_forward(event: KeyEvent) -> bool {
    event.code == KeyCode::Char(']')
        && event.modifiers.contains(KeyModifiers::CONTROL)
        && !event
            .modifiers
            .intersects(KeyModifiers::ALT | KeyModifiers::SUPER)
}

fn is_jump_backward(event: KeyEvent) -> bool {
    event.code == KeyCode::Char(']')
        && event
            .modifiers
            .contains(KeyModifiers::CONTROL | KeyModifiers::ALT)
        && !event.modifiers.contains(KeyModifiers::SUPER)
}

fn is_cursor_up(event: KeyEvent) -> bool {
    event.code == KeyCode::Up
        && !event
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER)
}

fn is_cursor_down(event: KeyEvent) -> bool {
    event.code == KeyCode::Down
        && !event
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER)
}

fn is_cursor_left(event: KeyEvent) -> bool {
    (event.code == KeyCode::Left
        && !event
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER))
        || is_ctrl_char(event, 'b')
}

fn is_cursor_right(event: KeyEvent) -> bool {
    (event.code == KeyCode::Right
        && !event
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER))
        || is_ctrl_char(event, 'f')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn key_mod(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, modifiers)
    }

    fn type_str(ed: &mut Editor, s: &str) {
        for ch in s.chars() {
            assert!(ed.key(key(KeyCode::Char(ch))));
        }
    }

    #[test]
    fn default_and_basic_insertion_and_boundary() {
        let mut ed = Editor::default();
        assert_eq!(ed.text(), "");
        assert_eq!(ed.cursor(), 0);

        type_str(&mut ed, "hi");
        assert_eq!(ed.text(), "hi");
        assert_eq!(ed.cursor(), 2);
        assert!(ed.text().is_char_boundary(ed.cursor()));

        // Release events ignored
        assert!(!ed.key(KeyEvent::new_with_kind(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
            KeyEventKind::Release,
        )));
        assert_eq!(ed.text(), "hi");
    }

    #[test]
    fn app_owned_keys_return_false_and_ctrl_d_respects_empty_state() {
        let mut ed = Editor::new();
        assert!(!ed.key(key(KeyCode::Enter)));
        assert!(!ed.key(key_mod(KeyCode::Enter, KeyModifiers::ALT)));
        assert!(!ed.key(key(KeyCode::Esc)));
        assert!(!ed.key(key_mod(KeyCode::Char('c'), KeyModifiers::CONTROL)));
        assert!(!ed.key(key_mod(KeyCode::Char('g'), KeyModifiers::CONTROL)));
        assert!(!ed.key(key_mod(KeyCode::Char('d'), KeyModifiers::CONTROL)));
        assert!(!ed.key(key(KeyCode::Tab)));

        // Ctrl-D deletes forward when buffer non-empty
        ed.set("ab");
        assert!(ed.key(key(KeyCode::Home)));
        assert!(ed.key(key_mod(KeyCode::Char('d'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "b");
        assert_eq!(ed.cursor(), 0);

        // Delete remaining char, then Ctrl-D returns false again
        assert!(ed.key(key_mod(KeyCode::Char('d'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "");
        assert!(!ed.key(key_mod(KeyCode::Char('d'), KeyModifiers::CONTROL)));
    }

    #[test]
    fn ctrl_j_and_shift_enter_insert_newline() {
        let mut ed = Editor::new();
        type_str(&mut ed, "line1");
        assert!(ed.key(key_mod(KeyCode::Enter, KeyModifiers::SHIFT)));
        type_str(&mut ed, "line2");
        assert!(ed.key(key_mod(KeyCode::Char('j'), KeyModifiers::CONTROL)));
        type_str(&mut ed, "line3");

        assert_eq!(ed.text(), "line1\nline2\nline3");
        assert_eq!(ed.cursor(), ed.text().len());
    }

    #[test]
    fn unicode_graphemes_accents_zwj_flags_cjk_and_tabs() {
        let mut ed = Editor::new();
        // Combining accent, ZWJ family emoji, flag emoji, CJK
        let sample = "a\u{0301}👨‍👩‍👧‍👦🇺🇸你好";
        ed.set(sample);
        assert_eq!(ed.text(), sample);
        assert_eq!(ed.cursor(), sample.len());

        // Move left across each grapheme cluster atomically
        assert!(ed.key(key(KeyCode::Left))); // over 好
        assert_eq!(&ed.text()[ed.cursor()..], "好");
        assert!(ed.key(key(KeyCode::Left))); // over 你
        assert_eq!(&ed.text()[ed.cursor()..], "你好");
        assert!(ed.key(key(KeyCode::Left))); // over 🇺🇸
        assert_eq!(&ed.text()[ed.cursor()..], "🇺🇸你好");
        assert!(ed.key(key(KeyCode::Left))); // over 👨‍👩‍👧‍👦
        assert_eq!(&ed.text()[ed.cursor()..], "👨‍👩‍👧‍👦🇺🇸你好");
        assert!(ed.key(key(KeyCode::Left))); // over á
        assert_eq!(ed.cursor(), 0);

        // Move right past á, then backspace deletes whole grapheme cluster
        assert!(ed.key(key(KeyCode::Right)));
        assert_eq!(&ed.text()[ed.cursor()..], "👨‍👩‍👧‍👦🇺🇸你好");
        assert!(ed.key(key(KeyCode::Right))); // past ZWJ emoji
        assert!(ed.key(key(KeyCode::Backspace))); // delete whole ZWJ emoji
        assert_eq!(ed.text(), "a\u{0301}🇺🇸你好");
        assert!(ed.text().is_char_boundary(ed.cursor()));

        // Forward delete removes whole flag emoji
        assert!(ed.key(key(KeyCode::Delete)));
        assert_eq!(ed.text(), "a\u{0301}你好");

        // Tabs preserved
        ed.set("a\tb");
        assert_eq!(ed.text(), "a\tb");
        assert!(ed.key(key(KeyCode::Left))); // before b
        assert!(ed.key(key(KeyCode::Left))); // before \t
        assert_eq!(ed.cursor(), 1);
    }

    #[test]
    fn word_navigation_and_deletion_match_boundaries() {
        let mut ed = Editor::new();
        ed.set("foo.bar baz");
        assert!(ed.key(key_mod(KeyCode::Left, KeyModifiers::CONTROL)));
        assert_eq!(ed.cursor(), 8);
        assert!(ed.key(key_mod(KeyCode::Left, KeyModifiers::ALT)));
        assert_eq!(ed.cursor(), 4);
        assert!(ed.key(key_mod(KeyCode::Char('b'), KeyModifiers::ALT)));
        assert_eq!(ed.cursor(), 3);
        assert!(ed.key(key_mod(KeyCode::Left, KeyModifiers::CONTROL)));
        assert_eq!(ed.cursor(), 0);

        assert!(ed.key(key_mod(KeyCode::Right, KeyModifiers::CONTROL)));
        assert_eq!(ed.cursor(), 3);
        assert!(ed.key(key_mod(KeyCode::Char('f'), KeyModifiers::ALT)));
        assert_eq!(ed.cursor(), 4);
        assert!(ed.key(key_mod(KeyCode::Right, KeyModifiers::ALT)));
        assert_eq!(ed.cursor(), 7);
        assert!(ed.key(key_mod(KeyCode::Right, KeyModifiers::CONTROL)));
        assert_eq!(ed.cursor(), 11);

        // Punctuation run and emoji word deletion
        ed.set("foo 😀😀 bar...");
        assert!(ed.key(key_mod(KeyCode::Char('w'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "foo 😀😀 bar");
        assert!(ed.key(key_mod(KeyCode::Char('w'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "foo 😀😀 ");
        assert!(ed.key(key_mod(KeyCode::Backspace, KeyModifiers::ALT)));
        assert_eq!(ed.text(), "foo ");

        // Alt+D deletes forward
        ed.set("alpha beta gamma");
        ed.key(key(KeyCode::Home));
        assert!(ed.key(key_mod(KeyCode::Char('d'), KeyModifiers::ALT)));
        assert_eq!(ed.text(), " beta gamma");
        assert!(ed.key(key_mod(KeyCode::Delete, KeyModifiers::ALT)));
        assert_eq!(ed.text(), " gamma");

        // CJK punctuation stops
        ed.set("你好，世界");
        assert!(ed.key(key_mod(KeyCode::Left, KeyModifiers::CONTROL)));
        assert_eq!(&ed.text()[ed.cursor()..], "界");
        assert!(ed.key(key_mod(KeyCode::Left, KeyModifiers::CONTROL)));
        assert_eq!(&ed.text()[ed.cursor()..], "世界");
        assert!(ed.key(key_mod(KeyCode::Left, KeyModifiers::CONTROL)));
        assert_eq!(&ed.text()[ed.cursor()..], "，世界");
    }

    #[test]
    fn emacs_line_movement_and_char_jump() {
        let mut ed = Editor::new();
        ed.set("alpha beta\ngamma delta");
        assert!(ed.key(key_mod(KeyCode::Char('a'), KeyModifiers::CONTROL)));
        assert_eq!(&ed.text()[ed.cursor()..], "gamma delta");
        assert!(ed.key(key_mod(KeyCode::Char('f'), KeyModifiers::CONTROL)));
        assert_eq!(&ed.text()[ed.cursor()..], "amma delta");
        assert!(ed.key(key_mod(KeyCode::Char('e'), KeyModifiers::CONTROL)));
        assert_eq!(ed.cursor(), ed.text().len());

        // Jump backward Ctrl+Alt+]
        assert!(ed.key(key_mod(
            KeyCode::Char(']'),
            KeyModifiers::CONTROL | KeyModifiers::ALT
        )));
        assert!(ed.key(key(KeyCode::Char('b'))));
        assert_eq!(&ed.text()[ed.cursor()..], "beta\ngamma delta");

        // Jump forward Ctrl+]
        assert!(ed.key(key_mod(KeyCode::Char(']'), KeyModifiers::CONTROL)));
        assert!(ed.key(key(KeyCode::Char('d'))));
        assert_eq!(&ed.text()[ed.cursor()..], "delta");

        // Cancel jump mode on Esc passes Esc back to app
        assert!(ed.key(key_mod(KeyCode::Char(']'), KeyModifiers::CONTROL)));
        assert!(!ed.key(key(KeyCode::Esc)));
    }

    #[test]
    fn kill_ring_accumulation_and_yank_pop() {
        let mut ed = Editor::new();
        ed.set("one two three");
        assert!(ed.key(key_mod(KeyCode::Char('w'), KeyModifiers::CONTROL)));
        assert!(ed.key(key_mod(KeyCode::Char('w'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "one ");
        assert!(ed.key(key_mod(KeyCode::Char('y'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "one two three");

        // Separate kills -> yank + yank-pop cycles
        ed.set("first second third");
        assert!(ed.key(key_mod(KeyCode::Char('w'), KeyModifiers::CONTROL))); // "third"
        assert!(ed.key(key(KeyCode::Left))); // break accumulation
        assert!(ed.key(key_mod(KeyCode::Char('w'), KeyModifiers::CONTROL))); // "second"
        ed.set("prefix ");
        assert!(ed.key(key_mod(KeyCode::Char('y'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "prefix second");
        assert!(ed.key(key_mod(KeyCode::Char('y'), KeyModifiers::ALT)));
        assert_eq!(ed.text(), "prefix third");

        // Ctrl+U and Ctrl+K
        ed.set("left|right");
        ed.key(key(KeyCode::Home));
        for _ in 0..4 {
            ed.key(key(KeyCode::Right));
        }
        assert!(ed.key(key_mod(KeyCode::Char('u'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "|right");
        assert!(ed.key(key_mod(KeyCode::Char('k'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "");
        assert!(ed.key(key_mod(KeyCode::Char('y'), KeyModifiers::CONTROL)));
        // Consecutive kills accumulate: "left" + "|right"
        assert_eq!(ed.text(), "left|right");
    }

    #[test]
    fn grouped_undo_and_redo() {
        let mut ed = Editor::new();
        type_str(&mut ed, "hello world");
        // Fish-style: "hello" is unit 1, " world" is unit 2
        assert!(ed.key(key_mod(KeyCode::Char('-'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "hello");
        assert!(ed.key(key_mod(KeyCode::Char('-'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "");

        // Redo brings them back
        assert!(ed.key(key_mod(
            KeyCode::Char('-'),
            KeyModifiers::CONTROL | KeyModifiers::SHIFT
        )));
        assert_eq!(ed.text(), "hello");
        assert!(ed.key(key_mod(
            KeyCode::Char('z'),
            KeyModifiers::CONTROL | KeyModifiers::SHIFT
        )));
        assert_eq!(ed.text(), "hello world");

        // No-op delete does not push undo
        ed.set("");
        assert!(ed.key(key_mod(KeyCode::Char('w'), KeyModifiers::CONTROL)));
        assert!(ed.undo());
        assert_eq!(ed.text(), "hello world");
    }

    #[test]
    fn visual_line_up_down_sticky_col_and_1_col_resize() {
        let mut ed = Editor::new();
        ed.set("1234567890\nab\n1234567890");
        ed.key(key(KeyCode::Home));
        for _ in 0..7 {
            ed.key(key(KeyCode::Right));
        }
        assert_eq!(ed.cursor(), "1234567890\nab\n1234567".len());

        // Up to short line -> clamped to end of "ab"
        assert!(ed.key(key(KeyCode::Up)));
        assert_eq!(ed.cursor(), "1234567890\nab".len());
        // Up to first line -> sticky col 7 restored
        assert!(ed.key(key(KeyCode::Up)));
        assert_eq!(ed.cursor(), 7);
        // Down back through short line -> sticky col 7 restored
        assert!(ed.key(key(KeyCode::Down)));
        assert_eq!(ed.cursor(), "1234567890\nab".len());
        assert!(ed.key(key(KeyCode::Down)));
        assert_eq!(ed.cursor(), "1234567890\nab\n1234567".len());

        // Narrow 1-column wrap width must not panic or get stuck
        ed.set_width(1);
        ed.set("abc");
        assert!(ed.key(key(KeyCode::Up)));
        assert_eq!(ed.cursor(), 1);
        assert!(ed.key(key(KeyCode::Up)));
        assert_eq!(ed.cursor(), 0);
        assert!(ed.key(key(KeyCode::Down)));
        assert_eq!(ed.cursor(), 1);
    }

    #[test]
    fn paste_normalizes_crlf_never_dispatches_and_collapses_large_pastes() {
        let mut ed = Editor::new();
        // Bracketed paste with /quit and CRLF does not dispatch or submit
        ed.paste("  /quit\r\n  indented  \r");
        assert_eq!(ed.text(), "  /quit\n  indented  \n");
        // Submitted preserves leading/trailing whitespace
        let sent = ed.submitted();
        assert_eq!(sent, "  /quit\n  indented  \n");
        assert_eq!(ed.text(), "");

        // Large paste (> 10 lines) creates atomic marker and expands on submitted
        let big = (1..=12)
            .map(|i| format!("  line {i}  "))
            .collect::<Vec<_>>()
            .join("\r\n");
        ed.paste(&big);
        assert!(ed.text().starts_with("[paste #1 +12 lines]"));
        assert_eq!(ed.cursor(), ed.text().len());

        // Left arrow jumps across marker atomically
        assert!(ed.key(key(KeyCode::Left)));
        assert_eq!(ed.cursor(), 0);
        assert!(ed.key(key(KeyCode::Right)));
        assert_eq!(ed.cursor(), ed.text().len());

        // Second large paste (> 1000 chars, 1 line)
        let big_chars = "x".repeat(1200);
        ed.paste(&big_chars);
        assert!(ed.text().contains("[paste #2 1200 chars]"));

        // Delete first marker -> second renumbers to #1 and expands accurately
        ed.key(key(KeyCode::Home));
        assert!(ed.key(key(KeyCode::Delete)));
        assert_eq!(ed.text(), "[paste #1 1200 chars]");
        assert_eq!(ed.submitted(), big_chars);
    }

    #[test]
    fn paste_marker_undo_and_tmux_csi_u_decoding() {
        let mut ed = Editor::new();
        ed.paste("a\x1b[106;5ub");
        assert_eq!(ed.text(), "a\nb");

        ed.set("");
        let big_a = (0..12)
            .map(|i| format!("a{i}"))
            .collect::<Vec<_>>()
            .join("\n");
        let big_b = (0..12)
            .map(|i| format!("b{i}"))
            .collect::<Vec<_>>()
            .join("\n");
        ed.paste(&big_a);
        ed.paste(&big_b);
        ed.key(key(KeyCode::Home));
        ed.key(key(KeyCode::Right));
        assert!(ed.key(key(KeyCode::Backspace))); // deletes marker #1, renumbers #2 -> #1
        assert!(ed.undo()); // restores both markers and registry
        assert_eq!(ed.submitted(), format!("{big_a}{big_b}"));
    }

    #[test]
    fn history_navigation_dedup_draft_return_and_incremental_search() {
        let mut ed = Editor::new();
        // Empty/whitespace not recorded; consecutive duplicates deduped
        ed.set("   \n  ");
        assert_eq!(ed.submitted(), "   \n  ");
        assert_eq!(ed.history().len(), 0);

        ed.set("first prompt");
        assert_eq!(ed.submitted(), "first prompt");
        ed.set("first prompt");
        assert_eq!(ed.submitted(), "first prompt");
        assert_eq!(ed.history().len(), 1);

        ed.set("second\nmultiline");
        assert_eq!(ed.submitted(), "second\nmultiline");
        assert_eq!(ed.history().len(), 2);

        // Type draft and browse history
        ed.set("my draft");
        // First Up moves to col 0 on line 0, second Up enters history
        assert!(ed.key(key(KeyCode::Up)));
        assert_eq!(ed.text(), "my draft");
        assert_eq!(ed.cursor(), 0);
        assert!(ed.key(key(KeyCode::Up)));
        assert_eq!(ed.text(), "second\nmultiline");
        assert_eq!(ed.cursor(), 0);

        // Down moves to line 1 of multiline history, then back to draft (at col 0 where Up entered history)
        assert!(ed.key(key(KeyCode::Down)));
        assert_eq!(ed.cursor(), "second\n".len());
        assert!(ed.key(key(KeyCode::Down)));
        assert_eq!(ed.text(), "my draft");
        assert_eq!(ed.cursor(), 0);

        // Editing a history entry does not mutate stored history
        assert!(ed.key(key(KeyCode::Up)));
        assert!(ed.key(key(KeyCode::Up)));
        type_str(&mut ed, "edited ");
        assert_eq!(ed.history()[0], "second\nmultiline");

        // Incremental history search (Ctrl+R) and Esc closes search (returns true)
        ed.set("keep draft");
        assert!(ed.key(key_mod(KeyCode::Char('r'), KeyModifiers::CONTROL)));
        assert!(ed.is_searching_history());
        assert!(ed.key(key(KeyCode::Char('f'))));
        assert!(ed.key(key(KeyCode::Char('i'))));
        assert_eq!(ed.search_query(), Some("fi"));
        assert_eq!(ed.text(), "first prompt");
        // Esc cancels search and restores draft (and consumes Esc)
        assert!(ed.key(key(KeyCode::Esc)));
        assert!(!ed.is_searching_history());
        assert_eq!(ed.text(), "keep draft");

        // Ctrl+R then Enter accepts match
        assert!(ed.key(key_mod(KeyCode::Char('r'), KeyModifiers::CONTROL)));
        assert!(ed.key(key(KeyCode::Char('m'))));
        assert!(ed.key(key(KeyCode::Char('u'))));
        assert_eq!(ed.text(), "second\nmultiline");
        assert!(ed.key(key(KeyCode::Enter)));
        assert!(!ed.is_searching_history());
        assert_eq!(ed.text(), "second\nmultiline");
    }

    #[test]
    fn history_opt_out_bound_and_search_cycling() {
        let mut ed = Editor::new();
        ed.set_max_history(2);
        ed.set("alpha one");
        ed.submitted();
        ed.set("beta two");
        ed.submitted();
        ed.set("alpha three");
        ed.submitted();
        assert_eq!(ed.history().len(), 2);
        assert_eq!(ed.history()[0], "alpha three");
        assert_eq!(ed.history()[1], "beta two");

        // Multi-match Ctrl+R / Ctrl+S cycling and backspace in search
        ed.set_max_history(10);
        ed.set("alpha one");
        ed.submitted();
        ed.set("draft");
        assert!(ed.key(key_mod(KeyCode::Char('r'), KeyModifiers::CONTROL)));
        assert!(ed.key(key(KeyCode::Char('a'))));
        assert!(ed.key(key(KeyCode::Char('l'))));
        assert_eq!(ed.text(), "alpha one");
        assert!(ed.key(key_mod(KeyCode::Char('r'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "alpha three");
        assert!(ed.key(key_mod(KeyCode::Char('s'), KeyModifiers::CONTROL)));
        assert_eq!(ed.text(), "alpha one");
        assert!(ed.key(key(KeyCode::Backspace)));
        assert!(ed.key(key(KeyCode::Backspace)));
        assert_eq!(ed.text(), "draft");
        assert!(ed.key(key(KeyCode::Esc)));

        // Opt-out clears and disables history recording
        ed.set_history_enabled(false);
        assert_eq!(ed.history().len(), 0);
        ed.set("secret");
        assert_eq!(ed.submitted(), "secret");
        assert_eq!(ed.history().len(), 0);
    }

    #[test]
    fn manually_typed_paste_marker_is_not_atomic_and_multi_vl_paste_nav_works() {
        let mut ed = Editor::new();
        let fake = "[paste #99 +5 lines]";
        type_str(&mut ed, fake);
        assert!(ed.key(key(KeyCode::Home)));
        assert!(ed.key(key(KeyCode::Right)));
        assert_eq!(ed.cursor(), 1);

        // Multi-VL wrapped paste marker navigation at narrow width (20)
        ed.set_width(20);
        ed.set("");
        type_str(&mut ed, "abcdefgh");
        let big = (0..100)
            .map(|i| format!("l{i}"))
            .collect::<Vec<_>>()
            .join("\n");
        ed.paste(&big);
        type_str(&mut ed, "ijklmnopqr");
        assert!(ed.key(key_mod(KeyCode::Enter, KeyModifiers::SHIFT)));
        type_str(&mut ed, "123456789012345678");

        // Go to line 0 col 3 ('d'), navigate down through marker and skip continuation VL
        assert!(ed.key(key(KeyCode::Up))); // line 0 VL3
        assert!(ed.key(key(KeyCode::Up))); // marker start (col 8)
        assert!(ed.key(key(KeyCode::Up))); // VL0
        assert!(ed.key(key(KeyCode::Home)));
        for _ in 0..3 {
            ed.key(key(KeyCode::Right));
        }
        assert_eq!(ed.cursor(), 3);

        // Down into marker -> snaps to start (byte 8)
        assert!(ed.key(key(KeyCode::Down)));
        assert_eq!(ed.cursor(), 8);
        // Down again -> skips continuation VL tail and lands on line 1 col 3 ('4')
        assert!(ed.key(key(KeyCode::Down)));
        let line1_start = ed.text().find('\n').unwrap() + 1;
        assert_eq!(ed.cursor(), line1_start + 3);
    }

    #[test]
    fn undo_spaces_one_at_a_time_and_repeat_events_work() {
        let mut ed = Editor::new();
        type_str(&mut ed, "hi  ");
        assert!(ed.undo());
        assert_eq!(ed.text(), "hi ");
        assert!(ed.undo());
        assert_eq!(ed.text(), "hi");
        assert!(ed.undo());
        assert_eq!(ed.text(), "");

        assert!(ed.key(KeyEvent::new_with_kind(
            KeyCode::Char('x'),
            KeyModifiers::NONE,
            KeyEventKind::Repeat,
        )));
        assert_eq!(ed.text(), "x");
    }
}
