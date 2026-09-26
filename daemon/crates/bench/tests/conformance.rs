//! Conformance: run the REAL binaries as subprocesses and check both directions —
//! the `SpoolWireConformanceTests` shape, ported (bench-roadmap, working discipline).
//! Nothing here mocks the socket, the daemon, or the CLI; what these tests pass is what
//! an agent's shell gets.
//!
//! Ground rules carried from helm's incidents:
//! - **Never the operator's estate.** Every test claims its own `HOME` under the OS
//!   tempdir, every child starts through [`isolated`] without the inherited `BENCH_*` and
//!   `HELM_PANE`, and the negative control asserts the shared `~/.bench` shape was never
//!   created there (#285's lesson: isolation is proven, not assumed).
//! - **Bounded children.** Every daemon is killed by the guard's Drop by the pid we
//!   spawned — never a pattern — and waited on (#291's lesson).
//! - Requires a prior `cargo build --workspace` (daemon/test.sh does this): the benchd
//!   binary is located beside our own CARGO_BIN_EXE path.

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
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

/// What the shell running `cargo test` may carry that would point `bench` or `benchd` past the
/// test's own HOME, or make a child speak as somebody. An agent in a benchd-spawned session
/// inherits `BENCH_DIR` (the operator's live `~/.bench`), `BENCH_SESSION` and `BENCH_HANDLE`;
/// one in a helm pane inherits `HELM_PANE`; a just recipe the operator started carries
/// `BENCH_ASKED=1`. `HELM_BENCH_DIR` and `PLAYWRIGHT_BROWSERS_PATH` override roots benchd
/// otherwise finds under HOME (helm's snapshot, the browser's Playwright cache).
const INHERITED: &[&str] = &[
    "BENCH_DIR",
    "BENCH_SUITE",
    "BENCH_SESSION",
    "BENCH_HANDLE",
    "BENCH_ASKED",
    "HELM_PANE",
    "HELM_BENCH_DIR",
    "PLAYWRIGHT_BROWSERS_PATH",
];

/// The one way this suite starts a child: without any of [`INHERITED`], so a test sets only
/// what it means. `Command` is deliberately not imported, so a bare `Command::new` does not
/// compile. Before this, `bench status` reached the operator's live benchd through an
/// inherited `BENCH_DIR` and exited 0 where a test expected 2.
fn isolated(program: impl AsRef<std::ffi::OsStr>) -> std::process::Command {
    let mut cmd = std::process::Command::new(program);
    for name in INHERITED {
        cmd.env_remove(name);
    }
    cmd
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
        DaemonGuard::start_with(home, suite, isolated(benchd_bin()))
    }

    /// A daemon whose `pi` is [`write_fake_agent`]'s: a real harness name, so its sessions
    /// are rows in `sessions/all`, and no real agent behind it.
    fn start_with_fake_pi(home: &Path) -> DaemonGuard {
        DaemonGuard::start_with_fake(home, "pi")
    }

    fn start_with_fake(home: &Path, agent: &str) -> DaemonGuard {
        let bin = write_fake_agent(home, agent);
        let path = std::env::var("PATH").unwrap_or_default();
        let mut cmd = isolated(benchd_bin());
        cmd.env("PATH", format!("{}:{path}", bin.display()));
        DaemonGuard::start_with(home, None, cmd)
    }

    fn start_with(home: &Path, suite: Option<&str>, mut cmd: std::process::Command) -> DaemonGuard {
        cmd.env("BENCH_SESSION_TEST_AGENT", "1")
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
    bench_as(home, args, &[])
}

/// `bench` with the caller's declared identity (`HELM_PANE`, `BENCH_HANDLE`) set as given, and
/// otherwise absent ([`isolated`]).
fn bench_as(home: &Path, args: &[&str], env: &[(&str, &str)]) -> CliRun {
    let mut cmd = isolated(bench_bin());
    for (k, v) in env {
        cmd.env(k, v);
    }
    let out = cmd
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
    assert_eq!(kinds.first().map(String::as_str), Some("log/format"));
    assert_eq!(kinds.get(1).map(String::as_str), Some("daemon/started"));
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
    assert_eq!(events[0]["kind"], "log/format");
    assert_eq!(events[0]["seq"], 0);
    assert_eq!(events[1]["kind"], "daemon/started");
}

// ---------------------------------------------------------------------------
// The record survives what interrupts it (PR #340 review, R1/R2/R4/R5)
// ---------------------------------------------------------------------------

/// Run a command with a hard deadline; a hang is a FAILING outcome with its own name,
/// never a stuck test run.
fn run_bounded(cmd: &mut std::process::Command, deadline: Duration) -> Option<CliRun> {
    let mut child = cmd
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn bounded command");
    let start = Instant::now();
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            let mut stdout = String::new();
            let mut stderr = String::new();
            use std::io::Read as _;
            child
                .stdout
                .take()
                .map(|mut s| s.read_to_string(&mut stdout));
            child
                .stderr
                .take()
                .map(|mut s| s.read_to_string(&mut stderr));
            return Some(CliRun {
                code: status.code().unwrap_or(-1),
                stdout,
                stderr,
            });
        }
        if start.elapsed() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn write_seed_log(root: &Path, torn_tail: Option<&str>, garbage_middle: bool) {
    fs::create_dir_all(root).unwrap();
    let mut log = String::new();
    log.push_str("{\"seq\":0,\"at\":\"2026-08-18T00:00:00Z\",\"kind\":\"log/format\",\"data\":{\"format\":\"bench.events-log\",\"version\":0}}\n");
    log.push_str("{\"seq\":1,\"at\":\"2026-08-18T00:00:01Z\",\"kind\":\"daemon/started\",\"data\":{\"pid\":1}}\n");
    if garbage_middle {
        log.push_str("this line was never an event\n");
    }
    log.push_str("{\"seq\":2,\"at\":\"2026-08-18T00:00:02Z\",\"kind\":\"daemon/stopped\",\"data\":{\"pid\":1}}\n");
    if let Some(tail) = torn_tail {
        log.push_str(tail); // no newline: an interrupted append
    }
    fs::write(root.join("events.jsonl"), log).unwrap();
}

#[test]
fn a_torn_last_line_is_quarantined_and_the_daemon_starts() {
    let home = TestHome::claim("torn");
    let root = home.dir.join("r");
    write_seed_log(&root, Some("{\"seq\":3,\"at\":\"2026-08-18T00:0"), false);

    let mut cmd = isolated(benchd_bin());
    cmd.env("HOME", &home.dir).env("BENCH_DIR", &root);
    cmd.stdout(Stdio::null()).stderr(Stdio::null());
    let mut child = cmd.spawn().unwrap();
    let socket = root.join("benchd.sock");
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && UnixStream::connect(&socket).is_err() {
        std::thread::sleep(Duration::from_millis(20));
    }

    let status = isolated(bench_bin())
        .env("HOME", &home.dir)
        .env("BENCH_DIR", &root)
        .arg("status")
        .output()
        .unwrap();
    let _ = child.kill();
    let _ = child.wait();
    assert_eq!(
        status.status.code(),
        Some(0),
        "a torn LAST line must be forgiven, not brick the root: {}",
        String::from_utf8_lossy(&status.stderr)
    );

    // The tail is quarantined beside the log — dropped bytes are named, never vanished.
    let quarantined = fs::read_dir(&root)
        .unwrap()
        .filter_map(|e| e.ok())
        .any(|e| e.file_name().to_string_lossy().contains("torn"));
    assert!(
        quarantined,
        "the torn tail must be quarantined, not silently discarded"
    );

    // Bench-visible means logged: the repair itself is an event in the record.
    let log = fs::read_to_string(root.join("events.jsonl")).unwrap();
    assert!(
        log.contains("log/repaired"),
        "the repair must be logged: {log}"
    );
}

#[test]
fn a_bad_line_in_the_middle_still_refuses_naming_the_line() {
    let home = TestHome::claim("midbad");
    let root = home.dir.join("r");
    write_seed_log(&root, None, true);

    let out = isolated(benchd_bin())
        .env("HOME", &home.dir)
        .env("BENCH_DIR", &root)
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(3),
        "unexplained middle corruption keeps refusing"
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("line 3"),
        "the refusal names the line: {stderr}"
    );
}

#[test]
fn a_stalled_client_does_not_park_the_daemon() {
    let home = TestHome::claim("stall");
    let daemon = DaemonGuard::start(&home.dir, None);

    // A client that connects, sends half a line, and just sits there.
    let stalled = UnixStream::connect(&daemon.socket).unwrap();
    (&stalled)
        .write_all(b"{\"id\":\"stall\",\"verb\":\"stat")
        .unwrap();

    let t0 = Instant::now();
    let run = run_bounded(
        isolated(bench_bin())
            .env("HOME", &home.dir)
            .args(["status"]),
        Duration::from_secs(12),
    );
    drop(stalled);
    let run = run.expect("bench status hung past 12s behind one stalled client — R2 unfixed");
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    assert!(
        t0.elapsed() < Duration::from_secs(10),
        "service must resume within the daemon's own I/O bound"
    );
}

#[test]
fn a_daemon_that_never_answers_is_exit_2_not_a_hang() {
    let home = TestHome::claim("mute");
    let root = home.dir.join(".bench");
    fs::create_dir_all(&root).unwrap();
    // A listener that accepts and never answers — the worst-behaved daemon possible.
    let listener = std::os::unix::net::UnixListener::bind(root.join("benchd.sock")).unwrap();
    let _keep = std::thread::spawn(move || {
        let mut held = Vec::new();
        while let Ok((s, _)) = listener.accept() {
            held.push(s);
        }
    });

    let run = run_bounded(
        isolated(bench_bin())
            .env("HOME", &home.dir)
            .args(["status"]),
        Duration::from_secs(25),
    );
    let run = run.expect("bench hung past 25s on a mute daemon — the client has no read bound");
    assert_eq!(
        run.code, 2,
        "a timeout is EXIT_NO_DAEMON, never silence: {}",
        run.stderr
    );
}

#[test]
fn a_fresh_log_opens_with_its_format_marker() {
    let home = TestHome::claim("fmt");
    let daemon = DaemonGuard::start(&home.dir, None);
    let _ = &daemon;
    let log = fs::read_to_string(home.dir.join(".bench/events.jsonl")).unwrap();
    let first: serde_json::Value = serde_json::from_str(log.lines().next().unwrap()).unwrap();
    assert_eq!(first["kind"], "log/format");
    assert_eq!(first["data"]["format"], "bench.events-log");
}

#[test]
fn the_justfile_probes_every_known_verb() {
    // The probe list is hand-typed in the justfile (a `just` recipe cannot import a
    // crate), so it is pinned here the way helm pins the spool scripts' id pattern:
    // read the literal out of the source and compare (R5).
    let justfile = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../justfile"))
        .expect("daemon/justfile readable from the bench crate");
    let mut probe_lines: Vec<&str> = Vec::new();
    let mut in_probe = false;
    for line in justfile.lines() {
        if line.contains("for verb in") {
            in_probe = true;
        }
        if in_probe {
            probe_lines.push(line);
            if line.contains("; do") {
                break;
            }
        }
    }
    let probe_line = probe_lines.join(" ");
    for verb in bench_wire::KNOWN_VERBS {
        assert!(
            probe_line.contains(verb),
            "justfile spec probe list is missing known verb {verb:?}: {probe_line}"
        );
    }
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

    let mut cmd = isolated(benchd_bin());
    cmd.env("HOME", home.dir.join("unused-home"))
        .env("BENCH_DIR", &claimed)
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut child = cmd.spawn().unwrap();
    let socket = claimed.join("benchd.sock");
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && UnixStream::connect(&socket).is_err() {
        std::thread::sleep(Duration::from_millis(20));
    }

    let out = isolated(bench_bin())
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
    let out = isolated(benchd_bin())
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

// ---------------------------------------------------------------------------
// M5a: the pty core — sessions, the relay, and the OSC passthrough proof
// ---------------------------------------------------------------------------

/// Send one request on a raw socket and return (response_line, open_stream).
fn raw_request(
    socket: &Path,
    verb: &str,
    args: serde_json::Value,
) -> (serde_json::Value, UnixStream) {
    let stream = UnixStream::connect(socket).expect("connect");
    let req = format!(
        "{{\"id\":\"t-{}\",\"verb\":\"{verb}\",\"args\":{args}}}\n",
        std::process::id()
    );
    (&stream).write_all(req.as_bytes()).unwrap();
    let mut line = Vec::new();
    let mut b = [0u8; 1];
    loop {
        match (&stream).read(&mut b) {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                if b[0] == b'\n' {
                    break;
                }
                line.push(b[0]);
            }
        }
    }
    (
        serde_json::from_slice(&line).expect("response json"),
        stream,
    )
}

#[test]
fn spawn_refuses_an_agent_off_the_allowlist() {
    let home = TestHome::claim("allow");
    let _daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(&home.dir, &["spawn", "--agent", "sh", "--cwd", "/tmp"]);
    assert_eq!(run.code, 3, "stderr: {}", run.stderr);
    assert!(
        run.stderr.contains("allowlist"),
        "the refusal names the rule: {}",
        run.stderr
    );
}

#[test]
fn spawn_refuses_a_cwd_that_is_not_an_absolute_directory() {
    let home = TestHome::claim("cwd");
    let _daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(
        &home.dir,
        &["spawn", "--agent", "test-echo", "--cwd", "relative/x"],
    );
    assert_eq!(run.code, 3, "stderr: {}", run.stderr);
}

#[test]
fn a_session_relays_bytes_faithfully_including_an_osc_sequence() {
    // THE canvas-passthrough proof (M5a's named assumption): an OSC 777 written by the
    // agent must cross the relay byte-for-byte, because whatever terminal hosts
    // `bench attach` is what parses it — helm included.
    let home = TestHome::claim("relay");
    let daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(
        &home.dir,
        &["spawn", "--agent", "test-echo", "--cwd", "/tmp"],
    );
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    let spawned: serde_json::Value = serde_json::from_str(&run.stdout).unwrap();
    let sid = spawned["session"].as_str().unwrap().to_string();

    let (resp, stream) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": sid}),
    );
    assert_eq!(resp["status"], "ok", "{resp}");

    // cat echoes what the pty carries; the OSC must come back intact.
    let osc = "\u{1b}]777;notify;helm.canvas;/tmp/proof.html\u{7}";
    let payload = format!("before {osc} after\n");
    (&stream).write_all(payload.as_bytes()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut seen = Vec::new();
    let mut chunk = [0u8; 4096];
    let _ = stream.set_read_timeout(Some(Duration::from_millis(300)));
    while Instant::now() < deadline {
        match (&stream).read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => seen.extend_from_slice(&chunk[..n]),
            Err(_) => {}
        }
        if seen.windows(osc.len()).any(|w| w == osc.as_bytes()) {
            break;
        }
    }
    assert!(
        seen.windows(osc.len()).any(|w| w == osc.as_bytes()),
        "the OSC must survive the relay byte-for-byte; got {} bytes: {:?}",
        seen.len(),
        String::from_utf8_lossy(&seen)
    );

    let close = bench(&home.dir, &["close", &sid]);
    assert_eq!(close.code, 0, "stderr: {}", close.stderr);

    // Bench-visible means logged: the session's whole life is in the record.
    let log = fs::read_to_string(home.dir.join(".bench/events.jsonl")).unwrap();
    for kind in ["session/spawned", "session/attached", "session/closed"] {
        assert!(log.contains(kind), "{kind} missing from the log");
    }
}

#[test]
fn a_second_attach_takes_over_and_the_first_sees_eof() {
    let home = TestHome::claim("takeover");
    let daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(
        &home.dir,
        &["spawn", "--agent", "test-echo", "--cwd", "/tmp"],
    );
    let sid = serde_json::from_str::<serde_json::Value>(&run.stdout).unwrap()["session"]
        .as_str()
        .unwrap()
        .to_string();

    let (r1, s1) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": sid}),
    );
    assert_eq!(r1["status"], "ok");
    let (r2, _s2) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": sid}),
    );
    assert_eq!(r2["status"], "ok");

    // The first stream is shut down by the takeover — its next read is EOF, not a hang.
    let _ = s1.set_read_timeout(Some(Duration::from_secs(5)));
    let mut chunk = [0u8; 64];
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut eof = false;
    while Instant::now() < deadline {
        match (&s1).read(&mut chunk) {
            Ok(0) => {
                eof = true;
                break;
            }
            Ok(_) => {}
            Err(_) => {
                eof = true;
                break;
            }
        }
    }
    assert!(eof, "the replaced attach must be closed, not left dangling");

    let sessions = bench(&home.dir, &["sessions"]);
    let data: serde_json::Value = serde_json::from_str(&sessions.stdout).unwrap();
    assert_eq!(
        data["sessions"][0]["live"], true,
        "takeover must not kill the session"
    );
}

#[test]
fn an_exited_session_refuses_attach_and_the_exit_is_logged() {
    let home = TestHome::claim("exited");
    let _daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(
        &home.dir,
        &["spawn", "--agent", "test-echo", "--cwd", "/tmp"],
    );
    let spawned: serde_json::Value = serde_json::from_str(&run.stdout).unwrap();
    let sid = spawned["session"].as_str().unwrap().to_string();
    let pid = spawned["pid"].as_u64().unwrap();

    // Kill the agent out from under the daemon — the reader thread must notice and log.
    libc_kill(pid as i32);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let log = fs::read_to_string(home.dir.join(".bench/events.jsonl")).unwrap_or_default();
        if log.contains("session/exited") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "session/exited never reached the log"
        );
        std::thread::sleep(Duration::from_millis(100));
    }

    // R2: the exit must also REAP — a `<defunct>` child is a lifetime the daemon owns
    // and dropped. `ps -o stat=` on a zombie prints a state containing 'Z'; a reaped
    // pid prints nothing.
    let reap_deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let out = isolated("ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output()
            .unwrap();
        let stat = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !stat.contains('Z') {
            break;
        }
        assert!(
            Instant::now() < reap_deadline,
            "the exited child stayed a zombie (stat {stat:?}) — the drain thread must reap"
        );
        std::thread::sleep(Duration::from_millis(100));
    }

    let attach = bench(&home.dir, &["attach", &sid]);
    assert_eq!(
        attach.code, 3,
        "attach to an exited session is a refusal: {}",
        attach.stderr
    );
    assert!(
        attach.stderr.contains("resume"),
        "the refusal names the route: {}",
        attach.stderr
    );

    // The test agent has nothing to resume — the refusal says why.
    let resume = bench(&home.dir, &["resume", &sid]);
    assert_eq!(resume.code, 3, "stderr: {}", resume.stderr);
}

