//! Which workspace a spawned agent's pane goes in: its project's (#645). The operator's rule:
//! "when an agent spawns an agent it spawns into existing workspaces, isolation is in worktrees
//! not workspaces." So an agent working in `<repo>/.worktrees/<name>` shows up in `<repo>`'s
//! workspace, and the bench gets one workspace per project rather than one per agent.
//!
//! Only placement changes: the agent still runs in its own cwd.

use crate::Core;
use crate::commands::common_dir_containing;
use bench_doc::StandardPath;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// The workspace for a pane working in `cwd`. The open workspaces are read under the lock and
/// the disk outside it.
pub fn workspace(core: &Arc<Mutex<Core>>, cwd: &str) -> Result<StandardPath, String> {
    let open: Vec<StandardPath> = core
        .lock()
        .unwrap()
        .bench
        .document
        .workspaces()
        .iter()
        .map(|w| w.path.clone())
        .collect();
    workspace_for(Path::new(cwd), &open)
}

/// The open workspace that is the same folder as `cwd`'s project, else the project's folder,
/// which the spawn then opens. "The same folder" is compared on disk, so a workspace spelled
/// `/Users/x/Projects/app` is found for `/users/x/projects/app` on a case-insensitive volume,
/// or through a symlink; how an open workspace is spelled never changes.
fn workspace_for(cwd: &Path, open: &[StandardPath]) -> Result<StandardPath, String> {
    let project = project(cwd);
    if let Ok(folder) = fs::canonicalize(&project)
        && let Some(found) = open
            .iter()
            .find(|w| fs::canonicalize(w.as_str()).is_ok_and(|w| w == folder))
    {
        return Ok(found.clone());
    }
    StandardPath::new(&project.to_string_lossy())
}

/// The folder a cwd's work belongs to: the main checkout of the git repository it is in, read
/// from the disk as the Worktrees drawer reads it (`commands::common_dir_containing`), so a
/// linked worktree and a folder inside the main checkout both answer the main checkout, the
/// folder holding the common `.git`. Outside any repository, or in one with no main checkout
/// (a bare repository's worktree, a submodule), the cwd is its own project.
fn project(cwd: &Path) -> PathBuf {
    common_dir_containing(cwd)
        .map(PathBuf::from)
        .filter(|common| common.file_name().is_some_and(|n| n == ".git"))
        .and_then(|common| common.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| cwd.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Scratch(PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn scratch() -> Scratch {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "benchd-project-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        Scratch(fs::canonicalize(&dir).unwrap())
    }

    /// A main checkout at `main` with a linked worktree at `worktree`, laid out as `git worktree
    /// add` lays them out: the worktree's `.git` file names its git dir, whose `commondir` leads
    /// back to `main/.git`.
    fn repo_with_worktree(main: &Path, worktree: &Path) {
        let git_dir = main.join(".git/worktrees/wt");
        fs::create_dir_all(&git_dir).unwrap();
        fs::write(git_dir.join("commondir"), "../..\n").unwrap();
        fs::create_dir_all(worktree).unwrap();
        fs::write(
            worktree.join(".git"),
            format!("gitdir: {}\n", git_dir.display()),
        )
        .unwrap();
    }

    fn path(p: &Path) -> StandardPath {
        StandardPath::new(&p.to_string_lossy()).unwrap()
    }

    #[test]
    fn a_worktree_and_a_folder_of_the_main_checkout_answer_the_main_checkout() {
        let s = scratch();
        let main = s.0.join("app");
        let worktree = main.join(".worktrees/feature");
        repo_with_worktree(&main, &worktree);
        fs::create_dir_all(main.join("src")).unwrap();
        fs::create_dir_all(worktree.join("src")).unwrap();

        for cwd in [&main, &worktree, &worktree.join("src"), &main.join("src")] {
            assert_eq!(workspace_for(cwd, &[]).unwrap(), path(&main), "{cwd:?}");
        }
    }

    #[test]
    fn a_folder_outside_git_is_its_own_project() {
        let s = scratch();
        let notes = s.0.join("notes");
        fs::create_dir_all(&notes).unwrap();
        assert_eq!(workspace_for(&notes, &[]).unwrap(), path(&notes));
    }

    /// The open workspace keeps its spelling; the spawn's own spelling of that folder finds it.
    #[test]
    fn another_spelling_of_an_open_workspace_finds_it() {
        let s = scratch();
        let app = s.0.join("App");
        fs::create_dir_all(&app).unwrap();
        let link = s.0.join("link");
        std::os::unix::fs::symlink(&app, &link).unwrap();
        let open = [path(&s.0.join("elsewhere")), path(&app)];

        assert_eq!(workspace_for(&link, &open).unwrap(), path(&app));

        // Case folds only where the volume does, as macOS's usually does.
        let lower = s.0.join("app");
        if lower.is_dir() {
            assert_eq!(workspace_for(&lower, &open).unwrap(), path(&app));
        }
    }

    #[test]
    fn a_worktree_finds_its_main_checkouts_open_workspace_through_a_symlink() {
        let s = scratch();
        let main = s.0.join("app");
        let worktree = main.join(".worktrees/feature");
        repo_with_worktree(&main, &worktree);
        let link = s.0.join("link");
        std::os::unix::fs::symlink(&main, &link).unwrap();
        let open = [path(&link)];

        assert_eq!(workspace_for(&worktree, &open).unwrap(), path(&link));
    }

    /// A submodule's git dir is `<parent>/.git/modules/<name>`, not a `.git`: it is its own
    /// project, not its parent repository's.
    #[test]
    fn a_submodule_is_its_own_project() {
        let s = scratch();
        let parent = s.0.join("parent");
        let module_git = parent.join(".git/modules/lib");
        fs::create_dir_all(&module_git).unwrap();
        let module = parent.join("lib");
        fs::create_dir_all(&module).unwrap();
        fs::write(
            module.join(".git"),
            format!("gitdir: {}\n", module_git.display()),
        )
        .unwrap();
        assert_eq!(workspace_for(&module, &[]).unwrap(), path(&module));
    }
}
