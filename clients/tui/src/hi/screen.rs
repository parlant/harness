use crate::render::{sanitize_single_line, sanitize_terminal_text};
use crossterm::event::{
    DisableBracketedPaste, EnableBracketedPaste, KeyboardEnhancementFlags,
    PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crossterm::{cursor, queue};
#[cfg(test)]
use ratatui::backend::TestBackend;
use ratatui::backend::{Backend, CrosstermBackend, WindowSize};
use ratatui::buffer::Buffer;
use ratatui::layout::{Position, Rect, Size};
use ratatui::style::{Modifier, Style};
use ratatui::widgets::{Block, Borders, Clear, Widget};
use ratatui::Terminal;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::io::{self, IsTerminal, Write};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

const TAB_WIDTH: usize = 4;
const TAB_SPACES: &str = "    ";
const EDITOR_PROMPT: &str = "> ";
const EDITOR_CONT_PREFIX: &str = "  ";

trait TerminalModeOps {
    fn enable_raw_mode(&mut self) -> io::Result<()>;
    fn disable_raw_mode(&mut self) -> io::Result<()>;
    fn enter_alt_screen(&mut self) -> io::Result<()>;
    fn leave_alt_screen(&mut self) -> io::Result<()>;
    fn enable_bracketed_paste(&mut self) -> io::Result<()>;
    fn disable_bracketed_paste(&mut self) -> io::Result<()>;
    fn push_keyboard_enhancement(&mut self) -> io::Result<()>;
    fn pop_keyboard_enhancement(&mut self) -> io::Result<()>;
    fn hide_cursor(&mut self) -> io::Result<()>;
    fn show_cursor(&mut self) -> io::Result<()>;
    fn flush(&mut self) -> io::Result<()>;
}

struct RealTerminalOps {
    stdout: io::Stdout,
}

impl RealTerminalOps {
    fn new() -> Self {
        Self {
            stdout: io::stdout(),
        }
    }
}

impl TerminalModeOps for RealTerminalOps {
    fn enable_raw_mode(&mut self) -> io::Result<()> {
        enable_raw_mode()
    }

    fn disable_raw_mode(&mut self) -> io::Result<()> {
        disable_raw_mode()
    }

    fn enter_alt_screen(&mut self) -> io::Result<()> {
        queue!(self.stdout, EnterAlternateScreen)
    }

    fn leave_alt_screen(&mut self) -> io::Result<()> {
        queue!(self.stdout, LeaveAlternateScreen)
    }

    fn enable_bracketed_paste(&mut self) -> io::Result<()> {
        queue!(self.stdout, EnableBracketedPaste)
    }

    fn disable_bracketed_paste(&mut self) -> io::Result<()> {
        queue!(self.stdout, DisableBracketedPaste)
    }

    fn push_keyboard_enhancement(&mut self) -> io::Result<()> {
        queue!(
            self.stdout,
            PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
        )
    }

    fn pop_keyboard_enhancement(&mut self) -> io::Result<()> {
        queue!(self.stdout, PopKeyboardEnhancementFlags)
    }

    fn hide_cursor(&mut self) -> io::Result<()> {
        queue!(self.stdout, cursor::Hide)
    }

    fn show_cursor(&mut self) -> io::Result<()> {
        queue!(self.stdout, cursor::Show)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.stdout.flush()
    }
}

struct TerminalModeGuard {
    ops: Option<Box<dyn TerminalModeOps>>,
    raw_mode: bool,
    alt_screen: bool,
    bracketed_paste: bool,
    keyboard_enhancement: bool,
    cleaned_up: bool,
}

impl TerminalModeGuard {
    #[cfg(test)]
    fn noop() -> Self {
        Self {
            ops: None,
            raw_mode: false,
            alt_screen: false,
            bracketed_paste: false,
            keyboard_enhancement: false,
            cleaned_up: true,
        }
    }

    fn enter(ops: Box<dyn TerminalModeOps>) -> io::Result<Self> {
        let mut guard = Self {
            ops: Some(ops),
            raw_mode: false,
            alt_screen: false,
            bracketed_paste: false,
            keyboard_enhancement: false,
            cleaned_up: false,
        };

        if let Err(err) = guard.enter_inner() {
            let _ = guard.cleanup();
            return Err(err);
        }
        Ok(guard)
    }

    fn enter_inner(&mut self) -> io::Result<()> {
        let ops = self.ops.as_deref_mut().expect("ops present");
        ops.enable_raw_mode()?;
        self.raw_mode = true;

        ops.enter_alt_screen()?;
        self.alt_screen = true;

        ops.enable_bracketed_paste()?;
        self.bracketed_paste = true;

        ops.push_keyboard_enhancement()?;
        self.keyboard_enhancement = true;

        ops.hide_cursor()?;
        ops.flush()?;
        Ok(())
    }

    fn cleanup(&mut self) -> io::Result<()> {
        if self.cleaned_up {
            return Ok(());
        }
        self.cleaned_up = true;

        let Some(ops) = self.ops.as_deref_mut() else {
            return Ok(());
        };

        let mut first_err: Option<io::Error> = None;
        let mut record_err = |res: io::Result<()>| {
            if let Err(e) = res {
                if first_err.is_none() {
                    first_err = Some(e);
                }
            }
        };

        if self.keyboard_enhancement {
            record_err(ops.pop_keyboard_enhancement());
            self.keyboard_enhancement = false;
        }
        if self.bracketed_paste {
            record_err(ops.disable_bracketed_paste());
            self.bracketed_paste = false;
        }
        if self.alt_screen || self.raw_mode {
            record_err(ops.show_cursor());
        }
        if self.alt_screen {
            record_err(ops.leave_alt_screen());
            self.alt_screen = false;
        }
        record_err(ops.flush());

        if self.raw_mode {
            record_err(ops.disable_raw_mode());
            self.raw_mode = false;
        }

        match first_err {
            Some(err) => Err(err),
            None => Ok(()),
        }
    }
}

impl Drop for TerminalModeGuard {
    fn drop(&mut self) {
        let _ = self.cleanup();
    }
}

enum ScreenBackend {
    Crossterm(CrosstermBackend<io::Stdout>),
    #[cfg(test)]
    Test(TestBackend),
}

impl Backend for ScreenBackend {
    fn draw<'a, I>(&mut self, content: I) -> io::Result<()>
    where
        I: Iterator<Item = (u16, u16, &'a ratatui::buffer::Cell)>,
    {
        match self {
            ScreenBackend::Crossterm(b) => b.draw(content),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.draw(content),
        }
    }

    fn hide_cursor(&mut self) -> io::Result<()> {
        match self {
            ScreenBackend::Crossterm(b) => b.hide_cursor(),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.hide_cursor(),
        }
    }

    fn show_cursor(&mut self) -> io::Result<()> {
        match self {
            ScreenBackend::Crossterm(b) => b.show_cursor(),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.show_cursor(),
        }
    }

    fn get_cursor_position(&mut self) -> io::Result<Position> {
        match self {
            ScreenBackend::Crossterm(b) => b.get_cursor_position(),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.get_cursor_position(),
        }
    }

    fn set_cursor_position<P: Into<Position>>(&mut self, position: P) -> io::Result<()> {
        match self {
            ScreenBackend::Crossterm(b) => b.set_cursor_position(position),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.set_cursor_position(position),
        }
    }

    fn clear(&mut self) -> io::Result<()> {
        match self {
            ScreenBackend::Crossterm(b) => b.clear(),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.clear(),
        }
    }

    fn clear_region(&mut self, clear_type: ratatui::backend::ClearType) -> io::Result<()> {
        match self {
            ScreenBackend::Crossterm(b) => b.clear_region(clear_type),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.clear_region(clear_type),
        }
    }

    fn size(&self) -> io::Result<Size> {
        match self {
            ScreenBackend::Crossterm(b) => b.size(),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.size(),
        }
    }

    fn window_size(&mut self) -> io::Result<WindowSize> {
        match self {
            ScreenBackend::Crossterm(b) => b.window_size(),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.window_size(),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            ScreenBackend::Crossterm(b) => Backend::flush(b),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.flush(),
        }
    }
}

#[derive(Debug, Clone)]
enum ScrollState {
    Bottom,
    Scrolled {
        pending_delta: i32,
        from_bottom: usize,
        top_anchor: Option<(usize, usize)>,
        anchor_row_hash: Option<u64>,
    },
}

pub struct Screen {
    terminal: Terminal<ScreenBackend>,
    _guard: TerminalModeGuard,
    scroll_state: ScrollState,
    editor_scroll: usize,
}

impl Screen {
    pub fn open() -> io::Result<Self> {
        let term = std::env::var("TERM").ok();
        check_open_env(
            io::stdin().is_terminal(),
            io::stdout().is_terminal(),
            term.as_deref(),
        )?;

        let guard = TerminalModeGuard::enter(Box::new(RealTerminalOps::new()))?;
        let backend = ScreenBackend::Crossterm(CrosstermBackend::new(io::stdout()));
        let terminal = Terminal::new(backend)?;

        Ok(Self {
            terminal,
            _guard: guard,
            scroll_state: ScrollState::Bottom,
            editor_scroll: 0,
        })
    }

    #[cfg(test)]
    pub(crate) fn with_test_backend(width: u16, height: u16) -> io::Result<Self> {
        let backend = ScreenBackend::Test(TestBackend::new(width, height));
        let terminal = Terminal::new(backend)?;
        Ok(Self {
            terminal,
            _guard: TerminalModeGuard::noop(),
            scroll_state: ScrollState::Bottom,
            editor_scroll: 0,
        })
    }

    #[cfg(test)]
    pub(crate) fn test_backend(&self) -> &TestBackend {
        match self.terminal.backend() {
            ScreenBackend::Test(b) => b,
            ScreenBackend::Crossterm(_) => unreachable!(),
        }
    }

    #[cfg(test)]
    pub(crate) fn resize_test_backend(&mut self, width: u16, height: u16) {
        if let ScreenBackend::Test(ref mut b) = self.terminal.backend_mut() {
            b.resize(width, height);
        }
    }

    pub fn scroll(&mut self, lines: i32) {
        if lines == 0 {
            return;
        }
        match &mut self.scroll_state {
            ScrollState::Bottom => {
                if lines > 0 {
                    self.scroll_state = ScrollState::Scrolled {
                        pending_delta: lines,
                        from_bottom: 0,
                        top_anchor: None,
                        anchor_row_hash: None,
                    };
                }
            }
            ScrollState::Scrolled { pending_delta, .. } => {
                *pending_delta = pending_delta.saturating_add(lines);
            }
        }
    }

    pub fn bottom(&mut self) {
        self.scroll_state = ScrollState::Bottom;
    }

    pub fn draw(
        &mut self,
        rows: &[String],
        editor: &str,
        cursor: usize,
        status: &str,
        overlay: &[String],
    ) -> io::Result<()> {
        let mut next_scroll_state = self.scroll_state.clone();
        let mut next_editor_scroll = self.editor_scroll;

        self.terminal.draw(|frame| {
            let area = frame.area();
            if area.width == 0 || area.height == 0 {
                return;
            }

            let width = area.width as usize;
            let use_prompt = width >= 4;
            let prefix_width = if use_prompt { 2 } else { 0 };
            let editor_content_width = width.saturating_sub(prefix_width).max(1);

            let editor_layout = layout_editor(editor, cursor, editor_content_width);
            let layout = compute_layout(area.height, editor_layout.lines.len());

            // 1. Transcript rows
            if layout.transcript_height > 0 {
                let wrapped_rows = wrap_transcript_rows(rows, width);
                let total_visual = wrapped_rows.len();
                let view_h = layout.transcript_height as usize;
                let max_top = total_visual.saturating_sub(view_h);

                let (top, updated_scroll) =
                    resolve_scroll_top(&next_scroll_state, rows, &wrapped_rows, max_top);
                next_scroll_state = updated_scroll;

                let end = (top + view_h).min(total_visual);
                let buf = frame.buffer_mut();
                for (offset, vline) in wrapped_rows[top..end].iter().enumerate() {
                    let y = area.y + offset as u16;
                    write_segments_to_row(buf, area.x, y, width, &vline.segments, Style::default());
                }
            }

            // 2. Separator line
            let scrolled_lines = match &next_scroll_state {
                ScrollState::Bottom => 0,
                ScrollState::Scrolled { from_bottom, .. } => *from_bottom,
            };
            if let Some(sep_y) = layout.separator_y {
                render_separator(
                    frame.buffer_mut(),
                    area.x,
                    area.y + sep_y,
                    area.width,
                    scrolled_lines,
                );
            }

            // 3. Editor area + draft cursor
            let visible_editor_h = layout.editor_height as usize;
            let cursor_visual_row = editor_layout.cursor_row;
            if cursor_visual_row < next_editor_scroll {
                next_editor_scroll = cursor_visual_row;
            } else if visible_editor_h > 0
                && cursor_visual_row >= next_editor_scroll + visible_editor_h
            {
                next_editor_scroll = cursor_visual_row + 1 - visible_editor_h;
            }
            let max_ed_scroll = editor_layout.lines.len().saturating_sub(visible_editor_h);
            next_editor_scroll = next_editor_scroll.min(max_ed_scroll);

            let mut cursor_pos: Option<Position> = None;
            let buf = frame.buffer_mut();
            for row_offset in 0..visible_editor_h {
                let line_idx = next_editor_scroll + row_offset;
                let Some(ed_line) = editor_layout.lines.get(line_idx) else {
                    break;
                };
                let y = area.y + layout.editor_y + row_offset as u16;
                if use_prompt {
                    let prefix = if line_idx == 0 {
                        EDITOR_PROMPT
                    } else {
                        EDITOR_CONT_PREFIX
                    };
                    let p_style = if line_idx == 0 {
                        Style::default().add_modifier(Modifier::BOLD)
                    } else {
                        Style::default()
                    };
                    write_plain_str_to_row(buf, area.x, y, prefix_width, prefix, p_style);
                }
                write_segments_to_row(
                    buf,
                    area.x + prefix_width as u16,
                    y,
                    editor_content_width,
                    &ed_line.segments,
                    Style::default(),
                );
                if line_idx == editor_layout.cursor_row {
                    let cx = (area.x as usize + prefix_width + editor_layout.cursor_col)
                        .min(area.x as usize + width.saturating_sub(1))
                        as u16;
                    cursor_pos = Some(Position::new(cx, y));
                }
            }

            // 4. Status bar
            if let Some(status_y) = layout.status_y {
                let safe_status = sanitize_single_line(status);
                let style = Style::default().add_modifier(Modifier::REVERSED);
                let y = area.y + status_y;
                // Fill entire status bar width with reversed background
                for dx in 0..area.width {
                    buf[(area.x + dx, y)].set_symbol(" ").set_style(style);
                }
                write_plain_str_to_row(buf, area.x, y, width, &safe_status, style);
            }

            // 5. Overlay (modal/picker/completion)
            let overlay_rect = if !overlay.is_empty() {
                render_overlay(frame.buffer_mut(), area, overlay)
            } else {
                None
            };

            if let Some(pos) = cursor_pos {
                let covered_by_overlay = overlay_rect.is_some_and(|r| {
                    pos.x >= r.x && pos.x < r.x + r.width && pos.y >= r.y && pos.y < r.y + r.height
                });
                if !covered_by_overlay {
                    frame.set_cursor_position(pos);
                }
            }
        })?;

        self.scroll_state = next_scroll_state;
        self.editor_scroll = next_editor_scroll;
        Ok(())
    }
}

fn check_open_env(stdin_tty: bool, stdout_tty: bool, term: Option<&str>) -> io::Result<()> {
    if !stdin_tty || !stdout_tty {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "interactive screen requires a TTY on stdin and stdout",
        ));
    }
    if term.is_some_and(|v| v.eq_ignore_ascii_case("dumb")) {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "interactive screen is disabled when TERM=dumb",
        ));
    }
    Ok(())
}

