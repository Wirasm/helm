//! `screen/get` and `screen/send` (M5b PR 4): an agent reads and types into any terminal on the
//! bench — the operator's shells included — through its session's VT engine, the same bytes his
//! Ghostty draws from.
//!
//! A target is a pane id (the terminal that pane shows) or a session id. Sent text is logged by
//! its length and who sent it, never its content: what is typed into a shell can be a secret.

use crate::Core;
use bench_doc::PaneId;
use bench_session::Session;
use bench_wire::{Actor, ScreenAnswer, ScreenGetArgs, ScreenSendArgs, Verb};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

/// The start and end of a bracketed paste.
const PASTE_START: &str = "\x1b[200~";
const PASTE_END: &str = "\x1b[201~";

pub fn answer(
    core: &Arc<Mutex<Core>>,
    verb: Verb,
    args: &Value,
    by: Option<Actor>,
) -> Result<Value, String> {
    match verb {
        Verb::ScreenSend => send(core, args, by),
        _ => get(core, args),
    }
}

fn get(core: &Arc<Mutex<Core>>, args: &Value) -> Result<Value, String> {
    let args: ScreenGetArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("screen/get args: {e}"))?;
    let session = live_session(core, &args.target)?;
    // The engine answers at a finished frame, which can take up to a second: not under the lock.
    let screen = session.screen(args.history)?;
    Ok(json!(ScreenAnswer {
        session: session.id.clone(),
        rows: screen.rows,
        cols: screen.cols,
        cursor: [screen.cursor.0, screen.cursor.1],
        cursor_visible: screen.cursor_visible,
        title: screen.title,
        pwd: screen.pwd,
        alt_screen: screen.alt_screen,
        bracketed_paste: screen.bracketed_paste,
        lines: screen.lines,
    }))
}

fn send(core: &Arc<Mutex<Core>>, args: &Value, by: Option<Actor>) -> Result<Value, String> {
    let args: ScreenSendArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("screen/send args: {e}"))?;
    let session = live_session(core, &args.target)?;
    let pasted = session.screen(false)?.bracketed_paste;
    let bytes = paste(&args.text, pasted);
    session.write_input(bytes.as_bytes())?;
    // Return on its own, after the paste: inside one, a program takes it as text.
    if args.enter {
        session.write_input(b"\r")?;
    }
    let mut c = core.lock().unwrap();
    c.append(
        "screen/sent",
        json!({
            "session": session.id,
            "bytes": args.text.len(),
            "enter": args.enter,
            "by": by.unwrap_or_else(Actor::agent),
        }),
    )?;
    Ok(json!({ "session": session.id, "bracketed": pasted }))
}

/// `text` as it is typed: whole inside a bracketed paste when the program asked for one, with
/// any paste end inside it taken out so the text cannot end the paste early and run as keys.
fn paste(text: &str, bracketed: bool) -> String {
    if bracketed {
        format!("{PASTE_START}{}{PASTE_END}", text.replace(PASTE_END, ""))
    } else {
        text.to_string()
    }
}

/// The live session `target` names: a pane's, or a session by id.
fn live_session(core: &Arc<Mutex<Core>>, target: &str) -> Result<Arc<Session>, String> {
    let c = core.lock().unwrap();
    let id = match PaneId::parse(target.trim()) {
        Ok(pane) => {
            let found = c
                .bench
                .document
                .pane(pane)
                .ok_or_else(|| format!("no pane {pane} — `bench get` lists them"))?;
            found
                .surface
                .session()
                .ok_or_else(|| {
                    format!("pane {pane} shows no session — a terminal whose session ended gets one from `bench restore {pane}`")
                })?
                .to_string()
        }
        Err(_) => target.trim().to_string(),
    };
    let session = c
        .sessions
        .get(&id)
        .ok_or_else(|| format!("no session {id} — `bench sessions` lists them"))?;
    if !session.is_live() {
        return Err(format!("session {id} has ended"));
    }
    Ok(Arc::clone(session))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_paste_is_bracketed_only_when_asked_and_cannot_end_itself() {
        assert_eq!(paste("ls", false), "ls");
        assert_eq!(paste("ls", true), "\x1b[200~ls\x1b[201~");
        assert_eq!(
            paste("a\x1b[201~rm -rf x\r", true),
            "\x1b[200~arm -rf x\r\x1b[201~"
        );
    }
}
