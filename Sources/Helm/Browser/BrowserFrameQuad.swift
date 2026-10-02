import Foundation

/// Invert the projected iframe content quad, preserving borders, scroll and CSS transforms.
struct BrowserFrameQuad {
    private let corners: [CGPoint]

    init?(_ coordinates: [Double]) {
        guard coordinates.count == 8, coordinates.allSatisfy(\.isFinite) else { return nil }
        corners = stride(from: 0, to: 8, by: 2).map {
            CGPoint(x: coordinates[$0], y: coordinates[$0 + 1])
        }
    }

    func local(_ point: CGPoint, size: CGSize) -> CGPoint? {
        // Solve the square-to-quad projective map for normalized u/v in the child viewport.
        let p = corners
        let dx1 = p[1].x - p[2].x
        let dx2 = p[3].x - p[2].x
        let dx3 = p[0].x - p[1].x + p[2].x - p[3].x
        let dy1 = p[1].y - p[2].y
        let dy2 = p[3].y - p[2].y
        let dy3 = p[0].y - p[1].y + p[2].y - p[3].y
        let divisor = dx1 * dy2 - dx2 * dy1
        guard abs(divisor) > 0.000001 else { return nil }
        let g = (dx3 * dy2 - dx2 * dy3) / divisor
        let h = (dx1 * dy3 - dx3 * dy1) / divisor
        let a = p[1].x - p[0].x + g * p[1].x - point.x * g
        let b = p[3].x - p[0].x + h * p[3].x - point.x * h
        let d = p[1].y - p[0].y + g * p[1].y - point.y * g
        let e = p[3].y - p[0].y + h * p[3].y - point.y * h
        let determinant = a * e - b * d
        guard abs(determinant) > 0.000001 else { return nil }
        let x = point.x - p[0].x
        let y = point.y - p[0].y
        let u = (x * e - b * y) / determinant
        let v = (a * y - x * d) / determinant
        guard u.isFinite, v.isFinite, (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u * size.width, y: v * size.height)
    }
}
