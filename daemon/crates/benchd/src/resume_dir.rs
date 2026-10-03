//! Where a resumed conversation runs when the folder it ran in is gone (#621).
//!
//! A finished agent stays resumable, but its record names the worktree it ran in, and the merge
//! queue prunes that worktree after the merge. Both routes that resume (`spawn --resume` and
//! `restore`) ask [`plan`], outside the core lock since it may run git. A resume that is refused
//! (its conversation is live elsewhere) is refused before [`start`], so it recreates nothing.
//! [`start`] finds the folder:
//!
//! - **The folder is there**: it, as before.
//! - **It is gone, its parent is not, git ignores it, and the agent's branch still exists**:
//!   benchd recreates the folder as a worktree of its repository on that local branch. Only a
//!   folder that can have been a worktree's root: its parent is there (a parent that is gone too,
//!   all of `.worktrees/` or a worktree the cwd was a subfolder of, is not invented), and git
//!   ignores it, so a gone tracked or scratch folder of a live checkout never becomes a worktree
//!   nested in that checkout's tree.
//! - **Otherwise**, an agent that can re-enter its conversation from anywhere starts in the
//!   repository's root; pi cannot ([`resumes_anywhere`]), so its resume is refused, naming the
//!   command that would bring the folder back.
//!
//! The agent learns which through the resume notice (`spawn::wire`). A worktree is recreated before
//! the spawn has its pane, so a spawn refused after that (a taken `--name`, a placement refusal)
//! leaves it in place: the folder the next resume of that conversation would recreate anyway.

use crate::Core;
use bench_session::{AgentKind, Posture};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Where a resume runs, and what its notice says about it when that is not where it ran.
#[derive(Debug, PartialEq, Eq)]
pub struct Start {
    pub cwd: String,
    pub note: Option<String>,
}

/// Whether conversation `conversation` of `agent`, recorded in `cwd`, may be resumed, and how:
/// refused while a live process holds it ([`crate::restore::refusal`]), else in the posture it
/// was spawned in (a fork's is read-only, #531), in the folder [`start`] finds, which a codex must
/// trust. The refusal comes first, so a resume that will not run brings back no worktree.
pub fn plan(
    core: &Arc<Mutex<Core>>,
    agent: AgentKind,
    conversation: &str,
    cwd: &str,
) -> Result<(Start, Posture), String> {
    let forked_from = {
        let c = core.lock().unwrap();
        if let Some(why) = crate::restore::refusal(&c, agent.name(), conversation) {
            return Err(why);
        }
        crate::sessions::recorded(&c, agent.name(), conversation)
            .and_then(|h| h.forked_from.clone())
    };
    let start = start(agent, conversation, cwd)?;
    if agent == AgentKind::Codex {
        crate::codex_trust::may_run(&start.cwd)?;
    }
    Ok((start, Posture::resuming(forked_from.as_deref())))
}

