//! `bench file read` and `bench file write --expect` (helm #532): an agent's two halves of a file
//! the operator edits too, most often an HTML canvas's live file (`<stem>.data.json`).
//!
//! A write says what it expects to replace, and benchd writes only if the file still holds those
//! bytes (`file/write`'s `unchanged`, compared under benchd's lock). That is the whole point of
//! going through benchd rather than the filesystem: an agent that read the file, then writes back
//! its copy after the operator changed it, is refused instead of silently undoing his edit.

use crate::{Cli, exchange, record_root, refuse};
use bench_wire::{Expect, FileWriteArgs, Status, unbase64};
use serde_json::{Value, json};
use std::io::{Read, Write};

/// Whether `raw` (the arguments after `bench`) is `file …`.
pub fn owns(raw: &[String]) -> bool {
    raw.first().is_some_and(|w| w == "file") && !raw.iter().any(|a| a == "--help" || a == "-h")
}

pub fn run(raw: &[String]) -> i32 {
    let mut words = Vec::new();
    let mut expect = None;
    let mut suite = None;
    let mut it = raw.iter().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--expect" | "--suite" => {
                let Some(value) = it.next() else {
                    return refuse(&format!("{arg} needs a value"));
                };
                if arg == "--expect" {
                    expect = Some(value.clone());
                } else {
                    suite = Some(value.clone());
                }
            }
            flag if flag.starts_with("--") => return refuse(&format!("unknown flag {flag:?}")),
            word => words.push(word.to_string()),
        }
    }
    let root = match record_root(suite) {
        Ok(root) => root,
        Err(why) => return refuse(&why),
    };
    let path = match words.get(1).map(|p| absolute(p)) {
        Some(Ok(path)) => path,
        Some(Err(why)) => return refuse(&why),
        None => return refuse("file read|write needs a path"),
    };
    match words.first().map(String::as_str) {
        Some("read") if words.len() == 2 => read(root, path),
        Some("write") if words.len() == 2 => match expect {
            Some(expect) => write(root, path, &expect),
            None => refuse(
                "file write needs --expect <a file holding the bytes you read> — `bench file read` gives them; for a file that is not there yet, --expect /dev/null",
            ),
        },
        _ => refuse("usage: bench file read <path> | bench file write <path> --expect <file>"),
    }
}

fn absolute(raw: &str) -> Result<String, String> {
    let path = std::env::current_dir().unwrap_or_default().join(raw);
    bench_doc::StandardPath::new(&path.display().to_string()).map(|p| p.as_str().to_string())
}

fn ask(root: std::path::PathBuf, verb: &str, args: Value) -> Result<Value, i32> {
    let cli = Cli {
        verb: verb.into(),
        args,
        root,
        asked: false,
    };
    let response = exchange(&cli)?;
    if response.status != Status::Ok {
        let why = response.reason.unwrap_or_else(|| "no reason given".into());
        eprintln!("bench: {why}");
        return Err(response.status.exit_code());
    }
    response.data.ok_or_else(|| {
        eprintln!("bench: benchd answered {verb} with nothing");
        Status::Error.exit_code()
    })
}

/// The file's bytes on stdout, exactly: save them, and pass that file to `--expect` later.
fn read(root: std::path::PathBuf, path: String) -> i32 {
    let data = match ask(root, "file/read", json!({ "path": path })) {
        Ok(data) => data,
        Err(code) => return code,
    };
    match data["kind"].as_str() {
        Some("bytes") => match data["base64"].as_str().and_then(unbase64) {
            Some(bytes) => match std::io::stdout().write_all(&bytes) {
                Ok(()) => 0,
                Err(e) => refuse(&format!("cannot write to stdout: {e}")),
            },
            None => refuse("benchd answered bytes that are not base64"),
        },
        Some("absent") => refuse(&format!("no file at {path}")),
        _ => refuse(&format!("benchd answered file/read with {data}")),
    }
}

/// stdin, written over `path` only if it still holds what `expect` (a file) holds.
fn write(root: std::path::PathBuf, path: String, expect: &str) -> i32 {
    let expected = match std::fs::read(expect) {
        Ok(bytes) => bytes,
        Err(e) => return refuse(&format!("cannot read --expect {expect}: {e}")),
    };
    let (Ok(expected), mut text) = (String::from_utf8(expected), String::new()) else {
        return refuse(&format!("--expect {expect} is not UTF-8 text"));
    };
    if let Err(e) = std::io::stdin().read_to_string(&mut text) {
        return refuse(&format!("the new text on stdin is not UTF-8 text: {e}"));
    }
    let args = FileWriteArgs {
        path: path.clone(),
        text,
        expect: Expect::Unchanged { text: expected },
        notify: false,
    };
    let data = match ask(root, "file/write", json!(args)) {
        Ok(data) => data,
        Err(code) => return code,
    };
    match data["kind"].as_str() {
        Some("written") => 0,
        Some("changed") => refuse(&format!(
            "{path} changed since you read it, and nothing was written — read it again with `bench file read` and make your change on what is there"
        )),
        _ => refuse(&format!("benchd answered file/write with {data}")),
    }
}
