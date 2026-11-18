use serde_json::{json, Value};
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};

#[cfg(unix)]
use std::os::unix::fs::MetadataExt;

pub const MAX_API_JSON_BYTES: usize = 4_000_000;
pub const MAX_BLOCK_JSON_BYTES: usize = 3_500_000;
pub const MAX_TEXT_BYTES: usize = 1_048_576;
pub const MAX_IMAGE_BYTES: usize = 2_600_000;

const IMAGE_SNIFF_BYTES: usize = 4100;
const MAX_LIST_RESULTS: usize = 200;
const MAX_LIST_CANDIDATES: usize = 2_000;
const MAX_DIR_SCAN: usize = 10_000;

const PNG_SIGNATURE: [u8; 8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

pub fn list(dir: &Path, prefix: &str) -> io::Result<Vec<(String, String)>> {
    if dir.as_os_str().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "directory path cannot be empty",
        ));
    }
    if prefix.contains('\0') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "path prefix contains NUL byte",
        ));
    }

    let Some(plan) = plan_list(dir, prefix) else {
        return Ok(Vec::new());
    };

    let read_dir = match fs::read_dir(&plan.search_dir) {
        Ok(rd) => rd,
        Err(err)
            if plan.scoped_subpath
                && matches!(
                    err.kind(),
                    io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied
                ) =>
        {
            return Ok(Vec::new());
        }
        Err(err) if plan.scoped_subpath && is_not_a_directory(&err) => {
            return Ok(Vec::new());
        }
        Err(err) => return Err(err),
    };

    let prefix_lower = plan.file_prefix.to_lowercase();
    let mut matches: Vec<(bool, String, String, String)> = Vec::new();

    for (scanned, entry_res) in read_dir.enumerate() {
        if scanned >= MAX_DIR_SCAN || matches.len() >= MAX_LIST_CANDIDATES {
            break;
        }
        let Ok(entry) = entry_res else {
            continue;
        };
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if name.contains('\0') {
            continue;
        }
        let name_lower = name.to_lowercase();
        if !prefix_lower.is_empty() && !name_lower.starts_with(&prefix_lower) {
            continue;
        }
        let Ok(ft) = entry.file_type() else {
            continue;
        };
        // Never follow symlinks or list FIFOs/sockets/devices.
        if ft.is_symlink() || (!ft.is_dir() && !ft.is_file()) {
            continue;
        }

        let is_dir = ft.is_dir();
        let value = if is_dir {
            format!("{}{name}/", plan.display_dir)
        } else {
            format!("{}{name}", plan.display_dir)
        };
        let label = if is_dir { format!("{name}/") } else { name };
        matches.push((is_dir, name_lower, value, label));
    }

    matches.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| a.1.cmp(&b.1))
            .then_with(|| a.3.cmp(&b.3))
    });
    matches.truncate(MAX_LIST_RESULTS);

    Ok(matches
        .into_iter()
        .map(|(_, _, value, label)| (value, label))
        .collect())
}

