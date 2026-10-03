//! Every wire type and every shared resolution rule, spelled once.
//!
//! This crate exists so that `benchd` and `bench` can never disagree about what travels
//! on the socket or where a suite's state lives. helm spent real incidents on the other
//! arrangement — three copies of the mailbox rule in three languages, held together by a
//! conformance harness (deleted with helm's mailroom in #358). Rust on both ends of this socket
//! means the single spelling is finally free; anything that later reads these types from
//! Swift gets a generated or conformance-pinned copy, never a hand-written one
//! (bench-roadmap.md, invariant 9).
//!
//! The protocol itself is deliberately small: one connection carries one JSON request line
//! and one JSON response line, then closes. No framing, no multiplexing, no versioned
//! handshake — those arrive when a milestone needs them, and `Request`/`Response` carry
//! nothing a later field cannot extend compatibly.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

pub mod attach;
mod layout;
pub use layout::{
    Actor, DOCUMENT_CHANGED, DOCUMENT_RECORD_FORMAT, DOCUMENT_RECORD_VERSION, Divider, DocumentAt,
    DocumentChange, DocumentRecord, Frame, LAYOUT_VERBS, LayoutReport, LayoutVerb, MoveTo,
    OpenInto, PaneOpen, RULES_LOADED, RULES_REJECTED, document_path, placement_rules_path,
};

pub mod hook;
pub use hook::{HookArgs, HookReply};

mod usage;
pub use usage::{Usage, UsageWindow};

mod commands;
pub use commands::{
    COMMAND_OUTPUT_MAX_BYTES, Command, CommandRun, CommandRunArgs, GitRepositories,
    GitRepositoriesArgs, GitRepository, PathExists, PathExistsArgs,
};

mod files;
pub use files::{
    Expect, FILE_CHANGED, FILE_READ_MAX_BYTES, FILE_REQUEST_MAX_BYTES, FileAppendArgs, FileChanged,
    FileRead, FileReadArgs, FileWrite, FileWriteArgs, LIVE_SUFFIX, NOTES_SUFFIX, base64,
    is_notes_sidecar, live_file, notes_sidecar, unbase64,
};

mod prp;
pub use prp::{
    NOTES_DIRECTORY, PRP_RESOLVE_WAIT, PathKind, PathResolveArgs, PathResolved, PrpArtifact,
    PrpArtifacts, PrpArtifactsArgs, PrpNote, PrpNoteArgs, PrpStore, PrpStores, PrpStoresArgs,
    RENDERABLE, is_renderable,
};

mod just;
pub use just::{
    JUST_FINISHED, JUST_STARTED, JustFinished, JustList, JustRunArgs, JustStarted, is_recipe_name,
    just_logs_dir, justfile_path,
};

mod sessions;
pub use sessions::{
    Activity, AttentionRecord, DISMISSED_RECORD_FORMAT, DISMISSED_RECORD_VERSION, Dismissal,
    DismissedRecord, HOSTED_RECORD_FORMAT, HOSTED_RECORD_VERSION, Harness, Host, HostedRecord,
    HostedSession, HostedVia, MailAddress, OpenAction, SessionKey, SessionList, SessionLog,
    SessionLogArgs, SessionLogEntry, SessionRow, SessionState, SessionsArgs, Spawner, Unreadable,
    dismissed_path, hosted_path, sessions_dir,
};

/// This build of the bench, as `status.version` and `bench --version` both say it. helm runs
/// its own `bench` against a benchd over TCP and refuses to attach when the two differ, so bump
/// the workspace version (`daemon/Cargo.toml`) with any change to the wire, as 0.0.2 did when
/// `sessions` gained `report` and `status` its `version`.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// A request line larger than this is refused, not read. The cap is about the reader:
/// every accepted byte can end up in an event log an agent later pulls into context.
pub const MAX_REQUEST_BYTES: usize = 64 * 1024;

// ---------------------------------------------------------------------------
// Suite names
// ---------------------------------------------------------------------------

/// A validated suite name — the isolation primitive, ported from helm's
/// `HELM_DEFAULTS_SUITE` (#86) with the same posture: **refuse loudly rather than fall
/// back to the live instance.** A test that launches under a suite it believes isolates
/// it, and silently lands in the operator's `~/.bench`, is exactly the disaster helm
/// #285 documents. So a name that cannot isolate is an error at the edge, never a
/// fallback to the shared root.
///
/// The unchecked value is unrepresentable: the only route in is `validate`, and every
/// path builder below takes `&SuiteName`, not `&str`. (helm's `RequestID`/#260 argument,
/// applied on day one instead of after the incident.)
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct SuiteName(String);

