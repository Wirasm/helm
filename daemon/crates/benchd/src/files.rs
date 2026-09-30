//! A canvas's files, read and written by benchd (M5c, helm #459): the three `file/*` verbs, and
//! the watcher that tells followers when a canvas file, its sidecar or its live file changed.
//!
//! helm draws canvases and never touches their files itself, on one machine as much as across
//! two, so this is the one place a canvas's bytes are read, compared and written. The wire types
//! and their rules are `bench_wire::files`.

use crate::Core;
use bench_doc::StandardPath;
use bench_wire::{
    Expect, FILE_CHANGED, FILE_READ_MAX_BYTES, FileAppendArgs, FileChanged, FileRead, FileReadArgs,
    FileWrite, FileWriteArgs, base64, is_notes_sidecar, live_file, notes_sidecar,
};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How often the watcher looks. A write is reported once it has held still for one look, so
/// helm hears of a save 100–200 ms after its last byte: the quiet period helm's own watcher
/// used (120 ms), and what keeps a document written in chunks from rendering half-written.
const POLL: Duration = Duration::from_millis(100);

/// Held across a compare-and-write, so two writes to one file cannot both pass the compare.
static WRITES: Mutex<()> = Mutex::new(());

/// Names each temporary file uniquely within this process.
static TEMPORARY: AtomicU64 = AtomicU64::new(0);

fn absolute(raw: &str) -> Result<PathBuf, String> {
    Ok(PathBuf::from(StandardPath::new(raw)?.as_str()))
}

/// `file/read`: the bytes, `absent`, or `outside` when `within` names a folder the file is not
/// in. Containment is decided twice, and both are needed: lexically (`..` collapsed), which is
/// all a path that does not exist has; and with symlinks followed for one that does, so a link
/// inside the folder that points out of it is refused rather than read.
pub fn read(args: &Value) -> Result<Value, String> {
    let args: FileReadArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("file/read args: {e}"))?;
    let path = absolute(&args.path)?;
    if let Some(within) = &args.within
        && !inside(&path, &absolute(within)?)
    {
        return Ok(json!(FileRead::Outside));
    }
    let meta = match fs::metadata(&path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(json!(FileRead::Absent)),
        Err(e) => return Err(format!("cannot read {}: {e}", path.display())),
    };
    if meta.is_dir() {
        return Err(format!("cannot read {}: it is a directory", path.display()));
    }
    if meta.len() > FILE_READ_MAX_BYTES {
        return Err(format!(
            "cannot read {}: {} bytes, over the {FILE_READ_MAX_BYTES}-byte limit",
            path.display(),
            meta.len()
        ));
    }
    let bytes = fs::read(&path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    Ok(json!(FileRead::Bytes {
        base64: base64(&bytes)
    }))
}

/// Whether `path` (already standardized) is strictly inside `dir`.
fn inside(path: &Path, dir: &Path) -> bool {
    if path == dir || !path.starts_with(dir) {
        return false;
    }
    match path.canonicalize() {
        // A folder under a symlink (`/tmp` → `/private/tmp`) is compared resolved too, or every
        // honest sibling in it would be refused.
        Ok(real) => {
            let root = dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf());
            real != root && real.starts_with(root)
        }
        // Nothing there to follow: the lexical answer stands, and the read will say `absent`.
        Err(_) => true,
    }
}

/// `file/write`: temp file and rename, beside the target. The file is compared first, under
/// `WRITES`: gone or byte-equal to `expect` is written, anything else answers `changed` with what
/// is there and writes nothing. A file that cannot be read for the compare is refused, never
/// written: "could not look" is not "unchanged". A write that says `notify` is handed to the
/// live-file mailer once it is on disk (`live::edited`).
pub fn write(args: &Value) -> Result<Value, String> {
    let args: FileWriteArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("file/write args: {e}"))?;
    let path = absolute(&args.path)?;
    // The standardized path: `plan.notes.md/.` is the sidecar too.
    if is_notes_sidecar(&path.to_string_lossy()) {
        return Err(format!(
            "{} is a notes sidecar, which is only ever appended to (file/append)",
            path.display()
        ));
    }
    let held = WRITES
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let Expect::Unchanged { text: expected } = &args.expect;
    let before = match fs::read(&path) {
        Ok(now) if now != expected.as_bytes() => {
            return Ok(json!(FileWrite::Changed {
                base64: base64(&now)
            }));
        }
        Ok(now) => Some(now),
        Err(e) if e.kind() == ErrorKind::NotFound => None,
        Err(e) => {
            return Err(format!(
                "cannot read {} to compare before writing: {e}",
                path.display()
            ));
        }
    };
    replace(&path, args.text.as_bytes())
        .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    drop(held);
    if args.notify {
        crate::live::edited(&path.to_string_lossy(), before.as_deref(), &args.text);
    }
    Ok(json!(FileWrite::Written))
}

