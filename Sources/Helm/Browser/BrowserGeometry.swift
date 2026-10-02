import Foundation

/// Both pointer input and candidate windows follow the frame's centred aspect-fit layout.
/// View points and page CSS pixels have a top-left origin.
enum BrowserGeometry {
    static func pagePoint(
        _ point: CGPoint, in view: CGSize, image: CGSize, page: CGSize
    ) -> CGPoint? {
        guard let drawn = drawnRect(in: view, image: image), page.width > 0, page.height > 0 else {
            return nil
        }
        let u = (point.x - drawn.minX) / drawn.width
        let v = (point.y - drawn.minY) / drawn.height
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u * page.width, y: v * page.height)
    }

    static func viewRect(_ rect: CGRect, in view: CGSize, image: CGSize, page: CGSize) -> CGRect {
        guard let drawn = drawnRect(in: view, image: image), page.width > 0, page.height > 0 else {
            return .zero
        }
        return CGRect(
            x: drawn.minX + rect.minX * drawn.width / page.width,
            y: drawn.minY + rect.minY * drawn.height / page.height,
            width: max(1, rect.width * drawn.width / page.width),
            height: rect.height * drawn.height / page.height)
    }

    private static func drawnRect(in view: CGSize, image: CGSize) -> CGRect? {
        guard view.width > 0, view.height > 0, image.width > 0, image.height > 0 else { return nil }
        let scale = min(view.width / image.width, view.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: (view.width - size.width) / 2, y: (view.height - size.height) / 2,
            width: size.width, height: size.height)
    }
}
