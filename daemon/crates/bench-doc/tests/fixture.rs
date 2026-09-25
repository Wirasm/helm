//! `daemon/fixtures/bench-document.json` is the one sample of the document both gates read:
//! this suite pins that the Rust types read it and write it back **byte for byte**, and
//! helm's Swift decoder (M4 PR 3) decodes the same file — the #352/#353 pattern
//! (`browser-endpoint.json`), so neither gate needs the other's toolchain and a renamed field
//! fails the gate that renamed it.
//!
//! The fixture is meant to be hand-read, so it holds one of everything: three workspaces, a
//! shelved bench, every surface kind, both kinds of name, a recorded agent.

use bench_doc::{CanvasSource, Document, PaneName, Surface};
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
    let benches = doc
        .workspaces()
        .iter()
        .flat_map(|w| std::iter::once(&w.bench).chain(w.shelved.as_ref()));
    let panes: Vec<_> = benches.flat_map(|b| b.panes()).collect();
    let has = |f: &dyn Fn(&Surface) -> bool| panes.iter().any(|p| f(&p.surface));

    assert_eq!(doc.workspaces().len(), 3);
    assert!(doc.active().is_some());
    assert!(
        doc.workspaces().iter().any(|w| w.shelved.is_some()),
        "a shelved bench"
    );
    assert!(
        has(&|s| matches!(s, Surface::Terminal { agent: None })),
        "a plain terminal"
    );
    assert!(
        has(&|s| matches!(s, Surface::Terminal { agent: Some(_) })),
        "a recorded agent"
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
}
