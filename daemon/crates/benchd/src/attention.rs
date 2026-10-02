//! Attention (M1, #357): which sessions need someone, and whom. Three things, each projected from
//! what benchd already sees, never classified from prose:
//!
//! - **waiting** on the operator ([`crate::waiting`]): always his;
//! - **done**: the agent's turn ended (`Transition::TurnEnded`) and it has not started another.
//!   It is addressed to whoever spawned it, and `seen` once the operator focused its pane, or
//!   marked it seen, after the turn ended. Nothing acknowledges or decays it;
//! - **operator mail**: mail it sent the operator that he has not read.
//!
//! The only state is a session's [`AttentionRecord`] in the hosted-sessions record: its spawner,
//! when its last turn ended, and when the operator last looked. It lives there so a finished turn
//! nobody looked at is still one after a daemon restart (a resumed agent reports `SessionStart`,
//! never its old `Stop`). A mark changes only that record: it never closes a pane, ends a session
//! or removes an entry.

use crate::sessions::{self, Refusal, now_ms};
use crate::{Core, hook, waiting};
use bench_doc::PaneId;
use bench_session::Session;
use bench_wire::{
    Activity, Actor, AttentionRecord, Done, Harness, OPERATOR_HANDLE, OperatorMail, Request,
    SessionKey, SessionRow, SessionState, Spawner, hook::Transition,
};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

/// Who a spawn is for, from who asked. An agent benchd spawned names its own handle
/// (`BENCH_HANDLE`); one the operator started in a pane names only the pane, and is whoever holds
/// that pane's mailbox ([`hook::who`]). Anything else is the operator: his gesture, helm acting
/// for him, or him typing `bench spawn` in a shell. Asked outside the core lock: `who` probes
/// processes.
pub fn spawner(core: &Arc<Mutex<Core>>, by: &Actor) -> Spawner {
    let agent = match by {
        Actor::Agent {
            handle: Some(handle),
            ..
        } => Some(handle.clone()),
        Actor::Agent {
            pane: Some(pane), ..
        } => PaneId::parse(pane.trim())
            .ok()
            .and_then(|pane| hook::who(core, pane))
            .map(|who| who.handle),
        _ => None,
    };
    agent.map_or(Spawner::Operator, |handle| Spawner::Agent { handle })
}

/// A hook event's effect on the record of the agent `key`: a turn end stamps when (and, in the
/// pane the operator is looking at, that he saw it); starting work clears it. Written only when it
/// changes, so a busy agent's every tool call writes nothing.
pub fn turn(
    c: &mut Core,
    key: &SessionKey,
    transition: Option<&Transition>,
    pane: Option<PaneId>,
) -> Result<(), String> {
    match transition {
        Some(Transition::TurnEnded) if record(c, key).is_some() => {
            let now = now_ms();
            let looking = pane.is_some() && pane == c.bench.document.focused_pane();
            c.append(
                "agent/done",
                json!({ "harness": key.harness.name(), "session": key.id, "pane": pane, "seen": looking }),
            )?;
            update(c, key, |a| {
                a.turn_ended_ms = Some(now);
                if looking {
                    a.seen_ms = Some(now);
                }
            })
            .map(|_| ())
        }
        Some(Transition::To(now)) if working(now) => {
            // The `agent/state` this transition logs is the record of it.
            update(c, key, |a| a.turn_ended_ms = None).map(|_| ())
        }
        _ => Ok(()),
    }
}

/// The operator's focus arrived at `pane` (`layout::commit`): the conversation in it is seen, when
/// that clears a finished turn. Logged as `sessions/seen` with the `seq` of the change that moved
/// the focus, whose own event says what it was and who asked.
pub fn looked(c: &mut Core, pane: PaneId, seq: u64) -> Result<(), String> {
    let Some(session) = c
        .bench
        .document
        .pane(pane)
        .and_then(|p| p.surface.session())
        .map(str::to_string)
    else {
        return Ok(());
    };
    let Some(key) = waiting::reporting(c, &session).map(|(key, _)| key.clone()) else {
        return Ok(());
    };
    let unseen = record(c, &key).is_some_and(|a| a.turn_ended_ms.is_some() && !seen(a));
    if unseen {
        mark(c, &key, json!({ "pane": pane, "seq": seq }))?;
    }
    Ok(())
}

