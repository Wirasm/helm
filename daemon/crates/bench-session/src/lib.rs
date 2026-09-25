//! The pty core — M5a's substance, built directly on what the spikes proved
//! (`daemon/spikes/`): a headless process can own ptys hosting full interactive agent
//! TUIs, deliver prompts paste-then-submit, and re-enter session state from outside.
//!
//! This crate knows runtimes and ptys; it knows nothing about sockets, verbs, or the
//! event log — the daemon composes those. Everything an incident already paid for is
//! carried as code:
//!
//! - **Postures are helm's `SpoolUnattendedPolicy`, plus the model/effort columns the
//!   model-selection spike proved.** A posture removes a prompt; it never withholds
//!   capability (helm #179).
//! - **The agent allowlist is the security line** (helm `SpoolPolicy`): a spawn request
//!   arrives over a socket, and `sh` in a login shell is what an ungated spawn would be.
//! - **Prompts travel by file, never argv** (helm #93) — and are pasted, then submitted
//!   separately (helm's launch-line rule; bracketed-paste measurement).
//! - **Runtime session ids are minted at spawn, never inferred later** — the
//!   session-state spike grabbed a live session that was not ours by inferring; minting
//!   is what makes `resume` a lookup instead of a guess.
//! - **Close is drain-then-die**: SIGKILL races the transcript write (session-state
//!   spike), so a close is a term, a grace, then the kill.
//! - **The reader never stops draining the master** — an undrained pty blocks the agent
//!   on write (pty spike).

use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Ring capacity per session: enough scrollback for an attach to land mid-thought,
/// small enough that fifty sessions are a footnote. The cap is reported to an attacher
/// via `replayed`, never silent.
pub const RING_CAPACITY: usize = 256 * 1024;

/// The environment gate for the conformance-test agent. Real deployments never set it;
/// CI has no claude/codex/pi, and the relay's byte-fidelity still has to be proven
/// against a REAL spawned process — `/bin/cat` echoes what it is sent, which is exactly
/// the oracle a relay test needs.
pub const TEST_AGENT_ENV: &str = "BENCH_SESSION_TEST_AGENT";

// ---------------------------------------------------------------------------
// Agents and their argv
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentKind {
    Claude,
    Codex,
    Pi,
    /// `/bin/cat`, admitted only when `BENCH_SESSION_TEST_AGENT=1` — the conformance
    /// suite's echo oracle, refused everywhere else.
    TestEcho,
}

impl AgentKind {
    pub fn parse(raw: &str, test_agent_allowed: bool) -> Result<AgentKind, String> {
        match raw {
            "claude" => Ok(AgentKind::Claude),
            "codex" => Ok(AgentKind::Codex),
            "pi" => Ok(AgentKind::Pi),
            "test-echo" if test_agent_allowed => Ok(AgentKind::TestEcho),
            other => Err(format!(
                "agent {other:?} is not on the allowlist — this bench spawns: claude, codex, pi"
            )),
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            AgentKind::Claude => "claude",
            AgentKind::Codex => "codex",
            AgentKind::Pi => "pi",
            AgentKind::TestEcho => "test-echo",
        }
    }

    /// Whether this runtime can mint its session identity at spawn — the property that
    /// makes `resume` a lookup. codex names its own sessions after the fact, so resume
    /// for it is refused with the reason rather than guessed at (session-state spike).
    pub fn mints_session_id(&self) -> bool {
        matches!(self, AgentKind::Claude | AgentKind::Pi)
    }
}

/// What a spawn (or resume — `resume_from` set) wants. Pure data; `argv()` is the one
/// spelling of every posture/model/effort/resume flag, unit-tested per runtime.
#[derive(Debug, Clone)]
pub struct SpawnSpec {
    pub agent: AgentKind,
    pub cwd: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    /// The runtime session id this bench minted (claude, pi) — present on spawn for
    /// minting runtimes, and on resume naming what to re-enter.
    pub runtime_session: Option<String>,
    pub resume: bool,
}

