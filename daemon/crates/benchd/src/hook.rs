//! The sensor in the daemon (#358): `hook` claims an address for an agent the first time its
//! hook reports, keeps what the agent is doing, and hands out its unread mail on the events
//! whose reply the harness puts in front of the model.
//!
//! An idle agent is not waiting for a tool call, so [`deliver_to_idle`] starts a turn for it
//! through the harness's own [`Channel`]: Claude's inbox socket, or benchd's codex app-server for
//! a codex benchd spawned. pi's extension starts its own. Nothing is ever typed into a pty.
//!
//! State lives in `Core::agents`, keyed by the harness's own session id: an agent for a
//! session with a mailbox, `None` for one that was asked once and gets none. The address is
//! written to the hosted-sessions record, so the same session gets the same handle after a
//! daemon restart. What is logged: the claim, each change of activity (never every tool
//! call), each hand-out and push, and, once each, an event name this build does not know and a
//! guest: a session reporting from a place another live agent holds ([`unplace_guest`]).

use crate::layout::{Change, Committed, commit};
use crate::sessions::{self, Refusal};
use crate::{Core, now_rfc3339};
use bench_doc::{Focus, PaneId, ResumableAgent, Surface};
use bench_wire::hook::{self, Transition};
use bench_wire::{
    Activity, Actor, AttentionRecord, Harness, HookArgs, HookReply, HostedSession, HostedVia,
    SessionKey,
};
use serde_json::{Value, json};
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// An agent with a mailbox, as its hook last reported it.
pub struct Agent {
    pub handle: String,
    /// `None` until an event says what it is doing. Changed only by [`Agent::set_activity`].
    pub activity: Option<Activity>,
    /// When `activity` last changed, in epoch ms: how long a waiting agent has waited, and
    /// whether its report is older than what its screen shows (`waiting`).
    pub activity_since_ms: u64,
    /// It has been given the standing rule. Once per session in this daemon's life, by the
    /// first reply or push that reached it.
    pub told: bool,
    /// How a turn is started for it when it is idle; `None` until it has one.
    pub channel: Option<Channel>,
    pub push: Push,
    /// When its hook last reported.
    pub seen: Instant,
    /// The agent's process, as its last hook reported it: how the session list tells a live
    /// agent from one that was killed (a killed session reports no `SessionEnd`).
    pub pid: u32,
    /// When `pid` started, read when the pid was reported, so a pid the kernel has since given
    /// another process is not taken for this agent ([`Agent::is_running`]).
    started_ms: Option<u64>,
    /// The helm pane it runs in now, as its last report from a terminal said: what `mail/who`
    /// answers. `None` outside helm, and in a benchd session. See [`locate`].
    pub pane: Option<PaneId>,
}

fn started_ms(pid: u32) -> Option<u64> {
    bench_sessions::process::started_at_secs(pid).map(|s| s * 1000)
}

/// The harness's own way to start a turn, per agent.
#[derive(Clone)]
pub enum Channel {
    /// Claude's inbox socket, as its hooks last reported it.
    ClaudeSocket(PathBuf),
    /// benchd's codex app-server, where every codex benchd spawned is a thread (#466). A codex
    /// the operator started runs on an app-server benchd cannot reach, so it has no channel.
    Codex,
    /// pi's extension watches its own inbox and starts its own turn (`wake`), so benchd never
    /// pushes to it but can promise a send will wake it.
    PiItself,
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
    fn new(handle: String, channel: Option<Channel>, pid: u32, pane: Option<PaneId>) -> Agent {
        Agent {
            channel,
            pid,
            started_ms: started_ms(pid),
            pane,
            handle,
            activity: None,
            activity_since_ms: sessions::now_ms(),
            told: false,
            push: Push::Ready,
            seen: Instant::now(),
        }
    }

    /// Its process is alive, and is the one its hook reported.
    pub fn is_running(&self) -> bool {
        self.started_ms
            .is_some_and(|ms| bench_sessions::process::alive(self.pid, Some(ms)))
    }