/// `sessions/seen`: the operator has seen this session's finished turn, as if he had focused its
/// pane. His to say: helm's gesture, or an agent he asked (`asked`). Only a session the record
/// holds; it changes nothing else.
pub fn answer_seen(core: &Arc<Mutex<Core>>, req: &Request) -> Result<Value, Refusal> {
    let by = req.by.clone().unwrap_or_else(Actor::agent);
    if matches!(by, Actor::Agent { .. }) && !req.asked {
        return Err(Refusal::Refused(
            "seen is the operator's: mark it only when he asked you to (--asked)".into(),
        ));
    }
    let key: SessionKey = serde_json::from_value(req.args.clone())
        .map_err(|e| Refusal::Refused(format!("sessions/seen args: {e}")))?;
    let mut c = core.lock().unwrap();
    if record(&c, &key).is_none() {
        return Err(Refusal::Refused(format!(
            "{} session {:?} is not one benchd or helm hosted — `bench sessions --all` lists the ones it can mark",
            key.harness.name(),
            key.id
        )));
    }
    let seen_ms = mark(&mut c, &key, json!({ "verb": "sessions/seen", "by": by }))
        .map_err(Refusal::Failed)?;
    Ok(json!({ "harness": key.harness, "id": key.id, "seen_ms": seen_ms }))
}

/// Stamp `seen_ms`, logged first, then written.
fn mark(c: &mut Core, key: &SessionKey, how: Value) -> Result<u64, String> {
    let now = now_ms();
    c.append(
        "sessions/seen",
        json!({ "harness": key.harness.name(), "session": key.id, "seen_ms": now, "how": how }),
    )?;
    update(c, key, |a| a.seen_ms = Some(now))?;
    Ok(now)
}

/// Whether an activity is work the agent is doing, which no finished turn survives.
fn working(activity: &Activity) -> bool {
    !matches!(activity, Activity::Idle | Activity::Unknown)
}

fn seen(a: &AttentionRecord) -> bool {
    matches!((a.turn_ended_ms, a.seen_ms), (Some(ended), Some(seen)) if seen >= ended)
}

fn record<'a>(c: &'a Core, key: &SessionKey) -> Option<&'a AttentionRecord> {
    c.session_records
        .hosted
        .iter()
        .find(|h| h.key() == *key)
        .map(|h| &h.attention)
}

/// Change one entry's attention and write the record when it changed. A session the record does
/// not hold has nothing to remember: every agent with a mailbox has an entry.
fn update(
    c: &mut Core,
    key: &SessionKey,
    f: impl FnOnce(&mut AttentionRecord),
) -> Result<bool, String> {
    let Some(entry) = c
        .session_records
        .hosted
        .iter_mut()
        .find(|h| h.key() == *key)
    else {
        return Ok(false);
    };
    let before = entry.attention.clone();
    f(&mut entry.attention);
    if entry.attention == before {
        return Ok(false);
    }
    sessions::save_hosted(&c.root, &c.session_records.hosted)?;
    Ok(true)
}

/// The conversation `key`'s finished turn, when it has one and `activity` is not work. The
/// activity is the agent's latest word, which may be newer than the record (codex's `turn/start`
/// push sets it busy before any hook).
pub fn done(c: &Core, key: &SessionKey, activity: Option<&Activity>) -> Option<Done> {
    if activity.is_some_and(working) {
        return None;
    }
    project(record(c, key)?)
}

fn project(a: &AttentionRecord) -> Option<Done> {
    Some(Done {
        since_ms: a.turn_ended_ms?,
        to: a
            .spawner
            .as_ref()
            .map_or(OPERATOR_HANDLE, Spawner::handle)
            .to_string(),
        seen: seen(a),
    })
}

