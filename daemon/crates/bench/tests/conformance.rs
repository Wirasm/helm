//! Conformance: run the REAL binaries as subprocesses and check both directions —
//! the `SpoolWireConformanceTests` shape, ported (bench-roadmap, working discipline).
//! Nothing here mocks the socket, the daemon, or the CLI; what these tests pass is what
//! an agent's shell gets.
//!
//! Ground rules carried from helm's incidents:
//! - **Never the operator's estate.** Every test claims its own `HOME` under the OS
//!   tempdir, and the negative control asserts the shared `~/.bench` shape was never
//!   created there (#285's lesson: isolation is proven, not assumed).
//! - **Bounded children.** Every daemon is killed by the guard's Drop by the pid we
//!   spawned — never a pattern — and waited on (#291's lesson).
//! - Requires a prior `cargo build --workspace` (daemon/test.sh does this): the benchd
//!   binary is located beside our own CARGO_BIN_EXE path.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

fn bench_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_bench"))
}

fn benchd_bin() -> PathBuf {
    let p = bench_bin().parent().unwrap().join("benchd");
    assert!(
        p.exists(),
        "benchd binary not built — run daemon/test.sh (or cargo build --workspace) first"
    );
    p
}

/// A disposable HOME under the OS tempdir. The OS tempdir, not the repo and not a long
/// scratch path: unix socket paths cap near 104 bytes, and bench-wire refuses overlong
/// ones — a test home has to stay short enough to bind in.
struct TestHome {
    dir: PathBuf,
}

impl TestHome {
    /// The name is SHORT on purpose (`bcf-<pid>-<n>`): the macOS per-user tempdir is
    /// already ~50 bytes, and `<home>/.bench-<suite>/benchd.sock` has to stay under the
    /// ~104-byte `sun_path` cap. A descriptive label here once pushed every socket past
    /// it and all eight daemons refused to start — correctly, and uselessly. The `label`
    /// is kept only for the panic message.
    fn claim(label: &str) -> TestHome {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("bcf-{}-{n}", std::process::id()));
        fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("claim home for {label}: {e}"));
        TestHome { dir }
    }
}

impl Drop for TestHome {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// Owns exactly the daemon it spawned; Drop kills that pid and waits.
struct DaemonGuard {
    child: Child,
    socket: PathBuf,
}

impl DaemonGuard {
    fn start(home: &Path, suite: Option<&str>) -> DaemonGuard {
        let mut cmd = Command::new(benchd_bin());
        cmd.env_remove("BENCH_DIR")
            .env_remove("BENCH_SUITE")
            .env("HOME", home)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let root = match suite {
            Some(s) => {
                cmd.arg("--suite").arg(s);
                home.join(format!(".bench-{s}"))
            }
            None => home.join(".bench"),
        };
        let child = cmd.spawn().expect("spawn benchd");
        let socket = root.join("benchd.sock");
        let guard = DaemonGuard { child, socket };
        guard.await_socket();
        guard
    }

