//! helm's `git` and `archon`, run on this machine (M5c, helm #459): `command/run`,
//! `path/exists` and `git/repositories`. The wire types and why there are three are
//! `bench_wire::commands`.
//!
//! helm keeps every line of its git and Archon logic — parsing, what a delete would lose, the
//! merged re-check before a branch goes — and asks benchd only to run the commands and look at
//! the disk, because the repositories are on benchd's machine. So what these verbs owe helm is
//! fidelity: the exit status, stdout and stderr exactly as the program gave them, and "could
//! not look" never passed off as "not there".

use bench_doc::StandardPath;
use bench_wire::{
    COMMAND_OUTPUT_MAX_BYTES, Command, CommandRun, CommandRunArgs, GitRepositories,
    GitRepositoriesArgs, GitRepository, PathExists, PathExistsArgs, base64,
};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Read, Seek, SeekFrom};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// Where a program is looked for after benchd's own `PATH`: launchd starts benchd with a
/// minimal one, and Homebrew's prefixes are where tools live on the operator's machines.
const FALLBACK_BINS: &[&str] = &["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"];

/// How often a running command is checked for having exited.
const POLL: Duration = Duration::from_millis(5);

/// Names each capture file uniquely within this process.
static CAPTURE: AtomicU64 = AtomicU64::new(0);

fn absolute(raw: &str) -> Result<PathBuf, String> {
    Ok(PathBuf::from(StandardPath::new(raw)?.as_str()))
}

fn home() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| "benchd has no HOME, so there is no home to look in".to_string())
}

// ---------------------------------------------------------------------------
// command/run
// ---------------------------------------------------------------------------

/// `command/run`: the program's exit status and output, or `timed_out`. Refused when the working
/// directory is not one, the program is not installed, or its output is over the cap.
///
/// Output goes to files, never pipes: `archon workflow run --detach` leaves a background process
/// holding the program's stdout, and a pipe would hold this answer until that run ended.
pub fn run(args: &Value) -> Result<Value, String> {
    let args: CommandRunArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("command/run args: {e}"))?;
    let (name, arguments, cwd) = match &args.command {
        Command::Git { args, cwd } => ("git", args, cwd.as_deref()),
        Command::Archon { args, cwd, .. } => ("archon", args, Some(cwd.as_str())),
    };
    let cwd = cwd.map(absolute).transpose()?;
    if let Some(cwd) = &cwd
        && !cwd.is_dir()
    {
        return Err(format!(
            "{} is not a directory to run {name} in",
            cwd.display()
        ));
    }
    let dirs = search_path(&args.command)?;
    let program = dirs
        .iter()
        .map(|dir| dir.join(name))
        .find(|candidate| is_executable(candidate))
        .ok_or_else(|| {
            let looked: Vec<String> = dirs.iter().map(|d| d.display().to_string()).collect();
            format!(
                "{name} is not installed on benchd's machine: looked in {}",
                looked.join(", ")
            )
        })?;

    let mut command = std::process::Command::new(&program);
    command.args(arguments).stdin(Stdio::null());
    if let Some(cwd) = &cwd {
        command.current_dir(cwd);
    }
    if let Command::Archon { home, .. } = &args.command {
        // Archon is `#!/usr/bin/env bun`: bun has to be on the child's PATH, not only archon.
        command.env(
            "PATH",
            std::env::join_paths(&dirs).map_err(|e| e.to_string())?,
        );
        if let Some(home) = home {
            command.env("ARCHON_HOME", home);
        }
    }
    let (stdout, stdout_writer) = capture()?;
    let (stderr, stderr_writer) = capture()?;
    command.stdout(stdout_writer).stderr(stderr_writer);
    let mut child = command
        .spawn()
        .map_err(|e| format!("cannot start {}: {e}", program.display()))?;
    drop(command);

    let deadline = Instant::now() + Duration::from_millis(args.timeout_ms);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Ok(json!(CommandRun::TimedOut));
            }
            Ok(None) => std::thread::sleep(POLL),
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("cannot wait for {name}: {e}"));
            }
        }
    };
    let status = status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(0));
    Ok(json!(CommandRun::Exited {
        status,
        stdout: base64(&read_capture(stdout, name, "stdout")?),
        stderr: base64(&read_capture(stderr, name, "stderr")?),
    }))
}

