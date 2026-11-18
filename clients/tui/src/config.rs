use serde::Deserialize;
use std::fmt;
use std::fs;
use std::os::unix::fs::FileTypeExt;
use std::path::{Path, PathBuf};

#[derive(Clone, PartialEq, Eq)]
pub struct SecretToken(String);

impl SecretToken {
    pub fn new(token: impl Into<String>) -> Result<Self, ConfigError> {
        let trimmed = token.into().trim().to_string();
        if trimmed.is_empty() {
            return Err(ConfigError::InvalidToken("auth.token is empty".to_string()));
        }
        if trimmed.contains(['\r', '\n', '\0']) {
            return Err(ConfigError::InvalidToken(
                "auth.token contains invalid control characters".to_string(),
            ));
        }
        Ok(Self(trimmed))
    }

    pub(crate) fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for SecretToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("[REDACTED]")
    }
}

impl fmt::Display for SecretToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("[REDACTED]")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoopbackHost {
    Ipv4,
    Ipv6,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DaemonTarget {
    UnixSocket(PathBuf),
    LoopbackHttp { host: LoopbackHost, port: u16 },
}

impl DaemonTarget {
    pub fn host_header(&self) -> String {
        match self {
            DaemonTarget::UnixSocket(_) => "localhost".to_string(),
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            } => format!("127.0.0.1:{port}"),
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv6,
                port,
            } => format!("[::1]:{port}"),
        }
    }

    pub fn display_endpoint(&self) -> String {
        match self {
            DaemonTarget::UnixSocket(path) => format!("unix://{}", path.display()),
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            } => format!("http://127.0.0.1:{port}"),
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv6,
                port,
            } => format!("http://[::1]:{port}"),
        }
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct DaemonManifest {
    pub version: Option<u32>,
    pub pid: Option<u64>,
    pub http_url: Option<String>,
    pub api_socket: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ResolvedConfig {
    pub data_dir: PathBuf,
    pub target: DaemonTarget,
    pub token: SecretToken,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ConfigError {
    MissingHome,
    InvalidDataDir(String),
    InvalidDaemonUrl(String),
    InvalidManifest(String),
    MissingToken(PathBuf),
    InvalidToken(String),
    DaemonNotFound { checked: Vec<String> },
    Io(String),
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::MissingHome => {
                write!(f, "cannot determine data dir: H_DATA_DIR and HOME are unset")
            }
            ConfigError::InvalidDataDir(msg) => write!(f, "invalid data dir: {msg}"),
            ConfigError::InvalidDaemonUrl(msg) => write!(f, "invalid daemon URL: {msg}"),
            ConfigError::InvalidManifest(msg) => write!(f, "invalid daemon.json: {msg}"),
            ConfigError::MissingToken(path) => write!(
                f,
                "owner auth token not found at {}; start the H daemon first",
                path.display()
            ),
            ConfigError::InvalidToken(msg) => write!(f, "invalid auth.token: {msg}"),
            ConfigError::DaemonNotFound { checked } => write!(
                f,
                "H daemon not found (no auto-start). Checked: {}. Start the H daemon or set H_DAEMON_URL.",
                checked.join(", ")
            ),
            ConfigError::Io(msg) => write!(f, "config I/O error: {msg}"),
        }
    }
}

impl std::error::Error for ConfigError {}

pub fn resolve_config(
    cli_data_dir: Option<&Path>,
    cli_daemon_url: Option<&str>,
) -> Result<ResolvedConfig, ConfigError> {
    let env_data_dir = std::env::var("H_DATA_DIR").ok();
    let env_daemon_url = std::env::var("H_DAEMON_URL").ok();
    let home_dir = std::env::var("HOME").ok();

    resolve_config_with(
        cli_data_dir,
        env_data_dir.as_deref(),
        home_dir.as_deref(),
        cli_daemon_url,
        env_daemon_url.as_deref(),
    )
}

