//! Whether the operator trusts the folder a codex is spawned in, by codex's own rule for a
//! plain `codex`: the folder's own `[projects."<path>"]` entry, else the entry of the git main
//! repository it belongs to, a linked worktree followed back to its main checkout. A served
//! codex (`--remote … -C <cwd>`, how benchd runs every codex) checks the exact folder only
//! (codex `tui/src/config_update.rs`, rust-v0.159.3), so a worktree of a repo the operator
//! trusts would ask. benchd answers the second lookup and hands codex the result
//! ([`bench_session::codex_folder_trust`]); it never trusts what plain codex would not.
//!
//! Read-only: the operator's `config.toml` is never written.

use std::path::{Path, PathBuf};

/// Whether the app-server should be told to trust `cwd`: it has no entry of its own in
/// `<home>/.codex/config.toml`, and its git main repository is `trusted` there. A folder with
/// its own entry gets nothing, since a served codex finds that exact key itself and an
/// `untrusted` there must win. `home`, not `CODEX_HOME`: every session benchd starts runs
/// without `CODEX_HOME` (`bench_session::pty`), so its codex reads the config under `HOME`.
/// A missing or unparsable config trusts nothing.
pub fn operator_trusts(cwd: &Path, home: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(home.join(".codex/config.toml")) else {
        return false;
    };
    let Ok(config) = text.parse::<toml::Table>() else {
        return false;
    };
    trust_level(&config, cwd).is_none()
        && git_main_root(cwd).is_some_and(|root| trust_level(&config, &root) == Some("trusted"))
}

/// `projects."<path>".trust_level`, by exact key, as codex looks it up.
fn trust_level<'a>(config: &'a toml::Table, path: &Path) -> Option<&'a str> {
    config
        .get("projects")?
        .get(path.to_str()?)?
        .get("trust_level")?
        .as_str()
}

/// The largest git metadata file read, as codex caps it: a `.git` file, `gitdir` or `commondir`
/// is one line.
const MAX_GIT_METADATA_BYTES: u64 = 64 * 1024;

/// The git main repository `dir` belongs to, as codex resolves it for trust
/// (`git-utils/src/trust.rs`, rust-v0.159.3), without running git, and refusing everything codex
/// refuses: one check fewer would trust a folder a plain codex asks about. The nearest ancestor
/// with a `.git`: a directory (with `HEAD`) makes that ancestor the root. A `.git` file (never a
/// symlink) must point at a real directory `<common>/worktrees/<name>` whose `gitdir` names this
/// checkout back and whose `commondir` is `<common>`, and the root, the parent of `<common>` as
/// the `.git` file spells it (codex keeps that spelling as the key), must own `<common>` through
/// its own `.git`. The backlink stops a `.git` file anyone can write from borrowing a trusted
/// repository's trust; the ownership check stops a bare repository's worktree from borrowing the
/// trust of the folder the bare repository sits in. Any other `.git` file, a submodule's, has no
/// root.
fn git_main_root(dir: &Path) -> Option<PathBuf> {
    let checkout = dir.ancestors().find(|a| {
        let dot = a.join(".git");
        dot.is_file() || dot.join("HEAD").exists()
    })?;
    let dot_git = checkout.join(".git");
    if dot_git.is_dir() {
        return Some(checkout.to_path_buf());
    }
    let git_dir = gitdir_of(&dot_git)?;
    let meta = std::fs::symlink_metadata(&git_dir).ok()?;
    if !meta.is_dir() {
        return None;
    }
    let canonical = git_dir.canonicalize().ok()?;
    let worktrees = canonical.parent()?;
    if worktrees.file_name()? != "worktrees" {
        return None;
    }
    let common = worktrees.parent()?;
    let registered = canonical.join(read_small(&canonical.join("gitdir"))?.trim());
    if registered.file_name()? != ".git"
        || registered.parent()?.canonicalize().ok()? != checkout.canonicalize().ok()?
    {
        return None;
    }
    let commondir = canonical.join(read_small(&canonical.join("commondir"))?.trim());
    if commondir.canonicalize().ok()? != common {
        return None;
    }
    let main_root = git_dir.parent()?.parent()?.parent()?;
    let main_dot_git = main_root.join(".git");
    let main_git_dir = if main_dot_git.is_dir() {
        main_dot_git
    } else {
        gitdir_of(&main_dot_git)?
    };
    (main_git_dir.canonicalize().ok()? == common).then(|| main_root.to_path_buf())
}

/// Where a `.git` file points (`gitdir: <path>`, relative to its folder). `None` for a symlink, a
/// file over [`MAX_GIT_METADATA_BYTES`], or anything else.
fn gitdir_of(dot_git: &Path) -> Option<PathBuf> {
    let meta = std::fs::symlink_metadata(dot_git).ok()?;
    if !meta.is_file() {
        return None;
    }
    let text = read_small(dot_git)?;
    let target = text.trim().strip_prefix("gitdir:")?.trim();
    (!target.is_empty()).then(|| dot_git.parent().unwrap_or(dot_git).join(target))
}