impl SuiteName {
    /// Lowercase ASCII letters, digits and `-`; must start alphanumeric; at most 32
    /// bytes. Everything else is refused with a reason that names the rule, because the
    /// refusal is read by an agent that has to fix its call.
    pub fn validate(raw: &str) -> Result<Self, String> {
        if raw.is_empty() {
            return Err(
                "a suite name cannot be empty — unset BENCH_SUITE for the live instance".into(),
            );
        }
        if raw.contains('/') || raw.contains('\\') || raw.contains("..") {
            return Err(format!(
                "a path is not a suite name: {raw:?} — the suite decides the directory, never names it"
            ));
        }
        if raw.len() > 32 {
            return Err(format!(
                "suite name too long ({} bytes, max 32): {raw:?}",
                raw.len()
            ));
        }
        let mut chars = raw.chars();
        let first_ok = chars
            .next()
            .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
        let rest_ok = raw
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
        if !first_ok || !rest_ok {
            return Err(format!(
                "a suite name is lowercase ASCII letters, digits and '-', starting alphanumeric: {raw:?}"
            ));
        }
        Ok(SuiteName(raw.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

// ---------------------------------------------------------------------------
// Request ids
// ---------------------------------------------------------------------------

/// A validated request id. Port of helm's `RequestID` (#260), not a reinvention: the
/// pattern is the filename-safe one, because M3's socketless drop-box will use ids as
/// filenames and an ungated id writes wherever the caller likes. Gating it now costs one
/// type; gating it at M3 would be a migration.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct RequestId(String);

impl RequestId {
    /// First char ASCII alphanumeric; the rest alphanumeric, `.`, `_` or `-`; 1–64 bytes.
    pub fn validate(raw: &str) -> Result<Self, String> {
        let mut chars = raw.chars();
        let first_ok = chars.next().is_some_and(|c| c.is_ascii_alphanumeric());
        let rest_ok = raw
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-');
        if raw.is_empty() || raw.len() > 64 || !first_ok || !rest_ok {
            return Err(format!(
                "a request id is 1-64 bytes of [A-Za-z0-9._-], starting alphanumeric: {raw:?}"
            ));
        }
        Ok(RequestId(raw.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

// ---------------------------------------------------------------------------
// Verbs
// ---------------------------------------------------------------------------

/// Every verb this daemon answers, spelled once (PR #340 review, R5). The refusal
/// string derives from this list, the dispatcher matches on the parsed enum so the
/// compiler forces a verdict when a verb is added, and the justfile's probe list is
/// pinned to it by a conformance test that reads the justfile's own source.
pub const KNOWN_VERBS: &[&str] = &[
    "status",
    "events",
    "stop",
    "spawn",
    "sessions",
    "sessions/all",
    "sessions/dismiss",
    // M1 (#357): the operator has seen a session's finished turn.
    "sessions/seen",
    // #625: one session's transcript, for Pocket's chat.
    "sessions/log",
    "attach",
    "close",
    "mail/send",
    "mail/list",
    "mail/read",
    "mail/who",
    "hook",
    // #143: a harness's plan limits, reported by `bench statusline` (Claude's statusline).
    "usage/report",
    "browser/start",
    "browser/status",
    "browser/stop",
    "browser/setup",
    // M5c: a view onto the shared browser, relayed by benchd for a helm that may not share its
    // machine.
    "browser/connect",
    // A file the operator chose on helm's machine, for a page's file input (helm #549).
    "browser/upload",
    "just/run",
    "just/list",
    // M5b: give terminal panes whose session ended a session again (`just resume-all`).
    "restore",
    // M5b: read and type into any terminal, through its session's VT engine.
    "screen/get",
    "screen/send",
    // M5c: a canvas's files, read and written by benchd for a helm that may not share its disk.
    "file/read",
    "file/write",
    "file/append",
    // M5c: the drawers' git and archon, run on benchd's machine for a helm that may not be on it.
    "command/run",
    "path/exists",
    "git/repositories",
    // M5c: prp's stores and the paths the operator types, answered on benchd's machine.
    "prp/note",
    "prp/stores",
    "prp/artifacts",
    "path/resolve",
    // The layout verbs (M4) — `LAYOUT_VERBS`, spelled again here so this one list stays the
    // whole surface; `every_layout_verb_is_known_and_routes_to_layout` keeps the two in step.
    "bench/get",
    "workspace/open",
    "workspace/close",
    "workspace/activate",
    "workspace/move",
    "pane/open",
    "pane/split",
    "pane/close",
    "pane/show",
    "pane/move",
    "pane/name",
    "focus/slot",
    "focus/step",
    "focus/waiting",
    "layout/resize",
    "drawer/toggle",
    "drawer/place",
    // M3: benchd asks helm for what only helm can do.
    "helm/ask",
    "helm/answer",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verb {
    Status,
    Events,
    Stop,
    Spawn,
    Sessions,
    /// Every agent session in a workspace (#384).
    SessionsAll,
    /// Hide a finished session from `sessions/all`.
    SessionsDismiss,
    /// Mark a session's finished turn seen (`SessionKey`): what focusing its pane does.
    SessionsSeen,
    /// One session's transcript entries (`SessionLogArgs`).
    SessionsLog,
    Attach,
    Close,
    MailSend,
    MailList,
    MailRead,
    /// Which mailbox the agent in a helm pane holds (#358): how helm addresses a pane.
    MailWho,
    /// The sensor (#358): an agent's hook reports an event; the answer carries its mail.
    Hook,
    /// A harness's plan limits (#143): what `bench statusline` reads off Claude's statusline.
    UsageReport,
    BrowserStart,
    BrowserStatus,
    BrowserStop,
    BrowserSetup,
    /// The connection becomes a relay of CDP messages to the running browser, one JSON line
    /// each way (`BrowserConnected`).
    BrowserConnect,
    /// A file for a page's file input, kept on benchd's machine (`BrowserUploadArgs`).
    BrowserUpload,
    /// Run a recipe from the operator's bench justfile (#356).
    JustRun,
    /// Name the recipes in it (#500).
    JustList,
    /// Every verb in `LAYOUT_VERBS`; `LayoutVerb` decodes which one and its arguments.
    Layout,
    /// Terminal panes whose session ended get one again (`RestoreArgs`).
    Restore,
    /// A terminal's screen, read off its session's VT engine (`ScreenGetArgs`).
    ScreenGet,
    /// Text typed into a terminal (`ScreenSendArgs`).
    ScreenSend,
    /// Something only helm can do, asked of whichever helm follows the bench (`HelmAsk`).
    HelmAsk,
    /// helm's answer to one (`HelmAnswer`).
    HelmAnswer,
    /// A canvas's file, its sibling or its sidecar, read for helm (`FileReadArgs`).
    FileRead,
    /// A canvas's file written for helm, against what it expects to replace (`FileWriteArgs`).
    FileWrite,
    /// A note appended to a canvas's sidecar (`FileAppendArgs`).
    FileAppend,
    /// `git` or `archon` run on benchd's machine (`CommandRunArgs`).
    CommandRun,
    /// Which of some paths exist on benchd's machine (`PathExistsArgs`).
    PathExists,
    /// Every repository under benchd's home (`GitRepositoriesArgs`).
    GitRepositories,
    /// An operator note started in a workspace's prp store (`PrpNoteArgs`).
    PrpNote,
    /// The prp stores, and a workspace's (`PrpStoresArgs`).
    PrpStores,
    /// One store's renderable files (`PrpArtifactsArgs`).
    PrpArtifacts,
    /// A typed path, resolved on benchd's machine (`PathResolveArgs`).
    PathResolve,
}

impl Verb {
    /// `None` is an unknown verb — the caller owes a refusal naming `KNOWN_VERBS`.
    pub fn parse(raw: &str) -> Option<Verb> {
        match raw {
            "status" => Some(Verb::Status),
            "events" => Some(Verb::Events),
            "stop" => Some(Verb::Stop),
            "spawn" => Some(Verb::Spawn),
            "sessions" => Some(Verb::Sessions),
            "sessions/all" => Some(Verb::SessionsAll),
            "sessions/dismiss" => Some(Verb::SessionsDismiss),
            "sessions/seen" => Some(Verb::SessionsSeen),
            "sessions/log" => Some(Verb::SessionsLog),
            "attach" => Some(Verb::Attach),
            "close" => Some(Verb::Close),
            "mail/send" => Some(Verb::MailSend),
            "mail/list" => Some(Verb::MailList),
            "mail/read" => Some(Verb::MailRead),
            "mail/who" => Some(Verb::MailWho),
            "hook" => Some(Verb::Hook),
            "usage/report" => Some(Verb::UsageReport),
            "browser/start" => Some(Verb::BrowserStart),
            "browser/status" => Some(Verb::BrowserStatus),
            "browser/stop" => Some(Verb::BrowserStop),
            "browser/setup" => Some(Verb::BrowserSetup),
            "browser/connect" => Some(Verb::BrowserConnect),
            "browser/upload" => Some(Verb::BrowserUpload),
            "helm/ask" => Some(Verb::HelmAsk),
            "helm/answer" => Some(Verb::HelmAnswer),
            "just/run" => Some(Verb::JustRun),
            "just/list" => Some(Verb::JustList),
            "restore" => Some(Verb::Restore),
            "screen/get" => Some(Verb::ScreenGet),
            "screen/send" => Some(Verb::ScreenSend),
            "file/read" => Some(Verb::FileRead),
            "file/write" => Some(Verb::FileWrite),
            "file/append" => Some(Verb::FileAppend),
            "command/run" => Some(Verb::CommandRun),
            "path/exists" => Some(Verb::PathExists),
            "git/repositories" => Some(Verb::GitRepositories),
            "prp/note" => Some(Verb::PrpNote),
            "prp/stores" => Some(Verb::PrpStores),
            "prp/artifacts" => Some(Verb::PrpArtifacts),
            "path/resolve" => Some(Verb::PathResolve),
            layout if LAYOUT_VERBS.contains(&layout) => Some(Verb::Layout),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// I/O bounds
// ---------------------------------------------------------------------------

/// One connection may hold the daemon's serial loop for at most this long (R2): a
/// client that connects and never finishes its line gets a refusal, not the daemon.
pub const DAEMON_IO_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// How long `browser/start` waits for Chromium to write `DevToolsActivePort` — the
/// moment its debugging server is listening. A cold profile on a busy machine takes a
/// second or two; a browser that has not answered in this long is not going to.
pub const BROWSER_READY_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// A caller waits at most this long for an answer — strictly longer than every
/// daemon-side wait, **true by construction**: the longest wait (a browser start; a spawn
/// waits for nothing since #358) plus the I/O bound plus slack, so the two sides cannot
/// drift apart again (PR #341's R1). A timeout maps to
/// `EXIT_NO_DAEMON`: no exit code at all is the one failure an unattended agent cannot
/// act on.
pub const CLIENT_READ_TIMEOUT: std::time::Duration =
    std::time::Duration::from_secs(LONGEST_DAEMON_WAIT + DAEMON_IO_TIMEOUT.as_secs() + 5);

/// How long `helm/ask` waits for helm to answer. A capture draws one window, well under a
/// second; a helm that has not answered in this long is not following this bench.
pub const HELM_ASK_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// The longest wait the daemon does on a caller's behalf, in seconds.
const LONGEST_DAEMON_WAIT: u64 = if BROWSER_READY_WAIT.as_secs() > HELM_ASK_WAIT.as_secs() {
    BROWSER_READY_WAIT.as_secs()
} else {
    HELM_ASK_WAIT.as_secs()
};

// ---------------------------------------------------------------------------
// Handles and mail payloads
// ---------------------------------------------------------------------------

/// A mailbox handle. Same shape rule as suites — it decides a directory, so a path can
/// never be one — plus one reservation ported from helm's mailbox verbatim:
/// **`operator` is the operator's**, addressable by anyone, claimable by no session.
pub const OPERATOR_HANDLE: &str = "operator";

pub fn validate_handle(raw: &str) -> Result<(), String> {
    if raw.is_empty() {
        return Err("a handle cannot be empty".into());
    }
    if raw.contains('/') || raw.contains('\\') || raw.contains("..") {
        return Err(format!("a path is not a handle: {raw:?}"));
    }
    if raw.len() > 32
        || !raw
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        || !raw
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    {
        return Err(format!(
            "a handle is lowercase ASCII letters, digits and '-', starting alphanumeric, max 32: {raw:?}"
        ));
    }
    Ok(())
}

/// `mail/send`'s payload. The body travels IN the request; the notice a recipient gets
/// carries only the path (helm's rule: notice carries path, never body).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MailSendArgs {
    pub to: String,
    pub from: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    pub body: String,
}

/// `mail/list`'s payload: whose mailbox. Metadata only comes back — sender, subject,
/// time, read-state — bodies never; pull is on demand, push is minimal.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MailListArgs {
    pub handle: String,
}

/// `mail/read`'s payload: retire-never-delete — reading moves inbox → read, and the
/// response names the new path.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MailReadArgs {
    pub handle: String,
    pub id: String,
}

/// `mail/who`'s payload: a helm pane, by the uuid helm declares as `HELM_PANE`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MailWhoArgs {
    pub pane: String,
}

/// `mail/who`'s answer: the agent whose hook most recently reported from that pane and claimed
/// a mailbox there. helm reads it to address a canvas note and to name a spawned agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MailWho {
    pub handle: String,
    pub harness: Harness,
    pub session: String,
    /// The agent's process, as its last hook reported it. helm falls back to it when a spawn is
    /// claimed before the pty's foreground has moved off the shell.
    pub pid: u32,
}

// ---------------------------------------------------------------------------
// Session verb payloads
// ---------------------------------------------------------------------------

/// `spawn`'s payload, typed once (PR #341 review, R3): both binaries serialize and
/// decode this struct, so a one-sided rename is a compile error or a refusal naming
/// the missing field — never a silently-defaulted option or an allowlist refusal that
/// misdescribes a missing key.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpawnArgs {
    pub agent: String,
    pub cwd: String,
    /// The mailbox address and tab name — defaults to the session id. `operator` is
    /// refused: that handle is the operator's, addressable, never claimable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_file: Option<String>,
    /// The first prompt as text, for a caller with no disk benchd can read (helm over TCP):
    /// benchd writes it to a file under its root, which outlives the spawn, and starts the agent
    /// as for `prompt_file`. Refused with `prompt_file`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cols: Option<u16>,
    /// A runtime session id to re-enter rather than start fresh: claude's `--resume`, pi's
    /// `--session-id`, codex's `resume <id>`. Any conversation, not only one this bench
    /// started — how `just release-resume` brings the operator's own session back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<String>,
    /// A conversation to fork rather than re-enter (#531): a new conversation that starts as a
    /// copy of this one and runs read-only while the original carries on, under an id the bench
    /// mints (claude, pi) or codex names (its hook reports it). Refused with `resume`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fork: Option<String>,
    /// Flags for the agent, after its posture: added to it, never replacing it.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
}

/// What benchd asks of helm: the things only the window can do. Tagged by `kind` from the
/// first one, so a second is an addition rather than a migration.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum HelmAsk {
    /// helm draws its own window, the one titled like `window` when more than one is open. The
    /// answer's `data` is helm's capture report with the PNG in it as `png` (`base64`): helm
    /// may not share benchd's disk (M5c), so benchd writes the file and hands the caller the
    /// report with `path` where `png` was.
    Capture {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        window: Option<String>,
    },
}

/// `helm/ask`'s args: the ask, and where benchd writes the file its answer carries (a capture's
/// PNG). `out` is an absolute `.png` on benchd's side; absent, benchd picks one under its own
/// `captures/` (`captures_dir`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HelmAskArgs {
    #[serde(flatten)]
    pub ask: HelmAsk,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub out: Option<String>,
}

/// The key in a capture answer's `data` holding the PNG, and the one benchd replaces with
/// `path` once the file is written.
pub const CAPTURE_PNG_KEY: &str = "png";

/// Where benchd writes a capture nobody named a path for.
pub fn captures_dir(root: &Path) -> PathBuf {
    root.join("captures")
}

/// The data of a `helm/asked` event: which ask, and what it asks. helm reads these from its
/// `events --follow` and answers each with `helm/answer`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HelmAsked {
    pub ask: String,
    pub request: HelmAsk,
}

/// `helm/answer`'s payload: the ask it answers and helm's outcome, which benchd hands to the
/// caller unchanged — its status is the caller's exit code.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HelmAnswer {
    pub ask: String,
    pub status: Status,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

pub const HELM_ASKED: &str = "helm/asked";

/// One row of `sessions`: a session benchd runs, and the pane that shows it. helm reads `handle`,
/// `pane`, `foreground_pid`, `waiting`, `report`, `done` and `operator_mail` for each pane's agent
/// (the snapshot's `agent`, the attention it draws), so the shape is pinned by
/// `fixtures/session-list.json` on both sides.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SessionEntry {
    pub session: String,
    pub handle: String,
    /// `claude`, `codex`, `pi`, `shell` (a terminal pane's own), or `test-echo`.
    pub agent: String,
    pub cwd: String,
    pub pid: u32,
    /// The pane showing it, if one does.
    pub pane: Option<bench_doc::PaneId>,
    /// What has the terminal: the session's own process, or the job a shell is running. `None`
    /// once the session has ended.
    pub foreground_pid: Option<i32>,
    pub live: bool,
    pub attached: bool,
    pub output_bytes: u64,
    pub runtime_session: Option<String>,
    pub uptime_secs: u64,
    /// The agent in it is waiting on the operator (M1, #357); absent when it is not.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting: Option<Waiting>,
    /// What the agent in it says it is doing; absent when nothing there reports (a shell at
    /// its prompt, a harness whose hooks are not wired).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub report: Option<AgentReport>,
    /// The agent's last turn ended and it has not started another (M1, #357); absent otherwise.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub done: Option<Done>,
    /// Mail the agent sent the operator that he has not read; absent when there is none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operator_mail: Option<OperatorMail>,
}

/// An agent whose turn ended (Claude's `Stop`; for a codex on benchd's app-server its
/// `turn/completed`, else its `Stop`; pi's `agent_settled`) and that has not started another (M1,
/// #357). Present whether or not anybody looked, so `bench watch` can wait on
/// it; `seen` says whether the operator did.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Done {
    /// When the turn ended, in epoch ms.
    pub since_ms: u64,
    /// Whose it is: the handle of the agent that last spawned it (a `--resume` by another agent
    /// makes it that agent's), or `operator` for one he started.
    pub to: String,
    /// The operator focused its pane, or marked it seen (`sessions/seen`, his or an agent's he
    /// asked), after the turn ended. Nothing else clears it: nothing acknowledges or decays.
    pub seen: bool,
}

/// Unread mail from an agent to the operator (M1, #357): how much, and the oldest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OperatorMail {
    pub unread: usize,
    /// When the oldest unread message arrived, in epoch ms.
    pub since_ms: u64,
    /// Its subject, the agent's own words, when it gave one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
}

