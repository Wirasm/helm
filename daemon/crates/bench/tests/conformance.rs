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
use std::io::{BufRead, BufReader, Read, Write};
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
        DaemonGuard::start_with(home, suite, Command::new(benchd_bin()))
    }

    /// A daemon whose `pi` is [`write_fake_pi`]'s: a real harness name, so its sessions are
    /// rows in `sessions/all`, and no real agent behind it.
    fn start_with_fake_pi(home: &Path) -> DaemonGuard {
        let bin = write_fake_pi(home);
        let path = std::env::var("PATH").unwrap_or_default();
        let mut cmd = Command::new(benchd_bin());
        cmd.env("PATH", format!("{}:{path}", bin.display()));
        DaemonGuard::start_with(home, None, cmd)
    }

    fn start_with(home: &Path, suite: Option<&str>, mut cmd: Command) -> DaemonGuard {
        cmd.env_remove("BENCH_DIR")
            .env_remove("BENCH_SUITE")
            // The browser's default binary is looked up in the Playwright cache under
            // HOME; a runner's own override must not reach past the test home.
            .env_remove("PLAYWRIGHT_BROWSERS_PATH")
            // helm's snapshot is found under HOME; a runner's override must not reach past it.
            .env_remove("HELM_BENCH_DIR")
            .env("BENCH_SESSION_TEST_AGENT", "1")
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
fn run_bounded(cmd: &mut Command, deadline: Duration) -> Option<CliRun> {
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

    let mut cmd = Command::new(benchd_bin());
    cmd.env_remove("BENCH_SUITE")
        .env("HOME", &home.dir)
        .env("BENCH_DIR", &root);
    cmd.stdout(Stdio::null()).stderr(Stdio::null());
    let mut child = cmd.spawn().unwrap();
    let socket = root.join("benchd.sock");
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && UnixStream::connect(&socket).is_err() {
        std::thread::sleep(Duration::from_millis(20));
    }

    let status = Command::new(bench_bin())
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

    let out = Command::new(benchd_bin())
        .env_remove("BENCH_SUITE")
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
        Command::new(bench_bin())
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
        Command::new(bench_bin())
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
        let out = Command::new("ps")
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

/// `<home>/bin/pi`: a stand-in that reads its pty and prints nothing, so it is idle, live,
/// and dies when its pid is killed. Returns the directory to put on the daemon's PATH.
fn write_fake_pi(home: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let pi = bin.join("pi");
    fs::write(&pi, "#!/bin/sh\nexec cat\n").unwrap();
    fs::set_permissions(&pi, fs::Permissions::from_mode(0o755)).unwrap();
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
            wakeable: true,
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
    // wakeable is what a send does: queued for the live session, not for the operator.
    assert_eq!(send("worker"), "queued");
    assert_eq!(send("operator"), "no-live-session");
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
    assert_eq!(send("worker"), "no-live-session");
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
        sent["wake"], "no-live-session",
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
fn a_send_to_a_live_session_wakes_it_with_a_path_never_the_body() {
    let home = TestHome::claim("wake");
    let daemon = DaemonGuard::start(&home.dir, None);
    let spawn = bench(
        &home.dir,
        &[
            "spawn",
            "--agent",
            "test-echo",
            "--cwd",
            "/tmp",
            "--name",
            "echo1",
        ],
    );
    assert_eq!(spawn.code, 0, "stderr: {}", spawn.stderr);

    let send = bench(
        &home.dir,
        &[
            "mail",
            "send",
            "--to",
            "echo1",
            "--body",
            "SECRET-BODY-99",
            "--subject",
            "ping",
        ],
    );
    assert_eq!(send.code, 0, "stderr: {}", send.stderr);
    let sent: serde_json::Value = serde_json::from_str(&send.stdout).unwrap();
    assert_eq!(sent["wake"], "queued");
    let id = sent["id"].as_str().unwrap().to_string();

    // The reactor pastes the notice into the pty; cat echoes it into the ring, which an
    // attach replays — the production wake path observed end to end.
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let log = fs::read_to_string(home.dir.join(".bench/events.jsonl")).unwrap_or_default();
        if log.contains("agent/woken") {
            break;
        }
        assert!(Instant::now() < deadline, "the wake never happened: {log}");
        std::thread::sleep(Duration::from_millis(200));
    }
    let (resp, stream) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": "s1"}),
    );
    assert_eq!(resp["status"], "ok");
    let _ = stream.set_read_timeout(Some(Duration::from_millis(300)));
    let mut seen = Vec::new();
    let mut chunk = [0u8; 4096];
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        match (&stream).read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => seen.extend_from_slice(&chunk[..n]),
            Err(_) => {}
        }
        if String::from_utf8_lossy(&seen).contains("You have mail") {
            break;
        }
    }
    let text = String::from_utf8_lossy(&seen);
    assert!(
        text.contains("You have mail from operator"),
        "the notice names the sender: {text}"
    );
    assert!(
        text.contains("/read/"),
        "the notice carries the retired path: {text}"
    );
    assert!(
        !text.contains("SECRET-BODY-99"),
        "the notice must NEVER carry the body: {text}"
    );

    // Retired at delivery: the notice's path is where the file already lives.
    let mailbox = home.dir.join(".bench/mail/echo1");
    assert!(mailbox.join("read").join(format!("{id}.md")).exists());
}

