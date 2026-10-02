//! benchd's one codex app-server (#466): every codex agent on the bench is a thread on it, and its
//! pane is a TUI attached to that thread (`codex resume <thread> --remote`, `bench_session::argv`).
//!
//! benchd creates each thread itself (`thread/start`, `thread/fork`, `thread/resume`), so the
//! thread carries the agent's cwd, model, effort, posture and environment, and benchd knows its id
//! before anything runs. codex runs every hook with the server's own environment, so a hook says
//! which agent it is only by its `session_id`, which is the thread id: `hook::answer` finds the
//! session that owns it.
//!
//! The server starts on first use, behind the same leash as a `just` run ([`crate::just::LEASH`]):
//! a benchd that dies however it dies closes the pipe, and the server is TERMed. Its environment
//! is benchd's minus every agent variable ([`crate::shell_env::agent_variables`]), plus `BENCH_DIR`
//! so `bench hook codex` reaches this benchd and no other.
//!
//! The wire, measured on codex 0.157.0 and 0.160.0: `app-server --listen unix://PATH` speaks
//! WebSocket over the unix socket, one JSON-RPC message per text frame. benchd holds one
//! connection. It is the one that creates every thread, so codex subscribes it to every thread and
//! sends it every thread's notifications ([`crate::hook::codex_notification`]), which is where
//! attention (#357) reads codex's status. benchd never answers an approval: the TUI owns those.
//! The protocol is versioned (`codex app-server generate-json-schema`); the command itself is
//! labelled experimental.

use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak, mpsc};
use std::time::{Duration, Instant};

/// How long one request may take. A local server answers `turn/start` in about 15 ms and
/// `thread/start` in about 100 ms; `thread/resume` of an unloaded thread reads its rollout.
const ANSWER_WAIT: Duration = Duration::from_secs(10);

/// How long a starting server has to listen.
const LISTEN_WAIT: Duration = Duration::from_secs(10);

/// How long a stopping server has to go once its leash is dropped.
const STOP_WAIT: Duration = Duration::from_secs(3);

/// The server's socket under this root. codex leaves a symlink here and binds a short socket of
/// its own, so a long root still works.
pub fn socket_path(root: &Path) -> PathBuf {
    root.join("codex.sock")
}

/// Where the running server is, if one is. Held across a whole start, never under the core lock:
/// a start waits for the server to listen, and the server's notifications take the core lock.
#[derive(Default)]
pub struct Host(Mutex<Option<Arc<Server>>>);

/// One running app-server and benchd's connection to it.
pub struct Server {
    /// The codex every TUI runs too, resolved once when the server started: a newer codex on disk
    /// reaches the bench when the server restarts, never as a TUI newer than its server.
    pub program: PathBuf,
    pub socket: PathBuf,
    /// The leash's pid: the process benchd started, whose child the server is.
    pub pid: u32,
    wrapper: Mutex<Child>,
    leash: Mutex<Option<ChildStdin>>,
    writer: Mutex<UnixStream>,
    waiting: Mutex<HashMap<u64, mpsc::Sender<Result<Value, String>>>>,
    next_id: AtomicU64,
    /// The threads this connection is subscribed to, so the ones no session owns any more can be
    /// let go ([`Server::release`]).
    subscribed: Mutex<HashSet<String>>,
    /// Threads benchd made or re-entered whose session is not registered yet, each with the
    /// first turn benchd started on it: never let go, and stopped if the spawn fails
    /// ([`Server::abandon`]) so no agent runs that no pane shows.
    pending: Mutex<HashMap<String, Option<String>>>,
    /// Each thread's status as codex last said, so one that changed before its session was
    /// registered is not lost ([`Server::claim`]).
    statuses: Mutex<HashMap<String, String>>,
    gone: Mutex<bool>,
}

