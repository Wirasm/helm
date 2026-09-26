//! Mirrors `Tests/HelmTests/Workbench/WorkbenchPlacementTests.swift` against
//! `Rules::defaults()`, plus the browser's rule from #353, and the rules as data: the embedded
//! default file pinned against a hand-built table, and the TOML spelling of every strategy. `placement(forOpening:)` is a canvas opened by anyone; `placementForNewTerminal` is a
//! terminal the operator opened; `placementForSpawnedTerminal` is one an agent opened.

mod common;

use bench_doc::{
    Bench, Caller, Destination, DrawerName, Focus, Pane, PaneId, Placement, Rule, Rules, Split,
    Strategy, Surface, SurfaceClass,
};
use common::*;

/// Every default rule places on the bench; a drawer destination here is a changed default.
fn place(bench: &Bench, surface: &Surface, caller: Caller) -> Placement {
    match Rules::defaults().place(bench, surface, caller) {
        Destination::Bench(placement) => placement,
        other => panic!("the defaults sent {surface:?} to {other:?}"),
    }
}

fn opening(bench: &Bench, path: &str) -> Placement {
    place(bench, &file(path), Caller::Agent)
}

fn new_terminal(bench: &Bench) -> Placement {
    place(bench, &Surface::terminal(), Caller::Operator)
}

fn spawned_terminal(bench: &Bench) -> Placement {
    place(bench, &Surface::terminal(), Caller::Agent)
}

#[test]
fn an_already_open_source_is_selected_rather_than_opened_again() {
    let mut bench = Bench::terminal(PaneId::mint());
    let open = canvas("/tmp/plan.md");
    let open_id = open.id;
    bench.place(open, Placement::Column, Focus::Take).unwrap();

    assert_eq!(
        opening(&bench, "/tmp/plan.md"),
        Placement::Existing(open_id),
        "⌘-clicking the same link twice selects the canvas you already have"
    );
    assert_eq!(
        place(&bench, &file("/tmp/plan.md"), Caller::Operator),
        Placement::Existing(open_id),
        "the canvas rule is the same whoever opens it"
    );
}

#[test]
fn todays_frame_at_one_by_one_puts_the_first_canvas_in_a_new_column() {
    let bench = Bench::terminal(PaneId::mint());

    assert_eq!(
        opening(&bench, "/tmp/plan.md"),
        Placement::Column,
        "where the dock was"
    );
}

#[test]
fn a_focused_slot_already_holding_a_canvas_takes_the_new_one_as_a_tab() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench
        .place(canvas("/tmp/plan.md"), Placement::Column, Focus::Take)
        .unwrap();
    let canvas_slot = bench.focused_slot();

    assert_eq!(
        opening(&bench, "/tmp/tasks.md"),
        Placement::Tab(canvas_slot),
        "the tenth offered canvas must not create a tenth column"
    );
}

#[test]
fn any_other_slot_holding_a_canvas_takes_it_when_the_focused_one_does_not() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench
        .place(canvas("/tmp/plan.md"), Placement::Column, Focus::Take)
        .unwrap();
    let canvas_slot = bench.focused_slot();
    bench.focus_slot(bench.columns()[0].slots[0].id).unwrap();

    assert_eq!(
        opening(&bench, "/tmp/tasks.md"),
        Placement::Tab(canvas_slot),
        "the first slot in column order that holds a canvas takes it"
    );
}

#[test]
fn a_slot_mixing_a_terminal_and_a_canvas_still_counts_as_a_canvas_slot() {
    let shell = terminal();
    let shell_id = shell.id;
    let bench = bench_of(vec![shell, canvas("/tmp/plan.md")], Some(shell_id));

    assert_eq!(
        opening(&bench, "/tmp/tasks.md"),
        Placement::Tab(bench.focused_slot())
    );
}

#[test]
fn a_new_terminal_is_a_tab_in_the_focused_slot() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();

    assert_eq!(
        new_terminal(&bench),
        Placement::Tab(bench.focused_slot()),
        "⌘N appends to the slot you are in"
    );
}

