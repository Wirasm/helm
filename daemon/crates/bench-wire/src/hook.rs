//! The sensor (#358): what `bench hook <harness>` sends, what benchd answers, and the rules
//! both ends read — which events mean what, who gets a mailbox, and what that mailbox is
//! called. One spelling, where helm had three (`hooks/helm-mail.mjs`,
//! `pi/extensions/helm-mail`, `MailboxDirectory.swift`) and a conformance harness to keep them
//! in step.
//!
//! One command per harness is wired once into the harness's own hook config. On every event
//! it reports the agent's state, and benchd's reply carries the mail pointer when there is
//! unread mail. The harness puts that reply in front of the model as hook context — at the
//! next tool call for a busy agent. So sensing and delivery are one call.

use crate::{Activity, Harness, validate_handle};
use serde::{Deserialize, Serialize};

/// `hook`'s payload: the typed fields `bench hook` takes out of the harness's own hook
/// payload, plus what only the hook process can see (its parent pid, its environment).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HookArgs {
    pub harness: Harness,
    /// The harness's own event name, verbatim (`PostToolUse`, `agent_settled`).
    pub event: String,
    /// The harness's session id: Claude's `session_id`, codex's thread id, pi's session id.
    pub session: String,
    pub cwd: String,
    /// The agent's pid: the hook process's parent.
    pub pid: u32,
    /// The tool a tool event is about, when the payload names one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    /// `HELM_PANE` from the hook's environment: helm declared this process tree its pane's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    /// `BENCH_SESSION` from the hook's environment: benchd spawned this process tree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bench_session: Option<String>,
    /// `CLAUDE_CODE_MESSAGING_SOCKET` from the hook's environment: the Claude session's own
    /// inbox, which Claude exports to its hooks. Where benchd starts a turn when it is idle.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub messaging_socket: Option<String>,
}

/// `hook`'s answer. Both fields are absent for a session that has no mailbox.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HookReply {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<String>,
    /// What the harness puts in front of the model, when there is anything: the standing
    /// rule the first time, then one pointer line per message. Never a message body.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<String>,
    /// pi only: the inbox directory its extension watches, so it can ask for its mail
    /// (`wake`) the moment some arrives while it is idle.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inbox: Option<String>,
    /// pi only: the standing rule, which its extension adds to the system prompt of every run.
    /// pi's `context` changes one request and not the history, so a rule told once there would
    /// be gone by the next run (measured: an idle wake's turn never read its mail).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule: Option<String>,
}

/// What one event says about the agent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Transition {
    /// The agent is now doing this.
    To(Activity),
    /// The session ended cleanly. (A killed one says nothing; its pid is the signal.)
    Ended,
    /// The event carries no state (a Claude `Notification`, pi's `wake`).
    Unchanged,
}

pub const PERMISSION: &str = "permission prompt";
pub const QUESTION: &str = "question";

/// The tool Claude and codex ask the operator a question through. A `PreToolUse` for it is
/// the agent waiting on a person, not working.
const ASK_TOOL: &str = "AskUserQuestion";

/// What an event means, per harness. `None` is an event this build does not know: benchd
/// logs it once and changes nothing, so a harness that adds events never breaks a hook.
pub fn transition(harness: Harness, event: &str, tool: Option<&str>) -> Option<Transition> {
    use Transition::*;
    let waiting = |what: &str| {
        To(Activity::Waiting {
            waiting_for: Some(what.into()),
        })
    };
    Some(match harness {
        // The same hook names on both (Claude's hooks docs; codex's hooks docs).
        Harness::Claude | Harness::Codex => match event {
            "SessionStart" | "Stop" | "StopFailure" | "Interrupt" => To(Activity::Idle),
            "PreToolUse" if tool == Some(ASK_TOOL) => waiting(QUESTION),
            "UserPromptSubmit" | "PreToolUse" | "PostToolUse" | "PostToolUseFailure" => {
                To(Activity::Busy)
            }
            "PermissionRequest" => waiting(PERMISSION),
            "SessionEnd" => Ended,
            "Notification" | "PreCompact" | "PostCompact" | "SubagentStart" | "SubagentStop" => {
                Unchanged
            }
            _ => return None,
        },
        // pi's extension events (`docs/extensions.md`), sent by the pi sensor.
        Harness::Pi => match event {
            "session_start" | "agent_settled" => To(Activity::Idle),
            "agent_start"
            | "context"
            | "tool_execution_start"
            | "tool_execution_end"
            | "ui_prompt_end" => To(Activity::Busy),
            "ui_prompt_start" => waiting(QUESTION),
            "session_shutdown" => Ended,
            // The extension saw its inbox change while idle and asks for the mail.
            "wake" => Unchanged,
            _ => return None,
        },
    })
}