/// The running server, started if none runs. `on_note` takes every notification;
/// `on_exit` is told once when the server is gone. Both run on the reader thread.
pub fn ensure(
    host: &Host,
    root: &Path,
    home: &Path,
    on_note: impl Fn(&str, &Value) + Send + 'static,
    on_exit: impl FnOnce(Option<i32>) + Send + 'static,
) -> Result<(Arc<Server>, bool), String> {
    let mut slot = host.0.lock().unwrap();
    if let Some(server) = slot.as_ref().filter(|s| !*s.gone.lock().unwrap()) {
        return Ok((Arc::clone(server), false));
    }
    let (server, frames) = Server::start(root, home)?;
    let weak = Arc::downgrade(&server);
    std::thread::spawn(move || read_loop(frames, weak, on_note, on_exit));
    *slot = Some(Arc::clone(&server));
    Ok((server, true))
}

/// The running server, if one is, without starting one.
pub fn running(host: &Host) -> Option<Arc<Server>> {
    host.0
        .lock()
        .unwrap()
        .as_ref()
        .filter(|s| !*s.gone.lock().unwrap())
        .cloned()
}

/// benchd's server, started if none runs: `ensure` wired to this daemon. Its notifications go to
/// [`crate::hook::codex_notification`]; its start and its end are logged. Never under the core
/// lock.
pub fn server(core: &Arc<Mutex<crate::Core>>) -> Result<Arc<Server>, String> {
    let (host, root, home) = {
        let c = core.lock().unwrap();
        (Arc::clone(&c.codex), c.root.clone(), c.home.clone())
    };
    let notes = Arc::downgrade(core);
    let exits = Arc::downgrade(core);
    let (server, started) = ensure(
        &host,
        &root,
        &home,
        move |method, params| {
            if let Some(core) = notes.upgrade() {
                crate::hook::codex_notification(&core, method, params);
            }
        },
        move |code| {
            if let Some(core) = exits.upgrade() {
                let _ = core
                    .lock()
                    .unwrap()
                    .append("codex/server-exited", json!({ "code": code }));
            }
        },
    )?;
    if started {
        core.lock().unwrap().append(
            "codex/server-started",
            json!({ "pid": server.pid, "program": server.program, "socket": server.socket }),
        )?;
    }
    Ok(server)
}

/// A codex spawn that failed after its thread was made ([`crate::spawn::codex_thread`]): its
/// first turn stopped and its thread let go. Not under the core lock.
pub fn abandon(core: &Arc<Mutex<crate::Core>>, spec: &bench_session::SpawnSpec) {
    let (Some(_), Some(thread)) = (&spec.codex, spec.conversation.id()) else {
        return;
    };
    let host = Arc::clone(&core.lock().unwrap().codex);
    if let Some(server) = running(&host) {
        server.abandon(thread);
    }
}

/// Stop the running server, if one is: `bench stop`.
pub fn stop(host: &Host) {
    if let Some(server) = host.0.lock().unwrap().take() {
        server.stop();
    }
}