struct ScreenLayout {
    transcript_height: u16,
    separator_y: Option<u16>,
    editor_y: u16,
    editor_height: u16,
    status_y: Option<u16>,
}

fn compute_layout(total_height: u16, editor_visual_lines: usize) -> ScreenLayout {
    if total_height == 0 {
        return ScreenLayout {
            transcript_height: 0,
            separator_y: None,
            editor_y: 0,
            editor_height: 0,
            status_y: None,
        };
    }
    if total_height == 1 {
        return ScreenLayout {
            transcript_height: 0,
            separator_y: None,
            editor_y: 0,
            editor_height: 1,
            status_y: None,
        };
    }
    if total_height == 2 {
        return ScreenLayout {
            transcript_height: 0,
            separator_y: None,
            editor_y: 0,
            editor_height: 1,
            status_y: Some(1),
        };
    }
    if total_height <= 4 {
        let editor_h = 1u16;
        let status_y = total_height - 1;
        let editor_y = status_y - editor_h;
        return ScreenLayout {
            transcript_height: editor_y,
            separator_y: None,
            editor_y,
            editor_height: editor_h,
            status_y: Some(status_y),
        };
    }

    // total_height >= 5: transcript + 1 separator + editor + 1 status
    let status_h = 1u16;
    let sep_h = 1u16;
    let max_editor = ((total_height as usize * 3) / 10)
        .max(3)
        .min((total_height - status_h - sep_h - 1) as usize);
    let editor_h = editor_visual_lines.clamp(1, max_editor) as u16;
    let status_y = total_height - 1;
    let editor_y = status_y - editor_h;
    let separator_y = editor_y - 1;

    ScreenLayout {
        transcript_height: separator_y,
        separator_y: Some(separator_y),
        editor_y,
        editor_height: editor_h,
        status_y: Some(status_y),
    }
}