#[test]
fn a_spawn_while_a_canvas_has_focus_is_not_a_tab_on_the_canvas() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench
        .place(canvas("/tmp/plan.md"), Placement::Column, Focus::Take)
        .unwrap();
    let canvas_slot = bench.focused_slot();

    let placement = spawned_terminal(&bench);

    assert_ne!(
        placement,
        Placement::Tab(canvas_slot),
        "not stacked onto the canvas (#177)"
    );
    assert_eq!(
        placement,
        Placement::Column,
        "a column of its own at the right end"
    );
}

#[test]
fn a_spawn_ignores_focus_even_when_focus_is_on_a_terminal() {
    let bench = Bench::terminal(PaneId::mint());

    assert_eq!(
        new_terminal(&bench),
        Placement::Tab(bench.focused_slot()),
        "⌘N is unchanged"
    );
    assert_eq!(
        spawned_terminal(&bench),
        Placement::Column,
        "a spawn nobody is watching must be visible, and a tab is hidden"
    );
}

#[test]
fn a_spawn_always_gets_a_new_column_even_beside_a_column_of_terminals() {
    let mut bench = bench_of(vec![canvas("/tmp/plan.md")], None);
    bench
        .place(terminal(), Placement::Column, Focus::Take)
        .unwrap();
    bench
        .place(terminal(), Placement::Column, Focus::Take)
        .unwrap();

    assert_eq!(spawned_terminal(&bench), Placement::Column);
}

#[test]
fn a_spawn_onto_an_all_canvas_bench_gets_a_column_of_its_own() {
    let mut bench = bench_of(vec![canvas("/tmp/plan.md")], None);
    bench
        .place(canvas("/tmp/tasks.md"), Placement::Column, Focus::Take)
        .unwrap();

    assert_eq!(spawned_terminal(&bench), Placement::Column);
}

#[test]
fn paths_are_standardised_so_the_same_file_is_one_canvas() {
    let mut bench = Bench::terminal(PaneId::mint());
    let open = canvas("/tmp/./plan.md");
    let open_id = open.id;
    bench.place(open, Placement::Column, Focus::Take).unwrap();

    assert_eq!(
        opening(&bench, "/tmp/plan.md"),
        Placement::Existing(open_id),
        "the rule compares by value, so an unstandardised path would open a second copy"
    );
}

// MARK: - The browser (#353's `placementForBrowser`)

#[test]
fn the_browser_goes_to_the_pane_already_showing_it_else_a_new_column() {
    let mut bench = Bench::terminal(PaneId::mint());
    assert_eq!(
        place(&bench, &Surface::Browser, Caller::Operator),
        Placement::Column
    );

    let browser = Pane::new(Surface::Browser);
    let browser_id = browser.id;
    bench
        .place(browser, Placement::Column, Focus::Take)
        .unwrap();

    assert_eq!(
        place(&bench, &Surface::Browser, Caller::Agent),
        Placement::Existing(browser_id),
        "one shared browser, so a second pane onto it would be a second copy of one tab"
    );
    assert_eq!(
        place(&bench, &file("/tmp/plan.md"), Caller::Operator),
        Placement::Column,
        "and a browser slot is not a canvas slot"
    );
}

// MARK: - Data, not code

#[test]
fn a_different_table_changes_placement_without_touching_any_operation() {
    let bench = Bench::terminal(PaneId::mint());
    let rules = Rules {
        rules: vec![Rule {
            surface: SurfaceClass::Terminal,
            caller: Some(Caller::Agent),
            strategies: vec![Strategy::TabInFocused],
        }],
    };

    assert_eq!(
        rules.place(&bench, &Surface::terminal(), Caller::Agent),
        Destination::Bench(Placement::Tab(bench.focused_slot())),
        "the same bench, the same request, a different rule"
    );
    assert_eq!(
        rules.place(&bench, &file("/tmp/plan.md"), Caller::Agent),
        Destination::Bench(Placement::Column),
        "a surface no rule mentions gets the one destination that always exists"
    );
}