/// Whether the harness puts this event's reply in front of the model, so mail may be handed
/// out on it. Claude and codex take `hookSpecificOutput.additionalContext` on these four
/// (measured on Claude 2.1.283 for the tool events and SessionStart; codex's docs for all
/// four). A question is not one: the agent is waiting on a person, and the mail keeps until
/// the answer's tool call.
pub fn carries_context(harness: Harness, event: &str, tool: Option<&str>) -> bool {
    match harness {
        Harness::Claude | Harness::Codex => match event {
            "PreToolUse" => tool != Some(ASK_TOOL),
            "SessionStart" | "UserPromptSubmit" | "PostToolUse" => true,
            _ => false,
        },
        // `context` fires before every model call; `wake` is the extension asking.
        Harness::Pi => matches!(event, "context" | "wake"),
    }
}

/// Every Claude Code event `bench hook claude` is wired to. The same list goes into the
/// settings benchd gives the Claude sessions it spawns and into the operator's one-time wiring.
pub const CLAUDE_EVENTS: [&str; 8] = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionRequest",
    "Stop",
    "SessionEnd",
];

/// The Claude Code settings that wire `bench hook claude` (exec form, so no shell reads the
/// path) into every event in [`CLAUDE_EVENTS`], and accept messages benchd posts to the
/// session's inbox socket. Without `crossSessionInbound: "accept"` a session that bypasses
/// permission prompts holds benchd's message behind an approval dialog in its pane (measured
/// on 2.1.283; the session's own token does not change that).
pub fn claude_settings(bench: &str) -> serde_json::Value {
    let handler = serde_json::json!([{ "hooks": [{
        "type": "command", "command": bench, "args": ["hook", "claude"], "timeout": 5,
    }]}]);
    let hooks: serde_json::Map<String, serde_json::Value> = CLAUDE_EVENTS
        .iter()
        .map(|event| ((*event).to_string(), handler.clone()))
        .collect();
    serde_json::json!({ "hooks": hooks, "crossSessionInbound": "accept" })
}

/// Who gets a mailbox (#427, the rule moved here from both writers): a session a host
/// declared — helm's `HELM_PANE` or benchd's `BENCH_SESSION` — **and** that runs on a
/// terminal.
///
/// The declaration alone is not enough. Both variables are inherited by everything the
/// agent spawns, and Archon passes its whole environment to the SDK sessions it starts, so
/// a declaration alone claimed a mailbox for every one of them (12,497 mailboxes, #417).
/// What does not survive is the terminal: the pane's agent is on the pane's tty, while a
/// session started from its tool call has none (measured on #427). The terminal alone is
/// not enough either: every Claude session the operator opens in any terminal has one.
pub fn claims_a_mailbox(declared: bool, has_terminal: bool) -> bool {
    declared && has_terminal
}

/// The longest cwd part of a derived handle: room for `-` and a 12-character tail inside
/// `validate_handle`'s 32.
const WHERE_MAX: usize = 19;
const TAILS: [usize; 4] = [4, 6, 8, 12];

/// A session's address: `<cwd basename>-<tail of the session id>`, widened while another
/// session holds it, as helm's `deriveHandle` does (#126, #262). The tail, because a UUID's
/// head is a clock. Always carries a `-`, so it is never `operator`.
///
/// Two differences from helm's copy, both because benchd owns every address: the widest rung
/// is 12 characters rather than the whole id, because a handle is at most 32; and when every
/// width is held the fallback is a number (`helm-a1b2-2`) rather than a pid, because benchd
/// knows every handle it has given out and can pick a free one. So a claim is never refused:
/// a session that cannot be addressed would be #358's defect again.
pub fn derive_handle(cwd: &str, session: &str, held: impl Fn(&str) -> bool) -> String {
    let base = cwd.rsplit('/').find(|p| !p.is_empty()).unwrap_or("");
    let mut place = slug(base);
    place.truncate(WHERE_MAX);
    let place = place.trim_end_matches('-');
    let place = if place.is_empty() { "agent" } else { place };
    let id = slug(session);
    let candidates: Vec<String> = TAILS
        .iter()
        .map(|&width| id[id.len().saturating_sub(width)..].trim_matches('-'))
        .filter(|tail| !tail.is_empty())
        .map(|tail| format!("{place}-{tail}"))
        .collect();
    let free = |handle: &String| validate_handle(handle).is_ok() && !held(handle);
    if let Some(handle) = candidates.iter().find(|h| free(h)) {
        return handle.clone();
    }
    let stem = candidates
        .first()
        .cloned()
        .unwrap_or_else(|| format!("{place}-s"));
    (2u32..)
        .map(|n| format!("{stem}-{n}"))
        .find(free)
        .expect("a finite set of held handles leaves a number free")
}

/// Lowercase ASCII letters and digits, every other run folded to one `-`. A handle is a
/// directory name, and the macOS default filesystem folds case.
fn slug(text: &str) -> String {
    let mut out = String::new();
    for c in text.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push('-');
        }
    }
    out.trim_end_matches('-').to_string()
}

/// The one line a message becomes in front of its recipient. The path, never the body: the
/// agent reads the file with its own tools, so nothing it acts on arrives as another
/// agent's words (#358).
pub fn notice(from: &str, path: &str) -> String {
    format!("You have mail from {from}: {path}")
}

