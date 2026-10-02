//! The pty core — M5a's substance, built directly on what the spikes proved
//! (`daemon/spikes/`): a headless process can own ptys hosting full interactive agent
//! TUIs, deliver prompts paste-then-submit, and re-enter session state from outside.
//!
//! This crate knows runtimes and ptys; it knows nothing about sockets, verbs, or the
//! event log — the daemon composes those. Everything an incident already paid for is
//! carried as code:
//!
//! - **Postures are the operator's unattended table (helm #179), plus the model/effort columns the
//!   model-selection spike proved.** A posture removes a prompt; it never withholds
//!   capability (helm #179), except a fork's, which is read-only by the operator's ruling (#531).
//! - **The agent allowlist is the security line** (as helm's spool had it): a spawn request
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

mod engine;
mod pty;

pub use engine::{SCROLLBACK_BYTES, Screen};
pub use pty::Env;

use std::fs::File;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::Child;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Sender, SyncSender, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

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
    /// The operator's login shell in a terminal pane (M5b). Never parsed from a request: a
    /// shell is what benchd starts for a terminal pane, with no argv from anyone, so the
    /// allowlist above still refuses an arbitrary program.
    Shell,
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
            AgentKind::Shell => "shell",
        }
    }

    /// Whether this runtime can mint its session identity at spawn, so a new session's id is
    /// known before it runs. codex mints its own thread id when benchd creates the thread on its
    /// app-server, before the TUI starts (#466).
    pub fn mints_session_id(&self) -> bool {
        matches!(self, AgentKind::Claude | AgentKind::Pi)
    }
}

/// Which conversation a session holds, and how it came by it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Conversation {
    /// A new conversation: under the id benchd minted (claude, pi) or codex minted when benchd
    /// created its thread; none until then.
    New(Option<String>),
    /// Re-enter conversation `id`.
    Resume(String),
    /// A new conversation that starts as a copy of `from`, which carries on untouched: how the
    /// operator asks an agent about its work without interrupting it (#531). benchd mints `id`
    /// as it does for [`Conversation::New`] (claude, pi), so no record of the fork ever names
    /// `from`; codex mints the fork's id when benchd forks the thread on its app-server.
    Fork { from: String, id: Option<String> },
}

impl Conversation {
    /// The conversation the session holds, when the bench knows it.
    pub fn id(&self) -> Option<&str> {
        match self {
            Conversation::New(id) | Conversation::Fork { id, .. } => id.as_deref(),
            Conversation::Resume(id) => Some(id),
        }
    }

    /// The conversation this one was copied from, for a fork.
    pub fn forked_from(&self) -> Option<&str> {
        match self {
            Conversation::Fork { from, .. } => Some(from),
            _ => None,
        }
    }
}

/// How much an agent may do without asking.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Posture {
    /// The operator's unattended table (helm #179): removes every prompt it can.
    #[default]
    Unattended,
    /// Reads, never writes: a fork (#531), which exists to answer, in the author's worktree
    /// where an edit would collide with the author's work. The one posture that withholds
    /// capability, by the operator's ruling. claude's plan mode, codex's read-only sandbox, pi
    /// with only its read tools.
    ReadOnly,
}

impl Posture {
    /// The posture a recorded conversation is resumed in: the one it was spawned in, which for a
    /// fork (it records the conversation it was `forked_from`) is read-only.
    pub fn resuming(forked_from: Option<&str>) -> Posture {
        match forked_from {
            Some(_) => Posture::ReadOnly,
            None => Posture::Unattended,
        }
    }
}