pub fn attach(dir: &Path, path: &str) -> io::Result<Value> {
    if path.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "attachment path cannot be empty",
        ));
    }
    if path.contains('\0') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "attachment path contains NUL byte",
        ));
    }

    let resolved = resolve_local_path(dir, path)?;
    let lmeta = fs::symlink_metadata(&resolved)?;
    let ltype = lmeta.file_type();

    if ltype.is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("refusing to attach symlink: {path}"),
        ));
    }
    if ltype.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("cannot attach directory: {path}"),
        ));
    }
    if !ltype.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("cannot attach non-regular file: {path}"),
        ));
    }

    if lmeta.len() > MAX_IMAGE_BYTES as u64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "file {path} ({} bytes) exceeds maximum attachment size ({} bytes)",
                lmeta.len(),
                MAX_IMAGE_BYTES
            ),
        ));
    }

    let mut file = File::open(&resolved)?;
    let fmeta = file.metadata()?;
    if !fmeta.file_type().is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("cannot attach non-regular file: {path}"),
        ));
    }
    #[cfg(unix)]
    if lmeta.dev() != fmeta.dev() || lmeta.ino() != fmeta.ino() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("file changed while opening: {path}"),
        ));
    }

    let head = read_bounded(&mut file, IMAGE_SNIFF_BYTES)?;
    if let Some(media_type) = detect_supported_image_mime(&head) {
        let mut bytes = head;
        let remaining_budget = MAX_IMAGE_BYTES.saturating_sub(bytes.len());
        let tail = read_bounded(&mut file, remaining_budget + 1)?;
        if tail.len() > remaining_budget {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("image {path} exceeds maximum attachment size ({MAX_IMAGE_BYTES} bytes)"),
            ));
        }
        bytes.extend_from_slice(&tail);

        let encoded = encode_base64(&bytes);
        let block = json!({
            "type": "image",
            "media_type": media_type,
            "data": encoded,
        });
        enforce_json_budget(&block, path)?;
        return Ok(block);
    }

    if has_supported_image_extension(&resolved) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("file {path} has an image extension but invalid or unsupported image bytes"),
        ));
    }

    if lmeta.len() > MAX_TEXT_BYTES as u64 || head.len() > MAX_TEXT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("text file {path} exceeds maximum byte budget ({MAX_TEXT_BYTES} bytes)"),
        ));
    }

    let mut bytes = head;
    let remaining_budget = MAX_TEXT_BYTES.saturating_sub(bytes.len());
    let tail = read_bounded(&mut file, remaining_budget + 1)?;
    if tail.len() > remaining_budget {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("text file {path} exceeds maximum byte budget ({MAX_TEXT_BYTES} bytes)"),
        ));
    }
    bytes.extend_from_slice(&tail);

    if bytes.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("cannot attach binary file (NUL byte detected): {path}"),
        ));
    }

    let raw_text = String::from_utf8(bytes).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("cannot attach non-UTF-8 file: {path}"),
        )
    })?;
    let clean_text = raw_text.strip_prefix('\u{FEFF}').unwrap_or(&raw_text);
    let formatted = format_attached_text(path, clean_text);

    let block = json!({
        "type": "text",
        "text": formatted,
    });
    enforce_json_budget(&block, path)?;
    Ok(block)
}

struct ListPlan {
    search_dir: PathBuf,
    file_prefix: String,
    display_dir: String,
    scoped_subpath: bool,
}

fn plan_list(dir: &Path, prefix: &str) -> Option<ListPlan> {
    if prefix == "~" || prefix == "~/" {
        let home = local_home_dir()?;
        return Some(ListPlan {
            search_dir: home,
            file_prefix: String::new(),
            display_dir: "~/".to_string(),
            scoped_subpath: true,
        });
    }

    if let Some(after_tilde) = prefix.strip_prefix("~/") {
        let home = local_home_dir()?;
        return Some(match after_tilde.rfind('/') {
            Some(slash_idx) => {
                let sub = &after_tilde[..slash_idx];
                let file_prefix = after_tilde[slash_idx + 1..].to_string();
                let search_dir = if sub.is_empty() { home } else { home.join(sub) };
                let display_dir = if sub.is_empty() {
                    "~/".to_string()
                } else {
                    format!("~/{sub}/")
                };
                ListPlan {
                    search_dir,
                    file_prefix,
                    display_dir,
                    scoped_subpath: true,
                }
            }
            None => ListPlan {
                search_dir: home,
                file_prefix: after_tilde.to_string(),
                display_dir: "~/".to_string(),
                scoped_subpath: true,
            },
        });
    }

    if prefix.starts_with('/') {
        let slash_idx = prefix.rfind('/')?;
        let dir_part = &prefix[..=slash_idx];
        let file_prefix = prefix[slash_idx + 1..].to_string();
        return Some(ListPlan {
            search_dir: PathBuf::from(dir_part),
            file_prefix,
            display_dir: dir_part.to_string(),
            scoped_subpath: true,
        });
    }

    if let Some(slash_idx) = prefix.rfind('/') {
        let dir_part = &prefix[..=slash_idx];
        let file_prefix = prefix[slash_idx + 1..].to_string();
        return Some(ListPlan {
            search_dir: dir.join(dir_part),
            file_prefix,
            display_dir: dir_part.to_string(),
            scoped_subpath: true,
        });
    }

    Some(ListPlan {
        search_dir: dir.to_path_buf(),
        file_prefix: prefix.to_string(),
        display_dir: String::new(),
        scoped_subpath: false,
    })
}

fn local_home_dir() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    if home.is_empty() {
        return None;
    }
    Some(PathBuf::from(home))
}

