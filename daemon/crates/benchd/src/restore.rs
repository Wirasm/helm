//! `restore`: terminal panes whose session ended get one again (M5b, #359).
//!
//! No session outlives the benchd that ran it: a restart, an upgrade or a reboot leaves every
//! terminal pane in the document with no session. That was ruled acceptable (2026-09-27) on one
//! condition, that bringing the panes back is one obvious step: `just resume-all`, which is
//! `bench restore --all`. A pane comes back from its own record, and nothing else:
//!
//! - **An agent was recorded there** (`Surface::Terminal::agent`: its harness, its conversation
//!   and where it ran): that conversation is resumed, with the posture `bench_session::argv`
//!   spells, as a benchd session shown in the same pane, under the mailbox it had.
//! - **Otherwise** the operator's login shell, in the pane's workspace.
//!
//! A pane that already shows a live session is left alone, so a second run changes nothing; and a
//! recorded conversation a live session already holds (resumed elsewhere) gets a shell instead of a
//! second, forking resume.

use crate::{Core, claude_settings, shells, spawn};
use bench_doc::{PaneId, ResumableAgent};
use bench_session::{AgentKind, Session, SpawnSpec};
use bench_wire::{Actor, Harness, RestoreArgs, SessionKey};
use serde_json::{Value, json};
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
    let mut c = core.lock().unwrap();
    let mut next = c.bench.document.clone();
    let waiting: Vec<_> = next
        .terminals()
        .into_iter()
        .filter(|(pane, _, _)| only.is_none_or(|p| p == *pane))
        .filter(|(_, _, session)| {
            session
                .as_deref()
                .is_none_or(|s| !c.sessions.get(s).is_some_and(|s| s.is_live()))
        })
        .collect();
    if let Some(pane) = only
        && waiting.is_empty()
    {
        return Err(match next.pane(pane) {
            None => format!("no pane {pane} — `bench get` lists them"),
            Some(_) => format!("pane {pane} is not a terminal whose session has ended"),
        });
    }
    let mut restored = Vec::new();
    for (pane, workspace, _) in waiting {
        let agent = next.pane(pane).and_then(recorded_agent);
        // A conversation a live session already holds is not resumed a second time: two
        // processes on one conversation fork it. `just release-resume` resumes its caller's
        // session in a pane of its own before it restores the rest.
        let resumed = match agent {
            Some(a) if held(&c, &a.session) => Err(Some(format!(
                "conversation {} is already live in another session",
                a.session
            ))),
            Some(a) => resume(&mut c, pane, &a).map_err(Some),
            None => Err(None),
        };
        let one = match resumed {
            Ok(session) => Some((session, "resumed", None)),
            Err(note) => {
                shells::start(&mut c, pane, workspace.as_ref()).map(|s| (s, "shell", note))
            }
        };
        if let Some((session, how, note)) = one {
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
    match crate::layout::commit(&mut c, change) {
        crate::layout::Committed::Failed(why) => Err(why),
        _ => Ok(json!({ "restored": list })),
    }
}

/// Whether a live session already holds conversation `runtime`.
fn held(core: &Core, runtime: &str) -> bool {
    core.sessions
        .values()
        .any(|s| s.is_live() && s.runtime_session.as_deref() == Some(runtime))
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

/// Resume `agent`'s conversation as a benchd session for `pane`, under the mailbox the record
/// gave it when it has one.
fn resume(core: &mut Core, pane: PaneId, agent: &ResumableAgent) -> Result<Arc<Session>, String> {
    let kind = AgentKind::parse(&agent.command, false)?;
    let id = format!("s{}", core.next_session);
    core.next_session += 1;
    let handle = Harness::parse(kind.name())
        .and_then(|harness| {
            let key = SessionKey {
                harness,
                id: agent.session.clone(),
            };
            core.session_records
                .hosted
                .iter()
                .find(|h| h.key() == key)
                .and_then(|h| h.handle().map(str::to_string))
        })
        .filter(|h| !core.sessions.values().any(|s| &s.handle == h))
        .unwrap_or_else(|| id.clone());
    let settings = match kind {
        AgentKind::Claude => Some(claude_settings(&core.root)?),
        _ => None,
    };
    let spec = SpawnSpec {
        agent: kind,
        cwd: agent.cwd.clone(),
        model: None,
        effort: None,
        runtime_session: Some(agent.session.clone()),
        resume: true,
        prompt_file: None,
        extra_args: Vec::new(),
        settings,
        codex_server: None,
    };
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
    let _ = core.append(
        "session/spawned",
        json!({
            "session": id,
            "handle": handle,
            "agent": kind.name(),
            "cwd": agent.cwd,
            "pid": session.pid,
            "runtime_session": agent.session,
            "resumed": true,
            "pane": pane,
        }),
    );
    Ok(session)
}
