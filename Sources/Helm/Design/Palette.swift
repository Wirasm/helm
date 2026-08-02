import Foundation

/// helm's palette, as values.
///
/// **The missing primitive, not a restyle.** helm had three independent colour sources and
/// no shared tokens: `ChatPalette`, five values local to the chat face; the terminal's
/// colours, which were whatever the operator's own Ghostty config happened to say; and
/// system defaults for all the chrome in between. Nothing agreed with anything, which is
/// precisely why the app did not read as one surface. This table is what all three spend
/// now.
///
/// **Values rather than `Color`s, and that is load-bearing.** A token is sRGB components in
/// both appearances, so the palette is reachable from `swift test` — and, the part that
/// actually decides the shape, renderable as a ghostty `background = #rrggbb` config line
/// as readily as a SwiftUI `Color`. A palette expressed in `Color` could not have themed
/// the terminal at all, and the terminal is the one surface helm exists to host.
///
/// **Semantic names, never literal ones.** `surface`, not `offWhite`: a token's light and
/// dark values are nothing alike, so naming one after either is a lie in the other.
///
/// **Where this lives.** Not `App/`, which `AGENTS.md` reserves for composition, and not a
/// feature slice, because every feature spends it. `Design/` is the primitive itself — the
/// same standing `Shared/` has, one level up in how much of the app it touches.
struct Palette: Equatable, Sendable {
    /// One colour, sRGB, 0…1 per channel.
    struct RGB: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double

        /// From `0xRRGGBB`. The literal form the values below are written in, because a
        /// palette is read and compared as hex everywhere else it appears — a design tool,
        /// a ghostty config, a CSS file.
        init(hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }

        /// `#rrggbb` — what ghostty's config takes. Lowercase and always six digits, so a
        /// rendered config line is comparable by string.
        var hex: String {
            let channel = { (value: Double) in
                String(format: "%02x", Int((value * 255).rounded()))
            }
            return "#" + channel(red) + channel(green) + channel(blue)
        }
    }

    /// A token: one role, in both appearances. Not a colour — a *job* a colour does.
    struct Token: Equatable, Sendable {
        let light: RGB
        let dark: RGB

        init(light: UInt32, dark: UInt32) {
            self.light = RGB(hex: light)
            self.dark = RGB(hex: dark)
        }

        func value(in appearance: Appearance) -> RGB {
            switch appearance {
            case .light: light
            case .dark: dark
            }
        }
    }

    /// Which of a token's two values is in force. Distinct from `AppearanceOverride`, which
    /// is the operator's *preference* and has a third case for "follow the system" — by the
    /// time a colour is resolved that question has been answered.
    enum Appearance: Equatable, Sendable, CaseIterable {
        case light
        case dark
    }

    /// The reading plane: the terminal grid, the chat face's paper, a canvas. Everything
    /// helm shows content on is this one colour, which is the whole point of having it.
    let surface: Token
    /// Chrome sitting above the plane — the workspace bar, a slot's tab strip, the status
    /// bar. It reads as a step up rather than as a different material.
    let surfaceRaised: Token
    /// Body text and anything the operator is meant to read.
    let textPrimary: Token
    /// A second voice: labels, secondary prose, a branch name.
    let textMuted: Token
    /// Present but not competing — a key hint, an index, a unit. Below this a thing should
    /// be absent instead.
    let textFaint: Token
    /// Hairlines and the edges of things. Never a fill.
    let border: Token
    /// helm's one colour with an opinion. Spent sparingly: the cursor, the mark on an
    /// answer, an active control. Orange stays what it has always been — the attention
    /// colour, which is a different job (see `AgentDot`).
    let accent: Token
    /// What a selection leaves behind: dragged text in the terminal, the selected tab.
    /// Accent mixed most of the way into the surface, so it tints rather than highlights.
    let selection: Token

    /// **Private, which is what makes "helm's one palette" a fact rather than a habit.**
    /// `PaletteTests` proves the contrast ratios of `helm`; a second palette built elsewhere
    /// in the module would carry none of that and nothing would ask. `RGB` and `Token` are
    /// closed the same way, one level down.
    private init(
        surface: Token, surfaceRaised: Token, textPrimary: Token, textMuted: Token,
        textFaint: Token, border: Token, accent: Token, selection: Token
    ) {
        self.surface = surface
        self.surfaceRaised = surfaceRaised
        self.textPrimary = textPrimary
        self.textMuted = textMuted
        self.textFaint = textFaint
        self.border = border
        self.accent = accent
        self.selection = selection
    }

    /// helm's one palette.
    ///
    /// **The chat face's five values, promoted.** `surface`, `textPrimary`, `textMuted`,
    /// `border` and `accent` are `ChatPalette`'s `paper`, `ink`, `quiet`, `rule` and
    /// `accent` unchanged, to the digit. That direction was deliberate: the chat face was
    /// the only surface in helm whose colours had ever been *chosen*, so folding it in
    /// meant promoting them rather than picking new ones and regressing the one face that
    /// already worked. What changed is everything else — the terminal and the chrome now
    /// agree with it instead of each going its own way.
    static let helm = Palette(
        surface: Token(light: 0xFB_FA_F8, dark: 0x1C_1E_21),
        surfaceRaised: Token(light: 0xF1_EF_EA, dark: 0x24_27_2B),
        textPrimary: Token(light: 0x1B_1D_1F, dark: 0xE6_E3_DE),
        textMuted: Token(light: 0x5C_60_66, dark: 0x93_99_A0),
        textFaint: Token(light: 0x83_87_8E, dark: 0x6E_74_7B),
        border: Token(light: 0xE2_DF_DA, dark: 0x30_34_39),
        accent: Token(light: 0x3F_8F_80, dark: 0x5F_C0_AC),
        selection: Token(light: 0xD5_E5_E0, dark: 0x29_3E_3D)
    )
}
