import XCTest
@testable import MeterlarkApp

final class FormattingTests: XCTestCase {
    func testRelativeTimeUsesJustNowForSubsecondSnapshots() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            RelativeTime.localizedString(
                for: now.addingTimeInterval(-0.1),
                relativeTo: now,
                language: .english
            ),
            "Just now"
        )
        XCTAssertEqual(
            RelativeTime.localizedString(
                for: now.addingTimeInterval(-0.1),
                relativeTo: now,
                language: .chinese
            ),
            "刚刚"
        )
    }

    func testAxisNumbersUseReadableSuffixes() {
        XCTAssertEqual(NumberFormat.compact(750.0), "750")
        XCTAssertEqual(NumberFormat.compact(1_250.0), "1.2K")
        XCTAssertEqual(NumberFormat.compact(2_500_000.0), "2.5M")
        XCTAssertEqual(NumberFormat.compact(3_000_000_000.0), "3.0B")
        XCTAssertEqual(Currency.compact(8.08), "$8")
        XCTAssertEqual(Currency.numeric(10.2), "10.2")
        XCTAssertEqual(Currency.numeric(10.2, precision: 2), "10.20")
        XCTAssertEqual(Currency.compact(1_250.0), "$1.2K")
    }

    func testGroupedTokenCountsPreserveExactValues() {
        XCTAssertEqual(NumberFormat.grouped(0), "0")
        XCTAssertEqual(NumberFormat.grouped(35_400_000), "35,400,000")
        XCTAssertEqual(NumberFormat.grouped(1_250), "1,250")
    }

    func testPricingThresholdsAvoidUnnecessaryDecimalSuffixes() {
        XCTAssertEqual(NumberFormat.threshold(200_000), "200K")
        XCTAssertEqual(NumberFormat.threshold(272_000), "272K")
        XCTAssertEqual(NumberFormat.threshold(1_250), "1.2K")
    }

    func testMenuBarFormatParsesLogoAndCostParts() {
        let format = MenuBarFormat(rawValue: "[logo]*$[cost:2]")

        XCTAssertTrue(format.isValid)
        XCTAssertEqual(format.parts, [.logo, .text("*$"), .cost(precision: 2)])
    }

    func testMenuBarFormatParsesMoneyLensParts() {
        let format = MenuBarFormat(rawValue: "[money:2]")

        XCTAssertEqual(format.parts, [.money(precision: 2, includeCurrency: true)])
    }

    func testMenuBarFormatParsesPlainMoneyLensParts() {
        XCTAssertEqual(
            MenuBarFormat(rawValue: "[money:0:plain]").parts,
            [.money(precision: 0, includeCurrency: false)]
        )
        XCTAssertEqual(
            MenuBarFormat(rawValue: "[money:compact:plain]").parts,
            [.compactMoney(includeCurrency: false)]
        )
    }

    func testMenuBarFormatSupportsCompactCost() {
        let format = MenuBarFormat(rawValue: "$[cost:compact]")

        XCTAssertEqual(format.parts, [.text("$"), .compactCost])
    }

    func testMenuBarFormatRejectsUnknownOrMissingTokens() {
        XCTAssertEqual(MenuBarFormat(rawValue: "[price]").validationError, .unsupportedToken("price"))
        XCTAssertEqual(MenuBarFormat(rawValue: "logo").validationError, .missingToken)
        XCTAssertEqual(MenuBarFormat(rawValue: "[cost:7]").validationError, .invalidPrecision)
        XCTAssertEqual(MenuBarFormat(rawValue: "[logo]\n[cost]").validationError, .controlCharacter)
    }

    func testMenuBarFormatTrimsOnlyOuterWhitespace() {
        let format = MenuBarFormat(rawValue: "  [logo] · $[cost:0]  ")

        XCTAssertTrue(format.isValid)
        XCTAssertEqual(format.rawValue, "[logo] · $[cost:0]")
    }

    func testMenuBarFormatPreviewStateTracksSaveEligibility() {
        let valid = MenuBarFormatPreviewState(rawValue: "[logo] · $[cost:2]")
        XCTAssertTrue(valid.canSave)
        XCTAssertTrue(valid.format.isValid)

        let invalid = MenuBarFormatPreviewState(rawValue: "[unsupported]")
        XCTAssertFalse(invalid.canSave)
        XCTAssertEqual(invalid.format.parts, [.logo])
        XCTAssertEqual(invalid.format.validationError, .unsupportedToken("unsupported"))
    }

    func testMenuBarFormatRendererKeepsLogoAndCostInOneImage() {
        let format = MenuBarFormat(rawValue: "[logo]-[cost:0]")
        let image = MenuBarFormatRenderer.image(parts: format.parts, cost: 13.0)

        XCTAssertTrue(format.isValid)
        XCTAssertTrue(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 20)
        XCTAssertEqual(image.size.height, MenuBarFormatRenderer.height)
    }

    func testMenuBarFormatRendererCapsPathologicalFormats() {
        let literal = String(repeating: "x", count: 512)
        let image = MenuBarFormatRenderer.image(parts: [.logo, .text(literal)], cost: 13.0)

        XCTAssertLessThanOrEqual(image.size.width, MenuBarFormatRenderer.maximumWidth)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testMenuBarFormatRendererHandlesNonFiniteCost() {
        let format = MenuBarFormat(rawValue: "[money:2]")
        let image = MenuBarFormatRenderer.image(format: format, cost: .nan)

        XCTAssertEqual(image.size.height, MenuBarFormatRenderer.height)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testMenuBarFormatRendererSupportsAlertPresentation() {
        let format = MenuBarFormat(rawValue: "[logo]$[cost]")
        let image = MenuBarFormatRenderer.image(format: format, cost: 13, alerting: true)

        XCTAssertTrue(format.isValid)
        XCTAssertTrue(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 20)
    }
}