/// The single spelling of how each runtime is started unattended. Postures verbatim
/// from helm's `SpoolUnattendedPolicy`; model/effort flags verbatim from the
/// model-selection spike; resume flags from the session-state spike.
pub fn argv(spec: &SpawnSpec) -> Result<(String, Vec<String>), String> {
    let mut args: Vec<String> = Vec::new();
    let program = match spec.agent {
        AgentKind::Claude => {
            args.push("--dangerously-skip-permissions".into());
            if let Some(m) = &spec.model {
                args.extend(["--model".into(), m.clone()]);
            }
            if let Some(e) = &spec.effort {
                args.extend(["--effort".into(), e.clone()]);
            }
            match (&spec.runtime_session, spec.resume) {
                (Some(id), false) => args.extend(["--session-id".into(), id.clone()]),
                (Some(id), true) => args.extend(["--resume".into(), id.clone()]),
                (None, false) => {}
                (None, true) => return Err("claude resume needs the minted session id".into()),
            }
            "claude"
        }
        AgentKind::Codex => {
            if spec.resume {
                return Err(
                    "codex names its own sessions after the fact; resume is not supported for it yet — spawn fresh, or use claude/pi where the bench mints the id"
                        .into(),
                );
            }
            args.push("--dangerously-bypass-approvals-and-sandbox".into());
            // No modals: nobody is at an unattended pane to answer one, so the next pasted
            // Return does. Both measured. The update prompt: the brief's Return accepted
            // "Update now" and the pane ran `brew upgrade --cask codex` and quit (0.155.1).
            // The rate-limit nudge: raised after a turn near the weekly limit, with "Switch
            // to <cheaper model>" as the default a mail wake would select (0.157.0).
            args.extend([
                "-c".into(),
                "check_for_update_on_startup=false".into(),
                "-c".into(),
                "notice.hide_rate_limit_model_nudge=true".into(),
            ]);
            if let Some(m) = &spec.model {
                args.extend(["-m".into(), m.clone()]);
            }
            if let Some(e) = &spec.effort {
                args.extend(["-c".into(), format!("model_reasoning_effort={e}")]);
            }
            "codex"
        }
        AgentKind::Pi => {
            args.push("--approve".into());
            if let Some(m) = &spec.model {
                // pi carries thinking as a `:<level>` suffix on the model — one flag,
                // measured working in the model-selection spike.
                let model = match &spec.effort {
                    Some(e) => format!("{m}:{e}"),
                    None => m.clone(),
                };
                args.extend(["--model".into(), model]);
            } else if let Some(e) = &spec.effort {
                args.extend(["--thinking".into(), e.clone()]);
            }
            // --session-id creates when missing and re-enters when present, so spawn
            // and resume are the same flag (session-state spike).
            if let Some(id) = &spec.runtime_session {
                args.extend(["--session-id".into(), id.clone()]);
            } else if spec.resume {
                return Err("pi resume needs the minted session id".into());
            }
            "pi"
        }
        AgentKind::TestEcho => {
            if spec.resume {
                return Err("the test agent has no sessions to resume".into());
            }
            "/bin/cat"
        }
    };
    Ok((program.to_string(), args))
}

/// Mint a runtime session id. `uuidgen` where present; a /dev/urandom-derived v4 shape
/// otherwise. Never inferred after the fact — that is the spike's hard-won rule.
pub fn mint_session_id() -> String {
    if let Ok(out) = std::process::Command::new("uuidgen").output() {
        let s = String::from_utf8_lossy(&out.stdout).trim().to_lowercase();
        if s.len() == 36 {
            return s;
        }
    }
    let mut bytes = [0u8; 16];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut bytes);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let h: Vec<String> = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}{}{}{}-{}{}-{}{}-{}{}-{}{}{}{}{}{}",
        h[0],
        h[1],
        h[2],
        h[3],
        h[4],
        h[5],
        h[6],
        h[7],
        h[8],
        h[9],
        h[10],
        h[11],
        h[12],
        h[13],
        h[14],
        h[15]
    )
}

/// claude's footer under `--dangerously-skip-permissions`: once it is drawn, the TUI
/// accepts a paste.
const CLAUDE_READY_MARKER: &str = "bypass permissions";

