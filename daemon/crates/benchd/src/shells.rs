//! Every terminal pane is a benchd session (M5b, #359): the two rules that keep it so, both
//! applied where every change to the document is made ([`crate::layout::commit`]).
//!
//! - **A new terminal pane gets a shell.** Whatever verb made it — `pane/open`, a split, a new
//!   workspace, a drawer — a terminal pane that did not exist before the change and names no
//!   session gets the operator's login shell, started here and named in the pane before the
//!   change is logged. helm never starts one; it shows the session with `bench attach`.
//! - **A session no pane shows ends.** Closing a pane, a workspace or a drawer's tab takes what
//!   ran there with it, drained off the core lock the way `close` drains.
//!
//! A pane that existed before and has no session — one whose session ended with a benchd restart
//! — is left alone: bringing it back is `bench restore`'s, run by `just resume-all`.

use crate::layout::{Change, commit};
use crate::{Core, shell_env};
use bench_doc::{Document, PaneId, StandardPath};
use bench_session::{AgentKind, Session, SpawnSpec, login_shell};
use bench_wire::Actor;
use serde_json::json;
use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Start a shell for every terminal pane in `next` that is not in `before` and shows no session,
/// and name it in the pane. Answers the sessions started, so a change that is not committed can
/// end them again.
pub fn start_for_new_panes(
    core: &mut Core,
    next: &mut Document,
    before: &HashSet<PaneId>,
) -> Vec<Arc<Session>> {
    let mut started = Vec::new();
    for (pane, workspace, session) in next.terminals() {
        if session.is_some() || before.contains(&pane) {
            continue;
        }
        if let Some(session) = start(core, pane, workspace.as_ref()) {
            next.show_session(pane, &session.id);
            started.push(session);
        }
    }
    started
}

/// A login shell for `pane`, in `workspace` (the home directory for a drawer's pane), registered
/// and logged. A shell that cannot start is logged and the pane stays without one: helm draws it
/// as a pane with no session, and `bench restore` tries again.
pub fn start(
    core: &mut Core,
    pane: PaneId,
    workspace: Option<&StandardPath>,
) -> Option<Arc<Session>> {
    // A workspace whose folder is gone (moved, or never on this machine) still gets a shell,
    // in the home directory, as Ghostty does for a working directory it cannot enter.
    let cwd = workspace
        .map(|w| w.as_str().to_string())
        .filter(|w| std::path::Path::new(w).is_dir())
        .unwrap_or_else(|| core.home.display().to_string());
    start_in(core, pane, &cwd)
}

/// A login shell for `pane` in `cwd`.
pub fn start_in(core: &mut Core, pane: PaneId, cwd: &str) -> Option<Arc<Session>> {
    let id = format!("s{}", core.next_session);
    core.next_session += 1;
    let shell = login_shell();
    let spec = SpawnSpec {
        agent: AgentKind::Shell,
        cwd: cwd.to_string(),
        model: None,
        effort: None,
        runtime_session: None,
        resume: false,
        prompt_file: None,
        extra_args: Vec::new(),
        settings: None,
        codex_server: None,
    };
    let env = shell_env::for_pane(&core.root, &pane.to_string(), &shell);
    match Session::spawn(
        id.clone(),
        id.clone(),
        &spec,
        40,
        140,
        &env,
        core.notices.clone(),
    ) {
        Ok(session) => {
            core.sessions.insert(id.clone(), Arc::clone(&session));
            let _ = core.append(
                "session/spawned",
                json!({
                    "session": id,
                    "agent": AgentKind::Shell.name(),
                    "shell": shell,
                    "cwd": cwd,
                    "pid": session.pid,
                    "pane": pane,
                }),
            );
            Some(session)
        }
        Err(why) => {
            let _ = core.append(
                "session/failed",
                json!({ "pane": pane, "shell": shell, "cwd": cwd, "why": why }),
            );
            None
        }
    }
}

/// End every session `before` showed that `after` does not: its pane went. Drained on threads of
/// their own, off the core lock.
pub fn end_lost(core: &mut Core, before: &HashSet<String>, after: &HashSet<String>, seq: u64) {
    for id in before.difference(after) {
        if let Some(session) = core.sessions.remove(id) {
            let _ = core.append(
                "session/closed",
                json!({ "session": id, "with_pane_closed_at": seq }),
            );
            std::thread::spawn(move || session.close(Duration::from_secs(2)));
        }
    }
}

/// End sessions a change started but did not commit.
pub fn abandon(core: &mut Core, started: Vec<Arc<Session>>) {
    for session in started {
        core.sessions.remove(&session.id);
        let _ = core.append(
            "session/closed",
            json!({ "session": session.id, "why": "the change that started it was not committed" }),
        );
        std::thread::spawn(move || session.close(Duration::ZERO));
    }
}

/// Record where each pane's shell is working now, when that changed: the directory `bench
/// restore` starts its fresh shell in after a restart. Read off the shell process (its cwd), off
/// the core lock; one logged change for everything that moved.
pub fn record_cwds(core: &Arc<Mutex<Core>>) {
    let watched: Vec<(PaneId, Arc<Session>)> = {
        let c = core.lock().unwrap();
        c.sessions
            .values()
            .filter(|s| s.agent == AgentKind::Shell && s.is_live())
            .filter_map(|s| Some((c.bench.document.pane_showing_session(&s.id)?, Arc::clone(s))))
            .collect()
    };
    let seen: Vec<(PaneId, String)> = watched
        .iter()
        .filter_map(|(pane, s)| Some((*pane, s.cwd_now()?)))
        .collect();
    if seen.is_empty() {
        return;
    }
    let mut c = core.lock().unwrap();
    let mut next = c.bench.document.clone();
    let moved: Vec<_> = seen
        .into_iter()
        .filter(|(pane, cwd)| next.record_cwd(*pane, cwd))
        .collect();
    if moved.is_empty() {
        return;
    }
    let change = Change {
        verb: "pane/cwd".into(),
        args: json!(
            moved
                .iter()
                .map(|(pane, cwd)| json!({ "pane": pane, "cwd": cwd }))
                .collect::<Vec<_>>()
        ),
        // Nobody asked: benchd read it off the shell. An agent's actor is the one that can never
        // move the operator's focus, and this moves nothing.
        by: Actor::agent(),
        asked: false,
        next,
        created: None,
        pane: None,
    };
    commit(&mut c, change);
}
