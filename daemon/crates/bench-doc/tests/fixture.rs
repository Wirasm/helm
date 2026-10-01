//! `daemon/fixtures/bench-document.json` is the one sample of the document both gates read:
//! this suite pins that the Rust types read it and write it back **byte for byte**, and
//! helm's Swift decoder (M4 PR 3) decodes the same file — the #352/#353 pattern, so neither gate needs the other's toolchain and a renamed field
//! fails the gate that renamed it.
//!
//! The fixture is meant to be hand-read, so it holds one of everything: three workspaces,
//! every surface kind, both kinds of name, a recorded agent, and two drawers —
//! one open, one closed and badged.

use bench_doc::{CanvasSource, Document, DrawerEdge, DrawerName, PaneName, Surface};
use std::path::PathBuf;

fn fixture() -> (PathBuf, String) {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/bench-document.json");
    let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
    (path, text)
}

#[test]
fn the_fixture_reads_and_writes_back_byte_for_byte() {
    let (path, text) = fixture();

    let doc: Document = serde_json::from_str(&text).expect("the fixture decodes");
    let written = serde_json::to_string_pretty(&doc).unwrap() + "\n";

    assert_eq!(
        written,
        text,
        "the Rust spelling of the document drifted from {} — if the change is intended, \
         update the fixture and helm's decoder together",
        path.display()
    );
}

#[test]
fn the_fixture_holds_one_of_everything() {
    let (_, text) = fixture();
    let doc: Document = serde_json::from_str(&text).unwrap();
    let benches = doc.workspaces().iter().map(|w| &w.bench);
    let panes: Vec<_> = benches.flat_map(|b| b.panes()).collect();
    let has = |f: &dyn Fn(&Surface) -> bool| panes.iter().any(|p| f(&p.surface));

    assert_eq!(doc.workspaces().len(), 3);
    assert!(doc.active().is_some());
    assert!(
        has(&|s| matches!(s, Surface::Terminal { agent: None, .. })),
        "a plain terminal"
    );
    assert!(
        has(&|s| matches!(s, Surface::Terminal { agent: Some(_), .. })),
        "a recorded agent"
    );
    assert!(
        has(&|s| s.session().is_some()),
        "a terminal showing a benchd session (M3)"
    );
    assert!(
        has(&|s| matches!(s, Surface::Terminal { cwd: Some(_), .. })),
        "a terminal whose shell's directory was read (M5b)"
    );
    assert!(has(&|s| matches!(s, Surface::Browser)), "the browser");
    let canvas = |want: fn(&CanvasSource) -> bool| {
        has(&|s| matches!(s, Surface::Canvas { source } if want(source)))
    };
    assert!(
        canvas(|s| matches!(s, CanvasSource::File { .. })),
        "a file canvas"
    );
    assert!(
        panes.iter().any(|p| p.opener.is_some()),
        "a canvas an agent opened (helm #532)"
    );
    assert!(
        panes.iter().any(|p| p.author.is_some()),
        "a canvas that names the conversation that opened it (helm #535)"
    );
    assert!(
        panes.iter().any(|p| matches!(p.name, PaneName::Derived(_))),
        "a derived name"
    );
    assert!(
        panes.iter().any(|p| matches!(p.name, PaneName::Chosen(_))),
        "a chosen name"
    );
    assert!(
        panes.iter().any(|p| p.name.is_unnamed()),
        "and an unnamed pane"
    );
    let open = doc.open_drawer().expect("an open drawer");
    assert!(open.panes.len() > 1, "holding more than one tab");
    assert!(
        doc.drawers()
            .iter()
            .any(|d| d.badged && d.name != open.name),
        "a closed drawer an agent badged"
    );
    let notes = DrawerName::new("notes").unwrap();
    let browser = DrawerName::new("browser").unwrap();
    assert!(
        doc.drawer(&notes).is_some() && doc.drawer_edge(&notes) == Some(DrawerEdge::Bottom),
        "a drawer the operator put against an edge (#178)"
    );
    assert!(
        doc.drawer(&browser).is_none() && doc.drawer_edge(&browser).is_some(),
        "and an edge kept for a drawer that is gone"
    );
}
