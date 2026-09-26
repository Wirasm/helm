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

mod pty;

use std::collections::VecDeque;
use std::fs::File;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::Child;
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
    /// The first prompt's file. argv carries a sentence naming it, never its text: the
    /// agent reads it as its first act, so nothing waits for a TUI to be ready and nothing is
    /// typed into the pty (#358), and `ps` shows a path rather than a plan (helm #93). The
    /// file must outlive the spawn. Ignored on resume.
    pub prompt_file: Option<String>,
    /// Claude's `--settings` file: the hooks that report to benchd, and the inbound rule that
    /// lets benchd start a turn in an idle session (#358).
    pub settings: Option<String>,
    /// codex: the socket of the app-server this session's TUI runs against, which the session
    /// starts beside the TUI ([`CODEX_SERVED`]). benchd starts a turn there when the agent is
    /// idle (#358). `None` runs the TUI with its app-server embedded, which nothing outside the
    /// process can reach.
    pub codex_server: Option<String>,
}

/// How a served codex session starts, as a script: `$0` is the socket, `"$@"` the TUI's
/// flags. Measured on codex 0.157.0:
/// - The app-server runs the hooks, not the TUI, with its own environment and as the hook's
///   parent. So it runs in the session's environment (`BENCH_SESSION`), one per session, and
///   benchd knows which session a hook is from without matching threads.
/// - The TUI renders and takes keys against it with `--remote`, and a second client's
///   `turn/start` on its idle thread runs a turn the TUI shows.
/// - Closing stdin does not stop the app-server, and macOS has no parent-death signal. The
///   watcher is its leash: it outlives a hangup and stops the server within a second of the
///   TUI going, however the TUI went. `$$` is the TUI's pid after the `exec`.
pub const CODEX_SERVED: &str = r#"s="$0"
codex app-server --listen "unix://$s" </dev/null >/dev/null 2>"$s.log" &
p=$!
( trap '' HUP INT TERM; while kill -0 $$ 2>/dev/null; do sleep 1; done; kill $p 2>/dev/null ) </dev/null >/dev/null 2>&1 &
i=0
while [ ! -S "$s" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
exec codex --remote "unix://$s" "$@"
"#;

/// The sentence a first prompt becomes in argv.
pub fn prompt_pointer(path: &str) -> String {
    format!("Read and act on the prompt in {path}")
}

/// The single spelling of how each runtime is started unattended. Postures verbatim
/// from helm's `SpoolUnattendedPolicy`; model/effort flags verbatim from the
/// model-selection spike; resume flags from the session-state spike.
pub fn argv(spec: &SpawnSpec) -> Result<(String, Vec<String>), String> {
    let mut args: Vec<String> = Vec::new();
    let program = match spec.agent {
        AgentKind::Claude => {
            args.push("--dangerously-skip-permissions".into());
            if let Some(settings) = &spec.settings {
                args.extend(["--settings".into(), settings.clone()]);
            }
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
            // The hooks report to benchd, and hooks run only once trusted, which is a choice
            // made in a dialog nobody is at an unattended pane to answer. An agent that already
            // runs every command unsandboxed gains nothing a hook could add.
            args.push("--dangerously-bypass-hook-trust".into());
            // The thread's directory. Against a separate app-server the TUI's own cwd is not
            // it (measured: the thread ran in the server's).
            args.extend(["-C".into(), spec.cwd.clone()]);
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
            // `cat` would read a pointer as a file to print; it takes no prompt.
            return Ok(("/bin/cat".to_string(), args));
        }
    };
    if let Some(path) = spec.prompt_file.as_deref().filter(|_| !spec.resume) {
        args.push(prompt_pointer(path));
    }
    if let (AgentKind::Codex, Some(socket)) = (spec.agent, &spec.codex_server) {
        let mut served = vec!["-c".to_string(), CODEX_SERVED.to_string(), socket.clone()];
        served.extend(args);
        return Ok(("/bin/sh".to_string(), served));
    }
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
}

impl Ring {
    fn new() -> Ring {
        Ring {
            bytes: VecDeque::with_capacity(8192),
            total: 0,
        }
    }

    fn push(&mut self, chunk: &[u8]) {
        self.total += chunk.len() as u64;
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
    pub pid: u32,
    pub runtime_session: Option<String>,
    pub spawned_at: Instant,
    /// The pty master: input and resize go through it; the drain thread reads a dup.
    master: Mutex<File>,
    child: Arc<Mutex<Child>>,
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
        // `extra_env` is how the session learns its own address and root — what lets an
        // agent inside run `bench mail send` with no flags and land in the right mailroom
        // (the same declare-don't-derive rule as helm's PaneEnvironment).
        let (master, child) = pty::spawn(&program, &args, &spec.cwd, extra_env, rows, cols)
            .map_err(|e| format!("spawn {program} in {}: {e}", spec.cwd))?;
        let mut reader = master
            .try_clone()
            .map_err(|e| format!("clone reader: {e}"))?;

        let session = Arc::new(Session {
            pid: child.id(),
            handle,
            spec: spec.clone(),
            id: id.clone(),
            agent: spec.agent,
            cwd: spec.cwd.clone(),
            runtime_session: spec.runtime_session.clone(),
            spawned_at: Instant::now(),
            master: Mutex::new(master),
            child: Arc::new(Mutex::new(child)),
            ring: Arc::new(Mutex::new(Ring::new())),
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
                        // EIO once the child's side has closed is the pty's EOF.
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
                // `resume`'s removal of the old session needs no second job. close() after
                // this finds the status already collected and signals nothing.
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

    pub fn write_input(&self, bytes: &[u8]) -> Result<(), String> {
        let mut w = self.master.lock().unwrap();
        w.write_all(bytes).map_err(|e| format!("input: {e}"))?;
        w.flush().ok();
        Ok(())
    }

    /// Attach: resize to the viewer, replay the ring, then hand live output to this
    /// stream. Replaces any previous attachment — the old stream is shut down, which
    /// its client sees as EOF. Returns the generation this attachment owns; the pump
    /// hands it back to `detach_generation` so a replaced pump cannot clear its
    /// replacement.
    pub fn attach(&self, stream: UnixStream, rows: u16, cols: u16) -> Result<u64, String> {
        if rows > 0 && cols > 0 {
            let master = self.master.lock().unwrap();
            let _ = pty::resize(&master, rows, cols);
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
    /// transcript, a hangup, another grace, then the kill. Returns whether it was still
    /// live when asked.
    pub fn close(&self, grace: Duration) -> bool {
        let was_live = self.is_live();
        if was_live {
            std::thread::sleep(grace);
        }
        self.detach();
        pty::hang_up_then_kill(&mut self.child.lock().unwrap());
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
            prompt_file: None,
            settings: None,
            codex_server: None,
        }
    }

    #[test]
    fn the_first_prompt_is_a_pointer_at_the_end_of_argv_and_never_on_resume() {
        for agent in [AgentKind::Claude, AgentKind::Codex, AgentKind::Pi] {
            let mut s = spec(agent);
            s.prompt_file = Some("/tmp/p.txt".into());
            s.runtime_session = Some("id-1".into());
            let (_, a) = argv(&s).unwrap();
            assert_eq!(
                a.last().unwrap(),
                "Read and act on the prompt in /tmp/p.txt"
            );
            if agent != AgentKind::Codex {
                s.resume = true;
                let (_, a) = argv(&s).unwrap();
                assert!(!a.iter().any(|x| x.contains("/tmp/p.txt")), "{a:?}");
            }
        }
        let mut s = spec(AgentKind::TestEcho);
        s.prompt_file = Some("/tmp/p.txt".into());
        assert_eq!(argv(&s).unwrap(), ("/bin/cat".to_string(), vec![]));
        let mut s = spec(AgentKind::Claude);
        s.settings = Some("/r/claude-settings.json".into());
        let (_, a) = argv(&s).unwrap();
        assert_eq!(
            a,
            [
                "--dangerously-skip-permissions",
                "--settings",
                "/r/claude-settings.json"
            ]
        );
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
                "--dangerously-bypass-hook-trust",
                "-C",
                "/tmp",
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
    fn a_served_codex_starts_its_app_server_and_runs_the_tui_against_it() {
        let mut s = spec(AgentKind::Codex);
        s.prompt_file = Some("/tmp/p.txt".into());
        let (_, embedded) = argv(&s).unwrap();
        s.codex_server = Some("/r/codex/s1.sock".into());
        let (p, a) = argv(&s).unwrap();
        assert_eq!(p, "/bin/sh");
        assert_eq!(a[..3], ["-c", CODEX_SERVED, "/r/codex/s1.sock"]);
        assert_eq!(
            a[3..],
            embedded[..],
            "the TUI keeps every flag and the prompt"
        );
    }

    /// A stub `codex` on PATH: `app-server` records its pid and sleeps; the TUI sleeps too, so
    /// the test decides how it goes.
    fn served_codex_stub(dir: &std::path::Path) -> String {
        let stub = dir.join("codex");
        std::fs::write(
            &stub,
            format!(
                "#!/bin/sh\nif [ \"$1\" = app-server ]; then echo $$ > {}/server.pid; exec sleep 30; fi\nexec sleep 30\n",
                dir.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&stub, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        format!("{}:/bin:/usr/bin", dir.display())
    }

    fn gone_within(pid: i32, limit: Duration) -> bool {
        let start = Instant::now();
        while start.elapsed() < limit {
            // SAFETY: signal 0 only asks whether the pid exists.
            if unsafe { libc::kill(pid, 0) } != 0 {
                return true;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        false
    }

    #[test]
    fn a_served_codexs_app_server_dies_with_its_tui_however_the_tui_goes() {
        for signal in [libc::SIGTERM, libc::SIGKILL] {
            let dir = std::env::temp_dir().join(format!("bcx{}-{signal}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            let path = served_codex_stub(&dir);
            let socket = dir.join("s.sock");
            let _listening = std::os::unix::net::UnixListener::bind(&socket).unwrap();
            let mut tui = std::process::Command::new("/bin/sh")
                .args(["-c", CODEX_SERVED, socket.to_str().unwrap()])
                .env("PATH", path)
                .spawn()
                .unwrap();
            let pid_file = dir.join("server.pid");
            let start = Instant::now();
            while !pid_file.exists() && start.elapsed() < Duration::from_secs(5) {
                std::thread::sleep(Duration::from_millis(50));
            }
            let server: i32 = std::fs::read_to_string(&pid_file)
                .unwrap()
                .trim()
                .parse()
                .unwrap();
            assert!(
                !gone_within(server, Duration::from_millis(300)),
                "server started"
            );
            // SAFETY: the TUI is this test's own child.
            unsafe { libc::kill(tui.id() as i32, signal) };
            let _ = tui.wait();
            let gone = gone_within(server, Duration::from_secs(4));
            if !gone {
                // SAFETY: the stub server is this test's own grandchild.
                unsafe { libc::kill(server, libc::SIGKILL) };
            }
            let _ = std::fs::remove_dir_all(&dir);
            assert!(
                gone,
                "the app-server outlived its TUI after signal {signal}"
            );
        }
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
                "--dangerously-bypass-hook-trust",
                "-C",
                "/tmp",
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
    fn the_ring_caps_and_reports_totals() {
        let mut ring = Ring::new();
        ring.push(&vec![b'x'; RING_CAPACITY + 100]);
        assert_eq!(ring.bytes.len(), RING_CAPACITY);
        assert_eq!(ring.total, (RING_CAPACITY + 100) as u64);
    }
}
