//! pi's sessions: `~/.pi/agent/sessions/--<cwd with / as ->--/<timestamp>_<id>.jsonl`, whose
//! first line is `{"type":"session","version":3,"id":…,"cwd":…}` (pi 0.84 to 0.99.2, format
//! v3). A session's name is its latest `{"type":"session_info","name":…}` entry, and an empty
//! name clears it (`/name`, `SessionManager.appendSessionInfo` in 0.99.2).

use bench_wire::Unreadable;
use serde_json::Value;
use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

pub const SOURCE: &str = "pi-session";
pub const VERSION: u64 = 3;

/// pi's directory name for a cwd. Unlike Claude's it keeps `.` and `_`.
pub fn dir_name(cwd: &str) -> String {
    format!("--{}--", cwd.trim_start_matches('/').replace('/', "-"))
}

/// The session file for `id` started in `cwd`, confirmed by its own header. `Ok(None)` when
/// there is no such file — the session left nothing to resume.
pub fn session(home: &Path, cwd: &str, id: &str) -> Result<Option<PathBuf>, Unreadable> {
    let dir = home.join(".pi/agent/sessions").join(dir_name(cwd));
    let suffix = format!("_{id}.jsonl");
    let Some(path) = fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .find(|p| {
            p.file_name()
                .is_some_and(|n| n.to_string_lossy().ends_with(&suffix))
        })
    else {
        return Ok(None);
    };
    let bad = |why: String| Unreadable {
        source: SOURCE.into(),
        path: path.display().to_string(),
        why,
    };
    let mut first = String::new();
    BufReader::new(fs::File::open(&path).map_err(|e| bad(e.to_string()))?)
        .read_line(&mut first)
        .map_err(|e| bad(e.to_string()))?;
    header(&first, id).map_err(bad)?;
    Ok(Some(path))
}

/// Checks a session file's first line: the one format version this build reads, naming
/// `id`. The session list and `bench log` both read pi files through it.
pub fn header(first_line: &str, id: &str) -> Result<(), String> {
    let header: Value =
        serde_json::from_str(first_line).map_err(|e| format!("first line is not JSON: {e}"))?;
    let (kind, version) = (header["type"].as_str(), header["version"].as_u64());
    if kind != Some("session") || version != Some(VERSION) {
        return Err(format!(
            "header type {kind:?} version {version:?} — this build reads type \"session\" version {VERSION}"
        ));
    }
    if header["id"].as_str() != Some(id) {
        return Err(format!("header id {} is not {id:?}", header["id"]));
    }
    Ok(())
}

/// What the name scan of one session file has read so far. Session files are append-only, so
/// the scan resumes from `offset`; a file shorter than that was replaced and is read again.
#[derive(Debug, Default, Clone)]
pub struct NameScan {
    offset: u64,
    name: Option<String>,
}

const SESSION_INFO: &[u8] = b"\"session_info\"";

/// The session's name as pi shows it, reading only what was appended since the last call. A
/// name is a label on a row, so a file that cannot be read has none.
pub fn name(path: &Path, scan: &mut NameScan) -> Option<String> {
    let len = fs::metadata(path).ok()?.len();
    if len < scan.offset {
        *scan = NameScan::default();
    }
    if len > scan.offset {
        let mut buf = Vec::new();
        let mut file = fs::File::open(path).ok()?;
        file.seek(SeekFrom::Start(scan.offset)).ok()?;
        file.take(len - scan.offset).read_to_end(&mut buf).ok()?;
        // Only whole lines: pi may be halfway through writing the last one.
        let end = memchr::memrchr(b'\n', &buf).map_or(0, |i| i + 1);
        for line in buf[..end].split(|b| *b == b'\n') {
            if memchr::memmem::find(line, SESSION_INFO).is_none() {
                continue;
            }
            let Ok(entry) = serde_json::from_slice::<Value>(line) else {
                continue;
            };
            if entry["type"] == "session_info" {
                scan.name = entry["name"]
                    .as_str()
                    .map(str::trim)
                    .filter(|n| !n.is_empty())
                    .map(str::to_string);
            }
        }
        scan.offset += end as u64;
    }
    scan.name.clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_directory_name_keeps_dots_and_brackets_the_path() {
        assert_eq!(dir_name("/private/tmp"), "--private-tmp--");
        assert_eq!(dir_name("/r/helm/.worktrees/a"), "--r-helm-.worktrees-a--");
    }

    #[test]
    fn the_latest_name_wins_an_empty_one_clears_it_and_a_half_written_line_waits() {
        let dir = std::env::temp_dir().join(format!("pi-name-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("s.jsonl");
        let info = |name: &str| {
            format!(
                "{{\"type\":\"session_info\",\"id\":\"a\",\"parentId\":null,\"timestamp\":\"t\",\"name\":{name:?}}}\n"
            )
        };
        let message = "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"call it session_info\"}}\n";
        fs::write(
            &path,
            format!("{{\"type\":\"session\",\"version\":3}}\n{message}"),
        )
        .unwrap();
        let mut scan = NameScan::default();
        assert_eq!(
            name(&path, &mut scan),
            None,
            "a message that mentions it is not one"
        );
        let append = |text: &str| {
            use std::io::Write;
            fs::OpenOptions::new()
                .append(true)
                .open(&path)
                .unwrap()
                .write_all(text.as_bytes())
                .unwrap();
        };
        append(&info("  Fix the build "));
        assert_eq!(name(&path, &mut scan).as_deref(), Some("Fix the build"));
        let renamed = info("Ship it");
        append(&renamed[..renamed.len() - 5]);
        assert_eq!(
            name(&path, &mut scan).as_deref(),
            Some("Fix the build"),
            "not yet whole"
        );
        append(&renamed[renamed.len() - 5..]);
        assert_eq!(name(&path, &mut scan).as_deref(), Some("Ship it"));
        append(&info(""));
        assert_eq!(name(&path, &mut scan), None, "cleared");
        fs::write(&path, info("Replaced")).unwrap();
        assert_eq!(
            name(&path, &mut scan).as_deref(),
            Some("Replaced"),
            "a shorter file is read again"
        );
        fs::remove_dir_all(&dir).unwrap();
    }
}
