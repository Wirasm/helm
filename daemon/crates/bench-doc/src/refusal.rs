//! Why an operation did nothing.
//!
//! helm's `Workbench` answered most of these with a silent `guard … else { return }`, which
//! was right for a value the app itself drove and is wrong behind a socket: a caller told
//! "ok" about a pane that no longer exists believes something false. So every no-op that
//! is not the operation's ordinary answer is a refusal with a reason, and the bench is left
//! exactly as it was.

use crate::drawer::DrawerName;
use crate::ids::{ColumnId, PaneId, SlotId, StandardPath};
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    UnknownPane(PaneId),
    UnknownSlot(SlotId),
    UnknownColumn(ColumnId),
    /// A move named a pane to land before, and the destination slot does not hold it.
    NotInSlot {
        pane: PaneId,
        slot: SlotId,
    },
    UnknownWorkspace(StandardPath),
    /// A pane moved to a workspace whose bench already shows its surface (`Surface::already_shows`):
    /// a bench holds one pane per canvas file, one browser, one view of a session.
    AlreadyShown {
        pane: PaneId,
        workspace: StandardPath,
    },
    NoActiveWorkspace,
    /// The bench's last pane: a bench with nothing in it is not a state worth reaching.
    LastPane(PaneId),
    /// Pane ids are one namespace across the whole document.
    DuplicatePane(PaneId),
    /// A resize names two members a divider does not sit between.
    NotADivider,
    NotATerminal(PaneId),
    /// Opening a drawer that holds nothing, with nothing named to put in it.
    EmptyDrawer(DrawerName),
    /// Where a drawer sits is the operator's: an agent moves one only when he asked (#178).
    DrawerPlacement(DrawerName),
    /// Drawer names are one namespace across the document.
    DuplicateDrawer(DrawerName),
    /// A bench verb (a move, a resize, a focus) named a pane that lives in a drawer.
    PaneInDrawer {
        pane: PaneId,
        drawer: DrawerName,
    },
    /// The focus rule (bench-architecture.md): a change that would move the operator's
    /// focus, asked for by someone who did not say the operator asked.
    WouldMoveFocus,
    /// `focus/waiting` with no agent needing the operator: none asking, none finished unseen,
    /// no mail to him.
    NothingWaiting,
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Refusal::UnknownPane(id) => write!(f, "no pane {id} on the bench"),
            Refusal::UnknownSlot(id) => write!(f, "no slot {id} on the bench"),
            Refusal::UnknownColumn(id) => write!(f, "no column {id} on the bench"),
            Refusal::NotInSlot { pane, slot } => {
                write!(
                    f,
                    "slot {slot} does not hold pane {pane} to put a tab before"
                )
            }
            Refusal::UnknownWorkspace(path) => write!(f, "no workspace {path} is open"),
            Refusal::AlreadyShown { pane, workspace } => write!(
                f,
                "workspace {workspace} already shows that in pane {pane} — show that pane instead"
            ),
            Refusal::NoActiveWorkspace => write!(f, "no workspace is active"),
            Refusal::LastPane(id) => write!(
                f,
                "pane {id} is the bench's last pane — a bench with nothing in it is not a state to reach"
            ),
            Refusal::DuplicatePane(id) => {
                write!(
                    f,
                    "pane {id} is already on the bench — pane ids are one namespace"
                )
            }
            Refusal::NotADivider => write!(
                f,
                "those two are not either side of one divider — a resize trades between adjacent members only"
            ),
            Refusal::NotATerminal(id) => write!(f, "pane {id} is not a terminal"),
            Refusal::EmptyDrawer(name) => write!(
                f,
                "drawer {name} holds nothing — name a surface to open it with"
            ),
            Refusal::DuplicateDrawer(name) => write!(f, "drawer {name} appears twice"),
            Refusal::DrawerPlacement(name) => write!(
                f,
                "where drawer {name} sits is the operator's, and the operator did not ask — pass --asked when they did"
            ),
            Refusal::PaneInDrawer { pane, drawer } => write!(
                f,
                "pane {pane} is in drawer {drawer}, and this verb acts on the bench"
            ),
            Refusal::WouldMoveFocus => write!(
                f,
                "this would move the operator's focus, and the operator did not ask — pass --asked when they did"
            ),
            Refusal::NothingWaiting => write!(
                f,
                "no agent needs you: none asking, none finished unseen, no mail"
            ),
        }
    }
}

impl std::error::Error for Refusal {}
