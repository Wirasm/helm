//! The prompt rules (M1, #357): the shapes an agent's screen takes when it is waiting on the
//! operator, as data. #283 is why: a prompt the agent's hooks never report sits on its screen and
//! nowhere else, and nobody knew for six and a half hours.
//!
//! Each rule is pinned by a screen captured from the real CLI through benchd's own VT engine
//! (`bench get screen`), in `screens/`; the tests below hold every rule to its capture and every
//! idle and working capture to no rule at all. A rule names several strings together, because a
//! rule that matches something it should not is the expensive direction, and it reads only the
//! bottom of the screen, where a live prompt is drawn and an answered one has scrolled away from.
//! The strings are short: an agent draws its prompt at the pane's width, and a long sentence
//! wraps onto two rows in a narrow pane.
//!
//! To add one: capture the screen (`bench get screen <pane>` while it is up), save its lines to
//! `screens/<harness>-<what>.txt`, add the rule and a row to `CAPTURES`.

/// A shape of screen that means the agent is waiting on the operator.
pub struct Rule {
    /// Whose prompt this is: named in the log, and the capture that pins it. The rule is matched
    /// on any agent's screen.
    pub harness: &'static str,
    /// What the agent is waiting for, in the words `bench sessions --all` shows.
    pub waiting_for: &'static str,
    /// Every one of these is on one of the bottom [`TAIL`] non-blank lines.
    pub all: &'static [&'static str],
}

/// How many non-blank lines, from the bottom of the screen, a rule reads.
pub const TAIL: usize = 20;

pub const PERMISSION: &str = bench_wire::hook::PERMISSION;
pub const TRUST: &str = "trust prompt";
pub const HOOK_REVIEW: &str = "hook review";

pub static RULES: &[Rule] = &[
    // The stem varies by tool ("Do you want to make this edit to main.go?"), so it is the stem,
    // the first option and the footer together.
    Rule {
        harness: "claude",
        waiting_for: PERMISSION,
        all: &["Do you want to", "1. Yes", "Esc to cancel"],
    },
    // Asked once per directory, before the session reports anything to anyone.
    Rule {
        harness: "claude",
        waiting_for: TRUST,
        all: &["Quick safety check", "Yes, I trust this folder"],
    },
    Rule {
        harness: "codex",
        waiting_for: PERMISSION,
        all: &[
            "Would you like to",
            "1. Yes, proceed",
            "Press enter to confirm or esc to cancel",
        ],
    },
    Rule {
        harness: "codex",
        waiting_for: TRUST,
        all: &["Trust this folder?", "1. Trust and continue"],
    },
    // At startup, when the hooks codex reads (the bench's own among them) are new or changed
    // since he last trusted them. None of them runs until he does, so no hook reports this
    // wait. Measured on 0.159.3.
    Rule {
        harness: "codex",
        waiting_for: HOOK_REVIEW,
        all: &["Hooks need review", "Trust all and continue"],
    },
    // pi asks no permission for a tool; its one prompt is whether to load a project's `.pi`.
    Rule {
        harness: "pi",
        waiting_for: TRUST,
        all: &["Trust project folder?", "Do not trust"],
    },
];

/// The first rule the bottom of `lines` matches.
pub fn classify(lines: &[String]) -> Option<&'static Rule> {
    let tail: Vec<&str> = lines
        .iter()
        .rev()
        .map(|l| l.trim_end())
        .filter(|l| !l.is_empty())
        .take(TAIL)
        .collect();
    RULES.iter().find(|rule| {
        rule.all
            .iter()
            .all(|needle| tail.iter().any(|line| line.contains(needle)))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every capture, and what it must classify as.
    const CAPTURES: &[(&str, &str, Option<&str>)] = &[
        (
            "claude-permission",
            include_str!("../screens/claude-permission.txt"),
            Some(PERMISSION),
        ),
        (
            "claude-trust",
            include_str!("../screens/claude-trust.txt"),
            Some(TRUST),
        ),
        (
            "claude-idle",
            include_str!("../screens/claude-idle.txt"),
            None,
        ),
        (
            "claude-working",
            include_str!("../screens/claude-working.txt"),
            None,
        ),
        (
            "codex-approval",
            include_str!("../screens/codex-approval.txt"),
            Some(PERMISSION),
        ),
        (
            "codex-trust",
            include_str!("../screens/codex-trust.txt"),
            Some(TRUST),
        ),
        (
            "codex-hook-review",
            include_str!("../screens/codex-hook-review.txt"),
            Some(HOOK_REVIEW),
        ),
        (
            "codex-idle",
            include_str!("../screens/codex-idle.txt"),
            None,
        ),
        (
            "codex-working",
            include_str!("../screens/codex-working.txt"),
            None,
        ),
        (
            "pi-trust",
            include_str!("../screens/pi-trust.txt"),
            Some(TRUST),
        ),
        ("pi-idle", include_str!("../screens/pi-idle.txt"), None),
        (
            "pi-working",
            include_str!("../screens/pi-working.txt"),
            None,
        ),
    ];

    fn lines(text: &str) -> Vec<String> {
        text.lines().map(str::to_string).collect()
    }

    #[test]
    fn every_capture_classifies_as_what_it_shows() {
        for (name, text, want) in CAPTURES {
            let got = classify(&lines(text));
            assert_eq!(got.map(|r| r.waiting_for), *want, "{name}");
            if let Some(rule) = got {
                assert!(
                    name.starts_with(rule.harness),
                    "{name} matched {}'s rule",
                    rule.harness
                );
            }
        }
    }

    #[test]
    fn every_rule_is_pinned_by_a_capture() {
        for rule in RULES {
            assert!(
                CAPTURES.iter().any(|(name, text, _)| {
                    classify(&lines(text)).is_some_and(|r| std::ptr::eq(r, rule))
                        && name.starts_with(rule.harness)
                }),
                "{} {:?} has no capture",
                rule.harness,
                rule.all
            );
        }
    }

    /// An answered prompt scrolls up into the transcript: only a prompt at the bottom counts.
    #[test]
    fn a_prompt_above_the_tail_is_not_waiting() {
        let mut screen = lines(include_str!("../screens/claude-permission.txt"));
        screen.extend((0..TAIL).map(|i| format!("later output {i}")));
        assert!(classify(&screen).is_none());
    }
}
