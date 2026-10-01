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

/// The git main repository `dir` belongs to, as codex resolves it for trust
/// (`git-utils/src/trust.rs`, rust-v0.159.3), without running git. The nearest ancestor with a
/// `.git`: a directory (with `HEAD`) makes that ancestor the root; a `.git` file must point into
/// `<common>/worktrees/<name>` and be named back by that entry's `gitdir`, and the root is the
/// parent of `<common>`, spelled as the `.git` file spells it (codex keeps that spelling as the
/// key). The backlink is what stops a `.git` file anyone can write from borrowing a trusted
/// repository's trust. Any other `.git` file, a submodule's, has no root, as in codex.
fn git_main_root(dir: &Path) -> Option<PathBuf> {
    let checkout = dir.ancestors().find(|a| {
        let dot = a.join(".git");
        dot.is_file() || dot.join("HEAD").exists()
    })?;
    let dot_git = checkout.join(".git");
    if dot_git.is_dir() {
        return Some(checkout.to_path_buf());
    }
    let text = std::fs::read_to_string(&dot_git).ok()?;
    let git_dir = checkout.join(text.trim().strip_prefix("gitdir:")?.trim());
    let canonical = git_dir.canonicalize().ok()?;
    if canonical.parent()?.file_name()? != "worktrees" {
        return None;
    }
    let backlink = std::fs::read_to_string(canonical.join("gitdir")).ok()?;
    let registered = canonical.join(backlink.trim()).canonicalize().ok()?;
    if registered != dot_git.canonicalize().ok()? {
        return None;
    }
    Some(git_dir.parent()?.parent()?.parent()?.to_path_buf())
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
}
