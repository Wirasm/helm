//! What waits on the operator (M1, #357): one answer per session to "is the agent in it waiting
//! on you, for what, and since when", from the things that can say so.
//!
//! - **Its own report**: the hook (`bench hook`) that said `PermissionRequest`, a question, a pi
//!   `ui_prompt_start`; and, read when its output settles, Claude Code's registry row for the
//!   process in the foreground, which says `waiting` in its own words whether or not its hooks are
//!   wired.
//! - **Its screen**: each time a session's output settles (`Notice::Settled`), benchd reads the
//!   screen through the session's VT engine and matches the prompt rules (`prompts`). This is
//!   what catches a prompt nothing reports: #283's bypass-immune guardrail under a registry row
//!   left `busy`, a trust prompt that comes before the session has reported anything, a codex or
//!   pi whose hooks are not wired.
//!
//! **A report outranks the screen.** A hook that says it is waiting keeps its own words; a hook
//! that spoke after the settle says the wait is gone. A registry `waiting` is taken before a
//! screen match. A screen match wins only over a report older than it, which is #283 exactly:
//! `busy` at the tool call, then a prompt, then nothing, for six and a half hours.
//!
//! A shell at its prompt is never read: what is on its screen is history (a trust prompt left
//! behind by a claude that exited reads exactly like a live one).

use crate::hook::Agent;
use crate::{Core, prompts, sessions::now_ms};
use bench_doc::PaneId;
use bench_session::{AgentKind, Session};
use bench_wire::{Activity, AgentReport, SessionKey, Waiting, WaitingSource};
use serde_json::json;
use std::path::Path;
use std::sync::{Arc, Mutex};

/// What a session showed when its output last settled: a wait from Claude's registry row for
/// its foreground process, or from a prompt rule on its screen. Kept only while it waits.
pub type Seen = Waiting;

/// A session's output settled: read what it shows, off the core lock (a screen read inside a
/// synchronized update waits for it to end), and keep it. This runs on the one notice thread,
/// so such a wait (at most a second) holds back other sessions' notices too; they are logged
/// late, never lost.
pub fn settled(core: &Arc<Mutex<Core>>, id: &str) {
    let (session, home) = {
        let c = core.lock().unwrap();
        match c.sessions.get(id) {
            Some(s) if s.is_live() => (Arc::clone(s), c.home.clone()),
            _ => return,
        }
    };
    let now = shows(&session, &home);
    see(&mut core.lock().unwrap(), id, now);
}

/// What a live session shows now. Claude's registry row is the agent's own report, so it comes
/// before the screen: a Claude whose hooks are not wired still says there that it waits, and in
/// its own words, for a prompt no rule describes.
fn shows(session: &Session, home: &Path) -> Option<(Waiting, &'static str)> {
    let runs_a_program = session.agent != AgentKind::Shell || session.foreground_job().is_some();
    if !runs_a_program {
        return None;
    }
    let registry = session
        .foreground_pid()
        .and_then(|pid| bench_sessions::claude::row_of(home, u32::try_from(pid).ok()?));
    if let Some(row) = registry
        && let Activity::Waiting {
            waiting_for: Some(waiting_for),
        } = row.activity
    {
        let since_ms = row.status_updated_ms.unwrap_or_else(now_ms);
        let source = WaitingSource::Registry;
        return Some((
            Waiting {
                waiting_for,
                since_ms,
                source,
            },
            "claude",
        ));
    }
    let rule = prompts::classify(&session.screen(false).ok()?.lines)?;
    let waiting = Waiting {
        waiting_for: rule.waiting_for.into(),
        since_ms: now_ms(),
        source: WaitingSource::Screen,
    };
    Some((waiting, rule.harness))
}