// MARK: - The rules file (#356)

/// The control that the embedded file *is* today's table: it fails if a row is dropped,
/// reordered or loosened, which no placement test above would notice for a row it never asks.
#[test]
fn the_embedded_defaults_are_todays_four_rows() {
    use Strategy::*;
    let expected = Rules {
        rules: vec![
            Rule {
                surface: SurfaceClass::Canvas,
                caller: None,
                strategies: vec![
                    Existing,
                    TabInFocusedIfHolds(SurfaceClass::Canvas),
                    TabInFirstHolding(SurfaceClass::Canvas),
                    NewColumn,
                ],
            },
            Rule {
                surface: SurfaceClass::Terminal,
                caller: Some(Caller::Operator),
                strategies: vec![TabInFocused],
            },
            Rule {
                surface: SurfaceClass::Terminal,
                caller: Some(Caller::Agent),
                strategies: vec![NewColumn],
            },
            Rule {
                surface: SurfaceClass::Browser,
                caller: None,
                strategies: vec![Existing, NewColumn],
            },
        ],
    };
    assert_eq!(Rules::defaults(), expected);
}

#[test]
fn every_strategy_is_spelled_in_the_file() {
    let rules = Rules::parse(
        r#"
        [[place]]
        surface = "canvas"
        try = [
            "existing",
            "tab-in-focused",
            { tab-in-focused-if-holds = "terminal" },
            { tab-in-first-holding = "browser" },
            "new-column",
            { drawer = "notes" },
        ]
        "#,
    )
    .unwrap();
    assert_eq!(
        rules,
        Rules {
            rules: vec![Rule {
                surface: SurfaceClass::Canvas,
                caller: None,
                strategies: vec![
                    Strategy::Existing,
                    Strategy::TabInFocused,
                    Strategy::TabInFocusedIfHolds(SurfaceClass::Terminal),
                    Strategy::TabInFirstHolding(SurfaceClass::Browser),
                    Strategy::NewColumn,
                    Strategy::Drawer(DrawerName::new("notes").unwrap()),
                ],
            }],
        },
        "`by` left out means any caller"
    );
}

#[test]
fn a_file_that_cannot_be_read_is_refused_whole_naming_the_line() {
    for (text, names) in [
        (
            "[[place]]\nsurface = \"canvas\"\ntry = [\"existing\", \"sideways\"]\n",
            "sideways",
        ),
        (
            "[[place]]\nsurface = \"canvas\"\ntyr = [\"existing\"]\n",
            "tyr",
        ),
        (
            "[[place]]\nsurface = \"whiteboard\"\ntry = [\"new-column\"]\n",
            "whiteboard",
        ),
        (
            "[[place]]\nsurface = \"canvas\"\ntry = [{ drawer = \"My Notes\" }]\n",
            "My Notes",
        ),
        ("[[place]\n", "line 1"),
    ] {
        let why = Rules::parse(text).expect_err(text);
        assert!(why.contains(names), "{names:?} in: {why}");
        assert!(why.contains("line"), "the refusal names a line: {why}");
    }
}

#[test]
fn a_file_with_no_rules_is_refused_not_read_as_an_empty_table() {
    for text in ["", "  \n# only a comment\n", "place = []\n"] {
        let why = Rules::parse(text).expect_err(text);
        assert!(why.contains("delete the file"), "{why}");
    }
}

#[test]
fn a_drawer_strategy_sends_the_pane_to_that_drawer() {
    let bench = Bench::terminal(PaneId::mint());
    let rules = Rules::parse(
        "[[place]]\nsurface = \"browser\"\nby = \"agent\"\ntry = [\"existing\", { drawer = \"browser\" }]\n",
    )
    .unwrap();
    assert_eq!(
        rules.place(&bench, &Surface::Browser, Caller::Agent),
        Destination::Drawer(DrawerName::new("browser").unwrap())
    );
    assert_eq!(
        rules.place(&bench, &Surface::Browser, Caller::Operator),
        Destination::Bench(Placement::Column),
        "a row for agents says nothing about the operator"
    );
}
