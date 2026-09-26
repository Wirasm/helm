//! `spawn`: an agent in a benchd pty, and a pane on the bench that shows it (M3).
//!
//! The session is M5a's: the allowlist, the unattended posture, the prompt by file and the
//! runtime session id minted here (`bench_session::argv`). What M3 adds is the pane, so an
//! agent an agent starts is on the bench where the operator can see it, without the operator
//! having done anything: a terminal pane naming the session, which helm shows by running
//! `bench attach` in it. Nothing in the path needs helm, a display or a shell, which is what
//! retires helm #253 (a spawn needed an awake display) and #324 (a shell prompt ate the launch
//! line).
//!
//! The pane goes in the cwd's workspace, placed by the rules as an agent's terminal, and lands
//! in the background unless the request says the operator asked. The order keeps a refusal
//! from leaving anything behind: the pane is placed on a copy first, so a focus refusal
//! answers before any process starts; the session is spawned outside the lock; then the pane
//! is placed again on the document as it is by then, and a refusal at that point closes the
//! session it would have shown.

use crate::layout::{self, Change, Committed};
use crate::{Core, claude_settings, sessions};
use bench_doc::{
    Caller, Document, Focus, PaneId, PaneName, Refusal, ResumableAgent, Rules, StandardPath,
    Surface,
};
use bench_session::{AgentKind, Session, SpawnSpec, TEST_AGENT_ENV, mint_session_id};
use bench_wire::{
    Actor, LayoutVerb, OPERATOR_HANDLE, OpenInto, PaneOpen, Request, Response, SpawnArgs, Status,
    validate_handle,
};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// What a spawn needs once its arguments are judged.
struct Plan {
    agent: AgentKind,
    /// The mailbox address asked for; the session id when none was.
    handle: Option<String>,
    spec: SpawnSpec,
    workspace: StandardPath,
    rows: u16,
    cols: u16,
}

/// A refusal or failure, as the status and reason the caller gets.
type Outcome<T> = Result<T, (Status, String)>;

pub fn answer(core: &Arc<Mutex<Core>>, req: &Request) -> Response {
    let (status, reason, data) = match spawn(core, req) {
        Ok((status, reason, data)) => (status, reason, Some(data)),
        Err((status, why)) => (status, Some(why), None),
    };
    Response {
        id: req.id.clone(),
        status,
        reason,
        data,
    }
}

fn spawn(core: &Arc<Mutex<Core>>, req: &Request) -> Outcome<(Status, Option<String>, Value)> {
    let plan = judge(req).map_err(|why| (Status::Refused, why))?;
    let by = req.by.clone().unwrap_or_else(Actor::agent);
    let focus = Actor::focus(&by, req.asked);
    let (id, handle) = reserve(core, &plan, focus)?;
    let session = start(core, &plan, &id, &handle)?;

    let mut c = core.lock().unwrap();
    let mut next = c.bench.document.clone();
    let rules = c.placement.rules();
    let pane = match place(&mut next, rules, &plan, &id, focus) {
        Ok(pane) => pane,
        Err(refusal) => {
            // The bench changed under the spawn. Nothing shows the session, so it goes.
            drop(c);
            session.close(Duration::ZERO);
            return Err((Status::Refused, refusal.to_string()));
        }
    };
    register(&mut c, &plan, &session, pane)?;
    let data = |report: &bench_wire::LayoutReport| {
        json!({
            "session": session.id,
            "handle": session.handle,
            "pid": session.pid,
            "agent": plan.agent.name(),
            "runtime_session": session.runtime_session,
            "pane": pane,
            "workspace": plan.workspace,
            "focused_pane_before": report.focused_pane_before,
            "focused_pane_after": report.focused_pane_after,
        })
    };
    let change = Change {
        verb: req.verb.clone(),
        args: req.args.clone(),
        by,
        asked: req.asked,
        next,
        created: Some(pane),
        pane: Some(pane),
    };
    match layout::commit(&mut c, change) {
        Committed::Changed(report) | Committed::Unchanged(report) => {
            Ok((Status::Ok, None, data(&report)))
        }
        Committed::Unsaved(report, why) => Ok((Status::Error, Some(why), data(&report))),
        Committed::Failed(why) => Err((
            Status::Error,
            format!("session {id} started, but its pane was not: {why}"),
        )),
    }
}