/// An agent's own report of what it is doing, read on benchd's machine (M5c, #459): Claude
/// Code's registry row for the process in the session's foreground, else the agent's last hook.
/// Never `Activity::Unknown`: nothing said is no report.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentReport {
    pub activity: Activity,
    /// When `activity` last changed, in epoch ms: a transition time, not a heartbeat. Absent
    /// when the registry row carries no time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since_ms: Option<u64>,
}

/// An agent waiting on the operator: at a permission prompt, a trust prompt, a question.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Waiting {
    /// What for, in words: the agent's own when it said so (`permission prompt`), else the
    /// screen rule's.
    pub waiting_for: String,
    /// Since when, in epoch ms: when the agent said so, or when its screen first showed it.
    pub since_ms: u64,
    pub source: WaitingSource,
}

/// Who said an agent is waiting. The agent's own report outranks its screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WaitingSource {
    /// Its hook (`bench hook`).
    Hook,
    /// Claude Code's own registry row for the process in the foreground, read when its output
    /// settled: the agent's own words even when its hooks are not wired.
    Registry,
    /// A prompt rule matched its screen.
    Screen,
}

/// The answer to `sessions`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LiveSessions {
    pub sessions: Vec<SessionEntry>,
    /// Each harness's plan limits as benchd last heard them (#143), at most one per harness;
    /// absent when none has reported since benchd started.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub usage: Vec<Usage>,
}