#[test]
fn stop_takes_the_sessions_with_it() {
    let home = TestHome::claim("stopall");
    let _daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(
        &home.dir,
        &["spawn", "--agent", "test-echo", "--cwd", "/tmp"],
    );
    let pid = serde_json::from_str::<serde_json::Value>(&run.stdout).unwrap()["pid"]
        .as_u64()
        .unwrap();
    let stop = bench(&home.dir, &["stop"]);
    assert_eq!(stop.code, 0);
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        let alive = libc_alive(pid as i32);
        if !alive {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the spawned agent outlived the daemon's stop"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

// Minimal libc shims — kill(2) with SIGKILL / signal 0 liveness — to avoid a dependency
// for two calls.
unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
}
fn libc_kill(pid: i32) {
    unsafe {
        kill(pid, 9);
    }
}
fn libc_alive(pid: i32) -> bool {
    unsafe { kill(pid, 0) == 0 }
}

// ---------------------------------------------------------------------------
// Mail: the mailroom, the notice discipline, the wake reactor, the cap
// ---------------------------------------------------------------------------

/// `<home>/bin/<agent>`: a stand-in that ignores its argv, echoes its pty and prints nothing
/// of its own, so it is quiet, live, and dies when its pid is killed. Returns the directory to
/// put on the daemon's PATH.
fn write_fake_agent(home: &Path, agent: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let path = bin.join(agent);
    fs::write(&path, "#!/bin/sh\nexec cat\n").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    bin
}

/// A git workspace under the test home: what `sessions/all` scopes rows by. Canonical,
/// because a snippet run from inside it resolves its cwd physically (`/private/var/…` on
/// macOS), and scope is compared lexically.
fn workspace(home: &Path) -> PathBuf {
    let ws = home.join("ws");
    fs::create_dir_all(ws.join(".git")).unwrap();
    ws.canonicalize().unwrap()
}

/// `bench spawn --agent pi --name <handle>` in `ws`, answering (pid, runtime session id).
fn spawn_pi(home: &Path, ws: &Path, handle: &str) -> (i32, String) {
    let ws = ws.display().to_string();
    let run = bench(
        home,
        &["spawn", "--agent", "pi", "--cwd", &ws, "--name", handle],
    );
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    let v = json_of(&run);
    (
        v["pid"].as_i64().unwrap() as i32,
        v["runtime_session"].as_str().unwrap().to_string(),
    )
}

#[test]
fn a_session_row_says_where_to_mail_it_and_whether_a_send_will_wake_it() {
    use bench_wire::{MailAddress, SessionList};
    let home = TestHome::claim("mailrow");
    let h = &home.dir;
    let daemon = DaemonGuard::start_with_fake_pi(h);
    let ws = workspace(h);
    let ws_arg = ws.display().to_string();
    let (pid, runtime) = spawn_pi(h, &ws, "worker");
    let list = || -> SessionList {
        let run = bench(h, &["sessions", "--all", "--workspace", &ws_arg]);
        assert_eq!(run.code, 0, "stderr: {}", run.stderr);
        let raw: serde_json::Value = serde_json::from_str(&run.stdout).unwrap();
        assert!(
            raw["rows"]
                .as_array()
                .unwrap()
                .iter()
                .all(|r| r.as_object().unwrap().contains_key("mail")),
            "every row says, even when the answer is null: {}",
            run.stdout
        );
        serde_json::from_value(raw).unwrap()
    };
    let send = |to: &str| -> String {
        let run = bench(h, &["mail", "send", "--to", to, "--body", "x"]);
        assert_eq!(run.code, 0, "stderr: {}", run.stderr);
        json_of(&run)["wake"].as_str().unwrap().to_string()
    };
    let inbox = |handle: &str| {
        fs::read_dir(h.join(".bench/mail").join(handle).join("inbox"))
            .map(|d| d.count())
            .unwrap_or(0)
    };

    let live = list();
    assert_eq!(live.rows.len(), 1, "{:?}", live.rows);
    assert_eq!(
        live.rows[0].mail,
        Some(MailAddress {
            handle: "worker".into(),
            // A pi session has no channel benchd can start a turn through yet: its mail
            // waits for its next prompt or model call.
            wakeable: false,
            unread: 0
        })
    );
    assert_eq!(
        live.operator,
        MailAddress {
            handle: "operator".into(),
            wakeable: false,
            unread: 0
        }
    );
    // wakeable is what a send does: next-turn for both, as neither can be started.
    assert_eq!(send("worker"), "next-turn");
    assert_eq!(send("operator"), "next-turn");
    assert_eq!(list().operator.unread, 1);

    // The worker dies. Its finished row keeps the address, and the send agrees it will not
    // be woken.
    libc_kill(pid);
    wait_until("the worker is dead", Duration::from_secs(5), || {
        json_of(&bench(h, &["sessions"]))["sessions"][0]["live"] == false
    });
    let pi_dir = h
        .join(".pi/agent/sessions")
        .join(bench_sessions::pi::dir_name(&ws_arg));
    fs::create_dir_all(&pi_dir).unwrap();
    fs::write(
        pi_dir.join(format!("2026-09-25T10-00-00-000Z_{runtime}.jsonl")),
        serde_json::json!({"type": "session", "version": 3, "id": runtime, "cwd": ws_arg})
            .to_string()
            + "\n",
    )
    .unwrap();
    assert_eq!(send("worker"), "next-turn");
    let dead = list();
    assert_eq!(dead.rows.len(), 1, "{:?}", dead.rows);
    assert_eq!(dead.rows[0].id, runtime);
    assert!(!dead.rows[0].state.is_running());
    assert_eq!(
        dead.rows[0].mail,
        Some(MailAddress {
            handle: "worker".into(),
            wakeable: false,
            unread: inbox("worker"),
        })
    );
    assert!(inbox("worker") >= 1, "the last send waits unread");

    // The mailbox outlives the session in the daemon's memory: closed, then across a restart,
    // the finished row still says where its mail waits.
    let session = json_of(&bench(h, &["sessions"]))["sessions"][0]["session"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(bench(h, &["close", &session]).code, 0);
    assert_eq!(list().rows, dead.rows, "closed: the row is unchanged");
    drop(daemon);
    let _daemon = DaemonGuard::start_with_fake_pi(h);
    assert_eq!(list().rows, dead.rows, "restarted: the row is unchanged");
}

#[test]
fn mail_to_a_handle_nobody_hosts_waits_in_the_record() {
    let home = TestHome::claim("ghostmail");
    let _daemon = DaemonGuard::start(&home.dir, None);
    let send = bench(
        &home.dir,
        &[
            "mail",
            "send",
            "--to",
            "ghost",
            "--body",
            "hello there",
            "--subject",
            "hi",
        ],
    );
    assert_eq!(send.code, 0, "stderr: {}", send.stderr);
    let sent: serde_json::Value = serde_json::from_str(&send.stdout).unwrap();
    assert_eq!(
        sent["wake"], "next-turn",
        "honest: nothing will wake a ghost"
    );
    let id = sent["id"].as_str().unwrap().to_string();

    // Pull is metadata-only: the listing must never carry the body.
    let list = bench(&home.dir, &["mail", "list", "--handle", "ghost"]);
    assert_eq!(list.code, 0);
    assert!(list.stdout.contains("\"unread\": true"));
    assert!(
        !list.stdout.contains("hello there"),
        "bodies never ride a listing"
    );

    // Read = body + retirement; retire-never-delete.
    let read = bench(&home.dir, &["mail", "read", &id, "--handle", "ghost"]);
    assert_eq!(read.code, 0, "stderr: {}", read.stderr);
    assert!(read.stdout.contains("hello there"));
    assert!(
        read.stdout.contains("/read/"),
        "the response names where it lives now"
    );
    let mailbox = home.dir.join(".bench/mail/ghost");
    assert!(mailbox.join("read").join(format!("{id}.md")).exists());
    assert_eq!(
        fs::read_dir(mailbox.join("inbox")).unwrap().count(),
        0,
        "moved, not copied — and never deleted"
    );

    let relist = bench(&home.dir, &["mail", "list", "--handle", "ghost"]);
    assert!(relist.stdout.contains("\"unread\": false"));
}

#[test]
fn mail_sent_before_a_restart_survives_mail_sent_after_it() {
    // #399: the id counter began again at m1 on every boot and the write replaced the file,
    // so the first send after a restart overwrote unread mail from before it.
    let home = TestHome::claim("restartmail");
    let h = &home.dir;
    let send = |body: &str| -> String {
        let run = bench(h, &["mail", "send", "--to", "ghost", "--body", body]);
        assert_eq!(run.code, 0, "stderr: {}", run.stderr);
        json_of(&run)["id"].as_str().unwrap().to_string()
    };
    let daemon = DaemonGuard::start(h, None);
    let first = send("before the restart");
    drop(daemon);
    let daemon = DaemonGuard::start(h, None);
    let second = send("after the restart");
    assert_ne!(first, second, "an id is never handed out twice");
    let inbox = h.join(".bench/mail/ghost/inbox");
    for (id, body) in [
        (&first, "before the restart"),
        (&second, "after the restart"),
    ] {
        let text = fs::read_to_string(inbox.join(format!("{id}.md")))
            .unwrap_or_else(|e| panic!("{id} is gone: {e}"));
        assert!(text.ends_with(&format!("{body}\n")), "{id}: {text}");
    }

    // A file already at the next id (planted behind the daemon's back) is never replaced:
    // the send fails loudly, exit 4, and the planted file is untouched.
    let n: u64 = second.trim_start_matches('m').parse().unwrap();
    let planted = inbox.join(format!("m{}.md", n + 1));
    fs::write(&planted, "planted").unwrap();
    let run = bench(h, &["mail", "send", "--to", "ghost", "--body", "third"]);
    assert_eq!(run.code, 4, "stdout: {} stderr: {}", run.stdout, run.stderr);
    assert!(
        run.stderr.contains("refusing to overwrite"),
        "{}",
        run.stderr
    );
    assert_eq!(fs::read_to_string(&planted).unwrap(), "planted");
    drop(daemon);
}

#[test]
fn mail_read_refuses_an_id_that_is_a_path_and_reads_nothing() {
    // #402: the id was joined onto the mailbox path unchecked, so `..` read another
    // mailbox's message.
    let home = TestHome::claim("readpath");
    let h = &home.dir;
    let _daemon = DaemonGuard::start(h, None);
    let sent = bench(h, &["mail", "send", "--to", "other", "--body", "not yours"]);
    assert_eq!(sent.code, 0, "stderr: {}", sent.stderr);
    let id = json_of(&sent)["id"].as_str().unwrap().to_string();
    let other = h.join(".bench/mail/other/inbox").join(format!("{id}.md"));
    // `me` has read mail before, so its `read/` exists and `read/../../other/…` resolves.
    let own = bench(h, &["mail", "send", "--to", "me", "--body", "mine"]);
    let own_id = json_of(&own)["id"].as_str().unwrap().to_string();
    assert_eq!(
        bench(h, &["mail", "read", &own_id, "--handle", "me"]).code,
        0
    );

    for bad in [
        format!("../../other/inbox/{id}"),
        format!("x/{id}"),
        "..".into(),
        "".into(),
    ] {
        let run = bench(h, &["mail", "read", &bad, "--handle", "me"]);
        assert_eq!(
            run.code, 3,
            "{bad:?}: stdout {} stderr {}",
            run.stdout, run.stderr
        );
        assert!(
            run.stdout.trim().is_empty(),
            "{bad:?} read something: {}",
            run.stdout
        );
        assert!(
            run.stderr.contains("not a message id"),
            "{bad:?}: {}",
            run.stderr
        );
    }
    assert!(
        other.exists(),
        "the other mailbox's message is still unread where it was"
    );

    // A hand-written name is still a message id.
    let inbox = h.join(".bench/mail/me/inbox");
    fs::create_dir_all(&inbox).unwrap();
    fs::write(inbox.join("note.md"), "by hand").unwrap();
    let run = bench(h, &["mail", "read", "note", "--handle", "me"]);
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    assert!(run.stdout.contains("by hand"));
}

#[test]
fn the_operator_handle_is_addressable_but_never_claimable() {
    let home = TestHome::claim("oper");
    let _daemon = DaemonGuard::start(&home.dir, None);
    let claim = bench(
        &home.dir,
        &[
            "spawn",
            "--agent",
            "test-echo",
            "--cwd",
            "/tmp",
            "--name",
            "operator",
        ],
    );
    assert_eq!(claim.code, 3, "stderr: {}", claim.stderr);
    assert!(
        claim.stderr.contains("operator"),
        "the refusal names the reservation: {}",
        claim.stderr
    );
    let send = bench(
        &home.dir,
        &["mail", "send", "--to", "operator", "--body", "for you"],
    );
    assert_eq!(send.code, 0, "addressable: {}", send.stderr);
}

#[test]
fn a_claimed_handle_refuses_a_second_claim_and_a_path_is_not_a_handle() {
    let home = TestHome::claim("dupes");
    let _daemon = DaemonGuard::start(&home.dir, None);
    let a = bench(
        &home.dir,
        &[
            "spawn",
            "--agent",
            "test-echo",
            "--cwd",
            "/tmp",
            "--name",
            "worker",
        ],
    );
    assert_eq!(a.code, 0);
    let b = bench(
        &home.dir,
        &[
            "spawn",
            "--agent",
            "test-echo",
            "--cwd",
            "/tmp",
            "--name",
            "worker",
        ],
    );
    assert_eq!(b.code, 3, "stderr: {}", b.stderr);
    assert!(b.stderr.contains("already claimed"));
    let c = bench(
        &home.dir,
        &["mail", "send", "--to", "../escape", "--body", "x"],
    );
    assert_eq!(c.code, 3, "stderr: {}", c.stderr);
}

#[test]
fn the_bench_mail_skills_snippets_execute_against_a_real_daemon() {
    // The house rule: a documented snippet is executed, never restated — a test that
    // retypes it is a second copy that drifts (helm's mail-skill gate, ported). Every
    // ```bash fence in SKILL.md runs in order, as operator, against a throwaway root.
    let skill = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.claude/skills/bench-mail/SKILL.md"),
    )
    .expect("bench-mail SKILL.md readable");
    let mut snippets: Vec<String> = Vec::new();
    let mut current: Option<String> = None;
    for line in skill.lines() {
        match (&mut current, line.trim()) {
            (None, "```bash") => current = Some(String::new()),
            (Some(buf), "```") => {
                snippets.push(std::mem::take(buf));
                current = None;
            }
            (Some(buf), _) => {
                buf.push_str(line);
                buf.push('\n');
            }
            _ => {}
        }
    }
    assert!(
        snippets.len() >= 3,
        "the skill's send/list/read snippets exist"
    );

    let home = TestHome::claim("skill");
    let _daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    let root = home.dir.join(".bench");
    // The snippets run from inside a workspace holding one live bench session, so "who can I
    // mail" has somebody to find besides the operator.
    let ws = workspace(&home.dir);
    spawn_pi(&home.dir, &ws, "worker");
    let mut who = None;
    for (i, snippet) in snippets.iter().enumerate() {
        let out = isolated("bash")
            .args(["-euo", "pipefail", "-c", snippet])
            .current_dir(&ws)
            .env("HOME", &home.dir)
            .env("BENCH_DIR", &root)
            .env("BENCH", bench_bin())
            .output()
            .expect("run snippet");
        assert!(
            out.status.success(),
            "SKILL.md snippet {} failed (exit {:?}):\n{}\n--- stderr:\n{}",
            i + 1,
            out.status.code(),
            snippet,
            String::from_utf8_lossy(&out.stderr)
        );
        if snippet.contains("sessions --all") {
            who = Some(String::from_utf8_lossy(&out.stdout).into_owned());
        }
    }
    let who = who.expect("the skill's who-can-I-mail snippet");
    let handles: Vec<&str> = who
        .lines()
        .filter_map(|l| l.split_whitespace().next())
        .collect();
    assert_eq!(
        handles,
        ["operator", "worker"],
        "the operator and the live session: {who}"
    );
    assert!(who.contains("worker not-wakeable"), "{who}");
    // The sequence is the story the skill tells: a send exists, the listing shows it
    // or its retirement, and the read snippet retired it.
    let listing = bench(&home.dir, &["mail", "list", "--handle", "operator"]);
    assert!(
        listing.stdout.contains("\"unread\": false"),
        "the read snippet retired the sent message: {}",
        listing.stdout
    );

    // With no daemon, the read snippet must fail with bench's own code — never exit 0 and
    // look like an empty inbox, which is what an agent would then report.
    // The same for the who-can-I-mail snippet: an empty list is not "nobody to mail".
    drop(_daemon);
    for needle in ["mail read", "sessions --all"] {
        let snippet = snippets
            .iter()
            .find(|s| s.contains(needle))
            .expect("the skill's snippet");
        let out = isolated("bash")
            .args(["-c", snippet])
            .current_dir(&ws)
            .env("HOME", &home.dir)
            .env("BENCH_DIR", &root)
            .env("BENCH", bench_bin())
            .output()
            .expect("run snippet");
        assert_eq!(
            out.status.code(),
            Some(2),
            "{needle}: no daemon reaches the caller as exit 2: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(String::from_utf8_lossy(&out.stdout).trim().is_empty());
    }
}

// ---------------------------------------------------------------------------
// The shared browser (#350): a fake Chromium, so the gate needs no browser
// ---------------------------------------------------------------------------

/// A stand-in for Chromium that keeps the two promises benchd relies on: `--version`
/// answers with a version line, and once "listening" it writes `DevToolsActivePort`
/// into its `--user-data-dir`. It records its argv there, dies on TERM, and with
/// `--die-after=<s>` crashes by itself — a profile that takes Chromium down on launch.
/// `--slow-start=<s>` holds off "listening" that long, so a launch can be caught in flight.
fn write_fake_browser(home: &Path) -> PathBuf {
    let path = home.join("fake-chromium");
    fs::write(
        &path,
        r#"#!/bin/sh
if [ "$1" = "--version" ]; then echo "Fake Chromium 142.0.7000.1"; exit 0; fi
dir=""; die=""
for a in "$@"; do
  case "$a" in
    --user-data-dir=*) dir="${a#--user-data-dir=}" ;;
    --die-after=*) die="${a#--die-after=}" ;;
    --slow-start=*) sleep "${a#--slow-start=}" ;;
  esac
done
printf '%s\n' "$@" > "$dir/argv"
trap 'exit 0' TERM
printf '%s\n/devtools/browser/fake-%s\n' "$(( $$ % 40000 + 20000 ))" "$$" > "$dir/port.tmp"
mv "$dir/port.tmp" "$dir/DevToolsActivePort"
if [ -n "$die" ]; then sleep "$die"; exit 1; fi
while :; do sleep 0.1; done
"#,
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn write_browser_config(home: &Path, config: serde_json::Value) {
    let dir = home.join(".bench/browser");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("config.json"), config.to_string()).unwrap();
}

fn json_of(run: &CliRun) -> serde_json::Value {
    serde_json::from_str(&run.stdout)
        .unwrap_or_else(|e| panic!("not JSON ({e}): {} / {}", run.stdout, run.stderr))
}

fn event_kinds(home: &Path) -> Vec<(String, serde_json::Value)> {
    let run = bench(home, &["events"]);
    json_of(&run)["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| (e["kind"].as_str().unwrap().to_string(), e["data"].clone()))
        .collect()
}

fn wait_until(what: &str, deadline: Duration, mut done: impl FnMut() -> bool) {
    let end = Instant::now() + deadline;
    while !done() {
        assert!(Instant::now() < end, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn browser_start_publishes_the_endpoint_it_logged_and_a_second_start_finds_it() {
    let home = TestHome::claim("brstart");
    let fake = write_fake_browser(&home.dir);
    write_browser_config(&home.dir, serde_json::json!({ "binary": fake }));
    let _daemon = DaemonGuard::start(&home.dir, None);

    let run = bench(&home.dir, &["browser", "start"]);
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    let answer = json_of(&run);
    assert_eq!(answer["already_running"], false);
    assert_eq!(answer["format"], "bench.browser-endpoint");
    let port = answer["port"].as_u64().unwrap();
    assert_eq!(answer["cdp"], format!("http://127.0.0.1:{port}"));
    assert!(
        answer["ws"]
            .as_str()
            .unwrap()
            .starts_with(&format!("ws://127.0.0.1:{port}/devtools/browser/"))
    );

    // The file is the same fact the answer reported — helm and agents read it, not us.
    let endpoint_path = home.dir.join(".bench/browser/endpoint.json");
    let mut on_disk: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&endpoint_path).unwrap()).unwrap();
    on_disk["already_running"] = serde_json::json!(false);
    on_disk["mode"] = serde_json::json!("headless");
    assert_eq!(on_disk, answer);

    // helm reads this file from Swift and cannot import the Rust type, so both sides test
    // against one checked-in sample: the keys written here are exactly the fixture's, and
    // helm's BrowserEndpointTests decodes the same file.
    let fixture: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/browser-endpoint.json"),
        )
        .expect("daemon/fixtures/browser-endpoint.json"),
    )
    .unwrap();
    let keys = |v: &serde_json::Value| {
        let mut k: Vec<String> = v.as_object().unwrap().keys().cloned().collect();
        k.sort();
        k
    };
    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&endpoint_path).unwrap()).unwrap();
    assert_eq!(
        keys(&written),
        keys(&fixture),
        "endpoint.json drifted from the fixture helm reads"
    );
    serde_json::from_value::<bench_wire::BrowserEndpoint>(fixture)
        .expect("the fixture is a real endpoint");
    let typed: bench_wire::BrowserEndpoint =
        serde_json::from_value(written).expect("what the daemon writes decodes as the type");
    assert_eq!(typed.version, bench_wire::BROWSER_ENDPOINT_VERSION);

    // Logged before it was answered.
    let started: Vec<_> = event_kinds(&home.dir)
        .into_iter()
        .filter(|(k, _)| k == "browser/started")
        .collect();
    assert_eq!(started.len(), 1);
    assert_eq!(started[0].1["pid"], answer["pid"]);

    // Default flags: a normal Chrome UA at the binary's own major, headless; then the
    // daemon's own flags, last so they win.
    let profile = home.dir.join(".bench/browser/profile");
    let argv = fs::read_to_string(profile.join("argv")).unwrap();
    let argv: Vec<&str> = argv.lines().collect();
    assert!(argv.contains(&"--headless=new"), "{argv:?}");
    let ua = argv
        .iter()
        .find(|a| a.starts_with("--user-agent="))
        .unwrap();
    assert!(
        ua.contains("Chrome/142.0.0.0") && !ua.contains("Headless"),
        "{ua}"
    );
    assert_eq!(
        &argv[argv.len() - 6..],
        &[
            format!("--user-data-dir={}", profile.display()).as_str(),
            "--remote-debugging-port=0",
            "--no-first-run",
            "--no-default-browser-check",
            // A test HOME is not the account's own: a Chrome here must never go looking
            // for a login keychain (the dialog that offers to reset the real ones).
            "--use-mock-keychain",
            "--password-store=basic",
        ]
    );

    let again = bench(&home.dir, &["browser", "start"]);
    assert_eq!(again.code, 0, "stderr: {}", again.stderr);
    let again = json_of(&again);
    assert_eq!(again["already_running"], true);
    assert_eq!(again["pid"], answer["pid"], "one browser per root");

    let status = json_of(&bench(&home.dir, &["browser", "status"]));
    assert_eq!(status["running"], true);
    assert_eq!(status["pid"], answer["pid"]);
}

#[test]
fn configured_args_replace_the_defaults_but_never_the_daemons_own_flags() {
    let home = TestHome::claim("brargs");
    let fake = write_fake_browser(&home.dir);
    write_browser_config(
        &home.dir,
        serde_json::json!({ "binary": fake, "args": ["--remote-debugging-port=9222", "--kiosk"] }),
    );
    let _daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(&home.dir, &["browser", "start"]);
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    let argv = fs::read_to_string(home.dir.join(".bench/browser/profile/argv")).unwrap();
    let argv: Vec<&str> = argv.lines().collect();
    assert_eq!(argv[..2], ["--remote-debugging-port=9222", "--kiosk"]);
    assert!(
        !argv.iter().any(|a| a.starts_with("--user-agent")),
        "{argv:?}"
    );
    assert_eq!(argv.last(), Some(&"--password-store=basic"));
    assert!(
        argv.contains(&"--remote-debugging-port=0"),
        "the daemon's port flag comes after and wins"
    );
}

#[test]
fn browser_stop_and_daemon_stop_each_leave_no_browser_and_no_endpoint() {
    let home = TestHome::claim("brstop");
    let fake = write_fake_browser(&home.dir);
    write_browser_config(&home.dir, serde_json::json!({ "binary": fake }));
    let _daemon = DaemonGuard::start(&home.dir, None);
    let endpoint = home.dir.join(".bench/browser/endpoint.json");

    let pid = json_of(&bench(&home.dir, &["browser", "start"]))["pid"]
        .as_u64()
        .unwrap() as i32;
    let stop = bench(&home.dir, &["browser", "stop"]);
    assert_eq!(stop.code, 0, "stderr: {}", stop.stderr);
    assert_eq!(json_of(&stop)["was_running"], true);
    assert!(
        !libc_alive(pid),
        "browser/stop answered before the browser was gone"
    );
    assert!(
        !endpoint.exists(),
        "an endpoint must not name a stopped browser"
    );
    assert!(
        event_kinds(&home.dir)
            .iter()
            .any(|(k, d)| k == "browser/stopped" && d["pid"] == pid)
    );
    // Nothing restarted it: a stop is not a crash.
    std::thread::sleep(Duration::from_millis(900));
    assert_eq!(
        json_of(&bench(&home.dir, &["browser", "status"]))["running"],
        false
    );
    assert_eq!(
        json_of(&bench(&home.dir, &["browser", "stop"]))["was_running"],
        false
    );

    let pid = json_of(&bench(&home.dir, &["browser", "start"]))["pid"]
        .as_u64()
        .unwrap() as i32;
    assert_eq!(bench(&home.dir, &["stop"]).code, 0);
    wait_until(
        "the browser to die with the daemon's stop",
        Duration::from_secs(8),
        || !libc_alive(pid),
    );
    // The wrapper removes the file after its browser exits, a moment after the pid goes.
    wait_until("the endpoint to be removed", Duration::from_secs(2), || {
        !endpoint.exists()
    });
}

