//! `restore`: terminal panes whose session ended get one again (M5b, #359).
//!
//! No session outlives the benchd that ran it: a restart, an upgrade or a reboot leaves every
//! terminal pane in the document with no session. That was ruled acceptable (2026-09-27) on one
//! condition, that bringing the panes back is one obvious step: `just resume-all`, which is
//! `bench restore --all`. A pane comes back from its own record, and nothing else:
//!
//! - **An agent was recorded there** (`Surface::Terminal::agent`: its harness, its conversation
//!   and where it ran): that conversation is resumed, with the posture `bench_session::argv`
//!   spells, as a benchd session shown in the same pane, under the mailbox it had. Its first
//!   message is the resume notice (`spawn::wire`), so it starts a turn and carries on.
//! - **Otherwise** the operator's login shell, in the directory the pane's shell was last seen
//!   working in (`Surface::Terminal::cwd`), else the pane's workspace.
//!
//! A pane that already shows a live session is left alone, so a second run changes nothing; and a
//! recorded conversation a live process already holds (resumed elsewhere, inside benchd or not)
//! gets a shell instead of a second, forking resume ([`refusal`]).

use crate::resume_dir::{self, Start};
use crate::{Core, hook, sessions, shells, spawn};
use bench_doc::{PaneId, ResumableAgent};
use bench_session::{AgentKind, Conversation, Posture, Session, SpawnSpec};
use bench_wire::{Actor, RestoreArgs};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// What `restore` did for one pane.
struct Restored {
    pane: PaneId,
    session: String,
    /// `resumed` (the recorded agent's conversation) or `shell`.
    how: &'static str,
    /// Why a recorded agent came back as a shell instead.
    note: Option<String>,
}

pub fn answer(core: &Arc<Mutex<Core>>, args: &Value, by: Option<Actor>) -> Result<Value, String> {
    let args: RestoreArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("restore args: {e}"))?;
    let only = match args.pane.as_deref() {
        Some(p) => Some(PaneId::parse(p.trim()).map_err(|why| format!("restore: {why}"))?),
        None => None,
    };
    let mut prepared = prepare(core, only);
    let mut abandoned: Vec<SpawnSpec> = Vec::new();
    let mut c = core.lock().unwrap();
    let mut next = c.bench.document.clone();
    let waiting = waiting(&c, &next, only);
    if let Some(pane) = only
        && waiting.is_empty()
    {
        drop(c);
        // The pane changed while its thread was being re-entered: that thread goes too.
        for spec in prepared
            .codex
            .into_values()
            .filter_map(Result::ok)
            .map(|r| r.spec)
        {
            crate::codex::abandon(core, &spec);
        }
        let c = core.lock().unwrap();
        return Err(match c.bench.document.pane(pane) {
            None => format!("no pane {pane} — `bench get` lists them"),
            Some(_) => format!("pane {pane} is not a terminal whose session has ended"),
        });
    }
    let mut restored = Vec::new();
    for (pane, workspace, _) in waiting {
        let agent = next.pane(pane).and_then(recorded_agent);
        let cwd = next.pane(pane).and_then(recorded_cwd);
        let shell = |c: &mut Core, note| {
            match cwd.as_deref() {
                Some(dir) => shells::start_in(c, pane, dir),
                None => shells::start(c, pane, workspace.as_ref()),
            }
            .map(|s| (s, "shell", note))
        };
        let resumed = resume(&mut c, pane, agent, &mut prepared, &mut abandoned);
        let one = match resumed {
            Ok(session) => Some((session, "resumed", None)),
            Err(note) => shell(&mut c, note),
        };
        if let Some((session, how, note)) = one {
            // The pane says why its agent did not come back, not only the answer to `restore`,
            // which a release's log swallows.
            if let Some(why) = &note {
                session.print(&format!("bench restore: a shell, not the agent: {why}"));
            }
            next.show_session(pane, &session.id);
            restored.push(Restored {
                pane,
                session: session.id.clone(),
                how,
                note,
            });
        }
    }
    let list: Vec<Value> = restored
        .iter()
        .map(|r| json!({ "pane": r.pane, "session": r.session, "how": r.how, "note": r.note }))
        .collect();
    let change = crate::layout::Change {
        verb: "restore".into(),
        args: json!(args),
        by: by.unwrap_or_else(Actor::agent),
        asked: false,
        next,
        created: None,
        pane: None,
    };
    let committed = crate::layout::commit(&mut c, change);
    drop(c);
    // A thread re-entered for a pane that did not get it (its session failed to start, or the
    // pane turned out held): its first turn is stopped, so nothing runs that no pane shows.
    let unused = prepared
        .codex
        .into_values()
        .filter_map(Result::ok)
        .map(|r| r.spec);
    for spec in abandoned.into_iter().chain(unused) {
        crate::codex::abandon(core, &spec);
    }
    match committed {
        crate::layout::Committed::Failed(why) => Err(why),
        _ => Ok(json!({ "restored": list })),
    }
}