/// `restore`: one terminal pane, or every one (`pane` absent), whose session has ended gets a
/// session again — its recorded agent resumed, or a shell.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RestoreArgs {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
}

/// `screen/get`: the terminal a pane shows (`target` a pane id) or a session's (a session id).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScreenGetArgs {
    pub target: String,
    /// The rows above the screen too.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub history: bool,
}

/// `screen/send`: `text` typed into a terminal, pasted as one piece (bracketed when the program
/// asked for bracketed paste), then Return on its own when `enter`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScreenSendArgs {
    pub target: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub enter: bool,
    /// `text` is keys (Esc, Ctrl-C, an arrow, a digit picking an option): written as they are,
    /// never inside a bracketed paste, where a program reads them as pasted text.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub keys: bool,
}

/// `screen/send`'s answer: the session typed into, and whether the text went in as a bracketed
/// paste.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScreenSent {
    pub session: String,
    pub bracketed: bool,
}

/// A terminal's screen at a finished frame: `screen/get`'s answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScreenAnswer {
    pub session: String,
    pub rows: u16,
    pub cols: u16,
    /// `[column, row]` from zero.
    pub cursor: [u16; 2],
    pub cursor_visible: bool,
    pub title: String,
    pub pwd: String,
    /// A full-screen program has the alternate screen.
    pub alt_screen: bool,
    pub bracketed_paste: bool,
    /// One string per row, trailing blanks trimmed; with history, the rows above come first.
    pub lines: Vec<String>,
}

/// The payload shared by `attach` and `close`: a session id, plus the
/// viewer's size where the verb has a viewer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionArgs {
    pub session: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cols: Option<u16>,
}

// ---------------------------------------------------------------------------
// The shared browser
// ---------------------------------------------------------------------------

/// `<root>/browser/config.json` — how the operator swaps the browser without a code
/// change. Both keys are optional; an unknown key is refused rather than ignored, so a
/// typo (`"binnary"`) is a named refusal and not a silent fall back to the default.
///
/// - `binary`: absolute path to a Chromium-family executable. Default: Google Chrome
///   where it is installed (the operator's ruling on #350 — real Chrome runs the Claude
///   in Chrome and Codex extensions), else the newest Playwright Chrome for Testing.
/// - `mock_keychain`: see the field.
/// - `args`: REPLACES the headless browser's default set (`--headless=new`, a normal
///   Chrome user agent, `--remote-allow-origins`, a window size). The flags the daemon
///   owns — profile dir, debugging port, first-run suppression — are always added and
///   cannot be configured away. The setup browser takes none of these: it runs plain
///   (`bench_browser::setup_args`), because Google refuses sign-in to anything else.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BrowserConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub args: Option<Vec<String>>,
    /// `true` adds `--use-mock-keychain --password-store=basic`: Chrome keeps its
    /// cookie and password encryption key in the profile instead of the macOS login
    /// keychain. The trade-off is real — anything that can read the profile directory can
    /// then read the logged-in sessions in it — so the default is `false`: the shared
    /// browser runs under the operator's own HOME with his real keychain. The flags are
    /// added regardless whenever the browser runs under a HOME that is not the account's
    /// own (a test, a redirected HOME), because there macOS finds no keychain and offers
    /// to reset the operator's real ones (#350, measured the hard way).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mock_keychain: Option<bool>,
}

/// How the browser is running. `headless` is the normal state, seen only through helm's
/// pane. `setup` is the same profile in a plain Chrome window, started by `browser/setup`
/// so the operator can sign in and install extensions — things with browser UI the pane
/// cannot show. It has no debugging port, so nothing can connect to it and it publishes
/// no endpoint. Quitting the setup window returns the browser to `headless`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BrowserMode {
    Headless,
    Setup,
}

pub const BROWSER_ENDPOINT_FORMAT: &str = "bench.browser-endpoint";
/// 1 since #374: `mode` is gone, because only a headless browser has an endpoint.
pub const BROWSER_ENDPOINT_VERSION: u64 = 1;

/// Where the running browser is — the one shape written to `<root>/browser/endpoint.json`
/// and returned by `browser/start` and `browser/status`. It is read OUTSIDE this
/// workspace (agents' shells, `playwright-cli`), so it carries `format`/`version` and a
/// reader checks them before trusting the rest (`BenchSnapshot`'s rule).
///
/// `cdp` is what `playwright-cli attach --cdp=` takes; `ws` is the browser-level
/// websocket a CDP client opens directly. The file exists exactly while the headless
/// browser is running: written after it answers, removed when it stops or exits. A setup
/// browser has no debugging port and so no endpoint — while it runs there is no file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BrowserEndpoint {
    pub format: String,
    pub version: u64,
    pub cdp: String,
    pub ws: String,
    pub port: u16,
    pub pid: u32,
    pub binary: String,
    pub profile: String,
    pub started_at: String,
}

