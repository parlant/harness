mod pi;

use clap::{Parser, ValueEnum};
use serde_json::Value;
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::{fs::MetadataExt, net::UnixStream};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, UNIX_EPOCH};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const ARCHIVES: &str = "/api/v1/archives";

#[derive(Clone, ValueEnum)]
enum Harness {
    Pi,
}

#[derive(Parser)]
#[command(
    name = "hi import",
    version,
    about = "Import transcripts into H as read-only archives"
)]
struct Args {
    #[arg(long, value_enum)]
    harness: Harness,
    /// Root to scan recursively (default for pi: ~/.pi/agent/sessions)
    #[arg(long)]
    directory: Option<PathBuf>,
    /// Local H store (default: $H_DATA_DIR or ~/.local/share/h)
    #[arg(long)]
    data_dir: Option<PathBuf>,
}

fn main() -> ExitCode {
    match run(Args::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("hi-import: {}", printable(&err.to_string()));
            ExitCode::FAILURE
        }
    }
}

fn home() -> Result<PathBuf> {
    Ok(PathBuf::from(
        std::env::var_os("HOME").ok_or("HOME is unset")?,
    ))
}

fn run(args: Args) -> Result<()> {
    let dir = match args.directory {
        Some(dir) => dir,
        None => home()?.join(".pi/agent/sessions"),
    };
    let data_dir = match args.data_dir.or_else(|| {
        std::env::var_os("H_DATA_DIR")
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
    }) {
        Some(dir) => match dir.strip_prefix("~") {
            Ok(rest) => home()?.join(rest),
            Err(_) => dir,
        },
        None => home()?.join(".local/share/h"),
    };
    let client = Client::new(data_dir)?;
    let catalog = client.connect("GET", "").and_then(response)?;
    let archives = catalog["archives"]
        .as_array()
        .ok_or("invalid archive index response")?;
    let mut known: HashMap<String, Revision> = archives
        .iter()
        .filter_map(|row| {
            if row["source"] != "pi" {
                return None;
            }
            Some((
                row["source_id"].as_str()?.to_owned(),
                (row["revision"].as_u64()?, row["size"].as_u64()?),
            ))
        })
        .collect();

    let mut paths = Vec::new();
    collect(&dir, &mut paths)?;
    paths.sort_unstable();
    let mut counts = [0_u64; 5];
    for path in paths {
        match import(&client, &path, &mut known) {
            Ok(index) => counts[index] += 1,
            Err(err) => {
                counts[4] += 1;
                eprintln!(
                    "{}: {}",
                    printable(&path.to_string_lossy()),
                    printable(&err.to_string())
                );
            }
        }
    }
    let [created, updated, unchanged, stale, failed] = counts;
    println!(
        "Created {created}, updated {updated}, unchanged {unchanged}, stale {stale}, failed {failed}"
    );
    if failed > 0 {
        return Err("some sessions could not be imported; rerun after fixing them".into());
    }
    Ok(())
}

fn collect(dir: &Path, paths: &mut Vec<PathBuf>) -> io::Result<()> {
    for item in fs::read_dir(dir)? {
        let item = item?;
        let kind = item.file_type()?;
        if kind.is_dir() {
            collect(&item.path(), paths)?;
        } else if kind.is_file() && item.path().extension().is_some_and(|ext| ext == "jsonl") {
            paths.push(item.path());
        }
    }
    Ok(())
}

type Revision = (u64, u64);

fn revision(meta: &fs::Metadata) -> Result<Revision> {
    let nsec = meta.modified()?.duration_since(UNIX_EPOCH)?.as_nanos();
    Ok((u64::try_from(nsec)?, meta.len()))
}

