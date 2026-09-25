//! The identities the document is addressed by. Each is its own type so a slot id can
//! never be handed where a pane id belongs — the confusion helm's `TerminalID` (#231) was
//! introduced to make a compile error rather than a `nil` three calls downstream.

use serde::{Deserialize, Deserializer, Serialize};
use std::fmt;
use uuid::Uuid;

macro_rules! uuid_id {
    ($(#[$doc:meta])* $name:ident) => {
        $(#[$doc])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(Uuid);

        impl $name {
            /// A fresh random id. Minted by the daemon, never derived: an id that could be
            /// computed from something else would be a second thing to keep in step.
            pub fn mint() -> Self {
                $name(Uuid::new_v4())
            }

            /// Parse the textual form, in either case — helm writes uppercase, this crate
            /// writes lowercase, and both name the same id.
            pub fn parse(raw: &str) -> Result<Self, String> {
                Uuid::parse_str(raw)
                    .map($name)
                    .map_err(|e| format!("not a {}: {raw:?} ({e})", stringify!($name)))
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(f)
            }
        }
    };
}

uuid_id!(
    /// A pane — one tenant of a slot. For a terminal pane in M4 this is also the id helm
    /// keys its live `TerminalSession` by, exactly as `Pane.id` is today.
    PaneId
);
uuid_id!(
    /// A slot — one tabbed cell of a column. Focus names a slot by id, never by index: an
    /// index goes stale the moment anything is inserted before it.
    SlotId
);
uuid_id!(
    /// A column — one vertical stack of slots.
    ColumnId
);

/// An absolute path in one canonical spelling: `.` and empty components dropped, `..`
/// collapsed lexically, no trailing slash. Symlinks are **not** resolved — the path the
/// caller named is the path the bench shows (helm's `FilesystemPath.normalized` rule).
///
/// It is a type rather than a helper because placement compares sources **by value**
/// (`Bench::pane_showing`): an unstandardised path silently fails to match and ⌘-clicking
/// the same link twice opens a second copy. helm learned that as `StandardizedPath` (#88)
/// and `WorkspacePath` (#226); the unstandardised value is unconstructable here from day one.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub struct StandardPath(String);

impl StandardPath {
    /// Refuses a relative path rather than resolving it against a cwd the daemon does not
    /// share with its caller. Tilde expansion is the caller's (the CLI's) job for the same
    /// reason — `~` means the caller's home, and only the caller knows whose that is.
    pub fn new(raw: &str) -> Result<Self, String> {
        if !raw.starts_with('/') {
            return Err(format!("not an absolute path: {raw:?}"));
        }
        let mut parts: Vec<&str> = Vec::new();
        for part in raw.split('/') {
            match part {
                "" | "." => {}
                ".." => {
                    parts.pop();
                }
                other => parts.push(other),
            }
        }
        Ok(StandardPath(format!("/{}", parts.join("/"))))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for StandardPath {
    /// A decoded path goes through the same door as a constructed one, so a hand-edited
    /// `bench.json` cannot smuggle in a spelling `new` would have refused or changed.
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(d)?;
        StandardPath::new(&raw).map_err(serde::de::Error::custom)
    }
}

impl fmt::Display for StandardPath {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_has_one_spelling() {
        for (raw, want) in [
            ("/tmp/plan.md", "/tmp/plan.md"),
            ("/tmp/./plan.md", "/tmp/plan.md"),
            ("/tmp//a/../plan.md", "/tmp/plan.md"),
            ("/tmp/work/", "/tmp/work"),
            ("/", "/"),
            ("/..", "/"),
        ] {
            assert_eq!(StandardPath::new(raw).unwrap().as_str(), want, "{raw}");
        }
    }

    #[test]
    fn a_relative_path_is_refused_not_resolved() {
        for raw in ["plan.md", "./plan.md", "~/plan.md", ""] {
            assert!(StandardPath::new(raw).is_err(), "{raw:?} should be refused");
        }
    }

    #[test]
    fn a_decoded_path_is_standardised_too() {
        let p: StandardPath = serde_json::from_str("\"/tmp/./a/../plan.md\"").unwrap();
        assert_eq!(p.as_str(), "/tmp/plan.md");
        assert!(serde_json::from_str::<StandardPath>("\"plan.md\"").is_err());
    }

    #[test]
    fn ids_read_either_case_and_write_one() {
        let upper = PaneId::parse("E621E1F8-C36C-495A-93FC-0C247A3E6E5F").unwrap();
        let lower = PaneId::parse("e621e1f8-c36c-495a-93fc-0c247a3e6e5f").unwrap();
        assert_eq!(upper, lower);
        assert_eq!(
            serde_json::to_string(&upper).unwrap(),
            "\"e621e1f8-c36c-495a-93fc-0c247a3e6e5f\""
        );
    }
}