#[test]
fn the_wake_cap_starves_wakes_never_mail() {
    let home = TestHome::claim("cap");
    let _daemon = DaemonGuard::start(&home.dir, None);
    let spawn = bench(
        &home.dir,
        &[
            "spawn",
            "--agent",
            "test-echo",
            "--cwd",
            "/tmp",
            "--name",
            "echo2",
        ],
    );
    assert_eq!(spawn.code, 0, "stderr: {}", spawn.stderr);
    for i in 0..9 {
        let send = bench(
            &home.dir,
            &[
                "mail",
                "send",
                "--to",
                "echo2",
                "--body",
                &format!("msg {i}"),
            ],
        );
        assert_eq!(send.code, 0, "send {i} failed: {}", send.stderr);
    }
    // Six tokens of burst; the seventh-plus wake must be capped and say so.
    let deadline = Instant::now() + Duration::from_secs(60);
    let (mut woken, mut capped);
    loop {
        let log = fs::read_to_string(home.dir.join(".bench/events.jsonl")).unwrap_or_default();
        woken = log.matches("agent/woken").count();
        capped = log.matches("wake/capped").count();
        if capped >= 1 && woken >= 6 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "cap never engaged: woken={woken} capped={capped}"
        );
        std::thread::sleep(Duration::from_millis(300));
    }
    assert!(
        woken <= 6,
        "the burst budget is six; {woken} wakes happened"
    );
    // The starved mail is safe in the inbox, unread — the cap brakes wakes, never mail.
    let listing = bench(&home.dir, &["mail", "list", "--handle", "echo2"]);
    assert!(
        listing.stdout.contains("\"unread\": true"),
        "capped mail waits unread: {}",
        listing.stdout
    );
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
        let out = Command::new("bash")
            .args(["-euo", "pipefail", "-c", snippet])
            .current_dir(&ws)
            .env_remove("BENCH_SUITE")
            .env_remove("BENCH_HANDLE")
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
    assert!(who.contains("worker wakeable"), "{who}");
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
        let out = Command::new("bash")
            .args(["-c", snippet])
            .current_dir(&ws)
            .env_remove("BENCH_SUITE")
            .env_remove("BENCH_HANDLE")
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
    let out = Command::new("bash")
        .args(["-euo", "pipefail", "-c", &snippets[0]])
        .env_remove("BENCH_SUITE")
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
    let refused = Command::new("bash")
        .args(["-c", &snippets[0]])
        .env_remove("BENCH_SUITE")
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
        ("pane/close", serde_json::json!({ "pane": right })),
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
        serde_json::json!({ "pane": held }),
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
        serde_json::json!({ "pane": held }),
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
    let mut child = Command::new(bench_bin())
        .env_remove("BENCH_DIR")
        .env_remove("BENCH_SUITE")
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
