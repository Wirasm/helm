//! The mailroom — mail is mail, and nothing else (the operator's decomposition).
//!
//! This crate knows directories and files; it knows nothing about sessions, wakes,
//! sockets, or ptys — the wake is a *reactor* in the daemon, answering `mail/sent`
//! events with a paste, and the loop cap lives there too. The rules carried here are
//! helm's, bought with incidents:
//!
//! - **Files are the record.** A message is a markdown file a plain `cat` reads; the
//!   socket is transport, never the only copy.
//! - **The notice carries the path, never the body.** Whatever wakes a recipient says
//!   where the mail is; the mail itself costs tokens only when the agent chooses to
//!   read it, once, at the moment it matters.
//! - **Retire, never delete.** Reading moves inbox → read. Nothing in the mailroom
//!   ever unlinks a message, and delivery never replaces one: ids continue from the
//!   mailroom across restarts ([`next_seq`]) and a message file is created new.
//! - **Pull is metadata-only.** A listing returns sender/subject/time/read-state —
//!   bodies never — and reports its caps.
//!
//! Layout, under the record root:
//! ```text
//! mail/<handle>/inbox/<id>.md    unread
//! mail/<handle>/read/<id>.md     retired
//! ```
//! A message file is front-matter plus body, cat-friendly:
//! ```text
//! ---
//! from: post-claude
//! at: 2026-08-18T14:00:00Z
//! subject: the codeword
//! ---
//! <body>
//! ```

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// One line of a listing: everything a triage needs, nothing a body costs.
#[derive(Debug, Clone)]
pub struct MailMeta {
    pub id: String,
    pub from: String,
    pub subject: Option<String>,
    pub at: String,
    pub unread: bool,
}

pub fn mail_root(root: &Path) -> PathBuf {
    root.join("mail")
}

fn inbox(root: &Path, handle: &str) -> PathBuf {
    mail_root(root).join(handle).join("inbox")
}

fn read_dir_of(root: &Path, handle: &str) -> PathBuf {
    mail_root(root).join(handle).join("read")
}

/// Deliver a message into a handle's inbox. The mailbox is created on first delivery —
/// a claim is a directory, and mail to a handle nobody has spawned yet simply waits.
/// Returns `(id, path)`; the path is what a notice may carry.
pub fn deliver(
    root: &Path,
    seq: u64,
    from: &str,
    to: &str,
    subject: Option<&str>,
    at_rfc3339: &str,
    body: &str,
) -> Result<(String, PathBuf), String> {
    let dir = inbox(root, to);
    fs::create_dir_all(&dir).map_err(|e| format!("cannot create mailbox for {to:?}: {e}"))?;
    let id = format!("m{seq}");
    let path = dir.join(format!("{id}.md"));
    let subject_line = subject
        .map(|s| format!("subject: {s}\n"))
        .unwrap_or_default();
    let content = format!("---\nfrom: {from}\nat: {at_rfc3339}\n{subject_line}---\n{body}\n");
    // Create-new: a message is never replaced. An id that names a file already there is an
    // allocation bug, and it fails the send rather than losing the mail it would replace.
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|e| match e.kind() {
            std::io::ErrorKind::AlreadyExists => format!(
                "message {id} already exists at {} — refusing to overwrite it",
                path.display()
            ),
            _ => format!("cannot write {}: {e}", path.display()),
        })?;
    file.write_all(content.as_bytes())
        .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    Ok((id, path))
}

/// Where a message lives once retired, whether or not it has been yet — what a wake notice
/// names before the move (#415: the reactor retires only after the paste is written).
pub fn retired_path(root: &Path, handle: &str, id: &str) -> Result<PathBuf, String> {
    // The one place an id becomes a path, so the one place it is checked (#402): `Path::join`
    // does not collapse `..`, and `read/../../<other>/inbox/m1` read another mailbox. Any
    // single file name is an id — hand-written ones like `note` included.
    if id.is_empty() || id.contains('/') || id.contains('\\') || id.contains("..") {
        return Err(format!(
            "{id:?} is not a message id — an id is one file name, as `bench mail list` shows it"
        ));
    }
    Ok(read_dir_of(root, handle).join(format!("{id}.md")))
}

