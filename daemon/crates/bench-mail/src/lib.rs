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
//!   ever unlinks a message.
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
    fs::write(&path, content).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    Ok((id, path))
}

/// Retire a message: inbox → read, never delete. Returns the retired path. Retiring an
/// already-retired message is fine and answers with where it lives.
pub fn retire(root: &Path, handle: &str, id: &str) -> Result<PathBuf, String> {
    let name = format!("{id}.md");
    let from_path = inbox(root, handle).join(&name);
    let to_dir = read_dir_of(root, handle);
    let to_path = to_dir.join(&name);
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

    fn root() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "bmail-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
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
        let listing = list(&r, "b");
        assert_eq!(listing.len(), 2);
        assert!(listing[0].unread && listing[0].from == "y");
        assert!(!listing[1].unread && listing[1].subject.as_deref() == Some("one"));
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
