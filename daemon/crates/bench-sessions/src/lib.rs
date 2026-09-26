//! Every agent session in a workspace, read from the harnesses' own files (#384).
//!
//! The same shape as `bench-mail`: this crate reads and decides; benchd logs, persists and
//! answers. It knows no sockets, events or record files — the hosted-sessions record and the
//! dismissals arrive as inputs, and what should be added to the record leaves as output.
//!
//! What is listed, and from where (the rulings on #384):
//! - **Running, hosted:** benchd's own sessions, and agents in helm terminal panes (helm's
//!   snapshot, matched by exact pid). A live agent anywhere else is foreign and left out.
//! - **Running, background:** Claude Code `--bg` jobs whose cwd is in scope, unless the job
//!   has neither a process nor a transcript (a job Claude still lists as `blocked` from July).
//! - **Running subagents** of a hosted live Claude session, by the three rules in
//!   [`claude::Cache::subagent`].
//! - **Finished:** only sessions in the hosted-sessions record. No harness file records where
//!   a session ran, so the record is the only honest source. Dismissed ones are hidden.
//!
//! Scope: a session is in the workspace when its cwd is inside the repo or one of its
//! worktrees ([`scope::Workspace`]).

pub mod claude;
pub mod pi;
pub mod process;
pub mod scope;
pub mod snapshot;
pub mod transcript;

use bench_doc::StandardPath;
use bench_session::{AgentKind, SpawnSpec};
use bench_wire::{
    Activity, Dismissal, Harness, Host, HostedSession, HostedVia, MailAddress, OPERATOR_HANDLE,
    OpenAction, SessionKey, SessionList, SessionRow, SessionState, Unreadable,
};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

pub use claude::Cache;
pub use scope::Workspace;

/// `Unreadable.source` for a row [`open_action`] had no action for.
pub const SESSION_LIST: &str = "session-list";

/// A reply lists at most this many rows and says how many it left out.
pub const MAX_ROWS: usize = 200;

/// One of benchd's own pty sessions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BenchSession {
    pub session: String,
    pub harness: Harness,
    /// The runtime's own session id, when the bench minted one (claude, pi).
    pub runtime_session: Option<String>,
    pub cwd: String,
    pub pid: u32,
    pub live: bool,
    pub spawned_ms: u64,
    /// Its mailbox handle.
    pub handle: String,
}

/// An agent helm hosted as its own hooks report it to benchd (#358): the source for pi and
/// codex, which publish no registry, and for any agent the snapshot's foreground pid misses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookedAgent {
    pub harness: Harness,
    pub session: String,
    pub cwd: String,
    /// The pane it reports from now; `None` once it was resumed outside helm.
    pub pane: Option<bench_doc::PaneId>,
    /// Its process as the last hook reported it; alive is running.
    pub pid: u32,
    pub activity: Activity,
    pub handle: String,
}

/// Everything a build reads besides the harness files.
pub struct Inputs<'a> {
    /// Whose `~/.claude` and `~/.pi`.
    pub home: &'a Path,
    /// helm's bench directory, holding `snapshot.json`.
    pub helm_bench_dir: &'a Path,
    pub workspace: &'a StandardPath,
    pub bench: &'a [BenchSession],
    pub hosted: &'a [HostedSession],
    /// Agents helm hosted whose hooks report to benchd, and the pane each reports from now.
    pub hooked: &'a [HookedAgent],
    pub dismissed: &'a [Dismissal],
    /// A handle's mail address: its unread count, and whether benchd holds a live session
    /// with it. benchd answers from its mailroom and the same rule `mail/send` uses to queue a
    /// wake; this crate only decides which rows have a mailbox.
    pub mailbox: &'a dyn Fn(&str) -> MailAddress,
    pub now_ms: u64,
    /// Stamped on sessions this build adds to the record.
    pub now: &'a str,
    /// Whether a pid is alive and started at the given epoch ms. [`process::alive`] in the
    /// daemon; a parameter so a test can say which pids are live.
    pub alive: &'a dyn Fn(u32, Option<u64>) -> bool,
}

pub struct Built {
    pub list: SessionList,
    /// Sessions seen in helm panes that the record does not hold yet.
    pub newly_hosted: Vec<HostedSession>,
}