/// Resume `pane`'s recorded agent, or why not: `Err(None)` when it records none.
fn resume(
    c: &mut Core,
    pane: PaneId,
    agent: Option<ResumableAgent>,
    prepared: &mut Prepared,
    abandoned: &mut Vec<SpawnSpec>,
) -> Result<Arc<Session>, Option<String>> {
    // A conversation a live process already holds is not resumed a second time: two
    // processes on one conversation fork it. `just release-resume` resumes its caller's
    // session in a pane of its own before it restores the rest.
    let refused = agent
        .as_ref()
        .and_then(|a| refusal(c, &a.command, &a.session));
    match (agent, refused) {
        (Some(_), Some(why)) => Err(Some(why)),
        // Claude reports its id at start, before anything is said: a conversation nobody
        // wrote in has no transcript, and `claude --resume` of it exits at once. With no
        // transcript there is no branch either, so `plan` recreated no worktree for it.
        (Some(a), None) if a.command == "claude" && !has_transcript(&a.session) => {
            Err(Some(format!(
                "claude conversation {} was never written in: nothing to resume",
                a.session
            )))
        }
        (Some(a), None) => match (prepared.codex.remove(&pane), prepared.plans.get(&pane)) {
            (Some(ready), _) => ready
                .and_then(|r| {
                    let spec = r.spec.clone();
                    start(c, pane, &a, r).inspect_err(|_| abandoned.push(spec))
                })
                .map_err(Some),
            // A codex runs only on a thread `prepare` re-entered on benchd's server; one it
            // did not prepare (held then, free now) waits for the next restore.
            (None, Some(Ok(_))) if a.command == AgentKind::Codex.name() => Err(Some(format!(
                "codex conversation {} was held when this restore began",
                a.session
            ))),
            (None, Some(Ok((at, posture)))) => reserve(c, &a, at, *posture)
                .and_then(|r| start(c, pane, &a, r))
                .map_err(Some),
            (None, Some(Err(why))) => Err(Some(why.clone())),
            // A pane that ended while the lock was let go: the next restore takes it.
            (None, None) => Err(Some("its session ended during this restore".to_string())),
        },
        (None, _) => Err(None),
    }
}

/// Whether and where each recorded agent of the panes a restore takes resumes
/// ([`resume_dir::plan`]: refused while it is live elsewhere; its worktree may be gone, #621).
/// Then a codex's thread has to be re-entered on benchd's app-server before its TUI starts
/// (`spawn::codex_thread`), which asks the server; so each codex pane that will be resumed gets
/// its session reserved and its thread re-entered here too. Both start or ask processes, git and
/// codex, so they are worked out before the lock is taken for the restore.
fn prepare(core: &Arc<Mutex<Core>>, only: Option<PaneId>) -> Prepared {
    let agents: Vec<(PaneId, ResumableAgent)> = {
        let c = core.lock().unwrap();
        let doc = &c.bench.document;
        waiting(&c, doc, only)
            .iter()
            .filter_map(|(pane, _, _)| Some((*pane, doc.pane(*pane).and_then(recorded_agent)?)))
            .collect()
    };
    let plans: HashMap<PaneId, Result<(Start, Posture), String>> = agents
        .iter()
        .map(|(pane, a)| {
            let plan = AgentKind::parse(&a.command, false)
                .and_then(|kind| resume_dir::plan(core, kind, &a.session, &a.cwd));
            (*pane, plan)
        })
        .collect();
    let reserved: Vec<(PaneId, Result<Reserved, String>)> = {
        let mut c = core.lock().unwrap();
        let codex: Vec<&(PaneId, ResumableAgent)> = agents
            .iter()
            .filter(|(_, a)| {
                a.command == AgentKind::Codex.name()
                    && refusal(&c, &a.command, &a.session).is_none()
            })
            .collect();
        codex
            .into_iter()
            .filter_map(|(pane, a)| {
                let (at, posture) = plans.get(pane)?.as_ref().ok()?;
                Some((*pane, reserve(&mut c, a, at, *posture)))
            })
            .collect()
    };
    let codex = reserved
        .into_iter()
        .map(|(pane, r)| {
            let r = r.and_then(|mut r| {
                spawn::codex_thread(core, &mut r.spec, &r.id, &r.handle).map(|()| r)
            });
            (pane, r)
        })
        .collect();
    Prepared { plans, codex }
}

