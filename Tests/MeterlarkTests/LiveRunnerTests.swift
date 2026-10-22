import Foundation
import XCTest
@testable import MeterlarkApp

final class LiveRunnerTests: XCTestCase {
    private var bundledURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/ccusage")
    }

    private func recentCodexTimestamp() -> (timestamp: String, day: String) {
        let date = Date().addingTimeInterval(-60)
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)!
        dayFormatter.dateFormat = "yyyy-MM-dd"
        return (ISO8601DateFormatter().string(from: date), dayFormatter.string(from: date))
    }

    func testLookbackCommandUsesOnlinePricingWhenRequested() throws {
        var settings = MonitorSettings.default
        settings.lookbackDays = 30

        let command = try CCUsageRunner(bundledExecutableURL: bundledURL).command(settings: settings, mode: .onlinePricing)

        XCTAssertTrue(command.arguments.contains("--since"))
        XCTAssertTrue(command.arguments.contains("--by-agent"))
        XCTAssertFalse(command.arguments.contains("--offline"))
        XCTAssertFalse(command.arguments.contains("--no-cost"))
        XCTAssertFalse(command.arguments.contains("--breakdown"))
        XCTAssertFalse(command.arguments.contains("--mode"))
    }

    func testMonthlyBudgetCommandUsesNaturalMonthAndPricingConfig() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 15))!
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-monthly-budget-\(UUID().uuidString).json")

        let command = try CCUsageRunner(bundledExecutableURL: bundledURL).monthlyCommand(
            settings: .default,
            mode: .usage,
            pricingConfigURL: config,
            now: now,
            calendar: calendar
        )

        let sinceIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--since"))
        let untilIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--until"))
        let configIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--config"))
        XCTAssertEqual(command.arguments.first, "monthly")
        XCTAssertEqual(command.arguments[sinceIndex + 1], "2026-08-01")
        XCTAssertEqual(command.arguments[untilIndex + 1], "2026-08-18")
        XCTAssertEqual(command.arguments[configIndex + 1], config.path)
        let sectionsIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--sections"))
        XCTAssertEqual(command.arguments[sectionsIndex + 1], "daily,monthly")
        XCTAssertTrue(command.arguments.contains("--offline"))
        XCTAssertFalse(command.arguments.contains("--mode"))
    }

    func testCurrentMonthCommandStartsOnTheFirstDayOfTheMonth() throws {
        var settings = MonitorSettings.default
        settings.lookbackDays = MonitorSettings.calendarMonthLookback

        let command = try CCUsageRunner(bundledExecutableURL: bundledURL).command(settings: settings, mode: .usage)
        let sinceIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--since"))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let expected = formatter.string(from: CCUsageRunner.startDate(for: settings.lookbackDays, now: Date()))

        XCTAssertEqual(command.arguments[sinceIndex + 1], expected)
        XCTAssertTrue(expected.hasSuffix("-01"))
    }

    func testTodayCommandUsesOneCalendarDayForBothBounds() throws {
        var settings = MonitorSettings.default
        settings.lookbackDays = 1

        let command = try CCUsageRunner(bundledExecutableURL: bundledURL).command(settings: settings, mode: .usage)
        let sinceIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--since"))
        let untilIndex = try XCTUnwrap(command.arguments.firstIndex(of: "--until"))

        XCTAssertEqual(command.arguments[sinceIndex + 1], command.arguments[untilIndex + 1])
    }

    func testUsageCommandCalculatesOfflineCostWithoutRefreshingPriceData() throws {
        let settings = MonitorSettings.default

        let command = try CCUsageRunner(bundledExecutableURL: bundledURL).command(settings: settings, mode: .usage)

        XCTAssertTrue(command.arguments.contains("--offline"))
        XCTAssertFalse(command.arguments.contains("--no-cost"))
    }

    func testPricingConfigIsPassedToBothOfflineAndOnlineCostCommands() throws {
        let settings = MonitorSettings.default
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-pricing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: config) }

        let pricingCommand = try CCUsageRunner(bundledExecutableURL: bundledURL).command(
            settings: settings,
            mode: .onlinePricing,
            pricingConfigURL: config
        )
        let usageCommand = try CCUsageRunner(bundledExecutableURL: bundledURL).command(
            settings: settings,
            mode: .usage,
            pricingConfigURL: config
        )

        let configIndex = try XCTUnwrap(pricingCommand.arguments.firstIndex(of: "--config"))
        XCTAssertEqual(pricingCommand.arguments[configIndex + 1], config.path)
        let usageConfigIndex = try XCTUnwrap(usageCommand.arguments.firstIndex(of: "--config"))
        XCTAssertEqual(usageCommand.arguments[usageConfigIndex + 1], config.path)
        XCTAssertFalse(usageCommand.arguments.contains("--mode"))
    }

    func testBundledCcusageCalculatesPiCostWhenRecordedCostIsZero() throws {
        guard FileManager.default.isExecutableFile(atPath: bundledURL.path) else {
            throw XCTSkip("Bundled ccusage native binary is not available")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.PiCalculateLiveRunnerTests.\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sessions = root.appendingPathComponent("pi/sessions/project-a", isDirectory: true)
        let config = root.appendingPathComponent("pricing.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
        let session = """
        {"type":"message","timestamp":"\(timestamp)","message":{"role":"assistant","model":"gpt-5.6-luna","usage":{"input":1000,"output":100,"cacheRead":0,"cacheWrite":0,"totalTokens":1100,"cost":{"total":0}}}}
        """
        try Data(session.utf8).write(to: sessions.appendingPathComponent("agent_pi-fixture.jsonl"))
        try Data(#"{"defaults":{"pricingOverrides":{"gpt-5.6-luna":{"inputCostPerToken":0.000001,"outputCostPerToken":0.000002}}}}"#.utf8)
            .write(to: config)

        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        let previousPiAgentDir = ProcessInfo.processInfo.environment["PI_AGENT_DIR"]
        setenv("HOME", home.path, 1)
        setenv("PI_AGENT_DIR", root.appendingPathComponent("pi/sessions").path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
            if let previousPiAgentDir {
                setenv("PI_AGENT_DIR", previousPiAgentDir, 1)
            } else {
                unsetenv("PI_AGENT_DIR")
            }
        }

        var settings = MonitorSettings.default
        settings.lookbackDays = 30
        let runner = CCUsageRunner(timeout: 60, bundledExecutableURL: bundledURL)
        let command = try runner.command(settings: settings, mode: .usage, pricingConfigURL: config)
        XCTAssertFalse(command.arguments.contains("--mode"))

        let snapshot = try runner.run(
            settings: settings,
            mode: .usage,
            previousPricingDate: nil,
            pricingConfigURL: config
        )

        let model = try XCTUnwrap(snapshot.models.first { $0.name == "[pi] gpt-5.6-luna" })
        XCTAssertTrue(model.hasKnownPricing)
        XCTAssertEqual(model.estimatedCost, 0.0012, accuracy: 0.0000001)
    }

    func testBundledNativeCcusageProducesSnapshot() throws {
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
            throw XCTSkip("Requires local Codex usage data unavailable on GitHub Actions")
        }

        guard FileManager.default.isExecutableFile(atPath: bundledURL.path) else {
            throw XCTSkip("Bundled ccusage native binary is not available")
        }

        var settings = MonitorSettings.default
        settings.lookbackDays = 30

        let snapshot = try CCUsageRunner(timeout: 60, bundledExecutableURL: bundledURL).run(
            settings: settings,
            mode: .usage,
            previousPricingDate: nil
        )

        XCTAssertTrue(snapshot.hasData)
        XCTAssertGreaterThan(snapshot.totalTokens.totalTokens, 0)
        XCTAssertFalse(snapshot.models.isEmpty)
    }

    func testBundledNativeCcusageProducesMonthlyBudgetSnapshot() throws {
        guard FileManager.default.isExecutableFile(atPath: bundledURL.path) else {
            throw XCTSkip("Bundled ccusage native binary is not available")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.MonthlyBudgetLiveRunnerTests.\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sessions = root.appendingPathComponent("codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = """
        {"timestamp":"2026-08-18T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.6-luna-2026-08-18","last_token_usage":{"input_tokens":250000,"cached_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":0,"total_tokens":251000}}}}
        """
        try Data(session.utf8).write(to: sessions.appendingPathComponent("session.jsonl"))

        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        let previousCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("HOME", home.path, 1)
        setenv("CODEX_HOME", root.appendingPathComponent("codex").path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
            if let previousCodexHome {
                setenv("CODEX_HOME", previousCodexHome, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 15))!
        let snapshot = try CCUsageRunner(timeout: 60, bundledExecutableURL: bundledURL).runMonthlyBudget(
            settings: .default,
            mode: .usage,
            previousPricingDate: nil,
            pricingConfigURL: nil,
            customPricingRevision: nil,
            now: now
        )

        XCTAssertEqual(snapshot.month, "2026-08")
        XCTAssertGreaterThan(snapshot.totalTokens, 0)
        XCTAssertFalse(snapshot.models.isEmpty)
        XCTAssertTrue(snapshot.hasRealtimeProjection)
        XCTAssertGreaterThan(snapshot.realtimeAnchorTodayCost ?? -1, 0)
    }

    func testBundledCcusageHonorsConfigForPinnedModelName() throws {
        guard FileManager.default.isExecutableFile(atPath: bundledURL.path) else {
            throw XCTSkip("Bundled ccusage native binary is not available")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.LiveRunnerTests.\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sessions = root.appendingPathComponent("codex/sessions", isDirectory: true)
        let emptyConfig = root.appendingPathComponent("empty.json")
        let customConfig = root.appendingPathComponent("custom.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = recentCodexTimestamp()
        let modelName = "gpt-6-astra-\(fixture.day)"
        let session = """
        {"timestamp":"\(fixture.timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"model":"\(modelName)","last_token_usage":{"input_tokens":250000,"cached_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":0,"total_tokens":251000}}}}
        """
        try Data(session.utf8).write(to: sessions.appendingPathComponent("session.jsonl"))
        try Data(#"{"defaults":{"pricingOverrides":{}}}"#.utf8).write(to: emptyConfig)
        try Data(#"""
        {"defaults":{"pricingOverrides":{"gpt-6-astra":{"inputCostPerToken":0.000000001,"outputCostPerToken":0.000000002,"inputCostPerTokenAbove200kTokens":0.000000004,"outputCostPerTokenAbove200kTokens":0.000000008}}}}
        """#.utf8).write(to: customConfig)

        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        let previousCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("HOME", home.path, 1)
        setenv("CODEX_HOME", root.appendingPathComponent("codex").path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
            if let previousCodexHome {
                setenv("CODEX_HOME", previousCodexHome, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }

        var settings = MonitorSettings.default
        settings.lookbackDays = 30
        let runner = CCUsageRunner(timeout: 60, bundledExecutableURL: bundledURL)
        let baseline = try runner.run(
            settings: settings,
            mode: .offlinePricing,
            previousPricingDate: nil,
            pricingConfigURL: emptyConfig
        )
        let custom = try runner.run(
            settings: settings,
            mode: .offlinePricing,
            previousPricingDate: nil,
            pricingConfigURL: customConfig
        )

        let baselineModel = try XCTUnwrap(baseline.models.first { $0.name == modelName })
        let customModel = try XCTUnwrap(custom.models.first { $0.name == modelName })
        XCTAssertEqual(baselineModel.name, modelName)
        XCTAssertEqual(customModel.name, baselineModel.name)
        XCTAssertEqual(customModel.estimatedCost, 0.000252, accuracy: 0.000000001)
        XCTAssertNotEqual(customModel.estimatedCost, baselineModel.estimatedCost)
        XCTAssertLessThan(customModel.estimatedCost, baselineModel.estimatedCost)
    }

    func testBundledCcusageHonorsExplicitZeroAndMixedTierOverrides() throws {
        guard FileManager.default.isExecutableFile(atPath: bundledURL.path) else {
            throw XCTSkip("Bundled ccusage native binary is not available")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.ZeroPricingLiveRunnerTests.\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sessions = root.appendingPathComponent("codex/sessions", isDirectory: true)
        let positiveConfig = root.appendingPathComponent("positive.json")
        let zeroConfig = root.appendingPathComponent("zero.json")
        let mixedNoTierConfig = root.appendingPathComponent("mixed-no-tier.json")
        let mixedOutputZeroConfig = root.appendingPathComponent("mixed-output-zero.json")
        let mixedConfig = root.appendingPathComponent("mixed.json")
        let partialTierConfig = root.appendingPathComponent("partial-tier.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = recentCodexTimestamp()
        let modelName = "ccusage-zero-fixture-\(fixture.day)"
        let session = """
        {"timestamp":"\(fixture.timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"model":"\(modelName)","last_token_usage":{"input_tokens":250000,"cached_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":0,"total_tokens":251000}}}}
        """
        try Data(session.utf8).write(to: sessions.appendingPathComponent("session.jsonl"))
        try Data(#"{"defaults":{"pricingOverrides":{"ccusage-zero-fixture":{"inputCostPerToken":0.000001,"outputCostPerToken":0.000002}}}}"#.utf8).write(to: positiveConfig)
        try Data(#"{"defaults":{"pricingOverrides":{"ccusage-zero-fixture":{"inputCostPerToken":0,"outputCostPerToken":0,"inputCostPerTokenAbove200kTokens":0,"outputCostPerTokenAbove200kTokens":0}}}}"#.utf8).write(to: zeroConfig)
        try Data(#"{"defaults":{"pricingOverrides":{"ccusage-zero-fixture":{"inputCostPerToken":0,"outputCostPerToken":0.001}}}}"#.utf8).write(to: mixedNoTierConfig)
        try Data(#"{"defaults":{"pricingOverrides":{"ccusage-zero-fixture":{"inputCostPerToken":0.000001,"outputCostPerToken":0}}}}"#.utf8).write(to: mixedOutputZeroConfig)
        try Data(#"{"defaults":{"pricingOverrides":{"ccusage-zero-fixture":{"inputCostPerToken":0,"outputCostPerToken":0.000000002,"inputCostPerTokenAbove200kTokens":0,"outputCostPerTokenAbove200kTokens":0.000000008}}}}"#.utf8).write(to: mixedConfig)
        try Data(#"{"defaults":{"pricingOverrides":{"ccusage-zero-fixture":{"inputCostPerToken":0,"outputCostPerToken":0.001,"inputCostPerTokenAbove200kTokens":0}}}}"#.utf8).write(to: partialTierConfig)

        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        let previousCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("HOME", home.path, 1)
        setenv("CODEX_HOME", root.appendingPathComponent("codex").path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
            if let previousCodexHome {
                setenv("CODEX_HOME", previousCodexHome, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }

        var settings = MonitorSettings.default
        settings.lookbackDays = 30
        let runner = CCUsageRunner(timeout: 60, bundledExecutableURL: bundledURL)
        let baseline = try runner.run(
            settings: settings,
            mode: .offlinePricing,
            previousPricingDate: nil,
            pricingConfigURL: positiveConfig
        )
        let allFree = try runner.run(
            settings: settings,
            mode: .offlinePricing,
            previousPricingDate: nil,
            pricingConfigURL: zeroConfig
        )
        let mixedNoTier = try runner.run(
            settings: settings,
            mode: .offlinePricing,
            previousPricingDate: nil,
            pricingConfigURL: mixedNoTierConfig
        )
        let mixedOutputZero = try runner.run(
            settings: settings,
            mode: .offlinePricing,
            previousPricingDate: nil,
            pricingConfigURL: mixedOutputZeroConfig
        )
        let mixed = try runner.run(
            settings: settings,
            mode: .offlinePricing,
            previousPricingDate: nil,
            pricingConfigURL: mixedConfig
        )
        let partialTier = try runner.run(
            settings: settings,
            mode: .offlinePricing,
            previousPricingDate: nil,
            pricingConfigURL: partialTierConfig
        )

        let baselineCost = try XCTUnwrap(baseline.models.first?.estimatedCost)
        let allFreeCost = try XCTUnwrap(allFree.models.first?.estimatedCost)
        XCTAssertEqual(baselineCost, 0.252, accuracy: 0.000001)
        XCTAssertEqual(allFreeCost, 0, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(mixedNoTier.models.first?.estimatedCost), 1, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(mixedOutputZero.models.first?.estimatedCost), 0.25, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(mixed.models.first?.estimatedCost), 0.000008, accuracy: 0.000000001)
        // The backend falls back to the base output rate when that tier field
        // is missing; PricingResolutionTests verifies the app rejects the
        // incomplete tier instead of trusting this partial backend estimate.
        XCTAssertEqual(try XCTUnwrap(partialTier.models.first?.estimatedCost), 1, accuracy: 0.000001)
    }

    func testBundledCcusageNoConfigExposesUnpricedSyntheticZero() throws {
        guard FileManager.default.isExecutableFile(atPath: bundledURL.path) else {
            throw XCTSkip("Bundled ccusage native binary is not available")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.UnpricedZeroLiveRunnerTests.\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let sessions = root.appendingPathComponent("codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fixture = recentCodexTimestamp()
        let modelName = "ccusage-unpriced-zero-fixture-\(fixture.day)"
        let session = """
        {"timestamp":"\(fixture.timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"model":"\(modelName)","last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":1100}}}}
        """
        try Data(session.utf8).write(to: sessions.appendingPathComponent("session.jsonl"))

        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        let previousCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("HOME", home.path, 1)
        setenv("CODEX_HOME", root.appendingPathComponent("codex").path, 1)
        defer {
            if let previousHome {
                setenv("HOME", previousHome, 1)
            } else {
                unsetenv("HOME")
            }
            if let previousCodexHome {
                setenv("CODEX_HOME", previousCodexHome, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }

        var settings = MonitorSettings.default
        settings.lookbackDays = 30
        let runner = CCUsageRunner(timeout: 60, bundledExecutableURL: bundledURL)
        let result = try runner.run(
            settings: settings,
            mode: .offlinePricing,
            previousPricingDate: nil,
            pricingConfigURL: nil
        )

        let model = try XCTUnwrap(result.models.first { $0.name == modelName })
        XCTAssertEqual(model.estimatedCost, 0)
        XCTAssertFalse(model.hasKnownPricing)
    }
}
