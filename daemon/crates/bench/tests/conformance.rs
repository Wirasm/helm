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

use bench_wire::attach::AttachFrame;

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
/// `BENCH_ASKED=1`. `PLAYWRIGHT_BROWSERS_PATH` overrides a root benchd otherwise finds under
/// HOME (the browser's Playwright cache).
const INHERITED: &[&str] = &[
    "BENCH_DIR",
    "BENCH_SUITE",
    "BENCH_SESSION",
    "BENCH_HANDLE",
    "BENCH_ASKED",
    // A benchd by address (M5c): a test run from a pane of a remote helm inherits BENCH_URL,
    // which outranks every root the test claims.
    "BENCH_URL",
    "BENCH_LISTEN",
    "HELM_PANE",
    "PLAYWRIGHT_BROWSERS_PATH",
    // prp's store home, which `prp/*` reads and writes: the test's HOME decides it, never the
    // operator's `~/.prp`.
    "PRP_HOME",
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
        static SWEPT: std::sync::Once = std::sync::Once::new();
        SWEPT.call_once(sweep_dead_runs);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("bcf-{}-{n}", std::process::id()));
        fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("claim home for {label}: {e}"));
        TestHome { dir }
    }
}

/// Remove the homes of runs that died before their Drop ran: a killed or aborted test binary.
/// The pid in the name is the owner, so a home is removed only once no process has that pid;
/// another worktree's run in progress keeps its homes.
fn sweep_dead_runs() {
    let Ok(entries) = fs::read_dir(std::env::temp_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(pid) = name
            .to_str()
            .and_then(|n| n.strip_prefix("bcf-"))
            .and_then(|rest| rest.split_once('-'))
            .and_then(|(pid, _)| pid.parse::<i32>().ok())
        else {
            continue;
        };
        // SAFETY: signal 0 only asks whether the pid exists.
        let gone = unsafe { libc::kill(pid, 0) } != 0
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
        if gone {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
}

impl Drop for TestHome {
    fn drop(&mut self) {
        // A session's shell writes its history into this HOME as it exits, and the daemon's
        // Drop has only just hung it up: a write that lands mid-removal fails the removal and
        // left the directory behind. Retry until the late writer is done.
        for _ in 0..40 {
            if fs::remove_dir_all(&self.dir).is_ok() || !self.dir.exists() {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
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
        DaemonGuard::start_with_script(home, agent, "exec cat")
    }

    /// A daemon whose `agent` runs `body` under `/bin/sh`.
    fn start_with_script(home: &Path, agent: &str, body: &str) -> DaemonGuard {
        let bin = write_agent_script(home, agent, body);
        let path = std::env::var("PATH").unwrap_or_default();
        let mut cmd = isolated(benchd_bin());
        cmd.env("PATH", format!("{}:{path}", bin.display()));
        DaemonGuard::start_with(home, None, cmd)
    }

    fn start_with(home: &Path, suite: Option<&str>, cmd: std::process::Command) -> DaemonGuard {
        DaemonGuard::try_start_with(home, suite, cmd)
            .unwrap_or_else(|why| panic!("benchd did not start: {why}"))
    }

    /// Start benchd and wait for its socket; `Err` with how it ended when it exits first (a
    /// refused start, such as a TCP address it could not bind), rather than waiting out the
    /// deadline for a socket that will never come.
    fn try_start_with(
        home: &Path,
        suite: Option<&str>,
        mut cmd: std::process::Command,
    ) -> Result<DaemonGuard, String> {
        // Every terminal pane runs a login shell (M5b): a known one, reading nothing of the
        // operator's configuration.
        cmd.env("BENCH_SESSION_TEST_AGENT", "1")
            .env("SHELL", "/bin/sh")
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
        let mut guard = DaemonGuard { child, socket };
        guard.await_socket()?;
        Ok(guard)
    }

    fn await_socket(&mut self) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if UnixStream::connect(&self.socket).is_ok() {
                return Ok(());
            }
            if let Ok(Some(status)) = self.child.try_wait() {
                return Err(format!("benchd exited ({status}) before it answered"));
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

/// Read `stream` until `done` says what arrived is enough, or `limit` passes. The stream's own
/// read timeout decides how often `done` is asked.
fn read_until(stream: &UnixStream, limit: Duration, done: impl Fn(&[u8]) -> bool) -> Vec<u8> {
    let deadline = Instant::now() + limit;
    let mut seen = Vec::new();
    let mut chunk = [0u8; 4096];
    while Instant::now() < deadline && !done(&seen) {
        match (&*stream).read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => seen.extend_from_slice(&chunk[..n]),
            Err(_) => {}
        }
    }
    seen
}

/// `bench attach <session> <extra…>` with a pty of its own as its terminal and controlling
/// terminal, the way a helm pane runs it: the pty is the size given, and resizing the returned
/// master is what a pane being dragged does. Answers the master and the child.
fn attach_on_pty(
    home: &Path,
    session: &str,
    extra: &[&str],
    rows: u16,
    cols: u16,
) -> (fs::File, Child) {
    attach_on_pty_with(home, session, extra, rows, cols, &[])
}

/// [`attach_on_pty`], with `env` set on the client.
fn attach_on_pty_with(
    home: &Path,
    session: &str,
    extra: &[&str],
    rows: u16,
    cols: u16,
    env: &[(&str, &str)],
) -> (fs::File, Child) {
    use rustix::pty::{OpenptFlags, grantpt, openpt, ptsname, unlockpt};
    use std::os::unix::process::CommandExt;
    let master = openpt(OpenptFlags::RDWR | OpenptFlags::NOCTTY).unwrap();
    grantpt(&master).unwrap();
    unlockpt(&master).unwrap();
    let name = ptsname(&master, Vec::new()).unwrap();
    let slave = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(name.to_str().unwrap())
        .unwrap();
    let master = fs::File::from(master);
    set_size(&master, rows, cols);
    let mut cmd = isolated(bench_bin());
    cmd.envs(env.iter().copied());
    cmd.arg("attach")
        .arg(session)
        .args(extra)
        .env("HOME", home)
        .stdin(slave.try_clone().unwrap())
        .stdout(slave.try_clone().unwrap())
        .stderr(slave);
    // SAFETY: setsid and the TIOCSCTTY ioctl are async-signal-safe and allocate nothing.
    unsafe {
        cmd.pre_exec(|| {
            rustix::process::setsid()?;
            rustix::process::ioctl_tiocsctty(rustix::fd::BorrowedFd::borrow_raw(0))?;
            Ok(())
        });
    }
    let child = cmd.spawn().unwrap();
    (master, child)
}

/// Resize a pty from its master: the kernel sends SIGWINCH to its foreground process group.
fn set_size(master: &fs::File, rows: u16, cols: u16) {
    rustix::termios::tcsetwinsize(
        master,
        rustix::termios::Winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        },
    )
    .unwrap();
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
    // M5a's named assumption: an OSC sequence written by the agent must cross the relay
    // byte-for-byte, because whatever terminal hosts `bench attach` is what parses it —
    // in helm, ghostty reads titles, OSC 9/777 notifications and OSC 133 from it. (This
    // was once the canvas-passthrough proof; a canvas arrives through `bench open` now.)
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

    // cat echoes what the pty carries; every sequence helm reads off a terminal must come back
    // intact, because the Ghostty hosting `bench attach` is what parses them. Each is its own
    // line: the pty's line discipline is cooked, and a line is what `cat` echoes.
    let sequences = [
        "\u{1b}]777;notify;helm.canvas;/tmp/proof.html\u{7}", // notification (OSC 777)
        "\u{1b}]0;a title\u{7}",                              // title
        "\u{1b}]2;another title\u{1b}\\",                     // title, ST-terminated
        "\u{1b}]7;file://host/tmp/work\u{7}",                 // working directory
        "\u{1b}]8;;https://example.com\u{7}link\u{1b}]8;;\u{7}", // hyperlink
        "\u{1b}]9;4;1;42\u{7}",                               // progress
        "\u{1b}]52;c;aGVsbG8=\u{7}",                          // clipboard write
        "\u{1b}]133;A\u{7}",                                  // prompt mark
        "\u{1b}]133;D;0\u{7}",                                // command finished
        "\u{1b}[?2004h",                                      // bracketed paste on
        "\u{1b}[200~pasted\u{1b}[201~",                       // a bracketed paste
    ];
    for seq in sequences {
        let payload = format!("before {seq} after\n");
        (&stream)
            .write_all(&AttachFrame::Input(payload.into_bytes()).encode())
            .unwrap();
    }
    let _ = stream.set_read_timeout(Some(Duration::from_millis(300)));
    let has = |seen: &[u8], seq: &str| seen.windows(seq.len()).any(|w| w == seq.as_bytes());
    let seen = read_until(&stream, Duration::from_secs(5), |seen| {
        sequences.iter().all(|seq| has(seen, seq))
    });
    for seq in sequences {
        assert!(
            has(&seen, seq),
            "{seq:?} must survive the relay byte-for-byte; got {} bytes: {:?}",
            seen.len(),
            String::from_utf8_lossy(&seen)
        );
    }

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
    // The test agent has nothing to resume — the refusal says why.
    assert!(
        attach.stderr.contains("no conversation to resume"),
        "the refusal says why: {}",
        attach.stderr
    );
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
    write_agent_script(home, agent, "exec cat")
}

fn write_agent_script(home: &Path, agent: &str, body: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let path = bin.join(agent);
    fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
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
/// `--fake-port=<n>` names that port in `DevToolsActivePort`, for a test that serves it.
fn write_fake_browser(home: &Path) -> PathBuf {
    let path = home.join("fake-chromium");
    fs::write(
        &path,
        r#"#!/bin/sh
if [ "$1" = "--version" ]; then echo "Fake Chromium 142.0.7000.1"; exit 0; fi
dir=""; die=""; port=$(( $$ % 40000 + 20000 ))
for a in "$@"; do
  case "$a" in
    --user-data-dir=*) dir="${a#--user-data-dir=}" ;;
    --fake-port=*) port="${a#--fake-port=}" ;;
    --die-after=*) die="${a#--die-after=}" ;;
    --slow-start=*) sleep "${a#--slow-start=}" ;;
  esac
done
printf '%s\n' "$@" > "$dir/argv"
trap 'exit 0' TERM
printf '%s\n/devtools/browser/fake-%s\n' "$port" "$$" > "$dir/port.tmp"
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

    // Agents and `playwright-cli` read this file outside the workspace, so its keys are pinned to
    // one checked-in sample. helm no longer reads it (M5c: its pane asks `browser/connect`).
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
        "endpoint.json drifted from its pinned fixture"
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

/// The canvases the M4 tests open under `/tmp/m4-proof`: benchd opens only a file it finds.
/// Written if absent, never removed, so tests running at once share them safely.
fn m4_proof() {
    let dir = Path::new("/tmp/m4-proof");
    fs::create_dir_all(dir).unwrap();
    for name in ["plan", "review", "tasks", "drawers", "a", "b", "c", "d"] {
        let file = dir.join(format!("{name}.md"));
        if !file.exists() {
            fs::write(file, format!("# {name}\n")).unwrap();
        }
    }
}

/// The operator's working bench: a workspace, a second terminal to the right, and a canvas.
/// Answers the pane ids: (first terminal, right terminal, canvas).
fn working_bench(socket: &Path) -> (String, String, String) {
    m4_proof();
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

/// A drop (#178) is `pane/move` with a place named by ids: `tab` into a slot before a pane, and
/// `beside` a slot. Driven through the socket so the arm in benchd's `layout.rs` is the one
/// tested, not only `bench-doc`'s rules.
#[test]
fn a_pane_dropped_as_a_tab_or_beside_a_slot_lands_there() {
    let home = TestHome::claim("m4-drop");
    let daemon = DaemonGuard::start(&home.dir, None);
    let (first, _, canvas) = working_bench(&daemon.socket);
    let bench = |socket: &Path| {
        ok_data(layout(
            socket,
            "bench/get",
            serde_json::Value::Null,
            None,
            false,
        ))["document"]["workspaces"][0]["bench"]
            .clone()
    };
    let slot_of = |bench: &serde_json::Value, pane: &str| -> serde_json::Value {
        bench["columns"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|c| c["slots"].as_array().unwrap().iter())
            .find(|s| {
                s["panes"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|p| p["id"] == pane)
            })
            .unwrap()
            .clone()
    };
    let target = slot_of(&bench(&daemon.socket), &first)["id"].clone();

    ok_data(layout(
        &daemon.socket,
        "pane/move",
        serde_json::json!({ "pane": canvas, "to": { "tab": { "slot": target, "before": first } } }),
        operator(),
        false,
    ));
    let ids: Vec<_> = slot_of(&bench(&daemon.socket), &first)["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        ids,
        vec![canvas.clone(), first.clone()],
        "a tab, before the pane named"
    );

    ok_data(layout(
        &daemon.socket,
        "pane/move",
        serde_json::json!({ "pane": canvas, "to": { "beside": { "slot": target, "side": "down" } } }),
        operator(),
        false,
    ));
    let after = bench(&daemon.socket);
    let column = after["columns"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["slots"][0]["id"] == target)
        .unwrap();
    assert_eq!(
        column["slots"][1]["panes"][0]["id"], canvas,
        "a row of its own below"
    );
}

/// `bench move` reaches every place a drag in helm can drop a pane (#178): a slot's tab strip,
/// beside a slot, and another workspace. An agent finds the slot with `bench get pane`.
#[test]
fn bench_move_reaches_every_drop_destination() {
    let home = TestHome::claim("m4-move-cli");
    let daemon = DaemonGuard::start(&home.dir, None);
    // `canvas` holds the keyboard, so `right` and `first` are the agent's to move.
    let (first, right, _canvas) = working_bench(&daemon.socket);
    let pane = |id: &str| {
        let run = bench(&home.dir, &["get", "pane", id]);
        assert_eq!(run.code, 0, "{}", run.stderr);
        json_of(&run)
    };
    let first_slot = pane(&first)["slot"].as_str().unwrap().to_string();
    let moved = |args: &[&str]| {
        let mut all = vec!["move", right.as_str()];
        all.extend_from_slice(args);
        let run = bench(&home.dir, &all);
        assert_eq!(run.code, 0, "bench {all:?}: {}", run.stderr);
        pane(&right)
    };

    let tab = moved(&["--tab", &first_slot, "--before", &first]);
    assert_eq!(tab["slot"], first_slot.as_str(), "a tab of that slot");
    let tabs =
        &document(&daemon.socket)["workspaces"][0]["bench"]["columns"][0]["slots"][0]["panes"];
    assert_eq!(tabs[0]["id"], right.as_str(), "before the pane named");

    let beside = moved(&["--beside", &first_slot, "--side", "down"]);
    assert_ne!(beside["slot"], first_slot.as_str(), "a slot of its own");
    let column = &document(&daemon.socket)["workspaces"][0]["bench"]["columns"][0]["slots"];
    assert_eq!(
        column[1]["panes"][0]["id"],
        right.as_str(),
        "below that slot"
    );

    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": "/tmp/m4-proof/other" }),
        None,
        false,
    ));
    let elsewhere = moved(&["--workspace", "/tmp/m4-proof/other"]);
    assert_eq!(elsewhere["workspace"], "/tmp/m4-proof/other");
    assert_eq!(
        document(&daemon.socket)["active"],
        "/tmp/m4-proof",
        "an agent's move leaves the operator where he is"
    );

    for wrong in [
        vec!["move", &first, "left", "--tab", &first_slot],
        vec!["move", &first, "--before", &right],
        vec!["move", &first, "--beside", &first_slot],
        vec!["move", &first],
    ] {
        let run = bench(&home.dir, &wrong);
        assert_eq!(run.code, 3, "bench {wrong:?} is refused: {}", run.stderr);
        assert!(
            run.stderr.contains("one destination"),
            "names the forms: {}",
            run.stderr
        );
    }
}

/// `workspace/move` reorders the document's workspaces, which is the order helm's bar draws.
#[test]
fn a_workspace_moves_before_another_through_the_socket() {
    let home = TestHome::claim("m4-move-ws");
    let daemon = DaemonGuard::start(&home.dir, None);
    working_bench(&daemon.socket);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": "/tmp/m4-proof/other" }),
        None,
        false,
    ));
    let order = || -> Vec<String> {
        document(&daemon.socket)["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| w["path"].as_str().unwrap().to_string())
            .collect()
    };
    assert_eq!(order(), ["/tmp/m4-proof", "/tmp/m4-proof/other"]);

    let report = ok_data(layout(
        &daemon.socket,
        "workspace/move",
        serde_json::json!({ "path": "/tmp/m4-proof/other", "before": "/tmp/m4-proof" }),
        operator(),
        false,
    ));
    assert_eq!(report["changed"], true);
    assert_eq!(order(), ["/tmp/m4-proof/other", "/tmp/m4-proof"]);

    let again = ok_data(layout(
        &daemon.socket,
        "workspace/move",
        serde_json::json!({ "path": "/tmp/m4-proof/other", "before": "/tmp/m4-proof" }),
        None,
        false,
    ));
    assert_eq!(again["changed"], false, "where it already is");
}

/// A file dropped from Finder (#178) is `pane/open` with `at`, the place a drop names: it opens
/// there, and a second drop of the same file moves the pane already showing it.
#[test]
fn a_file_opened_at_a_place_lands_there_and_is_not_opened_twice() {
    let home = TestHome::claim("m4-open-at");
    let daemon = DaemonGuard::start(&home.dir, None);
    let (first, _, _) = working_bench(&daemon.socket);
    let file = home.dir.join("dropped.md");
    std::fs::write(&file, "# dropped\n").unwrap();
    let surface =
        serde_json::json!({ "kind": "canvas", "source": { "kind": "file", "path": file } });
    let columns = |socket: &Path| {
        ok_data(layout(
            socket,
            "bench/get",
            serde_json::Value::Null,
            None,
            false,
        ))["document"]["workspaces"][0]["bench"]["columns"]
            .clone()
    };
    let slot_of_first = columns(&daemon.socket)[0]["slots"][0]["id"].clone();
    assert_eq!(
        columns(&daemon.socket)[0]["slots"][0]["panes"][0]["id"],
        first
    );

    let opened = ok_data(layout(
        &daemon.socket,
        "pane/open",
        serde_json::json!({ "surface": surface, "at": { "beside": { "slot": slot_of_first, "side": "up" } } }),
        operator(),
        false,
    ));
    let pane = opened["pane_created"].as_str().unwrap().to_string();
    let after = columns(&daemon.socket);
    assert_eq!(after[0]["slots"][0]["panes"][0]["id"], pane, "a row above");
    assert_eq!(after[0]["slots"][1]["id"], slot_of_first);

    let again = ok_data(layout(
        &daemon.socket,
        "pane/open",
        serde_json::json!({ "surface": surface, "at": { "tab": { "slot": slot_of_first, "before": first } } }),
        operator(),
        false,
    ));
    assert!(again["pane_created"].is_null(), "{again}");
    assert_eq!(again["pane"], pane, "the pane already showing it");
    let after = columns(&daemon.socket);
    let panes: Vec<_> = after[0]["slots"][0]["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["id"].clone())
        .collect();
    assert_eq!(
        panes,
        vec![serde_json::json!(pane), serde_json::json!(first)]
    );
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
        after,
        forget_sessions(before.clone()),
        "bench.json brought the whole document back, seq and all, less the sessions that ended with the daemon"
    );

    // Files are the record: the file and the log, read with no daemon in the loop.
    let record: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(root.join("bench.json")).unwrap()).unwrap();
    assert_eq!(record["format"], "bench.document");
    assert_eq!(
        record["document"],
        forget_sessions(before["document"].clone())
    );
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
    m4_proof();
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
    m4_proof();
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

/// The next frame that changed the document, past the session events a change may log first (a
/// new terminal pane's shell is logged before the change that shows it).
fn read_change(reader: &mut BufReader<UnixStream>) -> serde_json::Value {
    loop {
        let frame = read_frame(reader);
        let kind = frame["event"]["kind"].as_str().unwrap_or_default();
        if !kind.starts_with("session/") {
            return frame;
        }
    }
}

/// `doc` as a restarted daemon has it: every terminal pane's session forgotten, since no session
/// outlives the daemon that ran it (M5b; `bench restore` brings them back).
fn forget_sessions(mut doc: serde_json::Value) -> serde_json::Value {
    fn walk(v: &mut serde_json::Value) {
        match v {
            serde_json::Value::Object(map) => {
                if map.get("kind").and_then(|k| k.as_str()) == Some("terminal") {
                    map.remove("session");
                }
                map.values_mut().for_each(walk);
            }
            serde_json::Value::Array(items) => items.iter_mut().for_each(walk),
            _ => {}
        }
    }
    walk(&mut doc);
    doc
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
    let frame = read_change(&mut reader);
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
    let frame = read_change(&mut reader);
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
    m4_proof();
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
    read_change(&mut reader);

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
    let frame = read_change(&mut reader);
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
        forget_sessions(document.clone()),
        "the drawer came back from bench.json"
    );
    let record: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(home.dir.join(".bench").join("bench.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(record["version"], bench_wire::DOCUMENT_RECORD_VERSION);
}

/// #178: where a drawer sits is the operator's. The CLI speaks for an agent, so it is refused
/// without --asked and changes nothing; the operator's drag is applied, moves no focus and no
/// workspace, and is kept across a restart.
#[test]
fn only_the_operator_moves_a_drawer_and_it_stays_where_he_put_it() {
    m4_proof();
    let home = TestHome::claim("drawer-edge");
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
    ok_data(layout(
        &daemon.socket,
        "pane/open",
        serde_json::json!({ "drawer": "notes", "surface": { "kind": "canvas", "source": { "kind": "file", "path": "/tmp/m4-proof/drawers.md" } } }),
        None,
        false,
    ));
    let before = get(&daemon.socket);

    let refused = bench(&home.dir, &["drawer", "place", "notes", "bottom"]);
    assert_eq!(refused.code, 3, "{}", refused.stderr);
    assert!(refused.stderr.contains("--asked"), "{}", refused.stderr);
    assert_eq!(
        get(&daemon.socket),
        before,
        "a refused placement changes nothing"
    );

    // The refusal's way through works from the CLI: an agent the operator asked.
    let asked = bench(&home.dir, &["drawer", "place", "notes", "left", "--asked"]);
    assert_eq!(asked.code, 0, "{}", asked.stderr);
    assert_eq!(get(&daemon.socket)["drawer_edges"]["notes"], "left");

    let placed = ok_data(layout(
        &daemon.socket,
        "drawer/place",
        serde_json::json!({ "drawer": "notes", "edge": "bottom" }),
        operator(),
        false,
    ));
    assert_eq!(placed["changed"], true, "{placed}");
    assert_eq!(
        placed["focused_pane_after"],
        held.as_str(),
        "the keyboard stayed"
    );
    let document = get(&daemon.socket);
    assert_eq!(document["drawer_edges"]["notes"], "bottom");
    assert_eq!(
        document["workspaces"], before["workspaces"],
        "no workspace moved"
    );
    drop(daemon);

    let daemon = DaemonGuard::start(&home.dir, None);
    assert_eq!(
        get(&daemon.socket)["drawer_edges"]["notes"],
        "bottom",
        "the edge came back from bench.json"
    );
}

/// #356: placement comes from `<root>/rules/placement.toml`, reread on the next verb with no
/// restart; a file that cannot be read is logged naming the line, reported by `status`, and
/// changes nothing — the last good table keeps placing.
#[test]
fn a_rules_file_applies_on_the_next_verb_and_a_bad_one_changes_nothing() {
    m4_proof();
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
    // Past the new terminal pane's `session/spawned`.
    let frame = lines
        .by_ref()
        .map(|l| serde_json::from_str::<serde_json::Value>(&l.unwrap()).unwrap())
        .find(|f| {
            !f["event"]["kind"]
                .as_str()
                .unwrap_or_default()
                .starts_with("session/")
        })
        .unwrap();
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
    let ws = workspace(h);
    let write = |p: PathBuf, text: String| {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    };
    let root = h.join(".bench");
    // A pane whose agent exited: its session is in the record, and its transcript remains. And
    // an Archon run's transcript: in scope, never hosted.
    write(
        bench_wire::hosted_path(&root),
        serde_json::json!({"format": bench_wire::HOSTED_RECORD_FORMAT,
            "version": bench_wire::HOSTED_RECORD_VERSION, "sessions": [{"harness": "claude",
            "id": "gone", "cwd": ws, "via": {"kind": "pane",
            "pane": "3c47fa92-a0be-4012-a697-f7be06aede28"}, "recorded_at": "2026-09-25T12:00:00Z"}]})
        .to_string(),
    );
    let daemon = DaemonGuard::start(h, None);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));

    // Two live Claude processes in the workspace: the one in a pane's foreground (the pane's own
    // shell, at its prompt) and the daemon (in no pane — foreign). Their registry rows carry
    // their real start times. benchd places the first from its own document and the session's
    // terminal: there is no helm, and nothing under `.helm` (M5c).
    let started = |pid: u32| bench_sessions::process::started_at_secs(pid).unwrap() * 1000;
    let opened = bench(h, &["open", "terminal"]);
    assert_eq!(opened.code, 0, "{}", opened.stderr);
    let pane = json_of(&opened)["pane"].as_str().unwrap().to_string();
    let sid = pane_session(h, &pane).expect("the new pane names a session");
    let in_pane = u32::try_from(session_row(h, &sid)["pid"].as_i64().unwrap()).unwrap();
    let foreign = daemon.child.id();
    for (pid, sid) in [(in_pane, "in-pane"), (foreign, "in-zed")] {
        write(
            h.join(format!(".claude/sessions/{pid}.json")),
            serde_json::json!({"pid": pid, "sessionId": sid, "cwd": ws, "startedAt": started(pid),
                "status": "idle", "kind": "interactive", "entrypoint": "cli"})
            .to_string(),
        );
    }
    for sid in ["gone", "archon-run", "in-zed"] {
        write(
            h.join(".claude/projects")
                .join(mangle(&ws))
                .join(format!("{sid}.jsonl")),
            "{\"type\":\"user\"}\n".into(),
        );
    }
    // A job in a state no reader knows.
    write(
        h.join(".claude/jobs/j1/state.json"),
        serde_json::json!({"state": "hibernating", "sessionId": "j", "cwd": ws}).to_string(),
    );
    let harness_files = [h.join(".claude")];
    let before: Vec<_> = harness_files.iter().map(|d| tree_state(d)).collect();
    // The shell is at its prompt, so it holds its terminal.
    let deadline = Instant::now() + Duration::from_secs(5);
    while session_row(h, &sid)["foreground_pid"] != in_pane {
        assert!(Instant::now() < deadline, "{}", session_row(h, &sid));
        std::thread::sleep(Duration::from_millis(50));
    }

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
    assert_eq!(recorded, ["in-pane"], "the pane's agent joins the record");
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
    // Both live rows' processes ended with the first daemon, and only `gone` left a transcript.
    let after = list(&["--workspace", &ws.join("src").display().to_string()]);
    assert!(
        after.rows.is_empty(),
        "dismissed, and the record survived the restart: {:?}",
        after.rows
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
        4,
        "the skill's sessions, watch and two log snippets"
    );

    let home = TestHome::claim("sskill");
    let _daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    let ws = workspace(&home.dir);
    fs::write(ws.join(".git/HEAD"), "ref: refs/heads/feat/skill\n").unwrap();
    let (_, pi_session) = spawn_pi(&home.dir, &ws, "worker");
    // The session file the fake pi does not write: its header and the model it runs.
    let pi_dir = home
        .dir
        .join(".pi/agent/sessions")
        .join(bench_sessions::pi::dir_name(&ws.display().to_string()));
    fs::create_dir_all(&pi_dir).unwrap();
    fs::write(
        pi_dir.join(format!("t_{pi_session}.jsonl")),
        format!(
            "{}\n{}\n",
            serde_json::json!({"type": "session", "version": 3, "id": pi_session, "cwd": ws}),
            serde_json::json!({"type": "model_change", "provider": "p", "modelId": "gpt-6.1-sol"}),
        ),
    )
    .unwrap();
    write_claude_transcript(&home.dir, "s-2");
    // Something to watch that answers at once: a session whose process has exited.
    let (gone, gone_pid) = terminal_process(&home.dir, "gone");
    // SAFETY: the pid is this test's own spawn, still a child of benchd, not yet reaped.
    unsafe { kill(gone_pid as i32, 9) };
    wait_until("the session ends", Duration::from_secs(10), || {
        live_entry(&home.dir, &gone)["live"] == false
    });
    let mut outputs = Vec::new();
    for (i, snippet) in snippets.iter().enumerate() {
        let out = isolated("bash")
            .args(["-euo", "pipefail", "-c", snippet])
            .current_dir(&ws)
            .env("HOME", &home.dir)
            .env("BENCH", bench_bin())
            .env("SESSION", "s-2")
            .env("HANDLE", "gone")
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
        outputs[0].contains(&format!("pi {pi_session} feat/skill running gpt-6.1-sol")),
        "the live session is listed: {}",
        outputs[0]
    );
    assert!(
        outputs[1].contains(r#""outcome":"ended""#),
        "{}",
        outputs[1]
    );
    assert!(
        outputs[2].contains("tool   Bash  cargo build"),
        "{}",
        outputs[2]
    );
    assert!(
        outputs[3].contains("claude") && outputs[3].contains("4 of 4"),
        "{}",
        outputs[3]
    );
    assert!(outputs[3].contains("user  fix the build"), "{}", outputs[3]);
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
    bench_stdin(home, &["hook", harness], &payload.to_string())
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

/// `bench statusline <command>` exactly as Claude Code runs it: the payload on stdin.
fn bench_statusline(home: &Path, command: &[&str], payload: &serde_json::Value) -> CliRun {
    let mut child = isolated(bench_bin())
        .env("HOME", home)
        .arg("statusline")
        .args(command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run bench statusline");
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

/// `sessions`' `usage` for one harness, with each window's `at_ms` set aside: Claude's is the
/// moment `bench statusline` ran.
fn usage_of(home: &Path, harness: &str) -> Option<serde_json::Value> {
    let run = bench(home, &["sessions"]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let mut usage = json_of(&run)["usage"]
        .as_array()?
        .iter()
        .find(|u| u["harness"] == harness)?
        .clone();
    for w in usage["windows"].as_array_mut().unwrap() {
        w.as_object_mut().unwrap().remove("at_ms");
    }
    Some(usage)
}

/// #143: Claude's plan limits reach `sessions` through `bench statusline`, which runs the
/// operator's own statusline on the same input whether or not benchd is there; codex's reach it
/// through its hook, from the rollout the payload names. A lower reading of the same window
/// never replaces a higher one.
#[test]
fn plan_limits_reach_sessions_from_claudes_statusline_and_codexs_hook() {
    let home = TestHome::claim("usage");
    let h = &home.dir;
    let fixture: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/usage.json"),
        )
        .unwrap(),
    )
    .unwrap();
    // The fixture's windows, moved to reset an hour and a day from now: a window that has
    // already reset is replaced by any later report, which is not what this test is about.
    let now_s = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let mut payload = fixture["claude_statusline"].clone();
    payload["rate_limits"]["five_hour"]["resets_at"] = serde_json::json!(now_s + 3600);
    payload["rate_limits"]["seven_day"]["resets_at"] = serde_json::json!(now_s + 86400);
    let payload = &payload;
    let mine = write_agent_script(h, "statusline", "printf 'mine:'; wc -c | tr -d ' '; exit 3")
        .join("statusline");
    let mine = mine.to_str().unwrap();
    let expected_out = format!("mine:{}\n", payload.to_string().len());

    let alone = bench_statusline(h, &[mine], payload);
    assert_eq!(
        (alone.code, alone.stdout.as_str()),
        (3, expected_out.as_str()),
        "{}",
        alone.stderr
    );

    let daemon = DaemonGuard::start(h, None);
    assert_eq!(usage_of(h, "claude"), None, "nothing reported yet");
    let (pi, _) = raw_request(
        &daemon.socket,
        "usage/report",
        serde_json::json!({"harness": "pi", "windows": []}),
    );
    assert_eq!(pi["status"], "refused", "pi publishes no plan limits: {pi}");
    let run = bench_statusline(h, &[mine], payload);
    assert_eq!(
        (run.code, run.stdout.as_str()),
        (3, expected_out.as_str()),
        "{}",
        run.stderr
    );
    let mut want = fixture["claude_usage"].clone();
    for (w, resets) in want["windows"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .zip([now_s + 3600, now_s + 86400])
    {
        w.as_object_mut().unwrap().remove("at_ms");
        w["resets_at_ms"] = serde_json::json!(resets * 1000);
    }
    assert_eq!(usage_of(h, "claude"), Some(want.clone()));

    let mut lower = payload.clone();
    lower["rate_limits"]["five_hour"]["used_percentage"] = serde_json::json!(10);
    assert_eq!(
        bench_statusline(h, &[], &lower).code,
        0,
        "no command is an empty statusline"
    );
    assert_eq!(usage_of(h, "claude"), Some(want), "an older, lower reading");

    let rollout = h.join("rollout.jsonl");
    let lines: Vec<String> = fixture["codex_rollout"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l.to_string())
        .collect();
    fs::write(&rollout, lines.join("\n") + "\n").unwrap();
    let hook = bench_hook(
        h,
        "codex",
        serde_json::json!({"session_id": "c1", "hook_event_name": "Stop", "cwd": "/tmp",
                           "transcript_path": rollout}),
    );
    assert_eq!(hook.code, 0);
    let run = bench(h, &["sessions"]);
    let codex = json_of(&run)["usage"]
        .as_array()
        .unwrap()
        .iter()
        .find(|u| u["harness"] == "codex")
        .cloned();
    assert_eq!(
        codex,
        Some(fixture["codex_usage"].clone()),
        "the line's own time, the plan's limit"
    );
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

/// benchd's codex app-server, played by the test (#466): what codex 0.160.0 speaks on
/// `--listen unix://` (WebSocket, one JSON-RPC message per text frame), as much of it as benchd
/// asks. It answers and records every request, and sends a notification to every connection on
/// demand. The fake `codex` benchd starts as its app-server links benchd's socket to this one,
/// as real codex links it to a short socket of its own ([`write_fake_codex`]).
struct FakeCodex {
    seen: std::sync::Arc<std::sync::Mutex<Vec<serde_json::Value>>>,
    /// The answers to the next `turn/start`s: `Some(true)` starts a turn, `Some(false)` refuses,
    /// `None` answers naming no turn. Empty starts one.
    turns: std::sync::Arc<std::sync::Mutex<std::collections::VecDeque<Option<bool>>>>,
    /// Notifications (method, params without the thread) to send on the thread before answering
    /// the next `turn/start`: a turn that ends, or fails, before benchd has heard its answer.
    early: std::sync::Arc<std::sync::Mutex<Vec<(&'static str, serde_json::Value)>>>,
    clients: std::sync::Arc<std::sync::Mutex<Vec<std::sync::Arc<std::sync::Mutex<UnixStream>>>>>,
}

impl FakeCodex {
    fn bind(home: &Path) -> FakeCodex {
        let listener = std::os::unix::net::UnixListener::bind(home.join("fcx.sock"))
            .expect("bind the fake codex app-server");
        let fake = FakeCodex {
            seen: Default::default(),
            turns: Default::default(),
            early: Default::default(),
            clients: Default::default(),
        };
        let (seen, turns, early, clients) = (
            std::sync::Arc::clone(&fake.seen),
            std::sync::Arc::clone(&fake.turns),
            std::sync::Arc::clone(&fake.early),
            std::sync::Arc::clone(&fake.clients),
        );
        std::thread::spawn(move || {
            let next = std::sync::Arc::new(AtomicU32::new(1));
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { return };
                let mut head = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") && stream.read_exact(&mut byte).is_ok() {
                    head.push(byte[0]);
                }
                let _ = stream.write_all(b"HTTP/1.1 101 Switching Protocols\r\nconnection: Upgrade\r\nupgrade: websocket\r\n\r\n");
                let writer =
                    std::sync::Arc::new(std::sync::Mutex::new(stream.try_clone().unwrap()));
                clients.lock().unwrap().push(std::sync::Arc::clone(&writer));
                let (seen, turns, early, next) = (
                    std::sync::Arc::clone(&seen),
                    std::sync::Arc::clone(&turns),
                    std::sync::Arc::clone(&early),
                    std::sync::Arc::clone(&next),
                );
                std::thread::spawn(move || {
                    while let Some(message) = read_client_frame(&mut stream) {
                        let (Some(method), Some(id)) =
                            (message["method"].as_str(), message.get("id"))
                        else {
                            continue;
                        };
                        let params = message["params"].clone();
                        let answer = codex_answer(method, &params, &turns, &next);
                        if method != "initialize" {
                            seen.lock()
                                .unwrap()
                                .push(serde_json::json!({"method": method, "params": params}));
                        }
                        if method == "turn/start" {
                            for (note, mut body) in early.lock().unwrap().drain(..) {
                                body["threadId"] = params["threadId"].clone();
                                server_frame(
                                    &mut writer.lock().unwrap(),
                                    &serde_json::json!({"method": note, "params": body}),
                                );
                            }
                        }
                        let reply = match answer {
                            Ok(result) => serde_json::json!({"id": id, "result": result}),
                            Err(why) => {
                                serde_json::json!({"id": id, "error": {"code": -32600, "message": why}})
                            }
                        };
                        server_frame(&mut writer.lock().unwrap(), &reply);
                    }
                });
            }
        });
        fake
    }

    /// A notification to every connection, as codex sends them unasked.
    fn notify(&self, message: serde_json::Value) {
        for client in self.clients.lock().unwrap().iter() {
            server_frame(&mut client.lock().unwrap(), &message);
        }
    }

    /// The params of every `method` request so far.
    fn asked_now(&self, method: &str) -> Vec<serde_json::Value> {
        self.seen
            .lock()
            .unwrap()
            .iter()
            .filter(|m| m["method"] == method)
            .map(|m| m["params"].clone())
            .collect()
    }

    /// The params of every `method` request, once there are `n`.
    fn asked(&self, method: &str, n: usize) -> Vec<serde_json::Value> {
        wait_until(
            &format!("{n} {method} request(s)"),
            Duration::from_secs(15),
            || self.asked_now(method).len() >= n,
        );
        self.asked_now(method)
    }
}

/// What the fake codex answers: a thread per `thread/start` and `thread/fork`, the thread asked
/// for on `thread/resume`, a recorded model on `thread/read`. A thread id is a UUIDv7 as codex's
/// are, from 2026-10-01, the day the session list looks for its rollout under.
fn codex_answer(
    method: &str,
    params: &serde_json::Value,
    turns: &std::sync::Mutex<std::collections::VecDeque<Option<bool>>>,
    next: &AtomicU32,
) -> Result<serde_json::Value, String> {
    let new_thread = || {
        let n = next.fetch_add(1, Ordering::Relaxed);
        serde_json::json!({"thread": {"id": format!("01a0f663-47f0-7d53-b41a-{n:012}")}})
    };
    match method {
        "initialize" => Ok(serde_json::json!({"userAgent": "fake"})),
        "thread/start" | "thread/fork" => Ok(new_thread()),
        "thread/resume" => Ok(serde_json::json!({"thread": {"id": params["threadId"]}})),
        "thread/read" => Ok(serde_json::json!({"thread": {"id": params["threadId"],
            "model": "gpt-recorded", "reasoningEffort": "low"}})),
        "turn/start" => match turns.lock().unwrap().pop_front().unwrap_or(Some(true)) {
            // Long enough for a 16-bit length, as real answers are.
            Some(true) => Ok(
                serde_json::json!({"turn": {"id": "t1", "status": "inProgress", "items": [], "note": "x".repeat(300)}}),
            ),
            Some(false) => Err("thread is busy".into()),
            None => Ok(serde_json::json!({"turn": {"status": "inProgress"}})),
        },
        "thread/unsubscribe" => Ok(serde_json::json!({"status": "unsubscribed"})),
        "turn/interrupt" => Ok(serde_json::json!({})),
        other => Err(format!("the fake codex does not know {other}")),
    }
}

/// `HOME`'s codex config trusting each of `dirs`, as the operator's own codex records it.
fn trust_codex(home: &Path, dirs: &[&Path]) -> String {
    let config: String = dirs
        .iter()
        .map(|d| {
            format!(
                "[projects.{:?}]\ntrust_level = \"trusted\"\n",
                d.display().to_string()
            )
        })
        .collect();
    fs::create_dir_all(home.join(".codex")).unwrap();
    fs::write(home.join(".codex/config.toml"), &config).unwrap();
    config
}

/// A daemon whose `codex` is the fake in `bin` ([`write_fake_codex`]).
fn codex_daemon(home: &Path, bin: &Path) -> DaemonGuard {
    let path = std::env::var("PATH").unwrap_or_default();
    let mut cmd = isolated(benchd_bin());
    cmd.env("PATH", format!("{}:{path}", bin.display()));
    DaemonGuard::start_with(home, None, cmd)
}

/// `bench spawn --agent codex` in `cwd` with `extra` flags: its answer.
fn spawn_codex(home: &Path, cwd: &Path, extra: &[&str]) -> serde_json::Value {
    let cwd = cwd.display().to_string();
    let mut args = vec!["spawn", "--agent", "codex", "--cwd", &cwd];
    args.extend_from_slice(extra);
    let run = bench(home, &args);
    assert_eq!(run.code, 0, "stderr: {}", run.stderr);
    json_of(&run)
}

/// A codex hook as benchd's app-server runs it: the thread and nothing that names a session,
/// from the server's process (here this test's own, which is alive).
fn codex_hook(daemon: &DaemonGuard, event: &str, thread: &str, cwd: &str) -> serde_json::Value {
    hook_verb(
        &daemon.socket,
        serde_json::json!({"harness": "codex", "event": event, "session": thread,
            "cwd": cwd, "pid": std::process::id()}),
    )
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

/// One codex benchd spawned (#466): its thread made with its own cwd, model, posture and
/// environment, its first message sent as a turn, its pane recording the thread before any hook,
/// and its TUI attached to that thread.
fn assert_codex_thread(
    h: &Path,
    runs: &Path,
    spawned: &serde_json::Value,
    cwd: &Path,
    model: &str,
    start: &serde_json::Value,
    turns: &[serde_json::Value],
) {
    let root = h.join(".bench");
    let thread = spawned["runtime_session"].as_str().expect("known at spawn");
    assert_eq!(start["cwd"], cwd.display().to_string());
    assert_eq!(start["model"], model);
    assert_eq!(start["sandbox"], "danger-full-access");
    assert_eq!(start["approvalPolicy"], "never");
    assert_eq!(start["config"]["bypass_hook_trust"], true);
    let set = &start["config"]["shell_environment_policy"]["set"];
    assert_eq!(set["BENCH_SESSION"], spawned["session"]);
    assert_eq!(set["BENCH_HANDLE"], spawned["handle"]);
    assert_eq!(set["BENCH_DIR"], root.display().to_string());
    assert!(
        turns.iter().any(|t| t["threadId"] == thread),
        "its first message is a turn: {turns:?}"
    );
    let pane = spawned["pane"].as_str().unwrap();
    assert_eq!(pane_agent(h, pane)["session"], thread);
    let socket = format!("unix://{}", root.join("codex.sock").display());
    let tui = format!("resume {thread} --remote {socket} -c check_for_update_on_startup=false");
    assert!(
        recorded_runs(runs, 3).iter().any(|r| r.starts_with(&tui)),
        "{tui}"
    );
}

#[test]
fn every_codex_is_a_thread_benchd_makes_on_its_one_app_server() {
    // #466: one server, whatever the number of codex agents. benchd makes each thread with the
    // agent's own cwd, model, posture and environment, sends its first message as a turn, and
    // the pane only attaches. The server sees none of the agent variables benchd itself has.
    let home = TestHome::claim("cxone");
    let h = &home.dir;
    let root = h.join(".bench");
    let (a, b) = (h.join("wa"), h.join("wb"));
    fs::create_dir_all(&a).unwrap();
    fs::create_dir_all(&b).unwrap();
    trust_codex(h, &[&a, &b]);
    let fake = FakeCodex::bind(h);
    let (bin, runs) = write_fake_codex(h);
    let path = std::env::var("PATH").unwrap_or_default();
    let mut cmd = isolated(benchd_bin());
    cmd.env("PATH", format!("{}:{path}", bin.display()))
        .env("HELM_PANE", "operator-pane")
        .env("CLAUDE_CODE_MESSAGING_SOCKET", "/tmp/operator.sock")
        .env("BENCH_HANDLE", "operator-agent");
    let _daemon = DaemonGuard::start_with(h, None, cmd);
    let prompt = h.join("brief.md");
    fs::write(&prompt, "do the thing").unwrap();
    let first = spawn_codex(
        h,
        &a,
        &[
            "--name",
            "cx-a",
            "--model",
            "gpt-a",
            "--effort",
            "low",
            "--prompt-file",
            prompt.to_str().unwrap(),
        ],
    );
    let second = spawn_codex(h, &b, &["--name", "cx-b", "--model", "gpt-b"]);

    let servers: Vec<String> = recorded_runs(&runs, 3)
        .into_iter()
        .filter(|r| r.starts_with("app-server "))
        .collect();
    let socket = format!("unix://{}", root.join("codex.sock").display());
    assert_eq!(servers.len(), 1, "one app-server for both: {servers:?}");
    assert!(
        servers[0].ends_with(&format!(" --listen {socket}")),
        "{}",
        servers[0]
    );
    // A TUI that resumes against a remote server reviews hooks whatever its own flag says, so the
    // server trusts the hooks codex says need review.
    assert!(
        servers[0].contains(
            r#" -c hooks.state={ "/h/hooks.json:stop:0:0" = { trusted_hash = "sha256:new" } } "#
        ),
        "{}",
        servers[0]
    );
    let env = fs::read_to_string(h.join("codex-server.env")).unwrap();
    assert!(
        env.contains(&format!("BENCH_DIR={}\n", root.display())),
        "{env}"
    );
    for leak in [
        "HELM_PANE=",
        "CLAUDE_CODE_MESSAGING_SOCKET=",
        "BENCH_HANDLE=",
        "BENCH_SESSION=",
    ] {
        assert!(!env.contains(leak), "the server must not see {leak}: {env}");
    }

    let starts = fake.asked("thread/start", 2);
    let turns = fake.asked("turn/start", 2);
    for (spawned, cwd, model, start) in [
        (&first, &a, "gpt-a", &starts[0]),
        (&second, &b, "gpt-b", &starts[1]),
    ] {
        assert_codex_thread(h, &runs, spawned, cwd, model, start, &turns);
    }
    assert_eq!(starts[0]["config"]["model_reasoning_effort"], "low");
    let brief = turns
        .iter()
        .find(|t| t["threadId"] == first["runtime_session"])
        .unwrap();
    assert_eq!(
        brief["input"][0]["text"],
        format!("Read and act on the prompt in {}", prompt.display())
    );
    let sessions = json_of(&bench(h, &["sessions"]));
    let row = sessions["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["handle"] == "cx-b")
        .unwrap()
        .clone();
    assert_eq!(row["runtime_session"], second["runtime_session"]);
}

#[test]
fn a_codex_hook_names_only_its_thread_and_reaches_the_session_benchd_made_it_for() {
    // codex runs every hook with its app-server's environment, so a hook says nothing about
    // which benchd session it is from. The thread does.
    let home = TestHome::claim("cxhook");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let _fake = FakeCodex::bind(h);
    let (bin, _) = write_fake_codex(h);
    let daemon = codex_daemon(h, &bin);
    let spawned = spawn_codex(h, &ws, &["--name", "cx"]);
    let thread = spawned["runtime_session"].as_str().unwrap();
    let cwd = ws.display().to_string();
    let reply = codex_hook(&daemon, "SessionStart", thread, &cwd);
    assert_eq!(reply["handle"], "cx");
    let record = hosted_record(&h.join(".bench"));
    let entry = record["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == thread)
        .expect("the thread is in the record");
    assert_eq!(entry["via"]["kind"], "bench");
    assert_eq!(entry["via"]["handle"], "cx");
    // A thread benchd did not make, from a hook that declares nothing, gets no mailbox.
    let stranger = codex_hook(&daemon, "SessionStart", "019f-not-benchds", &cwd);
    assert!(stranger["handle"].is_null(), "{stranger}");
    // The hook's process is the shared server, which outlives the pane; the hook is read as the
    // session's own, so the agent dies with its TUI and its conversation can come back.
    let pid = spawned["pid"].as_i64().unwrap() as i32;
    libc_kill(pid);
    wait_until("the session exits", Duration::from_secs(5), || {
        !libc_alive(pid)
    });
    let again = bench(
        h,
        &[
            "spawn", "--agent", "codex", "--cwd", &cwd, "--resume", thread,
        ],
    );
    assert_eq!(again.code, 0, "not held by a dead pane: {}", again.stderr);
    // Two sessions now hold the thread, the exited one and its resume: a hook is the live one's.
    let resumed = json_of(&again)["session"].clone();
    for _ in 0..5 {
        codex_hook(&daemon, "UserPromptSubmit", thread, &cwd);
        let row = json_of(&bench(h, &["sessions"]))["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["session"] == resumed)
            .unwrap()
            .clone();
        assert_eq!(row["report"]["activity"]["kind"], "busy", "{row}");
    }
}

#[test]
fn an_idle_codex_is_woken_through_benchds_app_server_and_a_busy_one_is_not() {
    let home = TestHome::claim("cxpush");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let fake = FakeCodex::bind(h);
    let (bin, _) = write_fake_codex(h);
    let _daemon = codex_daemon(h, &bin);
    let spawned = spawn_codex(h, &ws, &["--name", "cx"]);
    let thread = spawned["runtime_session"].as_str().unwrap().to_string();
    // What codex says on benchd's connection, unasked (#357): the hooks no longer say it.
    let status = |kind: serde_json::Value| {
        fake.notify(serde_json::json!({"method": "thread/status/changed",
            "params": {"threadId": thread, "status": kind}}));
    };
    let ended = || {
        fake.notify(serde_json::json!({"method": "turn/completed",
            "params": {"threadId": thread, "turn": {"id": "t1", "status": "completed"}}}));
    };
    let woken = || {
        fake.asked_now("turn/start")
            .into_iter()
            .filter(|t| t["threadId"] == thread)
            .count()
    };
    assert_eq!(woken(), 1, "benchd sent the first message");
    fake.turns.lock().unwrap().extend([Some(true), Some(false)]);
    let send = |body: &str| json_of(&bench(h, &["mail", "send", "--to", "cx", "--body", body]));
    // Busy from spawn: benchd has just started its first turn.
    assert_eq!(send("while busy")["wake"], "queued");
    std::thread::sleep(Duration::from_secs(2));
    assert_eq!(woken(), 1, "nothing is started while it is busy");
    status(serde_json::json!({"type": "active", "activeFlags": ["waitingOnApproval"]}));
    std::thread::sleep(Duration::from_secs(1));
    assert_eq!(woken(), 1);

    // Idle: one turn on its own thread, carrying the pointer and never the body.
    ended();
    wait_until(
        "a turn is started once idle",
        Duration::from_secs(5),
        || woken() == 2,
    );
    let read = h.join(".bench/mail/cx/read/m1.md");
    let pushed = fake.asked_now("turn/start").pop().unwrap();
    assert!(
        pushed["input"][0]["text"]
            .as_str()
            .unwrap()
            .ends_with(&format!("You have mail from operator: {}", read.display())),
        "{pushed}"
    );
    assert!(read.exists() && inbox_count(h, "cx") == 0);

    // A refused turn: the mail goes back, unread, and the session is not pushed again.
    send("during the turn");
    ended();
    wait_until("the refused push is held", Duration::from_secs(5), || {
        event_kinds(h).iter().any(|(k, _)| k == "mail/held")
    });
    assert_eq!(inbox_count(h, "cx"), 1, "back in the inbox, unread");
    assert_eq!(send("after the refusal")["wake"], "next-turn");
    let delivered: Vec<_> = event_kinds(h)
        .into_iter()
        .filter(|(k, _)| k == "mail/delivered")
        .map(|(_, d)| d["channel"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(delivered, ["codex"]);
}

#[test]
fn a_codex_turn_that_failed_is_found_idle_by_its_thread_status() {
    // A turn refused by a usage limit fires no Stop (measured on codex 0.157.0): the hooks last
    // said busy, and only the app-server knows the thread stopped. It says so unasked.
    let home = TestHome::claim("cxstale");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let fake = FakeCodex::bind(h);
    let (bin, _) = write_fake_codex(h);
    let _daemon = codex_daemon(h, &bin);
    let spawned = spawn_codex(h, &ws, &["--name", "cx"]);
    let thread = spawned["runtime_session"].as_str().unwrap().to_string();
    // Busy from spawn: benchd has just started its first turn.
    bench(h, &["mail", "send", "--to", "cx", "--body", "one"]);
    std::thread::sleep(Duration::from_secs(2));
    assert_eq!(fake.asked_now("turn/start").len(), 1, "held while running");
    fake.notify(serde_json::json!({"method": "thread/status/changed",
        "params": {"threadId": thread, "status": {"type": "systemError"}}}));
    let turns = fake.asked("turn/start", 2);
    assert_eq!(turns[1]["threadId"], thread);
    assert!(
        event_kinds(h)
            .iter()
            .any(|(k, d)| k == "agent/state" && d["event"] == "thread/status/changed"),
        "the log says which record found it idle"
    );
}

#[test]
fn codex_runs_only_where_the_operator_trusts_it() {
    // Without `-C`, codex itself never asks "Trust this folder?" for a bench agent, so benchd
    // asks his rule: the folder's own entry, else its git repository's, worktrees included.
    // Nothing starts for a refused one, and his codex config is never written.
    let home = TestHome::claim("cxtrust");
    let h = &home.dir;
    let trusted = git_repo_with_worktree(h, "t");
    let untrusted = git_repo_with_worktree(h, "u");
    let config = trust_codex(h, &[&h.join("t").canonicalize().unwrap()]);
    let _fake = FakeCodex::bind(h);
    let (bin, runs) = write_fake_codex(h);
    let _daemon = codex_daemon(h, &bin);
    let refused = bench(
        h,
        &[
            "spawn",
            "--agent",
            "codex",
            "--cwd",
            untrusted.to_str().unwrap(),
        ],
    );
    assert_eq!(refused.code, 3, "{}", refused.stderr);
    assert!(
        refused
            .stderr
            .contains("codex runs only in a folder you trust"),
        "{}",
        refused.stderr
    );
    assert!(!runs.exists(), "nothing started for it");
    spawn_codex(h, &trusted, &[]);
    assert_eq!(
        fs::read_to_string(h.join(".codex/config.toml")).unwrap(),
        config,
        "benchd never writes the operator's codex config"
    );
}

#[test]
fn benchds_codex_app_server_ends_with_benchd_however_benchd_ends() {
    let home = TestHome::claim("cxleash");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let _fake = FakeCodex::bind(h);
    let (bin, _) = write_fake_codex(h);
    let server_pid = || -> i32 {
        fs::read_to_string(h.join("codex-server.pid"))
            .unwrap()
            .trim()
            .parse()
            .unwrap()
    };
    // `bench stop`.
    {
        let _daemon = codex_daemon(h, &bin);
        spawn_codex(h, &ws, &[]);
        let pid = server_pid();
        assert!(libc_alive(pid));
        assert_eq!(bench(h, &["stop"]).code, 0);
        wait_until("the server is gone", Duration::from_secs(5), || {
            !libc_alive(pid)
        });
    }
    fs::remove_file(h.join("codex-server.pid")).unwrap();
    // Killed outright: the leash's pipe closes.
    let mut daemon = codex_daemon(h, &bin);
    spawn_codex(h, &ws, &[]);
    let pid = server_pid();
    let _ = daemon.child.kill();
    let _ = daemon.child.wait();
    wait_until("the server is gone", Duration::from_secs(5), || {
        !libc_alive(pid)
    });
}

#[test]
fn a_codex_thread_no_session_holds_any_more_is_let_go() {
    // benchd's connection is subscribed to every thread it made; once the pane that showed one
    // is closed, it lets go, so codex unloads the thread rather than keeping it for its life.
    let home = TestHome::claim("cxrelease");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let fake = FakeCodex::bind(h);
    let (bin, _) = write_fake_codex(h);
    let _daemon = codex_daemon(h, &bin);
    let spawned = spawn_codex(h, &ws, &[]);
    let thread = spawned["runtime_session"].as_str().unwrap();
    // Not the bench's last pane, which a close refuses.
    let ws = ws.display().to_string();
    let other = bench(h, &["open", "terminal", "--workspace", &ws]);
    assert_eq!(other.code, 0, "{}", other.stderr);
    std::thread::sleep(Duration::from_secs(1));
    assert!(
        fake.asked_now("thread/unsubscribe").is_empty(),
        "kept while its session holds it"
    );
    let pane = spawned["pane"].as_str().unwrap();
    let closed = bench(h, &["close", pane, "--force"]);
    assert_eq!(closed.code, 0, "{}", closed.stderr);
    assert_eq!(fake.asked("thread/unsubscribe", 1)[0]["threadId"], thread);
}

#[test]
fn a_codex_spawn_whose_first_turn_is_refused_fails_and_lets_its_thread_go() {
    // Nothing may run that no pane shows: a thread whose spawn failed is let go, its turn
    // stopped if one started.
    let home = TestHome::claim("cxabandon");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let fake = FakeCodex::bind(h);
    fake.turns.lock().unwrap().push_back(Some(false));
    let (bin, _) = write_fake_codex(h);
    let _daemon = codex_daemon(h, &bin);
    let run = bench(
        h,
        &[
            "spawn",
            "--agent",
            "codex",
            "--cwd",
            &ws.display().to_string(),
        ],
    );
    assert_ne!(run.code, 0, "the spawn reports its failure");
    let thread = fake.asked("thread/start", 1);
    assert_eq!(thread.len(), 1);
    assert_eq!(fake.asked("thread/unsubscribe", 1).len(), 1);
    let sessions = json_of(&bench(h, &["sessions"]));
    assert_eq!(sessions["sessions"], serde_json::json!([]), "{sessions}");
}

#[test]
fn a_codex_whose_session_fails_after_its_first_turn_has_that_turn_stopped() {
    // The thread step succeeds and its first turn runs; then the session cannot start (its
    // program is no longer executable). The turn is interrupted by its id and the thread let go,
    // so no agent runs that no pane shows.
    let home = TestHome::claim("cxstop");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let fake = FakeCodex::bind(h);
    let (bin, _) = write_fake_codex(h);
    let _daemon = codex_daemon(h, &bin);
    spawn_codex(h, &ws, &[]);
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(bin.join("codex"), fs::Permissions::from_mode(0o644)).unwrap();
    }
    let run = bench(
        h,
        &[
            "spawn",
            "--agent",
            "codex",
            "--cwd",
            &ws.display().to_string(),
        ],
    );
    assert_ne!(run.code, 0, "{}", run.stdout);
    let turn = fake.asked("turn/start", 2)[1].clone();
    let interrupt = &fake.asked("turn/interrupt", 1)[0];
    assert_eq!(interrupt["threadId"], turn["threadId"], "its own turn");
    assert_eq!(interrupt["turnId"], "t1");
    assert!(
        fake.asked("thread/unsubscribe", 1)
            .iter()
            .any(|u| u["threadId"] == turn["threadId"]),
        "and its thread let go"
    );
}

#[test]
fn a_codex_first_turn_codex_names_no_id_for_fails_the_spawn_and_lets_the_thread_go() {
    // An answer with no turn in it may be a turn benchd cannot stop: the spawn fails, and the
    // thread is let go, with nothing interrupted because nothing can be named.
    let home = TestHome::claim("cxnameless");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let fake = FakeCodex::bind(h);
    fake.turns.lock().unwrap().push_back(None);
    let (bin, _) = write_fake_codex(h);
    let _daemon = codex_daemon(h, &bin);
    let run = bench(
        h,
        &[
            "spawn",
            "--agent",
            "codex",
            "--cwd",
            &ws.display().to_string(),
        ],
    );
    assert_ne!(run.code, 0, "{}", run.stdout);
    assert!(run.stderr.contains("named no turn"), "{}", run.stderr);
    assert_eq!(fake.asked("thread/unsubscribe", 1).len(), 1);
    assert!(fake.asked_now("turn/interrupt").is_empty());
}

#[test]
fn a_codex_status_sent_before_its_session_is_registered_is_not_lost() {
    // A first turn that fails at once fires no Stop; codex says so in a status that can arrive
    // before benchd has registered the session. The agent starts idle, and its mail goes out.
    let home = TestHome::claim("cxearly");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let fake = FakeCodex::bind(h);
    fake.early.lock().unwrap().push((
        "thread/status/changed",
        serde_json::json!({"status": {"type": "systemError"}}),
    ));
    let (bin, _) = write_fake_codex(h);
    let _daemon = codex_daemon(h, &bin);
    let spawned = spawn_codex(h, &ws, &["--name", "cx"]);
    bench(h, &["mail", "send", "--to", "cx", "--body", "one"]);
    let turns = fake.asked("turn/start", 2);
    assert_eq!(turns[1]["threadId"], spawned["runtime_session"]);
}

#[test]
fn a_codex_first_turn_that_ends_before_its_session_is_registered_is_done() {
    // A turn can complete before benchd has heard `turn/start`'s answer, let alone registered
    // the session: its `turn/completed` is kept, and the agent starts done.
    let home = TestHome::claim("cxearlydone");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let fake = FakeCodex::bind(h);
    fake.early.lock().unwrap().extend([
        (
            "turn/completed",
            serde_json::json!({"turn": {"id": "t1", "status": "completed"}}),
        ),
        (
            "thread/status/changed",
            serde_json::json!({"status": {"type": "idle"}}),
        ),
    ]);
    let (bin, _) = write_fake_codex(h);
    let _daemon = codex_daemon(h, &bin);
    let spawned = spawn_codex(h, &ws, &["--name", "cx"]);
    let e = live_entry(h, spawned["session"].as_str().unwrap());
    assert_eq!(e["done"]["to"], "operator", "{e}");
    assert_eq!(e["report"]["activity"]["kind"], "idle", "{e}");
}

#[test]
fn a_codex_the_operator_resumes_himself_after_its_benchd_session_ended_reports_by_its_hooks() {
    // A thread is benchd's only while a live session holds it. Once that session ended, the
    // operator's own codex on it (a pane, codex's own server) is read by its hooks again.
    let home = TestHome::claim("cxreclaim");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let _fake = FakeCodex::bind(h);
    let (bin, _) = write_fake_codex(h);
    let daemon = codex_daemon(h, &bin);
    let spawned = spawn_codex(h, &ws, &["--name", "cx"]);
    let thread = spawned["runtime_session"].as_str().unwrap().to_string();
    let pid = spawned["pid"].as_i64().unwrap() as i32;
    libc_kill(pid);
    wait_until("the session exits", Duration::from_secs(5), || {
        !libc_alive(pid)
    });
    let (_, his) = terminal_process(h, "his-codex");
    let reply = hook_verb(
        &daemon.socket,
        serde_json::json!({"harness": "codex", "event": "PermissionRequest", "session": thread,
            "cwd": ws.display().to_string(), "pid": his, "pane": HOOK_PANE}),
    );
    assert_eq!(reply["handle"], "cx", "the mailbox it had: {reply}");
    assert!(
        event_kinds(h).iter().any(|(k, d)| k == "agent/state"
            && d["session"] == thread.as_str()
            && d["event"] == "PermissionRequest"),
        "his hook says what it does"
    );
}

/// A benchd-spawned codex is listed by its thread, and once it ends by its rollout; `bench log`
/// reads that rollout. The rollout's lines are real codex 0.157 shapes. `bench sessions`, `bench
/// sessions --all` and `mail who` name a spawned codex by its thread from the moment it is
/// spawned, never benchd's `sN`: benchd made the thread (#466).
#[test]
fn a_spawned_codex_is_named_by_its_thread_in_every_answer_before_any_hook() {
    let home = TestHome::claim("cxname");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let _fake = FakeCodex::bind(h);
    let (bin, _) = write_fake_codex(h);
    let daemon = codex_daemon(h, &bin);
    let spawned = spawn_codex(h, &ws, &[]);
    let thread = spawned["runtime_session"].clone();
    let pane = spawned["pane"].as_str().unwrap().to_string();
    let ws = ws.display().to_string();
    let answers = || {
        let plain = bench(h, &["sessions"]);
        assert_eq!(plain.code, 0, "stderr: {}", plain.stderr);
        let who = bench(h, &["mail", "who", "--pane", &pane]);
        assert_eq!(who.code, 0, "stderr: {}", who.stderr);
        let all = bench(h, &["sessions", "--all", "--workspace", &ws]);
        assert_eq!(all.code, 0, "stderr: {}", all.stderr);
        [
            json_of(&plain)["sessions"][0]["runtime_session"].clone(),
            json_of(&who)["session"].clone(),
            json_of(&all)["rows"][0]["id"].clone(),
        ]
    };
    assert_eq!(answers(), [thread.clone(), thread.clone(), thread.clone()]);
    codex_hook(&daemon, "SessionStart", thread.as_str().unwrap(), &ws);
    assert_eq!(answers(), [thread.clone(), thread.clone(), thread]);
}

#[test]
fn a_spawned_codex_is_listed_by_its_thread_and_its_rollout_reads_as_a_log() {
    let home = TestHome::claim("cxrow");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let _fake = FakeCodex::bind(h);
    let (bin, _) = write_fake_codex(h);
    let daemon = codex_daemon(h, &bin);
    let ws_arg = ws.display().to_string();
    let spawned = spawn_codex(h, &ws, &["--name", "cx"]);
    let (session, pid) = (
        spawned["session"].as_str().unwrap().to_string(),
        spawned["pid"].as_i64().unwrap() as i32,
    );
    let thread = spawned["runtime_session"].as_str().unwrap().to_string();
    let thread = thread.as_str();
    for event in ["SessionStart", "UserPromptSubmit"] {
        codex_hook(&daemon, event, thread, &ws_arg);
    }
    fs::create_dir_all(h.join(".codex")).unwrap();
    fs::write(
        h.join(".codex/session_index.jsonl"),
        serde_json::json!({"id": thread, "thread_name": "Fix the build", "updated_at": "2026-10-01T07:35:00Z"})
            .to_string()
            + "\n",
    )
    .unwrap();
    let rows = || {
        let run = bench(h, &["sessions", "--all", "--workspace", &ws_arg]);
        assert_eq!(run.code, 0, "stderr: {}", run.stderr);
        json_of(&run)["rows"].as_array().unwrap().clone()
    };
    let live = rows();
    assert_eq!(live.len(), 1, "{live:?}");
    assert_eq!(live[0]["id"], thread, "the thread, not {session}");
    assert_eq!(live[0]["name"], "Fix the build");
    assert_eq!(live[0]["state"]["activity"]["kind"], "busy");

    let at = "2026-10-01T07:34:57.000Z";
    let event = |payload: serde_json::Value| serde_json::json!({"timestamp": at, "type": "event_msg", "payload": payload});
    let item = |item: serde_json::Value| {
        event(
            serde_json::json!({"type": "item_completed", "thread_id": thread, "turn_id": "u", "item": item}),
        )
    };
    let lines = [
        serde_json::json!({"timestamp": at, "type": "session_meta", "payload": {"id": thread, "cli_version": "0.157.0", "cwd": ws_arg}}),
        serde_json::json!({"timestamp": at, "type": "response_item", "payload": {"type": "message", "role": "user",
            "content": [{"type": "input_text", "text": "<environment_context>injected</environment_context>"}]}}),
        item(
            serde_json::json!({"type": "UserMessage", "id": "item-1", "content": [{"type": "text", "text": "fix the build"}]}),
        ),
        item(
            serde_json::json!({"type": "CommandExecution", "id": "c", "command": ["/bin/zsh", "-lc", "cargo build"],
            "status": "completed", "exit_code": 0}),
        ),
        item(
            serde_json::json!({"type": "AgentMessage", "id": "a", "phase": "final_answer",
            "content": [{"type": "Text", "text": "Built."}]}),
        ),
    ];
    let dir = h.join(".codex/sessions/2026/10/01");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join(format!("rollout-2026-10-01T10-34-56-{thread}.jsonl")),
        lines.iter().map(|l| format!("{l}\n")).collect::<String>(),
    )
    .unwrap();
    let log = bench(h, &["log", thread]);
    assert_eq!(log.code, 0, "stderr: {}", log.stderr);
    for line in [
        "2026-10-01 07:34:57  user   fix the build",
        "2026-10-01 07:34:57  tool   shell  cargo build",
        "2026-10-01 07:34:57  agent  Built.",
    ] {
        assert!(log.stdout.contains(line), "{line:?} in:\n{}", log.stdout);
    }
    assert!(!log.stdout.contains("injected"), "{}", log.stdout);

    // Listed as finished once benchd sees its process gone.
    libc_kill(pid);
    wait_until("the codex is finished", Duration::from_secs(5), || {
        rows()
            .first()
            .is_some_and(|r| r["state"]["kind"] == "finished")
    });
    let finished = rows();
    assert_eq!(finished.len(), 1, "{finished:?}");
    assert_eq!(finished[0]["id"], thread);
    assert_eq!(finished[0]["state"]["kind"], "finished");
    assert_eq!(finished[0]["open"]["argv"][1], "resume");
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

/// `codex app-server` on stdio, as much of it as `bench wiring --check` asks: it answers
/// `hooks/list` with `$HOME/codex-hooks-list.json`, and only while its stdin is open, as the
/// real one does.
const STUB_CODEX_APP_SERVER: &str = r#"[ "$1" = app-server ] || exit 2
while IFS= read -r line; do
  case "$line" in *'"hooks/list"'*)
    printf '{"id":2,"result":%s}\n' "$(cat "$HOME/codex-hooks-list.json")" ;;
  esac
done"#;

/// A stub `codex` (on the PATH this returns) whose `hooks/list` reports every hook in `merge`,
/// the codex half of `bench wiring`'s plan, at `trust`.
fn codex_trusting(h: &Path, merge: &serde_json::Value, trust: &str) -> String {
    let hooks: Vec<serde_json::Value> = merge["hooks"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(event, groups)| {
            serde_json::json!({ "eventName": event, "trustStatus": trust,
                "command": groups[0]["hooks"][0]["command"], "source": "user" })
        })
        .collect();
    let list = serde_json::json!({ "data": [{ "hooks": hooks }] });
    fs::write(h.join("codex-hooks-list.json"), list.to_string()).unwrap();
    let bin = write_agent_script(h, "codex", STUB_CODEX_APP_SERVER);
    format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    )
}

/// Every file right and codex not trusting its hooks is the state the operator's own codex was
/// in: it opened on "Hooks need review", ran no bench hook, and the check said all was well.
#[test]
fn wiring_check_fails_until_codex_trusts_its_hooks() {
    let home = TestHome::claim("trust");
    let h = &home.dir;
    let plan = json_of(&bench(h, &["wiring"]));
    let write = |rel: &str, value: &serde_json::Value| {
        let path = h.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, value.to_string()).unwrap();
    };
    write(".claude/settings.json", &plan["claude"]["merge"]);
    write(".codex/hooks.json", &plan["codex"]["merge"]);
    write(
        ".pi/agent/extensions/bench/index.ts",
        &serde_json::json!(""),
    );
    let check = |trust: &str| {
        let path = codex_trusting(h, &plan["codex"]["merge"], trust);
        bench_as(h, &["wiring", "--check"], &[("PATH", &path)])
    };

    for trust in ["untrusted", "modified"] {
        let run = check(trust);
        assert_eq!(
            run.code, 3,
            "{trust}: codex runs none of them: {}",
            run.stdout
        );
        let codex = &json_of(&run)["codex"];
        assert_eq!(codex["missing_events"], serde_json::json!([]), "{codex}");
        assert_eq!(
            codex["needs_review"].as_array().unwrap().len(),
            8,
            "{codex}"
        );
        assert!(
            codex["then"].as_str().unwrap().contains("Trust all"),
            "{codex}"
        );
    }
    let trusted = check("trusted");
    assert_eq!(trusted.code, 0, "{}", trusted.stdout);
    // A codex that lists none of them (another CODEX_HOME, hooks off) runs none of them.
    fs::write(h.join("codex-hooks-list.json"), r#"{"data": []}"#).unwrap();
    let path = format!(
        "{}:{}",
        h.join("bin").display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let unlisted = bench_as(h, &["wiring", "--check"], &[("PATH", &path)]);
    assert_eq!(unlisted.code, 3, "{}", unlisted.stdout);
    assert_eq!(
        json_of(&unlisted)["codex"]["needs_review"]
            .as_array()
            .unwrap()
            .len(),
        8
    );
    assert!(
        json_of(&trusted)["codex"].get("then").is_none(),
        "{}",
        trusted.stdout
    );
}

/// codex 0.159.3 saves the trust a `codex -p <name>` session accepts in
/// `~/.codex/<name>.config.toml`, which the app-server's `hooks/list` never reads: the operator
/// trusted all eight under `-p yolo` and the check kept telling him to trust them again.
#[test]
fn wiring_check_names_trust_saved_only_under_a_codex_profile() {
    let home = TestHome::claim("profile");
    let h = &home.dir;
    let plan = json_of(&bench(h, &["wiring"]));
    let write = |rel: &str, text: &str| {
        let path = h.join(rel);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    };
    write(
        ".claude/settings.json",
        &plan["claude"]["merge"].to_string(),
    );
    write(".codex/hooks.json", &plan["codex"]["merge"].to_string());
    write(".pi/agent/extensions/bench/index.ts", "");
    let merge = &plan["codex"]["merge"]["hooks"];
    let events: Vec<&String> = merge.as_object().unwrap().keys().collect();
    let hooks: Vec<serde_json::Value> = events
        .iter()
        .map(|event| {
            serde_json::json!({ "eventName": event, "trustStatus": "untrusted",
                "key": format!("hooks.json:{event}:0:0"), "currentHash": format!("sha256:{event}"),
                "command": merge[event.as_str()][0]["hooks"][0]["command"], "enabled": true })
        })
        .collect();
    write(
        "codex-hooks-list.json",
        &serde_json::json!({ "data": [{ "hooks": hooks }] }).to_string(),
    );
    let state = |hash: &dyn Fn(&str) -> String| {
        events
            .iter()
            .map(|e| {
                format!(
                    "[hooks.state.\"hooks.json:{e}:0:0\"]\ntrusted_hash = \"{}\"\n",
                    hash(e)
                )
            })
            .collect::<String>()
    };
    write(
        ".codex/yolo.config.toml",
        &state(&|e| format!("sha256:{e}")),
    );
    // Trust in a profile for an older definition of the hook covers nothing now.
    write(
        ".codex/old.config.toml",
        &state(&|_| "sha256:before".into()),
    );
    let bin = write_agent_script(h, "codex", STUB_CODEX_APP_SERVER);
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );

    let run = bench_as(h, &["wiring", "--check"], &[("PATH", &path)]);
    assert_eq!(run.code, 3, "plain codex still runs none: {}", run.stdout);
    let codex = &json_of(&run)["codex"];
    assert_eq!(
        codex["needs_review"].as_array().unwrap().len(),
        8,
        "{codex}"
    );
    assert_eq!(
        codex["trusted_only_under_profile"],
        serde_json::json!({ "yolo": codex["needs_review"] }),
        "{codex}"
    );
    assert!(
        codex["then"]
            .as_str()
            .unwrap()
            .contains("plain `codex` (no `-p`)"),
        "{codex}"
    );
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
    assert_eq!(
        plan["claude_statusline"]["statusLine"]["command"],
        format!("{bench_path} statusline <your current statusLine command>"),
        "the operator's own statusline goes after `statusline`, never away"
    );

    // codex itself is a stub that trusts every hook: this test is about the files.
    let path = codex_trusting(h, &plan["codex"]["merge"], "trusted");
    let check = || bench_as(h, &["wiring", "--check"], &[("PATH", &path)]);
    let unwired = check();
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
    let half = json_of(&check());
    assert_eq!(half["claude"]["missing_events"], serde_json::json!([]));
    assert_eq!(
        half["claude"]["cross_session_inbound_accept"], false,
        "{half}"
    );

    claude["crossSessionInbound"] = serde_json::json!("accept");
    write(".claude/settings.json", &claude);
    let wired = check();
    assert_eq!(wired.code, 0, "all wired: {}", wired.stdout);
    assert_eq!(
        json_of(&wired)["claude"]["statusline_reports_limits"],
        false,
        "the statusline is optional: reported, not required"
    );
    claude["statusLine"] = serde_json::json!({"type": "command",
        "command": format!("{bench_path} statusline ~/.claude/statusline.py")});
    write(".claude/settings.json", &claude);
    let limits = json_of(&check());
    assert_eq!(
        limits["claude"]["statusline_reports_limits"], true,
        "{limits}"
    );
    assert!(
        !h.join(".bench").exists(),
        "wiring needs no daemon and writes nothing"
    );
}

/// A killed agent reports no `SessionEnd`, so its record stays, and `reconcile` keeps its last
/// report fresh while it waits on a prompt: `mail/who` must not name it over the live agent that
/// took the pane after it. (Two live agents never share a pane: the second is a guest, #644.)
#[test]
fn mail_who_skips_an_agent_whose_process_is_gone() {
    let home = TestHome::claim("whodead");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (dead_session, dead_pid) = terminal_process(h, "older");
    let (_, live_pid) = terminal_process(h, "newer");
    let report = |event: &str, session: &str, pid: u32| {
        hook_verb(
            &daemon.socket,
            serde_json::json!({"harness": "claude", "event": event, "session": session,
                "cwd": "/Users/op/Projects/helm", "pid": pid, "pane": HOOK_PANE,
                "messaging_socket": h.join("no-inbox.sock")}),
        )
    };
    report(
        "SessionStart",
        "ffffffff-1c4d-4e5f-8a6b-7c8d9e0f0000",
        dead_pid,
    );
    report(
        "PermissionRequest",
        "ffffffff-1c4d-4e5f-8a6b-7c8d9e0f0000",
        dead_pid,
    );
    assert_eq!(bench(h, &["close", &dead_session]).code, 0);
    wait_until("the first agent exits", Duration::from_secs(5), || {
        !libc_alive(dead_pid as i32)
    });
    let live = report(
        "SessionStart",
        "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2",
        live_pid,
    )["handle"]
        .as_str()
        .unwrap()
        .to_string();
    // Lets reconcile's quiet window (5 s) pass, so the dead agent's report is the later one.
    std::thread::sleep(Duration::from_secs(6));
    let run = bench(h, &["mail", "who", "--pane", HOOK_PANE]);
    assert_eq!(json_of(&run)["handle"], live.as_str(), "{}", run.stdout);
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

/// #500: `just/list` names the recipes `just/run` would run, in the justfile's own order, for
/// helm's command palette. No justfile is no recipes rather than a refusal, because the palette
/// asks every time it opens; a justfile `just` cannot parse is refused in `just`'s words.
#[test]
fn the_recipes_are_listed_in_the_justfiles_order() {
    if !just_available() {
        return;
    }
    let home = TestHome::claim("justlist");
    let rules = home.dir.join(".bench").join("rules");
    let daemon = DaemonGuard::start(&home.dir, None);
    let list = || {
        layout(
            &daemon.socket,
            "just/list",
            serde_json::json!({}),
            None,
            false,
        )
    };
    assert_eq!(
        ok_data(list())["recipes"],
        serde_json::json!([]),
        "no justfile"
    );

    fs::create_dir_all(&rules).unwrap();
    fs::write(
        rules.join("justfile"),
        "zed:\n    true\n\nopen:\n    true\n\n_helper:\n    true\n",
    )
    .unwrap();
    assert_eq!(
        ok_data(list())["recipes"],
        serde_json::json!(["zed", "open"]),
        "in the file's order, and a private recipe is not offered"
    );

    fs::write(rules.join("justfile"), "open\n    true\n").unwrap();
    let broken = list();
    assert_eq!(broken["status"], "refused", "{broken}");
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

/// Whether a file exists is benchd's to say, on its own disk (M5c, #459): the operator's `bench`
/// may run on another machine, where a path on benchd's is absent. So the CLI only makes the path
/// absolute and checks what kind of file it is, and benchd refuses a canvas it cannot find.
#[test]
fn a_canvas_that_is_not_on_benchds_disk_is_refused_by_benchd() {
    let home = TestHome::claim("m5c-open");
    let ws = workspace(&home.dir).display().to_string();
    let daemon = DaemonGuard::start(&home.dir, None);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    let missing = home.dir.join("nowhere/plan.md").display().to_string();
    // Straight to benchd, as a `bench` whose own disk does not matter would send it.
    let reply = layout(
        &daemon.socket,
        "pane/open",
        serde_json::json!({ "surface": { "kind": "canvas", "source": { "kind": "file", "path": missing } } }),
        None,
        false,
    );
    assert_eq!(reply["status"], "refused", "{reply}");
    assert_eq!(reply["reason"], format!("no file at {missing}"));
    let cli = bench(&home.dir, &["open", &missing]);
    assert_eq!(cli.code, 3, "{}", cli.stderr);
    assert!(
        cli.stderr.contains(&format!("no file at {missing}")),
        "{}",
        cli.stderr
    );
    // The kind of file is still the CLI's to check: it needs no disk.
    let text = bench(&home.dir, &["open", "notes.txt"]);
    assert!(
        text.stderr.contains("is not a file helm renders"),
        "{}",
        text.stderr
    );

    let plan = artifact(&home.dir, "plan.md");
    let opened = bench(&home.dir, &["open", &plan]);
    assert_eq!(opened.code, 0, "{}", opened.stderr);
}

/// `sessions` carries what the agent in each session says it is doing (M5c, #459): helm's presence
/// dots and the snapshot's `agent` read it there, so neither reads Claude's registry on helm's
/// machine. benchd reads the row for the session's foreground process from its own HOME.
#[test]
fn sessions_report_what_the_agent_in_a_pane_says_it_is_doing() {
    let home = TestHome::claim("m5c-report");
    let h = &home.dir;
    let ws = workspace(h).display().to_string();
    let daemon = DaemonGuard::start(h, None);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    let pane = json_of(&bench(h, &["open", "terminal"]))["pane"]
        .as_str()
        .unwrap()
        .to_string();
    let sid = pane_session(h, &pane).expect("the new pane names a session");
    let pid = u32::try_from(session_row(h, &sid)["pid"].as_i64().unwrap()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while session_row(h, &sid)["foreground_pid"] != pid {
        assert!(Instant::now() < deadline, "{}", session_row(h, &sid));
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(
        session_row(h, &sid).get("report").is_none(),
        "a shell nobody reports for has no report"
    );

    // A Claude registry row for the process holding the pane's terminal.
    let started = bench_sessions::process::started_at_secs(pid).unwrap() * 1000;
    let row = h.join(format!(".claude/sessions/{pid}.json"));
    fs::create_dir_all(row.parent().unwrap()).unwrap();
    fs::write(
        &row,
        serde_json::json!({"pid": pid, "sessionId": "c-1", "cwd": ws, "startedAt": started,
            "status": "waiting", "waitingFor": "permission prompt", "statusUpdatedAt": started + 7})
        .to_string(),
    )
    .unwrap();
    let got = session_row(h, &sid);
    let report: bench_wire::AgentReport =
        serde_json::from_value(got["report"].clone()).unwrap_or_else(|e| panic!("{e}: {got}"));
    assert_eq!(
        report,
        bench_wire::AgentReport {
            activity: bench_wire::Activity::Waiting {
                waiting_for: Some("permission prompt".into())
            },
            since_ms: Some(started + 7),
        }
    );
}

/// A pane's agent is found through the shell the pane shows. A session benchd spawned is listed as
/// its own session already, so the pane showing it adds nothing (it would list it twice).
#[test]
fn a_pane_showing_a_spawned_session_places_no_second_agent() {
    let home = TestHome::claim("m5c-spawned");
    let h = &home.dir;
    let ws = workspace(h);
    let _daemon = DaemonGuard::start(h, None);
    let (sid, pid) = terminal_process(h, "spawned");
    let pane = session_row(h, &sid)["pane"].clone();
    assert!(pane.is_string(), "the spawn is shown in a pane: {pane}");
    let started = bench_sessions::process::started_at_secs(pid).unwrap() * 1000;
    let row = h.join(format!(".claude/sessions/{pid}.json"));
    fs::create_dir_all(row.parent().unwrap()).unwrap();
    fs::write(
        &row,
        serde_json::json!({"pid": pid, "sessionId": "via-pane", "cwd": ws, "startedAt": started,
            "status": "idle"})
        .to_string(),
    )
    .unwrap();
    let list = bench(
        h,
        &[
            "sessions",
            "--all",
            "--workspace",
            &ws.display().to_string(),
        ],
    );
    assert_eq!(list.code, 0, "{}", list.stderr);
    let list: bench_wire::SessionList = serde_json::from_str(&list.stdout).unwrap();
    assert!(
        list.rows.iter().all(|r| r.id != "via-pane"),
        "{:?}",
        list.rows
    );
}

/// `bench --version` is what helm compares with `status.version` before it runs its own `bench`
/// in a pane against a benchd over TCP, so the two say the same thing for the same build.
#[test]
fn bench_version_is_what_benchd_says_in_status() {
    let home = TestHome::claim("m5c-version");
    let _daemon = DaemonGuard::start(&home.dir, None);
    let version = bench(&home.dir, &["--version"]);
    assert_eq!(version.code, 0, "{}", version.stderr);
    let status = json_of(&bench(&home.dir, &["status"]));
    assert_eq!(status["version"], version.stdout.trim());
    // Every field helm reads of `status` (`fixtures/helm-ask.json`), a string in a live answer.
    let fixture: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/helm-ask.json"),
        )
        .unwrap(),
    )
    .unwrap();
    for key in fixture["status_reply"].as_object().unwrap().keys() {
        assert!(status[key].is_string(), "{key} in {status}");
    }
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

    // A shell at its prompt closes without --force (nothing runs there to lose), and the pane
    // holding the keyboard needs --asked, whatever --force says.
    let idle = bench(&home.dir, &["close", &right]);
    assert_eq!(idle.code, 0, "{}", idle.stderr);
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
    m4_proof();
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
    assert_eq!(document(&daemon.socket), before);
    // The bench's own terminal panes run shells; no agent was started.
    let listed = json_of(&bench(&home.dir, &["sessions"]));
    assert!(
        listed["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .all(|s| s["agent"] == "shell"),
        "{listed}"
    );
}

#[test]
fn ctrl_backslash_detaches_a_terminal_viewer_and_reaches_the_session_from_a_pane() {
    // In a shell Ctrl-\ is SIGQUIT, so a helm pane (`--in-pane`) must pass it on; a viewer in
    // the operator's own terminal keeps it as the detach key.
    let home = TestHome::claim("m5b-detach");
    // The session quits on SIGQUIT by a trap rather than by the signal's default action,
    // which dumps core: `cat` killed that way left a crash report in
    // ~/Library/Logs/DiagnosticReports on every run. `read` and `echo` are builtins, so the
    // shell is the pty's whole foreground group.
    let _daemon = DaemonGuard::start_with_script(
        &home.dir,
        "pi",
        "trap 'exit 0' QUIT\nwhile IFS= read -r line; do echo \"$line\"; done",
    );
    let wait_exit = |child: &mut Child| {
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if child.try_wait().unwrap().is_some() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = child.kill();
        let _ = child.wait();
        false
    };
    let live = |sid: &str| {
        json_of(&bench(&home.dir, &["sessions"]))["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["session"] == sid)
            .is_some_and(|s| s["live"] == true)
    };
    for (extra, session_survives) in [(&[][..], true), (&["--in-pane"][..], false)] {
        let run = bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", "/tmp"]);
        let sid = json_of(&run)["session"].as_str().unwrap().to_string();
        let (mut master, mut viewer) = attach_on_pty(&home.dir, &sid, extra, 24, 80);
        std::thread::sleep(Duration::from_millis(500));
        master.write_all(b"\x1c").unwrap();
        assert!(wait_exit(&mut viewer), "{extra:?}: the viewer ends");
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(
            live(&sid),
            session_survives,
            "{extra:?}: detaching leaves the session; a forwarded Ctrl-\\ quits the agent"
        );
    }
}

#[test]
fn a_malformed_attach_stream_ends_the_attachment_and_not_the_session() {
    let home = TestHome::claim("m5b-garbage");
    let daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(
        &home.dir,
        &["spawn", "--agent", "test-echo", "--cwd", "/tmp"],
    );
    let sid = json_of(&run)["session"].as_str().unwrap().to_string();
    let (resp, stream) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": sid}),
    );
    assert_eq!(resp["status"], "ok", "{resp}");
    // Unframed keys, as a client from before framing would send them.
    (&stream).write_all(b"ls\n").unwrap();
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let mut rest = Vec::new();
    let _ = (&stream).read_to_end(&mut rest);
    let listed = json_of(&bench(&home.dir, &["sessions"]));
    assert_eq!(listed["sessions"][0]["live"], true, "{listed}");
    assert_eq!(listed["sessions"][0]["attached"], false, "{listed}");
}

/// A daemon whose `pi` prints its size (`stty size`) whenever its pty's size changes, once it
/// has said `ready`.
fn size_reporting_daemon(home: &Path) -> DaemonGuard {
    scripted_pi_daemon(
        home,
        "#!/bin/sh\ntrap 'stty size' WINCH\necho ready\nwhile :; do sleep 0.1; done\n",
    )
}

/// A daemon whose `pi` is `script`.
fn scripted_pi_daemon(home: &Path, script: &str) -> DaemonGuard {
    let bin = home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let agent = bin.join("pi");
    fs::write(&agent, script).unwrap();
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&agent, fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::var("PATH").unwrap_or_default();
    let mut cmd = isolated(benchd_bin());
    cmd.env("PATH", format!("{}:{path}", bin.display()));
    DaemonGuard::start_with(home, None, cmd)
}

#[test]
fn a_viewer_terminal_being_dragged_resizes_the_session_to_its_last_size() {
    let home = TestHome::claim("m5b-drag");
    let _daemon = size_reporting_daemon(&home.dir);
    let ws = workspace(&home.dir).display().to_string();
    let run = bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", &ws]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let sid = json_of(&run)["session"].as_str().unwrap().to_string();
    // `bench attach` on a terminal of its own: resizing that terminal, as dragging a pane
    // does, reaches the agent, and the last size of a burst is the one it keeps.
    let (master, mut viewer) = attach_on_pty(&home.dir, &sid, &["--in-pane"], 24, 80);
    let mut screen = master.try_clone().unwrap();
    let output = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    {
        let output = std::sync::Arc::clone(&output);
        std::thread::spawn(move || {
            let mut chunk = [0u8; 4096];
            while let Ok(n) = screen.read(&mut chunk) {
                if n == 0 {
                    break;
                }
                output.lock().unwrap().extend_from_slice(&chunk[..n]);
            }
        });
    }
    // The agent must be listening before the drag starts, or its signals land first.
    let shown_now = || String::from_utf8_lossy(&output.lock().unwrap()).into_owned();
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline && !shown_now().contains("ready") {
        std::thread::sleep(Duration::from_millis(20));
    }
    for cols in 81..=100 {
        set_size(&master, 30, cols);
        std::thread::sleep(Duration::from_millis(2));
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline
        && !String::from_utf8_lossy(&output.lock().unwrap()).contains("30 100")
    {
        std::thread::sleep(Duration::from_millis(50));
    }
    let shown = String::from_utf8_lossy(&output.lock().unwrap()).into_owned();
    let _ = viewer.kill();
    let _ = viewer.wait();
    assert!(
        shown.contains("30 100"),
        "the last size of a drag reaches the agent: {shown:?}"
    );
    assert!(
        !shown.contains("bench:"),
        "--in-pane prints nothing of its own: {shown:?}"
    );
}

/// Everything a pane's terminal is sent, from its master, as it arrives.
fn record_pane(master: &fs::File) -> std::sync::Arc<std::sync::Mutex<Vec<u8>>> {
    let output = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let recorded = std::sync::Arc::clone(&output);
    let mut screen = master.try_clone().unwrap();
    std::thread::spawn(move || {
        let mut chunk = [0u8; 4096];
        while let Ok(n) = screen.read(&mut chunk) {
            if n == 0 {
                break;
            }
            recorded.lock().unwrap().extend_from_slice(&chunk[..n]);
        }
    });
    output
}

/// Whether `done` holds within `secs`, asked every 50 ms.
fn within(secs: u64, done: &dyn Fn() -> bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < deadline && !done() {
        std::thread::sleep(Duration::from_millis(50));
    }
    done()
}

/// The lines of a screen, with trailing blanks and blank rows at the end dropped.
fn trimmed(lines: Vec<String>) -> Vec<String> {
    let mut lines: Vec<String> = lines
        .into_iter()
        .map(|l| l.trim_end().to_string())
        .collect();
    while lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    lines
}

#[test]
fn a_pane_whose_session_another_viewer_takes_waits_for_it_and_takes_it_back() {
    // A helm pane's viewer lost its session to a second attach (a test run reaching the
    // operator's benchd did exactly this) and exited, so the pane showed "Process exited" with
    // its agent still running and no way back to it. Now it says so, waits, and attaches again.
    let home = TestHome::claim("m5b-retake");
    let daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(
        &home.dir,
        &["spawn", "--agent", "test-echo", "--cwd", "/tmp"],
    );
    let sid = json_of(&run)["session"].as_str().unwrap().to_string();
    let (mut master, mut viewer) = attach_on_pty(&home.dir, &sid, &["--in-pane"], 24, 80);
    let output = record_pane(&master);
    let shown = || String::from_utf8_lossy(&output.lock().unwrap()).into_owned();
    let attached = || json_of(&bench(&home.dir, &["sessions"]))["sessions"][0]["attached"] == true;
    const NOTICE: &str = "another viewer took it over";
    assert!(within(5, &attached), "the pane's viewer attaches");

    let (answer, other) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": sid}),
    );
    assert_eq!(answer["status"], "ok", "{answer}");
    assert!(
        within(5, &|| shown().contains(NOTICE)),
        "the displaced pane says why: {:?}",
        shown()
    );
    assert!(
        viewer.try_wait().unwrap().is_none(),
        "the displaced pane's viewer keeps running"
    );

    // The other viewer lets go: the pane attaches again by itself, and its keys reach the
    // session again.
    drop(other);
    let notices = || shown().matches(NOTICE).count();
    std::thread::sleep(Duration::from_secs(3));
    assert!(within(5, &attached), "the pane took its session back");
    master.write_all(b"back-in-the-pane\n").unwrap();
    assert!(
        within(5, &|| shown()
            .rsplit(NOTICE)
            .next()
            .is_some_and(|after| after.contains("back-in-the-pane"))),
        "keys reach the session after the retake: {:?}",
        shown()
    );

    // Held again, a key takes it back at once: the other viewer's stream is closed.
    let (answer, other) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": sid}),
    );
    assert_eq!(answer["status"], "ok", "{answer}");
    assert!(within(5, &|| notices() == 2), "{:?}", shown());
    master.write_all(b"x").unwrap();
    let _ = other.set_read_timeout(Some(Duration::from_secs(5)));
    let mut rest = Vec::new();
    let _ = (&other).read_to_end(&mut rest);
    assert!(within(5, &attached), "the key took the session back");

    // Control, which passes either way: when the session ends, the pane's viewer still ends.
    master.write_all(b"\n\x04").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline && viewer.try_wait().unwrap().is_none() {
        std::thread::sleep(Duration::from_millis(50));
    }
    let ended = viewer.try_wait().unwrap();
    if ended.is_none() {
        let _ = viewer.kill();
        let _ = viewer.wait();
    }
    assert_eq!(
        ended.and_then(|s| s.code()),
        Some(0),
        "the viewer ends with its session: {:?}",
        shown()
    );
    assert!(
        within(5, &|| shown()
            .contains(&format!("{sid} has ended. `bench restore"))),
        "and leaves the pane saying so, not a bare dead terminal: {:?}",
        shown()
    );
}

/// A program that leaves history, a title and an alternate screen with a hidden cursor and
/// bracketed paste on, then on `go` undoes all of it and prints more. Written for a pane that is
/// displaced in between, so the retake has state to get right in both directions.
const REHYDRATES: &str = "#!/bin/sh
printf '\\033]2;before\\033\\\\'
i=1; while [ $i -le 60 ]; do echo \"line-$i\"; i=$((i+1)); done
printf '\\033[?1049h\\033[?25l\\033[?2004h\\033[5;3HALT-SCREEN'
while read l; do
  if [ \"$l\" = go ]; then
    printf '\\033[?2004l\\033[?25h\\033[?1049l\\033]2;after\\033\\\\'
    i=1; while [ $i -le 30 ]; do echo \"after-$i\"; i=$((i+1)); done
    echo ready-after
  fi
done
";

#[test]
fn a_retaken_pane_shows_the_session_as_it_is_and_paints_nothing_twice() {
    // The rehydration checklist (tuios's REHYDRATION.md, adopted for #494): after a reattach the
    // pane's screen, scrollback, cursor and modes are the session's, and no line appears twice.
    let home = TestHome::claim("m5b-rehydrate");
    let daemon = scripted_pi_daemon(&home.dir, REHYDRATES);
    let ws = workspace(&home.dir).display().to_string();
    let run = bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", &ws]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let sid = json_of(&run)["session"].as_str().unwrap().to_string();
    let (master, mut viewer) = attach_on_pty(&home.dir, &sid, &["--in-pane"], 24, 80);
    let output = record_pane(&master);
    let shown = || output.lock().unwrap().clone();
    assert!(within(10, &|| contains(&shown(), b"ALT-SCREEN")));

    // Displaced; the other viewer drives the program out of every mode it set, then lets go.
    let (answer, other) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": sid}),
    );
    assert_eq!(answer["status"], "ok", "{answer}");
    assert!(within(5, &|| contains(&shown(), b"another viewer")));
    (&other)
        .write_all(&AttachFrame::Input(b"go\n".to_vec()).encode())
        .unwrap();
    let seen = read_until(&other, Duration::from_secs(5), |b| {
        contains(b, b"ready-after")
    });
    assert!(contains(&seen, b"ready-after"));
    let retake_from = shown().len();
    drop(other);
    assert!(
        within(10, &|| contains(&shown()[retake_from..], b"ready-after")),
        "the pane attached again"
    );
    std::thread::sleep(Duration::from_millis(300));

    // Everything the pane's terminal was sent, read by a terminal of the pane's size.
    let mut pane = bench_vt::Terminal::new(80, 24, 1 << 20).unwrap();
    pane.write(&shown());
    let run = bench(&home.dir, &["get", "screen", &sid, "--history"]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let session = json_of(&run);
    let pane_lines = trimmed(pane.lines(true).unwrap());
    let session_lines = trimmed(
        session["lines"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l.as_str().unwrap().to_string())
            .collect(),
    );
    assert_eq!(pane_lines, session_lines, "screen and scrollback");
    for marker in ["line-1", "line-60", "after-1", "after-30"] {
        assert_eq!(
            pane_lines.iter().filter(|l| l.as_str() == marker).count(),
            1,
            "{marker} is painted once: {pane_lines:#?}"
        );
    }
    let (col, row) = pane.cursor();
    assert_eq!(
        (u64::from(col), u64::from(row)),
        (
            session["cursor"][0].as_u64().unwrap(),
            session["cursor"][1].as_u64().unwrap()
        ),
        "cursor"
    );
    assert_eq!(
        pane.alt_screen(),
        session["alt_screen"] == true,
        "alternate screen"
    );
    assert!(!pane.alt_screen());
    assert_eq!(
        pane.cursor_visible(),
        session["cursor_visible"] == true,
        "cursor visibility"
    );
    assert!(pane.cursor_visible());
    assert_eq!(
        pane.mode(bench_vt::Mode::BRACKETED_PASTE),
        session["bracketed_paste"] == true,
        "bracketed paste"
    );
    assert!(!pane.mode(bench_vt::Mode::BRACKETED_PASTE));
    assert_eq!(pane.title(), "after");
    let _ = viewer.kill();
    let _ = viewer.wait();
}

#[test]
fn an_attached_viewer_resizes_the_session_and_ends_when_it_does() {
    let home = TestHome::claim("m3-attach");
    let daemon = size_reporting_daemon(&home.dir);
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
    // The size rides the attach stream, in order with the keys (#359).
    (&stream)
        .write_all(&AttachFrame::Size { rows: 33, cols: 77 }.encode())
        .unwrap();
    let seen = read_until(&stream, Duration::from_secs(5), |seen| {
        String::from_utf8_lossy(seen).contains("33 77")
    });
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

/// A stand-in for helm: follow the bench and answer the first ask with `data`, whose `png` is
/// what a capture draws (M5c: the bytes, never a path). Returns the ask it saw.
fn answer_one_ask(
    socket: PathBuf,
    data: serde_json::Value,
) -> std::thread::JoinHandle<serde_json::Value> {
    std::thread::spawn(move || {
        let mut reader = follow(&socket);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        loop {
            line.clear();
            assert_ne!(reader.read_line(&mut line).unwrap_or(0), 0, "no ask came");
            let frame: serde_json::Value = serde_json::from_str(&line).unwrap();
            if frame["event"]["kind"] != "helm/asked" {
                continue;
            }
            let asked = frame["event"]["data"].clone();
            let answer = layout(
                &socket,
                "helm/answer",
                serde_json::json!({ "ask": asked["ask"], "status": "ok", "data": data }),
                Some(serde_json::json!({ "kind": "helm" })),
                false,
            );
            assert_eq!(answer["status"], "ok", "{answer}");
            return asked;
        }
    })
}

#[test]
fn a_screenshot_is_helms_answer_and_no_helm_is_an_error_naming_it() {
    let home = TestHome::claim("m3-shot");
    let daemon = DaemonGuard::start(&home.dir, None);
    let out = home.dir.join("shot.png").display().to_string();
    let png = b"\x89PNG\r\n\x1a\nnot really a picture".to_vec();

    // helm answers with the bytes; benchd writes them where the caller asked, on its own side.
    let helm = answer_one_ask(
        daemon.socket.clone(),
        serde_json::json!({ "png": bench_wire::base64(&png), "window": "helm — m3" }),
    );
    let shot = bench(&home.dir, &["get", "screenshot", "--out", &out]);
    assert_eq!(shot.code, 0, "{}", shot.stderr);
    let report = json_of(&shot);
    assert_eq!(report["path"], out.as_str());
    assert_eq!(report["window"], "helm — m3");
    assert!(
        report.get("png").is_none(),
        "the caller gets a path, not the bytes: {report}"
    );
    assert_eq!(fs::read(&out).unwrap(), png);
    let asked = helm.join().unwrap();
    assert!(
        asked["request"].get("path").is_none(),
        "helm is never told a path on benchd's machine: {asked}"
    );

    // No --out: benchd picks one under its own root, which the CLI's side may not share.
    let helm = answer_one_ask(
        daemon.socket.clone(),
        serde_json::json!({ "png": bench_wire::base64(&png), "window": "helm — m3" }),
    );
    let shot = bench(&home.dir, &["get", "screenshot"]);
    assert_eq!(shot.code, 0, "{}", shot.stderr);
    let path = PathBuf::from(json_of(&shot)["path"].as_str().unwrap());
    assert!(
        path.starts_with(home.dir.join(".bench/captures")),
        "{}",
        path.display()
    );
    assert_eq!(fs::read(&path).unwrap(), png);
    helm.join().unwrap();

    // An answer with no PNG in it is an error naming that, and writes nothing.
    let missing = home.dir.join("missing.png").display().to_string();
    let helm = answer_one_ask(daemon.socket.clone(), serde_json::json!({ "window": "w" }));
    let shot = bench(&home.dir, &["get", "screenshot", "--out", &missing]);
    assert_eq!(shot.code, 4, "{}", shot.stderr);
    assert!(shot.stderr.contains("no PNG"), "{}", shot.stderr);
    assert!(!Path::new(&missing).exists());
    helm.join().unwrap();

    // A folder that does not exist on benchd's side is refused before helm is asked.
    let asks_before = log_of(&home.dir.join(".bench"))
        .iter()
        .filter(|e| e["kind"] == "helm/asked")
        .count();
    let nowhere = home.dir.join("no/such/dir/x.png").display().to_string();
    let refused = bench(&home.dir, &["get", "screenshot", "--out", &nowhere]);
    assert_eq!(refused.code, 3, "{}", refused.stderr);
    assert!(
        refused.stderr.contains("no directory"),
        "{}",
        refused.stderr
    );
    let asks_after = log_of(&home.dir.join(".bench"))
        .iter()
        .filter(|e| e["kind"] == "helm/asked")
        .count();
    assert_eq!(
        asks_before, asks_after,
        "nobody drew a window for a path that cannot be written"
    );

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

/// helm's answer carries a whole PNG, so `helm/answer` takes the large request line `file/write`
/// does; every other verb keeps the small one.
#[test]
fn a_capture_answer_may_be_large_and_a_status_may_not() {
    let home = TestHome::claim("m5c-bigshot");
    let daemon = DaemonGuard::start(&home.dir, None);
    let out = home.dir.join("big.png").display().to_string();
    let png = vec![0x89u8; 3 * 1024 * 1024];
    let helm = answer_one_ask(
        daemon.socket.clone(),
        serde_json::json!({ "png": bench_wire::base64(&png), "window": "w" }),
    );
    let shot = bench(&home.dir, &["get", "screenshot", "--out", &out]);
    assert_eq!(shot.code, 0, "{}", shot.stderr);
    assert_eq!(fs::read(&out).unwrap().len(), png.len());
    helm.join().unwrap();
    let big = layout(
        &daemon.socket,
        "status",
        serde_json::json!({ "pad": "x".repeat(100 * 1024) }),
        None,
        false,
    );
    assert_eq!(big["status"], "refused", "{big}");
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
    assert_eq!(
        snippets.len(),
        5,
        "open, get pane, spawn, tidy up, read and type"
    );

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
        if i == 4 {
            assert!(
                stdout.lines().any(|l| l == "ready"),
                "the shell's screen: {stdout}"
            );
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
    assert_eq!(
        snippets.len(),
        3,
        "open, then show and take away, then change a live file"
    );

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
    let live = saved(&home.dir, "tasks.data.json", "{\"items\": []}\n");
    let mut pane = String::new();
    for (i, snippet) in snippets.iter().enumerate() {
        let out = isolated("bash")
            .args(["-euo", "pipefail", "-c", snippet])
            .current_dir(&home.dir)
            .env("HOME", &home.dir)
            .env("BENCH_DIR", home.dir.join(".bench"))
            .env("BENCH", bench_bin())
            .env("ARTIFACT", &plan)
            .env("LIVE", &live)
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
    let written: serde_json::Value = serde_json::from_str(&fs::read_to_string(&live).unwrap())
        .expect("the live file is still JSON");
    assert_eq!(written["reply"], "on it", "the agent's change landed");
}

#[test]
fn the_helm_orchestrate_skills_snippets_execute_against_a_real_daemon() {
    // The orchestration skill's two snippets run here, in order, as an orchestrator would run
    // them: spawn a workstream and append its launch to the run file, then read the fleet.
    let skill = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../.claude/skills/helm-orchestrate/SKILL.md"),
    )
    .expect("helm-orchestrate SKILL.md readable");
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
    assert_eq!(snippets.len(), 2, "spawn and record, then read the fleet");

    let home = TestHome::claim("orch-skill");
    let _daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    let ws = workspace(&home.dir);
    let brief = artifact(&home.dir, "ws1.md");
    let run = home.dir.join("run.md");
    fs::write(&run, "## Event log\n\n- 10:00 run started\n").unwrap();
    let mut outputs = Vec::new();
    for (i, snippet) in snippets.iter().enumerate() {
        let out = isolated("bash")
            .args(["-euo", "pipefail", "-c", snippet])
            .current_dir(&ws)
            .env("HOME", &home.dir)
            .env("BENCH_DIR", home.dir.join(".bench"))
            .env("BENCH", bench_bin())
            .env("AGENT", "pi")
            .env("MODEL", "openai-codex/gpt-6-luna")
            .env("EFFORT", "low")
            .env("WORKTREE", &ws)
            .env("WS", "ws1")
            .env("BRIEF", &brief)
            .env("RUN", &run)
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
    let log = fs::read_to_string(&run).unwrap();
    let launch = log.lines().last().unwrap();
    assert!(
        launch.contains("launched ws1: pi openai-codex/gpt-6-luna, session s"),
        "the launch is the run file's last line: {log}"
    );
    assert!(
        !launch.contains("runtime -,"),
        "pi's conversation id is recorded for --resume: {launch}"
    );
    assert_eq!(
        outputs[0].trim(),
        launch,
        "the snippet echoes what it recorded"
    );
    assert!(
        outputs[1]
            .lines()
            .any(|l| l.starts_with("ws1 pi unknown ") && l.ends_with(" unread=0")),
        "the fleet lists the workstream by handle: {}",
        outputs[1]
    );
}

// ---------------------------------------------------------------------------
// M5b: every terminal pane is a benchd session (#359)
// ---------------------------------------------------------------------------

/// The session a pane shows, from the document.
fn pane_session(home: &Path, pane: &str) -> Option<String> {
    let found = json_of(&bench(home, &["get", "pane", pane]));
    found["pane"]["surface"]["session"]
        .as_str()
        .map(str::to_string)
}

/// Type `line` into session `sid` and read what comes back until `done` says it is enough.
fn type_into(socket: &Path, sid: &str, line: &str, done: impl Fn(&str) -> bool) -> String {
    let (resp, stream) = raw_request(socket, "attach", serde_json::json!({"session": sid}));
    assert_eq!(resp["status"], "ok", "{resp}");
    let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
    (&stream)
        .write_all(&AttachFrame::Input(line.as_bytes().to_vec()).encode())
        .unwrap();
    let seen = read_until(&stream, Duration::from_secs(10), |seen| {
        done(&String::from_utf8_lossy(seen))
    });
    String::from_utf8_lossy(&seen).into_owned()
}

fn session_row(home: &Path, sid: &str) -> serde_json::Value {
    json_of(&bench(home, &["sessions"]))["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["session"] == sid)
        .cloned()
        .unwrap_or(serde_json::Value::Null)
}

#[test]
fn a_new_terminal_pane_is_a_login_shell_with_the_panes_environment() {
    let home = TestHome::claim("m5b-shell");
    let ws = workspace(&home.dir).display().to_string();
    // What an agent that started benchd would leak into every pane (#139).
    let mut cmd = isolated(benchd_bin());
    cmd.env("CLAUDECODE", "1").env("PI_CODING_AGENT", "true");
    let daemon = DaemonGuard::start_with(&home.dir, None, cmd);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    let opened = bench(&home.dir, &["open", "terminal"]);
    assert_eq!(opened.code, 0, "{}", opened.stderr);
    let pane = json_of(&opened)["pane"].as_str().unwrap().to_string();
    let sid = pane_session(&home.dir, &pane).expect("the new pane names a session");
    // What a live daemon answers decodes as the type helm's copy is pinned against.
    serde_json::from_value::<bench_wire::LiveSessions>(json_of(&bench(&home.dir, &["sessions"])))
        .expect("`sessions` answers LiveSessions");
    let row = session_row(&home.dir, &sid);
    assert_eq!(row["agent"], "shell", "{row}");
    assert_eq!(row["live"], true, "{row}");
    assert_eq!(row["pane"], pane.as_str(), "{row}");
    assert_eq!(row["cwd"], ws.as_str(), "{row}");

    let out = type_into(
        &daemon.socket,
        &sid,
        "printf 'E%s|%s|%s|%s|%s|%s\\n' \"$HELM_PANE\" \"$COLORTERM\" \"$TERM_PROGRAM\" \"${BENCH_SESSION:-none}\" \"${CLAUDECODE:-none}\" \"${PI_CODING_AGENT:-none}\"\n",
        |seen| seen.contains(&format!("E{pane}|")),
    );
    let line = out
        .lines()
        .find(|l| l.starts_with(&format!("E{pane}|")))
        .unwrap_or_else(|| panic!("no answer: {out:?}"));
    assert_eq!(
        line.trim(),
        format!("E{pane}|truecolor|ghostty|none|none|none"),
        "the pane's identity, truecolor, and nobody else's session"
    );
}

#[test]
fn an_idle_shell_closes_without_force_and_a_busy_one_names_what_runs() {
    let home = TestHome::claim("m5b-busy");
    let ws = workspace(&home.dir).display().to_string();
    let daemon = DaemonGuard::start(&home.dir, None);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    let mut panes = Vec::new();
    for _ in 0..2 {
        let run = bench(&home.dir, &["open", "terminal"]);
        assert_eq!(run.code, 0, "{}", run.stderr);
        panes.push(json_of(&run)["pane"].as_str().unwrap().to_string());
    }
    let sid = pane_session(&home.dir, &panes[1]).unwrap();
    let pid = session_row(&home.dir, &sid)["pid"].as_i64().unwrap();
    // An interactive shell runs a job in a group of its own, which takes the terminal.
    let (resp, stream) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": sid}),
    );
    assert_eq!(resp["status"], "ok");
    (&stream)
        .write_all(&AttachFrame::Input(b"sleep 30\n".to_vec()).encode())
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while session_row(&home.dir, &sid)["foreground_pid"].as_i64() == Some(pid) {
        assert!(Instant::now() < deadline, "sleep never took the terminal");
        std::thread::sleep(Duration::from_millis(100));
    }
    let refused = bench(&home.dir, &["close", &panes[1]]);
    assert_eq!(refused.code, 3, "{}", refused.stderr);
    assert!(
        refused.stderr.contains("running sleep") && refused.stderr.contains("--force"),
        "{}",
        refused.stderr
    );
    let idle = bench(&home.dir, &["close", &panes[0]]);
    assert_eq!(idle.code, 0, "{}", idle.stderr);
    let forced = bench(&home.dir, &["close", &panes[1], "--force"]);
    assert_eq!(forced.code, 0, "{}", forced.stderr);
    // The shell went with its pane.
    let deadline = Instant::now() + Duration::from_secs(10);
    while libc_alive(pid as i32) {
        assert!(Instant::now() < deadline, "the shell outlived its pane");
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn closing_a_workspace_ends_the_shells_its_panes_ran() {
    let home = TestHome::claim("m5b-sweep");
    let ws = workspace(&home.dir).display().to_string();
    let daemon = DaemonGuard::start(&home.dir, None);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    let pane = json_of(&bench(&home.dir, &["open", "terminal"]))["pane"]
        .as_str()
        .unwrap()
        .to_string();
    let sid = pane_session(&home.dir, &pane).unwrap();
    let pid = session_row(&home.dir, &sid)["pid"].as_i64().unwrap() as i32;
    ok_data(layout(
        &daemon.socket,
        "workspace/close",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    let deadline = Instant::now() + Duration::from_secs(10);
    while libc_alive(pid) {
        assert!(Instant::now() < deadline, "a shell outlived its workspace");
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(session_row(&home.dir, &sid).is_null());
}

/// `bench workspace close` (#608): an orchestrator closes the workspace of a worktree it is done
/// with. It closes only what the agent could close pane by pane: a pane where something runs
/// needs --force, and the workspace the operator is in needs --asked. A workspace whose folder is
/// gone still closes, and nothing on disk is touched.
#[test]
fn an_agent_closes_a_workspace_only_as_it_could_close_its_panes() {
    let home = TestHome::claim("ws-close");
    let daemon = DaemonGuard::start(&home.dir, None);
    let dir = |name: &str| {
        let d = home.dir.join(name);
        fs::create_dir_all(d.join(".git")).unwrap();
        d.canonicalize().unwrap().display().to_string()
    };
    let (held, busy, gone) = (dir("held"), dir("busy"), dir("gone"));
    fs::write(Path::new(&busy).join("keep.txt"), "mine").unwrap();
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": held }),
        operator(),
        false,
    ));
    // The orchestrator's worktrees: background workspaces, each a shell.
    let mut first = Vec::new();
    for ws in [&busy, &gone] {
        let opened = ok_data(layout(
            &daemon.socket,
            "workspace/open",
            serde_json::json!({ "path": ws }),
            None,
            false,
        ));
        first.push(opened["pane_created"].as_str().unwrap().to_string());
    }
    let sid = pane_session(&home.dir, &first[0]).unwrap();
    let pid = session_row(&home.dir, &sid)["pid"].as_i64().unwrap();
    let (resp, stream) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": sid}),
    );
    assert_eq!(resp["status"], "ok");
    (&stream)
        .write_all(&AttachFrame::Input(b"sleep 30\n".to_vec()).encode())
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while session_row(&home.dir, &sid)["foreground_pid"].as_i64() == Some(pid) {
        assert!(Instant::now() < deadline, "sleep never took the terminal");
        std::thread::sleep(Duration::from_millis(100));
    }
    let open = |doc: &serde_json::Value| -> Vec<String> {
        doc["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| w["path"].as_str().unwrap().to_string())
            .collect()
    };

    let refused = bench(&home.dir, &["workspace", "close", &busy]);
    assert_eq!(refused.code, 3, "{}", refused.stderr);
    assert!(
        refused.stderr.contains("running sleep") && refused.stderr.contains("--force"),
        "{}",
        refused.stderr
    );
    assert!(open(&document(&daemon.socket)).contains(&busy));
    let forced = bench(&home.dir, &["workspace", "close", &busy, "--force"]);
    assert_eq!(forced.code, 0, "{}", forced.stderr);
    let deadline = Instant::now() + Duration::from_secs(10);
    while libc_alive(pid as i32) {
        assert!(
            Instant::now() < deadline,
            "the shell outlived its workspace"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(
        fs::read_to_string(Path::new(&busy).join("keep.txt")).unwrap(),
        "mine",
        "closing a workspace touches no file"
    );
    assert!(Path::new(&busy).join(".git").is_dir(), "nor git");

    // A removed worktree: its folder is gone, its shell idles at the prompt.
    fs::remove_dir_all(&gone).unwrap();
    let closed = bench(&home.dir, &["workspace", "close", &gone]);
    assert_eq!(closed.code, 0, "{}", closed.stderr);

    // The operator's own workspace moves his focus, whatever --force says.
    let mine = bench(&home.dir, &["workspace", "close", &held, "--force"]);
    assert_eq!(mine.code, 3, "{}", mine.stderr);
    assert!(mine.stderr.contains("--asked"), "{}", mine.stderr);
    assert_eq!(open(&document(&daemon.socket)), vec![held.clone()]);
    let asked = bench(&home.dir, &["workspace", "close", &held, "--asked"]);
    assert_eq!(asked.code, 0, "{}", asked.stderr);
    assert!(open(&document(&daemon.socket)).is_empty());
}

/// A spawned agent's session in a background workspace: the other half of the rule, a live
/// agent rather than a shell's job, refused naming the session (#608).
#[test]
fn closing_a_workspace_where_an_agent_runs_needs_force() {
    let home = TestHome::claim("ws-close-agent");
    let daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    working_bench(&daemon.socket);
    let ws = workspace(&home.dir).display().to_string();
    let spawned = bench(
        &home.dir,
        &["spawn", "--agent", "pi", "--cwd", &ws, "--name", "worker"],
    );
    assert_eq!(spawned.code, 0, "{}", spawned.stderr);
    let session = json_of(&spawned)["session"].as_str().unwrap().to_string();
    let refused = bench(&home.dir, &["workspace", "close", &ws]);
    assert_eq!(refused.code, 3, "{}", refused.stderr);
    assert!(
        refused.stderr.contains(&session) && refused.stderr.contains("--force"),
        "{}",
        refused.stderr
    );
    let forced = bench(&home.dir, &["workspace", "close", &ws, "--force"]);
    assert_eq!(forced.code, 0, "{}", forced.stderr);
}

#[test]
fn after_a_restart_restore_resumes_the_recorded_agent_and_gives_other_panes_a_shell() {
    let home = TestHome::claim("m5b-restore");
    let ws = workspace(&home.dir).display().to_string();
    let (agent_pane, shell_pane, runtime, old_ids) = {
        let daemon = DaemonGuard::start_with_fake_pi(&home.dir);
        ok_data(layout(
            &daemon.socket,
            "workspace/open",
            serde_json::json!({ "path": ws }),
            operator(),
            false,
        ));
        let spawned = bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", &ws]);
        assert_eq!(spawned.code, 0, "{}", spawned.stderr);
        let spawned = json_of(&spawned);
        let shell = bench(&home.dir, &["open", "terminal"]);
        assert_eq!(shell.code, 0, "{}", shell.stderr);
        let before: Vec<String> = json_of(&bench(&home.dir, &["sessions"]))["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["session"].as_str().unwrap().to_string())
            .collect();
        (
            spawned["pane"].as_str().unwrap().to_string(),
            json_of(&shell)["pane"].as_str().unwrap().to_string(),
            spawned["runtime_session"].as_str().unwrap().to_string(),
            before,
        )
    };
    let _daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    assert_eq!(
        pane_session(&home.dir, &agent_pane),
        None,
        "no session outlives its daemon"
    );
    assert_eq!(pane_session(&home.dir, &shell_pane), None);

    let run = bench(&home.dir, &["restore", "--all"]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let restored = json_of(&run)["restored"].as_array().unwrap().clone();
    let how = |pane: &str| {
        restored
            .iter()
            .find(|r| r["pane"] == pane)
            .map(|r| r["how"].as_str().unwrap().to_string())
    };
    assert_eq!(how(&agent_pane).as_deref(), Some("resumed"), "{restored:?}");
    assert_eq!(how(&shell_pane).as_deref(), Some("shell"), "{restored:?}");
    // A session id never repeats across restarts: helm keeps a pane's surface while its session
    // id is unchanged, so a reused id would leave the pane showing the ended session.
    for r in &restored {
        let id = r["session"].as_str().unwrap();
        assert!(
            !old_ids.iter().any(|o| o == id),
            "{id} was used before the restart: {old_ids:?}"
        );
    }
    let agent = session_row(&home.dir, &pane_session(&home.dir, &agent_pane).unwrap());
    assert_eq!(agent["agent"], "pi");
    assert_eq!(
        agent["runtime_session"],
        runtime.as_str(),
        "the same conversation"
    );
    assert_eq!(agent["live"], true);
    let shell = session_row(&home.dir, &pane_session(&home.dir, &shell_pane).unwrap());
    assert_eq!(shell["agent"], "shell");
    assert_eq!(shell["live"], true);

    let again = json_of(&bench(&home.dir, &["restore", "--all"]));
    assert_eq!(
        again["restored"],
        serde_json::json!([]),
        "live panes are left alone"
    );
}

#[test]
fn restore_never_resumes_a_conversation_a_live_session_already_holds() {
    // `just release-resume` resumes its caller's conversation in a pane of its own, then restores
    // the rest: the caller's old pane must not resume it a second time, which would fork it.
    let home = TestHome::claim("m5b-nofork");
    let ws = workspace(&home.dir).display().to_string();
    let (old_pane, runtime) = {
        let daemon = DaemonGuard::start_with_fake_pi(&home.dir);
        ok_data(layout(
            &daemon.socket,
            "workspace/open",
            serde_json::json!({ "path": ws }),
            operator(),
            false,
        ));
        let spawned = json_of(&bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", &ws]));
        (
            spawned["pane"].as_str().unwrap().to_string(),
            spawned["runtime_session"].as_str().unwrap().to_string(),
        )
    };
    let _daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    let resumed = bench(
        &home.dir,
        &["spawn", "--agent", "pi", "--cwd", &ws, "--resume", &runtime],
    );
    assert_eq!(resumed.code, 0, "{}", resumed.stderr);

    let restored = json_of(&bench(&home.dir, &["restore", "--all"]));
    let old = restored["restored"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["pane"] == old_pane.as_str())
        .cloned()
        .unwrap_or_else(|| panic!("{restored}"));
    assert_eq!(old["how"], "shell", "{restored}");
    assert!(
        old["note"]
            .as_str()
            .is_some_and(|n| n.contains("already live")),
        "the answer says why it was not resumed: {restored}"
    );
    let holders = json_of(&bench(&home.dir, &["sessions"]))["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s["runtime_session"] == runtime.as_str() && s["live"] == true)
        .count();
    assert_eq!(holders, 1, "one process on the conversation");
}

/// `pid` holds Claude conversation `id`, as Claude's own registry says: the row a live claude
/// keeps at `~/.claude/sessions/<pid>.json`.
fn claude_holds(home: &Path, pid: u32, id: &str) {
    let started = bench_sessions::process::started_at_secs(pid).unwrap() * 1000;
    let row = home.join(format!(".claude/sessions/{pid}.json"));
    fs::create_dir_all(row.parent().unwrap()).unwrap();
    fs::write(
        &row,
        serde_json::json!({"pid": pid, "sessionId": id, "cwd": "/tmp", "startedAt": started,
            "status": "idle"})
        .to_string(),
    )
    .unwrap();
}

#[test]
fn restore_never_resumes_a_claude_conversation_a_process_outside_benchd_holds() {
    // 2026-10-02: the orchestrator ran as `claude --resume <id>` in a terminal outside helm, and
    // had once been hosted in a pane. Every restore after a benchd restart resumed it in that pane
    // too: benchd knew holders only by its own sessions and the hooks it had heard since it
    // started, and an idle claude elsewhere had said nothing yet. Claude's registry knows.
    let home = TestHome::claim("m5b-outside");
    let ws = workspace(&home.dir).display().to_string();
    let (pane, runtime) = {
        let daemon = DaemonGuard::start_with_script(&home.dir, "claude", ARGV_CLAUDE);
        ok_data(layout(
            &daemon.socket,
            "workspace/open",
            serde_json::json!({ "path": ws }),
            operator(),
            false,
        ));
        let spawned = json_of(&bench(
            &home.dir,
            &["spawn", "--agent", "claude", "--cwd", &ws],
        ));
        (
            spawned["pane"].as_str().unwrap().to_string(),
            spawned["runtime_session"].as_str().unwrap().to_string(),
        )
    };
    fake_transcript(&home.dir, &runtime);
    let outside = Detached::start();
    claude_holds(&home.dir, outside.0.id(), &runtime);
    let _daemon = DaemonGuard::start_with_script(&home.dir, "claude", ARGV_CLAUDE);

    let restored = json_of(&bench(&home.dir, &["restore", "--all"]));
    let row = restored["restored"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["pane"] == pane.as_str())
        .cloned()
        .unwrap_or_else(|| panic!("{restored}"));
    assert_eq!(row["how"], "shell", "{restored}");
    assert!(
        row["note"]
            .as_str()
            .is_some_and(|n| n.contains("already live")),
        "the answer says why it was not resumed: {restored}"
    );
    let holder = format!("already live in process {}", outside.0.id());
    let screen = screen_until(&home.dir, &pane, |l| l.contains(&holder));
    assert!(
        screen["lines"]
            .as_array()
            .unwrap()
            .iter()
            .any(|l| l.as_str().unwrap().contains(&holder)),
        "the pane says so too, naming the holder: {screen}"
    );
}

#[test]
fn spawn_resume_refuses_a_claude_conversation_a_process_outside_benchd_holds() {
    // `bench spawn --resume` (what the Sessions drawer sends) refuses it as restore does, and
    // takes it once the holder is gone.
    let home = TestHome::claim("outside-resume");
    let h = &home.dir;
    let ws = workspace(h).display().to_string();
    let _daemon = DaemonGuard::start_with_script(h, "claude", ARGV_CLAUDE);
    let spawned = json_of(&bench(h, &["spawn", "--agent", "claude", "--cwd", &ws]));
    let runtime = spawned["runtime_session"].as_str().unwrap().to_string();
    let pid = spawned["pid"].as_i64().unwrap() as i32;
    libc_kill(pid);
    wait_until("the session exits", Duration::from_secs(5), || {
        !libc_alive(pid)
    });
    let outside = Detached::start();
    claude_holds(h, outside.0.id(), &runtime);
    let resume = || {
        bench(
            h,
            &[
                "spawn", "--agent", "claude", "--cwd", &ws, "--resume", &runtime,
            ],
        )
    };

    let refused = resume();
    assert_eq!(refused.code, 3, "{}", refused.stderr);
    assert!(
        refused.stderr.contains("already live"),
        "{}",
        refused.stderr
    );

    // A live process's row that cannot be read could be the holder: refused, and saying why.
    let row = h.join(format!(".claude/sessions/{}.json", outside.0.id()));
    fs::write(&row, "{\"pid\":").unwrap();
    let refused = resume();
    assert_eq!(refused.code, 3, "{}", refused.stderr);
    assert!(refused.stderr.contains("cannot tell"), "{}", refused.stderr);

    // The row outlives its process: a stale row holds nothing, read or not.
    drop(outside);
    let resumed = resume();
    assert_eq!(resumed.code, 0, "{}", resumed.stderr);
}

#[test]
fn an_exited_sessions_attach_refusal_names_a_resume_that_works() {
    // `bench resume` is retired: attaching to an exited session prints the `spawn --resume` that
    // replaces it, and running exactly that brings the conversation back.
    let home = TestHome::claim("exited-hint");
    let h = &home.dir;
    let ws = h.join("a dir with 'quotes'");
    fs::create_dir_all(&ws).unwrap();
    let ws = ws.display().to_string();
    let _daemon = DaemonGuard::start_with_script(h, "claude", ARGV_CLAUDE);
    let spawned = json_of(&bench(h, &["spawn", "--agent", "claude", "--cwd", &ws]));
    let sid = spawned["session"].as_str().unwrap().to_string();
    let pid = spawned["pid"].as_i64().unwrap() as i32;
    libc_kill(pid);
    wait_until("the session exits", Duration::from_secs(5), || {
        session_row(h, &sid)["live"] == false
    });

    let attach = bench(h, &["attach", &sid]);
    assert_eq!(attach.code, 3, "{}", attach.stderr);
    let command = attach
        .stderr
        .split('`')
        .nth(1)
        .unwrap_or_else(|| panic!("names a command: {}", attach.stderr));
    // The shell splits it as an operator pasting it would.
    let words = isolated("sh")
        .arg("-c")
        .arg(format!(
            "for w in {command}; do printf '%s\\0' \"$w\"; done"
        ))
        .output()
        .unwrap();
    let words: Vec<String> = String::from_utf8(words.stdout)
        .unwrap()
        .split('\0')
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect();
    assert_eq!(words[0], "bench", "{words:?}");
    let args: Vec<&str> = words[1..].iter().map(String::as_str).collect();
    let resumed = bench(h, &args);
    assert_eq!(resumed.code, 0, "`{command}`: {}", resumed.stderr);
    assert_eq!(
        json_of(&resumed)["runtime_session"],
        spawned["runtime_session"],
        "the same conversation"
    );
}

/// The agent recorded in a pane, from the document.
fn pane_agent(home: &Path, pane: &str) -> serde_json::Value {
    json_of(&bench(home, &["get", "pane", pane]))["pane"]["surface"]["agent"].clone()
}

#[test]
fn an_agent_started_in_a_shell_pane_is_recorded_there_until_it_ends() {
    // What `bench restore` resumes after a restart is benchd's record, fed by every harness's
    // own hook: here a claude the operator started himself in a shell pane.
    let home = TestHome::claim("m5b-record");
    let ws = workspace(&home.dir).display().to_string();
    let daemon = DaemonGuard::start(&home.dir, None);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    let pane = json_of(&bench(&home.dir, &["open", "terminal"]))["pane"]
        .as_str()
        .unwrap()
        .to_string();
    let (_, pid) = terminal_process(&home.dir, "holder");
    let event = |event: &str| {
        hook_verb(
            &daemon.socket,
            serde_json::json!({"harness": "claude", "event": event, "session": "c-4b1c",
                "cwd": "/tmp/work", "pid": pid, "pane": pane}),
        )
    };

    event("SessionStart");
    assert_eq!(
        pane_agent(&home.dir, &pane),
        serde_json::json!({"command": "claude", "session": "c-4b1c", "cwd": "/tmp/work"})
    );
    event("SessionEnd");
    assert!(
        pane_agent(&home.dir, &pane).is_null(),
        "an agent that ended is not resumed there"
    );
}

/// The events of `kind` about conversation `session`.
fn events_about(home: &Path, kind: &str, session: &str) -> Vec<serde_json::Value> {
    event_kinds(home)
        .into_iter()
        .filter(|(k, data)| {
            k == kind && (data["session"] == session || data["session"]["id"] == session)
        })
        .map(|(_, data)| data)
        .collect()
}

#[test]
fn an_agent_started_by_a_benchd_session_s_agent_does_not_take_its_pane() {
    // #644: the operator's orchestrator ran a test suite whose agents inherited its
    // BENCH_SESSION and reported through `bench hook`. Each was given the orchestrator's handle
    // and its pane's record, and each one's end cleared it, so a restart restored a shell there.
    let home = TestHome::claim("guest-bench");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let spawned = json_of(&bench(
        h,
        &[
            "spawn",
            "--agent",
            "test-echo",
            "--cwd",
            "/tmp",
            "--name",
            "orch",
        ],
    ));
    let session = spawned["session"].as_str().unwrap().to_string();
    let pane = spawned["pane"].as_str().unwrap().to_string();
    let holder = spawned["pid"].as_u64().unwrap() as u32;
    let child = Detached::start();
    let event = |event: &str, conversation: &str, pid: u32| {
        hook_verb(
            &daemon.socket,
            serde_json::json!({"harness": "claude", "event": event, "session": conversation,
                "cwd": "/tmp/work", "pid": pid, "bench_session": session}),
        )
    };

    assert_eq!(event("SessionStart", "c-holder", holder)["handle"], "orch");
    let held = serde_json::json!({"command": "claude", "session": "c-holder", "cwd": "/tmp/work"});
    assert_eq!(pane_agent(h, &pane), held);

    // A test agent the holder started: same BENCH_SESSION, its own process and conversation.
    for e in ["SessionStart", "UserPromptSubmit", "Stop"] {
        assert_eq!(
            event(e, "c-test", child.0.id()),
            serde_json::json!({}),
            "{e}: a guest gets no mailbox"
        );
        assert_eq!(pane_agent(h, &pane), held, "{e} left the pane's agent");
    }
    event("SessionEnd", "c-test", child.0.id());
    assert_eq!(pane_agent(h, &pane), held, "its end did not clear the pane");
    let record = hosted_record(&h.join(".bench"));
    assert!(
        record["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .all(|s| s["id"] != "c-test"),
        "the guest is not recorded under the holder's handle: {record}"
    );
    for kind in ["mail/claimed", "agent/state", "agent/done"] {
        assert!(
            events_about(h, kind, "c-test").is_empty(),
            "no {kind} for a guest"
        );
    }
    let guests = events_about(h, "agent/guest", "c-test");
    assert_eq!(guests.len(), 1, "logged once: {guests:?}");
    assert_eq!(guests[0]["holder"]["session"], "c-holder");
    assert_eq!(guests[0]["holder"]["handle"], "orch");

    // A conversation with a mailbox of its own, resumed by a child of the holder: it keeps its
    // handle, and the holder keeps its pane.
    let (worker_session, worker) = terminal_process(h, "worker");
    hook_verb(
        &daemon.socket,
        serde_json::json!({"harness": "claude", "event": "SessionStart", "session": "c-worker",
            "cwd": "/tmp/work", "pid": worker, "bench_session": worker_session}),
    );
    assert_eq!(
        event("SessionStart", "c-worker", child.0.id())["handle"],
        "worker"
    );
    event("Stop", "c-worker", child.0.id());
    assert_eq!(
        pane_agent(h, &pane),
        held,
        "a resumed conversation left the pane"
    );

    // The holder's own process with a new conversation (`/clear`) is still the holder.
    assert_eq!(event("SessionStart", "c-cleared", holder)["handle"], "orch");
    assert_eq!(pane_agent(h, &pane)["session"], "c-cleared");
}

#[test]
fn a_shell_pane_s_agent_keeps_the_pane_while_it_lives_and_the_next_one_claims_it_after() {
    // The same rule in a pane the operator started an agent in: a child on a terminal of its own
    // passes the tty rule, so only the holder's live process keeps the pane.
    let home = TestHome::claim("guest-pane");
    let h = &home.dir;
    let ws = workspace(h).display().to_string();
    let daemon = DaemonGuard::start(h, None);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    let pane = json_of(&bench(h, &["open", "terminal"]))["pane"]
        .as_str()
        .unwrap()
        .to_string();
    let (holder_session, holder) = terminal_process(h, "holder");
    let (_, child) = terminal_process(h, "child");
    let event = |event: &str, conversation: &str, pid: u32| {
        hook_verb(
            &daemon.socket,
            serde_json::json!({"harness": "claude", "event": event, "session": conversation,
                "cwd": "/tmp/work", "pid": pid, "pane": pane}),
        )
    };
    let who = || json_of(&bench(h, &["mail", "who", "--pane", &pane]))["session"].clone();

    // An earlier conversation ran here and ended: the record remembers this pane for it.
    let earlier = event("SessionStart", "c-earlier", child)["handle"].clone();
    assert!(earlier.is_string());
    event("SessionEnd", "c-earlier", child);

    event("SessionStart", "c-holder", holder);
    assert_eq!(pane_agent(h, &pane)["session"], "c-holder");
    assert_eq!(
        event("SessionStart", "c-test", child),
        serde_json::json!({})
    );
    event("SessionEnd", "c-test", child);
    assert_eq!(pane_agent(h, &pane)["session"], "c-holder");
    assert_eq!(who(), "c-holder");

    // The holder resumes that earlier conversation from a tool call (`claude -p --resume`): no
    // terminal, and a pane remembered for it. It keeps its handle and leaves the pane alone.
    let detached = Detached::start();
    for e in ["SessionStart", "Stop"] {
        assert_eq!(event(e, "c-earlier", detached.0.id())["handle"], earlier);
        assert_eq!(pane_agent(h, &pane)["session"], "c-holder", "{e}");
        assert_eq!(who(), "c-holder", "{e}");
    }
    event("PreToolUse", "c-holder", holder);
    assert!(
        events_about(h, "agent/guest", "c-holder").is_empty(),
        "the holder is still the holder"
    );
    event("SessionEnd", "c-earlier", detached.0.id());
    assert_eq!(pane_agent(h, &pane)["session"], "c-holder");

    // The holder quits; the next agent started there claims the pane as before.
    libc_kill(holder as i32);
    wait_until("the holder exits", Duration::from_secs(5), || {
        session_row(h, &holder_session)["live"] == false
    });
    assert!(event("SessionStart", "c-next", child)["handle"].is_string());
    assert_eq!(pane_agent(h, &pane)["session"], "c-next");
    assert_eq!(who(), "c-next");
}

#[test]
fn stopping_benchd_keeps_the_records_its_ending_agents_report_on_their_way_out() {
    // `bench stop` hangs up every session, and a claude reports `SessionEnd` as it goes. That end
    // is benchd's own doing: the record must survive it, or `just resume-all` finds nothing.
    let home = TestHome::claim("m5b-stopkeeps");
    let ws = workspace(&home.dir).display().to_string();
    let bin = home.dir.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let claude = bin.join("claude");
    fs::write(
        &claude,
        format!(
            "#!/bin/sh\nsid=\nwhile [ $# -gt 0 ]; do [ \"$1\" = --session-id ] && sid=$2; shift; done\n\
             end() {{ printf '{{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"%s\",\"cwd\":\"%s\"}}' \"$sid\" \"$PWD\" | {bench} hook claude >/dev/null; exit 0; }}\n\
             trap end HUP\n\
             printf '{{\"hook_event_name\":\"SessionStart\",\"session_id\":\"%s\",\"cwd\":\"%s\"}}' \"$sid\" \"$PWD\" | {bench} hook claude >/dev/null\n\
             echo ready\nwhile :; do sleep 0.02; done\n",
            bench = bench_bin().display()
        ),
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&claude, fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::var("PATH").unwrap_or_default();
    let pane = {
        let mut cmd = isolated(benchd_bin());
        cmd.env("PATH", format!("{}:{path}", bin.display()));
        let _daemon = DaemonGuard::start_with(&home.dir, None, cmd);
        let spawned = json_of(&bench(
            &home.dir,
            &["spawn", "--agent", "claude", "--cwd", &ws],
        ));
        let pane = spawned["pane"].as_str().unwrap().to_string();
        // It reports SessionStart after setting its trap, so once benchd has logged that, the
        // stop reaches a claude that reports its end. Waiting on the event rather than for a
        // fixed time: an 800 ms window the stub had to report inside failed on a loaded machine.
        // (The pane's record is no signal: benchd writes it at spawn.)
        let events = home.dir.join(".bench/events.jsonl");
        wait_until(
            "the fake claude's SessionStart",
            Duration::from_secs(20),
            || {
                fs::read_to_string(&events)
                    .is_ok_and(|log| log.contains(r#""event":"SessionStart""#))
            },
        );
        let stop = bench(&home.dir, &["stop"]);
        assert_eq!(stop.code, 0, "{}", stop.stderr);
        let deadline = Instant::now() + Duration::from_secs(10);
        while home.dir.join(".bench/benchd.sock").exists() {
            assert!(Instant::now() < deadline, "benchd did not stop");
            std::thread::sleep(Duration::from_millis(100));
        }
        pane
    };
    let log = fs::read_to_string(home.dir.join(".bench/events.jsonl")).unwrap();
    assert!(
        log.contains("agent/ended"),
        "the fake claude reported its end during the stop, so this test sees the case: {log}"
    );
    let mut cmd = isolated(benchd_bin());
    cmd.env("PATH", format!("{}:{path}", bin.display()));
    let _daemon = DaemonGuard::start_with(&home.dir, None, cmd);
    let recorded = pane_agent(&home.dir, &pane);
    assert_eq!(
        recorded["command"], "claude",
        "the record survived the stop"
    );

    // Nobody said anything to that claude, so it wrote no transcript, and `claude --resume` of
    // it would exit at once: the pane gets a shell, and the answer says why.
    let restored = json_of(&bench(&home.dir, &["restore", &pane]));
    let row = &restored["restored"][0];
    assert_eq!(row["how"], "shell", "{restored}");
    assert!(
        row["note"]
            .as_str()
            .is_some_and(|n| n.contains("never written in")),
        "{restored}"
    );
}

#[test]
fn typing_a_program_never_reads_never_holds_up_a_verb_on_another_session() {
    // Typing into a terminal whose program does not read waits for as long as it does not: the
    // pty's input queue is full. An agent's close of that pane asks the shell what it runs, and
    // if that question waited on the typing under benchd's core lock, every verb for every pane
    // would wait with it, for good (#517). Closes and reads of another session run back to back
    // here, so they overlap the blocked typing whenever it starts.
    let home = TestHome::claim("m5b-typing");
    let ws = workspace(&home.dir).display().to_string();
    let daemon = DaemonGuard::start(&home.dir, None);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    let mut panes = Vec::new();
    for _ in 0..2 {
        let run = bench(&home.dir, &["open", "terminal"]);
        assert_eq!(run.code, 0, "{}", run.stderr);
        panes.push(json_of(&run)["pane"].as_str().unwrap().to_string());
    }
    let (busy, other) = (panes[0].clone(), panes[1].clone());
    let sid = pane_session(&home.dir, &busy).unwrap();
    let pid = session_row(&home.dir, &sid)["pid"].as_i64().unwrap();
    let (resp, stream) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": sid}),
    );
    assert_eq!(resp["status"], "ok");
    (&stream)
        .write_all(&AttachFrame::Input(b"sleep 600\n".to_vec()).encode())
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while session_row(&home.dir, &sid)["foreground_pid"].as_i64() == Some(pid) {
        assert!(Instant::now() < deadline, "sleep never took the terminal");
        std::thread::sleep(Duration::from_millis(100));
    }
    drop(stream);
    // Lines `sleep` never reads: the first fills the terminal's line, the rest wait behind it.
    let typing = {
        let (home, busy) = (home.dir.clone(), busy.clone());
        let text = "a line nobody reads\n".repeat(2000);
        std::thread::spawn(move || bench(&home, &["send", &busy, &text]))
    };
    // Every thread here stops at this deadline on its own, whatever the assertions do.
    let deadline = Instant::now() + Duration::from_secs(3);
    let closes = {
        let (home, busy) = (home.dir.clone(), busy.clone());
        std::thread::spawn(move || {
            let mut refusals = Vec::new();
            while Instant::now() < deadline {
                refusals.push(bench(&home, &["close", &busy]));
            }
            refusals
        })
    };
    let mut reads = Vec::new();
    while Instant::now() < deadline {
        let started = Instant::now();
        let screen = bench(&home.dir, &["get", "screen", &other]);
        reads.push((screen.code, screen.stderr, started.elapsed()));
    }
    for (code, stderr, waited) in reads {
        assert_eq!(code, 0, "reading another session: {stderr}");
        // Held up, a read waits until its client gives up: seconds past the write limit.
        assert!(
            waited < bench_wire::DAEMON_IO_TIMEOUT,
            "reading another session waited {waited:?} behind the blocked typing"
        );
    }
    // Checked after the reads: a read held up behind it would outlast the typing's own timeout.
    assert!(
        !typing.is_finished(),
        "the typing was not blocked, so this measured nothing"
    );
    for refused in closes.join().unwrap() {
        assert_eq!(refused.code, 3, "{}", refused.stderr);
        assert!(
            refused.stderr.contains("running sleep"),
            "{}",
            refused.stderr
        );
    }
    let forced = bench(&home.dir, &["close", &busy, "--force"]);
    assert_eq!(forced.code, 0, "{}", forced.stderr);
    let _ = typing.join();
}

#[test]
fn a_shell_comes_back_in_the_directory_it_was_last_working_in() {
    let home = TestHome::claim("m5b-cwd");
    let ws = workspace(&home.dir).display().to_string();
    let elsewhere = home.dir.join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    let elsewhere = elsewhere.canonicalize().unwrap().display().to_string();
    let pane = {
        let daemon = DaemonGuard::start(&home.dir, None);
        ok_data(layout(
            &daemon.socket,
            "workspace/open",
            serde_json::json!({ "path": ws }),
            operator(),
            false,
        ));
        let pane = json_of(&bench(&home.dir, &["open", "terminal"]))["pane"]
            .as_str()
            .unwrap()
            .to_string();
        let sid = pane_session(&home.dir, &pane).unwrap();
        type_into(
            &daemon.socket,
            &sid,
            &format!("cd '{elsewhere}' && echo MOVED\n"),
            |seen| seen.contains("MOVED\r"),
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let doc = json_of(&bench(&home.dir, &["get", "pane", &pane]));
            if doc["pane"]["surface"]["cwd"] == elsewhere.as_str() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "the cwd was never recorded: {doc}"
            );
            std::thread::sleep(Duration::from_millis(200));
        }
        pane
    };
    let _daemon = DaemonGuard::start(&home.dir, None);
    let run = bench(&home.dir, &["restore", &pane]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let sid = pane_session(&home.dir, &pane).unwrap();
    assert_eq!(session_row(&home.dir, &sid)["cwd"], elsewhere.as_str());
}

/// `<home>/bin/codex`, benchd's codex in these tests (#466). Asked `hooks/list` on stdio
/// (benchd's probe as its app-server starts, not recorded) it answers [`FAKE_CODEX_HOOKS`].
/// Otherwise it appends its argv to `<home>/codex-runs`, one line each. As the app-server
/// (`app-server … --listen unix://P`) it writes its pid and environment beside it, links `P` to
/// the test's [`FakeCodex`], as real codex links it to a short socket of its own, and lives until
/// benchd's leash TERMs it. As a TUI it echoes its pty, like `cat`.
fn write_fake_codex(home: &Path) -> (PathBuf, PathBuf) {
    let runs = home.join("codex-runs");
    let bin = write_agent_script(
        home,
        "codex",
        &format!(
            "if [ \"$*\" = app-server ]; then\n\
             while IFS= read -r line; do case \"$line\" in *'\"hooks/list\"'*) \
             printf '{{\"id\":2,\"result\":%s}}\\n' '{hooks}' ;; esac; done; exit 0; fi\n\
             printf '%s\\n' \"$*\" >> {runs}\n\
             if [ \"$1\" = app-server ]; then\n\
             echo $$ > {home}/codex-server.pid\n\
             env > {home}/codex-server.env\n\
             for a; do case \"$a\" in unix://*) l=\"${{a#unix://}}\" ;; esac; done\n\
             ln -sf {fake} \"$l\"\n\
             exec sleep 120\n\
             fi\n\
             exec cat",
            hooks = FAKE_CODEX_HOOKS,
            runs = runs.display(),
            home = home.display(),
            fake = home.join("fcx.sock").display(),
        ),
    );
    (bin, runs)
}

/// The fake codex's `hooks/list`: one hook to review, one already trusted.
const FAKE_CODEX_HOOKS: &str = r#"{"data":[{"hooks":[{"key":"/h/hooks.json:stop:0:0","currentHash":"sha256:new","trustStatus":"untrusted"},{"key":"/h/hooks.json:session_start:0:0","currentHash":"sha256:old","trustStatus":"trusted"}]}]}"#;

/// The invocations a recording stand-in saw (one argv line each), once `n` of them have run.
fn recorded_runs(runs: &Path, n: usize) -> Vec<String> {
    let lines = || {
        fs::read_to_string(runs)
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect::<Vec<_>>()
    };
    wait_until("agent runs", Duration::from_secs(5), || lines().len() >= n);
    lines()
}

/// A codex re-entered by benchd (#466): the thread resumed on its app-server in the posture
/// `sandbox` with session `session`'s own environment, then its first message, the resume
/// notice, as a turn, then a TUI attached to it.
fn assert_codex_resumed(
    home: &Path,
    fake: &FakeCodex,
    runs: &Path,
    session: &str,
    thread: &str,
    sandbox: &str,
) {
    let resume = fake
        .asked("thread/resume", 1)
        .into_iter()
        .rev()
        .find(|r| {
            r["threadId"] == thread
                && r["config"]["shell_environment_policy"]["set"]["BENCH_SESSION"] == session
        })
        .unwrap_or_else(|| {
            panic!(
                "{session} re-enters {thread}: {:?}",
                fake.asked_now("thread/resume")
            )
        });
    assert_eq!(resume["sandbox"], sandbox);
    assert_eq!(resume["config"]["bypass_hook_trust"], true);
    let turn = fake
        .asked("turn/start", 1)
        .into_iter()
        .rev()
        .find(|t| t["threadId"] == thread)
        .unwrap();
    let text = turn["input"][0]["text"].as_str().unwrap();
    let path = text
        .strip_prefix("Read and act on the prompt in ")
        .unwrap_or_else(|| panic!("a pointer: {text}"));
    let notice = fs::read_to_string(path).unwrap();
    assert!(
        notice.starts_with("benchd resumed this conversation"),
        "a resume's first message is the notice: {notice:?}"
    );
    let socket = home.join(".bench/codex.sock");
    let tui = format!("resume {thread} --remote unix://{}", socket.display());
    wait_until("the TUI attaches", Duration::from_secs(5), || {
        fs::read_to_string(runs)
            .unwrap_or_default()
            .lines()
            .any(|r| r.starts_with(&tui))
    });
}

/// The text of the prompt file an agent's argv line (its args joined by spaces) points at last.
fn pointed_prompt(line: &str) -> (String, String) {
    let marker = "Read and act on the prompt in ";
    let at = line
        .rfind(marker)
        .unwrap_or_else(|| panic!("no prompt pointer in {line:?}"));
    let path = line[at + marker.len()..].to_string();
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    (path, text)
}

/// A resumed agent's argv ends pointing at benchd's resume notice, and only at that.
fn assert_resume_notice(line: &str) -> String {
    let (path, text) = pointed_prompt(line);
    assert!(
        text.starts_with("benchd resumed this conversation")
            && text.contains("Continue where you were"),
        "a resume's first message is the notice: {text:?}"
    );
    path
}

#[test]
fn a_codex_its_hook_recorded_in_a_pane_is_restored_on_benchds_app_server_with_its_model() {
    // A codex the operator started in a pane comes back after a restart as a thread on benchd's
    // app-server: re-entered with the model its record says it ran (restore knows only the
    // conversation), wakeable by mail (harness parity G2).
    let home = TestHome::claim("m5b-codex");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let ws = ws.display().to_string();
    let fake = FakeCodex::bind(h);
    let (bin, runs) = write_fake_codex(h);
    let pane = {
        let daemon = codex_daemon(h, &bin);
        ok_data(layout(
            &daemon.socket,
            "workspace/open",
            serde_json::json!({ "path": ws }),
            operator(),
            false,
        ));
        let pane = json_of(&bench(h, &["open", "terminal"]))["pane"]
            .as_str()
            .unwrap()
            .to_string();
        let (_, pid) = terminal_process(h, "holder");
        hook_verb(
            &daemon.socket,
            serde_json::json!({"harness": "codex", "event": "SessionStart", "session": "019a-thread",
                "cwd": ws, "pid": pid, "pane": pane}),
        );
        pane
    };
    let _daemon = codex_daemon(h, &bin);
    let run = json_of(&bench(h, &["restore", &pane]));
    assert_eq!(run["restored"][0]["how"], "resumed", "{run}");
    let session = run["restored"][0]["session"].as_str().unwrap();
    assert_codex_resumed(
        h,
        &fake,
        &runs,
        session,
        "019a-thread",
        "danger-full-access",
    );
    assert_eq!(fake.asked("thread/read", 1)[0]["threadId"], "019a-thread");
    let resume = &fake.asked_now("thread/resume")[0];
    assert_eq!(resume["model"], "gpt-recorded");
    assert_eq!(resume["config"]["model_reasoning_effort"], "low");

    // Busy with its notice; mail waits until codex says the thread stopped.
    let handle = json_of(&bench(h, &["sessions"]))["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["session"] == session)
        .map(|s| s["handle"].as_str().unwrap().to_string())
        .unwrap();
    let sent = json_of(&bench(
        h,
        &["mail", "send", "--to", &handle, "--body", "wake up"],
    ));
    assert_eq!(sent["wake"], "queued", "{sent}");
    std::thread::sleep(Duration::from_secs(2));
    assert_eq!(
        fake.asked_now("turn/start").len(),
        1,
        "only the notice so far"
    );
    fake.notify(serde_json::json!({"method": "thread/status/changed",
        "params": {"threadId": "019a-thread", "status": {"type": "idle"}}}));
    assert_eq!(fake.asked("turn/start", 2)[1]["threadId"], "019a-thread");
}

#[test]
fn a_codex_thread_a_live_session_holds_is_not_resumed_a_second_time() {
    let home = TestHome::claim("cxheld");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let _fake = FakeCodex::bind(h);
    let (bin, _) = write_fake_codex(h);
    let _daemon = codex_daemon(h, &bin);
    let spawned = spawn_codex(h, &ws, &[]);
    let thread = spawned["runtime_session"].as_str().unwrap();
    let ws = ws.display().to_string();
    let again = bench(
        h,
        &[
            "spawn", "--agent", "codex", "--cwd", &ws, "--resume", thread,
        ],
    );
    assert_eq!(again.code, 3, "{}", again.stderr);
    assert!(again.stderr.contains("already live"), "{}", again.stderr);
}

#[test]
fn a_codex_the_operator_started_in_a_pane_is_not_resumed_a_second_time() {
    let home = TestHome::claim("cxpane");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let ws = ws.display().to_string();
    let _fake = FakeCodex::bind(h);
    let (bin, _) = write_fake_codex(h);
    let daemon = codex_daemon(h, &bin);
    // His codex in a shell pane: its hook declares the pane, never a benchd session.
    let (_, pid) = terminal_process(h, "his-codex");
    let thread = "019a0dde-1128-7572-8528-e0979f7e7072";
    let reply = hook_verb(
        &daemon.socket,
        serde_json::json!({"harness": "codex", "event": "SessionStart", "session": thread,
            "cwd": ws, "pid": pid, "pane": HOOK_PANE}),
    );
    assert!(reply["handle"].is_string(), "it claimed a mailbox: {reply}");
    let again = bench(
        h,
        &[
            "spawn", "--agent", "codex", "--cwd", &ws, "--resume", thread,
        ],
    );
    assert_eq!(again.code, 3, "{}", again.stderr);
    assert!(again.stderr.contains("already live"), "{}", again.stderr);
}

#[test]
fn a_codex_conversation_is_resumed_by_spawn_and_again_by_resume_in_each_sessions_own_name() {
    // codex takes `resume <id>` as claude and pi take theirs (harness parity G10). Each resume
    // re-enters the thread on benchd's app-server with the new session's own environment, after
    // benchd lets go of it, so codex restarts it with that environment rather than keep the
    // exited session's.
    let home = TestHome::claim("cxresume");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let fake = FakeCodex::bind(h);
    let (bin, runs) = write_fake_codex(h);
    let _daemon = codex_daemon(h, &bin);
    let thread = "019a0dde-1128-7572-8528-e0979f7e706f";
    let spawned = spawn_codex(h, &ws, &["--resume", thread, "--model", "gpt-asked"]);
    let first = spawned["session"].as_str().unwrap().to_string();
    assert_codex_resumed(h, &fake, &runs, &first, thread, "danger-full-access");
    assert_eq!(fake.asked_now("thread/resume")[0]["model"], "gpt-asked");
    assert!(
        fake.asked_now("thread/read").is_empty(),
        "a model asked for is not looked up"
    );

    let again = bench(
        h,
        &[
            "spawn",
            "--agent",
            "codex",
            "--cwd",
            &ws.display().to_string(),
            "--resume",
            thread,
        ],
    );
    assert_eq!(again.code, 3, "{}", again.stderr);
    assert!(again.stderr.contains("already live"), "{}", again.stderr);

    let pid = spawned["pid"].as_i64().unwrap() as i32;
    libc_kill(pid);
    wait_until("the session exits", Duration::from_secs(5), || {
        !libc_alive(pid)
    });
    let resumed = codex_resume_once_free(h, &ws, thread);
    let second = resumed["session"].as_str().unwrap().to_string();
    assert_ne!(second, first);
    assert_eq!(
        fake.asked("thread/unsubscribe", 1)[0]["threadId"],
        thread,
        "benchd let go of it first"
    );
    assert_codex_resumed(h, &fake, &runs, &second, thread, "danger-full-access");
    // The second session is woken by mail through the same server.
    fake.notify(serde_json::json!({"method": "thread/status/changed",
        "params": {"threadId": thread, "status": {"type": "idle"}}}));
    let sent = json_of(&bench(
        h,
        &["mail", "send", "--to", &second, "--body", "wake up"],
    ));
    assert_eq!(sent["wake"], "queued", "{sent}");
    wait_until(
        "a turn is started on its thread",
        Duration::from_secs(10),
        || fake.asked_now("turn/start").len() >= 3,
    );
}

#[test]
fn a_codex_spawned_new_is_resumed_by_the_thread_its_spawn_named() {
    // Its thread is known from spawn (#466), so a resume has an id to re-enter; before, codex
    // named it only after the fact.
    let home = TestHome::claim("cxresnew");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let fake = FakeCodex::bind(h);
    let (bin, runs) = write_fake_codex(h);
    let _daemon = codex_daemon(h, &bin);
    let spawned = spawn_codex(h, &ws, &[]);
    let (first, thread) = (
        spawned["session"].as_str().unwrap().to_string(),
        spawned["runtime_session"].as_str().unwrap().to_string(),
    );
    let pid = spawned["pid"].as_i64().unwrap() as i32;
    libc_kill(pid);
    wait_until("the session exits", Duration::from_secs(5), || {
        !libc_alive(pid)
    });
    let resumed = codex_resume_once_free(h, &ws, &thread);
    let second = resumed["session"].as_str().unwrap().to_string();
    assert_ne!(second, first);
    assert_codex_resumed(h, &fake, &runs, &second, &thread, "danger-full-access");
}

/// `bench spawn --resume <thread>` of a codex whose session was just killed: benchd may still
/// count that session live for a moment, and refuses the resume while it does.
fn codex_resume_once_free(home: &Path, ws: &Path, thread: &str) -> serde_json::Value {
    let ws = ws.display().to_string();
    let args = [
        "spawn", "--agent", "codex", "--cwd", &ws, "--resume", thread,
    ];
    let mut resumed = bench(home, &args);
    let deadline = Instant::now() + Duration::from_secs(5);
    while resumed.stderr.contains("already live") && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
        resumed = bench(home, &args);
    }
    assert_eq!(resumed.code, 0, "stderr: {}", resumed.stderr);
    json_of(&resumed)
}

#[test]
fn a_claude_conversation_with_a_transcript_is_resumed_after_a_restart() {
    // The other half of `restore`'s transcript check: a conversation Claude wrote is resumed.
    let home = TestHome::claim("m5b-claudeback");
    let ws = workspace(&home.dir).display().to_string();
    let pane = {
        let daemon = DaemonGuard::start(&home.dir, None);
        ok_data(layout(
            &daemon.socket,
            "workspace/open",
            serde_json::json!({ "path": ws }),
            operator(),
            false,
        ));
        let pane = json_of(&bench(&home.dir, &["open", "terminal"]))["pane"]
            .as_str()
            .unwrap()
            .to_string();
        let (_, pid) = terminal_process(&home.dir, "holder");
        hook_verb(
            &daemon.socket,
            serde_json::json!({"harness": "claude", "event": "SessionStart", "session": "c-7e2d",
                "cwd": ws, "pid": pid, "pane": pane}),
        );
        pane
    };
    let projects = home.dir.join(".claude/projects/ws");
    fs::create_dir_all(&projects).unwrap();
    fs::write(projects.join("c-7e2d.jsonl"), "{}\n").unwrap();
    let runs = home.dir.join("claude-runs");
    let _daemon = DaemonGuard::start_with_script(
        &home.dir,
        "claude",
        &format!("printf '%s\\n' \"$*\" >> '{}'\nexec cat", runs.display()),
    );
    let restored = json_of(&bench(&home.dir, &["restore", &pane]));
    assert_eq!(restored["restored"][0]["how"], "resumed", "{restored}");
    wait_until("claude ran", Duration::from_secs(5), || runs.exists());
    let run = fs::read_to_string(&runs).unwrap();
    assert!(run.contains("--resume c-7e2d"), "{run}");
    assert_resume_notice(run.trim_end());
}

/// A pi stand-in that records each run's argv in `<home>/pi-runs`, and that file.
fn recording_pi(home: &Path) -> (String, PathBuf) {
    let runs = home.join("pi-runs");
    let record = format!("printf '%s\\n' \"$*\" >> '{}'\nexec cat", runs.display());
    (record, runs)
}

#[test]
fn restore_sends_a_fresh_notice_and_never_the_spawn_prompt() {
    // A resumed agent whose last turn was cut off sits at its prompt until something starts a
    // turn, so benchd's resume routes start one with the notice (`spawn --resume`'s is
    // `spawn_resume_sends_the_notice_unless_the_caller_sent_a_prompt`).
    let home = TestHome::claim("resume-notice");
    let ws = workspace(&home.dir).display().to_string();
    let (record, runs) = recording_pi(&home.dir);
    let (agent_pane, shell_pane, task) = {
        let daemon = DaemonGuard::start_with_script(&home.dir, "pi", &record);
        ok_data(layout(
            &daemon.socket,
            "workspace/open",
            serde_json::json!({ "path": ws }),
            operator(),
            false,
        ));
        let brief = home.dir.join("task.md");
        fs::write(&brief, "TASK-ALPHA").unwrap();
        let brief = brief.display().to_string();
        let spawned = bench(
            &home.dir,
            &[
                "spawn",
                "--agent",
                "pi",
                "--cwd",
                &ws,
                "--prompt-file",
                &brief,
            ],
        );
        assert_eq!(spawned.code, 0, "{}", spawned.stderr);
        let spawned = json_of(&spawned);
        let (task, text) = pointed_prompt(&recorded_runs(&runs, 1)[0]);
        assert_eq!(text, "TASK-ALPHA", "a new conversation gets its own prompt");

        let shell = json_of(&bench(&home.dir, &["open", "terminal"]));
        (
            spawned["pane"].as_str().unwrap().to_string(),
            shell["pane"].as_str().unwrap().to_string(),
            task,
        )
    };

    // A restart, then `restore --all`: the agent pane's resume gets a notice written for it,
    // and the shell pane starts no agent at all.
    let _daemon = DaemonGuard::start_with_script(&home.dir, "pi", &record);
    let restored = json_of(&bench(&home.dir, &["restore", "--all"]));
    let how = |pane: &str| {
        restored["restored"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["pane"] == pane)
            .map(|r| r["how"].as_str().unwrap().to_string())
    };
    assert_eq!(how(&agent_pane).as_deref(), Some("resumed"), "{restored}");
    assert_eq!(how(&shell_pane).as_deref(), Some("shell"), "{restored}");
    let all = recorded_runs(&runs, 2);
    assert_eq!(all.len(), 2, "{all:?}");
    let notice = assert_resume_notice(&all[1]);
    assert_ne!(notice, task);
}

#[test]
fn spawn_resume_sends_the_notice_unless_the_caller_sent_a_prompt() {
    let home = TestHome::claim("resume-notice-spawn");
    let ws = workspace(&home.dir).display().to_string();
    let (record, runs) = recording_pi(&home.dir);
    let _daemon = DaemonGuard::start_with_script(&home.dir, "pi", &record);
    let bare = bench(
        &home.dir,
        &[
            "spawn", "--agent", "pi", "--cwd", &ws, "--resume", "p-other",
        ],
    );
    assert_eq!(bare.code, 0, "{}", bare.stderr);
    let line = &recorded_runs(&runs, 1)[0];
    assert!(line.contains("--session-id p-other "), "{line}");
    assert_resume_notice(line);

    // A caller's own message replaces the notice: `just release-resume` sends its own.
    let mine = home.dir.join("mine.md");
    fs::write(&mine, "CALLER-NOTE").unwrap();
    let mine = mine.display().to_string();
    let with_prompt = bench(
        &home.dir,
        &[
            "spawn",
            "--agent",
            "pi",
            "--cwd",
            &ws,
            "--resume",
            "p-third",
            "--prompt-file",
            &mine,
        ],
    );
    assert_eq!(with_prompt.code, 0, "{}", with_prompt.stderr);
    let (path, text) = pointed_prompt(&recorded_runs(&runs, 2)[1]);
    assert_eq!(
        (path.as_str(), text.as_str()),
        (mine.as_str(), "CALLER-NOTE")
    );
}

/// A repository under `home` that ignores `.worktrees/`, as helm's does, with the worktree
/// `.worktrees/w` on branch `feat/x`, and a Claude transcript of conversation `c-wt` there that
/// names the branch, as Claude Code writes one.
fn claude_in_a_worktree(home: &Path) -> (PathBuf, String) {
    let repo = home.join("repo");
    fs::create_dir_all(&repo).unwrap();
    let repo = repo.canonicalize().unwrap();
    fs::write(repo.join(".gitignore"), "/.worktrees/\n").unwrap();
    git_in(&repo, &["init", "-q", "-b", "main"]);
    git_in(&repo, &["add", ".gitignore"]);
    git_in(
        &repo,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            "x",
        ],
    );
    git_in(
        &repo,
        &["worktree", "add", "-q", "-b", "feat/x", ".worktrees/w"],
    );
    let wt = repo.join(".worktrees/w").display().to_string();
    let mangled: String = wt
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let transcript = home
        .join(".claude/projects")
        .join(mangled)
        .join("c-wt.jsonl");
    fs::create_dir_all(transcript.parent().unwrap()).unwrap();
    let line = serde_json::json!({"type": "user", "cwd": wt, "gitBranch": "feat/x"});
    fs::write(&transcript, format!("{line}\n")).unwrap();
    (repo, wt)
}

/// An agent stand-in that records each run as `<physical cwd> <argv>` in `<home>/runs`.
fn recording_where(home: &Path) -> (String, PathBuf) {
    let runs = home.join("runs");
    let record = format!(
        "printf '%s %s\\n' \"$(pwd -P)\" \"$*\" >> '{}'\nexec cat",
        runs.display()
    );
    (record, runs)
}

/// The note a resume notice carries about where the resume runs, if any.
fn resume_note(line: &str) -> String {
    let (_, text) = pointed_prompt(line);
    text.split_once("This notice is not a new task.\n")
        .map(|(_, note)| note.trim().to_string())
        .unwrap_or_default()
}

#[test]
fn a_resume_whose_worktree_was_removed_recreates_it_on_the_agents_branch() {
    // The merge queue prunes a worktree after its merge; the finished agent stays resumable
    // (#621). Every route that resumes brings the worktree back.
    let home = TestHome::claim("resume-gone-wt");
    let (repo, wt) = claude_in_a_worktree(&home.dir);
    let (record, runs) = recording_where(&home.dir);
    let remove = || git_in(&repo, &["worktree", "remove", "--force", ".worktrees/w"]);
    let on_branch = || {
        let out = isolated("git")
            .args(["-C", &wt, "branch", "--show-current"])
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    };
    let recreated = |line: &str| {
        assert!(
            line.starts_with(&format!("{wt} ")),
            "runs in the worktree: {line}"
        );
        assert_eq!(on_branch(), "feat/x");
        let note = resume_note(line);
        assert!(
            note.contains("recreated") && note.contains("feat/x"),
            "{note:?}"
        );
    };
    {
        let _daemon = DaemonGuard::start_with_script(&home.dir, "claude", &record);
        let spawned = bench(
            &home.dir,
            &[
                "spawn", "--agent", "claude", "--cwd", &wt, "--resume", "c-wt",
            ],
        );
        assert_eq!(spawned.code, 0, "{}", spawned.stderr);
        let first = &recorded_runs(&runs, 1)[0];
        assert!(first.starts_with(&format!("{wt} ")), "{first}");
        assert_eq!(
            resume_note(first),
            "",
            "a folder that is there gets no note"
        );

        // `spawn --resume` again once the session exited, after its worktree went.
        let spawned = json_of(&spawned);
        let sid = spawned["session"].as_str().unwrap().to_string();
        libc_kill(spawned["pid"].as_i64().unwrap() as i32);
        wait_until("the agent's session ends", Duration::from_secs(10), || {
            session_row(&home.dir, &sid)["live"] == false
        });
        remove();
        let resumed = bench(
            &home.dir,
            &[
                "spawn", "--agent", "claude", "--cwd", &wt, "--resume", "c-wt",
            ],
        );
        assert_eq!(resumed.code, 0, "{}", resumed.stderr);
        recreated(&recorded_runs(&runs, 2)[1]);
    }

    // `restore` after a restart, the worktree gone again.
    remove();
    let _daemon = DaemonGuard::start_with_script(&home.dir, "claude", &record);
    let restored = json_of(&bench(&home.dir, &["restore", "--all"]));
    assert_eq!(restored["restored"][0]["how"], "resumed", "{restored}");
    recreated(&recorded_runs(&runs, 3)[2]);
}

#[test]
fn a_refused_resume_never_recreates_its_worktree() {
    // A pane whose worktree was pruned (#621) and whose conversation is live elsewhere (#634):
    // restore refuses the resume, and must not bring back a folder for a resume that never runs.
    let home = TestHome::claim("resume-held-wt");
    let (repo, wt) = claude_in_a_worktree(&home.dir);
    let (record, _runs) = recording_where(&home.dir);
    let pane = {
        let _daemon = DaemonGuard::start_with_script(&home.dir, "claude", &record);
        let spawned = bench(
            &home.dir,
            &[
                "spawn", "--agent", "claude", "--cwd", &wt, "--resume", "c-wt",
            ],
        );
        assert_eq!(spawned.code, 0, "{}", spawned.stderr);
        json_of(&spawned)["pane"].as_str().unwrap().to_string()
    };
    git_in(&repo, &["worktree", "remove", "--force", ".worktrees/w"]);
    let outside = Detached::start();
    claude_holds(&home.dir, outside.0.id(), "c-wt");
    let _daemon = DaemonGuard::start_with_script(&home.dir, "claude", &record);

    let restored = json_of(&bench(&home.dir, &["restore", "--all"]));
    let row = restored["restored"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["pane"] == pane.as_str())
        .cloned()
        .unwrap_or_else(|| panic!("{restored}"));
    assert_eq!(row["how"], "shell", "{restored}");
    assert!(
        row["note"]
            .as_str()
            .is_some_and(|n| n.contains("already live")),
        "{restored}"
    );
    assert!(!Path::new(&wt).exists(), "no worktree came back for it");

    // `spawn --resume` refuses it the same way, before the folder too.
    let spawn = bench(
        &home.dir,
        &[
            "spawn", "--agent", "claude", "--cwd", &wt, "--resume", "c-wt",
        ],
    );
    assert_eq!(spawn.code, 3, "{}", spawn.stderr);
    assert!(!Path::new(&wt).exists(), "no worktree came back for it");
}

#[test]
fn a_claude_never_written_in_gets_no_worktree_back_either() {
    // restore refuses it after `plan`, and only Claude's transcript names the branch a worktree
    // would come back on: no transcript, no branch, no `git worktree add`.
    let home = TestHome::claim("resume-unwritten-wt");
    let (repo, wt) = claude_in_a_worktree(&home.dir);
    let (record, _runs) = recording_where(&home.dir);
    {
        let _daemon = DaemonGuard::start_with_script(&home.dir, "claude", &record);
        let spawned = bench(
            &home.dir,
            &[
                "spawn", "--agent", "claude", "--cwd", &wt, "--resume", "c-wt",
            ],
        );
        assert_eq!(spawned.code, 0, "{}", spawned.stderr);
    }
    fs::remove_dir_all(home.dir.join(".claude/projects")).unwrap();
    git_in(&repo, &["worktree", "remove", "--force", ".worktrees/w"]);
    let _daemon = DaemonGuard::start_with_script(&home.dir, "claude", &record);

    let restored = json_of(&bench(&home.dir, &["restore", "--all"]));
    let note = restored["restored"][0]["note"].as_str().unwrap_or_default();
    assert!(note.contains("never written in"), "{restored}");
    assert!(!Path::new(&wt).exists(), "no worktree came back for it");
}

#[test]
fn with_its_branch_gone_too_claude_resumes_in_the_repo_root_and_pi_is_refused() {
    // claude and codex re-enter a conversation from any folder; pi starts a new, empty one
    // there, so it is refused rather than resumed somewhere it would lose its conversation.
    let home = TestHome::claim("resume-gone-br");
    let (repo, wt) = claude_in_a_worktree(&home.dir);
    git_in(&repo, &["worktree", "remove", ".worktrees/w"]);
    git_in(&repo, &["branch", "-D", "feat/x"]);
    let (record, runs) = recording_where(&home.dir);
    let pi_runs = home.dir.join("pi-runs");
    write_agent_script(
        &home.dir,
        "pi",
        &format!("echo ran >> '{}'\nexec cat", pi_runs.display()),
    );
    let _daemon = DaemonGuard::start_with_script(&home.dir, "claude", &record);

    let claude = bench(
        &home.dir,
        &[
            "spawn", "--agent", "claude", "--cwd", &wt, "--resume", "c-wt",
        ],
    );
    assert_eq!(claude.code, 0, "{}", claude.stderr);
    let line = &recorded_runs(&runs, 1)[0];
    assert!(line.starts_with(&format!("{} ", repo.display())), "{line}");
    let note = resume_note(line);
    assert!(note.contains("repository root"), "{note:?}");
    assert!(!Path::new(&wt).exists(), "nothing was recreated");

    let pi = bench(
        &home.dir,
        &["spawn", "--agent", "pi", "--cwd", &wt, "--resume", "p-wt"],
    );
    assert_eq!(pi.code, 3, "refused: {}", pi.stderr);
    assert!(pi.stderr.contains("worktree add"), "{}", pi.stderr);
    // A refusal answers before any process starts; the sleep only lets a wrong start show.
    std::thread::sleep(Duration::from_millis(300));
    assert!(!pi_runs.exists(), "no pi ran");
}

#[test]
fn an_alternate_profile_is_neither_read_nor_passed_on() {
    // The operator's ruling (#491): benchd and its agents always use the default profile under
    // HOME. A transcript that exists only where CLAUDE_CONFIG_DIR points is not a transcript,
    // and no session benchd spawns inherits CLAUDE_CONFIG_DIR, CODEX_HOME or PI_CODING_AGENT_DIR.
    let home = TestHome::claim("m5b-claudecfg");
    let ws = workspace(&home.dir).display().to_string();
    let config = home.dir.join("elsewhere-claude");
    let projects = config.join("projects/ws");
    fs::create_dir_all(&projects).unwrap();
    fs::write(projects.join("c-9a1f.jsonl"), "{}\n").unwrap();
    let seen = home.dir.join("agent-env");
    let bin = write_agent_script(
        &home.dir,
        "pi",
        &format!("env > '{}'; exec cat", seen.display()),
    );
    write_fake_agent(&home.dir, "claude");
    let path = std::env::var("PATH").unwrap_or_default();
    let with_alternates = || {
        let mut cmd = isolated(benchd_bin());
        cmd.env("PATH", format!("{}:{path}", bin.display()))
            .env("CLAUDE_CONFIG_DIR", &config)
            .env("CODEX_HOME", home.dir.join("elsewhere-codex"))
            .env("PI_CODING_AGENT_DIR", home.dir.join("elsewhere-pi"));
        cmd
    };
    let pane = {
        let daemon = DaemonGuard::start_with(&home.dir, None, with_alternates());
        ok_data(layout(
            &daemon.socket,
            "workspace/open",
            serde_json::json!({ "path": ws }),
            operator(),
            false,
        ));
        let pane = json_of(&bench(&home.dir, &["open", "terminal"]))["pane"]
            .as_str()
            .unwrap()
            .to_string();
        let (_, pid) = terminal_process(&home.dir, "holder");
        hook_verb(
            &daemon.socket,
            serde_json::json!({"harness": "claude", "event": "SessionStart", "session": "c-9a1f",
                "cwd": ws, "pid": pid, "pane": pane}),
        );
        pane
    };
    let _daemon = DaemonGuard::start_with(&home.dir, None, with_alternates());
    let restored = json_of(&bench(&home.dir, &["restore", &pane]));
    assert_ne!(restored["restored"][0]["how"], "resumed", "{restored}");

    let run = bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", &ws]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let deadline = Instant::now() + Duration::from_secs(10);
    while !fs::read_to_string(&seen).is_ok_and(|e| e.contains("BENCH_SESSION=")) {
        assert!(
            Instant::now() < deadline,
            "the spawned agent never wrote its environment"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let env = fs::read_to_string(&seen).unwrap();
    for name in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "PI_CODING_AGENT_DIR"] {
        assert!(
            !env.lines().any(|l| l.starts_with(&format!("{name}="))),
            "{name} reached the spawned agent:\n{env}"
        );
    }
}

// ---------------------------------------------------------------------------
// M5b PR 4: each session's VT engine
// ---------------------------------------------------------------------------

/// Attach raw and read what the viewer is sent until `done` holds or ten seconds pass.
fn attach_and_read(
    socket: &Path,
    sid: &str,
    done: impl Fn(&[u8]) -> bool,
) -> (Vec<u8>, UnixStream) {
    let (resp, stream) = raw_request(socket, "attach", serde_json::json!({"session": sid}));
    assert_eq!(resp["status"], "ok", "{resp}");
    let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
    let seen = read_until(&stream, Duration::from_secs(10), done);
    (seen, stream)
}

/// Spawn `pi` (a scripted one) and wait until its script has touched `<home>/written`: what it
/// wrote before that is in the session before any viewer attaches.
fn spawn_scripted(home: &Path) -> String {
    let ws = workspace(home).display().to_string();
    let run = bench(home, &["spawn", "--agent", "pi", "--cwd", &ws]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let marker = home.join("written");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !marker.exists() {
        assert!(Instant::now() < deadline, "the script never got going");
        std::thread::sleep(Duration::from_millis(20));
    }
    // The marker is written after the output, which then still has to cross the pty.
    std::thread::sleep(Duration::from_millis(200));
    json_of(&run)["session"].as_str().unwrap().to_string()
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

#[test]
fn a_viewer_that_attaches_late_is_shown_the_alternate_screen_the_program_opened() {
    let home = TestHome::claim("m5b-alt");
    let daemon = scripted_pi_daemon(
        &home.dir,
        &format!(
            "#!/bin/sh\nprintf '\\033]2;my title\\007\\033[?1049h\\033[5;3HON ALT'\ntouch {}/written\nexec sleep 60\n",
            home.dir.display()
        ),
    );
    // Written before any viewer existed.
    let sid = spawn_scripted(&home.dir);
    let (seen, _stream) = attach_and_read(&daemon.socket, &sid, |b| contains(b, b"ON ALT"));
    let text = String::from_utf8_lossy(&seen);
    let alt = text
        .find("\x1b[?1049h")
        .unwrap_or_else(|| panic!("no alternate screen: {text:?}"));
    assert!(alt < text.find("ON ALT").unwrap(), "{text:?}");
    assert!(
        text.contains("\x1b[5;9H"),
        "the cursor is where the program left it: {text:?}"
    );
    assert!(
        text.contains("\x1b]2;my title"),
        "the title it set: {text:?}"
    );
}

/// A program that asks the terminal what it is (DA1) and prints the answer it got, in hex.
const ASKS_DA1: &str = "#!/bin/sh\nstty -icanon -echo min 1\necho ready\nIFS= read -r go\nprintf '\\033[c'\nhead -c 9 | od -An -tx1\nexec sleep 60\n";

#[test]
fn a_query_is_answered_by_benchd_while_no_viewer_is_attached() {
    let home = TestHome::claim("m5b-da1");
    let daemon = scripted_pi_daemon(&home.dir, ASKS_DA1);
    let ws = workspace(&home.dir).display().to_string();
    let run = bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", &ws]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let sid = json_of(&run)["session"].as_str().unwrap().to_string();
    // Start it through a viewer, then leave, so the query lands with nobody attached.
    {
        let (_seen, stream) = attach_and_read(&daemon.socket, &sid, |b| contains(b, b"ready"));
        (&stream)
            .write_all(&AttachFrame::Input(b"go\n".to_vec()).encode())
            .unwrap();
        let _ = stream.shutdown(std::net::Shutdown::Both);
    }
    std::thread::sleep(Duration::from_millis(1500));
    let (seen, _stream) = attach_and_read(&daemon.socket, &sid, |b| contains(b, b"63"));
    let text = String::from_utf8_lossy(&seen);
    let words = text.split_whitespace().collect::<Vec<_>>().join(" ");
    // `ESC [ ? 6 2 ; 2 2 c`, what Ghostty answers.
    assert!(words.contains("1b 5b 3f 36 32 3b 32 32 63"), "{text:?}");
}

#[test]
fn a_query_is_left_to_the_viewer_while_one_is_attached() {
    let home = TestHome::claim("m5b-da1v");
    let daemon = scripted_pi_daemon(&home.dir, ASKS_DA1);
    let ws = workspace(&home.dir).display().to_string();
    let run = bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", &ws]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let sid = json_of(&run)["session"].as_str().unwrap().to_string();
    let (_seen, stream) = attach_and_read(&daemon.socket, &sid, |b| contains(b, b"ready"));
    (&stream)
        .write_all(&AttachFrame::Input(b"go\n".to_vec()).encode())
        .unwrap();
    // The query reaches the viewer, which (a socket, not a terminal) never answers it.
    let seen = read_until(&stream, Duration::from_secs(3), |b| contains(b, b"1b"));
    assert!(
        contains(&seen, b"\x1b[c"),
        "{:?}",
        String::from_utf8_lossy(&seen)
    );
    assert!(
        !contains(&seen, b"1b"),
        "benchd answered for an attached viewer: {:?}",
        String::from_utf8_lossy(&seen)
    );
}

#[test]
fn a_viewer_that_attaches_mid_frame_is_shown_the_finished_frame() {
    let home = TestHome::claim("m5b-hold");
    let daemon = scripted_pi_daemon(
        &home.dir,
        &format!(
            "#!/bin/sh\nprintf '\\033[?2026hPART'\ntouch {}/written\nsleep 1\nprintf 'WHOLE\\033[?2026l'\nexec sleep 60\n",
            home.dir.display()
        ),
    );
    let sid = spawn_scripted(&home.dir);
    let (seen, _stream) = attach_and_read(&daemon.socket, &sid, |b| contains(b, b"WHOLE"));
    let text = String::from_utf8_lossy(&seen);
    // Replayed as one frame, rather than PART on screen and WHOLE arriving after it.
    assert!(text.contains("PARTWHOLE"), "{text:?}");
}

#[test]
fn a_frame_that_never_finishes_keeps_a_viewer_out_for_a_second_at_most() {
    let home = TestHome::claim("m5b-hold2");
    let daemon = scripted_pi_daemon(
        &home.dir,
        &format!(
            "#!/bin/sh\nprintf '\\033[?2026hSTUCK'\ntouch {}/written\nexec sleep 60\n",
            home.dir.display()
        ),
    );
    let sid = spawn_scripted(&home.dir);
    let started = Instant::now();
    let (seen, _stream) = attach_and_read(&daemon.socket, &sid, |b| contains(b, b"STUCK"));
    assert!(
        contains(&seen, b"STUCK"),
        "{:?}",
        String::from_utf8_lossy(&seen)
    );
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "{:?}",
        started.elapsed()
    );
}

/// `bench get screen <target>` until one of its lines satisfies `found`, or five seconds.
fn screen_until(home: &Path, target: &str, found: impl Fn(&str) -> bool) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let run = bench(home, &["get", "screen", target]);
        assert_eq!(run.code, 0, "{}", run.stderr);
        let screen = json_of(&run);
        let lines = screen["lines"].as_array().unwrap();
        if lines.iter().any(|l| found(l.as_str().unwrap())) || Instant::now() > deadline {
            return screen;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn an_agent_types_into_a_shell_pane_and_reads_what_it_printed() {
    let home = TestHome::claim("m5b-send");
    let ws = workspace(&home.dir).display().to_string();
    let daemon = DaemonGuard::start(&home.dir, None);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    let opened = bench(&home.dir, &["open", "terminal"]);
    assert_eq!(opened.code, 0, "{}", opened.stderr);
    let pane = json_of(&opened)["pane"].as_str().unwrap().to_string();

    let sent = bench(&home.dir, &["send", &pane, "echo sum-$((40+2))", "--enter"]);
    assert_eq!(sent.code, 0, "{}", sent.stderr);
    // A shell that has not printed its prompt yet echoes the typed line first, so the output
    // can follow a prompt on its row.
    let ran = |l: &str| l.ends_with("sum-42") && !l.contains("echo");
    let screen = screen_until(&home.dir, &pane, ran);
    let lines: Vec<&str> = screen["lines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l.as_str().unwrap())
        .collect();
    assert!(lines.iter().any(|l| ran(l)), "the shell ran it: {screen}");
    assert_eq!(
        screen["rows"].as_u64().unwrap() as usize,
        lines.len(),
        "{screen}"
    );
    assert_eq!(screen["alt_screen"], false);

    // What was typed is logged by its size and sender, never its text.
    let log = fs::read_to_string(home.dir.join(".bench/events.jsonl")).unwrap();
    let sent_line = log
        .lines()
        .find(|l| l.contains("\"screen/sent\""))
        .expect("screen/sent logged");
    assert!(sent_line.contains("\"bytes\":18"), "{sent_line}");
    assert!(!log.contains("sum-$((40+2))"), "the text reached the log");

    let gone = bench(&home.dir, &["get", "screen", "s999"]);
    assert_eq!(gone.code, 3, "{}", gone.stderr);
}

#[test]
fn text_sent_to_a_program_that_asked_for_bracketed_paste_arrives_as_one_paste() {
    let home = TestHome::claim("m5b-paste");
    let _daemon = scripted_pi_daemon(
        &home.dir,
        &format!(
            "#!/bin/sh\nstty -icanon -echo -icrnl min 1\nprintf '\\033[?2004h'\ntouch {}/written\nhead -c 16 | od -An -c\nexec sleep 60\n",
            home.dir.display()
        ),
    );
    let sid = spawn_scripted(&home.dir);
    let sent = bench(&home.dir, &["send", &sid, "abc", "--enter"]);
    assert_eq!(sent.code, 0, "{}", sent.stderr);
    assert_eq!(json_of(&sent)["bracketed"], true);
    let screen = screen_until(&home.dir, &sid, |l| l.contains('~'));
    let text: String = screen["lines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l.as_str().unwrap())
        .collect::<Vec<_>>()
        .join(" ");
    let words = text.split_whitespace().collect::<Vec<_>>().join(" ");
    // ESC [ 2 0 0 ~ a b c ESC [ 2 0 1 ~ \r
    assert!(
        words.contains("033 [ 2 0 0 ~ a b c 033 [ 2 0 1 ~ \\r"),
        "{words:?}"
    );
}

/// Keys answer a prompt: Esc, Ctrl-C and a digit reach a program that asked for bracketed paste
/// as the bytes themselves. Inside a paste, Claude Code reads Esc as text (#625).
#[test]
fn keys_sent_to_a_program_that_asked_for_bracketed_paste_arrive_unpasted() {
    let home = TestHome::claim("m5b-keys");
    let _daemon = scripted_pi_daemon(
        &home.dir,
        &format!(
            "#!/bin/sh\nstty -icanon -isig -echo -icrnl min 1\nprintf '\\033[?2004h'\ntouch {}/written\nhead -c 4 | od -An -c\nexec sleep 60\n",
            home.dir.display()
        ),
    );
    let sid = spawn_scripted(&home.dir);
    let sent = bench(
        &home.dir,
        &["send", &sid, "\u{1b}\u{3}2", "--keys", "--enter"],
    );
    assert_eq!(sent.code, 0, "{}", sent.stderr);
    assert_eq!(json_of(&sent)["bracketed"], false);
    let screen = screen_until(&home.dir, &sid, |l| l.contains("033"));
    let text: String = screen["lines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l.as_str().unwrap())
        .collect::<Vec<_>>()
        .join(" ");
    let words = text.split_whitespace().collect::<Vec<_>>().join(" ");
    // ESC ^C 2 \r, and no paste around them
    assert!(words.contains("033 003 2 \\r"), "{words:?}");
    let log = fs::read_to_string(home.dir.join(".bench/events.jsonl")).unwrap();
    let sent_line = log
        .lines()
        .find(|l| l.contains("\"screen/sent\""))
        .expect("screen/sent logged");
    assert!(sent_line.contains("\"keys\":true"), "{sent_line}");
}

#[test]
fn watch_prints_each_finished_frame_and_never_one_inside_an_update() {
    let home = TestHome::claim("m5b-watch");
    let _daemon = scripted_pi_daemon(
        &home.dir,
        &format!(
            "#!/bin/sh\ntouch {}/written\nsleep 1\nprintf '\\033[?2026hMIDFRAME'\nsleep 0.5\nprintf ' DONE\\033[?2026l'\nexec sleep 60\n",
            home.dir.display()
        ),
    );
    let sid = spawn_scripted(&home.dir);
    let mut watch = isolated(bench_bin())
        .env("HOME", &home.dir)
        .args(["watch", "screen", &sid])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let stdout = watch.stdout.take().unwrap();
    let frames = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    {
        let frames = std::sync::Arc::clone(&frames);
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                frames.lock().unwrap().push(line);
            }
        });
    }
    let deadline = Instant::now() + Duration::from_secs(8);
    while Instant::now() < deadline && !frames.lock().unwrap().iter().any(|f| f.contains("DONE")) {
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = watch.kill();
    let _ = watch.wait();
    let frames = frames.lock().unwrap();
    assert!(
        frames.len() >= 2,
        "a first frame, then the change: {frames:?}"
    );
    assert!(
        frames.iter().any(|f| f.contains("MIDFRAME DONE")),
        "{frames:?}"
    );
    assert!(
        !frames
            .iter()
            .any(|f| f.contains("MIDFRAME") && !f.contains("DONE")),
        "a frame from inside the update: {frames:?}"
    );
}

#[test]
fn a_viewer_that_stops_reading_is_dropped_and_the_session_still_answers() {
    // Every connection writes under DAEMON_IO_TIMEOUT, the relay included: a viewer that stops
    // reading holds the engine thread, and with it the session's resizes and screen reads, for
    // that long and then is dropped.
    //
    // When the stall begins is the kernel's business: the relay blocks once the viewer's socket
    // is full, which this side cannot see. So no single read is known to land inside it, and a
    // read timed against a fixed bound flakes whenever the stall starts just after the read
    // before it (#487's version did, on CI). Reads run back to back on their own thread instead,
    // so some read overlaps the stall whenever it starts, and each is bounded by the write limit.
    let limit = bench_wire::DAEMON_IO_TIMEOUT;
    let home = TestHome::claim("m5b-stuck");
    let daemon = scripted_pi_daemon(
        &home.dir,
        &format!(
            "#!/bin/sh\ntouch {}/written\nsleep 2\nexec yes 'a line of output that fills the socket'\n",
            home.dir.display()
        ),
    );
    let sid = spawn_scripted(&home.dir);
    // A viewer that reads for a while, then never again.
    let (seen, stream) = attach_and_read(&daemon.socket, &sid, |b| b.len() > 100_000);
    assert!(seen.len() > 100_000, "the flood reached the viewer");
    // Dropped once one write has waited the limit out; the deadline only says "never", and
    // bounds the reader too, so a failed assertion below does not leave it running.
    let deadline = Instant::now() + 3 * limit;
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let reads = {
        let (home, sid, stop) = (home.dir.clone(), sid.clone(), std::sync::Arc::clone(&stop));
        std::thread::spawn(move || {
            let mut reads = Vec::new();
            while !stop.load(Ordering::SeqCst) && Instant::now() < deadline {
                let started = Instant::now();
                let screen = bench(&home, &["get", "screen", &sid]);
                reads.push((screen.code, screen.stderr, started.elapsed()));
            }
            reads
        })
    };
    while session_row(&home.dir, &sid)["attached"] != false {
        assert!(
            Instant::now() < deadline,
            "a viewer that stopped reading was never dropped"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    stop.store(true, Ordering::SeqCst);
    for (code, stderr, waited) in reads.join().unwrap() {
        assert_eq!(code, 0, "a read while the viewer was stuck: {stderr}");
        // One stalled write is the most a read may wait behind, not one per chunk of output.
        assert!(waited < 2 * limit, "a read waited {waited:?}");
    }
    // With the viewer gone nothing is left to wait on: no read waits out a write limit.
    let started = Instant::now();
    let after = bench(&home.dir, &["get", "screen", &sid]);
    assert_eq!(after.code, 0, "{}", after.stderr);
    assert!(started.elapsed() < limit, "{:?}", started.elapsed());
    drop(stream);
}

#[test]
fn a_stalled_viewer_on_one_session_never_holds_up_a_verb_on_another() {
    // A stalled viewer holds its own session's locks for up to DAEMON_IO_TIMEOUT (see the test
    // above). `sessions` reads every session, and helm asks it every two seconds: if it read one
    // of those locks under benchd's core lock, every verb for every pane would wait out the stall
    // behind it (#517). `sessions` runs back to back here as helm's poll does, so one call
    // overlaps the stall whenever it starts, while another session's screen is read back to back.
    let limit = bench_wire::DAEMON_IO_TIMEOUT;
    let home = TestHome::claim("m5b-stall-other");
    let daemon = scripted_pi_daemon(
        &home.dir,
        &format!(
            "#!/bin/sh\ntouch {}/written\nsleep 2\nexec yes 'a line of output that fills the socket'\n",
            home.dir.display()
        ),
    );
    let stalled = spawn_scripted(&home.dir);
    let other = spawn_scripted(&home.dir);
    let (seen, stream) = attach_and_read(&daemon.socket, &stalled, |b| b.len() > 100_000);
    assert!(seen.len() > 100_000, "the flood reached the viewer");
    // Every thread here stops at this deadline on its own, whatever the assertions do.
    let deadline = Instant::now() + 3 * limit;
    let dropped = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let poll = {
        let (home, stalled, dropped) = (
            home.dir.clone(),
            stalled.clone(),
            std::sync::Arc::clone(&dropped),
        );
        std::thread::spawn(move || {
            while Instant::now() < deadline {
                if session_row(&home, &stalled)["attached"] == false {
                    dropped.store(true, Ordering::SeqCst);
                    return;
                }
            }
        })
    };
    let mut reads = Vec::new();
    while !dropped.load(Ordering::SeqCst) && Instant::now() < deadline {
        let started = Instant::now();
        let screen = bench(&home.dir, &["get", "screen", &other]);
        reads.push((screen.code, screen.stderr, started.elapsed()));
    }
    poll.join().unwrap();
    assert!(
        dropped.load(Ordering::SeqCst),
        "a viewer that stopped reading was never dropped"
    );
    for (code, stderr, waited) in reads {
        assert_eq!(code, 0, "{stderr}");
        // Behind a blocked `sessions`, a read waits out the rest of the stall: seconds, not the
        // milliseconds a read of an unrelated session takes.
        assert!(
            waited < limit / 2,
            "reading another session waited {waited:?} behind the stalled viewer"
        );
    }
    drop(stream);
}

#[test]
fn a_session_flooding_its_viewer_still_answers_at_once() {
    // Output and requests share the engine thread; a program that never pauses must not keep a
    // resize or a screen read waiting behind its output.
    let home = TestHome::claim("m5b-flood");
    let daemon = scripted_pi_daemon(
        &home.dir,
        &format!(
            "#!/bin/sh\ntouch {}/written\nexec yes 'a line of output from a program that never pauses'\n",
            home.dir.display()
        ),
    );
    let sid = spawn_scripted(&home.dir);
    let (resp, stream) = raw_request(
        &daemon.socket,
        "attach",
        serde_json::json!({"session": sid}),
    );
    assert_eq!(resp["status"], "ok", "{resp}");
    let reading = std::thread::spawn(move || {
        let mut chunk = [0u8; 65536];
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if (&stream).read(&mut chunk).map_or(true, |n| n == 0) {
                break;
            }
        }
    });
    std::thread::sleep(Duration::from_millis(500));
    for _ in 0..5 {
        let started = Instant::now();
        let screen = bench(&home.dir, &["get", "screen", &sid]);
        assert_eq!(screen.code, 0, "{}", screen.stderr);
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "{:?}",
            started.elapsed()
        );
    }
    let _ = bench(&home.dir, &["close", &sid]);
    let _ = reading.join();
}

/// A captured screen from `crates/benchd/screens/`.
fn capture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../benchd/screens")
        .join(format!("{name}.txt"))
        .canonicalize()
        .unwrap()
}

/// `bench sessions`' entry for `session`.
fn live_entry(home: &Path, session: &str) -> serde_json::Value {
    let run = bench(home, &["sessions"]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    json_of(&run)["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["session"] == session)
        .cloned()
        .unwrap_or_else(|| panic!("no session {session}"))
}

#[test]
fn an_agent_parked_at_a_prompt_is_seen_waiting_from_its_screen() {
    let home = TestHome::claim("m1-waiting");
    // pi's real trust prompt, drawn by a program that then goes silent, as pi does.
    let _daemon = scripted_pi_daemon(
        &home.dir,
        &format!(
            "#!/bin/sh\ncat '{}'\ntouch {}/written\nexec sleep 60\n",
            capture("pi-trust").display(),
            home.dir.display()
        ),
    );
    let sid = spawn_scripted(&home.dir);
    let mut entry = serde_json::Value::Null;
    wait_until("the prompt is seen", Duration::from_secs(10), || {
        entry = live_entry(&home.dir, &sid);
        !entry["waiting"].is_null()
    });
    assert_eq!(entry["waiting"]["waiting_for"], "trust prompt", "{entry}");
    assert_eq!(entry["waiting"]["source"], "screen", "{entry}");
    assert!(entry["waiting"]["since_ms"].as_u64().unwrap() > 0);

    // The session list says so too: pi publishes no status of its own.
    let ws = workspace(&home.dir).display().to_string();
    let all = json_of(&bench(
        &home.dir,
        &["sessions", "--all", "--workspace", &ws],
    ));
    let row = all["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["host"]["session"] == sid.as_str())
        .unwrap_or_else(|| panic!("no row for {sid}: {all}"));
    assert_eq!(
        row["state"]["activity"],
        serde_json::json!({ "kind": "waiting", "waiting_for": "trust prompt" }),
        "{row}"
    );
    // Dated from when the wait began, not the session's start: the age is what says stall.
    assert_eq!(row["updated_at_ms"], entry["waiting"]["since_ms"], "{row}");
    let logged = event_kinds(&home.dir)
        .into_iter()
        .find(|(kind, _)| kind == "session/waiting")
        .expect("session/waiting logged");
    assert_eq!(logged.1["waiting_for"], "trust prompt", "{:?}", logged.1);
    assert_eq!(logged.1["rule"], "pi", "{:?}", logged.1);
}

/// A prompt left on a shell's screen by a program that exited is history, not a wait: a
/// claude that stopped at a prompt and was quit leaves exactly this.
#[test]
fn a_prompt_on_a_shell_at_its_prompt_is_not_waiting() {
    let home = TestHome::claim("m1-shell");
    let ws = workspace(&home.dir).display().to_string();
    let daemon = DaemonGuard::start(&home.dir, None);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    let opened = bench(&home.dir, &["open", "terminal"]);
    assert_eq!(opened.code, 0, "{}", opened.stderr);
    let pane = json_of(&opened)["pane"].as_str().unwrap().to_string();
    let line = format!("cat '{}'", capture("claude-permission").display());
    let sent = bench(&home.dir, &["send", &pane, &line, "--enter"]);
    assert_eq!(sent.code, 0, "{}", sent.stderr);
    let screen = screen_until(&home.dir, &pane, |l| l.contains("Esc to cancel"));
    let sid = screen["session"].as_str().unwrap().to_string();
    // Longer than output takes to settle, however it trickles in.
    std::thread::sleep(Duration::from_secs(3));
    let entry = live_entry(&home.dir, &sid);
    assert!(entry["waiting"].is_null(), "{entry}");
}

/// ⌘⇧J's verb: the operator goes to the agent waiting on him longest, and each press after that
/// to the next, round again. An agent may not take him there unasked.
#[test]
fn focus_waiting_walks_the_waiting_panes_longest_first() {
    let home = TestHome::claim("m1-jump");
    let daemon = scripted_pi_daemon(
        &home.dir,
        &format!(
            "#!/bin/sh\ncat '{}'\nexec sleep 60\n",
            capture("pi-trust").display()
        ),
    );
    let ws = workspace(&home.dir).display().to_string();
    let nothing = layout(
        &daemon.socket,
        "focus/waiting",
        serde_json::json!({}),
        operator(),
        false,
    );
    assert_eq!(nothing["status"], "refused", "{nothing}");
    assert!(
        nothing["reason"].as_str().unwrap().contains("needs you"),
        "{nothing}"
    );

    let mut spawned = Vec::new();
    for _ in 0..2 {
        let run = bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", &ws]);
        assert_eq!(run.code, 0, "{}", run.stderr);
        let answer = json_of(&run);
        let (sid, pane) = (
            answer["session"].as_str().unwrap().to_string(),
            answer["pane"].as_str().unwrap().to_string(),
        );
        wait_until("the prompt is seen", Duration::from_secs(10), || {
            !live_entry(&home.dir, &sid)["waiting"].is_null()
        });
        spawned.push(pane);
    }
    let jump = |by: Option<serde_json::Value>, asked: bool| {
        layout(
            &daemon.socket,
            "focus/waiting",
            serde_json::json!({}),
            by,
            asked,
        )
    };
    let refused = jump(None, false);
    assert_eq!(refused["status"], "refused", "an agent, unasked: {refused}");

    let mut visited = Vec::new();
    for _ in 0..3 {
        let data = ok_data(jump(operator(), false));
        assert_eq!(data["focused_pane_after"], data["pane"], "{data}");
        visited.push(data["pane"].as_str().unwrap().to_string());
    }
    assert_eq!(
        visited,
        [spawned[0].clone(), spawned[1].clone(), spawned[0].clone()]
    );
}

/// A Claude whose hooks are not wired still says it waits, in its own registry row: benchd reads
/// the row of the process in a session's foreground when its output settles, so a prompt no
/// screen rule describes is still one the operator is taken to.
#[test]
fn a_registry_row_saying_waiting_is_a_wait_without_a_hook_or_a_rule() {
    let home = TestHome::claim("m1-registry");
    let sessions = home.dir.join(".claude/sessions");
    fs::create_dir_all(&sessions).unwrap();
    let _daemon = scripted_pi_daemon(
        &home.dir,
        &format!(
            "#!/bin/sh\nprintf '{{\"pid\":%s,\"sessionId\":\"s-1\",\"cwd\":\"/tmp\",\"startedAt\":%s000,\"status\":\"waiting\",\"waitingFor\":\"dialog open\",\"statusUpdatedAt\":1000}}' $$ $(date +%s) > {}/$$.json\nprintf 'a screen no rule reads\\n'\ntouch {}/written\nexec sleep 60\n",
            sessions.display(),
            home.dir.display()
        ),
    );
    let sid = spawn_scripted(&home.dir);
    let mut entry = serde_json::Value::Null;
    wait_until("the row is read", Duration::from_secs(10), || {
        entry = live_entry(&home.dir, &sid);
        !entry["waiting"].is_null()
    });
    assert_eq!(
        entry["waiting"],
        serde_json::json!({ "waiting_for": "dialog open", "since_ms": 1000, "source": "registry" }),
        "{entry}"
    );
}

// ---------------------------------------------------------------------------
// M5c (#459): a benchd reached by address, and a pane that outlives a dropped link
// ---------------------------------------------------------------------------

/// A loopback port nobody holds right now, for `BENCH_LISTEN`.
fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// A daemon that also listens on TCP, and the port it holds.
fn tcp_daemon(home: &Path) -> (DaemonGuard, u16) {
    tcp_daemon_from(home, None, |_| {})
}

/// A port `free_port` found is let go of before benchd binds it, and under the full gate another
/// test can take it in between; benchd then refuses to start (`serve_tcp`). So each try starts
/// benchd on a fresh port until one holds, beginning at `first` when given.
fn tcp_daemon_from(
    home: &Path,
    first: Option<u16>,
    configure: impl Fn(&mut std::process::Command),
) -> (DaemonGuard, u16) {
    let mut refused = Vec::new();
    for port in first
        .into_iter()
        .chain(std::iter::repeat_with(free_port))
        .take(10)
    {
        let mut cmd = isolated(benchd_bin());
        cmd.env("BENCH_LISTEN", format!("127.0.0.1:{port}"));
        configure(&mut cmd);
        match DaemonGuard::try_start_with(home, None, cmd) {
            Ok(guard) => return (guard, port),
            Err(why) => refused.push(format!("{port}: {why}")),
        }
    }
    panic!("benchd could not hold a TCP port: {refused:?}");
}

/// A TCP link between clients and benchd's listener that the test can cut, the way a Wi-Fi
/// change or a sleeping Mac cuts one: `cut` closes every connection it carries and stops
/// accepting, so a client that tries again is refused; `restore` accepts again on the same port.
/// Its threads end with the test binary.
struct Link {
    port: u16,
    up: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl Link {
    fn start(target: u16) -> Link {
        use std::net::{Shutdown, TcpListener, TcpStream};
        use std::sync::atomic::AtomicBool;
        use std::sync::{Arc, Mutex};
        let first = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = first.local_addr().unwrap().port();
        let up = Arc::new(AtomicBool::new(true));
        let carried: Arc<Mutex<Vec<TcpStream>>> = Arc::default();
        let flag = Arc::clone(&up);
        std::thread::spawn(move || {
            let mut listener = Some(first);
            loop {
                if !flag.load(Ordering::SeqCst) {
                    listener = None;
                    for stream in carried.lock().unwrap().drain(..) {
                        let _ = stream.shutdown(Shutdown::Both);
                    }
                    std::thread::sleep(Duration::from_millis(20));
                    continue;
                }
                if listener.is_none() {
                    listener = TcpListener::bind(("127.0.0.1", port)).ok();
                }
                let Some(l) = &listener else {
                    std::thread::sleep(Duration::from_millis(20));
                    continue;
                };
                l.set_nonblocking(true).unwrap();
                let Ok((client, _)) = l.accept() else {
                    std::thread::sleep(Duration::from_millis(20));
                    continue;
                };
                client.set_nonblocking(false).unwrap();
                let Ok(server) = TcpStream::connect(("127.0.0.1", target)) else {
                    continue;
                };
                for (from, to) in [(&client, &server), (&server, &client)] {
                    let (mut from, mut to) = (from.try_clone().unwrap(), to.try_clone().unwrap());
                    std::thread::spawn(move || {
                        let _ = std::io::copy(&mut from, &mut to);
                        let _ = to.shutdown(Shutdown::Both);
                    });
                }
                carried.lock().unwrap().extend([client, server]);
            }
        });
        Link { port, up }
    }

    fn url(&self) -> String {
        format!("tcp://127.0.0.1:{}", self.port)
    }

    fn cut(&self) {
        self.up.store(false, Ordering::SeqCst);
    }

    fn restore(&self) {
        self.up.store(true, Ordering::SeqCst);
    }
}

#[test]
fn a_client_with_only_a_url_reaches_benchd_over_tcp() {
    let home = TestHome::claim("m5c-tcp");
    let (_daemon, port) = tcp_daemon(&home.dir);
    let url = format!("tcp://127.0.0.1:{port}");
    // A root of its own with no socket in it: whatever answers came over TCP.
    let elsewhere = home.dir.join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    let remote = [
        ("BENCH_URL", url.as_str()),
        ("BENCH_DIR", elsewhere.to_str().unwrap()),
    ];

    let status = bench_as(&home.dir, &["status"], &remote);
    assert_eq!(status.code, 0, "{}", status.stderr);
    assert_eq!(
        json_of(&status)["root"],
        home.dir.join(".bench").display().to_string(),
        "the benchd that answered is the one listening"
    );
    let spawned = bench_as(
        &home.dir,
        &["spawn", "--agent", "test-echo", "--cwd", "/tmp"],
        &remote,
    );
    assert_eq!(spawned.code, 0, "{}", spawned.stderr);
    let sessions = bench(&home.dir, &["sessions"]);
    assert_eq!(
        json_of(&sessions)["sessions"][0]["live"],
        true,
        "{}",
        sessions.stdout
    );

    // The follower: the document first, as over the unix socket.
    let mut follow = isolated(bench_bin());
    follow
        .envs(remote)
        .env("HOME", &home.dir)
        .args(["events", "--follow"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut child = follow.spawn().unwrap();
    let mut first = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut first)
        .unwrap();
    let _ = child.kill();
    let _ = child.wait();
    let first: serde_json::Value = serde_json::from_str(&first).expect("the document line");
    assert!(first["document"].is_object(), "{first}");

    assert!(
        !elsewhere.join("benchd.sock").exists() && fs::read_dir(&elsewhere).unwrap().count() == 0,
        "nothing was made in the client's own root"
    );
}

#[test]
fn a_url_that_is_wrong_or_unanswered_is_named_and_a_listen_that_cannot_bind_stops_benchd() {
    let home = TestHome::claim("m5c-bad");
    let malformed = bench_as(&home.dir, &["status"], &[("BENCH_URL", "forge:4518")]);
    assert_eq!(malformed.code, 3, "{}", malformed.stderr);
    assert!(
        malformed.stderr.contains("BENCH_URL=forge:4518"),
        "{}",
        malformed.stderr
    );

    let url = format!("tcp://127.0.0.1:{}", free_port());
    let unanswered = bench_as(&home.dir, &["status"], &[("BENCH_URL", &url)]);
    assert_eq!(unanswered.code, 2, "{}", unanswered.stderr);
    assert!(unanswered.stderr.contains(&url), "{}", unanswered.stderr);

    // Two benchds, one address: the second is told why, and does not start.
    let (_first, port) = tcp_daemon(&home.dir);
    let other = TestHome::claim("m5c-bad-2");
    let mut second = isolated(benchd_bin());
    second
        .env("HOME", &other.dir)
        .env("BENCH_LISTEN", format!("127.0.0.1:{port}"))
        .stdout(Stdio::null());
    let out = run_bounded(&mut second, Duration::from_secs(10)).expect("benchd gave up at once");
    assert_ne!(out.code, 0);
    assert!(
        out.stderr
            .contains(&format!("cannot listen on tcp 127.0.0.1:{port}")),
        "{}",
        out.stderr
    );
}

#[test]
fn a_pane_whose_link_drops_reconnects_and_shows_the_session_as_it_is() {
    // A helm pane on a remote benchd read a dropped link as "benchd is not running" and ended,
    // with its session still live (the M5c spike, attach.rs:240). Sleep, a Wi-Fi change and a
    // benchd restart all drop the link; only benchd saying the session ended may end the pane.
    let home = TestHome::claim("m5c-drop");
    let (_daemon, port) = tcp_daemon(&home.dir);
    let link = Link::start(port);
    let run = bench(
        &home.dir,
        &["spawn", "--agent", "test-echo", "--cwd", "/tmp"],
    );
    assert_eq!(run.code, 0, "{}", run.stderr);
    let sid = json_of(&run)["session"].as_str().unwrap().to_string();
    let elsewhere = home.dir.join("elsewhere");
    fs::create_dir_all(&elsewhere).unwrap();
    let url = link.url();
    let (mut master, mut viewer) = attach_on_pty_with(
        &home.dir,
        &sid,
        &["--in-pane"],
        24,
        80,
        &[
            ("BENCH_URL", &url),
            ("BENCH_DIR", elsewhere.to_str().unwrap()),
        ],
    );
    let output = record_pane(&master);
    let shown = || String::from_utf8_lossy(&output.lock().unwrap()).into_owned();
    let attached = || json_of(&bench(&home.dir, &["sessions"]))["sessions"][0]["attached"] == true;
    assert!(within(10, &attached), "the pane attaches over TCP");
    master.write_all(b"before-the-drop\n").unwrap();
    assert!(within(5, &|| shown().contains("before-the-drop")));

    link.cut();
    std::thread::sleep(Duration::from_secs(3));
    assert!(
        viewer.try_wait().unwrap().is_none(),
        "the pane's viewer keeps running while benchd is out of reach: {:?}",
        shown()
    );
    assert!(!shown().contains("ended"), "{:?}", shown());
    assert!(
        shown().contains("cannot reach benchd"),
        "the pane says why it is waiting: {:?}",
        shown()
    );

    link.restore();
    assert!(
        within(15, &attached),
        "the pane attached again: {:?}",
        shown()
    );
    master.write_all(b"after-the-drop\n").unwrap();
    assert!(
        within(5, &|| shown()
            .rsplit("cannot reach benchd")
            .next()
            .is_some_and(|after| after.contains("after-the-drop"))),
        "keys reach the session after the reconnect: {:?}",
        shown()
    );

    // The pane's terminal, replayed, is the session's screen: redrawn from benchd, nothing twice.
    std::thread::sleep(Duration::from_millis(300));
    let mut pane = bench_vt::Terminal::new(80, 24, 1 << 20).unwrap();
    pane.write(&output.lock().unwrap());
    let screen = json_of(&bench(&home.dir, &["get", "screen", &sid, "--history"]));
    let session_lines = trimmed(
        screen["lines"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l.as_str().unwrap().to_string())
            .collect(),
    );
    assert_eq!(trimmed(pane.lines(true).unwrap()), session_lines);

    // Control, which passes either way: the session ending still ends the pane, over TCP too.
    master.write_all(b"\n\x04").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline && viewer.try_wait().unwrap().is_none() {
        std::thread::sleep(Duration::from_millis(50));
    }
    let ended = viewer.try_wait().unwrap();
    if ended.is_none() {
        let _ = viewer.kill();
        let _ = viewer.wait();
    }
    assert_eq!(ended.and_then(|s| s.code()), Some(0), "{:?}", shown());
    assert!(
        within(5, &|| shown().contains(&format!("{sid} has ended"))),
        "{:?}",
        shown()
    );
}

// ---------------------------------------------------------------------------
// M5c: a canvas's files, through benchd, for a helm that shares no disk with it
// ---------------------------------------------------------------------------

/// One verb over TCP, the way helm sends a `file/*` verb to a benchd on another machine.
fn tcp_verb(port: u16, verb: &str, args: serde_json::Value) -> serde_json::Value {
    let stream = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect over TCP");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let request = serde_json::json!({ "id": "t-files", "verb": verb, "args": args });
    (&stream)
        .write_all(format!("{request}\n").as_bytes())
        .unwrap();
    let mut line = String::new();
    BufReader::new(&stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|e| panic!("not JSON ({e}): {line}"))
}

fn ok(answer: &serde_json::Value) -> &serde_json::Value {
    assert_eq!(answer["status"], "ok", "{answer}");
    &answer["data"]
}

fn decoded(answer: &serde_json::Value) -> Vec<u8> {
    let text = ok(answer)["base64"].as_str().expect("bytes");
    bench_wire::unbase64(text).expect("base64")
}

/// A benchd on TCP and a canvas folder holding `plan.md` (`# Plan\n`), canonical.
fn canvas_over_tcp(name: &str) -> (TestHome, u16, PathBuf, PathBuf, DaemonGuard) {
    let home = TestHome::claim(name);
    let (daemon, port) = tcp_daemon(&home.dir);
    let dir = home.dir.join("canvas");
    fs::create_dir_all(dir.join("img")).unwrap();
    let dir = dir.canonicalize().unwrap();
    let plan = dir.join("plan.md");
    fs::write(&plan, "# Plan\n").unwrap();
    (home, port, dir, plan, daemon)
}

#[test]
fn file_read_over_tcp_answers_bytes_absent_and_outside_the_folder() {
    let (home, port, dir, plan, _daemon) = canvas_over_tcp("m5c-read");
    fs::write(dir.join("img/x.png"), [0x89, b'P', b'N', b'G', 0, 255]).unwrap();
    fs::write(home.dir.join("secret.txt"), "secret").unwrap();
    std::os::unix::fs::symlink(home.dir.join("secret.txt"), dir.join("leak.txt")).unwrap();
    let p = |path: &Path| path.display().to_string();
    let within = p(&dir);

    // Read: bytes, nothing there, a directory refused.
    let read = |args| tcp_verb(port, "file/read", args);
    assert_eq!(
        decoded(&read(serde_json::json!({ "path": p(&plan) }))),
        b"# Plan\n"
    );
    let gone = read(serde_json::json!({ "path": p(&dir.join("gone.md")) }));
    assert_eq!(ok(&gone)["kind"], "absent");
    assert_eq!(
        read(serde_json::json!({ "path": within }))["status"],
        "refused"
    );

    // A page's sibling: inside the folder, nested, binary; `..`, a symlink out, and the folder
    // itself are outside. (`CanvasFileBoundaryTests`, moved to where the files are.)
    let sibling = |rel: &str| {
        read(serde_json::json!({ "path": format!("{within}/{rel}"), "within": within }))
    };
    assert_eq!(
        decoded(&sibling("img/x.png")),
        [0x89, b'P', b'N', b'G', 0, 255]
    );
    assert_eq!(ok(&sibling("missing.js"))["kind"], "absent");
    assert_eq!(ok(&sibling("../secret.txt"))["kind"], "outside");
    assert_eq!(ok(&sibling("leak.txt"))["kind"], "outside");
    assert_eq!(ok(&sibling(""))["kind"], "outside");
    // A folder named under a symlink (`/tmp` → `/private/tmp`) still holds its own siblings.
    if let Ok(tmp_spelled) = Path::new("/tmp").canonicalize()
        && let Ok(rest) = dir.strip_prefix(&tmp_spelled)
    {
        let aliased = format!("/tmp/{}", rest.display());
        let answer =
            read(serde_json::json!({ "path": format!("{aliased}/plan.md"), "within": aliased }));
        assert_eq!(decoded(&answer), b"# Plan\n");
    }
}

#[test]
fn file_write_and_append_over_tcp_keep_the_canvas_rules() {
    let (_home, port, dir, plan, _daemon) = canvas_over_tcp("m5c-write");
    let p = |path: &Path| path.display().to_string();

    // Write against what the writer was shown.
    let write = |text: &str, expect| {
        tcp_verb(
            port,
            "file/write",
            serde_json::json!({ "path": p(&plan), "text": text, "expect": expect }),
        )
    };
    let unchanged = |text: &str| serde_json::json!({ "kind": "unchanged", "text": text });
    assert_eq!(
        ok(&write("# Plan\n\nMine.\n", unchanged("# Plan\n")))["kind"],
        "written"
    );
    assert_eq!(fs::read_to_string(&plan).unwrap(), "# Plan\n\nMine.\n");
    // Somebody else rewrote it: nothing is written, and the answer carries their bytes.
    fs::write(&plan, "# Theirs\n").unwrap();
    let refused = write("# Plan\n\nMore.\n", unchanged("# Plan\n\nMine.\n"));
    assert_eq!(ok(&refused)["kind"], "changed");
    assert_eq!(decoded(&refused), b"# Theirs\n");
    assert_eq!(
        fs::read_to_string(&plan).unwrap(),
        "# Theirs\n",
        "untouched"
    );
    // Gone is not changed: the draft recreates the file.
    fs::remove_file(&plan).unwrap();
    assert_eq!(
        ok(&write("# Back\n", unchanged("# Theirs\n")))["kind"],
        "written"
    );
    assert_eq!(fs::read_to_string(&plan).unwrap(), "# Back\n");
    // A write that names no expectation is refused: every writer says what it saw (#532).
    let blind = write("{}", serde_json::json!({ "kind": "any" }));
    assert_eq!(blind["status"], "refused", "{blind}");
    assert_eq!(fs::read_to_string(&plan).unwrap(), "# Back\n");
    assert!(
        fs::read_dir(&dir).unwrap().all(|e| !e
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".tmp")),
        "no temporary file left behind"
    );

    // The sidecar is only ever appended to: a write is refused and touches nothing.
    let notes = dir.join("plan.notes.md");
    for text in ["## one\n", "## two\n"] {
        let answer = tcp_verb(
            port,
            "file/append",
            serde_json::json!({ "path": p(&notes), "text": text }),
        );
        ok(&answer);
    }
    assert_eq!(fs::read_to_string(&notes).unwrap(), "## one\n## two\n");
    let clobber = tcp_verb(
        port,
        "file/write",
        serde_json::json!({ "path": p(&notes), "text": "", "expect": unchanged("## one\n## two\n") }),
    );
    assert_eq!(clobber["status"], "refused", "{clobber}");
    // Other spellings of the same file are the sidecar too.
    for spelled in [
        format!("{}/.", p(&notes)),
        p(&dir.join("x/../plan.notes.md")),
        p(&dir.join("plan.NOTES.md")),
    ] {
        let answer = tcp_verb(
            port,
            "file/write",
            serde_json::json!({ "path": spelled, "text": "", "expect": unchanged("") }),
        );
        assert_eq!(answer["status"], "refused", "{spelled}: {answer}");
    }
    assert_eq!(fs::read_to_string(&notes).unwrap(), "## one\n## two\n");

    // A document larger than an ordinary request is accepted by the verbs that carry one;
    // every other verb keeps the 64 KB cap.
    let big = "x".repeat(1_000_000);
    assert_eq!(ok(&write(&big, unchanged("# Back\n")))["kind"], "written");
    assert_eq!(fs::read(&plan).unwrap().len(), 1_000_000);
    let padded = tcp_verb(
        port,
        "status",
        serde_json::json!({ "pad": "x".repeat(100_000) }),
    );
    assert_eq!(padded["status"], "refused", "{padded}");
}

#[test]
fn file_changed_names_the_canvas_and_its_sidecar_once_per_settled_save() {
    let home = TestHome::claim("m5c-watch");
    let daemon = DaemonGuard::start(&home.dir, None);
    let _ = working_bench(&daemon.socket);
    let plan = artifact(&home.dir, "watched.md");
    let notes = plan.replace("watched.md", "watched.notes.md");
    let neighbour = plan.replace("watched.md", "neighbour.md");
    let opened = bench(&home.dir, &["open", &plan]);
    assert_eq!(opened.code, 0, "{}", opened.stderr);
    let all_changes = || -> Vec<String> {
        event_kinds(&home.dir)
            .into_iter()
            .filter(|(kind, _)| kind == "file/changed")
            .map(|(_, data)| data["path"].as_str().unwrap().to_string())
            .collect()
    };
    // A canvas just watched is reported once it holds still — its file and its sidecar (absent,
    // still a state) — so a write between helm's read at open and benchd's first look, or made
    // while benchd was down, still reaches the pane.
    let ours = |all: Vec<String>| -> Vec<String> {
        all.into_iter()
            .filter(|p| *p == plan || *p == notes)
            .collect()
    };
    wait_until(
        "the new canvas's first report",
        Duration::from_secs(5),
        || ours(all_changes()).len() == 2,
    );
    let mut first = ours(all_changes());
    first.sort();
    let mut expected = vec![plan.clone(), notes.clone()];
    expected.sort();
    assert_eq!(
        first, expected,
        "the canvas file and its sidecar, once each"
    );
    std::thread::sleep(Duration::from_millis(300));
    let settled = all_changes().len();
    let changes = || all_changes().split_off(settled);
    // An atomic save of the canvas, in two pieces written quickly.
    let staged = format!("{plan}.tmp");
    fs::write(&staged, "# plan\n\nrewritten\n").unwrap();
    fs::rename(&staged, &plan).unwrap();
    fs::OpenOptions::new()
        .append(true)
        .open(&plan)
        .unwrap()
        .write_all(b"more\n")
        .unwrap();
    wait_until("the canvas's change", Duration::from_secs(5), || {
        changes().contains(&plan)
    });
    // A sidecar that did not exist when the canvas opened.
    fs::write(&notes, "## a note\n").unwrap();
    wait_until("the sidecar's change", Duration::from_secs(5), || {
        changes().contains(&notes)
    });
    // Something else in the folder is not watched.
    fs::write(&neighbour, "unrelated\n").unwrap();
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(
        changes(),
        vec![plan.clone(), notes.clone()],
        "one report each, and nothing else"
    );
}

// ---------------------------------------------------------------------------
// The live file (helm #532): an HTML canvas's `<stem>.data.json`, edited by the page and the agent
// ---------------------------------------------------------------------------

/// `bench` with `input` on its stdin.
///
/// A run that refuses before reading stdin (`file write` without `--expect`, `hook` for a
/// harness it does not know) may exit before the write lands, and the write then fails with
/// a broken pipe. That is the refusal itself, not a fault, so it is let through: the caller
/// still asserts the exit code and what the run left behind.
fn bench_stdin(home: &Path, args: &[&str], input: &str) -> CliRun {
    let mut child = isolated(bench_bin())
        .env("HOME", home)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run bench");
    match child.stdin.take().unwrap().write_all(input.as_bytes()) {
        Err(e) if e.kind() != std::io::ErrorKind::BrokenPipe => panic!("bench's stdin: {e}"),
        _ => {}
    }
    let out = child.wait_with_output().unwrap();
    CliRun {
        code: out.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    }
}

/// A `file/write` as helm sends one for the page: against the bytes the page saw.
fn page_write(socket: &Path, path: &str, text: &str, base: &str, notify: bool) -> String {
    let (reply, _) = raw_request(
        socket,
        "file/write",
        serde_json::json!({ "path": path, "text": text,
            "expect": { "kind": "unchanged", "text": base }, "notify": notify }),
    );
    ok(&reply)["kind"].as_str().unwrap().to_string()
}

/// An agent with a mailbox in `pane`: a process on a real terminal whose hook reports from it.
fn agent_in(home: &Path, socket: &Path, pane: &str) -> String {
    let (_, pid) = terminal_process(home, "opener");
    hook_verb(
        socket,
        serde_json::json!({"harness": "claude", "event": "SessionStart",
            "session": "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2", "cwd": "/tmp", "pid": pid,
            "pane": pane}),
    )["handle"]
        .as_str()
        .unwrap()
        .to_string()
}

fn canvas_pane<'a>(doc: &'a serde_json::Value, path: &str) -> &'a serde_json::Value {
    doc["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|w| w["bench"]["columns"].as_array().unwrap())
        .flat_map(|c| c["slots"].as_array().unwrap())
        .flat_map(|s| s["panes"].as_array().unwrap())
        .find(|p| p["surface"]["source"]["path"] == path)
        .unwrap_or_else(|| panic!("no pane shows {path}: {doc}"))
}

/// The bytes an agent read, as `--expect` wants them: a file.
fn saved(home: &Path, name: &str, text: &str) -> String {
    let path = home.join(name);
    fs::write(&path, text).unwrap();
    path.display().to_string()
}

#[test]
fn an_agents_write_over_a_version_it_has_not_read_is_refused() {
    let home = TestHome::claim("live-cas");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let data = saved(h, "tasks.data.json", "{\"done\": false}\n");

    // The agent reads the file, and keeps what it read.
    let read = bench(h, &["file", "read", &data]);
    assert_eq!(read.code, 0, "{}", read.stderr);
    assert_eq!(read.stdout, "{\"done\": false}\n", "the bytes, exactly");
    let base = saved(h, "base.json", &read.stdout);

    // The operator ticks the box on the page.
    let ticked = "{\n  \"done\" : true\n}\n";
    assert_eq!(
        page_write(&daemon.socket, &data, ticked, &read.stdout, true),
        "written"
    );

    // The agent writes back its copy: refused, and his edit is still there.
    let stale = bench_stdin(
        h,
        &["file", "write", &data, "--expect", &base],
        "{\"done\": false, \"note\": \"mine\"}\n",
    );
    assert_eq!(stale.code, 3, "{}", stale.stderr);
    assert!(
        stale.stderr.contains("changed since you read it"),
        "{}",
        stale.stderr
    );
    assert_eq!(fs::read_to_string(&data).unwrap(), ticked);

    // Read again, change what is there: written.
    let again = bench(h, &["file", "read", &data]);
    let base = saved(h, "base.json", &again.stdout);
    let merged = bench_stdin(
        h,
        &["file", "write", &data, "--expect", &base],
        "{\"done\": true, \"note\": \"mine\"}\n",
    );
    assert_eq!(merged.code, 0, "{}", merged.stderr);
    assert_eq!(
        fs::read_to_string(&data).unwrap(),
        "{\"done\": true, \"note\": \"mine\"}\n"
    );

    // Writing what is there changes nothing, not even the file's time.
    let mtime = || fs::metadata(&data).unwrap().modified().unwrap();
    let was = mtime();
    let current = fs::read_to_string(&data).unwrap();
    std::thread::sleep(Duration::from_millis(20));
    assert_eq!(
        page_write(&daemon.socket, &data, &current, &current, true),
        "written"
    );
    assert_eq!(mtime(), was, "an unchanged write leaves the file alone");

    // A pipe whose first step failed hands over nothing, or not JSON: refused, file untouched.
    let before = fs::read_to_string(&data).unwrap();
    let base = saved(h, "base.json", &before);
    for broken in ["", "{\"done\": tr"] {
        let run = bench_stdin(h, &["file", "write", &data, "--expect", &base], broken);
        assert_eq!(run.code, 3, "{broken:?}: {}", run.stderr);
        assert_eq!(fs::read_to_string(&data).unwrap(), before, "{broken:?}");
    }

    // No --expect is refused before anything is sent; a new file is --expect /dev/null.
    let blind = bench_stdin(h, &["file", "write", &data], "{}");
    assert_eq!(blind.code, 3, "{}", blind.stderr);
    assert!(blind.stderr.contains("--expect"), "{}", blind.stderr);
    let fresh = h.join("fresh.data.json").display().to_string();
    let missing = bench(h, &["file", "read", &fresh]);
    assert_eq!(missing.code, 3, "{}", missing.stderr);
    let created = bench_stdin(
        h,
        &["file", "write", &fresh, "--expect", "/dev/null"],
        "{}\n",
    );
    assert_eq!(created.code, 0, "{}", created.stderr);
    assert_eq!(fs::read_to_string(&fresh).unwrap(), "{}\n");
}

#[test]
fn a_page_edit_mails_the_canvas_opener_once_per_window_naming_every_pointer() {
    let home = TestHome::claim("live-mail");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (_, right, _) = working_bench(&daemon.socket);
    let handle = agent_in(h, &daemon.socket, &right);
    let page = artifact(h, "tasks.html");
    let data = page.replace("tasks.html", "tasks.data.json");
    fs::write(&data, r#"{"a":0,"b":0,"c":0}"#).unwrap();
    let opened = bench_as(h, &["open", &page], &[("HELM_PANE", &right)]);
    assert_eq!(opened.code, 0, "{}", opened.stderr);

    let mails = || -> Vec<serde_json::Value> {
        event_kinds(h)
            .into_iter()
            .filter(|(kind, d)| kind == "mail/sent" && d["to"] == handle.as_str())
            .map(|(_, d)| d)
            .collect()
    };
    // Three clicks inside one window, one of them the page reporting on itself (`notify:
    // false`), and one that only reformats the file.
    let mut base = fs::read_to_string(&data).unwrap();
    for (text, notify) in [
        (r#"{"a":1,"b":0,"c":0}"#, true),
        (r#"{"a":1,"b":1,"c":0}"#, true),
        (r#"{"a":1,"b":1,"c":1}"#, false),
        ("{\n  \"c\": 1, \"b\": 1, \"a\": 1\n}\n", true),
    ] {
        assert_eq!(
            page_write(&daemon.socket, &data, text, &base, notify),
            "written"
        );
        base = text.to_string();
    }
    wait_until("the opener's mail", Duration::from_secs(5), || {
        !mails().is_empty()
    });
    std::thread::sleep(Duration::from_millis(1500));
    let sent = mails();
    assert_eq!(sent.len(), 1, "one mail for the window: {sent:?}");
    assert_eq!(sent[0]["from"], "operator");
    let body = fs::read_to_string(sent[0]["path"].as_str().unwrap()).unwrap();
    assert!(
        body.contains(&format!("{data} was changed on the canvas tasks.html")),
        "{body}"
    );
    assert!(
        body.contains("Changed: /a, /b\n"),
        "the union, and not /c: {body}"
    );

    // A page reporting on itself alone mails nobody.
    let quiet = r#"{"a":1,"b":1,"c":2}"#;
    assert_eq!(
        page_write(&daemon.socket, &data, quiet, &base, false),
        "written"
    );
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(mails().len(), 1, "notify: false sends nothing");

    // A canvas the operator opened himself has nobody to tell, and the log says so.
    let own = artifact(h, "own.html");
    let own_data = own.replace("own.html", "own.data.json");
    assert_eq!(bench(h, &["open", &own]).code, 0);
    assert_eq!(
        page_write(&daemon.socket, &own_data, "{\"x\":1}", "", true),
        "written"
    );
    wait_until("the unmailed record", Duration::from_secs(5), || {
        event_kinds(h).iter().any(|(kind, d)| {
            kind == "live/unmailed"
                && d["path"] == own_data.as_str()
                && d["why"].as_str().unwrap().contains("no agent opened")
        })
    });
}

#[test]
fn the_opener_is_on_the_pane_in_the_document_and_survives_a_restart() {
    let home = TestHome::claim("live-opener");
    let h = &home.dir;
    let page = artifact(h, "tasks.html");
    let right = {
        let daemon = DaemonGuard::start(h, None);
        let (first, right, _) = working_bench(&daemon.socket);
        // An open from no agent's pane names nobody.
        assert_eq!(bench(h, &["open", &page]).code, 0);
        assert!(canvas_pane(&document(&daemon.socket), &page)["opener"].is_null());
        // An agent's open names its pane, and the newest agent wins.
        assert_eq!(
            bench_as(h, &["open", &page], &[("HELM_PANE", &first)]).code,
            0
        );
        assert_eq!(
            bench_as(h, &["open", &page], &[("HELM_PANE", &right)]).code,
            0
        );
        assert_eq!(
            canvas_pane(&document(&daemon.socket), &page)["opener"],
            right.as_str()
        );
        // Opened again from no agent's pane: the route stays.
        assert_eq!(bench(h, &["open", &page]).code, 0);
        assert_eq!(
            canvas_pane(&document(&daemon.socket), &page)["opener"],
            right.as_str()
        );
        right
    };
    let daemon = DaemonGuard::start(h, None);
    assert_eq!(
        canvas_pane(&document(&daemon.socket), &page)["opener"],
        right.as_str(),
        "read back from bench.json"
    );
    // The live file is watched once the canvas is open: an agent's write reaches helm.
    let data = page.replace("tasks.html", "tasks.data.json");
    fs::write(&data, "{}").unwrap();
    wait_until("the live file's change", Duration::from_secs(5), || {
        event_kinds(h)
            .iter()
            .any(|(kind, d)| kind == "file/changed" && d["path"] == data.as_str())
    });
}

/// A claude that writes the argv it was started with to `$HOME/argv-<bench session>`, then
/// echoes: what a fork was asked to run is a fact the stub can report. Written aside and renamed,
/// so [`stub_argv`], which reads as soon as the file exists, never reads half of it.
const ARGV_CLAUDE: &str = "printf '%s\\n' \"$@\" > \"$HOME/.argv-$BENCH_SESSION\" && mv \"$HOME/.argv-$BENCH_SESSION\" \"$HOME/argv-$BENCH_SESSION\"\nexec cat";

/// The argv the stub claude of session `sid` was started with.
fn stub_argv(home: &Path, sid: &str) -> Vec<String> {
    let file = home.join(format!("argv-{sid}"));
    let deadline = Instant::now() + Duration::from_secs(5);
    while !file.is_file() {
        assert!(Instant::now() < deadline, "session {sid} never started");
        std::thread::sleep(Duration::from_millis(20));
    }
    fs::read_to_string(file)
        .unwrap()
        .lines()
        .map(str::to_string)
        .collect()
}

/// Claude has a transcript for `id`: what `restore` needs before it resumes a claude.
fn fake_transcript(home: &Path, id: &str) {
    let project = home.join(".claude/projects/ws");
    fs::create_dir_all(&project).unwrap();
    fs::write(project.join(format!("{id}.jsonl")), "{}\n").unwrap();
}

#[test]
fn a_fork_is_its_own_read_only_conversation_so_the_author_restores_beside_it() {
    // #531: the operator asks an agent about its work in a fork of its conversation. Before, a
    // fork (`--resume <id> --arg --fork-session`) was recorded under the author's id, and while it
    // ran the author's pane would not restore: "conversation <id> is already live in <session>".
    let home = TestHome::claim("fork");
    let ws = workspace(&home.dir).display().to_string();
    let (author_pane, author) = {
        let daemon = DaemonGuard::start_with_script(&home.dir, "claude", ARGV_CLAUDE);
        ok_data(layout(
            &daemon.socket,
            "workspace/open",
            serde_json::json!({ "path": ws }),
            operator(),
            false,
        ));
        let spawned = json_of(&bench(
            &home.dir,
            &["spawn", "--agent", "claude", "--cwd", &ws],
        ));
        (
            spawned["pane"].as_str().unwrap().to_string(),
            spawned["runtime_session"].as_str().unwrap().to_string(),
        )
    };
    fake_transcript(&home.dir, &author);
    let _daemon = DaemonGuard::start_with_script(&home.dir, "claude", ARGV_CLAUDE);

    let run = bench(
        &home.dir,
        &[
            "spawn", "--agent", "claude", "--cwd", &ws, "--fork", &author,
        ],
    );
    assert_eq!(run.code, 0, "{}", run.stderr);
    let fork = json_of(&run);
    let (fork_sid, fork_id) = (
        fork["session"].as_str().unwrap().to_string(),
        fork["runtime_session"].as_str().unwrap().to_string(),
    );
    assert_ne!(fork_id, author, "a fork is a conversation of its own");
    assert_eq!(fork_id.len(), 36, "minted like any spawn's: {fork_id}");
    assert_eq!(fork["forked_from"], author.as_str());

    // What claude was asked to run: the author's conversation copied under the minted id, in
    // plan mode rather than the unattended posture.
    let argv = stub_argv(&home.dir, &fork_sid);
    let pos = |flag: &str| argv.iter().position(|a| a == flag);
    assert_eq!(argv[pos("--resume").unwrap() + 1], author, "{argv:?}");
    assert!(pos("--fork-session").is_some(), "{argv:?}");
    assert_eq!(argv[pos("--session-id").unwrap() + 1], fork_id, "{argv:?}");
    assert_eq!(
        argv[pos("--permission-mode").unwrap() + 1],
        "plan",
        "{argv:?}"
    );
    assert!(pos("--dangerously-skip-permissions").is_none(), "{argv:?}");

    // Every record names the fork's own conversation.
    assert_eq!(
        session_row(&home.dir, &fork_sid)["runtime_session"],
        fork_id.as_str()
    );
    assert_eq!(
        pane_agent(&home.dir, fork["pane"].as_str().unwrap())["session"],
        fork_id.as_str()
    );
    let events = fs::read_to_string(home.dir.join(".bench/events.jsonl")).unwrap();
    let spawned = events
        .lines()
        .map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap())
        .find(|e| e["kind"] == "session/spawned" && e["data"]["session"] == fork_sid.as_str())
        .expect("the fork's spawn is logged");
    assert_eq!(spawned["data"]["runtime_session"], fork_id.as_str());
    assert_eq!(spawned["data"]["forked_from"], author.as_str());
    assert_eq!(spawned["data"]["resumed"], false);

    // The author's pane comes back while the fork runs.
    let restored = json_of(&bench(&home.dir, &["restore", &author_pane]));
    assert_eq!(restored["restored"][0]["how"], "resumed", "{restored}");
    let author_sid = restored["restored"][0]["session"].as_str().unwrap();
    let author_argv = stub_argv(&home.dir, author_sid);
    assert!(
        author_argv.contains(&"--dangerously-skip-permissions".to_string()),
        "the author keeps its posture: {author_argv:?}"
    );

    // After another restart the fork comes back read-only, from benchd's record of it.
    drop(_daemon);
    fake_transcript(&home.dir, &fork_id);
    let _daemon = DaemonGuard::start_with_script(&home.dir, "claude", ARGV_CLAUDE);
    let again = json_of(&bench(
        &home.dir,
        &["restore", fork["pane"].as_str().unwrap()],
    ));
    assert_eq!(again["restored"][0]["how"], "resumed", "{again}");
    let argv = stub_argv(&home.dir, again["restored"][0]["session"].as_str().unwrap());
    assert_eq!(argv[..2], ["--permission-mode", "plan"], "{argv:?}");
    assert_eq!(
        argv[argv.iter().position(|a| a == "--resume").unwrap() + 1],
        fork_id
    );

    // And by any other route: a caller re-entering the fork by its id gets it read-only too.
    drop(_daemon);
    let _daemon = DaemonGuard::start_with_script(&home.dir, "claude", ARGV_CLAUDE);
    let resumed = bench(
        &home.dir,
        &[
            "spawn", "--agent", "claude", "--cwd", &ws, "--resume", &fork_id,
        ],
    );
    assert_eq!(resumed.code, 0, "{}", resumed.stderr);
    let argv = stub_argv(&home.dir, json_of(&resumed)["session"].as_str().unwrap());
    assert_eq!(argv[..2], ["--permission-mode", "plan"], "{argv:?}");
}

#[test]
fn a_fork_is_refused_where_it_cannot_run() {
    let home = TestHome::claim("fork-refused");
    let ws = workspace(&home.dir).display().to_string();
    let _daemon = DaemonGuard::start_with_fake(&home.dir, "claude");
    for (cmd, rule) in [
        (
            vec!["--agent", "claude", "--fork", "x1", "--resume", "x2"],
            "pass one of them",
        ),
        (
            vec!["--agent", "claude", "--fork", "--looks-like-a-flag"],
            "--fork",
        ),
    ] {
        let mut args = vec!["spawn", "--cwd", ws.as_str()];
        args.extend(cmd);
        let run = bench(&home.dir, &args);
        assert_eq!(run.code, 3, "{args:?}: {}", run.stderr);
        assert!(run.stderr.contains(rule), "{args:?}: {}", run.stderr);
    }
    let listed = json_of(&bench(&home.dir, &["sessions"]));
    assert_eq!(
        listed["sessions"],
        serde_json::json!([]),
        "nothing started: {listed}"
    );
}

#[test]
fn a_pi_fork_is_its_own_conversation_with_only_read_tools_and_comes_back_so() {
    // Harness parity G8/G9: pi forks with `--fork <id>` under the id benchd mints, and is
    // read-only with only its read tools, at spawn and after a restore.
    let home = TestHome::claim("pifork");
    let ws = workspace(&home.dir).display().to_string();
    let (fork_sid, fork_id, pane) = {
        let _daemon = DaemonGuard::start_with_script(&home.dir, "pi", ARGV_CLAUDE);
        let run = bench(
            &home.dir,
            &["spawn", "--agent", "pi", "--cwd", &ws, "--fork", "p-author"],
        );
        assert_eq!(run.code, 0, "{}", run.stderr);
        let fork = json_of(&run);
        assert_eq!(fork["forked_from"], "p-author");
        let fork_id = fork["runtime_session"].as_str().unwrap().to_string();
        assert_eq!(fork_id.len(), 36, "minted like any spawn's: {fork_id}");
        let sid = fork["session"].as_str().unwrap().to_string();
        let argv = stub_argv(&home.dir, &sid);
        let pos = |flag: &str| argv.iter().position(|a| a == flag);
        assert_eq!(argv[pos("--fork").unwrap() + 1], "p-author", "{argv:?}");
        assert_eq!(argv[pos("--session-id").unwrap() + 1], fork_id, "{argv:?}");
        assert_eq!(
            argv[pos("--tools").unwrap() + 1],
            "read,grep,find,ls",
            "{argv:?}"
        );
        (sid, fork_id, fork["pane"].as_str().unwrap().to_string())
    };
    let _daemon = DaemonGuard::start_with_script(&home.dir, "pi", ARGV_CLAUDE);
    let again = json_of(&bench(&home.dir, &["restore", &pane]));
    assert_eq!(again["restored"][0]["how"], "resumed", "{again}");
    let restored = again["restored"][0]["session"].as_str().unwrap();
    assert_ne!(restored, fork_sid);
    let argv = stub_argv(&home.dir, restored);
    assert_eq!(
        argv[..5],
        [
            "--approve",
            "--tools",
            "read,grep,find,ls",
            "--session-id",
            &fork_id
        ],
        "a restored pi fork is read-only again"
    );
    // Its answer was cut off like any other turn, so it is told to carry on.
    assert_eq!(argv.len(), 6, "{argv:?}");
    assert_resume_notice(&argv[5]);
}

#[test]
fn a_codex_fork_is_a_read_only_thread_and_comes_back_read_only() {
    // Harness parity G8/G9 on benchd's app-server (#466): the fork is `thread/fork` of the
    // author's thread in the read-only sandbox, its id known at spawn and recorded as a fork, and
    // the restored fork is re-entered read-only again.
    let home = TestHome::claim("cxfork");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let fake = FakeCodex::bind(h);
    let (bin, runs) = write_fake_codex(h);
    let pane = {
        let _daemon = codex_daemon(h, &bin);
        let fork = spawn_codex(h, &ws, &["--fork", "019a-author"]);
        assert_eq!(fork["forked_from"], "019a-author");
        let forked = &fake.asked("thread/fork", 1)[0];
        assert_eq!(forked["threadId"], "019a-author");
        assert_eq!(forked["sandbox"], "read-only");
        let thread = fork["runtime_session"].as_str().expect("known at spawn");
        let pane = fork["pane"].as_str().unwrap().to_string();
        assert_eq!(pane_agent(h, &pane)["session"], thread);
        (pane, thread.to_string())
    };
    let (pane, thread) = pane;
    let _daemon = codex_daemon(h, &bin);
    let again = json_of(&bench(h, &["restore", &pane]));
    assert_eq!(again["restored"][0]["how"], "resumed", "{again}");
    let restored = again["restored"][0]["session"].as_str().unwrap();
    assert_codex_resumed(h, &fake, &runs, restored, &thread, "read-only");
}

/// One workspace per project (#645): an agent spawned in a worktree, or in a folder of the main
/// checkout, shows in the repository's workspace, which the first spawn opens; it still runs where
/// it was spawned. A cwd spelled another way (here through macOS's `/var` symlink) finds the
/// workspace already open for that folder, whichever spelling opened it.
#[test]
fn agents_spawned_across_a_repositorys_worktrees_share_its_workspace() {
    let home = TestHome::claim("one-workspace");
    let daemon = DaemonGuard::start_with_fake_pi(&home.dir);
    let worktree = git_repo_with_worktree(&home.dir, "app");
    let repo = home.dir.join("app").canonicalize().unwrap();
    let repo_path = repo.display().to_string();
    fs::create_dir_all(home.dir.join("app/src")).unwrap();
    let spawn = |cwd: &Path| {
        let spawned = bench(
            &home.dir,
            &[
                "spawn",
                "--agent",
                "pi",
                "--cwd",
                &cwd.display().to_string(),
            ],
        );
        assert_eq!(spawned.code, 0, "{cwd:?}: {}", spawned.stderr);
        json_of(&spawned)
    };
    let open = || -> Vec<String> {
        document(&daemon.socket)["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| w["path"].as_str().unwrap().to_string())
            .collect()
    };

    let first = spawn(&worktree);
    assert_eq!(first["workspace"], repo_path.as_str(), "{first}");
    // Spelled as the test home is, not canonically: a second spelling of the main checkout.
    let second = spawn(&home.dir.join("app/src"));
    assert_eq!(second["workspace"], repo_path.as_str(), "{second}");
    assert_eq!(open(), [repo_path.as_str()]);
    // The workspace's session list has it too, however its cwd was spelled.
    let listed = json_of(&bench(
        &home.dir,
        &["sessions", "--all", "--workspace", &repo_path],
    ));
    assert!(
        listed["rows"]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["id"] == second["runtime_session"]),
        "{listed}"
    );

    // Only placement moved: the agent runs in the worktree.
    let pane = first["pane"].as_str().unwrap();
    let found = json_of(&bench(&home.dir, &["get", "pane", pane]));
    assert_eq!(found["pane"]["name"]["text"], "pi · wt", "{found}");

    // Outside git a folder is its own project, found under whichever spelling opened it.
    let notes = home.dir.join("notes");
    fs::create_dir_all(&notes).unwrap();
    let opened = layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": notes.display().to_string() }),
        operator(),
        false,
    );
    assert_eq!(opened["status"], "ok", "{opened}");
    let third = spawn(&notes.canonicalize().unwrap());
    let stray = notes.display().to_string();
    assert_eq!(third["workspace"], stray.as_str());
    assert_eq!(open().len(), 2, "{:?}", open());

    // A stray workspace folds into another: its last pane moves too, the emptied workspace goes,
    // and the agent in it keeps running. (Asked: the operator is in it.)
    let doc = document(&daemon.socket);
    let ids: Vec<String> = doc["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["path"] == stray.as_str())
        .unwrap()["bench"]["columns"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|c| c["slots"].as_array().unwrap().clone())
        .flat_map(|s| s["panes"].as_array().unwrap().clone())
        .map(|p| p["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(ids.len(), 2, "{doc}");
    for pane in &ids {
        let moved = bench(
            &home.dir,
            &["move", pane, "--workspace", &repo_path, "--asked"],
        );
        assert_eq!(moved.code, 0, "{}", moved.stderr);
    }
    assert_eq!(open(), [repo_path.as_str()]);
    let session = third["session"].as_str().unwrap();
    let listed = json_of(&bench(&home.dir, &["sessions"]));
    assert!(
        listed["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["session"] == session && s["live"] == true),
        "{listed}"
    );
}

/// `<home>/<name>`, a git repository with one commit and a linked worktree at
/// `.worktrees/wt`, made by git itself; answers the worktree.
fn git_repo_with_worktree(home: &Path, name: &str) -> PathBuf {
    let repo = home.join(name);
    fs::create_dir_all(&repo).unwrap();
    let repo = repo.canonicalize().unwrap();
    for args in [
        &["init", "-q"][..],
        &["commit", "-q", "--allow-empty", "-m", "x"],
        &["worktree", "add", "-q", ".worktrees/wt"],
    ] {
        let out = isolated("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t"])
            .args(args)
            .current_dir(&repo)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {out:?}");
    }
    repo.join(".worktrees/wt")
}

#[test]
fn a_canvas_names_the_conversation_that_opened_it_after_its_pane_moves_on() {
    // helm #535: a fork asked about a canvas must reach the conversation that wrote it. The
    // opener's pane record follows the agent: a `/clear` replaces it and an exit clears it.
    let home = TestHome::claim("author");
    let h = &home.dir;
    let ws = workspace(h).display().to_string();
    let page = artifact(h, "plan.md");
    let wrote = serde_json::json!({"command": "claude", "session": "c-4b1c", "cwd": "/tmp/work"});
    {
        let daemon = DaemonGuard::start(h, None);
        ok_data(layout(
            &daemon.socket,
            "workspace/open",
            serde_json::json!({ "path": ws }),
            operator(),
            false,
        ));
        let pane = json_of(&bench(h, &["open", "terminal"]))["pane"]
            .as_str()
            .unwrap()
            .to_string();
        let (_, pid) = terminal_process(h, "holder");
        let event = |event: &str, session: &str| {
            hook_verb(
                &daemon.socket,
                serde_json::json!({"harness": "claude", "event": event, "session": session,
                    "cwd": "/tmp/work", "pid": pid, "pane": pane}),
            )
        };
        event("SessionStart", "c-4b1c");
        assert_eq!(
            bench_as(h, &["open", &page], &[("HELM_PANE", &pane)]).code,
            0
        );
        let author = || canvas_pane(&document(&daemon.socket), &page)["author"].clone();
        assert_eq!(author(), wrote, "recorded with the opener");

        // `/clear`: the pane now holds a new, empty conversation.
        event("SessionStart", "c-9e0f");
        assert_eq!(pane_agent(h, &pane)["session"], "c-9e0f");
        assert_eq!(author(), wrote, "the canvas does not follow the pane");
        // The agent exits: the pane holds nothing.
        event("SessionEnd", "c-9e0f");
        assert!(pane_agent(h, &pane).is_null());
        assert_eq!(author(), wrote, "nor does an exit take it");
    }
    let daemon = DaemonGuard::start(h, None);
    assert_eq!(
        canvas_pane(&document(&daemon.socket), &page)["author"],
        wrote,
        "read back from bench.json"
    );
}

#[test]
fn a_fork_helm_asks_for_gets_its_prompt_as_a_file_and_leaves_focus_alone() {
    // helm #535: helm's "Ask a fork" sends the prompt as text, since helm may not share benchd's
    // disk, and as `helm`, so the fork appears without taking the operator's keyboard.
    let home = TestHome::claim("ask-fork");
    let h = &home.dir;
    let ws = workspace(h).display().to_string();
    let daemon = DaemonGuard::start_with_script(h, "claude", ARGV_CLAUDE);
    ok_data(layout(
        &daemon.socket,
        "workspace/open",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    let author = json_of(&bench(h, &["spawn", "--agent", "claude", "--cwd", &ws]));
    let author_id = author["runtime_session"].as_str().unwrap().to_string();
    let focused = document(&daemon.socket)["workspaces"][0]["bench"]["focused_slot"].clone();

    let prompt = "You are a fork.\n\n```text\nthe marked passage\n```\n\nWhy four retries?";
    let fork = ok_data(layout(
        &daemon.socket,
        "spawn",
        serde_json::json!({"agent": "claude", "cwd": ws, "fork": author_id, "prompt": prompt}),
        Some(serde_json::json!({ "kind": "helm" })),
        false,
    ));
    assert_eq!(fork["forked_from"], author_id.as_str());
    // helm decodes this answer from `fixtures/spawn-verbs.json`'s `fork_reply`: every key it
    // holds is one benchd answers.
    let fixture: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/spawn-verbs.json"),
        )
        .unwrap(),
    )
    .unwrap();
    for key in fixture["fork_reply"].as_object().unwrap().keys() {
        assert!(fork.get(key).is_some(), "benchd answers {key}: {fork}");
    }
    assert!(
        !focused.is_null() && !fork["focused_pane_before"].is_null(),
        "{fork}"
    );
    assert_eq!(
        fork["focused_pane_before"], fork["focused_pane_after"],
        "appear, don't seize: {fork}"
    );
    assert_eq!(
        document(&daemon.socket)["workspaces"][0]["bench"]["focused_slot"],
        focused
    );

    let argv = stub_argv(h, fork["session"].as_str().unwrap());
    let pos = |flag: &str| argv.iter().position(|a| a == flag);
    assert_eq!(argv[pos("--resume").unwrap() + 1], author_id, "{argv:?}");
    let pointer = argv.last().unwrap();
    let file = pointer
        .strip_prefix("Read and act on the prompt in ")
        .unwrap_or_else(|| panic!("the prompt is a file: {argv:?}"));
    let folder = Path::new(file).parent().unwrap();
    assert_eq!(
        folder.parent().unwrap(),
        h.join(".bench/prompts"),
        "a folder of its own under the root: {file}"
    );
    assert_eq!(fs::read_to_string(file).unwrap(), prompt);
    // Plan mode would ask before reading outside the cwd, so the prompt's folder is allowed.
    // Only that folder: another spawn's prompt stays out of reach.
    assert_eq!(
        argv[pos("--add-dir").unwrap() + 1],
        folder.display().to_string(),
        "{argv:?}"
    );
    let log = fs::read_to_string(h.join(".bench/events.jsonl")).unwrap();
    assert!(
        !log.contains("Why four retries?"),
        "the event log names the file, not the operator's words"
    );

    // Both at once is a refusal naming the rule; an empty prompt too.
    for extra in [
        serde_json::json!({"prompt": "x", "prompt_file": file}),
        serde_json::json!({"prompt": "  "}),
    ] {
        let mut args = serde_json::json!({"agent": "claude", "cwd": ws, "fork": author_id});
        args.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        let reply = layout(&daemon.socket, "spawn", args, None, false);
        assert_eq!(reply["status"], "refused", "{reply}");
    }
}

// ---------------------------------------------------------------------------
// M5c (#459): the browser pane's view onto the shared browser, relayed by benchd
// ---------------------------------------------------------------------------

/// One websocket frame from a server: unmasked, as the browser's debugging server sends them.
fn ws_frame(fin: bool, opcode: u8, payload: &[u8]) -> Vec<u8> {
    let mut f = vec![if fin { 0x80 } else { 0 } | opcode];
    match payload.len() {
        n if n < 126 => f.push(n as u8),
        n if n <= 0xFFFF => {
            f.push(126);
            f.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            f.push(127);
            f.extend_from_slice(&(n as u64).to_be_bytes());
        }
    }
    f.extend_from_slice(payload);
    f
}

/// A frame from benchd, which must mask it: `(opcode, unmasked payload)`.
fn ws_read(stream: &mut std::net::TcpStream) -> std::io::Result<(u8, Vec<u8>)> {
    let mut head = [0u8; 2];
    stream.read_exact(&mut head)?;
    assert_ne!(head[1] & 0x80, 0, "a client's frame is masked");
    let len = match head[1] & 0x7F {
        126 => {
            let mut n = [0u8; 2];
            stream.read_exact(&mut n)?;
            u64::from(u16::from_be_bytes(n))
        }
        127 => {
            let mut n = [0u8; 8];
            stream.read_exact(&mut n)?;
            u64::from_be_bytes(n)
        }
        n => u64::from(n),
    };
    let mut mask = [0u8; 4];
    stream.read_exact(&mut mask)?;
    let mut payload = vec![0u8; len as usize];
    stream.read_exact(&mut payload)?;
    for (i, b) in payload.iter_mut().enumerate() {
        *b ^= mask[i % 4];
    }
    Ok((head[0] & 0x0F, payload))
}

/// The browser's debugging server, played by the test: accepts one websocket upgrade and hands
/// the upgraded stream to `serve`, which returns what it saw.
fn fake_debugger<T: Send + 'static>(
    serve: impl FnOnce(std::net::TcpStream) -> T + Send + 'static,
) -> (u16, std::thread::JoinHandle<(String, T)>) {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let handle = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let mut head = Vec::new();
        let mut byte = [0u8; 1];
        while !head.ends_with(b"\r\n\r\n") {
            stream.read_exact(&mut byte).unwrap();
            head.push(byte[0]);
        }
        stream
            .write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: x\r\n\r\n")
            .unwrap();
        (String::from_utf8_lossy(&head).into_owned(), serve(stream))
    });
    (port, handle)
}

/// A benchd on TCP whose (fake) browser names `debugger` as its debugging port, started.
fn browser_over_tcp(name: &str, debugger: u16) -> (TestHome, u16, DaemonGuard) {
    let home = TestHome::claim(name);
    let fake = write_fake_browser(&home.dir);
    write_browser_config(
        &home.dir,
        serde_json::json!({ "binary": fake, "args": [format!("--fake-port={debugger}")] }),
    );
    let (daemon, port) = tcp_daemon(&home.dir);
    let started = bench(&home.dir, &["browser", "start"]);
    assert_eq!(started.code, 0, "{}", started.stderr);
    (home, port, daemon)
}

/// `browser/connect` over TCP, as helm's pane sends it, with `pipelined` written in the same
/// write right behind it: the answer line, and the connection.
fn browser_connect(
    port: u16,
    pipelined: &[u8],
) -> (serde_json::Value, BufReader<std::net::TcpStream>) {
    let stream = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect over TCP");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut request =
        b"{\"id\":\"helm-browser-1\",\"verb\":\"browser/connect\",\"by\":{\"kind\":\"helm\"}}\n"
            .to_vec();
    request.extend_from_slice(pipelined);
    (&stream).write_all(&request).unwrap();
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let answer = serde_json::from_str(&line).unwrap_or_else(|e| panic!("not JSON ({e}): {line}"));
    (answer, reader)
}

#[test]
fn browser_connect_relays_one_cdp_message_per_line_each_way_over_tcp() {
    let big = format!(
        "{{\"id\":2,\"result\":{{\"data\":\"{}\"}}}}",
        "a".repeat(200_000)
    );
    let sent_big = big.clone();
    let (debugger, server) = fake_debugger(move |mut stream| {
        let (op, first) = ws_read(&mut stream).unwrap();
        // A reply in two fragments with a ping between them and a raw newline as whitespace,
        // then a message too long for a 16-bit length, then the browser goes away.
        stream
            .write_all(&ws_frame(false, 0x1, b"{\"id\":1,\n"))
            .unwrap();
        stream
            .write_all(&ws_frame(true, 0x9, b"are you there"))
            .unwrap();
        stream
            .write_all(&ws_frame(true, 0x0, b"\"result\":{}}"))
            .unwrap();
        let pong = ws_read(&mut stream).unwrap();
        stream
            .write_all(&ws_frame(true, 0x1, sent_big.as_bytes()))
            .unwrap();
        stream.write_all(&ws_frame(true, 0x8, &[])).unwrap();
        (op, first, pong)
    });
    let (home, port, _daemon) = browser_over_tcp("m5c-cdp", debugger);

    // The first message rides in the same write as the request: it is relayed, not lost in the
    // buffer that read the request line.
    let (answer, mut relay) =
        browser_connect(port, b"{\"id\":1,\"method\":\"Target.getTargets\"}\n");
    assert_eq!(answer["status"], "ok", "{answer}");
    assert!(answer["data"]["pid"].as_u64().is_some(), "{answer}");
    let mut line = String::new();
    relay.read_line(&mut line).unwrap();
    assert_eq!(line, "{\"id\":1, \"result\":{}}\n", "one message, one line");
    line.clear();
    relay.read_line(&mut line).unwrap();
    assert_eq!(line.trim_end(), big);
    line.clear();
    assert_eq!(
        relay.read_line(&mut line).unwrap(),
        0,
        "the browser leaving ends the pane's connection"
    );

    let (head, (op, first, pong)) = server.join().unwrap();
    assert!(head.starts_with("GET /devtools/browser/fake-"), "{head}");
    assert!(head.contains("Upgrade: websocket"), "{head}");
    assert_eq!(op, 0x1, "a line goes to the browser as a text message");
    assert_eq!(first, b"{\"id\":1,\"method\":\"Target.getTargets\"}");
    assert_eq!(pong, (0xA, b"are you there".to_vec()), "a ping is answered");

    wait_until("the relay's end is logged", Duration::from_secs(5), || {
        event_kinds(&home.dir).iter().any(|(k, d)| {
            k == "browser/viewer-left" && d["why"] == "the browser closed the connection"
        })
    });
    let kinds = event_kinds(&home.dir);
    assert!(kinds.iter().any(|(k, _)| k == "browser/viewer-connected"));
    assert!(
        !fs::read_to_string(home.dir.join(".bench/events.jsonl"))
            .unwrap()
            .contains("Target.getTargets"),
        "what the pane and the browser say is never logged"
    );
}

#[test]
fn a_pane_that_leaves_closes_the_browser_side_and_no_browser_is_refused() {
    let (debugger, server) = fake_debugger(|mut stream| {
        let mut frames = Vec::new();
        while let Ok(frame) = ws_read(&mut stream) {
            let close = frame.0 == 0x8;
            frames.push(frame.0);
            if close {
                break;
            }
        }
        frames
    });
    let (home, port, _daemon) = browser_over_tcp("m5c-cdp-left", debugger);
    let (answer, relay) = browser_connect(port, b"");
    assert_eq!(answer["status"], "ok", "{answer}");
    drop(relay);
    let (_, frames) = server.join().unwrap();
    assert_eq!(frames, [0x8], "the browser is told the viewer went");
    wait_until(
        "the viewer's leaving is logged",
        Duration::from_secs(5),
        || {
            event_kinds(&home.dir)
                .iter()
                .any(|(k, d)| k == "browser/viewer-left" && d["why"] == "the viewer left")
        },
    );

    // With the browser stopped there is nothing to connect to, and the refusal says what to do.
    assert_eq!(bench(&home.dir, &["browser", "stop"]).code, 0);
    let (answer, _) = browser_connect(port, b"");
    assert_eq!(answer["status"], "refused", "{answer}");
    assert!(
        answer["reason"]
            .as_str()
            .unwrap()
            .starts_with("no shared browser is running"),
        "{answer}"
    );
}

// ---------------------------------------------------------------------------
// M5c: helm's git and archon, run on benchd's machine (`command/run`, `path/exists`,
// `git/repositories`)
// ---------------------------------------------------------------------------

/// A TCP daemon whose PATH holds only the system's and Homebrew's folders: never the operator's
/// `~/.bun/bin`, so the only `archon` it can find is a test's stub in its own `HOME`.
fn tcp_daemon_with_system_path(home: &Path) -> (DaemonGuard, u16) {
    tcp_daemon_from(home, None, |cmd| {
        cmd.env("PATH", "/usr/bin:/bin:/opt/homebrew/bin");
    })
}

fn command_run(port: u16, command: serde_json::Value, timeout_ms: u64) -> serde_json::Value {
    tcp_verb(
        port,
        "command/run",
        serde_json::json!({ "command": command, "timeout_ms": timeout_ms }),
    )
}

/// An `exited` answer's (status, stdout, stderr).
fn exited(answer: &serde_json::Value) -> (i64, String, String) {
    let data = ok(answer);
    assert_eq!(data["kind"], "exited", "{answer}");
    let text = |key: &str| {
        String::from_utf8(bench_wire::unbase64(data[key].as_str().unwrap()).unwrap()).unwrap()
    };
    (
        data["status"].as_i64().unwrap(),
        text("stdout"),
        text("stderr"),
    )
}

fn test_git(args: &[&str], dir: &Path) {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.com")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.com")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// `<home>/Projects/app` on `main`, with a worktree `merged-one` at main's tip and a worktree
/// `feature` one commit ahead of it.
fn repo_with_worktrees(home: &Path) -> PathBuf {
    let app = home.join("Projects/app");
    fs::create_dir_all(&app).unwrap();
    let app = app.canonicalize().unwrap();
    test_git(&["init", "-q", "-b", "main"], &app);
    fs::write(app.join("a.txt"), "a").unwrap();
    test_git(&["add", "."], &app);
    test_git(&["commit", "-q", "-m", "first"], &app);
    test_git(
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "merged-one",
            ".worktrees/merged-one",
        ],
        &app,
    );
    test_git(
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "feature",
            ".worktrees/feature",
        ],
        &app,
    );
    let feature = app.join(".worktrees/feature");
    fs::write(feature.join("b.txt"), "b").unwrap();
    test_git(&["add", "."], &feature);
    test_git(&["commit", "-q", "-m", "unmerged"], &feature);
    app
}

/// What the Worktrees drawer's delete leans on, through benchd over TCP: git's own answers come
/// back exactly, a "no" included. `merge-base --is-ancestor` says an unmerged branch is not in
/// main with status 1 — an answer, not a refusal — and helm stops before `branch -D` on it; a
/// merged one says 0. Uncommitted work shows in `status --porcelain`, and `worktree remove`
/// without `--force` refuses a dirty worktree with git's words.
#[test]
fn command_run_over_tcp_answers_gits_own_status_and_output() {
    let home = TestHome::claim("m5c-git");
    let (_daemon, port) = tcp_daemon_with_system_path(&home.dir);
    let app = repo_with_worktrees(&home.dir);
    let common = app.join(".git").display().to_string();
    let git = |args: &[&str]| {
        exited(&command_run(
            port,
            serde_json::json!({ "program": "git", "args": args }),
            20_000,
        ))
    };

    let (status, listing, _) = git(&["-C", &common, "worktree", "list", "--porcelain"]);
    assert_eq!(status, 0);
    assert!(listing.contains("branch refs/heads/feature"), "{listing}");
    assert_eq!(
        git(&[
            "-C",
            &common,
            "merge-base",
            "--is-ancestor",
            "feature",
            "main"
        ])
        .0,
        1
    );
    assert_eq!(
        git(&[
            "-C",
            &common,
            "merge-base",
            "--is-ancestor",
            "merged-one",
            "main"
        ])
        .0,
        0
    );

    let feature = app.join(".worktrees/feature");
    fs::write(feature.join("new.txt"), "work").unwrap();
    let path = feature.display().to_string();
    let (_, dirty, _) = git(&["--no-optional-locks", "-C", &path, "status", "--porcelain"]);
    assert_eq!(dirty.lines().count(), 1, "{dirty}");
    let (status, _, stderr) = git(&["-C", &common, "worktree", "remove", &path]);
    assert_ne!(status, 0, "a dirty worktree is not removed without --force");
    assert!(
        stderr.contains("untracked"),
        "git's own words come back: {stderr}"
    );
    assert!(feature.join("new.txt").exists());

    // A working directory and a failure that is git's, not benchd's.
    let (status, branch, _) = exited(&command_run(
        port,
        serde_json::json!({ "program": "git", "args": ["branch", "--show-current"], "cwd": app }),
        10_000,
    ));
    assert_eq!((status, branch.as_str()), (0, "main\n"));
    let (status, _, stderr) = git(&["-C", &home.dir.display().to_string(), "status"]);
    assert_eq!(status, 128);
    assert!(stderr.contains("not a git repository"), "{stderr}");
}

/// `archon` is found in benchd's own `~/.bun/bin`, runs in the named directory with that folder
/// first on its PATH (it is a bun script), and gets `ARCHON_HOME` when asked. What benchd cannot
/// start is a refusal naming why; a slow run is killed at its deadline; and a run that leaves a
/// background child holding its stdout (`--detach`) is still answered at once.
#[test]
fn command_run_over_tcp_finds_archon_in_benchds_home_and_keeps_its_deadline() {
    let home = TestHome::claim("m5c-archon");
    let (_daemon, port) = tcp_daemon_with_system_path(&home.dir);
    let work = home.dir.join("work");
    fs::create_dir_all(&work).unwrap();
    let work = work.canonicalize().unwrap();
    let archon = |args: &[&str], extra: serde_json::Value, timeout_ms| {
        let mut command = serde_json::json!({ "program": "archon", "args": args, "cwd": work });
        if let Some(home) = extra.get("home") {
            command["home"] = home.clone();
        }
        command_run(port, command, timeout_ms)
    };

    // Not installed on benchd's machine: refused, naming where it looked.
    let missing = archon(
        &["workflow", "runs", "--json"],
        serde_json::json!({}),
        5_000,
    );
    assert_eq!(missing["status"], "refused", "{missing}");
    let why = missing["reason"].as_str().unwrap();
    assert!(
        why.contains("archon is not installed") && why.contains(".bun/bin"),
        "{why}"
    );

    let bun = home.dir.join(".bun/bin");
    fs::create_dir_all(&bun).unwrap();
    let stub = bun.join("archon");
    fs::write(
        &stub,
        "#!/bin/sh\ncase \"$1\" in\n  slow) exec sleep 5 ;;\n  detach) sleep 2 & echo started; exit 0 ;;\nesac\n\
         printf '%s|%s|%s|%s\\n' \"$PWD\" \"${ARCHON_HOME:-none}\" \"${PATH%%:*}\" \"$*\"\nexit 3\n",
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();

    let (status, out, _) = exited(&archon(
        &["complete", "archon/task-x"],
        serde_json::json!({ "home": "/archon/home" }),
        5_000,
    ));
    assert_eq!(status, 3, "a nonzero exit is an answer");
    assert_eq!(
        out,
        format!(
            "{}|/archon/home|{}|complete archon/task-x\n",
            work.display(),
            bun.display()
        )
    );

    let started = Instant::now();
    let slow = archon(&["slow"], serde_json::json!({}), 300);
    assert_eq!(ok(&slow)["kind"], "timed_out", "{slow}");
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "killed at its deadline"
    );

    let started = Instant::now();
    let (status, out, _) = exited(&archon(&["detach"], serde_json::json!({}), 5_000));
    assert_eq!((status, out.as_str()), (0, "started\n"));
    assert!(
        started.elapsed() < Duration::from_millis(1500),
        "a background child holding stdout does not hold the answer"
    );

    // Refused before anything runs: a directory that is not one, a program that is not allowed.
    let nowhere = command_run(
        port,
        serde_json::json!({ "program": "git", "args": ["status"], "cwd": work.join("gone") }),
        5_000,
    );
    assert_eq!(nowhere["status"], "refused", "{nowhere}");
    let shell = command_run(
        port,
        serde_json::json!({ "program": "sh", "args": ["-c", "true"] }),
        5_000,
    );
    assert_eq!(shell["status"], "refused", "{shell}");
}

/// `path/exists` and `git/repositories` read benchd's disk and benchd's home, over TCP.
#[test]
fn path_exists_and_git_repositories_over_tcp_read_benchds_disk() {
    let home = TestHome::claim("m5c-repos");
    let (_daemon, port) = tcp_daemon_with_system_path(&home.dir);
    let app = repo_with_worktrees(&home.dir);
    let feature = app.join(".worktrees/feature").display().to_string();
    let gone = app.join(".worktrees/gone").display().to_string();

    let answer = tcp_verb(
        port,
        "path/exists",
        serde_json::json!({ "paths": [feature, gone] }),
    );
    assert_eq!(ok(&answer)["existing"], serde_json::json!([feature]));

    let found = tcp_verb(
        port,
        "git/repositories",
        serde_json::json!({ "workspaces": [feature] }),
    );
    assert_eq!(
        ok(&found)["repositories"],
        serde_json::json!([{ "common_dir": app.join(".git"), "is_workspace": true }])
    );
}

// ---------------------------------------------------------------------------
// M5c (#459): prp's stores and typed paths, answered on benchd's machine
// ---------------------------------------------------------------------------

/// prp's canonical store resolver, copied verbatim from the block every prp skill carries
/// (`prp-plan/SKILL.md`, "PRP store resolver"), with a `cd` before it and a `printf` after. Run in
/// `folder` with `home` as HOME and `prp_home` as PRP_HOME, it prints `PRP_DIR`, creating it as the
/// skills do. A copy, because prp is another repo: when prp changes its block, change this and
/// `benchd/src/prp.rs` together.
const CANONICAL_RESOLVER: &str = r#"cd "$1" || exit 1
_gd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
case "$_gd" in */.git) _root="${_gd%/.git}" ;; "") _root="$PWD" ;; *) _root="$_gd" ;; esac
_root="$(cd "$_root" && pwd -P)"
_name="$(basename "$_root" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')"
_home="${PRP_HOME:-$HOME/.prp}"
_hit="$(grep -lsF "\"path\": \"$_root\"" "$_home"/*/project.json 2>/dev/null | head -1)"
PRP_DIR="${_hit%/project.json}"
[ -n "$PRP_DIR" ] || PRP_DIR="$_home/${_name:-project}-$(printf %s "$_root" | git hash-object --stdin | cut -c1-8)"
mkdir -p "$PRP_DIR"; [ -f "$PRP_DIR/project.json" ] || printf '{"path": "%s", "name": "%s"}\n' "$_root" "${_name:-project}" > "$PRP_DIR/project.json"
printf %s "$PRP_DIR""#;

fn canonical_store(folder: &Path, home: &Path, prp_home: Option<&Path>) -> PathBuf {
    let mut cmd = isolated("/bin/sh");
    cmd.args(["-c", CANONICAL_RESOLVER, "sh"])
        .arg(folder)
        .env("HOME", home)
        .env("GIT_CONFIG_GLOBAL", "/dev/null");
    if let Some(prp_home) = prp_home {
        cmd.env("PRP_HOME", prp_home);
    }
    let out = cmd.output().unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    PathBuf::from(String::from_utf8(out.stdout).unwrap())
}

fn git_in(dir: &Path, args: &[&str]) {
    let status = isolated("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

/// A repository `Main Repo` with one commit and a worktree of it, and a folder that is no repo
/// with a name prp's slug has to work at, all canonical.
fn prp_folders(home: &Path) -> (PathBuf, PathBuf, PathBuf) {
    let work = home.join("work");
    let main = work.join("Main Repo");
    let plain = work.join("-Plain__Ünïcøde-");
    fs::create_dir_all(&main).unwrap();
    fs::create_dir_all(&plain).unwrap();
    git_in(&main, &["init", "-q"]);
    git_in(
        &main,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "x",
        ],
    );
    let worktree = work.join("wt");
    git_in(
        &main,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "wt",
            worktree.to_str().unwrap(),
        ],
    );
    let c = |p: PathBuf| p.canonicalize().unwrap();
    (c(main), c(worktree), c(plain))
}

fn note(port: u16, workspace: &Path) -> PathBuf {
    let answer = tcp_verb(
        port,
        "prp/note",
        serde_json::json!({ "workspace": workspace, "day": "2026-09-30" }),
    );
    PathBuf::from(ok(&answer)["path"].as_str().unwrap())
}

/// ⌘⇧N's note lands in the store prp's own resolver picks on benchd's machine: a plain folder is
/// its own root, a worktree shares its main checkout's store, a new store is registered with
/// prp's exact bytes, and a second note of the day does not overwrite the first.
#[test]
fn prp_note_lands_in_the_store_the_canonical_resolver_picks() {
    let home = TestHome::claim("m5c-prp-note");
    let (_daemon, port) = tcp_daemon(&home.dir);
    let (main, worktree, plain) = prp_folders(&home.dir);
    let prp_home = home.dir.join(".prp");
    let sub = main.join("sub");
    fs::create_dir_all(&sub).unwrap();

    for (n, folder) in [&main, &worktree, &plain, &sub].into_iter().enumerate() {
        // What the block keys this folder as, in a home of its own so nothing is adopted.
        let reference = home.dir.join(format!("reference-{n}"));
        let key = canonical_store(folder, &home.dir, Some(&reference));
        let path = note(port, folder);
        let store = path.parent().unwrap().parent().unwrap();
        assert_eq!(store.file_name(), key.file_name(), "{}", folder.display());
        assert_eq!(store.parent().unwrap(), prp_home);
        assert_eq!(path.parent().unwrap().file_name().unwrap(), "notes");
        assert_eq!(fs::read(&path).unwrap(), b"", "a note starts empty");
        // The block run against benchd's home adopts the store benchd registered.
        assert_eq!(canonical_store(folder, &home.dir, None), store);
        assert_eq!(
            fs::read(store.join("project.json")).unwrap(),
            fs::read(key.join("project.json")).unwrap(),
            "registered with prp's own bytes"
        );
    }
    // The main checkout, its worktree and a folder inside it are one project and one store.
    let main_note = note(port, &main);
    assert!(
        main_note.ends_with("notes/2026-09-30-note-4.md"),
        "{}",
        main_note.display()
    );
    assert!(note(port, &plain).ends_with("notes/2026-09-30-note-2.md"));
}

#[test]
fn prp_note_adopts_a_registration_and_refuses_what_it_cannot_key() {
    let home = TestHome::claim("m5c-prp-adopt");
    let (_daemon, port) = tcp_daemon(&home.dir);
    let (main, worktree, _) = prp_folders(&home.dir);
    let custom = home.dir.join(".prp/custom-name");
    fs::create_dir_all(&custom).unwrap();
    let registration = format!("{{\"path\": \"{}\", \"name\": \"mine\"}}\n", main.display());
    fs::write(custom.join("project.json"), &registration).unwrap();

    assert!(note(port, &worktree).starts_with(custom.join("notes")));
    assert_eq!(
        fs::read_to_string(custom.join("project.json")).unwrap(),
        registration
    );

    let refused = |args| {
        let answer = tcp_verb(port, "prp/note", args);
        assert_eq!(answer["status"], "refused", "{answer}");
        answer["reason"].as_str().unwrap().to_string()
    };
    let gone = home.dir.join("gone");
    assert!(
        refused(serde_json::json!({ "workspace": gone, "day": "2026-09-30" }))
            .contains("no folder")
    );
    refused(serde_json::json!({ "workspace": main, "day": "../../x" }));
    refused(serde_json::json!({ "workspace": "relative", "day": "2026-09-30" }));
    assert!(!gone.exists());
}

/// ⌘O's listing: the stores under benchd's prp home, the workspace's among them (a worktree
/// included), and a store's renderable files at every depth, newest first.
#[test]
fn prp_stores_and_artifacts_list_benchds_home() {
    let home = TestHome::claim("m5c-prp-list");
    let (_daemon, port) = tcp_daemon(&home.dir);
    let (main, worktree, plain) = prp_folders(&home.dir);
    let prp = home.dir.join(".prp");
    let store = |key: &str, json: &str| {
        let dir = prp.join(key);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("project.json"), json).unwrap();
        dir
    };
    let helm = store(
        "helm-1",
        &format!("{{\"path\": \"{}\", \"name\": \"Zeta\"}}\n", main.display()),
    );
    store("alpha", "{}");
    store(".hidden", "{}");
    fs::create_dir_all(prp.join("not-a-store")).unwrap();

    let stores = |args| ok(&tcp_verb(port, "prp/stores", args)).clone();
    let all = stores(serde_json::json!({}));
    let names: Vec<_> = all["stores"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["name"].clone())
        .collect();
    assert_eq!(names, ["alpha", "Zeta"], "{all}");
    assert_eq!(all["stores"][1]["path"], main.display().to_string());
    assert!(all["workspace"].is_null());
    assert_eq!(
        stores(serde_json::json!({ "workspace": worktree }))["workspace"],
        "helm-1"
    );
    assert!(stores(serde_json::json!({ "workspace": plain }))["workspace"].is_null());
    assert_eq!(
        fs::read_dir(&prp).unwrap().count(),
        4,
        "asking created nothing"
    );

    fs::create_dir_all(helm.join("plans/completed")).unwrap();
    let file = |rel: &str, age: u64| {
        let path = helm.join(rel);
        fs::write(&path, "x").unwrap();
        let when = std::time::SystemTime::now() - Duration::from_secs(age);
        fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_modified(when)
            .unwrap();
    };
    file("plans/a.plan.md", 30);
    file("plans/completed/old.plan.md", 300);
    file("canvas.html", 10);
    file("data.json", 1);
    file("plans/.draft.md", 1);
    std::os::unix::fs::symlink(prp.join("alpha"), helm.join("linked")).unwrap();
    fs::write(prp.join("alpha/hidden-by-link.md"), "x").unwrap();

    let listed = ok(&tcp_verb(
        port,
        "prp/artifacts",
        serde_json::json!({ "store": "helm-1" }),
    ))
    .clone();
    let relative: Vec<_> = listed["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["relative"].clone())
        .collect();
    assert_eq!(
        relative,
        [
            "canvas.html",
            "plans/a.plan.md",
            "plans/completed/old.plan.md"
        ],
        "{listed}"
    );
    assert_eq!(
        listed["files"][0]["path"],
        helm.join("canvas.html").display().to_string()
    );
    for store in ["nope", "../helm-1", ".hidden", "not-a-store"] {
        let answer = tcp_verb(port, "prp/artifacts", serde_json::json!({ "store": store }));
        assert_eq!(answer["status"], "refused", "{store}: {answer}");
    }
}

/// ⇧⌘O's typed path: `~` is benchd's home, not the client's, and nothing there is a refusal.
#[test]
fn path_resolve_expands_against_benchds_home() {
    let home = TestHome::claim("m5c-path");
    let (_daemon, port) = tcp_daemon(&home.dir);
    fs::create_dir_all(home.dir.join("proj/sub")).unwrap();
    fs::write(home.dir.join("proj/plan.md"), "x").unwrap();
    let resolve = |path: &str| tcp_verb(port, "path/resolve", serde_json::json!({ "path": path }));
    let h = home.dir.display().to_string();

    let dir = ok(&resolve("~/proj/sub/../")).clone();
    assert_eq!(
        dir,
        serde_json::json!({ "path": format!("{h}/proj"), "kind": "directory" })
    );
    let file = ok(&resolve(&format!("{h}/proj/plan.md"))).clone();
    assert_eq!(file["kind"], "file");
    assert_eq!(ok(&resolve("~"))["path"], h);
    for bad in ["~/proj/gone", "proj", "~root/x"] {
        assert_eq!(resolve(bad)["status"], "refused", "{bad}");
    }
    assert!(
        resolve("~/proj/gone")["reason"]
            .as_str()
            .unwrap()
            .contains(&format!("{h}/proj/gone"))
    );
}

// ---------------------------------------------------------------------------
// Attention (M1, #357): done-not-seen, its addressee, mail to the operator, `bench watch`
// ---------------------------------------------------------------------------

/// A Claude hook event from the agent in benchd session `bench`, whose conversation is `id`.
fn claude_turn(socket: &Path, bench: &str, pid: u32, id: &str, event: &str) {
    claude_turn_in(socket, bench, pid, id, event, "/tmp");
}

fn claude_turn_in(socket: &Path, bench: &str, pid: u32, id: &str, event: &str, cwd: &str) {
    hook_verb(
        socket,
        serde_json::json!({ "harness": "claude", "event": event, "session": id,
            "cwd": cwd, "pid": pid, "bench_session": bench }),
    );
}

/// The operator focuses a pane, the way a click in helm does.
fn operator_shows(socket: &Path, pane: &str) {
    ok_data(layout(
        socket,
        "pane/show",
        serde_json::json!({ "pane": pane }),
        operator(),
        false,
    ));
}

/// pi, whose own turn end is `agent_settled`: the case the drawer's row has to show too, since a
/// pi reports nothing anywhere but its hook.
#[test]
fn a_finished_turn_is_done_until_the_operator_looks() {
    let home = TestHome::claim("m1-done");
    let h = &home.dir;
    let daemon = scripted_pi_daemon(h, "#!/bin/sh\nexec sleep 60\n");
    let ws = workspace(h).display().to_string();
    let run = bench(
        h,
        &["spawn", "--agent", "pi", "--cwd", &ws, "--name", "worker"],
    );
    assert_eq!(run.code, 0, "{}", run.stderr);
    let spawned = json_of(&run);
    let sid = spawned["session"].as_str().unwrap().to_string();
    let pane = spawned["pane"].as_str().unwrap().to_string();
    let conv = spawned["runtime_session"].as_str().unwrap().to_string();
    let pid = spawned["pid"].as_u64().unwrap() as u32;
    let other = bench(
        h,
        &[
            "spawn",
            "--agent",
            "test-echo",
            "--cwd",
            &ws,
            "--name",
            "other",
        ],
    );
    assert_eq!(other.code, 0, "{}", other.stderr);
    let elsewhere = json_of(&other)["pane"].as_str().unwrap().to_string();
    // An agent's spawn never takes focus: the operator opens the workspace himself.
    ok_data(layout(
        &daemon.socket,
        "workspace/activate",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    operator_shows(&daemon.socket, &elsewhere);
    let turn = |event: &str| {
        hook_verb(
            &daemon.socket,
            serde_json::json!({ "harness": "pi", "event": event, "session": conv,
                "cwd": ws, "pid": pid, "bench_session": sid }),
        );
    };
    turn("session_start");
    turn("agent_start");
    assert!(live_entry(h, &sid)["done"].is_null(), "working is not done");

    turn("agent_settled");
    let done = live_entry(h, &sid)["done"].clone();
    assert_eq!(done["to"], "operator", "{done}");
    assert_eq!(done["seen"], false, "{done}");
    // The drawer's row says the same.
    let all = json_of(&bench(h, &["sessions", "--all", "--workspace", &ws]));
    let row = all["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == conv.as_str());
    assert_eq!(row.map(|r| r["done"].clone()), Some(done.clone()), "{all}");

    // Looking at it clears it; looking away again does not bring it back.
    operator_shows(&daemon.socket, &pane);
    let seen = live_entry(h, &sid)["done"].clone();
    assert_eq!(seen["seen"], true, "{seen}");
    assert_eq!(seen["since_ms"], done["since_ms"]);
    operator_shows(&daemon.socket, &elsewhere);
    assert_eq!(live_entry(h, &sid)["done"]["seen"], true);
    let looked = event_kinds(h)
        .into_iter()
        .filter(|(k, _)| k == "sessions/seen")
        .count();
    assert_eq!(looked, 1, "seen once: the second focus cleared nothing");

    // A new turn is no longer done; one that ends in front of him is seen at once.
    turn("agent_start");
    assert!(live_entry(h, &sid)["done"].is_null());
    operator_shows(&daemon.socket, &pane);
    turn("agent_settled");
    assert_eq!(live_entry(h, &sid)["done"]["seen"], true);
}

#[test]
fn a_codex_on_benchds_server_is_done_and_waiting_by_its_typed_events_not_its_hooks() {
    // #357 slice 3: benchd's one connection to its codex app-server hears every thread's typed
    // events, and they, not codex's hooks, say what a codex does: attention and `bench watch`
    // see it exactly as they see Claude.
    let home = TestHome::claim("m1-codex");
    let h = &home.dir;
    let ws = workspace(h);
    trust_codex(h, &[&ws]);
    let fake = FakeCodex::bind(h);
    let (bin, _) = write_fake_codex(h);
    let daemon = codex_daemon(h, &bin);
    let spawned = spawn_codex(h, &ws, &["--name", "cx"]);
    let (sid, thread) = (
        spawned["session"].as_str().unwrap().to_string(),
        spawned["runtime_session"].as_str().unwrap().to_string(),
    );
    let cwd = ws.display().to_string();
    let note = |method: &str, params: serde_json::Value| {
        let mut params = params;
        params["threadId"] = serde_json::json!(thread);
        fake.notify(serde_json::json!({"method": method, "params": params}));
    };
    let status =
        |s: serde_json::Value| note("thread/status/changed", serde_json::json!({ "status": s }));
    let ended = |how: &str| {
        note(
            "turn/completed",
            serde_json::json!({"turn": {"id": "t1", "status": how}}),
        )
    };
    let entry = || live_entry(h, &sid);
    let settle = |what: &str, ok: &dyn Fn(&serde_json::Value) -> bool| {
        wait_until(what, Duration::from_secs(5), || ok(&entry()));
    };

    // Waiting on an approval, then working again.
    status(serde_json::json!({"type": "active", "activeFlags": ["waitingOnApproval"]}));
    settle("waiting on the approval", &|e| {
        e["waiting"]["waiting_for"] == "permission prompt"
    });
    status(serde_json::json!({"type": "active", "activeFlags": []}));
    settle("working again", &|e| e["waiting"].is_null());
    status(serde_json::json!({"type": "active", "activeFlags": ["waitingOnUserInput"]}));
    settle("waiting on a question", &|e| {
        e["waiting"]["waiting_for"] == "question"
    });
    status(serde_json::json!({"type": "active", "activeFlags": []}));
    settle("working again", &|e| e["waiting"].is_null());

    // Its hooks no longer say it: a Stop or a permission prompt from the hook changes nothing.
    codex_hook(&daemon, "PermissionRequest", &thread, &cwd);
    codex_hook(&daemon, "Stop", &thread, &cwd);
    let e = entry();
    assert!(e["waiting"].is_null() && e["done"].is_null(), "{e}");

    // The turn completes: done, for whoever spawned it, and a watch wakes on it.
    let waiter = watch(h, &["cx", "--timeout", "20"]);
    std::thread::sleep(Duration::from_millis(500));
    ended("completed");
    let (code, out) = watched(waiter);
    assert_eq!((code, out["outcome"].clone()), (0, "done".into()), "{out}");
    settle("done for the operator", &|e| e["done"]["to"] == "operator");

    // A new turn is not done; one the operator interrupts ends idle, not done.
    note("turn/started", serde_json::json!({"turn": {"id": "t2"}}));
    settle("working", &|e| e["done"].is_null());
    ended("interrupted");
    settle("idle after the interrupt", &|e| {
        e["report"]["activity"]["kind"] == "idle"
    });
    assert!(
        entry()["done"].is_null(),
        "an interrupted turn is not a finished one"
    );
}

#[test]
fn a_pi_question_waits_on_the_operator_and_its_settle_is_done() {
    // pi's own events reach the same projection as Claude's and codex's: `ui_prompt_start` waits,
    // `ui_prompt_end` works again, `agent_settled` is done.
    let home = TestHome::claim("m1-piwait");
    let h = &home.dir;
    let daemon = scripted_pi_daemon(h, "#!/bin/sh\nexec sleep 60\n");
    let ws = workspace(h).display().to_string();
    let run = bench(h, &["spawn", "--agent", "pi", "--cwd", &ws, "--name", "pw"]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    let spawned = json_of(&run);
    let sid = spawned["session"].as_str().unwrap().to_string();
    let conv = spawned["runtime_session"].as_str().unwrap().to_string();
    let pid = spawned["pid"].as_u64().unwrap() as u32;
    let turn = |event: &str| {
        hook_verb(
            &daemon.socket,
            serde_json::json!({ "harness": "pi", "event": event, "session": conv,
                "cwd": ws, "pid": pid, "bench_session": sid }),
        );
    };
    turn("session_start");
    turn("agent_start");
    turn("ui_prompt_start");
    let e = live_entry(h, &sid);
    assert_eq!(e["waiting"]["waiting_for"], "question", "{e}");
    assert_eq!(e["waiting"]["source"], "hook", "{e}");
    turn("ui_prompt_end");
    assert!(live_entry(h, &sid)["waiting"].is_null());
    turn("agent_settled");
    assert_eq!(live_entry(h, &sid)["done"]["to"], "operator");
}

#[test]
fn done_goes_to_the_agent_that_spawned_it_and_survives_a_restart() {
    let home = TestHome::claim("m1-spawner");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let run = bench_as(
        h,
        &[
            "spawn",
            "--agent",
            "test-echo",
            "--cwd",
            "/tmp",
            "--name",
            "worker",
        ],
        &[("BENCH_HANDLE", "orch")],
    );
    assert_eq!(run.code, 0, "{}", run.stderr);
    let spawned = json_of(&run);
    let (sid, pid) = (
        spawned["session"].as_str().unwrap().to_string(),
        spawned["pid"].as_u64().unwrap() as u32,
    );
    let conv = "2d0e3f4a-5b6c-4d7e-8f9a-1b2c3d4e5f6a";
    for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
        claude_turn(&daemon.socket, &sid, pid, conv, event);
    }
    let done = live_entry(h, &sid)["done"].clone();
    assert_eq!(
        (done["to"].clone(), done["seen"].clone()),
        ("orch".into(), false.into()),
        "{done}"
    );
    let spawned_event = event_kinds(h)
        .into_iter()
        .find(|(k, _)| k == "session/spawned")
        .unwrap();
    assert_eq!(
        spawned_event.1["spawner"],
        serde_json::json!({ "kind": "agent", "handle": "orch" }),
        "{:?}",
        spawned_event.1
    );
    // The operator's own spawn is his.
    let (mine, mine_pid) = terminal_process(h, "mine");
    let conv2 = "3e1f4a5b-6c7d-4e8f-9a0b-2c3d4e5f6a7b";
    for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
        claude_turn(&daemon.socket, &mine, mine_pid, conv2, event);
    }
    assert_eq!(live_entry(h, &mine)["done"]["to"], "operator");

    // A restart ends every session; the conversation resumed in a new one is still done, still
    // the orchestrator's, still not seen.
    drop(daemon);
    let daemon = DaemonGuard::start(h, None);
    let (again, again_pid) = terminal_process(h, "worker");
    claude_turn(&daemon.socket, &again, again_pid, conv, "SessionStart");
    let resumed = live_entry(h, &again)["done"].clone();
    assert_eq!(resumed, done, "the record kept it across the restart");
}

#[test]
fn mail_to_the_operator_shows_on_its_senders_session_until_read() {
    let home = TestHome::claim("m1-mail");
    let h = &home.dir;
    let _daemon = DaemonGuard::start(h, None);
    let (sid, _) = terminal_process(h, "reporter");
    assert!(live_entry(h, &sid)["operator_mail"].is_null());
    for subject in ["reporter: blocked", "reporter: still blocked"] {
        let sent = bench(
            h,
            &[
                "mail",
                "send",
                "--from",
                "reporter",
                "--to",
                "operator",
                "--subject",
                subject,
                "--body",
                "x",
            ],
        );
        assert_eq!(sent.code, 0, "{}", sent.stderr);
        std::thread::sleep(Duration::from_millis(20));
    }
    let mail = live_entry(h, &sid)["operator_mail"].clone();
    assert_eq!(mail["unread"], 2, "{mail}");
    assert_eq!(mail["subject"], "reporter: blocked", "the oldest: {mail}");
    // Mail between agents is not the operator's.
    let other = bench(
        h,
        &[
            "mail", "send", "--from", "reporter", "--to", "someone", "--body", "x",
        ],
    );
    assert_eq!(other.code, 0);
    assert_eq!(live_entry(h, &sid)["operator_mail"]["unread"], 2);
    let listed = json_of(&bench(h, &["mail", "list", "--handle", "operator"]));
    for m in listed["mail"].as_array().unwrap() {
        let id = m["id"].as_str().unwrap();
        assert_eq!(
            bench(h, &["mail", "read", id, "--handle", "operator"]).code,
            0
        );
    }
    assert!(
        live_entry(h, &sid)["operator_mail"].is_null(),
        "read is not unread"
    );
}

#[test]
fn marking_seen_clears_done_and_closes_nothing() {
    let home = TestHome::claim("m1-seen");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (sid, pid) = terminal_process(h, "worker");
    let conv = "4f2a5b6c-7d8e-4f9a-0b1c-3d4e5f6a7b8c";
    for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
        claude_turn(&daemon.socket, &sid, pid, conv, event);
    }
    let before = live_entry(h, &sid);
    let unknown = bench(h, &["sessions", "seen", "nobody", "--harness", "claude"]);
    assert_eq!(unknown.code, 3, "{}", unknown.stderr);
    // Seen is the operator's: an agent marks it only when he asked.
    let unasked = bench(h, &["sessions", "seen", conv, "--harness", "claude"]);
    assert_eq!(unasked.code, 3, "{}", unasked.stderr);
    assert_eq!(live_entry(h, &sid)["done"]["seen"], false);
    let marked = bench(
        h,
        &["sessions", "seen", conv, "--harness", "claude", "--asked"],
    );
    assert_eq!(marked.code, 0, "{}", marked.stderr);
    let after = live_entry(h, &sid);
    assert_eq!(after["done"]["seen"], true, "{after}");
    // The session, its pane and its record entry are all still there.
    assert_eq!(
        (after["live"].clone(), after["pane"].clone()),
        (true.into(), before["pane"].clone())
    );
    let record = hosted_record(&h.join(".bench"));
    assert!(
        record["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["id"] == conv)
    );
    let kinds: Vec<String> = event_kinds(h).into_iter().map(|(k, _)| k).collect();
    assert!(kinds.contains(&"sessions/seen".to_string()), "{kinds:?}");
    // A turn the operator interrupts is not a finished one.
    claude_turn(&daemon.socket, &sid, pid, conv, "UserPromptSubmit");
    claude_turn(&daemon.socket, &sid, pid, conv, "Interrupt");
    assert!(live_entry(h, &sid)["done"].is_null());
    assert!(
        !kinds
            .iter()
            .any(|k| k == "session/closed" || k == "sessions/dismissed"),
        "{kinds:?}"
    );
}

/// `bench watch <handle>` as an orchestrator runs it: a child process, read when it exits.
fn watch(home: &Path, args: &[&str]) -> Child {
    let mut cmd = isolated(bench_bin());
    cmd.env("HOME", home)
        .arg("watch")
        .args(args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    cmd.spawn().expect("spawn bench watch")
}

fn watched(child: Child) -> (i32, serde_json::Value) {
    let out = child.wait_with_output().unwrap();
    let line = String::from_utf8_lossy(&out.stdout).to_string();
    let value = serde_json::from_str(line.trim()).unwrap_or(serde_json::Value::Null);
    (out.status.code().unwrap_or(-1), value)
}

#[test]
fn watch_wakes_on_a_turn_end_and_a_wait_and_gives_up_at_its_timeout() {
    let home = TestHome::claim("m1-watch");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (sid, pid) = terminal_process(h, "watched");
    let conv = "5a3b6c7d-8e9f-4a0b-1c2d-4e5f6a7b8c9d";
    // A session that has only started is idle with no turn: not an answer.
    let fresh = watch(h, &["watched", "--timeout", "2"]);
    std::thread::sleep(Duration::from_millis(300));
    claude_turn(&daemon.socket, &sid, pid, conv, "SessionStart");
    let (code, out) = watched(fresh);
    assert_eq!(
        (code, out["outcome"].clone()),
        (3, "timeout".into()),
        "{out}"
    );
    claude_turn(&daemon.socket, &sid, pid, conv, "UserPromptSubmit");
    let (code, out) = watched(watch(h, &["watched", "--timeout", "1"]));
    assert_eq!(
        (code, out["outcome"].clone()),
        (3, "timeout".into()),
        "{out}"
    );

    let waiter = watch(h, &["watched", "--timeout", "20"]);
    std::thread::sleep(Duration::from_millis(300));
    claude_turn(&daemon.socket, &sid, pid, conv, "Stop");
    let (code, out) = watched(waiter);
    assert_eq!((code, out["outcome"].clone()), (0, "done".into()), "{out}");
    let since = out["session"]["done"]["since_ms"].as_u64().unwrap();
    // The turn it already answered does not answer again; a wait does.
    let after = since.to_string();
    let (code, out) = watched(watch(h, &["watched", "--timeout", "1", "--after", &after]));
    assert_eq!(
        (code, out["outcome"].clone()),
        (3, "timeout".into()),
        "{out}"
    );
    let waiter = watch(h, &["watched", "--timeout", "20", "--after", &after]);
    claude_turn(&daemon.socket, &sid, pid, conv, "UserPromptSubmit");
    hook_verb(
        &daemon.socket,
        serde_json::json!({ "harness": "claude", "event": "PermissionRequest", "session": conv,
            "cwd": "/tmp", "pid": pid, "bench_session": sid, "tool": "Bash" }),
    );
    let (code, out) = watched(waiter);
    assert_eq!(
        (code, out["outcome"].clone()),
        (0, "waiting".into()),
        "{out}"
    );
    // A turn that fails ends with no `Stop`, and no done: the watch still wakes, as idle.
    claude_turn(&daemon.socket, &sid, pid, conv, "PostToolUse");
    let waiter = watch(h, &["watched", "--timeout", "20"]);
    std::thread::sleep(Duration::from_millis(1200));
    claude_turn(&daemon.socket, &sid, pid, conv, "StopFailure");
    let (code, out) = watched(waiter);
    assert_eq!((code, out["outcome"].clone()), (0, "idle".into()), "{out}");
    // However short: a turn that starts and fails back to back, with no pause for a poll.
    let waiter = watch(h, &["watched", "--timeout", "20"]);
    std::thread::sleep(Duration::from_millis(500));
    claude_turn(&daemon.socket, &sid, pid, conv, "UserPromptSubmit");
    claude_turn(&daemon.socket, &sid, pid, conv, "StopFailure");
    let (code, out) = watched(waiter);
    assert_eq!((code, out["outcome"].clone()), (0, "idle".into()), "{out}");
    // A handle nobody has is refused, not waited on.
    let (code, _) = watched(watch(h, &["nobody", "--timeout", "1"]));
    assert_eq!(code, 3);
    // A session closed under the watch has ended, though it has left the list.
    claude_turn(&daemon.socket, &sid, pid, conv, "UserPromptSubmit");
    let waiter = watch(h, &["watched", "--timeout", "20"]);
    std::thread::sleep(Duration::from_millis(1500));
    let closed = bench(h, &["close", &sid]);
    assert_eq!(closed.code, 0, "{}", closed.stderr);
    let (code, out) = watched(waiter);
    assert_eq!((code, out["outcome"].clone()), (0, "ended".into()), "{out}");
}

/// An agent the operator started in a pane has no `BENCH_HANDLE`: its spawn names only the pane,
/// and the spawner is whoever holds that pane's mailbox. The operator typing in a shell there is
/// nobody's agent.
#[test]
fn a_pane_agent_s_spawn_is_addressed_to_the_mailbox_in_that_pane() {
    let home = TestHome::claim("m1-panespawn");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let spawn_from_pane = |name: &str| {
        let run = bench_as(
            h,
            &[
                "spawn",
                "--agent",
                "test-echo",
                "--cwd",
                "/tmp",
                "--name",
                name,
            ],
            &[("HELM_PANE", HOOK_PANE)],
        );
        assert_eq!(run.code, 0, "{}", run.stderr);
        json_of(&run)
    };
    let before = spawn_from_pane("before");
    let (_, tty_pid) = terminal_process(h, "holder");
    let claimed = hook_verb(
        &daemon.socket,
        serde_json::json!({ "harness": "claude", "event": "SessionStart",
            "session": "6b4c7d8e-9f0a-4b1c-2d3e-5f6a7b8c9d0e", "cwd": "/Users/op/Projects/helm",
            "pid": tty_pid, "pane": HOOK_PANE }),
    );
    let orchestrator = claimed["handle"].as_str().unwrap().to_string();
    let after = spawn_from_pane("after");
    let spawners: Vec<(String, serde_json::Value)> = event_kinds(h)
        .into_iter()
        .filter(|(k, d)| k == "session/spawned" && d["handle"] != "holder")
        .map(|(_, d)| {
            (
                d["session"].as_str().unwrap().to_string(),
                d["spawner"].clone(),
            )
        })
        .collect();
    assert_eq!(
        spawners,
        [
            (
                before["session"].as_str().unwrap().to_string(),
                serde_json::json!({ "kind": "operator" })
            ),
            (
                after["session"].as_str().unwrap().to_string(),
                serde_json::json!({ "kind": "agent", "handle": orchestrator })
            ),
        ]
    );
}

/// A conversation spawned again (`--resume`) by another agent is that agent's from then on.
#[test]
fn a_resume_by_another_agent_readdresses_its_done() {
    let home = TestHome::claim("m1-respawn");
    let h = &home.dir;
    let daemon = scripted_pi_daemon(h, "#!/bin/sh\nexec sleep 60\n");
    let ws = workspace(h).display().to_string();
    let spawn_as = |who: &str, args: &[&str]| {
        let mut all = vec!["spawn", "--agent", "pi", "--cwd", ws.as_str()];
        all.extend_from_slice(args);
        let run = bench_as(h, &all, &[("BENCH_HANDLE", who)]);
        assert_eq!(run.code, 0, "{}", run.stderr);
        json_of(&run)
    };
    let settle = |spawned: &serde_json::Value, conv: &str| {
        for event in ["session_start", "agent_start", "agent_settled"] {
            hook_verb(
                &daemon.socket,
                serde_json::json!({ "harness": "pi", "event": event, "session": conv, "cwd": ws,
                    "pid": spawned["pid"], "bench_session": spawned["session"] }),
            );
        }
        live_entry(h, spawned["session"].as_str().unwrap())["done"]["to"].clone()
    };
    let first = spawn_as("orch-a", &["--name", "first"]);
    let conv = first["runtime_session"].as_str().unwrap().to_string();
    assert_eq!(settle(&first, &conv), "orch-a");
    // A closed pi says so on its way out.
    hook_verb(
        &daemon.socket,
        serde_json::json!({ "harness": "pi", "event": "session_shutdown", "session": conv,
            "cwd": ws, "pid": first["pid"], "bench_session": first["session"] }),
    );
    let closed = bench(h, &["close", first["session"].as_str().unwrap()]);
    assert_eq!(closed.code, 0, "{}", closed.stderr);
    wait_until("the first session is gone", Duration::from_secs(10), || {
        let list = json_of(&bench(h, &["sessions"]));
        !list["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["session"] == first["session"] && s["live"] == true)
    });
    let again = spawn_as("orch-b", &["--name", "again", "--resume", &conv]);
    assert_eq!(settle(&again, &conv), "orch-b");
    // The drawer's row names its spawner too, beside its own handle.
    let all = json_of(&bench(h, &["sessions", "--all", "--workspace", &ws]));
    let row = all["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == conv.as_str());
    let row = row.unwrap_or_else(|| panic!("no row: {all}"));
    assert_eq!(
        (row["spawner"].clone(), row["mail"]["handle"].clone()),
        (
            serde_json::json!({ "kind": "agent", "handle": "orch-b" }),
            "again".into()
        ),
        "{row}"
    );
    assert!(
        event_kinds(h)
            .iter()
            .any(|(k, d)| k == "sessions/spawner" && d["spawner"]["handle"] == "orch-b"),
        "the readdress is logged"
    );
}

/// A Claude's `sessions` report is its registry row when it has one, which can lag a hook (a turn
/// it has not caught up with yet) and can change with no hook at all (Esc). The watch judges
/// working and idle from that report alone.
#[test]
fn watch_reads_claude_s_registry_row_for_a_turn_no_hook_ends() {
    let home = TestHome::claim("m1-watch-reg");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let (sid, pid) = terminal_process(h, "clauded");
    let conv = "7c5d8e9f-0a1b-4c2d-3e4f-6a7b8c9d0e1f";
    let started = bench_sessions::process::started_at_secs(pid).unwrap() * 1000;
    let row = |status: &str, at: u64| {
        let path = h.join(format!(".claude/sessions/{pid}.json"));
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            serde_json::json!({"pid": pid, "sessionId": conv, "cwd": "/tmp", "startedAt": started,
                "status": status, "statusUpdatedAt": at})
            .to_string(),
        )
        .unwrap();
    };
    // A row that first appears after the hooks, idle and older than the work they announced,
    // ends nothing.
    claude_turn(&daemon.socket, &sid, pid, conv, "SessionStart");
    claude_turn(&daemon.socket, &sid, pid, conv, "UserPromptSubmit");
    let late = watch(h, &["clauded", "--timeout", "3"]);
    std::thread::sleep(Duration::from_millis(800));
    row("idle", started + 10);
    let (code, out) = watched(late);
    assert_eq!(
        (code, out["outcome"].clone()),
        (3, "timeout".into()),
        "{out}"
    );
    // The hook says a turn began; the row has not caught up: not an answer.
    let lagging = watch(h, &["clauded", "--timeout", "3"]);
    std::thread::sleep(Duration::from_millis(800));
    claude_turn(&daemon.socket, &sid, pid, conv, "UserPromptSubmit");
    let (code, out) = watched(lagging);
    assert_eq!(
        (code, out["outcome"].clone()),
        (3, "timeout".into()),
        "{out}"
    );
    // Esc: the row goes idle and no hook says so.
    row("busy", started + 20);
    let esc = watch(h, &["clauded", "--timeout", "20"]);
    std::thread::sleep(Duration::from_millis(1500));
    row("idle", started + 30);
    let (code, out) = watched(esc);
    assert_eq!((code, out["outcome"].clone()), (0, "idle".into()), "{out}");
}

/// ⌘⇧J walks everything that needs the operator, in his list's order: asking, then a finished
/// turn he has not seen, then mail to him. Arriving at the finished one sees it, and the walk
/// goes on from its place.
#[test]
fn focus_waiting_walks_asking_then_finished_then_mail() {
    let home = TestHome::claim("m1-walk");
    let h = &home.dir;
    let daemon = DaemonGuard::start(h, None);
    let ws = workspace(h).display().to_string();
    let pane_of = |name: &str| {
        let run = bench(
            h,
            &[
                "spawn",
                "--agent",
                "test-echo",
                "--cwd",
                &ws,
                "--name",
                name,
            ],
        );
        assert_eq!(run.code, 0, "{}", run.stderr);
        let v = json_of(&run);
        let ids = |k: &str| v[k].as_str().unwrap().to_string();
        (
            ids("session"),
            v["pid"].as_u64().unwrap() as u32,
            ids("pane"),
        )
    };
    let (asking, asking_pid, asking_pane) = pane_of("asking");
    let (finished, finished_pid, finished_pane) = pane_of("finished");
    let (_, _, mail_pane) = pane_of("mailer");
    let hook = |sid: &str, pid: u32, conv: &str, event: &str| {
        hook_verb(
            &daemon.socket,
            serde_json::json!({ "harness": "claude", "event": event, "session": conv,
                "cwd": ws, "pid": pid, "bench_session": sid, "tool": "Bash" }),
        );
    };
    for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
        hook(
            &finished,
            finished_pid,
            "8d6e9f0a-1b2c-4d3e-4f5a-7b8c9d0e1f2a",
            event,
        );
    }
    for event in ["SessionStart", "PermissionRequest"] {
        hook(
            &asking,
            asking_pid,
            "9e7f0a1b-2c3d-4e4f-5a6b-8c9d0e1f2a3b",
            event,
        );
    }
    let sent = bench(
        h,
        &[
            "mail", "send", "--from", "mailer", "--to", "operator", "--body", "x",
        ],
    );
    assert_eq!(sent.code, 0, "{}", sent.stderr);
    ok_data(layout(
        &daemon.socket,
        "workspace/activate",
        serde_json::json!({ "path": ws }),
        operator(),
        false,
    ));
    // From the asking pane: the finished one, the mail, round to the asking one, then the mail,
    // since arriving at the finished one saw it.
    operator_shows(&daemon.socket, &asking_pane);
    let mut visited = Vec::new();
    for _ in 0..4 {
        let data = ok_data(layout(
            &daemon.socket,
            "focus/waiting",
            serde_json::json!({}),
            operator(),
            false,
        ));
        visited.push(data["pane"].as_str().unwrap().to_string());
    }
    assert_eq!(
        visited,
        [finished_pane, mail_pane.clone(), asking_pane, mail_pane]
    );
}

/// The flake in `a_client_with_only_a_url_reaches_benchd_over_tcp`, with the race lost on purpose:
/// `free_port` lets go of the port it found, and under the full gate another test can take it
/// before benchd binds. benchd then rightly refuses to start (`serve_tcp`), so a helper that hands
/// it a port it no longer holds must try another.
#[test]
fn a_tcp_daemon_whose_port_was_taken_starts_on_another() {
    let home = TestHome::claim("m5c-taken");
    let taken = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let held = taken.local_addr().unwrap().port();
    let (_daemon, port) = tcp_daemon_from(&home.dir, Some(held), |_| {});
    assert_ne!(
        port, held,
        "it moved on rather than waiting out its deadline"
    );
    let status = bench_as(
        &home.dir,
        &["status"],
        &[("BENCH_URL", format!("tcp://127.0.0.1:{port}").as_str())],
    );
    assert_eq!(status.code, 0, "{}", status.stderr);
}

/// `BENCH_LISTEN` is benchd's own: a session it spawns never inherits it, or a test benchd an
/// agent starts from that session would try to bind the operator's address (and refuse to start).
#[test]
fn a_spawned_session_does_not_inherit_bench_listen() {
    let home = TestHome::claim("m5c-listen");
    let out = home.dir.join("agent-env.txt");
    let bin = write_agent_script(
        &home.dir,
        "pi",
        &format!(
            "env > '{}.tmp' && mv '{0}.tmp' '{0}'\nexec sleep 60",
            out.display()
        ),
    );
    let path = std::env::var("PATH").unwrap_or_default();
    let (_daemon, port) = tcp_daemon_from(&home.dir, None, |cmd| {
        cmd.env("PATH", format!("{}:{path}", bin.display()));
    });
    let ws = workspace(&home.dir).display().to_string();
    let run = bench(&home.dir, &["spawn", "--agent", "pi", "--cwd", &ws]);
    assert_eq!(run.code, 0, "{}", run.stderr);
    wait_until(
        "the agent wrote its environment",
        Duration::from_secs(10),
        || out.exists(),
    );
    let env = fs::read_to_string(&out).unwrap();
    assert!(
        env.contains("BENCH_SESSION="),
        "the agent's own variables are there: {env}"
    );
    assert!(
        !env.lines().any(|l| l.starts_with("BENCH_LISTEN=")),
        "benchd's tcp address 127.0.0.1:{port} reached its child: {env}"
    );
}
