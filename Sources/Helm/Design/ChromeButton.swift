import SwiftUI

/// The button style for helm's chrome: tabs, the ×s, the glyph buttons. Its whole label is the
/// click target.
///
/// `.plain` hit-tests only what the label draws. A tab whose background is `.clear` (every tab
/// but the selected one) answers clicks only on its text: measured with a grid of clicks over
/// an unselected workspace tab, its padding, the gap between `⌃2` and the name, and the bands
/// above and below the text reached nothing. Over a pane tab
/// the × answered on its 8pt glyph alone, and a click just beside it fell through to the tab's
/// own tap and selected the pane instead of closing it (#488). This style makes the label's
/// frame the target, so a small glyph needs a frame of its own (`frame(width:height:)`) to be
/// easy to hit. Every button in helm uses it: `ChromeHitTargetTests` fails on a `.plain` one.
struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == ChromeButtonStyle {
    static var chrome: ChromeButtonStyle { ChromeButtonStyle() }
}