    /// benchd can start a turn for it: a channel it reported, not known to hold pushes.
    pub fn can_push(&self) -> bool {
        self.channel.is_some() && !matches!(self.push, Push::Held)
    }

    /// Take in one event. Returns the activity when it changed.
    fn observe(&mut self, args: &HookArgs, transition: Option<&Transition>) -> Option<Activity> {
        self.seen = Instant::now();
        // A codex on benchd's server is its session's TUI, the pid it was registered with
        // ([`serve_codex`]); a hook's process is the shared server, which outlives every pane.
        if !matches!(self.channel, Some(Channel::Codex)) && self.pid != args.pid {
            self.pid = args.pid;
            self.started_ms = started_ms(args.pid);
        }
        if let Some(socket) = &args.messaging_socket {
            self.channel = Some(Channel::ClaudeSocket(PathBuf::from(socket)));
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
        let now = transition?.activity()?;
        (self.activity.as_ref() != Some(&now)).then(|| {
            self.set_activity(now.clone());
            now
        })
    }

    /// The one way `activity` changes, so `activity_since_ms` always says when it did.
    pub fn set_activity(&mut self, now: Activity) {
        self.activity = Some(now);
        self.activity_since_ms = sessions::now_ms();
    }
}

/// Every codex benchd starts is an agent from the moment its session is: benchd created its
/// thread (`spawn::codex_thread`), so the thread id is known before any hook reports, and benchd
/// has just started its first turn on it, so it is busy. Its thread's typed events
/// ([`codex_notification`]) say what it does from there; its hooks only hand out mail.
pub fn serve_codex(c: &mut Core, session: &bench_session::Session) {
    let (bench_session::AgentKind::Codex, Some(thread)) =
        (session.spec.agent, session.spec.conversation.id())
    else {
        return;
    };
    let key = SessionKey {
        harness: Harness::Codex,
        id: thread.to_string(),
    };
    let mut agent = Agent::new(
        session.handle.clone(),
        Some(Channel::Codex),
        session.pid,
        None,
    );
    // What codex said about the thread before its session was here, if anything: a first turn
    // that already completed, or one that failed at once (a usage limit, only a status).
    let earlier = crate::codex::running(&c.codex)
        .map(|server| server.claim(thread))
        .unwrap_or_default();
    agent.set_activity(earlier.activity.unwrap_or(Activity::Busy));
    c.agents.insert(key.clone(), Some(agent));
    if earlier.ended {
        let pane = c.bench.document.pane_showing_session(&session.id);
        if let Err(why) = crate::attention::turn(c, &key, Some(&Transition::TurnEnded), pane) {
            eprintln!("benchd: codex thread {thread}: its first turn's end not recorded: {why}");
        }
    }
}

/// What benchd's codex app-server says about one of its threads (`codex.rs`'s connection is
/// subscribed to every thread benchd created): codex's own typed events, read as the transition a
/// hook would carry ([`hook::codex_server_transition`]) and applied the way [`answer`] applies a
/// hook's, so `waiting`, `done` and activity see a codex exactly as they see Claude. A turn that
/// completed is `done`; one waiting on an approval or on the user's input waits for the operator;
/// a turn refused by a usage limit (no `Stop`, measured on codex 0.157.0) still leaves it idle,
/// so its mail is pushed.
pub fn codex_notification(core: &Arc<Mutex<Core>>, method: &str, params: &Value) {
    let Some((thread, transition)) = hook::codex_server_transition(method, params) else {
        return;
    };
    let key = SessionKey {
        harness: Harness::Codex,
        id: thread.clone(),
    };
    let mut c = core.lock().unwrap();
    let pane = c
        .sessions
        .values()
        .find(|s| s.is_live() && s.runtime_session.as_deref() == Some(thread.as_str()))
        .and_then(|s| c.bench.document.pane_showing_session(&s.id));
    let Some(Some(agent)) = c.agents.get_mut(&key) else {
        return;
    };
    let changed = transition
        .activity()
        .filter(|now| agent.activity.as_ref() != Some(now));
    if let Some(now) = &changed {
        agent.set_activity(now.clone());
    }
    let handle = agent.handle.clone();
    if let Some(now) = changed {
        let _ = c.append(
            "agent/state",
            json!({ "harness": "codex", "session": thread, "handle": handle, "activity": now, "event": method }),
        );
    }
    if let Err(why) = crate::attention::turn(&mut c, &key, Some(&transition), pane) {
        eprintln!("benchd: codex thread {thread}: {method} not recorded: {why}");
    }
}

pub fn answer(core: &Arc<Mutex<Core>>, args: &Value) -> Result<Value, Refusal> {
    let mut args: HookArgs = serde_json::from_value(args.clone())
        .map_err(|e| Refusal::Refused(format!("hook args: {e}")))?;
    args.pid = bench_sessions::process::hook_caller(args.pid);
    let served =
        args.harness == Harness::Codex && own_codex_thread(&core.lock().unwrap(), &mut args);
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
    let transition = match hook::transition(args.harness, &args.event, tool) {
        // A codex on benchd's server says what it is doing in typed events on benchd's own
        // connection ([`codex_notification`]); its hook still hands out mail and says it ended.
        Some(t) if served && t != Transition::Ended => Some(Transition::Unchanged),
        t => t,
    };
    let hands_out = hook::carries_context(args.harness, &args.event, tool);

    // Under the lock: who this is, and what it is doing now. No mailbox is read here.
    let (handle, rule, idle, root) = {
        let mut c = core.lock().unwrap();
        if let Some(usage) = args.usage.take().filter(|u| u.harness == args.harness) {
            crate::usage::record(&mut c, usage);
        }
        let guest = unplace_guest(&mut c, &mut args, &key).map_err(Refusal::Failed)?;
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
            ended(&mut c, &args, &key, guest).map_err(Refusal::Failed)?;
            return Ok(json!(HookReply::default()));
        }
        if args.harness == Harness::Codex && !served {
            reclaim_codex(&mut c, &args, &key);
        }
        if !c.agents.contains_key(&key) {
            let channel = channel(&c, &args);
            let agent = address(&mut c, &args, &key)
                .map_err(Refusal::Failed)?
                .map(|handle| Agent::new(handle, channel, args.pid, recorded_pane(&c, &key)));
            c.agents.insert(key.clone(), agent);
        }
        locate(&mut c, &args, &key, guest).map_err(Refusal::Failed)?;
        record_in_pane(&mut c, &args, &key).map_err(Refusal::Failed)?;
        let Some(Some(agent)) = c.agents.get_mut(&key) else {
            return Ok(json!(HookReply::default()));
        };
        let changed = agent.observe(&args, transition.as_ref());
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
        let pane = agent_pane(&c, &args, &key);
        crate::attention::turn(&mut c, &key, transition.as_ref(), pane).map_err(Refusal::Failed)?;
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

/// The session ended: benchd forgets it, and its pane no longer holds it. A guest's pane is
/// another agent's ([`unplace_guest`]).
fn ended(c: &mut Core, args: &HookArgs, key: &SessionKey, guest: bool) -> Result<(), String> {
    if !guest {
        forget_in_pane(c, args, key)?;
    }
    c.guests.remove(key);
    if let Some(Some(agent)) = c.agents.remove(key) {
        c.append(
            "agent/ended",
            json!({ "harness": args.harness.name(), "session": args.session, "handle": agent.handle }),
        )?;
    }
    Ok(())
}

/// A codex hook runs in benchd's app-server, with the server's environment, so it never says
/// which benchd session it is from (#466). Its thread does: the session that owns the thread
/// is the one benchd created it for. The hook is then read as that session's own, its process
/// the session's TUI rather than the shared server, so every rule below that reads the declared
/// session (the claim, the pane, the channel) and every liveness check that reads the pid holds
/// for it as for any other agent. A codex the operator started is owned by no session and is
/// read as it came.
fn own_codex_thread(c: &Core, args: &mut HookArgs) -> bool {
    // Only a live one: a thread re-entered by a new session after its old one exited is held by
    // both until the old pane goes, and a thread whose session ended is no longer benchd's (the
    // operator may resume it on codex's own server, where only its hooks say what it does).
    let Some(session) = c
        .sessions
        .values()
        .find(|s| s.is_live() && s.runtime_session.as_deref() == Some(args.session.as_str()))
    else {
        return false;
    };
    args.bench_session = Some(session.id.clone());
    args.pid = session.pid;
    true
}

/// A codex the operator runs himself, in a pane, on a thread a benchd session once held: benchd's
/// entry for it is gone with that session, and his hooks address it afresh. Only his declare a
/// pane; benchd's server runs hooks with no `HELM_PANE`.
fn reclaim_codex(c: &mut Core, args: &HookArgs, key: &SessionKey) {
    let benchds =
        matches!(c.agents.get(key), Some(Some(a)) if matches!(a.channel, Some(Channel::Codex)));
    if args.pane.is_some() && benchds {
        c.agents.remove(key);
    }
}

/// The channel an agent starts with. Claude's is the socket its hooks report, on any event.
fn channel(c: &Core, args: &HookArgs) -> Option<Channel> {
    match args.harness {
        Harness::Pi => Some(Channel::PiItself),
        Harness::Codex => args
            .bench_session
            .as_deref()
            .filter(|id| c.sessions.contains_key(*id))
            .map(|_| Channel::Codex),
        Harness::Claude => None,
    }
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

/// Where a claimed session runs now, from a report on a terminal: the pane it declares, or no
/// pane when it declares none (resumed outside helm, `claude --resume` in another terminal
/// app) or declares a benchd session. A report with no terminal says nothing about where the
/// session is: a detached child inherits `HELM_PANE` (#417), so it moves and drops nothing.
/// Runs on every event, because a session resumed while this daemon holds it never reaches
/// [`address`]; the terminal is probed only when the answer would change. A guest's report says
/// it is not in the pane, terminal or not ([`unplace_guest`]): it leaves the pane remembered for it.
///
/// A change is logged as `mail/moved`, `to` null when it left helm. The record keeps the last
/// pane it was in (the handle never changes), which seeds [`Agent::pane`] after a restart.
fn locate(c: &mut Core, args: &HookArgs, key: &SessionKey, guest: bool) -> Result<(), String> {
    let Some(Some(agent)) = c.agents.get(key) else {
        return Ok(());
    };
    let declared_bench = args
        .bench_session
        .as_deref()
        .is_some_and(|s| !s.trim().is_empty());
    let now = if declared_bench {
        None
    } else {
        args.pane
            .as_deref()
            .and_then(|p| PaneId::parse(p.trim()).ok())
    };
    if now == agent.pane || !guest && !bench_sessions::process::has_terminal(args.pid) {
        return Ok(());
    }
    let (from, handle) = (agent.pane, agent.handle.clone());
    c.append(
        "mail/moved",
        json!({ "handle": handle, "pid": args.pid, "session": key.id, "harness": key.harness.name(), "from": from, "to": now }),
    )?;
    if let Some(Some(agent)) = c.agents.get_mut(key) {
        agent.pane = now;
    }
    match now {
        Some(pane) if recorded_pane(c, key) != Some(pane) => sessions::record_move(c, key, pane),
        _ => Ok(()),
    }
}

/// The pane an agent with a mailbox runs in: the one showing the benchd session it declares, else
/// the helm pane its last report on a terminal named ([`locate`]).
fn agent_pane(c: &Core, args: &HookArgs, key: &SessionKey) -> Option<PaneId> {
    let Some(Some(agent)) = c.agents.get(key) else {
        return None;
    };
    match args
        .bench_session
        .as_deref()
        .filter(|s| !s.trim().is_empty())
    {
        Some(session) => c.bench.document.pane_showing_session(session),
        None => agent.pane,
    }
}

/// Write down which conversation runs in a pane (M5b): what `bench restore` resumes there after
/// a benchd restart. Every harness reports through its hook, so this covers claude, codex and pi
/// alike, and an agent the operator started himself in a shell pane. Written only when it changed.
fn record_in_pane(c: &mut Core, args: &HookArgs, key: &SessionKey) -> Result<(), String> {
    let Some(pane) = agent_pane(c, args, key) else {
        return Ok(());
    };
    let record = ResumableAgent {
        command: key.harness.name().to_string(),
        session: key.id.clone(),
        cwd: args.cwd.clone(),
    };
    set_record(c, pane, Some(record), args, key)
}

/// The agent's session ended: its pane no longer holds it. Not while benchd is stopping, when the
/// ends are benchd's own doing and the record is what brings the pane back.
fn forget_in_pane(c: &mut Core, args: &HookArgs, key: &SessionKey) -> Result<(), String> {
    if c.stopping {
        return Ok(());
    }
    let Some(pane) = agent_pane(c, args, key) else {
        return Ok(());
    };
    let holds = matches!(
        c.bench.document.pane(pane).map(|p| &p.surface),
        Some(Surface::Terminal { agent: Some(a), .. }) if a.session == key.id
    );
    if !holds {
        return Ok(());
    }
    set_record(c, pane, None, args, key)
}

fn set_record(
    c: &mut Core,
    pane: PaneId,
    record: Option<ResumableAgent>,
    args: &HookArgs,
    key: &SessionKey,
) -> Result<(), String> {
    let current = match c.bench.document.pane(pane).map(|p| &p.surface) {
        Some(Surface::Terminal { agent, .. }) => agent.clone(),
        _ => return Ok(()),
    };
    if current == record {
        return Ok(());
    }
    let mut next = c.bench.document.clone();
    next.record_agent(pane, record.clone(), Focus::Leave)
        .map_err(|r| r.to_string())?;
    let handle = c
        .agents
        .get(key)
        .and_then(|a| a.as_ref())
        .map(|a| a.handle.clone());
    let change = Change {
        verb: "pane/agent".into(),
        args: json!({ "pane": pane, "agent": record, "event": args.event }),
        by: Actor::Agent {
            pane: Some(pane.to_string()),
            handle,
        },
        asked: false,
        next,
        created: None,
        pane: Some(pane),
    };
    match commit(c, change) {
        Committed::Failed(why) => Err(why),
        _ => Ok(()),
    }
}

/// The pane the record last saw a session in.
fn recorded_pane(c: &Core, key: &SessionKey) -> Option<PaneId> {
    match c
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
        let forked_from = spawned.spec.conversation.forked_from().map(str::to_string);
        let spawner = c.spawners.get(&session).cloned();
        // A conversation the spawn did not record: the hook's id is the first the daemon hears of
        // it. A fork's record says so, which is what brings it back read-only (#531).
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
                forked_from,
                attention: AttentionRecord {
                    spawner,
                    ..AttentionRecord::default()
                },
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
    // A pane's own agent is one the operator started there.
    let spawner = matches!(via, HostedVia::Pane { .. }).then_some(bench_wire::Spawner::Operator);
    sessions::record_claim(
        c,
        HostedSession {
            harness: args.harness,
            id: args.session.clone(),
            cwd: args.cwd.clone(),
            via,
            recorded_at: now_rfc3339(),
            forked_from: None,
            attention: AttentionRecord {
                spawner,
                ..AttentionRecord::default()
            },
        },
        args.pid,
    )?;
    Ok(Some(handle))
}

/// A hook from a guest is read as declaring no place (#644). A guest is a session reporting from
/// another process in a place a live agent holds: the benchd session it declares (whose handle
/// that agent has, as `waiting` finds a session's agents), else the helm pane. An agent's children
/// inherit both, so one it starts (a test suite's, a workflow's, a conversation it resumes) would
/// otherwise take its handle, its pane's record and the pane's attention. Without a place, a new
/// session claims no mailbox, and an addressed one keeps its own and leaves any pane remembered for
/// it ([`locate`]). The holder's own process reporting a new conversation (`/clear`) is not a guest.
/// Once the holder's process is gone, the next agent started there claims the place; a new session
/// that was a guest keeps no mailbox for its life (`Core::agents` holds `None` for it), so a child
/// that outlives its agent never takes the pane it was started in. Logged once per guest session.
/// Answers whether this hook is a guest's.
fn unplace_guest(c: &mut Core, args: &mut HookArgs, key: &SessionKey) -> Result<bool, String> {
    let Some((holder, agent)) = holder(c, args, key) else {
        return Ok(false);
    };
    let held = json!({ "harness": holder.harness.name(), "session": holder.id, "handle": agent.handle, "pid": agent.pid });
    let place = json!({ "pane": args.pane, "bench_session": args.bench_session });
    args.pane = None;
    args.bench_session = None;
    if c.guests.insert(key.clone()) {
        c.append(
            "agent/guest",
            json!({ "harness": args.harness.name(), "session": args.session, "pid": args.pid, "cwd": args.cwd, "event": args.event, "place": place, "holder": held }),
        )?;
    }
    Ok(true)
}

/// The live agent of another session and process in the place `args` declares ([`unplace_guest`]).
fn holder<'a>(
    c: &'a Core,
    args: &HookArgs,
    key: &SessionKey,
) -> Option<(&'a SessionKey, &'a Agent)> {
    let session_handle = args
        .bench_session
        .as_deref()
        .and_then(|id| c.sessions.get(id.trim()))
        .map(|s| s.handle.as_str());
    let pane = args
        .pane
        .as_deref()
        .and_then(|p| PaneId::parse(p.trim()).ok());
    c.agents
        .iter()
        .filter_map(|(k, agent)| Some((k, agent.as_ref()?)))
        .filter(|(k, a)| {
            *k != key
                && match session_handle {
                    Some(handle) => a.pane.is_none() && a.handle == handle,
                    None => pane.is_some() && a.pane == pane,
                }
        })
        .find(|(_, a)| a.pid != args.pid && a.is_running())
}

/// How long a pushed notice has to start a turn. Measured on Claude 2.1.283: an accepted
/// message starts one in 0.1 s. One that has not in this long was held: a session without
/// `crossSessionInbound: "accept"` puts it behind an approval dialog in its pane.
const PUSH_ANSWER_WAIT: Duration = Duration::from_secs(10);

/// An agent that says it is busy or waiting, with mail waiting, is checked against its
/// harness's own record once it has been this quiet ([`reconcile`]).
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
    release_codex_threads(core);
    let idle: Vec<(SessionKey, String, Channel)> = {
        let c = core.lock().unwrap();
        c.agents
            .iter()
            .filter_map(|(key, agent)| Some((key, agent.as_ref()?)))
            .filter(|(_, a)| {
                a.can_push() && matches!(a.push, Push::Ready) && a.activity == Some(Activity::Idle)
            })
            .filter_map(|(key, a)| match &a.channel {
                Some(Channel::PiItself) | None => None,
                Some(channel) => Some((key.clone(), a.handle.clone(), channel.clone())),
            })
            .collect()
    };
    for (key, handle, channel) in idle {
        if bench_mail::unread(&root, &handle) == 0 || !core.lock().unwrap().take_wake_token(&handle)
        {
            continue;
        }
        push(core, &root, &key, &handle, &channel);
    }
}

/// Hand the unread mail to the agent's channel as one user message, the standing rule first if
/// it is still owed.
fn push(core: &Arc<Mutex<Core>>, root: &Path, key: &SessionKey, handle: &str, channel: &Channel) {
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
    let text = lines.join("\n");
    // The channel names are read back by `daemon/mail-ring.py`'s CHANNELS.
    let (name, sent) = match channel {
        Channel::ClaudeSocket(socket) => ("socket", poke(socket, &text)),
        Channel::Codex => {
            let host = Arc::clone(&core.lock().unwrap().codex);
            let sent = match crate::codex::running(&host) {
                Some(server) => server.start_turn(&key.id, &text),
                None => Err("benchd's codex app-server is not running".into()),
            };
            ("codex", sent)
        }
        Channel::PiItself => return,
    };
    if let Err(why) = sent {
        let why = format!("the {name} channel refused it: {why}");
        return hold(core, root, key, handle, &ids, &why);
    }
    let mut c = core.lock().unwrap();
    let mut started = false;
    if let Some(Some(agent)) = c.agents.get_mut(key) {
        agent.told = true;
        match channel {
            // Claude accepts the message before it knows whether it will start a turn: the
            // session's next `UserPromptSubmit` says it did (`settle_unanswered`).
            Channel::ClaudeSocket(_) => {
                agent.push = Push::Sent {
                    at: Instant::now(),
                    ids: ids.clone(),
                };
            }
            // codex answered with the turn it started, so the agent is busy now, before any
            // hook says so, and is not pushed to again on the next tick.
            _ => {
                agent.set_activity(Activity::Busy);
                started = true;
            }
        }
    }
    let _ = c.append(
        "mail/delivered",
        json!({ "handle": handle, "mail": ids, "channel": name }),
    );
    if started {
        let _ = c.append(
            "agent/state",
            json!({ "harness": key.harness.name(), "session": key.id, "handle": handle, "activity": Activity::Busy, "event": "turn/start" }),
        );
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
/// waiting or waiting on the operator (a wait nobody ends would send him to a pane that is not
/// waiting, M1): Claude's registry row says whether they went idle without a hook saying so, for
/// Esc on a prompt (sensor research, run B). A codex needs no asking: its app-server says when a
/// thread stops running ([`codex_notification`]).
fn reconcile(core: &Arc<Mutex<Core>>, root: &Path, home: &Path) {
    let quiet: Vec<(SessionKey, String, bool)> = {
        let c = core.lock().unwrap();
        c.agents
            .iter()
            .filter_map(|(key, agent)| Some((key, agent.as_ref()?)))
            .filter(|(_, a)| {
                matches!(a.channel, Some(Channel::ClaudeSocket(_)))
                    && a.can_push()
                    && matches!(a.push, Push::Ready)
                    && a.activity.as_ref().is_some_and(|x| *x != Activity::Idle)
                    && a.seen.elapsed() > RECONCILE_AFTER
            })
            .map(|(key, a)| {
                let waiting = matches!(a.activity, Some(Activity::Waiting { .. }));
                (key.clone(), a.handle.clone(), waiting)
            })
            .collect()
    };
    let stale: Vec<_> = quiet
        .into_iter()
        .filter(|(_, handle, waiting)| *waiting || bench_mail::unread(root, handle) > 0)
        .map(|(key, handle, _)| (key, handle))
        .collect();
    if stale.is_empty() {
        return;
    }
    let idle = went_idle(home, &stale);
    let mut c = core.lock().unwrap();
    for ((key, handle), idle) in stale.into_iter().zip(idle) {
        let Some(Some(agent)) = c.agents.get_mut(&key) else {
            continue;
        };
        agent.seen = Instant::now();
        if let Some(record) = idle {
            agent.set_activity(Activity::Idle);
            let _ = c.append(
                "agent/state",
                json!({ "harness": key.harness.name(), "session": key.id, "handle": handle, "activity": Activity::Idle, "event": record }),
            );
        }
    }
}

/// Per agent, the registry row that says it is idle, or `None`. Read outside the core lock: it
/// is disk.
fn went_idle(home: &Path, agents: &[(SessionKey, String)]) -> Vec<Option<&'static str>> {
    let rows = bench_sessions::claude::registry(home, |pid, started| {
        bench_sessions::process::alive(pid, Some(started))
    })
    .0;
    agents
        .iter()
        .map(|(key, _)| {
            rows.iter()
                .any(|r| {
                    r.session == key.id
                        && matches!(
                            r.activity,
                            Activity::Idle | Activity::Waiting { waiting_for: None }
                        )
                })
                .then_some("registry")
        })
        .collect()
}

/// benchd's codex connection lets go of every thread no session holds any more (its pane
/// closed, `bench close`), so codex unloads it once idle. An exited session whose pane remains
/// keeps its thread until it is resumed or its pane goes. Outside the core lock: it asks codex.
fn release_codex_threads(core: &Arc<Mutex<Core>>) {
    let (host, owned) = {
        let c = core.lock().unwrap();
        let owned: std::collections::HashSet<String> = c
            .sessions
            .values()
            .filter_map(|s| s.runtime_session.clone())
            .collect();
        (Arc::clone(&c.codex), owned)
    };
    if let Some(server) = crate::codex::running(&host) {
        server.release(&owned, |thread| {
            core.lock()
                .unwrap()
                .sessions
                .values()
                .any(|s| s.runtime_session.as_deref() == Some(thread))
        });
    }
}

/// The mailbox of the agent in a helm pane: of the live agents whose claim put them in that
/// pane, the one whose hook reported last (#358). How helm addresses a pane without a mailroom
/// of its own: a canvas note, and a spawn's answer. Liveness is checked because a killed agent
/// reports no `SessionEnd` and `reconcile` keeps its `seen` fresh while it has unread mail, so
/// without it a dead agent could outrank the live one now in its pane. Checked after the lock is
/// released, like every other process probe here.
pub fn who(core: &Arc<Mutex<Core>>, pane: PaneId) -> Option<bench_wire::MailWho> {
    if let Some(who) = session_in(&core.lock().unwrap(), pane) {
        return Some(who);
    }
    let mut candidates: Vec<(Instant, bench_wire::MailWho)> = {
        let c = core.lock().unwrap();
        c.agents
            .iter()
            .filter_map(|(key, agent)| Some((key, agent.as_ref()?)))
            .filter(|(_, a)| a.pane == Some(pane))
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

/// The agent in a pane that shows one of benchd's own sessions (M3): benchd spawned it, so it
/// knows the address without waiting for a hook. `session` is the conversation it runs now
/// ([`conversation`]), else benchd's session id (a codex no hook has reported yet).
fn session_in(core: &Core, pane: PaneId) -> Option<bench_wire::MailWho> {
    let id = core.bench.document.pane(pane)?.surface.session()?;
    let session = core.sessions.get(id).filter(|s| s.is_live())?;
    Some(bench_wire::MailWho {
        handle: session.handle.clone(),
        harness: bench_wire::Harness::parse(session.agent.name())?,
        session: conversation(core, session).unwrap_or_else(|| session.id.clone()),
        pid: session.pid,
    })
}

/// The conversation benchd session `s` runs now, by the session list's rule
/// ([`bench_sessions::conversation`]): what its agent's hook reported last, else the id it was
/// started with. `None` for a shell, and for a codex no hook has reported yet.
pub fn conversation(core: &Core, s: &bench_session::Session) -> Option<String> {
    let Some(harness) = bench_wire::Harness::parse(s.agent.name()) else {
        return s.runtime_session.clone();
    };
    bench_sessions::conversation(
        &hooked(core),
        harness,
        &s.handle,
        s.runtime_session.as_deref(),
        &bench_sessions::process::alive,
    )
}

/// Agents helm hosted as their hooks report them, for the session list: the one source for
/// a pi or codex pane agent, whose harness publishes no registry. One that has left helm is
/// here too, with no pane, so the list neither places it in a pane nor calls it finished.
pub fn hooked(core: &Core) -> Vec<bench_sessions::HookedAgent> {
    core.agents
        .iter()
        .filter_map(|(key, agent)| Some((key, agent.as_ref()?)))
        .filter_map(|(key, a)| {
            let entry = core
                .session_records
                .hosted
                .iter()
                .find(|h| h.key() == *key)?;
            Some(bench_sessions::HookedAgent {
                harness: key.harness,
                session: key.id.clone(),
                cwd: entry.cwd.clone(),
                pane: a.pane,
                pid: a.pid,
                activity: a.activity.clone().unwrap_or(Activity::Unknown),
                handle: a.handle.clone(),
                reported_ms: sessions::now_ms().saturating_sub(a.seen.elapsed().as_millis() as u64),
            })
        })
        .collect()
}