/// Where the program is looked for, in order, which is also the `PATH` an `archon` child gets:
/// benchd's `~/.bun/bin` first for `archon` (a bun global), then benchd's `PATH`, then the
/// fallbacks.
fn search_path(command: &Command) -> Result<Vec<PathBuf>, String> {
    let mut dirs = Vec::new();
    if matches!(command, Command::Archon { .. }) {
        dirs.push(home()?.join(".bun/bin"));
    }
    let path = std::env::var_os("PATH").unwrap_or_default();
    for dir in std::env::split_paths(&path).chain(FALLBACK_BINS.iter().map(PathBuf::from)) {
        if !dir.as_os_str().is_empty() && !dirs.contains(&dir) {
            dirs.push(dir);
        }
    }
    Ok(dirs)
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// A capture file already unlinked, so nothing is left behind whatever happens next: the read
/// handle, and a write handle for the child.
fn capture() -> Result<(File, Stdio), String> {
    let path = std::env::temp_dir().join(format!(
        "benchd-command-{}-{}",
        std::process::id(),
        CAPTURE.fetch_add(1, Ordering::Relaxed)
    ));
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|e| format!("cannot create a capture file at {}: {e}", path.display()))?;
    let _ = fs::remove_file(&path);
    let writer = file
        .try_clone()
        .map_err(|e| format!("cannot share a capture file: {e}"))?;
    Ok((file, Stdio::from(writer)))
}

fn read_capture(mut file: File, name: &str, stream: &str) -> Result<Vec<u8>, String> {
    file.seek(SeekFrom::Start(0))
        .map_err(|e| format!("cannot read {name}'s {stream}: {e}"))?;
    let mut bytes = Vec::new();
    file.take(COMMAND_OUTPUT_MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("cannot read {name}'s {stream}: {e}"))?;
    if bytes.len() as u64 > COMMAND_OUTPUT_MAX_BYTES {
        return Err(format!(
            "{name} wrote more than {COMMAND_OUTPUT_MAX_BYTES} bytes to {stream}"
        ));
    }
    Ok(bytes)
}

// ---------------------------------------------------------------------------
// path/exists
// ---------------------------------------------------------------------------

/// `path/exists`: the asked paths that exist, symlinks followed. A path whose parent is a file
/// does not exist; one benchd was not allowed to look at refuses the whole answer, because helm
/// reads a missing worktree as one to prune.
pub fn exists(args: &Value) -> Result<Value, String> {
    let args: PathExistsArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("path/exists args: {e}"))?;
    let mut existing = Vec::new();
    for raw in args.paths {
        let path = absolute(&raw)?;
        match fs::metadata(&path) {
            Ok(_) => existing.push(raw),
            Err(e) if matches!(e.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory) => {}
            Err(e) => {
                return Err(format!(
                    "cannot tell whether {} exists: {e}",
                    path.display()
                ));
            }
        }
    }
    Ok(json!(PathExists { existing }))
}

// ---------------------------------------------------------------------------
// git/repositories
// ---------------------------------------------------------------------------

/// How deep under `~/Projects` a repository is looked for.
const PROJECT_DEPTH: usize = 4;

/// Folders that hold build output or dependencies, never a repository the operator works in.
const SKIPPED: &[&str] = &[
    "node_modules",
    ".build",
    ".worktrees",
    "target",
    ".venv",
    "venv",
    "dist",
    "build",
    "Pods",
    "DerivedData",
];

/// `git/repositories`: which repositories the Worktrees drawer lists, found by reading the disk
/// and starting no process, so a scan of a few hundred folders costs milliseconds. Three places,
/// one entry per common git directory:
///
/// - the bench's workspaces, marked, which are listed even when they have no linked worktree;
/// - `<home>/Projects`, down to `PROJECT_DEPTH` folders, skipping `SKIPPED` and never descending
///   into a repository once found;
/// - Archon's worktrees, `<home>/.archon*/workspaces/<owner>/<repo>/worktrees/…`, which lead back
///   to the repository each was made from.
pub fn repositories(args: &Value) -> Result<Value, String> {
    let args: GitRepositoriesArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("git/repositories args: {e}"))?;
    Ok(json!(find(&home()?, &args.workspaces)?))
}

/// Refused when benchd cannot read one of the places it searches from — `~/Projects` or the home
/// the `.archon*` folders are in — so the drawer says it could not look instead of "No worktrees
/// found". Below those roots an unreadable folder is skipped, as one project among many.
fn find(home: &Path, workspaces: &[String]) -> Result<GitRepositories, String> {
    let mut found: HashMap<String, bool> = HashMap::new();
    for workspace in workspaces {
        if let Some(dir) = common_dir_containing(Path::new(workspace)) {
            found.insert(dir, true);
        }
    }
    for dir in projects(home)?.into_iter().chain(archon_worktrees(home)?) {
        found.entry(dir).or_insert(false);
    }
    let mut repositories: Vec<GitRepository> = found
        .into_iter()
        .map(|(common_dir, is_workspace)| GitRepository {
            common_dir,
            is_workspace,
        })
        .collect();
    repositories
        .sort_by(|a, b| (!a.is_workspace, &a.common_dir).cmp(&(!b.is_workspace, &b.common_dir)));
    Ok(GitRepositories { repositories })
}

