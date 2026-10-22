import AppKit
import SwiftUI

struct BrandMark: View {
    let size: CGFloat

    private var markColor: Color {
        Color(nsColor: NSColor.labelColor)
    }

    var body: some View {
        ZStack {
            SignalLensFrame()
                .stroke(
                    markColor,
                    style: StrokeStyle(
                        lineWidth: max(1.6, size * 0.105),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

            RoundedRectangle(cornerRadius: max(1.2, size * 0.045), style: .continuous)
                .fill(markColor)
                .frame(width: max(2.8, size * 0.18), height: max(2.8, size * 0.18))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SignalLensFrame: Shape {
    let radiusFraction: CGFloat
    let cornerFraction: CGFloat

    init(radiusFraction: CGFloat = 0.29, cornerFraction: CGFloat = 0.13) {
        self.radiusFraction = radiusFraction
        self.cornerFraction = cornerFraction
    }

    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let left = rect.midX - size * radiusFraction
        let right = rect.midX + size * radiusFraction
        let top = rect.midY - size * radiusFraction
        let bottom = rect.midY + size * radiusFraction
        let corner = size * cornerFraction

        var path = Path()

        path.move(to: CGPoint(x: left + corner, y: top))
        path.addLine(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: top + corner))

        path.move(to: CGPoint(x: right - corner, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: top + corner))

        path.move(to: CGPoint(x: right, y: bottom - corner))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right - corner, y: bottom))

        path.move(to: CGPoint(x: left + corner, y: bottom))
        path.addLine(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: bottom - corner))

        return path
    }
}
