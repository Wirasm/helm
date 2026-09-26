//! A terminal pane that shows a benchd session (M3): found by its session, and forgotten when
//! the daemon that ran the session is gone.

mod common;

use bench_doc::{Document, DrawerName, Focus, Pane, ResumableAgent, StandardPath, Surface};

fn session_pane(session: &str) -> Pane {
    Pane::new(Surface::Terminal {
        agent: Some(ResumableAgent {
            command: "claude".into(),
            session: "4b1c".into(),
            cwd: "/tmp/w".into(),
        }),
        session: Some(session.into()),
    })
}

#[test]
fn a_session_pane_is_found_wherever_it_lives_and_forgotten_at_boot() {
    let mut doc = Document::default();
    let on_bench = session_pane("s1");
    let bench_id = on_bench.id;
    doc.open_workspace(StandardPath::new("/tmp/w").unwrap(), on_bench, Focus::Take)
        .unwrap();
    let in_drawer = session_pane("s2");
    let drawer_id = in_drawer.id;
    doc.place_in_drawer(&DrawerName::new("agents").unwrap(), in_drawer, Focus::Leave)
        .unwrap();

    assert_eq!(doc.pane_showing_session("s1"), Some(bench_id));
    assert_eq!(doc.pane_showing_session("s2"), Some(drawer_id));
    assert_eq!(doc.pane_showing_session("s3"), None);
    assert!(doc.pane(drawer_id).is_some());

    let ended = doc.end_sessions();
    assert_eq!(ended.len(), 2);
    assert!(ended.contains(&bench_id) && ended.contains(&drawer_id));
    assert_eq!(doc.pane_showing_session("s1"), None);
    // The pane stays, and keeps what it needs for the resume offer.
    match &doc.pane(bench_id).unwrap().surface {
        Surface::Terminal { agent, session } => {
            assert!(agent.is_some());
            assert!(session.is_none());
        }
        other => panic!("{other:?}"),
    }
    assert!(
        doc.end_sessions().is_empty(),
        "a second sweep finds nothing"
    );
}
