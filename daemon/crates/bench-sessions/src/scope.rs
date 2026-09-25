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
}

impl Workspace {
    /// Resolve any path inside a workspace. Walks up to the nearest `.git`: a directory
    /// names the repo root; a file (a linked worktree) is followed through `gitdir` and
    /// `commondir` to the repo it belongs to. No `.git` at all is a workspace of one
    /// directory. Paths stay lexical — symlinks are not resolved, because the cwds they are
    /// compared with were not resolved either.
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
        Workspace {
            root: only.clone(),
            roots: vec![only],
        }
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
        Workspace { root, roots }
    }

    /// The root `cwd` is in — the most specific one, since a worktree under `.worktrees/`
    /// is also under the repo root.
    pub fn root_of(&self, cwd: &str) -> Option<&str> {
        self.roots
            .iter()
            .filter(|r| within(cwd, r))
            .max_by_key(|r| r.len())
            .map(String::as_str)
    }
}

fn within(cwd: &str, root: &str) -> bool {
    cwd == root
        || (cwd.starts_with(root) && cwd.as_bytes().get(root.len()) == Some(&b'/'))
        || root == "/"
}

/// A linked worktree's `.git` file says `gitdir: <repo>/.git/worktrees/<name>`, and that
/// directory's `commondir` (usually `../..`) leads back to `<repo>/.git`.
fn common_dir_of_worktree(dotgit_file: &Path) -> Option<PathBuf> {
    let text = fs::read_to_string(dotgit_file).ok()?;
    let gitdir = text.trim().strip_prefix("gitdir:")?.trim();
    let gitdir = if gitdir.starts_with('/') {
        PathBuf::from(gitdir)
    } else {
        dotgit_file.parent()?.join(gitdir)
    };
    let common = fs::read_to_string(gitdir.join("commondir")).ok()?;
    let common = common.trim();
    let common = if common.starts_with('/') {
        PathBuf::from(common)
    } else {
        gitdir.join(common)
    };
    Some(PathBuf::from(lexical(&common)))
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
        let ws = Workspace {
            root: "/r/helm".into(),
            roots: vec!["/r/helm".into(), "/r/helm/.worktrees/a".into()],
        };
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
}
