//! The sensor in the daemon (#358): `hook` claims an address for an agent the first time its
//! hook reports, keeps what the agent is doing, and hands out its unread mail on the events
//! whose reply the harness puts in front of the model.
//!
//! An idle agent is not waiting for a tool call, so [`deliver_to_idle`] starts a turn for it
//! through the harness's own channel: Claude's inbox socket. Nothing is ever typed into a pty.
//!
//! State lives in `Core::agents`, keyed by the harness's own session id: an agent for a
//! session with a mailbox, `None` for one that was asked once and gets none. The address is
//! written to the hosted-sessions record, so the same session gets the same handle after a
//! daemon restart. What is logged: the claim, each change of activity (never every tool
//! call), each hand-out and push, and an event name this build does not know, once.

use crate::sessions::{self, Refusal};
use crate::{Core, now_rfc3339};
use bench_doc::PaneId;
use bench_wire::hook::{self, Transition};
use bench_wire::{Activity, HookArgs, HookReply, HostedSession, HostedVia, SessionKey};
use serde_json::{Value, json};
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// An agent with a mailbox, as its hook last reported it.
pub struct Agent {
    pub handle: String,
    /// `None` until an event says what it is doing.
    pub activity: Option<Activity>,
    /// It has been given the standing rule. Once per session in this daemon's life, on the
    /// first reply that reaches the model.
    pub told: bool,
    /// Claude's inbox socket, as its hooks last reported it.
    pub socket: Option<PathBuf>,
    /// A push waiting for the turn it should start: when, and the messages it carried.
    pub poked: Option<(Instant, Vec<String>)>,
    /// A push started no turn: nothing more is pushed until the session starts again.
    pub held: bool,
    /// When its hook last reported.
    pub seen: Instant,
}

impl Agent {
    fn new(handle: String) -> Agent {
        Agent {
            handle,
            activity: None,
            told: false,
            socket: None,
            poked: None,
            held: false,
            seen: Instant::now(),
        }
    }

    /// benchd can start a turn for it: a channel it reported, not known to hold pushes.
    pub fn can_push(&self) -> bool {
        self.socket.is_some() && !self.held
    }

    /// Take in one event. Returns the activity when it changed.
    fn observe(&mut self, args: &HookArgs, transition: Option<Transition>) -> Option<Activity> {
        self.seen = Instant::now();
        if let Some(socket) = &args.messaging_socket {
            self.socket = Some(PathBuf::from(socket));
        }
        match args.event.as_str() {
            // A turn started: whatever a push was waiting for has happened.
            "UserPromptSubmit" => self.poked = None,
            // A session that starts again may take pushes again.
            "SessionStart" => {
                self.poked = None;
                self.held = false;
            }
            _ => {}
        }
        let Some(Transition::To(now)) = transition else {
            return None;
        };
        (self.activity.as_ref() != Some(&now)).then(|| {
            self.activity = Some(now.clone());
            now
        })
    }
}

pub fn answer(core: &Arc<Mutex<Core>>, args: &Value) -> Result<Value, Refusal> {
    let mut args: HookArgs = serde_json::from_value(args.clone())
        .map_err(|e| Refusal::Refused(format!("hook args: {e}")))?;
    args.pid = bench_sessions::process::hook_caller(args.pid);
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
    let (handle, rule) = {
        let mut c = core.lock().unwrap();
        if transition.is_none()
            && c.unknown_hook_events
                .insert((args.harness.name(), args.event.clone()))
        {
            c.append(
                "hook/unknown-event",
                json!({ "harness": args.harness.name(), "event": args.event }),
            )
            .map_err(Refusal::Failed)?;
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
                .map(Agent::new);
            c.agents.insert(key.clone(), agent);
        }
        let Some(Some(agent)) = c.agents.get_mut(&key) else {
            return Ok(json!(HookReply::default()));
        };
        let changed = agent.observe(&args, transition);
        let handle = agent.handle.clone();
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
        (handle, rule)
    };

    if !hands_out {
        return Ok(json!(HookReply {
            handle: Some(handle),
            context: None,
        }));
    }

    hand_out(core, handle, rule, &args.event)
}

