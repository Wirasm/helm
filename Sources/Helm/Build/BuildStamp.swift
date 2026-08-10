import Foundation

/// The build waiting on disk: what a finished `make release` leaves behind so a helm that is
/// already running can notice it.
///
/// **Why this is a file, and why the build writes it rather than the install.** The obvious
/// signal — watch `/Applications/Helm.app` and see it change — cannot work, and the reason is
/// circular rather than subtle. That bundle only changes when `make install` copies over it,
/// and `make install` refuses to run while helm is running, on purpose: replacing a live
/// bundle leaves the running process on its old code and the swap is invisible until
/// something behaves oddly an hour later. So by the time the installed bundle moves, the
/// operator has already quit, and the question this type exists to answer has answered
/// itself.
///
/// The step that *can* happen while helm runs is the **build**. `make release` produces the
/// Release product and leaves this beside it; `make install` is that plus the copy. An agent
/// building on a branch is the normal case here, and it is exactly the moment the operator
/// wants to be told.
///
/// **It carries a header because a shell script writes it and the app reads it** — the same
/// boundary `BenchSnapshot` documents, and the same answer. `format` and `version` are what
/// let a helm that predates a change refuse the file rather than misread a field that moved;
/// a refused stamp shows no badge, which is the safe direction.
struct BuildStamp: Codable, Equatable {
    static let currentFormat = "helm.build-stamp"
    static let currentVersion = 1

    let format: String
    let version: Int

    /// The commit the product was built from, and the whole of the comparison.
    ///
    /// **Compared verbatim, never parsed.** Whether the Makefile writes a short sha or a long
    /// one is its business; this type only ever asks whether two strings differ, so there is
    /// no format here to get wrong and no parse to forget.
    let sha: String

    /// When the build finished — for the operator to read, and never for the comparison.
    ///
    /// Two builds of the same commit are the same build, and rebuilding on an unchanged tree
    /// must not raise a badge. Deciding on a timestamp would do exactly that.
    let builtAt: Date

    /// Where the built `.app` is, so a relaunch can install it without re-deriving a path only
    /// the Makefile knows.
    ///
    /// **A `String`, deliberately, and this is the documented carve-out rather than a lapse.**
    /// A stamp is decoded permissively in shape and judged strictly afterwards — the same
    /// reasoning `CloseRequest.terminal` and `SpawnRequest.cwd` record in their own headers.
    /// It is judged in exactly one place, `BuildStamp.installableProduct`, and a path that
    /// fails that check produces a refusal naming the reason instead of unreadable JSON under
    /// the wrong field.
    let product: String

    init(sha: String, builtAt: Date, product: String) {
        format = Self.currentFormat
        version = Self.currentVersion
        self.sha = sha
        self.builtAt = builtAt
        self.product = product
    }

    /// Whether this build is one this helm understands well enough to act on.
    ///
    /// Exact on both fields. A *newer* version is as unreadable as an older one — helm cannot
    /// know what a future field means, and guessing is how a reader misreports rather than
    /// fails.
    var isReadable: Bool {
        format == Self.currentFormat && version == Self.currentVersion
    }

    /// The product path, once it has been judged — or nil, which is a refusal to act.
    ///
    /// Three things must hold, and each has cost somebody an hour somewhere: it must be a
    /// real path on disk, it must be a **directory** (an `.app` is a bundle, and a file at
    /// that path is a truncated copy or something else entirely), and it must actually end in
    /// `.app` (so a mis-set `product` cannot make the relaunch copy an arbitrary directory
    /// over the running application).
    var installableProduct: URL? {
        let url = URL(fileURLWithPath: (product as NSString).expandingTildeInPath)
            .standardizedFileURL
        guard url.pathExtension == "app" else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return url
    }
}
