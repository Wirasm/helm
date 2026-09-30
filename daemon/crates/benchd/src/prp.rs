//! prp's artifact stores and the paths the operator types, answered on benchd's machine (M5c,
//! helm #459): `prp/note`, `prp/stores`, `prp/artifacts` and `path/resolve`.
//!
//! `~/.prp` lives with the agents, which is benchd's machine, so this is the one place helm's
//! questions about it are answered. The wire types are `bench_wire::prp`.
//!
//! **The store a workspace belongs to is prp's own resolver's answer**, the block every prp skill
//! carries byte-identical (`prp-plan/SKILL.md`, "PRP store resolver (canonical …)"), ported here
//! rule for rule and pinned against the block itself by the conformance suite:
//!
//! ```sh
//! _gd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
//! case "$_gd" in */.git) _root="${_gd%/.git}" ;; "") _root="$PWD" ;; *) _root="$_gd" ;; esac
//! _root="$(cd "$_root" && pwd -P)"
//! _name="$(basename "$_root" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')"
//! _home="${PRP_HOME:-$HOME/.prp}"
//! _hit="$(grep -lsF "\"path\": \"$_root\"" "$_home"/*/project.json 2>/dev/null | head -1)"
//! PRP_DIR="${_hit%/project.json}"
//! [ -n "$PRP_DIR" ] || PRP_DIR="$_home/${_name:-project}-$(printf %s "$_root" | git hash-object --stdin | cut -c1-8)"
//! mkdir -p "$PRP_DIR"; [ -f "$PRP_DIR/project.json" ] || printf '{"path": "%s", "name": "%s"}\n' "$_root" "${_name:-project}" > "$PRP_DIR/project.json"
//! ```
//!
//! Two places refuse where the block would carry on: a workspace folder that does not exist (the
//! block's `cd` fails and it uses its own directory), and a `git` that does not answer within
//! `GIT_WAIT` or cannot hash (the block would mint `<name>-`). Either would put a note in a
//! store no agent will ever use.

use bench_doc::StandardPath;
use bench_wire::{
    NOTES_DIRECTORY, PathKind, PathResolveArgs, PathResolved, PrpArtifact, PrpArtifacts,
    PrpArtifactsArgs, PrpNote, PrpNoteArgs, PrpStore, PrpStores, PrpStoresArgs, is_renderable,
};
use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, UNIX_EPOCH};

/// How long one `git` run may take. Under helm's patience for `prp/note` (10 s), so a git that
/// hangs is benchd's sentence rather than helm's timeout.
const GIT_WAIT: Duration = Duration::from_secs(8);

/// `${PRP_HOME:-$HOME/.prp}`, from benchd's own environment: unset and empty both mean the
/// default, as `:-` does.
fn prp_home() -> Result<PathBuf, String> {
    let set = |name: &str| std::env::var(name).ok().filter(|v| !v.is_empty());
    if let Some(home) = set("PRP_HOME") {
        return Ok(PathBuf::from(home));
    }
    set("HOME")
        .map(|home| Path::new(&home).join(".prp"))
        .ok_or_else(|| "benchd has no HOME, so it has no ~/.prp".to_string())
}

/// `git <args>` in `cwd`, with `input` on stdin, bounded by `GIT_WAIT`. `Ok(None)` when git is
/// missing or says no (nonzero exit); `Err` only when it did not answer in time.
fn git(args: &[&str], cwd: &Path, input: Option<&str>) -> Result<Option<String>, String> {
    let mut child = match Command::new("git")
        .args(args)
        .current_dir(cwd)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(_) => return Ok(None),
    };
    if let (Some(text), Some(mut stdin)) = (input, child.stdin.take()) {
        // Dropped at the end of this block, which is the EOF `--stdin` waits for.
        let _ = stdin.write_all(text.as_bytes());
    }
    let deadline = Instant::now() + GIT_WAIT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(5)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "git {} did not answer within {} s in {}",
                    args.first().copied().unwrap_or_default(),
                    GIT_WAIT.as_secs(),
                    cwd.display()
                ));
            }
        }
    };
    let mut out = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        let _ = stdout.read_to_string(&mut out);
    }
    Ok(status
        .success()
        .then(|| out.trim_end_matches('\n').to_string()))
}