/// Whether a message still waits in its recipient's inbox.
pub fn is_unread(root: &Path, handle: &str, id: &str) -> bool {
    retired_path(root, handle, id).is_ok() && inbox(root, handle).join(format!("{id}.md")).is_file()
}

/// Retire a message: inbox → read, never delete. Returns the retired path. Retiring an
/// already-retired message is fine and answers with where it lives.
pub fn retire(root: &Path, handle: &str, id: &str) -> Result<PathBuf, String> {
    let to_path = retired_path(root, handle, id)?;
    let from_path = inbox(root, handle).join(format!("{id}.md"));
    let to_dir = read_dir_of(root, handle);
    if to_path.exists() {
        return Ok(to_path);
    }
    if !from_path.exists() {
        return Err(format!("no message {id:?} in {handle:?}'s mailbox"));
    }
    fs::create_dir_all(&to_dir).map_err(|e| format!("cannot create read dir: {e}"))?;
    fs::rename(&from_path, &to_path).map_err(|e| format!("cannot retire {id}: {e}"))?;
    Ok(to_path)
}

pub fn read_body(path: &Path) -> Result<String, String> {
    fs::read_to_string(path).map_err(|e| format!("cannot read {}: {e}", path.display()))
}

/// List a mailbox, metadata only, unread first then retired, each side sorted by id.
/// The caller reports any cap it applies; this returns everything.
pub fn list(root: &Path, handle: &str) -> Vec<MailMeta> {
    let mut out = Vec::new();
    for (dir, unread) in [
        (inbox(root, handle), true),
        (read_dir_of(root, handle), false),
    ] {
        let mut entries: Vec<PathBuf> = fs::read_dir(&dir)
            .map(|rd| {
                rd.filter_map(|e| e.ok().map(|e| e.path()))
                    .filter(|p| p.extension().is_some_and(|x| x == "md"))
                    .collect()
            })
            .unwrap_or_default();
        entries.sort();
        for path in entries {
            let id = path
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();
            let head = fs::read_to_string(&path).unwrap_or_default();
            let meta = parse_front_matter(&head);
            out.push(MailMeta {
                id,
                from: meta.0,
                subject: meta.2,
                at: meta.1,
                unread,
            });
        }
    }
    out
}

/// The first id no message in the mailroom has: one past the highest `m<n>` in any inbox
/// or read directory. benchd seeds its counter from this at boot, so an id is never handed
/// out twice across restarts. Files with other names (hand-written ones) are not ids.
pub fn next_seq(root: &Path) -> u64 {
    let mailboxes = fs::read_dir(mail_root(root))
        .into_iter()
        .flatten()
        .flatten();
    mailboxes
        .flat_map(|mailbox| ["inbox", "read"].map(|dir| mailbox.path().join(dir)))
        .flat_map(|dir| fs::read_dir(dir).into_iter().flatten().flatten())
        .filter_map(|e| {
            let name = e.file_name();
            name.to_str()?
                .strip_prefix('m')?
                .strip_suffix(".md")?
                .parse::<u64>()
                .ok()
        })
        .max()
        .map_or(1, |n| n + 1)
}

/// How many messages wait unread in a handle's inbox — the files `list` reports as unread,
/// counted without reading them.
pub fn unread(root: &Path, handle: &str) -> usize {
    fs::read_dir(inbox(root, handle))
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .filter(|e| e.path().extension().is_some_and(|x| x == "md"))
                .count()
        })
        .unwrap_or(0)
}

/// A message handed to its recipient: who sent it and where it now lives, in `read/`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Taken {
    pub id: String,
    pub from: String,
    pub path: PathBuf,
}