fn render_separator(buf: &mut Buffer, x: u16, y: u16, width: u16, scrolled_lines: usize) {
    let dim = Style::default().add_modifier(Modifier::DIM);
    for dx in 0..width {
        buf[(x + dx, y)].set_symbol("─").set_style(dim);
    }
    if scrolled_lines > 0 && width >= 8 {
        let badge = format!(" [↑ {scrolled_lines}] ");
        let badge_w = display_str_width(&badge);
        if badge_w <= width as usize {
            let start_x = x + (width - badge_w as u16);
            write_plain_str_to_row(
                buf,
                start_x,
                y,
                badge_w,
                &badge,
                Style::default().add_modifier(Modifier::BOLD),
            );
        }
    }
}

#[derive(Debug, Clone)]
struct RenderSeg {
    text: String,
    width: usize,
    orig_start: usize,
    orig_end: usize,
    is_whitespace: bool,
    is_cjk: bool,
}

#[derive(Debug, Clone)]
struct WrappedRow {
    row_idx: usize,
    sub_idx: usize,
    segments: Vec<RenderSeg>,
}

#[derive(Debug, Clone)]
struct EditorVisualLine {
    segments: Vec<RenderSeg>,
}

struct EditorLayout {
    lines: Vec<EditorVisualLine>,
    cursor_row: usize,
    cursor_col: usize,
}

fn hash_str(s: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    s.hash(&mut hasher);
    hasher.finish()
}

fn is_regional_indicator(cp: u32) -> bool {
    (0x1F1E6..=0x1F1FF).contains(&cp)
}

fn is_cjk_char(ch: char) -> bool {
    let cp = ch as u32;
    matches!(
        cp,
        0x3040..=0x309F // Hiragana
            | 0x30A0..=0x30FF // Katakana
            | 0x3100..=0x312F // Bopomofo
            | 0x3400..=0x4DBF // CJK Unified Ideographs Ext A
            | 0x4E00..=0x9FFF // CJK Unified Ideographs
            | 0xAC00..=0xD7AF // Hangul Syllables
            | 0xF900..=0xFAFF // CJK Compatibility Ideographs
            | 0x20000..=0x2A6DF // CJK Ext B
    )
}

fn grapheme_display_width(g: &str) -> usize {
    if g == "\t" {
        return TAB_WIDTH;
    }
    if g.len() == 1 {
        let b = g.as_bytes()[0];
        if (0x20..=0x7E).contains(&b) {
            return 1;
        }
    }
    if let Some(first_cp) = g.chars().find(|&c| {
        let u = c as u32;
        !(u == 0xFE0E || u == 0xFE0F || u == 0x200D || (0x0300..=0x036F).contains(&u))
    }) {
        if is_regional_indicator(first_cp as u32) {
            return 2;
        }
    }
    let w = UnicodeWidthStr::width(g);
    // Single-codepoint or ZWJ emoji with VS16 should occupy 2 cells when terminal renders emoji.
    if w == 1 && (g.contains('\u{FE0F}') || g.contains('\u{200D}')) {
        return 2;
    }
    w
}

fn display_str_width(s: &str) -> usize {
    s.graphemes(true).map(grapheme_display_width).sum()
}

fn sanitize_graphemes_for_line(line: &str) -> Vec<RenderSeg> {
    let safe = sanitize_terminal_text(line);
    let mut segs = Vec::new();
    for g in safe.graphemes(true) {
        if g == "\t" {
            segs.push(RenderSeg {
                text: TAB_SPACES.to_string(),
                width: TAB_WIDTH,
                orig_start: 0,
                orig_end: 0,
                is_whitespace: true,
                is_cjk: false,
            });
        } else {
            let w = grapheme_display_width(g);
            let is_ws = g.chars().all(|c| c == ' ');
            let is_cjk = g.chars().next().is_some_and(is_cjk_char);
            segs.push(RenderSeg {
                text: g.to_string(),
                width: w,
                orig_start: 0,
                orig_end: 0,
                is_whitespace: is_ws,
                is_cjk,
            });
        }
    }
    segs
}

