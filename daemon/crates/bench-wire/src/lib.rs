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

/// One line of the append-only record. **Bench-visible means logged**: anything a
/// projection, a snapshot, or a later reader is allowed to know happened must be
/// reconstructable from this stream — the file is the record, the socket is only
/// transport (bench-roadmap, invariants 7 and the dsh lesson in direction.md).
///
/// `kind` is namespaced `domain/what` (`daemon/started`). A reader that meets a kind it
/// does not know must refuse or skip *visibly*, never misread it — which is why the
/// envelope stays this small and flat.
#[derive(Debug, Clone, Serialize, Deserialize)]
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
///    claims into instead of the operator's estate (helm's `HELM_MAIL_DIR` rule).
/// 2. else `<home>/.bench-<suite>` when a suite is set,
/// 3. else the shared `<home>/.bench`.
///
/// `home` is a parameter, not a `$HOME` read, so the rule is testable and the caller is
/// forced to say whose home it means.
pub fn resolve_root(bench_dir: Option<&str>, suite: Option<&SuiteName>, home: &Path) -> PathBuf {
    if let Some(dir) = bench_dir {
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
