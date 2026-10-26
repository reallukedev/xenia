import XeniaCore
import SwiftUI

/// A message bubble: a rounded rectangle, with the Messages tail at the bottom corner on the
/// last bubble of a run. The tail hangs outside the frame, so tailed and untailed bubbles in a
/// run share their edges.
nonisolated struct BubbleShape: Shape {
    var radius: CGFloat
    var tail: Edge?
    /// Draw the tail inside the frame (for masking photos, whose pixels must fill the tail):
    /// the body is inset by the tail's width on its side.
    var tailInside = false

    /// How far the tail reaches past the body.
    static let tailWidth: CGFloat = 5.5

    func path(in frame: CGRect) -> Path {
        var rect = frame
        if tailInside, let tail {
            rect.size.width -= Self.tailWidth
            if tail == .leading { rect.origin.x += Self.tailWidth }
        }
        let body = Path(roundedRect: rect, cornerRadius: min(radius, rect.height / 2), style: .continuous)
        guard let tail else { return body }
        // A true union, so the mirrored (leading) tail never leaves a hole where it overlaps.
        return body.union(tailPath(in: rect, edge: tail))
    }

    /// The tail: squares off the bottom corner, then sweeps out to a point just past the edge,
    /// and hooks back under the bubble.
    private func tailPath(in rect: CGRect, edge: Edge) -> Path {
        let r = min(radius, rect.height / 2)
        var p = Path()
        // Drawn for a trailing tail, then mirrored for a leading one.
        let maxX = rect.maxX, maxY = rect.maxY
        p.move(to: CGPoint(x: maxX - r, y: maxY))
        p.addLine(to: CGPoint(x: maxX - r, y: maxY - r))
        p.addLine(to: CGPoint(x: maxX, y: maxY - r))
        p.addCurve(
            to: CGPoint(x: maxX + Self.tailWidth, y: maxY),
            control1: CGPoint(x: maxX, y: maxY - r * 0.4),
            control2: CGPoint(x: maxX + 1.5, y: maxY - 1.2)
        )
        p.addQuadCurve(to: CGPoint(x: maxX - 7, y: maxY - 1.6), control: CGPoint(x: maxX - 1.5, y: maxY + 0.4))
        p.addQuadCurve(to: CGPoint(x: maxX - r, y: maxY), control: CGPoint(x: maxX - 10, y: maxY))
        p.closeSubpath()
        guard edge == .leading else { return p }
        let mirror = CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1)
        return p.applying(mirror)
    }
}

extension BubbleShape {
    enum Edge { case leading, trailing }
}

#Preview {
    VStack(alignment: .trailing, spacing: 2) {
        Text("A run of bubbles").padding(.horizontal, 12).padding(.vertical, 7)
            .background(.blue, in: BubbleShape(radius: 18, tail: nil))
        Text("with a tail on the last one").padding(.horizontal, 12).padding(.vertical, 7)
            .background(.blue, in: BubbleShape(radius: 18, tail: .trailing))
    }
    .foregroundStyle(.white)
    .padding(40)
}
