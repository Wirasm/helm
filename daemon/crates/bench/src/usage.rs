//! The two senders of a harness's plan limits (#143). Both run on the agent's machine, where the
//! harness writes them, so helm never reads a harness's files.
//!
//! - **Claude Code** publishes `rate_limits` only to its statusline command (measured on
//!   2.1.286: no hook payload carries it). `bench statusline [command...]` is wired as that
//!   command: it reports the limits and runs the operator's own statusline on the same input.
//! - **codex** writes them into its rollout, which every hook payload names
//!   (`transcript_path`), so `bench hook codex` reads the newest record there.

use bench_wire::{Harness, Usage};
use serde_json::{Value, json};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

/// A statusline payload larger than this is not read further (a few KB in practice).
const STATUSLINE_STDIN_MAX: u64 = 1024 * 1024;

/// How far back from a rollout's end `bench hook codex` looks for a `rate_limits` record: one
/// is written per model response, so it sits near the end unless a tool printed more than this
/// since. One read per hook, so a rollout with no plan record (an API-key session) costs at most
/// this on each tool call.
const ROLLOUT_TAIL: u64 = 1024 * 1024;

/// `bench statusline [command [args...]]`: Claude Code's `statusLine` command. Runs `command`
/// with the payload on its stdin and its output as this one's, so the operator's statusline
/// shows unchanged, and reports the payload's `rate_limits` to benchd on the way. Exits with the
/// command's status (0 with none). benchd being down, or a payload with no limits, changes only
/// the report, never the statusline.
pub fn statusline(command: &[String]) -> i32 {
    let mut input = Vec::new();
    let _ = std::io::stdin()
        .take(STATUSLINE_STDIN_MAX)
        .read_to_end(&mut input);
    // Reported first, so a statusline command that cannot start loses only itself.
    if let Some(usage) = serde_json::from_slice::<Value>(&input)
        .ok()
        .and_then(|payload| Usage::from_claude_statusline(&payload, now_ms()))
    {
        let _ = crate::quiet_request("usage/report", json!(usage));
    }
    let child = match command.split_first() {
        None => None,
        Some((program, args)) => {
            match Command::new(program)
                .args(args)
                .stdin(Stdio::piped())
                .spawn()
            {
                Ok(mut child) => {
                    // A command that never reads its stdin closes it: not our failure.
                    if let Some(mut stdin) = child.stdin.take() {
                        let _ = stdin.write_all(&input);
                    }
                    Some(child)
                }
                Err(e) => {
                    eprintln!("bench statusline: cannot run {program}: {e}");
                    return 127;
                }
            }
        }
    };
    match child.map(|mut c| c.wait()) {
        None => 0,
        Some(Ok(status)) => status.code().unwrap_or(1),
        Some(Err(_)) => 1,
    }
}

/// What a codex hook reports about its plan's limits: the newest record in its rollout, on the
/// events that follow a model response (`PostToolUse`, `Stop`) or open a session (`SessionStart`,
/// so a resumed one shows its last figure). Every other event, and every other harness, nothing.
pub fn codex_hook(harness: Harness, event: &str, rollout: Option<&str>) -> Option<Usage> {
    if harness != Harness::Codex || !matches!(event, "SessionStart" | "PostToolUse" | "Stop") {
        return None;
    }
    newest_in_rollout(Path::new(rollout?))
}

/// The last plan-limit record in the last [`ROLLOUT_TAIL`] bytes of a rollout.
fn newest_in_rollout(path: &Path) -> Option<Usage> {
    let mut file = File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    let start = len.saturating_sub(ROLLOUT_TAIL);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    // A tail that starts mid-file starts mid-line: that first piece is not a line.
    let whole = if start == 0 {
        &text[..]
    } else {
        text.split_once('\n').map_or("", |(_, rest)| rest)
    };
    whole.lines().rev().find_map(Usage::from_codex_rollout_line)
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The newest plan record wins over an older one and over any line after it, however much
    /// output followed it inside the tail.
    #[test]
    fn the_newest_plan_record_is_found_however_far_back() {
        let dir = std::env::temp_dir().join(format!("bench-usage-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rollout.jsonl");
        let plan = |used: f64, ts: &str| {
            json!({ "timestamp": ts, "type": "event_msg", "payload": { "type": "token_count",
                "rate_limits": { "limit_id": "codex",
                    "primary": { "used_percent": used, "window_minutes": 10080, "resets_at": 1 } } } })
            .to_string()
        };
        let noise =
            json!({ "type": "response_item", "payload": { "output": "x".repeat(200_000) } })
                .to_string();
        let text = [
            plan(10.0, "2026-09-27T10:00:00Z"),
            plan(20.0, "2026-09-27T11:00:00Z"),
            noise,
        ]
        .join("\n")
            + "\n";
        std::fs::write(&path, text).unwrap();
        let found = codex_hook(Harness::Codex, "Stop", path.to_str()).unwrap();
        assert_eq!(found.windows[0].used_percent, 20.0);
        assert_eq!(
            codex_hook(Harness::Codex, "PreToolUse", path.to_str()),
            None
        );
        assert_eq!(codex_hook(Harness::Claude, "Stop", path.to_str()), None);
        assert_eq!(codex_hook(Harness::Codex, "Stop", None), None);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