/// prp's name for a root: the basename lowercased, each run of anything outside `[a-z0-9]` one
/// `-`, dashes trimmed from both ends, and `project` when nothing is left. By bytes, as `tr`
/// does: a non-ASCII letter is outside the set.
fn slug(root: &Path) -> String {
    let base = root
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut out = String::new();
    let mut gap = false;
    for byte in base.bytes().map(|b| b.to_ascii_lowercase()) {
        if byte.is_ascii_lowercase() || byte.is_ascii_digit() {
            if gap && !out.is_empty() {
                out.push('-');
            }
            gap = false;
            out.push(char::from(byte));
        } else {
            gap = true;
        }
    }
    if out.is_empty() {
        "project".to_string()
    } else {
        out
    }
}

/// The directories under the prp home that `"$_home"/*/project.json` names, in order: hidden
/// ones are not matched by `*`. A home that does not exist has none.
fn store_dirs(home: &Path) -> Result<Vec<PathBuf>, String> {
    let entries = match fs::read_dir(home) {
        Ok(entries) => entries,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(format!("cannot read {}: {e}", home.display())),
    };
    let mut dirs: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
        .map(|e| e.path())
        .filter(|p| p.join("project.json").is_file())
        .collect();
    dirs.sort();
    Ok(dirs)
}

/// What the resolver decided for a workspace.
struct Resolved {
    root: String,
    name: String,
    dir: PathBuf,
}

fn resolve(workspace: &str) -> Result<Resolved, String> {
    let workspace = PathBuf::from(StandardPath::new(workspace)?.as_str());
    if !workspace.is_dir() {
        return Err(format!("no folder at {}", workspace.display()));
    }
    let common = git(
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        &workspace,
        None,
    )?
    .unwrap_or_default();
    let root = match common.strip_suffix("/.git") {
        _ if common.is_empty() => workspace.clone(),
        Some(main) => PathBuf::from(main),
        None => PathBuf::from(&common),
    };
    let root = root
        .canonicalize()
        .map_err(|e| format!("cannot resolve {}: {e}", root.display()))?;
    let name = slug(&root);
    let root = root
        .to_str()
        .ok_or_else(|| format!("{} is not UTF-8", root.display()))?
        .to_string();
    let home = prp_home()?;
    let needle = format!("\"path\": \"{root}\"");
    let hit = store_dirs(&home)?.into_iter().find(|dir| {
        fs::read_to_string(dir.join("project.json")).is_ok_and(|text| text.contains(&needle))
    });
    let dir = match hit {
        Some(dir) => dir,
        None => {
            let hash = git(&["hash-object", "--stdin"], &workspace, Some(&root))?
                .filter(|h| h.len() >= 8)
                .ok_or_else(|| format!("git could not hash {root}, so no store key"))?;
            home.join(format!("{name}-{}", &hash[..8]))
        }
    };
    Ok(Resolved { root, name, dir })
}

/// The block's last line: the store exists, and a store nothing had touched is registered with
/// the bytes prp's `printf` writes.
fn create(store: &Resolved) -> Result<(), String> {
    fs::create_dir_all(&store.dir)
        .map_err(|e| format!("cannot create {}: {e}", store.dir.display()))?;
    let registration = store.dir.join("project.json");
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&registration)
    {
        Ok(mut file) => file
            .write_all(
                format!(
                    "{{\"path\": \"{}\", \"name\": \"{}\"}}\n",
                    store.root, store.name
                )
                .as_bytes(),
            )
            .map_err(|e| format!("cannot write {}: {e}", registration.display())),
        Err(e) if e.kind() == ErrorKind::AlreadyExists => Ok(()),
        Err(e) => Err(format!("cannot write {}: {e}", registration.display())),
    }
}

