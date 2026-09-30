//! What helm asks of benchd's machine rather than its own (M5c, helm #459): the Worktrees
//! drawer's and the Archon drawer's `git` and `archon` calls, the workspace tab's branch, which
//! repositories there are and whether a path exists. helm draws; benchd's machine is the one with
//! the repositories on it, whether that is this Mac or another.
//!
//! Three verbs:
//!
//! - `command/run` runs `git` or `archon` there and answers its exit status and output. The
//!   program is a tagged enum, not an argv, because benchd resolves each one on its own machine:
//!   `archon` is a bun global in benchd's `~/.bun/bin`, which helm cannot name. **It is not a
//!   boundary**: `git -c alias.x='!cmd' x` runs anything, so this verb is a shell for whoever
//!   reaches benchd, exactly as `spawn` and `just/run` already are. The trust boundary is the
//!   socket and the operator's tailnet.
//! - `path/exists` answers which of some paths exist there. A path benchd could not look at is a
//!   refusal, never "absent": a worktree read as missing is removed by `git worktree prune`.
//! - `git/repositories` is the drawer's discovery: every repository under benchd's home, found by
//!   reading the disk there, in one call rather than a round trip per folder.
//!
//! helm's copies are `Sources/HelmWire/Bench/BenchCommands.swift`; both are pinned by
//! `fixtures/command-verbs.json`.

use serde::{Deserialize, Serialize};

/// The most `command/run` answers with from one stream. An Archon run list is well under a
/// megabyte and `git status` of a busy worktree a few; past this, the answer is a refusal.
pub const COMMAND_OUTPUT_MAX_BYTES: u64 = 16 * 1024 * 1024;

/// The program `command/run` runs, and what it needs besides its arguments.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "program", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    /// `git`, found on benchd's `PATH`. Most calls name their repository with `-C`, so the
    /// working directory is optional.
    Git {
        args: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
    /// `archon`, found in benchd's `~/.bun/bin` first. The working directory is required: Archon
    /// resolves its project from it and refuses without one.
    Archon {
        args: Vec<String>,
        cwd: String,
        /// `ARCHON_HOME` for the run: `archon complete` works in the Archon home a worktree lives
        /// under.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        home: Option<String>,
    },
}

/// `command/run`'s payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommandRunArgs {
    pub command: Command,
    /// benchd kills the program after this long and answers `TimedOut`.
    pub timeout_ms: u64,
}

/// `command/run`'s answer. A nonzero exit is an answer, not a refusal: `git merge-base
/// --is-ancestor` says "no" with status 1, and the caller decides what a status means. A program
/// benchd could not start is a refusal with the reason.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CommandRun {
    /// `status` is the exit code, or 128 plus the signal that ended it. `stdout` and `stderr` are
    /// base64: git prints paths in whatever bytes the disk holds.
    Exited {
        status: i32,
        stdout: String,
        stderr: String,
    },
    TimedOut,
}

/// `path/exists`'s payload: absolute paths.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PathExistsArgs {
    pub paths: Vec<String>,
}

/// `path/exists`'s answer: the asked paths that exist (symlinks followed), as they were asked.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PathExists {
    pub existing: Vec<String>,
}

/// `git/repositories`'s payload: the bench's workspace paths, whose repositories are listed
/// first and marked.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GitRepositoriesArgs {
    pub workspaces: Vec<String>,
}

/// One repository, by its common git directory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitRepository {
    pub common_dir: String,
    /// Some bench workspace is in this repository.
    pub is_workspace: bool,
}

/// `git/repositories`'s answer: workspaces' repositories first, then the rest, each by path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitRepositories {
    pub repositories: Vec<GitRepository>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::path::PathBuf;

    /// `fixtures/command-verbs.json` pins what helm sends and reads — each request and each
    /// answer, written back byte for byte.
    #[test]
    fn the_command_fixture_round_trips() {
        let path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/command-verbs.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();

        let request = |key: &str, verb: &str| -> crate::Request {
            let r: crate::Request = serde_json::from_value(value[key].clone()).unwrap();
            assert_eq!(r.verb, verb, "{key}");
            assert!(crate::Verb::parse(verb).is_some(), "{verb}");
            r
        };
        let with = |r: crate::Request, args: Value| crate::Request { args, ..r };
        let run = |key: &str| {
            let r = request(key, "command/run");
            let args: CommandRunArgs = serde_json::from_value(r.args.clone()).unwrap();
            (r, args)
        };
        let (git, git_args) = run("git");
        assert!(matches!(git_args.command, Command::Git { cwd: None, .. }));
        let (git_in, git_in_args) = run("git_in");
        assert!(matches!(
            git_in_args.command,
            Command::Git { cwd: Some(_), .. }
        ));
        let (archon, archon_args) = run("archon");
        assert!(matches!(
            archon_args.command,
            Command::Archon { home: None, .. }
        ));
        let (complete, complete_args) = run("archon_complete");
        assert!(matches!(
            complete_args.command,
            Command::Archon { home: Some(_), .. }
        ));
        let exists = request("exists", "path/exists");
        let exists_args: PathExistsArgs = serde_json::from_value(exists.args.clone()).unwrap();
        let repos = request("repositories", "git/repositories");
        let repos_args: GitRepositoriesArgs = serde_json::from_value(repos.args.clone()).unwrap();
        let ran: Vec<CommandRun> = serde_json::from_value(value["run_answers"].clone()).unwrap();
        let existing: PathExists = serde_json::from_value(value["existing"].clone()).unwrap();
        let found: GitRepositories = serde_json::from_value(value["found"].clone()).unwrap();

        let written_back = serde_json::to_string_pretty(&json!({
            "git": with(git, json!(git_args)),
            "git_in": with(git_in, json!(git_in_args)),
            "archon": with(archon, json!(archon_args)),
            "archon_complete": with(complete, json!(complete_args)),
            "exists": with(exists, json!(exists_args)),
            "repositories": with(repos, json!(repos_args)),
            "run_answers": ran,
            "existing": existing,
            "found": found,
        }))
        .unwrap()
            + "\n";
        assert_eq!(
            written_back,
            text,
            "the spelling drifted from {}",
            path.display()
        );
    }

    /// Only the two programs: anything else is not a `Command`, so benchd refuses it before
    /// looking for a binary.
    #[test]
    fn a_program_that_is_not_git_or_archon_does_not_parse() {
        for args in [
            json!({ "command": { "program": "sh", "args": ["-c", "true"] }, "timeout_ms": 1 }),
            json!({ "command": { "program": "git", "args": [], "env": {} }, "timeout_ms": 1 }),
            json!({ "command": { "program": "archon", "args": [] }, "timeout_ms": 1 }),
        ] {
            assert!(
                serde_json::from_value::<CommandRunArgs>(args.clone()).is_err(),
                "{args}"
            );
        }
    }
}