/// The one place a row's action is decided, from where it runs and whether it is running.
/// A combination that cannot happen (a finished session still in a pane) is an error, so no
/// caller can build a row whose action contradicts its state.
pub fn open_action(
    harness: Harness,
    id: &str,
    cwd: &str,
    host: &Host,
    state: &SessionState,
) -> Result<OpenAction, String> {
    let running = state.is_running();
    match (host, running) {
        (Host::Pane { pane }, true) => Ok(OpenAction::FocusPane { pane: *pane }),
        (Host::Bench { session }, true) => Ok(OpenAction::BenchAttach {
            session: session.clone(),
        }),
        (Host::Background { job }, true) => Ok(OpenAction::ClaudeAttach { job: job.clone() }),
        (Host::InSession { parent, transcript }, _) => Ok(OpenAction::Transcript {
            path: transcript.clone(),
            parent: parent.clone(),
        }),
        (Host::None, false) => {
            // The resume flags have one spelling, the one `bench resume` uses.
            let agent = match harness {
                Harness::Claude => AgentKind::Claude,
                Harness::Codex => AgentKind::Codex,
                Harness::Pi => AgentKind::Pi,
            };
            let (program, args) = bench_session::argv(&SpawnSpec {
                agent,
                cwd: cwd.to_string(),
                model: None,
                effort: None,
                runtime_session: Some(id.to_string()),
                resume: true,
                prompt_file: None,
                settings: None,
                extra_args: Vec::new(),
            })?;
            Ok(OpenAction::Resume {
                argv: std::iter::once(program).chain(args).collect(),
                cwd: cwd.to_string(),
            })
        }
        (host, running) => Err(format!(
            "no action for a {} session hosted as {host:?}",
            if running { "running" } else { "finished" }
        )),
    }
}

/// Assembles rows; every row goes through [`open_action`].
struct Rows<'a> {
    ws: &'a Workspace,
    rows: Vec<SessionRow>,
    unreadable: Vec<Unreadable>,
}

struct Draft {
    harness: Harness,
    id: String,
    parent: Option<String>,
    name: Option<String>,
    cwd: String,
    state: SessionState,
    host: Host,
    mail: Option<MailAddress>,
    updated_at_ms: u64,
}

impl Rows<'_> {
    /// Adds the row when `scope_cwd` is in the workspace.
    fn push(&mut self, scope_cwd: &str, d: Draft) {
        let Some(root) = self.ws.root_of(scope_cwd) else {
            return;
        };
        let open = match open_action(d.harness, &d.id, &d.cwd, &d.host, &d.state) {
            Ok(o) => o,
            Err(why) => {
                self.unreadable.push(Unreadable {
                    source: SESSION_LIST.into(),
                    path: d.cwd.clone(),
                    why,
                });
                return;
            }
        };
        self.rows.push(SessionRow {
            harness: d.harness,
            id: d.id,
            parent: d.parent,
            name: d.name,
            cwd: d.cwd,
            root: root.to_string(),
            state: d.state,
            host: d.host,
            open,
            mail: d.mail,
            updated_at_ms: d.updated_at_ms,
        });
    }
}