/// Keep what a session shows now, logging `session/waiting` when that changed. The same wait
/// seen again keeps the time it began.
pub fn see(c: &mut Core, id: &str, now: Option<(Waiting, &'static str)>) {
    let same = |a: &Waiting, b: &Waiting| a.waiting_for == b.waiting_for && a.source == b.source;
    let before = c.screen_waits.get(id);
    match (&now, before) {
        (Some((w, _)), Some(b)) if same(w, b) => return,
        (None, None) => return,
        _ => {}
    }
    let pane = c.bench.document.pane_showing_session(id);
    let event = json!({
        "session": id,
        "pane": pane,
        "waiting_for": now.as_ref().map(|(w, _)| &w.waiting_for),
        "source": now.as_ref().map(|(w, _)| w.source),
        "rule": now.as_ref().map(|(_, harness)| harness),
    });
    match now {
        Some((waiting, _)) => c.screen_waits.insert(id.to_string(), waiting),
        None => c.screen_waits.remove(id),
    };
    let _ = c.append("session/waiting", event);
}

/// Whether the agent in a live session is waiting on the operator.
pub fn of_session(c: &Core, id: &str) -> Option<Waiting> {
    if !c.sessions.get(id).is_some_and(|s| s.is_live()) {
        return None;
    }
    decide(reporting_agent(c, id), c.screen_waits.get(id))
}

/// The precedence, on its own: `reported` is the agent's last hook report and when it began,
/// `seen` what the session showed when it last settled.
fn decide(reported: Option<(&Activity, u64)>, seen: Option<&Seen>) -> Option<Waiting> {
    if let Some((Activity::Waiting { waiting_for }, since_ms)) = reported {
        return Some(Waiting {
            waiting_for: waiting_for.clone().unwrap_or_else(|| "input".into()),
            since_ms,
            source: WaitingSource::Hook,
        });
    }
    let seen = seen?;
    if reported.is_some_and(|(_, reported_ms)| reported_ms > seen.since_ms) {
        return None;
    }
    Some(seen.clone())
}

/// Where `focus/waiting` goes: every pane showing a session whose agent waits on the operator,
/// the longest wait first, and of those the one after the focused pane, so pressing again walks
/// them and comes round. `None` when nothing waits.
pub fn next_pane(c: &Core) -> Option<PaneId> {
    let doc = &c.bench.document;
    let waiting = c
        .sessions
        .keys()
        .filter_map(|id| Some((of_session(c, id)?.since_ms, doc.pane_showing_session(id)?)))
        .collect();
    next_after(waiting, doc.focused_pane())
}

/// The ordering on its own: the longest wait first (ties by pane id, so it is stable), and the
/// one after `focused` when it is one of them.
fn next_after(mut waiting: Vec<(u64, PaneId)>, focused: Option<PaneId>) -> Option<PaneId> {
    waiting.sort_by_key(|(since, pane)| (*since, pane.to_string()));
    let after = focused
        .and_then(|f| waiting.iter().position(|(_, p)| *p == f))
        .map_or(0, |at| at + 1);
    waiting.get(after % waiting.len().max(1)).map(|(_, p)| *p)
}

/// What the agent in a live session says it is doing (`SessionEntry.report`): Claude Code's
/// registry row for the process in its foreground, read from benchd's own HOME, else `hooked`,
/// its last hook report ([`hook_report`]). This is what helm's presence and the snapshot's `agent`
/// show, so neither reads a file on benchd's machine (M5c, #459). Called outside the core lock:
/// the foreground pid asks the session's pty.
pub fn report(session: &Session, home: &Path, hooked: Option<AgentReport>) -> Option<AgentReport> {
    let registry = session
        .foreground_pid()
        .and_then(|pid| bench_sessions::claude::row_of(home, u32::try_from(pid).ok()?))
        .map(|row| AgentReport {
            activity: row.activity,
            since_ms: row.status_updated_ms,
        });
    let said = |r: &AgentReport| r.activity != Activity::Unknown;
    registry.filter(said).or(hooked.filter(said))
}

/// The live session's hook report, as [`report`] takes it.
pub fn hook_report(c: &Core, id: &str) -> Option<AgentReport> {
    if !c.sessions.get(id).is_some_and(|s| s.is_live()) {
        return None;
    }
    reporting_agent(c, id).map(|(activity, since_ms)| AgentReport {
        activity: activity.clone(),
        since_ms: Some(since_ms),
    })
}

/// What the live agent running in a session last reported, and since when.
fn reporting_agent<'a>(c: &'a Core, id: &str) -> Option<(&'a Activity, u64)> {
    agents_in(c, id).find_map(|(_, a)| Some((a.activity.as_ref()?, a.activity_since_ms)))
}

