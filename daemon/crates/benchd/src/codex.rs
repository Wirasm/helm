//! Starting a turn in an idle codex session benchd spawned (#358), through the session's own
//! app-server: the socket its TUI runs against (`bench_wire::codex_server_socket`).
//!
//! The wire, measured on codex 0.157.0: `app-server --listen unix://PATH` speaks WebSocket over
//! the unix socket, one JSON-RPC message per text frame. One connection per push, closed after
//! the answer: `initialize`, `initialized`, then `turn/start` on the thread, whose id is the
//! `session_id` codex's hooks report. A second client needs no `thread/resume` to start a turn,
//! and the TUI renders it as if typed. benchd never answers an approval: the TUI owns those.
//!
//! The protocol is versioned (`codex app-server generate-json-schema`); `turn/start` is in its
//! non-experimental half. The command itself is labelled experimental.

use serde_json::{Value, json};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

/// How long a push may take end to end. A local app-server answers `turn/start` at once
/// (measured: 15 ms from the request to `{"status":"inProgress"}`); the model runs afterwards.
const ANSWER_WAIT: Duration = Duration::from_secs(5);

/// Start a turn on `thread` with `text` as the user's message. `Ok` once the app-server
/// answered with the turn it started.
pub fn start_turn(socket: &Path, thread: &str, text: &str) -> Result<(), String> {
    let mut ws = connect(socket)?;
    ws.call(
        2,
        "turn/start",
        json!({ "threadId": thread, "input": [{ "type": "text", "text": text }] }),
    )?;
    Ok(())
}

/// One connection, initialized.
fn connect(socket: &Path) -> Result<Ws, String> {
    // codex leaves a symlink at the path it was given and binds a short one of its own, so a
    // long root still connects.
    let target = std::fs::canonicalize(socket).map_err(|e| format!("{}: {e}", socket.display()))?;
    let stream = UnixStream::connect(&target).map_err(|e| format!("connect: {e}"))?;
    let _ = stream.set_read_timeout(Some(ANSWER_WAIT));
    let _ = stream.set_write_timeout(Some(ANSWER_WAIT));
    let mut ws = Ws::open(stream, Instant::now() + ANSWER_WAIT)?;
    ws.call(
        1,
        "initialize",
        json!({ "clientInfo": { "name": "benchd", "version": env!("CARGO_PKG_VERSION") } }),
    )?;
    ws.send(&json!({ "method": "initialized" }))?;
    Ok(ws)
}

/// Whether `thread` is running no turn, as its app-server says (`thread/read`'s `status`):
/// `idle`, or `systemError` after a turn that failed. Measured on 0.157.0: a turn refused by a
/// usage limit leaves `systemError`, and a `turn/start` there runs a turn. Waiting on an
/// approval or a question is `active`, so it is not idle.
pub fn thread_idle(socket: &Path, thread: &str) -> Result<bool, String> {
    let mut ws = connect(socket)?;
    let answer = ws.call(2, "thread/read", json!({ "threadId": thread }))?;
    Ok(matches!(
        answer["thread"]["status"]["type"].as_str(),
        Some("idle" | "systemError")
    ))
}

/// The client half of RFC 6455, as much as one request-and-answer needs: text frames out,
/// masked; text frames in, fragments joined; anything else read past.
struct Ws {
    stream: UnixStream,
    buf: Vec<u8>,
    deadline: Instant,
}

impl Ws {
    fn open(mut stream: UnixStream, deadline: Instant) -> Result<Ws, String> {
        stream
            .write_all(
                b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
                  Sec-WebSocket-Key: YmVuY2hkLWNvZGV4LXB1c2g=\r\nSec-WebSocket-Version: 13\r\n\r\n",
            )
            .map_err(|e| format!("handshake: {e}"))?;
        let mut ws = Ws {
            stream,
            buf: Vec::new(),
            deadline,
        };
        let end = loop {
            if let Some(i) = ws.buf.windows(4).position(|w| w == b"\r\n\r\n") {
                break i + 4;
            }
            ws.fill()?;
        };
        let head = String::from_utf8_lossy(&ws.buf[..end]).to_string();
        if !head.starts_with("HTTP/1.1 101") {
            return Err(format!(
                "not a websocket: {}",
                head.lines().next().unwrap_or("")
            ));
        }
        ws.buf.drain(..end);
        Ok(ws)
    }

    fn fill(&mut self) -> Result<(), String> {
        if Instant::now() > self.deadline {
            return Err("no answer in time".into());
        }
        let mut chunk = [0u8; 8192];
        match self.stream.read(&mut chunk) {
            Ok(0) => Err("the app-server closed the connection".into()),
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

    fn send(&mut self, message: &Value) -> Result<(), String> {
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
        self.stream
            .write_all(&frame)
            .map_err(|e| format!("write: {e}"))
    }

    /// The next whole text message.
    fn recv(&mut self) -> Result<Value, String> {
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
                0x8 => return Err("the app-server closed the connection".into()),
                0x0..=0x2 => message.extend_from_slice(&payload),
                _ => continue, // ping, pong: nothing to answer on a connection this short
            }
            if fin {
                return serde_json::from_slice(&message).map_err(|e| format!("answer: {e}"));
            }
        }
    }

    /// Send a request and wait for its answer, reading past notifications.
    fn call(&mut self, id: u64, method: &str, params: Value) -> Result<Value, String> {
        self.send(&json!({ "id": id, "method": method, "params": params }))?;
        loop {
            let message = self.recv()?;
            if message.get("id") != Some(&json!(id)) || message.get("method").is_some() {
                continue;
            }
            if let Some(error) = message.get("error") {
                return Err(format!(
                    "{method}: {}",
                    error
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("refused")
                ));
            }
            return Ok(message.get("result").cloned().unwrap_or(Value::Null));
        }
    }
}
