//! A Claude login other than the operator's default, named by its config dir.

use serde::{Deserialize, Deserializer, Serialize};
use std::ffi::OsString;

/// The config dir of a Claude login other than the default (`CLAUDE_CONFIG_DIR`), spelled exactly
/// as set: Claude names the login's keychain item after that string, so two spellings of one
/// folder are two logins. Never empty, because an empty one is the default login, to Claude as
/// here; always absolute, because Claude refuses a relative one. The default login itself is no
/// `ConfigDir`: it is the absence of one.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(transparent)]
pub struct ConfigDir(String);

impl ConfigDir {
    pub fn new(dir: impl Into<String>) -> Result<ConfigDir, String> {
        let dir = dir.into();
        if !dir.starts_with('/') {
            return Err(format!(
                "a Claude config dir is an absolute path, got {dir:?}"
            ));
        }
        Ok(ConfigDir(dir))
    }

    /// The login a process runs on, from its `CLAUDE_CONFIG_DIR`: `None` when unset or empty
    /// (the default login), an error for one Claude would not run on (relative, or not UTF-8).
    pub fn from_env(value: Option<OsString>) -> Result<Option<ConfigDir>, String> {
        match value.map(OsString::into_string) {
            None => Ok(None),
            Some(Ok(dir)) if dir.is_empty() => Ok(None),
            Some(Ok(dir)) => ConfigDir::new(dir).map(Some),
            Some(Err(raw)) => Err(format!("CLAUDE_CONFIG_DIR {raw:?} is not UTF-8")),
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for ConfigDir {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        ConfigDir::new(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unset_or_empty_is_the_default_and_anything_claude_refuses_is_refused() {
        assert_eq!(ConfigDir::from_env(None), Ok(None));
        assert_eq!(ConfigDir::from_env(Some("".into())), Ok(None));
        assert_eq!(
            ConfigDir::from_env(Some("/Users/op/.claude-b/".into())),
            Ok(Some(ConfigDir("/Users/op/.claude-b/".into()))),
            "spelled as set, trailing slash and all"
        );
        assert!(ConfigDir::from_env(Some("rel".into())).is_err());
        assert!(serde_json::from_str::<ConfigDir>("\"\"").is_err());
        assert!(serde_json::from_str::<ConfigDir>("\"x/.claude-b\"").is_err());
    }
}
