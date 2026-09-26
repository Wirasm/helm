//! What a pane shows, and what it is called.
//!
//! A pane is a view of one **surface**, named by a typed source (`bench-architecture.md`,
//! primitive 2). The document says *which* surface; helm resolves it to a live view at the
//! edge. New kinds are new variants here — the layout operations in `bench.rs` never match
//! on a kind, only placement (`placement.rs`) asks what class a surface is.

use crate::ids::StandardPath;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// The source a pane shows. Internally tagged by `kind`, so a stored document reads as
/// `{"kind":"canvas","source":{"kind":"file","path":"/tmp/plan.md"}}` — the same shape helm
/// persists today — and a kind this build does not know is a decode error that names it,
/// never a silently dropped pane.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Surface {
    /// A terminal. Its pty is helm's until M5b, keyed by the pane's own id. `agent` is what
    /// was running in it when last looked (helm #63): an id of a conversation that outlives
    /// the pty, which is why it is persisted where a presentation (the chat face) is not.
    Terminal {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        agent: Option<ResumableAgent>,
    },
    /// A document surface — markdown, HTML, a board, a page.
    Canvas { source: CanvasSource },
    /// A view onto the one shared browser benchd supervises (#350). No payload: there is one
    /// browser per bench root, and which tab it shows is live state, not arrangement.
    Browser,
    /// The list of agent sessions in the active workspace (#384), from `sessions/all`. No
    /// payload: which workspace it lists is where the operator is, not arrangement.
    Sessions,
}

impl Surface {
    /// A terminal nothing has been recorded in.
    pub fn terminal() -> Surface {
        Surface::Terminal { agent: None }
    }

    pub fn file(path: &str) -> Result<Surface, String> {
        Ok(Surface::Canvas {
            source: CanvasSource::File {
                path: StandardPath::new(path)?,
            },
        })
    }

    /// Whether a pane showing `self` is already a view of `wanted`, so opening `wanted` again
    /// should bring that pane forward rather than add a second. A canvas matches by source,
    /// **by value** — why ⌘-clicking the same link twice selects the canvas you have. The
    /// browser matches any browser pane: there is one browser. A terminal never matches:
    /// every one is its own.
    pub fn already_shows(&self, wanted: &Surface) -> bool {
        match (wanted, self) {
            (Surface::Canvas { source: a }, Surface::Canvas { source: b }) => a == b,
            (Surface::Browser, Surface::Browser) | (Surface::Sessions, Surface::Sessions) => true,
            _ => false,
        }
    }

    /// The class placement rules are written against.
    pub fn class(&self) -> SurfaceClass {
        match self {
            Surface::Terminal { .. } => SurfaceClass::Terminal,
            Surface::Canvas { .. } => SurfaceClass::Canvas,
            Surface::Browser => SurfaceClass::Browser,
            Surface::Sessions => SurfaceClass::Sessions,
        }
    }
}

/// Where a canvas points. A file, and only a file: helm's URL canvas was removed (#376, the
/// operator's ruling of 2026-09-25 — a web page is a tab of the shared browser), and with it
/// the empty `⌘L` canvas and the verb that repointed one. A tagged type with one variant so a
/// later source kind is an addition, not a migration; a stored `url` or `empty` source is no
/// longer a kind this build reads, and the tolerant reader skips that pane with a note.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CanvasSource {
    File { path: StandardPath },
}

/// The coarse classes placement distinguishes. Every canvas source is one class: helm's
/// rule "the operator put a canvas there, so that is where canvases go" never cared whether
/// it was a file or a page.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfaceClass {
    Terminal,
    Canvas,
    Browser,
    Sessions,
}

/// The agent a terminal pane held (helm `ResumableAgent`), recorded so a restart can offer
/// to resume the conversation. The offer itself is helm's; this is only the record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResumableAgent {
    pub command: String,
    pub session: String,
    pub cwd: String,
}

/// What a pane is called, and who called it that (helm #313). Provenance is the point: an
/// agent may replace helm's own derived label without asking, and may not replace a name
/// somebody chose, so a bare `Option<String>` could not carry the rule.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum PaneName {
    #[default]
    Unnamed,
    Derived(String),
    Chosen(String),
}

impl PaneName {
    pub fn is_unnamed(&self) -> bool {
        matches!(self, PaneName::Unnamed)
    }

    pub fn text(&self) -> Option<&str> {
        match self {
            PaneName::Unnamed => None,
            PaneName::Derived(t) | PaneName::Chosen(t) => Some(t),
        }
    }
}

/// The encoded form, `{"source":"derived"|"chosen","text":…}`, as helm writes it. `Unnamed`
/// has no encoded form: `Pane` omits the key entirely, so an un-named pane's JSON is exactly
/// what it would be if names did not exist.
#[derive(Serialize, Deserialize)]
struct EncodedName {
    source: NameSource,
    text: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum NameSource {
    Derived,
    Chosen,
}

impl Serialize for PaneName {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let (source, text) = match self {
            // Only reachable if a caller serializes a bare name; `Pane` never does.
            PaneName::Unnamed => return s.serialize_none(),
            PaneName::Derived(t) => (NameSource::Derived, t.clone()),
            PaneName::Chosen(t) => (NameSource::Chosen, t.clone()),
        };
        EncodedName { source, text }.serialize(s)
    }
}

impl<'de> Deserialize<'de> for PaneName {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(match Option::<EncodedName>::deserialize(d)? {
            None => PaneName::Unnamed,
            Some(EncodedName {
                source: NameSource::Derived,
                text,
            }) => PaneName::Derived(text),
            Some(EncodedName {
                source: NameSource::Chosen,
                text,
            }) => PaneName::Chosen(text),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn every_surface_kind_round_trips_with_a_named_discriminator() {
        for (surface, encoded) in [
            (Surface::terminal(), json!({"kind": "terminal"})),
            (
                Surface::file("/tmp/plan.md").unwrap(),
                json!({"kind": "canvas", "source": {"kind": "file", "path": "/tmp/plan.md"}}),
            ),
            (Surface::Browser, json!({"kind": "browser"})),
            (Surface::Sessions, json!({"kind": "sessions"})),
        ] {
            assert_eq!(serde_json::to_value(&surface).unwrap(), encoded);
            assert_eq!(serde_json::from_value::<Surface>(encoded).unwrap(), surface);
        }
    }

    #[test]
    fn an_unknown_surface_kind_is_refused_naming_the_kind() {
        let err = serde_json::from_value::<Surface>(json!({"kind": "archonRun"}))
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("archonRun"),
            "the refusal names the kind: {err}"
        );
    }

    #[test]
    fn a_name_keeps_who_gave_it() {
        for (name, encoded) in [
            (
                PaneName::Derived("claude · helm".into()),
                json!({"source": "derived", "text": "claude · helm"}),
            ),
            (
                PaneName::Chosen("review".into()),
                json!({"source": "chosen", "text": "review"}),
            ),
        ] {
            assert_eq!(serde_json::to_value(&name).unwrap(), encoded);
            assert_eq!(serde_json::from_value::<PaneName>(encoded).unwrap(), name);
        }
    }
}
