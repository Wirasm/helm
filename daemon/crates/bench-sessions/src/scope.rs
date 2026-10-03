//! Which sessions belong to a workspace: those whose cwd is inside the repo or one of the
//! worktrees git knows about. Worktrees are read from `.git/worktrees/*/gitdir`, so a worktree
//! outside the repo directory (`~/.sasha/merge-queue`) is still in scope.

use bench_doc::StandardPath;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Workspace {
    /// The main worktree: the repo root.
    pub root: String,
    /// `root` plus every linked worktree, each in one lexical spelling.
    pub roots: Vec<String>,
    /// Each of `roots` as the disk spells it, where it still exists: what a cwd spelled another
    /// way is compared with.
    real: Vec<Option<PathBuf>>,
}

impl Workspace {
    /// Resolve any path inside a workspace. Walks up to the nearest `.git`: a directory
    /// names the repo root; a file (a linked worktree) is followed through `gitdir` and
    /// `commondir` to the repo it belongs to. No `.git` at all is a workspace of one
    /// directory. The roots keep their lexical spelling, which is what rows report;
    /// [`Workspace::root_of`] compares on disk only when a cwd's spelling matches none.
    pub fn resolve(path: &StandardPath) -> Workspace {
        let start = PathBuf::from(path.as_str());
        let mut dir: Option<&Path> = Some(&start);
        while let Some(d) = dir {
            let dotgit = d.join(".git");
            if dotgit.is_dir() {
                return Workspace::from_common(d, &dotgit);
            }
            if dotgit.is_file()
                && let Some(common) = common_dir_of_worktree(&dotgit)
                && let Some(repo) = common.parent()
            {
                return Workspace::from_common(repo, &common);
            }
            dir = d.parent();
        }
        let only = path.as_str().to_string();
        Workspace::new(only.clone(), vec![only])
    }

    fn new(root: String, roots: Vec<String>) -> Workspace {
        let real = roots.iter().map(|r| fs::canonicalize(r).ok()).collect();
        Workspace { root, roots, real }
    }

    fn from_common(repo: &Path, common: &Path) -> Workspace {
        let root = lexical(repo);
        let mut roots = vec![root.clone()];
        for entry in fs::read_dir(common.join("worktrees"))
            .into_iter()
            .flatten()
            .flatten()
        {
            let Ok(gitdir) = fs::read_to_string(entry.path().join("gitdir")) else {
                continue;
            };
            let worktree = gitdir.trim();
            let worktree = worktree.strip_suffix("/.git").unwrap_or(worktree);
            if let Ok(p) = StandardPath::new(worktree)
                && !roots.contains(&p.as_str().to_string())
            {
                roots.push(p.as_str().to_string());
            }
        }
        Workspace::new(root, roots)
    }

    /// The root `cwd` is in — the most specific one, since a worktree under `.worktrees/`
    /// is also under the repo root. A cwd in none by its spelling is compared on disk: benchd
    /// puts a pane in the workspace that is its project's folder under any spelling (case,
    /// symlinks, #645), so its session belongs to that workspace's list too.
    pub fn root_of(&self, cwd: &str) -> Option<&str> {
        let lexical = self
            .roots
            .iter()
            .filter(|r| within(cwd, r))
            .max_by_key(|r| r.len());
        lexical
            .or_else(|| self.root_on_disk(cwd))
            .map(String::as_str)
    }

    fn root_on_disk(&self, cwd: &str) -> Option<&String> {
        let cwd = fs::canonicalize(cwd).ok()?;
        self.roots
            .iter()
            .zip(&self.real)
            .filter_map(|(root, real)| Some((root, real.as_ref()?)))
            .filter(|(_, real)| cwd.starts_with(real))
            .max_by_key(|(_, real)| real.as_os_str().len())
            .map(|(root, _)| root)
    }
}

