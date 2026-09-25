//! pi's sessions: `~/.pi/agent/sessions/--<cwd with / as ->--/<timestamp>_<id>.jsonl`, whose
//! first line is `{"type":"session","version":3,"id":…,"cwd":…}` (pi 0.84, format v3).

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
    let header: Value =
        serde_json::from_str(&first).map_err(|e| bad(format!("first line is not JSON: {e}")))?;
    let (kind, version) = (header["type"].as_str(), header["version"].as_u64());
    if kind != Some("session") || version != Some(VERSION) {
        return Err(bad(format!(
            "header type {kind:?} version {version:?} — this build reads type \"session\" version {VERSION}"
        )));
    }
    if header["id"].as_str() != Some(id) {
        return Err(bad(format!("header id {} is not {id:?}", header["id"])));
    }
    Ok(Some(path))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_directory_name_keeps_dots_and_brackets_the_path() {
        assert_eq!(dir_name("/private/tmp"), "--private-tmp--");
        assert_eq!(dir_name("/r/helm/.worktrees/a"), "--r-helm-.worktrees-a--");
    }
}
