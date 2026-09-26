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
use bench_wire::{Activity, Harness, HookArgs, HookReply, HostedSession, HostedVia, SessionKey};
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
    /// It has been given the standing rule. Once per session in this daemon's life, by the
    /// first reply or push that reached it.
    pub told: bool,
    /// Claude's inbox socket, as its hooks last reported it.
    pub socket: Option<PathBuf>,
    /// pi: its extension watches its own inbox and starts its own turn (`wake`), so benchd
    /// never pushes to it but can promise a send will wake it.
    pub wakes_itself: bool,
    pub push: Push,
    /// When its hook last reported.
    pub seen: Instant,
    /// The agent's process, as its last hook reported it: how the session list tells a live
    /// agent from one that was killed (a killed session reports no `SessionEnd`).
    pub pid: u32,
}

/// Where benchd stands with starting turns for an agent.
pub enum Push {
    /// It may be started when idle.
    Ready,
    /// A push is waiting for the turn it should start: when, and the messages it carried.
    Sent { at: Instant, ids: Vec<String> },
    /// A push started no turn. Nothing more is pushed until the session starts again.
    Held,
}

impl Agent {
    fn new(handle: String, harness: Harness, pid: u32) -> Agent {
        Agent {
            wakes_itself: harness == Harness::Pi,
            pid,
            handle,
            activity: None,
            told: false,
            socket: None,
            push: Push::Ready,
            seen: Instant::now(),
        }
    }

    /// benchd can start a turn for it: a channel it reported, not known to hold pushes.
    pub fn can_push(&self) -> bool {
        (self.socket.is_some() || self.wakes_itself) && !matches!(self.push, Push::Held)
    }