#[test]
fn a_killed_daemon_takes_its_browser_with_it() {
    // The #291 rule made mechanical: no cleanup code runs when a daemon is SIGKILLed,
    // so only the leash can do this.
    let home = TestHome::claim("brleash");
    let fake = write_fake_browser(&home.dir);
    write_browser_config(&home.dir, serde_json::json!({ "binary": fake }));
    let mut daemon = DaemonGuard::start(&home.dir, None);
    let pid = json_of(&bench(&home.dir, &["browser", "start"]))["pid"]
        .as_u64()
        .unwrap() as i32;
    assert!(libc_alive(pid));

    let _ = daemon.child.kill();
    let _ = daemon.child.wait();
    wait_until(
        "the browser to die with its daemon",
        Duration::from_secs(5),
        || !libc_alive(pid),
    );
    wait_until("the endpoint to be removed", Duration::from_secs(2), || {
        !home.dir.join(".bench/browser/endpoint.json").exists()
    });
}

#[test]
fn a_crashed_browser_is_restarted_and_a_crash_loop_gives_up() {
    let home = TestHome::claim("brcrash");
    let fake = write_fake_browser(&home.dir);
    write_browser_config(&home.dir, serde_json::json!({ "binary": fake }));
    let _daemon = DaemonGuard::start(&home.dir, None);
    let first = json_of(&bench(&home.dir, &["browser", "start"]))["pid"]
        .as_u64()
        .unwrap();
    libc_kill(first as i32);
    let mut second = 0;
    wait_until("a restarted browser", Duration::from_secs(8), || {
        let s = json_of(&bench(&home.dir, &["browser", "status"]));
        second = s["pid"].as_u64().unwrap_or(0);
        s["running"] == true && second != first
    });
    let events = event_kinds(&home.dir);
    assert!(
        events
            .iter()
            .any(|(k, d)| k == "browser/exited" && d["pid"] == first && d["restarting"] == true),
        "{events:?}"
    );
    assert!(
        events
            .iter()
            .any(|(k, d)| k == "browser/started" && d["pid"] == second && d["restart"] == 1),
        "{events:?}"
    );
    let _ = bench(&home.dir, &["browser", "stop"]);

    // A browser that dies on every launch is relaunched three times, then left down.
    write_browser_config(
        &home.dir,
        serde_json::json!({ "binary": fake, "args": ["--die-after=0.3"] }),
    );
    assert_eq!(bench(&home.dir, &["browser", "start"]).code, 0);
    wait_until("the crash loop to give up", Duration::from_secs(15), || {
        event_kinds(&home.dir)
            .iter()
            .any(|(k, _)| k == "browser/gave-up")
    });
    let restarts = event_kinds(&home.dir)
        .iter()
        .filter(|(k, d)| k == "browser/started" && d["restart"].as_u64().unwrap_or(0) > 0)
        .count();
    assert_eq!(
        restarts,
        1 + 3,
        "one restart from the first half, three from the loop"
    );
    std::thread::sleep(Duration::from_millis(900));
    assert_eq!(
        json_of(&bench(&home.dir, &["browser", "status"]))["running"],
        false
    );
}

#[test]
fn a_browser_config_or_binary_that_cannot_work_is_refused_naming_the_fix() {
    let home = TestHome::claim("brrefuse");
    let _daemon = DaemonGuard::start(&home.dir, None);

    // "No browser anywhere" is a unit test in bench-browser: this machine may well have
    // Google Chrome installed, and a conformance test must not launch the real thing.
    write_browser_config(&home.dir, serde_json::json!({ "binnary": "/x" }));
    let typo = bench(&home.dir, &["browser", "start"]);
    assert_eq!(typo.code, 3, "stderr: {}", typo.stderr);
    assert!(typo.stderr.contains("config.json"), "{}", typo.stderr);

    write_browser_config(
        &home.dir,
        serde_json::json!({ "binary": "/no/such/chrome" }),
    );
    let missing = bench(&home.dir, &["browser", "start"]);
    assert_eq!(missing.code, 3, "stderr: {}", missing.stderr);
    assert!(
        missing.stderr.contains("/no/such/chrome"),
        "{}",
        missing.stderr
    );

    let failed = event_kinds(&home.dir)
        .iter()
        .filter(|(k, _)| k == "browser/failed")
        .count();
    assert_eq!(failed, 2, "a refused start is still on the record");
    assert_eq!(
        json_of(&bench(&home.dir, &["browser", "status"]))["running"],
        false
    );
}

#[test]
fn an_endpoint_left_by_a_dead_daemon_is_cleared_at_boot_and_logged() {
    let home = TestHome::claim("brstale");
    let dir = home.dir.join(".bench/browser");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("endpoint.json"), r#"{"cdp":"http://127.0.0.1:1"}"#).unwrap();
    let _daemon = DaemonGuard::start(&home.dir, None);
    assert!(!dir.join("endpoint.json").exists());
    assert!(
        event_kinds(&home.dir)
            .iter()
            .any(|(k, _)| k == "browser/cleared")
    );
}

/// The pid of a running browser, once the daemon reports one.
fn await_browser(home: &Path, what: &str) -> u64 {
    let mut pid = 0;
    wait_until(what, Duration::from_secs(8), || {
        let s = json_of(&bench(home, &["browser", "status"]));
        pid = s["pid"].as_u64().unwrap_or(0);
        s["running"] == true
    });
    pid
}

#[test]
fn a_wanted_browser_comes_back_with_the_next_daemon() {
    // #407: launchd brings benchd back after a crash or a reboot, and the browser has to
    // come with it — benchd decides that from `<root>/browser/wanted`, not the plist.
    let home = TestHome::claim("brback");
    let fake = write_fake_browser(&home.dir);
    write_browser_config(&home.dir, serde_json::json!({ "binary": fake }));
    let marker = home.dir.join(".bench/browser/wanted");

    let mut daemon = DaemonGuard::start(&home.dir, None);
    let first = json_of(&bench(&home.dir, &["browser", "start"]))["pid"]
        .as_u64()
        .unwrap();
    assert!(marker.exists(), "a started browser is marked wanted");

    // A crash: no cleanup runs, the leash takes the browser down.
    let _ = daemon.child.kill();
    let _ = daemon.child.wait();
    wait_until(
        "the browser to die with its daemon",
        Duration::from_secs(5),
        || !libc_alive(first as i32),
    );
    let mut daemon = DaemonGuard::start(&home.dir, None);
    let second = await_browser(&home.dir, "the browser after a crash");
    assert_ne!(second, first);
    assert!(
        event_kinds(&home.dir)
            .iter()
            .any(|(k, d)| k == "browser/resuming" && d["marker"] == marker.display().to_string()),
        "a browser nobody asked this daemon for says why it started"
    );

    // A clean `bench stop` is not `bench browser stop`: the browser is still wanted.
    assert_eq!(bench(&home.dir, &["stop"]).code, 0);
    let _ = daemon.child.wait();
    assert!(marker.exists());
    let _daemon = DaemonGuard::start(&home.dir, None);
    let third = await_browser(&home.dir, "the browser after a daemon stop");
    assert_ne!(third, second);
}

#[test]
fn a_stopped_browser_stays_stopped_across_a_restart() {
    let home = TestHome::claim("brgone");
    let fake = write_fake_browser(&home.dir);
    write_browser_config(&home.dir, serde_json::json!({ "binary": fake }));
    let marker = home.dir.join(".bench/browser/wanted");

    let mut daemon = DaemonGuard::start(&home.dir, None);
    assert_eq!(bench(&home.dir, &["browser", "start"]).code, 0);
    assert_eq!(bench(&home.dir, &["browser", "stop"]).code, 0);
    assert!(
        !marker.exists(),
        "browser/stop is the one thing that unwants it"
    );
    let _ = daemon.child.kill();
    let _ = daemon.child.wait();

    let _daemon = DaemonGuard::start(&home.dir, None);
    std::thread::sleep(Duration::from_millis(900));
    assert_eq!(
        json_of(&bench(&home.dir, &["browser", "status"]))["running"],
        false
    );
    let events = event_kinds(&home.dir);
    let boot = events
        .iter()
        .rposition(|(k, _)| k == "daemon/started")
        .unwrap();
    assert!(
        !events[boot..]
            .iter()
            .any(|(k, _)| k == "browser/started" || k == "browser/resuming"),
        "{events:?}"
    );
}

#[test]
fn a_stop_that_lands_during_a_launch_still_unwants_the_browser() {
    // The launch a restart makes routine: benchd comes back, starts the wanted browser, and
    // `bench browser stop` arrives before it is up. The stop waits for the launch and takes the
    // browser down; the marker must go with it, or the next daemon brings it back.
    let home = TestHome::claim("brrace");
    let fake = write_fake_browser(&home.dir);
    write_browser_config(
        &home.dir,
        serde_json::json!({ "binary": fake, "args": ["--slow-start=1.5"] }),
    );
    let marker = home.dir.join(".bench/browser/wanted");
    let mut daemon = DaemonGuard::start(&home.dir, None);

    let starter = {
        let home = home.dir.clone();
        std::thread::spawn(move || bench(&home, &["browser", "start"]))
    };
    std::thread::sleep(Duration::from_millis(400));
    let stop = bench(&home.dir, &["browser", "stop"]);
    assert_eq!(stop.code, 0, "stderr: {}", stop.stderr);
    assert_eq!(starter.join().unwrap().code, 0);
    assert_eq!(
        json_of(&stop)["was_running"],
        true,
        "the stop waited for the launch"
    );
    assert!(!marker.exists(), "a stopped browser is not wanted");

    let _ = daemon.child.kill();
    let _ = daemon.child.wait();
    let _daemon = DaemonGuard::start(&home.dir, None);
    std::thread::sleep(Duration::from_millis(900));
    assert_eq!(
        json_of(&bench(&home.dir, &["browser", "status"]))["running"],
        false
    );
}

#[test]
fn setup_opens_the_profile_in_a_plain_window_and_quitting_it_returns_to_headless() {
    let home = TestHome::claim("brsetup");
    let fake = write_fake_browser(&home.dir);
    // Configured args are headless flags; setup must not take them either.
    write_browser_config(
        &home.dir,
        serde_json::json!({ "binary": fake, "args": ["--headless=new", "--user-agent=spoofed"] }),
    );
    let _daemon = DaemonGuard::start(&home.dir, None);
    let argv_path = home.dir.join(".bench/browser/profile/argv");

    let headless = json_of(&bench(&home.dir, &["browser", "start"]));
    assert_eq!(headless["mode"], "headless");
    let headless_pid = headless["pid"].as_u64().unwrap() as i32;

    // Setup takes the running browser down and brings the profile up in a window.
    fs::remove_file(&argv_path).unwrap();
    let setup = bench(&home.dir, &["browser", "setup"]);
    assert_eq!(setup.code, 0, "stderr: {}", setup.stderr);
    let setup = json_of(&setup);
    assert_eq!(setup["mode"], "setup");
    assert!(!libc_alive(headless_pid));
    // A plain Chrome on the same profile: Google refuses sign-in to one carrying the
    // headless browser's user agent, remote-allow-origins or a debugging port (#374).
    // Setup answers once it has the pid — there is no port to wait for — so the fake may
    // not have recorded its argv yet (removed above so the headless one cannot be read).
    let profile = home.dir.join(".bench/browser/profile");
    let mut argv = String::new();
    wait_until("the setup browser's argv", Duration::from_secs(5), || {
        argv = fs::read_to_string(&argv_path).unwrap_or_default();
        argv.ends_with('\n')
    });
    assert_eq!(
        argv.lines().collect::<Vec<_>>(),
        [
            format!("--user-data-dir={}", profile.display()).as_str(),
            "--no-first-run",
            "--no-default-browser-check",
            "--use-mock-keychain",
            "--password-store=basic",
        ],
        "setup runs with the profile flags and nothing else"
    );
    assert!(
        !home.dir.join(".bench/browser/endpoint.json").exists(),
        "a setup browser has no address, so no endpoint names it"
    );

    // While the operator is in that window, `start` must not hand it to an agent as "the
    // shared browser" — it refuses and says what brings the headless browser back.
    let meanwhile = bench(&home.dir, &["browser", "start"]);
    assert_eq!(meanwhile.code, 3, "stderr: {}", meanwhile.stderr);
    assert!(meanwhile.stderr.contains("setup"), "{}", meanwhile.stderr);
    let during = json_of(&bench(&home.dir, &["browser", "status"]));
    assert_eq!(during["mode"], "setup");
    assert_eq!(during["pid"], setup["pid"]);
    assert!(
        during.get("cdp").is_none() && during.get("ws").is_none(),
        "{during}"
    );

    // The operator quits the window (Cmd-Q is a clean exit; TERM is how the fake gets one).
    let setup_pid = setup["pid"].as_u64().unwrap() as i32;
    unsafe {
        kill(setup_pid, 15);
    }
    let mut back = serde_json::Value::Null;
    wait_until(
        "the browser to come back headless",
        Duration::from_secs(8),
        || {
            back = json_of(&bench(&home.dir, &["browser", "status"]));
            back["running"] == true && back["pid"].as_u64() != Some(setup_pid as u64)
        },
    );
    assert_eq!(back["mode"], "headless");
    assert!(
        fs::read_to_string(&argv_path)
            .unwrap()
            .contains("--remote-debugging-port=0")
    );
    assert!(home.dir.join(".bench/browser/endpoint.json").exists());
    assert!(
        event_kinds(&home.dir)
            .iter()
            .any(|(k, d)| k == "browser/exited" && d["mode"] == "setup" && d["pid"] == setup_pid),
        "the quit is on the record"
    );
}

#[test]
fn the_bench_browser_skills_snippets_execute_against_a_real_daemon() {
    // The bench-mail rule: a documented snippet is executed, never restated. Every ```bash
    // fence in the skill runs against a throwaway daemon whose browser is the fake — the
    // ```text fences are Playwright's, which the gate does not have.
    let skill = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../.claude/skills/bench-browser/SKILL.md"),
    )
    .expect("bench-browser SKILL.md readable");
    let mut snippets: Vec<String> = Vec::new();
    let mut current: Option<String> = None;
    for line in skill.lines() {
        match (&mut current, line.trim()) {
            (None, "```bash") => current = Some(String::new()),
            (Some(buf), "```") => {
                snippets.push(std::mem::take(buf));
                current = None;
            }
            (Some(buf), _) => {
                buf.push_str(line);
                buf.push('\n');
            }
            _ => {}
        }
    }
    assert_eq!(
        snippets.len(),
        1,
        "the skill's one executable snippet: get the endpoint"
    );

    let home = TestHome::claim("brskill");
    let fake = write_fake_browser(&home.dir);
    write_browser_config(&home.dir, serde_json::json!({ "binary": fake }));
    let _daemon = DaemonGuard::start(&home.dir, None);
    let out = isolated("bash")
        .args(["-euo", "pipefail", "-c", &snippets[0]])
        .env("HOME", &home.dir)
        .env("BENCH_DIR", home.dir.join(".bench"))
        .env("BENCH", bench_bin())
        .output()
        .expect("run snippet");
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "snippet failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let status = json_of(&bench(&home.dir, &["browser", "status"]));
    assert_eq!(
        stdout.trim(),
        status["cdp"].as_str().unwrap(),
        "the snippet prints the endpoint playwright-cli attach takes"
    );

    // A refusal must reach the caller as bench's own exit code, not as an empty endpoint
    // piped onward — an agent that sees exit 0 and "" attaches to nothing.
    let _ = bench(&home.dir, &["browser", "stop"]);
    write_browser_config(
        &home.dir,
        serde_json::json!({ "binary": "/no/such/chrome" }),
    );
    let refused = isolated("bash")
        .args(["-c", &snippets[0]])
        .env("HOME", &home.dir)
        .env("BENCH_DIR", home.dir.join(".bench"))
        .env("BENCH", bench_bin())
        .output()
        .expect("run snippet");
    assert_eq!(
        refused.status.code(),
        Some(3),
        "the refusal's exit code survives the snippet: {}",
        String::from_utf8_lossy(&refused.stderr)
    );
    assert!(String::from_utf8_lossy(&refused.stdout).trim().is_empty());
}

// ---------------------------------------------------------------------------
// M4: the bench document — layout verbs, bench.json, events --follow
// ---------------------------------------------------------------------------

/// One layout verb over the raw socket, as helm (`by: operator`) or an agent (`by: None`).
/// Bounded: a daemon that stops answering is a failed assertion here, never a hung run.
fn layout(
    socket: &Path,
    verb: &str,
    args: serde_json::Value,
    by: Option<serde_json::Value>,
    asked: bool,
) -> serde_json::Value {
    let stream = UnixStream::connect(socket).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut req = serde_json::json!({ "id": "m4", "verb": verb, "args": args });
    if let Some(by) = by {
        req["by"] = by;
    }
    if asked {
        req["asked"] = serde_json::json!(true);
    }
    (&stream).write_all(format!("{req}\n").as_bytes()).unwrap();
    let mut reply = String::new();
    BufReader::new(&stream)
        .read_line(&mut reply)
        .unwrap_or_else(|e| panic!("{verb}: no answer ({e})"));
    serde_json::from_str(&reply).unwrap_or_else(|e| panic!("{verb}: {e}: {reply:?}"))
}

fn operator() -> Option<serde_json::Value> {
    Some(serde_json::json!({ "kind": "operator" }))
}

fn ok_data(reply: serde_json::Value) -> serde_json::Value {
    assert_eq!(reply["status"], "ok", "{reply}");
    reply["data"].clone()
}

fn log_of(root: &Path) -> Vec<serde_json::Value> {
    fs::read_to_string(root.join("events.jsonl"))
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

/// The operator's working bench: a workspace, a second terminal to the right, and a canvas.
/// Answers the pane ids: (first terminal, right terminal, canvas).
fn working_bench(socket: &Path) -> (String, String, String) {
    let first = ok_data(layout(
        socket,
        "workspace/open",
        serde_json::json!({ "path": "/tmp/m4-proof" }),
        operator(),
        false,
    ))["pane_created"]
        .as_str()
        .unwrap()
        .to_string();
    let right = ok_data(layout(
        socket,
        "pane/split",
        serde_json::json!({ "direction": "right" }),
        operator(),
        false,
    ))["pane_created"]
        .as_str()
        .unwrap()
        .to_string();
    let canvas = ok_data(layout(
        socket,
        "pane/open",
        serde_json::json!({ "surface": { "kind": "canvas", "source": { "kind": "file", "path": "/tmp/m4-proof/plan.md" } } }),
        operator(),
        false,
    ))["pane_created"]
        .as_str()
        .unwrap()
        .to_string();
    (first, right, canvas)
}

/// `fixtures/bench-report.json` is the sample helm's Swift decodes a layout answer and
/// `bench/get` against. The Rust gate pins its spelling from the types (`bench-wire`'s
/// `the_reply_fixture_round_trips`); this pins it against what a live daemon actually answers,
/// key for key, the way `browser-endpoint.json` is pinned — so the fixture cannot describe a
/// reply benchd no longer sends.
#[test]
fn the_reply_fixture_is_what_a_live_daemon_answers() {
    let home = TestHome::claim("m4-reply-fixture");
    let daemon = DaemonGuard::start(&home.dir, None);
    working_bench(&daemon.socket);
    let report = ok_data(layout(
        &daemon.socket,
        "pane/open",
        serde_json::json!({ "surface": { "kind": "canvas", "source": { "kind": "file", "path": "/tmp/m4-proof/review.md" } } }),
        operator(),
        false,
    ));
    let get = ok_data(layout(
        &daemon.socket,
        "bench/get",
        serde_json::Value::Null,
        None,
        false,
    ));

    let fixture: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/bench-report.json"),
        )
        .expect("daemon/fixtures/bench-report.json"),
    )
    .unwrap();
    let keys = |v: &serde_json::Value| {
        let mut k: Vec<String> = v
            .as_object()
            .unwrap_or_else(|| panic!("not an object: {v}"))
            .keys()
            .cloned()
            .collect();
        k.sort();
        k
    };
    assert_eq!(
        keys(&report),
        keys(&fixture["report"]),
        "a layout answer drifted from the fixture helm reads"
    );
    assert_eq!(keys(&get), keys(&fixture["get"]), "bench/get drifted");
    let live = &get["document"];
    let sample = &fixture["get"]["document"];
    assert_eq!(keys(live), keys(sample), "the document drifted");
    let (live, sample) = (&live["workspaces"][0], &sample["workspaces"][0]);
    assert_eq!(keys(live), keys(sample), "a workspace drifted");
    let (live, sample) = (&live["bench"], &sample["bench"]);
    assert_eq!(keys(live), keys(sample), "a bench drifted");
    let (live, sample) = (&live["columns"][0], &sample["columns"][0]);
    assert_eq!(keys(live), keys(sample), "a column drifted");
    let (live, sample) = (&live["slots"][0], &sample["slots"][0]);
    assert_eq!(keys(live), keys(sample), "a slot drifted");
    // An unnamed terminal on both sides: a name is written only when there is one.
    assert_eq!(
        keys(&live["panes"][0]),
        keys(&sample["panes"][1]),
        "a pane drifted"
    );
    serde_json::from_value::<bench_wire::LayoutReport>(report).expect("a LayoutReport");
    serde_json::from_value::<bench_wire::DocumentAt>(get).expect("a DocumentAt");
}

#[test]
fn a_whole_session_driven_through_the_socket_survives_a_daemon_restart() {
    let home = TestHome::claim("m4-session");
    let root = home.dir.join(".bench");
    let daemon = DaemonGuard::start(&home.dir, None);
    let (_, right, canvas) = working_bench(&daemon.socket);
    ok_data(layout(
        &daemon.socket,
        "pane/move",
        serde_json::json!({ "pane": canvas, "to": { "step": "left" } }),
        operator(),
        false,
    ));
    ok_data(layout(
        &daemon.socket,
        "pane/close",
        serde_json::json!({ "pane": right }),
        operator(),
        false,
    ));
    let before = ok_data(layout(
        &daemon.socket,
        "bench/get",
        serde_json::Value::Null,
        None,
        false,
    ));
    // What the daemon actually sends decodes as the wire types helm's client will read.
    serde_json::from_value::<bench_wire::DocumentAt>(before.clone())
        .expect("bench/get is a DocumentAt");
    drop(daemon);

    let daemon = DaemonGuard::start(&home.dir, None);
    let after = ok_data(layout(
        &daemon.socket,
        "bench/get",
        serde_json::Value::Null,
        None,
        false,
    ));
    assert_eq!(
        after, before,
        "bench.json brought the whole document back, seq and all"
    );

    // Files are the record: the file and the log, read with no daemon in the loop.
    let record: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(root.join("bench.json")).unwrap()).unwrap();
    assert_eq!(record["format"], "bench.document");
    assert_eq!(record["document"], before["document"]);
    let changes: Vec<_> = log_of(&root)
        .into_iter()
        .filter(|e| e["kind"] == "bench/changed")
        .collect();
    let verbs: Vec<_> = changes
        .iter()
        .map(|e| e["data"]["verb"].as_str().unwrap())
        .collect();
    assert_eq!(
        verbs,
        [
            "workspace/open",
            "pane/split",
            "pane/open",
            "pane/move",
            "pane/close"
        ],
        "every change is one event, in order"
    );
    assert!(
        changes
            .iter()
            .all(|e| e["data"]["by"]["kind"] == "operator"),
        "and each says who asked"
    );
    for change in &changes {
        let typed: bench_wire::DocumentChange = serde_json::from_value(change["data"].clone())
            .expect("a bench/changed event's data is a DocumentChange");
        assert_eq!(
            typed.report.seq, change["seq"],
            "the report names its own event"
        );
    }
    assert_eq!(
        record["seq"],
        changes.last().unwrap()["seq"],
        "the file names its event"
    );
}