/// `browser/connect`'s answer: which browser the connection now relays to. After this line
/// the connection carries CDP messages, one JSON object per line in each direction: a line
/// the client writes is sent to the browser as one websocket message, and each message the
/// browser sends arrives as one line. helm's browser pane is the client (M5c), so it needs no
/// endpoint and no port on benchd's machine; agents keep `cdp` and Playwright.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BrowserConnected {
    pub pid: u32,
}

pub fn browser_dir(root: &Path) -> PathBuf {
    root.join("browser")
}

/// `browser/upload`'s payload (helm #549): a file the operator chose in helm's open panel for a
/// page's `<input type=file>`. Chrome takes a file input's files as paths on its own machine
/// (`DOM.setFileInputFiles`), so a helm on another machine sends the bytes here first. On one
/// machine helm passes its own path and never sends this. Capped, like `file/write`, by
/// `FILE_REQUEST_MAX_BYTES` on the request line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BrowserUploadArgs {
    /// The file's name, which the page sees: one path component.
    pub name: String,
    pub base64: String,
}

/// `browser/upload`'s answer: where benchd put the file, for `DOM.setFileInputFiles`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BrowserUploaded {
    pub path: String,
}

/// Where uploads are kept, one folder each so two files of one name never collide. Emptied
/// when benchd starts: a page reads its file when its form is sent, while the browser (benchd's
/// child) still runs.
pub fn browser_uploads_dir(root: &Path) -> PathBuf {
    browser_dir(root).join("uploads")
}

pub fn browser_config_path(root: &Path) -> PathBuf {
    browser_dir(root).join("config.json")
}

pub fn browser_endpoint_path(root: &Path) -> PathBuf {
    browser_dir(root).join("endpoint.json")
}

/// Present while the browser is wanted: written when one starts, removed only by
/// `browser/stop`. A daemon that boots and finds it starts the browser again, so a crash,
/// a `bench stop` or a reboot does not take the browser away with the daemon (#407).
pub fn browser_wanted_path(root: &Path) -> PathBuf {
    browser_dir(root).join("wanted")
}

pub fn browser_profile_dir(root: &Path) -> PathBuf {
    browser_dir(root).join("profile")
}

// ---------------------------------------------------------------------------
// The envelope
// ---------------------------------------------------------------------------

/// What a caller sends. `id` and `verb` stay raw `String`s **on purpose**: a request is
/// decoded permissively in shape and judged strictly afterwards, so a malformed id or an
/// unknown verb is a `refused` response naming the reason rather than unreadable JSON
/// with no reply. That is helm's standing carve-out (`CloseRequest.terminal`,
/// `SpawnRequest.cwd`) and it is load-bearing here for the same reason.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub id: String,
    pub verb: String,
    #[serde(default)]
    pub args: Value,
    /// Who asked. Absent means an agent — the reading that cannot move the operator's
    /// focus. Only the layout verbs read it today.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub by: Option<Actor>,
    /// The caller says the operator asked for this, so it may bring something forward or
    /// move focus. "Only when asked" is a rule in the agent's skill, not a check: the
    /// daemon cannot know what the operator said (helm #320).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub asked: bool,
}

/// Every response carries a status, and the status is the exit code: a caller never
/// parses prose to learn what happened. `reason` is for humans and agents; `data` is the
/// verb's payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    pub id: String,
    pub status: Status,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

/// The three outcomes, mapped onto helm's spool exit-code discipline. `2` (no daemon) is
/// deliberately absent: it is the *transport's* failure, decided by the caller when the
/// socket cannot be reached, never something a daemon could say about itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Ok,
    Refused,
    Error,
}

impl Status {
    /// 0 ok / 3 refused / 4 daemon failed — helm's spool codes, kept (bench-roadmap M0).
    pub fn exit_code(self) -> i32 {
        match self {
            Status::Ok => 0,
            Status::Refused => 3,
            Status::Error => 4,
        }
    }
}

/// The caller-side exit for "the socket could not be reached at all".
pub const EXIT_NO_DAEMON: i32 = 2;

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

/// The first event of every fresh log declares the file's format (R4): the record is
/// read outside the process, and a reader that predates a change must fail loudly on
/// the marker instead of misreading history — `BenchSnapshot.format`'s rule, applied to
/// the file that matters most.
pub const EVENTS_LOG_FORMAT: &str = "bench.events-log";
pub const EVENTS_LOG_VERSION: u64 = 0;

/// One line of the append-only record. **Bench-visible means logged**: anything a
/// projection, a snapshot, or a later reader is allowed to know happened must be
/// reconstructable from this stream — the file is the record, the socket is only
/// transport (bench-roadmap, invariants 7 and the dsh lesson in direction.md).
///
/// `kind` is namespaced `domain/what` (`daemon/started`). A reader that meets a kind it
/// does not know must refuse or skip *visibly*, never misread it — which is why the
/// envelope stays this small and flat.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Event {
    pub seq: u64,
    /// RFC 3339 UTC. A `cat` of the log is meant to be readable by a human having a bad
    /// morning; epoch integers are not that.
    pub at: String,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub data: Value,
}

// ---------------------------------------------------------------------------
// Where a bench lives on disk
// ---------------------------------------------------------------------------

/// Resolve the record root. One rule, spelled once, used by both binaries:
///
/// 1. `BENCH_DIR` names the root outright and wins over everything — it is what a test
///    claims into instead of the operator's estate (what `HELM_MAIL_DIR` was to helm's mail). An empty
///    value is unset, as helm's `BenchRoot` reads it (#395): taken literally it would make
///    the cwd the root, so helm's pane and `bench` in it would use different benches.
/// 2. else `<home>/.bench-<suite>` when a suite is set,
/// 3. else the shared `<home>/.bench`.
///
/// `home` is a parameter, not a `$HOME` read, so the rule is testable and the caller is
/// forced to say whose home it means.
pub fn resolve_root(bench_dir: Option<&str>, suite: Option<&SuiteName>, home: &Path) -> PathBuf {
    if let Some(dir) = bench_dir.filter(|d| !d.is_empty()) {
        return PathBuf::from(dir);
    }
    match suite {
        Some(s) => home.join(format!(".bench-{}", s.as_str())),
        None => home.join(".bench"),
    }
}

pub fn socket_path(root: &Path) -> PathBuf {
    root.join("benchd.sock")
}

/// Where a client reaches benchd: the root's unix socket, or a benchd on another machine named
/// by `BENCH_URL=tcp://<host>:<port>` (M5c, #459). benchd listens on both when it runs with
/// `BENCH_LISTEN=<host>:<port>`. `fixtures/bench-url.json` is the table helm's `BenchEndpoint`
/// is checked against too.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Endpoint {
    Unix(PathBuf),
    /// `host:port`, as `TcpStream::connect` takes it (an IPv6 host in brackets).
    Tcp(String),
}

/// The variable naming a benchd by address.
pub const BENCH_URL: &str = "BENCH_URL";

/// How long a client's TCP link may be silent before the kernel probes it, how often it probes,
/// and how many unanswered probes end it: a link that died while the Mac slept is noticed in
/// about 25 s instead of after hours, so an attached pane gets to reconnect.
const KEEPALIVE_IDLE_SECS: libc::c_int = 10;
const KEEPALIVE_EVERY_SECS: libc::c_int = 5;
const KEEPALIVE_PROBES: libc::c_int = 3;

