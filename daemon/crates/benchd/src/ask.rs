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

use crate::Core;
use bench_wire::{
    HELM_ASK_WAIT, HELM_ASKED, HelmAnswer, HelmAsk, HelmAsked, Request, Response, Status,
};
use serde_json::json;
use std::collections::HashMap;
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
    let request: HelmAsk = match serde_json::from_value(req.args.clone()) {
        Ok(r) => r,
        Err(e) => return reply(Status::Refused, Some(format!("helm/ask args: {e}")), None),
    };
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
    match rx.recv_timeout(HELM_ASK_WAIT) {
        Ok(answer) => reply(answer.status, answer.reason, answer.data),
        Err(_) => {
            let mut c = core.lock().unwrap();
            // Taken out under the lock, so an answer arriving from now on is refused as late
            // rather than delivered to nobody. One that won the race is already in the channel.
            if c.asks.by_id.remove(&id).is_none()
                && let Ok(answer) = rx.try_recv()
            {
                return reply(answer.status, answer.reason, answer.data);
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