#[test]
fn an_agent_rearranges_the_bench_and_never_moves_the_operators_focus() {
    let home = TestHome::claim("m4-focus");
    let daemon = DaemonGuard::start(&home.dir, None);
    let (first, right, canvas) = working_bench(&daemon.socket);
    // The operator is in the canvas they just opened.
    let held = canvas.clone();

    for (verb, args) in [
        (
            "pane/open",
            serde_json::json!({ "surface": { "kind": "canvas", "source": { "kind": "file", "path": "/tmp/m4-proof/tasks.md" } } }),
        ),
        ("pane/split", serde_json::json!({ "direction": "down" })),
        (
            "pane/open",
            serde_json::json!({ "surface": { "kind": "terminal" } }),
        ),
        (
            "pane/move",
            serde_json::json!({ "pane": first, "to": { "step": "right" } }),
        ),
        // `force`: an agent closing a terminal says it means to end what runs there; this
        // test is about focus, not that rule.
        (
            "pane/close",
            serde_json::json!({ "pane": right, "force": true }),
        ),
    ] {
        let data = ok_data(layout(&daemon.socket, verb, args, None, false));
        serde_json::from_value::<bench_wire::LayoutReport>(data.clone())
            .unwrap_or_else(|e| panic!("{verb}: the reply is a LayoutReport: {e}"));
        assert_eq!(data["focused_pane_before"], held.as_str(), "{verb}");
        assert_eq!(
            data["focused_pane_after"],
            held.as_str(),
            "{verb}: the keyboard stayed"
        );
        assert_eq!(
            data["changed"], true,
            "{verb}: and it was a real change, not a no-op"
        );
    }

    // tasks.md landed as a background tab of the operator's own slot (the canvas rule), so
    // showing it would take the keyboard (#284) — refused, where showing it anywhere else
    // would not be.
    let bench = ok_data(layout(
        &daemon.socket,
        "bench/get",
        serde_json::Value::Null,
        None,
        false,
    ));
    let tasks = bench["document"]["workspaces"][0]["bench"]["columns"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|c| c["slots"].as_array().unwrap().iter())
        .flat_map(|s| s["panes"].as_array().unwrap().iter())
        .find(|p| p["surface"]["source"]["path"] == "/tmp/m4-proof/tasks.md")
        .unwrap()["id"]
        .clone();
    let shown = layout(
        &daemon.socket,
        "pane/show",
        serde_json::json!({ "pane": tasks }),
        None,
        false,
    );
    assert_eq!(shown["status"], "refused", "{shown}");

    let refused = layout(
        &daemon.socket,
        "pane/close",
        serde_json::json!({ "pane": held, "force": true }),
        None,
        false,
    );
    assert_eq!(refused["status"], "refused", "{refused}");
    assert!(
        refused["reason"].as_str().unwrap().contains("--asked"),
        "the refusal names the route: {refused}"
    );

    let asked = ok_data(layout(
        &daemon.socket,
        "pane/close",
        serde_json::json!({ "pane": held, "force": true }),
        None,
        true,
    ));
    assert_ne!(
        asked["focused_pane_after"],
        held.as_str(),
        "with --asked it may"
    );
}

#[test]
fn a_layout_refusal_names_what_was_wrong_and_changes_nothing() {
    let home = TestHome::claim("m4-refuse");
    let root = home.dir.join(".bench");
    let daemon = DaemonGuard::start(&home.dir, None);
    working_bench(&daemon.socket);
    let events_before = log_of(&root).len();

    for (verb, args, names) in [
        ("pane/close", serde_json::json!({}), "pane"),
        (
            "pane/open",
            serde_json::json!({ "surface": { "kind": "archonRun" } }),
            "archonRun",
        ),
        (
            "pane/close",
            serde_json::json!({ "pane": "00000000-0000-4000-8000-000000000000" }),
            "no pane",
        ),
        (
            "workspace/open",
            serde_json::json!({ "path": "relative/dir" }),
            "absolute",
        ),
    ] {
        let reply = layout(&daemon.socket, verb, args, operator(), false);
        assert_eq!(reply["status"], "refused", "{verb}: {reply}");
        assert!(
            reply["reason"].as_str().unwrap().contains(names),
            "{verb}: the refusal names {names:?}: {reply}"
        );
    }
    let run = bench(&home.dir, &["get"]);
    assert_eq!(run.code, 0, "and the CLI still reads it: {}", run.stderr);
    assert_eq!(
        log_of(&root).len(),
        events_before,
        "a refusal is not a change and logs nothing"
    );
}

#[test]
fn a_verb_that_changes_nothing_logs_nothing() {
    let home = TestHome::claim("m4-noop");
    let root = home.dir.join(".bench");
    let daemon = DaemonGuard::start(&home.dir, None);
    working_bench(&daemon.socket);
    let events_before = log_of(&root).len();

    let data = ok_data(layout(
        &daemon.socket,
        "workspace/activate",
        serde_json::json!({ "path": "/tmp/m4-proof" }),
        None,
        false,
    ));

    assert_eq!(data["changed"], false);
    assert_eq!(log_of(&root).len(), events_before);
}

/// Read one newline-terminated line, bounded.
fn read_frame(reader: &mut BufReader<UnixStream>) -> serde_json::Value {
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .unwrap_or_else(|e| panic!("no frame ({e})"));
    serde_json::from_str(&line).unwrap_or_else(|e| panic!("{e}: {line:?}"))
}

fn follow(socket: &Path) -> BufReader<UnixStream> {
    let stream = UnixStream::connect(socket).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    (&stream)
        .write_all(b"{\"id\":\"f\",\"verb\":\"events\",\"args\":{\"follow\":true}}\n")
        .unwrap();
    BufReader::new(stream)
}

#[test]
fn a_follower_gets_the_document_then_every_change_with_the_document_attached() {
    let home = TestHome::claim("m4-follow");
    let daemon = DaemonGuard::start(&home.dir, None);
    let mut reader = follow(&daemon.socket);
    let first = read_frame(&mut reader);
    assert_eq!(first["status"], "ok", "{first}");
    assert_eq!(
        first["data"]["document"]["workspaces"],
        serde_json::json!([])
    );

    let opened = ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": "/tmp/m4-follow" }),
        operator(),
        false,
    ));
    let frame = read_frame(&mut reader);
    assert_eq!(frame["event"]["kind"], "bench/changed");
    assert_eq!(frame["event"]["seq"], opened["seq"]);
    assert_eq!(
        frame["document"]["workspaces"][0]["path"], "/tmp/m4-follow",
        "the frame carries the whole document after the change"
    );

    // Every event reaches a follower, not only document changes — and one that did not
    // change the document carries none.
    let mail = bench(
        &home.dir,
        &["mail", "send", "--to", "operator", "--body", "hi"],
    );
    assert_eq!(mail.code, 0, "{}", mail.stderr);
    let frame = read_frame(&mut reader);
    assert_eq!(frame["event"]["kind"], "mail/sent");
    assert!(frame.get("document").is_none(), "{frame}");
}

#[test]
fn a_follower_that_stops_reading_never_parks_the_daemon() {
    let home = TestHome::claim("m4-stall");
    let root = home.dir.join(".bench");
    let daemon = DaemonGuard::start(&home.dir, None);
    working_bench(&daemon.socket);
    // Connected, answered, and never read again.
    let _stalled = follow(&daemon.socket);
    let columns = ok_data(layout(
        &daemon.socket,
        "bench/get",
        serde_json::Value::Null,
        None,
        false,
    ))["document"]["workspaces"][0]["bench"]["columns"]
        .clone();
    let (member, against) = (columns[0]["id"].clone(), columns[1]["id"].clone());

    // Enough changes, each with the whole document attached, to fill the socket's buffer
    // and the follower's queue several times over.
    // The bound is on the worst single verb. A follower written to under the mutex parks
    // every verb for as long as that write blocks — DAEMON_IO_TIMEOUT, 5 s — while a verb
    // here takes milliseconds; 3 s sits between the two with room on a loaded machine.
    let started = Instant::now();
    let mut slowest = Duration::ZERO;
    for i in 0..600 {
        let fraction = if i % 2 == 0 { 0.3 } else { 0.7 };
        let sent = Instant::now();
        let reply = layout(
            &daemon.socket,
            "layout/resize",
            serde_json::json!({ "divider": { "between": "columns", "member": member, "against": against }, "fraction": fraction }),
            operator(),
            false,
        );
        assert_eq!(
            reply["status"],
            "ok",
            "verb {i} after {:?}: {reply}",
            started.elapsed()
        );
        slowest = slowest.max(sent.elapsed());
    }
    assert!(
        slowest < Duration::from_secs(3),
        "no verb waited on the stalled follower: the slowest took {slowest:?}"
    );
    assert!(
        log_of(&root)
            .iter()
            .any(|e| e["kind"] == "events/follower-dropped"),
        "the stalled follower was dropped, and that is on the record"
    );
}

/// #356: an agent's pane lands in a drawer and badges it, with the operator's keyboard and
/// every workspace exactly where they were; only the operator opens it; and the drawer comes
/// back from `bench.json` after a restart.
#[test]
fn an_agent_badges_a_drawer_and_only_the_operator_opens_it() {
    let home = TestHome::claim("drawer");
    let daemon = DaemonGuard::start(&home.dir, None);
    let (_, _, held) = working_bench(&daemon.socket);
    let get = |socket: &Path| {
        ok_data(layout(
            socket,
            "bench/get",
            serde_json::Value::Null,
            None,
            false,
        ))["document"]
            .clone()
    };
    let workspaces = get(&daemon.socket)["workspaces"].clone();
    let mut reader = follow(&daemon.socket);
    read_frame(&mut reader);

    let pushed = ok_data(layout(
        &daemon.socket,
        "pane/open",
        serde_json::json!({ "drawer": "notes", "surface": { "kind": "canvas", "source": { "kind": "file", "path": "/tmp/m4-proof/drawers.md" } } }),
        None,
        false,
    ));
    assert_eq!(pushed["changed"], true, "{pushed}");
    assert_eq!(pushed["focused_pane_before"], held.as_str());
    assert_eq!(
        pushed["focused_pane_after"],
        held.as_str(),
        "the keyboard stayed"
    );
    let frame = read_frame(&mut reader);
    assert_eq!(frame["event"]["kind"], "bench/changed");
    let drawer = &frame["document"]["drawers"][0];
    assert_eq!(drawer["name"], "notes");
    assert_eq!(drawer["badged"], true, "the operator is told: {frame}");
    assert_eq!(drawer["selected"], pushed["pane_created"]);
    assert!(
        frame["document"].get("open_drawer").is_none(),
        "and nothing opened"
    );
    assert_eq!(
        frame["document"]["workspaces"], workspaces,
        "no workspace moved"
    );

    // The CLI speaks for an agent, and opening a drawer is the operator's focus.
    let refused = bench(&home.dir, &["drawer", "toggle", "notes"]);
    assert_eq!(refused.code, 3, "{}", refused.stderr);
    assert!(refused.stderr.contains("--asked"), "{}", refused.stderr);

    let opened = ok_data(layout(
        &daemon.socket,
        "drawer/toggle",
        serde_json::json!({ "drawer": "notes" }),
        operator(),
        false,
    ));
    assert_eq!(opened["focused_pane_after"], pushed["pane_created"]);
    let document = get(&daemon.socket);
    assert_eq!(document["open_drawer"], "notes");
    assert_eq!(document["drawers"][0]["badged"], false, "opening clears it");
    assert_eq!(
        document["workspaces"], workspaces,
        "opening a drawer re-lays-out nothing"
    );
    drop(daemon);

    let daemon = DaemonGuard::start(&home.dir, None);
    assert_eq!(
        get(&daemon.socket),
        document,
        "the drawer came back from bench.json"
    );
    let record: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(home.dir.join(".bench").join("bench.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(record["version"], bench_wire::DOCUMENT_RECORD_VERSION);
}

/// #356: placement comes from `<root>/rules/placement.toml`, reread on the next verb with no
/// restart; a file that cannot be read is logged naming the line, reported by `status`, and
/// changes nothing — the last good table keeps placing.
#[test]
fn a_rules_file_applies_on_the_next_verb_and_a_bad_one_changes_nothing() {
    let home = TestHome::claim("rules");
    let root = home.dir.join(".bench");
    let daemon = DaemonGuard::start(&home.dir, None);
    working_bench(&daemon.socket);
    let rules = root.join("rules").join("placement.toml");
    let open_canvas = |path: &str| {
        ok_data(layout(
            &daemon.socket,
            "pane/open",
            serde_json::json!({ "surface": { "kind": "canvas", "source": { "kind": "file", "path": path } } }),
            None,
            false,
        ))
    };
    let drawer_panes = || {
        let document = ok_data(layout(
            &daemon.socket,
            "bench/get",
            serde_json::Value::Null,
            None,
            false,
        ))["document"]
            .clone();
        document["drawers"]
            .as_array()
            .map_or(0, |d| d[0]["panes"].as_array().unwrap().len())
    };
    let status = || json_of(&bench(&home.dir, &["status"]))["rules"]["placement"].clone();
    assert_eq!(status()["state"], "default");

    open_canvas("/tmp/m4-proof/a.md");
    assert_eq!(
        drawer_panes(),
        0,
        "the built-in table keeps canvases on the bench"
    );

    fs::create_dir_all(rules.parent().unwrap()).unwrap();
    fs::write(
        &rules,
        "[[place]]\nsurface = \"canvas\"\nby = \"agent\"\ntry = [{ drawer = \"notes\" }]\n",
    )
    .unwrap();
    let focus = open_canvas("/tmp/m4-proof/b.md");
    assert_eq!(drawer_panes(), 1, "the file applied without a restart");
    assert_eq!(focus["focused_pane_before"], focus["focused_pane_after"]);
    assert_eq!(status()["state"], "ok");

    fs::write(
        &rules,
        "[[place]]\nsurface = \"canvas\"\ntry = [\"sideways\"]\n",
    )
    .unwrap();
    open_canvas("/tmp/m4-proof/c.md");
    assert_eq!(drawer_panes(), 2, "the last good table is still placing");
    let rejected: Vec<_> = log_of(&root)
        .into_iter()
        .filter(|e| e["kind"] == "rules/rejected")
        .collect();
    assert_eq!(
        rejected.len(),
        1,
        "logged once for this version of the file"
    );
    let why = rejected[0]["data"]["why"].as_str().unwrap();
    assert!(why.contains("line 3") && why.contains("sideways"), "{why}");
    assert_eq!(rejected[0]["data"]["file"], rules.display().to_string());
    let reported = status();
    assert_eq!(reported["state"], "rejected");
    assert_eq!(reported["why"], why);
    open_canvas("/tmp/m4-proof/d.md");
    assert_eq!(
        log_of(&root)
            .iter()
            .filter(|e| e["kind"] == "rules/rejected")
            .count(),
        1,
        "not once per verb"
    );
}

#[test]
fn an_unreadable_bench_json_is_moved_aside_and_the_daemon_starts_empty() {
    let home = TestHome::claim("m4-bad");
    let root = home.dir.join(".bench");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join("bench.json"), "this was never a document").unwrap();

    let daemon = DaemonGuard::start(&home.dir, None);

    let data = ok_data(layout(
        &daemon.socket,
        "bench/get",
        serde_json::Value::Null,
        None,
        false,
    ));
    assert_eq!(data["document"]["workspaces"], serde_json::json!([]));
    assert!(
        !root.join("bench.json").exists(),
        "moved, not left to be read again"
    );
    let aside: Vec<_> = fs::read_dir(&root)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.file_name()
                .to_string_lossy()
                .starts_with("bench.json.bad-")
        })
        .collect();
    assert_eq!(aside.len(), 1, "and kept, never deleted");
    assert!(
        log_of(&root)
            .iter()
            .any(|e| e["kind"] == "bench/quarantined")
    );
}

#[test]
fn a_bench_json_with_one_unreadable_pane_loses_only_that_pane() {
    let home = TestHome::claim("m4-tolerant");
    let root = home.dir.join(".bench");
    fs::create_dir_all(&root).unwrap();
    let mut document: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/bench-document.json"),
        )
        .unwrap(),
    )
    .unwrap();
    let panes = document["workspaces"][0]["bench"]["columns"][0]["slots"][0]["panes"]
        .as_array_mut()
        .unwrap();
    let before = panes.len();
    panes.push(serde_json::json!({ "id": "99999999-9999-4999-8999-999999999999", "surface": { "kind": "archonRun" } }));
    fs::write(
        root.join("bench.json"),
        serde_json::json!({ "format": "bench.document", "version": 0, "seq": 0, "document": document }).to_string(),
    )
    .unwrap();

    let daemon = DaemonGuard::start(&home.dir, None);

    let data = ok_data(layout(
        &daemon.socket,
        "bench/get",
        serde_json::Value::Null,
        None,
        false,
    ));
    let workspaces = data["document"]["workspaces"].as_array().unwrap();
    assert_eq!(workspaces.len(), 3, "every workspace survived");
    assert_eq!(
        workspaces[0]["bench"]["columns"][0]["slots"][0]["panes"]
            .as_array()
            .unwrap()
            .len(),
        before,
        "only the unreadable pane went"
    );
    let repaired: Vec<_> = log_of(&root)
        .into_iter()
        .filter(|e| e["kind"] == "bench/repaired")
        .collect();
    assert_eq!(repaired.len(), 1, "and the loss is on the record");
}

#[test]
fn a_bench_json_older_than_the_log_says_so() {
    let home = TestHome::claim("m4-behind");
    let root = home.dir.join(".bench");
    fs::create_dir_all(&root).unwrap();
    let mut log = String::new();
    log.push_str("{\"seq\":0,\"at\":\"2026-09-25T00:00:00Z\",\"kind\":\"log/format\",\"data\":{\"format\":\"bench.events-log\",\"version\":0}}\n");
    log.push_str("{\"seq\":1,\"at\":\"2026-09-25T00:00:01Z\",\"kind\":\"bench/changed\",\"data\":{\"verb\":\"workspace/open\"}}\n");
    log.push_str("{\"seq\":2,\"at\":\"2026-09-25T00:00:02Z\",\"kind\":\"bench/changed\",\"data\":{\"verb\":\"pane/split\"}}\n");
    fs::write(root.join("events.jsonl"), log).unwrap();
    fs::write(
        root.join("bench.json"),
        serde_json::json!({ "format": "bench.document", "version": 0, "seq": 1, "document": { "workspaces": [], "active": null } }).to_string(),
    )
    .unwrap();

    let _daemon = DaemonGuard::start(&home.dir, None);

    let behind: Vec<_> = log_of(&root)
        .into_iter()
        .filter(|e| e["kind"] == "bench/behind")
        .collect();
    assert_eq!(behind.len(), 1);
    assert_eq!(behind[0]["data"]["log_seq"], 2);
    assert_eq!(behind[0]["data"]["document_seq"], 1);
}

#[test]
fn the_cli_follows_the_bench_line_by_line() {
    let home = TestHome::claim("m4-cli");
    let daemon = DaemonGuard::start(&home.dir, None);
    let mut child = isolated(bench_bin())
        .env("HOME", &home.dir)
        .args(["events", "--follow"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn bench events --follow");
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let first: serde_json::Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
    assert!(
        first.get("document").is_some(),
        "the first line is the document: {first}"
    );

    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": "/tmp/m4-cli" }),
        operator(),
        false,
    ));
    let frame: serde_json::Value = serde_json::from_str(&lines.next().unwrap().unwrap()).unwrap();
    let _ = child.kill();
    let _ = child.wait();
    assert_eq!(frame["event"]["kind"], "bench/changed");
}

// ---------------------------------------------------------------------------
// The session list (#384)
// ---------------------------------------------------------------------------

/// Every file under `dir` with its size and mtime — the negative control that reading the
/// harness files never wrote to them.
fn tree_state(dir: &Path) -> Vec<(PathBuf, u64, std::time::SystemTime)> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in fs::read_dir(&d).into_iter().flatten().flatten() {
            let md = e.metadata().unwrap();
            if md.is_dir() {
                stack.push(e.path());
            } else {
                out.push((e.path(), md.len(), md.modified().unwrap()));
            }
        }
    }
    out.sort();
    out
}

fn mangle(cwd: &Path) -> String {
    bench_sessions::claude::mangle(&cwd.display().to_string())
}

