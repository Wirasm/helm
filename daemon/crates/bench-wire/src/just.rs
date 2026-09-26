//! The just layer on the wire (#356): `just/run` runs a recipe from the operator's bench
//! justfile, and two events say when it started and how it ended. benchd executes it
//! (`benchd/src/just.rs`); `bench just` and helm's key action send it.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// `just/run`'s payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JustRunArgs {
    /// A recipe name from `<root>/rules/justfile`: `[A-Za-z0-9_-]+`.
    pub recipe: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    /// Where an agent's run works. The operator's run always works in the active workspace,
    /// and so does an agent's that names none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
}

/// `just/run`'s answer: the run has started, and this is where its output goes. It does not
/// wait for the run; `just/finished` says how it ended.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JustStarted {
    pub run: String,
    pub log: String,
}

/// `just/finished`'s data: how a run ended. helm reads it to show the operator a run of his
/// that failed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JustFinished {
    pub run: String,
    pub recipe: String,
    /// The exit code; `None` when a signal ended the run.
    pub exit: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signal: Option<i32>,
    pub log: String,
}

/// A recipe started. `data`: `{run, recipe, by, cwd, log}`.
pub const JUST_STARTED: &str = "just/started";
/// A recipe ended. `data`: a `JustFinished`.
pub const JUST_FINISHED: &str = "just/finished";

/// `<root>/rules/justfile`: the operator's recipes. benchd only reads it.
pub fn justfile_path(root: &Path) -> PathBuf {
    root.join("rules").join("justfile")
}

/// `<root>/just/`: one log per run.
pub fn just_logs_dir(root: &Path) -> PathBuf {
    root.join("just")
}

/// A recipe name `just/run` will pass to `just`: letters, digits, `_` and `-`, so it can never
/// be read as a flag or reach anything but a recipe.
pub fn is_recipe_name(raw: &str) -> bool {
    !raw.is_empty()
        && !raw.starts_with('-')
        && raw
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    /// `fixtures/just-verbs.json` pins what helm sends and reads: the operator's `just/run`,
    /// its answer, and the `just/finished` frame, each written back byte for byte.
    #[test]
    fn the_just_fixture_round_trips() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/just-verbs.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();
        let run: crate::Request = serde_json::from_value(value["run"].clone()).unwrap();
        assert_eq!(run.verb, "just/run");
        assert_eq!(run.by, Some(crate::Actor::Operator));
        let args: JustRunArgs = serde_json::from_value(run.args.clone()).unwrap();
        let started: JustStarted = serde_json::from_value(value["started"].clone()).unwrap();
        let finished: JustFinished =
            serde_json::from_value(value["finished"]["event"]["data"].clone()).unwrap();
        assert_eq!(value["finished"]["event"]["kind"], JUST_FINISHED);
        let mut frame = value["finished"].clone();
        frame["event"]["data"] = json!(finished);
        let written = serde_json::to_string_pretty(&json!({
            "run": crate::Request { args: json!(args), ..run },
            "started": started,
            "finished": frame,
        }))
        .unwrap()
            + "\n";
        assert_eq!(
            written,
            text,
            "the spelling drifted from {}",
            path.display()
        );
    }

    #[test]
    fn a_recipe_name_cannot_be_a_flag_or_a_path() {
        for good in ["day", "open_notes", "review-queue", "a1"] {
            assert!(is_recipe_name(good), "{good}");
        }
        for bad in ["", "-f", "--justfile", "a b", "../x", "a;b", "é"] {
            assert!(!is_recipe_name(bad), "{bad:?}");
        }
    }
}