/// Whether `marker` is on screen in raw pty output. Escape sequences and whitespace are
/// dropped from both sides first: a renderer that places each word with a cursor move
/// (claude's inline renderer does, measured on 2.1.282) draws the phrase without ever
/// writing it contiguously. An OSC's payload (a window title, say) is not on screen.
fn shows_marker(bytes: &[u8], marker: &str) -> bool {
    let mut drawn = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            0x1b => {
                i += 1;
                match bytes.get(i) {
                    // CSI: parameters, then one final byte in @..~.
                    Some(b'[') => {
                        i += 1;
                        while i < bytes.len() && !(0x40..=0x7e).contains(&bytes[i]) {
                            i += 1;
                        }
                    }
                    // OSC: up to BEL or ST (ESC \).
                    Some(b']') => {
                        while i < bytes.len() && bytes[i] != 0x07 {
                            if bytes[i] == 0x1b && bytes.get(i + 1) == Some(&b'\\') {
                                i += 1;
                                break;
                            }
                            i += 1;
                        }
                    }
                    // Any other escape is ESC plus one byte.
                    _ => {}
                }
                i += 1;
            }
            b if b.is_ascii_whitespace() => i += 1,
            b => {
                drawn.push(b);
                i += 1;
            }
        }
    }
    let wanted: Vec<u8> = marker
        .bytes()
        .filter(|b| !b.is_ascii_whitespace())
        .collect();
    drawn.windows(wanted.len()).any(|w| w == wanted.as_slice())
}

// ---------------------------------------------------------------------------
// The live session
// ---------------------------------------------------------------------------

/// What the reader thread reports upward. The daemon logs these — bench-visible means
/// logged, and the exit of a session is exactly the kind of fact the log exists for.
#[derive(Debug)]
pub enum Notice {
    Exited { session: String },
    Detached { session: String },
}

struct Ring {
    bytes: VecDeque<u8>,
    total: u64,
    last_change: Instant,
}

impl Ring {
    fn push(&mut self, chunk: &[u8]) {
        self.total += chunk.len() as u64;
        self.last_change = Instant::now();
        for &b in chunk {
            if self.bytes.len() == RING_CAPACITY {
                self.bytes.pop_front();
            }
            self.bytes.push_back(b);
        }
    }
}

pub struct Session {
    pub id: String,
    /// The mailbox address and human name for this session — `--name` at spawn, else
    /// the session id. Uniqueness and the `operator` reservation are the daemon's to
    /// enforce; this crate just carries the decided value.
    pub handle: String,
    pub spec: SpawnSpec,
    pub agent: AgentKind,
    pub cwd: String,
    pub pid: Option<u32>,
    pub runtime_session: Option<String>,
    pub spawned_at: Instant,
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    child: Arc<Mutex<Box<dyn Child + Send + Sync>>>,
    ring: Arc<Mutex<Ring>>,
    /// dtach-grade: at most one attached client. A new attach REPLACES the old one —
    /// reconnect-after-drop is the common case, and "already attached" refusals would
    /// strand every dropped connection until a timeout nothing owns. The generation is
    /// what makes replacement safe: a replaced connection's pump thread wakes on the
    /// shutdown and must clear ONLY the attachment it owned — clearing blindly tears
    /// down the newcomer (found by the takeover conformance test, not by review).
    attached: Arc<Mutex<Option<(u64, UnixStream)>>>,
    attach_gen: AtomicU64,
    exited: Arc<AtomicBool>,
}

