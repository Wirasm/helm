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
use crate::{Core, claude_settings, hook, restore, sessions};
use bench_doc::{
    Caller, Document, Focus, PaneId, PaneName, Refusal, ResumableAgent, Rules, StandardPath,
    Surface,
};
use bench_session::{
    AgentKind, Conversation, Posture, Session, SpawnSpec, TEST_AGENT_ENV, mint_session_id,
};
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
    let plan = judge(core, req).map_err(|why| (Status::Refused, why))?;
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
            "forked_from": plan.spec.conversation.forked_from(),
            "pane": pane,
            "workspace": plan.workspace,
            "focused_pane_before": report.focused_pane_before,
            "focused_pane_after": report.focused_pane_after,
        })
    };
    let change = Change {
        verb: req.verb.clone(),
        args: logged_args(req, &plan.spec),
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
    wire(&mut spec, &root, id).map_err(|why| (Status::Error, why))?;
    Session::spawn(
        id.to_string(),
        handle.to_string(),
        &spec,
        plan.rows,
        plan.cols,
        &agent_env(&root, id, handle),
        notices,
    )
    .map_err(|why| (Status::Error, why))
}

/// What an agent's session `id` needs from this root to report to benchd and be woken by it:
/// claude's settings (its hooks), and codex's own app-server socket (#454). Every route that
/// starts an agent, `spawn`, `restore` and `resume`, goes through here, so none starts one
/// benchd cannot reach.
pub fn wire(spec: &mut SpawnSpec, root: &std::path::Path, id: &str) -> Result<(), String> {
    match spec.agent {
        AgentKind::Claude => spec.settings = Some(claude_settings(root)?),
        AgentKind::Codex => spec.codex_server = Some(codex_server_socket(root, id)?),
        _ => {}
    }
    Ok(())
}

/// What an agent benchd starts learns about itself: its session, its address and this root, so
/// `bench mail send` inside it needs no flags and lands in the right mailroom.
pub fn agent_env(root: &std::path::Path, id: &str, handle: &str) -> bench_session::Env {
    bench_session::Env {
        set: vec![
            ("BENCH_SESSION".to_string(), id.to_string()),
            ("BENCH_HANDLE".to_string(), handle.to_string()),
            ("BENCH_DIR".to_string(), root.display().to_string()),
        ],
        remove: Vec::new(),
    }
}

