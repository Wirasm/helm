import Foundation

/// A physical Mac key, translated into the three names Chrome's `Input.dispatchKeyEvent`
/// wants: the DOM `code`, the DOM `key`, and the legacy Windows virtual-key code.
///
/// **The virtual-key code comes from the physical key, never from the character.** The spike's
/// viewer used `charCodeAt`, so `#` (0x23) went out as VK 35 — End — and `$` as Home, `%&'(` as
/// the arrows, `.` as Delete: 186 of 200 typed characters survived. Here a key's VK is a row in
/// `table`, looked up by the Mac key code AppKit reports, which is what Chrome itself does on a
/// Mac (`ui/events/keycodes/keyboard_code_conversion_mac.mm`).
///
/// **Text is not decided here.** What a key *types* comes from AppKit's own text input —
/// `interpretKeyEvents` calling `insertText(_:)` — so dead keys, ⌥-combinations and non-US
/// layouts produce the character the operator's layout produces (a Finnish ⌥2 is `@`). This
/// type only names the key that was pressed.
struct BrowserKey: Equatable {
    let code: String
    let key: String
    let windowsVirtualKeyCode: Int
    let nativeVirtualKeyCode: Int

    /// - Parameters:
    ///   - macKeyCode: `NSEvent.keyCode`.
    ///   - charactersIgnoringModifiers: `NSEvent.charactersIgnoringModifiers`, used as the DOM
    ///     `key` of a printable key when no text is produced (⌘-combinations).
    ///   - text: the text this press produced, when it produced any — the DOM `key` of a
    ///     printable key is what it typed.
    init(macKeyCode: UInt16, charactersIgnoringModifiers: String?, text: String?) {
        let entry = Self.table[macKeyCode]
        code = entry?.code ?? ""
        windowsVirtualKeyCode = entry?.vk ?? 0
        nativeVirtualKeyCode = Int(macKeyCode)
        if let named = entry?.named {
            key = named
        } else if let text, !text.isEmpty {
            key = text
        } else {
            key = charactersIgnoringModifiers.flatMap { Self.printable($0) } ?? "Unidentified"
        }
    }

    /// Enter types a carriage return, as it does in a browser of its own — a form submits on
    /// it. It is the one named key that carries text.
    static func enterText(macKeyCode: UInt16) -> String? {
        macKeyCode == 0x24 || macKeyCode == 0x4C ? "\r" : nil
    }

    /// AppKit reports function keys as characters in the private-use range 0xF700–0xF8FF, and
    /// control keys as C0 controls. Neither is text a page should receive.
    static func printable(_ characters: String) -> String? {
        guard let scalar = characters.unicodeScalars.first else { return nil }
        if (0xF700...0xF8FF).contains(scalar.value) || scalar.value < 0x20 || scalar.value == 0x7F {
            return nil
        }
        return characters
    }

    private struct Entry {
        let code: String
        let vk: Int
        /// The DOM `key` for a key that does not type a character. nil for a printable key.
        let named: String?
    }

    private static func printable(_ code: String, _ vk: Int) -> Entry {
        Entry(code: code, vk: vk, named: nil)
    }

    private static func named(_ code: String, _ vk: Int, _ key: String? = nil) -> Entry {
        Entry(code: code, vk: vk, named: key ?? code)
    }