/// What [`prepare`] worked out: where each pane's agent resumes, or why it cannot, and each codex
/// pane's session with its thread already re-entered, or why not.
struct Prepared {
    plans: HashMap<PaneId, Result<(Start, Posture), String>>,
    codex: HashMap<PaneId, Result<Reserved, String>>,
}

/// The terminal panes of `doc` (or only `only`) that show no live session: the ones a restore
/// gives a session.
fn waiting(
    c: &Core,
    doc: &bench_doc::Document,
    only: Option<PaneId>,
) -> Vec<(PaneId, Option<bench_doc::StandardPath>, Option<String>)> {
    doc.terminals()
        .into_iter()
        .filter(|(pane, _, _)| only.is_none_or(|p| p == *pane))
        .filter(|(_, _, session)| {
            session
                .as_deref()
                .is_none_or(|s| !c.sessions.get(s).is_some_and(|s| s.is_live()))
        })
        .collect()
}

/// Whether Claude has written a transcript for conversation `id`:
/// `~/.claude/projects/<dir>/<id>.jsonl`. Always the default profile under HOME (#491): benchd
/// strips any `CLAUDE_CONFIG_DIR` a session would inherit, and a second login it chooses
/// links its `projects` here (`accounts::configured` refuses one that does not), so the resumed
/// claude reads here too.
fn has_transcript(id: &str) -> bool {
    let Some(home) = std::env::var_os("HOME") else {
        return false;
    };
    let config = std::path::Path::new(&home).join(".claude");
    // An id is a hook's word, and it becomes a file name: nothing that can leave the directory.
    if id.is_empty()
        || !id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return false;
    }
    let file = format!("{id}.jsonl");
    std::fs::read_dir(config.join("projects"))
        .into_iter()
        .flatten()
        .flatten()
        .any(|project| project.path().join(&file).is_file())
}

/// Why conversation `runtime`, run by `agent`, must not be resumed now: a live process holds it,
/// and two processes on one conversation fork it; or benchd cannot tell whether one does. Every
/// resume route asks this. A holder is a benchd session, by the id it was started with or the id
/// its hook recorded; an agent whose hook reported it, which is how a codex the operator started
/// in a pane is seen; or a claude benchd never started, by Claude's own registry. The registry is
/// what catches a holder after a benchd restart: hooks are heard only from then on, and an idle
/// claude in another terminal says nothing (2026-10-02). codex refuses a thread another process
/// writes by itself ("already has an active writer", 0.160); pi records no holder.
pub fn refusal(core: &Core, agent: &str, runtime: &str) -> Option<String> {
    let held = |by: String| Some(format!("conversation {runtime} is already live in {by}"));
    let live = |id: &str| core.sessions.get(id).is_some_and(|s| s.is_live());
    let session = core
        .sessions
        .values()
        .find(|s| s.is_live() && s.runtime_session.as_deref() == Some(runtime))
        .map(|s| s.id.clone())
        .or_else(|| {
            core.session_records
                .hosted
                .iter()
                .find_map(|h| match &h.via {
                    bench_wire::HostedVia::Bench { session, .. }
                        if h.id == runtime && live(session) =>
                    {
                        Some(session.clone())
                    }
                    _ => None,
                })
        });
    if let Some(session) = session {
        return held(format!("session {session}"));
    }
    let hooked = core
        .agents
        .iter()
        .filter_map(|(key, agent)| Some((key, agent.as_ref()?)))
        .find(|(key, a)| key.id == runtime && a.is_running());
    if let Some((_, a)) = hooked {
        return held(format!("process {}", a.pid));
    }
    if agent != AgentKind::Claude.name() {
        return None;
    }
    match bench_sessions::claude::holder(&core.home, runtime) {
        Ok(Some(pid)) => held(format!("process {pid}")),
        Ok(None) => None,
        Err(why) => Some(format!(
            "cannot tell whether conversation {runtime} is live elsewhere: {why}"
        )),
    }
}

