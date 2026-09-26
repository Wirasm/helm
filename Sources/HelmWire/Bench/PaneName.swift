import Foundation

// MARK: - PaneName

/// What a pane is called, and **who called it that** (#313).
///
/// **The provenance is the whole reason this is not a `String?`.** The operator's ruling is that
/// agents *"by default … name new panes, and by default … dont rename if editing existing, but i
/// can ask for a rename"*, and the half that can be checked is *is anybody already calling this
/// pane something?* A label the bench derived (benchd names a spawned agent's pane
/// `<agent> · <folder>`) is nobody's choice, so an agent replaces it without asking; a chosen one
/// needs `bench name --rename`. benchd applies the rule (`PaneName::agent_may_replace`); this is
/// helm's reading of the same document field.
///
/// **An enum rather than a struct with a `source` field**: two loosely-coupled fields make
/// nonsense constructable — a `.chosen` with no text, a text with nobody having chosen it.
package enum PaneName: Equatable, Sendable {
    /// Nobody has named it. What the tab shows then is the pane's own business — the shell's OSC
    /// title for a terminal, the file for a canvas.
    case unnamed
    /// helm worked it out from facts it already had. **Nobody chose these words**, so an agent's
    /// first name replaces it without asking. Today the only producer is benchd's spawn.
    case derived(String)
    /// Somebody picked these words — an agent naming a pane nothing had named, or a rename the
    /// operator asked for. This is the one case a rename has to ask about.
    case chosen(String)

    /// The words, or nil when there are none. The one accessor a renderer needs, so no view has
    /// to switch on provenance it has no opinion about.
    package var text: String? {
        switch self {
        case .unnamed: nil
        case .derived(let text), .chosen(let text): text
        }
    }
}

// MARK: - Codable

/// Hand-written with a string discriminator, for the reason `Pane.Content`'s encoder gives: the
/// synthesized shape for an enum with associated values uses positional `_0` keys, which break on
/// any reordering of the cases and are unreadable in the stored blob — and this one is stored, in
/// the bench that survives a restart.
extension PaneName: Codable {
    private enum CodingKeys: String, CodingKey { case source, text }
    private enum Source: String, Codable { case derived, chosen }

    /// **A `source` this build does not know decodes as `.unnamed` rather than throwing.** The
    /// pane is what matters and the name is chrome: `Slot.init(from:)` skips a pane it cannot
    /// read, so a throw here would cost the operator a whole terminal to save a word on its tab.
    /// The same trade `Pane.Content` makes for a malformed `agent`.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let source = try? container.decode(Source.self, forKey: .source),
            let text = try? container.decode(String.self, forKey: .text)
        else {
            self = .unnamed
            return
        }
        self =
            switch source {
            case .derived: .derived(text)
            case .chosen: .chosen(text)
            }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unnamed:
            // Nothing. `Pane` does not write the key at all for this case, so an un-named bench's
            // blob stays byte-identical to what every build before #313 wrote.
            break
        case .derived(let text):
            try container.encode(Source.derived, forKey: .source)
            try container.encode(text, forKey: .text)
        case .chosen(let text):
            try container.encode(Source.chosen, forKey: .source)
            try container.encode(text, forKey: .text)
        }
    }
}
