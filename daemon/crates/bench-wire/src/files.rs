//! The file layer on the wire (M5c, helm #459): what a canvas does to its files, done by
//! benchd, so helm can draw a canvas whose file is on another machine.
//!
//! Three verbs and one event, and each carries a rule rather than generic file access:
//!
//! - `file/read` answers the bytes, or that nothing is there, or — with `within` — that the
//!   path leaves the canvas's folder. Only benchd can follow a symlink on its own disk, so the
//!   folder boundary a page's fetch is held to is decided here.
//! - `file/write` says what the writer expects to replace (`Expect`). `unchanged` is helm's
//!   "never write over bytes the operator has not been shown", done as one compare-and-write on
//!   benchd's side. A notes sidecar is refused: it is only ever appended to.
//! - `file/append` is the sidecar's one write.
//! - `file/changed` is benchd telling its followers that a canvas file or its sidecar changed.
//!
//! helm's copies are `Sources/HelmWire/Bench/BenchFiles.swift`; both are pinned by
//! `fixtures/file-verbs.json`.

use serde::{Deserialize, Serialize};

/// A canvas file or its sidecar changed. `data`: a `FileChanged`.
pub const FILE_CHANGED: &str = "file/changed";

/// The largest file `file/read` answers with. A canvas's sibling can be a video (the
/// post-canvas skill), so this is well above a document's size; helm refuses to render a text
/// document over 5 MB on its own side.
pub const FILE_READ_MAX_BYTES: u64 = 64 * 1024 * 1024;

/// The largest `file/write` or `file/append` request line. Those two carry a document, which
/// never reaches the event log, so they are not held to `MAX_REQUEST_BYTES`: a 5 MB draft plus
/// the `unchanged` copy it is compared with, escaped, fits.
pub const FILE_REQUEST_MAX_BYTES: usize = 16 * 1024 * 1024;

/// What makes a file some canvas's notes sidecar (helm's `CanvasNotes.sidecarSuffix`).
pub const NOTES_SUFFIX: &str = ".notes.md";

/// `file/read`'s payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileReadArgs {
    pub path: String,
    /// The folder the file must be inside, symlinks followed: a canvas page's sibling fetch.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub within: Option<String>,
}

/// `file/read`'s answer. A file benchd cannot read — permission, a directory, larger than
/// `FILE_READ_MAX_BYTES` — is a refusal with the reason, never `Absent`: "nothing there" and
/// "could not look" are different answers, and only the first licenses writing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FileRead {
    Bytes {
        base64: String,
    },
    Absent,
    /// The path resolves outside `within`.
    Outside,
}

/// What a `file/write` expects to replace.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Expect {
    /// Write whatever is there. The state latch, which only helm writes.
    Any,
    /// Write only if the file still holds exactly `text`, or is gone.
    Unchanged { text: String },
}

/// `file/write`'s payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileWriteArgs {
    pub path: String,
    pub text: String,
    pub expect: Expect,
}

/// `file/write`'s answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FileWrite {
    Written,
    /// The file no longer held what `Expect::Unchanged` named. Nothing was written; these are
    /// the bytes that are there instead.
    Changed {
        base64: String,
    },
}

/// `file/append`'s payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileAppendArgs {
    pub path: String,
    pub text: String,
}

/// `file/changed`'s data.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileChanged {
    pub path: String,
}

/// `/a/plan.md` → `/a/plan.notes.md`, `/a/README` → `/a/README.notes.md`: the notes beside a
/// canvas. helm's `CanvasNotes.sidecarURL` is the same rule, pinned by the fixture's table.
pub fn notes_sidecar(canvas: &str) -> String {
    let (dir, name) = canvas.rsplit_once('/').unwrap_or(("", canvas));
    let stem = match name.rfind('.') {
        Some(i) if i > 0 && i + 1 < name.len() => &name[..i],
        _ => name,
    };
    format!("{dir}/{stem}{NOTES_SUFFIX}")
}

/// Whether `path` is some canvas's notes sidecar, which `file/write` refuses.
pub fn is_notes_sidecar(path: &str) -> bool {
    path.ends_with(NOTES_SUFFIX)
}

/// Standard base64 with padding, which Swift's `Data(base64Encoded:)` reads.
pub fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(char::from(ALPHABET[(n >> (18 - 6 * i)) as usize & 63]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::path::PathBuf;

    #[test]
    fn base64_matches_the_standard_alphabet_and_padding() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64(&[0xff, 0xfe, 0x00]), "//4A");
    }

    /// `fixtures/file-verbs.json` pins what helm sends and reads — each request, each answer and
    /// the event frame, written back byte for byte — and the sidecar rule both sides spell.
    #[test]
    fn the_file_fixture_round_trips() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/file-verbs.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();

        let request = |key: &str, verb: &str| -> crate::Request {
            let r: crate::Request = serde_json::from_value(value[key].clone()).unwrap();
            assert_eq!(r.verb, verb, "{key}");
            r
        };
        let read = request("read", "file/read");
        let read_args: FileReadArgs = serde_json::from_value(read.args.clone()).unwrap();
        let sibling = request("read_sibling", "file/read");
        let sibling_args: FileReadArgs = serde_json::from_value(sibling.args.clone()).unwrap();
        let write = request("write", "file/write");
        let write_args: FileWriteArgs = serde_json::from_value(write.args.clone()).unwrap();
        let latch = request("write_latch", "file/write");
        let latch_args: FileWriteArgs = serde_json::from_value(latch.args.clone()).unwrap();
        let append = request("append", "file/append");
        let append_args: FileAppendArgs = serde_json::from_value(append.args.clone()).unwrap();
        let answers: Vec<FileRead> = serde_json::from_value(value["read_answers"].clone()).unwrap();
        let written: Vec<FileWrite> =
            serde_json::from_value(value["write_answers"].clone()).unwrap();
        let changed: FileChanged =
            serde_json::from_value(value["changed"]["event"]["data"].clone()).unwrap();
        assert_eq!(value["changed"]["event"]["kind"], FILE_CHANGED);

        let mut frame = value["changed"].clone();
        frame["event"]["data"] = json!(changed);
        let with = |r: crate::Request, args: Value| crate::Request { args, ..r };
        let written_back = serde_json::to_string_pretty(&json!({
            "read": with(read, json!(read_args)),
            "read_sibling": with(sibling, json!(sibling_args)),
            "write": with(write, json!(write_args)),
            "write_latch": with(latch, json!(latch_args)),
            "append": with(append, json!(append_args)),
            "read_answers": answers,
            "write_answers": written,
            "changed": frame,
            "sidecars": value["sidecars"],
        }))
        .unwrap()
            + "\n";
        assert_eq!(
            written_back,
            text,
            "the spelling drifted from {}",
            path.display()
        );

        for row in value["sidecars"].as_array().unwrap() {
            let canvas = row["canvas"].as_str().unwrap();
            assert_eq!(notes_sidecar(canvas), row["sidecar"], "{canvas}");
            assert_eq!(
                is_notes_sidecar(canvas),
                row["canvas_is_sidecar"].as_bool().unwrap(),
                "{canvas}"
            );
            assert!(is_notes_sidecar(&notes_sidecar(canvas)));
        }
    }
}
