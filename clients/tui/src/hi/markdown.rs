use super::theme::Theme;
use crate::render::sanitize_terminal_text;
use ratatui::style::Style;
use std::hash::{Hash, Hasher};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StyledSpan {
    pub text: String,
    pub style: Style,
}

impl StyledSpan {
    pub fn new(text: impl Into<String>, style: Style) -> Self {
        Self {
            text: text.into(),
            style,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StyledRow {
    pub spans: Vec<StyledSpan>,
    pub hang_prefix: Vec<StyledSpan>,
    pub fill_style: Option<Style>,
    pub hr_style: Option<Style>,
}

impl StyledRow {
    pub fn plain(text: impl Into<String>, style: Style) -> Self {
        let text = text.into();
        let spans = if text.is_empty() {
            Vec::new()
        } else {
            vec![StyledSpan::new(text, style)]
        };
        Self {
            spans,
            hang_prefix: Vec::new(),
            fill_style: None,
            hr_style: None,
        }
    }

    pub fn from_spans(spans: Vec<StyledSpan>) -> Self {
        Self {
            spans,
            hang_prefix: Vec::new(),
            fill_style: None,
            hr_style: None,
        }
    }

    pub fn with_hang_prefix(mut self, hang_prefix: Vec<StyledSpan>) -> Self {
        self.hang_prefix = hang_prefix;
        self
    }

    pub fn with_fill(mut self, style: Style) -> Self {
        self.fill_style = Some(style);
        self
    }

    pub fn hr(style: Style) -> Self {
        Self {
            spans: vec![StyledSpan::new("---", style)],
            hang_prefix: Vec::new(),
            fill_style: None,
            hr_style: Some(style),
        }
    }

    pub fn plain_text(&self) -> String {
        let mut out = String::new();
        for span in &self.spans {
            out.push_str(&span.text);
        }
        out
    }

    pub fn hash_with<H: Hasher>(&self, state: &mut H) {
        self.spans.len().hash(state);
        for span in &self.spans {
            span.text.hash(state);
            hash_style(&span.style, state);
        }
        self.hang_prefix.len().hash(state);
        for span in &self.hang_prefix {
            span.text.hash(state);
            hash_style(&span.style, state);
        }
        self.fill_style.is_some().hash(state);
        if let Some(s) = self.fill_style.as_ref() {
            hash_style(s, state);
        }
        self.hr_style.is_some().hash(state);
        if let Some(s) = self.hr_style.as_ref() {
            hash_style(s, state);
        }
    }
}

fn hash_style<H: Hasher>(style: &Style, state: &mut H) {
    style.fg.hash(state);
    style.bg.hash(state);
    style.add_modifier.bits().hash(state);
    style.sub_modifier.bits().hash(state);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CodeLang {
    Rust,
    Elixir,
    JsTs,
    Python,
    Bash,
    JsonToml,
    Diff,
    Other,
}

impl CodeLang {
    fn from_info(info: &str) -> Self {
        let token = info
            .split(|c: char| c.is_whitespace() || c == ',' || c == '{')
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        match token.as_str() {
            "rs" | "rust" => Self::Rust,
            "ex" | "exs" | "elixir" | "heex" => Self::Elixir,
            "js" | "jsx" | "ts" | "tsx" | "mjs" | "cjs" | "javascript" | "typescript" => Self::JsTs,
            "py" | "python" => Self::Python,
            "sh" | "bash" | "zsh" | "shell" | "console" => Self::Bash,
            "json" | "jsonc" | "toml" => Self::JsonToml,
            "diff" | "patch" => Self::Diff,
            _ => Self::Other,
        }
    }
}

pub fn render_markdown_lines(raw: &str, theme: &Theme, base_style: Style) -> Vec<StyledRow> {
    let safe = sanitize_terminal_text(raw).replace('\t', "   ");
    let mut out = Vec::new();
    let mut in_fence: Option<(char, usize, CodeLang)> = None;
    let mut in_diff = false;

    for line in safe.split('\n') {
        if let Some((fence_ch, fence_len, lang)) = in_fence {
            if is_closing_fence(line, fence_ch, fence_len) {
                out.push(StyledRow::plain(line, theme.md_code_fence));
                in_fence = None;
            } else if lang == CodeLang::Diff {
                out.push(StyledRow::plain(line, diff_line_style(line, theme)));
            } else {
                let mut spans = highlight_code_line(line, lang, theme);
                if base_style != Style::default() {
                    for s in &mut spans {
                        s.style = base_style.patch(s.style);
                    }
                }
                out.push(StyledRow::from_spans(spans));
            }
            continue;
        }

        if let Some((fence_ch, fence_len, info)) = parse_opening_fence(line) {
            let lang = CodeLang::from_info(info);
            in_fence = Some((fence_ch, fence_len, lang));
            in_diff = false;
            out.push(render_fence_open(line, info, theme));
            continue;
        }

        if is_diff_start(line) {
            in_diff = true;
            out.push(StyledRow::plain(line, diff_line_style(line, theme)));
            continue;
        }

        if in_diff {
            if line.starts_with('+') || line.starts_with('-') {
                out.push(StyledRow::plain(line, diff_line_style(line, theme)));
                continue;
            }
            if line.is_empty() || line.starts_with(' ') {
                out.push(StyledRow::plain(line, base_style));
                continue;
            }
            in_diff = false;
        }

        if let Some((level, prefix, body)) = parse_atx_heading(line) {
            let h_style = match level {
                1 => base_style.patch(theme.md_h1),
                2 => base_style.patch(theme.md_h2),
                _ => base_style.patch(theme.md_h3),
            };
            let mut spans = vec![StyledSpan::new(prefix, h_style)];
            spans.extend(parse_inline_spans(body, theme, h_style));
            out.push(StyledRow::from_spans(spans));
            continue;
        }

        if is_horizontal_rule(line) {
            out.push(StyledRow::hr(base_style.patch(theme.md_hr)));
            continue;
        }

        if let Some((depth, content)) = parse_blockquote(line) {
            let mut bar = String::new();
            for _ in 0..depth {
                bar.push_str("│ ");
            }
            let border_style = base_style.patch(theme.md_quote_border);
            let quote_base = base_style.patch(theme.md_quote_text);
            let mut spans = vec![StyledSpan::new(bar.clone(), border_style)];
            if let Some(list) = parse_list_item(content) {
                let mut list_row = render_list_row(list, theme, quote_base);
                let mut combined_hang = vec![StyledSpan::new(bar, border_style)];
                combined_hang.extend(list_row.hang_prefix);
                spans.append(&mut list_row.spans);
                out.push(StyledRow::from_spans(spans).with_hang_prefix(combined_hang));
            } else {
                spans.extend(parse_inline_spans(content, theme, quote_base));
                out.push(
                    StyledRow::from_spans(spans)
                        .with_hang_prefix(vec![StyledSpan::new(bar, border_style)]),
                );
            }
            continue;
        }

        if let Some(list) = parse_list_item(line) {
            out.push(render_list_row(list, theme, base_style));
            continue;
        }

        let spans = parse_inline_spans(line, theme, base_style);
        out.push(StyledRow::from_spans(spans));
    }

    out
}

pub fn render_plain_inline(raw: &str, theme: &Theme, base_style: Style) -> StyledRow {
    let safe = sanitize_terminal_text(raw).replace('\t', "   ");
    let spans = parse_inline_spans(&safe, theme, base_style);
    StyledRow::from_spans(spans)
}

pub fn diff_line_style(line: &str, theme: &Theme) -> Style {
    if line.starts_with("@@ ") {
        theme.diff_hunk
    } else if line.starts_with("+++ ") {
        theme.diff_add.patch(theme.md_bold)
    } else if line.starts_with("--- ") {
        theme.diff_remove.patch(theme.md_bold)
    } else if line.starts_with("diff --git ")
        || line.starts_with("index ")
        || line.starts_with("new file mode ")
        || line.starts_with("deleted file mode ")
    {
        theme.diff_meta
    } else if line.starts_with('+') {
        theme.diff_add
    } else if line.starts_with('-') {
        theme.diff_remove
    } else {
        Style::default()
    }
}

fn is_diff_start(line: &str) -> bool {
    line.starts_with("diff --git ")
        || line.starts_with("--- ")
        || line.starts_with("+++ ")
        || (line.starts_with("@@ ") && line.contains(" @@"))
}

fn parse_opening_fence(line: &str) -> Option<(char, usize, &str)> {
    let indent = line.bytes().take_while(|&b| b == b' ').count();
    if indent > 3 {
        return None;
    }
    let rest = &line[indent..];
    let first = rest.chars().next()?;
    if first != '`' && first != '~' {
        return None;
    }
    let count = rest.chars().take_while(|&c| c == first).count();
    if count < 3 {
        return None;
    }
    let info = rest[count..].trim();
    if first == '`' && info.contains('`') {
        return None;
    }
    Some((first, count, info))
}

fn is_closing_fence(line: &str, fence_ch: char, fence_len: usize) -> bool {
    let indent = line.bytes().take_while(|&b| b == b' ').count();
    if indent > 3 {
        return false;
    }
    let rest = &line[indent..];
    let count = rest.chars().take_while(|&c| c == fence_ch).count();
    count >= fence_len && rest[count..].trim().is_empty()
}

fn render_fence_open(line: &str, info: &str, theme: &Theme) -> StyledRow {
    if info.is_empty() {
        return StyledRow::plain(line, theme.md_code_fence);
    }
    if let Some(pos) = line.find(info) {
        let head = &line[..pos];
        let lang_part = &line[pos..];
        StyledRow::from_spans(vec![
            StyledSpan::new(head, theme.md_code_fence),
            StyledSpan::new(lang_part, theme.md_code_fence.patch(theme.syn_type)),
        ])
    } else {
        StyledRow::plain(line, theme.md_code_fence)
    }
}

fn parse_atx_heading(line: &str) -> Option<(usize, &str, &str)> {
    let indent = line.bytes().take_while(|&b| b == b' ').count();
    if indent > 3 {
        return None;
    }
    let rest = &line[indent..];
    let hashes = rest.bytes().take_while(|&b| b == b'#').count();
    if (1..=6).contains(&hashes) && rest.as_bytes().get(hashes) == Some(&b' ') {
        let prefix_end = indent + hashes + 1;
        Some((hashes, &line[..prefix_end], &line[prefix_end..]))
    } else {
        None
    }
}

fn is_horizontal_rule(line: &str) -> bool {
    let indent = line.bytes().take_while(|&b| b == b' ').count();
    if indent > 3 {
        return false;
    }
    let trimmed = line[indent..].trim();
    let Some(first) = trimmed.chars().next() else {
        return false;
    };
    if !matches!(first, '-' | '*' | '_') {
        return false;
    }
    let mut count = 0usize;
    for ch in trimmed.chars() {
        if ch == first {
            count += 1;
        } else if ch != ' ' {
            return false;
        }
    }
    count >= 3
}

fn parse_blockquote(line: &str) -> Option<(usize, &str)> {
    let mut rest = line;
    let mut depth = 0usize;
    loop {
        let trimmed = rest.trim_start_matches(' ');
        let leading = rest.len() - trimmed.len();
        if leading > 3 {
            break;
        }
        if let Some(after) = trimmed.strip_prefix('>') {
            depth += 1;
            rest = after.strip_prefix(' ').unwrap_or(after);
        } else {
            break;
        }
    }
    (depth > 0).then_some((depth, rest))
}

struct ListParts<'a> {
    indent: &'a str,
    marker: &'a str,
    checkbox: Option<(&'a str, bool)>,
    body: &'a str,
    hang_width: usize,
}

fn parse_list_item(line: &str) -> Option<ListParts<'_>> {
    let indent_len = line.bytes().take_while(|&b| b == b' ').count();
    let indent = &line[..indent_len];
    let rest = &line[indent_len..];

    let (marker, after_marker) =
        if rest.starts_with("- ") || rest.starts_with("* ") || rest.starts_with("+ ") {
            if rest.starts_with("---") || rest.starts_with("***") {
                return None;
            }
            (&rest[..2], &rest[2..])
        } else {
            let digits = rest.bytes().take_while(|b| b.is_ascii_digit()).count();
            if digits > 0
                && digits <= 9
                && matches!(rest.as_bytes().get(digits), Some(b'.' | b')'))
                && rest.as_bytes().get(digits + 1) == Some(&b' ')
            {
                (&rest[..digits + 2], &rest[digits + 2..])
            } else {
                return None;
            }
        };

    let (checkbox, body) = if let Some(after) = after_marker.strip_prefix("[x] ") {
        (Some(("[x] ", true)), after)
    } else if let Some(after) = after_marker.strip_prefix("[X] ") {
        (Some(("[X] ", true)), after)
    } else if let Some(after) = after_marker.strip_prefix("[ ] ") {
        (Some(("[ ] ", false)), after)
    } else {
        (None, after_marker)
    };

    let hang_width = indent.chars().count()
        + marker.chars().count()
        + checkbox.map_or(0, |(c, _)| c.chars().count());

    Some(ListParts {
        indent,
        marker,
        checkbox,
        body,
        hang_width,
    })
}

fn render_list_row(list: ListParts<'_>, theme: &Theme, base_style: Style) -> StyledRow {
    let mut spans = Vec::new();
    if !list.indent.is_empty() {
        spans.push(StyledSpan::new(list.indent, base_style));
    }
    spans.push(StyledSpan::new(
        list.marker,
        base_style.patch(theme.md_bullet),
    ));
    let mut body_base = base_style;
    if let Some((box_str, checked)) = list.checkbox {
        let box_style = if checked {
            base_style.patch(theme.tool_ok).patch(theme.md_bold)
        } else {
            base_style.patch(theme.md_bullet)
        };
        spans.push(StyledSpan::new(box_str, box_style));
        if checked {
            body_base = body_base.patch(theme.md_strike);
        }
    }
    spans.extend(parse_inline_spans(list.body, theme, body_base));
    let hang = " ".repeat(list.hang_width);
    StyledRow::from_spans(spans).with_hang_prefix(vec![StyledSpan::new(hang, base_style)])
}

pub fn parse_inline_spans(text: &str, theme: &Theme, base_style: Style) -> Vec<StyledSpan> {
    if text.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    parse_inline_range(text, 0, text.len(), theme, base_style, &mut out);
    merge_adjacent_spans(out)
}

fn merge_adjacent_spans(spans: Vec<StyledSpan>) -> Vec<StyledSpan> {
    let mut merged: Vec<StyledSpan> = Vec::with_capacity(spans.len());
    for span in spans {
        if span.text.is_empty() {
            continue;
        }
        if let Some(last) = merged.last_mut() {
            if last.style == span.style {
                last.text.push_str(&span.text);
                continue;
            }
        }
        merged.push(span);
    }
    merged
}

fn is_md_escapable(b: u8) -> bool {
    matches!(
        b,
        b'\\'
            | b'`'
            | b'*'
            | b'_'
            | b'{'
            | b'}'
            | b'['
            | b']'
            | b'('
            | b')'
            | b'#'
            | b'+'
            | b'-'
            | b'.'
            | b'!'
            | b'|'
            | b'~'
    )
}

fn parse_inline_range(
    src: &str,
    start: usize,
    end: usize,
    theme: &Theme,
    base: Style,
    out: &mut Vec<StyledSpan>,
) {
    let mut pos = start;
    let mut literal_start = start;

    while pos < end {
        let bytes = src.as_bytes();
        let b = bytes[pos];

        // Backslash escape for Markdown punctuation: keep literal character,
        // but preserve `\x1b` / `\r` / `\n` / `\u{...}` from sanitizer verbatim.
        if b == b'\\' && pos + 1 < end && is_md_escapable(bytes[pos + 1]) {
            if literal_start < pos {
                out.push(StyledSpan::new(&src[literal_start..pos], base));
            }
            out.push(StyledSpan::new(&src[pos + 1..pos + 2], base));
            pos += 2;
            literal_start = pos;
            continue;
        }

        // Inline code: `...` or ``...`` (no nested inline parsing)
        if b == b'`' {
            let ticks = bytes[pos..end].iter().take_while(|&&c| c == b'`').count();
            if let Some(close) = find_closing_backticks(src, pos + ticks, end, ticks) {
                if literal_start < pos {
                    out.push(StyledSpan::new(&src[literal_start..pos], base));
                }
                let inner = &src[pos + ticks..close];
                let trimmed = if inner.len() >= 2
                    && inner.starts_with(' ')
                    && inner.ends_with(' ')
                    && inner.bytes().any(|c| c != b' ')
                {
                    &inner[1..inner.len() - 1]
                } else {
                    inner
                };
                out.push(StyledSpan::new(trimmed, base.patch(theme.md_code_inline)));
                pos = close + ticks;
                literal_start = pos;
                continue;
            }
            pos += ticks;
            continue;
        }

        // Link: [text](url)
        if b == b'[' {
            if let Some((label_end, url_start, url_end, full_end)) = parse_link(src, pos, end) {
                if literal_start < pos {
                    out.push(StyledSpan::new(&src[literal_start..pos], base));
                }
                let link_style = base.patch(theme.md_link_text);
                parse_inline_range(src, pos + 1, label_end, theme, link_style, out);
                let url = &src[url_start..url_end];
                if !url.is_empty() && !url.eq_ignore_ascii_case(&src[pos + 1..label_end]) {
                    out.push(StyledSpan::new(
                        format!(" ({url})"),
                        base.patch(theme.md_link_url),
                    ));
                }
                pos = full_end;
                literal_start = pos;
                continue;
            }
        }

        // Strikethrough: ~~...~~
        if b == b'~' && pos + 1 < end && bytes[pos + 1] == b'~' {
            if let Some(close) = find_closing_delim(src, pos + 2, end, "~~") {
                if literal_start < pos {
                    out.push(StyledSpan::new(&src[literal_start..pos], base));
                }
                parse_inline_range(src, pos + 2, close, theme, base.patch(theme.md_strike), out);
                pos = close + 2;
                literal_start = pos;
                continue;
            }
        }

        // Bold+italic: ***...*** or ___...___
        if (b == b'*' || b == b'_') && pos + 2 < end && bytes[pos + 1] == b && bytes[pos + 2] == b {
            let delim = if b == b'*' { "***" } else { "___" };
            let word_ok = b == b'*' || is_word_boundary_open(src, pos, start);
            if word_ok {
                if let Some(close) = find_closing_emphasis(src, pos + 3, end, delim, b == b'_') {
                    if literal_start < pos {
                        out.push(StyledSpan::new(&src[literal_start..pos], base));
                    }
                    let style = base.patch(theme.md_bold).patch(theme.md_italic);
                    parse_inline_range(src, pos + 3, close, theme, style, out);
                    pos = close + 3;
                    literal_start = pos;
                    continue;
                }
            }
        }

        // Bold: **...** or __...__
        if (b == b'*' || b == b'_') && pos + 1 < end && bytes[pos + 1] == b {
            let delim = if b == b'*' { "**" } else { "__" };
            let word_ok = b == b'*' || is_word_boundary_open(src, pos, start);
            if word_ok {
                if let Some(close) = find_closing_emphasis(src, pos + 2, end, delim, b == b'_') {
                    if literal_start < pos {
                        out.push(StyledSpan::new(&src[literal_start..pos], base));
                    }
                    parse_inline_range(src, pos + 2, close, theme, base.patch(theme.md_bold), out);
                    pos = close + 2;
                    literal_start = pos;
                    continue;
                }
            }
        }

        // Italic: *...* or _..._
        if b == b'*' || b == b'_' {
            let delim = if b == b'*' { "*" } else { "_" };
            let word_ok = b == b'*' || is_word_boundary_open(src, pos, start);
            if word_ok {
                if let Some(close) = find_closing_emphasis(src, pos + 1, end, delim, b == b'_') {
                    if literal_start < pos {
                        out.push(StyledSpan::new(&src[literal_start..pos], base));
                    }
                    parse_inline_range(
                        src,
                        pos + 1,
                        close,
                        theme,
                        base.patch(theme.md_italic),
                        out,
                    );
                    pos = close + 1;
                    literal_start = pos;
                    continue;
                }
            }
        }

        let ch_len = src[pos..end].chars().next().map_or(1, char::len_utf8);
        pos += ch_len;
    }

    if literal_start < end {
        out.push(StyledSpan::new(&src[literal_start..end], base));
    }
}

fn find_closing_backticks(src: &str, mut pos: usize, end: usize, count: usize) -> Option<usize> {
    let bytes = src.as_bytes();
    while pos < end {
        if bytes[pos] == b'`' {
            let run = bytes[pos..end].iter().take_while(|&&c| c == b'`').count();
            if run == count {
                return Some(pos);
            }
            pos += run;
        } else {
            pos += 1;
        }
    }
    None
}

fn is_word_boundary_open(src: &str, pos: usize, min_start: usize) -> bool {
    if pos <= min_start {
        return true;
    }
    src[min_start..pos]
        .chars()
        .next_back()
        .is_none_or(|c| !c.is_alphanumeric())
}

fn is_word_boundary_close(src: &str, after_close: usize, max_end: usize) -> bool {
    if after_close >= max_end {
        return true;
    }
    src[after_close..max_end]
        .chars()
        .next()
        .is_none_or(|c| !c.is_alphanumeric())
}

fn find_closing_delim(src: &str, mut pos: usize, end: usize, delim: &str) -> Option<usize> {
    let dlen = delim.len();
    let content_start = pos;
    while pos + dlen <= end {
        if src.as_bytes()[pos] == b'`' {
            let ticks = src.as_bytes()[pos..end]
                .iter()
                .take_while(|&&c| c == b'`')
                .count();
            if let Some(close) = find_closing_backticks(src, pos + ticks, end, ticks) {
                pos = close + ticks;
                continue;
            }
        }
        if src[pos..end].starts_with(delim) && pos > content_start {
            return Some(pos);
        }
        pos += src[pos..end].chars().next().map_or(1, char::len_utf8);
    }
    None
}

fn find_closing_emphasis(
    src: &str,
    mut pos: usize,
    end: usize,
    delim: &str,
    require_word_boundary: bool,
) -> Option<usize> {
    let dlen = delim.len();
    let content_start = pos;
    let bytes = src.as_bytes();
    if content_start >= end || bytes[content_start] == b' ' {
        return None;
    }
    while pos + dlen <= end {
        if bytes[pos] == b'\\' && pos + 1 < end && is_md_escapable(bytes[pos + 1]) {
            pos += 2;
            continue;
        }
        if bytes[pos] == b'`' {
            let ticks = bytes[pos..end].iter().take_while(|&&c| c == b'`').count();
            if let Some(close) = find_closing_backticks(src, pos + ticks, end, ticks) {
                pos = close + ticks;
                continue;
            }
        }
        if src[pos..end].starts_with(delim) && pos > content_start && bytes[pos - 1] != b' ' {
            if dlen == 1 && bytes.get(pos + 1) == Some(&delim.as_bytes()[0]) {
                // Skip `**` when looking for single `*` so `***` / `**` inside `*...*` still works
                if let Some(inner_close) = find_closing_emphasis(
                    src,
                    pos + 2,
                    end,
                    if delim == "*" { "**" } else { "__" },
                    require_word_boundary,
                ) {
                    pos = inner_close + 2;
                    continue;
                }
            }
            if !require_word_boundary || is_word_boundary_close(src, pos + dlen, end) {
                return Some(pos);
            }
        }
        pos += src[pos..end].chars().next().map_or(1, char::len_utf8);
    }
    None
}

fn parse_link(src: &str, open_bracket: usize, end: usize) -> Option<(usize, usize, usize, usize)> {
    let bytes = src.as_bytes();
    let mut pos = open_bracket + 1;
    let mut depth = 1usize;
    while pos < end {
        match bytes[pos] {
            b'\\' if pos + 1 < end && is_md_escapable(bytes[pos + 1]) => pos += 2,
            b'`' => {
                let ticks = bytes[pos..end].iter().take_while(|&&c| c == b'`').count();
                if let Some(close) = find_closing_backticks(src, pos + ticks, end, ticks) {
                    pos = close + ticks;
                } else {
                    pos += ticks;
                }
            }
            b'[' => {
                depth += 1;
                pos += 1;
            }
            b']' => {
                depth -= 1;
                if depth == 0 {
                    break;
                }
                pos += 1;
            }
            _ => pos += src[pos..end].chars().next().map_or(1, char::len_utf8),
        }
    }
    if depth != 0 || pos == open_bracket + 1 {
        return None;
    }
    let label_end = pos;
    if bytes.get(label_end + 1) != Some(&b'(') {
        return None;
    }
    let url_start = label_end + 2;
    let mut u = url_start;
    let mut paren_depth = 1usize;
    while u < end {
        match bytes[u] {
            b'(' => {
                paren_depth += 1;
                u += 1;
            }
            b')' => {
                paren_depth -= 1;
                if paren_depth == 0 {
                    return Some((label_end, url_start, u, u + 1));
                }
                u += 1;
            }
            b' ' | b'\t' => return None,
            _ => u += src[u..end].chars().next().map_or(1, char::len_utf8),
        }
    }
    None
}

fn highlight_code_line(line: &str, lang: CodeLang, theme: &Theme) -> Vec<StyledSpan> {
    if theme.is_plain || lang == CodeLang::Other {
        return if line.is_empty() {
            Vec::new()
        } else {
            vec![StyledSpan::new(line, Style::default())]
        };
    }

    let bytes = line.as_bytes();
    let len = bytes.len();
    let mut pos = 0usize;
    let mut out: Vec<StyledSpan> = Vec::new();
    let mut after_fn_kw = false;

    while pos < len {
        // Line comments
        if matches!(lang, CodeLang::Rust | CodeLang::JsTs | CodeLang::JsonToml)
            && bytes[pos..].starts_with(b"//")
        {
            out.push(StyledSpan::new(&line[pos..], theme.syn_comment));
            break;
        }
        if matches!(
            lang,
            CodeLang::Elixir | CodeLang::Python | CodeLang::Bash | CodeLang::JsonToml
        ) && bytes[pos] == b'#'
        {
            // Keep Rust/JS `#` or Bash `${#...}` un-commented if inside token, but `#` at token boundary is comment
            let is_hash_comment = match lang {
                CodeLang::Elixir | CodeLang::Python | CodeLang::JsonToml => true,
                CodeLang::Bash => pos == 0 || bytes[pos - 1].is_ascii_whitespace(),
                _ => false,
            };
            if is_hash_comment {
                out.push(StyledSpan::new(&line[pos..], theme.syn_comment));
                break;
            }
        }
        if lang == CodeLang::Python && bytes[pos..].starts_with(b"\"\"\"") {
            out.push(StyledSpan::new(&line[pos..], theme.syn_string));
            break;
        }

        // Strings ("..." and '...')
        let b = bytes[pos];
        if b == b'"' || (b == b'\'' && should_parse_single_quote(line, pos, lang)) || b == b'`' {
            let end = scan_string(line, pos, b);
            out.push(StyledSpan::new(&line[pos..end], theme.syn_string));
            pos = end;
            after_fn_kw = false;
            continue;
        }

        // Rust lifetime `'a`
        if b == b'\'' && lang == CodeLang::Rust && pos + 1 < len && is_ident_start(bytes[pos + 1]) {
            let mut end = pos + 2;
            while end < len && is_ident_continue(bytes[end]) {
                end += 1;
            }
            out.push(StyledSpan::new(&line[pos..end], theme.syn_type));
            pos = end;
            after_fn_kw = false;
            continue;
        }

        // Numbers
        if b.is_ascii_digit() && (pos == 0 || !is_ident_continue(bytes[pos - 1])) {
            let mut end = pos + 1;
            while end < len
                && (bytes[end].is_ascii_alphanumeric() || bytes[end] == b'_' || bytes[end] == b'.')
            {
                end += 1;
            }
            out.push(StyledSpan::new(&line[pos..end], theme.syn_number));
            pos = end;
            after_fn_kw = false;
            continue;
        }

        // Elixir atoms `:atom`
        if lang == CodeLang::Elixir
            && b == b':'
            && pos + 1 < len
            && is_ident_start(bytes[pos + 1])
            && (pos == 0 || !is_ident_continue(bytes[pos - 1]))
        {
            let mut end = pos + 2;
            while end < len && (is_ident_continue(bytes[end]) || matches!(bytes[end], b'?' | b'!'))
            {
                end += 1;
            }
            out.push(StyledSpan::new(&line[pos..end], theme.syn_type));
            pos = end;
            after_fn_kw = false;
            continue;
        }

        // Bash `$VAR`
        if lang == CodeLang::Bash && b == b'$' && pos + 1 < len {
            let mut end = pos + 1;
            if bytes[end] == b'{' {
                if let Some(close) = line[end..].find('}') {
                    end += close + 1;
                    out.push(StyledSpan::new(&line[pos..end], theme.syn_type));
                    pos = end;
                    after_fn_kw = false;
                    continue;
                }
            } else if is_ident_start(bytes[end]) || bytes[end].is_ascii_digit() {
                end += 1;
                while end < len && is_ident_continue(bytes[end]) {
                    end += 1;
                }
                out.push(StyledSpan::new(&line[pos..end], theme.syn_type));
                pos = end;
                after_fn_kw = false;
                continue;
            }
        }

        // Identifiers / keywords / types / functions
        if is_ident_start(b) {
            let mut end = pos + 1;
            while end < len && is_ident_continue(bytes[end]) {
                end += 1;
            }
            if lang == CodeLang::Elixir && end < len && matches!(bytes[end], b'?' | b'!') {
                end += 1;
            }
            let word = &line[pos..end];
            let style = if is_keyword(word, lang) {
                after_fn_kw = matches!(word, "fn" | "def" | "defp" | "function");
                theme.syn_keyword
            } else if is_literal_keyword(word, lang) {
                after_fn_kw = false;
                theme.syn_number
            } else if after_fn_kw
                || bytes.get(end) == Some(&b'(')
                || bytes[end..].starts_with(b"!(")
            {
                after_fn_kw = false;
                theme.syn_fn
            } else if is_type_name(word, lang) {
                after_fn_kw = false;
                theme.syn_type
            } else {
                after_fn_kw = false;
                Style::default()
            };
            out.push(StyledSpan::new(word, style));
            pos = end;
            continue;
        }

        // Non-identifier single character or UTF-8 char
        let ch_len = line[pos..].chars().next().map_or(1, char::len_utf8);
        if !bytes[pos].is_ascii_whitespace() {
            after_fn_kw = false;
        }
        out.push(StyledSpan::new(&line[pos..pos + ch_len], Style::default()));
        pos += ch_len;
    }

    merge_adjacent_spans(out)
}

fn should_parse_single_quote(line: &str, pos: usize, lang: CodeLang) -> bool {
    if lang != CodeLang::Rust {
        return true;
    }
    let rest = &line.as_bytes()[pos + 1..];
    matches!(
        rest,
        [b'\\', _, b'\'', ..] | [b'\\', b'x', _, _, b'\'', ..] | [_, b'\'', ..]
    )
}

fn scan_string(line: &str, start: usize, quote: u8) -> usize {
    let bytes = line.as_bytes();
    let mut i = start + 1;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            i += 2;
            continue;
        }
        if bytes[i] == quote {
            return i + 1;
        }
        i += 1;
    }
    bytes.len()
}

fn is_ident_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_'
}