/// Under the lock: the session's id and handle, and a dry run of its pane, so a refusal
/// answers before any process starts.
fn reserve(core: &Arc<Mutex<Core>>, plan: &Plan, focus: Focus) -> Outcome<(String, String)> {
    let mut c = core.lock().unwrap();
    let id = format!("s{}", c.next_session);
    let handle = plan.handle.clone().unwrap_or_else(|| id.clone());
    claimable(&c, &handle).map_err(|why| (Status::Refused, why))?;
    layout::refresh_rules(&mut c);
    let mut dry = c.bench.document.clone();
    place(&mut dry, c.placement.rules(), plan, &id, focus)
        .map_err(|refusal| (Status::Refused, refusal.to_string()))?;
    c.next_session += 1;
    Ok((id, handle))
}

/// Outside the lock: the agent in its pty. It learns its address and root from its
/// environment, so `bench mail send` inside it needs no flags and lands in the right mailroom.
fn start(core: &Arc<Mutex<Core>>, plan: &Plan, id: &str, handle: &str) -> Outcome<Arc<Session>> {
    let (root, notices) = {
        let c = core.lock().unwrap();
        (c.root.clone(), c.notices.clone())
    };
    let mut spec = plan.spec.clone();
    if plan.agent == AgentKind::Claude {
        spec.settings = Some(claude_settings(&root).map_err(|why| (Status::Error, why))?);
    }
    if plan.agent == AgentKind::Codex {
        spec.codex_server = Some(codex_server_socket(&root, id)?);
    }
    let extra_env = [
        ("BENCH_SESSION".to_string(), id.to_string()),
        ("BENCH_HANDLE".to_string(), handle.to_string()),
        ("BENCH_DIR".to_string(), root.display().to_string()),
    ];
    Session::spawn(
        id.to_string(),
        handle.to_string(),
        &spec,
        plan.rows,
        plan.cols,
        &extra_env,
        notices,
    )
    .map_err(|why| (Status::Error, why))
}

/// The session joins the registry and the record, logged before the pane that shows it.
fn register(core: &mut Core, plan: &Plan, session: &Arc<Session>, pane: PaneId) -> Outcome<()> {
    let spec = &session.spec;
    core.sessions
        .insert(session.id.clone(), Arc::clone(session));
    core.append(
        "session/spawned",
        json!({
            "session": session.id,
            "handle": session.handle,
            "agent": plan.agent.name(),
            "cwd": spec.cwd,
            "pid": session.pid,
            "runtime_session": spec.runtime_session,
            "resumed": spec.resume,
            "model": spec.model,
            "effort": spec.effort,
            "pane": pane,
        }),
    )
    .map_err(|why| (Status::Error, why))?;
    // Recorded at spawn only: `resume` re-enters the same runtime session id
    // (bench_session::argv), which this record already holds.
    sessions::record_spawn(
        core,
        bench_wire::Harness::parse(plan.agent.name()),
        spec.runtime_session.as_deref(),
        &spec.cwd,
        &session.id,
        &session.handle,
    )
    .map_err(|why| (Status::Error, why))
}

/// Judge the arguments before anything is reserved: a missing key refuses naming the field,
/// and every rule names what it applied.
fn judge(req: &Request) -> Result<Plan, String> {
    let args: SpawnArgs =
        serde_json::from_value(req.args.clone()).map_err(|e| format!("spawn args: {e}"))?;
    let test_ok = std::env::var(TEST_AGENT_ENV).is_ok_and(|v| v == "1");
    let agent = AgentKind::parse(&args.agent, test_ok)?;
    let cwd = args.cwd.as_str();
    if !cwd.starts_with('/') || !PathBuf::from(cwd).is_dir() {
        return Err(format!(
            "cwd must be an absolute path to an existing directory, got {cwd:?}"
        ));
    }
    let workspace = StandardPath::new(cwd)?;
    // The file must outlive the spawn (helm #93): the agent reads it as its first act.
    if let Some(p) = args.prompt_file.as_deref()
        && !(p.starts_with('/') && PathBuf::from(p).is_file())
    {
        return Err(format!(
            "prompt_file must be an absolute path to a file the agent can read, got {p:?}"
        ));
    }
    let runtime_session = match args.resume.as_deref() {
        Some(id) => Some(resumable(agent, id)?),
        None => agent.mints_session_id().then(mint_session_id),
    };
    Ok(Plan {
        agent,
        handle: args.name,
        spec: SpawnSpec {
            agent,
            cwd: args.cwd.clone(),
            model: args.model,
            effort: args.effort,
            runtime_session,
            resume: args.resume.is_some(),
            prompt_file: args.prompt_file,
            settings: None,
            extra_args: args.args,
            codex_server: None,
        },
        workspace,
        rows: args.rows.unwrap_or(40),
        cols: args.cols.unwrap_or(140),
    })
}