/// A root's subfolders: none when it is not there, refused when it cannot be read.
fn root_subfolders(root: &Path, including_hidden: bool) -> Result<Vec<PathBuf>, String> {
    match fs::read_dir(root) {
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(vec![]),
        Err(e) => Err(format!(
            "cannot look for repositories in {}: {e}",
            root.display()
        )),
        Ok(_) => Ok(subfolders(root, including_hidden)),
    }
}

fn projects(home: &Path) -> Result<Vec<String>, String> {
    let root = home.join("Projects");
    if let Some(dir) = common_dir_of(&root) {
        return Ok(vec![dir]);
    }
    let mut found = Vec::new();
    let mut level = root_subfolders(&root, false)?;
    for _ in 1..=PROJECT_DEPTH {
        if level.is_empty() {
            break;
        }
        let mut next = Vec::new();
        for folder in level {
            match common_dir_of(&folder) {
                Some(dir) => found.push(dir),
                None => next.extend(subfolders(&folder, false)),
            }
        }
        level = next;
    }
    Ok(found)
}

fn archon_worktrees(home: &Path) -> Result<Vec<String>, String> {
    let homes = root_subfolders(home, true)?.into_iter().filter(|h| {
        h.file_name()
            .is_some_and(|n| n.to_string_lossy().starts_with(".archon"))
    });
    let roots = homes.flat_map(|archon| {
        subfolders(&archon.join("workspaces"), false)
            .into_iter()
            .flat_map(|owner| subfolders(&owner, false))
            .map(|repo| repo.join("worktrees"))
    });
    // Archon nests a worktree one or two folders down: `worktrees/<prefix>/<name>`.
    Ok(roots
        .flat_map(|root| subfolders(&root, false))
        .flat_map(|child| match common_dir_of(&child) {
            Some(dir) => vec![dir],
            None => subfolders(&child, false)
                .iter()
                .filter_map(|c| common_dir_of(c))
                .collect(),
        })
        .collect())
}

/// The common git directory of the checkout at `folder` or of any folder above it.
pub fn common_dir_containing(folder: &Path) -> Option<String> {
    let mut folder = PathBuf::from(StandardPath::new(&folder.to_string_lossy()).ok()?.as_str());
    loop {
        if let Some(dir) = common_dir_of(&folder) {
            return Some(dir);
        }
        if !folder.pop() {
            return None;
        }
    }
}

/// The common git directory of the checkout whose root is `folder`, or `None` when it is not
/// one. A main checkout's `.git` is a directory and is the answer. A linked worktree's `.git` is
/// a file, `gitdir: <repo>/.git/worktrees/<name>`, and that directory names the common one in its
/// `commondir` file; without one (a submodule) it is its own.
fn common_dir_of(folder: &Path) -> Option<String> {
    let dot_git = folder.join(".git");
    let meta = fs::metadata(&dot_git).ok()?;
    if meta.is_dir() {
        return Some(canonical(&dot_git));
    }
    let text = fs::read_to_string(&dot_git).ok()?;
    let git_dir = folder.join(text.lines().next()?.strip_prefix("gitdir: ")?);
    match fs::read_to_string(git_dir.join("commondir")) {
        Ok(common) => Some(canonical(&git_dir.join(common.trim()))),
        // No `commondir` is a submodule, its own common directory; one benchd cannot read is
        // skipped rather than guessed.
        Err(e) if e.kind() == ErrorKind::NotFound => Some(canonical(&git_dir)),
        Err(_) => None,
    }
}

/// Resolved through symlinks, so one repository reached two ways is one entry; a path that no
/// longer resolves (a stale linked worktree's) is still collapsed lexically, `..` and all.
fn canonical(path: &Path) -> String {
    fs::canonicalize(path).map_or_else(
        |_| {
            let raw = path.display().to_string();
            StandardPath::new(&raw).map_or(raw, |p| p.as_str().to_string())
        },
        |resolved| resolved.display().to_string(),
    )
}