    /// Carbon's `kVK_*` codes (HIToolbox `Events.h`) → DOM code and Windows VK.
    private static let table: [UInt16: Entry] = {
        var t: [UInt16: Entry] = [:]
        let letters: [(UInt16, Character)] = [
            (0x00, "A"), (0x01, "S"), (0x02, "D"), (0x03, "F"), (0x04, "H"), (0x05, "G"),
            (0x06, "Z"), (0x07, "X"), (0x08, "C"), (0x09, "V"), (0x0B, "B"), (0x0C, "Q"),
            (0x0D, "W"), (0x0E, "E"), (0x0F, "R"), (0x10, "Y"), (0x11, "T"), (0x1F, "O"),
            (0x20, "U"), (0x22, "I"), (0x23, "P"), (0x25, "L"), (0x26, "J"), (0x28, "K"),
            (0x2D, "N"), (0x2E, "M"),
        ]
        for (mac, letter) in letters {
            t[mac] = printable("Key\(letter)", Int(letter.asciiValue!))
        }
        let digits: [(UInt16, Int)] = [
            (0x1D, 0), (0x12, 1), (0x13, 2), (0x14, 3), (0x15, 4), (0x17, 5), (0x16, 6),
            (0x1A, 7), (0x1C, 8), (0x19, 9),
        ]
        for (mac, digit) in digits {
            t[mac] = printable("Digit\(digit)", 48 + digit)
        }
        t[0x18] = printable("Equal", 187)
        t[0x1B] = printable("Minus", 189)
        t[0x21] = printable("BracketLeft", 219)
        t[0x1E] = printable("BracketRight", 221)
        t[0x27] = printable("Quote", 222)
        t[0x29] = printable("Semicolon", 186)
        t[0x2A] = printable("Backslash", 220)
        t[0x2B] = printable("Comma", 188)
        t[0x2C] = printable("Slash", 191)
        t[0x2F] = printable("Period", 190)
        t[0x32] = printable("Backquote", 192)
        t[0x0A] = printable("IntlBackslash", 226)
        t[0x31] = printable("Space", 32)

        t[0x24] = named("Enter", 13)
        t[0x4C] = named("NumpadEnter", 13, "Enter")
        t[0x30] = named("Tab", 9)
        t[0x33] = named("Backspace", 8)
        t[0x75] = named("Delete", 46)
        t[0x35] = named("Escape", 27)
        t[0x73] = named("Home", 36)
        t[0x77] = named("End", 35)
        t[0x74] = named("PageUp", 33)
        t[0x79] = named("PageDown", 34)
        t[0x7B] = named("ArrowLeft", 37)
        t[0x7E] = named("ArrowUp", 38)
        t[0x7C] = named("ArrowRight", 39)
        t[0x7D] = named("ArrowDown", 40)
        let functionKeys: [(UInt16, Int)] = [
            (0x7A, 1), (0x78, 2), (0x63, 3), (0x76, 4), (0x60, 5), (0x61, 6), (0x62, 7),
            (0x64, 8), (0x65, 9), (0x6D, 10), (0x67, 11), (0x6F, 12),
        ]
        for (mac, n) in functionKeys {
            t[mac] = named("F\(n)", 111 + n)
        }
        let keypad: [(UInt16, Int)] = [
            (0x52, 0), (0x53, 1), (0x54, 2), (0x55, 3), (0x56, 4), (0x57, 5), (0x58, 6),
            (0x59, 7), (0x5B, 8), (0x5C, 9),
        ]
        for (mac, n) in keypad {
            t[mac] = printable("Numpad\(n)", 96 + n)
        }
        t[0x41] = printable("NumpadDecimal", 110)
        t[0x43] = printable("NumpadMultiply", 106)
        t[0x45] = printable("NumpadAdd", 107)
        t[0x4E] = printable("NumpadSubtract", 109)
        t[0x4B] = printable("NumpadDivide", 111)
        return t
    }()
}

/// Modifier bits as CDP counts them: Alt 1, Control 2, Meta 4, Shift 8.
struct BrowserModifiers: OptionSet, Equatable {
    let rawValue: Int
    static let alt = BrowserModifiers(rawValue: 1)
    static let control = BrowserModifiers(rawValue: 2)
    static let meta = BrowserModifiers(rawValue: 4)
    static let shift = BrowserModifiers(rawValue: 8)
}

/// The editing commands a key press asks for, as Chrome's `commands` field names them.
///
/// On a Mac, Chrome does not decide what ⌥⌫ or ⌘→ do in a text field — AppKit does, through
/// the key bindings that turn a press into a selector (`deleteWordBackward:`,
/// `moveToEndOfLine:`), and Chrome executes the named command. A headless browser has no
/// AppKit of its own to ask, so the pane asks its own (`interpretKeyEvents` → `doCommand(by:)`)
/// and forwards the name. That keeps every binding the operator has — including ones he
/// customised — rather than a table here guessing them.
///
/// `insert…` selectors are dropped, as Playwright drops them: the key event itself inserts
/// the newline or moves focus on Tab, and a second insertion would double it. `noop:` means
/// nothing is bound.
enum BrowserEditingCommand {
    static func name(forSelector selector: String) -> String? {
        guard selector.hasSuffix(":") else { return nil }
        let name = String(selector.dropLast())
        guard !name.hasPrefix("insert"), name != "noop", !name.isEmpty else { return nil }
        return name
    }
}