/// `yyyy-mm-dd`, digits and dashes only: the day becomes part of a file name.
fn is_day(day: &str) -> bool {
    day.len() == 10
        && day.bytes().enumerate().all(|(i, b)| {
            if i == 4 || i == 7 {
                b == b'-'
            } else {
                b.is_ascii_digit()
            }
        })
}

/// The `n`th note of a day: `2026-09-30-note.md`, then `-note-2.md`, `-note-3.md`. The date and
/// `-note` are both in it because a person scans this directory, and the store is shared with
/// agents whose daily logs could claim a bare date.
fn note_name(day: &str, n: u32) -> String {
    if n == 1 {
        format!("{day}-note.md")
    } else {
        format!("{day}-note-{n}.md")
    }
}

/// `prp/note`: resolve and register the workspace's store as prp would, then create the day's
/// next free note in its `notes/`, empty. Created with `create_new`, so a name another writer
/// took a moment ago is skipped rather than truncated.
pub fn note(args: &Value) -> Result<Value, String> {
    let args: PrpNoteArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("prp/note args: {e}"))?;
    if !is_day(&args.day) {
        return Err(format!("prp/note: day is yyyy-mm-dd, not {:?}", args.day));
    }
    let store = resolve(&args.workspace)?;
    create(&store)?;
    let notes = store.dir.join(NOTES_DIRECTORY);
    fs::create_dir_all(&notes).map_err(|e| format!("cannot create {}: {e}", notes.display()))?;
    for n in 1.. {
        let path = notes.join(note_name(&args.day, n));
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(_) => {
                return Ok(json!(PrpNote {
                    path: path.to_string_lossy().into_owned()
                }));
            }
            Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
            Err(e) => return Err(format!("cannot create {}: {e}", path.display())),
        }
    }
    unreachable!("a directory holds finitely many notes")
}

/// A store's registration, read as JSON: prp writes `path` and `name`, and either may be absent
/// or empty in a store somebody wrote by hand.
fn registration(dir: &Path) -> (Option<String>, Option<String>) {
    let value: Value = fs::read_to_string(dir.join("project.json"))
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default();
    let field = |key: &str| {
        value[key]
            .as_str()
            .filter(|v| !v.is_empty())
            .map(str::to_string)
    };
    (field("path"), field("name"))
}

fn key_of(dir: &Path) -> String {
    dir.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// `prp/stores`: every store, sorted by name ignoring case, and the workspace's when asked. The
/// workspace is resolved as `prp/note` does but nothing is created, and a workspace whose store
/// does not exist yet, or that cannot be resolved (its folder gone, git past its wait), names no
/// store: the list is still the answer.
pub fn stores(args: &Value) -> Result<Value, String> {
    let args: PrpStoresArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("prp/stores args: {e}"))?;
    let home = prp_home()?;
    let dirs = store_dirs(&home)?;
    let workspace = args
        .workspace
        .and_then(|w| resolve(&w).ok())
        .filter(|r| dirs.contains(&r.dir))
        .map(|r| key_of(&r.dir));
    let mut stores: Vec<PrpStore> = dirs
        .iter()
        .map(|dir| {
            let (path, name) = registration(dir);
            let key = key_of(dir);
            PrpStore {
                name: name.unwrap_or_else(|| key.clone()),
                key,
                path,
                dir: dir.to_string_lossy().into_owned(),
            }
        })
        .collect();
    stores.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| a.key.cmp(&b.key))
    });
    Ok(json!(PrpStores { stores, workspace }))
}

