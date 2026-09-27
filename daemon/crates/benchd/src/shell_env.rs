//! What a terminal pane's shell starts with (M5b): the environment helm's own panes gave their
//! shells, and Ghostty's shell integration.
//!
//! Until M5b helm's Ghostty spawned each pane's shell, and two things came with that which a shell
//! benchd starts would otherwise lose:
//!
//! - **The pane's environment** (helm's `PaneEnvironment`): `HELM_PANE` names the pane, which is
//!   how an agent the operator starts in the shell claims its address; `COLORTERM`/`TERM_PROGRAM`
//!   say truecolor Ghostty, because `TERM` is pinned to `xterm-256color`; the root `bench` should
//!   reach; and none of the `CLAUDE*`/`PI_*` variables whatever started benchd carried, which
//!   would hand every agent in the pane somebody else's session identity (helm #139). A shell gets
//!   no `BENCH_SESSION`/`BENCH_HANDLE`: those mark an agent benchd spawned.
//! - **Shell integration**: OSC 133 prompt marks (⌘↑/⌘↓, command-finished), OSC 7, the title.
//!   Ghostty injects it only into shells it spawns, so benchd injects it the way Ghostty does
//!   (`src/termio/shell_integration.zig`): fish through `XDG_DATA_DIRS`, zsh through `ZDOTDIR`.
//!   The scripts are helm's vendored copy, from the same Ghostty commit as helm's renderer, built
//!   into benchd and written under the root. bash is not injected: Ghostty needs to rewrite bash's
//!   command line for it, and nothing here runs bash as a login shell today.

use bench_session::Env;
use std::fs;
use std::path::{Path, PathBuf};

const INTEGRATION: &[(&str, &str)] = &[
    (
        "fish/vendor_conf.d/ghostty-shell-integration.fish",
        include_str!(
            "../../../../Sources/Helm/Resources/ghostty/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish"
        ),
    ),
    (
        "zsh/.zshenv",
        include_str!("../../../../Sources/Helm/Resources/ghostty/shell-integration/zsh/.zshenv"),
    ),
    (
        "zsh/ghostty-integration",
        include_str!(
            "../../../../Sources/Helm/Resources/ghostty/shell-integration/zsh/ghostty-integration"
        ),
    ),
];

/// Ghostty's default `shell-integration-features`, in the order Ghostty writes them.
const FEATURES: &str = "cursor,path,title";

/// The resources directory under `root`, as `GHOSTTY_RESOURCES_DIR` names it.
pub fn resources_dir(root: &Path) -> PathBuf {
    root.join("ghostty")
}

/// Write the integration scripts under the root, replacing any that differ (a new benchd may
/// carry a newer Ghostty's). Called at boot.
pub fn install(root: &Path) -> Result<(), String> {
    let base = resources_dir(root).join("shell-integration");
    for (relative, text) in INTEGRATION {
        let path = base.join(relative);
        if fs::read_to_string(&path).is_ok_and(|current| current == *text) {
            continue;
        }
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))?;
    }
    Ok(())
}

/// The environment a terminal pane's shell starts with: `pane`'s identity, the root `bench`
/// reaches, and the integration for `shell` (a path; only its name is read).
pub fn for_pane(root: &Path, pane: &str, shell: &str) -> Env {
    let resources = resources_dir(root);
    let integration = resources.join("shell-integration");
    let mut set = vec![
        ("HELM_PANE".to_string(), pane.to_string()),
        ("COLORTERM".to_string(), "truecolor".to_string()),
        ("TERM_PROGRAM".to_string(), "ghostty".to_string()),
        ("BENCH_DIR".to_string(), root.display().to_string()),
        (
            "GHOSTTY_RESOURCES_DIR".to_string(),
            resources.display().to_string(),
        ),
        ("GHOSTTY_SHELL_FEATURES".to_string(), FEATURES.to_string()),
    ];
    let name = Path::new(shell)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    match name.as_str() {
        "fish" => {
            let dirs = std::env::var("XDG_DATA_DIRS")
                .ok()
                .filter(|d| !d.is_empty())
                .unwrap_or_else(|| "/usr/local/share:/usr/share".to_string());
            set.push((
                "GHOSTTY_SHELL_INTEGRATION_XDG_DIR".to_string(),
                integration.display().to_string(),
            ));
            set.push((
                "XDG_DATA_DIRS".to_string(),
                format!("{}:{dirs}", integration.display()),
            ));
        }
        "zsh" => {
            if let Ok(old) = std::env::var("ZDOTDIR") {
                set.push(("GHOSTTY_ZSH_ZDOTDIR".to_string(), old));
            }
            set.push((
                "ZDOTDIR".to_string(),
                integration.join("zsh").display().to_string(),
            ));
        }
        _ => {}
    }
    let remove = std::env::vars()
        .map(|(k, _)| k)
        .filter(|k| k.starts_with("CLAUDE") || k.starts_with("PI_") || k.starts_with("BENCH_"))
        .filter(|k| k != "BENCH_DIR")
        .collect();
    Env { set, remove }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fish_and_zsh_are_pointed_at_the_installed_scripts() {
        let root = std::env::temp_dir().join(format!("bse-{}", std::process::id()));
        install(&root).unwrap();
        let value = |env: &Env, key: &str| {
            env.set
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.clone())
        };
        let fish = for_pane(&root, "p1", "/opt/homebrew/bin/fish");
        let xdg = value(&fish, "GHOSTTY_SHELL_INTEGRATION_XDG_DIR").unwrap();
        assert!(Path::new(&xdg).join("fish/vendor_conf.d").is_dir());
        assert!(value(&fish, "XDG_DATA_DIRS").unwrap().starts_with(&xdg));
        assert_eq!(value(&fish, "HELM_PANE").as_deref(), Some("p1"));
        let zsh = for_pane(&root, "p1", "/bin/zsh");
        let zdotdir = value(&zsh, "ZDOTDIR").unwrap();
        assert!(Path::new(&zdotdir).join(".zshenv").is_file());
        assert_eq!(value(&zsh, "XDG_DATA_DIRS"), None);
        let sh = for_pane(&root, "p1", "/bin/sh");
        assert_eq!(value(&sh, "ZDOTDIR"), None);
        let _ = fs::remove_dir_all(&root);
    }
}