    /// Take in one event. Returns the activity when it changed.
    fn observe(&mut self, args: &HookArgs, transition: Option<Transition>) -> Option<Activity> {
        self.seen = Instant::now();
        self.pid = args.pid;
        if let Some(socket) = &args.messaging_socket {
            self.socket = Some(PathBuf::from(socket));
        }
        match args.event.as_str() {
            // A turn started. The payload cannot say whether the push started it or the
            // operator did; either way the session is taking turns, so the push was not held.
            "UserPromptSubmit" if matches!(self.push, Push::Sent { .. }) => {
                self.push = Push::Ready;
            }
            // A session that starts again may take pushes again.
            "SessionStart" => self.push = Push::Ready,
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
    let (handle, rule, idle, root) = {
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
        follow(&mut c, &args, &key).map_err(Refusal::Failed)?;
        if !c.agents.contains_key(&key) {
            let agent = address(&mut c, &args, &key)
                .map_err(Refusal::Failed)?
                .map(|handle| Agent::new(handle, args.harness, args.pid));
            c.agents.insert(key.clone(), agent);
        }
        let Some(Some(agent)) = c.agents.get_mut(&key) else {
            return Ok(json!(HookReply::default()));
        };
        let changed = agent.observe(&args, transition);
        let handle = agent.handle.clone();
        let idle = agent.activity == Some(Activity::Idle);
        // The rule is owed once per session, decided here under the lock so two hooks firing
        // at once cannot both tell it. pi keeps it in its system prompt instead (`rule` below).
        let rule = hands_out && !agent.told && args.harness != Harness::Pi;
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
        (handle, rule, idle, c.root.clone())
    };
    // pi's extension asks for its mail when it sees its inbox change while it is idle, and
    // hands it to `sendUserMessage`, which starts a turn: benchd's wake cap decides.
    let wake = args.harness == Harness::Pi && args.event == "wake";
    let hands_out = hands_out
        && (!wake
            || idle
                && bench_mail::unread(&root, &handle) > 0
                && core.lock().unwrap().take_wake_token(&handle));
    // When pi starts it learns what to watch, and the rule for its system prompt (see
    // `HookReply.rule`).
    let starting = args.harness == Harness::Pi && args.event == "session_start";
    let inbox = starting.then(|| bench_mail::inbox_dir(&root, &handle).display().to_string());
    let pi_rule = starting.then(|| hook::standing_rule(&handle));
    let mut reply = if hands_out {
        let channel = if wake { "pi" } else { "hook" };
        hand_out(core, &handle, rule, &args.event, channel)?
    } else {
        HookReply {
            handle: Some(handle),
            ..HookReply::default()
        }
    };
    reply.inbox = inbox;
    reply.rule = pi_rule;
    Ok(json!(reply))
}

/// Outside the lock: the mailbox. A rename per message decides who hands it out. The reply's
/// context is the standing rule when it is owed, then one pointer per message.
fn hand_out(
    core: &Arc<Mutex<Core>>,
    handle: &str,
    rule: bool,
    event: &str,
    channel: &str,
) -> Result<HookReply, Refusal> {
    let root = core.lock().unwrap().root.clone();
    let taken = bench_mail::take_unread(&root, handle);
    if !taken.is_empty() {
        let ids: Vec<&str> = taken.iter().map(|t| t.id.as_str()).collect();
        core.lock()
            .unwrap()
            .append(
                "mail/delivered",
                json!({ "handle": handle, "mail": ids, "channel": channel, "event": event }),
            )
            .map_err(Refusal::Failed)?;
    }
    let mut lines: Vec<String> = Vec::new();
    if rule {
        lines.push(hook::standing_rule(handle));
    }
    lines.extend(
        taken
            .iter()
            .map(|t| hook::notice(&t.from, &t.path.display().to_string())),
    );
    Ok(HookReply {
        handle: Some(handle.to_string()),
        context: (!lines.is_empty()).then(|| lines.join("\n")),
        inbox: None,
        rule: None,
    })
}

/// A claimed session reporting from a pane other than the one its record names was resumed
/// there (`claude --resume` in a new pane): the record moves to that pane and keeps the
/// handle, so `mail/who` answers the pane the session is in now. The move passes the same rule
/// as a claim, so a detached child that inherited another `HELM_PANE` moves nothing. Runs on
/// every event, because a session this daemon already holds never reaches [`address`]; the
/// terminal is probed only when the pane differs.
fn follow(c: &mut Core, args: &HookArgs, key: &SessionKey) -> Result<(), String> {
    let declared_bench = args
        .bench_session
        .as_deref()
        .is_some_and(|s| !s.trim().is_empty());
    let Some(pane) = args
        .pane
        .as_deref()
        .and_then(|p| PaneId::parse(p.trim()).ok())
    else {
        return Ok(());
    };
    let Some(entry) = c.session_records.hosted.iter().find(|h| h.key() == *key) else {
        return Ok(());
    };
    let recorded = match entry.via {
        HostedVia::Pane { pane, .. } => Some(pane),
        HostedVia::Bench { .. } => None,
    };
    if declared_bench
        || entry.handle().is_none()
        || recorded == Some(pane)
        || !hook::claims_a_mailbox(true, bench_sessions::process::has_terminal(args.pid))
    {
        return Ok(());
    }
    sessions::record_move(c, key, pane, args.pid)
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
/// the hooks could not report, then start a turn for every idle agent with unread mail. The
/// core mutex is held only to read and change agents and to log; every mailbox is read and
/// every file moved outside it.
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
            .filter(|(_, a)| {
                a.can_push() && matches!(a.push, Push::Ready) && a.activity == Some(Activity::Idle)
            })
            .filter_map(|(key, a)| Some((key.clone(), a.handle.clone(), a.socket.clone()?)))
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

/// Hand the unread mail to the session's inbox socket as one user message, the standing rule
/// first if it is still owed.
fn push(core: &Arc<Mutex<Core>>, root: &Path, key: &SessionKey, handle: &str, socket: &Path) {
    let taken = bench_mail::take_unread(root, handle);
    if taken.is_empty() {
        return;
    }
    let owed = matches!(core.lock().unwrap().agents.get(key), Some(Some(a)) if !a.told);
    let mut lines: Vec<String> = Vec::new();
    if owed {
        lines.push(hook::standing_rule(handle));
    }
    lines.extend(
        taken
            .iter()
            .map(|t| hook::notice(&t.from, &t.path.display().to_string())),
    );
    let ids: Vec<String> = taken.iter().map(|t| t.id.clone()).collect();
    match poke(socket, &lines.join("\n")) {
        Ok(()) => {
            let mut c = core.lock().unwrap();
            if let Some(Some(agent)) = c.agents.get_mut(key) {
                agent.told = true;
                agent.push = Push::Sent {
                    at: Instant::now(),
                    ids: ids.clone(),
                };
            }
            let _ = c.append(
                "mail/delivered",
                json!({ "handle": handle, "mail": ids, "channel": "socket" }),
            );
        }
        Err(why) => hold(
            core,
            root,
            key,
            handle,
            &ids,
            &format!("the session's inbox socket refused it: {why}"),
        ),
    }
}

/// A push that reached no model: its messages go back to the inbox, unread, the session gets
/// no more pushes until it starts again, and the log says why. Its next prompt or tool call
/// delivers them instead.
fn hold(
    core: &Arc<Mutex<Core>>,
    root: &Path,
    key: &SessionKey,
    handle: &str,
    ids: &[String],
    why: &str,
) {
    for id in ids {
        let _ = bench_mail::unretire(root, handle, id);
    }
    let mut c = core.lock().unwrap();
    if let Some(Some(agent)) = c.agents.get_mut(key) {
        agent.push = Push::Held;
    }
    let _ = c.append(
        "mail/held",
        json!({ "handle": handle, "mail": ids, "why": why }),
    );
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

/// A push that started no turn in [`PUSH_ANSWER_WAIT`] was held by the session.
fn settle_unanswered(core: &Arc<Mutex<Core>>, root: &Path) {
    let overdue: Vec<(SessionKey, String, Vec<String>)> = {
        let c = core.lock().unwrap();
        c.agents
            .iter()
            .filter_map(|(key, agent)| match agent {
                Some(Agent {
                    handle,
                    push: Push::Sent { at, ids },
                    ..
                }) if at.elapsed() > PUSH_ANSWER_WAIT => {
                    Some((key.clone(), handle.clone(), ids.clone()))
                }
                _ => None,
            })
            .collect()
    };
    for (key, handle, ids) in overdue {
        hold(
            core,
            root,
            &key,
            &handle,
            &ids,
            "the push started no turn: the session held it (is crossSessionInbound \"accept\"?); it waits for the next prompt or tool call",
        );
    }
}

/// Claude agents the hooks last saw busy or waiting, quiet for [`RECONCILE_AFTER`], with mail
/// waiting: their registry row says whether they went idle without a hook saying so.
fn reconcile(core: &Arc<Mutex<Core>>, root: &Path, home: &Path) {
    let quiet: Vec<(SessionKey, String)> = {
        let c = core.lock().unwrap();
        c.agents
            .iter()
            .filter_map(|(key, agent)| Some((key, agent.as_ref()?)))
            .filter(|(key, a)| {
                key.harness == Harness::Claude
                    && a.can_push()
                    && matches!(a.push, Push::Ready)
                    && a.activity.as_ref().is_some_and(|x| *x != Activity::Idle)
                    && a.seen.elapsed() > RECONCILE_AFTER
            })
            .map(|(key, a)| (key.clone(), a.handle.clone()))
            .collect()
    };
    let stale: Vec<(SessionKey, String)> = quiet
        .into_iter()
        .filter(|(_, handle)| bench_mail::unread(root, handle) > 0)
        .collect();
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

/// The mailbox of the agent in a helm pane: of the live agents whose claim put them in that
/// pane, the one whose hook reported last (#358). How helm addresses a pane without a mailroom
/// of its own: a canvas note, and a spawn's answer. Liveness is checked because a killed agent
/// reports no `SessionEnd` and `reconcile` keeps its `seen` fresh while it has unread mail, so
/// without it a dead agent could outrank the live one now in its pane. Checked after the lock is
/// released, like every other process probe here.
pub fn who(core: &Arc<Mutex<Core>>, pane: PaneId) -> Option<bench_wire::MailWho> {
    let mut candidates: Vec<(Instant, bench_wire::MailWho)> = {
        let c = core.lock().unwrap();
        c.agents
            .iter()
            .filter_map(|(key, agent)| Some((key, agent.as_ref()?)))
            .filter(|(key, _)| pane_of(&c, key) == Some(pane))
            .map(|(key, a)| {
                let who = bench_wire::MailWho {
                    handle: a.handle.clone(),
                    harness: key.harness,
                    session: key.id.clone(),
                    pid: a.pid,
                };
                (a.seen, who)
            })
            .collect()
    };
    candidates.retain(|(_, who)| bench_sessions::process::alive(who.pid, None));
    candidates
        .into_iter()
        .max_by_key(|(seen, _)| *seen)
        .map(|(_, who)| who)
}

/// Agents in helm panes as their hooks report them, for the session list: the one source for
/// a pi or codex pane agent, whose harness publishes no registry.
pub fn in_panes(core: &Core) -> Vec<bench_sessions::HookedAgent> {
    core.agents
        .iter()
        .filter_map(|(key, agent)| Some((key, agent.as_ref()?)))
        .filter_map(|(key, a)| {
            let entry = core
                .session_records
                .hosted
                .iter()
                .find(|h| h.key() == *key)?;
            let HostedVia::Pane { pane, .. } = entry.via else {
                return None;
            };
            Some(bench_sessions::HookedAgent {
                harness: key.harness,
                session: key.id.clone(),
                cwd: entry.cwd.clone(),
                pane,
                pid: a.pid,
                activity: a.activity.clone().unwrap_or(Activity::Unknown),
                handle: a.handle.clone(),
            })
        })
        .collect()
}

fn pane_of(core: &Core, key: &SessionKey) -> Option<PaneId> {
    match core
        .session_records
        .hosted
        .iter()
        .find(|h| h.key() == *key)?
        .via
    {
        HostedVia::Pane { pane, .. } => Some(pane),
        HostedVia::Bench { .. } => None,
    }
}