pub fn resolve_config_with(
    cli_data_dir: Option<&Path>,
    env_data_dir: Option<&str>,
    home_dir: Option<&str>,
    cli_daemon_url: Option<&str>,
    env_daemon_url: Option<&str>,
) -> Result<ResolvedConfig, ConfigError> {
    let data_dir = resolve_data_dir(cli_data_dir, env_data_dir, home_dir)?;
    let target = discover_target(&data_dir, cli_daemon_url, env_daemon_url)?;
    let token = load_auth_token(&data_dir)?;
    Ok(ResolvedConfig {
        data_dir,
        target,
        token,
    })
}

pub fn resolve_data_dir(
    cli_data_dir: Option<&Path>,
    env_data_dir: Option<&str>,
    home_dir: Option<&str>,
) -> Result<PathBuf, ConfigError> {
    if let Some(p) = cli_data_dir {
        let s = p.to_string_lossy();
        if s.trim().is_empty() {
            return Err(ConfigError::InvalidDataDir(
                "--data-dir cannot be empty".to_string(),
            ));
        }
        return expand_tilde(p, home_dir);
    }

    if let Some(raw) = env_data_dir {
        let trimmed = raw.trim();
        if !trimmed.is_empty() {
            return expand_tilde(Path::new(trimmed), home_dir);
        }
    }

    let home = home_dir
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or(ConfigError::MissingHome)?;

    Ok(PathBuf::from(home).join(".local").join("share").join("h"))
}

fn expand_tilde(path: &Path, home_dir: Option<&str>) -> Result<PathBuf, ConfigError> {
    let s = path.to_string_lossy();
    if s == "~" {
        let home = home_dir
            .map(str::trim)
            .filter(|h| !h.is_empty())
            .ok_or(ConfigError::MissingHome)?;
        return Ok(PathBuf::from(home));
    }
    if let Some(rest) = s.strip_prefix("~/") {
        let home = home_dir
            .map(str::trim)
            .filter(|h| !h.is_empty())
            .ok_or(ConfigError::MissingHome)?;
        return Ok(PathBuf::from(home).join(rest));
    }
    Ok(path.to_path_buf())
}

pub fn parse_daemon_url(raw: &str) -> Result<DaemonTarget, ConfigError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ConfigError::InvalidDaemonUrl("URL is empty".to_string()));
    }

    let rest = trimmed.strip_prefix("http://").ok_or_else(|| {
        ConfigError::InvalidDaemonUrl(
            "only literal http:// loopback URLs (127.0.0.1 or [::1]) are permitted".to_string(),
        )
    })?;

    if rest.contains('@') {
        return Err(ConfigError::InvalidDaemonUrl(
            "userinfo is not permitted in daemon URL".to_string(),
        ));
    }
    if rest.contains(['?', '#']) {
        return Err(ConfigError::InvalidDaemonUrl(
            "query or fragment is not permitted in daemon URL".to_string(),
        ));
    }

    let authority = match rest.find('/') {
        Some(idx) => {
            let path = &rest[idx..];
            if path != "/" {
                return Err(ConfigError::InvalidDaemonUrl(
                    "daemon URL must not contain a non-root path".to_string(),
                ));
            }
            &rest[..idx]
        }
        None => rest,
    };

    if let Some(after_bracket) = authority.strip_prefix("[::1]") {
        let port = parse_optional_port(after_bracket, 80)?;
        return Ok(DaemonTarget::LoopbackHttp {
            host: LoopbackHost::Ipv6,
            port,
        });
    }

    if let Some(after_v4) = authority.strip_prefix("127.0.0.1") {
        if after_v4.is_empty() || after_v4.starts_with(':') {
            let port = parse_optional_port(after_v4, 80)?;
            return Ok(DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port,
            });
        }
    }

    Err(ConfigError::InvalidDaemonUrl(
        "daemon URL host must be literal loopback 127.0.0.1 or [::1]".to_string(),
    ))
}