/// `prp/artifacts`: a store's renderable files at every depth, newest first. Dotfiles and the
/// store's own `project.json` are skipped, and only real directories are entered, so a symlink
/// cycle cannot spin the walk. `store` must name a store under the prp home, so this lists
/// stores and nothing else.
pub fn artifacts(args: &Value) -> Result<Value, String> {
    let args: PrpArtifactsArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("prp/artifacts args: {e}"))?;
    let home = prp_home()?;
    let dir = store_dirs(&home)?
        .into_iter()
        .find(|dir| key_of(dir) == args.store)
        .ok_or_else(|| format!("no prp store {:?} in {}", args.store, home.display()))?;
    let mut files = Vec::new();
    walk(&dir, &dir, &mut files);
    files.sort_by(|a: &PrpArtifact, b| {
        b.modified_ms
            .cmp(&a.modified_ms)
            .then_with(|| a.relative.cmp(&b.relative))
    });
    Ok(json!(PrpArtifacts { files }))
}

fn walk(dir: &Path, store: &Path, files: &mut Vec<PrpArtifact>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        // `DirEntry::file_type` does not follow a symlink: a link to a folder is not entered.
        if entry.file_type().is_ok_and(|t| t.is_dir()) {
            walk(&path, store, files);
        } else if is_renderable(&name) && !(dir == store && name == "project.json") {
            let modified_ms = fs::metadata(&path)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX));
            files.push(PrpArtifact {
                relative: path
                    .strip_prefix(store)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .into_owned(),
                path: path.to_string_lossy().into_owned(),
                modified_ms,
            });
        }
    }
}

/// `path/resolve`: what the operator typed, as benchd's absolute path. `~` and `~/…` expand
/// against benchd's `HOME`, which is the whole point: on the operator's Mac they would name his
/// home, not the agents'. Symlinks are kept as typed, so the path the operator named is the one
/// helm shows. Nothing there is a refusal naming the path.
pub fn resolve_path(args: &Value) -> Result<Value, String> {
    let args: PathResolveArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("path/resolve args: {e}"))?;
    let typed = args.path.as_str();
    let expanded = match typed.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => {
            let home = std::env::var("HOME")
                .ok()
                .filter(|h| !h.is_empty())
                .ok_or_else(|| "benchd has no HOME to expand ~ against".to_string())?;
            format!("{home}{rest}")
        }
        Some(_) => return Err(format!("{typed}: only ~ and ~/… are expanded")),
        None => typed.to_string(),
    };
    let path = StandardPath::new(&expanded)?;
    let kind = match fs::metadata(path.as_str()) {
        Ok(meta) if meta.is_dir() => PathKind::Directory,
        Ok(_) => PathKind::File,
        Err(e) if e.kind() == ErrorKind::NotFound => {
            return Err(format!("nothing at {}", path.as_str()));
        }
        Err(e) => return Err(format!("cannot look at {}: {e}", path.as_str())),
    };
    Ok(json!(PathResolved {
        path: path.as_str().to_string(),
        kind
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_is_prps() {
        let s = |p: &str| slug(Path::new(p));
        assert_eq!(s("/x/helm"), "helm");
        assert_eq!(s("/x/My Project"), "my-project");
        assert_eq!(s("/x/a__b--c"), "a-b-c");
        assert_eq!(s("/x/-lead-and-trail-"), "lead-and-trail");
        assert_eq!(s("/x/ünïcøde"), "n-c-de");
        assert_eq!(s("/x/---"), "project");
        assert_eq!(s("/"), "project");
    }

    #[test]
    fn a_day_is_ten_digits_and_dashes() {
        assert!(is_day("2026-09-30"));
        for bad in [
            "2026-9-30",
            "../../etc",
            "2026-09-30/x",
            "2026_09_30",
            "",
            "2026-09-3a",
        ] {
            assert!(!is_day(bad), "{bad}");
        }
    }

    #[test]
    fn notes_of_one_day_count_up() {
        assert_eq!(note_name("2026-09-30", 1), "2026-09-30-note.md");
        assert_eq!(note_name("2026-09-30", 2), "2026-09-30-note-2.md");
    }
}
