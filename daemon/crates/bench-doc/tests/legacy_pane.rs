//! Mirrors the value tests of `Tests/HelmTests/Workbench/WorkbenchLegacyPaneTests.swift`:
//! a stored document loses no more than the pane it cannot read. The Swift file's
//! `UserDefaults` case (`testOneWorkspacesLegacyPaneDoesNotWipeEveryOtherWorkspacesLayout`)
//! is mirrored at the level that replaces `UserDefaults` here — one document, many workspaces.
//! Its `testOnlyTwoPaneKindsEncodeAndAThirdDoesNotDecode` is `surface.rs`'s
//! `an_unknown_surface_kind_is_refused_naming_the_kind`: the strict decode still refuses.

use bench_doc::{Bench, Document, PaneId, PaneName, Surface};
use serde_json::{Value, json};

const TERMINAL: &str = "44444444-4444-4444-4444-444444444444";
const CANVAS: &str = "55555555-5555-5555-5555-555555555555";
const ARCHON: &str = "11111111-1111-1111-1111-111111111111";
const SLOT: &str = "22222222-2222-2222-2222-222222222222";

fn archon_pane() -> Value {
    json!({"id": ARCHON, "surface": {"kind": "archonRun", "run": {"kind": "run", "id": "r1"}}})
}
fn terminal_pane(id: &str) -> Value {
    json!({"id": id, "surface": {"kind": "terminal"}})
}
fn canvas_pane(id: &str) -> Value {
    json!({"id": id, "surface": {"kind": "canvas", "source": {"kind": "file", "path": "/tmp/plan.md"}}})
}

/// A one-slot bench whose `selected` names the archon pane, as the Swift fixture does.
fn bench(panes: Vec<Value>) -> Value {
    json!({
        "columns": [{"id": "33333333-3333-3333-3333-333333333333", "width": 1.0, "slots": [
            {"id": SLOT, "height": 1.0, "selected": ARCHON, "panes": panes}
        ]}],
        "focused_slot": SLOT
    })
}

fn ids(bench: &Bench) -> Vec<String> {
    bench.panes().map(|p| p.id.to_string()).collect()
}

#[test]
fn an_unknown_pane_kind_is_skipped_and_the_rest_of_the_slot_survives() {
    let stored = bench(vec![
        terminal_pane(TERMINAL),
        archon_pane(),
        canvas_pane(CANVAS),
    ]);

    let read = Bench::read_tolerant(stored).unwrap();

    assert_eq!(
        ids(&read.value),
        vec![TERMINAL, CANVAS],
        "the archonRun pane goes, nothing else"
    );
    assert_eq!(
        read.value.slots().count(),
        1,
        "a slot that still holds panes is not dropped"
    );
    assert_eq!(
        read.notes.len(),
        1,
        "and the skip is reported, not silent: {:?}",
        read.notes
    );
    assert!(read.notes[0].contains(ARCHON), "{:?}", read.notes);
}

#[test]
fn a_selection_that_named_the_skipped_pane_is_repointed() {
    let stored = bench(vec![archon_pane(), terminal_pane(TERMINAL)]);

    let read = Bench::read_tolerant(stored).unwrap();

    let slot = read.value.slots().next().unwrap();
    assert_eq!(
        slot.selected.to_string(),
        TERMINAL,
        "normalize() repoints what named it"
    );
}

#[test]
fn a_bench_of_nothing_but_the_removed_type_is_refused_rather_than_rendered_empty() {
    let err = Bench::read_tolerant(bench(vec![archon_pane()])).unwrap_err();

    assert!(err.contains("no panes"), "{err}");
}

#[test]
fn one_workspaces_legacy_pane_does_not_wipe_every_other_workspaces_layout() {
    let survivor = Bench::terminal(PaneId::mint());
    let stored = json!({
        "workspaces": [
            {"path": "/work/with-a-run", "bench": bench(vec![archon_pane(), terminal_pane(TERMINAL)])},
            {"path": "/work/only-a-run", "bench": bench(vec![archon_pane()]),
             "shelved": bench(vec![archon_pane()])},
            {"path": "/work/plain", "bench": serde_json::to_value(&survivor).unwrap()}
        ],
        "active": "/work/plain"
    });
    assert!(
        serde_json::from_value::<Document>(stored.clone()).is_err(),
        "the strict decode is what the tolerant one exists to avoid"
    );

    let read = Document::read_tolerant(stored).unwrap();

    let doc = read.value;
    assert_eq!(doc.workspaces().len(), 3, "every workspace keeps its place");
    assert_eq!(
        ids(&doc.workspaces()[0].bench),
        vec![TERMINAL],
        "the pane it can read stays"
    );
    let fallback = &doc.workspaces()[1];
    assert_eq!(
        fallback.bench.panes().count(),
        1,
        "an unrecoverable bench is today's 1×1"
    );
    assert!(matches!(
        fallback.bench.panes().next().unwrap().surface,
        Surface::Terminal { agent: None }
    ));
    assert_eq!(fallback.shelved, None, "an unreadable shelf is dropped");
    assert_eq!(
        doc.workspaces()[2].bench,
        survivor,
        "a workspace that never held one is untouched"
    );
    assert_eq!(
        read.notes.len(),
        3,
        "every loss is a sentence: {:#?}",
        read.notes
    );
    assert!(
        read.notes[1].contains(ARCHON),
        "a lost bench still names the pane it lost: {:#?}",
        read.notes
    );
}

