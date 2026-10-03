//! The session list on the wire (#384): every agent session in a workspace, one typed row
//! each, with the one action that opens it. `bench-sessions` builds the rows; benchd serves
//! them as `sessions/all` and keeps the two records below; helm's drawer renders them.

use bench_doc::PaneId;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// The agent runtime a session belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Harness {
    Claude,
    Codex,
    Pi,
}

impl Harness {
    pub fn name(self) -> &'static str {
        match self {
            Harness::Claude => "claude",
            Harness::Codex => "codex",
            Harness::Pi => "pi",
        }
    }

    /// The spelling helm and benchd use for an agent command (`owner.runtime`,
    /// `resumable.command`, `AgentKind::name`). Anything else is not a harness.
    pub fn parse(raw: &str) -> Option<Harness> {
        match raw {
            "claude" => Some(Harness::Claude),
            "codex" => Some(Harness::Codex),
            "pi" => Some(Harness::Pi),
            _ => None,
        }
    }
}

/// One session. `open` is not an independent field: benchd computes it from `harness`,
/// `host` and `state` in one place (`bench_sessions::open_action`) and sends it, so no
/// reader re-derives the rules.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionRow {
    pub harness: Harness,
    /// The harness's own id: Claude session id, pi session id, codex thread id, subagent id. A
    /// benchd session with no harness id carries its bench session id here instead.
    pub id: String,
    /// Some only for a subagent: the session or subagent that started it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    /// The registry name, the job name, or `agentType · description` for a subagent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub cwd: String,
    /// The worktree root the row was scoped by: the repo or one of its worktrees.
    pub root: String,
    /// The short branch checked out in `root`, or none when it has no readable branch.
    pub branch: Option<String>,
    /// The model the agent runs, as its harness last recorded it: Claude's `model` attachment
    /// (written at start and on every `/model`), pi's `model_change`, the model of codex's latest
    /// `turn_context`. `null` while the harness has recorded none (a codex before its first
    /// turn), and always sent.
    pub model: Option<String>,
    pub state: SessionState,
    pub host: Host,
    pub open: OpenAction,
    /// Where to mail this session, when it has a benchd mailbox: a session benchd spawned, or
    /// one whose hook claimed a mailbox through `bench hook` (#358). `null` otherwise, and
    /// always sent.
    pub mail: Option<MailAddress>,
    /// Claude's `statusUpdatedAt` for a live registry session; when its wait began for a row
    /// benchd sees waiting on the operator (M1, #357); a file's mtime otherwise.
    pub updated_at_ms: u64,
    /// A running session whose last turn ended and that has not started another (M1, #357).
    /// `null` otherwise, and always sent.
    pub done: Option<crate::Done>,
    /// Unread mail this session's mailbox sent the operator (M1, #357), unlike `mail`, which is
    /// mail waiting for it. `null` when there is none, and always sent.
    pub operator_mail: Option<crate::OperatorMail>,
    /// Who spawned it (M1, #357): the operator, or an agent and its handle. `null` when benchd
    /// never recorded it (an entry from before it did, a session it only saw in a pane); always
    /// sent. The row's own handle is `mail.handle`.
    pub spawner: Option<Spawner>,
}

/// Who spawned a session. Tagged from the first kind, so a third is an addition.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Spawner {
    /// The operator: his gesture in helm, helm acting for him, `bench spawn` from his shell, or an
    /// agent he started himself in a pane.
    Operator,
    /// An agent, by its mailbox handle.
    Agent { handle: String },
}

impl Spawner {
    /// The handle its finished turns are addressed to (`Done::to`).
    pub fn handle(&self) -> &str {
        match self {
            Spawner::Operator => crate::OPERATOR_HANDLE,
            Spawner::Agent { handle } => handle,
        }
    }
}

/// A benchd mailbox: who to `bench mail send --to`, and what that send will do.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MailAddress {
    pub handle: String,
    /// benchd can start a turn for this agent when it is idle: its hooks reported a channel
    /// (a Claude session's inbox socket) and it has not held a push. A send answers
    /// `"wake": "queued"`. False: the mail waits for the agent's next prompt or tool call, and
    /// a send answers `"wake": "next-turn"`.
    pub wakeable: bool,
    /// Messages in the inbox: delivered and neither read nor retired by a wake.
    pub unread: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SessionState {
    Running { activity: Activity },
    Finished { at_ms: u64 },
}

impl SessionState {
    pub fn is_running(&self) -> bool {
        matches!(self, SessionState::Running { .. })
    }
}