/// What a spawn (or resume, or fork) wants. Pure data; `argv()` is the one spelling of every
/// posture/model/effort/resume/fork flag, unit-tested per runtime.
#[derive(Debug, Clone)]
pub struct SpawnSpec {
    pub agent: AgentKind,
    pub cwd: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub conversation: Conversation,
    pub posture: Posture,
    /// The first prompt's file. argv carries a sentence naming it, never its text: the
    /// agent reads it as its first act, so nothing waits for a TUI to be ready and nothing is
    /// typed into the pty (#358), and `ps` shows a path rather than a plan (helm #93). The
    /// file must outlive the spawn. A resume always carries one: the caller's new message
    /// (`bench spawn --resume --prompt-file`), else the notice benchd writes for it
    /// (`spawn::wire` in benchd), never the prompt of an earlier spawn.
    pub prompt_file: Option<String>,
    /// The caller's own flags, after the posture and before the prompt (`--remote-control`,
    /// say). They add to the posture, never replace it: a posture removes a prompt, and the
    /// operator's yolo posture is the bench's rule (roadmap invariant 4).
    pub extra_args: Vec<String>,
    /// Claude's `--settings` file: the hooks that report to benchd, and the inbound rule that
    /// lets benchd start a turn in an idle session (#358).
    pub settings: Option<String>,
    /// codex: the app-server its TUI attaches to (#466). benchd runs one per root and creates
    /// the session's thread there before the TUI starts, so the thread carries the posture,
    /// model, effort, cwd and environment, and the TUI only draws it.
    pub codex: Option<CodexAttach>,
}

impl SpawnSpec {
    /// The spec that re-enters conversation `id` as this one ran it: the same agent, directory,
    /// model, posture and caller flags, and no first prompt. An earlier spawn's prompt is never
    /// sent again; benchd gives the resume its own notice when it wires the session.
    pub fn resuming(&self, id: String) -> SpawnSpec {
        SpawnSpec {
            conversation: Conversation::Resume(id),
            prompt_file: None,
            settings: None,
            codex: None,
            ..self.clone()
        }
    }
}

/// Where a codex TUI attaches: the program benchd's app-server runs (the same file, so a codex
/// update on disk never puts a newer TUI on an older server) and that server's socket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexAttach {
    pub program: String,
    pub socket: String,
}

/// The sentence a first prompt becomes in argv.
pub fn prompt_pointer(path: &str) -> String {
    format!("Read and act on the prompt in {path}")
}

/// The operator's shell, as a terminal finds it: `$SHELL` (what his login session and
/// Ghostty go by), else his entry in the user database, else `/bin/sh`.
pub fn login_shell() -> String {
    if let Ok(shell) = std::env::var("SHELL")
        && shell.starts_with('/')
    {
        return shell;
    }
    // SAFETY: getpwuid returns a pointer into static storage or null; the string is copied out
    // at once, and nothing else in benchd calls getpwuid concurrently with a spawn.
    unsafe {
        let entry = libc::getpwuid(libc::getuid());
        if !entry.is_null() && !(*entry).pw_shell.is_null() {
            let shell = std::ffi::CStr::from_ptr((*entry).pw_shell).to_string_lossy();
            if shell.starts_with('/') {
                return shell.into_owned();
            }
        }
    }
    "/bin/sh".to_string()
}

