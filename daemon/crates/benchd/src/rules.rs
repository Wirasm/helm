//! The operator's placement rules file, `<root>/rules/placement.toml` (#356).
//!
//! He writes it; benchd only reads it. There is no watcher: the file is looked at (one `stat`)
//! before every layout verb and every `status`, and reread only when it changed. Placement is
//! rare and a stat is cheap, so a thread and a dependency would buy nothing.
//!
//! The rule for a file that cannot be read is `bench-browser`'s — a config the operator wrote
//! and the daemon ignored is a silent fallback, so it never is one — adapted to a table that
//! cannot simply refuse: placement has to keep working. So a bad file changes nothing, the table
//! in force before it stays in force, and the rejection is logged once per version of the file
//! and reported by `status` until a good version replaces it. Rules are never half-applied.

use bench_doc::Rules;
use bench_wire::{RULES_LOADED, RULES_REJECTED};
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::time::SystemTime;

/// A version of the file: enough to tell "changed" from "the same file again". The length is
/// there for two saves inside one mtime tick.
type Version = (SystemTime, u64);

/// What `status` says about the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RulesState {
    /// No file: the built-in table is in force.
    Default,
    /// The file was read and is in force.
    Loaded,
    /// The file's current version could not be read; the table before it is still in force.
    Rejected { why: String },
}

pub struct RulesFile {
    path: PathBuf,
    /// The table in force.
    rules: Rules,
    state: RulesState,
    /// The version last looked at; `None` while there is no file.
    seen: Option<Version>,
}

impl RulesFile {
    /// Read the file at boot, answering the event to log when there is one. No file is the
    /// ordinary case and logs nothing (`status` still says `default`); a file that is bad at
    /// boot leaves the built-in table, since there is no earlier one to keep.
    pub fn boot(path: PathBuf) -> (RulesFile, Option<(&'static str, Value)>) {
        let mut file = RulesFile {
            path,
            rules: Rules::defaults(),
            state: RulesState::Default,
            seen: None,
        };
        let event = file.refresh();
        (file, event)
    }

    pub fn rules(&self) -> &Rules {
        &self.rules
    }

    /// `status`'s line for this file.
    pub fn status(&self) -> Value {
        let path = self.path.display().to_string();
        match &self.state {
            RulesState::Default => json!({ "path": path, "state": "default" }),
            RulesState::Loaded => json!({ "path": path, "state": "ok" }),
            RulesState::Rejected { why } => {
                json!({ "path": path, "state": "rejected", "why": why })
            }
        }
    }

    /// Look at the file, and adopt it if it changed. Answers the event to log, if anything
    /// changed: the file appeared, changed, or went away.
    pub fn refresh(&mut self) -> Option<(&'static str, Value)> {
        let version = fs::metadata(&self.path)
            .ok()
            .map(|m| (m.modified().unwrap_or(SystemTime::UNIX_EPOCH), m.len()));
        if version == self.seen {
            return None;
        }
        self.seen = version;
        if version.is_none() {
            self.rules = Rules::defaults();
            self.state = RulesState::Default;
            return Some(self.loaded_event("default"));
        }
        let read = fs::read_to_string(&self.path)
            .map_err(|e| format!("cannot read it: {e}"))
            .and_then(|text| Rules::parse(&text));
        match read {
            Ok(rules) => {
                self.rules = rules;
                self.state = RulesState::Loaded;
                Some(self.loaded_event("file"))
            }
            Err(why) => {
                self.state = RulesState::Rejected { why: why.clone() };
                Some((
                    RULES_REJECTED,
                    json!({ "file": self.path.display().to_string(), "why": why }),
                ))
            }
        }
    }

    fn loaded_event(&self, source: &str) -> (&'static str, Value) {
        (
            RULES_LOADED,
            json!({ "file": self.path.display().to_string(), "source": source }),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bench_doc::{Caller, Destination, Surface};

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("benchd-rules-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir.join("placement.toml")
    }

    fn browser_goes(file: &RulesFile) -> Destination {
        let bench = bench_doc::Bench::terminal(bench_doc::PaneId::mint());
        file.rules().place(&bench, &Surface::Browser, Caller::Agent)
    }

    const TO_DRAWER: &str = "[[place]]\nsurface = \"browser\"\ntry = [{ drawer = \"browser\" }]\n";

    #[test]
    fn a_bad_version_keeps_the_last_good_table_and_is_reported_once() {
        let path = scratch("bad");
        let (mut file, booted) = RulesFile::boot(path.clone());
        assert_eq!(booted, None, "no file is the ordinary case");
        assert_eq!(file.state, RulesState::Default);

        fs::write(&path, TO_DRAWER).unwrap();
        let (kind, _) = file.refresh().expect("a new file is news");
        assert_eq!(kind, RULES_LOADED);
        assert!(matches!(browser_goes(&file), Destination::Drawer(_)));
        assert_eq!(file.refresh(), None, "the same version is not read again");

        fs::write(&path, "[[place]\nnot toml at all\n").unwrap();
        let (kind, data) = file.refresh().expect("a changed file is news");
        assert_eq!(kind, RULES_REJECTED);
        assert!(data["why"].as_str().unwrap().contains("line"), "{data}");
        assert!(
            matches!(browser_goes(&file), Destination::Drawer(_)),
            "the last good table is still in force"
        );
        assert_eq!(file.status()["state"], "rejected");
        assert_eq!(
            file.refresh(),
            None,
            "rejected once per version, not per verb"
        );

        fs::remove_file(&path).unwrap();
        let (kind, data) = file.refresh().expect("a removed file is news");
        assert_eq!(
            (kind, data["source"].as_str()),
            (RULES_LOADED, Some("default"))
        );
        assert_eq!(file.state, RulesState::Default);
        assert!(matches!(browser_goes(&file), Destination::Bench(_)));
    }

    #[test]
    fn a_bad_file_at_boot_leaves_the_built_in_table() {
        let path = scratch("boot");
        fs::write(&path, "surface = 3").unwrap();
        let (file, booted) = RulesFile::boot(path);
        assert_eq!(booted.map(|(kind, _)| kind), Some(RULES_REJECTED));
        assert_eq!(file.rules(), &Rules::defaults());
    }
}