fn wrap_segments(segs: &[RenderSeg], max_width: usize) -> Vec<Vec<RenderSeg>> {
    if max_width == 0 {
        return vec![Vec::new()];
    }
    if segs.is_empty() {
        return vec![Vec::new()];
    }

    let total_w: usize = segs.iter().map(|s| s.width).sum();
    if total_w <= max_width {
        return vec![segs.to_vec()];
    }

    let mut chunks: Vec<Vec<RenderSeg>> = Vec::new();
    let mut chunk_start = 0usize;
    let mut current_w = 0usize;
    let mut wrap_opp_idx: Option<usize> = None;
    let mut wrap_opp_w = 0usize;

    let mut i = 0usize;
    while i < segs.len() {
        let seg = &segs[i];
        let g_w = seg.width;

        if current_w + g_w > max_width {
            if let Some(opp) = wrap_opp_idx {
                if current_w - wrap_opp_w + g_w <= max_width {
                    chunks.push(segs[chunk_start..opp].to_vec());
                    chunk_start = opp;
                    current_w -= wrap_opp_w;
                    wrap_opp_idx = None;
                    continue;
                }
            }
            if chunk_start < i {
                chunks.push(segs[chunk_start..i].to_vec());
                chunk_start = i;
                current_w = 0;
                wrap_opp_idx = None;
                continue;
            }
            // Single grapheme wider than max_width (e.g. width 2 in a 1-column terminal).
            chunks.push(vec![seg.clone()]);
            chunk_start = i + 1;
            current_w = 0;
            wrap_opp_idx = None;
            i += 1;
            continue;
        }

        current_w += g_w;

        if let Some(next) = segs.get(i + 1) {
            if !next.is_whitespace && (seg.is_whitespace || seg.is_cjk || next.is_cjk) {
                wrap_opp_idx = Some(i + 1);
                wrap_opp_w = current_w;
            }
        }

        i += 1;
    }

    if chunk_start < segs.len() {
        chunks.push(segs[chunk_start..].to_vec());
    }
    if chunks.is_empty() {
        chunks.push(Vec::new());
    }
    chunks
}

fn wrap_transcript_rows(rows: &[String], width: usize) -> Vec<WrappedRow> {
    let mut out = Vec::new();
    for (row_idx, raw_row) in rows.iter().enumerate() {
        let safe = sanitize_terminal_text(raw_row);
        let mut sub_idx = 0usize;
        for logical in safe.split('\n') {
            let segs = sanitize_graphemes_for_line(logical);
            for chunk in wrap_segments(&segs, width) {
                out.push(WrappedRow {
                    row_idx,
                    sub_idx,
                    segments: chunk,
                });
                sub_idx += 1;
            }
        }
    }
    out
}

fn resolve_scroll_top(
    state: &ScrollState,
    rows: &[String],
    wrapped: &[WrappedRow],
    max_top: usize,
) -> (usize, ScrollState) {
    match state {
        ScrollState::Bottom => (max_top, ScrollState::Bottom),
        ScrollState::Scrolled {
            pending_delta,
            from_bottom,
            top_anchor,
            anchor_row_hash,
        } => {
            if max_top == 0 {
                return (0, ScrollState::Bottom);
            }

            let mut base_top = max_top.saturating_sub(*from_bottom);
            if let (Some((r_idx, sub_idx)), Some(expected_hash)) = (top_anchor, anchor_row_hash) {
                if *r_idx < rows.len() && hash_str(&rows[*r_idx]) == *expected_hash {
                    if let Some(pos) = wrapped
                        .iter()
                        .position(|w| w.row_idx == *r_idx && w.sub_idx == *sub_idx)
                        .or_else(|| wrapped.iter().rposition(|w| w.row_idx == *r_idx))
                    {
                        base_top = pos.min(max_top);
                    }
                }
            }

            let new_top =
                (base_top as isize - *pending_delta as isize).clamp(0, max_top as isize) as usize;
            let new_from_bottom = max_top.saturating_sub(new_top);

            if new_from_bottom == 0 {
                (max_top, ScrollState::Bottom)
            } else {
                let (anchor, row_hash) = wrapped
                    .get(new_top)
                    .and_then(|w| {
                        rows.get(w.row_idx)
                            .map(|r| (Some((w.row_idx, w.sub_idx)), Some(hash_str(r))))
                    })
                    .unwrap_or((None, None));
                (
                    new_top,
                    ScrollState::Scrolled {
                        pending_delta: 0,
                        from_bottom: new_from_bottom,
                        top_anchor: anchor,
                        anchor_row_hash: row_hash,
                    },
                )
            }
        }
    }
}

struct SanitizedEditorLine {
    orig_start: usize,
    orig_end: usize,
    delim_end: usize,
    segments: Vec<RenderSeg>,
}

fn sanitize_editor_lines(editor: &str) -> Vec<SanitizedEditorLine> {
    let mut lines = Vec::new();
    let bytes = editor.as_bytes();
    let mut line_start = 0usize;
    let mut i = 0usize;

    while i < bytes.len() {
        if bytes[i] == b'\n' {
            let segs = sanitize_editor_line_slice(editor, line_start, i);
            lines.push(SanitizedEditorLine {
                orig_start: line_start,
                orig_end: i,
                delim_end: i + 1,
                segments: segs,
            });
            line_start = i + 1;
            i += 1;
        } else if bytes[i] == b'\r' && bytes.get(i + 1) == Some(&b'\n') {
            let segs = sanitize_editor_line_slice(editor, line_start, i);
            lines.push(SanitizedEditorLine {
                orig_start: line_start,
                orig_end: i,
                delim_end: i + 2,
                segments: segs,
            });
            line_start = i + 2;
            i += 2;
        } else {
            i += 1;
        }
    }

    let segs = sanitize_editor_line_slice(editor, line_start, editor.len());
    lines.push(SanitizedEditorLine {
        orig_start: line_start,
        orig_end: editor.len(),
        delim_end: editor.len(),
        segments: segs,
    });

    lines
}

fn sanitize_editor_line_slice(editor: &str, start: usize, end: usize) -> Vec<RenderSeg> {
    let slice = &editor[start..end];
    let mut segs = Vec::new();
    for (rel_idx, g) in slice.grapheme_indices(true) {
        let orig_start = start + rel_idx;
        let orig_end = orig_start + g.len();

        if g == "\t" {
            segs.push(RenderSeg {
                text: TAB_SPACES.to_string(),
                width: TAB_WIDTH,
                orig_start,
                orig_end,
                is_whitespace: true,
                is_cjk: false,
            });
            continue;
        }

        if g.len() == 1 || g.chars().count() == 1 {
            let ch = g.chars().next().expect("non-empty grapheme");
            if let Some(escaped) = escape_unsafe_char(ch) {
                let w = display_str_width(&escaped);
                segs.push(RenderSeg {
                    text: escaped,
                    width: w,
                    orig_start,
                    orig_end,
                    is_whitespace: false,
                    is_cjk: false,
                });
                continue;
            }
        }

        // Clean any unsafe chars inside a multi-char grapheme if present
        let mut clean = String::new();
        let mut had_unsafe = false;
        for ch in g.chars() {
            if let Some(escaped) = escape_unsafe_char(ch) {
                clean.push_str(&escaped);
                had_unsafe = true;
            } else {
                clean.push(ch);
            }
        }
        let text = if had_unsafe { clean } else { g.to_string() };
        let w = grapheme_display_width(&text);
        let is_ws = text.chars().all(|c| c == ' ');
        let is_cjk = text.chars().next().is_some_and(is_cjk_char);
        segs.push(RenderSeg {
            text,
            width: w,
            orig_start,
            orig_end,
            is_whitespace: is_ws,
            is_cjk,
        });
    }
    segs
}