#[expect(clippy::too_many_lines, reason = "legacy (#418): 296 lines, limit 100")]
pub fn build(inputs: &Inputs, cache: &mut Cache) -> Built {
    let ws = Workspace::resolve(inputs.workspace);
    let mut out = Rows {
        ws: &ws,
        rows: Vec::new(),
        unreadable: Vec::new(),
    };
    let alive = inputs.alive;

    let (registry, problems) =
        claude::registry(inputs.home, |pid, started| alive(pid, Some(started)));
    out.unreadable.extend(problems);
    let by_pid: HashMap<u32, &claude::Registered> = registry.iter().map(|r| (r.pid, r)).collect();
    // Anything live, hosted or not, is never a finished row.
    let mut live: HashSet<SessionKey> = registry
        .iter()
        .map(|r| key(Harness::Claude, &r.session))
        .collect();
    // Hosted live Claude sessions: where subagents are looked for.
    let mut hosted_claude: Vec<&claude::Registered> = Vec::new();

    // 1. benchd's own sessions.
    for b in inputs.bench.iter().filter(|b| b.live) {
        let registered = by_pid.get(&b.pid).copied();
        let id = registered
            .map(|r| r.session.clone())
            .or_else(|| b.runtime_session.clone())
            .unwrap_or_else(|| b.session.clone());
        live.insert(key(b.harness, &id));
        if let Some(r) = registered {
            hosted_claude.push(r);
        }
        out.push(
            &b.cwd,
            Draft {
                harness: b.harness,
                id,
                parent: None,
                name: registered.and_then(|r| r.name.clone()),
                cwd: b.cwd.clone(),
                state: SessionState::Running {
                    activity: registered.map_or(Activity::Unknown, |r| r.activity.clone()),
                },
                host: Host::Bench {
                    session: b.session.clone(),
                },
                mail: Some((inputs.mailbox)(&b.handle)),
                updated_at_ms: registered
                    .and_then(|r| r.status_updated_ms)
                    .unwrap_or(b.spawned_ms),
            },
        );
    }

    // 2. Agents in helm panes.
    let (panes, problems) = snapshot::read(inputs.helm_bench_dir);
    out.unreadable.extend(problems);
    let recorded: HashSet<SessionKey> = inputs.hosted.iter().map(HostedSession::key).collect();
    // A pane's agent has a mailbox when its hook claimed one (#358); the record says which.
    let claimed: HashMap<SessionKey, &str> = inputs
        .hosted
        .iter()
        .filter_map(|h| Some((h.key(), h.handle()?)))
        .collect();
    let mail_of = |harness: Harness, id: &str| {
        claimed
            .get(&key(harness, id))
            .map(|handle| (inputs.mailbox)(handle))
    };
    let mut newly_hosted: Vec<HostedSession> = Vec::new();
    let mut record = |harness: Harness, id: &str, cwd: &str, pane: bench_doc::PaneId| {
        let k = key(harness, id);
        if !recorded.contains(&k) && !newly_hosted.iter().any(|h| h.key() == k) {
            newly_hosted.push(HostedSession {
                harness,
                id: id.to_string(),
                cwd: cwd.to_string(),
                via: HostedVia::Pane { pane, handle: None },
                recorded_at: inputs.now.to_string(),
            });
        }
    };
    for p in &panes {
        let host = Host::Pane { pane: p.pane };
        let claude_here = p.foreground_pid.and_then(|pid| by_pid.get(&pid).copied());
        if let Some(r) = claude_here {
            record(Harness::Claude, &r.session, &r.cwd, p.pane);
            hosted_claude.push(r);
            live.insert(key(Harness::Claude, &r.session));
            let cwd = r.cwd.clone();
            out.push(
                &cwd,
                Draft {
                    harness: Harness::Claude,
                    id: r.session.clone(),
                    parent: None,
                    name: r.name.clone(),
                    cwd: cwd.clone(),
                    state: SessionState::Running {
                        activity: r.activity.clone(),
                    },
                    host,
                    mail: mail_of(Harness::Claude, &r.session),
                    updated_at_ms: r.status_updated_ms.unwrap_or(r.started_ms),
                },
            );
        }
        if let Some(r) = &p.resumable {
            record(r.harness, &r.session, &r.cwd, p.pane);
        }
    }

    // 2b. Agents helm hosted that benchd knows from their own hooks, not already listed.
    for h in inputs.hooked {
        let listed = out
            .rows
            .iter()
            .any(|r| r.harness == h.harness && r.id == h.session);
        if listed || !alive(h.pid, None) {
            continue;
        }
        live.insert(key(h.harness, &h.session));
        // Running outside helm: no row, like any live agent there, and not finished either.
        let Some(pane) = h.pane else {
            continue;
        };
        let registered = (h.harness == Harness::Claude)
            .then(|| registry.iter().find(|r| r.session == h.session))
            .flatten();
        if let Some(r) = registered {
            hosted_claude.push(r);
        }
        out.push(
            &h.cwd,
            Draft {
                harness: h.harness,
                id: h.session.clone(),
                parent: None,
                name: registered.and_then(|r| r.name.clone()),
                cwd: h.cwd.clone(),
                state: SessionState::Running {
                    activity: h.activity.clone(),
                },
                host: Host::Pane { pane },
                mail: Some((inputs.mailbox)(&h.handle)),
                updated_at_ms: inputs.now_ms,
            },
        );
    }

    // 3. --bg jobs.
    let (jobs, problems) = claude::jobs(inputs.home);
    out.unreadable.extend(problems);
    for j in jobs {
        let has_process = live.contains(&key(Harness::Claude, &j.session));
        if !has_process && !j.has_transcript {
            continue;
        }
        live.insert(key(Harness::Claude, &j.session));
        out.push(
            &j.cwd.clone(),
            Draft {
                harness: Harness::Claude,
                id: j.session,
                parent: None,
                name: j.name,
                cwd: j.cwd,
                state: SessionState::Running {
                    activity: j.activity,
                },
                host: Host::Background { job: j.job },
                mail: None,
                updated_at_ms: j.updated_ms,
            },
        );
    }

    // 4. Running subagents of hosted live Claude sessions.
    hosted_claude.sort_by(|a, b| a.session.cmp(&b.session));
    hosted_claude.dedup_by(|a, b| a.session == b.session);
    for r in &hosted_claude {
        let dir = claude::subagents_dir(inputs.home, &r.cwd, &r.session);
        let mut metas: Vec<PathBuf> = std::fs::read_dir(&dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.to_string_lossy().ends_with(".meta.json"))
            .collect();
        metas.sort();
        for meta_path in metas {
            let name = meta_path.file_name().unwrap_or_default().to_string_lossy();
            let Some(agent) = name
                .strip_prefix("agent-")
                .and_then(|n| n.strip_suffix(".meta.json"))
            else {
                continue;
            };
            let transcript = dir.join(format!("agent-{agent}.jsonl"));
            let activity = match cache.subagent(&transcript, r.started_ms, inputs.now_ms) {
                claude::Verdict::Finished => continue,
                claude::Verdict::Running(a) => a,
                claude::Verdict::Unreadable(why) => {
                    out.unreadable.push(Unreadable {
                        source: claude::SUBAGENT.into(),
                        path: transcript.display().to_string(),
                        why,
                    });
                    continue;
                }
            };
            let meta = match claude::meta(&meta_path) {
                Ok(m) => m,
                Err(u) => {
                    out.unreadable.push(u);
                    continue;
                }
            };
            let label = [meta.agent_type, meta.description]
                .into_iter()
                .flatten()
                .collect::<Vec<_>>()
                .join(" · ");
            out.push(
                &r.cwd,
                Draft {
                    harness: Harness::Claude,
                    id: agent.to_string(),
                    parent: Some(meta.parent_agent.unwrap_or_else(|| r.session.clone())),
                    name: (!label.is_empty()).then_some(label),
                    cwd: r.cwd.clone(),
                    state: SessionState::Running { activity },
                    host: Host::InSession {
                        parent: r.session.clone(),
                        transcript: transcript.display().to_string(),
                    },
                    mail: None,
                    updated_at_ms: claude::mtime_ms(&transcript),
                },
            );
        }
    }
    cache.end_build();

    // 5. Finished: the record, minus anything live, anything dismissed, and anything whose
    //    harness left nothing to resume.
    let dismissed: HashMap<SessionKey, u64> = inputs
        .dismissed
        .iter()
        .map(|d| (d.key(), d.at_ms))
        .collect();
    let mut seen: HashSet<SessionKey> = HashSet::new();
    for h in inputs.hosted.iter().chain(newly_hosted.iter()) {
        let k = h.key();
        if live.contains(&k) || !seen.insert(k.clone()) || ws.root_of(&h.cwd).is_none() {
            continue;
        }
        let transcript = match h.harness {
            Harness::Claude => {
                Some(claude::transcript(inputs.home, &h.cwd, &h.id)).filter(|p| p.is_file())
            }
            Harness::Pi => match pi::session(inputs.home, &h.cwd, &h.id) {
                Ok(p) => p,
                Err(u) => {
                    out.unreadable.push(u);
                    continue;
                }
            },
            // benchd cannot mint a codex id and helm records none, so no codex id reaches
            // the record; one that did would have no rollout lookup here.
            Harness::Codex => None,
        };
        let Some(transcript) = transcript else {
            continue;
        };
        let at_ms = claude::mtime_ms(&transcript);
        if dismissed.get(&k).is_some_and(|d| at_ms <= *d) {
            continue;
        }
        out.push(
            &h.cwd,
            Draft {
                harness: h.harness,
                id: h.id.clone(),
                parent: None,
                name: None,
                cwd: h.cwd.clone(),
                state: SessionState::Finished { at_ms },
                host: Host::None,
                // The handle recorded at spawn or claim: the mailbox outlives the session, in
                // benchd's memory and across its restarts. Never looked up by bench session id,
                // which begins again at s1 when the daemon restarts.
                mail: h.handle().map(|handle| (inputs.mailbox)(handle)),
                updated_at_ms: at_ms,
            },
        );
    }

    let Rows {
        mut rows,
        unreadable,
        ..
    } = out;
    rows.sort_by(|a, b| {
        b.state
            .is_running()
            .cmp(&a.state.is_running())
            .then(b.updated_at_ms.cmp(&a.updated_at_ms))
            .then(a.id.cmp(&b.id))
    });
    let total = rows.len();
    rows.truncate(MAX_ROWS);
    Built {
        list: SessionList {
            workspace: ws.root.clone(),
            roots: ws.roots.clone(),
            operator: (inputs.mailbox)(OPERATOR_HANDLE),
            returned: rows.len(),
            truncated: rows.len() < total,
            total,
            rows,
            unreadable,
        },
        newly_hosted,
    }
}

fn key(harness: Harness, id: &str) -> SessionKey {
    SessionKey {
        harness,
        id: id.to_string(),
    }
}
