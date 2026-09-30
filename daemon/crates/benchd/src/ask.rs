//! Asking helm for what only the window can do (M3): today, drawing itself.
//!
//! benchd never draws, so a verb like `bench get screenshot` is answered by helm. The ask
//! travels on the channel helm already reads — the event log, through `events --follow` — as a
//! `helm/asked` event, and helm answers with a `helm/answer` verb on the socket like any other
//! caller. No second socket and no files as IPC (daemon/AGENTS.md, "Bench-visible means
//! logged"): the ask, its answer, and an ask nobody answered are all in the record.
//!
//! The caller's connection waits for the answer, bounded by `HELM_ASK_WAIT`, which the
//! client's own patience outlasts by construction (`CLIENT_READ_TIMEOUT`). No answer is an
//! error naming the likely cause — no helm follows this bench — rather than a hang.
//!
//! A capture comes back as bytes, and benchd writes the file (M5c): helm may be on another
//! machine, and the caller's path is on this one.

use crate::Core;
use bench_wire::{
    CAPTURE_PNG_KEY, HELM_ASK_WAIT, HELM_ASKED, HelmAnswer, HelmAsk, HelmAskArgs, HelmAsked,
    Request, Response, Status, captures_dir, unbase64,
};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Arc, Mutex};

/// Asks waiting for helm, by id. An id is minted per ask and never reused in a daemon's
/// lifetime, so a late answer cannot be taken for another ask's.
#[derive(Default)]
pub struct Waiting {
    next: u64,
    by_id: HashMap<String, SyncSender<HelmAnswer>>,
}

/// `helm/ask`: log the ask for helm, and wait for its answer.
pub fn ask(core: &Arc<Mutex<Core>>, req: &Request) -> Response {
    let reply = |status: Status, reason: Option<String>, data| Response {
        id: req.id.clone(),
        status,
        reason,
        data,
    };
    let args: HelmAskArgs = match serde_json::from_value(req.args.clone()) {
        Ok(r) => r,
        Err(e) => return reply(Status::Refused, Some(format!("helm/ask args: {e}")), None),
    };
    // Where the capture goes is settled before helm is asked, so a path benchd cannot write is
    // a refusal rather than a window drawn for nothing.
    let out = match &args.ask {
        HelmAsk::Capture { .. } => {
            let root = core.lock().unwrap().root.clone();
            match capture_path(&root, args.out.as_deref()) {
                Ok(path) => path,
                Err(why) => return reply(Status::Refused, Some(why), None),
            }
        }
    };
    let request = args.ask;
    let (tx, rx) = mpsc::sync_channel(1);
    let id = {
        let mut c = core.lock().unwrap();
        c.asks.next += 1;
        let id = format!("a{}", c.asks.next);
        c.asks.by_id.insert(id.clone(), tx);
        let asked = HelmAsked {
            ask: id.clone(),
            request,
        };
        if let Err(why) = c.append(HELM_ASKED, json!(asked)) {
            c.asks.by_id.remove(&id);
            return reply(Status::Error, Some(why), None);
        }
        id
    };
    let delivered = |answer: HelmAnswer| {
        if answer.status != Status::Ok {
            return reply(answer.status, answer.reason, answer.data);
        }
        match write_capture(&out, answer.data) {
            Ok(report) => reply(Status::Ok, None, Some(report)),
            Err(why) => reply(Status::Error, Some(why), None),
        }
    };
    match rx.recv_timeout(HELM_ASK_WAIT) {
        Ok(answer) => delivered(answer),
        Err(_) => {
            let mut c = core.lock().unwrap();
            // Taken out under the lock, so an answer arriving from now on is refused as late
            // rather than delivered to nobody. One that won the race is already in the channel.
            if c.asks.by_id.remove(&id).is_none()
                && let Ok(answer) = rx.try_recv()
            {
                drop(c);
                return delivered(answer);
            }
            let _ = c.append("helm/unanswered", json!({ "ask": id }));
            reply(
                Status::Error,
                Some(format!(
                    "no helm answered within {}s — is a helm running against this bench (the same BENCH_SUITE or HELM_DEFAULTS_SUITE)?",
                    HELM_ASK_WAIT.as_secs()
                )),
                None,
            )
        }
    }
}

/// Where a capture is written: `out` when the caller named one (absolute, a `.png`, in a folder
/// that exists), else a new name under `<root>/captures/`.
fn capture_path(root: &Path, out: Option<&str>) -> Result<PathBuf, String> {
    let path = match out {
        Some(out) => PathBuf::from(out),
        None => {
            let dir = captures_dir(root);
            fs::create_dir_all(&dir).map_err(|e| format!("cannot make {}: {e}", dir.display()))?;
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or(0);
            dir.join(format!("capture-{stamp}.png"))
        }
    };
    if !path.is_absolute() {
        return Err(format!(
            "out must be an absolute path on benchd's machine, not {}",
            path.display()
        ));
    }
    if path.extension().and_then(|e| e.to_str()) != Some("png") {
        return Err(format!("out names a .png, not {}", path.display()));
    }
    if !path.parent().is_some_and(Path::is_dir) {
        return Err(format!(
            "no directory on benchd's machine to write {} into",
            path.display()
        ));
    }
    Ok(path)
}

/// Write the PNG helm sent to `path` (temp then rename, so a reader never sees half a file) and
/// hand back helm's report with `path` where the bytes were.
fn write_capture(path: &Path, data: Option<Value>) -> Result<Value, String> {
    let Some(Value::Object(mut report)) = data else {
        return Err("helm answered the capture with no report".into());
    };
    let png = report
        .remove(CAPTURE_PNG_KEY)
        .and_then(|v| v.as_str().and_then(unbase64))
        .ok_or("helm's capture answer carried no PNG (a helm older than this benchd?)")?;
    let temp = path.with_extension(format!("png.{}.tmp", std::process::id()));
    fs::write(&temp, &png)
        .and_then(|()| fs::rename(&temp, path))
        .map_err(|e| {
            let _ = fs::remove_file(&temp);
            format!("could not write the PNG to {}: {e}", path.display())
        })?;
    report.insert("path".into(), json!(path.display().to_string()));
    Ok(Value::Object(report))
}

/// `helm/answer`: hand helm's answer to the caller waiting on it.
pub fn answer(core: &Arc<Mutex<Core>>, req: &Request) -> Response {
    let reply = |status: Status, reason: Option<String>| Response {
        id: req.id.clone(),
        status,
        reason,
        data: None,
    };
    let answer: HelmAnswer = match serde_json::from_value(req.args.clone()) {
        Ok(a) => a,
        Err(e) => return reply(Status::Refused, Some(format!("helm/answer args: {e}"))),
    };
    let mut c = core.lock().unwrap();
    let Some(waiting) = c.asks.by_id.remove(&answer.ask) else {
        return reply(
            Status::Refused,
            Some(format!(
                "no ask {:?} is waiting — it was answered already or timed out",
                answer.ask
            )),
        );
    };
    let _ = c.append(
        "helm/answered",
        json!({ "ask": answer.ask, "status": answer.status, "reason": answer.reason }),
    );
    // The waiter holds the only receiver and a one-slot channel: this never blocks.
    let _ = waiting.try_send(answer);
    reply(Status::Ok, None)
}