/// What a running session is doing, as far as its harness says. `Unknown` is a harness
/// that publishes no status (codex, pi) — absence, never a guess.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Activity {
    Busy,
    /// Running a shell command (Claude's `shell` status).
    Shell,
    Idle,
    /// Claude's `waiting`, with its own `waitingFor` words verbatim.
    Waiting {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        waiting_for: Option<String>,
    },
    /// A `--bg` job waiting on someone: the job's own state word (`blocked`,
    /// `needs_approval`, `needs_reply`) and its detail line.
    Blocked {
        state: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    /// A subagent whose turn ended while tasks it started have not reported back. It wakes
    /// when they do, so it is not finished.
    WaitingOnTasks {
        count: u32,
    },
    Unknown,
}

/// Where a session runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Host {
    /// A helm terminal pane.
    Pane { pane: PaneId },
    /// A benchd pty session.
    Bench { session: String },
    /// A Claude Code `--bg` job.
    Background { job: String },
    /// A subagent inside another session; `transcript` is its own file.
    InSession { parent: String, transcript: String },
    /// Nowhere any more: a finished session.
    None,
}

/// The one thing to do with a row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum OpenAction {
    FocusPane {
        pane: PaneId,
    },
    BenchAttach {
        session: String,
    },
    ClaudeAttach {
        job: String,
    },
    /// A finished conversation, resumed at `cwd`: helm sends `spawn --resume` (#621); `argv` is
    /// the harness's own command, for a reader of `bench sessions --all`.
    Resume {
        argv: Vec<String>,
        cwd: String,
    },
    /// Read-only: the subagent's transcript, and the session to jump to instead.
    Transcript {
        path: String,
        parent: String,
    },
}

/// `sessions/log`: one session's transcript, as `bench log` reads it (Pocket's chat, #625).
/// `id` is a session id as a `sessions/all` row carries it (a Claude session, a codex thread, a
/// pi session), never a path: the verb answers a client over TCP, which must not be able to point
/// it at any file. The transcript only grows, so an entry's `index` in it is the cursor.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionLogArgs {
    pub id: String,
    /// Up to `limit` entries before this index: paging back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<usize>,
    /// Up to `limit` entries after this index: following new ones.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<usize>,
    /// How many entries at most; 50 when absent, never more than 200. With no cursor, the last.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<usize>,
}

/// `sessions/log`'s answer: entries in transcript order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionLog {
    pub harness: Harness,
    pub id: String,
    /// How many entries the transcript has: the next one's index.
    pub total: usize,
    pub entries: Vec<SessionLogEntry>,
    /// Lines the reader skipped because it did not know their shape.
    pub unreadable: usize,
}

/// What a transcript entry is: the one spelling `bench log`, `sessions/log` and helm's copy
/// (`BenchLogEntry.Kind`) share.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    /// A prompt: the operator's, a spawner's, or a notice the harness delivered as a turn.
    User,
    /// The agent's text reply.
    Agent,
    /// A tool call: `tool` is its name and `text` a short argument.
    Tool,
    /// A failed tool call (`tool` names it) or an error the harness recorded.
    Error,
}

/// One entry of a transcript (`bench_sessions::transcript::Entry`) and its place in it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionLogEntry {
    pub index: usize,
    /// When it was written, in epoch ms, from the record's own timestamp.
    pub at_ms: u64,
    pub kind: EntryKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    pub text: String,
}

/// A file a reader could not read as the shape it knows. The row it would have produced is
/// skipped; benchd logs each one once as `sessions/unreadable` and lists them in every reply
/// until the file changes. Every Claude source is internal and undocumented, so this is how
/// a Claude Code release that changes one shows up.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Unreadable {
    /// Which reader: `claude-registry`, `claude-job`, `claude-subagent`, `pi-session` — or
    /// `session-list` for a row the list itself had no action for
    /// (a combination of host and state no reader should produce; `path` is its cwd).
    pub source: String,
    pub path: String,
    pub why: String,
}

/// `sessions/all`'s payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionsArgs {
    /// Any path inside the workspace: the repo, one of its worktrees, or a directory in one.
    pub workspace: String,
}

/// `sessions/all`'s answer. Running rows first, then by `updated_at_ms`, newest first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionList {
    /// The repo root the workspace resolved to.
    pub workspace: String,
    /// The repo and every worktree git knows about — what `root` on a row is one of.
    pub roots: Vec<String>,
    /// The operator's mailbox. Always addressable, claimable by no session, and never
    /// wakeable: benchd hosts no session for the operator.
    pub operator: MailAddress,
    pub rows: Vec<SessionRow>,
    pub total: usize,
    pub returned: usize,
    pub truncated: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unreadable: Vec<Unreadable>,
}

/// A session's identity across harnesses: `sessions/dismiss`'s payload, and the key of both
/// records.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct SessionKey {
    pub harness: Harness,
    pub id: String,
}