/// Outside the lock: the mailbox. A rename per message decides who hands it out. The reply's
/// context is the standing rule when it is owed, then one pointer per message.
fn hand_out(
    core: &Arc<Mutex<Core>>,
    handle: String,
    rule: bool,
    event: &str,
) -> Result<Value, Refusal> {
    let root = core.lock().unwrap().root.clone();
    let taken = bench_mail::take_unread(&root, &handle);
    if !taken.is_empty() {
        let mut c = core.lock().unwrap();
        let ids: Vec<&str> = taken.iter().map(|t| t.id.as_str()).collect();
        c.append(
            "mail/delivered",
            json!({ "handle": handle, "mail": ids, "channel": "hook", "event": event }),
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

/// How long a pushed notice has to start a turn. Measured on Claude 2.1.283: an accepted
/// message starts one in 0.1 s. One that has not in this long was held: a session without
/// `crossSessionInbound: "accept"` puts it behind an approval dialog in its pane.
const PUSH_ANSWER_WAIT: Duration = Duration::from_secs(10);

/// A Claude agent that says it is busy or waiting, with mail waiting, is checked against its
/// registry row once it has been this quiet: Esc on a prompt ends a turn and fires no hook
/// (sensor research, run B), so only the row knows it went idle.
const RECONCILE_AFTER: Duration = Duration::from_secs(5);

/// One pass of the delivery reactor: settle pushes that started no turn, notice idle agents
/// the hooks could not report, then start a turn for every idle agent with unread mail.
pub fn deliver_to_idle(core: &Arc<Mutex<Core>>) {
    let (root, home) = {
        let c = core.lock().unwrap();
        (c.root.clone(), c.home.clone())
    };
    settle_unanswered(core, &root);
    reconcile(core, &root, &home);
    let idle: Vec<(SessionKey, String, PathBuf)> = {
        let c = core.lock().unwrap();
        c.agents
            .iter()
            .filter_map(|(key, agent)| Some((key, agent.as_ref()?)))
            .filter(|(_, a)| a.poked.is_none() && a.activity == Some(Activity::Idle))
            .filter_map(|(key, a)| {
                Some((
                    key.clone(),
                    a.handle.clone(),
                    a.socket.clone().filter(|_| !a.held)?,
                ))
            })
            .collect()
    };
    for (key, handle, socket) in idle {
        if bench_mail::unread(&root, &handle) == 0 || !core.lock().unwrap().take_wake_token(&handle)
        {
            continue;
        }
        push(core, &root, &key, &handle, &socket);
    }
}

/// Hand the unread mail to the session's inbox socket as one user message. A failed write
/// puts every message back in the inbox and stops pushing to that session.
fn push(core: &Arc<Mutex<Core>>, root: &Path, key: &SessionKey, handle: &str, socket: &Path) {
    let taken = bench_mail::take_unread(root, handle);
    if taken.is_empty() {
        return;
    }
    let rule = {
        let mut c = core.lock().unwrap();
        match c.agents.get_mut(key) {
            Some(Some(agent)) => !std::mem::replace(&mut agent.told, true),
            _ => false,
        }
    };
    let mut lines: Vec<String> = Vec::new();
    if rule {
        lines.push(hook::standing_rule(handle));
    }
    lines.extend(
        taken
            .iter()
            .map(|t| hook::notice(&t.from, &t.path.display().to_string())),
    );
    let ids: Vec<String> = taken.iter().map(|t| t.id.clone()).collect();
    let sent = poke(socket, &lines.join("\n"));
    let mut c = core.lock().unwrap();
    let Some(Some(agent)) = c.agents.get_mut(key) else {
        return;
    };
    match sent {
        Ok(()) => {
            agent.poked = Some((Instant::now(), ids.clone()));
            let _ = c.append(
                "mail/delivered",
                json!({ "handle": handle, "mail": ids, "channel": "socket" }),
            );
        }
        Err(why) => {
            agent.held = true;
            for id in &ids {
                let _ = bench_mail::unretire(root, handle, id);
            }
            let _ = c.append(
                "mail/held",
                json!({ "handle": handle, "mail": ids, "why": format!("the session's inbox socket refused it: {why}") }),
            );
        }
    }
}

/// One user message into a Claude session's inbox socket — the wire shape measured on
/// 2.1.283 (agent-control-channels research, section 3). An idle session starts a turn with
/// it, a busy one reads it at its next tool call, and it can never answer a prompt.
fn poke(socket: &Path, text: &str) -> Result<(), String> {
    let mut stream = UnixStream::connect(socket).map_err(|e| e.to_string())?;
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    let line = json!({
        "type": "user",
        "message": { "role": "user", "content": text },
        "from": "bench",
    })
    .to_string()
        + "\n";
    stream
        .write_all(line.as_bytes())
        .map_err(|e| e.to_string())?;
    let _ = stream.shutdown(std::net::Shutdown::Write);
    Ok(())
}

/// A push that started no turn in [`PUSH_ANSWER_WAIT`] was held by the session: its messages
/// go back to the inbox, unread, and the session gets no more pushes until it starts again.
/// Its next prompt or tool call delivers them instead.
fn settle_unanswered(core: &Arc<Mutex<Core>>, root: &Path) {
    let mut c = core.lock().unwrap();
    let mut held: Vec<(String, Vec<String>)> = Vec::new();
    for agent in c.agents.values_mut().flatten() {
        if let Some((at, ids)) = &agent.poked
            && at.elapsed() > PUSH_ANSWER_WAIT
        {
            held.push((agent.handle.clone(), ids.clone()));
            agent.poked = None;
            agent.held = true;
        }
    }
    for (handle, ids) in held {
        for id in &ids {
            let _ = bench_mail::unretire(root, &handle, id);
        }
        let _ = c.append(
            "mail/held",
            json!({ "handle": handle, "mail": ids, "why": "the push started no turn: the session held it (is crossSessionInbound \"accept\"?); it waits for the next prompt or tool call" }),
        );
    }
}

/// Claude agents the hooks last saw busy or waiting, quiet for [`RECONCILE_AFTER`], with mail
/// waiting: their registry row says whether they went idle without a hook saying so.
fn reconcile(core: &Arc<Mutex<Core>>, root: &Path, home: &Path) {
    let stale: Vec<(SessionKey, String)> = {
        let c = core.lock().unwrap();
        c.agents
            .iter()
            .filter_map(|(key, agent)| Some((key, agent.as_ref()?)))
            .filter(|(key, a)| {
                key.harness == bench_wire::Harness::Claude
                    && a.can_push()
                    && a.poked.is_none()
                    && a.activity.as_ref().is_some_and(|x| *x != Activity::Idle)
                    && a.seen.elapsed() > RECONCILE_AFTER
            })
            .map(|(key, a)| (key.clone(), a.handle.clone()))
            .filter(|(_, handle)| bench_mail::unread(root, handle) > 0)
            .collect()
    };
    if stale.is_empty() {
        return;
    }
    let (rows, _) = bench_sessions::claude::registry(home, |pid, started| {
        bench_sessions::process::alive(pid, Some(started))
    });
    let mut c = core.lock().unwrap();
    for (key, handle) in stale {
        let idle = rows.iter().any(|r| {
            r.session == key.id
                && matches!(
                    r.activity,
                    Activity::Idle | Activity::Waiting { waiting_for: None }
                )
        });
        let Some(Some(agent)) = c.agents.get_mut(&key) else {
            continue;
        };
        agent.seen = Instant::now();
        if idle {
            agent.activity = Some(Activity::Idle);
            let _ = c.append(
                "agent/state",
                json!({ "harness": key.harness.name(), "session": key.id, "handle": handle, "activity": Activity::Idle, "event": "registry" }),
            );
        }
    }
}
