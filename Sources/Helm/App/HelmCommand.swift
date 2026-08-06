import Combine
import Foundation
import HelmWire

/// Every command helm can carry out, as one closed value.
///
/// **One channel, one type.** This was eighteen `Notification.Name`s whose payload rode in
/// `Notification.object`, which is `Any?` — so a value that was an enum at the source became an
/// `Int` in flight and was rebuilt at the destination, and eleven receivers held the only
/// knowledge of which name carried which shape. Nothing checked that they agreed.
///
/// **#152 is what that cost.** `Shortcut` carried `payload: Int?` *and* `direction: Direction?`
/// *and* a computed `var object: Any?` to squeeze either into the untyped slot; the keymap posted
/// `object` and the menu posted the raw `payload`, which is `nil` on all four focus-movement rows.
/// View ▸ Focus Left/Right/Up/Down were silent no-ops from the day `HelmCommands` was split out.
/// That fix centralised posting into one method — which stopped two callers disagreeing and left
/// the channel that let them disagree exactly as it was. This removes the channel.
///
/// A payload now travels *as itself*. `moveFocus(.left)` is a direction, not an `Int` that a
/// receiver hopes is a `Direction` raw value, and a receiver that forgets a command fails to
/// compile rather than falling through a `switch` in silence.
///
/// **It is also the prerequisite for configurable bindings.** A config that says "⌘⌥J is focus
/// left" needs *focus left* to have a stable name it can write down; today that identity is a
/// notification name plus a separate field, erased on the wire. `Name` below is that identity,
/// and it is deliberately one name with three consumers — the keymap, the status bar's hint
/// catalogue, and whatever config lands next — because a second list of command names is a second
/// thing to keep in step.
enum HelmCommand: Equatable {
    /// ⌘N — a fresh login shell in a new pane.
    case newTerminal
    /// ⌘1–⌘9 — select a tab by position. 0-based; the keys are 1-based.
    case selectTerminal(index: Int)
    /// ⌘O — the canvas presents its open panel.
    case openArtifact
    /// A ⌘-click on an OSC 8 link the agent printed. Distinct from `openArtifact`, which is the
    /// payload-less ⌘O that summons the picker.
    case openCanvasFile(URL)
    /// An agent pushing an artifact onto the bench. Distinct from `openCanvasFile`, which is the
    /// operator asking: a push **appears** as a tab without selecting it or moving focus, because
    /// the operator did not ask for it and may be mid-thought in another pane (#125).
    case pushCanvasFile(CanvasPushRequest)
    /// The canvas takes a URL. `nil` is ⌘L — *"show me the address field"*, whether the canvas is
    /// open or not; a URL is a ⌘-clicked http link.
    ///
    /// The optional is the whole distinction and it used to live in the *absence* of a
    /// notification object, which is the one shape an untyped channel cannot tell from a mistake.
    case openCanvasURL(URL?)
    /// ⌘⇧O — the sidebar presents the folder picker; the chosen folder becomes an open workspace.
    case openWorkspace
    /// ⌘+/⌘-/⌘0 — applied to the selected terminal.
    case adjustFontSize(FontSizeStep)
    /// ⌘↑/⌘↓ — the prompt offset, -1 previous and +1 next. In an agent session each turn leaves
    /// a mark, so this is effectively jump-between-turns.
    case jumpToPrompt(offset: Int)
    /// ⌃1–⌃9 / ⌘⌥1–⌘⌥9 — 0-based workspace index.
    case selectWorkspace(index: Int)
    /// ⌃←/⌃→ — -1 or +1.
    case cycleWorkspace(delta: Int)
    /// ⌘T — swap the **focused pane's** two faces: the terminal, and the agent's writing drawn
    /// over it.
    case toggleChat
    /// ⌘D — a new column right of the focused one, holding a fresh terminal.
    case splitRight
    /// ⌘⇧D — a new row under the focused slot, holding a fresh terminal.
    case splitDown
    /// ⌘⌥W — close the focused pane. ⌘W is unavailable: SwiftUI's `WindowGroup` binds it to
    /// close-window.
    case closePane
    /// ⌘⌥←/→/↑/↓ — the direction travels as a `Direction`, not as its raw value.
    case moveFocus(Workbench.Direction)
    /// A canvas's `Post`: prefill one pane's composer with text.
    case composeText(ComposeRequest)
    /// ⇧⌘R — show or hide the remembered Archon monitor rail.
    case toggleRail
}

