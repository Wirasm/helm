//! prp's artifact stores and the paths the operator types, answered by benchd (M5c, helm #459).
//!
//! `~/.prp` lives on the agents' machine, which is benchd's, so helm asks benchd about it rather
//! than reading its own disk. Four verbs:
//!
//! - `prp/note` starts an operator note (⌘⇧N) in the store prp's own resolver picks for a
//!   workspace, registering the store as prp would when nothing has touched it yet.
//! - `prp/stores` lists the stores, and says which one a workspace belongs to.
//! - `prp/artifacts` lists one store's renderable files.
//! - `path/resolve` turns a typed path into benchd's absolute path, `~` expanded against benchd's
//!   home, and says whether it is a file or a folder.
//!
//! helm's copies are `Sources/HelmWire/Bench/BenchPrp.swift`; both are pinned by
//! `fixtures/prp-verbs.json`.

use serde::{Deserialize, Serialize};
use std::time::Duration;

/// benchd's whole budget for resolving a workspace's store, both git runs together
/// (`prp/note`, and `prp/stores` with a workspace). A git that has not answered by then is a
/// refusal for a note and "no workspace store" for a listing. A client asking either verb waits
/// longer than this, so it always hears benchd's answer rather than its own timeout: helm's
/// `PrpStores.resolvingTimeout`, held above this by the fixture's `resolve_wait_ms`.
pub const PRP_RESOLVE_WAIT: Duration = Duration::from_millis(3000);

/// The extensions helm renders as a canvas: helm's `RenderableFile.isRenderable`, spelled again
/// because `bench open` refuses before anything reaches helm and `prp/artifacts` lists only
/// these. `bench`'s verbs test reads the Swift literal and compares.
pub const RENDERABLE: &[&str] = &["md", "markdown", "mdown", "html", "htm"];

/// Whether a file's name has one of `RENDERABLE`'s extensions, in any case. A path is judged by
/// its last component.
pub fn is_renderable(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.rsplit_once('.')
        .is_some_and(|(_, e)| RENDERABLE.contains(&e.to_ascii_lowercase().as_str()))
}

/// The one directory in a store that is the operator's rather than an agent's: where ⌘⇧N puts a
/// note.
pub const NOTES_DIRECTORY: &str = "notes";

/// `prp/note`'s payload. `day` is the operator's calendar day, `yyyy-mm-dd`: the note is named
/// after it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PrpNoteArgs {
    pub workspace: String,
    pub day: String,
}

/// `prp/note`'s answer: the new, empty note.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrpNote {
    pub path: String,
}

/// `prp/stores`'s payload. With `workspace`, the answer also names that workspace's store.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PrpStoresArgs {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
}

/// One store: a directory under the prp home holding a `project.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrpStore {
    /// The directory's name.
    pub key: String,
    /// `project.json`'s `name`, else the key.
    pub name: String,
    /// `project.json`'s `path`: the project root the store belongs to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub dir: String,
}

/// `prp/stores`'s answer: every store, sorted by name ignoring case, and the key of the
/// workspace's store when one was asked about and it exists.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrpStores {
    pub stores: Vec<PrpStore>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
}

/// `prp/artifacts`'s payload: a store, by key.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PrpArtifactsArgs {
    pub store: String,
}

/// One renderable file in a store.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrpArtifact {
    pub path: String,
    /// The path under the store, as the browser shows it: `plans/foo.plan.md`.
    pub relative: String,
    /// Last modified, milliseconds since the epoch.
    pub modified_ms: u64,
}

/// `prp/artifacts`'s answer, newest first.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrpArtifacts {
    pub files: Vec<PrpArtifact>,
}

/// `path/resolve`'s payload: what the operator typed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PathResolveArgs {
    pub path: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PathKind {
    File,
    Directory,
}

/// `path/resolve`'s answer: the absolute, standardized path on benchd's machine, and what is
/// there. A path with nothing there is refused.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PathResolved {
    pub path: String,
    pub kind: PathKind,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::path::PathBuf;

    #[test]
    fn renderable_is_by_extension_in_any_case() {
        assert!(is_renderable("plan.md"));
        assert!(is_renderable("PAGE.HTML"));
        assert!(!is_renderable("data.json"));
        assert!(!is_renderable("README"));
        assert!(!is_renderable("/a.md/README"));
        assert!(is_renderable("/a/b.markdown"));
    }

    /// `fixtures/prp-verbs.json` pins what helm sends and reads — each request and each answer,
    /// written back byte for byte.
    #[test]
    fn the_prp_fixture_round_trips() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/prp-verbs.json");
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        let value: Value = serde_json::from_str(&text).unwrap();

        fn back<T: Serialize + for<'de> Deserialize<'de>>(v: &Value) -> Value {
            json!(serde_json::from_value::<T>(v.clone()).unwrap())
        }
        let request = |key: &str, verb: &str, args: fn(&Value) -> Value| -> Value {
            let r: crate::Request = serde_json::from_value(value[key].clone()).unwrap();
            assert_eq!(r.verb, verb, "{key}");
            assert!(crate::Verb::parse(verb).is_some(), "{verb} is a known verb");
            let args = args(&r.args);
            json!(crate::Request { args, ..r })
        };
        let written_back = serde_json::to_string_pretty(&json!({
            "note": request("note", "prp/note", back::<PrpNoteArgs>),
            "note_answer": back::<PrpNote>(&value["note_answer"]),
            "stores": request("stores", "prp/stores", back::<PrpStoresArgs>),
            "stores_all": request("stores_all", "prp/stores", back::<PrpStoresArgs>),
            "stores_answer": back::<PrpStores>(&value["stores_answer"]),
            "artifacts": request("artifacts", "prp/artifacts", back::<PrpArtifactsArgs>),
            "artifacts_answer": back::<PrpArtifacts>(&value["artifacts_answer"]),
            "resolve": request("resolve", "path/resolve", back::<PathResolveArgs>),
            "resolve_answers": back::<Vec<PathResolved>>(&value["resolve_answers"]),
            "resolve_wait_ms": PRP_RESOLVE_WAIT.as_millis(),
        }))
        .unwrap()
            + "\n";
        assert_eq!(
            written_back,
            text,
            "the spelling drifted from {}",
            path.display()
        );
    }
}