/// Hand out every unread message: each moves inbox → read, and only the moves this call
/// made come back. Two callers racing for one mailbox (two hooks of one agent firing at
/// once) each get a message at most once, because a rename succeeds for exactly one of them.
/// Oldest first: `m9` before `m10`.
pub fn take_unread(root: &Path, handle: &str) -> Vec<Taken> {
    let mut entries: Vec<PathBuf> = fs::read_dir(inbox(root, handle))
        .map(|rd| {
            rd.filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().is_some_and(|x| x == "md"))
                .collect()
        })
        .unwrap_or_default();
    entries.sort_by_key(|p| {
        let name = p.file_name().unwrap_or_default().to_string_lossy();
        (name.len(), name.into_owned())
    });
    let to_dir = read_dir_of(root, handle);
    if !entries.is_empty() && fs::create_dir_all(&to_dir).is_err() {
        return Vec::new();
    }
    let mut taken = Vec::new();
    for from_path in entries {
        let Some(id) = from_path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
        else {
            continue;
        };
        // The front matter is read before the move, while the file is still where this call
        // found it; a failed move discards what was read.
        let (from, _, _) = parse_front_matter(&fs::read_to_string(&from_path).unwrap_or_default());
        let to_path = to_dir.join(format!("{id}.md"));
        if to_path.exists() || fs::rename(&from_path, &to_path).is_err() {
            continue;
        }
        taken.push(Taken {
            id,
            from,
            path: to_path,
        });
    }
    taken
}