/// The single spelling of how each runtime is started unattended. Postures verbatim
/// from the operator's unattended table (helm #179); model/effort flags verbatim from the
/// model-selection spike; resume flags from the session-state spike; the fork from the
/// fork-author-session spike (#531).
pub fn argv(spec: &SpawnSpec) -> Result<(String, Vec<String>), String> {
    // A runtime that takes its id from benchd needs one for a fork as for a new conversation:
    // without it the fork would run under an id nobody recorded, and could never be resumed.
    if let Conversation::Fork { id: None, .. } = spec.conversation
        && spec.agent.mints_session_id()
    {
        return Err(format!(
            "a {} fork needs the id benchd mints for it",
            spec.agent.name()
        ));
    }
    let mut args: Vec<String> = Vec::new();
    let program = match spec.agent {
        AgentKind::Claude => {
            args.extend(claude_flags(spec));
            "claude"
        }
        AgentKind::Codex if spec.codex.is_some() => return codex_argv(spec),
        AgentKind::Codex => {
            // A codex outside benchd: what the operator runs himself to resume a finished
            // codex from the session list, on codex's own app-server. `codex resume <id>` and
            // `codex fork <id>` take every flag below.
            match &spec.conversation {
                Conversation::New(_) => {}
                Conversation::Resume(id) => args.extend(["resume".into(), id.clone()]),
                Conversation::Fork { from, .. } => args.extend(["fork".into(), from.clone()]),
            }
            match spec.posture {
                Posture::Unattended => {
                    args.push("--dangerously-bypass-approvals-and-sandbox".into())
                }
                Posture::ReadOnly => {
                    args.extend(["-s".into(), "read-only".into(), "-a".into(), "never".into()])
                }
            }
            // The hooks report to benchd, and hooks run only once trusted, which is a choice
            // made in a dialog nobody is at an unattended pane to answer. An agent that already
            // runs every command unsandboxed gains nothing a hook could add.
            args.push("--dangerously-bypass-hook-trust".into());
            args.extend(["-C".into(), spec.cwd.clone()]);
            // No modals, as for a codex benchd runs ([`codex_argv`]).
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
            // `--approve` trusts the project's own files, a prompt rather than a capability, so
            // a read-only pi takes it too. Read-only is pi's own recipe: only the tools that
            // read, which leaves it no bash, edit or write (measured on 0.99.2: a fork asked to
            // write a file had no tool to do it with).
            args.push("--approve".into());
            if spec.posture == Posture::ReadOnly {
                args.extend(["--tools".into(), "read,grep,find,ls".into()]);
            }
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
            // and resume are the same flag (session-state spike). Beside `--fork` it names the
            // copy, which keeps `parentSession` (measured on 0.84.4 and 0.99.2).
            if let Conversation::Fork { from, .. } = &spec.conversation {
                args.extend(["--fork".into(), from.clone()]);
            }
            if let Some(id) = spec.conversation.id() {
                args.extend(["--session-id".into(), id.to_string()]);
            }
            "pi"
        }
        AgentKind::TestEcho => {
            if spec.conversation != Conversation::New(None) {
                return Err("the test agent has no sessions to resume or fork".into());
            }
            // `cat` would read a pointer as a file to print; it takes no prompt.
            return Ok(("/bin/cat".to_string(), args));
        }
        AgentKind::Shell => {
            if spec.conversation != Conversation::New(None) {
                return Err("a shell has no conversation to resume or fork".into());
            }
            return Ok((login_shell(), vec!["-l".to_string()]));
        }
    };
    args.extend(spec.extra_args.iter().cloned());
    if let Some(path) = spec.prompt_file.as_deref() {
        args.push(prompt_pointer(path));
    }
    Ok((program.to_string(), args))
}

/// codex's half of [`argv`]: the TUI attaches to the thread benchd created on its app-server
/// (#466). Nothing about the conversation rides on the command line. The thread already holds
/// the posture, model, effort and cwd, and its first message was sent as a turn, because a TUI
/// cannot attach to a thread with no turn yet (codex 0.160.0). No `-C`: against a remote server
/// it asks "Trust this folder?" for any folder without its own exact trust entry, a worktree of
/// a trusted repository included, and the thread has its cwd already.
fn codex_argv(spec: &SpawnSpec) -> Result<(String, Vec<String>), String> {
    let attach = spec
        .codex
        .as_ref()
        .ok_or("a codex attaches to benchd's app-server, and this spec names none")?;
    let thread = spec
        .conversation
        .id()
        .ok_or("a codex attaches to the thread benchd created for it, and this spec names none")?;
    let mut args: Vec<String> = vec![
        "resume".into(),
        thread.into(),
        "--remote".into(),
        format!("unix://{}", attach.socket),
        // No modals: nobody is at an unattended pane to answer one, so the next pasted Return
        // does. Both measured. The update prompt: the brief's Return accepted "Update now" and the pane ran
        // `brew upgrade --cask codex` and quit (0.155.1). The rate-limit nudge: raised after a
        // turn near the weekly limit, with "Switch to <cheaper model>" as the default a mail
        // wake would select (0.157.0).
        "-c".into(),
        "check_for_update_on_startup=false".into(),
        "-c".into(),
        "notice.hide_rate_limit_model_nudge=true".into(),
    ];
    args.extend(spec.extra_args.iter().cloned());
    Ok((attach.program.clone(), args))
}

