import Darwin
import Foundation

enum CCUsageRunnerError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case timedOut
    case failed(status: Int32, message: String)
    case invalidJSON(String)
    case monthlyDataUnavailable

    func message(language: AppLanguage) -> String {
        let copy = L10n(language: language)
        switch self {
        case .executableNotFound:
            return copy.text("The bundled ccusage binary was not found.", "找不到 app 内置的 ccusage 程序。")
        case let .launchFailed(message):
            return copy.text("Could not start ccusage: \(message)", "无法启动 ccusage：\(message)")
        case .timedOut:
            return copy.text("ccusage timed out. The previous snapshot is kept.", "ccusage 刷新超时，已保留上一次结果。")
        case let .failed(status, message):
            return message.isEmpty ? copy.text("ccusage exited with status \(status).", "ccusage 退出码 \(status)。") : copy.text("ccusage failed: \(message)", "ccusage 失败：\(message)")
        case let .invalidJSON(message):
            return copy.text("ccusage returned unreadable data: \(message)", "ccusage 返回了无法识别的数据：\(message)")
        case .monthlyDataUnavailable:
            return copy.text("Monthly budget data is unavailable.", "每月额度数据暂不可用。")
        }
    }

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "找不到 app 内置的 ccusage 程序。"
        case let .launchFailed(message):
            return "无法启动 ccusage：\(message)"
        case .timedOut:
            return "ccusage 刷新超时，已保留上一次结果。"
        case let .failed(status, message):
            return message.isEmpty ? "ccusage 退出码 \(status)。" : "ccusage 失败：\(message)"
        case let .invalidJSON(message):
            return "ccusage 返回了无法识别的数据：\(message)"
        case .monthlyDataUnavailable:
            return "每月额度数据暂不可用。"
        }
    }
}

struct CCUsageCommand: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
}

enum CCUsageRunMode: Equatable, Sendable {
    case usage
    case onlinePricing
    case offlinePricing

    var onlinePricing: Bool {
        self == .onlinePricing
    }

    var includesCost: Bool {
        true
    }
}

final class CCUsageRunner: @unchecked Sendable {
    private let fileManager: FileManager
    private let timeout: TimeInterval
    private let bundledExecutableURL: URL?

    init(
        fileManager: FileManager = .default,
        timeout: TimeInterval = 45,
        bundledExecutableURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.timeout = timeout
        self.bundledExecutableURL = bundledExecutableURL
    }

    func command(settings: MonitorSettings, mode: CCUsageRunMode) throws -> CCUsageCommand {
        try command(settings: settings, mode: mode, pricingConfigURL: nil, now: Date())
    }

    func command(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        pricingConfigURL: URL?
    ) throws -> CCUsageCommand {
        try command(settings: settings, mode: mode, pricingConfigURL: pricingConfigURL, now: Date())
    }

    private func command(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        pricingConfigURL: URL?,
        now: Date
    ) throws -> CCUsageCommand {
        let executable = try resolveExecutable()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let scope = Self.queryScope(for: settings.lookbackDays, now: now, calendar: calendar)

        var args = [
            "daily",
            "--by-agent",
            "--json",
            "--no-color",
            "--since",
            scope.since,
            "--until",
            scope.until
        ]
        if !mode.onlinePricing {
            args.append(contentsOf: ["--offline"])
        }
        if !mode.includesCost {
            args.append("--no-cost")
        }
        if mode.includesCost, let pricingConfigURL {
            args.append(contentsOf: ["--config", pricingConfigURL.path])
        }
        return CCUsageCommand(executable: executable, arguments: args)
    }

