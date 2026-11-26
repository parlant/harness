use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
};

pub const MAX_PROMPT_FILE_BYTES: usize = 65_536;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptTemplate {
    pub name: String,
    pub path: PathBuf,
    pub description: String,
    pub body: String,
}

pub fn is_valid_prompt_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    (1..=64).contains(&bytes.len())
        && bytes[0].is_ascii_alphanumeric()
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
}

pub fn discover_prompts(data_dir: &Path) -> Vec<PromptTemplate> {
    let dir = data_dir.join("prompts");
    let Ok(entries) = fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut templates = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if !is_valid_prompt_name(stem) {
            continue;
        }
        let Ok(meta) = fs::symlink_metadata(&path) else {
            continue;
        };
        if !meta.is_file() || meta.len() > MAX_PROMPT_FILE_BYTES as u64 {
            continue;
        }
        let Ok(file) = fs::File::open(&path) else {
            continue;
        };
        let mut raw = String::new();
        if file
            .take(MAX_PROMPT_FILE_BYTES as u64 + 1)
            .read_to_string(&mut raw)
            .is_err()
        {
            continue;
        }
        if raw.len() > MAX_PROMPT_FILE_BYTES {
            continue;
        }
        let body = raw.strip_prefix('\u{feff}').unwrap_or(&raw).to_string();
        let description = first_line_preview(&body);
        templates.push(PromptTemplate {
            name: stem.to_string(),
            path,
            description,
            body,
        });
    }
    templates.sort_by(|a, b| a.name.cmp(&b.name));
    templates
}

pub fn expand_prompt(body: &str, args: &str) -> String {
    let trimmed_args = args.trim();
    if body.contains("{{args}}") || body.contains("$ARGUMENTS") {
        body.replace("{{args}}", trimmed_args)
            .replace("$ARGUMENTS", trimmed_args)
    } else if trimmed_args.is_empty() {
        body.to_string()
    } else {
        format!("{}\n\n{trimmed_args}", body.trim_end_matches('\n'))
    }
}

fn first_line_preview(body: &str) -> String {
    body.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(|line| {
            let trimmed = line.trim_start_matches('#').trim();
            if trimmed.is_empty() {
                line
            } else {
                trimmed
            }
        })
        .map(|line| line.chars().take(72).collect())
        .unwrap_or_else(|| "Prompt template".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "hi_prompts_test_{}_{}_{}",
            std::process::id(),
            nanos,
            label
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn discovers_valid_markdown_prompts_and_rejects_symlinks_oversize_and_invalid_names() {
        let data_dir = temp_dir("discover");
        let prompts_dir = data_dir.join("prompts");
        fs::create_dir_all(&prompts_dir).unwrap();

        fs::write(
            prompts_dir.join("review.md"),
            "# Code Review\nCheck {{args}}",
        )
        .unwrap();
        fs::write(prompts_dir.join("Plan_v2-beta.md"), "Draft plan").unwrap();
        fs::write(prompts_dir.join("-bad.md"), "nope").unwrap();
        fs::write(prompts_dir.join("bad name.md"), "nope").unwrap();
        fs::write(prompts_dir.join("notes.txt"), "nope").unwrap();
        fs::write(
            prompts_dir.join("too_big.md"),
            "x".repeat(MAX_PROMPT_FILE_BYTES + 1),
        )
        .unwrap();

        #[cfg(unix)]
        {
            let outside = data_dir.join("secret.md");
            fs::write(&outside, "secret").unwrap();
            std::os::unix::fs::symlink(&outside, prompts_dir.join("linked.md")).unwrap();
        }

        let found = discover_prompts(&data_dir);
        let names: Vec<_> = found.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names, vec!["Plan_v2-beta", "review"]);
        assert_eq!(found[0].description, "Draft plan");
        assert_eq!(found[1].description, "Code Review");

        let _ = fs::remove_dir_all(&data_dir);
    }

    #[test]
    fn expands_args_placeholders_or_appends_after_blank_line() {
        assert_eq!(
            expand_prompt("Review {{args}} carefully", "  src/main.rs  "),
            "Review src/main.rs carefully"
        );
        assert_eq!(
            expand_prompt("Explain $ARGUMENTS in detail", "closures"),
            "Explain closures in detail"
        );
        assert_eq!(
            expand_prompt("Summarize\n", "file.rs"),
            "Summarize\n\nfile.rs"
        );
        assert_eq!(expand_prompt("Summarize\n", "   "), "Summarize\n");
    }
}
