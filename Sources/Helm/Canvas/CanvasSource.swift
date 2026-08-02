import Foundation

// MARK: - CanvasSource

/// Where the canvas gets what it renders. CONTEXT.md: the canvas is *modular
/// by source* — a file an agent or the operator opened, or a URL.
///
/// A sum rather than two optionals, because a canvas showing both a file and
/// a URL is not a state that exists — and because the difference has to
/// survive the persistence seam: `WorkspaceContext.openArtifactPath` is a
/// **file** path, and a `https:` URL parked in `Document.url` would persist
/// as `url.path` (empty, or a stray `/segment`) and be reopened through
/// `URL(fileURLWithPath:)` on the next workspace switch. `CanvasModel.fileURL`
/// is what keeps that honest.
///
/// Top level rather than nested in `CanvasModel`, because the workbench
/// persists it: a bench pane carries the source it is showing, so the type has
/// to be nameable without naming a live model. It still carries the model's
/// `Document`/`Page` — hoisting those too is a change of shape, not a rename,
/// and belongs with the work that gives this a `Codable` form.
enum CanvasSource {
    case file(CanvasModel.Document)
    case url(CanvasModel.Page)
}