/// claude's half of [`argv`]: posture, settings, model and effort, then the conversation.
fn claude_flags(spec: &SpawnSpec) -> Vec<String> {
    let mut args: Vec<String> = match spec.posture {
        Posture::Unattended => vec!["--dangerously-skip-permissions".into()],
        Posture::ReadOnly => vec!["--permission-mode".into(), "plan".into()],
    };
    // Plan mode asks before reading outside the working directories, and the first prompt is
    // usually outside (benchd's `<root>/prompts`, helm #535): measured on 2.1.285, a fork sat at
    // "Read file … Do you want to proceed?" before reading its question. Allowing the prompt's
    // folder is the whole grant: benchd gives each prompt a folder of its own, and a caller's own
    // `--prompt-file` grants the folder it chose. Here, before any flag it could be mistaken for,
    // because `--add-dir` takes every argument up to the next flag.
    if let (Posture::ReadOnly, Some(folder)) = (
        spec.posture,
        spec.prompt_file
            .as_deref()
            .and_then(|p| std::path::Path::new(p).parent()),
    ) {
        args.extend(["--add-dir".into(), folder.display().to_string()]);
    }
    if let Some(settings) = &spec.settings {
        args.extend(["--settings".into(), settings.clone()]);
    }
    if let Some(m) = &spec.model {
        args.extend(["--model".into(), m.clone()]);
    }
    if let Some(e) = &spec.effort {
        args.extend(["--effort".into(), e.clone()]);
    }
    match &spec.conversation {
        Conversation::New(Some(id)) => args.extend(["--session-id".into(), id.clone()]),
        Conversation::New(None) => {}
        Conversation::Resume(id) => args.extend(["--resume".into(), id.clone()]),
        // Claude takes `--session-id` beside `--resume` only with `--fork-session` (2.1.285:
        // "--session-id can only be used with --continue or --resume if --fork-session is also
        // specified"), which is what names the fork up front.
        Conversation::Fork { from, id } => {
            args.extend(["--resume".into(), from.clone(), "--fork-session".into()]);
            if let Some(id) = id {
                args.extend(["--session-id".into(), id.clone()]);
            }
        }
    }
    args
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
    Exited {
        session: String,
    },
    Detached {
        session: String,
    },
    /// The program's output has settled (`engine::SETTLE`): the moment its screen is worth
    /// reading for a prompt it may be waiting at (M1, #357).
    Settled {
        session: String,
    },
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
    /// The pty master: input, resize and the engine's answers go through it; the drain thread
    /// reads a dup.
    master: Arc<Mutex<File>>,
    /// Another dup, for asking the kernel about the terminal (its foreground group). That takes
    /// no turn at the master, and must not wait for one: `write_input` holds the master's lock
    /// for as long as the program leaves its input unread, which can be for good (#517).
    terminal: File,
    child: Arc<Mutex<Child>>,
    /// Bytes the program has written, all told.
    output_total: Arc<AtomicU64>,
    /// The session's VT engine (`engine.rs`): output, attaches, resizes and screen reads.
    engine: SyncSender<engine::Msg>,
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
        env: &Env,
        notices: Sender<Notice>,
    ) -> Result<Arc<Session>, String> {
        let (program, args) = argv(spec)?;
        // `env` is how the session learns its own address and root — what lets an
        // agent inside run `bench mail send` with no flags and land in the right mailroom
        // (the same declare-don't-derive rule as helm's PaneEnvironment).
        let (master, child) = pty::spawn(&program, &args, &spec.cwd, env, rows, cols)
            .map_err(|e| format!("spawn {program} in {}: {e}", spec.cwd))?;
        let mut reader = master
            .try_clone()
            .map_err(|e| format!("clone reader: {e}"))?;
        let terminal = master
            .try_clone()
            .map_err(|e| format!("clone terminal: {e}"))?;

        let pid = child.id();
        let child = Arc::new(Mutex::new(child));
        let master = Arc::new(Mutex::new(master));
        let attached: engine::Attached = Arc::new(Mutex::new(None));
        let exited = Arc::new(AtomicBool::new(false));
        let (engine, output) = sync_channel(engine::QUEUE);
        let shared = engine::Shared {
            id: id.clone(),
            master: Arc::clone(&master),
            attached: Arc::clone(&attached),
            child: Arc::clone(&child),
            exited: Arc::clone(&exited),
            notices,
        };
        if let Err(why) = engine::start(shared, rows, cols, output) {
            pty::hang_up_then_kill(&mut child.lock().unwrap());
            return Err(why);
        }
        let session = Arc::new(Session {
            pid,
            handle,
            spec: spec.clone(),
            id,
            agent: spec.agent,
            cwd: spec.cwd.clone(),
            runtime_session: spec.conversation.id().map(str::to_string),
            spawned_at: Instant::now(),
            master,
            terminal,
            child,
            output_total: Arc::new(AtomicU64::new(0)),
            engine: engine.clone(),
            attached,
            attach_gen: AtomicU64::new(0),
            exited,
        });

        // The drain thread: the pty owner's first duty. Everything it reads goes to the engine
        // thread, which relays it to the viewer — escape sequences included, which is what lets
        // an OSC ride the relay into whatever terminal hosts `bench attach`.
        {
            let total = Arc::clone(&session.output_total);
            std::thread::spawn(move || {
                let mut chunk = [0u8; 8192];
                loop {
                    match reader.read(&mut chunk) {
                        // EIO once the child's side has closed is the pty's EOF.
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            total.fetch_add(n as u64, Ordering::Relaxed);
                            if engine
                                .send(engine::Msg::Output(chunk[..n].to_vec()))
                                .is_err()
                            {
                                break;
                            }
                        }
                    }
                }
                let _ = engine.send(engine::Msg::Closed);
            });
        }
        Ok(session)
    }

    pub fn is_live(&self) -> bool {
        !self.exited.load(Ordering::SeqCst)
    }

    /// What runs in the foreground of this session's terminal, when it is not the session's own
    /// process: a shell's running command (an interactive shell puts each job in a group of its
    /// own), answered as its pid and name. `None` means the session's process has the terminal
    /// — a shell at its prompt, or an agent — or the session has ended.
    pub fn foreground_job(&self) -> Option<(i32, String)> {
        if !self.is_live() {
            return None;
        }
        let group = pty::foreground(&self.terminal)?;
        if group == self.pid as i32 {
            return None;
        }
        let name = pty::process_name(group).unwrap_or_else(|| format!("pid {group}"));
        Some((group, name))
    }

    /// Where this session's own process is working now, while it lives.
    pub fn cwd_now(&self) -> Option<String> {
        if !self.is_live() {
            return None;
        }
        pty::process_cwd(self.pid as i32)
    }

    /// The pid in the foreground of this session's terminal: its own process, or the job a shell
    /// is running. How a pane's agent is found (helm joins it against Claude's registry).
    pub fn foreground_pid(&self) -> Option<i32> {
        if !self.is_live() {
            return None;
        }
        pty::foreground(&self.terminal)
    }

    pub fn is_attached(&self) -> bool {
        self.attached.lock().unwrap().is_some()
    }

    pub fn output_bytes(&self) -> u64 {
        self.output_total.load(Ordering::Relaxed)
    }

    pub fn write_input(&self, bytes: &[u8]) -> Result<(), String> {
        let mut w = self.master.lock().unwrap();
        w.write_all(bytes).map_err(|e| format!("input: {e}"))?;
        w.flush().ok();
        Ok(())
    }

    /// Attach: resize to the viewer, redraw the session's screen in it, then hand live output to
    /// this stream. Replaces any previous attachment — the old stream is shut down, which its
    /// client sees as EOF. Returns the generation this attachment owns; the pump hands it back
    /// to `detach_generation` so a replaced pump cannot clear its replacement.
    pub fn attach(&self, stream: UnixStream, rows: u16, cols: u16) -> Result<u64, String> {
        let generation = self.attach_gen.fetch_add(1, Ordering::SeqCst) + 1;
        self.ask(|reply| engine::Msg::Attach {
            stream,
            generation,
            rows,
            cols,
            reply,
        })?;
        Ok(generation)
    }

    /// The viewer's terminal changed size: the pty and the engine follow, and the kernel tells
    /// the program.
    pub fn resize(&self, rows: u16, cols: u16) -> Result<(), String> {
        self.ask(|reply| engine::Msg::Resize { rows, cols, reply })
    }

    /// The session's terminal as its viewer shows it, with the history above when asked.
    pub fn screen(&self, history: bool) -> Result<Screen, String> {
        self.ask(|reply| engine::Msg::Screen { history, reply })
    }

    /// Put a request to the engine thread and wait for its answer. The wait is bounded: an
    /// attach waits out at most a second of synchronized update, and the rest are immediate
    /// once the output ahead of them is handled.
    fn ask<T>(
        &self,
        msg: impl FnOnce(SyncSender<Result<T, String>>) -> engine::Msg,
    ) -> Result<T, String> {
        let (reply, answer) = sync_channel(1);
        self.engine
            .send(msg(reply))
            .map_err(|_| "the session's terminal engine has stopped".to_string())?;
        answer
            .recv_timeout(Duration::from_secs(10))
            .map_err(|_| "the session's terminal engine did not answer".to_string())?
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
            conversation: Conversation::New(None),
            posture: Posture::Unattended,
            prompt_file: None,
            settings: None,
            extra_args: Vec::new(),
            codex: None,
        }
    }

    fn attached(mut s: SpawnSpec) -> SpawnSpec {
        s.codex = Some(CodexAttach {
            program: "/opt/codex/0.160.0/codex".into(),
            socket: "/r/codex.sock".into(),
        });
        s
    }

    #[test]
    fn a_resume_of_a_named_conversation_carries_the_callers_flags_then_its_new_message() {
        let mut s = spec(AgentKind::Claude);
        s.conversation = Conversation::Resume("4b1c".into());
        s.extra_args = vec!["--remote-control".into(), "helm abc123".into()];
        s.prompt_file = Some("/tmp/notice.txt".into());
        let (_, a) = argv(&s).unwrap();
        assert_eq!(
            a,
            [
                "--dangerously-skip-permissions",
                "--resume",
                "4b1c",
                "--remote-control",
                "helm abc123",
                "Read and act on the prompt in /tmp/notice.txt"
            ]
        );
    }

    #[test]
    fn the_first_prompt_is_a_pointer_at_the_end_of_argv() {
        for agent in [AgentKind::Claude, AgentKind::Codex, AgentKind::Pi] {
            let mut s = spec(agent);
            s.prompt_file = Some("/tmp/p.txt".into());
            s.conversation = Conversation::New(Some("id-1".into()));
            let (_, a) = argv(&s).unwrap();
            assert_eq!(
                a.last().unwrap(),
                "Read and act on the prompt in /tmp/p.txt"
            );
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
    fn resume_re_enters_the_conversation_for_every_runtime() {
        let mut s = spec(AgentKind::Claude);
        s.conversation = Conversation::Resume("abc-123".into());
        let (_, a) = argv(&s).unwrap();
        assert!(a.contains(&"--resume".to_string()) && a.contains(&"abc-123".to_string()));

        let mut s = spec(AgentKind::Pi);
        s.conversation = Conversation::New(Some("sess-9".into()));
        let (_, a) = argv(&s).unwrap();
        assert!(a.contains(&"--session-id".to_string()));
        s.conversation = Conversation::Resume("sess-9".into());
        let (_, a) = argv(&s).unwrap();
        assert!(
            a.contains(&"--session-id".to_string()),
            "pi resume is the same flag"
        );

        let mut s = attached(spec(AgentKind::Codex));
        s.conversation = Conversation::Resume("019a-codex".into());
        let (_, a) = argv(&s).unwrap();
        assert_eq!(a[..2], ["resume", "019a-codex"]);
    }

    #[test]
    fn a_claude_fork_copies_the_conversation_under_the_minted_id_in_plan_mode() {
        let mut s = spec(AgentKind::Claude);
        s.conversation = Conversation::Fork {
            from: "author-1".into(),
            id: Some("fork-2".into()),
        };
        s.posture = Posture::ReadOnly;
        s.prompt_file = Some("/tmp/q.md".into());
        let (p, a) = argv(&s).unwrap();
        assert_eq!(p, "claude");
        assert_eq!(
            a,
            [
                "--permission-mode",
                "plan",
                "--add-dir",
                "/tmp",
                "--resume",
                "author-1",
                "--fork-session",
                "--session-id",
                "fork-2",
                "Read and act on the prompt in /tmp/q.md"
            ]
        );
        // A fork resumed later is still read-only: the posture travels apart from the conversation.
        s.conversation = Conversation::Resume("fork-2".into());
        s.prompt_file = None;
        let (_, a) = argv(&s).unwrap();
        assert_eq!(a[..4], ["--permission-mode", "plan", "--resume", "fork-2"]);
    }

    /// Every codex conversation, new, forked or resumed, is a thread benchd created (or
    /// re-entered) on its app-server before the TUI starts, so the TUI's command line is the same
    /// for all three: attach to that thread. Posture, model, effort, cwd and the first message
    /// live on the thread, never here; a permission flag would even make codex exit on a remote
    /// resume or fork.
    #[test]
    fn a_codex_tui_attaches_to_its_thread_and_carries_nothing_else() {
        let mut s = attached(spec(AgentKind::Codex));
        s.cwd = "/r/helm/.worktrees/issue-195".into();
        s.model = Some("gpt-6-luna".into());
        s.effort = Some("low".into());
        s.posture = Posture::ReadOnly;
        s.prompt_file = Some("/tmp/q.md".into());
        s.extra_args = vec!["--no-alt-screen".into()];
        let want = [
            "resume",
            "019b-thread",
            "--remote",
            "unix:///r/codex.sock",
            "-c",
            "check_for_update_on_startup=false",
            "-c",
            "notice.hide_rate_limit_model_nudge=true",
            "--no-alt-screen",
        ];
        for conversation in [
            Conversation::New(Some("019b-thread".into())),
            Conversation::Resume("019b-thread".into()),
            Conversation::Fork {
                from: "019a-author".into(),
                id: Some("019b-thread".into()),
            },
        ] {
            s.conversation = conversation;
            let (p, a) = argv(&s).unwrap();
            assert_eq!(p, "/opt/codex/0.160.0/codex", "the server's own program");
            assert_eq!(a, want);
        }
    }

    #[test]
    fn a_codex_on_benchds_server_without_its_thread_is_refused() {
        let s = attached(spec(AgentKind::Codex));
        assert!(argv(&s).unwrap_err().contains("the thread benchd created"));
    }

    /// Outside benchd (the session list's resume of a finished codex), the TUI carries the
    /// posture itself.
    #[test]
    fn a_codex_outside_benchd_carries_its_posture_on_the_command_line() {
        let mut s = spec(AgentKind::Codex);
        s.conversation = Conversation::Resume("019a-fork".into());
        s.posture = Posture::ReadOnly;
        s.model = Some("gpt-5.3-codex".into());
        s.effort = Some("high".into());
        let (p, a) = argv(&s).unwrap();
        assert_eq!(p, "codex");
        assert_eq!(
            a,
            [
                "resume",
                "019a-fork",
                "-s",
                "read-only",
                "-a",
                "never",
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
    }

    #[test]
    fn a_pi_fork_copies_the_conversation_under_the_minted_id_with_only_read_tools() {
        let mut s = spec(AgentKind::Pi);
        s.conversation = Conversation::Fork {
            from: "author-1".into(),
            id: Some("fork-2".into()),
        };
        s.posture = Posture::ReadOnly;
        s.prompt_file = Some("/tmp/q.md".into());
        let (p, a) = argv(&s).unwrap();
        assert_eq!(p, "pi");
        assert_eq!(
            a,
            [
                "--approve",
                "--tools",
                "read,grep,find,ls",
                "--fork",
                "author-1",
                "--session-id",
                "fork-2",
                "Read and act on the prompt in /tmp/q.md"
            ]
        );
        s.conversation = Conversation::Resume("fork-2".into());
        s.prompt_file = None;
        let (_, a) = argv(&s).unwrap();
        assert_eq!(
            a,
            [
                "--approve",
                "--tools",
                "read,grep,find,ls",
                "--session-id",
                "fork-2"
            ],
            "a pi fork resumed later still has only its read tools"
        );
    }

    #[test]
    fn a_claude_or_pi_fork_without_a_minted_id_is_refused() {
        for agent in [AgentKind::Claude, AgentKind::Pi] {
            let mut s = spec(agent);
            s.conversation = Conversation::Fork {
                from: "author-1".into(),
                id: None,
            };
            s.posture = Posture::ReadOnly;
            let err = argv(&s).unwrap_err();
            assert!(err.contains("needs the id benchd mints"), "{err}");
        }
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
}