fn is_ident_continue(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

fn is_type_name(word: &str, lang: CodeLang) -> bool {
    if word.starts_with(|c: char| c.is_ascii_uppercase())
        && word.chars().any(|c| c.is_ascii_lowercase())
    {
        return true;
    }
    match lang {
        CodeLang::Rust => matches!(
            word,
            "bool"
                | "char"
                | "str"
                | "u8"
                | "u16"
                | "u32"
                | "u64"
                | "u128"
                | "usize"
                | "i8"
                | "i16"
                | "i32"
                | "i64"
                | "i128"
                | "isize"
                | "f32"
                | "f64"
                | "Self"
                | "Option"
                | "Result"
                | "Vec"
                | "String"
                | "Box"
                | "Arc"
                | "Rc"
        ),
        CodeLang::JsTs => matches!(
            word,
            "string" | "number" | "boolean" | "void" | "never" | "unknown" | "any" | "Promise"
        ),
        CodeLang::Python => matches!(
            word,
            "int" | "str" | "float" | "bool" | "list" | "dict" | "tuple" | "set" | "bytes"
        ),
        _ => false,
    }
}

fn is_literal_keyword(word: &str, lang: CodeLang) -> bool {
    match lang {
        CodeLang::Rust | CodeLang::JsTs | CodeLang::JsonToml | CodeLang::Bash => {
            matches!(word, "true" | "false" | "null" | "undefined" | "NaN")
        }
        CodeLang::Elixir => matches!(word, "true" | "false" | "nil"),
        CodeLang::Python => matches!(word, "True" | "False" | "None"),
        CodeLang::Diff | CodeLang::Other => false,
    }
}

fn is_keyword(word: &str, lang: CodeLang) -> bool {
    match lang {
        CodeLang::Rust => matches!(
            word,
            "as" | "async"
                | "await"
                | "break"
                | "const"
                | "continue"
                | "crate"
                | "dyn"
                | "else"
                | "enum"
                | "extern"
                | "fn"
                | "for"
                | "if"
                | "impl"
                | "in"
                | "let"
                | "loop"
                | "match"
                | "mod"
                | "move"
                | "mut"
                | "pub"
                | "ref"
                | "return"
                | "self"
                | "static"
                | "struct"
                | "super"
                | "trait"
                | "type"
                | "unsafe"
                | "use"
                | "where"
                | "while"
        ),
        CodeLang::Elixir => matches!(
            word,
            "after"
                | "and"
                | "case"
                | "catch"
                | "cond"
                | "def"
                | "defdelegate"
                | "defexception"
                | "defimpl"
                | "defmacro"
                | "defmacrop"
                | "defmodule"
                | "defp"
                | "defprotocol"
                | "defstruct"
                | "do"
                | "else"
                | "end"
                | "fn"
                | "for"
                | "if"
                | "import"
                | "in"
                | "not"
                | "or"
                | "quote"
                | "raise"
                | "receive"
                | "require"
                | "rescue"
                | "try"
                | "unless"
                | "unquote"
                | "use"
                | "when"
                | "with"
        ),
        CodeLang::JsTs => matches!(
            word,
            "as" | "async"
                | "await"
                | "break"
                | "case"
                | "catch"
                | "class"
                | "const"
                | "continue"
                | "default"
                | "delete"
                | "do"
                | "else"
                | "enum"
                | "export"
                | "extends"
                | "finally"
                | "for"
                | "from"
                | "function"
                | "if"
                | "implements"
                | "import"
                | "in"
                | "instanceof"
                | "interface"
                | "let"
                | "new"
                | "of"
                | "return"
                | "static"
                | "switch"
                | "this"
                | "throw"
                | "try"
                | "type"
                | "typeof"
                | "var"
                | "while"
                | "yield"
        ),
        CodeLang::Python => matches!(
            word,
            "and"
                | "as"
                | "assert"
                | "async"
                | "await"
                | "break"
                | "class"
                | "continue"
                | "def"
                | "del"
                | "elif"
                | "else"
                | "except"
                | "finally"
                | "for"
                | "from"
                | "global"
                | "if"
                | "import"
                | "in"
                | "is"
                | "lambda"
                | "nonlocal"
                | "not"
                | "or"
                | "pass"
                | "raise"
                | "return"
                | "try"
                | "while"
                | "with"
                | "yield"
        ),
        CodeLang::Bash => matches!(
            word,
            "if" | "then"
                | "else"
                | "elif"
                | "fi"
                | "case"
                | "esac"
                | "for"
                | "while"
                | "until"
                | "do"
                | "done"
                | "in"
                | "function"
                | "return"
                | "local"
                | "export"
                | "readonly"
                | "set"
                | "unset"
        ),
        CodeLang::JsonToml | CodeLang::Diff | CodeLang::Other => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline_markdown_handles_bold_italic_code_strike_links_and_streaming() {
        let theme = Theme::dark();
        let rows = render_markdown_lines(
            "Hello **bold** *italic* _word_ `**not bold**` ~~gone~~ [docs](https://example.com) and **unclosed",
            &theme,
            Style::default(),
        );
        assert_eq!(rows.len(), 1);
        let spans = &rows[0].spans;
        assert_eq!(
            rows[0].plain_text(),
            "Hello bold italic word **not bold** gone docs (https://example.com) and **unclosed"
        );

        assert!(spans
            .iter()
            .any(|s| s.text == "bold" && s.style == theme.md_bold));
        assert!(spans
            .iter()
            .any(|s| s.text == "italic" && s.style == theme.md_italic));
        assert!(spans
            .iter()
            .any(|s| s.text == "word" && s.style == theme.md_italic));
        assert!(spans
            .iter()
            .any(|s| s.text == "**not bold**" && s.style == theme.md_code_inline));
        assert!(spans
            .iter()
            .any(|s| s.text == "gone" && s.style == theme.md_strike));
        assert!(spans
            .iter()
            .any(|s| s.text == "docs" && s.style == theme.md_link_text));
        assert!(spans
            .iter()
            .any(|s| s.text == " (https://example.com)" && s.style == theme.md_link_url));
        assert!(spans
            .iter()
            .any(|s| s.text.ends_with("**unclosed") && s.style == Style::default()));
    }

    #[test]
    fn snake_case_underscores_are_not_treated_as_italics() {
        let theme = Theme::dark();
        let rows = render_markdown_lines("foo_bar_baz", &theme, Style::default());
        assert_eq!(rows[0].plain_text(), "foo_bar_baz");
        assert_eq!(rows[0].spans.len(), 1);
        assert_eq!(rows[0].spans[0].style, Style::default());
    }

    #[test]
    fn blocks_render_headings_quotes_lists_hr_and_hanging_prefixes() {
        let theme = Theme::dark();
        let md = "# H1\n## H2\n### H3\n> quoted **line**\n- item one\n  1. [x] done\n---";
        let rows = render_markdown_lines(md, &theme, Style::default());
        assert_eq!(rows.len(), 7);

        assert!(rows[0].spans.iter().all(|s| s.style == theme.md_h1));
        assert!(rows[1].spans.iter().all(|s| s.style == theme.md_h2));
        assert!(rows[2].spans.iter().all(|s| s.style == theme.md_h3));

        assert_eq!(rows[3].spans[0].text, "│ ");
        assert_eq!(rows[3].spans[0].style, theme.md_quote_border);
        assert_eq!(rows[3].hang_prefix[0].text, "│ ");
        assert!(rows[3]
            .spans
            .iter()
            .any(|s| s.text == "line" && s.style == theme.md_quote_text.patch(theme.md_bold)));

        assert_eq!(rows[4].spans[0].text, "- ");
        assert_eq!(rows[4].spans[0].style, theme.md_bullet);
        assert_eq!(rows[4].hang_prefix[0].text, "  ");

        assert_eq!(rows[5].spans[1].text, "1. ");
        assert_eq!(rows[5].spans[2].text, "[x] ");
        assert_eq!(rows[5].hang_prefix[0].text, "         ");

        assert!(rows[6].hr_style.is_some());
    }

    #[test]
    fn fenced_code_highlights_languages_and_handles_unclosed_streaming_fence() {
        let theme = Theme::dark();
        let md = "```rust\n// note\nfn greet(name: &str) -> u32 {\n    let s = \"hi\";\n    42\n}";
        let rows = render_markdown_lines(md, &theme, Style::default());
        assert_eq!(rows.len(), 6);
        assert_eq!(rows[0].spans[1].text, "rust");
        assert_eq!(rows[1].spans[0].style, theme.syn_comment);
        assert!(rows[2]
            .spans
            .iter()
            .any(|s| s.text == "fn" && s.style == theme.syn_keyword));
        assert!(rows[2]
            .spans
            .iter()
            .any(|s| s.text == "greet" && s.style == theme.syn_fn));
        assert!(rows[2]
            .spans
            .iter()
            .any(|s| s.text == "u32" && s.style == theme.syn_type));
        assert!(rows[3]
            .spans
            .iter()
            .any(|s| s.text == "\"hi\"" && s.style == theme.syn_string));
        assert!(rows[4]
            .spans
            .iter()
            .any(|s| s.text == "42" && s.style == theme.syn_number));
    }

    #[test]
    fn untrusted_escapes_inside_markdown_spans_are_sanitized() {
        let theme = Theme::dark();
        let md = "**bold\x1b[31m** `code\x1b]0;pwn\x07` [lnk\x1b[2J](https://x\u{009b}y) [ok](https://ex/\x1b[2J)\n```rust\nlet x = \"\x1b[1m\";\n```";
        let rows = render_markdown_lines(md, &theme, Style::default());
        let joined: String = rows
            .iter()
            .map(StyledRow::plain_text)
            .collect::<Vec<_>>()
            .join("\n");
        assert!(!joined.contains('\x1b'));
        assert!(!joined.contains('\x07'));
        assert!(!joined.contains('\u{009b}'));
        assert!(joined.contains("\\x1b[31m"));
        assert!(joined.contains("\\x1b]0;pwn\\x07"));
        assert!(joined.contains("\\x1b[2J"));
        assert!(joined.contains("\\u{009b}"));
        assert!(joined.contains("\\x1b[1m"));
    }
}