    fn await_socket(&self) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if UnixStream::connect(&self.socket).is_ok() {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("benchd never answered at {}", self.socket.display());
    }
}

impl Drop for DaemonGuard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct CliRun {
    code: i32,
    stdout: String,
    stderr: String,
}

fn bench(home: &Path, args: &[&str]) -> CliRun {
    let out = Command::new(bench_bin())
        .env_remove("BENCH_DIR")
        .env_remove("BENCH_SUITE")
        .env("HOME", home)
        .args(args)
        .output()
        .expect("run bench");
    CliRun {
        code: out.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

// ---------------------------------------------------------------------------
// The exit-code contract, status case by status case
// ---------------------------------------------------------------------------

#[test]
fn no_daemon_is_exit_2_and_names_the_socket() {
    let home = TestHome::claim("nodaemon");
    let run = bench(&home.dir, &["status"]);
    assert_eq!(run.code, 2, "stderr: {}", run.stderr);
    assert!(
        run.stderr.contains("benchd.sock"),
        "refusal must name the socket: {}",
        run.stderr
    );
}

#[test]
fn ok_is_exit_0_with_the_verbs_data() {
    let home = TestHome::claim("ok");
    let _daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(&home.dir, &["status"]);
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    let data: serde_json::Value = serde_json::from_str(&run.stdout).expect("status prints JSON");
    assert!(data["pid"].as_u64().is_some());
    assert_eq!(data["suite"], serde_json::Value::Null);
    assert!(
        data["events"].as_u64().unwrap() >= 1,
        "daemon/started must be logged"
    );
}

#[test]
fn an_unknown_verb_is_refused_with_exit_3_naming_the_known_verbs() {
    let home = TestHome::claim("refused");
    let _daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(&home.dir, &["definitely-not-a-verb"]);
    assert_eq!(run.code, 3, "stderr: {}", run.stderr);
    assert!(
        run.stderr.contains("status, events, stop"),
        "a refusal names the route to use instead: {}",
        run.stderr
    );
}

#[test]
fn a_suite_that_cannot_isolate_is_refused_client_side_before_any_socket() {
    let home = TestHome::claim("badsuite");
    let run = bench(&home.dir, &["--suite", "has/slash", "status"]);
    assert_eq!(run.code, 3, "stderr: {}", run.stderr);
    assert!(
        run.stderr.contains("path"),
        "the refusal names the rule: {}",
        run.stderr
    );
}

#[test]
fn an_oversized_request_line_is_refused_not_read() {
    let home = TestHome::claim("oversize");
    let daemon = DaemonGuard::start(&home.dir, None);
    let stream = UnixStream::connect(&daemon.socket).unwrap();
    let huge = format!(
        "{{\"id\":\"big\",\"verb\":\"status\",\"pad\":\"{}\"}}\n",
        "x".repeat(70_000)
    );
    (&stream).write_all(huge.as_bytes()).unwrap();
    let mut reply = String::new();
    BufReader::new(&stream).read_line(&mut reply).unwrap();
    let response: serde_json::Value = serde_json::from_str(&reply).unwrap();
    assert_eq!(response["status"], "refused", "reply: {reply}");
}

// ---------------------------------------------------------------------------
// The record
// ---------------------------------------------------------------------------

#[test]
fn stop_is_logged_before_it_is_answered_and_the_file_outlives_the_daemon() {
    let home = TestHome::claim("stop");
    let daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(&home.dir, &["stop"]);
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);

    // The daemon exits on its own after answering; wait for it rather than killing it,
    // so what we then read is a *completed* record.
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && UnixStream::connect(&daemon.socket).is_ok() {
        std::thread::sleep(Duration::from_millis(20));
    }
    let after = bench(&home.dir, &["status"]);
    assert_eq!(after.code, 2, "a stopped daemon is exit 2, not an error");

    // Files are the record: read the log with cat-level tooling, no daemon involved.
    let log = fs::read_to_string(home.dir.join(".bench/events.jsonl")).unwrap();
    let kinds: Vec<String> = log
        .lines()
        .map(|l| {
            serde_json::from_str::<serde_json::Value>(l).unwrap()["kind"]
                .as_str()
                .unwrap()
                .to_string()
        })
        .collect();
    assert_eq!(kinds.first().map(String::as_str), Some("daemon/started"));
    assert_eq!(kinds.last().map(String::as_str), Some("daemon/stopped"));
}

#[test]
fn events_reads_back_exactly_what_was_logged() {
    let home = TestHome::claim("events");
    let _daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(&home.dir, &["events"]);
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    let data: serde_json::Value = serde_json::from_str(&run.stdout).unwrap();
    assert_eq!(data["truncated"], false);
    let events = data["events"].as_array().unwrap();
    assert_eq!(events[0]["kind"], "daemon/started");
    assert_eq!(events[0]["seq"], 0);
}

// ---------------------------------------------------------------------------
// M0's prove line: two instances, zero shared state
// ---------------------------------------------------------------------------

#[test]
fn a_live_and_a_suite_instance_share_nothing() {
    let home = TestHome::claim("isolation");
    let live = DaemonGuard::start(&home.dir, None);
    let suite = DaemonGuard::start(&home.dir, Some("m0"));
    assert_ne!(live.socket, suite.socket);

    let live_status = bench(&home.dir, &["status"]);
    let suite_status = bench(&home.dir, &["--suite", "m0", "status"]);
    assert_eq!(live_status.code, 0);
    assert_eq!(suite_status.code, 0);

    let live_data: serde_json::Value = serde_json::from_str(&live_status.stdout).unwrap();
    let suite_data: serde_json::Value = serde_json::from_str(&suite_status.stdout).unwrap();
    assert_ne!(live_data["pid"], suite_data["pid"], "two daemons, not one");
    assert_ne!(live_data["root"], suite_data["root"], "two roots, not one");
    assert_eq!(suite_data["suite"], "m0");

    // Stopping the suite instance must not touch the live one — the whole point.
    let stop = bench(&home.dir, &["--suite", "m0", "stop"]);
    assert_eq!(stop.code, 0);
    let live_after = bench(&home.dir, &["status"]);
    assert_eq!(
        live_after.code, 0,
        "the live instance survived the suite's stop"
    );

    // Two records on disk, each with its own history.
    assert!(home.dir.join(".bench/events.jsonl").exists());
    assert!(home.dir.join(".bench-m0/events.jsonl").exists());
}

#[test]
fn bench_dir_overrides_everything_which_is_what_a_test_claims_into() {
    let home = TestHome::claim("benchdir");
    let claimed = home.dir.join("claimed");
    fs::create_dir_all(&claimed).unwrap();

    let mut cmd = Command::new(benchd_bin());
    cmd.env_remove("BENCH_SUITE")
        .env("HOME", home.dir.join("unused-home"))
        .env("BENCH_DIR", &claimed)
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut child = cmd.spawn().unwrap();
    let socket = claimed.join("benchd.sock");
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && UnixStream::connect(&socket).is_err() {
        std::thread::sleep(Duration::from_millis(20));
    }

    let out = Command::new(bench_bin())
        .env("HOME", home.dir.join("unused-home"))
        .env("BENCH_DIR", &claimed)
        .arg("status")
        .output()
        .unwrap();
    let _ = child.kill();
    let _ = child.wait();
    assert_eq!(out.status.code(), Some(0));

    // Negative control (#285's shape): the claimed dir got the state, the un-claimed
    // home shape was never created.
    assert!(claimed.join("events.jsonl").exists());
    assert!(
        !home.dir.join("unused-home/.bench").exists(),
        "shared root must not appear"
    );
}

#[test]
fn a_second_daemon_on_a_claimed_root_is_refused_loudly() {
    let home = TestHome::claim("double");
    let _first = DaemonGuard::start(&home.dir, None);
    let out = Command::new(benchd_bin())
        .env_remove("BENCH_DIR")
        .env_remove("BENCH_SUITE")
        .env("HOME", &home.dir)
        .output()
        .expect("run second benchd");
    assert_eq!(
        out.status.code(),
        Some(3),
        "one daemon per root is a refusal, not a race"
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("already answers"),
        "the refusal says who holds the root: {stderr}"
    );
}
