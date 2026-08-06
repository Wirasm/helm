import Foundation
import HelmWire

// MARK: - MailMessage

/// One message in an agent's mailbox, in the shape both runtimes already read.
///
/// **helm has only ever read the mailbox until now.** `MailboxDirectory` resolves an agent from
/// a pid so a spawn result can name a handle, and `BenchSnapshot` publishes who is at which pane;
/// neither writes. This is the write half, and it is deliberately the *same* wire format rather
/// than a channel of helm's own — `{id, from, to, subject, body, sentAt}` is what
/// `hooks/helm-mail.mjs` and `pi/extensions/helm-mail/index.ts` already consume, and a second
/// shape would need a third reader in both runtimes to notice it.
///
/// **A third spelling of that format, and it earns the same carve-out the other two do.** The
/// mailbox's readers are JavaScript in separate processes, which is why `AGENTS.md` already
/// records the format as written twice (`hooks/`, `pi/`) with no shared module possible. Swift is
/// now a *writer* of it, and cannot import either. What that costs is stated plainly so it is not
/// mistaken for tidiness: a change to the message shape has to be made here as well.
///
/// `to` is a `Handle` because it names a directory that must already exist — a mailbox is claimed
/// by its owner, and addressing one helm invented would be silence. `from` is a plain `String`
/// because helm is **not** an agent and has no mailbox: there is no address here to reply to, and
/// typing it as a `Handle` would promise one.
struct MailMessage: Encodable, Equatable {
    /// `<epoch millis>-<6 hex>`, which is what the runtimes' own reply instructions name.
    let id: String
    let from: String
    let to: String
    let subject: String
    let body: String
    /// Epoch milliseconds. **Derived from `id` by construction rather than passed alongside it**,
    /// because the documented way to send is `'sentAt': int(id.split('-')[0])` (`helm-mail-cc`'s
    /// own snippet) — two fields carrying one number, with nothing to notice when a caller lets
    /// them disagree. One initializer computes both, so they cannot.
    let sentAt: Int

    /// The only route in. `nonce` is a parameter so a test gets a filename it can predict;
    /// production takes the default, which is six hex characters of `SystemRandomNumberGenerator`.
    init(
        from sender: String, to recipient: Handle, subject: String, body: String,
        at now: Date, nonce: String = MailMessage.nonce()
    ) {
        let millis = Int(now.timeIntervalSince1970 * 1000)
        self.id = "\(millis)-\(nonce)"
        self.sentAt = millis
        self.from = sender
        self.to = recipient.value
        self.subject = subject
        self.body = body
    }

    static func nonce() -> String {
        String(format: "%06x", Int.random(in: 0..<0x100_0000))
    }
}

// MARK: - Mailbox

