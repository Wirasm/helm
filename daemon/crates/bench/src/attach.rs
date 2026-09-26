//! `bench attach <session>`: the response line, then the connection is a raw relay. The local
//! terminal goes raw (keystrokes reach the agent unmangled, Ctrl-C included); Ctrl-\ detaches.
//!
//! Since M3 this is also what a helm pane runs to show a session an agent spawned, so it
//! behaves like the pane it is in: when the pane is resized the session's pty follows (a
//! `resize` request on its own connection, so the relay's bytes stay raw), and when the
//! session ends the client ends too, which is what tells helm the pane's process exited.

use crate::{Cli, EXIT_NO_DAEMON, fail, open, read_response_line};
use bench_wire::{Response, SessionArgs, Status};
use rustix::termios::tcgetwinsize;
use std::io::{IsTerminal, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc;
use std::time::Duration;

/// How often the viewer's size is checked. An ioctl, so cheap; a quarter second is below what
/// a person dragging a divider notices.
const SIZE_POLL: Duration = Duration::from_millis(250);

/// Why the relay stopped.
enum Ended {
    /// The viewer pressed Ctrl-\ or closed its input.
    Detached,
    /// The daemon closed the stream: the session ended, was closed, or another viewer took it.
    StreamClosed,
}

pub fn run(cli: Cli) -> i32 {
    let (stream, request_line) = match open(&cli) {
        Ok(pair) => pair,
        Err(code) => return code,
    };
    if let Err(e) = (&stream).write_all(request_line.as_bytes()) {
        eprintln!("bench: write failed ({e})");
        return EXIT_NO_DAEMON;
    }
    let Some(reply) = read_response_line(&stream) else {
        eprintln!(
            "bench: no answer within {}s",
            bench_wire::CLIENT_READ_TIMEOUT.as_secs()
        );
        return EXIT_NO_DAEMON;
    };
    let response: Response = match serde_json::from_str(&reply) {
        Ok(r) => r,
        Err(e) => return fail(&format!("unreadable response ({e}): {}", reply.trim())),
    };
    if response.status != Status::Ok {
        if let Some(reason) = &response.reason {
            eprintln!("bench: {reason}");
        }
        return response.status.exit_code();
    }
    eprintln!("bench: attached — Ctrl-\\ detaches");
    let _ = stream.set_read_timeout(None);
    let session = cli.args["session"].as_str().unwrap_or_default().to_string();

    let saved = raw_mode();
    let (done, ended) = mpsc::channel();
    let down = match stream.try_clone() {
        Ok(sock) => sock,
        Err(_) => return fail("cannot clone stream"),
    };
    relay_down(down, done.clone());
    relay_up(stream, done);
    follow_size(&cli, session);

    let ended = ended.recv().unwrap_or(Ended::Detached);
    restore(saved);
    match ended {
        Ended::Detached => eprintln!("\nbench: detached"),
        Ended::StreamClosed => eprintln!(
            "\nbench: the session's stream closed — it ended, was closed, or another attach took it over"
        ),
    }
    0
}

/// Socket → stdout, byte for byte: escape sequences ride through, which is what lets an OSC
/// from the agent reach whatever terminal hosts this client.
fn relay_down(mut sock: UnixStream, done: mpsc::Sender<Ended>) {
    std::thread::spawn(move || {
        let mut out = std::io::stdout();
        let mut chunk = [0u8; 8192];
        loop {
            match sock.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if out.write_all(&chunk[..n]).is_err() {
                        break;
                    }
                    let _ = out.flush();
                }
            }
        }
        let _ = done.send(Ended::StreamClosed);
    });
}

/// Stdin → socket, until Ctrl-\ (0x1C) or EOF. The byte itself is never forwarded.
fn relay_up(sock: UnixStream, done: mpsc::Sender<Ended>) {
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin();
        let mut chunk = [0u8; 1024];
        loop {
            match stdin.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if let Some(pos) = chunk[..n].iter().position(|&b| b == 0x1c) {
                        if pos > 0 {
                            let _ = (&sock).write_all(&chunk[..pos]);
                        }
                        break;
                    }
                    if (&sock).write_all(&chunk[..n]).is_err() {
                        break;
                    }
                }
            }
        }
        let _ = sock.shutdown(std::net::Shutdown::Both);
        let _ = done.send(Ended::Detached);
    });
}

/// Keep the session's pty the size of this terminal. A failed resize is not worth ending the
/// relay over: the agent keeps its last size, and the next change tries again.
fn follow_size(cli: &Cli, session: String) {
    let Some(mut last) = terminal_size() else {
        return;
    };
    let root = cli.root.clone();
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(SIZE_POLL);
            let Some(now) = terminal_size() else { continue };
            if now == last {
                continue;
            }
            last = now;
            let resize = Cli {
                verb: "resize".into(),
                args: serde_json::json!(SessionArgs {
                    session: session.clone(),
                    rows: Some(now.0),
                    cols: Some(now.1),
                }),
                root: root.clone(),
                asked: false,
            };
            let _ = crate::exchange(&resize);
        }
    });
}

/// The terminal's size, rows then columns, when stdout is one.
pub fn terminal_size() -> Option<(u16, u16)> {
    let out = std::io::stdout();
    if !out.is_terminal() {
        return None;
    }
    let size = tcgetwinsize(&out).ok()?;
    (size.ws_row > 0 && size.ws_col > 0).then_some((size.ws_row, size.ws_col))
}

/// Raw local terminal for the duration. `stty -g` gives a restore token, so whatever the mode
/// was is what comes back.
fn raw_mode() -> Option<String> {
    if !std::io::stdin().is_terminal() {
        return None;
    }
    let saved = std::process::Command::new("stty")
        .arg("-g")
        .stdin(std::process::Stdio::inherit())
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    let _ = std::process::Command::new("stty")
        .args(["raw", "-echo"])
        .stdin(std::process::Stdio::inherit())
        .status();
    saved
}

fn restore(saved: Option<String>) {
    if let Some(token) = saved {
        let _ = std::process::Command::new("stty")
            .arg(token)
            .stdin(std::process::Stdio::inherit())
            .status();
    }
}