/// (from, at, subject) out of the front-matter block. Absent fields come back empty —
/// a listing must render whatever is on disk, not refuse a file a human hand-wrote.
fn parse_front_matter(text: &str) -> (String, String, Option<String>) {
    let mut from = String::new();
    let mut at = String::new();
    let mut subject = None;
    let mut in_block = false;
    for line in text.lines().take(10) {
        if line.trim() == "---" {
            if in_block {
                break;
            }
            in_block = true;
            continue;
        }
        if !in_block {
            continue;
        }
        if let Some(v) = line.strip_prefix("from: ") {
            from = v.trim().to_string();
        } else if let Some(v) = line.strip_prefix("at: ") {
            at = v.trim().to_string();
        } else if let Some(v) = line.strip_prefix("subject: ") {
            subject = Some(v.trim().to_string());
        }
    }
    (from, at, subject)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One root per test. A clock reading was the old suffix, and two tests starting on the
    /// same tick shared a mailroom: `a_hand_written_file_still_lists` then counted the other
    /// test's mail, about one run in ten.
    fn root() -> PathBuf {
        static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("bmail-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn delivery_creates_the_mailbox_and_the_file_is_cat_friendly() {
        let r = root();
        let (id, path) = deliver(
            &r,
            7,
            "post-claude",
            "post-codex",
            Some("codeword"),
            "2026-08-18T00:00:00Z",
            "101",
        )
        .unwrap();
        assert_eq!(id, "m7");
        let text = fs::read_to_string(&path).unwrap();
        assert!(text.contains("from: post-claude"));
        assert!(text.contains("subject: codeword"));
        assert!(text.ends_with("101\n"));
        let _ = fs::remove_dir_all(r);
    }

    #[test]
    fn retire_moves_and_never_deletes_and_is_idempotent() {
        let r = root();
        let (id, path) = deliver(&r, 1, "a", "b", None, "t", "hello").unwrap();
        let retired = retire(&r, "b", &id).unwrap();
        assert!(!path.exists(), "inbox copy moved");
        assert!(retired.exists(), "read copy exists — nothing deleted");
        assert_eq!(
            retire(&r, "b", &id).unwrap(),
            retired,
            "retiring twice answers with where it lives"
        );
        assert!(retire(&r, "b", "m99").is_err(), "unknown id refuses");
        let _ = fs::remove_dir_all(r);
    }

    #[test]
    fn listing_is_metadata_only_unread_first() {
        let r = root();
        let (id1, _) = deliver(&r, 1, "x", "b", Some("one"), "t1", "SECRET-BODY").unwrap();
        let (_id2, _) = deliver(&r, 2, "y", "b", None, "t2", "another").unwrap();
        retire(&r, "b", &id1).unwrap();
        assert_eq!(unread(&r, "b"), 1, "the retired one no longer counts");
        assert_eq!(unread(&r, "nobody"), 0, "no mailbox is no mail");
        let listing = list(&r, "b");
        assert_eq!(listing.len(), 2);
        assert!(listing[0].unread && listing[0].from == "y");
        assert!(!listing[1].unread && listing[1].subject.as_deref() == Some("one"));
        let _ = fs::remove_dir_all(r);
    }

    #[test]
    fn a_delivery_never_replaces_a_message() {
        let r = root();
        let (_, path) = deliver(&r, 1, "a", "b", None, "t", "first").unwrap();
        let err = deliver(&r, 1, "a", "b", None, "t", "second").unwrap_err();
        assert!(err.contains("refusing to overwrite"), "{err}");
        assert!(fs::read_to_string(&path).unwrap().ends_with("first\n"));
        let _ = fs::remove_dir_all(r);
    }

    #[test]
    fn the_next_seq_follows_every_message_in_the_mailroom() {
        let r = root();
        assert_eq!(next_seq(&r), 1, "an empty mailroom starts at m1");
        deliver(&r, 3, "a", "b", None, "t", "x").unwrap();
        deliver(&r, 7, "a", "c", None, "t", "x").unwrap();
        retire(&r, "c", "m7").unwrap();
        let hand = mail_root(&r).join("b").join("inbox");
        fs::write(hand.join("note.md"), "hand-written").unwrap();
        fs::write(hand.join("m99.txt"), "not a message").unwrap();
        assert_eq!(next_seq(&r), 8, "retired mail counts; other names do not");
        let _ = fs::remove_dir_all(r);
    }

    #[test]
    fn an_id_that_is_a_path_is_refused_before_anything_moves() {
        let r = root();
        let (id, path) = deliver(&r, 1, "a", "other", None, "t", "not yours").unwrap();
        fs::create_dir_all(mail_root(&r).join("me").join("read")).unwrap();
        for bad in [
            format!("../../other/inbox/{id}"),
            "a/b".into(),
            "..".into(),
            "".into(),
        ] {
            let err = retire(&r, "me", &bad).unwrap_err();
            assert!(err.contains("not a message id"), "{bad:?}: {err}");
        }
        assert!(path.exists(), "nothing moved");
        let _ = fs::remove_dir_all(r);
    }

    #[test]
    fn taking_unread_mail_moves_each_message_once_oldest_first() {
        let r = root();
        deliver(&r, 10, "a", "b", None, "t", "ten").unwrap();
        deliver(&r, 9, "c", "b", None, "t", "nine").unwrap();
        let taken = take_unread(&r, "b");
        assert_eq!(
            taken
                .iter()
                .map(|t| (t.id.as_str(), t.from.as_str()))
                .collect::<Vec<_>>(),
            [("m9", "c"), ("m10", "a")]
        );
        assert!(
            taken
                .iter()
                .all(|t| t.path.exists() && t.path.parent().unwrap().ends_with("read"))
        );
        assert_eq!(unread(&r, "b"), 0);
        assert!(
            take_unread(&r, "b").is_empty(),
            "nothing is handed out twice"
        );
        assert!(take_unread(&r, "nobody").is_empty());
        let _ = fs::remove_dir_all(r);
    }

    #[test]
    fn a_hand_written_file_still_lists() {
        let r = root();
        let dir = mail_root(&r).join("b").join("inbox");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("note.md"), "no front matter at all").unwrap();
        let listing = list(&r, "b");
        assert_eq!(listing.len(), 1);
        assert_eq!(listing[0].id, "note");
        assert!(listing[0].from.is_empty());
        let _ = fs::remove_dir_all(r);
    }
}
