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
use crate::{Core, attention, claude_settings, hook, restore, resume_dir, sessions};
use bench_doc::{
    Caller, Document, Focus, PaneId, PaneName, Refusal, ResumableAgent, Rules, StandardPath,
    Surface,
};
use bench_session::{
    AgentKind, CodexAttach, Conversation, Posture, Session, SpawnSpec, TEST_AGENT_ENV,
    mint_session_id,
};
use bench_wire::{
    Actor, LayoutVerb, OPERATOR_HANDLE, OpenInto, PaneOpen, Request, Response, SpawnArgs, Spawner,
    Status, validate_handle,
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
    /// What the resume notice says about where a resume runs, when that is not where it ran.
    note: Option<String>,
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
    let spawner = attention::spawner(core, &by);
    let (id, handle) = reserve(core, &plan, focus)?;
    let session = start(core, &plan, &id, &handle)?;

    let mut c = core.lock().unwrap();
    let mut next = c.bench.document.clone();
    let rules = c.placement.rules();
    // The started session's conversation: a codex's thread exists only from here.
    let pane = match place(
        &mut next,
        rules,
        &plan,
        &session.spec.conversation,
        &id,
        focus,
    ) {
        Ok(pane) => pane,
        Err(refusal) => {
            // The bench changed under the spawn. Nothing shows the session, so it goes.
            drop(c);
            session.close(Duration::ZERO);
            crate::codex::abandon(core, &session.spec);
            return Err((Status::Refused, refusal.to_string()));
        }
    };
    register(&mut c, &plan, &session, pane, &spawner)?;
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
    place(
        &mut dry,
        c.placement.rules(),
        plan,
        &plan.spec.conversation,
        &id,
        focus,
    )
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
    wire(&mut spec, &root, plan.note.as_deref()).map_err(|why| (Status::Error, why))?;
    codex_thread(core, &mut spec, id, handle).map_err(|why| (Status::Error, why))?;
    Session::spawn(
        id.to_string(),
        handle.to_string(),
        &spec,
        plan.rows,
        plan.cols,
        &agent_env(&root, id, handle),
        notices,
    )
    .map_err(|why| {
        crate::codex::abandon(core, &spec);
        (Status::Error, why)
    })
}

/// What an agent's session `id` needs from this root to report to benchd and be woken by it:
/// claude's settings (its hooks). Every route that starts an agent, `spawn`, `restore` and
/// `resume`, goes through here, and a codex then through [`codex_thread`].
///
/// It also gives a resumed conversation its first message when the caller sent none: the
/// [`resume_notice`], so the agent starts a turn rather than sitting at its prompt after its
/// last turn was cut off. A caller's own prompt (`bench spawn --resume --prompt-file`, what
/// `just release-resume` sends) wins. `bench resume` drops the old spawn's prompt before it
/// gets here, so the notice is the only thing a resume ever sends that the caller did not. `note`
/// is what the notice adds about where the resume runs ([`resume_dir::Start`]).
pub fn wire(
    spec: &mut SpawnSpec,
    root: &std::path::Path,
    note: Option<&str>,
) -> Result<(), String> {
    if spec.agent == AgentKind::Claude {
        spec.settings = Some(claude_settings(root)?);
    }
    if matches!(spec.conversation, Conversation::Resume(_)) && spec.prompt_file.is_none() {
        let notice = resume_notice(&crate::now_rfc3339(), note);
        spec.prompt_file = Some(write_prompt(root, &notice)?);
    }
    Ok(())
}

/// What a conversation benchd resumes is told first. It asks only to carry on: the operator's
/// own agents are resumed too, and the notice must never restate a task. `note` follows, on its
/// own line, when the resume does not run where the conversation ran.
fn resume_notice(at: &str, note: Option<&str>) -> String {
    let mut notice = format!(
        "benchd resumed this conversation in a new process at {at}: benchd restarted, or the \
         process it ran in ended. Everything above is still your conversation. Your last turn \
         was interrupted. Continue where you were; if that work was already finished, say so in \
         one line and wait. Check that anything you had running (gates, watchers, reviewers, \
         background processes) is still alive, and re-arm it. This notice is not a new task.\n"
    );
    if let Some(note) = note {
        notice.push_str(&format!("\n{note}\n"));
    }
    notice
}