impl Server {
    fn start(root: &Path, home: &Path) -> Result<(Arc<Server>, Frames), String> {
        let program =
            crate::agents::resolve("codex", &std::env::var_os("PATH").unwrap_or_default())
                .and_then(|p| std::fs::canonicalize(p).ok())
                .ok_or("no codex on benchd's PATH")?;
        let socket = socket_path(root);
        // A server that died uncleanly can leave its link, and codex refuses to bind over one.
        let _ = std::fs::remove_file(&socket);
        let log = std::fs::File::create(root.join("codex.log"))
            .map_err(|e| format!("cannot create codex.log: {e}"))?;
        let mut command = Command::new("/bin/sh");
        command
            .arg("-c")
            .arg(crate::just::LEASH)
            .arg("sh")
            .arg(&program)
            .args(["app-server", "-c", "check_for_update_on_startup=false"]);
        // A TUI that resumes against a remote server reviews hooks at startup whatever
        // `--dangerously-bypass-hook-trust` says, asking this server's `hooks/list`; each thread
        // runs its hooks with `bypass_hook_trust`, so this only keeps the review screen away.
        match bench_wire::hook::codex_hooks_list(home) {
            Ok(list) => {
                if let Some(trust) = bench_wire::hook::codex_session_trust(&list) {
                    command.args(["-c", &trust]);
                }
            }
            Err(why) => eprintln!("benchd: codex app-server starts without hook trust: {why}"),
        }
        command
            .args(["--listen", &format!("unix://{}", socket.display())])
            .current_dir(home)
            .env("BENCH_DIR", root)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::from(log));
        for name in crate::shell_env::agent_variables() {
            command.env_remove(name);
        }
        for (name, _) in
            std::env::vars_os().filter(|(k, _)| k.to_string_lossy().starts_with("HELM_"))
        {
            command.env_remove(name);
        }
        command.env_remove("CODEX_HOME");
        let mut wrapper = command
            .spawn()
            .map_err(|e| format!("cannot start codex app-server: {e}"))?;
        let leash = wrapper.stdin.take();
        let pid = wrapper.id();
        let (stream, frames) = match listen(&socket, &mut wrapper) {
            Ok(connected) => connected,
            Err(why) => {
                drop(leash);
                let _ = wrapper.kill();
                let _ = wrapper.wait();
                return Err(why);
            }
        };
        let server = Arc::new(Server {
            program,
            socket,
            pid,
            wrapper: Mutex::new(wrapper),
            leash: Mutex::new(leash),
            writer: Mutex::new(stream),
            waiting: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            subscribed: Mutex::new(HashSet::new()),
            pending: Mutex::new(HashMap::new()),
            statuses: Mutex::new(HashMap::new()),
            gone: Mutex::new(false),
        });
        Ok((server, frames))
    }

    /// Ask, and wait for the answer.
    fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        self.waiting.lock().unwrap().insert(id, tx);
        let sent = send(
            &mut self.writer.lock().unwrap(),
            &json!({ "id": id, "method": method, "params": params }),
        );
        let answer = sent.and_then(|()| {
            rx.recv_timeout(ANSWER_WAIT).map_err(|_| {
                format!(
                    "{method}: no answer from codex within {}s",
                    ANSWER_WAIT.as_secs()
                )
            })?
        });
        self.waiting.lock().unwrap().remove(&id);
        answer.map_err(|why| format!("{method}: {why}"))
    }

    /// A new thread for an agent: its id.
    pub fn start_thread(&self, params: Value) -> Result<String, String> {
        let id = thread_id(self.call("thread/start", params)?)?;
        self.hold(&id);
        Ok(id)
    }

    /// A copy of thread `from` that carries on apart from it: its id.
    pub fn fork_thread(&self, from: &str, mut params: Value) -> Result<String, String> {
        params["threadId"] = json!(from);
        let id = thread_id(self.call("thread/fork", params)?)?;
        self.hold(&id);
        Ok(id)
    }

    /// Re-enter thread `id` with `params`. This connection lets go of it first: a loaded thread
    /// nobody else watches is restarted with the new params (the new session's environment
    /// among them), where one still watched keeps its old ones.
    pub fn resume_thread(&self, id: &str, mut params: Value) -> Result<(), String> {
        self.unsubscribe(id);
        params["threadId"] = json!(id);
        params["excludeTurns"] = json!(true);
        self.call("thread/resume", params)?;
        self.hold(id);
        Ok(())
    }

    /// A thread this connection now watches for a session not registered yet.
    fn hold(&self, id: &str) {
        self.subscribed.lock().unwrap().insert(id.to_string());
        self.pending.lock().unwrap().insert(id.to_string(), None);
    }

    /// The model and reasoning effort thread `id` last ran with, as its record says.
    pub fn thread_model(&self, id: &str) -> Result<(Option<String>, Option<String>), String> {
        let answer = self.call(
            "thread/read",
            json!({ "threadId": id, "includeTurns": false }),
        )?;
        let field = |name: &str| answer["thread"][name].as_str().map(str::to_string);
        Ok((field("model"), field("reasoningEffort")))
    }

    /// Start a turn on thread `id` with `text` as the user's message. `Ok` once codex answered
    /// with the turn it started; the TUI renders it as if typed.
    pub fn start_turn(&self, id: &str, text: &str) -> Result<(), String> {
        self.turn(id, text).map(|_| ())
    }

    /// The first turn on a thread benchd made or re-entered for a session not registered yet.
    pub fn first_turn(&self, id: &str, text: &str) -> Result<(), String> {
        let answer = self.turn(id, text);
        if let Some(first) = self.pending.lock().unwrap().get_mut(id) {
            *first = match &answer {
                Ok(turn) => Some(turn.clone()),
                // No answer in time: a turn may be running whose id benchd never got.
                Err(why) if why.contains("no answer") => Some(String::new()),
                // Refused: no turn started.
                Err(_) => None,
            };
        }
        answer.map(|_| ())
    }

    fn turn(&self, id: &str, text: &str) -> Result<String, String> {
        let answer = self.call(
            "turn/start",
            json!({ "threadId": id, "input": [{ "type": "text", "text": text }] }),
        )?;
        Ok(answer["turn"]["id"]
            .as_str()
            .unwrap_or_default()
            .to_string())
    }

    /// The session for thread `id` is registered: it is no longer pending, and this is what
    /// codex last said its status was, if anything.
    pub fn claim(&self, id: &str) -> Option<String> {
        self.pending.lock().unwrap().remove(id);
        self.statuses.lock().unwrap().remove(id)
    }

    /// The spawn of thread `id` failed after the thread was made: stop the turn benchd started
    /// on it and let it go, so nothing runs that no pane shows.
    pub fn abandon(&self, id: &str) {
        let first = self.pending.lock().unwrap().remove(id);
        let stopped = match first {
            Some(Some(turn)) if !turn.is_empty() => self
                .call("turn/interrupt", json!({ "threadId": id, "turnId": turn }))
                .map(|_| ()),
            // `turn/start` got no answer: codex may run a turn benchd has no id for.
            Some(Some(_)) => Err("its first turn got no answer, so benchd has no id for it".into()),
            Some(None) | None => Ok(()),
        };
        if let Err(why) = stopped {
            eprintln!(
                "benchd: codex thread {id} was abandoned, but its first turn was not stopped: {why}"
            );
        }
        self.unsubscribe(id);
    }

    fn unsubscribe(&self, id: &str) {
        self.statuses.lock().unwrap().remove(id);
        if self.subscribed.lock().unwrap().remove(id) {
            let _ = self.call("thread/unsubscribe", json!({ "threadId": id }));
        }
    }

    /// Let go of every thread no session in `owned` holds any more, so codex unloads it once it
    /// is idle (`thread_unload_delay_secs`, 60 s by default) rather than keeping its MCP servers
    /// for the life of the server. A pending thread is kept: its session is on its way. Each
    /// candidate is asked about again (`owned_now`) just before it goes, since its session may
    /// have been registered, and its thread no longer pending, after `owned` was read.
    pub fn release(&self, owned: &HashSet<String>, owned_now: impl Fn(&str) -> bool) {
        let loose: Vec<String> = {
            let pending = self.pending.lock().unwrap();
            self.subscribed
                .lock()
                .unwrap()
                .iter()
                .filter(|id| !owned.contains(*id) && !pending.contains_key(*id))
                .cloned()
                .collect()
        };
        for id in loose.into_iter().filter(|id| !owned_now(id)) {
            self.unsubscribe(&id);
        }
    }

    /// Drop the leash and wait for the server to go; kill the wrapper if it has not.
    fn stop(&self) {
        drop(self.leash.lock().unwrap().take());
        let deadline = Instant::now() + STOP_WAIT;
        let mut wrapper = self.wrapper.lock().unwrap();
        while Instant::now() < deadline {
            if let Ok(Some(_)) = wrapper.try_wait() {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = wrapper.kill();
        let _ = wrapper.wait();
    }
}

/// Whether a thread status says no turn is running: `idle`, or `systemError` after a turn that
/// failed (a usage limit fires no `Stop`, measured on codex 0.157.0).
pub fn stopped(status: &str) -> bool {
    matches!(status, "idle" | "systemError")
}

fn thread_id(answer: Value) -> Result<String, String> {
    answer["thread"]["id"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| "codex answered with no thread id".into())
}

/// Wait for the server to listen, then connect and initialize: the connection's write half,
/// and its read half with whatever arrived after the answer still buffered.
fn listen(socket: &Path, wrapper: &mut Child) -> Result<(UnixStream, Frames), String> {
    let deadline = Instant::now() + LISTEN_WAIT;
    let target = loop {
        if let Ok(target) = std::fs::canonicalize(socket)
            && UnixStream::connect(&target).is_ok()
        {
            break target;
        }
        if let Ok(Some(status)) = wrapper.try_wait() {
            return Err(format!(
                "codex app-server exited ({status}) before it listened"
            ));
        }
        if Instant::now() > deadline {
            return Err(format!(
                "codex app-server did not listen on {} within {}s",
                socket.display(),
                LISTEN_WAIT.as_secs()
            ));
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let mut stream = UnixStream::connect(&target).map_err(|e| format!("connect: {e}"))?;
    let _ = stream.set_write_timeout(Some(ANSWER_WAIT));
    stream
        .write_all(
            b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
              Sec-WebSocket-Key: YmVuY2hkLWNvZGV4LXB1c2g=\r\nSec-WebSocket-Version: 13\r\n\r\n",
        )
        .map_err(|e| format!("handshake: {e}"))?;
    let _ = stream.set_read_timeout(Some(ANSWER_WAIT));
    let mut frames = Frames::new(stream.try_clone().map_err(|e| e.to_string())?);
    frames.upgrade()?;
    send(
        &mut stream,
        &json!({ "id": 0, "method": "initialize",
            "params": { "clientInfo": { "name": "benchd", "version": env!("CARGO_PKG_VERSION") } } }),
    )?;
    loop {
        let message = frames.next()?;
        if message.get("id") == Some(&json!(0)) && message.get("method").is_none() {
            if let Some(error) = message.get("error") {
                return Err(format!("initialize: {error}"));
            }
            break;
        }
    }
    send(&mut stream, &json!({ "method": "initialized" }))?;
    let _ = stream.set_read_timeout(None);
    Ok((stream, frames))
}

/// The reader: answers to whoever waits for them, notifications to `on_note`, and the end of the
/// stream, the server gone, to `on_exit` once.
fn read_loop(
    mut frames: Frames,
    server: Weak<Server>,
    on_note: impl Fn(&str, &Value),
    on_exit: impl FnOnce(Option<i32>),
) {
    while let Ok(message) = frames.next() {
        let Some(server) = server.upgrade() else {
            return;
        };
        match (
            message.get("method").and_then(Value::as_str),
            message.get("id"),
        ) {
            (Some(method), None) => {
                let params = &message["params"];
                if method == "thread/status/changed"
                    && let (Some(thread), Some(status)) = (
                        params["threadId"].as_str(),
                        params["status"]["type"].as_str(),
                    )
                {
                    server
                        .statuses
                        .lock()
                        .unwrap()
                        .insert(thread.to_string(), status.to_string());
                }
                on_note(method, params);
            }
            // A request from the server (an approval): the TUI answers those.
            (Some(_), Some(_)) => {}
            (None, Some(id)) => {
                let answer = match message.get("error") {
                    Some(error) => Err(error
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("refused")
                        .to_string()),
                    None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
                };
                if let Some(tx) = id
                    .as_u64()
                    .and_then(|id| server.waiting.lock().unwrap().remove(&id))
                {
                    let _ = tx.send(answer);
                }
            }
            (None, None) => {}
        }
    }
    let Some(server) = server.upgrade() else {
        return;
    };
    *server.gone.lock().unwrap() = true;
    for (_, tx) in server.waiting.lock().unwrap().drain() {
        let _ = tx.send(Err("the codex app-server is gone".into()));
    }
    let code = {
        let mut wrapper = server.wrapper.lock().unwrap();
        let deadline = Instant::now() + STOP_WAIT;
        loop {
            match wrapper.try_wait() {
                Ok(Some(status)) => break status.code(),
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(50))
                }
                _ => break None,
            }
        }
    };
    on_exit(code);
}

/// One text frame, masked, as a client must send it.
fn send(stream: &mut UnixStream, message: &Value) -> Result<(), String> {
    let payload = message.to_string().into_bytes();
    let mut frame = vec![0x81u8];
    match payload.len() {
        n if n < 126 => frame.push(0x80 | n as u8),
        n if n <= usize::from(u16::MAX) => {
            frame.push(0x80 | 126);
            frame.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            frame.push(0x80 | 127);
            frame.extend_from_slice(&(n as u64).to_be_bytes());
        }
    }
    // A client must mask; the server only unmasks. Nothing here is secret from it.
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    let mask = (nanos ^ std::process::id()).to_be_bytes();
    frame.extend_from_slice(&mask);
    frame.extend(payload.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
    stream.write_all(&frame).map_err(|e| format!("write: {e}"))
}

/// The client half of RFC 6455 as one connection needs it: text frames in, fragments joined;
/// ping and pong read past.
struct Frames {
    stream: UnixStream,
    buf: Vec<u8>,
}

impl Frames {
    fn new(stream: UnixStream) -> Frames {
        Frames {
            stream,
            buf: Vec::new(),
        }
    }

    /// The handshake's answer.
    fn upgrade(&mut self) -> Result<(), String> {
        let end = loop {
            if let Some(i) = self.buf.windows(4).position(|w| w == b"\r\n\r\n") {
                break i + 4;
            }
            self.fill()?;
        };
        let head = String::from_utf8_lossy(&self.buf[..end]).to_string();
        if !head.starts_with("HTTP/1.1 101") {
            return Err(format!(
                "not a websocket: {}",
                head.lines().next().unwrap_or("")
            ));
        }
        self.buf.drain(..end);
        Ok(())
    }

    fn fill(&mut self) -> Result<(), String> {
        let mut chunk = [0u8; 8192];
        match self.stream.read(&mut chunk) {
            Ok(0) => Err("the codex app-server closed the connection".into()),
            Ok(n) => {
                self.buf.extend_from_slice(&chunk[..n]);
                Ok(())
            }
            Err(e) => Err(format!("read: {e}")),
        }
    }

    fn take(&mut self, n: usize) -> Result<Vec<u8>, String> {
        while self.buf.len() < n {
            self.fill()?;
        }
        Ok(self.buf.drain(..n).collect())
    }

    /// The next whole text message.
    fn next(&mut self) -> Result<Value, String> {
        let mut message = Vec::new();
        loop {
            let head = self.take(2)?;
            let (fin, opcode) = (head[0] & 0x80 != 0, head[0] & 0x0f);
            let len = match head[1] & 0x7f {
                126 => {
                    let n = self.take(2)?;
                    u64::from(u16::from_be_bytes([n[0], n[1]]))
                }
                127 => u64::from_be_bytes(self.take(8)?.try_into().unwrap_or([0; 8])),
                n => u64::from(n),
            };
            let mask = if head[1] & 0x80 != 0 {
                Some(self.take(4)?)
            } else {
                None
            };
            let mut payload = self.take(usize::try_from(len).map_err(|e| e.to_string())?)?;
            if let Some(m) = mask {
                payload
                    .iter_mut()
                    .enumerate()
                    .for_each(|(i, b)| *b ^= m[i % 4]);
            }
            match opcode {
                0x8 => return Err("the codex app-server closed the connection".into()),
                0x0..=0x2 => message.extend_from_slice(&payload),
                _ => continue,
            }
            if fin {
                return serde_json::from_slice(&message).map_err(|e| format!("message: {e}"));
            }
        }
    }
}