fn escape_unsafe_char(ch: char) -> Option<String> {
    match ch {
        '\r' => Some("\\r".to_string()),
        '\x1b' => Some("\\x1b".to_string()),
        '\x00'..='\x1f' if ch != '\n' && ch != '\t' => Some(format!("\\x{:02x}", ch as u32)),
        '\x7f' => Some("\\x7f".to_string()),
        '\u{0080}'..='\u{009f}' => Some(format!("\\u{{{:04x}}}", ch as u32)),
        _ => None,
    }
}

fn layout_editor(editor: &str, raw_cursor: usize, content_width: usize) -> EditorLayout {
    let mut cursor = raw_cursor.min(editor.len());
    while cursor > 0 && !editor.is_char_boundary(cursor) {
        cursor -= 1;
    }

    let logical_lines = sanitize_editor_lines(editor);
    let mut visual_lines = Vec::new();
    let mut cursor_row = 0usize;
    let mut cursor_col = 0usize;

    for (line_idx, line) in logical_lines.iter().enumerate() {
        let is_last_logical = line_idx + 1 == logical_lines.len();
        let cursor_on_line =
            cursor >= line.orig_start && (is_last_logical || cursor < line.delim_end);
        let line_cursor = cursor.min(line.orig_end);

        let chunks = wrap_segments(&line.segments, content_width);
        let chunk_count = chunks.len();

        for (chunk_idx, chunk) in chunks.into_iter().enumerate() {
            let is_last_chunk = chunk_idx + 1 == chunk_count;
            let chunk_start = chunk.first().map_or(line.orig_start, |s| s.orig_start);
            let chunk_end = chunk.last().map_or(line.orig_end, |s| s.orig_end);

            let visual_row_idx = visual_lines.len();
            let cursor_in_chunk = cursor_on_line
                && (if is_last_chunk {
                    line_cursor >= chunk_start
                } else {
                    line_cursor >= chunk_start && line_cursor < chunk_end
                });

            let mut need_trailing_cursor_line = false;
            if cursor_in_chunk {
                let col: usize = chunk
                    .iter()
                    .take_while(|s| s.orig_start < line_cursor)
                    .map(|s| s.width)
                    .sum();
                if col >= content_width && content_width > 1 && is_last_chunk {
                    need_trailing_cursor_line = true;
                } else {
                    cursor_row = visual_row_idx;
                    cursor_col = col.min(content_width.saturating_sub(1));
                }
            }

            visual_lines.push(EditorVisualLine { segments: chunk });

            if need_trailing_cursor_line {
                cursor_row = visual_lines.len();
                cursor_col = 0;
                visual_lines.push(EditorVisualLine {
                    segments: Vec::new(),
                });
            }
        }
    }

    if visual_lines.is_empty() {
        visual_lines.push(EditorVisualLine {
            segments: Vec::new(),
        });
    }

    EditorLayout {
        lines: visual_lines,
        cursor_row,
        cursor_col,
    }
}

fn render_overlay(buf: &mut Buffer, area: Rect, overlay: &[String]) -> Option<Rect> {
    if area.width == 0 || area.height == 0 || overlay.is_empty() {
        return None;
    }

    let bordered = area.width >= 6 && area.height >= 4;
    let max_box_w = if bordered {
        (area.width as usize).saturating_sub(2).max(4)
    } else {
        area.width as usize
    };
    let inner_max_w = if bordered {
        max_box_w.saturating_sub(2).max(1)
    } else {
        max_box_w.max(1)
    };

    let mut wrapped_lines: Vec<Vec<RenderSeg>> = Vec::new();
    let mut widest_content = 0usize;
    for raw in overlay {
        let safe = sanitize_terminal_text(raw);
        for logical in safe.split('\n') {
            let segs = sanitize_graphemes_for_line(logical);
            for chunk in wrap_segments(&segs, inner_max_w) {
                let w: usize = chunk.iter().map(|s| s.width).sum();
                widest_content = widest_content.max(w);
                wrapped_lines.push(chunk);
            }
        }
    }

    if wrapped_lines.is_empty() {
        wrapped_lines.push(Vec::new());
    }

    let (box_w, box_h, inner_w, inner_h) = if bordered {
        let desired_w = (widest_content + 2).clamp(16.min(max_box_w), max_box_w);
        let max_box_h = (area.height as usize).saturating_sub(2).max(3);
        let desired_h = (wrapped_lines.len() + 2).min(max_box_h);
        (
            desired_w as u16,
            desired_h as u16,
            desired_w - 2,
            desired_h - 2,
        )
    } else {
        let desired_w = widest_content.clamp(1, area.width as usize);
        let desired_h = wrapped_lines.len().clamp(1, area.height as usize);
        (desired_w as u16, desired_h as u16, desired_w, desired_h)
    };

    let box_x = area.x + (area.width.saturating_sub(box_w)) / 2;
    let box_y = area.y + (area.height.saturating_sub(box_h)) / 2;
    let rect = Rect::new(box_x, box_y, box_w, box_h);

    // Protect left CJK/wide-character boundary before clearing the overlay rect:
    // if cell (rect.x - 1, y) holds a width-2 grapheme that overlaps rect.x, clear it to space.
    if rect.x > area.x {
        let left_x = rect.x - 1;
        for y in rect.y..rect.y + rect.height {
            let sym = buf[(left_x, y)].symbol();
            if grapheme_display_width(sym) > 1 {
                buf[(left_x, y)].set_symbol(" ");
            }
        }
    }

    Clear.render(rect, buf);

    let inner_rect = if bordered {
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().add_modifier(Modifier::DIM));
        let inner = block.inner(rect);
        block.render(rect, buf);
        inner
    } else {
        rect
    };

    for (idx, line) in wrapped_lines.iter().take(inner_h).enumerate() {
        let y = inner_rect.y + idx as u16;
        write_segments_to_row(buf, inner_rect.x, y, inner_w, line, Style::default());
    }

    Some(rect)
}

fn write_plain_str_to_row(
    buf: &mut Buffer,
    start_x: u16,
    y: u16,
    max_width: usize,
    text: &str,
    style: Style,
) {
    let segs = sanitize_graphemes_for_line(text);
    write_segments_to_row(buf, start_x, y, max_width, &segs, style);
}

