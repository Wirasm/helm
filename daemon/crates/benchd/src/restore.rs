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
//! recorded conversation a live session already holds (resumed elsewhere) gets a shell instead of a
//! second, forking resume.

use crate::{Core, hook, sessions, shells, spawn};
use bench_doc::{PaneId, ResumableAgent};
use bench_session::{AgentKind, Conversation, Posture, Session, SpawnSpec};
use bench_wire::{Actor, RestoreArgs};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
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
    // Asking codex for its hook trust starts a process, so it is asked before the lock is
    // taken for the restore, once per directory a codex is recorded in.
    let codex_dirs: HashSet<String> = {
        let c = core.lock().unwrap();
        let doc = &c.bench.document;
        waiting(&c, doc, only)
            .iter()
            .filter_map(|(pane, _, _)| doc.pane(*pane).and_then(recorded_agent))
            .filter(|a| a.command == AgentKind::Codex.name())
            .map(|a| a.cwd)
            .collect()
    };
    let trusts: HashMap<String, Option<String>> = codex_dirs
        .into_iter()
        .map(|cwd| (spawn::codex_hook_trust(&cwd), cwd))
        .map(|(trust, cwd)| (cwd, trust))
        .collect();
    let mut c = core.lock().unwrap();
    let mut next = c.bench.document.clone();
    let waiting = waiting(&c, &next, only);
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
        let cwd = next.pane(pane).and_then(recorded_cwd);
        let shell = |c: &mut Core, note| {
            match cwd.as_deref() {
                Some(dir) => shells::start_in(c, pane, dir),
                None => shells::start(c, pane, workspace.as_ref()),
            }
            .map(|s| (s, "shell", note))
        };
        // A conversation a live session already holds is not resumed a second time: two
        // processes on one conversation fork it. `just release-resume` resumes its caller's
        // session in a pane of its own before it restores the rest.
        let resumed = match agent {
            Some(a) if held(&c, &a.session) => Err(Some(format!(
                "conversation {} is already live in another session",
                a.session
            ))),
            // Claude reports its id at start, before anything is said: a conversation nobody
            // wrote in has no transcript, and `claude --resume` of it exits at once.
            Some(a) if a.command == "claude" && !has_transcript(&a.session) => Err(Some(format!(
                "claude conversation {} was never written in: nothing to resume",
                a.session
            ))),
            Some(a) => {
                let trust = trusts.get(&a.cwd).cloned().flatten();
                resume(&mut c, pane, &a, trust).map_err(Some)
            }
            None => Err(None),
        };
        let one = match resumed {
            Ok(session) => Some((session, "resumed", None)),
            Err(note) => shell(&mut c, note),
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
/// strips `CLAUDE_CONFIG_DIR` from every session it spawns, so the resumed claude reads here too.
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

/// Whether a live session already holds conversation `runtime`: by the id it was started with,
/// or, for a codex that names its thread after the fact, by the id its hook recorded; or a live
/// agent whose hook reported it, which is how a codex the operator started in a pane is seen.
/// A thread a benchd codex left with `/new` stays held until that session ends: its app-server
/// keeps the thread open, and a second codex on it is read-only ("This conversation is open in
/// another app", measured on codex 0.159.3). The operator's own codex ends the old thread on
/// `/new` (`SessionEnd`), so his is free at once.
pub fn held(core: &Core, runtime: &str) -> bool {
    let live = |id: &str| core.sessions.get(id).is_some_and(|s| s.is_live());
    core.sessions
        .values()
        .any(|s| s.is_live() && s.runtime_session.as_deref() == Some(runtime))
        || core.session_records.hosted.iter().any(|h| {
            h.id == runtime
                && matches!(&h.via, bench_wire::HostedVia::Bench { session, .. } if live(session))
        })
        || crate::hook::hooked(core)
            .iter()
            .any(|h| h.session == runtime && bench_sessions::process::alive(h.pid, None))
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

/// Resume `agent`'s conversation as a benchd session for `pane`, under the mailbox the record
/// gave it when it has one; a codex with `hook_trust` ([`spawn::hook_trust`]).
fn resume(
    core: &mut Core,
    pane: PaneId,
    agent: &ResumableAgent,
    hook_trust: Option<String>,
) -> Result<Arc<Session>, String> {
    let kind = AgentKind::parse(&agent.command, false)?;
    let id = format!("s{}", core.next_session);
    core.next_session += 1;
    let hosted = sessions::recorded(core, kind.name(), &agent.session);
    // A fork comes back as it was spawned, read-only (#531).
    let posture = Posture::resuming(hosted.and_then(|h| h.forked_from.as_deref()));
    let handle = hosted
        .and_then(|h| h.handle().map(str::to_string))
        .filter(|h| !core.sessions.values().any(|s| &s.handle == h))
        .unwrap_or_else(|| id.clone());
    let mut spec = SpawnSpec {
        agent: kind,
        cwd: agent.cwd.clone(),
        model: None,
        effort: None,
        conversation: Conversation::Resume(agent.session.clone()),
        posture,
        prompt_file: None,
        extra_args: Vec::new(),
        settings: None,
        codex_server: None,
        codex_hook_trust: hook_trust,
    };
    spawn::wire(&mut spec, &core.root, &id)?;
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
    hook::serve_resumed(core, &session);
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
