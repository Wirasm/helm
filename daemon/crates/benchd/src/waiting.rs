//! What waits on the operator (M1, #357): one answer per session to "is the agent in it waiting
//! on you, for what, and since when", from the two things that can say so.
//!
//! - **Its own report**: the hook (`bench hook`) that said `PermissionRequest`, a question, a pi
//!   `ui_prompt_start`.
//! - **Its screen**: each time a session's output settles (`Notice::Settled`), benchd reads the
//!   screen through the session's VT engine and matches the prompt rules (`prompts`). This is
//!   what catches a prompt no hook reports: #283's bypass-immune guardrail, a trust prompt that
//!   comes before the session has reported anything, an agent whose hooks are not wired.
//!
//! **The report outranks the screen.** A hook that says it is waiting keeps its own words; a hook
//! that spoke after the screen was read says the prompt is gone. A screen match wins only over a
//! report older than it, which is #283 exactly: `busy` at the tool call, then a prompt, then
//! nothing, for six and a half hours.
//!
//! A shell at its prompt is never read: what is on its screen is history (a trust prompt left
//! behind by a claude that exited reads exactly like a live one).

use crate::{Core, prompts, sessions::now_ms};
use bench_session::AgentKind;
use bench_wire::{Activity, Waiting, WaitingSource};
use serde_json::json;
use std::sync::{Arc, Mutex};

/// The prompt a session's screen showed when its output last settled.
pub struct Seen {
    pub rule: &'static prompts::Rule,
    /// When its screen first showed this prompt.
    pub since_ms: u64,
}

/// A session's output settled: read its screen, off the core lock (a read inside a
/// synchronized update waits for it to end), and keep what it shows. This runs on the one
/// notice thread, so such a wait (at most a second) holds back other sessions' notices too;
/// they are logged late, never lost.
pub fn settled(core: &Arc<Mutex<Core>>, id: &str) {
    let session = {
        let c = core.lock().unwrap();
        match c.sessions.get(id) {
            Some(s) if s.is_live() => Arc::clone(s),
            _ => return,
        }
    };
    let runs_a_program = session.agent != AgentKind::Shell || session.foreground_job().is_some();
    let rule = runs_a_program
        .then(|| session.screen(false).ok())
        .flatten()
        .and_then(|screen| prompts::classify(&screen.lines));
    see(&mut core.lock().unwrap(), id, rule);
}

/// Keep what a session's screen shows now, logging `session/waiting` when that changed.
pub fn see(c: &mut Core, id: &str, now: Option<&'static prompts::Rule>) {
    let before = c.screen_waits.get(id).map(|s| s.rule);
    if before.map(std::ptr::from_ref) == now.map(std::ptr::from_ref) {
        return;
    }
    match now {
        Some(rule) => {
            let seen = Seen {
                rule,
                since_ms: now_ms(),
            };
            c.screen_waits.insert(id.to_string(), seen);
        }
        None => {
            c.screen_waits.remove(id);
        }
    }
    let pane = c.bench.document.pane_showing_session(id);
    let _ = c.append(
        "session/waiting",
        json!({
            "session": id,
            "pane": pane,
            "waiting_for": now.map(|r| r.waiting_for),
            "rule": now.map(|r| r.harness),
        }),
    );
}

/// Whether the agent in a live session is waiting on the operator.
pub fn of_session(c: &Core, id: &str) -> Option<Waiting> {
    if !c.sessions.get(id).is_some_and(|s| s.is_live()) {
        return None;
    }
    let seen = c
        .screen_waits
        .get(id)
        .map(|s| (s.rule.waiting_for, s.since_ms));
    decide(reporting_agent(c, id), seen)
}

/// The precedence, on its own: `reported` is the agent's last report and when it began,
/// `seen` the prompt its screen showed and since when.
fn decide(reported: Option<(&Activity, u64)>, seen: Option<(&str, u64)>) -> Option<Waiting> {
    if let Some((Activity::Waiting { waiting_for }, since_ms)) = reported {
        return Some(Waiting {
            waiting_for: waiting_for.clone().unwrap_or_else(|| "input".into()),
            since_ms,
            source: WaitingSource::Hook,
        });
    }
    let (waiting_for, since_ms) = seen?;
    if reported.is_some_and(|(_, reported_ms)| reported_ms > since_ms) {
        return None;
    }
    Some(Waiting {
        waiting_for: waiting_for.into(),
        since_ms,
        source: WaitingSource::Screen,
    })
}

/// What the live agent running in a session last reported, and since when: the agent in the
/// pane showing it (an agent the operator started in a shell), or the one benchd spawned there,
/// which shares the session's handle.
fn reporting_agent<'a>(c: &'a Core, id: &str) -> Option<(&'a Activity, u64)> {
    let handle = c.sessions.get(id).map(|s| s.handle.as_str());
    let pane = c.bench.document.pane_showing_session(id);
    c.agents
        .values()
        .flatten()
        .filter(|a| {
            (a.pane.is_some() && a.pane == pane)
                || (a.pane.is_none() && Some(a.handle.as_str()) == handle)
        })
        .filter(|a| bench_sessions::process::alive(a.pid, None))
        .find_map(|a| Some((a.activity.as_ref()?, a.activity_since_ms)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn waiting(what: &str) -> Activity {
        Activity::Waiting {
            waiting_for: Some(what.into()),
        }
    }

    #[test]
    fn an_agent_that_says_it_is_waiting_keeps_its_own_words() {
        let got = decide(
            Some((&waiting("question"), 10)),
            Some(("permission prompt", 20)),
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
        let got = decide(Some((&Activity::Busy, 10)), Some(("permission prompt", 20))).unwrap();
        assert_eq!((got.since_ms, got.source), (20, WaitingSource::Screen));
    }

    /// The operator answered: the agent reported again before the screen was read again.
    #[test]
    fn a_report_newer_than_the_screen_says_the_prompt_is_gone() {
        assert!(decide(Some((&Activity::Busy, 30)), Some(("permission prompt", 20))).is_none());
    }

    #[test]
    fn a_screen_prompt_stands_alone_and_nothing_is_nothing() {
        assert!(decide(None, Some(("trust prompt", 20))).is_some());
        assert!(decide(Some((&Activity::Idle, 10)), None).is_none());
    }
}
