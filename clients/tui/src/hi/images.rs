use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use std::fmt::Write as _;

pub const MAX_INLINE_IMAGE_BASE64_BYTES: usize = 4_000_000;
const KITTY_CHUNK_SIZE: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum InlineImageProtocol {
    #[default]
    Off,
    Kitty,
    ITerm2,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InlineImageBlock {
    pub key: String,
    pub media_type: String,
    pub base64_data: String,
    pub decoded_bytes: usize,
}

impl InlineImageProtocol {
    pub fn detect() -> Self {
        Self::detect_from_env(|key| std::env::var(key).ok())
    }

    pub fn detect_from_env<'a, F>(mut get: F) -> Self
    where
        F: FnMut(&'a str) -> Option<String>,
    {
        if get("NO_COLOR").is_some_and(|v| !v.is_empty()) {
            return Self::Off;
        }

        if let Some(override_val) = get("HI_INLINE_IMAGES") {
            let trimmed = override_val.trim();
            if !trimmed.is_empty() {
                if trimmed.eq_ignore_ascii_case("kitty") {
                    return Self::Kitty;
                }
                if trimmed.eq_ignore_ascii_case("iterm2") {
                    return Self::ITerm2;
                }
                if trimmed.eq_ignore_ascii_case("off")
                    || trimmed.eq_ignore_ascii_case("0")
                    || trimmed.eq_ignore_ascii_case("false")
                    || trimmed.eq_ignore_ascii_case("none")
                {
                    return Self::Off;
                }
                return Self::Off;
            }
        }

        if get("TMUX").is_some_and(|v| !v.is_empty()) {
            return Self::Off;
        }

        if get("KITTY_WINDOW_ID").is_some_and(|v| !v.is_empty())
            || get("TERM").is_some_and(|v| v == "xterm-kitty")
            || get("GHOSTTY_RESOURCES_DIR").is_some_and(|v| !v.is_empty())
        {
            return Self::Kitty;
        }

        if get("TERM_PROGRAM").is_some_and(|v| v == "iTerm.app" || v == "WezTerm")
            || get("LC_TERMINAL").is_some_and(|v| v == "iTerm2")
        {
            return Self::ITerm2;
        }

        Self::Off
    }

    pub fn format_sequence(self, media_type: &str, raw_base64: &str) -> Option<String> {
        let block = validate_image_block("", media_type, raw_base64)?;
        self.format_validated_block(&block)
    }

    pub fn format_validated_block(self, block: &InlineImageBlock) -> Option<String> {
        if !is_strict_base64_payload(&block.base64_data) {
            return None;
        }
        match self {
            Self::Off => None,
            Self::Kitty => {
                if block.media_type != "image/png" {
                    return None;
                }
                Some(encode_kitty_png(&block.base64_data))
            }
            Self::ITerm2 => {
                if !matches!(
                    block.media_type.as_str(),
                    "image/png" | "image/jpeg" | "image/gif" | "image/webp"
                ) {
                    return None;
                }
                Some(encode_iterm2(&block.base64_data, block.decoded_bytes))
            }
        }
    }
}

pub fn sanitize_and_validate_base64(raw: &str) -> Option<(String, usize)> {
    let mut cleaned = String::with_capacity(raw.len().min(1024));
    for b in raw.bytes() {
        if b.is_ascii_whitespace() {
            continue;
        }
        if !(b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'=') {
            return None;
        }
        cleaned.push(b as char);
        if cleaned.len() > MAX_INLINE_IMAGE_BASE64_BYTES {
            return None;
        }
    }
    if cleaned.is_empty() {
        return None;
    }
    let decoded = STANDARD.decode(cleaned.as_bytes()).ok()?;
    if decoded.is_empty() {
        return None;
    }
    Some((cleaned, decoded.len()))
}

pub fn validate_image_block(
    key: impl Into<String>,
    media_type: &str,
    raw_base64: &str,
) -> Option<InlineImageBlock> {
    let normalized_mime = media_type.trim().to_ascii_lowercase();
    if !matches!(
        normalized_mime.as_str(),
        "image/png" | "image/jpeg" | "image/gif" | "image/webp"
    ) {
        return None;
    }
    let (base64_data, decoded_bytes) = sanitize_and_validate_base64(raw_base64)?;
    Some(InlineImageBlock {
        key: key.into(),
        media_type: normalized_mime,
        base64_data,
        decoded_bytes,
    })
}

fn is_strict_base64_payload(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_INLINE_IMAGE_BASE64_BYTES
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'=')
}

fn encode_kitty_png(b64: &str) -> String {
    let bytes = b64.as_bytes();
    let total_chunks = bytes.len().div_ceil(KITTY_CHUNK_SIZE);
    let mut out = String::with_capacity(bytes.len() + total_chunks * 24);
    for (idx, chunk) in bytes.chunks(KITTY_CHUNK_SIZE).enumerate() {
        let chunk_str = std::str::from_utf8(chunk).expect("validated ASCII base64");
        let is_first = idx == 0;
        let has_more = idx + 1 < total_chunks;
        if is_first && !has_more {
            let _ = write!(out, "\x1b_Gf=100,a=T,q=2;{chunk_str}\x1b\\");
        } else if is_first {
            let _ = write!(out, "\x1b_Gf=100,a=T,q=2,m=1;{chunk_str}\x1b\\");
        } else if has_more {
            let _ = write!(out, "\x1b_Gm=1;{chunk_str}\x1b\\");
        } else {
            let _ = write!(out, "\x1b_Gm=0;{chunk_str}\x1b\\");
        }
    }
    out
}

fn encode_iterm2(b64: &str, decoded_bytes: usize) -> String {
    format!("\x1b]1337;File=inline=1;size={decoded_bytes}:{b64}\x07")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env_lookup<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl FnMut(&'a str) -> Option<String> {
        let map: HashMap<&'a str, &'a str> = pairs.iter().copied().collect();
        move |k| map.get(k).map(|v| (*v).to_string())
    }

    #[test]
    fn detects_kitty_iterm2_tmux_no_color_and_explicit_overrides() {
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[])),
            InlineImageProtocol::Off
        );
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[("KITTY_WINDOW_ID", "1")])),
            InlineImageProtocol::Kitty
        );
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[("TERM", "xterm-kitty")])),
            InlineImageProtocol::Kitty
        );
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[(
                "GHOSTTY_RESOURCES_DIR",
                "/Applications/Ghostty.app/Contents/Resources/ghostty"
            )])),
            InlineImageProtocol::Kitty
        );
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[("TERM_PROGRAM", "iTerm.app")])),
            InlineImageProtocol::ITerm2
        );
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[("TERM_PROGRAM", "WezTerm")])),
            InlineImageProtocol::ITerm2
        );
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[("LC_TERMINAL", "iTerm2")])),
            InlineImageProtocol::ITerm2
        );

        // TMUX suppresses auto-detection, but explicit HI_INLINE_IMAGES overrides it
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[
                ("TMUX", "/tmp/tmux-1000/default,123,0"),
                ("KITTY_WINDOW_ID", "1"),
            ])),
            InlineImageProtocol::Off
        );
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[
                ("TMUX", "/tmp/tmux-1000/default,123,0"),
                ("HI_INLINE_IMAGES", "kitty"),
            ])),
            InlineImageProtocol::Kitty
        );
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[
                ("TMUX", "/tmp/tmux-1000/default,123,0"),
                ("HI_INLINE_IMAGES", "iterm2"),
            ])),
            InlineImageProtocol::ITerm2
        );
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[
                ("KITTY_WINDOW_ID", "1"),
                ("HI_INLINE_IMAGES", "off"),
            ])),
            InlineImageProtocol::Off
        );

        // NO_COLOR disables everything including explicit override
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[
                ("NO_COLOR", "1"),
                ("HI_INLINE_IMAGES", "kitty"),
                ("KITTY_WINDOW_ID", "1"),
            ])),
            InlineImageProtocol::Off
        );
        // Empty NO_COLOR does not disable (matches theme.rs convention)
        assert_eq!(
            InlineImageProtocol::detect_from_env(env_lookup(&[
                ("NO_COLOR", ""),
                ("KITTY_WINDOW_ID", "1"),
            ])),
            InlineImageProtocol::Kitty
        );
    }

    #[test]
    fn rejects_escape_injection_invalid_base64_and_oversized_payloads() {
        let evil_inputs = [
            "AAAA\x1b]52;c;YQ==\x07",
            "AAAA\x07BBBB",
            "AAAA\x1b\\BBBB",
            "AAAA;a=T,f=100;BBBB",
            "not valid base64!",
            "   \n\t  ",
            "====",
        ];
        for evil in evil_inputs {
            assert!(
                InlineImageProtocol::Kitty
                    .format_sequence("image/png", evil)
                    .is_none(),
                "kitty must reject {evil:?}"
            );
            assert!(
                InlineImageProtocol::ITerm2
                    .format_sequence("image/png", evil)
                    .is_none(),
                "iterm2 must reject {evil:?}"
            );
        }

        // Oversized (> 4_000_000 bytes after stripping whitespace)
        let too_big = "A".repeat(MAX_INLINE_IMAGE_BASE64_BYTES + 4);
        assert!(InlineImageProtocol::Kitty
            .format_sequence("image/png", &too_big)
            .is_none());
        assert!(InlineImageProtocol::ITerm2
            .format_sequence("image/png", &too_big)
            .is_none());
    }

    #[test]
    fn formats_kitty_single_and_chunked_png_only_and_iterm2_all_supported_mimes() {
        let small = STANDARD.encode(b"\x89PNG\r\n\x1a\nhello");
        let with_ws = format!("  {}\n  {} ", &small[..4], &small[4..]);

        let kitty_single = InlineImageProtocol::Kitty
            .format_sequence("image/png", &with_ws)
            .expect("kitty png");
        assert_eq!(kitty_single, format!("\x1b_Gf=100,a=T,q=2;{small}\x1b\\"));

        // Kitty rejects non-PNG mimes
        for mime in ["image/jpeg", "image/gif", "image/webp", "image/svg+xml"] {
            assert!(
                InlineImageProtocol::Kitty
                    .format_sequence(mime, &small)
                    .is_none(),
                "kitty must not emit for {mime}"
            );
        }

        // Kitty multi-chunk (> 4096 base64 chars)
        let raw_bytes = vec![0xABu8; 4000]; // -> 5336 base64 chars -> 2 chunks
        let big_b64 = STANDARD.encode(&raw_bytes);
        assert!(big_b64.len() > KITTY_CHUNK_SIZE);
        let kitty_multi = InlineImageProtocol::Kitty
            .format_sequence("image/png", &big_b64)
            .expect("kitty multi-chunk");
        let prefix1 = format!(
            "\x1b_Gf=100,a=T,q=2,m=1;{}\x1b\\",
            &big_b64[..KITTY_CHUNK_SIZE]
        );
        let prefix2 = format!("\x1b_Gm=0;{}\x1b\\", &big_b64[KITTY_CHUNK_SIZE..]);
        assert_eq!(kitty_multi, format!("{prefix1}{prefix2}"));

        // 3 chunks (> 8192 base64 chars)
        let three_chunk_b64 = STANDARD.encode(vec![0xCDu8; 7000]); // -> 9336 chars
        let kitty_three = InlineImageProtocol::Kitty
            .format_sequence("image/png", &three_chunk_b64)
            .expect("kitty 3 chunks");
        assert!(kitty_three.contains("\x1b_Gf=100,a=T,q=2,m=1;"));
        assert!(kitty_three.contains("\x1b_Gm=1;"));
        assert!(kitty_three.contains("\x1b_Gm=0;"));

        // iTerm2 supports png, jpeg, gif, webp, rejects svg
        let payload = b"0123456789";
        let payload_b64 = STANDARD.encode(payload);
        for mime in ["image/png", "image/jpeg", "image/gif", "image/webp"] {
            let seq = InlineImageProtocol::ITerm2
                .format_sequence(mime, &payload_b64)
                .expect("iterm2 supported mime");
            assert_eq!(
                seq,
                format!(
                    "\x1b]1337;File=inline=1;size={}:{payload_b64}\x07",
                    payload.len()
                )
            );
        }
        assert!(InlineImageProtocol::ITerm2
            .format_sequence("image/svg+xml", &payload_b64)
            .is_none());
        assert!(InlineImageProtocol::Off
            .format_sequence("image/png", &payload_b64)
            .is_none());
    }
}
