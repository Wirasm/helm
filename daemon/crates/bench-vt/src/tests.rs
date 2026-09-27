use super::*;

fn term() -> Terminal {
    Terminal::new(20, 5, 1 << 20).unwrap()
}

fn plain(t: &Terminal) -> String {
    String::from_utf8(t.format(Format::Plain).unwrap()).unwrap()
}

#[test]
fn text_lands_on_the_screen_and_moves_the_cursor() {
    let mut t = term();
    t.write(b"hello\r\nworld");
    assert_eq!(plain(&t).trim_end(), "hello\nworld");
    assert_eq!(t.cursor(), (5, 1));
    assert_eq!(t.size(), (20, 5));
}

#[test]
fn a_resize_changes_the_size() {
    let mut t = term();
    t.resize(40, 10).unwrap();
    assert_eq!(t.size(), (40, 10));
}

#[test]
fn modes_title_pwd_and_the_alternate_screen_are_read_back() {
    let mut t = term();
    assert!(!t.mode(Mode::BRACKETED_PASTE));
    assert!(!t.alt_screen());
    t.write(b"\x1b[?2004h\x1b]2;my title\x07\x1b]7;file://host/tmp/x\x07\x1b[?1049h");
    assert!(t.mode(Mode::BRACKETED_PASTE));
    assert_eq!(t.title(), "my title");
    assert!(t.pwd().ends_with("/tmp/x"), "{}", t.pwd());
    assert!(t.alt_screen());
}

#[test]
fn a_device_attributes_query_is_answered_as_ghostty_answers_it() {
    let mut t = term();
    t.write(b"\x1b[c\x1b[>c");
    assert_eq!(t.take_replies(), b"\x1b[?62;22c\x1b[>1;10;0c");
    assert!(t.take_replies().is_empty(), "taken once");
}

#[test]
fn a_synchronized_update_holds_until_it_ends_or_is_released() {
    let mut t = term();
    t.write(b"\x1b[?2026h");
    assert!(t.held());
    t.write(b"\x1b[?2026l");
    assert!(!t.held());
    t.write(b"\x1b[?2026h");
    t.release_hold().unwrap();
    assert!(!t.held());
}

/// The replay contract: formatting one terminal and feeding the result to a fresh one of the
/// same size reproduces its text, cursor, modes and screen.
#[test]
fn a_vt_replay_reproduces_the_terminal() {
    let mut a = term();
    a.write(b"\x1b[31mred\x1b[0m line\r\n\x1b[?2004h\x1b[?1049h\x1b[3;4Hon alt");
    let mut b = term();
    b.write(&a.format(Format::Vt).unwrap());
    b.write(&a.continuation().unwrap());
    assert_eq!(plain(&b), plain(&a));
    assert_eq!(b.cursor(), a.cursor());
    assert!(b.alt_screen());
    assert!(b.mode(Mode::BRACKETED_PASTE));
}

#[test]
fn a_sequence_cut_off_mid_write_is_finished_in_the_replay() {
    let mut a = term();
    a.write(b"ab\x1b[3");
    let mut b = term();
    b.write(&a.format(Format::Vt).unwrap());
    b.write(&a.continuation().unwrap());
    // The rest of `ESC [ 3 1 m`, arriving after the replay, colours what follows in both.
    a.write(b"1mX");
    b.write(b"1mX");
    assert_eq!(plain(&b), plain(&a));
    assert_eq!(a.format(Format::Vt).unwrap(), b.format(Format::Vt).unwrap());
}