impl Session {
    /// Spawn the agent into a fresh pty and start the drain thread. `notices` is how
    /// exits and forced detaches reach the daemon's log.
    pub fn spawn(
        id: String,
        handle: String,
        spec: &SpawnSpec,
        rows: u16,
        cols: u16,
        extra_env: &[(String, String)],
        notices: Sender<Notice>,
    ) -> Result<Arc<Session>, String> {
        let (program, args) = argv(spec)?;
        let pty = native_pty_system();
        let pair = pty
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| format!("openpty: {e}"))?;
        let mut cmd = CommandBuilder::new(&program);
        for a in &args {
            cmd.arg(a);
        }
        cmd.cwd(&spec.cwd);
        cmd.env("TERM", "xterm-256color");
        // The session learns its own address and root — what lets an agent inside run
        // `bench mail send` with no flags and land in the right mailroom (the same
        // declare-don't-derive rule as helm's PaneEnvironment).
        for (k, v) in extra_env {
            cmd.env(k, v);
        }
        let child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| format!("spawn {program}: {e}"))?;
        drop(pair.slave);

        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| format!("clone reader: {e}"))?;
        let writer = pair
            .master
            .take_writer()
            .map_err(|e| format!("take writer: {e}"))?;

        let session = Arc::new(Session {
            pid: child.process_id(),
            handle,
            spec: spec.clone(),
            id: id.clone(),
            agent: spec.agent,
            cwd: spec.cwd.clone(),
            runtime_session: spec.runtime_session.clone(),
            spawned_at: Instant::now(),
            master: Mutex::new(pair.master),
            writer: Mutex::new(writer),
            child: Arc::new(Mutex::new(child)),
            ring: Arc::new(Mutex::new(Ring {
                bytes: VecDeque::with_capacity(8192),
                total: 0,
                last_change: Instant::now(),
            })),
            attached: Arc::new(Mutex::new(None)),
            attach_gen: AtomicU64::new(0),
            exited: Arc::new(AtomicBool::new(false)),
        });

        // The drain thread: the pty owner's first duty. It also carries live output to
        // the attached client, byte-for-byte — escape sequences included, which is what
        // lets an OSC ride the relay into whatever terminal hosts `bench attach`.
        {
            let ring = Arc::clone(&session.ring);
            let attached = Arc::clone(&session.attached);
            let exited = Arc::clone(&session.exited);
            let child = Arc::clone(&session.child);
            std::thread::spawn(move || {
                let mut chunk = [0u8; 8192];
                loop {
                    match reader.read(&mut chunk) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            ring.lock().unwrap().push(&chunk[..n]);
                            let mut guard = attached.lock().unwrap();
                            if let Some((_, stream)) = guard.as_mut()
                                && stream.write_all(&chunk[..n]).is_err()
                            {
                                let _ = stream.shutdown(std::net::Shutdown::Both);
                                *guard = None;
                                let _ = notices.send(Notice::Detached {
                                    session: id.clone(),
                                });
                            }
                        }
                    }
                }
                // Reap at the moment of exit (PR #341 review, R2): EOF on the master
                // means the child is gone or going; wait() here ends its lifetime with
                // its bytes, so no session leaves a zombie for `close` to find — and
                // `resume`'s removal of the old session needs no second job. close()'s
                // own wait after this is an ignored ECHILD, never a hang.
                let _ = child.lock().unwrap().wait();
                exited.store(true, Ordering::SeqCst);
                let _ = notices.send(Notice::Exited {
                    session: id.clone(),
                });
            });
        }
        Ok(session)
    }

    pub fn is_live(&self) -> bool {
        !self.exited.load(Ordering::SeqCst)
    }

    pub fn is_attached(&self) -> bool {
        self.attached.lock().unwrap().is_some()
    }

    pub fn output_bytes(&self) -> u64 {
        self.ring.lock().unwrap().total
    }

    /// How long the pty has been quiet — the crude idle gate the mail spike proved
    /// sufficient for wake delivery. The taps milestone replaces judgement, not
    /// plumbing.
    pub fn idle_for(&self) -> Duration {
        self.ring.lock().unwrap().last_change.elapsed()
    }

    /// Paste, then submit separately — the launch-line rule, spelled once.
    pub fn deliver_line(&self, line: &str) -> Result<(), String> {
        let mut w = self.writer.lock().unwrap();
        w.write_all(line.as_bytes())
            .map_err(|e| format!("paste: {e}"))?;
        w.flush().ok();
        drop(w);
        std::thread::sleep(Duration::from_millis(300));
        let mut w = self.writer.lock().unwrap();
        w.write_all(b"\r").map_err(|e| format!("submit: {e}"))?;
        w.flush().ok();
        Ok(())
    }

    pub fn write_input(&self, bytes: &[u8]) -> Result<(), String> {
        let mut w = self.writer.lock().unwrap();
        w.write_all(bytes).map_err(|e| format!("input: {e}"))?;
        w.flush().ok();
        Ok(())
    }

    /// Wait until the TUI is ready for its first paste. claude has a content marker
    /// (the yolo footer — settle heuristics alone raced history redraws, measured);
    /// the others settle on quiet output. The test agent is ready by construction.
    pub fn wait_ready(&self, cap: Duration) -> bool {
        if self.agent == AgentKind::TestEcho {
            return true;
        }
        let start = Instant::now();
        loop {
            {
                let ring = self.ring.lock().unwrap();
                match self.agent {
                    AgentKind::Claude => {
                        let bytes: Vec<u8> = ring.bytes.iter().copied().collect();
                        if shows_marker(&bytes, CLAUDE_READY_MARKER) {
                            drop(ring);
                            std::thread::sleep(Duration::from_secs(1));
                            return true;
                        }
                    }
                    _ => {
                        if ring.total > 500 && ring.last_change.elapsed() > Duration::from_secs(2) {
                            return true;
                        }
                    }
                }
            }
            if start.elapsed() > cap {
                return false;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    /// Attach: resize to the viewer, replay the ring, then hand live output to this
    /// stream. Replaces any previous attachment — the old stream is shut down, which
    /// its client sees as EOF. Returns the generation this attachment owns; the pump
    /// hands it back to `detach_generation` so a replaced pump cannot clear its
    /// replacement.
    pub fn attach(&self, stream: UnixStream, rows: u16, cols: u16) -> Result<u64, String> {
        if rows > 0 && cols > 0 {
            let master = self.master.lock().unwrap();
            let _ = master.resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            });
        }
        let replay: Vec<u8> = {
            let ring = self.ring.lock().unwrap();
            ring.bytes.iter().copied().collect()
        };
        let mut s = stream;
        s.write_all(&replay).map_err(|e| format!("replay: {e}"))?;
        let generation = self.attach_gen.fetch_add(1, Ordering::SeqCst) + 1;
        let mut guard = self.attached.lock().unwrap();
        if let Some((_, old)) = guard.take() {
            let _ = old.shutdown(std::net::Shutdown::Both);
        }
        *guard = Some((generation, s));
        Ok(generation)
    }

    /// Unconditional — for close/stop, where whatever is attached goes.
    pub fn detach(&self) {
        let mut guard = self.attached.lock().unwrap();
        if let Some((_, old)) = guard.take() {
            let _ = old.shutdown(std::net::Shutdown::Both);
        }
    }

    /// Clear the attachment only if `generation` still owns it. Returns whether it did
    /// — a pump whose attachment was taken over reports nothing, because the detach it
    /// noticed was the takeover, already logged from the other side.
    pub fn detach_generation(&self, generation: u64) -> bool {
        let mut guard = self.attached.lock().unwrap();
        match guard.as_ref() {
            Some((g, _)) if *g == generation => {
                if let Some((_, old)) = guard.take() {
                    let _ = old.shutdown(std::net::Shutdown::Both);
                }
                true
            }
            _ => false,
        }
    }

    /// Drain-then-die (session-state spike): a grace for the runtime to flush its
    /// transcript, a term, another grace, then the kill. Returns whether it was still
    /// live when asked.
    pub fn close(&self, grace: Duration) -> bool {
        let was_live = self.is_live();
        if was_live {
            std::thread::sleep(grace);
        }
        self.detach();
        let mut child = self.child.lock().unwrap();
        let _ = child.kill();
        let _ = child.wait();
        was_live
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(agent: AgentKind) -> SpawnSpec {
        SpawnSpec {
            agent,
            cwd: "/tmp".into(),
            model: None,
            effort: None,
            runtime_session: None,
            resume: false,
        }
    }

    #[test]
    fn postures_are_helms_table_verbatim() {
        let (p, a) = argv(&spec(AgentKind::Claude)).unwrap();
        assert_eq!(p, "claude");
        assert_eq!(a, vec!["--dangerously-skip-permissions"]);
        let (p, a) = argv(&spec(AgentKind::Codex)).unwrap();
        assert_eq!(p, "codex");
        assert_eq!(
            a,
            vec![
                "--dangerously-bypass-approvals-and-sandbox",
                "-c",
                "check_for_update_on_startup=false",
                "-c",
                "notice.hide_rate_limit_model_nudge=true"
            ]
        );
        let (p, a) = argv(&spec(AgentKind::Pi)).unwrap();
        assert_eq!(p, "pi");
        assert_eq!(a, vec!["--approve"]);
    }

    #[test]
    fn model_and_effort_flags_match_the_spike() {
        let mut s = spec(AgentKind::Claude);
        s.model = Some("opus".into());
        s.effort = Some("high".into());
        let (_, a) = argv(&s).unwrap();
        assert_eq!(
            a,
            vec![
                "--dangerously-skip-permissions",
                "--model",
                "opus",
                "--effort",
                "high"
            ]
        );

        let mut s = spec(AgentKind::Codex);
        s.model = Some("gpt-5.3-codex".into());
        s.effort = Some("high".into());
        let (_, a) = argv(&s).unwrap();
        assert_eq!(
            a,
            vec![
                "--dangerously-bypass-approvals-and-sandbox",
                "-c",
                "check_for_update_on_startup=false",
                "-c",
                "notice.hide_rate_limit_model_nudge=true",
                "-m",
                "gpt-5.3-codex",
                "-c",
                "model_reasoning_effort=high"
            ]
        );

        let mut s = spec(AgentKind::Pi);
        s.model = Some("anthropic/claude-opus-4-5".into());
        s.effort = Some("high".into());
        let (_, a) = argv(&s).unwrap();
        assert_eq!(
            a,
            vec!["--approve", "--model", "anthropic/claude-opus-4-5:high"]
        );
    }

    #[test]
    fn resume_needs_a_minted_id_and_codex_refuses_with_the_reason() {
        let mut s = spec(AgentKind::Claude);
        s.resume = true;
        assert!(argv(&s).is_err(), "resume without an id must refuse");
        s.runtime_session = Some("abc-123".into());
        let (_, a) = argv(&s).unwrap();
        assert!(a.contains(&"--resume".to_string()) && a.contains(&"abc-123".to_string()));

        let mut s = spec(AgentKind::Pi);
        s.runtime_session = Some("sess-9".into());
        let (_, a) = argv(&s).unwrap();
        assert!(a.contains(&"--session-id".to_string()));
        s.resume = true;
        let (_, a) = argv(&s).unwrap();
        assert!(
            a.contains(&"--session-id".to_string()),
            "pi resume is the same flag"
        );

        let mut s = spec(AgentKind::Codex);
        s.resume = true;
        let err = argv(&s).unwrap_err();
        assert!(
            err.contains("resume is not supported"),
            "the refusal names the reason: {err}"
        );
    }

    #[test]
    fn the_allowlist_refuses_arbitrary_commands_and_gates_the_test_agent() {
        assert!(AgentKind::parse("sh", false).is_err());
        assert!(
            AgentKind::parse("test-echo", false).is_err(),
            "test agent needs the env gate"
        );
        assert!(AgentKind::parse("test-echo", true).is_ok());
        assert!(AgentKind::parse("claude", false).is_ok());
    }

    #[test]
    fn minted_ids_are_uuid_shaped() {
        let id = mint_session_id();
        assert_eq!(id.len(), 36, "{id}");
        assert_eq!(id.chars().filter(|&c| c == '-').count(), 4);
    }

    #[test]
    fn claudes_ready_marker_is_found_when_words_are_placed_by_cursor_moves() {
        // claude 2.1.282's inline renderer, measured: the words sit at columns, not
        // behind spaces. This is what `wait_ready` saw while `mail-proof` timed out.
        let inline = b"\xe2\x8f\xb5\xe2\x8f\xb5\x1b[6Gbypass\x1b[13Gpermissions\x1b[25Gon";
        assert!(shows_marker(inline, CLAUDE_READY_MARKER));
        // The fullscreen renderer writes the plain phrase, with colour around it.
        assert!(shows_marker(
            b"\x1b[38;2;1;2;3mbypass permissions on\x1b[39m",
            CLAUDE_READY_MARKER
        ));
        // A title OSC carrying the words is not the footer being drawn, and a screen
        // without the footer is not ready.
        assert!(!shows_marker(
            b"\x1b]0;bypass permissions\x07claude starting",
            CLAUDE_READY_MARKER
        ));
        assert!(!shows_marker(
            b"bypass mode, no permissions",
            CLAUDE_READY_MARKER
        ));
    }

    #[test]
    fn the_ring_caps_and_reports_totals() {
        let mut ring = Ring {
            bytes: VecDeque::new(),
            total: 0,
            last_change: Instant::now(),
        };
        ring.push(&vec![b'x'; RING_CAPACITY + 100]);
        assert_eq!(ring.bytes.len(), RING_CAPACITY);
        assert_eq!(ring.total, (RING_CAPACITY + 100) as u64);
    }
}