/// Keepalive on, with [`KEEPALIVE_IDLE_SECS`] and the rest instead of the kernel's two hours.
fn keep_alive(tcp: &std::net::TcpStream) -> std::io::Result<()> {
    use std::os::fd::AsRawFd;
    #[cfg(target_vendor = "apple")]
    const IDLE: libc::c_int = libc::TCP_KEEPALIVE;
    #[cfg(not(target_vendor = "apple"))]
    const IDLE: libc::c_int = libc::TCP_KEEPIDLE;
    let options = [
        (libc::SOL_SOCKET, libc::SO_KEEPALIVE, 1),
        (libc::IPPROTO_TCP, IDLE, KEEPALIVE_IDLE_SECS),
        (libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, KEEPALIVE_EVERY_SECS),
        (libc::IPPROTO_TCP, libc::TCP_KEEPCNT, KEEPALIVE_PROBES),
    ];
    for (level, name, value) in options {
        // SAFETY: setsockopt reads one c_int from a live local, on a descriptor `tcp` owns.
        let set = unsafe {
            libc::setsockopt(
                tcp.as_raw_fd(),
                level,
                name,
                (&raw const value).cast(),
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            )
        };
        if set != 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(())
}

impl Endpoint {
    /// `BENCH_URL` when set: `tcp://<host>:<port>` and nothing else. Unset or empty is the root's
    /// socket, as an empty `BENCH_DIR` is unset (#395).
    pub fn resolve(url: Option<&str>, root: &Path) -> Result<Endpoint, String> {
        let Some(url) = url.filter(|u| !u.is_empty()) else {
            return Ok(Endpoint::Unix(socket_path(root)));
        };
        let refused = || format!("{BENCH_URL}={url} is not tcp://<host>:<port>");
        let address = url.strip_prefix("tcp://").ok_or_else(refused)?;
        let (host, port) = address.rsplit_once(':').ok_or_else(refused)?;
        // An IPv6 host is bracketed, so the last `:` is the port's; any other host has none.
        let (bare, colon_ok) = match host.strip_prefix('[').and_then(|h| h.strip_suffix(']')) {
            Some(v6) => (v6, true),
            None => (host, false),
        };
        let port_ok = port.parse::<u16>().is_ok_and(|p| p > 0);
        let host_ok = !bare.is_empty()
            && !bare.contains(['[', ']', '/'])
            && (colon_ok || !bare.contains(':'));
        if !host_ok || !port_ok {
            return Err(refused());
        }
        Ok(Endpoint::Tcp(address.to_string()))
    }

    /// Connect. A TCP link gets `TCP_NODELAY` (a keystroke is one small write) and keepalive,
    /// and comes back as a [`UnixStream`] over its fd: see [`tcp_stream`].
    pub fn connect(&self) -> std::io::Result<UnixStream> {
        match self {
            Endpoint::Unix(path) => UnixStream::connect(path),
            Endpoint::Tcp(address) => {
                let tcp = std::net::TcpStream::connect(address.as_str())?;
                keep_alive(&tcp)?;
                tcp_stream(tcp)
            }
        }
    }
}

impl std::fmt::Display for Endpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Endpoint::Unix(path) => write!(f, "{}", path.display()),
            Endpoint::Tcp(address) => write!(f, "tcp://{address}"),
        }
    }
}

/// A TCP connection as the [`UnixStream`] every bench path already speaks, with `TCP_NODELAY`
/// on. The protocol is bytes on a stream, and nothing on either side reads peer credentials or
/// socket addresses, which are the only calls that would answer differently for a TCP fd; read,
/// write, timeouts, `try_clone` and `shutdown` are the same syscalls. So benchd's handler and the
/// CLI stay one code path for both transports.
pub fn tcp_stream(tcp: std::net::TcpStream) -> std::io::Result<UnixStream> {
    tcp.set_nodelay(true)?;
    Ok(UnixStream::from(std::os::fd::OwnedFd::from(tcp)))
}

pub fn events_path(root: &Path) -> PathBuf {
    root.join("events.jsonl")
}

