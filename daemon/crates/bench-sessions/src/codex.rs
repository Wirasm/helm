//! codex's files: rollouts at `~/.codex/sessions/YYYY/MM/DD/rollout-<local time>-<thread
//! id>.jsonl`, whose first line is `{"type":"session_meta","payload":{"id":…}}`, and thread
//! names in `~/.codex/session_index.jsonl`, one `{"id","thread_name","updated_at"}` line per
//! rename (codex 0.157 and 0.159).

use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use time::OffsetDateTime;

pub fn sessions_dir(home: &Path) -> PathBuf {
    home.join(".codex/sessions")
}

/// The rollout of thread `id`. A thread id is a UUIDv7, whose first 48 bits are its creation
/// time in epoch ms, and the day directory is that time in codex's local zone: so the UTC day
/// and the days either side are looked in first, and the whole tree only when those miss.
pub fn rollout(home: &Path, id: &str) -> Option<PathBuf> {
    let root = sessions_dir(home);
    let suffix = format!("-{id}.jsonl");
    let dated = created_ms(id).into_iter().flat_map(|ms| {
        [-1i64, 0, 1].map(|d| {
            let t = OffsetDateTime::from_unix_timestamp(ms / 1000 + d * 86_400)
                .unwrap_or(OffsetDateTime::UNIX_EPOCH);
            root.join(format!(
                "{:04}/{:02}/{:02}",
                t.year(),
                t.month() as u8,
                t.day()
            ))
        })
    });
    dated
        .into_iter()
        .find_map(|dir| find(&dir, &suffix, 0))
        .or_else(|| find(&root, &suffix, 3))
}

/// The epoch ms a UUIDv7 was minted at, from its first twelve hex digits.
fn created_ms(id: &str) -> Option<i64> {
    let hex: String = id.chars().filter(|c| *c != '-').take(12).collect();
    (hex.len() == 12)
        .then(|| i64::from_str_radix(&hex, 16).ok())
        .flatten()
}

/// The file in `dir`, or `depth` directories below it, whose name ends with `suffix`.
fn find(dir: &Path, suffix: &str, depth: u8) -> Option<PathBuf> {
    for entry in fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() {
            if depth > 0
                && let Some(found) = find(&path, suffix, depth - 1)
            {
                return Some(found);
            }
        } else if path
            .file_name()
            .is_some_and(|n| n.to_string_lossy().ends_with(suffix))
        {
            return Some(path);
        }
    }
    None
}

/// Thread names by thread id, the last rename winning. A line that does not parse is left out:
/// a name is a label on a row, never a row.
pub fn names(home: &Path) -> HashMap<String, String> {
    let text = fs::read_to_string(home.join(".codex/session_index.jsonl")).unwrap_or_default();
    text.lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter_map(|v| {
            let (id, name) = (v["id"].as_str()?, v["thread_name"].as_str()?.trim());
            (!name.is_empty()).then(|| (id.to_string(), name.to_string()))
        })
        .collect()
}

/// Checks a rollout's first line: codex's `session_meta`, naming thread `id`.
pub fn header(first_line: &str, id: &str) -> Result<(), String> {
    let meta: Value =
        serde_json::from_str(first_line).map_err(|e| format!("first line is not JSON: {e}"))?;
    if meta["type"].as_str() != Some("session_meta") {
        return Err(format!(
            "first record is {} — a codex rollout opens with session_meta",
            meta["type"]
        ));
    }
    if meta["payload"]["id"].as_str() != Some(id) {
        return Err(format!(
            "session_meta id {} is not {id:?}",
            meta["payload"]["id"]
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rollout_is_found_in_its_day_directory_or_anywhere_below() {
        let home = std::env::temp_dir().join(format!("bench-codex-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        // 01a0f663-47f0… was minted 2026-10-01T07:34:56Z; codex filed it under the local day.
        let id = "01a0f663-47f0-7d53-b41a-68f3a1f656ab";
        let dated =
            sessions_dir(&home).join(format!("2026/10/01/rollout-2026-10-01T10-34-56-{id}.jsonl"));
        // Not a UUIDv7 day: found by the walk.
        let odd = sessions_dir(&home).join("2025/01/01/rollout-2025-01-01T00-00-00-x9.jsonl");
        for p in [&dated, &odd] {
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(p, "").unwrap();
        }
        assert_eq!(created_ms(id), Some(1_790_840_096_752));
        assert_eq!(rollout(&home, id), Some(dated));
        assert_eq!(rollout(&home, "x9"), Some(odd));
        assert_eq!(rollout(&home, "01a0f663-0000-7000-8000-000000000000"), None);

        fs::write(
            home.join(".codex/session_index.jsonl"),
            format!(
                "{}\n{{torn\n{}\n{}\n",
                serde_json::json!({"id": id, "thread_name": "first"}),
                serde_json::json!({"id": id, "thread_name": "Fix the build"}),
                serde_json::json!({"id": "other", "thread_name": "  "}),
            ),
        )
        .unwrap();
        let names = names(&home);
        assert_eq!(names.get(id).map(String::as_str), Some("Fix the build"));
        assert!(!names.contains_key("other"), "a blank name is no name");
        let _ = fs::remove_dir_all(&home);
    }
}
