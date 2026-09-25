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
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
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

    /// The class placement rules are written against.
    pub fn class(&self) -> SurfaceClass {
        match self {
            Surface::Terminal { .. } => SurfaceClass::Terminal,
            Surface::Canvas { .. } => SurfaceClass::Canvas,
            Surface::Browser => SurfaceClass::Browser,
        }
    }
}

/// Where a canvas points. A separate type rather than three more `Surface` variants,
/// because "repoint this canvas" must not be able to turn it into a terminal — a terminal
/// that quietly became a canvas is a pane whose pty has nowhere to render (helm's
/// `Workbench.repoint`), and with this type the wrong call does not compile.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum CanvasSource {
    File {
        path: StandardPath,
    },
    Url {
        url: String,
    },
    /// ⌘L before an address is committed. Persisted as itself so the empty pane comes back
    /// rather than vanishing.
    Empty,
}

/// The coarse classes placement distinguishes. Every canvas source is one class: helm's
/// rule "the operator put a canvas there, so that is where canvases go" never cared whether
/// it was a file or a page.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SurfaceClass {
    Terminal,
    Canvas,
    Browser,
}

/// The agent a terminal pane held (helm `ResumableAgent`), recorded so a restart can offer
/// to resume the conversation. The offer itself is helm's; this is only the record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
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
#[serde(deny_unknown_fields)]
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
            (
                Surface::Canvas {
                    source: CanvasSource::Url {
                        url: "http://localhost:3000".into(),
                    },
                },
                json!({"kind": "canvas", "source": {"kind": "url", "url": "http://localhost:3000"}}),
            ),
            (
                Surface::Canvas {
                    source: CanvasSource::Empty,
                },
                json!({"kind": "canvas", "source": {"kind": "empty"}}),
            ),
            (Surface::Browser, json!({"kind": "browser"})),
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