/// A `sockaddr_un` path is capped (~104 bytes on macOS), and exceeding it fails at bind
/// with an error that names none of this. Check it where the path is decided and say
/// what to do about it.
pub fn check_socket_path(path: &Path) -> Result<(), String> {
    let len = path.as_os_str().len();
    if len > 100 {
        return Err(format!(
            "socket path is {len} bytes; unix sockets cap near 104 — point BENCH_DIR at a shorter path: {}",
            path.display()
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suite_names_that_isolate_are_accepted() {
        for ok in ["x", "bench-dev", "a1", "m0-smoke"] {
            assert!(
                SuiteName::validate(ok).is_ok(),
                "{ok} should be a valid suite"
            );
        }
    }

    #[test]
    fn suite_names_that_cannot_isolate_are_refused_not_defaulted() {
        for bad in [
            "",
            "has/slash",
            "..",
            "a..b",
            "UPPER",
            "with space",
            "-leading",
            "x".repeat(33).as_str(),
        ] {
            assert!(
                SuiteName::validate(bad).is_err(),
                "{bad:?} should be refused"
            );
        }
    }

    #[test]
    fn request_ids_follow_the_filename_safe_pattern() {
        assert!(RequestId::validate("bench-123-9f").is_ok());
        assert!(RequestId::validate("a.b_c-d").is_ok());
        for bad in [
            "",
            "../../etc",
            "-lead",
            "id with space",
            "x".repeat(65).as_str(),
        ] {
            assert!(
                RequestId::validate(bad).is_err(),
                "{bad:?} should be refused"
            );
        }
    }

    #[test]
    fn bench_dir_wins_suite_decorates_shared_is_default() {
        let home = Path::new("/home/op");
        let suite = SuiteName::validate("dev").unwrap();
        assert_eq!(
            resolve_root(Some("/claimed/root"), Some(&suite), home),
            PathBuf::from("/claimed/root")
        );
        assert_eq!(
            resolve_root(None, Some(&suite), home),
            PathBuf::from("/home/op/.bench-dev")
        );
        assert_eq!(
            resolve_root(None, None, home),
            PathBuf::from("/home/op/.bench")
        );
    }

    /// `fixtures/bench-root.json` is the table helm's `BenchRoot` is checked against too
    /// (`BenchWireConformanceTests`), so the two copies of this rule cannot drift apart
    /// unnoticed. Each row goes through what both binaries do with the environment: the
    /// suite is judged first, then the root is resolved.
    #[test]
    fn the_bench_root_fixture_resolves_as_the_binaries_resolve_it() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/bench-root.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let table: Value = serde_json::from_str(&text).unwrap();
        let home = Path::new(table["home"].as_str().unwrap());
        for row in table["rows"].as_array().unwrap() {
            let var = |name: &str| row["env"][name].as_str();
            let resolved = match var("BENCH_SUITE").map(SuiteName::validate).transpose() {
                Err(_) => Err("BENCH_SUITE"),
                Ok(suite) => Ok(resolve_root(var("BENCH_DIR"), suite.as_ref(), home)),
            };
            let expected = match row["root"].as_str() {
                Some(root) => Ok(PathBuf::from(root)),
                None => Err(row["refused"].as_str().unwrap()),
            };
            assert_eq!(resolved, expected, "{}", row["env"]);
        }
    }

    /// `fixtures/bench-url.json` is the table helm's `BenchRoot.endpoint` is checked against
    /// too: which benchd a client reaches for each environment, resolved as `bench` resolves it
    /// (the suite judged first, then the root, then `BENCH_URL`).
    #[test]
    fn the_bench_url_fixture_resolves_as_the_binaries_resolve_it() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/bench-url.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let table: Value = serde_json::from_str(&text).unwrap();
        let home = Path::new(table["home"].as_str().unwrap());
        for row in table["rows"].as_array().unwrap() {
            let var = |name: &str| row["env"][name].as_str();
            let resolved = match var("BENCH_SUITE").map(SuiteName::validate).transpose() {
                Err(_) => Err("BENCH_SUITE"),
                Ok(suite) => {
                    let root = resolve_root(var("BENCH_DIR"), suite.as_ref(), home);
                    Endpoint::resolve(var(BENCH_URL), &root)
                        .map(|e| e.to_string())
                        .map_err(|_| BENCH_URL)
                }
            };
            let expected = match row["endpoint"].as_str() {
                Some(endpoint) => Ok(endpoint.to_string()),
                None => Err(row["refused"].as_str().unwrap()),
            };
            assert_eq!(resolved, expected, "{}", row["env"]);
        }
    }

    /// `fixtures/mail-verbs.json` holds the two mail verbs helm sends (#358) and the answer it
    /// reads; helm's `BenchWireConformanceTests` decodes the same file.
    #[test]
    fn the_mail_verbs_fixture_is_what_the_daemon_reads_and_answers() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/mail-verbs.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();
        let send: Request = serde_json::from_value(value["send"].clone()).unwrap();
        let who: Request = serde_json::from_value(value["who"].clone()).unwrap();
        assert_eq!(Verb::parse(&send.verb), Some(Verb::MailSend));
        assert_eq!(Verb::parse(&who.verb), Some(Verb::MailWho));
        let args: MailSendArgs = serde_json::from_value(send.args.clone()).unwrap();
        assert_eq!(serde_json::to_value(&args).unwrap(), send.args);
        let args: MailWhoArgs = serde_json::from_value(who.args.clone()).unwrap();
        assert_eq!(serde_json::to_value(&args).unwrap(), who.args);
        let reply: MailWho = serde_json::from_value(value["who_reply"].clone()).unwrap();
        assert_eq!(serde_json::to_value(&reply).unwrap(), value["who_reply"]);
    }

    /// `fixtures/screen-verbs.json` holds what Pocket sends to read and type into a session's
    /// screen (#625), a key and a message, and both answers. helm's `BenchWireConformanceTests`
    /// encodes the same requests and decodes the answers.
    #[test]
    fn the_screen_fixture_is_what_the_daemon_reads_and_answers() {
        let path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/screen-verbs.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();
        let get: Request = serde_json::from_value(value["get"].clone()).unwrap();
        assert_eq!(Verb::parse(&get.verb), Some(Verb::ScreenGet));
        let args: ScreenGetArgs = serde_json::from_value(get.args.clone()).unwrap();
        assert_eq!(serde_json::to_value(&args).unwrap(), get.args);
        for key in ["send", "message"] {
            let send: Request = serde_json::from_value(value[key].clone()).unwrap();
            assert_eq!(Verb::parse(&send.verb), Some(Verb::ScreenSend));
            assert_eq!(send.by, Some(Actor::Operator));
            let args: ScreenSendArgs = serde_json::from_value(send.args.clone()).unwrap();
            assert_eq!(serde_json::to_value(&args).unwrap(), send.args);
        }
        let key: ScreenSendArgs = serde_json::from_value(value["send"]["args"].clone()).unwrap();
        assert!(key.keys && !key.enter, "the key is sent as a key");
        let message: ScreenSendArgs =
            serde_json::from_value(value["message"]["args"].clone()).unwrap();
        assert!(
            !message.keys && message.enter,
            "a message is pasted, then Return"
        );
        let screen: ScreenAnswer = serde_json::from_value(value["get_reply"].clone()).unwrap();
        assert_eq!(serde_json::to_value(&screen).unwrap(), value["get_reply"]);
        let sent: ScreenSent = serde_json::from_value(value["send_reply"].clone()).unwrap();
        assert_eq!(serde_json::to_value(&sent).unwrap(), value["send_reply"]);
    }

    /// `fixtures/session-log.json` holds Pocket's read of a session's transcript (#625): the
    /// request parses into `SessionLogArgs` and the reply round-trips through `SessionLog`.
    /// helm's `BenchSessionLogWireTests` encodes the same request and decodes the reply.
    #[test]
    fn the_session_log_fixture_is_what_the_daemon_reads_and_answers() {
        let path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/session-log.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();
        let request: Request = serde_json::from_value(value["request"].clone()).unwrap();
        assert_eq!(Verb::parse(&request.verb), Some(Verb::SessionsLog));
        let args: SessionLogArgs = serde_json::from_value(request.args.clone()).unwrap();
        assert_eq!(serde_json::to_value(&args).unwrap(), request.args);
        let reply: SessionLog = serde_json::from_value(value["reply"].clone()).unwrap();
        assert_eq!(serde_json::to_value(&reply).unwrap(), value["reply"]);
        assert!(
            reply.entries.iter().any(|e| e.tool.is_some()),
            "a tool entry pins `tool`"
        );
    }

    /// `fixtures/spawn-verbs.json` holds the fork helm asks for from a canvas mark (#535) and the
    /// resume the sessions drawer asks for (#621): `SpawnArgs` reads each whole, and helm's
    /// `BenchWireConformanceTests` encodes the same requests and decodes the reply.
    #[test]
    fn the_spawn_fixture_is_what_the_daemon_reads() {
        let path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/spawn-verbs.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();
        let fork: Request = serde_json::from_value(value["fork"].clone()).unwrap();
        assert_eq!(Verb::parse(&fork.verb), Some(Verb::Spawn));
        assert_eq!(fork.by, Some(Actor::Helm));
        let args: SpawnArgs = serde_json::from_value(fork.args.clone()).unwrap();
        assert_eq!(serde_json::to_value(&args).unwrap(), fork.args);
        assert!(args.fork.is_some() && args.prompt.is_some());
        // The sessions drawer's resume of a finished row (#621), as the operator.
        let resume: Request = serde_json::from_value(value["resume"].clone()).unwrap();
        assert_eq!(resume.by, Some(Actor::Operator));
        let args: SpawnArgs = serde_json::from_value(resume.args.clone()).unwrap();
        assert_eq!(serde_json::to_value(&args).unwrap(), resume.args);
        assert!(args.resume.is_some() && args.prompt.is_none());
        // Pocket's start (#625): a new conversation with its first message as text, sent by
        // helm so benchd moves nobody's focus, and recorded as the operator's spawn.
        let start: Request = serde_json::from_value(value["start"].clone()).unwrap();
        assert_eq!(start.by, Some(Actor::Helm));
        let args: SpawnArgs = serde_json::from_value(start.args.clone()).unwrap();
        assert_eq!(serde_json::to_value(&args).unwrap(), start.args);
        assert!(args.prompt.is_some() && args.model.is_some() && args.effort.is_some());
        assert!(args.resume.is_none() && args.fork.is_none());
    }

    /// `fixtures/session-list.json` holds a `sessions` answer as helm reads it (M5b).
    #[test]
    fn the_session_list_fixture_is_what_the_daemon_answers() {
        let path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/session-list.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();
        let request: Request = serde_json::from_value(value["request"].clone()).unwrap();
        assert_eq!(Verb::parse(&request.verb), Some(Verb::Sessions));
        let reply: LiveSessions = serde_json::from_value(value["reply"].clone()).unwrap();
        assert_eq!(serde_json::to_value(&reply).unwrap(), value["reply"]);
        assert!(
            reply
                .sessions
                .iter()
                .any(|s| s.agent == "shell" && s.pane.is_some())
        );
        assert!(
            reply.sessions.iter().any(|s| s.report.is_some()),
            "the sample carries a report, so helm's decoder is pinned too"
        );
        // Attention (M1, #357) has a sample of its own, so the one above stays what helm's
        // presence reads.
        let attention: LiveSessions = serde_json::from_value(value["attention"].clone()).unwrap();
        assert_eq!(
            serde_json::to_value(&attention).unwrap(),
            value["attention"]
        );
        assert!(
            attention
                .sessions
                .iter()
                .any(|s| s.done.is_some() && s.operator_mail.is_some()),
            "a finished turn and mail to the operator, so helm's decoder is pinned too"
        );
        assert_eq!(
            reply.usage.iter().map(|u| u.harness).collect::<Vec<_>>(),
            [Harness::Claude, Harness::Codex],
            "the sample carries both harnesses' limits, one without a reset time"
        );
    }

    /// `fixtures/helm-ask.json` holds what a caller asks, what benchd asks helm, what helm answers
    /// and what the caller gets back (M3, M5c); helm's `BenchWireConformanceTests` decodes the ask
    /// and encodes both answers against the same file.
    #[test]
    fn the_helm_ask_fixture_is_what_the_daemon_asks_and_reads() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/helm-ask.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();
        let ask: Request = serde_json::from_value(value["ask"].clone()).unwrap();
        assert_eq!(Verb::parse(&ask.verb), Some(Verb::HelmAsk));
        let args: HelmAskArgs = serde_json::from_value(ask.args.clone()).unwrap();
        assert_eq!(args.out.as_deref(), Some("/tmp/bench-capture.png"));
        assert_eq!(serde_json::to_value(&args).unwrap(), ask.args);
        let asked: HelmAsked = serde_json::from_value(value["asked"].clone()).unwrap();
        assert_eq!(
            asked.request, args.ask,
            "helm is asked what the caller asked, less out"
        );
        assert_eq!(serde_json::to_value(&asked).unwrap(), value["asked"]);
        let answer: Request = serde_json::from_value(value["answer"].clone()).unwrap();
        assert_eq!(Verb::parse(&answer.verb), Some(Verb::HelmAnswer));
        assert_eq!(answer.by, Some(Actor::Helm));
        let refused: HelmAnswer = serde_json::from_value(answer.args.clone()).unwrap();
        assert_eq!(refused.status, Status::Error);
        assert_eq!(serde_json::to_value(&refused).unwrap(), answer.args);
        let captured: Request = serde_json::from_value(value["captured"].clone()).unwrap();
        let captured: HelmAnswer = serde_json::from_value(captured.args).unwrap();
        let mut data = captured.data.unwrap();
        let png = data[CAPTURE_PNG_KEY].as_str().and_then(unbase64).unwrap();
        assert!(
            png.starts_with(b"\x89PNG"),
            "the answer carries the PNG itself"
        );
        // What the caller gets is helm's report with the path benchd wrote in place of the bytes.
        let report = data.as_object_mut().unwrap();
        report.remove(CAPTURE_PNG_KEY);
        report.insert("path".into(), args.out.clone().unwrap().into());
        assert_eq!(Value::Object(report.clone()), value["reply"]);
        let status: Request = serde_json::from_value(value["status"].clone()).unwrap();
        assert_eq!(Verb::parse(&status.verb), Some(Verb::Status));
    }

    /// `fixtures/browser-connect.json`: the pane's request and benchd's two answers; helm's
    /// `BenchWireConformanceTests` encodes the request and decodes the answers.
    #[test]
    fn the_browser_connect_fixture_is_the_verb_and_its_answers() {
        let path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/browser-connect.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();
        let request: Request = serde_json::from_value(value["request"].clone()).unwrap();
        assert_eq!(Verb::parse(&request.verb), Some(Verb::BrowserConnect));
        assert_eq!(request.by, Some(Actor::Helm));
        let connected: Response = serde_json::from_value(value["connected"].clone()).unwrap();
        assert_eq!(connected.status, Status::Ok);
        let data: BrowserConnected = serde_json::from_value(connected.data.unwrap()).unwrap();
        assert_eq!(
            serde_json::to_value(&data).unwrap(),
            value["connected"]["data"]
        );
        let none: Response = serde_json::from_value(value["none"].clone()).unwrap();
        assert_eq!(none.status, Status::Refused);
        for line in ["to_browser", "from_browser"] {
            let message = value[line].as_str().unwrap();
            assert!(!message.contains('\n'), "a relayed message is one line");
            let _: Value = serde_json::from_str(message).unwrap();
        }
    }

    /// `fixtures/browser-upload.json`: the pane's upload and benchd's answer; helm's
    /// `BrowserUploadWireTests` encodes the request and decodes the answer.
    #[test]
    fn the_browser_upload_fixture_is_the_verb_and_its_answer() {
        let path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/browser-upload.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();
        let request: Request = serde_json::from_value(value["request"].clone()).unwrap();
        assert_eq!(Verb::parse(&request.verb), Some(Verb::BrowserUpload));
        assert_eq!(request.by, Some(Actor::Helm));
        let args: BrowserUploadArgs = serde_json::from_value(request.args.clone()).unwrap();
        assert_eq!(unbase64(&args.base64).unwrap(), b"upload-me\n");
        let uploaded: Response = serde_json::from_value(value["uploaded"].clone()).unwrap();
        assert_eq!(uploaded.status, Status::Ok);
        let data: BrowserUploaded = serde_json::from_value(uploaded.data.unwrap()).unwrap();
        assert_eq!(
            serde_json::to_value(&data).unwrap(),
            value["uploaded"]["data"]
        );
    }

    #[test]
    fn every_known_verb_parses_and_nothing_else_does() {
        for v in KNOWN_VERBS {
            assert!(Verb::parse(v).is_some(), "{v} is listed but does not parse");
        }
        assert_eq!(
            KNOWN_VERBS.len(),
            57,
            "a new verb joins KNOWN_VERBS and this count together"
        );
        assert!(Verb::parse("frobnicate").is_none());
        // Resize rides the attach stream (`attach::AttachFrame::Size`) since #359.
        assert!(Verb::parse("resize").is_none());
    }

    #[test]
    fn the_clients_patience_outlasts_every_daemon_wait_by_construction() {
        assert!(
            CLIENT_READ_TIMEOUT > BROWSER_READY_WAIT + DAEMON_IO_TIMEOUT,
            "the same invariant for a browser start"
        );
        assert!(
            CLIENT_READ_TIMEOUT > HELM_ASK_WAIT + DAEMON_IO_TIMEOUT,
            "and for an ask of helm"
        );
    }

    #[test]
    fn spawn_args_refuse_a_missing_required_key_naming_the_field() {
        let err = serde_json::from_value::<SpawnArgs>(serde_json::json!({"cwd": "/tmp"}))
            .unwrap_err()
            .to_string();
        assert!(err.contains("agent"), "the refusal names the field: {err}");
        let ok: SpawnArgs =
            serde_json::from_value(serde_json::json!({"agent": "claude", "cwd": "/tmp"})).unwrap();
        assert!(ok.model.is_none() && ok.rows.is_none());
    }

    #[test]
    fn status_maps_to_helm_exit_codes() {
        assert_eq!(Status::Ok.exit_code(), 0);
        assert_eq!(Status::Refused.exit_code(), 3);
        assert_eq!(Status::Error.exit_code(), 4);
        assert_eq!(EXIT_NO_DAEMON, 2);
    }

    #[test]
    fn overlong_socket_paths_are_named_before_bind() {
        let long = PathBuf::from(format!("/{}", "d".repeat(120)));
        assert!(check_socket_path(&long).is_err());
        assert!(check_socket_path(Path::new("/tmp/b/benchd.sock")).is_ok());
    }
}
