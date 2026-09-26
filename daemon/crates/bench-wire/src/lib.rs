//! Every wire type and every shared resolution rule, spelled once.
//!
//! This crate exists so that `benchd` and `bench` can never disagree about what travels
//! on the socket or where a suite's state lives. helm spent real incidents on the other
//! arrangement — three copies of the mailbox rule in three languages, held together by a
//! conformance harness (`hooks/mailbox-conformance.mjs`). Rust on both ends of this socket
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
use std::path::{Path, PathBuf};

mod layout;
pub use layout::{
    Actor, DOCUMENT_CHANGED, DOCUMENT_RECORD_FORMAT, DOCUMENT_RECORD_VERSION, Divider, DocumentAt,
    DocumentChange, DocumentRecord, Frame, LAYOUT_VERBS, LayoutReport, LayoutVerb, MoveTo,
    OpenInto, PaneOpen, RULES_LOADED, RULES_REJECTED, document_path, placement_rules_path,
};

pub mod hook;
pub use hook::{HookArgs, HookReply};

mod sessions;
pub use sessions::{
    Activity, DISMISSED_RECORD_FORMAT, DISMISSED_RECORD_VERSION, Dismissal, DismissedRecord,
    HOSTED_RECORD_FORMAT, HOSTED_RECORD_VERSION, Harness, Host, HostedRecord, HostedSession,
    HostedVia, MailAddress, OpenAction, SessionKey, SessionList, SessionRow, SessionState,
    SessionsArgs, Unreadable, dismissed_path, hosted_path, sessions_dir,
};

/// A request line larger than this is refused, not read. The cap is about the reader:
/// every accepted byte can end up in an event log an agent later pulls into context.
/// Same argument as helm's 64 KB canvas-state cap.
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
    "attach",
    "close",
    "resume",
    "mail/send",
    "mail/list",
    "mail/read",
    "hook",
    "browser/start",
    "browser/status",
    "browser/stop",
    "browser/setup",
    // The layout verbs (M4) — `LAYOUT_VERBS`, spelled again here so this one list stays the
    // whole surface; `every_layout_verb_is_known_and_routes_to_layout` keeps the two in step.
    "bench/get",
    "workspace/open",
    "workspace/close",
    "workspace/activate",
    "workspace/reset",
    "workspace/unshelve",
    "workspace/import",
    "pane/open",
    "pane/split",
    "pane/close",
    "pane/show",
    "pane/move",
    "pane/name",
    "pane/record",
    "focus/slot",
    "focus/step",
    "layout/resize",
    "drawer/toggle",
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
    Attach,
    Close,
    Resume,
    MailSend,
    MailList,
    MailRead,
    /// The sensor (#358): an agent's hook reports an event; the answer carries its mail.
    Hook,
    BrowserStart,
    BrowserStatus,
    BrowserStop,
    BrowserSetup,
    /// Every verb in `LAYOUT_VERBS`; `LayoutVerb` decodes which one and its arguments.
    Layout,
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
            "attach" => Some(Verb::Attach),
            "close" => Some(Verb::Close),
            "resume" => Some(Verb::Resume),
            "mail/send" => Some(Verb::MailSend),
            "mail/list" => Some(Verb::MailList),
            "mail/read" => Some(Verb::MailRead),
            "hook" => Some(Verb::Hook),
            "browser/start" => Some(Verb::BrowserStart),
            "browser/status" => Some(Verb::BrowserStatus),
            "browser/stop" => Some(Verb::BrowserStop),
            "browser/setup" => Some(Verb::BrowserSetup),
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
    std::time::Duration::from_secs(BROWSER_READY_WAIT.as_secs() + DAEMON_IO_TIMEOUT.as_secs() + 5);

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cols: Option<u16>,
}

/// The payload shared by `attach`, `close` and `resume`: a session id, plus the
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
/// workspace (helm's pane, agents' shells), so it carries `format`/`version` and a
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

pub fn browser_dir(root: &Path) -> PathBuf {
    root.join("browser")
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
///    claims into instead of the operator's estate (helm's `HELM_MAIL_DIR` rule). An empty
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

    #[test]
    fn every_known_verb_parses_and_nothing_else_does() {
        for v in KNOWN_VERBS {
            assert!(Verb::parse(v).is_some(), "{v} is listed but does not parse");
        }
        assert_eq!(
            KNOWN_VERBS.len(),
            36,
            "a new verb joins KNOWN_VERBS and this count together"
        );
        assert!(Verb::parse("frobnicate").is_none());
    }

    #[test]
    fn the_clients_patience_outlasts_every_daemon_wait_by_construction() {
        assert!(
            CLIENT_READ_TIMEOUT > BROWSER_READY_WAIT + DAEMON_IO_TIMEOUT,
            "the same invariant for a browser start"
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
