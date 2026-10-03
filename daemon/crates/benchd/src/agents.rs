//! Which claude, codex and pi this benchd would spawn, for `status` (helm parity G4).
//!
//! benchd starts an agent by name, so the binary is the first one on benchd's own `PATH`, which
//! is the LaunchAgent's and not the operator's shell's. A stale Homebrew codex ahead of the
//! self-updating one in `~/.local/bin` once made every spawned codex 0.157.0 while his install
//! had moved to 0.159.3. `status` names the path, what it links to, and the version it prints,
//! so that difference is visible without spawning anything.

use bench_session::AgentKind;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// How long `<agent> --version` may take. pi is a node program and takes about 0.2s.
const VERSION_TIMEOUT: Duration = Duration::from_secs(3);

/// Versions by the binary's resolved path, size and mtime. helm asks `status` before a pane
/// attaches, so `--version` runs once per binary rather than once per ask. A self-updating
/// install moves its symlink to a new release directory, and `npm update -g` rewrites pi's file
/// in place; either is a new key. A failed or overrun `--version` is not kept, so the next ask
/// tries again.
type Key = (PathBuf, u64, Option<std::time::SystemTime>);
static VERSIONS: Mutex<Option<HashMap<Key, String>>> = Mutex::new(None);

/// `{claude: {path, resolves_to, version}, codex: …, pi: …}`, each `null` when benchd's `PATH`
/// has no such program.
pub fn report() -> Value {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let mut out = serde_json::Map::new();
    for kind in [AgentKind::Claude, AgentKind::Codex, AgentKind::Pi] {
        let entry = resolve(kind.name(), &path).map(|found| {
            let target = std::fs::canonicalize(&found).unwrap_or_else(|_| found.clone());
            json!({
                "path": found,
                "resolves_to": target,
                "version": version(&target, VERSION_TIMEOUT),
            })
        });
        out.insert(kind.name().to_string(), entry.unwrap_or(Value::Null));
    }
    Value::Object(out)
}

/// The first executable `name` on `path`, as a `Command` spawned by that name would run it.
pub(crate) fn resolve(name: &str, path: &std::ffi::OsStr) -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    std::env::split_paths(path)
        .filter(|dir| !dir.as_os_str().is_empty())
        .map(|dir| dir.join(name))
        .find(|candidate| {
            std::fs::metadata(candidate)
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
}

fn version(binary: &Path, within: Duration) -> Option<String> {
    let meta = std::fs::metadata(binary).ok()?;
    let key = (binary.to_path_buf(), meta.len(), meta.modified().ok());
    if let Some(known) = VERSIONS
        .lock()
        .unwrap()
        .get_or_insert_with(HashMap::new)
        .get(&key)
    {
        return Some(known.clone());
    }
    let found = run_version(binary, within)?;
    VERSIONS
        .lock()
        .unwrap()
        .get_or_insert_with(HashMap::new)
        .insert(key, found.clone());
    Some(found)
}

/// The first line `<binary> --version` prints, or `None` when it fails or overruns `within`.
fn run_version(binary: &Path, within: Duration) -> Option<String> {
    let mut child = Command::new(binary)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + within;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    let mut text = String::new();
    child.stdout.take()?.read_to_string(&mut text).ok()?;
    let line = text.lines().next()?.trim();
    (status.success() && !line.is_empty()).then(|| line.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// Long enough for a stub's first run. A file written a moment ago can wait seconds on
    /// macOS before it runs, while other new binaries are checked: past `VERSION_TIMEOUT` with a
    /// few dozen being written beside it. benchd's agents were installed long before it asks.
    const ANSWER: Duration = Duration::from_secs(60);

    /// The stub is written by a child, so this process never holds it open for writing. A
    /// child another test forks meanwhile would inherit that descriptor until it execs, and
    /// Linux refuses to run a file anything has open for writing ("Text file busy").
    fn stub(dir: &Path, name: &str, body: &str) {
        std::fs::create_dir_all(dir).unwrap();
        let mut writer = Command::new("/bin/sh")
            .args(["-c", r#"cat > "$0" && chmod 755 "$0""#])
            .arg(dir.join(name))
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdin = writer.stdin.take().unwrap();
        stdin
            .write_all(format!("#!/bin/sh\n{body}\n").as_bytes())
            .unwrap();
        drop(stdin);
        assert!(writer.wait().unwrap().success());
    }

    #[test]
    fn the_first_codex_on_path_is_the_one_reported_with_its_version() {
        let root = std::env::temp_dir().join(format!("benchd-agents-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (brew, local) = (root.join("brew"), root.join("local"));
        stub(&brew, "codex", "echo 'codex-cli 0.157.0'");
        stub(&local, "codex", "echo 'codex-cli 0.159.3'");
        let path = std::env::join_paths([&local, &brew]).unwrap();

        let found = resolve("codex", &path).unwrap();
        assert_eq!(found, local.join("codex"));
        assert_eq!(
            version(&found, ANSWER).as_deref(),
            Some("codex-cli 0.159.3")
        );
        assert_eq!(
            resolve("pi", &path),
            None,
            "a program on no PATH entry is absent"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_binary_rewritten_in_place_reports_its_new_version() {
        let root = std::env::temp_dir().join(format!("benchd-agents-npm-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        stub(&root, "pi", "echo 0.84.4");
        let pi = root.join("pi");
        assert_eq!(version(&pi, ANSWER).as_deref(), Some("0.84.4"));
        stub(&root, "pi", "echo 0.99.2   ");
        assert_eq!(
            version(&pi, ANSWER).as_deref(),
            Some("0.99.2"),
            "npm update -g rewrites the file"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// `report` resolves `kind.name()` on PATH; a spawn runs what `argv` names. They must be the
    /// same program, or `status` reports a binary no spawn runs. A codex benchd runs is the
    /// program its app-server was started from, which is this same resolution, canonicalized:
    /// `status`'s `resolves_to` (`codex::Server::start`).
    #[test]
    fn the_program_reported_is_the_program_a_spawn_runs() {
        use bench_session::{Conversation, Posture, SpawnSpec, argv};
        for kind in [AgentKind::Claude, AgentKind::Codex, AgentKind::Pi] {
            let spec = SpawnSpec {
                agent: kind,
                cwd: "/tmp".into(),
                model: None,
                effort: None,
                conversation: Conversation::New(None),
                posture: Posture::Unattended,
                prompt_file: None,
                settings: None,
                extra_args: Vec::new(),
                codex: None,
                account: None,
            };
            assert_eq!(argv(&spec).unwrap().0, kind.name());
        }
    }

    #[test]
    fn a_version_that_fails_or_hangs_is_none_not_a_wrong_string() {
        let root = std::env::temp_dir().join(format!("benchd-agents-bad-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        stub(&root, "failing", "echo 'not a version'; exit 1");
        stub(&root, "hanging", "exec sleep 30");
        assert_eq!(run_version(&root.join("failing"), ANSWER), None);
        let start = Instant::now();
        assert_eq!(run_version(&root.join("hanging"), VERSION_TIMEOUT), None);
        assert!(start.elapsed() < VERSION_TIMEOUT + Duration::from_secs(2));
        let _ = std::fs::remove_dir_all(&root);
    }
}
