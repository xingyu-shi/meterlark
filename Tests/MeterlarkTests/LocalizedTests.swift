import XCTest
@testable import MeterlarkApp

final class LocalizedTests: XCTestCase {
    func testEnglishAndChineseOverridesAreSelectable() {
        let english = L10n(language: .english)
        let chinese = L10n(language: .chinese)

        XCTAssertEqual(english.usageByDay, "Usage by day")
        XCTAssertEqual(chinese.usageByDay, "每日用量")
        XCTAssertEqual(english.currentMonth, "This month")
        XCTAssertEqual(chinese.currentMonth, "本月")
        XCTAssertEqual(english.usageRefreshInterval, "Usage refresh interval")
        XCTAssertEqual(chinese.usageRefreshInterval, "用量刷新间隔")
        XCTAssertEqual(english.justNow, "Just now")
        XCTAssertEqual(chinese.justNow, "刚刚")
        XCTAssertEqual(english.unknown, "Unknown")
        XCTAssertEqual(chinese.unknown, "未知")
        XCTAssertEqual(english.totalTokens, "Total tokens")
        XCTAssertEqual(chinese.totalTokens, "Token 总量")
        XCTAssertEqual(english.totalCost, "Total cost")
        XCTAssertEqual(chinese.totalCost, "总费用")
        XCTAssertEqual(english.dailyTotals, "Daily totals")
        XCTAssertEqual(chinese.dailyTotals, "每日总量")
        XCTAssertEqual(english.peakDay, "Peak day")
        XCTAssertEqual(chinese.peakDay, "峰值日")
        XCTAssertEqual(english.autoRefreshShort, "Auto-refresh")
        XCTAssertEqual(chinese.autoRefreshShort, "自动刷新")
        XCTAssertEqual(english.apiEquivalentEstimate, "Today · estimated API cost")
        XCTAssertEqual(chinese.apiEquivalentEstimate, "今天 · API 费用估算")
        XCTAssertEqual(english.statusHelp, "This status reflects app health. Usage and pricing freshness are shown separately.")
        XCTAssertEqual(chinese.statusHelp, "此状态反映应用运行情况；用量和价格的新鲜度会单独显示。")
        XCTAssertEqual(english.about, "About")
        XCTAssertEqual(chinese.about, "关于")
        XCTAssertEqual(english.interfaceTextSize, "Interface text size")
        XCTAssertEqual(chinese.interfaceTextSize, "界面字号")
        XCTAssertEqual(english.interfaceTextSizeLabel(.largest), "Largest (130%)")
        XCTAssertEqual(chinese.interfaceTextSizeLabel(.largest), "特大 (130%)")
        XCTAssertEqual(chinese.interfaceTextSizeLabel(.extraLarge), "更大 (120%)")
        XCTAssertEqual(english.budgetAlertLabel("65"), "Alert at 65%")
        XCTAssertEqual(chinese.budgetAlertLabel("65"), "达到 65% 告警")
    }

    func testPriceListSourceUsesProviderNamesAndSupportsMultipleProviders() {
        let english = L10n(language: .english)
        let chinese = L10n(language: .chinese)

        XCTAssertEqual(
            english.priceListSourceLabel(["Plugin B", "Plugin A", "Plugin A"]),
            "Plugin A, Plugin B pricing"
        )
        XCTAssertEqual(
            chinese.priceListSourceLabel(["插件 B", "插件 A", "插件 A"]),
            "插件 A、插件 B 价目表"
        )
        XCTAssertEqual(
            chinese.pricingStatusSourceLabel(.remote),
            "价目表提供方不可用"
        )
    }
}