/// Putting a message in a mailbox — the write half of `MailboxDirectory`.
///
/// It lives in `Sources/Helm/` rather than beside `MailboxDirectory` in `HelmWire` because
/// nothing outside this process needs it: `HelmWire` exists for what crosses the spool's boundary,
/// and a `tools/*.swift` script that wanted to send mail would write the file with `python3` the
/// way the skills already do.
enum Mailbox {
    /// **Write to a temp name, then rename in.** A reader listing the directory mid-write must see
    /// nothing rather than half a message, and both readers filter on the same two rules — the
    /// name ends in `.json` and does not start with `.` (`hooks/helm-mail.mjs:118`). `.tmp-<id>`
    /// satisfies neither, so it is invisible until the rename makes it a message. This is the
    /// shape `helm-mail-cc`'s own send snippet documents, spelled the same way on purpose.
    ///
    /// **A missing mailbox is refused, never created.** A directory under the mail root *is* an
    /// address, and one helm made up has no owner, no `owner.json` and nobody watching it — a
    /// message put there is silence with a receipt, which is the exact failure #205 exists to
    /// remove. The refusal is a thrown error so the caller can say so in the pane.
    static func deliver(_ message: MailMessage, to handle: Handle, in root: URL) throws {
        let box = root.appendingPathComponent(handle.value)
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: box.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw Failure.noSuchMailbox(handle.value)
        }
        if retired(at: box) { throw Failure.retired(handle.value, box.path) }
        let staged = box.appendingPathComponent(".tmp-\(message.id)")
        let delivered = box.appendingPathComponent("\(message.id).json")
        // **`0600`, because both other writers make it so** — `writeAtomic` in
        // `hooks/helm-mail.mjs:99` and `pi/extensions/helm-mail/index.ts:284`, and `index.ts:484`
        // sends every message through it. The body of a canvas note is whatever the operator typed
        // about their own work, and a third writer that widened it to the umask would leave one
        // directory holding files with two postures depending on who sent them.
        //
        // `createFile(atPath:contents:attributes:)` rather than `Data.write(options: .atomic)`,
        // because that overload carries no mode and takes the umask (measured: `0644`). The rename
        // below preserves the mode, so the delivered message is `0600` too.
        guard
            FileManager.default.createFile(
                atPath: staged.path, contents: try JSONEncoder().encode(message),
                attributes: [.posixPermissions: 0o600])
        else {
            throw Failure.couldNotStage(handle.value)
        }
        do {
            try FileManager.default.moveItem(at: staged, to: delivered)
        } catch {
            // The staged file is invisible to a reader, so leaving it behind is litter rather
            // than a half-delivered message — but litter in someone else's mailbox that nothing
            // ever cleans up.
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// **Is this mailbox's owner gone?** Since #236 a retired mailbox keeps its directory and its
    /// `read/` archive **forever**, so "the directory exists" stopped being able to tell live from
    /// gone — and a message written into a retired box is never read and never bounces.
    ///
    /// **This is not a rule of helm's own; it is `pi/extensions/helm-mail/index.ts:465-473`
    /// restated in Swift**, down to refusing *differently* from a missing mailbox. That sender's
    /// own comment says why the distinction is the point: *"a sender holding a handle from an
    /// earlier message learns the agent is gone, instead of writing into a live-looking directory
    /// and waiting forever for a reply."* helm is a sender now, so it owes the same answer — a
    /// third spelling of the send rule that silently differed from the other two would be exactly
    /// the drift the duplication is already watched for.
    ///
    /// **A missing or unreadable `owner.json` is NOT retired**, which is also pi's behaviour to
    /// the letter (`readJson` yields undefined and the optional-chained check is falsy). Being
    /// stricter here would be the same defect wearing the opposite sign.
    ///
    /// `MailboxDirectory.owners(in:)` already drops retired rows, so `CanvasNoteRoute` cannot
    /// normally hand one over. This is not that filter restated: it guards the *primitive*, whose
    /// next caller will not have the route in front of it, and it closes the window where a
    /// mailbox retires between the route being decided and the write landing.
    private static func retired(at box: URL) -> Bool {
        guard let data = try? Data(contentsOf: box.appendingPathComponent("owner.json")),
            let owner = try? JSONDecoder().decode(MailboxOwner.self, from: data)
        else { return false }
        return owner.retiredAt != nil
    }

    enum Failure: Error, LocalizedError, Equatable {
        case noSuchMailbox(String)
        /// The agent is gone but its archive remains — a different fact from never having existed,
        /// and the sender is told which.
        case retired(String, String)
        /// The mailbox is there and live, and the write itself would not go — a full disk, a
        /// directory that turned read-only. Named rather than folded into the two above, because
        /// "your recipient is gone" and "this machine could not write a file" are different things
        /// to do next about.
        case couldNotStage(String)

        var errorDescription: String? {
            switch self {
            case let .noSuchMailbox(handle):
                "there is no mailbox at \(handle) any more"
            case let .retired(handle, path):
                "\(handle) has retired — that agent is gone and will not read this. "
                    + "Its archive is still in \(path)"
            case let .couldNotStage(handle):
                "\(handle)'s mailbox is there but the message could not be written into it"
            }
        }
    }
}
