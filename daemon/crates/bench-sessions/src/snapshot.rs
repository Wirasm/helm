//! helm's bench snapshot (`~/.helm/bench/snapshot.json`), read for one thing: which agent is
//! in which terminal pane. It is the pid → pane route until every pane is a benchd session
//! (M5b). Matching is by exact pid (`owner.pid`, `foregroundPid`); `HELM_PANE` in a process's
//! environment is deliberately not used, because every process an agent spawns inherits it
//! (an Archon `claude -p` started from a pane would claim the pane).

use bench_doc::PaneId;
use bench_wire::{Harness, Unreadable};
use serde::Deserialize;
use std::path::{Path, PathBuf};

pub const FORMAT: &str = "helm.bench-snapshot";
pub const VERSION: u64 = 1;
pub const SOURCE: &str = "helm-snapshot";

/// One terminal pane, reduced to what the session list needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneAgent {
    pub pane: PaneId,
    pub foreground_pid: Option<u32>,
    /// The agent that claimed a mailbox from this pane (helm's `owner`).
    pub owner: Option<Owner>,
    /// The agent helm recorded so a restart can offer to resume it.
    pub resumable: Option<Resumable>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Owner {
    pub harness: Harness,
    pub pid: u32,
    pub session: Option<String>,
    pub cwd: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resumable {
    pub harness: Harness,
    pub session: String,
    pub cwd: String,
}

pub fn path(helm_bench_dir: &Path) -> PathBuf {
    helm_bench_dir.join("snapshot.json")
}

/// Every terminal pane in the snapshot. An absent snapshot is no panes (helm is not
/// running, or never ran). A snapshot this build cannot read is no panes plus one
/// `Unreadable`; a pane naming a runtime this build does not know is skipped with one.
pub fn read(helm_bench_dir: &Path) -> (Vec<PaneAgent>, Vec<Unreadable>) {
    let file = path(helm_bench_dir);
    let unreadable = |why: String| Unreadable {
        source: SOURCE.into(),
        path: file.display().to_string(),
        why,
    };
    let bytes = match std::fs::read(&file) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return (Vec::new(), Vec::new()),
        Err(e) => return (Vec::new(), vec![unreadable(e.to_string())]),
    };
    let snapshot: Snapshot = match serde_json::from_slice(&bytes) {
        Ok(s) => s,
        Err(e) => return (Vec::new(), vec![unreadable(format!("not a snapshot: {e}"))]),
    };
    if snapshot.format != FORMAT || snapshot.version != VERSION {
        return (
            Vec::new(),
            vec![unreadable(format!(
                "format {:?} version {} — this build reads {FORMAT:?} version {VERSION}",
                snapshot.format, snapshot.version
            ))],
        );
    }
    let mut panes = Vec::new();
    let mut problems = Vec::new();
    let all = snapshot
        .workspaces
        .into_iter()
        .flat_map(|w| w.columns)
        .flat_map(|c| c.slots)
        .flat_map(|s| s.panes);
    for pane in all {
        let Some(terminal) = pane.terminal else {
            continue;
        };
        let Ok(id) = PaneId::parse(&pane.id) else {
            problems.push(unreadable(format!("pane id {:?} is not a uuid", pane.id)));
            continue;
        };
        let harness = |raw: &str| {
            Harness::parse(raw).ok_or_else(|| format!("pane {id}: unknown agent {raw:?}"))
        };
        let owner = match terminal.owner {
            None => None,
            Some(o) => match o.runtime.as_deref().map(harness) {
                // An owner with no runtime is a mailbox claim nothing names; it hosts nothing
                // this list can open.
                None => None,
                Some(Ok(h)) => Some(Owner {
                    harness: h,
                    pid: o.pid,
                    session: o.session_id,
                    cwd: o.cwd,
                }),
                Some(Err(why)) => {
                    problems.push(unreadable(why));
                    continue;
                }
            },
        };
        let resumable = match terminal.resumable {
            None => None,
            Some(r) => match harness(&r.command) {
                Ok(h) => Some(Resumable {
                    harness: h,
                    session: r.session,
                    cwd: r.cwd,
                }),
                Err(why) => {
                    problems.push(unreadable(why));
                    continue;
                }
            },
        };
        panes.push(PaneAgent {
            pane: id,
            foreground_pid: terminal.foreground_pid,
            owner,
            resumable,
        });
    }
    (panes, problems)
}

// The subset of helm's `BenchSnapshot` (Sources/Helm/Board/BenchSnapshot.swift) read here.
// Unknown fields are ignored: helm adds optionals without bumping the version.

#[derive(Deserialize)]
struct Snapshot {
    format: String,
    version: u64,
    workspaces: Vec<WorkspaceRecord>,
}

#[derive(Deserialize)]
struct WorkspaceRecord {
    columns: Vec<ColumnRecord>,
}

#[derive(Deserialize)]
struct ColumnRecord {
    slots: Vec<SlotRecord>,
}

#[derive(Deserialize)]
struct SlotRecord {
    panes: Vec<PaneRecord>,
}

#[derive(Deserialize)]
struct PaneRecord {
    id: String,
    terminal: Option<TerminalRecord>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TerminalRecord {
    foreground_pid: Option<u32>,
    owner: Option<OwnerRecord>,
    resumable: Option<ResumableRecord>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OwnerRecord {
    runtime: Option<String>,
    pid: u32,
    session_id: Option<String>,
    cwd: Option<String>,
}

#[derive(Deserialize)]
struct ResumableRecord {
    command: String,
    session: String,
    cwd: String,
}
