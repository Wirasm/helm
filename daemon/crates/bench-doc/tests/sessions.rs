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
        cwd: None,
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
        Surface::Terminal { agent, session, .. } => {
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

/// helm #535: a canvas keeps the conversation that opened it, whatever its opener's pane holds
/// later. The pane's own record follows the agent (a `/clear` replaces it, an exit clears it);
/// a fork asked about the canvas has to reach the conversation that wrote the file.
#[test]
fn a_canvas_keeps_the_conversation_that_opened_it() {
    let mut doc = Document::default();
    let terminal = session_pane("s1");
    let opener = terminal.id;
    doc.open_workspace(StandardPath::new("/tmp/w").unwrap(), terminal, Focus::Take)
        .unwrap();
    let canvas = Pane::new(Surface::Canvas {
        source: bench_doc::CanvasSource::File {
            path: StandardPath::new("/tmp/w/plan.md").unwrap(),
        },
    });
    let canvas_id = canvas.id;
    doc.place_in_drawer(&DrawerName::new("docs").unwrap(), canvas, Focus::Leave)
        .unwrap();
    let author = |doc: &Document| doc.pane(canvas_id).unwrap().author.clone();

    assert!(doc.record_opener(canvas_id, opener));
    let wrote = author(&doc).expect("the opener's conversation is recorded");
    assert_eq!(
        (wrote.command.as_str(), wrote.session.as_str()),
        ("claude", "4b1c")
    );

    // The agent `/clear`s: its pane now holds another conversation. The canvas does not follow.
    let cleared = ResumableAgent {
        command: "claude".into(),
        session: "9e0f".into(),
        cwd: "/tmp/w".into(),
    };
    doc.record_agent(opener, Some(cleared.clone()), Focus::Leave)
        .unwrap();
    assert_eq!(author(&doc), Some(wrote.clone()));
    // It exits: the pane holds nothing. The canvas still names the conversation.
    doc.record_agent(opener, None, Focus::Leave).unwrap();
    assert_eq!(author(&doc), Some(wrote));

    // Opened again, from a pane with no conversation: the newest open wins for both fields.
    assert!(doc.record_opener(canvas_id, opener));
    assert_eq!(author(&doc), None);
    doc.record_agent(opener, Some(cleared.clone()), Focus::Leave)
        .unwrap();
    assert!(doc.record_opener(canvas_id, opener));
    assert_eq!(author(&doc), Some(cleared));
    assert!(!doc.record_opener(canvas_id, opener), "nothing changed");
}
