import AppKit
import SwiftUI

struct MenuBarFormatView: View {
    let format: MenuBarFormat
    let cost: Double
    var isAlerting = false
    var notificationUnreadCount = 0

    var body: some View {
        let image = MenuBarFormatRenderer.image(format: format, cost: cost, alerting: isAlerting)
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .renderingMode(.template)
                .interpolation(.high)
                .foregroundStyle(isAlerting ? Color(nsColor: .systemRed) : .primary)
                .frame(width: image.size.width, height: image.size.height)
                .fixedSize()

            if notificationUnreadCount > 0 {
                Circle()
                    .fill(Color(nsColor: .systemRed))
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle()
                            .stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1)
                    )
                    .offset(x: 2, y: -2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: notificationUnreadCount > 0)
        .accessibilityHidden(true)
    }
}

struct MenuBarFormatPreviewView: View {
    let format: MenuBarFormat
    let cost: Double

    var body: some View {
        ZStack {
            MenuBarFormatView(format: format, cost: cost)
        }
        .frame(width: 360, height: 42)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

enum MenuBarFormatRenderer {
    static let height: CGFloat = 18
    static let maximumWidth: CGFloat = 240

    private static let partSpacing: CGFloat = 3
    private static let markSize: CGFloat = 15
    private static let moneyHeight: CGFloat = 17
    private static let textFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let moneyFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let boldTextFont = NSFont.systemFont(ofSize: 12, weight: .bold)
    private static let boldNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
    private static let boldMoneyFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
    // Text glyphs sit optically above the status-item center even when their
    // font metrics are mathematically centered. Keep Money Lens on its own
    // calibrated axis; this offset applies only to ordinary text/cost runs.
    // The status item baseline sits between AppKit's font-metric center and
    // the visible pixel center of the neighboring native menu-bar glyphs.
    private static let textOpticalOffset: CGFloat = -2.0
    private static let moneyTextOpticalOffset: CGFloat = -2.0

    static func image(format: MenuBarFormat, cost: Double, alerting: Bool = false) -> NSImage {
        image(parts: format.parts, cost: cost, alerting: alerting)
    }

    static func image(parts: [MenuBarFormatPart], cost: Double, alerting: Bool = false) -> NSImage {
        let requestedElements = elements(from: parts.isEmpty ? [.logo] : parts, cost: cost, alerting: alerting)
        let intrinsicWidth = totalWidth(of: requestedElements)
        let elements = intrinsicWidth <= maximumWidth
            ? requestedElements
            : [Element.mark, .text(value: "…", number: false, bold: alerting)]
        let width = min(maximumWidth, max(1, totalWidth(of: elements)))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            var x: CGFloat = 0
            for (index, element) in elements.enumerated() {
                draw(element, atX: x, in: rect)
                x += element.width
                if index < elements.count - 1 { x += partSpacing }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private enum Element {
        case mark
        case moneyFrame(text: String, bold: Bool)
        case text(value: String, number: Bool, bold: Bool)

        var width: CGFloat {
            switch self {
            case .mark:
                return markSize
            case let .moneyFrame(text, bold):
                return ceil(max(27, textWidth(text, font: bold ? boldMoneyFont : moneyFont) + 17))
            case let .text(value, number, bold):
                return ceil(textWidth(value, font: bold ? (number ? boldNumberFont : boldTextFont) : (number ? numberFont : textFont)))
            }
        }
    }

    private static func elements(from parts: [MenuBarFormatPart], cost: Double, alerting: Bool) -> [Element] {
        var elements: [Element] = []
        var pendingText = ""
        var pendingNumberStyle = true
        var pendingHasNumber = false

        func flushText() {
            guard !pendingText.isEmpty else { return }
            elements.append(.text(value: pendingText, number: pendingHasNumber && pendingNumberStyle, bold: alerting))
            pendingText = ""
            pendingNumberStyle = true
            pendingHasNumber = false
        }

        func appendLiteral(_ value: String) {
            guard !value.isEmpty else { return }
            pendingText += value
            pendingNumberStyle = pendingNumberStyle && isNumericLiteral(value)
        }

        func appendNumber(_ value: String) {
            pendingText += value
            pendingHasNumber = true
        }

        for part in parts {
            switch part {
            case .logo:
                flushText()
                elements.append(.mark)
            case let .money(precision, includeCurrency):
                flushText()
                let number = Currency.numeric(cost, precision: precision)
                elements.append(.moneyFrame(text: includeCurrency ? "$" + number : number, bold: alerting))
            case let .compactMoney(includeCurrency):
                flushText()
                let value = Currency.compact(cost)
                elements.append(.moneyFrame(text: includeCurrency ? value : value.replacingOccurrences(of: "$", with: ""), bold: alerting))
            case let .text(value):
                appendLiteral(value)
            case let .cost(precision):
                appendNumber(Currency.numeric(cost, precision: precision))
            case .compactCost:
                appendNumber(NumberFormat.compact(cost))
            }
        }
        flushText()
        return elements.isEmpty ? [.mark] : elements
    }

    private static func isNumericLiteral(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789 +-.,$€£¥₽₹₩%()")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func totalWidth(of elements: [Element]) -> CGFloat {
        elements.reduce(0) { $0 + $1.width } + partSpacing * CGFloat(max(0, elements.count - 1))
    }

    private static func draw(_ element: Element, atX x: CGFloat, in rect: NSRect) {
        switch element {
        case .mark:
            drawMark(atX: x, in: rect)
        case let .moneyFrame(text, bold):
            drawMoneyFrame(text: text, bold: bold, atX: x, in: rect)
        case let .text(value, number, bold):
            drawText(value, font: bold ? (number ? boldNumberFont : boldTextFont) : (number ? numberFont : textFont), atX: x, in: rect, verticalOffset: textOpticalOffset)
        }
    }

    private static func drawMark(atX x: CGFloat, in rect: NSRect) {
        let scale = markSize / 18
        let offsetY = (rect.height - markSize) / 2
        let pieces: [CGRect] = [
            CGRect(x: 3, y: 13, width: 5.5, height: 2.5),
            CGRect(x: 3, y: 10, width: 2.5, height: 5.5),
            CGRect(x: 9.5, y: 13, width: 5.5, height: 2.5),
            CGRect(x: 12.5, y: 10, width: 2.5, height: 5.5),
            CGRect(x: 12.5, y: 2.5, width: 2.5, height: 5.5),
            CGRect(x: 9.5, y: 2.5, width: 5.5, height: 2.5),
            CGRect(x: 3, y: 2.5, width: 5.5, height: 2.5),
            CGRect(x: 3, y: 2.5, width: 2.5, height: 5.5)
        ]
        for piece in pieces {
            let scaled = CGRect(
                x: x + piece.minX * scale,
                y: offsetY + piece.minY * scale,
                width: piece.width * scale,
                height: piece.height * scale
            )
            NSBezierPath(roundedRect: scaled, xRadius: scale, yRadius: scale).fill()
        }
        NSBezierPath(
            roundedRect: CGRect(x: x + 7 * scale, y: offsetY + 7 * scale, width: 4 * scale, height: 4 * scale),
            xRadius: scale,
            yRadius: scale
        ).fill()
    }

    private static func drawMoneyFrame(text: String, bold: Bool, atX x: CGFloat, in rect: NSRect) {
        let font = bold ? boldMoneyFont : moneyFont
        let width = ceil(max(27, textWidth(text, font: font) + 17))
        let left: CGFloat = x + 2
        let right = x + width - 4
        let top = rect.midY + 6
        let bottom = rect.midY - 8
        let arm: CGFloat = 6
        let thickness: CGFloat = 2
        let pieces = [
            CGRect(x: left, y: top, width: arm, height: thickness),
            CGRect(x: left, y: top - arm + thickness, width: thickness, height: arm),
            CGRect(x: right - arm + thickness, y: top, width: arm, height: thickness),
            CGRect(x: right, y: top - arm + thickness, width: thickness, height: arm),
            CGRect(x: left, y: bottom, width: arm, height: thickness),
            CGRect(x: left, y: bottom, width: thickness, height: arm),
            CGRect(x: right - arm + thickness, y: bottom, width: arm, height: thickness),
            CGRect(x: right, y: bottom, width: thickness, height: arm)
        ]
        for piece in pieces {
            NSBezierPath(roundedRect: piece, xRadius: 0.8, yRadius: 0.8).fill()
        }
        drawText(
            text,
            font: font,
            atX: x + (width - textWidth(text, font: font)) / 2,
            in: rect,
            verticalOffset: moneyTextOpticalOffset
        )
    }

    private static func drawText(
        _ value: String,
        font: NSFont,
        atX x: CGFloat,
        in rect: NSRect,
        verticalOffset: CGFloat
    ) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let baseline = rect.midY - font.capHeight / 2 - 0.5 + verticalOffset
        let origin = CGPoint(x: x, y: baseline)
        (value as NSString).draw(at: origin, withAttributes: attributes)
    }

    private static func textWidth(_ value: String, font: NSFont) -> CGFloat {
        textSize(value, font: font).width
    }

    private static func textSize(_ value: String, font: NSFont) -> CGSize {
        (value as NSString).size(withAttributes: [.font: font])
    }
}