/// Where the pane's shell was last working, if that directory is still there.
fn recorded_cwd(pane: &bench_doc::Pane) -> Option<String> {
    match &pane.surface {
        bench_doc::Surface::Terminal { cwd: Some(cwd), .. }
            if std::path::Path::new(cwd).is_dir() =>
        {
            Some(cwd.clone())
        }
        _ => None,
    }
}

/// The agent a pane's record names, if it is one benchd can resume.
fn recorded_agent(pane: &bench_doc::Pane) -> Option<ResumableAgent> {
    match &pane.surface {
        bench_doc::Surface::Terminal {
            agent: Some(agent), ..
        } => Some(agent.clone()),
        _ => None,
    }
}

/// A resume's session, reserved: its id, its handle and the spec it will run.
struct Reserved {
    id: String,
    handle: String,
    spec: SpawnSpec,
}

/// Reserve a session for resuming `agent`'s conversation in the folder `at` names and the posture
/// [`resume_dir::plan`] gave it, under the mailbox the record gave it when it has one.
fn reserve(
    core: &mut Core,
    agent: &ResumableAgent,
    at: &Start,
    posture: Posture,
) -> Result<Reserved, String> {
    let kind = AgentKind::parse(&agent.command, false)?;
    let id = format!("s{}", core.next_session);
    core.next_session += 1;
    let hosted = sessions::recorded(core, kind.name(), &agent.session);
    let handle = hosted
        .and_then(|h| h.handle().map(str::to_string))
        .filter(|h| !core.sessions.values().any(|s| &s.handle == h))
        .unwrap_or_else(|| id.clone());
    let conversation = Conversation::Resume(agent.session.clone());
    let account = crate::accounts::for_spawn(core, kind, &conversation)?;
    let mut spec = SpawnSpec {
        agent: kind,
        cwd: at.cwd.clone(),
        model: None,
        effort: None,
        conversation,
        posture,
        prompt_file: None,
        extra_args: Vec::new(),
        settings: None,
        codex: None,
        account,
    };
    spawn::wire(&mut spec, &core.root, at.note.as_deref())?;
    Ok(Reserved { id, handle, spec })
}

/// Start the reserved resume of `agent`'s conversation as a benchd session for `pane`.
fn start(
    core: &mut Core,
    pane: PaneId,
    agent: &ResumableAgent,
    r: Reserved,
) -> Result<Arc<Session>, String> {
    let Reserved { id, handle, spec } = r;
    let session = Session::spawn(
        id.clone(),
        handle.clone(),
        &spec,
        40,
        140,
        &spawn::agent_env(&core.root, &id, &handle),
        core.notices.clone(),
    )?;
    core.sessions.insert(id.clone(), Arc::clone(&session));
    if let Err(why) = sessions::record_account(core, &spec) {
        let _ = core.append(
            "sessions/unrecorded",
            json!({ "session": id, "account": spec.account, "why": why }),
        );
    }
    hook::serve_codex(core, &session);
    let _ = core.append(
        "session/spawned",
        json!({
            "session": id,
            "handle": handle,
            "agent": spec.agent.name(),
            "cwd": spec.cwd,
            "pid": session.pid,
            "runtime_session": agent.session,
            "resumed": true,
            "account": spec.account,
            "pane": pane,
        }),
    );
    Ok(session)
}