// MARK: - Payloads with no other home

/// Text offered to one pane's composer.
///
/// **Addressed, and that is the point.** The composer lives inside `ChatOverlay`, so under a
/// bench an unaddressed command would prefill every open chat face at once. Which pane is the
/// bench's decision (`WorkbenchModel.composeTarget`); this only carries it.
struct ComposeRequest: Equatable {
    let pane: Pane.ID
    let text: String
}

// MARK: - Name

extension HelmCommand {
    /// A command's stable identity, without its payload.
    ///
    /// **Not a convenience for the status bar — the command's public name.** `KeyHintCatalog`
    /// keys on it, and a bindings config will write it into a file. Deriving both from one
    /// enumeration is what stops the config and the keymap from disagreeing about what a command
    /// is called, which is precisely the drift a second hand-written list would guarantee.
    ///
    /// **It lives in `HelmWire` now (#269), and this is a typealias onto it rather than a second
    /// enumeration.** The prediction above — *"a bindings config will write it into a file"* —
    /// came true as a spool request rather than a config: `CommandRequest` carries one of these
    /// names across the process boundary and `SpoolCommandPolicy` decides per name whether an
    /// agent may send it. Both live in `HelmWire`, which depends on nothing in `Helm`, so the
    /// identity had to move there; `HelmCommandName`'s own header argues why the *payloads* did
    /// not follow it. Spelling it `HelmCommand.Name` here keeps every call site in `Helm`
    /// (`Shortcut`, `KeyHintCatalog`) reading exactly as it did.
    typealias Name = HelmCommandName

    /// **The compiler keeps this in step.** Add a case to `HelmCommand` and this `switch` stops
    /// being exhaustive, so the name cannot be forgotten — which is the whole reason a payload-free
    /// identity is derived here rather than written down twice.
    var name: Name {
        switch self {
        case .newTerminal: .newTerminal
        case .selectTerminal: .selectTerminal
        case .openArtifact: .openArtifact
        case .openCanvasFile: .openCanvasFile
        case .pushCanvasFile: .pushCanvasFile
        case .openCanvasURL: .openCanvasURL
        case .openWorkspace: .openWorkspace
        case .adjustFontSize: .adjustFontSize
        case .jumpToPrompt: .jumpToPrompt
        case .selectWorkspace: .selectWorkspace
        case .cycleWorkspace: .cycleWorkspace
        case .toggleChat: .toggleChat
        case .splitRight: .splitRight
        case .splitDown: .splitDown
        case .closePane: .closePane
        case .moveFocus: .moveFocus
        case .composeText: .composeText
        case .toggleRail: .toggleRail
        }
    }
}

// MARK: - The channel

extension Notification.Name {
    /// helm's one command channel. The object is **always** a `HelmCommand`, and nothing else
    /// should ever post it — use `HelmCommand.post()`.
    ///
    /// It stays a `NotificationCenter` name because the decoupling is right: a command has to
    /// reach a model whose view may be mounted, unmounted or not yet built, and several verticals
    /// listen for their own without knowing about each other. What was wrong was never the
    /// broadcast — it was that the payload had no type.
    fileprivate static let helmCommand = Notification.Name("helmCommand")
}

extension HelmCommand {
    /// Fire this command.
    ///
    /// **The only way to post one.** `Shortcut.post()` and every direct caller funnel through
    /// here, so there is no second way to pair a command with a payload — the shape that produced
    /// #152 cannot be written.
    func post() {
        NotificationCenter.default.post(name: .helmCommand, object: self)
    }

    /// Every command, typed.
    ///
    /// **The one `as?` in the whole channel**, and it is here because this is where Foundation's
    /// untyped API actually is. A seam is allowed one adapter; what it is not allowed is eleven,
    /// each holding its own idea of what the payload was.
    static var publisher: AnyPublisher<HelmCommand, Never> {
        NotificationCenter.default
            .publisher(for: .helmCommand)
            .compactMap { $0.object as? HelmCommand }
            .eraseToAnyPublisher()
    }
}
