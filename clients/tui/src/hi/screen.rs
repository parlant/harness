use super::markdown::StyledRow;
use super::theme::Theme;
use crate::render::{sanitize_single_line, sanitize_terminal_text};
use crossterm::event::{
    DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
    KeyboardEnhancementFlags, PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, size as terminal_size, EnterAlternateScreen,
    LeaveAlternateScreen,
};
use crossterm::{cursor, queue};
#[cfg(test)]
use ratatui::backend::TestBackend;
use ratatui::backend::{Backend, CrosstermBackend, WindowSize};
use ratatui::buffer::Buffer;
use ratatui::layout::{Position, Rect, Size};
use ratatui::style::{Color, Modifier, Style};
use ratatui::Terminal;
use std::collections::hash_map::DefaultHasher;
use std::fmt::Write as _;
use std::hash::Hasher;
use std::io::{self, IsTerminal, Write};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

const TAB_WIDTH: usize = 4;
const TAB_SPACES: &str = "    ";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScreenMode {
    Fullscreen,
    Regular,
}

trait TerminalModeOps {
    fn enable_raw_mode(&mut self) -> io::Result<()>;
    fn disable_raw_mode(&mut self) -> io::Result<()>;
    fn enter_alt_screen(&mut self) -> io::Result<()>;
    fn leave_alt_screen(&mut self) -> io::Result<()>;
    fn enable_bracketed_paste(&mut self) -> io::Result<()>;
    fn disable_bracketed_paste(&mut self) -> io::Result<()>;
    fn push_keyboard_enhancement(&mut self) -> io::Result<()>;
    fn pop_keyboard_enhancement(&mut self) -> io::Result<()>;
    fn enable_mouse_capture(&mut self) -> io::Result<()>;
    fn disable_mouse_capture(&mut self) -> io::Result<()>;
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

    fn enable_mouse_capture(&mut self) -> io::Result<()> {
        queue!(self.stdout, EnableMouseCapture)
    }