    func monthlyCommand(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        pricingConfigURL: URL? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> CCUsageCommand {
        let executable = try resolveExecutable()
        var queryCalendar = calendar
        queryCalendar.timeZone = calendar.timeZone
        let components = queryCalendar.dateComponents([.year, .month], from: now)
        let monthStart = queryCalendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)) ?? queryCalendar.startOfDay(for: now)
        let endDate = queryCalendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.calendar = queryCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = queryCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var args = [
            "monthly",
            "--by-agent",
            "--json",
            "--no-color",
            "--sections",
            "daily,monthly",
            "--since",
            formatter.string(from: monthStart),
            "--until",
            formatter.string(from: endDate)
        ]
        if !mode.onlinePricing {
            args.append("--offline")
        }
        if mode.includesCost, let pricingConfigURL {
            args.append(contentsOf: ["--config", pricingConfigURL.path])
        }
        _ = settings
        return CCUsageCommand(executable: executable, arguments: args)
    }

    static func startDate(for lookbackDays: Int, now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        if lookbackDays == MonitorSettings.calendarMonthLookback {
            let components = calendar.dateComponents([.year, .month], from: now)
            return calendar.startOfDay(for: calendar.date(from: components) ?? today)
        }

        return calendar.date(byAdding: .day, value: -max(0, lookbackDays - 1), to: today) ?? today
    }

    static func queryScope(for lookbackDays: Int, now: Date, calendar: Calendar = .current) -> UsageQueryScope {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let start = startDate(for: lookbackDays, now: now, calendar: calendar)
        let end = calendar.startOfDay(for: now)
        return UsageQueryScope(
            since: formatter.string(from: start),
            until: formatter.string(from: end),
            timeZone: calendar.timeZone.identifier,
            lookbackDays: lookbackDays
        )
    }

    func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot {
        try run(
            settings: settings,
            mode: mode,
            previousPricingDate: previousPricingDate,
            pricingConfigURL: nil
        )
    }

    func run(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?
    ) throws -> UsageSnapshot {
        try runWithPricingContext(
            settings: settings,
            mode: mode,
            previousPricingDate: previousPricingDate,
            pricingConfigURL: pricingConfigURL,
            pricingContext: .empty
        ).snapshot
    }

    func runWithPricingContext(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?,
        pricingContext: PricingResolutionContext
    ) throws -> UsageSnapshotBuildResult {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let scope = Self.queryScope(for: settings.lookbackDays, now: now, calendar: calendar)
        let command = try command(
            settings: settings,
            mode: mode,
            pricingConfigURL: pricingConfigURL,
            now: now
        )
        let output = try runProcess(command)
        let decoder = JSONDecoder()
        let response: CCUsageResponse
        do {
            response = try decoder.decode(CCUsageResponse.self, from: output)
        } catch {
            throw CCUsageRunnerError.invalidJSON(error.localizedDescription)
        }
        return UsageSnapshotBuilder.makeResult(
            from: response,
            pricingUpdatedAt: mode.onlinePricing ? Date() : previousPricingDate,
            queryScope: scope,
            pricingContext: pricingContext
        )
    }

    func runMonthlyBudget(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?,
        customPricingRevision: String?,
        now: Date
    ) throws -> MonthlyBudgetSnapshot {
        try runMonthlyBudgetWithPricingContext(
            settings: settings,
            mode: mode,
            previousPricingDate: previousPricingDate,
            pricingConfigURL: pricingConfigURL,
            customPricingRevision: customPricingRevision,
            now: now,
            pricingContext: .empty
        ).snapshot
    }

    func runMonthlyBudgetWithPricingContext(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?,
        customPricingRevision: String?,
        now: Date,
        pricingContext: PricingResolutionContext
    ) throws -> MonthlyBudgetBuildResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let month = MonthlyBudgetSnapshot.monthPeriod(for: now, calendar: calendar)
        let command = try monthlyCommand(
            settings: settings,
            mode: mode,
            pricingConfigURL: pricingConfigURL,
            now: now,
            calendar: calendar
        )
        let output = try runProcess(command)
        let response: CCUsageResponse
        do {
            response = try JSONDecoder().decode(CCUsageResponse.self, from: output)
        } catch {
            throw CCUsageRunnerError.invalidJSON(error.localizedDescription)
        }
        return UsageSnapshotBuilder.makeMonthlyBudgetResult(
            from: response,
            month: month,
            pricingUpdatedAt: mode.onlinePricing ? now : previousPricingDate,
            customPricingRevision: customPricingRevision,
            modelCatalogRevision: pricingContext.remoteCatalogRevision,
            realtimeAnchorDay: MonthlyBudgetSnapshot.dayPeriod(for: now, calendar: calendar),
            pricingContext: pricingContext
        )
    }

    private func resolveExecutable() throws -> URL {
        if let bundled = bundledExecutableURL ?? Bundle.main.resourceURL?.appendingPathComponent("ccusage"),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        throw CCUsageRunnerError.executableNotFound
    }

    private func runProcess(_ command: CCUsageCommand) throws -> Data {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let timeoutState = TimeoutState()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? ""
        if !path.contains("/opt/homebrew/bin") {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        }
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw CCUsageRunnerError.launchFailed(error.localizedDescription)
        }

        let processGroupID = process.processIdentifier
        // Put the bundled runner in its own group when the platform permits
        // it. The direct-pid fallback below still handles the normal case if
        // the child has already exec'd before setpgid can succeed.
        _ = setpgid(processGroupID, processGroupID)

        let outputBox = ProcessOutputBox()
        let errorBox = ProcessOutputBox()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        let timeoutWork = DispatchWorkItem { [pid = process.processIdentifier, processGroupID] in
            timeoutState.didTimeout = true
            // Prefer the isolated process group so descendants cannot outlive
            // a timed-out run; always kill the direct child as a fallback.
            if process.isRunning {
                _ = kill(-processGroupID, SIGKILL)
                _ = kill(pid, SIGKILL)
            }
            // A descendant can keep either pipe open after the direct child
            // exits. Closing the read ends guarantees readDataToEndOfFile()
            // returns instead of holding the refresh slot forever.
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        process.waitUntilExit()
        timeoutWork.cancel()
        if readers.wait(timeout: .now() + 2) == .timedOut {
            timeoutState.didTimeout = true
            _ = kill(-processGroupID, SIGKILL)
            _ = kill(process.processIdentifier, SIGKILL)
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            _ = readers.wait(timeout: .now() + 1)
        }

        let output = outputBox.data
        let errorData = errorBox.data
        let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if timeoutState.didTimeout { throw CCUsageRunnerError.timedOut }
        guard process.terminationStatus == 0 else {
            throw CCUsageRunnerError.failed(status: process.terminationStatus, message: errorMessage)
        }
        return output
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var didTimeout: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

private final class ProcessOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    var data: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}
