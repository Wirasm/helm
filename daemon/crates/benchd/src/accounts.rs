//! Which Claude login an agent benchd starts runs on, when the operator has more than one.
//!
//! Claude keeps one login per config dir: the default is `~/.claude`, with `CLAUDE_CONFIG_DIR`
//! unset, and every other login is a dir the operator lists in `<root>/accounts.toml`:
//!
//! ```toml
//! [[claude]]
//! dir = "/Users/op/.claude-b"
//! ```
//!
//! `just claude-account add` makes such a dir: links into `~/.claude` for everything but the
//! login, so an agent there runs the operator's own config and writes its conversations where
//! benchd reads them, and the operator logs it in once. The dir is used exactly as written,
//! because Claude names the login's keychain item after that string.
//!
//! [`choose`] is the whole policy, and it picks only the login: the model and effort a caller
//! asked for pass through untouched. A new conversation goes where quota is about to be lost:
//! the account whose week resets soonest, within [`WEEK_ENDING_MS`], with room left in both its
//! week and its five hours; else the one that has used the least of its five hours. A resume or a fork stays on the account its
//! conversation last ran on, where its prompt cache is, unless that account is spent; then it
//! goes where a new one would. With no file, there is one account, the default, and benchd
//! starts every agent as it did before accounts existed.
//!
//! The figures are what each login's statusline last reported (`usage`). A login that has not
//! reported counts as unused, which is how its figures arrive; a window past its reset counts
//! as empty.

use crate::Core;
use bench_session::{AgentKind, Conversation};
use bench_wire::{ConfigDir, Harness, Usage};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::Path;

/// A week that resets within this long is quota to spend now rather than balance.
pub const WEEK_ENDING_MS: u64 = 24 * 60 * 60 * 1000;

/// A window at or over this share is spent: Claude stops the agent there.
const SPENT_AT: f64 = 100.0;

/// A week about to reset is spent first only while its five hours have room, below this share
/// (helm's capsule calls it near the limit): otherwise the agent would stop within minutes.
const NEAR_AT: f64 = 90.0;

/// The file's shape. Unknown keys are refused, so a misspelt one is not silently ignored.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AccountsFile {
    #[serde(default)]
    claude: Vec<ClaudeAccount>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ClaudeAccount {
    dir: String,
}

/// The Claude logins benchd may start an agent on: the default (`None`) first, then each dir
/// `<root>/accounts.toml` lists that is logged in. A file that cannot be read, or names a dir that
/// is not a second login made from the default (its `projects` and `sessions` must be the
/// default's, or its transcripts and live sessions land where benchd never reads), is an error,
/// never a silent fallback to the
/// default: the operator wrote it to be used. A dir not yet logged in (no `oauthAccount` in its
/// `.claude.json`, which Claude writes at `/login`) is the expected state between
/// `just claude-account add` and the operator's login, so it is left out until then.
pub fn configured(root: &Path, home: &Path) -> Result<Vec<Option<ConfigDir>>, String> {
    let path = root.join("accounts.toml");
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![None]),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let file: AccountsFile =
        toml::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    let default = home.join(".claude");
    let mut accounts = vec![None];
    for ClaudeAccount { dir } in file.claude {
        let refused = |why: &str| format!("{} lists {dir:?}, which {why}", path.display());
        let account =
            ConfigDir::new(dir.clone()).map_err(|_| refused("is not an absolute path"))?;
        if Path::new(&dir) == default {
            return Err(refused("is the default login, which needs no entry"));
        }
        if !Path::new(&dir).is_dir() {
            return Err(refused("is not a directory"));
        }
        for shared in ["projects", "sessions"] {
            let real = |d: &Path| std::fs::canonicalize(d.join(shared)).ok();
            if real(Path::new(&dir)).is_none() || real(Path::new(&dir)) != real(&default) {
                return Err(refused(&format!(
                    "does not link its {shared} to the default login's (just claude-account seed)"
                )));
            }
        }
        if logged_in(Path::new(&dir)) && !accounts.contains(&Some(account.clone())) {
            accounts.push(Some(account));
        }
    }
    Ok(accounts)
}