fn parse_optional_port(suffix: &str, default_port: u16) -> Result<u16, ConfigError> {
    if suffix.is_empty() {
        return Ok(default_port);
    }
    let port_str = suffix.strip_prefix(':').ok_or_else(|| {
        ConfigError::InvalidDaemonUrl("unexpected authority suffix in daemon URL".to_string())
    })?;
    if port_str.is_empty() || !port_str.bytes().all(|b| b.is_ascii_digit()) {
        return Err(ConfigError::InvalidDaemonUrl(
            "invalid port in daemon URL".to_string(),
        ));
    }
    let port: u16 = port_str
        .parse()
        .map_err(|_| ConfigError::InvalidDaemonUrl("port out of range".to_string()))?;
    if port == 0 {
        return Err(ConfigError::InvalidDaemonUrl(
            "port 0 is not valid".to_string(),
        ));
    }
    Ok(port)
}

pub fn load_auth_token(data_dir: &Path) -> Result<SecretToken, ConfigError> {
    let token_path = data_dir.join("auth.token");
    match fs::read_to_string(&token_path) {
        Ok(content) => SecretToken::new(content),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            Err(ConfigError::MissingToken(token_path))
        }
        Err(err) => Err(ConfigError::Io(format!(
            "failed to read {}: {err}",
            token_path.display()
        ))),
    }
}