/// Told once per session, before any notice: without it a model notices a bare pointer and
/// carries on (measured: haiku ignored one 4 of 4 times; read it with this rule in place).
pub fn standing_rule(handle: &str) -> String {
    format!(
        "You are `{handle}` on the bench. Bench mail reaches you as a line \
         `You have mail from <sender>: <path>`. When you see one, read that file with your \
         tools before your next step. Send with `bench mail send --to <handle> --body <text>`; \
         `bench sessions --all` lists who you can mail."
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn none_held(_: &str) -> bool {
        false
    }

    #[test]
    fn a_handle_is_the_cwd_and_the_tail_of_the_session() {
        let id = "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2";
        assert_eq!(
            derive_handle("/Users/op/Projects/helm", id, none_held),
            "helm-a1b2"
        );
        // Folded like a directory name; a trailing slash is not an empty basename.
        assert_eq!(
            derive_handle("/x/My Repo.v2/", id, none_held),
            "my-repo-v2-a1b2"
        );
        assert_eq!(derive_handle("/", id, none_held), "agent-a1b2");
    }

    #[test]
    fn a_held_handle_widens_and_every_width_held_takes_a_number() {
        let id = "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2";
        let held = |h: &str| h == "helm-a1b2" || h == "helm-0fa1b2";
        assert_eq!(derive_handle("/p/helm", id, held), "helm-9e0fa1b2");
        let widths = |h: &str| !h.ends_with("-3") && h.starts_with("helm-");
        assert_eq!(derive_handle("/p/helm", id, widths), "helm-a1b2-3");
    }

    #[test]
    fn every_derived_handle_is_a_valid_handle_and_never_the_operators() {
        let long = "a".repeat(80);
        for (cwd, id) in [
            (
                format!("/p/{long}"),
                "0b9e3f2a-1c4d-4e5f-8a6b-7c8d9e0fa1b2".to_string(),
            ),
            ("/p/operator".into(), "x-y".into()),
            ("/p/---".into(), "--ab--".into()),
            ("/p/Ünïcode".into(), "session".into()),
        ] {
            let handle = derive_handle(&cwd, &id, none_held);
            assert!(validate_handle(&handle).is_ok(), "{handle}");
            assert_ne!(handle, crate::OPERATOR_HANDLE);
            assert!(handle.contains('-'), "{handle}");
        }
    }

    #[test]
    fn only_a_declared_session_on_a_terminal_claims() {
        assert!(claims_a_mailbox(true, true));
        // An inherited HELM_PANE in a tool call's process: declared, no terminal (#427).
        assert!(!claims_a_mailbox(true, false));
        // Any Claude session the operator opened in his own terminal.
        assert!(!claims_a_mailbox(false, true));
        assert!(!claims_a_mailbox(false, false));
    }

    #[test]
    fn an_event_means_one_thing_and_only_context_events_carry_mail() {
        for h in [Harness::Claude, Harness::Codex] {
            assert_eq!(
                transition(h, "PostToolUse", Some("Bash")),
                Some(Transition::To(Activity::Busy))
            );
            assert_eq!(
                transition(h, "PreToolUse", Some(ASK_TOOL)),
                Some(Transition::To(Activity::Waiting {
                    waiting_for: Some(QUESTION.into())
                }))
            );
            assert_eq!(transition(h, "SessionEnd", None), Some(Transition::Ended));
            assert_eq!(transition(h, "SomethingNew", None), None);
            assert!(carries_context(h, "PostToolUse", Some("Bash")));
            assert!(carries_context(h, "SessionStart", None));
            assert!(!carries_context(h, "PreToolUse", Some(ASK_TOOL)));
            assert!(!carries_context(h, "PermissionRequest", Some("Bash")));
            assert!(!carries_context(h, "Stop", None));
        }
        assert_eq!(
            transition(Harness::Pi, "agent_settled", None),
            Some(Transition::To(Activity::Idle))
        );
        assert!(carries_context(Harness::Pi, "context", None));
        assert!(!carries_context(Harness::Pi, "agent_settled", None));
    }

    #[test]
    fn every_wired_claude_event_means_something() {
        for event in CLAUDE_EVENTS {
            assert!(
                transition(Harness::Claude, event, None).is_some(),
                "{event}"
            );
        }
        let settings = claude_settings("/bin/bench");
        assert_eq!(settings["crossSessionInbound"], "accept");
        assert_eq!(
            settings["hooks"].as_object().unwrap().len(),
            CLAUDE_EVENTS.len()
        );
        assert_eq!(
            settings["hooks"]["PostToolUse"][0]["hooks"][0]["args"],
            serde_json::json!(["hook", "claude"])
        );
    }

    #[test]
    fn args_decode_from_what_the_cli_sends() {
        let args: HookArgs = serde_json::from_value(serde_json::json!({
            "harness": "claude", "event": "PostToolUse", "session": "s", "cwd": "/p", "pid": 7
        }))
        .unwrap();
        assert_eq!(args.harness, Harness::Claude);
        assert!(args.pane.is_none() && args.tool.is_none());
    }
}
