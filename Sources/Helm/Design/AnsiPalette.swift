import Foundation

/// The sixteen colours the operator's programs paint their own content with.
///
/// **This used to be the operator's, deliberately, and the reasoning was wrong.** The
/// argument for leaving them alone was that they are the most personal thing in a terminal
/// config and helm has no business in them — `ls` should stay the green it has always been.
/// What that missed is that a palette is not chosen against nothing. Sixteen colours picked
/// against somebody else's background, sitting inside a frame that now agrees with itself,
/// is most of what "the terminal looks off" actually was: the chrome had been retuned and
/// the content had not.
///
/// **Hue identity is the constraint, not a nicety.** Green must still read as green and red
/// as red — these are not decoration, they are how `git diff` says added and removed and how
/// a test runner says pass and fail. So each entry keeps its family's hue angle and only its
/// lightness and chroma move, tuned to helm's surface. `AnsiPaletteTests` pins the hue band
/// of every one of the sixteen, in both appearances, so a future retune cannot quietly turn
/// "error red" into something a reader has to stop and decode.
///
/// The two greys are the exception, and on purpose: index 0 and 8 are what programs dim text
/// with, so on a dark surface they are *supposed* to sit close to it. They are the only two
/// entries the contrast floor does not apply to.
struct AnsiPalette: Equatable, Sendable {
    let black: Palette.Token
    let red: Palette.Token
    let green: Palette.Token
    let yellow: Palette.Token
    let blue: Palette.Token
    let magenta: Palette.Token
    let cyan: Palette.Token
    let white: Palette.Token
    let brightBlack: Palette.Token
    let brightRed: Palette.Token
    let brightGreen: Palette.Token
    let brightYellow: Palette.Token
    let brightBlue: Palette.Token
    let brightMagenta: Palette.Token
    let brightCyan: Palette.Token
    let brightWhite: Palette.Token

    /// See `Palette.init` — same reasoning, and the ratios `AnsiPaletteTests` proves belong
    /// to `helm` alone.
    private init(
        black: Palette.Token, red: Palette.Token, green: Palette.Token, yellow: Palette.Token,
        blue: Palette.Token, magenta: Palette.Token, cyan: Palette.Token, white: Palette.Token,
        brightBlack: Palette.Token, brightRed: Palette.Token, brightGreen: Palette.Token,
        brightYellow: Palette.Token, brightBlue: Palette.Token, brightMagenta: Palette.Token,
        brightCyan: Palette.Token, brightWhite: Palette.Token
    ) {
        self.black = black
        self.red = red
        self.green = green
        self.yellow = yellow
        self.blue = blue
        self.magenta = magenta
        self.cyan = cyan
        self.white = white
        self.brightBlack = brightBlack
        self.brightRed = brightRed
        self.brightGreen = brightGreen
        self.brightYellow = brightYellow
        self.brightBlue = brightBlue
        self.brightMagenta = brightMagenta
        self.brightCyan = brightCyan
        self.brightWhite = brightWhite
    }

    /// The hue families, in ANSI index order — which is also `palette = N=…`'s order, so
    /// this is what renders and what the tests walk. Index and name together, because a bare
    /// `[Token]` would make an off-by-one silent and a test unable to say which entry failed.
    var ordered: [(index: Int, name: String, token: Palette.Token)] {
        [
            (0, "black", black), (1, "red", red), (2, "green", green), (3, "yellow", yellow),
            (4, "blue", blue), (5, "magenta", magenta), (6, "cyan", cyan), (7, "white", white),
            (8, "bright black", brightBlack), (9, "bright red", brightRed),
            (10, "bright green", brightGreen), (11, "bright yellow", brightYellow),
            (12, "bright blue", brightBlue), (13, "bright magenta", brightMagenta),
            (14, "bright cyan", brightCyan), (15, "bright white", brightWhite),
        ]
    }

    /// helm's sixteen, tuned to `Palette.helm.surface` in both appearances.
    ///
    /// The shape of the set: muted rather than saturated, because a terminal running an
    /// agent is a wall of coloured text read for hours and a vivid palette is exhausting at
    /// that length. Cyan is the accent — the one family helm already had an opinion about —
    /// one step darker in light, where the accent's own value is tuned for a cursor rather
    /// than for a paragraph of text.
    ///
    /// Light is not dark inverted. `white` goes DARK on a light surface and `black` goes
    /// dark on it too, because a program asking for "white" text means "the quiet one" and
    /// quiet on paper is grey, not white-on-white.
    static let helm = AnsiPalette(
        black: Palette.Token(light: 0x3A_3E_44, dark: 0x34_38_3E),
        red: Palette.Token(light: 0xB4_41_3F, dark: 0xE0_6C_6C),
        green: Palette.Token(light: 0x4E_7A_33, dark: 0x86_B3_6B),
        yellow: Palette.Token(light: 0x8C_6A_18, dark: 0xD9_AE_64),
        blue: Palette.Token(light: 0x35_61_8F, dark: 0x6E_9B_D1),
        magenta: Palette.Token(light: 0x7E_4A_94, dark: 0xC0_8A_D1),
        cyan: Palette.Token(light: 0x35_78_6B, dark: 0x5F_C0_AC),
        white: Palette.Token(light: 0x6E_71_78, dark: 0xC9_C5_BE),
        brightBlack: Palette.Token(light: 0x83_87_8E, dark: 0x5A_60_69),
        brightRed: Palette.Token(light: 0xC9_52_4F, dark: 0xF0_85_85),
        brightGreen: Palette.Token(light: 0x5E_8D_3F, dark: 0x9F_CC_82),
        brightYellow: Palette.Token(light: 0xA8_80_1F, dark: 0xEF_C7_7E),
        brightBlue: Palette.Token(light: 0x3F_6F_A3, dark: 0x8A_B4_E8),
        brightMagenta: Palette.Token(light: 0x8E_56_A6, dark: 0xD6_A3_E6),
        brightCyan: Palette.Token(light: 0x45_98_8A, dark: 0x7F_D6_C3),
        brightWhite: Palette.Token(light: 0x1B_1D_1F, dark: 0xE6_E3_DE)
    )
}