#[test]
fn a_malformed_agent_costs_the_pane_its_resume_record_not_the_pane() {
    let mut pane = terminal_pane(TERMINAL);
    pane["surface"]["agent"] = json!({"command": "claude"});

    let read = Bench::read_tolerant(bench(vec![pane])).unwrap();

    let kept = read.value.panes().next().unwrap();
    assert_eq!(kept.id.to_string(), TERMINAL);
    assert_eq!(kept.surface, Surface::Terminal { agent: None });
    assert!(read.notes[0].contains("agent"), "{:?}", read.notes);
}

#[test]
fn a_malformed_name_costs_the_pane_its_name_not_the_pane() {
    let mut pane = canvas_pane(CANVAS);
    pane["name"] = json!("just a string");

    let read = Bench::read_tolerant(bench(vec![pane])).unwrap();

    let kept = read.value.panes().next().unwrap();
    assert_eq!(kept.id.to_string(), CANVAS);
    assert_eq!(kept.name, PaneName::Unnamed);
    assert!(read.notes[0].contains("name"), "{:?}", read.notes);
}

#[test]
fn a_field_a_newer_build_added_is_ignored_not_fatal() {
    let mut pane = terminal_pane(TERMINAL);
    pane["surface"]["session"] = json!("s7");
    pane["pinned"] = json!(true);

    let strict: Bench = serde_json::from_value(bench(vec![pane.clone()])).unwrap();
    let read = Bench::read_tolerant(bench(vec![pane])).unwrap();

    assert_eq!(ids(&strict), vec![TERMINAL]);
    assert_eq!(read.value, strict);
    assert!(
        read.notes.is_empty(),
        "nothing was lost, so nothing is reported"
    );
}

#[test]
fn a_workspace_with_no_readable_path_is_dropped_and_its_siblings_survive() {
    let healthy = |path: &str| json!({"path": path, "bench": bench(vec![terminal_pane_fresh()])});
    for bad in [
        json!({"bench": bench(vec![archon_pane()])}),
        json!({"path": "relative/dir", "bench": bench(vec![archon_pane()])}),
        json!("not a workspace"),
    ] {
        let stored = json!({
            "workspaces": [healthy("/work/a"), bad.clone(), healthy("/work/b")],
            "active": "/work/b"
        });

        let read = Document::read_tolerant(stored).unwrap();

        let paths: Vec<_> = read
            .value
            .workspaces()
            .iter()
            .map(|w| w.path.to_string())
            .collect();
        assert_eq!(
            paths,
            vec!["/work/a", "/work/b"],
            "{bad}: the siblings survive"
        );
        assert_eq!(
            read.value.active().map(|p| p.to_string()).as_deref(),
            Some("/work/b")
        );
        assert_eq!(
            read.notes.len(),
            1,
            "{bad}: and the drop is reported: {:?}",
            read.notes
        );
    }
}

#[test]
fn an_active_workspace_that_did_not_survive_falls_back_to_the_first() {
    for active in [json!("/work/gone"), json!("relative"), json!(42)] {
        let stored = json!({
            "workspaces": [
                {"path": "/work/a", "bench": bench(vec![terminal_pane_fresh()])},
                {"path": "/work/b", "bench": bench(vec![terminal_pane_fresh()])}
            ],
            "active": active.clone()
        });

        let read = Document::read_tolerant(stored).unwrap();

        assert_eq!(
            read.value.active().map(|p| p.to_string()).as_deref(),
            Some("/work/a"),
            "{active}: helm shows the first when the remembered one is gone"
        );
        assert_eq!(read.notes.len(), 1, "{active}: {:?}", read.notes);
    }

    let nothing_active = json!({
        "workspaces": [{"path": "/work/a", "bench": bench(vec![terminal_pane_fresh()])}],
        "active": null
    });
    let read = Document::read_tolerant(nothing_active).unwrap();
    assert_eq!(
        read.value.active(),
        None,
        "nothing active is a state, not a loss"
    );
    assert!(read.notes.is_empty());
}

/// A terminal pane with its own id, for tests that hold several benches in one document.
fn terminal_pane_fresh() -> Value {
    terminal_pane(&PaneId::mint().to_string())
}