/// Real folders only: no symlinks (a symlinked checkout is found where it lives), no hidden ones
/// unless asked, and none of `SKIPPED`.
fn subfolders(folder: &Path, including_hidden: bool) -> Vec<PathBuf> {
    let Ok(children) = fs::read_dir(folder) else {
        return vec![];
    };
    let mut found: Vec<PathBuf> = children
        .filter_map(Result::ok)
        .filter(|child| {
            let name = child.file_name().to_string_lossy().to_string();
            (including_hidden || !name.starts_with('.'))
                && !SKIPPED.contains(&name.as_str())
                && child.file_type().is_ok_and(|t| t.is_dir())
        })
        .map(|child| child.path())
        .collect();
    found.sort();
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Scratch(PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn scratch(label: &str) -> Scratch {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "benchd-repos-{label}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        Scratch(fs::canonicalize(&dir).unwrap())
    }

    fn git(args: &[&str], dir: &Path) {
        let out = std::process::Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@example.com")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@example.com")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    fn repo(path: &Path) -> PathBuf {
        fs::create_dir_all(path).unwrap();
        git(&["init", "-q", "-b", "main"], path);
        fs::write(path.join("a.txt"), "a").unwrap();
        git(&["add", "."], path);
        git(&["commit", "-q", "-m", "first"], path);
        path.to_path_buf()
    }

    /// helm's `testDiscoveryFindsProjectsArchonWorktreesAndWorkspacesOnce`, moved to the side
    /// with the disk: projects under the depth bound, not under `node_modules`; an Archon worktree
    /// leading back to a repository outside `~/Projects`; a workspace in a linked worktree marks
    /// its repository; one repository reached twice is one entry.
    #[test]
    fn finds_projects_archon_worktrees_and_workspaces_once() {
        let s = scratch("find");
        let home = s.0.join("home");
        let app = repo(&home.join("Projects/acme/app"));
        git(
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                "feature",
                ".worktrees/feature",
            ],
            &app,
        );
        let solo = home.join("Projects/solo");
        fs::create_dir_all(&solo).unwrap();
        git(&["init", "-q", "-b", "main"], &solo);
        let vendored = home.join("Projects/web/node_modules/pkg");
        fs::create_dir_all(&vendored).unwrap();
        git(&["init", "-q"], &vendored);
        let deep = home.join("Projects/a/b/c/d/e/deep");
        fs::create_dir_all(&deep).unwrap();
        git(&["init", "-q"], &deep);
        let lib = repo(&s.0.join("elsewhere/lib"));
        let archon = home.join(".archon-test/workspaces/owner/lib/worktrees/archon/task-x");
        fs::create_dir_all(archon.parent().unwrap()).unwrap();
        git(
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                "archon/task-x",
                archon.to_str().unwrap(),
            ],
            &lib,
        );
        let app_archon = home.join(".archon/workspaces/o/app/worktrees/fix");
        fs::create_dir_all(app_archon.parent().unwrap()).unwrap();
        git(
            &[
                "worktree",
                "add",
                "-q",
                "-b",
                "fix",
                app_archon.to_str().unwrap(),
            ],
            &app,
        );

        let found = find(
            &home,
            &[app.join(".worktrees/feature").display().to_string()],
        )
        .unwrap();
        let entry = |dir: &Path, is_workspace| GitRepository {
            common_dir: dir.join(".git").display().to_string(),
            is_workspace,
        };
        assert_eq!(
            found.repositories,
            vec![entry(&app, true), entry(&lib, false), entry(&solo, false)],
            "node_modules and anything below the depth bound are not searched"
        );
    }

    /// A search root benchd cannot read refuses the answer, so the drawer says it could not look
    /// rather than "No worktrees found"; a root that is not there is simply empty.
    #[test]
    fn an_unreadable_projects_folder_refuses_and_a_missing_one_is_empty() {
        use std::os::unix::fs::PermissionsExt;
        let s = scratch("roots");
        let home = s.0.join("home");
        fs::create_dir_all(&home).unwrap();
        assert!(find(&home, &[]).unwrap().repositories.is_empty());

        let projects = home.join("Projects");
        fs::create_dir(&projects).unwrap();
        fs::set_permissions(&projects, fs::Permissions::from_mode(0o000)).unwrap();
        let refused = find(&home, &[]);
        fs::set_permissions(&projects, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(
            refused
                .unwrap_err()
                .contains("cannot look for repositories")
        );
    }

    #[test]
    fn exists_answers_the_subset_there_and_refuses_what_it_cannot_look_at() {
        let s = scratch("exists");
        let file = s.0.join("file");
        fs::write(&file, "x").unwrap();
        std::os::unix::fs::symlink(s.0.join("nowhere"), s.0.join("broken")).unwrap();
        let p = |p: &Path| p.display().to_string();
        let answer = exists(&json!({ "paths": [
            p(&s.0), p(&file), p(&s.0.join("gone")), p(&file.join("under-a-file")), p(&s.0.join("broken"))
        ]}))
        .unwrap();
        assert_eq!(answer["existing"], json!([p(&s.0), p(&file)]));
        assert!(exists(&json!({ "paths": ["relative"] })).is_err());

        // A folder benchd may not search: "could not look", never "absent".
        use std::os::unix::fs::PermissionsExt;
        let locked = s.0.join("locked");
        fs::create_dir(&locked).unwrap();
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
        let refused = exists(&json!({ "paths": [p(&locked.join("inside"))] }));
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(refused.unwrap_err().contains("cannot tell"));
    }
}