/// The session joins the registry and the record, logged before the pane that shows it.
fn register(core: &mut Core, plan: &Plan, session: &Arc<Session>, pane: PaneId) -> Outcome<()> {
    let spec = &session.spec;
    core.sessions
        .insert(session.id.clone(), Arc::clone(session));
    hook::serve_resumed(core, session);
    core.append(
        "session/spawned",
        json!({
            "session": session.id,
            "handle": session.handle,
            "agent": plan.agent.name(),
            "cwd": spec.cwd,
            "pid": session.pid,
            "runtime_session": spec.conversation.id(),
            "resumed": matches!(spec.conversation, Conversation::Resume(_)),
            "forked_from": spec.conversation.forked_from(),
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
        spec.conversation.id(),
        &spec.cwd,
        &session.id,
        &session.handle,
        spec.conversation.forked_from(),
    )
    .map_err(|why| (Status::Error, why))
}

/// Judge the arguments (and the record of a conversation to resume, for its posture) before
/// anything is reserved, so `argv` checks the spec that will run: a missing key refuses naming
/// the field, and every rule names what it applied.
fn judge(core: &Arc<Mutex<Core>>, req: &Request) -> Result<Plan, String> {
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
    if args.prompt.is_some() && args.prompt_file.is_some() {
        return Err("pass the first prompt as prompt or as prompt_file, not both".into());
    }
    if args.prompt.as_deref().is_some_and(|t| t.trim().is_empty()) {
        return Err("prompt is empty".into());
    }
    // The file must outlive the spawn (helm #93): the agent reads it as its first act.
    if let Some(p) = args.prompt_file.as_deref()
        && !(p.starts_with('/') && PathBuf::from(p).is_file())
    {
        return Err(format!(
            "prompt_file must be an absolute path to a file the agent can read, got {p:?}"
        ));
    }
    let (conversation, posture) = match (args.resume.as_deref(), args.fork.as_deref()) {
        (Some(_), Some(_)) => {
            return Err(
                "--resume re-enters a conversation and --fork copies one — pass one of them".into(),
            );
        }
        // A conversation is re-entered in the posture it was spawned in: a fork's is read-only
        // (#531), whoever resumes it and by whichever route.
        (Some(id), None) => {
            let c = core.lock().unwrap();
            // Two processes on one conversation fork it, as `restore` says too.
            if restore::held(&c, id) {
                return Err(format!(
                    "conversation {id} is already live in another session — attach to that one"
                ));
            }
            let forked_from =
                sessions::recorded(&c, agent.name(), id).and_then(|h| h.forked_from.as_deref());
            (
                Conversation::Resume(conversation_id("--resume", id)?),
                Posture::resuming(forked_from),
            )
        }
        // A fork answers questions about the original's work in the original's worktree, so it
        // runs read-only: the operator's ruling (#531). codex names the fork itself.
        (None, Some(from)) => (
            Conversation::Fork {
                from: conversation_id("--fork", from)?,
                id: agent.mints_session_id().then(mint_session_id),
            },
            Posture::ReadOnly,
        ),
        (None, None) => (
            Conversation::New(agent.mints_session_id().then(mint_session_id)),
            Posture::Unattended,
        ),
    };
    let spec = SpawnSpec {
        agent,
        cwd: args.cwd.clone(),
        model: args.model,
        effort: args.effort,
        conversation,
        posture,
        prompt_file: args.prompt_file,
        settings: None,
        extra_args: args.args,
        codex_server: None,
    };
    // `argv` is the one spelling of what each runtime can start as, so it also judges: a spec a
    // runtime cannot run (a fork of the test agent, say) is refused here, before anything is
    // reserved.
    bench_session::argv(&spec)?;
    let mut spec = spec;
    if let Some(text) = args.prompt {
        spec.prompt_file = Some(write_prompt(core, &text)?);
    }
    Ok(Plan {
        agent,
        handle: args.name,
        spec,
        workspace,
        rows: args.rows.unwrap_or(40),
        cols: args.cols.unwrap_or(140),
    })
}

/// A first prompt sent as text, written where the agent can read it:
/// `<root>/prompts/<uuid>/prompt.md`, inside the root's private directory. Kept, because the agent
/// reads it after the spawn answers (helm #93). A folder per spawn, because a read-only agent is
/// granted its prompt's folder (`bench_session::argv`), and that grant must not reach another
/// spawn's prompt.
fn write_prompt(core: &Arc<Mutex<Core>>, text: &str) -> Result<String, String> {
    let dir = core
        .lock()
        .unwrap()
        .root
        .join("prompts")
        .join(mint_session_id());
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let path = dir.join("prompt.md");
    std::fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(path.display().to_string())
}

/// What a spawn's `bench/changed` logs as its args: a prompt sent as text is logged as the file
/// benchd wrote it to, so the event log carries a path rather than the operator's words.
fn logged_args(req: &Request, spec: &SpawnSpec) -> Value {
    let mut args = req.args.clone();
    if let Some(map) = args.as_object_mut()
        && map.remove("prompt").is_some()
    {
        map.insert("prompt_file".into(), json!(spec.prompt_file));
    }
    args
}

/// A conversation id from the caller (`flag` names where it came from): one that cannot be read
/// as a flag. Which runtime can fork is `bench_session::argv`'s to say.
fn conversation_id(flag: &str, id: &str) -> Result<String, String> {
    let valid = (1..=128).contains(&id.len())
        && id.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if !valid {
        return Err(format!(
            "{flag} takes a session id (1-128 of [A-Za-z0-9_-], starting alphanumeric), got {id:?}"
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
        agent: plan.spec.conversation.id().map(|session| ResumableAgent {
            command: plan.agent.name().to_string(),
            session: session.to_string(),
            cwd: plan.spec.cwd.clone(),
        }),
        session: Some(id.to_string()),
        cwd: None,
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
        layout::apply(doc, rules, &open, focus, Caller::Agent, None)?
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
fn codex_server_socket(root: &std::path::Path, id: &str) -> Result<String, String> {
    let socket = bench_wire::codex_server_socket(root, id);
    if let Some(dir) = socket.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    }
    let _ = std::fs::remove_file(&socket);
    let _ = std::fs::remove_file(socket.with_extension("sock.log"));
    Ok(socket.display().to_string())
}