#[test]
#[expect(
    clippy::too_many_lines,
    clippy::cognitive_complexity,
    reason = "legacy (#418): 167 lines, limit 100; cognitive complexity 31, limit 25"
)]
fn the_session_list_names_what_helm_and_benchd_hosted_and_nothing_else() {
    use bench_wire::{Harness, Host, OpenAction, SessionList, SessionState};
    let home = TestHome::claim("sessions");
    let h = &home.dir;
    let ws = h.join("ws");
    fs::create_dir_all(ws.join(".git")).unwrap();
    let write = |p: PathBuf, text: String| {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    };
    let daemon = DaemonGuard::start(h, None);
    let root = h.join(".bench");

    // Two live Claude processes in the workspace: this test (in a helm pane) and the daemon
    // (in no pane — foreign). Their registry rows carry their real start times.
    let started = |pid: u32| bench_sessions::process::started_at_secs(pid).unwrap() * 1000;
    let me = std::process::id();
    let foreign = daemon.child.id();
    let pane = "0E8E8CC6-159B-45D8-BC02-485120975998";
    for (pid, sid) in [(me, "in-pane"), (foreign, "in-zed")] {
        write(
            h.join(format!(".claude/sessions/{pid}.json")),
            serde_json::json!({"pid": pid, "sessionId": sid, "cwd": ws, "startedAt": started(pid),
                "status": "idle", "kind": "interactive", "entrypoint": "cli"})
            .to_string(),
        );
    }
    // A pane whose agent exited: helm recorded it as resumable, and its transcript remains.
    // And an Archon run's transcript: in scope, never hosted.
    for sid in ["gone", "archon-run", "in-zed"] {
        write(
            h.join(".claude/projects")
                .join(mangle(&ws))
                .join(format!("{sid}.jsonl")),
            "{\"type\":\"user\"}\n".into(),
        );
    }
    let terminal =
        |t: serde_json::Value| serde_json::json!({"id": pane, "kind": "terminal", "terminal": t});
    write(
        h.join(".helm/bench/snapshot.json"),
        serde_json::json!({"format": "helm.bench-snapshot", "version": 1, "writtenAt": "2026-09-25T12:00:00Z",
            "workspaces": [{"columns": [{"slots": [{"panes": [
                terminal(serde_json::json!({"foregroundPid": me,
                    "owner": {"runtime": "claude", "pid": me, "sessionId": "in-pane", "cwd": ws}})),
                {"id": "3C47FA92-A0BE-4012-A697-F7BE06AEDE28", "kind": "terminal", "terminal":
                    {"resumable": {"command": "claude", "session": "gone", "cwd": ws}}},
            ]}]}]}]})
        .to_string(),
    );
    // A job in a state no reader knows.
    write(
        h.join(".claude/jobs/j1/state.json"),
        serde_json::json!({"state": "hibernating", "sessionId": "j", "cwd": ws}).to_string(),
    );
    let harness_files = [h.join(".claude"), h.join(".helm")];
    let before: Vec<_> = harness_files.iter().map(|d| tree_state(d)).collect();

    let list = |extra: &[&str]| -> SessionList {
        let mut args = vec!["sessions", "--all"];
        args.extend(extra);
        let run = bench(h, &args);
        assert_eq!(run.code, 0, "stderr: {}", run.stderr);
        serde_json::from_str(&run.stdout).unwrap_or_else(|e| panic!("{e}: {}", run.stdout))
    };
    let ws_arg = ws.display().to_string();
    let first = list(&["--workspace", &ws_arg]);
    let ids: Vec<&str> = first.rows.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(
        ids,
        ["in-pane", "gone"],
        "running first, and nothing foreign"
    );
    assert_eq!(
        serde_json::json!(first.rows[0].open),
        serde_json::json!({"kind": "focus_pane", "pane": pane.to_lowercase()})
    );
    assert!(matches!(first.rows[1].state, SessionState::Finished { .. }));
    assert_eq!(first.rows[1].host, Host::None);
    assert!(
        matches!(&first.rows[1].open, OpenAction::Resume { argv, .. } if argv.contains(&"gone".to_string()))
    );
    assert!(
        first.rows.iter().all(|r| r.mail.is_none()),
        "helm-pane agents have no benchd mailbox until #358"
    );
    assert_eq!(first.unreadable.len(), 1, "{:?}", first.unreadable);
    assert_eq!(first.unreadable[0].source, "claude-job");

    // Logged before it was answered, and written to the record.
    let log = log_of(&root);
    let hosted: Vec<&serde_json::Value> = log
        .iter()
        .filter(|e| e["kind"] == "sessions/hosted")
        .collect();
    assert_eq!(hosted.len(), 1);
    let recorded: Vec<&str> = hosted[0]["data"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["id"].as_str().unwrap())
        .collect();
    assert_eq!(recorded, ["in-pane", "gone"]);
    let record: bench_wire::HostedRecord =
        serde_json::from_str(&fs::read_to_string(root.join("sessions/hosted.json")).unwrap())
            .unwrap();
    assert_eq!(record.sessions.len(), 2);

    // A second build adds nothing to the record and logs the unreadable job no second time.
    let second = list(&["--workspace", &ws_arg]);
    assert_eq!(second.rows, first.rows);
    assert_eq!(
        second.unreadable, first.unreadable,
        "every reply still says which file"
    );
    let log = log_of(&root);
    assert_eq!(
        log.iter()
            .filter(|e| e["kind"] == "sessions/hosted")
            .count(),
        1
    );
    assert_eq!(
        log.iter()
            .filter(|e| e["kind"] == "sessions/unreadable")
            .count(),
        1
    );

    // Dismissing: only what was hosted, and it hides the finished row across a restart.
    let refused = bench(
        h,
        &["sessions", "dismiss", "archon-run", "--harness", "claude"],
    );
    assert_eq!(refused.code, 3, "stderr: {}", refused.stderr);
    assert!(
        refused.stderr.contains("bench sessions --all"),
        "{}",
        refused.stderr
    );
    let with_all = bench(
        h,
        &[
            "sessions",
            "dismiss",
            "gone",
            "--harness",
            "claude",
            "--all",
        ],
    );
    assert_eq!(
        with_all.code, 3,
        "--all never turns a dismiss into a listing"
    );
    let no_harness = bench(h, &["sessions", "dismiss", "gone"]);
    assert_eq!(no_harness.code, 3);
    let dismissed = bench(h, &["sessions", "dismiss", "gone", "--harness", "claude"]);
    assert_eq!(dismissed.code, 0, "stderr: {}", dismissed.stderr);
    let d: bench_wire::Dismissal = serde_json::from_str(&dismissed.stdout).unwrap();
    assert_eq!((d.harness, d.id.as_str()), (Harness::Claude, "gone"));
    assert!(
        log_of(&root)
            .iter()
            .any(|e| e["kind"] == "sessions/dismissed" && e["data"]["id"] == "gone")
    );
    drop(daemon);
    let _daemon = DaemonGuard::start(h, None);
    // The foreign row's pid died with the first daemon; the pane agent is still this test.
    let after = list(&["--workspace", &ws.join("src").display().to_string()]);
    let ids: Vec<&str> = after.rows.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(
        ids,
        ["in-pane"],
        "dismissed, and the record survived the restart"
    );
    assert_eq!(
        after.workspace, ws_arg,
        "any path inside resolves to the workspace"
    );

    // Reading never wrote to a harness file.
    let after_state: Vec<_> = harness_files.iter().map(|d| tree_state(d)).collect();
    assert_eq!(before, after_state);
}

// ---------------------------------------------------------------------------
// bench log (#421): a transcript read straight from its file, no daemon
// ---------------------------------------------------------------------------

/// A Claude transcript under the test home: a prompt, a reply, a tool call that failed, and
/// one record in a shape nobody knows.
fn write_claude_transcript(home: &Path, id: &str) -> PathBuf {
    let at = "2026-09-25T16:49:25.973Z";
    let lines = [
        serde_json::json!({"type": "user", "timestamp": at,
            "message": {"role": "user", "content": "fix the build"}}),
        serde_json::json!({"type": "assistant", "timestamp": at,
            "message": {"content": [{"type": "text", "text": "Looking at it."}]}}),
        serde_json::json!({"type": "assistant", "timestamp": at,
            "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Bash",
                "input": {"command": "cargo build"}}]}}),
        serde_json::json!({"type": "user", "timestamp": at,
            "message": {"content": [{"type": "tool_result", "tool_use_id": "t1",
                "is_error": true, "content": "error[E0425]: cannot find value"}]}}),
        serde_json::json!({"type": "assistant", "timestamp": at,
            "message": {"content": [{"type": "hologram"}]}}),
    ];
    let path = home
        .join(".claude/projects/-ws")
        .join(format!("{id}.jsonl"));
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
    fs::write(&path, text).unwrap();
    path
}

#[test]
fn log_reads_a_transcript_with_no_daemon_and_names_what_it_skipped() {
    let home = TestHome::claim("log");
    write_claude_transcript(&home.dir, "s-1");

    let text = bench(&home.dir, &["log", "s-1"]);
    assert_eq!(text.code, 0, "stderr: {}", text.stderr);
    for line in [
        "2026-09-25 16:49:25  user   fix the build",
        "2026-09-25 16:49:25  agent  Looking at it.",
        "2026-09-25 16:49:25  tool   Bash  cargo build",
        "2026-09-25 16:49:25  error  Bash  error[E0425]: cannot find value",
    ] {
        assert!(text.stdout.contains(line), "{line:?} in:\n{}", text.stdout);
    }
    assert!(
        text.stderr.contains("s-1.jsonl:5: skipped") && text.stderr.contains("hologram"),
        "the unknown record is reported with its line: {}",
        text.stderr
    );

    let json = bench(&home.dir, &["log", "s-1", "-n", "1", "--json"]);
    assert_eq!(json.code, 0, "stderr: {}", json.stderr);
    let v = json_of(&json);
    assert_eq!(v["harness"], "claude");
    assert_eq!(
        (v["total"].as_u64(), v["returned"].as_u64()),
        (Some(4), Some(1))
    );
    assert_eq!(v["entries"][0]["kind"], "error");
    assert_eq!(v["unreadable"][0]["line"], 5);

    let since = bench(&home.dir, &["log", "s-1", "--since", "1h", "--json"]);
    assert_eq!(
        json_of(&since)["total"],
        0,
        "every entry is older than an hour"
    );

    let unknown = bench(&home.dir, &["log", "no-such-session"]);
    assert_eq!(unknown.code, 3, "stderr: {}", unknown.stderr);
    assert!(
        unknown.stderr.contains("no transcript"),
        "{}",
        unknown.stderr
    );
    let flag = bench(&home.dir, &["status", "--json"]);
    assert_eq!(flag.code, 3, "--json belongs to log: {}", flag.stderr);
}

#[test]
fn the_bench_sessions_skills_snippets_execute() {
    // The same rule as the mail skill's: every ```bash fence runs, in order.
    let skill = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../.claude/skills/bench-sessions/SKILL.md"),
    )
    .expect("bench-sessions SKILL.md readable");
    let mut snippets: Vec<String> = Vec::new();
    let mut current: Option<String> = None;
    for line in skill.lines() {
        match (&mut current, line.trim()) {
            (None, "```bash") => current = Some(String::new()),
            (Some(buf), "```") => {
                snippets.push(std::mem::take(buf));
                current = None;
            }
            (Some(buf), _) => {
                buf.push_str(line);
                buf.push('\n');
            }
            _ => {}
        }
    }
    assert_eq!(
        snippets.len(),
        3,
        "the skill's sessions and two log snippets"
    );

    let home = TestHome::claim("sskill");
    let _daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    let ws = workspace(&home.dir);
    let (_, pi_session) = spawn_pi(&home.dir, &ws, "worker");
    write_claude_transcript(&home.dir, "s-2");
    let mut outputs = Vec::new();
    for (i, snippet) in snippets.iter().enumerate() {
        let out = isolated("bash")
            .args(["-euo", "pipefail", "-c", snippet])
            .current_dir(&ws)
            .env("HOME", &home.dir)
            .env("BENCH", bench_bin())
            .env("SESSION", "s-2")
            .output()
            .expect("run snippet");
        assert!(
            out.status.success(),
            "SKILL.md snippet {} failed (exit {:?}):\n{}\n--- stderr:\n{}",
            i + 1,
            out.status.code(),
            snippet,
            String::from_utf8_lossy(&out.stderr)
        );
        outputs.push(String::from_utf8_lossy(&out.stdout).into_owned());
    }
    assert!(
        outputs[0].contains(&format!("pi {pi_session} running")),
        "the live session is listed: {}",
        outputs[0]
    );
    assert!(
        outputs[1].contains("tool   Bash  cargo build"),
        "{}",
        outputs[1]
    );
    assert!(
        outputs[2].contains("claude") && outputs[2].contains("4 of 4"),
        "{}",
        outputs[2]
    );
    assert!(outputs[2].contains("user  fix the build"), "{}", outputs[2]);
}

// ---------------------------------------------------------------------------
// The sensor (#358): `hook` claims, keeps state, and hands out mail as hook context
// ---------------------------------------------------------------------------

const HOOK_PANE: &str = "0E8E8CC6-159B-45D8-BC02-485120975998";

unsafe extern "C" {
    fn setsid() -> i32;
}

/// A process with no controlling terminal: `sleep` moved into its own session. What a
/// session started from an agent's tool call looks like (#427).
struct Detached(Child);

impl Detached {
    fn start() -> Detached {
        use std::os::unix::process::CommandExt;
        let mut cmd = isolated("sleep");
        cmd.arg("60");
        // SAFETY: setsid is async-signal-safe and touches nothing of the parent's.
        unsafe {
            cmd.pre_exec(|| {
                setsid();
                Ok(())
            });
        }
        Detached(cmd.spawn().expect("spawn sleep"))
    }
}