fn replace(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let name = path
        .file_name()
        .ok_or_else(|| std::io::Error::other("no file name"))?;
    let temporary = path.with_file_name(format!(
        ".{}.bench-{}-{}.tmp",
        name.to_string_lossy(),
        std::process::id(),
        TEMPORARY.fetch_add(1, Ordering::Relaxed)
    ));
    let written = fs::write(&temporary, bytes).and_then(|()| fs::rename(&temporary, path));
    if written.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    written
}

/// `file/append`: the text at the end of the file, which is created if it is not there. The
/// sidecar's one write; any path may be appended to, since appending replaces nothing.
pub fn append(args: &Value) -> Result<Value, String> {
    let args: FileAppendArgs =
        serde_json::from_value(args.clone()).map_err(|e| format!("file/append args: {e}"))?;
    let path = absolute(&args.path)?;
    OpenOptions::new()
        .append(true)
        .create(true)
        .open(&path)
        .and_then(|mut file| file.write_all(args.text.as_bytes()))
        .map_err(|e| format!("cannot append to {}: {e}", path.display()))?;
    Ok(json!({}))
}

// ---------------------------------------------------------------------------
// The watcher
// ---------------------------------------------------------------------------

/// What a look at a path found: its size, modification time and inode, or nothing there. An
/// atomic save changes the inode, a write the time, a truncation the size.
pub type Signature = Option<(u64, i64, i64, u64)>;

fn signature(path: &str) -> Signature {
    let meta = fs::metadata(path).ok()?;
    Some((meta.len(), meta.mtime(), meta.mtime_nsec(), meta.ino()))
}

/// The watcher's memory: per path, the signature last reported (none yet for a path just
/// watched) and the one seen at the last look. Pure, so the debounce is tested without a clock.
#[derive(Default)]
pub struct Watch {
    paths: HashMap<String, Seen>,
}

struct Seen {
    reported: Option<Signature>,
    last: Signature,
}

impl Watch {
    /// One look: every watched path with its signature now. Answers the paths to report.
    ///
    /// A path is reported when it differs from what was last reported **and** has not moved
    /// since the previous look, so a write arriving in pieces is one report, after the last
    /// piece. **A path just watched is reported once it holds still**, because nothing was ever
    /// reported for it: helm read the canvas when it opened it, and a write between that read and
    /// benchd's first look — or made while a restarted benchd was down — would otherwise become
    /// the baseline and never reach the pane. A path no longer watched is forgotten.
    pub fn look(&mut self, now: Vec<(String, Signature)>) -> Vec<String> {
        let mut next = HashMap::with_capacity(now.len());
        let mut changed = Vec::new();
        for (path, signature) in now {
            let seen = match self.paths.remove(&path) {
                None => Seen {
                    reported: None,
                    last: signature,
                },
                Some(mut seen) => {
                    if seen.reported != Some(signature) && signature == seen.last {
                        changed.push(path.clone());
                        seen.reported = Some(signature);
                    }
                    seen.last = signature;
                    seen
                }
            };
            next.insert(path, seen);
        }
        self.paths = next;
        changed
    }
}

/// Every file to watch: each canvas file in the document, its notes sidecar, and an HTML
/// canvas's live file (helm #532), which an agent writes and the open page is told about.
fn watched(core: &Arc<Mutex<Core>>) -> Vec<String> {
    let files = core.lock().unwrap().bench.document.canvas_files();
    let mut seen = HashSet::new();
    files
        .iter()
        .flat_map(|f| {
            let f = f.as_str();
            [Some(f.to_string()), Some(notes_sidecar(f)), live_file(f)]
        })
        .flatten()
        .filter(|p| seen.insert(p.clone()))
        .collect()
}