/// Where conversation `conversation` of `agent`, recorded in `cwd`, resumes. The branch it is
/// recreated on is the harness's own last record of it ([`bench_sessions::last_branch`]); pi
/// writes none.
pub fn start(agent: AgentKind, conversation: &str, cwd: &str) -> Result<Start, String> {
    if Path::new(cwd).is_dir() {
        return Ok(Start {
            cwd: cwd.to_string(),
            note: None,
        });
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let branch = bench_wire::Harness::parse(agent.name())
        .zip(home)
        .and_then(|(harness, home)| bench_sessions::last_branch(&home, harness, conversation, cwd));
    place(agent, cwd, branch.as_deref())
}

/// Whether `agent` re-enters a conversation from a folder other than the one it ran in. claude
/// (2.1.287) and codex (0.160.0) do, and write on in the same transcript. pi (0.99.2) does not:
/// `--session-id` elsewhere starts a new, empty session under that id, and `--session` asks to
/// fork.
fn resumes_anywhere(agent: AgentKind) -> bool {
    matches!(agent, AgentKind::Claude | AgentKind::Codex)
}

/// [`start`] for a folder that is gone, once the branch is known (or known to be unknown).
fn place(agent: AgentKind, cwd: &str, branch: Option<&str>) -> Result<Start, String> {
    let path = Path::new(cwd);
    let Some(repo) = path
        .ancestors()
        .skip(1)
        .find(|a| a.is_dir())
        .and_then(repo_root)
    else {
        return Err(format!(
            "{cwd} is gone, and benchd finds no git repository it belonged to"
        ));
    };
    let parent_there = path.parent().is_some_and(Path::is_dir);
    let why = match branch {
        _ if !parent_there => "the folder it was in is gone too".to_string(),
        _ if !ignored(&repo, cwd) => format!("it is not a folder {repo} ignores, so no worktree"),
        None => "benchd cannot tell which branch it was on".to_string(),
        Some(b) => match add_worktree(&repo, cwd, b) {
            Ok(()) => {
                return Ok(Start {
                    cwd: cwd.to_string(),
                    note: Some(format!(
                        "The folder you ran in, {cwd}, had been removed. benchd recreated it as a \
                         worktree of {repo} on your branch {b}: what you committed is there; \
                         anything you had not committed is gone."
                    )),
                });
            }
            Err(e) => format!("its branch {b} could not be checked out there ({e})"),
        },
    };
    if !resumes_anywhere(agent) {
        let fix = match branch {
            Some(b) => format!("git -C {repo} worktree add {cwd} {b}"),
            None => format!("git -C {repo} worktree add {cwd} <branch>"),
        };
        return Err(format!(
            "{} re-enters a conversation only in the folder it ran in, and {cwd} is gone: {why}. \
             Bring it back (`{fix}`) and resume again",
            agent.name()
        ));
    }
    Ok(Start {
        note: Some(format!(
            "The folder you ran in, {cwd}, had been removed, and {why}. benchd started you in the \
             repository root, {repo}, instead: you are not in your old worktree or on your own \
             branch, so check where you are before you change anything."
        )),
        cwd: repo,
    })
}

/// The root of the checkout `dir` is in.
fn repo_root(dir: &Path) -> Option<String> {
    let top = git(
        dir,
        &["rev-parse", "--show-toplevel"],
        Duration::from_secs(5),
    )
    .ok()?;
    Some(top.trim().to_string()).filter(|t| !t.is_empty())
}

/// Whether the checkout at `repo` ignores `cwd`, as it does a worktree under `.worktrees/`.
fn ignored(repo: &str, cwd: &str) -> bool {
    git(
        Path::new(repo),
        &["check-ignore", "-q", cwd],
        Duration::from_secs(5),
    )
    .is_ok()
}

/// `git worktree add <cwd> <branch>` in `repo`, for a local branch only: given a name that is only
/// `origin/<branch>`, git would make a new branch from it. A name git would read as a flag is no
/// branch.
fn add_worktree(repo: &str, cwd: &str, branch: &str) -> Result<(), String> {
    if branch.starts_with('-') {
        return Err(format!("{branch:?} is not a branch name"));
    }
    let local = format!("refs/heads/{branch}");
    git(
        Path::new(repo),
        &["rev-parse", "--verify", "--quiet", &local],
        Duration::from_secs(5),
    )
    .map_err(|_| "it is not a local branch any more".to_string())?;
    git(
        Path::new(repo),
        &["worktree", "add", "--quiet", cwd, branch],
        Duration::from_secs(60),
    )
    .map(drop)
}

/// `git <args>` in `dir`: its stdout, or why not (git's own last line), killed at `wait`. Both
/// pipes are read as git writes, so a chatty hook cannot fill one and stall git until the kill.
fn git(dir: &Path, args: &[&str], wait: Duration) -> Result<String, String> {
    let mut child = Command::new("git")
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("git: {e}"))?;
    let drain = |pipe: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut text = String::new();
            if let Some(mut pipe) = pipe {
                let _ = pipe.read_to_string(&mut text);
            }
            text
        })
    };
    let out = drain(
        child
            .stdout
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let err = drain(
        child
            .stderr
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let deadline = Instant::now() + wait;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            // The readers are left to finish on their own: a hook's child can hold a pipe open.
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("git {} took over {}s", args[0], wait.as_secs()));
            }
        }
    };
    if status.success() {
        return Ok(out.join().unwrap_or_default());
    }
    let err = err.join().unwrap_or_default();
    Err(err
        .lines()
        .rfind(|l| !l.trim().is_empty())
        .unwrap_or("git failed")
        .trim()
        .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A temp dir holding `repo`, a git repository that ignores `.worktrees/` (as helm's does),
    /// and its worktree `repo/.worktrees/w` on branch `feat/x`, made and then removed by git.
    fn removed_worktree(name: &str) -> (PathBuf, String) {
        let dir = std::env::temp_dir().join(format!("resume-dir-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("repo")).unwrap();
        let dir = dir.canonicalize().unwrap();
        let repo = dir.join("repo");
        std::fs::write(repo.join(".gitignore"), "/.worktrees/\n").unwrap();
        for args in [
            &["init", "-q", "-b", "main"][..],
            &["add", ".gitignore"],
            &["commit", "-q", "-m", "x"],
            &["worktree", "add", "-q", "-b", "feat/x", ".worktrees/w"],
            &["worktree", "remove", ".worktrees/w"],
        ] {
            run_git(&repo, args);
        }
        let cwd = repo.join(".worktrees/w").display().to_string();
        (dir, cwd)
    }

    fn run_git(repo: &Path, args: &[&str]) {
        let out = Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t"])
            .args(args)
            .current_dir(repo)
            .output()
            .unwrap();
        assert!(out.status.success(), "{args:?}: {out:?}");
    }

    fn branch_of(dir: &str) -> String {
        git(
            Path::new(dir),
            &["branch", "--show-current"],
            Duration::from_secs(5),
        )
        .unwrap()
        .trim()
        .to_string()
    }

    #[test]
    fn a_folder_that_is_there_is_left_alone() {
        let here = std::env::temp_dir().display().to_string();
        let start = start(AgentKind::Pi, "p-1", &here).unwrap();
        assert_eq!(
            start,
            Start {
                cwd: here,
                note: None
            }
        );
    }

    #[test]
    fn a_removed_worktree_is_recreated_on_its_branch() {
        let (dir, cwd) = removed_worktree("recreate");
        let start = place(AgentKind::Pi, &cwd, Some("feat/x")).unwrap();
        assert_eq!(start.cwd, cwd);
        assert_eq!(branch_of(&cwd), "feat/x");
        let note = start.note.unwrap();
        assert!(
            note.contains("recreated") && note.contains("feat/x"),
            "{note}"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn with_no_branch_to_recreate_it_on_claude_starts_in_the_root_and_pi_is_refused() {
        let (dir, cwd) = removed_worktree("root");
        let repo = dir.join("repo").display().to_string();
        for branch in [None, Some("feat/deleted")] {
            let start = place(AgentKind::Claude, &cwd, branch).unwrap();
            assert_eq!(start.cwd, repo);
            let note = start.note.unwrap();
            assert!(note.contains("repository root"), "{note}");
            let refused = place(AgentKind::Pi, &cwd, branch).unwrap_err();
            assert!(refused.contains("worktree add"), "{refused}");
        }
        assert!(!Path::new(&cwd).exists(), "nothing was recreated");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_gone_folder_of_a_live_checkout_never_becomes_a_nested_worktree() {
        // A tracked subfolder a branch switch removed: its parent is there, git does not ignore
        // it, and a worktree there would sit inside the checkout's own tree.
        let (dir, _) = removed_worktree("nested");
        let repo = dir.join("repo");
        std::fs::create_dir_all(repo.join("daemon/crates")).unwrap();
        std::fs::write(repo.join("daemon/crates/f"), "").unwrap();
        run_git(&repo, &["add", "daemon"]);
        run_git(&repo, &["commit", "-q", "-m", "tracked"]);
        std::fs::remove_dir_all(repo.join("daemon/crates")).unwrap();
        let gone = repo.join("daemon/crates").display().to_string();
        let start = place(AgentKind::Claude, &gone, Some("feat/x")).unwrap();
        assert_eq!(start.cwd, repo.display().to_string());
        assert!(
            !Path::new(&gone).exists(),
            "no worktree in the tracked tree"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_branch_left_only_on_the_remote_is_not_recreated() {
        // `git worktree add <path> <b>` would make a new local branch from `origin/<b>`.
        let (dir, cwd) = removed_worktree("remote");
        let repo = dir.join("repo");
        run_git(
            &repo,
            &["update-ref", "refs/remotes/origin/feat/gone", "HEAD"],
        );
        let refused = place(AgentKind::Pi, &cwd, Some("feat/gone")).unwrap_err();
        assert!(refused.contains("not a local branch"), "{refused}");
        assert!(!Path::new(&cwd).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_folder_whose_parent_is_gone_too_is_not_recreated() {
        let (dir, cwd) = removed_worktree("parent");
        let deeper = format!("{cwd}/daemon");
        let start = place(AgentKind::Codex, &deeper, Some("feat/x")).unwrap();
        assert_eq!(start.cwd, dir.join("repo").display().to_string());
        assert!(!Path::new(&cwd).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_folder_in_no_repository_is_refused() {
        let dir = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("resume-dir-norepo-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let gone = dir.join("gone").display().to_string();
        let refused = place(AgentKind::Claude, &gone, Some("main")).unwrap_err();
        assert!(refused.contains("no git repository"), "{refused}");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