/// A git metadata file's text, unless it is over [`MAX_GIT_METADATA_BYTES`].
fn read_small(path: &Path) -> Option<String> {
    let meta = std::fs::metadata(path).ok()?;
    (meta.len() <= MAX_GIT_METADATA_BYTES)
        .then(|| std::fs::read_to_string(path).ok())
        .flatten()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    /// A temp dir holding `repo` (a real git repo with one commit) and its linked worktree at
    /// `repo/.worktrees/wt`, made by git itself so the `.git` file and backlink are git's own.
    fn repo(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("benchd-codex-trust-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let dir = dir.canonicalize().unwrap();
        let repo = dir.join("repo");
        std::fs::create_dir_all(repo.join("sub/deep")).unwrap();
        let git = |args: &[&str]| {
            let out = Command::new("git")
                .args(["-c", "user.name=t", "-c", "user.email=t@t"])
                .args(args)
                .current_dir(&repo)
                .output()
                .unwrap();
            assert!(out.status.success(), "{args:?}: {out:?}");
        };
        git(&["init", "-q"]);
        git(&["commit", "-q", "--allow-empty", "-m", "x"]);
        git(&["worktree", "add", "-q", ".worktrees/wt"]);
        dir
    }

    fn config(home: &Path, text: &str) {
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        std::fs::write(home.join(".codex/config.toml"), text).unwrap();
    }

    fn trusted(path: &Path) -> String {
        format!(
            "[projects.{:?}]\ntrust_level = \"trusted\"\n",
            path.display().to_string()
        )
    }

    #[test]
    fn a_worktree_or_subfolder_of_a_trusted_repo_is_trusted() {
        let dir = repo("trusted");
        let (repo, home) = (dir.join("repo"), dir.join("home"));
        config(&home, &trusted(&repo));
        for cwd in [repo.join(".worktrees/wt"), repo.join("sub/deep")] {
            assert!(operator_trusts(&cwd, &home), "{}", cwd.display());
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn nothing_is_trusted_that_plain_codex_would_ask_about() {
        let dir = repo("untrusted");
        let (repo, home) = (dir.join("repo"), dir.join("home"));
        let wt = repo.join(".worktrees/wt");
        // No config at all, then a config trusting something else.
        assert!(!operator_trusts(&wt, &home));
        config(&home, &trusted(&dir));
        assert!(
            !operator_trusts(&wt, &home),
            "a parent is not a prefix rule"
        );
        // The folder's own entry wins over its repository's, as in codex.
        config(
            &home,
            &format!(
                "{}[projects.{:?}]\ntrust_level = \"untrusted\"\n",
                trusted(&repo),
                wt.display().to_string()
            ),
        );
        assert!(!operator_trusts(&wt, &home));
        // A config that does not parse trusts nothing.
        config(&home, "[projects\n");
        assert!(!operator_trusts(&wt, &home));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_git_file_the_repository_does_not_name_back_borrows_no_trust() {
        let dir = repo("forged");
        let (repo, home) = (dir.join("repo"), dir.join("home"));
        config(&home, &trusted(&repo));
        // Points into the trusted repo's worktree entry, but that entry names `wt`, not this.
        let forged = dir.join("forged");
        std::fs::create_dir_all(&forged).unwrap();
        let entry = repo.join(".git/worktrees/wt");
        std::fs::write(
            forged.join(".git"),
            format!("gitdir: {}\n", entry.display()),
        )
        .unwrap();
        assert_eq!(git_main_root(&forged), None);
        assert!(!operator_trusts(&forged, &home));
        // A `.git` file outside any `worktrees` directory (a submodule's) has no root either.
        std::fs::write(
            forged.join(".git"),
            format!("gitdir: {}\n", repo.join(".git").display()),
        )
        .unwrap();
        assert_eq!(git_main_root(&forged), None);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_bare_repositorys_worktree_borrows_no_trust_from_the_folder_it_sits_in() {
        // `x/repo.git` is bare and `x/wt` its worktree: the common dir's parent is `x`, which owns
        // no repository, so a trusted `x` must not reach `wt`. Codex refuses it the same way.
        let dir = repo("bare");
        let (x, home) = (dir.join("x"), dir.join("home"));
        std::fs::create_dir_all(&x).unwrap();
        let git = |args: &[&str]| {
            let out = Command::new("git").args(args).output().unwrap();
            assert!(out.status.success(), "{args:?}: {out:?}");
        };
        let (bare, wt) = (x.join("repo.git"), x.join("wt"));
        git(&[
            "clone",
            "-q",
            "--bare",
            dir.join("repo").to_str().unwrap(),
            bare.to_str().unwrap(),
        ]);
        git(&[
            "-C",
            bare.to_str().unwrap(),
            "worktree",
            "add",
            "-q",
            wt.to_str().unwrap(),
        ]);
        config(&home, &trusted(&x));
        assert_eq!(git_main_root(&wt), None);
        assert!(!operator_trusts(&wt, &home));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