/// Look every `POLL` and log a `file/changed` for each path that settled into a new state.
/// Stats are taken off the core lock.
pub fn spawn_watcher(core: Arc<Mutex<Core>>) {
    std::thread::spawn(move || {
        let mut watch = Watch::default();
        loop {
            std::thread::sleep(POLL);
            let now = watched(&core)
                .into_iter()
                .map(|p| {
                    let s = signature(&p);
                    (p, s)
                })
                .collect();
            let changed = watch.look(now);
            if changed.is_empty() {
                continue;
            }
            let mut c = core.lock().unwrap();
            for path in changed {
                let _ = c.append(FILE_CHANGED, json!(FileChanged { path }));
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: Signature = Some((10, 1, 0, 7));
    const B: Signature = Some((20, 1, 5, 7));
    const C: Signature = Some((30, 1, 9, 7));

    fn look(watch: &mut Watch, sig: Signature) -> Vec<String> {
        watch.look(vec![("/a/plan.md".into(), sig)])
    }

    /// A write between helm's read at open and benchd's first look is not lost: a path just
    /// watched is reported once, when it first holds still.
    #[test]
    fn a_path_just_watched_is_reported_once_it_holds_still() {
        let mut watch = Watch::default();
        assert!(look(&mut watch, A).is_empty(), "first look");
        assert_eq!(look(&mut watch, A).len(), 1, "held still: reported");
        assert!(look(&mut watch, A).is_empty(), "and only once");
    }

    /// `FileWatcherTests.testAWriteThatArrivesInChunksRendersOnceAndOnlyWhenItIsWhole`, moved
    /// to where the files are: pieces landing between looks report nothing until the file holds
    /// still, then once.
    #[test]
    fn a_write_in_pieces_is_one_change_after_the_last_piece() {
        let mut watch = Watch::default();
        look(&mut watch, A);
        look(&mut watch, A);
        assert!(look(&mut watch, B).is_empty(), "still moving");
        assert!(look(&mut watch, C).is_empty(), "still moving");
        assert_eq!(look(&mut watch, C), vec!["/a/plan.md"]);
        assert!(look(&mut watch, C).is_empty(), "reported once");
    }

    #[test]
    fn two_settled_saves_are_two_changes() {
        let mut watch = Watch::default();
        look(&mut watch, A);
        look(&mut watch, A);
        look(&mut watch, B);
        assert_eq!(look(&mut watch, B).len(), 1);
        look(&mut watch, C);
        assert_eq!(look(&mut watch, C).len(), 1);
    }

    /// A sidecar that did not exist when the canvas opened, then does; and a file removed.
    #[test]
    fn appearing_and_disappearing_are_changes() {
        let mut watch = Watch::default();
        look(&mut watch, None);
        look(&mut watch, None);
        look(&mut watch, A);
        assert_eq!(look(&mut watch, A).len(), 1, "appeared");
        look(&mut watch, None);
        assert_eq!(look(&mut watch, None).len(), 1, "removed");
    }

    #[test]
    fn a_path_no_longer_watched_is_forgotten() {
        let mut watch = Watch::default();
        look(&mut watch, A);
        look(&mut watch, A);
        assert!(watch.look(vec![]).is_empty());
        // Watched again: a path just watched, reported once it holds still.
        assert!(look(&mut watch, B).is_empty());
        assert_eq!(look(&mut watch, B).len(), 1);
    }

    /// Real files: an atomic replace, an in-place truncation and an append each move the
    /// signature.
    #[test]
    fn every_kind_of_save_moves_the_signature() {
        let dir = std::env::temp_dir().join(format!("benchd-sig-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let file = dir.join("plan.md");
        let path = file.to_str().unwrap();
        assert_eq!(signature(path), None);
        fs::write(&file, "one\n").unwrap();
        let first = signature(path);
        replace(&file, b"two\n").unwrap();
        let replaced = signature(path);
        assert_ne!(first, replaced, "a rename is a new inode");
        OpenOptions::new()
            .append(true)
            .open(&file)
            .unwrap()
            .write_all(b"x")
            .unwrap();
        let appended = signature(path);
        assert_ne!(replaced, appended);
        fs::File::create(&file).unwrap();
        assert_ne!(appended, signature(path), "truncated to nothing");
        fs::remove_dir_all(&dir).unwrap();
    }
}