fn resolve_local_path(dir: &Path, path: &str) -> io::Result<PathBuf> {
    if path == "~" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "cannot attach home directory '~'",
        ));
    }
    if let Some(rest) = path.strip_prefix("~/") {
        let home = local_home_dir().ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "HOME is not set for '~/' path")
        })?;
        return Ok(home.join(rest));
    }

    let candidate = Path::new(path);
    if candidate.is_absolute() {
        return Ok(candidate.to_path_buf());
    }
    if dir.as_os_str().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "base directory cannot be empty for relative attachment path",
        ));
    }
    Ok(dir.join(candidate))
}

fn is_not_a_directory(err: &io::Error) -> bool {
    err.kind() == io::ErrorKind::NotADirectory || err.raw_os_error() == Some(20)
}

fn read_bounded(file: &mut File, max_bytes: usize) -> io::Result<Vec<u8>> {
    let mut buf = Vec::new();
    let mut limited = file.take(max_bytes as u64);
    limited.read_to_end(&mut buf)?;
    Ok(buf)
}

fn enforce_json_budget(block: &Value, path: &str) -> io::Result<()> {
    let serialized = serde_json::to_vec(block).map_err(|err| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("failed to serialize attachment block: {err}"),
        )
    })?;
    if serialized.len() > MAX_BLOCK_JSON_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "attachment {path} serialized to {} bytes, exceeding JSON budget ({MAX_BLOCK_JSON_BYTES} bytes)",
                serialized.len()
            ),
        ));
    }
    Ok(())
}

fn format_attached_text(path: &str, text: &str) -> String {
    let safe_name = escape_xml_attr(path);
    if text.is_empty() {
        format!("<file name=\"{safe_name}\"></file>")
    } else {
        format!("<file name=\"{safe_name}\">\n{text}\n</file>")
    }
}

fn escape_xml_attr(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '"' => out.push_str("&quot;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '\n' | '\r' | '\t' => out.push(' '),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

fn has_supported_image_extension(path: &Path) -> bool {
    let Some(ext) = path.extension().and_then(|e| e.to_str()) else {
        return false;
    };
    matches!(
        ext.to_ascii_lowercase().as_str(),
        "png" | "jpg" | "jpeg" | "gif" | "webp"
    )
}

fn detect_supported_image_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.len() >= 3
        && bytes[0] == 0xff
        && bytes[1] == 0xd8
        && bytes[2] == 0xff
        && bytes.get(3) != Some(&0xf7)
    {
        return Some("image/jpeg");
    }
    if is_valid_static_png(bytes) {
        return Some("image/png");
    }
    if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return Some("image/webp");
    }
    None
}

fn is_valid_static_png(bytes: &[u8]) -> bool {
    if bytes.len() < 16 || !bytes.starts_with(&PNG_SIGNATURE) {
        return false;
    }
    let ihdr_len = u32::from_be_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]);
    if ihdr_len != 13 || &bytes[12..16] != b"IHDR" {
        return false;
    }

    let mut offset = PNG_SIGNATURE.len();
    while offset + 8 <= bytes.len() {
        let chunk_len = u32::from_be_bytes([
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3],
        ]) as usize;
        let chunk_type = &bytes[offset + 4..offset + 8];
        if chunk_type == b"acTL" {
            return false;
        }
        if chunk_type == b"IDAT" {
            return true;
        }
        let Some(next) = offset
            .checked_add(8)
            .and_then(|v| v.checked_add(chunk_len))
            .and_then(|v| v.checked_add(4))
        else {
            break;
        };
        if next <= offset || next > bytes.len() {
            break;
        }
        offset = next;
    }
    true
}