/// A codex's thread on benchd's app-server (#466), made before its TUI starts: new, forked from
/// the conversation it copies, or re-entered. The thread holds everything about the agent: its
/// cwd, model, effort and posture, and the environment its commands see ([`agent_env`]), since the
/// TUI's own environment never reaches them. Then its first message goes in as a turn: a TUI
/// cannot attach to a thread with no turn yet (codex 0.160.0), so a new codex sent no prompt is
/// told to wait. `spec` comes back naming the thread and the server, which is all `argv` needs.
///
/// It talks to the server, so it runs outside the core lock: `spawn` and `resume` call it after
/// [`wire`], and `restore` calls it for each codex pane before it takes the lock.
pub fn codex_thread(
    core: &Arc<Mutex<Core>>,
    spec: &mut SpawnSpec,
    id: &str,
    handle: &str,
) -> Result<(), String> {
    if spec.agent != AgentKind::Codex {
        return Ok(());
    }
    let server = crate::codex::server(core)?;
    let root = core.lock().unwrap().root.clone();
    let env: serde_json::Map<String, Value> = agent_env(&root, id, handle)
        .set
        .into_iter()
        .map(|(k, v)| (k, json!(v)))
        .collect();
    let mut params = json!({
        "cwd": spec.cwd,
        // Nobody is at an unattended pane to approve anything, and a write a read-only fork
        // attempts fails rather than asking.
        "sandbox": match spec.posture {
            Posture::Unattended => "danger-full-access",
            Posture::ReadOnly => "read-only",
        },
        "approvalPolicy": "never",
        // Hooks run only once trusted, a choice made in a dialog nobody is at an unattended pane
        // to answer; the server's own trust keeps the TUI's review screen away (`codex.rs`).
        "config": { "bypass_hook_trust": true, "shell_environment_policy": { "set": env } },
    });
    if let Conversation::Resume(thread) = &spec.conversation
        && spec.model.is_none()
    {
        // A resume without a model runs on the server's default, not on what the thread ran
        // with; `restore` knows only the conversation, so the thread's record says.
        let (model, effort) = server.thread_model(thread)?;
        spec.model = model;
        spec.effort = spec.effort.take().or(effort);
    }
    if let Some(model) = &spec.model {
        params["model"] = json!(model);
    }
    if let Some(effort) = &spec.effort {
        params["config"]["model_reasoning_effort"] = json!(effort);
    }
    let thread = match &spec.conversation {
        Conversation::New(_) => {
            let thread = server.start_thread(params)?;
            spec.conversation = Conversation::New(Some(thread.clone()));
            thread
        }
        Conversation::Fork { from, .. } => {
            let from = from.clone();
            let thread = server.fork_thread(&from, params)?;
            spec.conversation = Conversation::Fork {
                from,
                id: Some(thread.clone()),
            };
            thread
        }
        Conversation::Resume(thread) => {
            server.resume_thread(thread, params)?;
            thread.clone()
        }
    };
    let first = match spec.prompt_file.as_deref() {
        Some(path) => bench_session::prompt_pointer(path),
        None => "benchd started this conversation. Wait for instructions.".to_string(),
    };
    if let Err(why) = server.first_turn(&thread, &first) {
        server.abandon(&thread);
        return Err(why);
    }
    spec.codex = Some(CodexAttach {
        program: server.program.display().to_string(),
        socket: server.socket.display().to_string(),
    });
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
/// `spawner` is who asked for it (`attention::spawner`).
fn register(
    core: &mut Core,
    plan: &Plan,
    session: &Arc<Session>,
    pane: PaneId,
    spawner: &Spawner,
) -> Outcome<()> {
    let spec = &session.spec;
    core.sessions
        .insert(session.id.clone(), Arc::clone(session));
    let live = &core.sessions;
    core.spawners.retain(|id, _| live.contains_key(id));
    core.spawners.insert(session.id.clone(), spawner.clone());
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
            "spawner": spawner,
        }),
    )
    .map_err(|why| (Status::Error, why))?;
    // Recorded at spawn only: `resume` re-enters the same runtime session id
    // (bench_session::argv), which this record already holds.
    sessions::record_spawn(core, session, spawner).map_err(|why| (Status::Error, why))?;
    // After the record: a codex whose first turn already ended is done, which the record holds.
    hook::serve_codex(core, session);
    Ok(())
}