impl Drop for Detached {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// A process on a real terminal: a benchd test session, whose `cat` holds its pty as its
/// controlling terminal. Answers (bench session id, pid).
fn terminal_process(home: &Path, name: &str) -> (String, u32) {
    let run = bench(
        home,
        &[
            "spawn",
            "--agent",
            "test-echo",
            "--cwd",
            "/tmp",
            "--name",
            name,
        ],
    );
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    let v = json_of(&run);
    (
        v["session"].as_str().unwrap().to_string(),
        v["pid"].as_u64().unwrap() as u32,
    )
}

/// The `hook` verb with an explicit pid, which the CLI cannot choose (it sends its parent).
fn hook_verb(socket: &Path, args: serde_json::Value) -> serde_json::Value {
    let (reply, _) = raw_request(socket, "hook", args);
    assert_eq!(reply["status"], "ok", "{reply}");
    reply["data"].clone()
}

/// `bench hook <harness>` exactly as a harness runs it: the payload on stdin.
fn bench_hook(home: &Path, harness: &str, payload: serde_json::Value) -> CliRun {
    let mut child = isolated(bench_bin())
        .env("HOME", home)
        .args(["hook", harness])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run bench hook");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(payload.to_string().as_bytes())
        .unwrap();
    let out = child.wait_with_output().unwrap();
    CliRun {
        code: out.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

fn hosted_record(root: &Path) -> serde_json::Value {
    serde_json::from_str(&fs::read_to_string(root.join("sessions/hosted.json")).unwrap()).unwrap()
}

#[test]
fn a_hook_claims_a_mailbox_only_for_a_declared_session_on_a_terminal() {
    let home = TestHome::claim("hookclaim");
    let h = &home.dir;
    let root = h.join(".bench");
    let daemon = DaemonGuard::start(h, None);
    let (_, tty_pid) = terminal_process(h, "holder");
    let detached = Detached::start();
    let event = |session: &str, pid: u32, pane: Option<&str>| {
        let mut args = serde_json::json!({
            "harness": "claude", "event": "SessionStart", "session": session,
            "cwd": "/Users/op/Projects/helm", "pid": pid,
        });
        if let Some(p) = pane {
            args["pane"] = serde_json::json!(p);
        }
        hook_verb(&daemon.socket, args)
    };

    // Declared, no terminal: a session an agent started from its tool call (#427).
    assert_eq!(
        event("inherited", detached.0.id(), Some(HOOK_PANE)),
        serde_json::json!({})
    );
    // A terminal, nothing declared: any Claude session the operator opens anywhere.
    assert_eq!(event("foreign", tty_pid, None), serde_json::json!({}));
    // Both: the pane's own agent.
    let id = "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2";
    let claimed = event(id, tty_pid, Some(HOOK_PANE));
    assert_eq!(claimed["handle"], "helm-a1b2", "{claimed}");
    assert_eq!(event(id, tty_pid, Some(HOOK_PANE))["handle"], "helm-a1b2");
    let claims: Vec<_> = event_kinds(h)
        .into_iter()
        .filter(|(k, _)| k == "mail/claimed")
        .collect();
    assert_eq!(claims.len(), 1, "claimed once, not per event: {claims:?}");
    let record = hosted_record(&root);
    let entry = record["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == id)
        .expect("the claim is in the record");
    assert_eq!(entry["via"]["kind"], "pane");
    assert_eq!(entry["via"]["handle"], "helm-a1b2");
    assert!(
        record["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .all(|s| s["id"] != "inherited" && s["id"] != "foreign"),
        "nothing unclaimed is recorded: {record}"
    );

    // A second session in the same directory with the same tail widens rather than shares.
    let twin = "ffffffff-1c4d-4e5f-8a6b-7c8d9e0fa1b2";
    assert_eq!(
        event(twin, tty_pid, Some(HOOK_PANE))["handle"],
        "helm-0fa1b2"
    );

    // The address survives a restart, and is not re-derived: the record answers, so no
    // terminal is needed to be recognised again.
    drop(daemon);
    let daemon = DaemonGuard::start(h, None);
    let again = hook_verb(
        &daemon.socket,
        serde_json::json!({"harness": "claude", "event": "PostToolUse", "session": id,
            "cwd": "/Users/op/Projects/helm", "pid": detached.0.id(), "tool": "Bash"}),
    );
    assert_eq!(again["handle"], "helm-a1b2");
    assert!(!h.join(".helm").exists(), "nothing reached helm's mailroom");
}

#[test]
fn a_benchd_session_keeps_its_handle_and_its_codex_id_joins_the_record() {
    let home = TestHome::claim("hookbench");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (session, pid) = terminal_process(h, "worker");
    let reply = hook_verb(
        &daemon.socket,
        serde_json::json!({"harness": "codex", "event": "SessionStart", "session": "thread-1",
            "cwd": "/tmp", "pid": pid, "bench_session": session}),
    );
    assert_eq!(reply["handle"], "worker");
    let record = hosted_record(&h.join(".bench"));
    let entry = record["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == "thread-1")
        .expect("codex's id joins the record");
    assert_eq!(entry["harness"], "codex");
    assert_eq!(entry["via"]["kind"], "bench");
    assert_eq!(entry["via"]["handle"], "worker");
}

#[test]
fn a_hook_hands_out_mail_as_context_once_and_never_while_a_prompt_is_open() {
    let home = TestHome::claim("hookmail");
    let h = &home.dir;
    let root = h.join(".bench");
    let daemon = DaemonGuard::start(h, None);
    let (_, tty_pid) = terminal_process(h, "holder");
    let session = "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2";
    let cwd = "/Users/op/Projects/helm";
    // Claimed with the pane's terminal; every later event is recognised by session id. The
    // first reply that reaches the model tells it the standing rule, once.
    let first = hook_verb(
        &daemon.socket,
        serde_json::json!({"harness": "claude", "event": "UserPromptSubmit",
            "session": session, "cwd": cwd, "pid": tty_pid, "pane": HOOK_PANE}),
    );
    assert_eq!(first["handle"], "helm-a1b2");
    assert!(
        first["context"]
            .as_str()
            .unwrap()
            .starts_with("You are `helm-a1b2` on the bench."),
        "{first}"
    );
    let inbox = || {
        fs::read_dir(root.join("mail/helm-a1b2/inbox"))
            .map(|d| d.count())
            .unwrap_or(0)
    };
    for body in ["SECRET-BODY-1", "SECRET-BODY-2"] {
        let send = bench(h, &["mail", "send", "--to", "helm-a1b2", "--body", body]);
        assert_eq!(send.code, 0, "stderr: {}", send.stderr);
    }
    let payload = |event: &str, tool: &str| {
        serde_json::json!({"session_id": session, "hook_event_name": event, "cwd": cwd,
            "tool_name": tool, "tool_input": {"command": "ls"}, "tool_response": {"stdout": "x"}})
    };

    // A permission prompt is open: its reply reaches no model, so nothing is handed out.
    let prompt = bench_hook(h, "claude", payload("PermissionRequest", "Bash"));
    assert_eq!(
        (prompt.code, prompt.stdout.as_str()),
        (0, ""),
        "{}",
        prompt.stderr
    );
    let question = bench_hook(h, "claude", payload("PreToolUse", "AskUserQuestion"));
    assert_eq!((question.code, question.stdout.as_str()), (0, ""));
    assert_eq!(inbox(), 2, "the mail waits");

    // The next tool call carries it: the proven shape, a pointer per message.
    let run = bench_hook(h, "claude", payload("PostToolUse", "Bash"));
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    let out: serde_json::Value = serde_json::from_str(run.stdout.trim())
        .unwrap_or_else(|e| panic!("one JSON line ({e}): {}", run.stdout));
    assert_eq!(out["hookSpecificOutput"]["hookEventName"], "PostToolUse");
    let context = out["hookSpecificOutput"]["additionalContext"]
        .as_str()
        .unwrap();
    let lines: Vec<&str> = context.lines().collect();
    assert_eq!(lines.len(), 2, "{context}");
    for (line, id) in lines.iter().zip(["m1", "m2"]) {
        let path = root.join(format!("mail/helm-a1b2/read/{id}.md"));
        assert_eq!(
            *line,
            format!("You have mail from operator: {}", path.display())
        );
        assert!(path.exists(), "the pointer names the retired file");
    }
    assert!(!run.stdout.contains("SECRET-BODY"), "never the body");
    assert_eq!(inbox(), 0);

    // Handed out once.
    let quiet = bench_hook(h, "claude", payload("PreToolUse", "Bash"));
    assert_eq!((quiet.code, quiet.stdout.as_str()), (0, ""));
    bench(h, &["mail", "send", "--to", "helm-a1b2", "--body", "third"]);
    let third = bench_hook(h, "claude", payload("PreToolUse", "Bash"));
    let out: serde_json::Value = serde_json::from_str(third.stdout.trim()).unwrap();
    assert_eq!(
        out["hookSpecificOutput"]["additionalContext"],
        format!(
            "You have mail from operator: {}",
            root.join("mail/helm-a1b2/read/m3.md").display()
        )
    );

    assert_the_hook_log(h);
    drop(daemon);
}

/// What `a_hook_hands_out_mail_as_context_once_and_never_while_a_prompt_is_open` logged: one
/// hand-out per call that handed something out, and a state change only when the activity
/// changed.
fn assert_the_hook_log(h: &Path) {
    let kinds = event_kinds(h);
    let delivered: Vec<_> = kinds
        .iter()
        .filter(|(k, _)| k == "mail/delivered")
        .collect();
    assert_eq!(delivered.len(), 2, "{delivered:?}");
    assert_eq!(delivered[0].1["mail"], serde_json::json!(["m1", "m2"]));
    assert_eq!(delivered[0].1["channel"], "hook");
    let states: Vec<String> = kinds
        .iter()
        .filter(|(k, _)| k == "agent/state")
        .map(|(_, d)| {
            let a = &d["activity"];
            match a["waiting_for"].as_str() {
                Some(what) => format!("waiting: {what}"),
                None => a["kind"].as_str().unwrap().to_string(),
            }
        })
        .collect();
    assert_eq!(
        states,
        [
            "busy",
            "waiting: permission prompt",
            "waiting: question",
            "busy"
        ],
        "transitions only: three PostToolUse/PreToolUse calls while busy log nothing"
    );
}

#[test]
fn a_hook_never_fails_its_agent() {
    let home = TestHome::claim("hooksafe");
    let h = &home.dir;
    let payload =
        serde_json::json!({"session_id": "s", "hook_event_name": "PostToolUse", "cwd": "/tmp"});
    // No daemon at all, a harness nobody wired, a payload that is not JSON: exit 0, nothing
    // on stdout.
    let none = bench_hook(h, "claude", payload.clone());
    assert_eq!(
        (none.code, none.stdout.as_str()),
        (0, ""),
        "{}",
        none.stderr
    );
    let _daemon = DaemonGuard::start(h, None);
    let wrong = bench_hook(h, "cursor", payload.clone());
    assert_eq!((wrong.code, wrong.stdout.as_str()), (0, ""));
    let mut child = isolated(bench_bin())
        .env("HOME", h)
        .args(["hook", "claude"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"not json").unwrap();
    let out = child.wait_with_output().unwrap();
    assert_eq!((out.status.code(), out.stdout.len()), (Some(0), 0));
    // An unaddressed session is answered and gets nothing; pi gets the reply itself.
    let pi = bench_hook(
        h,
        "pi",
        serde_json::json!({"session_id": "p", "hook_event_name": "context", "cwd": "/tmp"}),
    );
    assert_eq!((pi.code, pi.stdout.trim()), (0, "{}"));
    // A new event name is logged once and changes nothing.
    for _ in 0..2 {
        let run = bench_hook(
            h,
            "claude",
            serde_json::json!({"session_id": "s", "hook_event_name": "BrandNew", "cwd": "/tmp"}),
        );
        assert_eq!(run.code, 0);
    }
    let unknown = event_kinds(h)
        .into_iter()
        .filter(|(k, _)| k == "hook/unknown-event")
        .count();
    assert_eq!(unknown, 1);
}

#[test]
fn a_shell_string_hook_reports_the_agent_not_the_shell() {
    // codex runs its hook command as a shell string. bash and macOS's sh exec a single
    // command; dash (Ubuntu's sh) forks it, so `bench hook`'s parent is the shell. `; true`
    // makes every shell fork, so this proves the daemon sees through the shell to the agent
    // (here, this test process) on either system.
    let home = TestHome::claim("hookshell");
    let h = &home.dir;
    let _daemon = DaemonGuard::start(h, None);
    let (session, _) = terminal_process(h, "w");
    let payload = serde_json::json!({"session_id": "thread-sh", "hook_event_name": "SessionStart", "cwd": "/tmp"});
    let mut child = isolated("/bin/sh")
        .arg("-c")
        .arg(format!("{} hook codex; true", bench_bin().display()))
        .env("HOME", h)
        .env("BENCH_SESSION", &session)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(payload.to_string().as_bytes())
        .unwrap();
    assert_eq!(child.wait_with_output().unwrap().status.code(), Some(0));
    let claimed: Vec<_> = event_kinds(h)
        .into_iter()
        .filter(|(k, _)| k == "mail/claimed")
        .collect();
    assert_eq!(claimed.len(), 1, "{claimed:?}");
    assert_eq!(claimed[0].1["pid"], std::process::id(), "{:?}", claimed[0]);
}

// ---------------------------------------------------------------------------
// Delivery by state (#358): an idle agent is started through its own channel, never a pty
// ---------------------------------------------------------------------------

/// A stand-in for a Claude session's inbox socket: what benchd posts to it, line by line.
struct FakeInbox {
    path: PathBuf,
    listener: std::os::unix::net::UnixListener,
}

impl FakeInbox {
    fn bind(home: &Path) -> FakeInbox {
        let path = home.join("inbox.sock");
        let listener = std::os::unix::net::UnixListener::bind(&path).expect("bind fake inbox");
        listener.set_nonblocking(true).unwrap();
        FakeInbox { path, listener }
    }

    /// The next message posted within `wait`, as the JSON line benchd wrote.
    fn next(&self, wait: Duration) -> Option<serde_json::Value> {
        let end = Instant::now() + wait;
        while Instant::now() < end {
            if let Ok((mut stream, _)) = self.listener.accept() {
                stream.set_nonblocking(false).unwrap();
                let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                let mut text = String::new();
                let _ = stream.read_to_string(&mut text);
                return Some(serde_json::from_str(text.trim()).expect("one JSON line"));
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        None
    }
}

/// A Claude agent in a helm pane, claimed and reporting `inbox` as its socket.
fn claude_in_a_pane(daemon: &DaemonGuard, pid: u32, session: &str, inbox: &Path) -> String {
    let reply = claude_event(daemon, pid, session, inbox, "SessionStart", None);
    reply["handle"].as_str().unwrap().to_string()
}

fn claude_event(
    daemon: &DaemonGuard,
    pid: u32,
    session: &str,
    inbox: &Path,
    event: &str,
    tool: Option<&str>,
) -> serde_json::Value {
    let mut args = serde_json::json!({"harness": "claude", "event": event, "session": session,
        "cwd": "/Users/op/Projects/helm", "pid": pid, "pane": HOOK_PANE,
        "messaging_socket": inbox.display().to_string()});
    if let Some(t) = tool {
        args["tool"] = serde_json::json!(t);
    }
    hook_verb(&daemon.socket, args)
}

fn inbox_count(h: &Path, handle: &str) -> usize {
    fs::read_dir(h.join(".bench/mail").join(handle).join("inbox"))
        .map(|d| d.count())
        .unwrap_or(0)
}

#[test]
fn an_idle_claude_is_started_through_its_socket_and_a_busy_one_is_not() {
    let home = TestHome::claim("push");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (_, pid) = terminal_process(h, "holder");
    let inbox = FakeInbox::bind(h);
    let session = "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2";
    let handle = claude_in_a_pane(&daemon, pid, session, &inbox.path);
    let send = |body: &str| {
        let run = bench(h, &["mail", "send", "--to", &handle, "--body", body]);
        assert_eq!(run.code, 0, "stderr: {}", run.stderr);
        json_of(&run)
    };

    // Busy: nothing is pushed; the next tool call is the channel.
    claude_event(&daemon, pid, session, &inbox.path, "UserPromptSubmit", None);
    assert_eq!(send("while busy")["wake"], "queued");
    assert!(
        inbox.next(Duration::from_secs(2)).is_none(),
        "a busy agent gets no push"
    );
    // A permission prompt: still nothing.
    claude_event(
        &daemon,
        pid,
        session,
        &inbox.path,
        "PermissionRequest",
        Some("Bash"),
    );
    assert!(
        inbox.next(Duration::from_secs(2)).is_none(),
        "a prompt is never answered"
    );
    assert_eq!(inbox_count(h, &handle), 1);

    // Idle: one user message carrying the pointer, never the body.
    claude_event(&daemon, pid, session, &inbox.path, "Stop", None);
    let message = inbox
        .next(Duration::from_secs(5))
        .expect("pushed once idle");
    assert_eq!(message["type"], "user");
    assert_eq!(message["message"]["role"], "user");
    let text = message["message"]["content"].as_str().unwrap();
    let read = h.join(".bench/mail").join(&handle).join("read/m1.md");
    // The rule was told on SessionStart; the push carries only the pointer.
    assert_eq!(
        text,
        format!("You have mail from operator: {}", read.display())
    );
    assert!(!text.contains("while busy"), "never the body");
    assert!(read.exists() && inbox_count(h, &handle) == 0);
    // The turn it started arrives: no second push, and nothing reaches the pty at all.
    claude_event(&daemon, pid, session, &inbox.path, "UserPromptSubmit", None);
    claude_event(&daemon, pid, session, &inbox.path, "Stop", None);
    assert!(inbox.next(Duration::from_secs(2)).is_none());
    let delivered: Vec<_> = event_kinds(h)
        .into_iter()
        .filter(|(k, _)| k == "mail/delivered")
        .map(|(_, d)| d["channel"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(delivered, ["socket"]);
    let (resp, stream) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": "s1"}),
    );
    assert_eq!(resp["status"], "ok");
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let mut seen = [0u8; 4096];
    let n = (&stream).read(&mut seen).unwrap_or(0);
    assert!(
        !String::from_utf8_lossy(&seen[..n]).contains("You have mail"),
        "nothing is ever typed into a pty"
    );
}

/// A stand-in for the app-server a benchd-spawned codex runs its TUI against, speaking what
/// codex 0.157.0 speaks on `--listen unix://`: WebSocket, one JSON-RPC message per text frame.
/// Answers `initialize`, then `turn/start` with the next of `answers` (`true` starts a turn,
/// `false` refuses), and hands each `turn/start`'s params to the test. `thread/read` answers
/// the thread's status from `status`, which the test sets.
struct FakeAppServer {
    started: std::sync::mpsc::Receiver<serde_json::Value>,
    status: std::sync::Arc<std::sync::Mutex<&'static str>>,
}

impl FakeAppServer {
    fn bind(socket: &Path, answers: Vec<bool>) -> FakeAppServer {
        fs::create_dir_all(socket.parent().unwrap()).unwrap();
        let listener =
            std::os::unix::net::UnixListener::bind(socket).expect("bind fake app-server");
        let (tx, started) = std::sync::mpsc::channel();
        let status = std::sync::Arc::new(std::sync::Mutex::new("active"));
        let thread_status = std::sync::Arc::clone(&status);
        std::thread::spawn(move || {
            let mut answers = answers.into_iter();
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { return };
                let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                let mut head = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") && stream.read_exact(&mut byte).is_ok() {
                    head.push(byte[0]);
                }
                let _ = stream.write_all(b"HTTP/1.1 101 Switching Protocols\r\nconnection: Upgrade\r\nupgrade: websocket\r\n\r\n");
                while let Some(message) = read_client_frame(&mut stream) {
                    let id = message["id"].clone();
                    match message["method"].as_str() {
                        Some("initialize") => server_frame(
                            &mut stream,
                            &serde_json::json!({"id": id, "result": {"userAgent": "fake"}}),
                        ),
                        Some("thread/read") => {
                            let now = *thread_status.lock().unwrap();
                            let status = if now == "active" {
                                serde_json::json!({"type": "active", "activeFlags": []})
                            } else {
                                serde_json::json!({"type": now})
                            };
                            let thread = serde_json::json!({"id": message["params"]["threadId"], "status": status});
                            server_frame(
                                &mut stream,
                                &serde_json::json!({"id": id, "result": {"thread": thread}}),
                            );
                        }
                        Some("turn/start") => {
                            // A notification first, as the real one sends them unasked.
                            server_frame(
                                &mut stream,
                                &serde_json::json!({"method": "thread/status/changed", "params": {"threadId": message["params"]["threadId"], "status": {"type": "active", "activeFlags": []}}}),
                            );
                            let answer = if answers.next().unwrap_or(true) {
                                // Long enough for a 16-bit length, as real answers are.
                                serde_json::json!({"id": id, "result": {"turn": {"id": "t1", "status": "inProgress", "items": [], "note": "x".repeat(300)}}})
                            } else {
                                serde_json::json!({"id": id, "error": {"code": -32600, "message": "thread is busy"}})
                            };
                            server_frame(&mut stream, &answer);
                            let _ = tx.send(message["params"].clone());
                        }
                        _ => {}
                    }
                }
            }
        });
        FakeAppServer { started, status }
    }
}

fn read_client_frame(stream: &mut UnixStream) -> Option<serde_json::Value> {
    let mut head = [0u8; 2];
    stream.read_exact(&mut head).ok()?;
    assert!(head[1] & 0x80 != 0, "a client frame must be masked");
    let len = match head[1] & 0x7f {
        126 => {
            let mut n = [0u8; 2];
            stream.read_exact(&mut n).ok()?;
            u64::from(u16::from_be_bytes(n))
        }
        127 => {
            let mut n = [0u8; 8];
            stream.read_exact(&mut n).ok()?;
            u64::from_be_bytes(n)
        }
        n => u64::from(n),
    };
    let mut mask = [0u8; 4];
    stream.read_exact(&mut mask).ok()?;
    let mut payload = vec![0u8; len as usize];
    stream.read_exact(&mut payload).ok()?;
    payload
        .iter_mut()
        .enumerate()
        .for_each(|(i, b)| *b ^= mask[i % 4]);
    serde_json::from_slice(&payload).ok()
}

fn server_frame(stream: &mut UnixStream, message: &serde_json::Value) {
    let payload = message.to_string().into_bytes();
    let mut frame = vec![0x81u8];
    if payload.len() < 126 {
        frame.push(payload.len() as u8);
    } else {
        frame.push(126);
        frame.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    }
    frame.extend_from_slice(&payload);
    let _ = stream.write_all(&frame);
}

#[test]
fn an_idle_codex_benchd_spawned_is_started_through_its_app_server_and_a_busy_one_is_not() {
    let home = TestHome::claim("cxpush");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (session, pid) = terminal_process(h, "cx");
    let server = FakeAppServer::bind(
        &h.join(".bench/codex").join(format!("{session}.sock")),
        vec![true, false],
    );
    let thread = "01a0dde2-1128-7572-8528-e0979f7e706f";
    let event = |name: &str| {
        hook_verb(
            &daemon.socket,
            serde_json::json!({"harness": "codex", "event": name, "session": thread,
                "cwd": "/tmp", "pid": pid, "bench_session": session}),
        )
    };
    let send = |body: &str| json_of(&bench(h, &["mail", "send", "--to", "cx", "--body", body]));
    assert_eq!(
        event("SessionStart")["handle"],
        "cx",
        "joins its benchd session"
    );

    // Busy: nothing is started; the next tool call is the channel.
    event("UserPromptSubmit");
    assert_eq!(send("while busy")["wake"], "queued");
    assert!(server.started.recv_timeout(Duration::from_secs(2)).is_err());
    // A permission prompt: still nothing.
    event("PermissionRequest");
    assert!(server.started.recv_timeout(Duration::from_secs(2)).is_err());

    // Idle: one turn on its own thread, carrying the pointer and never the body.
    event("Stop");
    let params = server
        .started
        .recv_timeout(Duration::from_secs(5))
        .expect("a turn is started once idle");
    assert_eq!(params["threadId"], thread);
    let read = h.join(".bench/mail/cx/read/m1.md");
    assert_eq!(
        params["input"],
        serde_json::json!([{"type": "text", "text": format!("You have mail from operator: {}", read.display())}])
    );
    assert!(read.exists() && inbox_count(h, "cx") == 0);
    // It is busy with that turn: no second push before any hook says so.
    send("during the turn");
    assert!(server.started.recv_timeout(Duration::from_secs(2)).is_err());

    // A refused turn: the mail goes back, unread, and the session is not pushed again.
    event("Stop");
    server
        .started
        .recv_timeout(Duration::from_secs(5))
        .expect("tried once idle again");
    wait_until("the refused push is held", Duration::from_secs(5), || {
        event_kinds(h).iter().any(|(k, _)| k == "mail/held")
    });
    assert_eq!(inbox_count(h, "cx"), 1, "back in the inbox, unread");
    assert_eq!(send("after the refusal")["wake"], "next-turn");

    let log = event_kinds(h);
    let delivered: Vec<_> = log
        .iter()
        .filter(|(k, _)| k == "mail/delivered")
        .map(|(_, d)| d["channel"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(delivered, ["codex"]);
    assert!(
        log.iter().any(|(k, d)| k == "agent/state"
            && d["event"] == "turn/start"
            && d["activity"]["kind"] == "busy"),
        "the started turn is logged as the agent going busy"
    );
}

#[test]
fn a_codex_turn_that_failed_is_found_idle_by_its_thread_status() {
    // A turn refused by a usage limit fires no Stop (measured on codex 0.157.0): the hooks last
    // said busy, and only the app-server knows the thread went idle.
    let home = TestHome::claim("cxstale");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (session, pid) = terminal_process(h, "cx");
    let server = FakeAppServer::bind(
        &h.join(".bench/codex").join(format!("{session}.sock")),
        vec![true],
    );
    let thread = "01a0dded-514e-7681-9834-ce30a42cf6c5";
    for event in ["SessionStart", "UserPromptSubmit"] {
        hook_verb(
            &daemon.socket,
            serde_json::json!({"harness": "codex", "event": event, "session": thread,
                "cwd": "/tmp", "pid": pid, "bench_session": session}),
        );
    }
    bench(h, &["mail", "send", "--to", "cx", "--body", "one"]);
    // Still running by the server's word: held, however quiet the hooks are.
    assert!(server.started.recv_timeout(Duration::from_secs(7)).is_err());
    // What a usage-limit refusal leaves behind (measured): no turn is running.
    *server.status.lock().unwrap() = "systemError";
    let params = server
        .started
        .recv_timeout(Duration::from_secs(8))
        .expect("pushed once the server says idle");
    assert_eq!(params["threadId"], thread);
    assert!(
        event_kinds(h)
            .iter()
            .any(|(k, d)| k == "agent/state" && d["event"] == "thread/read"),
        "the log says which record found it idle"
    );
}

#[test]
fn a_codex_spawn_clears_a_socket_an_earlier_daemons_session_left_behind() {
    // Session ids restart at s1 with the daemon, and a codex app-server that died uncleanly
    // leaves its socket, which the next app-server on that path refuses to bind ("File
    // exists", measured on 0.157.0).
    let home = TestHome::claim("cxstalesock");
    let h = &home.dir;
    let stale = h.join(".bench/codex/s1.sock");
    fs::create_dir_all(stale.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink("/nonexistent/codex-daemon/gone", &stale).unwrap();
    let _daemon = DaemonGuard::start_with_fake(h, "codex");
    let run = bench(
        h,
        &["spawn", "--agent", "codex", "--cwd", "/tmp", "--name", "cx"],
    );
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    assert_eq!(json_of(&run)["session"], "s1");
    assert!(
        fs::symlink_metadata(&stale).is_err(),
        "the stale socket is gone before the app-server binds"
    );
}

#[test]
fn a_push_that_starts_no_turn_goes_back_to_the_inbox_and_stops_pushing() {
    // What a session without crossSessionInbound "accept" does: takes the message and holds
    // it behind a dialog, so no UserPromptSubmit follows. Waits out the 10 s answer window.
    let home = TestHome::claim("held");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (_, pid) = terminal_process(h, "holder");
    let inbox = FakeInbox::bind(h);
    let session = "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2";
    let handle = claude_in_a_pane(&daemon, pid, session, &inbox.path);
    bench(h, &["mail", "send", "--to", &handle, "--body", "one"]);
    assert!(inbox.next(Duration::from_secs(5)).is_some());
    wait_until(
        "the unanswered push is held",
        Duration::from_secs(20),
        || event_kinds(h).iter().any(|(k, _)| k == "mail/held"),
    );
    assert_eq!(inbox_count(h, &handle), 1, "back in the inbox, unread");
    let second = bench(h, &["mail", "send", "--to", &handle, "--body", "two"]);
    assert_eq!(
        json_of(&second)["wake"],
        "next-turn",
        "no more pushes to it"
    );
    assert!(inbox.next(Duration::from_secs(2)).is_none());
    // Its next tool call still delivers both.
    let reply = claude_event(
        &daemon,
        pid,
        session,
        &inbox.path,
        "PostToolUse",
        Some("Bash"),
    );
    let context = reply["context"].as_str().unwrap();
    assert_eq!(context.matches("You have mail").count(), 2, "{context}");
    // A session that starts again may take pushes again.
    claude_event(&daemon, pid, session, &inbox.path, "SessionStart", None);
    let third = bench(h, &["mail", "send", "--to", &handle, "--body", "three"]);
    assert_eq!(json_of(&third)["wake"], "queued");
    assert!(inbox.next(Duration::from_secs(5)).is_some());
}

#[test]
fn the_wake_cap_starves_pushes_never_mail() {
    let home = TestHome::claim("cap");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (_, pid) = terminal_process(h, "holder");
    let inbox = FakeInbox::bind(h);
    let session = "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2";
    let handle = claude_in_a_pane(&daemon, pid, session, &inbox.path);
    // Two agents replying to each other: every push starts a turn that ends idle again.
    for i in 0..6 {
        bench(
            h,
            &[
                "mail",
                "send",
                "--to",
                &handle,
                "--body",
                &format!("msg {i}"),
            ],
        );
        assert!(
            inbox.next(Duration::from_secs(5)).is_some(),
            "push {i} within the burst"
        );
        claude_event(&daemon, pid, session, &inbox.path, "UserPromptSubmit", None);
        claude_event(&daemon, pid, session, &inbox.path, "Stop", None);
    }
    bench(
        h,
        &["mail", "send", "--to", &handle, "--body", "the seventh"],
    );
    assert!(
        inbox.next(Duration::from_secs(3)).is_none(),
        "the burst budget is six"
    );
    wait_until("the cap is logged", Duration::from_secs(5), || {
        event_kinds(h).iter().any(|(k, _)| k == "wake/capped")
    });
    assert_eq!(inbox_count(h, &handle), 1, "capped mail waits unread");
}

#[test]
fn an_agent_that_went_idle_without_a_hook_is_found_by_its_registry_row() {
    // Esc on a Claude prompt ends the turn and fires no hook. The registry row is what knows.
    let home = TestHome::claim("reconcile");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (_, pid) = terminal_process(h, "holder");
    let inbox = FakeInbox::bind(h);
    let session = "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2";
    let handle = claude_in_a_pane(&daemon, pid, session, &inbox.path);
    claude_event(
        &daemon,
        pid,
        session,
        &inbox.path,
        "PermissionRequest",
        Some("Bash"),
    );
    bench(h, &["mail", "send", "--to", &handle, "--body", "x"]);
    let started = bench_sessions::process::started_at_secs(pid).unwrap() * 1000;
    let registry = h.join(".claude/sessions");
    fs::create_dir_all(&registry).unwrap();
    let row = |status: &str| {
        let v = serde_json::json!({"pid": pid, "sessionId": session, "cwd": "/tmp",
            "startedAt": started, "kind": "interactive", "status": status});
        fs::write(registry.join(format!("{pid}.json")), v.to_string()).unwrap();
    };
    // Still on the prompt: a row saying `waiting` with no `waitingFor` is idle, so name one.
    let v = serde_json::json!({"pid": pid, "sessionId": session, "cwd": "/tmp",
        "startedAt": started, "kind": "interactive", "status": "waiting",
        "waitingFor": "permission prompt"});
    fs::write(registry.join(format!("{pid}.json")), v.to_string()).unwrap();
    assert!(
        inbox.next(Duration::from_secs(7)).is_none(),
        "still waiting on the prompt"
    );
    row("idle");
    let message = inbox
        .next(Duration::from_secs(10))
        .expect("pushed once the row says idle");
    assert!(
        message["message"]["content"]
            .as_str()
            .unwrap()
            .contains("You have mail")
    );
    assert!(
        event_kinds(h)
            .iter()
            .any(|(k, d)| k == "agent/state" && d["event"] == "registry"),
        "the registry's word is logged as what changed the state"
    );
}

#[test]
fn a_spawn_hands_the_prompt_over_in_argv_and_waits_for_nothing() {
    use std::os::unix::fs::PermissionsExt;
    let home = TestHome::claim("argv");
    let h = &home.dir;
    // A `claude` that records its argv, then behaves like the others: quiet and live.
    let bin = h.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let recorded = h.join("argv.txt");
    fs::write(
        bin.join("claude"),
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\nexec cat\n",
            recorded.display()
        ),
    )
    .unwrap();
    fs::set_permissions(bin.join("claude"), fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::var("PATH").unwrap_or_default();
    let mut cmd = isolated(benchd_bin());
    cmd.env("PATH", format!("{}:{path}", bin.display()));
    let daemon = DaemonGuard::start_with(h, None, cmd);
    let prompt = h.join("brief.txt");
    fs::write(&prompt, "SECRET-PLAN line one\nline two\n").unwrap();

    let relative = bench(
        h,
        &[
            "spawn",
            "--agent",
            "claude",
            "--cwd",
            "/tmp",
            "--prompt-file",
            "nowhere.txt",
        ],
    );
    assert_eq!(
        relative.code, 3,
        "a file that is not there is refused: {}",
        relative.stderr
    );

    let started = Instant::now();
    let spawn = bench(
        h,
        &[
            "spawn",
            "--agent",
            "claude",
            "--cwd",
            "/tmp",
            "--prompt-file",
            &prompt.display().to_string(),
        ],
    );
    assert_eq!(spawn.code, 0, "stderr: {}", spawn.stderr);
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "nothing waits for a TUI: {:?}",
        started.elapsed()
    );
    wait_until(
        "the agent recorded its argv",
        Duration::from_secs(5),
        || recorded.exists(),
    );
    let argv = fs::read_to_string(&recorded).unwrap();
    let args: Vec<&str> = argv.lines().collect();
    assert_eq!(
        args.last().copied(),
        Some(format!("Read and act on the prompt in {}", prompt.display()).as_str()),
        "{argv}"
    );
    let settings_at = args
        .iter()
        .position(|a| *a == "--settings")
        .expect("--settings");
    let settings: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(args[settings_at + 1]).unwrap()).unwrap();
    assert_eq!(settings["crossSessionInbound"], "accept");
    assert_eq!(
        settings["hooks"]["PostToolUse"][0]["hooks"][0]["command"],
        bench_bin().display().to_string(),
        "the bench beside this daemon"
    );
    assert!(!argv.contains("SECRET-PLAN"), "a path, never the plan");
    let (resp, stream) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": "s1"}),
    );
    assert_eq!(resp["status"], "ok");
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let mut seen = [0u8; 4096];
    let n = (&stream).read(&mut seen).unwrap_or(0);
    assert!(
        !String::from_utf8_lossy(&seen[..n]).contains("SECRET-PLAN"),
        "nothing is typed into the pty"
    );
}

#[test]
fn a_pi_agent_wakes_itself_only_when_idle_and_under_the_cap() {
    // pi's extension watches the inbox benchd names and asks for its mail with `wake`; the
    // reply is what it hands to sendUserMessage. benchd decides whether a turn may start.
    let home = TestHome::claim("piwake");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (_, pid) = terminal_process(h, "holder");
    let session = "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2";
    let event = |event: &str| {
        hook_verb(
            &daemon.socket,
            serde_json::json!({"harness": "pi", "event": event, "session": session,
                "cwd": "/Users/op/Projects/helm", "pid": pid, "pane": HOOK_PANE}),
        )
    };
    let start = event("session_start");
    let handle = start["handle"].as_str().unwrap().to_string();
    assert_eq!(
        start["inbox"].as_str().unwrap(),
        h.join(".bench/mail")
            .join(&handle)
            .join("inbox")
            .display()
            .to_string(),
        "the extension is told what to watch"
    );
    assert!(
        start["rule"]
            .as_str()
            .unwrap()
            .starts_with(&format!("You are `{handle}`")),
        "and the rule for its system prompt: {start}"
    );
    let send = |body: &str| {
        let run = bench(h, &["mail", "send", "--to", &handle, "--body", body]);
        json_of(&run)["wake"].as_str().unwrap().to_string()
    };
    assert_eq!(send("while busy"), "queued", "a pi agent can be woken");

    // Busy: a wake hands out nothing; the next model call (`context`) carries it instead.
    event("agent_start");
    assert!(event("wake")["context"].is_null());
    let ctx = event("context");
    assert_eq!(
        ctx["context"].as_str().unwrap().lines().count(),
        1,
        "the pointer alone; the rule goes to the system prompt: {ctx}"
    );

    // Idle: a wake hands it out, as the pi channel, up to the burst of six.
    for i in 0..7 {
        event("agent_settled");
        send(&format!("idle {i}"));
        let reply = event("wake");
        if i < 6 {
            assert!(
                reply["context"].as_str().unwrap().contains("You have mail"),
                "wake {i}: {reply}"
            );
        } else {
            assert!(
                reply["context"].is_null(),
                "the seventh wake is over the cap: {reply}"
            );
        }
    }
    let channels: Vec<String> = event_kinds(h)
        .into_iter()
        .filter(|(k, _)| k == "mail/delivered")
        .map(|(_, d)| d["channel"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        channels.iter().filter(|c| *c == "pi").count(),
        6,
        "{channels:?}"
    );
    assert_eq!(inbox_count(h, &handle), 1, "capped mail waits unread");
}

#[test]
fn wiring_prints_what_to_add_and_check_says_what_is_missing() {
    let home = TestHome::claim("wiring");
    let h = &home.dir;
    let bench_path = bench_bin().canonicalize().unwrap().display().to_string();
    let plan = bench(h, &["wiring"]);
    assert_eq!(plan.code, 0, "stderr: {}", plan.stderr);
    let plan = json_of(&plan);
    assert_eq!(plan["bench"], bench_path.as_str());

    let unwired = bench(h, &["wiring", "--check"]);
    assert_eq!(unwired.code, 3, "nothing is wired yet: {}", unwired.stdout);
    let report = json_of(&unwired);
    assert_eq!(
        report["claude"]["missing_events"].as_array().unwrap().len(),
        8
    );
    assert_eq!(
        report["codex"]["missing_events"].as_array().unwrap().len(),
        8
    );

    // Wire exactly what the plan says, the way the operator would: merged into his files.
    let write = |rel: &str, value: &serde_json::Value| {
        let path = h.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, value.to_string()).unwrap();
    };
    let mut claude = serde_json::json!({"model": "opus", "hooks": {"Stop": [
        {"hooks": [{"type": "command", "command": "~/.claude/hooks/notify-done.sh"}]}]}});
    for (event, groups) in plan["claude"]["merge"]["hooks"].as_object().unwrap() {
        let list = claude["hooks"][event]
            .as_array()
            .cloned()
            .unwrap_or_default();
        claude["hooks"][event] =
            serde_json::json!([list, groups.as_array().unwrap().clone()].concat());
    }
    write(".claude/settings.json", &claude);
    write(".codex/hooks.json", &plan["codex"]["merge"]);
    fs::create_dir_all(h.join(".pi/agent/extensions/bench")).unwrap();
    fs::write(h.join(".pi/agent/extensions/bench/index.ts"), "").unwrap();
    let half = json_of(&bench(h, &["wiring", "--check"]));
    assert_eq!(half["claude"]["missing_events"], serde_json::json!([]));
    assert_eq!(
        half["claude"]["cross_session_inbound_accept"], false,
        "{half}"
    );

    claude["crossSessionInbound"] = serde_json::json!("accept");
    write(".claude/settings.json", &claude);
    let wired = bench(h, &["wiring", "--check"]);
    assert_eq!(wired.code, 0, "all wired: {}", wired.stdout);
    assert!(
        !h.join(".bench").exists(),
        "wiring needs no daemon and writes nothing"
    );
}

/// A killed agent reports no `SessionEnd`, so its record stays: `mail/who` must not name it over
/// the live agent in the same pane, whichever reported last.
#[test]
fn mail_who_skips_an_agent_whose_process_is_gone() {
    let home = TestHome::claim("whodead");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (_, older) = terminal_process(h, "older");
    let (newer_session, newer) = terminal_process(h, "newer");
    let report = |session: &str, pid: u32| {
        hook_verb(
            &daemon.socket,
            serde_json::json!({"harness": "claude", "event": "SessionStart", "session": session,
                "cwd": "/Users/op/Projects/helm", "pid": pid, "pane": HOOK_PANE}),
        )["handle"]
            .as_str()
            .unwrap()
            .to_string()
    };
    let live = report("0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2", older);
    std::thread::sleep(Duration::from_millis(20));
    let dead = report("ffffffff-1c4d-4e5f-8a6b-7c8d9e0f0000", newer);
    let run = bench(h, &["mail", "who", "--pane", HOOK_PANE]);
    assert_eq!(
        json_of(&run)["handle"],
        dead.as_str(),
        "both alive: the later one"
    );
    assert_eq!(bench(h, &["close", &newer_session]).code, 0);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let run = bench(h, &["mail", "who", "--pane", HOOK_PANE]);
        if json_of(&run)["handle"] == live.as_str() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "still naming the killed agent: {}",
            run.stdout
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn mail_who_names_the_agent_in_a_pane_and_refuses_an_empty_one() {
    let home = TestHome::claim("who");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (_, pid) = terminal_process(h, "holder");
    let report = |session: &str| {
        hook_verb(
            &daemon.socket,
            serde_json::json!({"harness": "claude", "event": "SessionStart", "session": session,
                "cwd": "/Users/op/Projects/helm", "pid": pid, "pane": HOOK_PANE}),
        )["handle"]
            .as_str()
            .unwrap()
            .to_string()
    };
    let empty = bench(h, &["mail", "who", "--pane", HOOK_PANE]);
    assert_eq!(
        empty.code, 3,
        "nobody has reported from it yet: {}",
        empty.stderr
    );
    let first = report("0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2");
    let run = bench(h, &["mail", "who", "--pane", &HOOK_PANE.to_lowercase()]);
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    assert_eq!(json_of(&run)["handle"], first.as_str());
    // A second agent later in the same pane (the first was killed, no SessionEnd): the one
    // that reported last is the one in it.
    std::thread::sleep(Duration::from_millis(20));
    let second = report("ffffffff-1c4d-4e5f-8a6b-7c8d9e0f0000");
    let run = bench(h, &["mail", "who", "--pane", HOOK_PANE]);
    assert_eq!(json_of(&run)["handle"], second.as_str());
    assert_eq!(json_of(&run)["harness"], "claude");
    assert_eq!(json_of(&run)["pid"], pid, "the process its hook reported");
    assert_eq!(bench(h, &["mail", "who", "--pane", "not-a-uuid"]).code, 3);
}

/// A session resumed in another pane (`claude --resume`) keeps its handle, and its record moves
/// with it: `mail/who` answers the pane it is in now and not the one it left. Reached both with
/// the daemon holding the session (its old process was killed, so no `SessionEnd`) and after a
/// restart, where the record is all the daemon has.
#[test]
fn a_resumed_session_moves_to_the_pane_it_reports_from_and_keeps_its_handle() {
    const NEW_PANE: &str = "D16CB9FE-B845-4763-96E7-13F3EA9FFB48";
    let home = TestHome::claim("whomoved");
    let h = &home.dir;
    let root = h.join(".bench");
    let daemon = DaemonGuard::start(h, None);
    let (_, old) = terminal_process(h, "old");
    let (_, new) = terminal_process(h, "new");
    let detached = Detached::start();
    let session = "19281c67-097c-4aec-ae6d-8eab6a7b7915";
    let report = |socket: &Path, pid: u32, pane: &str| {
        hook_verb(
            socket,
            serde_json::json!({"harness": "claude", "event": "SessionStart", "session": session,
                "cwd": "/Users/op/Projects/helm", "pid": pid, "pane": pane}),
        )["handle"]
            .as_str()
            .unwrap()
            .to_string()
    };
    let who = |pane: &str| bench(h, &["mail", "who", "--pane", pane]);
    let recorded_pane = || {
        hosted_record(&root)["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["id"] == session)
            .expect("the session is recorded")["via"]["pane"]
            .as_str()
            .unwrap()
            .to_uppercase()
    };

    let handle = report(&daemon.socket, old, HOOK_PANE);
    assert_eq!(json_of(&who(HOOK_PANE))["handle"], handle.as_str());

    // Resumed in a new pane while the daemon still holds the session.
    assert_eq!(report(&daemon.socket, new, NEW_PANE), handle, "same handle");
    let run = who(NEW_PANE);
    assert_eq!(run.code, 0, "the new pane answers: {}", run.stderr);
    assert_eq!(json_of(&run)["handle"], handle.as_str());
    assert_eq!(json_of(&run)["pid"], new);
    assert_eq!(who(HOOK_PANE).code, 3, "the old pane names nobody");
    assert_eq!(recorded_pane(), NEW_PANE);
    let moves: Vec<_> = event_kinds(h)
        .into_iter()
        .filter(|(k, _)| k == "mail/moved")
        .collect();
    assert_eq!(moves.len(), 1, "{moves:?}");

    // A declared pane with no terminal is a child that inherited HELM_PANE: nothing moves.
    report(&daemon.socket, detached.0.id(), HOOK_PANE);
    assert_eq!(recorded_pane(), NEW_PANE, "an inherited pane moves nothing");

    // After a restart the record is all benchd has, and it moves the same way.
    drop(daemon);
    let daemon = DaemonGuard::start(h, None);
    // The daemon's own test sessions went with it; the resumed agent is a fresh process.
    let (_, again) = terminal_process(h, "again");
    assert_eq!(report(&daemon.socket, again, HOOK_PANE), handle);
    assert_eq!(recorded_pane(), HOOK_PANE);
    assert_eq!(json_of(&who(HOOK_PANE))["handle"], handle.as_str());
    assert_eq!(who(NEW_PANE).code, 3);
}

// ---------------------------------------------------------------------------
// The just layer (#356)
// ---------------------------------------------------------------------------

/// `just` where benchd looks for it, or `None`. A runner without it skips the just tests
/// with a named reason, except in CI, which installs it: the proof has to run somewhere.
fn just_available() -> bool {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let found = std::env::split_paths(&path)
        .chain(["/opt/homebrew/bin", "/usr/local/bin"].map(PathBuf::from))
        .any(|dir| dir.join("just").is_file());
    if !found {
        assert!(
            std::env::var_os("CI").is_none(),
            "CI must install just: the just layer's proof runs there"
        );
        eprintln!("skipped: `just` is not installed (PATH, /opt/homebrew/bin, /usr/local/bin)");
    }
    found
}

/// Polls the event log for `kind` about `run`, within a generous deadline: the run is its own
/// process, so a slow machine only makes this wait longer.
fn await_event(root: &Path, kind: &str, run: &str) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if let Some(event) = log_of(root)
            .into_iter()
            .find(|e| e["kind"] == kind && e["data"]["run"] == run)
        {
            return event;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("no {kind} for {run} within 30s: {:?}", log_of(root));
}

/// #356: a recipe from `<root>/rules/justfile` runs at the active workspace, its `bench`
/// verbs reach this daemon, and it is logged as `just/started` (before the answer) and
/// `just/finished`. Run by the operator its verbs are his and may open a drawer; run by an
/// agent (`bench just`) the same verb is refused and the run fails. A missing justfile and a
/// name that is not a recipe are refused.
#[test]
fn a_recipe_runs_as_whoever_asked_and_is_logged() {
    if !just_available() {
        return;
    }
    let home = TestHome::claim("just");
    let root = home.dir.join(".bench");
    let daemon = DaemonGuard::start(&home.dir, None);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": home.dir.display().to_string() }),
        operator(),
        false,
    ));

    let missing = bench(&home.dir, &["just", "open"]);
    assert_eq!(missing.code, 3, "{}", missing.stderr);
    assert!(
        missing.stderr.contains("rules/justfile"),
        "{}",
        missing.stderr
    );

    fs::create_dir_all(root.join("rules")).unwrap();
    fs::write(
        root.join("rules").join("justfile"),
        format!(
            "open:\n    pwd\n    {} drawer toggle x --surface sessions\n",
            bench_bin().display()
        ),
    )
    .unwrap();
    let not_a_recipe = layout(
        &daemon.socket,
        "just/run",
        serde_json::json!({ "recipe": "--justfile" }),
        operator(),
        false,
    );
    assert_eq!(not_a_recipe["status"], "refused", "{not_a_recipe}");

    let started = ok_data(layout(
        &daemon.socket,
        "just/run",
        serde_json::json!({ "recipe": "open" }),
        operator(),
        false,
    ));
    let run = started["run"].as_str().unwrap().to_string();
    let logged = log_of(&root);
    let begun = logged
        .iter()
        .find(|e| e["kind"] == "just/started" && e["data"]["run"] == run.as_str())
        .unwrap_or_else(|| panic!("just/started is logged before the answer: {logged:?}"));
    assert_eq!(begun["data"]["by"], "operator");
    let finished = await_event(&root, "just/finished", &run);
    assert_eq!(finished["data"]["exit"], 0, "{finished}");
    let output = fs::read_to_string(started["log"].as_str().unwrap()).unwrap();
    let workspace = fs::canonicalize(&home.dir).unwrap();
    assert!(
        output.contains(&workspace.display().to_string())
            || output.contains(&home.dir.display().to_string()),
        "it ran at the active workspace: {output}"
    );
    let document = ok_data(layout(
        &daemon.socket,
        "bench/get",
        serde_json::Value::Null,
        None,
        false,
    ))["document"]
        .clone();
    assert_eq!(
        document["open_drawer"], "x",
        "the operator's recipe opened the drawer"
    );

    let by_agent = bench(&home.dir, &["just", "open"]);
    assert_eq!(by_agent.code, 0, "{}", by_agent.stderr);
    let agent_run = json_of(&by_agent)["run"].as_str().unwrap().to_string();
    let finished = await_event(&root, "just/finished", &agent_run);
    assert_ne!(
        finished["data"]["exit"], 0,
        "an agent's recipe cannot move the operator's focus: {finished}"
    );
    let output = fs::read_to_string(finished["data"]["log"].as_str().unwrap()).unwrap();
    assert!(
        output.contains("--asked"),
        "the refusal is in its log: {output}"
    );
}

/// A session claimed in a pane and resumed outside helm (`claude --resume` in another terminal
/// app: no `HELM_PANE`, on a terminal) leaves the pane: `mail/who` names nobody there, and the
/// session keeps its handle, so mail sent to it is still handed out. A report with no terminal
/// is a child that inherited the environment (#417) and changes nothing. Resumed in a pane
/// again, it answers there.
#[test]
fn a_session_resumed_outside_helm_leaves_its_pane_and_keeps_its_mail() {
    let home = TestHome::claim("wholeft");
    let h = &home.dir;
    let root = h.join(".bench");
    let daemon = DaemonGuard::start(h, None);
    let (_, in_pane) = terminal_process(h, "in-pane");
    let (_, outside) = terminal_process(h, "outside");
    let detached = Detached::start();
    let session = "5d1f0c2e-7a3b-4c8d-9e0f-1a2b3c4d5e6f";
    let report = |pid: u32, pane: Option<&str>, event: &str| {
        let mut args = serde_json::json!({"harness": "claude", "event": event, "tool": "Bash",
            "session": session, "cwd": "/Users/op/Projects/helm", "pid": pid});
        if let Some(pane) = pane {
            args["pane"] = pane.into();
        }
        hook_verb(&daemon.socket, args)
    };
    let who = || bench(h, &["mail", "who", "--pane", HOOK_PANE]);

    let handle = report(in_pane, Some(HOOK_PANE), "SessionStart")["handle"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(json_of(&who())["handle"], handle.as_str());

    // No terminal, no declaration: nothing is known about where it is, so nothing changes.
    report(detached.0.id(), None, "SessionStart");
    assert_eq!(who().code, 0, "a report with no terminal drops nothing");

    // Resumed in another terminal app.
    let reply = report(outside, None, "SessionStart");
    assert_eq!(reply["handle"], handle.as_str(), "same handle");
    let run = who();
    assert_eq!(run.code, 3, "the old pane names nobody: {}", run.stdout);
    let left: Vec<_> = event_kinds(h)
        .into_iter()
        .filter(|(k, d)| k == "mail/moved" && d["to"].is_null())
        .collect();
    assert_eq!(left.len(), 1, "{left:?}");
    assert!(
        hosted_record(&root)["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["id"] == session && s["via"]["handle"] == handle.as_str()),
        "the record keeps its handle"
    );

    // Mail to its handle still reaches it.
    let sent = bench(
        h,
        &["mail", "send", "--to", &handle, "--body", "still yours"],
    );
    assert_eq!(sent.code, 0, "{}", sent.stderr);
    let reply = report(outside, None, "PostToolUse");
    let context = reply["context"].as_str().unwrap_or_default();
    assert_eq!(context.matches("You have mail").count(), 1, "{reply}");

    // Resumed in a pane again: that pane answers.
    report(in_pane, Some(HOOK_PANE), "SessionStart");
    assert_eq!(json_of(&who())["handle"], handle.as_str());
}

// ---------------------------------------------------------------------------
// M3: the bench is the agent's whole surface — the CLI's pane verbs, spawn into a pane,
// attach that follows its viewer, and asking helm for what only helm can do
// ---------------------------------------------------------------------------

/// A renderable file under the test home, so `bench open` has something real to put up.
fn artifact(home: &Path, name: &str) -> String {
    let path = home.join(name);
    fs::write(&path, "# plan\n").unwrap();
    path.canonicalize().unwrap().display().to_string()
}

fn document(socket: &Path) -> serde_json::Value {
    ok_data(layout(
        socket,
        "bench/get",
        serde_json::Value::Null,
        None,
        false,
    ))["document"]
        .clone()
}

fn focused(socket: &Path) -> serde_json::Value {
    let doc = document(socket);
    let active = doc["active"].clone();
    let ws = doc["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["path"] == active)
        .cloned()
        .unwrap();
    let slot = ws["bench"]["focused_slot"].clone();
    ws["bench"]["columns"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|c| c["slots"].as_array().unwrap().clone())
        .find(|s| s["id"] == slot)
        .map(|s| s["selected"].clone())
        .unwrap()
}

#[test]
fn an_agents_pane_verbs_leave_the_operators_focus_until_it_says_he_asked() {
    let home = TestHome::claim("m3-verbs");
    let daemon = DaemonGuard::start(&home.dir, None);
    let (first, right, _canvas) = working_bench(&daemon.socket);
    let held = focused(&daemon.socket);
    let plan = artifact(&home.dir, "m3.md");

    let opened = bench(&home.dir, &["open", &plan]);
    assert_eq!(opened.code, 0, "{}", opened.stderr);
    let report = json_of(&opened);
    assert_eq!(report["focused_pane_before"], report["focused_pane_after"]);
    let split = bench(&home.dir, &["split", "down"]);
    assert_eq!(split.code, 0, "{}", split.stderr);
    let made = json_of(&split)["pane_created"]
        .as_str()
        .unwrap()
        .to_string();
    for args in [
        vec!["move", made.as_str(), "left"],
        vec!["name", made.as_str(), "scratch", "pad"],
    ] {
        let run = bench(&home.dir, &args);
        assert_eq!(run.code, 0, "{args:?}: {}", run.stderr);
    }
    assert_eq!(
        focused(&daemon.socket),
        held,
        "nothing above moved his focus"
    );

    // Every one was logged as the agent's, and none as asked.
    let changes: Vec<serde_json::Value> = log_of(&home.dir.join(".bench"))
        .into_iter()
        .filter(|e| e["kind"] == "bench/changed" && e["data"]["by"]["kind"] == "agent")
        .collect();
    assert_eq!(changes.len(), 4, "{changes:?}");
    assert!(changes.iter().all(|e| e["data"]["asked"] != true));

    // focus is the operator's: refused without --asked, done with it.
    let refused = bench(&home.dir, &["focus", &first]);
    assert_eq!(refused.code, 3);
    assert!(refused.stderr.contains("--asked"), "{}", refused.stderr);
    let asked = bench(&home.dir, &["focus", &first, "--asked"]);
    assert_eq!(asked.code, 0, "{}", asked.stderr);
    assert_eq!(focused(&daemon.socket), first.as_str());

    // A terminal ends what runs in it: --force, and the pane holding the keyboard also needs
    // --asked, whatever --force says.
    let refused = bench(&home.dir, &["close", &right]);
    assert_eq!(refused.code, 3);
    assert!(refused.stderr.contains("--force"), "{}", refused.stderr);
    let forced = bench(&home.dir, &["close", &right, "--force"]);
    assert_eq!(forced.code, 0, "{}", forced.stderr);
    let keyboard = bench(&home.dir, &["close", &first, "--force"]);
    assert_eq!(keyboard.code, 3);
    assert!(keyboard.stderr.contains("--asked"), "{}", keyboard.stderr);
}

#[test]
fn an_agent_replaces_a_chosen_name_only_when_it_says_the_operator_asked() {
    let home = TestHome::claim("m3-name");
    let daemon = DaemonGuard::start(&home.dir, None);
    let (first, _, _) = working_bench(&daemon.socket);
    ok_data(layout(
        &daemon.socket,
        "pane/name",
        serde_json::json!({ "pane": first, "name": { "source": "chosen", "text": "mine" } }),
        operator(),
        false,
    ));
    let refused = bench(&home.dir, &["name", &first, "theirs"]);
    assert_eq!(refused.code, 3);
    assert!(refused.stderr.contains("--rename"), "{}", refused.stderr);
    let renamed = bench(&home.dir, &["name", &first, "theirs", "--rename"]);
    assert_eq!(renamed.code, 0, "{}", renamed.stderr);
    let pane = json_of(&bench(&home.dir, &["get", "pane", &first]));
    assert_eq!(pane["pane"]["name"]["text"], "theirs");
}

#[test]
fn an_artifact_lands_in_the_workspace_of_the_agent_that_opened_it() {
    let home = TestHome::claim("m3-where");
    let daemon = DaemonGuard::start(&home.dir, None);
    let (in_first_workspace, _, _) = working_bench(&daemon.socket);
    // The operator moves on to another workspace; the agent is still in the first.
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": "/tmp/m3-other" }),
        operator(),
        false,
    ));
    let held = focused(&daemon.socket);
    let plan = artifact(&home.dir, "where.md");
    let opened = bench_as(
        &home.dir,
        &["open", &plan],
        &[("HELM_PANE", &in_first_workspace)],
    );
    assert_eq!(opened.code, 0, "{}", opened.stderr);
    let pane = json_of(&opened)["pane"].as_str().unwrap().to_string();
    let found = json_of(&bench(&home.dir, &["get", "pane", &pane]));
    assert_eq!(found["workspace"], "/tmp/m4-proof", "{found}");
    assert_eq!(
        found["visible"], false,
        "a background workspace is not on screen"
    );
    assert_eq!(focused(&daemon.socket), held);
    assert_eq!(document(&daemon.socket)["active"], "/tmp/m3-other");

    // A file helm cannot render, or none at all, never reaches the bench.
    let text = home.dir.join("notes.txt");
    fs::write(&text, "x").unwrap();
    let refused = bench(&home.dir, &["open", &text.display().to_string()]);
    assert_eq!(refused.code, 3);
    assert!(refused.stderr.contains("renders"), "{}", refused.stderr);
    assert_eq!(bench(&home.dir, &["open", "/nope/missing.md"]).code, 3);
}

#[test]
fn a_spawned_agent_arrives_in_a_pane_that_shows_its_session_without_taking_focus() {
    let home = TestHome::claim("m3-spawn");
    let daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    working_bench(&daemon.socket);
    let held = focused(&daemon.socket);
    let ws = workspace(&home.dir);
    let ws_path = ws.display().to_string();

    let spawned = bench(
        &home.dir,
        &["spawn", "--agent", "pi", "--cwd", &ws_path, "--name", "w1"],
    );
    assert_eq!(spawned.code, 0, "{}", spawned.stderr);
    let v = json_of(&spawned);
    let pane = v["pane"].as_str().unwrap().to_string();
    let session = v["session"].as_str().unwrap().to_string();
    assert_eq!(v["handle"], "w1");
    assert_eq!(v["workspace"], ws_path.as_str());
    assert_eq!(v["focused_pane_before"], v["focused_pane_after"]);
    assert_eq!(focused(&daemon.socket), held);

    let found = json_of(&bench(&home.dir, &["get", "pane", &pane]));
    assert_eq!(
        found["pane"]["surface"]["session"],
        session.as_str(),
        "{found}"
    );
    assert_eq!(found["pane"]["name"]["text"], "pi · ws");
    assert_eq!(found["visible"], false);
    let who = json_of(&bench(&home.dir, &["mail", "who", "--pane", &pane]));
    assert_eq!(who["handle"], "w1", "{who}");

    // A pane never names a session that is not running.
    let split = layout(
        &daemon.socket,
        "pane/split",
        serde_json::json!({ "direction": "right", "surface": { "kind": "terminal", "session": "s99" } }),
        operator(),
        false,
    );
    assert_eq!(split["status"], "refused", "{split}");

    // The pane ends what it shows only when told to. (A second agent first: a workspace's
    // last pane is not closed by anyone.)
    let second = bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", &ws_path]);
    assert_eq!(second.code, 0, "{}", second.stderr);
    let refused = bench(&home.dir, &["close", &pane]);
    assert_eq!(refused.code, 3);
    assert!(
        refused.stderr.contains("still running"),
        "{}",
        refused.stderr
    );
    let closed = bench(&home.dir, &["close", &pane, "--force"]);
    assert_eq!(closed.code, 0, "{}", closed.stderr);
    let kinds: Vec<String> = log_of(&home.dir.join(".bench"))
        .iter()
        .map(|e| e["kind"].as_str().unwrap().to_string())
        .collect();
    assert!(kinds.contains(&"session/closed".to_string()), "{kinds:?}");
    let listed = json_of(&bench(&home.dir, &["sessions"]));
    let listed = listed["sessions"].as_array().unwrap();
    assert!(
        listed.iter().all(|s| s["session"] != session.as_str()),
        "{listed:?}"
    );

    // Asked, it is brought forward: its workspace active, its pane focused.
    let asked = bench(
        &home.dir,
        &["spawn", "--agent", "pi", "--cwd", &ws_path, "--asked"],
    );
    assert_eq!(asked.code, 0, "{}", asked.stderr);
    let pane = json_of(&asked)["pane"].as_str().unwrap().to_string();
    assert_eq!(document(&daemon.socket)["active"], ws_path.as_str());
    assert_eq!(focused(&daemon.socket), pane.as_str());
}

#[test]
fn a_restarted_daemon_forgets_the_sessions_its_panes_named() {
    let home = TestHome::claim("m3-restart");
    let ws = workspace(&home.dir).display().to_string();
    let pane = {
        let _daemon = DaemonGuard::start_with_fake_pi(&home.dir);
        let run = bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", &ws]);
        assert_eq!(run.code, 0, "{}", run.stderr);
        json_of(&run)["pane"].as_str().unwrap().to_string()
    };
    let _daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    let found = json_of(&bench(&home.dir, &["get", "pane", &pane]));
    assert!(
        found["pane"]["surface"].get("session").is_none(),
        "no session outlives its daemon: {found}"
    );
    assert_eq!(
        found["pane"]["surface"]["agent"]["command"], "pi",
        "the resume record stays"
    );
    let kinds: Vec<String> = log_of(&home.dir.join(".bench"))
        .iter()
        .map(|e| e["kind"].as_str().unwrap().to_string())
        .collect();
    assert!(
        kinds.contains(&"bench/sessions-ended".to_string()),
        "{kinds:?}"
    );
}

#[test]
fn a_refused_spawn_leaves_no_process_and_no_pane() {
    let home = TestHome::claim("m3-norun");
    let daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    working_bench(&daemon.socket);
    let before = document(&daemon.socket);
    let ws = workspace(&home.dir).display().to_string();
    for (args, rule) in [
        (vec!["--name", "operator"], "operator"),
        (vec!["--resume", "--looks-like-a-flag"], "--resume"),
    ] {
        let mut cmd = vec!["spawn", "--agent", "pi", "--cwd", ws.as_str()];
        cmd.extend(args);
        let run = bench(&home.dir, &cmd);
        assert_eq!(run.code, 3, "{cmd:?}: {}", run.stderr);
        assert!(run.stderr.contains(rule), "{}", run.stderr);
    }
    let codex = bench(
        &home.dir,
        &["spawn", "--agent", "codex", "--cwd", &ws, "--resume", "x1"],
    );
    assert_eq!(codex.code, 3, "{}", codex.stderr);
    assert_eq!(document(&daemon.socket), before);
    let listed = json_of(&bench(&home.dir, &["sessions"]));
    assert!(
        listed["sessions"].as_array().unwrap().is_empty(),
        "{listed}"
    );
}

#[test]
fn an_attached_viewer_resizes_the_session_and_ends_when_it_does() {
    let home = TestHome::claim("m3-attach");
    // The agent reports its size whenever the pty's changes.
    let bin = home.dir.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let agent = bin.join("pi");
    fs::write(
        &agent,
        "#!/bin/sh\ntrap 'stty size' WINCH\necho ready\nwhile :; do sleep 0.1; done\n",
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&agent, fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::var("PATH").unwrap_or_default();
    let mut cmd = isolated(benchd_bin());
    cmd.env("PATH", format!("{}:{path}", bin.display()));
    let daemon = DaemonGuard::start_with(&home.dir, None, cmd);
    let ws = workspace(&home.dir).display().to_string();
    let run = bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", &ws]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let sid = json_of(&run)["session"].as_str().unwrap().to_string();

    let (resp, stream) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": sid}),
    );
    assert_eq!(resp["status"], "ok", "{resp}");
    // Wait until the agent is running its trap before resizing, or the signal lands first.
    let mut seen = Vec::new();
    let mut chunk = [0u8; 4096];
    let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && !String::from_utf8_lossy(&seen).contains("ready") {
        if let Ok(n) = (&stream).read(&mut chunk) {
            seen.extend_from_slice(&chunk[..n]);
        }
    }
    seen.clear();
    let (resized, _) = raw_request(
        &daemon.socket,
        "resize",
        serde_json::json!({"session": sid, "rows": 33, "cols": 77}),
    );
    assert_eq!(resized["status"], "ok", "{resized}");
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && !String::from_utf8_lossy(&seen).contains("33 77") {
        if let Ok(n) = (&stream).read(&mut chunk) {
            seen.extend_from_slice(&chunk[..n]);
        }
    }
    assert!(
        String::from_utf8_lossy(&seen).contains("33 77"),
        "the agent sees the viewer's size: {:?}",
        String::from_utf8_lossy(&seen)
    );
    drop(stream);

    // A real `bench attach`: when the agent ends by itself, so does the viewer. `cat` ends at
    // the Ctrl-D below.
    let run = bench(&home.dir, &["spawn", "--agent", "test-echo", "--cwd", &ws]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let sid = json_of(&run)["session"].as_str().unwrap().to_string();
    let echo_pane = json_of(&run)["pane"].as_str().unwrap().to_string();
    let mut viewer = isolated(bench_bin())
        .args(["attach", &sid])
        .env("HOME", &home.dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(300));
    // Ctrl-D at an empty line is end of input to `cat`, which exits.
    viewer.stdin.as_mut().unwrap().write_all(b"\x04").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = viewer.try_wait().unwrap() {
            break Some(status);
        }
        if Instant::now() > deadline {
            let _ = viewer.kill();
            let _ = viewer.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let status = status.expect("the viewer ends when its session does");
    assert_eq!(status.code(), Some(0));
    let mut stderr = String::new();
    viewer
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut stderr)
        .unwrap();
    assert!(stderr.contains("stream closed"), "{stderr}");
    // Nothing runs in its pane any more, so closing it needs no --force.
    let closed = bench(&home.dir, &["close", &echo_pane]);
    assert_eq!(closed.code, 0, "{}", closed.stderr);
}

#[test]
fn a_screenshot_is_helms_answer_and_no_helm_is_an_error_naming_it() {
    let home = TestHome::claim("m3-shot");
    let daemon = DaemonGuard::start(&home.dir, None);
    let out = home.dir.join("shot.png").display().to_string();

    // A stand-in for helm: follow the bench, answer each ask with what a capture reports.
    let socket = daemon.socket.clone();
    let helm = std::thread::spawn(move || {
        let mut reader = follow(&socket);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        loop {
            line.clear();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                return;
            }
            let frame: serde_json::Value = serde_json::from_str(&line).unwrap();
            if frame["event"]["kind"] != "helm/asked" {
                continue;
            }
            let data = &frame["event"]["data"];
            let answer = layout(
                &socket,
                "helm/answer",
                serde_json::json!({
                    "ask": data["ask"],
                    "status": "ok",
                    "data": { "path": data["request"]["path"], "window": "helm — m3" },
                }),
                Some(serde_json::json!({ "kind": "helm" })),
                false,
            );
            assert_eq!(answer["status"], "ok", "{answer}");
            return;
        }
    });
    let shot = bench(&home.dir, &["get", "screenshot", "--out", &out]);
    assert_eq!(shot.code, 0, "{}", shot.stderr);
    assert_eq!(json_of(&shot)["path"], out.as_str());
    helm.join().unwrap();

    // An answer nobody waits for is refused, not delivered to the next ask.
    let late = layout(
        &daemon.socket,
        "helm/answer",
        serde_json::json!({ "ask": "a1", "status": "ok" }),
        None,
        false,
    );
    assert_eq!(late["status"], "refused", "{late}");

    // With nothing following, the caller is told why rather than left waiting.
    let started = Instant::now();
    let alone = bench(&home.dir, &["get", "screenshot", "--out", &out]);
    assert_eq!(alone.code, 4, "{}", alone.stderr);
    assert!(
        alone.stderr.contains("no helm answered"),
        "{}",
        alone.stderr
    );
    assert!(started.elapsed() < Duration::from_secs(15));
    let kinds: Vec<String> = log_of(&home.dir.join(".bench"))
        .iter()
        .map(|e| e["kind"].as_str().unwrap().to_string())
        .collect();
    for kind in ["helm/asked", "helm/answered", "helm/unanswered"] {
        assert!(kinds.contains(&kind.to_string()), "{kind}: {kinds:?}");
    }
}

#[test]
fn the_bench_panes_skills_snippets_execute_against_a_real_daemon() {
    // Executed, never restated: every ```bash fence in SKILL.md runs in order, as an agent,
    // against a throwaway root, with the variables its prose names.
    let skill = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.claude/skills/bench-panes/SKILL.md"),
    )
    .expect("bench-panes SKILL.md readable");
    let mut snippets: Vec<String> = Vec::new();
    let mut current: Option<String> = None;
    for line in skill.lines() {
        match (&mut current, line.trim()) {
            (None, "```bash") => current = Some(String::new()),
            (Some(buf), "```") => {
                snippets.push(std::mem::take(buf));
                current = None;
            }
            (Some(buf), _) => {
                buf.push_str(line);
                buf.push('\n');
            }
            _ => {}
        }
    }
    assert_eq!(snippets.len(), 4, "open, get pane, spawn, tidy up");

    let home = TestHome::claim("m3-skill");
    let daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    working_bench(&daemon.socket);
    let held = focused(&daemon.socket);
    let ws = workspace(&home.dir);
    let plan = artifact(&home.dir, "skill.md");
    let brief = artifact(&home.dir, "brief.md");
    let mut pane = String::new();
    for (i, snippet) in snippets.iter().enumerate() {
        let out = isolated("bash")
            .args(["-euo", "pipefail", "-c", snippet])
            .current_dir(&ws)
            .env("HOME", &home.dir)
            .env("BENCH_DIR", home.dir.join(".bench"))
            .env("BENCH", bench_bin())
            .env("ARTIFACT", &plan)
            .env("PANE", &pane)
            .env("AGENT", "pi")
            .env("WORKTREE", &ws)
            .env("HANDLE", "helper")
            .env("BRIEF", &brief)
            .output()
            .expect("run snippet");
        let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
        assert!(
            out.status.success(),
            "SKILL.md snippet {} failed (exit {:?}):\n{}\n--- stderr:\n{}",
            i + 1,
            out.status.code(),
            snippet,
            String::from_utf8_lossy(&out.stderr)
        );
        if i == 0 {
            pane = stdout.trim().to_string();
        }
        if i == 2 {
            assert!(stdout.starts_with("helper "), "{stdout}");
        }
    }
    assert_eq!(
        focused(&daemon.socket),
        held,
        "no snippet took his keyboard"
    );
    assert!(
        bench(&home.dir, &["get", "pane", &pane]).code == 3,
        "the tidy-up closed the canvas it opened"
    );
}

#[test]
fn a_spawned_agents_verbs_name_the_pane_that_shows_it() {
    // An agent `bench spawn` started has no HELM_PANE, only its BENCH_HANDLE. benchd fills in the
    // pane showing its live session, so the logged `by` names where it runs: that is how helm
    // remembers which agent opened a canvas (#205), and where its canvas lands.
    let home = TestHome::claim("m3-placed");
    let daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    working_bench(&daemon.socket);
    let ws = workspace(&home.dir).display().to_string();
    let spawned = json_of(&bench(
        &home.dir,
        &["spawn", "--agent", "pi", "--cwd", &ws, "--name", "opener"],
    ));
    let pane = spawned["pane"].as_str().unwrap().to_string();
    let plan = artifact(&home.dir, "placed.md");

    let opened = bench_as(&home.dir, &["open", &plan], &[("BENCH_HANDLE", "opener")]);
    assert_eq!(opened.code, 0, "{}", opened.stderr);
    let canvas = json_of(&opened)["pane"].as_str().unwrap().to_string();

    let change = log_of(&home.dir.join(".bench"))
        .into_iter()
        .rev()
        .find(|e| e["kind"] == "bench/changed" && e["data"]["verb"] == "pane/open")
        .unwrap();
    assert_eq!(change["data"]["by"]["pane"], pane.as_str(), "{change}");
    assert_eq!(change["data"]["by"]["handle"], "opener");
    let found = json_of(&bench(&home.dir, &["get", "pane", &canvas]));
    assert_eq!(
        found["workspace"],
        ws.as_str(),
        "it lands in the agent's own workspace"
    );
}

#[test]
fn the_helm_canvas_skills_snippets_execute_against_a_real_daemon() {
    // The canvas skill puts an artifact on the bench with `bench open` since push.sh retired
    // (M3). Its snippets run here, in order, as an agent, the way bench-panes' do.
    let skill = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.claude/skills/helm-canvas/SKILL.md"),
    )
    .expect("helm-canvas SKILL.md readable");
    let mut snippets: Vec<String> = Vec::new();
    let mut current: Option<String> = None;
    for line in skill.lines() {
        match (&mut current, line.trim()) {
            (None, "```bash") => current = Some(String::new()),
            (Some(buf), "```") => {
                snippets.push(std::mem::take(buf));
                current = None;
            }
            (Some(buf), _) => {
                buf.push_str(line);
                buf.push('\n');
            }
            _ => {}
        }
    }
    assert_eq!(snippets.len(), 2, "open, then show and take away");

    let home = TestHome::claim("canvas-skill");
    let daemon = DaemonGuard::start(&home.dir, None);
    working_bench(&daemon.socket);
    // The operator works in a terminal of his own, so the canvas slot is not his and `show`
    // there moves nothing (showing a tab of *his* slot is refused, as the skill says).
    ok_data(layout(
        &daemon.socket,
        "pane/split",
        serde_json::json!({ "direction": "right" }),
        operator(),
        false,
    ));
    let held = focused(&daemon.socket);
    let plan = artifact(&home.dir, "canvas-skill.md");
    let mut pane = String::new();
    for (i, snippet) in snippets.iter().enumerate() {
        let out = isolated("bash")
            .args(["-euo", "pipefail", "-c", snippet])
            .current_dir(&home.dir)
            .env("HOME", &home.dir)
            .env("BENCH_DIR", home.dir.join(".bench"))
            .env("BENCH", bench_bin())
            .env("ARTIFACT", &plan)
            .env("PANE", &pane)
            .output()
            .expect("run snippet");
        assert!(
            out.status.success(),
            "SKILL.md snippet {} failed (exit {:?}):\n{}\n--- stderr:\n{}",
            i + 1,
            out.status.code(),
            snippet,
            String::from_utf8_lossy(&out.stderr)
        );
        if i == 0 {
            pane = String::from_utf8_lossy(&out.stdout).trim().to_string();
            assert!(bench_doc::PaneId::parse(&pane).is_ok(), "{pane:?}");
        }
    }
    assert_eq!(
        focused(&daemon.socket),
        held,
        "no snippet took his keyboard"
    );
    assert_eq!(
        bench(&home.dir, &["get", "pane", &pane]).code,
        3,
        "the canvas was closed"
    );
}
