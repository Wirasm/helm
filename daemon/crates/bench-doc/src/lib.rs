//! The bench document — the layout primitive of `bench-architecture.md`, owned by benchd.
//!
//! Workspaces → columns → slots → panes, each pane a view of one typed [`Surface`], and every
//! rule that changes them: `normalize()`'s invariants, placement as data, and the focus rule.
//! No IO, no sockets, no clock — the same shape as `bench-mail`: benchd calls this, logs what
//! happened, and answers. Ported from helm's `Workbench` (`Sources/Helm/Workbench/`), whose
//! tests are mirrored one for one under `tests/`, named after the Swift test they came from.
//!
//! The types live here rather than in `bench-wire` because Rust keeps a type's methods in
//! the crate that defines it, and the rules *are* the methods. They are still spelled once:
//! both binaries and the shared fixtures (`daemon/fixtures/bench-document.json`) read these.

mod bench;
mod document;
mod ids;
mod placement;
mod refusal;
mod surface;

pub use bench::{Bench, Column, Direction, Focus, MINIMUM_FRACTION, Pane, Placement, Slot, Split};
pub use document::{Document, Target, Workspace};
pub use ids::{ColumnId, PaneId, SlotId, StandardPath};
pub use placement::{Caller, Rule, Rules, Strategy};
pub use refusal::Refusal;
pub use surface::{CanvasSource, PaneName, ResumableAgent, Surface, SurfaceClass};
