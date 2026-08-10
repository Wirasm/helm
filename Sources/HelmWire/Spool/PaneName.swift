import Foundation

// MARK: - PaneName

/// What a pane is called, and **who called it that** (#313).
///
/// **The provenance is the whole reason this is not a `String?`.** The operator's ruling is that
/// agents *"by default … name new panes, and by default … dont rename if editing existing, but i
/// can ask for a rename"*, and the half of that helm can actually check is *is anybody already
/// calling this pane something?* A pane nobody has named has no label the operator has been
/// reading, so naming it takes nothing from anyone.
///
/// That check only works if helm's **own** default is distinguishable from somebody's choice. helm
/// labels a pane it opens for an agent (`derived(for:)` below), and if that landed in an
/// undifferentiated `String?` the very agent helm just spawned would be *refused* when it named its
/// own pane — inverting the ruling exactly. So the text travels with the answer to "who chose
/// this", and `SpoolNamePolicy` switches on it.
///
/// **An enum rather than a struct with a `source` field**, for `SpoolPaneState.Keyboard`'s own
/// argument one file over: two loosely-coupled fields make nonsense constructable — a `.chosen`
/// with no text, a text with nobody having chosen it — and `AGENTS.md`'s rule is that an invariant
/// explained by a comment wants a type carrying it. It also makes the policy's switch exhaustive,
/// so a fourth provenance cannot be added without a verdict.
///
/// **Lives in `HelmWire` rather than beside `Pane`**, because both sides of the seam need it: the
/// bench stores it on a pane and persists it, and `SpoolPaneState` carries it to
/// `SpoolNamePolicy`, which is judged with no bench at all. A type on one side and a comment on
/// the other is the defect `AGENTS.md` names.
package enum PaneName: Equatable, Sendable {
    /// Nobody has named it. What the tab shows then is the pane's own business — the shell's OSC
    /// title for a terminal, the file for a canvas.
    case unnamed
    /// helm worked it out from facts it already had. **Nobody chose these words**, so an agent's
    /// first name replaces it without asking. Today the only producer is `derived(for:)`.
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

    /// The name helm gives a pane it opens for an agent — the fix for #313's concrete trigger,
    /// and it needs no wire format at all: helm wrote the request, so it already knows everything
    /// this uses.
    ///
    /// **`<command> · <basename of cwd>`**, because those are the two facts that actually tell two
    /// agent panes apart on a strip 180pt wide: which agent, and which tree. A spawn lands in a
    /// worktree far more often than not here, so the basename is usually the ticket
    /// (`claude · issue-313-name-a-pane`) rather than a repo name.
    ///
    /// **The prompt is deliberately not read**, and that is a decision rather than an omission.
    /// #313 offers its first line as a candidate; it would be the most informative and it is the
    /// one source here that is *prose an agent wrote for another agent*. #93's whole lesson is to
    /// be conservative about which surfaces that text reaches, and a tab strip is shared with
    /// whoever is looking at the screen. An agent that wants a better name now has `helm-name`.
    package static func derived(for request: AcceptedSpawnRequest) -> PaneName {
        let base = (request.cwd as NSString).lastPathComponent
        // `/` and a trailing slash both leave `lastPathComponent` saying nothing useful — "/" and
        // the empty string respectively. A bare command is a worse name than a good one and a far
        // better one than `claude · /`.
        guard !base.isEmpty, base != "/" else { return .derived(request.command) }
        return .derived("\(request.command) · \(base)")
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