fn write_segments_to_row(
    buf: &mut Buffer,
    start_x: u16,
    y: u16,
    max_width: usize,
    segs: &[RenderSeg],
    style: Style,
) {
    if max_width == 0 {
        return;
    }
    let area = buf.area;
    if y < area.y || y >= area.y + area.height {
        return;
    }

    let mut col = 0usize;
    for seg in segs {
        if col >= max_width {
            break;
        }
        let w = seg.width;
        if w == 0 {
            continue;
        }
        if col + w > max_width {
            if max_width == 1 && col == 0 {
                let x = start_x;
                if x >= area.x && x < area.x + area.width {
                    buf[(x, y)].set_symbol("·").set_style(style);
                }
            }
            break;
        }
        let x = start_x + col as u16;
        if x >= area.x && x < area.x + area.width {
            let ratatui_w = UnicodeWidthStr::width(seg.text.as_str());
            if ratatui_w != w && w == 2 && ratatui_w == 1 {
                // Keep buffer cell width consistent with ratatui's Buffer::diff()
                buf[(x, y)].set_symbol(&seg.text).set_style(style);
                if x + 1 < area.x + area.width {
                    buf[(x + 1, y)].set_symbol(" ").set_style(style);
                }
            } else {
                buf[(x, y)].set_symbol(&seg.text).set_style(style);
                for dx in 1..w {
                    if x + dx as u16 >= area.x + area.width {
                        break;
                    }
                    buf[(x + dx as u16, y)].set_symbol(" ").set_style(style);
                }
            }
        }
        col += w;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    #[derive(Default)]
    struct MockOpsLog {
        events: Vec<&'static str>,
        fail_at: Option<&'static str>,
        raw_mode_active: bool,
        alt_screen_active: bool,
        paste_active: bool,
        keyboard_active: bool,
    }

    struct MockTerminalOps {
        log: Rc<RefCell<MockOpsLog>>,
    }

    impl MockTerminalOps {
        fn maybe_fail(&self, step: &'static str) -> io::Result<()> {
            if self.log.borrow().fail_at == Some(step) {
                return Err(io::Error::other(step));
            }
            Ok(())
        }
    }

    impl TerminalModeOps for MockTerminalOps {
        fn enable_raw_mode(&mut self) -> io::Result<()> {
            self.maybe_fail("enable_raw_mode")?;
            let mut log = self.log.borrow_mut();
            log.raw_mode_active = true;
            log.events.push("enable_raw_mode");
            Ok(())
        }

        fn disable_raw_mode(&mut self) -> io::Result<()> {
            let mut log = self.log.borrow_mut();
            log.raw_mode_active = false;
            log.events.push("disable_raw_mode");
            Ok(())
        }

        fn enter_alt_screen(&mut self) -> io::Result<()> {
            self.maybe_fail("enter_alt_screen")?;
            let mut log = self.log.borrow_mut();
            log.alt_screen_active = true;
            log.events.push("enter_alt_screen");
            Ok(())
        }

        fn leave_alt_screen(&mut self) -> io::Result<()> {
            let mut log = self.log.borrow_mut();
            log.alt_screen_active = false;
            log.events.push("leave_alt_screen");
            Ok(())
        }

        fn enable_bracketed_paste(&mut self) -> io::Result<()> {
            self.maybe_fail("enable_bracketed_paste")?;
            let mut log = self.log.borrow_mut();
            log.paste_active = true;
            log.events.push("enable_bracketed_paste");
            Ok(())
        }

        fn disable_bracketed_paste(&mut self) -> io::Result<()> {
            let mut log = self.log.borrow_mut();
            log.paste_active = false;
            log.events.push("disable_bracketed_paste");
            Ok(())
        }

        fn push_keyboard_enhancement(&mut self) -> io::Result<()> {
            self.maybe_fail("push_keyboard_enhancement")?;
            let mut log = self.log.borrow_mut();
            log.keyboard_active = true;
            log.events.push("push_keyboard_enhancement");
            Ok(())
        }

        fn pop_keyboard_enhancement(&mut self) -> io::Result<()> {
            let mut log = self.log.borrow_mut();
            log.keyboard_active = false;
            log.events.push("pop_keyboard_enhancement");
            Ok(())
        }

        fn hide_cursor(&mut self) -> io::Result<()> {
            self.log.borrow_mut().events.push("hide_cursor");
            Ok(())
        }

        fn show_cursor(&mut self) -> io::Result<()> {
            self.log.borrow_mut().events.push("show_cursor");
            Ok(())
        }

        fn flush(&mut self) -> io::Result<()> {
            self.log.borrow_mut().events.push("flush");
            Ok(())
        }
    }

    fn buffer_row_text(buf: &Buffer, y: u16) -> String {
        let mut s = String::new();
        for x in 0..buf.area.width {
            s.push_str(buf[(x, y)].symbol());
        }
        s.trim_end().to_string()
    }

    fn buffer_all_text(buf: &Buffer) -> Vec<String> {
        (0..buf.area.height)
            .map(|y| buffer_row_text(buf, y))
            .collect()
    }

    #[test]
    fn guard_restores_all_modes_on_drop_and_unwind() {
        let log = Rc::new(RefCell::new(MockOpsLog::default()));
        {
            let _guard = TerminalModeGuard::enter(Box::new(MockTerminalOps {
                log: Rc::clone(&log),
            }))
            .unwrap();
            assert!(log.borrow().raw_mode_active);
            assert!(log.borrow().alt_screen_active);
            assert!(log.borrow().paste_active);
            assert!(log.borrow().keyboard_active);
        }
        let borrowed = log.borrow();
        assert!(!borrowed.raw_mode_active);
        assert!(!borrowed.alt_screen_active);
        assert!(!borrowed.paste_active);
        assert!(!borrowed.keyboard_active);
        assert_eq!(
            borrowed.events,
            vec![
                "enable_raw_mode",
                "enter_alt_screen",
                "enable_bracketed_paste",
                "push_keyboard_enhancement",
                "hide_cursor",
                "flush",
                "pop_keyboard_enhancement",
                "disable_bracketed_paste",
                "show_cursor",
                "leave_alt_screen",
                "flush",
                "disable_raw_mode",
            ]
        );
    }

    #[test]
    fn guard_unwinds_partial_init_on_error() {
        let log = Rc::new(RefCell::new(MockOpsLog {
            fail_at: Some("push_keyboard_enhancement"),
            ..Default::default()
        }));
        let res = TerminalModeGuard::enter(Box::new(MockTerminalOps {
            log: Rc::clone(&log),
        }));
        assert!(res.is_err());

        let borrowed = log.borrow();
        assert!(!borrowed.raw_mode_active);
        assert!(!borrowed.alt_screen_active);
        assert!(!borrowed.paste_active);
        assert!(!borrowed.keyboard_active);
        assert_eq!(
            borrowed.events,
            vec![
                "enable_raw_mode",
                "enter_alt_screen",
                "enable_bracketed_paste",
                "disable_bracketed_paste",
                "show_cursor",
                "leave_alt_screen",
                "flush",
                "disable_raw_mode",
            ]
        );
    }

    #[test]
    fn guard_cleans_up_on_panic_unwind() {
        let log = Rc::new(RefCell::new(MockOpsLog::default()));
        let log_clone = Rc::clone(&log);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard =
                TerminalModeGuard::enter(Box::new(MockTerminalOps { log: log_clone })).unwrap();
            panic!("simulated ui panic");
        }));
        assert!(result.is_err());

        let borrowed = log.borrow();
        assert!(!borrowed.raw_mode_active);
        assert!(!borrowed.alt_screen_active);
        assert!(!borrowed.paste_active);
        assert!(!borrowed.keyboard_active);
    }

    #[test]
    fn non_tty_open_fails_cleanly_without_raw_mode() {
        // Under cargo test, stdin/stdout are pipes (non-TTY), so Screen::open() must refuse.
        if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
            let err = Screen::open().err().expect("open must fail when non-TTY");
            assert_eq!(err.kind(), io::ErrorKind::Unsupported);
        }
    }

    #[test]
    fn draw_renders_rows_editor_status_and_cursor() {
        let mut screen = Screen::with_test_backend(40, 10).unwrap();
        let rows = vec!["user: hello".to_string(), "assistant: world".to_string()];
        screen
            .draw(&rows, "draft text", 5, "[seq 1 · idle]", &[])
            .unwrap();

        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(lines[0], "user: hello");
        assert_eq!(lines[1], "assistant: world");
        assert!(lines[7].starts_with("────"));
        assert_eq!(lines[8], "> draft text");
        assert_eq!(lines[9], "[seq 1 · idle]");

        // Prompt is "> " (2 cols), cursor at byte 5 ("draft") -> x = 2 + 5 = 7, y = 8
        assert_eq!(
            screen.terminal.get_cursor_position().unwrap(),
            Position::new(7, 8)
        );
    }

    #[test]
    fn cursor_tracks_utf8_cjk_accents_zwj_and_tabs() {
        let mut screen = Screen::with_test_backend(40, 8).unwrap();

        // CJK "你好" (each width 2 -> 4 cols) + "a"
        let text = "你好a";
        screen.draw(&[], text, "你好".len(), "ok", &[]).unwrap();
        // "> " (2) + "你好" (4) = col 6, row 6
        assert_eq!(
            screen.terminal.get_cursor_position().unwrap(),
            Position::new(6, 6)
        );

        // Tab expands to 4 spaces
        let tab_text = "a\tb";
        screen.draw(&[], tab_text, 2, "ok", &[]).unwrap();
        // "> " (2) + "a" (1) + "\t" (4) = col 7
        assert_eq!(
            screen.terminal.get_cursor_position().unwrap(),
            Position::new(7, 6)
        );

        // Combining accent "e\u{0301}" (1 cell) + "x"
        let accent = "e\u{0301}x";
        screen
            .draw(&[], accent, "e\u{0301}".len(), "ok", &[])
            .unwrap();
        // "> " (2) + 1 = col 3
        assert_eq!(
            screen.terminal.get_cursor_position().unwrap(),
            Position::new(3, 6)
        );

        // ZWJ emoji "👨‍💻" (2 cells) + "z"
        let zwj = "👨‍💻z";
        screen.draw(&[], zwj, "👨‍💻".len(), "ok", &[]).unwrap();
        // "> " (2) + 2 = col 4
        assert_eq!(
            screen.terminal.get_cursor_position().unwrap(),
            Position::new(4, 6)
        );

        // Invalid mid-UTF8 byte cursor must clamp safely without panicking
        screen.draw(&[], "你好", 1, "ok", &[]).unwrap();
        assert_eq!(
            screen.terminal.get_cursor_position().unwrap(),
            Position::new(2, 6)
        );
    }

    #[test]
    fn editor_wraps_and_scrolls_internally_to_keep_cursor_visible() {
        let mut screen = Screen::with_test_backend(14, 10).unwrap();
        // Width 14 -> prefix 2 -> content width 12
        // "hello world foo bar" wraps cleanly at spaces into 3 lines:
        // "hello world ", "foo bar" -> 2 lines, let's test 3 lines then 5 lines (internal scroll).
        let three_lines = "hello world second line third";
        screen
            .draw(&[], three_lines, three_lines.len(), "ok", &[])
            .unwrap();

        let lines = buffer_all_text(screen.test_backend().buffer());
        // max_editor for height 10 is (10*3/10).max(3) = 3
        assert_eq!(lines[6], "> hello world");
        assert_eq!(lines[7], "  second line");
        assert_eq!(lines[8], "  third");
        assert_eq!(
            screen.terminal.get_cursor_position().unwrap(),
            Position::new(7, 8)
        );

        // 5 logical lines: editor must scroll internally so cursor on line 5 is visible on row 8
        let five_lines = "l1\nl2\nl3\nl4\nl5";
        screen
            .draw(&[], five_lines, five_lines.len(), "ok", &[])
            .unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(lines[6], "  l3");
        assert_eq!(lines[7], "  l4");
        assert_eq!(lines[8], "  l5");
        assert_eq!(
            screen.terminal.get_cursor_position().unwrap(),
            Position::new(4, 8)
        );

        // Moving cursor back to line 1 scrolls editor back up to show "> l1"
        screen.draw(&[], five_lines, 1, "ok", &[]).unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(lines[6], "> l1");
        assert_eq!(lines[7], "  l2");
        assert_eq!(lines[8], "  l3");
        assert_eq!(
            screen.terminal.get_cursor_position().unwrap(),
            Position::new(3, 6)
        );

        // Full-width single line places cursor on trailing soft-wrapped line:
        // "123456789012" + trailing cursor line = 2 lines (y=7 and y=8 for height 10)
        let exact = "123456789012";
        screen.draw(&[], exact, exact.len(), "ok", &[]).unwrap();
        assert_eq!(
            screen.terminal.get_cursor_position().unwrap(),
            Position::new(2, 8)
        );
    }

    #[test]
    fn scroll_positive_toward_older_and_bottom_returns_to_tail() {
        let mut screen = Screen::with_test_backend(30, 8).unwrap();
        // height 8 -> status(1) + editor(1) + sep(1) = 3, transcript = 5 rows
        let rows: Vec<String> = (1..=20).map(|i| format!("row {i:02}")).collect();

        // Initially at bottom: rows 16..=20
        screen.draw(&rows, "", 0, "ok", &[]).unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(
            &lines[0..5],
            &["row 16", "row 17", "row 18", "row 19", "row 20"]
        );

        // Scroll up 5 toward older: rows 11..=15
        screen.scroll(5);
        screen.draw(&rows, "", 0, "ok", &[]).unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(
            &lines[0..5],
            &["row 11", "row 12", "row 13", "row 14", "row 15"]
        );
        assert!(lines[5].contains("[↑ 5]"));

        // While scrolled up, appending new rows keeps anchor on row 11!
        let mut rows_extended = rows.clone();
        rows_extended.push("row 21".to_string());
        rows_extended.push("row 22".to_string());
        screen.draw(&rows_extended, "", 0, "ok", &[]).unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(
            &lines[0..5],
            &["row 11", "row 12", "row 13", "row 14", "row 15"]
        );

        // Scroll negative moves back toward newer
        screen.scroll(-2);
        screen.draw(&rows_extended, "", 0, "ok", &[]).unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(
            &lines[0..5],
            &["row 13", "row 14", "row 15", "row 16", "row 17"]
        );

        // bottom() jumps back to live tail
        screen.bottom();
        screen.draw(&rows_extended, "", 0, "ok", &[]).unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(
            &lines[0..5],
            &["row 18", "row 19", "row 20", "row 21", "row 22"]
        );
    }

    #[test]
    fn scroll_clamps_at_top_so_scroll_down_responds_immediately() {
        let mut screen = Screen::with_test_backend(30, 8).unwrap();
        let rows: Vec<String> = (1..=10).map(|i| format!("row {i:02}")).collect();

        screen.scroll(500);
        screen.draw(&rows, "", 0, "ok", &[]).unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(
            &lines[0..5],
            &["row 01", "row 02", "row 03", "row 04", "row 05"]
        );

        // Scrolling down by 1 immediately advances to row 02
        screen.scroll(-1);
        screen.draw(&rows, "", 0, "ok", &[]).unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(
            &lines[0..5],
            &["row 02", "row 03", "row 04", "row 05", "row 06"]
        );
    }

    #[test]
    fn resize_reflows_and_shrinks_without_panicking() {
        let mut screen = Screen::with_test_backend(40, 12).unwrap();
        let rows = vec![
            "first line with several words to wrap nicely".to_string(),
            "second line 日本語テスト 🎉".to_string(),
        ];
        screen.draw(&rows, "hello world", 5, "status", &[]).unwrap();

        // Shrink to 10x4
        screen.resize_test_backend(10, 4);
        screen.draw(&rows, "hello world", 5, "status", &[]).unwrap();

        // Shrink all the way to 1x1 (1-column resize test with CJK/emoji!)
        screen.resize_test_backend(1, 1);
        screen
            .draw(&["让👍a".to_string()], "让b", 3, "status\nline2", &[])
            .unwrap();
        let pos = screen.terminal.get_cursor_position().unwrap();
        assert_eq!(pos.x, 0);
        assert_eq!(pos.y, 0);

        // Also draw with an overlay on 1x1 without panicking
        screen
            .draw(
                &["让👍a".to_string()],
                "让b",
                3,
                "status",
                &["ov".to_string()],
            )
            .unwrap();

        // Expand back
        screen.resize_test_backend(40, 12);
        screen.draw(&rows, "hello world", 5, "status", &[]).unwrap();
    }

    #[test]
    fn overlay_renders_and_protects_cjk_left_boundary() {
        let mut screen = Screen::with_test_backend(20, 10).unwrap();
        // Place "abcd让EFGH" on every transcript row so the overlay left border hits column 2/3 or inside a wide char.
        // For width 20 and overlay width 16 (min 16), box_x = (20-16)/2 = 2.
        // Put a wide char at column 1..3: "a让bcd" -> 'a' at 0, '让' at 1..3 (crosses col 2!).
        let rows: Vec<String> = (0..6).map(|_| "a让bcdefghijkl".to_string()).collect();
        let overlay = vec!["Pick model".to_string(), "1. claude".to_string()];

        screen.draw(&rows, "hi", 2, "ok", &overlay).unwrap();
        let buf = screen.test_backend().buffer();

        // Row 3..7 has the overlay box starting at x=2.
        // Verify cell at x=1 on overlay rows was cleared from "让" (width 2) to " " so it doesn't collide with '┌'/'│'.
        for y in 3..7 {
            assert_eq!(
                buf[(1, y)].symbol(),
                " ",
                "wide char at col 1 row {y} must be cleared"
            );
        }
        let all = buffer_all_text(buf).join("\n");
        assert!(all.contains("Pick model"));
        assert!(all.contains("1. claude"));
    }

    #[test]
    fn untrusted_inputs_cannot_emit_escape_or_control_sequences() {
        let mut screen = Screen::with_test_backend(40, 10).unwrap();
        let evil_row = "hi\x1b[31mred\x1b]0;pwn\x07\x08\u{009b}2J";
        let evil_editor = "ed\x1b[2J";
        let evil_status = "st\x1b[1m\nfake";
        let evil_overlay = "ov\x1b]52;c;YQ==\x07";

        screen
            .draw(
                &[evil_row.to_string()],
                evil_editor,
                evil_editor.len(),
                evil_status,
                &[evil_overlay.to_string()],
            )
            .unwrap();

        let buf = screen.test_backend().buffer();
        for y in 0..buf.area.height {
            for x in 0..buf.area.width {
                let sym = buf[(x, y)].symbol();
                assert!(!sym.contains('\x1b'), "raw ESC leaked at ({x},{y})");
                assert!(!sym.contains('\x07'), "raw BEL leaked at ({x},{y})");
                assert!(!sym.contains('\x08'), "raw BS leaked at ({x},{y})");
                assert!(!sym.contains('\u{009b}'), "raw CSI leaked at ({x},{y})");
            }
        }
        let joined = buffer_all_text(buf).join("\n");
        assert!(joined.contains("\\x1b[31m"));
        assert!(joined.contains("st\\x1b[1m\\nfake"));
    }

    #[test]
    fn regional_indicator_singleton_and_flag_widths_match_pi_regression() {
        assert_eq!(grapheme_display_width("🇨"), 2);
        assert_eq!(grapheme_display_width("🇨🇳"), 2);
        assert_eq!(grapheme_display_width("👍"), 2);
        assert_eq!(grapheme_display_width("👍🏻"), 2);
        assert_eq!(grapheme_display_width("⚡️"), 2);
        assert_eq!(grapheme_display_width("👨‍💻"), 2);
        assert_eq!(grapheme_display_width("🏳️‍🌈"), 2);

        let segs = sanitize_graphemes_for_line("      - 🇨");
        let wrapped = wrap_segments(&segs, 9);
        assert_eq!(wrapped.len(), 2);
        let w0: usize = wrapped[0].iter().map(|s| s.width).sum();
        let w1: usize = wrapped[1].iter().map(|s| s.width).sum();
        assert!(w0 <= 9);
        assert_eq!(w1, 2);
    }

    #[test]
    fn open_env_rejects_non_tty_and_dumb_term() {
        assert_eq!(
            check_open_env(false, true, Some("xterm-256color"))
                .unwrap_err()
                .kind(),
            io::ErrorKind::Unsupported
        );
        assert_eq!(
            check_open_env(true, false, Some("xterm-256color"))
                .unwrap_err()
                .kind(),
            io::ErrorKind::Unsupported
        );
        assert_eq!(
            check_open_env(true, true, Some("dumb")).unwrap_err().kind(),
            io::ErrorKind::Unsupported
        );
        assert_eq!(
            check_open_env(true, true, Some("DUMB")).unwrap_err().kind(),
            io::ErrorKind::Unsupported
        );
        assert!(check_open_env(true, true, Some("xterm-256color")).is_ok());
        assert!(check_open_env(true, true, None).is_ok());
    }

    #[test]
    fn shrinking_content_clears_stale_lines() {
        let mut screen = Screen::with_test_backend(40, 10).unwrap();
        let rows = vec![
            "first".to_string(),
            "second".to_string(),
            "third".to_string(),
        ];
        screen.draw(&rows, "l1\nl2\nl3", 8, "busy", &[]).unwrap();
        let before = buffer_all_text(screen.test_backend().buffer()).join("\n");
        assert!(before.contains("first"));
        assert!(before.contains("third"));

        // Shrink both transcript and editor to empty/single line
        screen.draw(&[], "", 0, "idle", &[]).unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        for line in &lines {
            assert!(!line.contains("first"));
            assert!(!line.contains("second"));
            assert!(!line.contains("third"));
            assert!(!line.contains("l2"));
            assert!(!line.contains("l3"));
        }
        assert_eq!(lines[8], ">");
        assert_eq!(lines[9], "idle");
    }

    #[test]
    fn scroll_anchor_and_draft_survive_stream_resize_and_overlay_cycle() {
        let mut screen = Screen::with_test_backend(40, 10).unwrap();
        let mut rows: Vec<String> = (1..=20)
            .map(|i| format!("entry {i:02} alpha beta"))
            .collect();

        // Scroll up 8 lines from bottom (height=10 -> transcript=7 -> top is entry 06)
        screen.scroll(8);
        screen
            .draw(&rows, "draft msg", 5, "streaming", &[])
            .unwrap();
        let top_before = buffer_row_text(screen.test_backend().buffer(), 0);
        assert_eq!(top_before, "entry 06 alpha beta");

        // Append streaming rows, resize narrower (width 40 -> 15), and open overlay
        rows.push("entry 21 streaming".to_string());
        screen.resize_test_backend(15, 10);
        screen
            .draw(
                &rows,
                "draft msg",
                5,
                "streaming",
                &["Select".to_string(), "1. A".to_string()],
            )
            .unwrap();

        // Dismiss overlay and resize back: entry 06 remains the top anchor, draft intact
        screen.resize_test_backend(40, 10);
        screen
            .draw(&rows, "draft msg", 5, "streaming", &[])
            .unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(lines[0], "entry 06 alpha beta");
        assert_eq!(lines[8], "> draft msg");
        assert_eq!(
            screen.terminal.get_cursor_position().unwrap(),
            Position::new(7, 8)
        );
    }
}