/// A conversation to re-enter: only a runtime that takes its id from the caller, and an id
/// that cannot be read as a flag.
fn resumable(agent: AgentKind, id: &str) -> Result<String, String> {
    if !agent.mints_session_id() {
        return Err(format!(
            "{} names its own sessions after the fact, so --resume is not supported for it — spawn fresh, or use claude or pi",
            agent.name()
        ));
    }
    let valid = (1..=128).contains(&id.len())
        && id.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if !valid {
        return Err(format!(
            "--resume takes a session id (1-128 of [A-Za-z0-9_-], starting alphanumeric), got {id:?}"
        ));
    }
    Ok(id.to_string())
}

/// A handle a new session may take: not the operator's, not a live session's, and a valid one.
fn claimable(core: &Core, handle: &str) -> Result<(), String> {
    validate_handle(handle)?;
    if handle == OPERATOR_HANDLE {
        return Err(format!(
            "{OPERATOR_HANDLE:?} is the operator's handle — addressable by anyone, claimable by no session"
        ));
    }
    if core.sessions.values().any(|s| s.handle == handle) {
        return Err(format!(
            "handle {handle:?} is already claimed — `bench sessions` lists them"
        ));
    }
    Ok(())
}

/// The pane that shows session `id`: named for what runs in it and where (helm's
/// `PaneName.derived`, so the agent's own first `bench name` replaces it without `--rename`),
/// and carrying the conversation to offer resuming after a restart.
fn pane_for(plan: &Plan, id: &str) -> Surface {
    Surface::Terminal {
        agent: plan
            .spec
            .runtime_session
            .as_ref()
            .map(|session| ResumableAgent {
                command: plan.agent.name().to_string(),
                session: session.clone(),
                cwd: plan.spec.cwd.clone(),
            }),
        session: Some(id.to_string()),
    }
}

/// The derived name of a spawned pane: `<agent> · <folder>`, or the agent alone at `/`.
fn derived_name(plan: &Plan) -> PaneName {
    let folder = std::path::Path::new(&plan.spec.cwd)
        .file_name()
        .and_then(|f| f.to_str())
        .unwrap_or_default();
    if folder.is_empty() {
        PaneName::Derived(plan.agent.name().to_string())
    } else {
        PaneName::Derived(format!("{} · {folder}", plan.agent.name()))
    }
}

/// Put the pane showing session `id` on the cwd's bench, opening the workspace with it as its
/// only pane when it is not open. With `Take` the workspace becomes the active one and the pane
/// is focused.
fn place(
    doc: &mut Document,
    rules: &Rules,
    plan: &Plan,
    id: &str,
    focus: Focus,
) -> Result<PaneId, Refusal> {
    let surface = pane_for(plan, id);
    let workspace = &plan.workspace;
    let pane = if doc.workspace(workspace).is_none() {
        let pane = bench_doc::Pane::new(surface);
        let id = pane.id;
        doc.open_workspace(workspace.clone(), pane, focus)?;
        id
    } else {
        if focus == Focus::Take {
            doc.activate(workspace, focus)?;
        }
        let open = LayoutVerb::PaneOpen(PaneOpen {
            into: OpenInto::Workspace(workspace.clone()),
            surface,
        });
        layout::apply(doc, rules, &open, focus, Caller::Agent)?
            .created
            .expect("a terminal naming a new session is always a new pane")
    };
    doc.name_pane(pane, derived_name(plan), focus)?;
    Ok(pane)
}

/// The socket codex's own app-server listens on for this session (#454), so benchd can start
/// an idle codex's turn. Session ids restart at s1 with the daemon, so a server that died
/// uncleanly under an earlier daemon can have left this socket (codex then refuses to bind:
/// "File exists"). No live session holds this id, so what is there is stale.
fn codex_server_socket(root: &std::path::Path, id: &str) -> Outcome<String> {
    let socket = bench_wire::codex_server_socket(root, id);
    if let Some(dir) = socket.parent() {
        std::fs::create_dir_all(dir).map_err(|e| {
            (
                Status::Error,
                format!("cannot create {}: {e}", dir.display()),
            )
        })?;
    }
    let _ = std::fs::remove_file(&socket);
    let _ = std::fs::remove_file(socket.with_extension("sock.log"));
    Ok(socket.display().to_string())
}
