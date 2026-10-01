import SwiftUI

/// The drop zone (#178): one look for every place a tab can be dropped. `preview` is the region
/// the pane will occupy, tinted and outlined; `seam` is a solid bar where it enters — the edge
/// it splits, or the gap in a tab strip. Nothing is drawn where a drop would change nothing.
///
/// Drawn over the bench in `PaneDrop.space`, the space the frames it reads were measured in.
/// It takes no part in hit testing: the drag is the tab's gesture, not a drop target's.
struct DropZoneOverlay: View {
    @ObservedObject var drag: PaneDragModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let target = drag.drag?.target {
                place(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accent.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.accent.opacity(0.7), lineWidth: 1)),
                    at: target.preview.insetBy(dx: 2, dy: 2))
                place(
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.accent),
                    at: target.seam)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func place(_ shape: some View, at rect: CGRect) -> some View {
        shape
            .frame(width: max(rect.width, 0), height: max(rect.height, 0))
            .offset(x: rect.minX, y: rect.minY)
    }
}