fn encode_base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);

    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
        let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;

        out.push(TABLE[((triple >> 18) & 0x3f) as usize] as char);
        out.push(TABLE[((triple >> 12) & 0x3f) as usize] as char);
        if chunk.len() > 1 {
            out.push(TABLE[((triple >> 6) & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(TABLE[(triple & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(label: &str) -> Self {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = PathBuf::from(format!(
                "/private/tmp/hi-files-test-{label}-{}-{nanos}",
                std::process::id()
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[cfg(unix)]
    fn create_fifo(path: &Path) {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;

        let c_path = CString::new(path.as_os_str().as_bytes()).unwrap();
        let rc = unsafe { libc_mkfifo(c_path.as_ptr(), 0o600) };
        assert_eq!(rc, 0, "mkfifo failed: {}", io::Error::last_os_error());
    }

    #[cfg(unix)]
    extern "C" {
        #[link_name = "mkfifo"]
        fn libc_mkfifo(pathname: *const std::ffi::c_char, mode: u16) -> i32;
    }

    fn minimal_png(extra_payload: &[u8]) -> Vec<u8> {
        let mut buf = Vec::new();
        buf.extend_from_slice(&PNG_SIGNATURE);
        buf.extend_from_slice(&13u32.to_be_bytes());
        buf.extend_from_slice(b"IHDR");
        buf.extend_from_slice(&[0u8; 17]); // 13 bytes IHDR data + 4 bytes CRC
        if !extra_payload.is_empty() {
            buf.extend_from_slice(&(extra_payload.len() as u32).to_be_bytes());
            buf.extend_from_slice(b"IDAT");
            buf.extend_from_slice(extra_payload);
            buf.extend_from_slice(&[0u8; 4]);
        }
        buf
    }

    #[test]
    fn list_sorts_dirs_first_and_filters_case_insensitively() {
        let tmp = TempDir::new("list-sort");
        fs::create_dir(tmp.path().join("src")).unwrap();
        fs::create_dir(tmp.path().join("Assets")).unwrap();
        fs::write(tmp.path().join("README.md"), "hi").unwrap();
        fs::write(tmp.path().join("alpha.txt"), "a").unwrap();
        fs::write(tmp.path().join("src/main.rs"), "fn main() {}").unwrap();
        fs::create_dir(tmp.path().join("src/hi")).unwrap();

        let all = list(tmp.path(), "").unwrap();
        assert_eq!(
            all,
            vec![
                ("Assets/".to_string(), "Assets/".to_string()),
                ("src/".to_string(), "src/".to_string()),
                ("alpha.txt".to_string(), "alpha.txt".to_string()),
                ("README.md".to_string(), "README.md".to_string()),
            ]
        );

        let re_matches = list(tmp.path(), "re").unwrap();
        assert_eq!(
            re_matches,
            vec![("README.md".to_string(), "README.md".to_string())]
        );

        let sub = list(tmp.path(), "src/").unwrap();
        assert_eq!(
            sub,
            vec![
                ("src/hi/".to_string(), "hi/".to_string()),
                ("src/main.rs".to_string(), "main.rs".to_string()),
            ]
        );

        let dot_sub = list(tmp.path(), "./src/m").unwrap();
        assert_eq!(
            dot_sub,
            vec![("./src/main.rs".to_string(), "main.rs".to_string())]
        );
    }

    #[test]
    fn list_handles_missing_subdir_and_skips_symlinks_and_fifos() {
        let tmp = TempDir::new("list-nonfiles");
        fs::write(tmp.path().join("keep.txt"), "ok").unwrap();
        fs::create_dir(tmp.path().join("sub")).unwrap();

        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(tmp.path().join("keep.txt"), tmp.path().join("sym.txt"))
                .unwrap();
            std::os::unix::fs::symlink(tmp.path().join("missing"), tmp.path().join("dangling"))
                .unwrap();
            create_fifo(&tmp.path().join("pipe"));
        }

        let entries = list(tmp.path(), "").unwrap();
        assert_eq!(
            entries,
            vec![
                ("sub/".to_string(), "sub/".to_string()),
                ("keep.txt".to_string(), "keep.txt".to_string()),
            ]
        );

        // Missing subdir returns empty choices cleanly instead of failing Tab completion.
        assert_eq!(list(tmp.path(), "no_such_dir/").unwrap(), vec![]);
        // Invalid base dir returns error.
        assert!(list(&tmp.path().join("does_not_exist"), "").is_err());
    }

    #[test]
    fn attach_reads_utf8_text_and_strips_bom() {
        let tmp = TempDir::new("attach-text");
        fs::write(tmp.path().join("note.txt"), "\u{FEFF}hello world\nline 2").unwrap();

        let block = attach(tmp.path(), "note.txt").unwrap();
        assert_eq!(block["type"], "text");
        assert_eq!(
            block["text"],
            "<file name=\"note.txt\">\nhello world\nline 2\n</file>"
        );

        fs::write(tmp.path().join("empty.txt"), "").unwrap();
        let empty = attach(tmp.path(), "empty.txt").unwrap();
        assert_eq!(empty["type"], "text");
        assert_eq!(empty["text"], "<file name=\"empty.txt\"></file>");
    }

    #[test]
    fn attach_supports_bounded_images_without_extra_deps() {
        let tmp = TempDir::new("attach-image");
        let png = minimal_png(b"pixel");
        fs::write(tmp.path().join("pic.png"), &png).unwrap();

        let block = attach(tmp.path(), "pic.png").unwrap();
        assert_eq!(block["type"], "image");
        assert_eq!(block["media_type"], "image/png");
        assert_eq!(block["data"], encode_base64(&png));

        let jpeg = vec![0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10];
        fs::write(tmp.path().join("pic.jpg"), &jpeg).unwrap();
        let jpg_block = attach(tmp.path(), "pic.jpg").unwrap();
        assert_eq!(jpg_block["type"], "image");
        assert_eq!(jpg_block["media_type"], "image/jpeg");

        let gif = b"GIF89a\x01\x00\x01\x00";
        fs::write(tmp.path().join("anim.gif"), gif).unwrap();
        let gif_block = attach(tmp.path(), "anim.gif").unwrap();
        assert_eq!(gif_block["type"], "image");
        assert_eq!(gif_block["media_type"], "image/gif");

        let webp = b"RIFF\x10\x00\x00\x00WEBP";
        fs::write(tmp.path().join("img.webp"), webp).unwrap();
        let webp_block = attach(tmp.path(), "img.webp").unwrap();
        assert_eq!(webp_block["type"], "image");
        assert_eq!(webp_block["media_type"], "image/webp");
    }

    #[test]
    fn attach_rejects_nonfiles_including_symlinks_dirs_and_fifos() {
        let tmp = TempDir::new("attach-nonfiles");
        fs::create_dir(tmp.path().join("subdir")).unwrap();
        fs::write(tmp.path().join("real.txt"), "secret").unwrap();

        let dir_err = attach(tmp.path(), "subdir").unwrap_err();
        assert_eq!(dir_err.kind(), io::ErrorKind::InvalidInput);

        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(tmp.path().join("real.txt"), tmp.path().join("link.txt"))
                .unwrap();
            let sym_err = attach(tmp.path(), "link.txt").unwrap_err();
            assert_eq!(sym_err.kind(), io::ErrorKind::InvalidInput);

            std::os::unix::fs::symlink(
                tmp.path().join("missing"),
                tmp.path().join("broken_link.txt"),
            )
            .unwrap();
            let broken_err = attach(tmp.path(), "broken_link.txt").unwrap_err();
            assert_eq!(broken_err.kind(), io::ErrorKind::InvalidInput);

            let fifo_path = tmp.path().join("blocking_pipe");
            create_fifo(&fifo_path);
            let fifo_err = attach(tmp.path(), "blocking_pipe").unwrap_err();
            assert_eq!(fifo_err.kind(), io::ErrorKind::InvalidInput);
        }
    }

    #[test]
    fn attach_rejects_binary_invalid_utf8_and_corrupt_image_extension() {
        let tmp = TempDir::new("attach-binary");
        fs::write(tmp.path().join("bin.dat"), b"abc\x00def").unwrap();
        assert_eq!(
            attach(tmp.path(), "bin.dat").unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );

        fs::write(tmp.path().join("bad.txt"), [0xff, 0xfe, 0xfd]).unwrap();
        assert_eq!(
            attach(tmp.path(), "bad.txt").unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );

        fs::write(tmp.path().join("fake.png"), b"not really a png").unwrap();
        assert_eq!(
            attach(tmp.path(), "fake.png").unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn attach_enforces_byte_and_json_budgets_defensively() {
        let tmp = TempDir::new("attach-budget");

        // Oversized text file (> MAX_TEXT_BYTES)
        let big_text = vec![b'a'; MAX_TEXT_BYTES + 1];
        fs::write(tmp.path().join("big.txt"), &big_text).unwrap();
        assert_eq!(
            attach(tmp.path(), "big.txt").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );

        // Text under raw byte limit whose JSON escaping exceeds MAX_BLOCK_JSON_BYTES (6x per \x01)
        let escaped_heavy = vec![0x01u8; 700_000];
        fs::write(tmp.path().join("ctrl.txt"), &escaped_heavy).unwrap();
        assert_eq!(
            attach(tmp.path(), "ctrl.txt").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );

        // Oversized PNG (> MAX_IMAGE_BYTES)
        let big_png = minimal_png(&vec![0u8; MAX_IMAGE_BYTES]);
        assert!(big_png.len() > MAX_IMAGE_BYTES);
        fs::write(tmp.path().join("big.png"), &big_png).unwrap();
        assert_eq!(
            attach(tmp.path(), "big.png").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );

        // Image just under MAX_IMAGE_BYTES stays within 4 MB API JSON limit
        let ok_png = minimal_png(&vec![0u8; 2_000_000]);
        fs::write(tmp.path().join("ok.png"), &ok_png).unwrap();
        let block = attach(tmp.path(), "ok.png").unwrap();
        let json_len = serde_json::to_vec(&block).unwrap().len();
        assert!(json_len <= MAX_BLOCK_JSON_BYTES);
        assert!(json_len < MAX_API_JSON_BYTES);
    }

    #[test]
    fn base64_matches_rfc4648_vectors() {
        assert_eq!(encode_base64(b""), "");
        assert_eq!(encode_base64(b"f"), "Zg==");
        assert_eq!(encode_base64(b"fo"), "Zm8=");
        assert_eq!(encode_base64(b"foo"), "Zm9v");
        assert_eq!(encode_base64(b"foob"), "Zm9vYg==");
        assert_eq!(encode_base64(b"fooba"), "Zm9vYmE=");
        assert_eq!(encode_base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn list_and_attach_roundtrip_and_reject_invalid_paths() {
        let tmp = TempDir::new("roundtrip");
        fs::create_dir(tmp.path().join("docs")).unwrap();
        fs::write(tmp.path().join("docs/guide.md"), "# Guide").unwrap();

        let items = list(tmp.path(), "docs/").unwrap();
        assert_eq!(
            items,
            vec![("docs/guide.md".to_string(), "guide.md".to_string())]
        );
        let block = attach(tmp.path(), &items[0].0).unwrap();
        assert_eq!(block["type"], "text");
        assert!(block["text"].as_str().unwrap().contains("# Guide"));

        assert_eq!(
            attach(tmp.path(), "").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
        assert_eq!(
            attach(tmp.path(), "a\0b").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
        assert_eq!(
            list(tmp.path(), "a\0b").unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
    }

    #[test]
    fn rejects_apng_and_jpegls_and_escapes_xml_attribute_names() {
        let tmp = TempDir::new("image-variants");

        let mut apng = Vec::new();
        apng.extend_from_slice(&PNG_SIGNATURE);
        apng.extend_from_slice(&13u32.to_be_bytes());
        apng.extend_from_slice(b"IHDR");
        apng.extend_from_slice(&[0u8; 17]);
        apng.extend_from_slice(&8u32.to_be_bytes());
        apng.extend_from_slice(b"acTL");
        apng.extend_from_slice(&[0u8; 12]);
        fs::write(tmp.path().join("anim.png"), &apng).unwrap();
        assert_eq!(
            attach(tmp.path(), "anim.png").unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );

        fs::write(tmp.path().join("jls.jpg"), [0xff, 0xd8, 0xff, 0xf7, 0x00]).unwrap();
        assert_eq!(
            attach(tmp.path(), "jls.jpg").unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );

        let weird_name = "a&b\"<c>.txt";
        fs::write(tmp.path().join(weird_name), "ok").unwrap();
        let block = attach(tmp.path(), weird_name).unwrap();
        assert_eq!(
            block["text"],
            "<file name=\"a&amp;b&quot;&lt;c&gt;.txt\">\nok\n</file>"
        );
    }

    #[test]
    fn list_caps_large_directories_and_plans_absolute_and_tilde_prefixes() {
        let tmp = TempDir::new("list-cap");
        for idx in 0..(MAX_LIST_RESULTS + 25) {
            fs::write(tmp.path().join(format!("file-{idx:03}.txt")), "x").unwrap();
        }
        let entries = list(tmp.path(), "").unwrap();
        assert_eq!(entries.len(), MAX_LIST_RESULTS);
        assert_eq!(entries[0].0, "file-000.txt");

        let abs_plan = plan_list(tmp.path(), "/tmp/sub/pa").unwrap();
        assert_eq!(abs_plan.search_dir, PathBuf::from("/tmp/sub/"));
        assert_eq!(abs_plan.file_prefix, "pa");
        assert_eq!(abs_plan.display_dir, "/tmp/sub/");
        assert!(abs_plan.scoped_subpath);

        if let Some(home) = local_home_dir() {
            let tilde_plan = plan_list(tmp.path(), "~/docs/re").unwrap();
            assert_eq!(tilde_plan.search_dir, home.join("docs"));
            assert_eq!(tilde_plan.file_prefix, "re");
            assert_eq!(tilde_plan.display_dir, "~/docs/");
            assert!(tilde_plan.scoped_subpath);
        }
    }
}
