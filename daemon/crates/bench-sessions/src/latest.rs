//! The latest record of one kind in a harness's append-only JSONL file: pi's session name, and
//! each harness's model. Files only grow, so a scan resumes where the last one stopped and a
//! warm build reads only what was appended; a file shorter than that was replaced and is read
//! again. A value is a label on a row, never a row, so a file or a line that cannot be read
//! leaves the value as it was, and an empty value is no value.

use serde_json::Value;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// One kind of record: `needle` is a byte string every such line contains, so most lines are
/// skipped without parsing; `pick` reads a parsed line, answering `None` when it is not one.
pub struct Field {
    pub needle: &'static [u8],
    pub pick: fn(&Value) -> Option<String>,
}

/// What the scan of one file for one field has read so far.
#[derive(Debug, Default, Clone)]
pub struct Scan {
    offset: u64,
    value: String,
}

/// The field's latest value in `path`, reading only what was appended since the last call.
pub fn read(path: &Path, field: &Field, scan: &mut Scan) -> Option<String> {
    let len = fs::metadata(path).ok()?.len();
    if len < scan.offset {
        *scan = Scan::default();
    }
    if len > scan.offset {
        let mut buf = Vec::new();
        let mut file = fs::File::open(path).ok()?;
        file.seek(SeekFrom::Start(scan.offset)).ok()?;
        file.take(len - scan.offset).read_to_end(&mut buf).ok()?;
        // Only whole lines: the harness may be halfway through writing the last one.
        let end = memchr::memrchr(b'\n', &buf).map_or(0, |i| i + 1);
        for line in buf[..end].split(|b| *b == b'\n') {
            if memchr::memmem::find(line, field.needle).is_none() {
                continue;
            }
            let Ok(record) = serde_json::from_slice::<Value>(line) else {
                continue;
            };
            if let Some(value) = (field.pick)(&record) {
                scan.value = value;
            }
        }
        scan.offset += end as u64;
    }
    Some(scan.value.clone()).filter(|v| !v.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    const KIND: Field = Field {
        needle: b"\"kind\"",
        pick: |r| (r["type"] == "kind").then(|| r["v"].as_str().unwrap_or_default().to_string()),
    };

    #[test]
    fn the_latest_wins_a_half_written_line_waits_and_a_replaced_file_is_read_again() {
        let dir = std::env::temp_dir().join(format!("latest-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("s.jsonl");
        let append = |text: &str| {
            use std::io::Write;
            fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .unwrap()
                .write_all(text.as_bytes())
                .unwrap();
        };
        append("{\"type\":\"message\",\"text\":\"mentions \\\"kind\\\"\"}\n");
        let mut scan = Scan::default();
        assert_eq!(read(&path, &KIND, &mut scan), None, "a mention is not one");
        append("{\"type\":\"kind\",\"v\":\"a\"}\n");
        assert_eq!(read(&path, &KIND, &mut scan).as_deref(), Some("a"));
        let len = fs::metadata(&path).unwrap().len();
        assert_eq!(scan.offset, len, "the next read starts at the end");
        append("{\"type\":\"kind\",\"v\":\"b\"");
        assert_eq!(
            read(&path, &KIND, &mut scan).as_deref(),
            Some("a"),
            "not yet whole"
        );
        assert_eq!(scan.offset, len, "a half-written line is read again whole");
        append("}\n");
        assert_eq!(read(&path, &KIND, &mut scan).as_deref(), Some("b"));
        append("{\"type\":\"kind\",\"v\":\"\"}\n");
        assert_eq!(read(&path, &KIND, &mut scan), None, "cleared");
        fs::write(&path, "{\"type\":\"kind\",\"v\":\"c\"}\n").unwrap();
        assert_eq!(
            read(&path, &KIND, &mut scan).as_deref(),
            Some("c"),
            "a shorter file is read again"
        );
        fs::remove_dir_all(&dir).unwrap();
    }
}