/// Whether Claude has logged `dir` in: its `.claude.json` names the account (`oauthAccount`).
/// Only the key's presence is read, never anything of the login itself.
fn logged_in(dir: &Path) -> bool {
    std::fs::read_to_string(dir.join(".claude.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .is_some_and(|config| config["oauthAccount"].is_object())
}

/// What the caller is starting: a new conversation, or one that already ran on `recorded`
/// (a resume, or the original of a fork).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Start<'a> {
    New,
    Continue { recorded: Option<&'a ConfigDir> },
}

/// The account a Claude agent starts on, from `accounts` (the default first, as [`configured`]
/// gives them) and what each last reported at `now_ms`.
pub fn choose(
    accounts: &[Option<ConfigDir>],
    usage: &BTreeMap<(Harness, Option<ConfigDir>), Usage>,
    start: Start<'_>,
    now_ms: u64,
) -> Option<ConfigDir> {
    let standing = |account: &Option<ConfigDir>| {
        Standing::of(usage.get(&(Harness::Claude, account.clone())), now_ms)
    };
    if let Start::Continue { recorded } = start {
        let recorded = recorded.cloned();
        if accounts.contains(&recorded) && !standing(&recorded).spent {
            return recorded;
        }
    }
    let open: Vec<&Option<ConfigDir>> = accounts.iter().filter(|a| !standing(a).spent).collect();
    let candidates = if open.is_empty() {
        accounts.iter().collect()
    } else {
        open
    };
    let ending = candidates
        .iter()
        .filter_map(|a| {
            let standing = standing(a);
            let resets = standing.week_resets_ms?;
            (resets <= now_ms + WEEK_ENDING_MS && standing.five_hour < NEAR_AT)
                .then_some((resets, *a))
        })
        .min_by_key(|(resets, _)| *resets);
    if let Some((_, account)) = ending {
        return account.clone();
    }
    // `min_by` keeps the first of equals, so a tie goes to the default.
    candidates
        .into_iter()
        .min_by(|a, b| standing(a).five_hour.total_cmp(&standing(b).five_hour))
        .cloned()
        .flatten()
}

/// What one account's figures say at a moment, with every window past its reset dropped.
struct Standing {
    /// Share of the five-hour window used; 0 when unknown.
    five_hour: f64,
    /// When the week resets, while it still has room.
    week_resets_ms: Option<u64>,
    /// A live window is used up.
    spent: bool,
}

impl Standing {
    fn of(usage: Option<&Usage>, now_ms: u64) -> Standing {
        let live: Vec<_> = usage
            .into_iter()
            .flat_map(|u| &u.windows)
            .filter(|w| w.resets_at_ms.is_none_or(|r| r > now_ms))
            .collect();
        let window = |minutes: u32| live.iter().find(|w| w.minutes == minutes);
        let spent = live.iter().any(|w| w.used_percent >= SPENT_AT);
        Standing {
            five_hour: window(300).map_or(0.0, |w| w.used_percent),
            week_resets_ms: window(10080)
                .filter(|w| w.used_percent < SPENT_AT)
                .and_then(|w| w.resets_at_ms),
            spent,
        }
    }
}

/// The account `conversation` of `agent` starts on: only claude has accounts. A resume is
/// recorded under its own id, a fork under its original's.
pub fn for_spawn(
    core: &Core,
    agent: AgentKind,
    conversation: &Conversation,
) -> Result<Option<ConfigDir>, String> {
    if agent != AgentKind::Claude {
        return Ok(None);
    }
    let accounts = configured(&core.root, &core.home)?;
    if accounts.len() == 1 {
        return Ok(None);
    }
    let recorded = |id: &str| {
        crate::sessions::recorded(core, agent.name(), id).and_then(|h| h.account.clone())
    };
    let held;
    let start = match conversation {
        Conversation::New(_) => Start::New,
        Conversation::Resume(id) | Conversation::Fork { from: id, .. } => {
            held = recorded(id);
            Start::Continue {
                recorded: held.as_ref(),
            }
        }
    };
    Ok(choose(
        &accounts,
        &core.usage,
        start,
        crate::sessions::now_ms(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use bench_wire::UsageWindow;

    const NOW: u64 = 1_000_000_000_000;
    const HOUR: u64 = 60 * 60 * 1000;
    const B: &str = "/Users/op/.claude-b";

    fn dir(d: &str) -> ConfigDir {
        ConfigDir::new(d).unwrap()
    }

    fn accounts() -> Vec<Option<ConfigDir>> {
        vec![None, Some(dir(B))]
    }

    /// One account's figures: its five hours at `five_hour`, its week at `week` resetting in
    /// `week_in` hours.
    fn report(
        usage: &mut BTreeMap<(Harness, Option<ConfigDir>), Usage>,
        account: Option<&str>,
        five_hour: f64,
        (week, week_in): (f64, u64),
    ) {
        let window = |minutes, used_percent, resets| UsageWindow {
            minutes,
            used_percent,
            resets_at_ms: Some(resets),
            at_ms: NOW,
        };
        let account = account.map(dir);
        usage.insert(
            (Harness::Claude, account.clone()),
            Usage {
                harness: Harness::Claude,
                account,
                windows: vec![
                    window(300, five_hour, NOW + 2 * HOUR),
                    window(10080, week, NOW + week_in * HOUR),
                ],
            },
        );
    }

    fn pick(usage: &BTreeMap<(Harness, Option<ConfigDir>), Usage>, start: Start) -> Option<String> {
        choose(&accounts(), usage, start, NOW).map(|d| d.as_str().to_string())
    }

    #[test]
    fn a_new_conversation_goes_to_the_lower_five_hours() {
        let mut usage = BTreeMap::new();
        report(&mut usage, None, 70.0, (40.0, 100));
        report(&mut usage, Some(B), 10.0, (40.0, 120));
        assert_eq!(pick(&usage, Start::New).as_deref(), Some(B));
        report(&mut usage, Some(B), 80.0, (40.0, 120));
        assert_eq!(pick(&usage, Start::New), None);
    }

    #[test]
    fn a_week_about_to_reset_with_room_is_spent_first() {
        let mut usage = BTreeMap::new();
        report(&mut usage, None, 10.0, (40.0, 100));
        report(&mut usage, Some(B), 70.0, (60.0, 8));
        assert_eq!(
            pick(&usage, Start::New).as_deref(),
            Some(B),
            "B's week resets in 8 hours, whatever its five hours say"
        );
        report(&mut usage, None, 10.0, (40.0, 3));
        assert_eq!(pick(&usage, Start::New), None, "both ending: the sooner");
        report(&mut usage, Some(B), 70.0, (100.0, 8));
        report(&mut usage, None, 10.0, (40.0, 100));
        assert_eq!(
            pick(&usage, Start::New),
            None,
            "a week with no room left is not quota to spend"
        );
        report(&mut usage, Some(B), 95.0, (60.0, 8));
        assert_eq!(
            pick(&usage, Start::New),
            None,
            "nor one whose five hours are nearly gone"
        );
    }

    #[test]
    fn equal_figures_go_to_the_default() {
        let mut usage = BTreeMap::new();
        report(&mut usage, None, 20.0, (40.0, 100));
        report(&mut usage, Some(B), 20.0, (40.0, 120));
        assert_eq!(pick(&usage, Start::New), None);
    }

    #[test]
    fn a_spent_account_is_passed_over_unless_every_one_is() {
        let mut usage = BTreeMap::new();
        report(&mut usage, None, 100.0, (40.0, 100));
        report(&mut usage, Some(B), 90.0, (40.0, 120));
        assert_eq!(pick(&usage, Start::New).as_deref(), Some(B));
        report(&mut usage, Some(B), 100.0, (40.0, 120));
        assert_eq!(pick(&usage, Start::New), None, "all spent: the lowest");
    }

    #[test]
    fn a_continued_conversation_stays_where_it_ran_until_that_account_is_spent() {
        let mut usage = BTreeMap::new();
        report(&mut usage, None, 10.0, (40.0, 100));
        report(&mut usage, Some(B), 95.0, (40.0, 120));
        let b = dir(B);
        let on_b = Start::Continue { recorded: Some(&b) };
        assert_eq!(pick(&usage, on_b).as_deref(), Some(B), "its cache is there");
        report(&mut usage, Some(B), 100.0, (40.0, 120));
        assert_eq!(pick(&usage, on_b), None, "B's five hours are spent");
        report(&mut usage, Some(B), 10.0, (100.0, 120));
        assert_eq!(pick(&usage, on_b), None, "B's week is spent");
        assert_eq!(
            pick(&usage, Start::Continue { recorded: None }),
            None,
            "recorded on the default"
        );
        let gone_dir = dir("/Users/op/.claude-gone");
        let gone = Start::Continue {
            recorded: Some(&gone_dir),
        };
        report(&mut usage, Some(B), 5.0, (40.0, 120));
        assert_eq!(
            pick(&usage, gone).as_deref(),
            Some(B),
            "an account no longer listed: where a new one goes"
        );
    }

    #[test]
    fn an_account_that_has_not_reported_counts_as_unused_and_a_reset_window_as_empty() {
        let mut usage = BTreeMap::new();
        report(&mut usage, None, 30.0, (40.0, 100));
        assert_eq!(pick(&usage, Start::New).as_deref(), Some(B));
        report(&mut usage, Some(B), 50.0, (40.0, 120));
        usage.get_mut(&(Harness::Claude, None)).unwrap().windows[0].resets_at_ms = Some(NOW - 1);
        assert_eq!(
            pick(&usage, Start::New),
            None,
            "the default's 30% has reset"
        );
    }

    #[test]
    fn with_one_account_it_is_always_the_default() {
        let mut usage = BTreeMap::new();
        report(&mut usage, None, 100.0, (100.0, 1));
        assert_eq!(choose(&[None], &usage, Start::New, NOW), None);
        assert_eq!(
            choose(
                &[None],
                &usage,
                Start::Continue {
                    recorded: Some(&dir(B))
                },
                NOW
            ),
            None
        );
    }

    #[test]
    fn the_file_lists_logins_and_refuses_one_it_cannot_use() {
        let dir = std::env::temp_dir().join(format!("benchd-accounts-{}", std::process::id()));
        let (root, home) = (dir.join("root"), dir.join("home"));
        let (second, unlinked) = (dir.join("claude-b"), dir.join("claude-c"));
        for d in [&root, &second, &unlinked] {
            std::fs::create_dir_all(d).unwrap();
        }
        for d in ["projects", "sessions"] {
            std::fs::create_dir_all(home.join(".claude").join(d)).unwrap();
            std::os::unix::fs::symlink(home.join(".claude").join(d), second.join(d)).unwrap();
        }
        // Its transcripts would be shared, its live sessions not.
        std::os::unix::fs::symlink(home.join(".claude/projects"), unlinked.join("projects"))
            .unwrap();
        assert_eq!(configured(&root, &home), Ok(vec![None]), "no file");
        let write = |text: &str| std::fs::write(root.join("accounts.toml"), text).unwrap();
        let entry = |d: &Path| format!("[[claude]]\ndir = {:?}\n", d.display().to_string());
        write(&(entry(&second) + &entry(&second)));
        assert_eq!(
            configured(&root, &home),
            Ok(vec![None]),
            "not logged in yet"
        );
        std::fs::write(second.join(".claude.json"), r#"{"oauthAccount": {}}"#).unwrap();
        assert_eq!(
            configured(&root, &home),
            Ok(vec![
                None,
                Some(super::ConfigDir::new(second.display().to_string()).unwrap())
            ])
        );
        for (text, says) in [
            (entry(&unlinked), "does not link its sessions"),
            (entry(&dir.join("missing")), "is not a directory"),
            (entry(&home.join(".claude")), "is the default login"),
            ("[[claude]]\ndir = \"relative\"\n".to_string(), "absolute"),
            ("[[claude]]\npath = \"/x\"\n".to_string(), "unknown field"),
        ] {
            write(&text);
            let why = configured(&root, &home).unwrap_err();
            assert!(why.contains(says), "{why}");
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
