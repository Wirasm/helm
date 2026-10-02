//! pi's sessions: `~/.pi/agent/sessions/--<cwd with / as ->--/<timestamp>_<id>.jsonl`, whose
//! first line is `{"type":"session","version":3,"id":…,"cwd":…}` (pi 0.84 to 0.99.2, format
//! v3). A session's name is its latest `{"type":"session_info","name":…}` entry, and an empty
//! name clears it (`/name`, `SessionManager.appendSessionInfo` in 0.99.2); its model is its
//! latest `{"type":"model_change","modelId":…}`.

use crate::latest::Field;
use bench_wire::Unreadable;
use serde_json::Value;
use std::fs;
use std::io::{BufRead, BufReader};
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

/// The session's name as pi shows it: the latest `session_info`, an empty one clearing it.
pub const NAME: Field = Field {
    needle: b"\"session_info\"",
    pick: |entry| {
        (entry["type"] == "session_info").then(|| {
            entry["name"]
                .as_str()
                .unwrap_or_default()
                .trim()
                .to_string()
        })
    },
};

/// The model the session runs: the latest `model_change`, which pi writes when a session starts
/// and on every switch (`SessionManager.appendModelChange`).
pub const MODEL: Field = Field {
    needle: b"\"model_change\"",
    pick: |entry| {
        (entry["type"] == "model_change")
            .then(|| entry["modelId"].as_str().map(str::to_string))
            .flatten()
    },
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_directory_name_keeps_dots_and_brackets_the_path() {
        assert_eq!(dir_name("/private/tmp"), "--private-tmp--");
        assert_eq!(dir_name("/r/helm/.worktrees/a"), "--r-helm-.worktrees-a--");
    }

    #[test]
    fn the_name_is_the_latest_session_info_and_the_model_the_latest_model_change() {
        let dir = std::env::temp_dir().join(format!("pi-fields-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("s.jsonl");
        let lines = [
            r#"{"type":"session","version":3}"#,
            r#"{"type":"model_change","provider":"anthropic","modelId":"claude-opus-5-5"}"#,
            r#"{"type":"message","message":{"role":"user","content":"call it session_info, model_change"}}"#,
            r#"{"type":"session_info","name":"  Fix the build "}"#,
            r#"{"type":"model_change","provider":"openrouter","modelId":"google/gemini-2.5-flash"}"#,
        ];
        fs::write(&path, lines.join("\n") + "\n").unwrap();
        let read = |field: &Field| crate::latest::read(&path, field, &mut Default::default()).0;
        assert_eq!(read(&NAME).as_deref(), Some("Fix the build"));
        assert_eq!(read(&MODEL).as_deref(), Some("google/gemini-2.5-flash"));
        fs::write(
            &path,
            r#"{"type":"session_info","name":""}"#.to_string() + "\n",
        )
        .unwrap();
        assert_eq!(read(&NAME), None, "an empty name clears it");
        fs::remove_dir_all(&dir).unwrap();
    }
}
