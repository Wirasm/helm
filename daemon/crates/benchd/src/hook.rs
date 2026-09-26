//! The sensor in the daemon (#358): `hook` claims an address for an agent the first time its
//! hook reports, keeps what the agent is doing, and hands out its unread mail on the events
//! whose reply the harness puts in front of the model.
//!
//! State lives in `Core::agents`, keyed by the harness's own session id: an agent for a
//! session with a mailbox, `None` for one that was asked once and gets none. The address itself is written to the hosted-sessions record, so
//! the same session gets the same handle after a daemon restart. What is logged: the claim,
//! each change of activity (never every tool call), each hand-out, and an event name this
//! build does not know, once.

use crate::sessions::{self, Refusal};
use crate::{Core, now_rfc3339};
use bench_doc::PaneId;
use bench_wire::hook::{self, Transition};
use bench_wire::{Activity, HookArgs, HookReply, HostedSession, HostedVia, SessionKey};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

/// An agent with a mailbox, as its hook last reported it.
pub struct Agent {
    pub handle: String,
    /// `None` until an event says what it is doing.
    pub activity: Option<Activity>,
    /// It has been given the standing rule. Once per session in this daemon's life, on the
    /// first reply that reaches the model.
    pub told: bool,
}

pub fn answer(core: &Arc<Mutex<Core>>, args: &Value) -> Result<Value, Refusal> {
    let args: HookArgs = serde_json::from_value(args.clone())
        .map_err(|e| Refusal::Refused(format!("hook args: {e}")))?;
    if args.session.trim().is_empty() {
        return Err(Refusal::Refused(
            "hook: a session id is required — the harness's own session id".into(),
        ));
    }
    let key = SessionKey {
        harness: args.harness,
        id: args.session.clone(),
    };
    let tool = args.tool.as_deref();
    let transition = hook::transition(args.harness, &args.event, tool);
    let hands_out = hook::carries_context(args.harness, &args.event, tool);

    // Under the lock: who this is, and what it is doing now. No mailbox is read here.
    let (handle, rule, root) = {
        let mut c = core.lock().unwrap();
        if transition.is_none() {
            let first = c
                .unknown_hook_events
                .insert((args.harness.name(), args.event.clone()));
            if first {
                c.append(
                    "hook/unknown-event",
                    json!({ "harness": args.harness.name(), "event": args.event }),
                )
                .map_err(Refusal::Failed)?;
            }
        }
        if transition == Some(Transition::Ended) {
            if let Some(Some(agent)) = c.agents.remove(&key) {
                c.append(
                    "agent/ended",
                    json!({ "harness": args.harness.name(), "session": args.session, "handle": agent.handle }),
                )
                .map_err(Refusal::Failed)?;
            }
            return Ok(json!(HookReply::default()));
        }
        if !c.agents.contains_key(&key) {
            let agent = address(&mut c, &args, &key)
                .map_err(Refusal::Failed)?
                .map(|handle| Agent {
                    handle,
                    activity: None,
                    told: false,
                });
            c.agents.insert(key.clone(), agent);
        }
        let Some(Some(agent)) = c.agents.get_mut(&key) else {
            return Ok(json!(HookReply::default()));
        };
        let now = match transition {
            Some(Transition::To(activity)) => Some(activity),
            _ => None,
        };
        let handle = agent.handle.clone();
        let changed = now.filter(|a| agent.activity.as_ref() != Some(a));
        if let Some(a) = &changed {
            agent.activity = Some(a.clone());
        }
        let rule = hands_out && !agent.told;
        if rule {
            agent.told = true;
        }
        if let Some(a) = changed {
            c.append(
                "agent/state",
                json!({ "harness": args.harness.name(), "session": args.session, "handle": handle, "activity": a, "event": args.event }),
            )
            .map_err(Refusal::Failed)?;
        }
        (handle, rule, c.root.clone())
    };

    if !hands_out {
        return Ok(json!(HookReply {
            handle: Some(handle),
            context: None,
        }));
    }

    // Outside the lock: the mailbox. A rename per message decides who hands it out.
    let taken = bench_mail::take_unread(&root, &handle);
    if !taken.is_empty() {
        let mut c = core.lock().unwrap();
        let ids: Vec<&str> = taken.iter().map(|t| t.id.as_str()).collect();
        c.pending_wakes
            .retain(|p| !(p.handle == handle && ids.contains(&p.mail_id.as_str())));
        c.append(
            "mail/delivered",
            json!({ "handle": handle, "mail": ids, "channel": "hook", "event": args.event }),
        )
        .map_err(Refusal::Failed)?;
    }
    let mut lines: Vec<String> = Vec::new();
    if rule {
        lines.push(hook::standing_rule(&handle));
    }
    lines.extend(
        taken
            .iter()
            .map(|t| hook::notice(&t.from, &t.path.display().to_string())),
    );
    Ok(json!(HookReply {
        handle: Some(handle),
        context: (!lines.is_empty()).then(|| lines.join("\n")),
    }))
}

/// The handle of a session reporting for the first time in this daemon's life, or `None`
/// when it gets no mailbox. In order: a session benchd spawned keeps the handle it was
/// spawned with; a session the record already addressed keeps that one (a daemon restart);
/// anyone else is claimed by the rule, and the claim is logged and recorded before the
/// reply.
fn address(c: &mut Core, args: &HookArgs, key: &SessionKey) -> Result<Option<String>, String> {
    if let Some(spawned) = args
        .bench_session
        .as_deref()
        .and_then(|id| c.sessions.get(id))
    {
        let (session, handle) = (spawned.id.clone(), spawned.handle.clone());
        // codex names its session after the fact, so its spawn recorded nothing; the hook's
        // id is the first the daemon hears of it.
        sessions::record_claim(
            c,
            HostedSession {
                harness: args.harness,
                id: args.session.clone(),
                cwd: args.cwd.clone(),
                via: HostedVia::Bench {
                    session,
                    handle: Some(handle.clone()),
                },
                recorded_at: now_rfc3339(),
            },
            args.pid,
        )?;
        return Ok(Some(handle));
    }
    if let Some(handle) = c
        .session_records
        .hosted
        .iter()
        .find(|h| h.key() == *key)
        .and_then(HostedSession::handle)
    {
        return Ok(Some(handle.to_string()));
    }

    let pane = args
        .pane
        .as_deref()
        .and_then(|p| PaneId::parse(p.trim()).ok());
    let bench_session = args
        .bench_session
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let declared = pane.is_some() || bench_session.is_some();
    if !hook::claims_a_mailbox(
        declared,
        declared && bench_sessions::process::has_terminal(args.pid),
    ) {
        return Ok(None);
    }
    let held = c.held_handles();
    let handle = hook::derive_handle(&args.cwd, &args.session, |h| held.contains(h));
    let via = match (pane, bench_session) {
        (Some(pane), _) => HostedVia::Pane {
            pane,
            handle: Some(handle.clone()),
        },
        // Declared by a benchd session this daemon does not hold: one from before a restart.
        // The id is kept; it names where the session came from.
        (None, Some(session)) => HostedVia::Bench {
            session: session.to_string(),
            handle: Some(handle.clone()),
        },
        // `claims_a_mailbox` needs a declaration, so this is never reached.
        (None, None) => return Ok(None),
    };
    sessions::record_claim(
        c,
        HostedSession {
            harness: args.harness,
            id: args.session.clone(),
            cwd: args.cwd.clone(),
            via,
            recorded_at: now_rfc3339(),
        },
        args.pid,
    )?;
    Ok(Some(handle))
}