/// The conversation of the live agent with a mailbox running in a session, as its hook reported
/// it, and the agent: whose attention record the session's is (`attention`).
pub fn reporting<'a>(c: &'a Core, id: &str) -> Option<(&'a SessionKey, &'a Agent)> {
    agents_in(c, id).next()
}

/// The live agents with a mailbox in a session: the agent in the pane showing it (one the
/// operator started in a shell), or the one benchd spawned there, which shares its handle.
fn agents_in<'a>(c: &'a Core, id: &str) -> impl Iterator<Item = (&'a SessionKey, &'a Agent)> {
    let handle = c.sessions.get(id).map(|s| s.handle.as_str());
    let pane = c.bench.document.pane_showing_session(id);
    c.agents
        .iter()
        .filter_map(|(key, a)| Some((key, a.as_ref()?)))
        .filter(move |(_, a)| {
            (a.pane.is_some() && a.pane == pane)
                || (a.pane.is_none() && Some(a.handle.as_str()) == handle)
        })
        .filter(|(_, a)| bench_sessions::process::alive(a.pid, None))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn waiting(what: &str) -> Activity {
        Activity::Waiting {
            waiting_for: Some(what.into()),
        }
    }

    fn screen(what: &str, since_ms: u64) -> Seen {
        Waiting {
            waiting_for: what.into(),
            since_ms,
            source: WaitingSource::Screen,
        }
    }

    #[test]
    fn an_agent_that_says_it_is_waiting_keeps_its_own_words() {
        let got = decide(
            Some((&waiting("question"), 10)),
            Some(&screen("permission prompt", 20)),
        );
        let got = got.unwrap();
        assert_eq!(
            (got.waiting_for.as_str(), got.since_ms, got.source),
            ("question", 10, WaitingSource::Hook)
        );
    }

    /// #283: `busy` at the tool call, then a prompt no hook reported.
    #[test]
    fn a_screen_prompt_outranks_a_report_older_than_it() {
        let got = decide(
            Some((&Activity::Busy, 10)),
            Some(&screen("permission prompt", 20)),
        )
        .unwrap();
        assert_eq!((got.since_ms, got.source), (20, WaitingSource::Screen));
    }

    /// The operator answered: the agent reported again before the screen was read again.
    #[test]
    fn a_report_newer_than_the_screen_says_the_prompt_is_gone() {
        assert!(
            decide(
                Some((&Activity::Busy, 30)),
                Some(&screen("permission prompt", 20))
            )
            .is_none()
        );
    }

    #[test]
    fn the_jump_starts_at_the_longest_wait_and_walks_round() {
        let [a, b, c] = [PaneId::mint(), PaneId::mint(), PaneId::mint()];
        let waiting = vec![(30, c), (10, a), (20, b)];
        let other = PaneId::mint();
        assert_eq!(next_after(waiting.clone(), None), Some(a));
        assert_eq!(next_after(waiting.clone(), Some(other)), Some(a));
        assert_eq!(next_after(waiting.clone(), Some(a)), Some(b));
        assert_eq!(next_after(waiting.clone(), Some(b)), Some(c));
        assert_eq!(next_after(waiting, Some(c)), Some(a));
        assert_eq!(next_after(vec![(10, a)], Some(a)), Some(a));
        assert_eq!(next_after(Vec::new(), Some(a)), None);
    }

    #[test]
    fn a_screen_prompt_stands_alone_and_nothing_is_nothing() {
        assert!(decide(None, Some(&screen("trust prompt", 20))).is_some());
        assert!(decide(Some((&Activity::Idle, 10)), None).is_none());
    }
}