/// How benchd came to know a session ran in helm or in benchd.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum HostedVia {
    Pane {
        pane: PaneId,
        /// The mailbox its hook claimed (#358). Absent for a session seen only in a pane's
        /// foreground, and in entries recorded before the hook existed.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        handle: Option<String>,
    },
    Bench {
        session: String,
        /// The session's mailbox handle, which outlives the session: its finished row still
        /// says where its mail waits after `close` or a daemon restart. Absent in entries
        /// recorded before #396.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        handle: Option<String>,
    },
}

/// One entry of the hosted-sessions record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostedSession {
    pub harness: Harness,
    pub id: String,
    /// The cwd the session was started in — where its harness keeps its transcript.
    pub cwd: String,
    pub via: HostedVia,
    pub recorded_at: String,
    /// The conversation this one was forked from (#531): a fork is resumed read-only, as it
    /// was spawned. Absent for everything else.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub forked_from: Option<String>,
    /// The Claude login it last ran on, as the config dir benchd set (benchd's `accounts`): a
    /// resume goes back there, where its prompt cache is. Absent for the default login, for
    /// other harnesses, and for a session benchd did not start.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<crate::ConfigDir>,
    /// What attention needs to remember about it (M1, #357), kept beside the rest of the entry.
    #[serde(flatten)]
    pub attention: AttentionRecord,
}

/// The only state attention keeps (M1, #357); everything else it says is projected from what
/// benchd already knows. Every field is absent in entries recorded before it existed.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttentionRecord {
    /// Who spawned it: whose its finished turns are. Absent when benchd did not record it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spawner: Option<Spawner>,
    /// When its last turn ended, in epoch ms; cleared when it starts another. Kept on disk so a
    /// finished turn nobody looked at is still one after a daemon restart.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_ended_ms: Option<u64>,
    /// When the operator last looked at it: focused its pane, or marked it seen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen_ms: Option<u64>,
}

impl HostedSession {
    pub fn key(&self) -> SessionKey {
        SessionKey {
            harness: self.harness,
            id: self.id.clone(),
        }
    }

    /// Its mailbox, wherever it ran. A handle outlives its session.
    pub fn handle(&self) -> Option<&str> {
        match &self.via {
            HostedVia::Pane { handle, .. } | HostedVia::Bench { handle, .. } => handle.as_deref(),
        }
    }
}

pub const HOSTED_RECORD_FORMAT: &str = "bench.hosted-sessions";
pub const HOSTED_RECORD_VERSION: u64 = 0;

/// `<root>/sessions/hosted.json`: every session benchd or helm hosted, as benchd saw it.
/// The only source of finished rows — no harness file records where a session ran (spike
/// Evidence 6: 100 of 150 finished Claude rows were Archon runs). Written only by benchd.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostedRecord {
    pub format: String,
    pub version: u64,
    pub sessions: Vec<HostedSession>,
}

/// One dismissal: the finished row of `key` is hidden while it finished at or before `at_ms`.
/// A session resumed and finished again later comes back.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Dismissal {
    pub harness: Harness,
    pub id: String,
    pub at_ms: u64,
}

impl Dismissal {
    pub fn key(&self) -> SessionKey {
        SessionKey {
            harness: self.harness,
            id: self.id.clone(),
        }
    }
}

pub const DISMISSED_RECORD_FORMAT: &str = "bench.dismissed-sessions";
pub const DISMISSED_RECORD_VERSION: u64 = 0;

/// `<root>/sessions/dismissed.json`. Written only by benchd.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DismissedRecord {
    pub format: String,
    pub version: u64,
    pub dismissed: Vec<Dismissal>,
}

pub fn sessions_dir(root: &Path) -> PathBuf {
    root.join("sessions")
}

pub fn hosted_path(root: &Path) -> PathBuf {
    sessions_dir(root).join("hosted.json")
}