fn within(cwd: &str, root: &str) -> bool {
    cwd == root
        || (cwd.starts_with(root) && cwd.as_bytes().get(root.len()) == Some(&b'/'))
        || root == "/"
}

/// The short branch checked out in `root`, read from git's own files. A detached or unreadable
/// HEAD has no branch.
pub(crate) fn branch(root: &str) -> Option<String> {
    let dotgit = Path::new(root).join(".git");
    let gitdir = if dotgit.is_dir() {
        dotgit
    } else if dotgit.is_file() {
        git_dir_of_worktree(&dotgit)?
    } else {
        return None;
    };
    let head = fs::read_to_string(gitdir.join("HEAD")).ok()?;
    let name = head.trim().strip_prefix("ref: refs/heads/")?;
    (!name.is_empty()).then(|| name.to_string())
}

/// A linked worktree's `.git` file says `gitdir: <repo>/.git/worktrees/<name>`, and that
/// directory's `commondir` (usually `../..`) leads back to `<repo>/.git`.
fn common_dir_of_worktree(dotgit_file: &Path) -> Option<PathBuf> {
    let gitdir = git_dir_of_worktree(dotgit_file)?;
    let common = fs::read_to_string(gitdir.join("commondir")).ok()?;
    let common = common.trim();
    let common = if common.starts_with('/') {
        PathBuf::from(common)
    } else {
        gitdir.join(common)
    };
    Some(PathBuf::from(lexical(&common)))
}

fn git_dir_of_worktree(dotgit_file: &Path) -> Option<PathBuf> {
    let text = fs::read_to_string(dotgit_file).ok()?;
    let gitdir = text.trim().strip_prefix("gitdir:")?.trim();
    Some(if gitdir.starts_with('/') {
        PathBuf::from(gitdir)
    } else {
        dotgit_file.parent()?.join(gitdir)
    })
}

fn lexical(p: &Path) -> String {
    StandardPath::new(&p.to_string_lossy())
        .map(|s| s.as_str().to_string())
        .unwrap_or_else(|_| p.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cwd_is_in_the_most_specific_root_and_a_sibling_prefix_is_not_in_scope() {
        let ws = Workspace::new(
            "/r/helm".into(),
            vec!["/r/helm".into(), "/r/helm/.worktrees/a".into()],
        );
        assert_eq!(
            ws.root_of("/r/helm/.worktrees/a/src"),
            Some("/r/helm/.worktrees/a")
        );
        assert_eq!(ws.root_of("/r/helm/daemon"), Some("/r/helm"));
        assert_eq!(
            ws.root_of("/r/helm-other"),
            None,
            "a name prefix is not a path prefix"
        );
        assert_eq!(ws.root_of("/r"), None);
    }

    /// A cwd spelled through a symlink (and, where the volume folds case, in another case) is in
    /// the root that is that folder on disk, as benchd's placement puts its pane (#645).
    #[test]
    fn a_cwd_spelled_another_way_is_in_the_root_that_is_its_folder() {
        struct Scratch(PathBuf);
        impl Drop for Scratch {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let scratch =
            Scratch(std::env::temp_dir().join(format!("bench-scope-{}", std::process::id())));
        let dir = &scratch.0;
        let repo = dir.join("App");
        fs::create_dir_all(repo.join("src")).unwrap();
        let repo = fs::canonicalize(&repo).unwrap();
        std::os::unix::fs::symlink(&repo, dir.join("link")).unwrap();
        let root = repo.display().to_string();
        let ws = Workspace::new(root.clone(), vec![root.clone()]);

        let linked = dir.join("link/src").display().to_string();
        assert_eq!(ws.root_of(&linked), Some(root.as_str()));
        let other_case = dir.join("app/src");
        if other_case.is_dir() {
            assert_eq!(
                ws.root_of(&other_case.display().to_string()),
                Some(root.as_str())
            );
        }
        assert_eq!(ws.root_of(&dir.display().to_string()), None);
    }
}