/// Judge the arguments (and the record of a conversation to resume, for its posture) before
/// anything is reserved, so `argv` checks the spec that will run: a missing key refuses naming
/// the field, and every rule names what it applied.
fn judge(core: &Arc<Mutex<Core>>, req: &Request) -> Result<Plan, String> {
    let args: SpawnArgs =
        serde_json::from_value(req.args.clone()).map_err(|e| format!("spawn args: {e}"))?;
    let test_ok = std::env::var(TEST_AGENT_ENV).is_ok_and(|v| v == "1");
    let agent = AgentKind::parse(&args.agent, test_ok)?;
    let refused_cwd =
        |cwd: &str| format!("cwd must be an absolute path to an existing directory, got {cwd:?}");
    if !args.cwd.starts_with('/') {
        return Err(refused_cwd(&args.cwd));
    }
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
    let (mut cwd, mut note) = (args.cwd.clone(), None);
    let (conversation, posture) = match (args.resume.as_deref(), args.fork.as_deref()) {
        (Some(_), Some(_)) => {
            return Err(
                "--resume re-enters a conversation and --fork copies one — pass one of them".into(),
            );
        }
        // A conversation is re-entered in the posture it was spawned in: a fork's is read-only
        // (#531), whoever resumes it and by whichever route.
        (Some(id), None) => {
            let forked_from = {
                let c = core.lock().unwrap();
                // Two processes on one conversation fork it, as `restore` says too.
                if restore::held(&c, id) {
                    return Err(format!(
                        "conversation {id} is already live in another session — attach to that one"
                    ));
                }
                sessions::recorded(&c, agent.name(), id).and_then(|h| h.forked_from.clone())
            };
            let id = conversation_id("--resume", id)?;
            // The folder it ran in may be gone since: the merge queue prunes worktrees (#621).
            let start = resume_dir::start(agent, &id, &args.cwd)?;
            (cwd, note) = (start.cwd, start.note);
            (
                Conversation::Resume(id),
                Posture::resuming(forked_from.as_deref()),
            )
        }
        // A fork answers questions about the original's work in the original's worktree, so it
        // runs read-only: the operator's ruling (#531). codex mints the fork's id when benchd
        // forks the thread ([`codex_thread`]).
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
    if !PathBuf::from(&cwd).is_dir() {
        return Err(refused_cwd(&cwd));
    }
    let workspace = StandardPath::new(&cwd)?;
    if agent == AgentKind::Codex {
        crate::codex_trust::may_run(&cwd)?;
    }
    let spec = SpawnSpec {
        agent,
        cwd,
        model: args.model,
        effort: args.effort,
        conversation,
        posture,
        prompt_file: args.prompt_file,
        settings: None,
        extra_args: args.args,
        codex: None,
    };
    // `argv` is the one spelling of what each runtime can start as, so it also judges: a spec a
    // runtime cannot run (a fork of the test agent, say) is refused here, before anything is
    // reserved.
    bench_session::argv(&spec)?;
    let mut spec = spec;
    if let Some(text) = args.prompt {
        let root = core.lock().unwrap().root.clone();
        spec.prompt_file = Some(write_prompt(&root, &text)?);
    }
    Ok(Plan {
        agent,
        handle: args.name,
        spec,
        note,
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
fn write_prompt(root: &std::path::Path, text: &str) -> Result<String, String> {
    let dir = root.join("prompts").join(mint_session_id());
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
fn pane_for(plan: &Plan, conversation: &Conversation, id: &str) -> Surface {
    Surface::Terminal {
        agent: conversation.id().map(|session| ResumableAgent {
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
    conversation: &Conversation,
    id: &str,
    focus: Focus,
) -> Result<PaneId, Refusal> {
    let surface = pane_for(plan, conversation, id);
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