    fn disable_mouse_capture(&mut self) -> io::Result<()> {
        queue!(self.stdout, DisableMouseCapture)
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
    mouse_capture: bool,
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
            mouse_capture: false,
            cleaned_up: true,
        }
    }

    fn enter(ops: Box<dyn TerminalModeOps>, mode: ScreenMode) -> io::Result<Self> {
        let mut guard = Self {
            ops: Some(ops),
            raw_mode: false,
            alt_screen: false,
            bracketed_paste: false,
            keyboard_enhancement: false,
            mouse_capture: false,
            cleaned_up: false,
        };

        if let Err(err) = guard.enter_inner(mode) {
            let _ = guard.cleanup();
            return Err(err);
        }
        Ok(guard)
    }

    fn enter_inner(&mut self, mode: ScreenMode) -> io::Result<()> {
        let ops = self.ops.as_deref_mut().expect("ops present");
        ops.enable_raw_mode()?;
        self.raw_mode = true;

        if mode == ScreenMode::Fullscreen {
            ops.enter_alt_screen()?;
            self.alt_screen = true;
        }

        ops.enable_bracketed_paste()?;
        self.bracketed_paste = true;

        ops.push_keyboard_enhancement()?;
        self.keyboard_enhancement = true;

        if mode == ScreenMode::Fullscreen {
            ops.enable_mouse_capture()?;
            self.mouse_capture = true;
            ops.hide_cursor()?;
        }

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

        if self.mouse_capture {
            record_err(ops.disable_mouse_capture());
            self.mouse_capture = false;
        }
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
    type Error = io::Error;

    fn draw<'a, I>(&mut self, content: I) -> io::Result<()>
    where
        I: Iterator<Item = (u16, u16, &'a ratatui::buffer::Cell)>,
    {
        match self {
            ScreenBackend::Crossterm(b) => b.draw(content),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.draw(content).map_err(|never| match never {}),
        }
    }

    fn hide_cursor(&mut self) -> io::Result<()> {
        match self {
            ScreenBackend::Crossterm(b) => b.hide_cursor(),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.hide_cursor().map_err(|never| match never {}),
        }
    }

    fn show_cursor(&mut self) -> io::Result<()> {
        match self {
            ScreenBackend::Crossterm(b) => b.show_cursor(),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.show_cursor().map_err(|never| match never {}),
        }
    }

    fn get_cursor_position(&mut self) -> io::Result<Position> {
        match self {
            ScreenBackend::Crossterm(b) => b.get_cursor_position(),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.get_cursor_position().map_err(|never| match never {}),
        }
    }

    fn set_cursor_position<P: Into<Position>>(&mut self, position: P) -> io::Result<()> {
        match self {
            ScreenBackend::Crossterm(b) => b.set_cursor_position(position),
            #[cfg(test)]
            ScreenBackend::Test(b) => b
                .set_cursor_position(position)
                .map_err(|never| match never {}),
        }
    }

    fn clear(&mut self) -> io::Result<()> {
        match self {
            ScreenBackend::Crossterm(b) => b.clear(),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.clear().map_err(|never| match never {}),
        }
    }

    fn clear_region(&mut self, clear_type: ratatui::backend::ClearType) -> io::Result<()> {
        match self {
            ScreenBackend::Crossterm(b) => b.clear_region(clear_type),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.clear_region(clear_type).map_err(|never| match never {}),
        }
    }

    fn size(&self) -> io::Result<Size> {
        match self {
            ScreenBackend::Crossterm(b) => b.size(),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.size().map_err(|never| match never {}),
        }
    }

    fn window_size(&mut self) -> io::Result<WindowSize> {
        match self {
            ScreenBackend::Crossterm(b) => b.window_size(),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.window_size().map_err(|never| match never {}),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            ScreenBackend::Crossterm(b) => Backend::flush(b),
            #[cfg(test)]
            ScreenBackend::Test(b) => b.flush().map_err(|never| match never {}),
        }
    }
}

trait RegularTarget {
    fn size(&self) -> io::Result<(u16, u16)>;
    fn write_bytes(&mut self, data: &[u8]) -> io::Result<()>;
    fn flush(&mut self) -> io::Result<()>;
}

struct StdoutRegularTarget {
    stdout: io::Stdout,
}

impl StdoutRegularTarget {
    fn new() -> Self {
        Self {
            stdout: io::stdout(),
        }
    }
}

impl RegularTarget for StdoutRegularTarget {
    fn size(&self) -> io::Result<(u16, u16)> {
        terminal_size()
    }

    fn write_bytes(&mut self, data: &[u8]) -> io::Result<()> {
        self.stdout.write_all(data)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.stdout.flush()
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

struct FullscreenState {
    terminal: Terminal<ScreenBackend>,
    scroll_state: ScrollState,
    editor_scroll: usize,
}

struct RegularState {
    target: Box<dyn RegularTarget>,
    flushed_visual_lines: Vec<String>,
    working_lines: Vec<String>,
    cursor_row: usize,
    cursor_visible: bool,
    editor_scroll: usize,
    prev_width: u16,
    prev_height: u16,
    cached_width: usize,
    cached_row_hashes: Vec<u64>,
    cached_wrapped: Vec<WrappedRow>,
}

impl RegularState {
    fn new(target: Box<dyn RegularTarget>) -> Self {
        Self {
            target,
            flushed_visual_lines: Vec::new(),
            working_lines: Vec::new(),
            cursor_row: 0,
            cursor_visible: false,
            editor_scroll: 0,
            prev_width: 0,
            prev_height: 0,
            cached_width: 0,
            cached_row_hashes: Vec::new(),
            cached_wrapped: Vec::new(),
        }
    }
}

enum ModeState {
    Fullscreen(FullscreenState),
    Regular(RegularState),
}

#[derive(Clone, Copy)]
pub(super) enum EditorOverlay<'a> {
    None,
    Picker(&'a [String]),
    Tree(&'a [String]),
    Completion(&'a [String]),
}

pub struct Screen {
    mode: ModeState,
    _guard: TerminalModeGuard,
}

impl Drop for Screen {
    fn drop(&mut self) {
        if let ModeState::Regular(reg) = &mut self.mode {
            if !reg.working_lines.is_empty() {
                let mut out = String::new();
                let down = reg.working_lines.len().saturating_sub(1 + reg.cursor_row);
                if down > 0 {
                    let _ = write!(out, "\x1b[{down}B");
                }
                out.push_str("\r\n");
                let _ = reg.target.write_bytes(out.as_bytes());
                let _ = reg.target.flush();
                reg.working_lines.clear();
            }
        }
    }
}

impl Screen {
    pub fn open() -> io::Result<Self> {
        let term = std::env::var("TERM").ok();
        check_open_env(
            io::stdin().is_terminal(),
            io::stdout().is_terminal(),
            term.as_deref(),
        )?;

        let guard =
            TerminalModeGuard::enter(Box::new(RealTerminalOps::new()), ScreenMode::Fullscreen)?;
        let backend = ScreenBackend::Crossterm(CrosstermBackend::new(io::stdout()));
        let terminal = Terminal::new(backend)?;

        Ok(Self {
            mode: ModeState::Fullscreen(FullscreenState {
                terminal,
                scroll_state: ScrollState::Bottom,
                editor_scroll: 0,
            }),
            _guard: guard,
        })
    }

    pub fn open_regular() -> io::Result<Self> {
        let term = std::env::var("TERM").ok();
        check_open_env(
            io::stdin().is_terminal(),
            io::stdout().is_terminal(),
            term.as_deref(),
        )?;

        let guard =
            TerminalModeGuard::enter(Box::new(RealTerminalOps::new()), ScreenMode::Regular)?;

        Ok(Self {
            mode: ModeState::Regular(RegularState::new(Box::new(StdoutRegularTarget::new()))),
            _guard: guard,
        })
    }

    #[cfg(test)]
    pub(crate) fn with_test_backend(width: u16, height: u16) -> io::Result<Self> {
        let backend = ScreenBackend::Test(TestBackend::new(width, height));
        let terminal = Terminal::new(backend)?;
        Ok(Self {
            mode: ModeState::Fullscreen(FullscreenState {
                terminal,
                scroll_state: ScrollState::Bottom,
                editor_scroll: 0,
            }),
            _guard: TerminalModeGuard::noop(),
        })
    }

    #[cfg(test)]
    fn with_regular_test_target(target: Box<dyn RegularTarget>) -> Self {
        Self {
            mode: ModeState::Regular(RegularState::new(target)),
            _guard: TerminalModeGuard::noop(),
        }
    }

    #[cfg(test)]
    pub(crate) fn test_backend(&self) -> &TestBackend {
        match &self.mode {
            ModeState::Fullscreen(fs) => match fs.terminal.backend() {
                ScreenBackend::Test(b) => b,
                ScreenBackend::Crossterm(_) => unreachable!(),
            },
            ModeState::Regular(_) => unreachable!(),
        }
    }

    #[cfg(test)]
    pub(crate) fn test_cursor_position(&mut self) -> io::Result<Position> {
        match &mut self.mode {
            ModeState::Fullscreen(fs) => fs.terminal.get_cursor_position(),
            ModeState::Regular(_) => unreachable!(),
        }
    }

    #[cfg(test)]
    pub(crate) fn resize_test_backend(&mut self, width: u16, height: u16) {
        if let ModeState::Fullscreen(fs) = &mut self.mode {
            if let ScreenBackend::Test(ref mut b) = fs.terminal.backend_mut() {
                b.resize(width, height);
            }
        }
    }

    pub fn scroll(&mut self, lines: i32) {
        if lines == 0 {
            return;
        }
        let ModeState::Fullscreen(fs) = &mut self.mode else {
            return;
        };
        match &mut fs.scroll_state {
            ScrollState::Bottom => {
                if lines > 0 {
                    fs.scroll_state = ScrollState::Scrolled {
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
        if let ModeState::Fullscreen(fs) = &mut self.mode {
            fs.scroll_state = ScrollState::Bottom;
        }
    }

    pub fn draw(
        &mut self,
        rows: &[String],
        editor: &str,
        cursor: usize,
        status: &str,
        picker: &[String],
    ) -> io::Result<()> {
        let overlay = if picker.is_empty() {
            EditorOverlay::None
        } else {
            EditorOverlay::Picker(picker)
        };
        self.draw_with_overlay(rows, editor, cursor, &[status], overlay)
    }

    pub(super) fn draw_with_overlay(
        &mut self,
        rows: &[String],
        editor: &str,
        cursor: usize,
        status: &[impl AsRef<str>],
        overlay: EditorOverlay<'_>,
    ) -> io::Result<()> {
        let theme = Theme::ansi();
        let styled = rows_from_plain(rows, &theme);
        self.draw_styled_with_overlay(&styled, editor, cursor, status, overlay, &theme)
    }

    pub(super) fn draw_styled_with_overlay(
        &mut self,
        rows: &[StyledRow],
        editor: &str,
        cursor: usize,
        status: &[impl AsRef<str>],
        overlay: EditorOverlay<'_>,
        theme: &Theme,
    ) -> io::Result<()> {
        match &mut self.mode {
            ModeState::Fullscreen(fs) => {
                draw_fullscreen(fs, rows, editor, cursor, status, overlay, theme)
            }
            ModeState::Regular(reg) => {
                draw_regular(reg, rows, editor, cursor, status, overlay, theme)
            }
        }
    }

    pub(super) fn draw_inbox(
        &mut self,
        rows: &[StyledRow],
        selected_row: Option<usize>,
        status: &[impl AsRef<str>],
        theme: &Theme,
    ) -> io::Result<()> {
        match &mut self.mode {
            ModeState::Fullscreen(fs) => {
                draw_inbox_fullscreen(fs, rows, selected_row, status, theme)
            }
            ModeState::Regular(reg) => draw_inbox_regular(reg, rows, selected_row, status, theme),
        }
    }
}

fn inbox_window(total: usize, view_h: usize, selected_row: Option<usize>) -> (usize, usize) {
    if total == 0 || view_h == 0 {
        return (0, 0);
    }
    if total <= view_h {
        return (0, total);
    }
    let anchor = selected_row.unwrap_or(0).min(total - 1);
    let mut top = anchor.saturating_sub(view_h / 2);
    let max_top = total.saturating_sub(view_h);
    if top > max_top {
        top = max_top;
    }
    // Keep the parent directory header directly above the selected row visible when possible.
    if anchor > 0 && anchor == top {
        top = top.saturating_sub(1);
    }
    (top, (top + view_h).min(total))
}

fn draw_inbox_fullscreen(
    fs: &mut FullscreenState,
    rows: &[StyledRow],
    selected_row: Option<usize>,
    status: &[impl AsRef<str>],
    theme: &Theme,
) -> io::Result<()> {
    fs.terminal.draw(|frame| {
        let area = frame.area();
        if area.width == 0 || area.height == 0 {
            return;
        }
        let width = area.width as usize;
        let status_h = status.len().min(area.height.saturating_sub(1) as usize) as u16;
        let sep_h = u16::from(area.height >= status_h + 2);
        let body_h = area.height.saturating_sub(status_h + sep_h) as usize;

        let buf = frame.buffer_mut();
        let (top, end) = inbox_window(rows.len(), body_h, selected_row);
        for (offset, row) in rows[top..end].iter().enumerate() {
            let y = area.y + offset as u16;
            if let Some(fill) = row.fill_style {
                for dx in 0..area.width {
                    buf[(area.x + dx, y)].set_symbol(" ").set_style(fill);
                }
            }
            let segs = row_to_render_segs(row);
            write_segments_to_row(buf, area.x, y, width, &segs, Style::default());
        }

        if sep_h > 0 {
            render_separator(buf, area.x, area.y + body_h as u16, area.width, 0, theme);
        }
        if status_h > 0 {
            render_status_lines(
                buf,
                area.x,
                area.y + area.height - status_h,
                area.width,
                &status[..status_h as usize],
                theme,
            );
        }
    })?;
    Ok(())
}

fn draw_inbox_regular(
    reg: &mut RegularState,
    rows: &[StyledRow],
    selected_row: Option<usize>,
    status: &[impl AsRef<str>],
    theme: &Theme,
) -> io::Result<()> {
    let (term_w, term_h) = reg.target.size()?;
    if term_w == 0 || term_h == 0 {
        return Ok(());
    }
    let width = term_w as usize;
    let height = term_h as usize;
    let status_h = status.len().min(height.saturating_sub(1));
    let sep_h = usize::from(height >= status_h + 2);
    let max_body = height.saturating_sub(status_h + sep_h);
    let (top, end) = inbox_window(rows.len(), max_body, selected_row);
    let visible = &rows[top..end];
    let work_h = (visible.len() + sep_h + status_h).clamp(1, height);

    let area = Rect::new(0, 0, term_w, work_h as u16);
    let mut buf = Buffer::empty(area);
    for (idx, row) in visible.iter().enumerate() {
        if let Some(fill) = row.fill_style {
            for dx in 0..term_w {
                buf[(dx, idx as u16)].set_symbol(" ").set_style(fill);
            }
        }
        let segs = row_to_render_segs(row);
        write_segments_to_row(&mut buf, 0, idx as u16, width, &segs, Style::default());
    }
    let mut cur_y = visible.len() as u16;
    if sep_h > 0 && (cur_y as usize) < work_h {
        render_separator(&mut buf, 0, cur_y, term_w, 0, theme);
        cur_y += 1;
    }
    if status_h > 0 {
        render_status_lines(&mut buf, 0, cur_y, term_w, &status[..status_h], theme);
    }

    let new_working_lines: Vec<String> = (0..work_h)
        .map(|y| buffer_row_to_ansi(&buf, y as u16, term_w, theme.is_plain))
        .collect();

    let mut out = String::new();
    out.push_str("\x1b[?2026h");
    if reg.cursor_visible {
        out.push_str("\x1b[?25l");
        reg.cursor_visible = false;
    }
    if !reg.flushed_visual_lines.is_empty()
        || (reg.prev_width != 0 && reg.prev_width != term_w)
        || (reg.prev_height != 0 && height < reg.working_lines.len())
        || reg.working_lines.is_empty()
    {
        reg.flushed_visual_lines.clear();
        out.push_str("\x1b[2J\x1b[H\x1b[3J");
        for (i, line) in new_working_lines.iter().enumerate() {
            if i > 0 {
                out.push_str("\r\n");
            }
            out.push_str(line);
        }
    } else {
        if reg.cursor_row > 0 {
            let _ = write!(out, "\x1b[{}A", reg.cursor_row);
        }
        out.push_str("\r\x1b[J");
        for (i, line) in new_working_lines.iter().enumerate() {
            if i > 0 {
                out.push_str("\r\n");
            }
            out.push_str(line);
        }
    }
    out.push_str("\x1b[?2026l");
    reg.target.write_bytes(out.as_bytes())?;
    reg.target.flush()?;

    reg.cursor_row = new_working_lines.len().saturating_sub(1);
    reg.working_lines = new_working_lines;
    reg.prev_width = term_w;
    reg.prev_height = term_h;
    Ok(())
}

fn row_to_render_segs(row: &StyledRow) -> Vec<RenderSeg> {
    let mut segs = Vec::new();
    for span in &row.spans {
        segs.extend(sanitize_graphemes_with_style(&span.text, span.style));
    }
    segs
}

fn draw_fullscreen(
    fs: &mut FullscreenState,
    rows: &[StyledRow],
    editor: &str,
    cursor: usize,
    status: &[impl AsRef<str>],
    overlay: EditorOverlay<'_>,
    theme: &Theme,
) -> io::Result<()> {
    let mut next_scroll_state = fs.scroll_state.clone();
    let mut next_editor_scroll = fs.editor_scroll;

    fs.terminal.draw(|frame| {
        let area = frame.area();
        if area.width == 0 || area.height == 0 {
            return;
        }

        let width = area.width as usize;
        let editor_layout = layout_editor(editor, cursor, width);
        let layout = compute_layout(
            area.height,
            editor_layout.lines.len(),
            overlay,
            status.len(),
        );

        // 1. Transcript rows
        if layout.transcript_height > 0 {
            let wrapped_rows = wrap_styled_transcript_rows(rows, width);
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
                if let Some(fill) = vline.fill_style {
                    for dx in 0..area.width {
                        buf[(area.x + dx, y)].set_symbol(" ").set_style(fill);
                    }
                }
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
                theme,
            );
        }

        // 3. Editor area + draft cursor
        let cursor_pos = render_editor_area(
            frame.buffer_mut(),
            area.x,
            area.y + layout.editor_y,
            area.width,
            layout.editor_height,
            &editor_layout,
            &mut next_editor_scroll,
            overlay,
            layout.completion_height,
        );

        // 4. Status bar
        render_status_lines(
            frame.buffer_mut(),
            area.x,
            area.y + area.height - layout.status_height,
            area.width,
            &status[..layout.status_height as usize],
            theme,
        );

        if let Some(pos) = cursor_pos {
            frame.set_cursor_position(pos);
        }
    })?;

    fs.scroll_state = next_scroll_state;
    fs.editor_scroll = next_editor_scroll;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn render_editor_area(
    buf: &mut Buffer,
    area_x: u16,
    editor_y: u16,
    total_width: u16,
    editor_height: u16,
    editor_layout: &EditorLayout,
    editor_scroll: &mut usize,
    overlay: EditorOverlay<'_>,
    completion_height: u16,
) -> Option<Position> {
    if let EditorOverlay::Picker(lines) | EditorOverlay::Tree(lines) = overlay {
        render_option_lines(buf, area_x, editor_y, total_width, editor_height, lines);
        return None;
    }
    if let EditorOverlay::Completion(lines) = overlay {
        render_option_lines(
            buf,
            area_x,
            editor_y + editor_height - completion_height,
            total_width,
            completion_height,
            lines,
        );
    }
    let visible_editor_h = (editor_height - completion_height) as usize;
    let cursor_visual_row = editor_layout.cursor_row;
    if cursor_visual_row < *editor_scroll {
        *editor_scroll = cursor_visual_row;
    } else if visible_editor_h > 0 && cursor_visual_row >= *editor_scroll + visible_editor_h {
        *editor_scroll = cursor_visual_row + 1 - visible_editor_h;
    }
    let max_ed_scroll = editor_layout.lines.len().saturating_sub(visible_editor_h);
    *editor_scroll = (*editor_scroll).min(max_ed_scroll);

    let mut cursor_pos: Option<Position> = None;
    for row_offset in 0..visible_editor_h {
        let line_idx = *editor_scroll + row_offset;
        let Some(ed_line) = editor_layout.lines.get(line_idx) else {
            break;
        };
        let y = editor_y + row_offset as u16;
        write_segments_to_row(
            buf,
            area_x,
            y,
            total_width as usize,
            &ed_line.segments,
            Style::default(),
        );
        if line_idx == editor_layout.cursor_row {
            let cx = (area_x as usize + editor_layout.cursor_col)
                .min(area_x as usize + (total_width as usize).saturating_sub(1))
                as u16;
            cursor_pos = Some(Position::new(cx, y));
        }
    }
    cursor_pos
}

fn render_option_lines(
    buf: &mut Buffer,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    lines: &[String],
) {
    let Some((header, choices)) = lines.split_first() else {
        return;
    };
    // Header stays put; keep the selected result visible even after a short resize.
    let selected = choices
        .iter()
        .position(|s| s.starts_with("> "))
        .unwrap_or(0);
    let skip = (selected + 1).saturating_sub((height as usize).saturating_sub(1));
    for (row, line) in std::iter::once(header)
        .chain(choices.iter().skip(skip))
        .take(height as usize)
        .enumerate()
    {
        write_plain_str_to_row(
            buf,
            x,
            y + row as u16,
            width as usize,
            line,
            Style::default(),
        );
    }
}

fn render_status_lines(
    buf: &mut Buffer,
    x: u16,
    y: u16,
    width: u16,
    lines: &[impl AsRef<str>],
    theme: &Theme,
) {
    let style = theme.status_bar;
    for (i, line) in lines.iter().enumerate() {
        let row = y + i as u16;
        let safe = sanitize_single_line(line.as_ref());
        for dx in 0..width {
            buf[(x + dx, row)].set_symbol(" ").set_style(style);
        }
        write_plain_str_to_row(buf, x, row, width as usize, &safe, style);
    }
}

fn draw_regular(
    reg: &mut RegularState,
    rows: &[StyledRow],
    editor: &str,
    cursor: usize,
    status: &[impl AsRef<str>],
    overlay: EditorOverlay<'_>,
    theme: &Theme,
) -> io::Result<()> {
    let (term_w, term_h) = reg.target.size()?;
    if term_w == 0 || term_h == 0 {
        return Ok(());
    }

    let width = term_w as usize;
    let height = term_h as usize;

    let width_changed = reg.prev_width != 0 && reg.prev_width != term_w;
    let height_shrunk = reg.prev_height != 0 && height < reg.working_lines.len();
    let mut need_full_clear = width_changed || height_shrunk;

    let editor_layout = layout_editor(editor, cursor, width);
    let layout = compute_layout(term_h, editor_layout.lines.len(), overlay, status.len());

    let sep_h = usize::from(layout.separator_y.is_some());
    let status_h = layout.status_height as usize;
    let editor_h = layout.editor_height as usize;
    let bottom_h = sep_h + editor_h + status_h;
    let max_tail_lines = height.saturating_sub(bottom_h);

    // Cache wrapped rows when rows + width are unchanged (e.g. typing in editor)
    let row_hashes: Vec<u64> = rows.iter().map(hash_styled_row).collect();
    if reg.cached_width != width || reg.cached_row_hashes != row_hashes {
        reg.cached_wrapped = wrap_styled_transcript_rows(rows, width);
        reg.cached_row_hashes = row_hashes;
        reg.cached_width = width;
    }

    let total_visual = reg.cached_wrapped.len();
    let flush_target = total_visual
        .saturating_sub(max_tail_lines)
        .max(reg.flushed_visual_lines.len().min(total_visual));

    // Check if already-flushed prefix is still intact
    let mut prefix_intact = !need_full_clear && flush_target >= reg.flushed_visual_lines.len();
    let mut newly_flushed_ansi: Vec<String> = Vec::new();
    if prefix_intact {
        for (idx, expected) in reg.flushed_visual_lines.iter().enumerate() {
            let line_ansi =
                segments_to_ansi_line(&reg.cached_wrapped[idx].segments, theme.is_plain);
            if &line_ansi != expected {
                prefix_intact = false;
                break;
            }
        }
    }

    if !prefix_intact {
        need_full_clear = true;
        reg.flushed_visual_lines.clear();
        reg.working_lines.clear();
        reg.cursor_row = 0;
    }

    let flush_from = reg.flushed_visual_lines.len();
    for vrow in &reg.cached_wrapped[flush_from..flush_target] {
        newly_flushed_ansi.push(segments_to_ansi_line(&vrow.segments, theme.is_plain));
    }

    let tail = &reg.cached_wrapped[flush_target..];
    let base_h = tail.len() + bottom_h;
    let work_h = base_h.clamp(1, height);

    let area = Rect::new(0, 0, term_w, work_h as u16);
    let mut buf = Buffer::empty(area);

    for (idx, vrow) in tail.iter().enumerate() {
        if let Some(fill) = vrow.fill_style {
            for dx in 0..term_w {
                buf[(dx, idx as u16)].set_symbol(" ").set_style(fill);
            }
        }
        write_segments_to_row(
            &mut buf,
            0,
            idx as u16,
            width,
            &vrow.segments,
            Style::default(),
        );
    }

    let mut cur_y = tail.len() as u16;
    if layout.separator_y.is_some() && (cur_y as usize) < work_h {
        render_separator(&mut buf, 0, cur_y, term_w, 0, theme);
        cur_y += 1;
    }

    let cursor_pos = render_editor_area(
        &mut buf,
        0,
        cur_y,
        term_w,
        layout.editor_height,
        &editor_layout,
        &mut reg.editor_scroll,
        overlay,
        layout.completion_height,
    );
    cur_y += layout.editor_height;

    render_status_lines(&mut buf, 0, cur_y, term_w, &status[..status_h], theme);

    let new_working_lines: Vec<String> = (0..work_h)
        .map(|y| buffer_row_to_ansi(&buf, y as u16, term_w, theme.is_plain))
        .collect();

    let mut out = String::new();
    out.push_str("\x1b[?2026h");

    if need_full_clear {
        out.push_str("\x1b[2J\x1b[H\x1b[3J");
    }

    let mut hw_row: usize;
    if !newly_flushed_ansi.is_empty() || reg.working_lines.is_empty() {
        if !reg.working_lines.is_empty() && !need_full_clear {
            if reg.cursor_row > 0 {
                let _ = write!(out, "\x1b[{}A", reg.cursor_row);
            }
            out.push_str("\r\x1b[J");
        }
        for line in &newly_flushed_ansi {
            out.push_str(line);
            out.push_str("\r\n");
        }
        for (i, line) in new_working_lines.iter().enumerate() {
            if i > 0 {
                out.push_str("\r\n");
            }
            out.push_str(line);
        }
        reg.flushed_visual_lines.extend(newly_flushed_ansi);
        hw_row = new_working_lines.len().saturating_sub(1);
    } else {
        // Diff only within the working area; flushed scrollback is untouched.
        let old_len = reg.working_lines.len();
        let new_len = new_working_lines.len();
        let max_len = old_len.max(new_len);

        let mut first_changed: Option<usize> = None;
        let mut last_changed: usize = 0;
        for i in 0..max_len {
            let old_l = reg.working_lines.get(i).map(String::as_str).unwrap_or("");
            let new_l = new_working_lines.get(i).map(String::as_str).unwrap_or("");
            if old_l != new_l {
                if first_changed.is_none() {
                    first_changed = Some(i);
                }
                last_changed = i;
            }
        }

        hw_row = reg.cursor_row;
        if let Some(fc) = first_changed {
            if fc >= new_len {
                // Lines were only removed from the bottom.
                let target_row = new_len.saturating_sub(1);
                append_vertical_move(&mut out, hw_row, target_row);
                let extra = old_len - new_len;
                for _ in 0..extra {
                    out.push_str("\r\n\x1b[2K");
                }
                if extra > 0 {
                    let _ = write!(out, "\x1b[{extra}A");
                }
                hw_row = target_row;
            } else {
                let move_target = fc.min(old_len - 1);
                append_vertical_move(&mut out, hw_row, move_target);
                out.push('\r');
                if fc >= old_len {
                    out.push_str("\r\n");
                }

                let render_end = last_changed.min(new_len - 1);
                for (offset, line) in new_working_lines[fc..=render_end].iter().enumerate() {
                    if offset > 0 {
                        out.push_str("\r\n");
                    }
                    out.push_str("\x1b[2K");
                    out.push_str(line);
                }
                hw_row = render_end;

                if old_len > new_len {
                    let tail_row = new_len - 1;
                    append_vertical_move(&mut out, hw_row, tail_row);
                    let extra = old_len - new_len;
                    for _ in 0..extra {
                        out.push_str("\r\n\x1b[2K");
                    }
                    let _ = write!(out, "\x1b[{extra}A");
                    hw_row = tail_row;
                }
            }
        }
    }

    if let Some(pos) = cursor_pos {
        let target_row = (pos.y as usize).min(new_working_lines.len().saturating_sub(1));
        append_vertical_move(&mut out, hw_row, target_row);
        let _ = write!(out, "\x1b[{}G", pos.x as usize + 1);
        if !reg.cursor_visible {
            out.push_str("\x1b[?25h");
            reg.cursor_visible = true;
        }
        reg.cursor_row = target_row;
    } else {
        if reg.cursor_visible {
            out.push_str("\x1b[?25l");
            reg.cursor_visible = false;
        }
        reg.cursor_row = hw_row;
    }

    out.push_str("\x1b[?2026l");
    reg.target.write_bytes(out.as_bytes())?;
    reg.target.flush()?;

    reg.working_lines = new_working_lines;
    reg.prev_width = term_w;
    reg.prev_height = term_h;
    Ok(())
}

fn append_vertical_move(out: &mut String, from_row: usize, to_row: usize) {
    if to_row > from_row {
        let _ = write!(out, "\x1b[{}B", to_row - from_row);
    } else if to_row < from_row {
        let _ = write!(out, "\x1b[{}A", from_row - to_row);
    }
}

fn segments_to_ansi_line(segs: &[RenderSeg], plain: bool) -> String {
    if plain {
        let mut out = String::new();
        for seg in segs {
            out.push_str(&seg.text);
        }
        return out;
    }
    let mut out = String::new();
    let mut active = Style::default();
    for seg in segs {
        if seg.style != active {
            write_style_transition(&mut out, seg.style);
            active = seg.style;
        }
        out.push_str(&seg.text);
    }
    if active != Style::default() {
        out.push_str("\x1b[0m");
    }
    out
}

fn buffer_row_to_ansi(buf: &Buffer, y: u16, width: u16, plain: bool) -> String {
    let mut end_x = width as usize;
    while end_x > 0 {
        let cell = &buf[(end_x as u16 - 1, y)];
        if cell.symbol() == " " && cell.style() == Style::default() {
            end_x -= 1;
        } else {
            break;
        }
    }

    let mut out = String::new();
    let mut active = Style::default();
    let mut x = 0usize;
    while x < end_x {
        let cell = &buf[(x as u16, y)];
        let style = cell.style();
        if !plain && style != active {
            write_style_transition(&mut out, style);
            active = style;
        }
        let sym = cell.symbol();
        out.push_str(sym);
        let w = grapheme_display_width(sym).max(1);
        x += w;
    }
    if !plain && active != Style::default() {
        out.push_str("\x1b[0m");
    }
    out
}

fn write_style_transition(out: &mut String, style: Style) {
    out.push_str("\x1b[0m");
    if style == Style::default() {
        return;
    }
    let mut codes: Vec<String> = Vec::new();
    if style.add_modifier.contains(Modifier::BOLD) {
        codes.push("1".into());
    }
    if style.add_modifier.contains(Modifier::DIM) {
        codes.push("2".into());
    }
    if style.add_modifier.contains(Modifier::ITALIC) {
        codes.push("3".into());
    }
    if style.add_modifier.contains(Modifier::UNDERLINED) {
        codes.push("4".into());
    }
    if style.add_modifier.contains(Modifier::REVERSED) {
        codes.push("7".into());
    }
    if style.add_modifier.contains(Modifier::CROSSED_OUT) {
        codes.push("9".into());
    }
    if let Some(fg) = style.fg {
        push_color_codes(&mut codes, fg, false);
    }
    if let Some(bg) = style.bg {
        push_color_codes(&mut codes, bg, true);
    }
    if !codes.is_empty() {
        out.push_str("\x1b[");
        out.push_str(&codes.join(";"));
        out.push('m');
    }
}

fn push_color_codes(codes: &mut Vec<String>, color: Color, is_bg: bool) {
    let base = if is_bg { 40 } else { 30 };
    let bright = if is_bg { 100 } else { 90 };
    match color {
        Color::Reset => codes.push(if is_bg { "49".into() } else { "39".into() }),
        Color::Black => codes.push(base.to_string()),
        Color::Red => codes.push((base + 1).to_string()),
        Color::Green => codes.push((base + 2).to_string()),
        Color::Yellow => codes.push((base + 3).to_string()),
        Color::Blue => codes.push((base + 4).to_string()),
        Color::Magenta => codes.push((base + 5).to_string()),
        Color::Cyan => codes.push((base + 6).to_string()),
        Color::Gray => codes.push((base + 7).to_string()),
        Color::DarkGray => codes.push(bright.to_string()),
        Color::LightRed => codes.push((bright + 1).to_string()),
        Color::LightGreen => codes.push((bright + 2).to_string()),
        Color::LightYellow => codes.push((bright + 3).to_string()),
        Color::LightBlue => codes.push((bright + 4).to_string()),
        Color::LightMagenta => codes.push((bright + 5).to_string()),
        Color::LightCyan => codes.push((bright + 6).to_string()),
        Color::White => codes.push((bright + 7).to_string()),
        Color::Indexed(n) => {
            codes.push(if is_bg { "48".into() } else { "38".into() });
            codes.push("5".into());
            codes.push(n.to_string());
        }
        Color::Rgb(r, g, b) => {
            codes.push(if is_bg { "48".into() } else { "38".into() });
            codes.push("2".into());
            codes.push(r.to_string());
            codes.push(g.to_string());
            codes.push(b.to_string());
        }
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
    status_height: u16,
    completion_height: u16,
}

fn compute_layout(
    total_height: u16,
    editor_visual_lines: usize,
    overlay: EditorOverlay<'_>,
    status_lines: usize,
) -> ScreenLayout {
    let first_status_row = u16::from(total_height >= 2 && status_lines > 0);
    // Keep a transcript row and separator on terminals tall enough for both.
    let sep_h = u16::from(total_height >= 5);
    let available = total_height - first_status_row - 2 * sep_h;
    let max_editor = if sep_h == 0 {
        1
    } else {
        ((usize::from(total_height) * 3 / 10) as u16).max(3)
    };
    let mut editor_height = editor_visual_lines
        .clamp(1, max_editor as usize)
        .min(available as usize) as u16;
    let mut completion_height = 0;
    match overlay {
        EditorOverlay::None => {}
        EditorOverlay::Picker(lines) => {
            editor_height = (lines.len().clamp(1, 7) as u16).min(available);
        }
        EditorOverlay::Tree(lines) => {
            let max_tree = ((usize::from(total_height) * 6 / 10).clamp(7, 16)) as u16;
            editor_height = (lines.len().clamp(1, max_tree as usize) as u16).min(available);
        }
        EditorOverlay::Completion(lines) => {
            completion_height =
                (lines.len().min(7) as u16).min(available.saturating_sub(editor_height));
            editor_height += completion_height;
        }
    }
    // Additional status rows never crowd out the editor or its focused overlay.
    // Keep the first configured rows when the terminal is too short.
    let status_height =
        status_lines.min(usize::from(total_height - 2 * sep_h - editor_height)) as u16;
    let editor_y = total_height - status_height - editor_height;
    let transcript_height = editor_y - sep_h;
    ScreenLayout {
        transcript_height,
        separator_y: (sep_h != 0).then_some(transcript_height),
        editor_y,
        editor_height,
        status_height,
        completion_height,
    }
}

fn render_separator(
    buf: &mut Buffer,
    x: u16,
    y: u16,
    width: u16,
    scrolled_lines: usize,
    theme: &Theme,
) {
    let dim = theme.separator;
    for dx in 0..width {
        buf[(x + dx, y)].set_symbol("─").set_style(dim);
    }
    if scrolled_lines > 0 && width >= 8 {
        let badge = format!(" [↑ {scrolled_lines}] ");
        let badge_w = display_str_width(&badge);
        if badge_w <= width as usize {
            let start_x = x + (width - badge_w as u16);
            write_plain_str_to_row(buf, start_x, y, badge_w, &badge, theme.scroll_badge);
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
    style: Style,
}

#[derive(Debug, Clone)]
struct WrappedRow {
    row_idx: usize,
    sub_idx: usize,
    segments: Vec<RenderSeg>,
    fill_style: Option<Style>,
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

fn hash_styled_row(row: &StyledRow) -> u64 {
    let mut hasher = DefaultHasher::new();
    row.hash_with(&mut hasher);
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
    sanitize_graphemes_with_style(line, Style::default())
}

fn sanitize_graphemes_with_style(line: &str, style: Style) -> Vec<RenderSeg> {
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
                style,
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
                style,
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

fn rows_from_plain(rows: &[String], theme: &Theme) -> Vec<StyledRow> {
    let joined = rows
        .iter()
        .map(|r| sanitize_terminal_text(r))
        .collect::<Vec<_>>()
        .join("\n");
    if rows.is_empty() {
        return Vec::new();
    }
    super::markdown::render_markdown_lines(&joined, theme, Style::default())
}

fn wrap_styled_transcript_rows(rows: &[StyledRow], width: usize) -> Vec<WrappedRow> {
    let mut out = Vec::new();
    for (row_idx, row) in rows.iter().enumerate() {
        if let Some(hr_style) = row.hr_style {
            let rule_w = width.clamp(3, 60);
            let segs = sanitize_graphemes_with_style(&"─".repeat(rule_w), hr_style);
            out.push(WrappedRow {
                row_idx,
                sub_idx: 0,
                segments: segs,
                fill_style: row.fill_style,
            });
            continue;
        }

        let mut segs = Vec::new();
        for span in &row.spans {
            segs.extend(sanitize_graphemes_with_style(&span.text, span.style));
        }

        if row.hang_prefix.is_empty() || width == 0 {
            for (sub_idx, chunk) in wrap_segments(&segs, width).into_iter().enumerate() {
                out.push(WrappedRow {
                    row_idx,
                    sub_idx,
                    segments: chunk,
                    fill_style: row.fill_style,
                });
            }
            continue;
        }

        let mut prefix_segs = Vec::new();
        for span in &row.hang_prefix {
            prefix_segs.extend(sanitize_graphemes_with_style(&span.text, span.style));
        }
        let prefix_w: usize = prefix_segs.iter().map(|s| s.width).sum();
        if prefix_w == 0 || prefix_w >= width {
            for (sub_idx, chunk) in wrap_segments(&segs, width).into_iter().enumerate() {
                out.push(WrappedRow {
                    row_idx,
                    sub_idx,
                    segments: chunk,
                    fill_style: row.fill_style,
                });
            }
            continue;
        }

        let first_chunks = wrap_segments(&segs, width);
        let first_len = first_chunks.len();
        if first_len <= 1 {
            out.push(WrappedRow {
                row_idx,
                sub_idx: 0,
                segments: first_chunks.into_iter().next().unwrap_or_default(),
                fill_style: row.fill_style,
            });
            continue;
        }

        // First chunk fills full width; remaining segments wrap with `hang_prefix` on continuation lines.
        let mut iter = first_chunks.into_iter();
        let first = iter.next().unwrap_or_default();
        let first_seg_count = first.len();
        out.push(WrappedRow {
            row_idx,
            sub_idx: 0,
            segments: first,
            fill_style: row.fill_style,
        });
        let rest_segs = &segs[first_seg_count..];
        let cont_width = width - prefix_w;
        for (idx, chunk) in wrap_segments(rest_segs, cont_width).into_iter().enumerate() {
            let mut combined = Vec::with_capacity(prefix_segs.len() + chunk.len());
            combined.extend(prefix_segs.iter().cloned());
            combined.extend(chunk);
            out.push(WrappedRow {
                row_idx,
                sub_idx: idx + 1,
                segments: combined,
                fill_style: row.fill_style,
            });
        }
    }
    out
}

fn resolve_scroll_top(
    state: &ScrollState,
    rows: &[StyledRow],
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
                if *r_idx < rows.len() && hash_styled_row(&rows[*r_idx]) == *expected_hash {
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
                            .map(|r| (Some((w.row_idx, w.sub_idx)), Some(hash_styled_row(r))))
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
                style: Style::default(),
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
                    style: Style::default(),
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
            style: Style::default(),
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
    base_style: Style,
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
        let style = base_style.patch(seg.style);
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
        mouse_active: bool,
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

        fn enable_mouse_capture(&mut self) -> io::Result<()> {
            self.maybe_fail("enable_mouse_capture")?;
            let mut log = self.log.borrow_mut();
            log.mouse_active = true;
            log.events.push("enable_mouse_capture");
            Ok(())
        }

        fn disable_mouse_capture(&mut self) -> io::Result<()> {
            let mut log = self.log.borrow_mut();
            log.mouse_active = false;
            log.events.push("disable_mouse_capture");
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

    #[derive(Default)]
    struct MockRegularLog {
        width: u16,
        height: u16,
        writes: Vec<String>,
    }

    struct MockRegularTarget {
        log: Rc<RefCell<MockRegularLog>>,
    }

    impl RegularTarget for MockRegularTarget {
        fn size(&self) -> io::Result<(u16, u16)> {
            let log = self.log.borrow();
            Ok((log.width, log.height))
        }

        fn write_bytes(&mut self, data: &[u8]) -> io::Result<()> {
            let s = String::from_utf8(data.to_vec()).expect("valid utf8 output");
            self.log.borrow_mut().writes.push(s);
            Ok(())
        }

        fn flush(&mut self) -> io::Result<()> {
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
    fn guard_restores_all_modes_including_mouse_on_fullscreen_drop() {
        let log = Rc::new(RefCell::new(MockOpsLog::default()));
        {
            let _guard = TerminalModeGuard::enter(
                Box::new(MockTerminalOps {
                    log: Rc::clone(&log),
                }),
                ScreenMode::Fullscreen,
            )
            .unwrap();
            assert!(log.borrow().raw_mode_active);
            assert!(log.borrow().alt_screen_active);
            assert!(log.borrow().paste_active);
            assert!(log.borrow().keyboard_active);
            assert!(log.borrow().mouse_active);
        }
        let borrowed = log.borrow();
        assert!(!borrowed.raw_mode_active);
        assert!(!borrowed.alt_screen_active);
        assert!(!borrowed.paste_active);
        assert!(!borrowed.keyboard_active);
        assert!(!borrowed.mouse_active);
        assert_eq!(
            borrowed.events,
            vec![
                "enable_raw_mode",
                "enter_alt_screen",
                "enable_bracketed_paste",
                "push_keyboard_enhancement",
                "enable_mouse_capture",
                "hide_cursor",
                "flush",
                "disable_mouse_capture",
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
    fn guard_regular_mode_skips_alt_screen_and_mouse_capture() {
        let log = Rc::new(RefCell::new(MockOpsLog::default()));
        {
            let _guard = TerminalModeGuard::enter(
                Box::new(MockTerminalOps {
                    log: Rc::clone(&log),
                }),
                ScreenMode::Regular,
            )
            .unwrap();
            assert!(log.borrow().raw_mode_active);
            assert!(!log.borrow().alt_screen_active);
            assert!(log.borrow().paste_active);
            assert!(log.borrow().keyboard_active);
            assert!(!log.borrow().mouse_active);
        }
        let borrowed = log.borrow();
        assert!(!borrowed.raw_mode_active);
        assert!(!borrowed.alt_screen_active);
        assert!(!borrowed.paste_active);
        assert!(!borrowed.keyboard_active);
        assert!(!borrowed.mouse_active);
        assert_eq!(
            borrowed.events,
            vec![
                "enable_raw_mode",
                "enable_bracketed_paste",
                "push_keyboard_enhancement",
                "flush",
                "pop_keyboard_enhancement",
                "disable_bracketed_paste",
                "show_cursor",
                "flush",
                "disable_raw_mode",
            ]
        );
    }

    #[test]
    fn guard_unwinds_partial_init_on_error() {
        let log = Rc::new(RefCell::new(MockOpsLog {
            fail_at: Some("enable_mouse_capture"),
            ..Default::default()
        }));
        let res = TerminalModeGuard::enter(
            Box::new(MockTerminalOps {
                log: Rc::clone(&log),
            }),
            ScreenMode::Fullscreen,
        );
        assert!(res.is_err());

        let borrowed = log.borrow();
        assert!(!borrowed.raw_mode_active);
        assert!(!borrowed.alt_screen_active);
        assert!(!borrowed.paste_active);
        assert!(!borrowed.keyboard_active);
        assert!(!borrowed.mouse_active);
        assert_eq!(
            borrowed.events,
            vec![
                "enable_raw_mode",
                "enter_alt_screen",
                "enable_bracketed_paste",
                "push_keyboard_enhancement",
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
    fn guard_cleans_up_on_panic_unwind() {
        let log = Rc::new(RefCell::new(MockOpsLog::default()));
        let log_clone = Rc::clone(&log);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = TerminalModeGuard::enter(
                Box::new(MockTerminalOps { log: log_clone }),
                ScreenMode::Fullscreen,
            )
            .unwrap();
            panic!("simulated ui panic");
        }));
        assert!(result.is_err());

        let borrowed = log.borrow();
        assert!(!borrowed.raw_mode_active);
        assert!(!borrowed.alt_screen_active);
        assert!(!borrowed.paste_active);
        assert!(!borrowed.keyboard_active);
        assert!(!borrowed.mouse_active);
    }

    #[test]
    fn non_tty_open_fails_cleanly_without_raw_mode() {
        // Under cargo test, stdin/stdout are pipes (non-TTY), so open/open_regular must refuse.
        if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
            let err = Screen::open().err().expect("open must fail when non-TTY");
            assert_eq!(err.kind(), io::ErrorKind::Unsupported);
            let err_reg = Screen::open_regular()
                .err()
                .expect("open_regular must fail when non-TTY");
            assert_eq!(err_reg.kind(), io::ErrorKind::Unsupported);
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
        assert_eq!(lines[8], "draft text");
        assert_eq!(lines[9], "[seq 1 · idle]");

        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(5, 8));
    }

    #[test]
    fn cursor_tracks_utf8_cjk_accents_zwj_and_tabs() {
        let mut screen = Screen::with_test_backend(40, 8).unwrap();

        // CJK "你好" (each width 2 -> 4 cols) + "a"
        let text = "你好a";
        screen.draw(&[], text, "你好".len(), "ok", &[]).unwrap();
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(4, 6));

        // Tab expands to 4 spaces
        let tab_text = "a\tb";
        screen.draw(&[], tab_text, 2, "ok", &[]).unwrap();
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(5, 6));

        // Combining accent "e\u{0301}" (1 cell) + "x"
        let accent = "e\u{0301}x";
        screen
            .draw(&[], accent, "e\u{0301}".len(), "ok", &[])
            .unwrap();
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(1, 6));

        // ZWJ emoji "👨‍💻" (2 cells) + "z"
        let zwj = "👨‍💻z";
        screen.draw(&[], zwj, "👨‍💻".len(), "ok", &[]).unwrap();
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(2, 6));

        // Invalid mid-UTF8 byte cursor must clamp safely without panicking
        screen.draw(&[], "你好", 1, "ok", &[]).unwrap();
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(0, 6));
    }

    #[test]
    fn editor_wraps_and_scrolls_internally_to_keep_cursor_visible() {
        let mut screen = Screen::with_test_backend(12, 10).unwrap();
        // All 12 columns are available to the draft.
        // "hello world foo bar" wraps cleanly at spaces into 3 lines:
        // "hello world ", "foo bar" -> 2 lines, let's test 3 lines then 5 lines (internal scroll).
        let three_lines = "hello world second line third";
        screen
            .draw(&[], three_lines, three_lines.len(), "ok", &[])
            .unwrap();

        let lines = buffer_all_text(screen.test_backend().buffer());
        // max_editor for height 10 is (10*3/10).max(3) = 3
        assert_eq!(lines[6], "hello world");
        assert_eq!(lines[7], "second line");
        assert_eq!(lines[8], "third");
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(5, 8));

        // 5 logical lines: editor must scroll internally so cursor on line 5 is visible on row 8
        let five_lines = "l1\nl2\nl3\nl4\nl5";
        screen
            .draw(&[], five_lines, five_lines.len(), "ok", &[])
            .unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(lines[6], "l3");
        assert_eq!(lines[7], "l4");
        assert_eq!(lines[8], "l5");
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(2, 8));

        // Moving cursor back to line 1 scrolls the editor back up.
        screen.draw(&[], five_lines, 1, "ok", &[]).unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(lines[6], "l1");
        assert_eq!(lines[7], "l2");
        assert_eq!(lines[8], "l3");
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(1, 6));

        // Full-width single line places cursor on trailing soft-wrapped line:
        // "123456789012" + trailing cursor line = 2 lines (y=7 and y=8 for height 10)
        let exact = "123456789012";
        screen.draw(&[], exact, exact.len(), "ok", &[]).unwrap();
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(0, 8));
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
        let pos = screen.test_cursor_position().unwrap();
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
    fn picker_occupies_editor_rows_without_covering_transcript() {
        let mut screen = Screen::with_test_backend(20, 10).unwrap();
        // Wide transcript cells must remain intact above the inline list.
        let rows: Vec<String> = (0..6).map(|_| "a让bcdefghijkl".to_string()).collect();
        let overlay = vec!["Pick model".to_string(), "1. claude".to_string()];

        screen.draw(&rows, "hi", 2, "ok", &overlay).unwrap();
        let buf = screen.test_backend().buffer();

        for y in 0..6 {
            assert_eq!(buf[(1, y)].symbol(), "让");
        }
        let lines = buffer_all_text(buf);
        assert_eq!(&lines[7..], &["Pick model", "1. claude", "ok"]);
    }

    #[test]
    fn completion_keeps_draft_and_cursor_visible_with_selected_match() {
        let mut screen = Screen::with_test_backend(40, 5).unwrap();
        let options = ["Commands".into(), "  /help".into(), "> /hotkeys".into()];
        screen
            .draw_with_overlay(
                &["transcript".into()],
                "/hotkeys",
                8,
                &["ok"],
                EditorOverlay::Completion(&options),
            )
            .unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(lines[0], "transcript");
        assert_eq!(lines[2], "/hotkeys");
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(8, 2));

        screen.resize_test_backend(40, 6);
        screen
            .draw_with_overlay(
                &[],
                "/hotkeys",
                8,
                &["ok"],
                EditorOverlay::Completion(&options),
            )
            .unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(&lines[2..], &["/hotkeys", "Commands", "> /hotkeys", "ok"]);
    }

    #[test]
    fn multiline_footer_keeps_first_rows_and_editor_on_small_screens() {
        let mut screen = Screen::with_test_backend(28, 7).unwrap();
        let status = ["路径 🌱", "idle", "third", "fourth", "fifth", "sixth"];
        let rows = ["transcript".into()];
        screen
            .draw_with_overlay(&rows, "draft", 3, &status, EditorOverlay::None)
            .unwrap();
        let lines = buffer_all_text(screen.test_backend().buffer());
        assert_eq!(lines[0], "transcript");
        assert_eq!(lines[2], "draft");
        assert_eq!(&lines[4..], &["idle", "third", "fourth"]);
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(3, 2));

        screen.resize_test_backend(28, 2);
        screen
            .draw_with_overlay(&rows, "draft", 3, &status, EditorOverlay::None)
            .unwrap();
        assert_eq!(buffer_row_text(screen.test_backend().buffer(), 0), "draft");
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(3, 0));

        screen
            .draw_with_overlay(&rows, "draft", 3, &[] as &[&str], EditorOverlay::None)
            .unwrap();
        assert_eq!(
            buffer_all_text(screen.test_backend().buffer()),
            ["transcript", "draft"]
        );
    }

    #[test]
    fn regular_mode_footer_resize_does_not_reprint_flushed_history() {
        let log = Rc::new(RefCell::new(MockRegularLog {
            width: 40,
            height: 7,
            ..Default::default()
        }));
        let mut screen =
            Screen::with_regular_test_target(Box::new(MockRegularTarget { log: log.clone() }));
        let rows: Vec<_> = (0..9).map(|i| format!("history {i}")).collect();
        screen.draw(&rows, "draft", 3, "original", &[]).unwrap();
        screen
            .draw_with_overlay(
                &rows,
                "draft",
                3,
                &["first", "second", "third"],
                EditorOverlay::None,
            )
            .unwrap();
        screen
            .draw_with_overlay(&rows, "draft", 3, &[] as &[&str], EditorOverlay::None)
            .unwrap();
        let log = log.borrow();
        assert_eq!(log.writes.concat().matches("history 0").count(), 1);
        assert!(!log.writes[1].contains("\x1b[2J"));
        assert!(!log.writes[2].contains("\x1b[2J"));
        let ModeState::Regular(reg) = &screen.mode else {
            unreachable!()
        };
        assert!(reg.working_lines.last().unwrap().contains("draft"));
        assert_eq!(reg.cursor_row, reg.working_lines.len() - 1);
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
        assert_eq!(lines[8], "");
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
        assert_eq!(lines[8], "draft msg");
        assert_eq!(screen.test_cursor_position().unwrap(), Position::new(5, 8));
    }

    fn strip_sgr(s: &str) -> String {
        let mut out = String::new();
        let mut chars = s.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\x1b' && chars.peek() == Some(&'[') {
                chars.next();
                for ch in chars.by_ref() {
                    if ('@'..='~').contains(&ch) {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    #[test]
    fn regular_mode_streams_tokens_without_reprinting_flushed_history() {
        let log = Rc::new(RefCell::new(MockRegularLog {
            width: 30,
            height: 8,
            writes: Vec::new(),
        }));
        let mut screen = Screen::with_regular_test_target(Box::new(MockRegularTarget {
            log: Rc::clone(&log),
        }));

        // height=8 -> bottom_h=3 -> max_tail_lines=5.
        // 10 rows -> 5 flushed to scrollback, 5 in working tail.
        let mut rows: Vec<String> = (1..=9).map(|i| format!("hist {i:02}")).collect();
        rows.push("live: Hel".to_string());

        screen.draw(&rows, "draft", 5, "streaming", &[]).unwrap();
        assert_eq!(log.borrow().writes.len(), 1);
        let first_plain = strip_sgr(&log.borrow().writes[0]);
        assert!(first_plain.contains("hist 01"));
        assert!(first_plain.contains("hist 05"));
        assert!(first_plain.contains("live: Hel"));
        assert!(first_plain.contains("draft"));
        assert!(!first_plain.contains("> draft"));

        // Token update on last line: flushed history hist 01..05 must NOT be reprinted!
        rows[9] = "live: Hello world".to_string();
        screen.draw(&rows, "draft", 5, "streaming", &[]).unwrap();
        let second_write = log.borrow().writes[1].clone();
        let second_plain = strip_sgr(&second_write);
        for i in 1..=8 {
            assert!(
                !second_plain.contains(&format!("hist {i:02}")),
                "stable row hist {i:02} must not be reprinted on token update"
            );
        }
        assert!(second_plain.contains("live: Hello world"));
        assert!(!second_write.contains("\x1b[3J"));

        // Typing in editor updates only editor line, not tail or scrollback
        screen.draw(&rows, "draft!", 6, "streaming", &[]).unwrap();
        let third_plain = strip_sgr(&log.borrow().writes[2]);
        assert!(!third_plain.contains("hist 01"));
        assert!(!third_plain.contains("live: Hello world"));
        assert!(third_plain.contains("draft!"));
    }

    #[test]
    fn regular_mode_flushes_new_excess_lines_incrementally() {
        let log = Rc::new(RefCell::new(MockRegularLog {
            width: 30,
            height: 8,
            writes: Vec::new(),
        }));
        let mut screen = Screen::with_regular_test_target(Box::new(MockRegularTarget {
            log: Rc::clone(&log),
        }));

        let mut rows: Vec<String> = (1..=10).map(|i| format!("line {i:02}")).collect();
        screen.draw(&rows, "", 0, "idle", &[]).unwrap();

        // Append 2 more rows -> line 06 and line 07 flush incrementally; line 01..05 NEVER reprint.
        rows.push("line 11".to_string());
        rows.push("line 12".to_string());
        screen.draw(&rows, "", 0, "idle", &[]).unwrap();

        let second = &log.borrow().writes[1];
        for i in 1..=5 {
            assert!(
                !second.contains(&format!("line {i:02}")),
                "already-flushed line {i:02} must not be reprinted"
            );
        }
        assert!(second.contains("line 06"));
        assert!(second.contains("line 07"));
        assert!(second.contains("line 12"));
        assert!(!second.contains("\x1b[3J"));
    }

    #[test]
    fn regular_mode_handles_overlay_shrink_width_resize_and_drop() {
        let log = Rc::new(RefCell::new(MockRegularLog {
            width: 30,
            height: 10,
            writes: Vec::new(),
        }));
        {
            let mut screen = Screen::with_regular_test_target(Box::new(MockRegularTarget {
                log: Rc::clone(&log),
            }));
            screen
                .draw(&["a让bcde".to_string()], "hi", 2, "ok", &[])
                .unwrap();

            // scroll() / bottom() are safe no-ops in regular mode
            screen.scroll(5);
            screen.bottom();

            // Open overlay taller than working area (4 lines -> 8-row overlay)
            let overlay = vec![
                "Title".to_string(),
                "1. Option A".to_string(),
                "2. Option B".to_string(),
                "3. Option C".to_string(),
                "4. Option D".to_string(),
            ];
            screen
                .draw(&["a让bcde".to_string()], "hi", 2, "ok", &overlay)
                .unwrap();
            let ov_write = log.borrow().writes[1].clone();
            assert!(ov_write.contains("Title"));
            assert!(ov_write.contains("4. Option D"));
            assert!(!ov_write.contains("\x1b[3J"));

            // Dismiss overlay -> shrinks back and clears extra rows without full reset
            screen
                .draw(&["a让bcde".to_string()], "hi", 2, "ok", &[])
                .unwrap();
            let dismiss_write = log.borrow().writes[2].clone();
            assert!(dismiss_write.contains("\x1b[2K"));
            assert!(!dismiss_write.contains("\x1b[3J"));

            // Width resize triggers clean reset + reflow
            log.borrow_mut().width = 20;
            screen
                .draw(&["a让bcde".to_string()], "hi", 2, "ok", &[])
                .unwrap();
            let resize_write = log.borrow().writes[3].clone();
            assert!(resize_write.contains("\x1b[2J\x1b[H\x1b[3J"));
        }

        // Drop emits trailing newline below working area
        let writes = &log.borrow().writes;
        assert!(writes.last().unwrap().ends_with("\r\n"));
    }

    #[test]
    fn markdown_heading_fence_bullet_and_diff_styles_use_renderer_styles_only() {
        let mut screen = Screen::with_test_backend(40, 12).unwrap();
        let rows = vec![
            "# Title\x1b[31m".to_string(),
            "- bullet item".to_string(),
            "```rust".to_string(),
            "let x = 1;".to_string(),
            "```".to_string(),
            "@@ -1,2 +1,2 @@".to_string(),
            "-old".to_string(),
            "+new".to_string(),
        ];

        screen.draw(&rows, "", 0, "ok", &[]).unwrap();
        let buf = screen.test_backend().buffer();

        // Row 0: "# Title\x1b[31m" -> bold cyan heading, escape literalized
        assert_eq!(buf[(0, 0)].symbol(), "#");
        assert!(buf[(0, 0)].style().add_modifier.contains(Modifier::BOLD));
        assert_eq!(buf[(0, 0)].style().fg, Some(Color::Cyan));
        assert!(buffer_row_text(buf, 0).contains("\\x1b[31m"));

        // Row 1: "- bullet item" -> '-' is bold cyan, 'b' is default (NOT red diff!)
        assert_eq!(buf[(0, 1)].symbol(), "-");
        assert_eq!(buf[(0, 1)].style().fg, Some(Color::Cyan));
        assert!(matches!(buf[(2, 1)].style().fg, None | Some(Color::Reset)));

        // Row 2 & 4: code fence markers are DIM
        assert!(buf[(0, 2)].style().add_modifier.contains(Modifier::DIM));
        assert!(buf[(0, 4)].style().add_modifier.contains(Modifier::DIM));

        // Row 5: diff hunk header is Cyan + Bold
        assert_eq!(buf[(0, 5)].style().fg, Some(Color::Cyan));
        assert!(buf[(0, 5)].style().add_modifier.contains(Modifier::BOLD));

        // Row 6: "-old" inside diff is Red; Row 7: "+new" is Green
        assert_eq!(buf[(0, 6)].style().fg, Some(Color::Red));
        assert_eq!(buf[(0, 7)].style().fg, Some(Color::Green));
    }

    #[test]
    fn write_style_transition_emits_full_modifiers_indexed_rgb_and_backgrounds() {
        let mut out = String::new();
        let style = Style::default()
            .fg(Color::Rgb(110, 215, 235))
            .bg(Color::Indexed(236))
            .add_modifier(
                Modifier::BOLD
                    | Modifier::DIM
                    | Modifier::ITALIC
                    | Modifier::UNDERLINED
                    | Modifier::REVERSED
                    | Modifier::CROSSED_OUT,
            );
        write_style_transition(&mut out, style);
        assert_eq!(out, "\x1b[0m\x1b[1;2;3;4;7;9;38;2;110;215;235;48;5;236m");

        let mut basic = String::new();
        write_style_transition(
            &mut basic,
            Style::default().fg(Color::Blue).bg(Color::LightMagenta),
        );
        assert_eq!(basic, "\x1b[0m\x1b[34;105m");
    }

    #[test]
    fn plain_theme_suppresses_color_sgr_in_regular_mode_while_preserving_content() {
        let log = Rc::new(RefCell::new(MockRegularLog {
            width: 50,
            height: 8,
            writes: Vec::new(),
        }));
        let mut screen =
            Screen::with_regular_test_target(Box::new(MockRegularTarget { log: log.clone() }));
        let theme = Theme::plain();
        let styled = crate::hi::markdown::render_markdown_lines(
            "# Heading\n> quote **bold** `code`\n```rust\nfn main() {}\n```",
            &theme,
            Style::default(),
        );
        screen
            .draw_styled_with_overlay(&styled, "draft", 5, &["ok"], EditorOverlay::None, &theme)
            .unwrap();

        let written = log.borrow().writes.concat();
        assert!(written.contains("# Heading"));
        assert!(written.contains("│ quote bold code"));
        assert!(written.contains("fn main() {}"));
        // Plain theme emits zero foreground/background color SGRs (`38;`, `48;`, `30..37`, `90..97`, etc.)
        assert!(!written.contains("\x1b[38;"));
        assert!(!written.contains("\x1b[48;"));
        assert!(!written.contains(";36m"));
    }

    #[test]
    fn dark_and_light_themes_emit_styled_cells_and_hanging_blockquote_wrap() {
        for theme in [Theme::dark(), Theme::light()] {
            let mut screen = Screen::with_test_backend(22, 8).unwrap();
            let styled = crate::hi::markdown::render_markdown_lines(
                "> alpha beta gamma delta\n- [x] done",
                &theme,
                Style::default(),
            );
            screen
                .draw_styled_with_overlay(&styled, "", 0, &["ok"], EditorOverlay::None, &theme)
                .unwrap();

            let buf = screen.test_backend().buffer();
            // Line 0 and wrapped continuation line 1 both start with "│ " quote bar
            assert_eq!(buf[(0, 0)].symbol(), "│");
            assert_eq!(buf[(0, 0)].style().fg, theme.md_quote_border.fg);
            assert_eq!(buf[(0, 1)].symbol(), "│");
            assert_eq!(buf[(0, 1)].style().fg, theme.md_quote_border.fg);
            // Line 2 has checkbox [x]
            let row2 = buffer_row_text(buf, 2);
            assert!(row2.starts_with("- [x] done"), "row2={row2:?}");
            assert_eq!(buf[(2, 2)].style().fg, theme.tool_ok.fg);
        }
    }
}