pub fn dismissed_path(root: &Path) -> PathBuf {
    sessions_dir(root).join("dismissed.json")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    /// `fixtures/session-rows.json` pins the reply helm's drawer decodes — every state,
    /// activity, host and open action — the two requests it sends, and both records, written
    /// back byte for byte.
    #[test]
    fn the_session_rows_fixture_covers_every_variant_and_round_trips() {
        let path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/session-rows.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();
        let list: SessionList = serde_json::from_value(value["list"].clone()).unwrap();
        let hosted: HostedRecord = serde_json::from_value(value["hosted"].clone()).unwrap();
        let dismissed: DismissedRecord =
            serde_json::from_value(value["dismissed"].clone()).unwrap();
        // The two requests helm's drawer sends: `sessions/all`'s and `sessions/dismiss`'s args.
        let all_args: SessionsArgs = serde_json::from_value(value["all_args"].clone()).unwrap();
        let dismiss_args: SessionKey =
            serde_json::from_value(value["dismiss_args"].clone()).unwrap();

        let kinds = |f: &dyn Fn(&SessionRow) -> Value| -> Vec<String> {
            let mut k: Vec<String> = list
                .rows
                .iter()
                .map(|r| f(r)["kind"].as_str().unwrap().to_string())
                .collect();
            k.sort();
            k.dedup();
            k
        };
        assert_eq!(
            kinds(&|r| json!(r.host)),
            ["background", "bench", "in_session", "none", "pane"]
        );
        assert_eq!(
            kinds(&|r| json!(r.open)),
            [
                "bench_attach",
                "claude_attach",
                "focus_pane",
                "resume",
                "transcript"
            ]
        );
        let activities = kinds(&|r| match &r.state {
            SessionState::Running { activity } => json!(activity),
            SessionState::Finished { .. } => json!({"kind": "finished"}),
        });
        assert_eq!(
            activities,
            [
                "blocked",
                "busy",
                "finished",
                "idle",
                "shell",
                "unknown",
                "waiting",
                "waiting_on_tasks"
            ]
        );
        assert!(!list.unreadable.is_empty());
        // Both answers to "can I mail it": no benchd mailbox (`null`, and sent as `null`), and
        // an address — wakeable and not.
        let mail: Vec<Option<bool>> = {
            let mut m: Vec<Option<bool>> = list
                .rows
                .iter()
                .map(|r| r.mail.as_ref().map(|a| a.wakeable))
                .collect();
            m.sort();
            m.dedup();
            m
        };
        assert_eq!(mail, [None, Some(false), Some(true)]);
        let branches: Vec<Option<&str>> = list.rows.iter().map(|r| r.branch.as_deref()).collect();
        assert!(branches.contains(&Some("feat/sessions")));
        assert!(branches.contains(&None));
        let models: Vec<Option<&str>> = list.rows.iter().map(|r| r.model.as_deref()).collect();
        assert!(models.contains(&Some("claude-opus-5-5[1m]")));
        assert!(models.contains(&None));
        assert_the_fixture_carries_attention(&list, &hosted);
        // Each is sent as `null` rather than left out: every row says whether it has a mailbox,
        // whether its worktree has a branch, whether its model is known, and its attention.
        for key in [
            "mail",
            "branch",
            "model",
            "done",
            "operator_mail",
            "spawner",
        ] {
            let rows = value["list"]["rows"].as_array().unwrap();
            assert!(rows.iter().all(|r| r.get(key).is_some()), "{key}");
        }
        assert_eq!(list.operator.handle, crate::OPERATOR_HANDLE);

        let written = serde_json::to_string_pretty(&json!({
            "list": list, "hosted": hosted, "dismissed": dismissed,
            "all_args": all_args, "dismiss_args": dismiss_args,
        }))
        .unwrap()
            + "\n";
        assert_eq!(
            written,
            text,
            "the spelling drifted from {}",
            path.display()
        );
    }

    /// Attention (M1, #357): a finished turn seen and not, to the operator and to the agent that
    /// spawned it, mail to the operator with and without a subject, and the record's three fields.
    fn assert_the_fixture_carries_attention(list: &SessionList, hosted: &HostedRecord) {
        let done: Vec<(bool, &str)> = list
            .rows
            .iter()
            .filter_map(|r| Some((r.done.as_ref()?.seen, r.done.as_ref()?.to.as_str())))
            .collect();
        assert!(done.contains(&(false, "orchestrator")) && done.contains(&(true, "operator")));
        let subjects: Vec<bool> = list
            .rows
            .iter()
            .filter_map(|r| Some(r.operator_mail.as_ref()?.subject.is_some()))
            .collect();
        assert!(subjects.contains(&true) && subjects.contains(&false));
        let spawners: Vec<Option<&Spawner>> =
            list.rows.iter().map(|r| r.spawner.as_ref()).collect();
        assert!(spawners.contains(&None) && spawners.contains(&Some(&Spawner::Operator)));
        assert!(
            spawners
                .iter()
                .any(|s| matches!(s, Some(Spawner::Agent { .. })))
        );
        assert!(hosted.sessions.iter().any(|h| h.attention.spawner.is_some()
            && h.attention.turn_ended_ms.is_some()
            && h.attention.seen_ms.is_some()));
    }

    #[test]
    fn a_harness_is_one_of_three_spellings() {
        for h in [Harness::Claude, Harness::Codex, Harness::Pi] {
            assert_eq!(Harness::parse(h.name()), Some(h));
            assert_eq!(json!(h), json!(h.name()));
        }
        assert_eq!(Harness::parse("test-echo"), None);
    }
}