fn import(client: &Client, path: &Path, known: &mut HashMap<String, Revision>) -> Result<usize> {
    let file = File::open(path)?;
    let meta = file.metadata()?;
    let current = revision(&meta)?;
    let mut source = pi::Session::open(BufReader::new(file))?;
    let id = source.id().to_owned();
    if let Some(&old) = known.get(&id) {
        if current <= old {
            return Ok(if current == old { 2 } else { 3 });
        }
    }
    let mut socket = client.connect(
        "POST",
        "Content-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n",
    )?;
    send_row(
        &mut socket,
        &serde_json::to_string(&source.header(current))?,
    )?;
    let mut count = 0;
    while let Some(rows) = source.next_rows()? {
        for row in rows {
            send_row(&mut socket, &row)?;
            count += 1;
        }
    }
    let after = path.metadata()?;
    if revision(&after)? != current || (after.dev(), after.ino()) != (meta.dev(), meta.ino()) {
        return Err("session changed during import; retry when it is idle".into());
    }
    send_row(&mut socket, &format!("{{\"end\":{count}}}"))?;
    socket.write_all(b"0\r\n\r\n")?;
    let receipt = response(socket)?;
    let index = match receipt["status"].as_str() {
        Some("created") => 0,
        Some("updated") => 1,
        Some("unchanged") => 2,
        Some("stale") => return Ok(3),
        _ => return Err("invalid archive receipt".into()),
    };
    known.insert(id, current);
    Ok(index)
}

fn send_row(socket: &mut UnixStream, row: &str) -> Result<()> {
    let data = row.as_bytes();
    if data.len() > pi::MAX_LINE {
        return Err("archive record exceeds 15 MiB".into());
    }
    write!(socket, "{:x}\r\n", data.len() + 1)?;
    socket.write_all(data)?;
    socket.write_all(b"\n\r\n")?;
    Ok(())
}

struct Client {
    path: PathBuf,
    token: String,
}

impl Client {
    fn new(dir: PathBuf) -> Result<Self> {
        let token = fs::read_to_string(dir.join("auth.token"))?
            .trim()
            .to_owned();
        if token.is_empty() || !token.bytes().all(|b| b.is_ascii_graphic()) {
            return Err("invalid owner token".into());
        }
        Ok(Self {
            path: dir.join("api.sock"),
            token,
        })
    }

    fn connect(&self, method: &str, extra: &str) -> Result<UnixStream> {
        let mut socket = UnixStream::connect(&self.path).map_err(|err| {
            io::Error::new(
                err.kind(),
                format!("could not connect to {}: {err}", self.path.display()),
            )
        })?;
        socket.set_read_timeout(Some(Duration::from_secs(120)))?;
        socket.set_write_timeout(Some(Duration::from_secs(120)))?;
        write!(
            socket,
            "{method} {ARCHIVES} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nAuthorization: Bearer {}\r\n{extra}\r\n",
            self.token
        )?;
        Ok(socket)
    }
}

fn response(socket: UnixStream) -> Result<Value> {
    let mut reader = BufReader::new(socket).take(32 * 1024 * 1024);
    let mut headers = String::new();
    reader.read_line(&mut headers)?;
    let status = headers
        .split_ascii_whitespace()
        .nth(1)
        .ok_or("missing HTTP status")?
        .parse::<u16>()?;
    loop {
        headers.clear();
        if reader.read_line(&mut headers)? == 0 {
            return Err("incomplete HTTP headers".into());
        }
        if headers == "\r\n" {
            break;
        }
    }
    let mut body = Vec::new();
    reader.read_to_end(&mut body)?;
    if status != 200 {
        let detail = serde_json::from_slice::<Value>(&body).ok();
        return Err(format!(
            "HTTP {status}: {}",
            detail
                .as_ref()
                .and_then(|v| v["error"].as_str())
                .unwrap_or("archive request failed")
        )
        .into());
    }
    Ok(serde_json::from_slice(&body)?)
}

fn printable(text: &str) -> String {
    text.chars()
        .flat_map(|c| {
            if c.is_control() {
                c.escape_default().collect::<Vec<_>>()
            } else {
                vec![c]
            }
        })
        .collect()
}