pub fn load_daemon_manifest(data_dir: &Path) -> Result<Option<DaemonManifest>, ConfigError> {
    let manifest_path = data_dir.join("daemon.json");
    match fs::read_to_string(&manifest_path) {
        Ok(content) => {
            let manifest: DaemonManifest = serde_json::from_str(&content)
                .map_err(|err| ConfigError::InvalidManifest(err.to_string()))?;
            Ok(Some(manifest))
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(ConfigError::Io(format!(
            "failed to read {}: {err}",
            manifest_path.display()
        ))),
    }
}

fn is_existing_unix_socket(path: &Path) -> bool {
    match fs::symlink_metadata(path) {
        Ok(meta) => meta.file_type().is_socket(),
        Err(_) => false,
    }
}

pub fn discover_target(
    data_dir: &Path,
    cli_daemon_url: Option<&str>,
    env_daemon_url: Option<&str>,
) -> Result<DaemonTarget, ConfigError> {
    if let Some(url) = cli_daemon_url.map(str::trim).filter(|s| !s.is_empty()) {
        return parse_daemon_url(url);
    }

    if let Some(url) = env_daemon_url.map(str::trim).filter(|s| !s.is_empty()) {
        return parse_daemon_url(url);
    }

    let mut checked = Vec::new();
    let default_sock = data_dir.join("api.sock");
    checked.push(default_sock.display().to_string());
    if is_existing_unix_socket(&default_sock) {
        return Ok(DaemonTarget::UnixSocket(default_sock));
    }

    let manifest_path = data_dir.join("daemon.json");
    checked.push(manifest_path.display().to_string());
    if let Some(manifest) = load_daemon_manifest(data_dir)? {
        if let Some(sock_str) = manifest
            .api_socket
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let sock_path = PathBuf::from(sock_str);
            if sock_path.is_absolute() && is_existing_unix_socket(&sock_path) {
                return Ok(DaemonTarget::UnixSocket(sock_path));
            }
        }
        if let Some(http_url) = manifest
            .http_url
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            return parse_daemon_url(http_url);
        }
    }

    Err(ConfigError::DaemonNotFound { checked })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = PathBuf::from(format!(
            "/private/tmp/h-cfg-test-{label}-{}-{nanos}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn secret_token_never_prints_in_debug_or_display() {
        let tok = SecretToken::new("super-secret-value\n").unwrap();
        assert_eq!(tok.expose(), "super-secret-value");
        assert_eq!(format!("{tok}"), "[REDACTED]");
        assert_eq!(format!("{tok:?}"), "[REDACTED]");
    }

    #[test]
    fn resolve_data_dir_precedence() {
        let p1 = resolve_data_dir(
            Some(Path::new("/tmp/cli-dir")),
            Some("/tmp/env-dir"),
            Some("/Users/alice"),
        )
        .unwrap();
        assert_eq!(p1, PathBuf::from("/tmp/cli-dir"));

        let p2 = resolve_data_dir(None, Some("/tmp/env-dir"), Some("/Users/alice")).unwrap();
        assert_eq!(p2, PathBuf::from("/tmp/env-dir"));

        let p3 = resolve_data_dir(None, Some("   "), Some("/Users/alice")).unwrap();
        assert_eq!(p3, PathBuf::from("/Users/alice/.local/share/h"));

        let p4 = resolve_data_dir(None, Some("~/custom-h"), Some("/Users/alice")).unwrap();
        assert_eq!(p4, PathBuf::from("/Users/alice/custom-h"));

        let err = resolve_data_dir(None, None, None).unwrap_err();
        assert_eq!(err, ConfigError::MissingHome);
    }

    #[test]
    fn parse_daemon_url_allows_only_literal_loopback() {
        assert_eq!(
            parse_daemon_url("http://127.0.0.1:4100").unwrap(),
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port: 4100
            }
        );
        assert_eq!(
            parse_daemon_url("http://127.0.0.1:4100/").unwrap(),
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port: 4100
            }
        );
        assert_eq!(
            parse_daemon_url("http://[::1]:4200").unwrap(),
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv6,
                port: 4200
            }
        );

        assert!(parse_daemon_url("http://localhost:4100").is_err());
        assert!(parse_daemon_url("http://evil.example:4100").is_err());
        assert!(parse_daemon_url("https://127.0.0.1:4100").is_err());
        assert!(parse_daemon_url("http://user@127.0.0.1:4100").is_err());
        assert!(parse_daemon_url("http://127.0.0.1:4100/api").is_err());
        assert!(parse_daemon_url("http://127.0.0.1:0").is_err());
        assert!(parse_daemon_url("http://192.168.1.10:4100").is_err());
    }

    #[test]
    fn discover_target_prefers_cli_then_env_then_socket_then_manifest() {
        let dir = temp_dir("discover");
        let sock = dir.join("api.sock");
        let _listener = UnixListener::bind(&sock).unwrap();

        fs::write(
            dir.join("daemon.json"),
            r#"{"version":1,"pid":123,"http_url":"http://127.0.0.1:4100","api_socket":null}"#,
        )
        .unwrap();

        let cli = discover_target(
            &dir,
            Some("http://[::1]:4500"),
            Some("http://127.0.0.1:4100"),
        )
        .unwrap();
        assert_eq!(
            cli,
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv6,
                port: 4500
            }
        );

        let env = discover_target(&dir, None, Some("http://127.0.0.1:4999")).unwrap();
        assert_eq!(
            env,
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port: 4999
            }
        );

        let via_sock = discover_target(&dir, None, None).unwrap();
        assert_eq!(via_sock, DaemonTarget::UnixSocket(sock.clone()));

        drop(_listener);
        fs::remove_file(&sock).unwrap();

        let via_manifest_http = discover_target(&dir, None, None).unwrap();
        assert_eq!(
            via_manifest_http,
            DaemonTarget::LoopbackHttp {
                host: LoopbackHost::Ipv4,
                port: 4100
            }
        );

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn manifest_and_token_loading() {
        let dir = temp_dir("tok");
        fs::write(dir.join("auth.token"), "  tok_abc_123 \n").unwrap();
        let token = load_auth_token(&dir).unwrap();
        assert_eq!(token.expose(), "tok_abc_123");

        fs::write(
            dir.join("daemon.json"),
            r#"{"version":1,"pid":99,"http_url":"http://127.0.0.1:4100","api_socket":"/tmp/h.sock"}"#,
        )
        .unwrap();
        let manifest = load_daemon_manifest(&dir).unwrap().unwrap();
        assert_eq!(manifest.version, Some(1));
        assert_eq!(manifest.pid, Some(99));
        assert_eq!(manifest.http_url.as_deref(), Some("http://127.0.0.1:4100"));
        assert_eq!(manifest.api_socket.as_deref(), Some("/tmp/h.sock"));

        fs::remove_dir_all(&dir).unwrap();
    }
}