/// A benchd session's finished turn and its mail to the operator, by the agent reporting in it
/// ([`waiting::reporting`]) when one does, else by the session itself, whose conversation is
/// `runtime` (a resumed agent before its first hook).
pub fn of_session(
    c: &Core,
    s: &Session,
    runtime: Option<&str>,
    mail: &HashMap<String, OperatorMail>,
) -> (Option<Done>, Option<OperatorMail>) {
    let mail_from = |handle: &str| mail.get(handle).cloned();
    if let Some((key, agent)) = waiting::reporting(c, &s.id) {
        return (
            done(c, key, agent.activity.as_ref()),
            mail_from(&agent.handle),
        );
    }
    let key = Harness::parse(s.agent.name())
        .zip(runtime)
        .map(|(harness, id)| SessionKey {
            harness,
            id: id.to_string(),
        });
    let done = key.filter(|_| s.is_live()).and_then(|k| done(c, &k, None));
    (done, mail_from(&s.handle))
}

/// A `sessions/all` row's attention: who spawned it, a running row's finished turn, by its own
/// conversation and the activity its harness reports, and its mailbox's unread mail to the
/// operator.
pub fn show(c: &Core, row: &mut SessionRow, operator_mail: &HashMap<String, OperatorMail>) {
    let key = SessionKey {
        harness: row.harness,
        id: row.id.clone(),
    };
    row.spawner = record(c, &key).and_then(|a| a.spawner.clone());
    if let SessionState::Running { activity } = &row.state {
        row.done = done(c, &key, Some(activity));
    }
    row.operator_mail = row
        .mail
        .as_ref()
        .and_then(|m| operator_mail.get(&m.handle).cloned());
}

/// The operator's unread mail, by the handle that sent it. Read once per answer, outside the core
/// lock: it is a directory listing and a few front-matter reads.
pub fn operator_mail(root: &Path) -> HashMap<String, OperatorMail> {
    let mut by_sender: HashMap<String, OperatorMail> = HashMap::new();
    for m in bench_mail::unread_list(root, OPERATOR_HANDLE) {
        let entry = by_sender.entry(m.from.clone()).or_insert(OperatorMail {
            unread: 0,
            since_ms: m.delivered_ms,
            subject: m.subject.clone(),
        });
        entry.unread += 1;
        if m.delivered_ms < entry.since_ms {
            entry.since_ms = m.delivered_ms;
            entry.subject = m.subject;
        }
    }
    by_sender
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(ended: Option<u64>, seen: Option<u64>, spawner: Option<&str>) -> AttentionRecord {
        AttentionRecord {
            spawner: spawner.map(|handle| Spawner::Agent {
                handle: handle.to_string(),
            }),
            turn_ended_ms: ended,
            seen_ms: seen,
        }
    }

    #[test]
    fn a_turn_is_done_once_it_ended_and_seen_once_looked_at_after() {
        assert_eq!(project(&rec(None, Some(5), None)), None);
        let unseen = project(&rec(Some(10), Some(5), None)).unwrap();
        assert_eq!((unseen.since_ms, unseen.seen), (10, false));
        assert_eq!(unseen.to, OPERATOR_HANDLE);
        assert!(project(&rec(Some(10), Some(10), None)).unwrap().seen);
        assert!(!project(&rec(Some(10), None, None)).unwrap().seen);
        assert_eq!(
            project(&rec(Some(10), None, Some("orch"))).unwrap().to,
            "orch"
        );
    }

    #[test]
    fn work_outranks_a_finished_turn() {
        for activity in [
            Activity::Busy,
            Activity::Shell,
            Activity::Waiting { waiting_for: None },
        ] {
            assert!(working(&activity), "{activity:?}");
        }
        assert!(!working(&Activity::Idle));
        assert!(!working(&Activity::Unknown));
    }
}
