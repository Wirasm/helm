//! The operator's placement rules file, `<root>/rules/placement.toml` (#356).
//!
//! He writes it; benchd only reads it. There is no watcher: the file is read before every
//! `pane/open` (the one verb that places by the rules) and every `status`, and adopted only when
//! its text changed. It is a few hundred bytes and placement is rare, so comparing the text is
//! cheaper to trust than an mtime, and a thread and a dependency would buy nothing.
//!
//! The rule for a file that cannot be read is `bench-browser`'s — a config the operator wrote
//! and the daemon ignored is a silent fallback, so it never is one — adapted to a table that
//! cannot simply refuse: placement has to keep working. So a bad file changes nothing, the table
//! in force before it stays in force, and the rejection is logged once per version of the file
//! and reported by `status` until a good version replaces it. That covers a file that cannot be
//! read at all (a permission, say) and one with no rules in it: only a file that is *gone* means
//! the built-in table. Rules are never half-applied.

use bench_doc::Rules;
use bench_wire::{RULES_LOADED, RULES_REJECTED};
use serde_json::{Value, json};
use std::fs;
use std::io::ErrorKind;
use std::path::PathBuf;

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

/// What the file held when last looked at, so an unchanged file is not adopted or rejected
/// again.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Seen {
    Absent,
    Text(String),
    Unreadable(String),
}

pub struct RulesFile {
    path: PathBuf,
    /// The table in force.
    rules: Rules,
    state: RulesState,
    seen: Seen,
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
            seen: Seen::Absent,
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
    /// changed: the file appeared, changed, went away, or stopped being readable.
    pub fn refresh(&mut self) -> Option<(&'static str, Value)> {
        let now = match fs::read_to_string(&self.path) {
            Ok(text) => Seen::Text(text),
            Err(e) if e.kind() == ErrorKind::NotFound => Seen::Absent,
            Err(e) => Seen::Unreadable(e.to_string()),
        };
        if now == self.seen {
            return None;
        }
        self.seen = now.clone();
        let parsed = match now {
            Seen::Absent => {
                self.rules = Rules::defaults();
                self.state = RulesState::Default;
                return Some(self.loaded_event("default"));
            }
            Seen::Unreadable(e) => Err(format!("cannot read it: {e}")),
            Seen::Text(text) => Rules::parse(&text),
        };
        match parsed {
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

    /// The operator's file sends the browser to a drawer the built-in table does not name, so
    /// which table is in force is visible in where the browser goes.
    const TO_DRAWER: &str =
        "[[place]]\nsurface = \"browser\"\ntry = [{ drawer = \"elsewhere\" }]\n";

    fn drawer(name: &str) -> Destination {
        Destination::Drawer(bench_doc::DrawerName::new(name).unwrap())
    }

    /// Where the operator's file sends the browser.
    fn operators() -> Destination {
        drawer("elsewhere")
    }

    /// Where the built-in table sends it.
    fn built_in() -> Destination {
        drawer("browser")
    }

    #[test]
    fn a_bad_version_keeps_the_last_good_table_and_is_reported_once() {
        let path = scratch("bad");
        let (mut file, booted) = RulesFile::boot(path.clone());
        assert_eq!(booted, None, "no file is the ordinary case");
        assert_eq!(file.state, RulesState::Default);

        fs::write(&path, TO_DRAWER).unwrap();
        let (kind, _) = file.refresh().expect("a new file is news");
        assert_eq!(kind, RULES_LOADED);
        assert!(browser_goes(&file) == operators());
        assert_eq!(file.refresh(), None, "the same version is not read again");

        fs::write(&path, "[[place]\nnot toml at all\n").unwrap();
        let (kind, data) = file.refresh().expect("a changed file is news");
        assert_eq!(kind, RULES_REJECTED);
        assert!(data["why"].as_str().unwrap().contains("line"), "{data}");
        assert!(
            browser_goes(&file) == operators(),
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
        assert_eq!(browser_goes(&file), built_in());
    }

    #[test]
    fn only_a_missing_file_means_the_built_in_table() {
        use std::os::unix::fs::PermissionsExt;
        let path = scratch("unreadable");
        fs::write(&path, TO_DRAWER).unwrap();
        let (mut file, _) = RulesFile::boot(path.clone());
        assert!(browser_goes(&file) == operators());

        // Half a save — the file truncated before the new text lands — holds no rules.
        fs::write(&path, "").unwrap();
        assert_eq!(file.refresh().map(|(kind, _)| kind), Some(RULES_REJECTED));
        assert!(
            browser_goes(&file) == operators(),
            "an empty file is not an empty table"
        );

        fs::write(&path, TO_DRAWER).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o000)).unwrap();
        let (kind, data) = file.refresh().expect("an unreadable file is news");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(kind, RULES_REJECTED, "{data}");
        assert!(
            browser_goes(&file) == operators(),
            "a file that cannot be read keeps the last good table"
        );
    }

    #[test]
    fn a_change_is_seen_by_its_text_not_its_timestamp() {
        let path = scratch("same-length");
        fs::write(&path, TO_DRAWER).unwrap();
        let (mut file, _) = RulesFile::boot(path.clone());
        let stamp = fs::metadata(&path).unwrap().modified().unwrap();
        let other = TO_DRAWER.replace("elsewhere\" }", "somewhere\" }");
        assert_eq!(other.len(), TO_DRAWER.len());
        fs::write(&path, &other).unwrap();
        fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_modified(stamp)
            .unwrap();
        assert!(
            file.refresh().is_some(),
            "same length, same mtime, new text"
        );
        assert_eq!(browser_goes(&file), drawer("somewhere"));
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
