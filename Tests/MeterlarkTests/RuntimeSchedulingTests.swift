import CoreServices
import XCTest
@testable import MeterlarkApp

private final class StubSourceChangeWatcher: SourceChangeWatcherProtocol {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var isRunning: Bool
    var handler: (() -> Void)?

    init(isRunning: Bool = false) {
        self.isRunning = isRunning
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func emit() {
        handler?()
    }
}

private enum TestFingerprintError: Error, Sendable {
    case unavailable
}

@MainActor
final class RuntimeSchedulingTests: XCTestCase {
    func testFallbackIsDueImmediatelyAtLaunch() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(RefreshSchedule.isFallbackCheckDue(lastCheckAt: nil, now: now, refreshInterval: 60))
    }

    func testFallbackUsesRefreshIntervalForConfiguredBuckets() {
        let now = Date(timeIntervalSince1970: 10_000)
        for interval in MonitorSettings.allowedIntervals {
            let check = now.addingTimeInterval(-(interval - 0.1))
            XCTAssertFalse(RefreshSchedule.isFallbackCheckDue(lastCheckAt: check, now: now, refreshInterval: interval), "interval=\(interval)")
            XCTAssertTrue(RefreshSchedule.isFallbackCheckDue(lastCheckAt: now.addingTimeInterval(-interval), now: now, refreshInterval: interval), "interval=\(interval)")
        }
    }

    func testFallbackIgnoresInvalidRefreshInterval() {
        let now = Date(timeIntervalSince1970: 10_000)
        let last = now.addingTimeInterval(-10_000)
        XCTAssertFalse(RefreshSchedule.isFallbackCheckDue(lastCheckAt: last, now: now, refreshInterval: .nan))
        XCTAssertFalse(RefreshSchedule.isFallbackCheckDue(lastCheckAt: last, now: now, refreshInterval: -1))
    }

    func testFallbackRetryDelayScalesWithRefreshInterval() {
        XCTAssertEqual(RefreshSchedule.fallbackRetryDelay(refreshInterval: 30), 10)
        XCTAssertEqual(RefreshSchedule.fallbackRetryDelay(refreshInterval: 60), 20)
        XCTAssertEqual(RefreshSchedule.fallbackRetryDelay(refreshInterval: 300), 100)
        XCTAssertEqual(RefreshSchedule.fallbackRetryDelay(refreshInterval: 900), 300)
    }

    func testPricingRefreshDueUsesMostRecentAttemptOrSuccess() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(RefreshSchedule.isPricingRefreshDue(lastSuccessfulAt: nil, lastAttemptAt: nil, now: now, interval: 86_400))
        XCTAssertFalse(RefreshSchedule.isPricingRefreshDue(lastSuccessfulAt: now.addingTimeInterval(-10), lastAttemptAt: nil, now: now, interval: 86_400))
        XCTAssertFalse(RefreshSchedule.isPricingRefreshDue(lastSuccessfulAt: now.addingTimeInterval(-90_000), lastAttemptAt: now.addingTimeInterval(-10), now: now, interval: 86_400))
        XCTAssertTrue(RefreshSchedule.isPricingRefreshDue(lastSuccessfulAt: now.addingTimeInterval(-90_000), lastAttemptAt: nil, now: now, interval: 86_400))
    }

    func testLaunchRunsOneImmediateFallbackCheckWhenWatcherIsDown() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher()
        let recoveredWatcher = StubSourceChangeWatcher()
        let store = try makeStore(clock: clock, interval: 60, watchers: [watcher, recoveredWatcher])

        waitForFallbackCompletion(store)
        XCTAssertNotNil(store.lastFallbackCheckAtForTesting)
        XCTAssertEqual(watcher.startCount, 1)
        XCTAssertEqual(recoveredWatcher.startCount, 1, "the initial watcher install and one recovery attempt are expected")
    }

    func testFallbackCheckIsThrottledByRefreshIntervalWhenWatcherStaysDown() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher()
        let store = try makeStore(clock: clock, interval: 900, watchers: [watcher, StubSourceChangeWatcher()])
        waitForFallbackCompletion(store)
        guard let checkAt = store.lastFallbackCheckAtForTesting else {
            return XCTFail("launch fallback check never ran")
        }

        clock.now = checkAt.addingTimeInterval(899)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(store.lastFallbackCheckAtForTesting, checkAt, "fallback must not rescan before refreshInterval")

        clock.now = checkAt.addingTimeInterval(900)
        store.periodicCheckForTesting(now: clock.now)
        waitForFallbackCompletion(store)
        XCTAssertEqual(store.lastFallbackCheckAtForTesting, clock.now, "fallback should rescan at the refresh boundary")
    }

    func testFallbackCheckFailuresBackOffInsteadOfRescanningEveryTick() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher()
        let store = try makeStore(clock: clock, interval: 300, watchers: [watcher], fingerprintError: .unavailable)
        waitForFallbackCompletion(store)
        XCTAssertEqual(store.fallbackCheckFailuresForTesting, 1)

        guard let firstFailureAt = store.lastFallbackCheckAtForTesting else {
            return XCTFail("launch fallback check never ran")
        }
        clock.now = firstFailureAt.addingTimeInterval(20)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(store.fallbackCheckFailuresForTesting, 1, "failed scans must not stack on 5-second ticks")

        clock.now = firstFailureAt.addingTimeInterval(100)
        store.periodicCheckForTesting(now: clock.now)
        waitForFallbackCompletion(store)
        XCTAssertEqual(store.fallbackCheckFailuresForTesting, 2, "retry should fire after the backoff window")
    }

    func testPeriodicFingerprintFailureUsesFingerprintIntervalForRetry() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let store = try makeStore(
            clock: clock,
            interval: 900,
            watchers: [watcher],
            fingerprintError: .unavailable,
            verificationMode: .periodicFingerprint,
            fingerprintCheckInterval: 60
        )
        waitForFallbackCompletion(store)
        XCTAssertEqual(store.fallbackCheckFailuresForTesting, 1)

        guard let firstFailureAt = store.lastFallbackCheckAtForTesting else {
            return XCTFail("launch fingerprint check never ran")
        }
        clock.now = firstFailureAt.addingTimeInterval(19)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(store.fallbackCheckFailuresForTesting, 1, "periodic retry must wait for its own backoff")

        clock.now = firstFailureAt.addingTimeInterval(20)
        store.periodicCheckForTesting(now: clock.now)
        waitForFallbackCompletion(store)
        XCTAssertEqual(store.fallbackCheckFailuresForTesting, 2, "periodic retry should use one third of the 60-second fingerprint interval")
    }

    func testWatcherRecoveryStopsFallbackChecks() throws {
        let clock = TestClock()
        let firstWatcher = StubSourceChangeWatcher()
        let recoveredWatcher = StubSourceChangeWatcher(isRunning: true)
        let store = try makeStore(clock: clock, interval: 60, watchers: [firstWatcher, recoveredWatcher])
        waitForFallbackCompletion(store)
        XCTAssertEqual(firstWatcher.startCount, 1)
        XCTAssertEqual(recoveredWatcher.startCount, 1)

        let checkAt = store.lastFallbackCheckAtForTesting!
        clock.now = checkAt.addingTimeInterval(31)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(store.fallbackCheckFailuresForTesting, 0, "a recovered watcher disables fallback scans")
    }

    func testFirstWatcherDownFallbackReconcilesWithoutAnExistingBaseline() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let fingerprint = SourceFingerprint(
            root: "/tmp/ccusage-watcher-down-root",
            modificationTime: Date(timeIntervalSince1970: 100),
            fileCount: 1,
            latestFileModificationTime: Date(timeIntervalSince1970: 100)
        )
        let runner = BlockingUsageRunner(snapshot: .empty)
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [watcher],
            fingerprintReader: { [fingerprint] },
            runner: runner
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 2), .success)
        runner.releaseFirst()
        waitForRefreshCompletion(store)
        XCTAssertFalse(store.hasFallbackFingerprintBaselineForTesting)

        watcher.isRunning = false
        clock.now = clock.now.addingTimeInterval(1)
        store.periodicCheckForTesting(now: clock.now)
        waitForFallbackCompletion(store)

        XCTAssertTrue(store.hasFallbackFingerprintBaselineForTesting)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.lastSourceChangeCauseForTesting, "watcherDownFallback")
    }

    func testFallbackDoesNotRunMonthlyBudgetConcurrently() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher()
        let fallbackStarted = DispatchSemaphore(value: 0)
        let fallbackRelease = DispatchSemaphore(value: 0)
        let monthlyStarted = DispatchSemaphore(value: 0)
        let monthlyRelease = DispatchSemaphore(value: 0)
        let runner = MonthlyBudgetStubRunner(
            usageSnapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 2
            ),
            monthlySnapshot: { now in self.makeMonthlyBudgetSnapshot(now: now, cost: 12) },
            monthlyStarted: monthlyStarted,
            monthlyRelease: monthlyRelease
        )
        let store = try makeBudgetStore(
            clock: clock,
            runner: runner,
            watcher: watcher,
            fingerprintReader: {
                fallbackStarted.signal()
                _ = fallbackRelease.wait(timeout: .now() + 2)
                return []
            }
        )

        XCTAssertEqual(fallbackStarted.wait(timeout: .now() + 2), .success)
        clock.now = clock.now.addingTimeInterval(3)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        XCTAssertEqual(runner.monthlyCallCount, 0, "monthly budget must wait for an in-flight fallback scan")

        fallbackRelease.signal()
        waitForFallbackCompletion(store)
        waitForMonthlyBudgetCall(runner, count: 1)
        XCTAssertEqual(monthlyStarted.wait(timeout: .now() + 2), .success)
        monthlyRelease.signal()
        waitForMonthlyBudgetCompletion(store)
    }

    func testMonthlyBudgetDoesNotRunFallbackConcurrently() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let fallbackStarted = DispatchSemaphore(value: 0)
        let monthlyStarted = DispatchSemaphore(value: 0)
        let monthlyRelease = DispatchSemaphore(value: 0)
        let runner = MonthlyBudgetStubRunner(
            usageSnapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 2
            ),
            monthlySnapshot: { now in self.makeMonthlyBudgetSnapshot(now: now, cost: 12) },
            monthlyStarted: monthlyStarted,
            monthlyRelease: monthlyRelease
        )
        let store = try makeBudgetStore(
            clock: clock,
            runner: runner,
            watcher: watcher,
            fingerprintReader: {
                fallbackStarted.signal()
                return []
            }
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        XCTAssertEqual(monthlyStarted.wait(timeout: .now() + 2), .success)

        watcher.isRunning = false
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertNil(store.lastFallbackCheckAtForTesting, "fallback must wait for an in-flight monthly budget refresh")
        XCTAssertEqual(fallbackStarted.wait(timeout: .now() + 0.1), .timedOut)

        monthlyRelease.signal()
        waitForMonthlyBudgetCompletion(store)
        XCTAssertEqual(fallbackStarted.wait(timeout: .now() + 2), .success)
        waitForFallbackCompletion(store)
    }

    func testUsageRefreshRemainsThrottledWhenFallbackMarksDirty() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let store = try makeStore(clock: clock, interval: 300, watchers: [watcher])

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)

        store.markDirty()
        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertFalse(store.refreshInFlightForTesting, "dirty flag alone must not bypass refreshInterval")

        clock.now = clock.now.addingTimeInterval(300)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertTrue(store.refreshInFlightForTesting, "usage refresh should fire after refreshInterval elapses")
    }

    func testContinuousSourceStormUsesRefreshIntervalAsMaximumWait() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let runner = BlockingUsageRunner(snapshot: .empty)
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [watcher],
            runner: runner
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 2), .success)
        runner.releaseFirst()
        waitForRefreshCompletion(store)

        // Keep the source dirty right before the throttle expires. The quiet
        // window is intentionally never reached, so the interval cap is the
        // only way this refresh can start.
        store.markDirty()
        clock.now = clock.now.addingTimeInterval(59)
        store.markDirty()
        clock.now = clock.now.addingTimeInterval(1)
        store.periodicCheckForTesting(now: clock.now)

        let deadline = Date().addingTimeInterval(2)
        while runner.callCount < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(runner.callCount, 2, "a continuous source storm must not starve usage refresh beyond the configured interval")
        waitForRefreshCompletion(store)
    }

    func testContinuousSourceChangesPublishEachCompletedScanAndRemainDirty() throws {
        let clock = TestClock()
        let scope = CCUsageRunner.queryScope(for: 30, now: clock.now)
        let candidates = (1...3).map { makeScopedSnapshot(scope: scope, cost: Double($0)) }
        let runner = BlockingEveryUsageRunner(snapshots: candidates)
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [StubSourceChangeWatcher(isRunning: true)],
            runner: runner
        )

        for expected in candidates {
            clock.now = clock.now.addingTimeInterval(61)
            store.periodicCheckForTesting(now: clock.now)
            XCTAssertEqual(runner.started.wait(timeout: .now() + 2), .success)
            store.markDirty()
            runner.release.signal()
            waitForRefreshCompletion(store)

            XCTAssertEqual(store.snapshot.estimatedCost, expected.estimatedCost)
            XCTAssertTrue(store.isDirty, "events arriving during the scan still need a later refresh")
            XCTAssertFalse(store.refreshInFlightForTesting, "the next scan must respect the refresh interval")
        }
    }

    func testSourceChangeDuringUsageRefreshDefersReplacementUntilThrottleAndSettle() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let runner = BlockingUsageRunner(snapshot: .empty)
        let store = try makeStore(
            clock: clock,
            interval: 300,
            watchers: [watcher],
            runner: runner
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 2), .success)
        store.markDirty()
        runner.releaseFirst()
        waitForRefreshCompletion(store)

        XCTAssertEqual(runner.callCount, 1, "a source change must not immediately start a replacement scan")
        XCTAssertTrue(store.isDirty, "events after the scan started must leave the source dirty")

        clock.now = clock.now.addingTimeInterval(299)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.callCount, 1, "the replacement must respect the configured refresh interval")

        clock.now = clock.now.addingTimeInterval(1)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertTrue(store.refreshInFlightForTesting, "the replacement should start when the throttle expires")
        waitForRefreshCompletion(store)
        XCTAssertEqual(runner.callCount, 2)
    }

    func testUsageFailureSchedulesRetryAtConfiguredInterval() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let runner = FailingUsageRunner()
        let store = try makeStore(
            clock: clock,
            interval: 300,
            watchers: [watcher],
            runner: runner
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRunnerCall(runner, count: 1)
        waitForRefreshCompletion(store)

        clock.now = clock.now.addingTimeInterval(299)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.callCount, 1, "a failed refresh must remain throttled until the configured interval")

        clock.now = clock.now.addingTimeInterval(1)
        store.periodicCheckForTesting(now: clock.now)
        waitForRunnerCall(runner, count: 2)
        XCTAssertEqual(runner.callCount, 2)
    }

    func testManualRefreshStillBypassesThrottleWhenCurrentRefreshIsInFlight() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let runner = BlockingUsageRunner(snapshot: .empty)
        let store = try makeStore(
            clock: clock,
            interval: 900,
            watchers: [watcher],
            runner: runner
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 2), .success)
        store.refreshNow()
        XCTAssertEqual(store.lastSourceChangeCauseForTesting, "manual")
        runner.releaseFirst()

        let deadline = Date().addingTimeInterval(2)
        while runner.callCount < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(runner.callCount, 2, "an explicit manual refresh must retain its bypass semantics")
        waitForRefreshCompletion(store)
    }

    func testManualUsageRefreshIsRetainedWhenPricingIsQueued() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let runner = ModeRecordingRunner(
            snapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 1
            )
        )
        let store = try makeStore(clock: clock, interval: 900, watchers: [watcher], runner: runner)

        store.updatePricingNow()
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 2), .success)
        store.refreshNow()
        runner.releaseFirst()

        waitForRunnerModes(runner, count: 2)
        XCTAssertEqual(runner.modesForTesting, [.onlinePricing, .usage])
        waitForRefreshCompletion(store)
    }

    func testSourceEventGateCoalescesCallbacksButPreservesCount() {
        let lock = NSLock()
        var deliveryCounts: [Int] = []
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let submissions = 100
        let gate = SourceEventGate { callbackCount, completion in
            lock.lock()
            deliveryCounts.append(callbackCount)
            let deliveryNumber = deliveryCounts.count
            lock.unlock()

            if deliveryNumber == 1 {
                firstStarted.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
            }
            completion()
        }

        let group = DispatchGroup()
        for _ in 0..<submissions {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                gate.submit()
                group.leave()
            }
        }

        XCTAssertEqual(firstStarted.wait(timeout: .now() + 2), .success)
        releaseFirst.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

        let deadline = Date().addingTimeInterval(2)
        while true {
            lock.lock()
            let counts = deliveryCounts
            lock.unlock()
            if counts.reduce(0, +) == submissions || Date() >= deadline {
                XCTAssertEqual(counts.reduce(0, +), submissions)
                XCTAssertLessThan(counts.count, submissions, "callback delivery should be coalesced")
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testFSEventRecoveryFlagsInvalidateWatcherHealth() {
        XCTAssertFalse(SourceChangeWatcher.eventRequiresRecovery(0))
        XCTAssertTrue(SourceChangeWatcher.eventRequiresRecovery(FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)))
        XCTAssertTrue(SourceChangeWatcher.eventRequiresRecovery(FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)))
        XCTAssertTrue(SourceChangeWatcher.eventRequiresRecovery(FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)))
    }

    func testFSEventRecoveryChecksEveryEventInTheCallbackBatch() {
        let flags = [
            FSEventStreamEventFlags(0),
            FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        ]

        flags.withUnsafeBufferPointer { buffer in
            XCTAssertTrue(SourceChangeWatcher.eventBatchRequiresRecovery(buffer))
        }
    }

    func testWatcherEventUsesSettledOneShotCheckWithoutWaitingForWatchdog() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let store = try makeStore(clock: clock, interval: 60, watchers: [watcher])

        // Finish the launch refresh through the deterministic seam so the
        // event below is the only source of the second refresh.
        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        XCTAssertFalse(store.isDirty)
        let baselineEventCount = store.watcherEventCountForTesting
        let baselineRefreshStart = store.lastRefreshStartedAtForTesting

        // Move past the usage throttle before emitting the event. The test is
        // about the settled event path, not the separate due-time scheduler.
        clock.now = Date().addingTimeInterval(60)
        watcher.emit()
        let deadline = Date().addingTimeInterval(4)
        while store.watcherEventCountForTesting == baselineEventCount, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(store.watcherEventCountForTesting, baselineEventCount + 1, "watcher event should be delivered")

        // Drive the settled one-shot scheduler through its deterministic seam
        // instead of depending on the wall-clock timer in a test process.
        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        XCTAssertNotEqual(store.lastRefreshStartedAtForTesting, baselineRefreshStart, "the settled one-shot check should start a refresh")
        XCTAssertFalse(store.isDirty, "the settled one-shot check should refresh before the watchdog")
    }

    func testPeriodicFingerprintSeedsBaselineAndSkipsUnchangedSource() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let fingerprint = SourceFingerprint(
            root: "/tmp/ccusage-periodic-root",
            modificationTime: Date(timeIntervalSince1970: 100),
            fileCount: 1,
            latestFileModificationTime: Date(timeIntervalSince1970: 100)
        )
        let fingerprints = FingerprintSequence(values: [[fingerprint], [fingerprint]])
        let runner = BlockingUsageRunner(snapshot: .empty)
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [watcher],
            verificationMode: .periodicFingerprint,
            fingerprintCheckInterval: 60,
            fingerprintReader: { fingerprints.next() },
            runner: runner
        )

        waitForFallbackCompletion(store)
        XCTAssertTrue(store.hasFallbackFingerprintBaselineForTesting)

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 2), .success)
        runner.releaseFirst()
        waitForRefreshCompletion(store)
        XCTAssertFalse(store.isDirty)
        let generation = store.dirtyGenerationForTesting
        let usageCallCount = runner.callCount
        let firstCheckAt = try XCTUnwrap(store.lastFallbackCheckAtForTesting)

        clock.now = firstCheckAt.addingTimeInterval(59)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(store.fallbackScanCountForTesting, 1)

        clock.now = firstCheckAt.addingTimeInterval(60)
        store.periodicCheckForTesting(now: clock.now)
        waitForFallbackCompletion(store)

        XCTAssertEqual(store.fallbackScanCountForTesting, 2)
        XCTAssertEqual(store.fingerprintCheckOutcomeForTesting, "unchanged")
        XCTAssertEqual(store.dirtyGenerationForTesting, generation)
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(runner.callCount, usageCallCount, "unchanged metadata must not launch ccusage")
    }

    func testPeriodicFingerprintChangeUsesExistingDirtyRefreshPipeline() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let first = SourceFingerprint(
            root: "/tmp/ccusage-periodic-root",
            modificationTime: Date(timeIntervalSince1970: 100),
            fileCount: 1,
            latestFileModificationTime: Date(timeIntervalSince1970: 100)
        )
        let second = SourceFingerprint(
            root: first.root,
            modificationTime: Date(timeIntervalSince1970: 200),
            fileCount: 2,
            latestFileModificationTime: Date(timeIntervalSince1970: 200)
        )
        let fingerprints = FingerprintSequence(values: [[first], [second]])
        let runner = BlockingUsageRunner(snapshot: .empty)
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [watcher],
            verificationMode: .periodicFingerprint,
            fingerprintCheckInterval: 60,
            fingerprintReader: { fingerprints.next() },
            runner: runner
        )

        waitForFallbackCompletion(store)
        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 2), .success)
        runner.releaseFirst()
        waitForRefreshCompletion(store)
        let cleanGeneration = store.dirtyGenerationForTesting
        let firstCheckAt = try XCTUnwrap(store.lastFallbackCheckAtForTesting)

        clock.now = firstCheckAt.addingTimeInterval(60)
        store.periodicCheckForTesting(now: clock.now)
        waitForFallbackCompletion(store)

        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.dirtyGenerationForTesting, cleanGeneration + 1)
        XCTAssertEqual(store.lastSourceChangeCauseForTesting, "periodicFingerprint")
        XCTAssertEqual(runner.callCount, 1, "fingerprint detection should wait for the normal settle window")

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForUsageCall(runner, count: 2)
        waitForRefreshCompletion(store)
        XCTAssertFalse(store.isDirty)
    }

    func testPeriodicFingerprintChangeDuringDirtyUsageRefreshIsRetained() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let first = SourceFingerprint(
            root: "/tmp/ccusage-periodic-root",
            modificationTime: Date(timeIntervalSince1970: 100),
            fileCount: 1,
            latestFileModificationTime: Date(timeIntervalSince1970: 100)
        )
        let second = SourceFingerprint(
            root: first.root,
            modificationTime: Date(timeIntervalSince1970: 200),
            fileCount: 2,
            latestFileModificationTime: Date(timeIntervalSince1970: 200)
        )
        let fingerprints = FingerprintSequence(values: [[first], [second]])
        let runner = BlockingUsageRunner(snapshot: .empty)
        let store = try makeStore(
            clock: clock,
            interval: 300,
            watchers: [watcher],
            verificationMode: .periodicFingerprint,
            fingerprintCheckInterval: 60,
            fingerprintReader: { fingerprints.next() },
            runner: runner
        )

        waitForFallbackCompletion(store)
        let firstCheckAt = try XCTUnwrap(store.lastFallbackCheckAtForTesting)
        watcher.emit()
        waitForWatcherEvent(store, count: 1)
        clock.now = firstCheckAt.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 2), .success)
        let generationAtUsageStart = store.dirtyGenerationForTesting

        clock.now = firstCheckAt.addingTimeInterval(60)
        store.periodicCheckForTesting(now: clock.now)
        waitForFallbackCompletion(store)

        XCTAssertEqual(
            store.dirtyGenerationForTesting,
            generationAtUsageStart + 1,
            "a silent change must advance the dirty generation even when launch usage is already dirty"
        )
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.lastSourceChangeCauseForTesting, "periodicFingerprint")

        runner.releaseFirst()
        waitForRefreshCompletion(store)
        XCTAssertTrue(store.isDirty, "the in-flight usage result must be discarded as stale")
    }

    func testPeriodicFingerprintChangeDuringManualRefreshIsRetained() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let first = SourceFingerprint(
            root: "/tmp/ccusage-periodic-root",
            modificationTime: Date(timeIntervalSince1970: 100),
            fileCount: 1,
            latestFileModificationTime: Date(timeIntervalSince1970: 100)
        )
        let second = SourceFingerprint(
            root: first.root,
            modificationTime: Date(timeIntervalSince1970: 200),
            fileCount: 2,
            latestFileModificationTime: Date(timeIntervalSince1970: 200)
        )
        let fingerprints = InFlightFingerprintSequence(values: [[first], [second], [second]])
        let runner = BlockingUsageRunner(snapshot: .empty, blockCall: 2)
        let store = try makeStore(
            clock: clock,
            interval: 300,
            watchers: [watcher],
            verificationMode: .periodicFingerprint,
            fingerprintCheckInterval: 60,
            fingerprintReader: { fingerprints.next() },
            runner: runner
        )

        waitForFallbackCompletion(store)
        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForUsageCall(runner, count: 1)
        waitForRefreshCompletion(store)
        let firstCheckAt = try XCTUnwrap(store.lastFallbackCheckAtForTesting)
        clock.now = firstCheckAt.addingTimeInterval(60)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(fingerprints.secondScanStarted.wait(timeout: .now() + 2), .success)

        store.refreshNow()
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 2), .success)
        let manualGeneration = store.dirtyGenerationForTesting

        fingerprints.releaseSecondScan()
        waitForFallbackCompletion(store)

        XCTAssertEqual(
            store.dirtyGenerationForTesting,
            manualGeneration + 1,
            "a silent change must advance the generation even when manual refresh started during the scan"
        )
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.lastSourceChangeCauseForTesting, "periodicFingerprint")

        runner.releaseFirst()
        waitForRefreshCompletion(store)
        XCTAssertTrue(store.isDirty, "the manual usage result must be discarded as stale")
    }

    func testPeriodicFingerprintCoalescesAWatcherEventForTheSameChange() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let first = SourceFingerprint(
            root: "/tmp/ccusage-periodic-root",
            modificationTime: Date(timeIntervalSince1970: 100),
            fileCount: 1,
            latestFileModificationTime: Date(timeIntervalSince1970: 100)
        )
        let second = SourceFingerprint(
            root: first.root,
            modificationTime: Date(timeIntervalSince1970: 200),
            fileCount: 2,
            latestFileModificationTime: Date(timeIntervalSince1970: 200)
        )
        let fingerprints = FingerprintSequence(values: [[first], [second]])
        let runner = BlockingUsageRunner(snapshot: .empty)
        let store = try makeStore(
            clock: clock,
            interval: 300,
            watchers: [watcher],
            verificationMode: .periodicFingerprint,
            fingerprintCheckInterval: 60,
            fingerprintReader: { fingerprints.next() },
            runner: runner
        )

        waitForFallbackCompletion(store)
        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 2), .success)
        runner.releaseFirst()
        waitForRefreshCompletion(store)
        let firstCheckAt = try XCTUnwrap(store.lastFallbackCheckAtForTesting)

        watcher.emit()
        waitForWatcherEvent(store, count: 1)
        let eventGeneration = store.dirtyGenerationForTesting
        XCTAssertTrue(store.isDirty)

        clock.now = firstCheckAt.addingTimeInterval(60)
        store.periodicCheckForTesting(now: clock.now)
        waitForFallbackCompletion(store)

        XCTAssertEqual(store.dirtyGenerationForTesting, eventGeneration)
        XCTAssertEqual(store.lastSourceChangeCauseForTesting, "watcherEvent")
        XCTAssertEqual(store.fingerprintCheckOutcomeForTesting, "changed")
    }

    func testPeriodicFingerprintSchedulesFollowUpAfterAnInFlightWatcherEvent() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let first = SourceFingerprint(
            root: "/tmp/ccusage-periodic-root",
            modificationTime: Date(timeIntervalSince1970: 100),
            fileCount: 1,
            latestFileModificationTime: Date(timeIntervalSince1970: 100)
        )
        let second = SourceFingerprint(
            root: first.root,
            modificationTime: Date(timeIntervalSince1970: 200),
            fileCount: 2,
            latestFileModificationTime: Date(timeIntervalSince1970: 200)
        )
        let fingerprints = InFlightFingerprintSequence(values: [[first], [second], [second]])
        let store = try makeStore(
            clock: clock,
            interval: 300,
            watchers: [watcher],
            verificationMode: .periodicFingerprint,
            fingerprintCheckInterval: 60,
            fingerprintReader: { fingerprints.next() }
        )

        waitForFallbackCompletion(store)
        let firstCheckAt = try XCTUnwrap(store.lastFallbackCheckAtForTesting)
        clock.now = firstCheckAt.addingTimeInterval(60)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(fingerprints.secondScanStarted.wait(timeout: .now() + 2), .success)

        watcher.emit()
        waitForWatcherEvent(store, count: 1)
        let eventGeneration = store.dirtyGenerationForTesting
        fingerprints.releaseSecondScan()
        waitForFallbackScanCount(store, count: 3)

        XCTAssertFalse(store.fingerprintCheckRequestedForTesting)
        XCTAssertEqual(store.fallbackScanCountForTesting, 3)
        XCTAssertEqual(store.lastFallbackFingerprintsForTesting, [second])
        XCTAssertEqual(store.dirtyGenerationForTesting, eventGeneration)
        XCTAssertEqual(store.fingerprintCheckOutcomeForTesting, "unchanged")
    }

    func testDeveloperDiagnosticsRecordsWatcherEventsAndHealthBaseline() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let store = try makeStore(clock: clock, interval: 60, watchers: [watcher], developerMode: true)

        waitForHealthProbeCompletion(store)
        XCTAssertGreaterThanOrEqual(store.developerDiagnostics.healthProbeCount, 1)
        XCTAssertEqual(store.developerDiagnostics.watcherState, .running)

        watcher.emit()
        let deadline = Date().addingTimeInterval(2)
        while store.developerDiagnostics.watcherEventCount == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(store.developerDiagnostics.watcherEventCount, 1)
        XCTAssertNotNil(store.developerDiagnostics.watcherLastEventAt)
    }

    func testDeveloperHealthCheckDetectsSilentWatcherDegradation() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let first = SourceFingerprint(
            root: "/tmp/ccusage-health-root",
            modificationTime: Date(timeIntervalSince1970: 100),
            fileCount: 1,
            latestFileModificationTime: Date(timeIntervalSince1970: 100)
        )
        let second = SourceFingerprint(
            root: first.root,
            modificationTime: Date(timeIntervalSince1970: 200),
            fileCount: 2,
            latestFileModificationTime: Date(timeIntervalSince1970: 200)
        )
        let fingerprints = FingerprintSequence(values: [[first], [second]])
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [watcher],
            developerMode: true,
            fingerprintReader: { fingerprints.next() }
        )

        waitForHealthProbeCompletion(store)
        store.runDeveloperHealthCheck()
        waitForHealthProbeCompletion(store)

        XCTAssertEqual(store.developerDiagnostics.watcherState, .degraded)
        XCTAssertEqual(
            store.developerDiagnostics.watcherMessage,
            "Source fingerprint changed without a watcher event"
        )
    }

    func testFreshMonthlyBudgetDoesNotRunWithEveryUsageRefresh() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let monthly = makeMonthlyBudgetSnapshot(now: clock.now, cost: 12)
        let runner = MonthlyBudgetStubRunner(
            usageSnapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 2
            ),
            monthlySnapshot: { now in self.makeMonthlyBudgetSnapshot(now: now, cost: 12) }
        )
        let store = try makeBudgetStore(
            clock: clock,
            runner: runner,
            watcher: watcher,
            monthlySnapshot: monthly
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        store.periodicCheckForTesting(now: clock.now)

        XCTAssertEqual(runner.monthlyCallCount, 0, "a fresh monthly snapshot must not spawn a monthly process after usage refresh")
    }

    func testMonthlyBudgetReconcilesOnItsOwnSchedule() throws {
        let clock = try makeStableMiddayClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let runner = MonthlyBudgetStubRunner(
            usageSnapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 2
            ),
            monthlySnapshot: { now in self.makeMonthlyBudgetSnapshot(now: now, cost: 12) }
        )
        let store = try makeBudgetStore(clock: clock, runner: runner, watcher: watcher)

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        waitForMonthlyBudgetCall(runner, count: 1)
        waitForMonthlyBudgetCompletion(store)
        XCTAssertEqual(runner.monthlyCallCount, 1, "the first monthly snapshot should be reconciled independently")

        clock.now = clock.now.addingTimeInterval(3_599)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.monthlyCallCount, 1, "monthly reconciliation should remain throttled for one hour")

        clock.now = clock.now.addingTimeInterval(1)
        store.periodicCheckForTesting(now: clock.now)
        waitForMonthlyBudgetCall(runner, count: 2)
        waitForMonthlyBudgetCompletion(store)
        XCTAssertEqual(runner.monthlyCallCount, 2, "monthly reconciliation should run at its own due time")
    }

    func testMonthlyBudgetFailureUsesRetryBackoffAfterImmediateRequest() throws {
        let clock = try makeStableMiddayClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let runner = FailingMonthlyBudgetRunner(
            usageSnapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 2
            )
        )
        let store = try makeBudgetStore(clock: clock, runner: runner, watcher: watcher)

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        waitForFailingMonthlyBudgetCall(runner, count: 1)
        waitForMonthlyBudgetCompletion(store)

        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.monthlyCallCount, 1, "a failed immediate request must respect the monthly retry interval")

        clock.now = clock.now.addingTimeInterval(5 * 60)
        store.periodicCheckForTesting(now: clock.now)
        waitForFailingMonthlyBudgetCall(runner, count: 2)
        XCTAssertEqual(runner.monthlyCallCount, 2)
    }

    func testEmptyMonthlyBudgetUsesRetryBackoffInsteadOfSuccessInterval() throws {
        let clock = try makeStableMiddayClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let runner = MonthlyBudgetStubRunner(
            usageSnapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 2
            ),
            monthlySnapshot: { now in
                MonthlyBudgetSnapshot(
                    month: MonthlyBudgetSnapshot.monthPeriod(for: now),
                    generatedAt: now,
                    pricingUpdatedAt: nil,
                    customPricingRevision: nil,
                    models: [],
                    totalTokens: 0,
                    estimatedCost: 0,
                    unknownPricingModels: []
                )
            }
        )
        let previousMonthly = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: clock.now),
            generatedAt: clock.now.addingTimeInterval(-60 * 60),
            pricingUpdatedAt: nil,
            customPricingRevision: nil,
            models: [],
            totalTokens: 10,
            estimatedCost: 80,
            unknownPricingModels: []
        )
        let store = try makeBudgetStore(
            clock: clock,
            runner: runner,
            watcher: watcher,
            monthlySnapshot: previousMonthly
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        waitForMonthlyBudgetCall(runner, count: 1)
        waitForMonthlyBudgetCompletion(store)
        XCTAssertEqual(store.monthlyBudget?.estimatedCost, 80, "an empty candidate must not erase the last known monthly result")

        clock.now = clock.now.addingTimeInterval(5 * 60 - 1)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.monthlyCallCount, 1, "an empty result must still respect the retry interval")

        clock.now = clock.now.addingTimeInterval(1)
        store.periodicCheckForTesting(now: clock.now)
        waitForMonthlyBudgetCall(runner, count: 2)
        XCTAssertEqual(runner.monthlyCallCount, 2)
    }

    func testMonthlyCatalogGapRetainsSnapshotAndUsesRetryBackoff() throws {
        let clock = try makeStableMiddayClock()
        let providerID = "test.catalog"
        let ambiguousCatalog = ModelCatalogSnapshot(
            providerID: providerID,
            fetchedAt: clock.now,
            entries: [
                makeCatalogEntry(
                    id: "catalog-gap-a",
                    modelName: "catalog-gap-model",
                    providerID: providerID,
                    input: 0.000001,
                    output: 0.000002
                ),
                makeCatalogEntry(
                    id: "catalog-gap-b",
                    modelName: "catalog-gap-model",
                    providerID: providerID,
                    input: 0.000003,
                    output: 0.000004
                )
            ]
        )
        let provider = PendingModelCatalogProvider(snapshot: ambiguousCatalog)
        let modelCatalogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.MonthlyGapCatalog.\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: modelCatalogURL) }
        let pricingDate = clock.now.addingTimeInterval(-60)
        let previousMonthly = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: clock.now),
            generatedAt: clock.now.addingTimeInterval(-60 * 60),
            pricingUpdatedAt: pricingDate,
            customPricingRevision: nil,
            modelCatalogRevision: "old-catalog",
            models: [MonthlyBudgetModel(
                agent: "codex",
                name: "catalog-gap-model",
                tokens: TokenTotals(inputTokens: 10),
                estimatedCost: 80,
                hasKnownPricing: true,
                pricingSource: .remote,
                pricingProviderIDs: [providerID]
            )],
            totalTokens: 10,
            estimatedCost: 80,
            unknownPricingModels: ["catalog-gap-model"],
            realtimeAnchorDay: MonthlyBudgetSnapshot.dayPeriod(for: clock.now),
            realtimeAnchorTodayCost: 8
        )
        let runner = CatalogGapMonthlyRunner(
            usageSnapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 1,
                pricingUpdatedAt: pricingDate
            ),
            pricingDate: pricingDate
        )
        let store = try makeBudgetStore(
            clock: clock,
            runner: runner,
            watcher: StubSourceChangeWatcher(isRunning: true),
            monthlySnapshot: previousMonthly,
            automaticPricingRefresh: false,
            modelCatalogStore: ModelCatalogStore(fileURL: modelCatalogURL),
            baseModelCatalogProviders: [provider]
        )

        store.updatePricingNow()
        waitForModelCatalogStart(provider)
        provider.release()
        waitForPricingCompletion(store)
        waitForMonthlyBudgetCall(runner, count: 1)
        waitForMonthlyBudgetCompletion(store)

        XCTAssertEqual(store.monthlyBudget?.estimatedCost, previousMonthly.estimatedCost)
        XCTAssertTrue(store.monthlyBudget?.pricingBasisPreserved == true)
        XCTAssertEqual(store.monthlyBudget?.unknownPricingModels, previousMonthly.unknownPricingModels)
        XCTAssertFalse(store.monthlyBudget?.usesRealtimeProjection(using: store.snapshot, now: clock.now) == true)

        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.monthlyCallCount, 1, "a catalog gap must enter retry backoff")

        clock.now = clock.now.addingTimeInterval(5 * 60)
        store.periodicCheckForTesting(now: clock.now)
        waitForMonthlyBudgetCall(runner, count: 2)
        waitForMonthlyBudgetCompletion(store)
        XCTAssertEqual(runner.monthlyCallCount, 2)
    }

    func testChangingAnExistingMonthlyLimitDoesNotForceReconciliation() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let runner = MonthlyBudgetStubRunner(
            usageSnapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 2
            ),
            monthlySnapshot: { now in self.makeMonthlyBudgetSnapshot(now: now, cost: 12) }
        )
        let store = try makeBudgetStore(
            clock: clock,
            runner: runner,
            watcher: watcher,
            monthlySnapshot: makeMonthlyBudgetSnapshot(now: clock.now, cost: 12)
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)

        store.setBudgetSettings(dailyCostLimit: 0, monthlyCostLimit: 20, budgetAlertThreshold: 0.8)
        waitForRefreshCompletion(store)
        store.periodicCheckForTesting(now: clock.now)

        XCTAssertEqual(runner.monthlyCallCount, 0, "changing a positive limit does not change monthly usage data")
    }

    func testReenablingMonthlyBudgetRequestsAnImmediateReconciliation() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let runner = MonthlyBudgetStubRunner(
            usageSnapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 2
            ),
            monthlySnapshot: { now in self.makeMonthlyBudgetSnapshot(now: now, cost: 12) }
        )
        let store = try makeBudgetStore(clock: clock, runner: runner, watcher: watcher)

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        waitForMonthlyBudgetCall(runner, count: 1)
        waitForMonthlyBudgetCompletion(store)

        store.setBudgetSettings(dailyCostLimit: 0, monthlyCostLimit: 0, budgetAlertThreshold: 0.8)
        waitForRefreshCompletion(store)
        store.setBudgetSettings(dailyCostLimit: 0, monthlyCostLimit: 10, budgetAlertThreshold: 0.8)
        waitForRefreshCompletion(store)
        store.periodicCheckForTesting(now: clock.now)

        waitForMonthlyBudgetCall(runner, count: 2)
        waitForMonthlyBudgetCompletion(store)
        XCTAssertEqual(runner.monthlyCallCount, 2)
    }

    func testMonthlyBudgetResultIsDiscardedWhenSourceChangesDuringRefresh() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let monthlyStarted = DispatchSemaphore(value: 0)
        let monthlyRelease = DispatchSemaphore(value: 0)
        let runner = MonthlyBudgetStubRunner(
            usageSnapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 2
            ),
            monthlySnapshot: { now in self.makeMonthlyBudgetSnapshot(now: now, cost: 12) },
            monthlyStarted: monthlyStarted,
            monthlyRelease: monthlyRelease
        )
        let store = try makeBudgetStore(
            clock: clock,
            runner: runner,
            watcher: watcher,
            developerMode: true
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        XCTAssertEqual(monthlyStarted.wait(timeout: .now() + 2), .success)

        store.markDirty()
        monthlyRelease.signal()
        waitForMonthlyBudgetCompletion(store)

        XCTAssertNil(store.monthlyBudget, "a monthly result started before a source change must not be published")
        XCTAssertTrue(store.isDirty, "the source change must still require a usage refresh")
        XCTAssertEqual(
            store.developerDiagnostics.monthlyBudgetRefreshFailureCountLast12Hours,
            0,
            "discarded stale monthly work must not be reported as a failed refresh"
        )
        XCTAssertTrue(store.developerDiagnostics.monthlyBudgetRefreshRequested)
    }

    func testPricingUpdateRequestsMonthlyRecalibration() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let runner = MonthlyBudgetStubRunner(
            usageSnapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 2,
                pricingUpdatedAt: clock.now
            ),
            monthlySnapshot: { now in
                self.makeMonthlyBudgetSnapshot(now: now, cost: 12, pricingUpdatedAt: now)
            }
        )
        let initialPricingDate = clock.now.addingTimeInterval(-60)
        let store = try makeBudgetStore(
            clock: clock,
            runner: runner,
            watcher: watcher,
            monthlySnapshot: makeMonthlyBudgetSnapshot(
                now: clock.now,
                cost: 12,
                pricingUpdatedAt: initialPricingDate
            )
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        waitForMonthlyBudgetCall(runner, count: 1)
        waitForMonthlyBudgetCompletion(store)
        XCTAssertEqual(runner.monthlyCallCount, 1)

        // A pricing refresh changes pricingReferenceSnapshot.pricingUpdatedAt.
        // The stored anchor now uses stale pricing and monthly reconciliation
        // must run again instead of reusing the previous calibration.
        store.updatePricingNow()
        let pricingCompleted = Date().addingTimeInterval(2)
        while store.refreshInFlightForTesting
            || store.pricingRefreshInFlightForTesting
            || store.monthlyBudgetRefreshInFlightForTesting, Date() < pricingCompleted {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(store.snapshot.pricingUpdatedAt, "the pricing refresh must publish a pricing timestamp")
        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        waitForMonthlyBudgetCall(runner, count: 2)
        waitForMonthlyBudgetCompletion(store)

        XCTAssertEqual(runner.monthlyCallCount, 2)
        XCTAssertNotEqual(
            store.monthlyBudget?.pricingUpdatedAt,
            initialPricingDate,
            "the recalibrated snapshot must not reuse stale pricing"
        )
    }

    func testMonthlyBudgetAnchorExpiresAfterCalendarDayRollover() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let originalScope = CCUsageRunner.queryScope(for: 30, now: clock.now)
        let runner = MonthlyBudgetStubRunner(
            usageSnapshot: makeScopedSnapshot(scope: originalScope, cost: 2),
            monthlySnapshot: { now in self.makeMonthlyBudgetSnapshot(now: now, cost: 12) }
        )
        let store = try makeBudgetStore(
            clock: clock,
            runner: runner,
            watcher: watcher,
            monthlySnapshot: makeMonthlyBudgetSnapshot(now: clock.now, cost: 12)
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        XCTAssertEqual(runner.monthlyCallCount, 0, "a same-day anchor must not trigger another monthly scan")

        clock.now = clock.now.addingTimeInterval(86_400)
        let rolloverScope = CCUsageRunner.queryScope(for: 30, now: clock.now)
        let rolloverRunner = MonthlyBudgetStubRunner(
            usageSnapshot: makeScopedSnapshot(scope: rolloverScope, cost: 2),
            monthlySnapshot: { now in self.makeMonthlyBudgetSnapshot(now: now, cost: 12) }
        )
        store.setRunnerForTesting(rolloverRunner)
        store.periodicCheckForTesting(now: clock.now)
        waitForRefreshCompletion(store)
        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        waitForMonthlyBudgetCall(rolloverRunner, count: 1)
        waitForMonthlyBudgetCompletion(store)

        XCTAssertEqual(rolloverRunner.monthlyCallCount, 1, "a new calendar day must recalibrate the realtime anchor")
        XCTAssertEqual(
            store.monthlyBudget?.realtimeAnchorDay,
            MonthlyBudgetSnapshot.dayPeriod(for: clock.now),
            "the new anchor must match the new day"
        )
    }

    func testMonthlyBudgetEventuallyRunsDuringAContinuousDirtyStorm() throws {
        let clock = try makeStableMiddayClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let usageStarted = DispatchSemaphore(value: 0)
        let usageRelease = DispatchSemaphore(value: 0)
        let monthlyStarted = DispatchSemaphore(value: 0)
        let monthlyRelease = DispatchSemaphore(value: 0)
        let runner = MonthlyBudgetStubRunner(
            usageSnapshot: makeScopedSnapshot(
                scope: CCUsageRunner.queryScope(for: 30, now: clock.now),
                cost: 2
            ),
            monthlySnapshot: { now in self.makeMonthlyBudgetSnapshot(now: now, cost: 12) },
            monthlyStarted: monthlyStarted,
            monthlyRelease: monthlyRelease,
            usageStarted: usageStarted,
            usageRelease: usageRelease
        )
        let store = try makeBudgetStore(clock: clock, runner: runner, watcher: watcher)

        // Complete the launch usage and first monthly calibration.
        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(usageStarted.wait(timeout: .now() + 2), .success)
        usageRelease.signal()
        waitForRefreshCompletion(store)
        XCTAssertEqual(monthlyStarted.wait(timeout: .now() + 2), .success)
        monthlyRelease.signal()
        waitForMonthlyBudgetCompletion(store)

        // Use a longer usage interval so the bounded monthly wait can expire
        // without launching another usage scan at the same instant.
        store.setRefreshInterval(900)
        clock.now = clock.now.addingTimeInterval(60 * 60)
        store.markDirty()
        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(usageStarted.wait(timeout: .now() + 2), .success)
        // Keep the generation dirty when this usage attempt completes.
        store.markDirty()
        usageRelease.signal()
        waitForRefreshCompletion(store)
        XCTAssertTrue(store.isDirty)

        // The source never settles, but the monthly scan must still start
        // after its bounded dirty wait rather than starving indefinitely.
        clock.now = clock.now.addingTimeInterval(5 * 60)
        store.markDirty()
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(monthlyStarted.wait(timeout: .now() + 2), .success)
        store.markDirty()
        monthlyRelease.signal()
        waitForMonthlyBudgetCompletion(store)

        XCTAssertEqual(runner.monthlyCallCount, 2)
        XCTAssertEqual(store.monthlyBudget?.estimatedCost, 12)
        XCTAssertTrue(store.isDirty, "accepting a point-in-time monthly scan must not clear the pending usage generation")
    }

    func testManualRefreshBypassesRefreshInterval() throws {
        let clock = TestClock()
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let store = try makeStore(clock: clock, interval: 900, watchers: [watcher])

        store.refreshNow()
        XCTAssertTrue(store.refreshInFlightForTesting, "refreshNow must bypass the interval")
    }

    func testLookbackChangeCannotPublishAnOlderInFlightScope() throws {
        let clock = TestClock()
        let oldScope = CCUsageRunner.queryScope(for: 30, now: clock.now)
        let newScope = CCUsageRunner.queryScope(for: 1, now: clock.now)
        let oldSnapshot = makeScopedSnapshot(scope: oldScope, cost: 30)
        let newSnapshot = makeScopedSnapshot(scope: newScope, cost: 1)
        let runner = ScopeRaceRunner(first: oldSnapshot, second: newSnapshot)

        let suiteName = "Meterlark.RuntimeSchedulingTests.ScopeRace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.ScopeRace.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: snapshotDirectory) }
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.ScopeRaceSource.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sourceRoot) }
        let watcher = StubSourceChangeWatcher(isRunning: true)

        let store = MonitorStore(
            snapshotStore: SnapshotStore(baseURL: snapshotDirectory),
            settingsStore: SettingsStore(defaults: defaults),
            runner: runner,
            sourceRootsProvider: { [sourceRoot] },
            watcherFactory: { _, _ in watcher },
            nowProvider: { clock.now },
            fingerprintReader: { [] }
        )

        store.refreshNow()
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 1), .success)
        store.setLookbackDays(1)
        runner.releaseFirst()

        let deadline = Date().addingTimeInterval(2)
        while store.snapshot.queryScope != newScope, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(store.snapshot.queryScope, newScope)
        XCTAssertEqual(runner.callCount, 2)
    }

    func testScopeRolloverDuringUsageRefreshQueuesAReplacement() throws {
        let clock = TestClock()
        let oldScope = CCUsageRunner.queryScope(for: 1, now: clock.now)
        let nextDay = clock.now.addingTimeInterval(86_400)
        let newScope = CCUsageRunner.queryScope(for: 1, now: nextDay)
        XCTAssertNotEqual(oldScope, newScope)

        let runner = ScopeRaceRunner(
            first: makeScopedSnapshot(scope: oldScope, cost: 30),
            second: makeScopedSnapshot(scope: newScope, cost: 1)
        )
        let suiteName = "Meterlark.RuntimeSchedulingTests.ScopeRollover.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1, forKey: "Meterlark.lookbackDays")
        defaults.set(900.0, forKey: "Meterlark.refreshInterval")
        defaults.set(false, forKey: "Meterlark.automaticPricingRefresh")

        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.ScopeRollover.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: snapshotDirectory) }
        try SnapshotStore(baseURL: snapshotDirectory).save(makeScopedSnapshot(scope: oldScope, cost: 30))

        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.ScopeRolloverSource.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sourceRoot) }
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let store = MonitorStore(
            snapshotStore: SnapshotStore(baseURL: snapshotDirectory),
            settingsStore: SettingsStore(defaults: defaults),
            runner: runner,
            sourceRootsProvider: { [sourceRoot] },
            watcherFactory: { _, _ in watcher },
            nowProvider: { clock.now },
            fingerprintReader: { [] }
        )

        clock.now = clock.now.addingTimeInterval(2)
        store.periodicCheckForTesting(now: clock.now)
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 1), .success)

        clock.now = nextDay.addingTimeInterval(2)
        runner.releaseFirst()

        let deadline = Date().addingTimeInterval(2)
        while runner.callCount < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(runner.callCount, 2, "scope rollover must retain an explicit replacement request")
        waitForRefreshCompletion(store)
        XCTAssertEqual(store.snapshot.queryScope, newScope)
        XCTAssertFalse(store.isDirty)
    }

    func testScopeRolloverDuringPricingDoesNotPublishAnOlderCandidate() throws {
        let clock = TestClock()
        let oldScope = CCUsageRunner.queryScope(for: 1, now: clock.now)
        let nextDay = clock.now.addingTimeInterval(86_400)
        let newScope = CCUsageRunner.queryScope(for: 1, now: nextDay)
        XCTAssertNotEqual(oldScope, newScope)

        let runner = ScopeRaceRunner(
            first: makeScopedSnapshot(scope: oldScope, cost: 30),
            second: makeScopedSnapshot(scope: newScope, cost: 1)
        )
        let suiteName = "Meterlark.RuntimeSchedulingTests.PricingScopeRollover.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(1, forKey: "Meterlark.lookbackDays")
        defaults.set(900.0, forKey: "Meterlark.refreshInterval")
        defaults.set(false, forKey: "Meterlark.automaticPricingRefresh")

        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.PricingScopeRollover.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: snapshotDirectory) }
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.PricingScopeRolloverSource.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sourceRoot) }
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let store = MonitorStore(
            snapshotStore: SnapshotStore(baseURL: snapshotDirectory),
            settingsStore: SettingsStore(defaults: defaults),
            runner: runner,
            sourceRootsProvider: { [sourceRoot] },
            watcherFactory: { _, _ in watcher },
            nowProvider: { clock.now },
            fingerprintReader: { [] }
        )

        store.updatePricingNow()
        XCTAssertEqual(runner.firstStarted.wait(timeout: .now() + 2), .success)

        clock.now = nextDay.addingTimeInterval(2)
        runner.releaseFirst()
        let deadline = Date().addingTimeInterval(2)
        while store.snapshot.queryScope != newScope, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(runner.callCount, 2, "pricing scope rollover must queue a replacement")
        XCTAssertEqual(store.snapshot.queryScope, newScope)
        XCTAssertEqual(store.snapshot.estimatedCost, 1)
    }

    func testLegacySnapshotWithoutScopeIsNotPresentedAsCurrent() throws {
        let clock = TestClock()
        let suiteName = "Meterlark.RuntimeSchedulingTests.LegacyScope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.LegacyScope.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: snapshotDirectory) }
        let legacyStore = SnapshotStore(baseURL: snapshotDirectory)
        let tokens = TokenTotals(inputTokens: 10)
        let legacy = UsageSnapshot(
            schemaVersion: 3,
            generatedAt: Date(),
            pricingUpdatedAt: Date(),
            days: [DailyUsage(period: "2026-08-17", tokens: tokens, estimatedCost: 1)],
            agents: [],
            models: [ModelUsage(agent: "codex", name: "legacy", tokens: tokens, estimatedCost: 1, hasKnownPricing: true)],
            totalTokens: tokens,
            estimatedCost: 1,
            unknownPricingModels: []
        )
        try legacyStore.save(legacy)
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.LegacyScopeSource.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sourceRoot) }
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let runner = StubRunner(settings: MonitorSettings.default, snapshot: .empty)

        let store = MonitorStore(
            snapshotStore: legacyStore,
            settingsStore: SettingsStore(defaults: defaults),
            runner: runner,
            sourceRootsProvider: { [sourceRoot] },
            watcherFactory: { _, _ in watcher },
            nowProvider: { clock.now },
            fingerprintReader: { [] }
        )

        XCTAssertFalse(store.snapshot.hasData)
    }

    func testCustomPricingRemoveAndReimportFencesAnInFlightRefresh() throws {
        let clock = TestClock()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.PricingLifecycle.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let pathA = root.appendingPathComponent("pricing-a.json")
        let pathB = root.appendingPathComponent("pricing-b.json")
        let tableA = CustomPricingTable(entries: [
            "model": CustomModelPricing(inputCostPerToken: 0.000001, outputCostPerToken: 0.000002, cacheCreationInputTokenCost: nil, cacheReadInputTokenCost: nil)
        ])
        let tableB = CustomPricingTable(entries: [
            "model": CustomModelPricing(inputCostPerToken: 0, outputCostPerToken: 0, cacheCreationInputTokenCost: nil, cacheReadInputTokenCost: nil)
        ])
        try tableA.write(to: pathA)
        try tableB.write(to: pathB)

        let scope = CCUsageRunner.queryScope(for: 30, now: clock.now)
        let runner = ScopeRaceRunner(
            first: makeScopedSnapshot(scope: scope, cost: 1),
            second: makeScopedSnapshot(scope: scope, cost: 2)
        )
        let watcher = StubSourceChangeWatcher(isRunning: true)
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [watcher],
            runner: runner,
            customPricingPath: pathA.path,
            generatedPricingDirectory: root
        )

        clock.now = clock.now.addingTimeInterval(3)
        store.updatePricingNow()
        XCTAssertEqual(
            runner.firstStarted.wait(timeout: .now() + 2),
            .success,
            "phase=\(store.phase), callCount=\(runner.callCount)"
        )

        store.removeCustomPricing()
        XCTAssertFalse(store.hasCustomPricing)
        XCTAssertEqual(store.settings.customPricingPath, "")
        XCTAssertTrue(
            pricingArtifacts(in: root).isEmpty,
            "removing custom pricing must synchronously remove managed and staged ccusage configs"
        )

        // This is the next import while the old usage worker is still in
        // flight. The real import path writes the table and sets this path;
        // updatePricingNow then performs the normal disk reconciliation.
        store.settings.customPricingPath = pathB.path
        store.updatePricingNow()
        runner.releaseFirst()

        let deadline = Date().addingTimeInterval(2)
        while runner.callCount < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        waitForRefreshCompletion(store)

        XCTAssertEqual(store.snapshot.customPricingRevision, tableB.revision)
        XCTAssertEqual(store.settings.customPricingPath, pathB.path)
        XCTAssertFalse(store.pricingIsStale(relativeTo: clock.now))
        XCTAssertEqual(pricingArtifacts(in: root).count, 1)
    }

    func testSamePricingContentDoesNotBecomeStaleWhenPathChangesButChangedContentDoes() throws {
        let clock = TestClock()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.PricingRevision.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let pathA = root.appendingPathComponent("pricing-a.json")
        let pathB = root.appendingPathComponent("pricing-b.json")
        let tableA = CustomPricingTable(entries: [
            "model": CustomModelPricing(inputCostPerToken: 0.000001, outputCostPerToken: 0.000002, cacheCreationInputTokenCost: nil, cacheReadInputTokenCost: nil)
        ])
        let tableChanged = CustomPricingTable(entries: [
            "model": CustomModelPricing(inputCostPerToken: 0.000003, outputCostPerToken: 0.000004, cacheCreationInputTokenCost: nil, cacheReadInputTokenCost: nil)
        ])
        try tableA.write(to: pathA)
        try tableA.write(to: pathB)

        let scope = CCUsageRunner.queryScope(for: 30, now: clock.now)
        let snapshot = makeScopedSnapshot(
            scope: scope,
            cost: 1,
            pricingUpdatedAt: clock.now,
            customPricingRevision: tableA.revision
        )
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [StubSourceChangeWatcher(isRunning: true)],
            customPricingPath: pathA.path,
            initialSnapshot: snapshot
        )

        store.settings.customPricingPath = pathB.path
        XCTAssertFalse(store.pricingIsStale(relativeTo: clock.now), "same canonical content must not become stale after a path change")

        try tableChanged.write(to: pathB)
        XCTAssertTrue(store.pricingIsStale(relativeTo: clock.now), "changed canonical content must trigger repricing")
    }

    func testCatalogRefreshKeepsLoadingProjectionUntilAllProvidersFinish() throws {
        let clock = try makeStableMiddayClock()
        let firstProvider = PendingModelCatalogProvider(
            snapshot: makeCatalogSnapshot(at: clock.now, providerID: "test.catalog.first")
        )
        let secondProvider = PendingModelCatalogProvider(
            snapshot: makeCatalogSnapshot(at: clock.now, providerID: "test.catalog.second")
        )
        let modelCatalogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.LoadingCatalog.\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: modelCatalogURL) }

        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [StubSourceChangeWatcher(isRunning: true)],
            automaticPricingRefresh: true,
            modelCatalogStore: ModelCatalogStore(fileURL: modelCatalogURL),
            baseModelCatalogProviders: [firstProvider, secondProvider]
        )

        waitForModelCatalogFetch(firstProvider, count: 1)
        XCTAssertEqual(store.modelCatalogStatus.phase, .loading)

        firstProvider.release()
        waitForModelCatalogFetch(secondProvider, count: 1)
        XCTAssertEqual(store.modelCatalogStatus.phase, .loading)

        secondProvider.release()
        let deadline = Date().addingTimeInterval(2)
        while store.modelCatalogStatus.phase != .ready, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(store.modelCatalogStatus.phase, .ready)
    }

    func testNewActiveCatalogProviderIsFetchedEvenWhenAnotherProviderRecentlySucceeded() throws {
        let clock = try makeStableMiddayClock()
        let modelCatalogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.NewProviderCatalog.\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: modelCatalogURL) }

        let existingProviderID = "test.catalog.existing"
        var persistedCatalog = ModelCatalogStore(fileURL: modelCatalogURL)
        let existingSnapshot = makeCatalogSnapshot(at: clock.now, providerID: existingProviderID)
        XCTAssertEqual(try persistedCatalog.applySuccess(existingSnapshot, at: clock.now), [])
        try persistedCatalog.save()

        let existingProvider = PendingModelCatalogProvider(snapshot: existingSnapshot)
        let newProvider = PendingModelCatalogProvider(
            snapshot: makeCatalogSnapshot(at: clock.now, providerID: "test.catalog.new")
        )
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [StubSourceChangeWatcher(isRunning: true)],
            automaticPricingRefresh: true,
            modelCatalogStore: ModelCatalogStore(fileURL: modelCatalogURL),
            baseModelCatalogProviders: [existingProvider, newProvider]
        )

        waitForModelCatalogFetch(existingProvider, count: 1)
        waitForModelCatalogFetch(newProvider, count: 1)
        existingProvider.release()
        newProvider.release()

        let deadline = Date().addingTimeInterval(2)
        while store.modelCatalogStatus.phase != .ready, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(store.modelCatalogStatus.phase, .ready)
    }

    func testCatalogRefreshSaveFailureDoesNotPublishPartialBatch() throws {
        let clock = try makeStableMiddayClock()
        let provider = PendingModelCatalogProvider(
            snapshot: makeCatalogSnapshot(at: clock.now, providerID: "test.catalog")
        )
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.CatalogSaveBlocker.\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: blocker)
        let modelCatalogURL = blocker.appendingPathComponent("ModelCatalog.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: blocker) }

        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [StubSourceChangeWatcher(isRunning: true)],
            automaticPricingRefresh: true,
            modelCatalogStore: ModelCatalogStore(fileURL: modelCatalogURL),
            baseModelCatalogProviders: [provider]
        )

        waitForModelCatalogStart(provider)
        provider.release()

        let deadline = Date().addingTimeInterval(2)
        while store.modelCatalogStatus.phase != .failed, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(store.modelCatalogStatus.phase, .failed)
        XCTAssertNotNil(store.modelCatalogStatus.lastError)
        XCTAssertTrue(store.modelCatalogEntries.isEmpty)
        XCTAssertNil(ModelCatalogStore(fileURL: modelCatalogURL).revision)
    }

    func testCatalogProviderGenerationChangeAbandonsOldFetchBeforeStartingReplacement() throws {
        let clock = try makeStableMiddayClock()
        let firstProvider = PendingModelCatalogProvider(
            snapshot: makeCatalogSnapshot(
                at: clock.now,
                providerID: "test.catalog",
                modelName: "old-catalog-model"
            )
        )
        let replacementProvider = PendingModelCatalogProvider(
            snapshot: makeCatalogSnapshot(
                at: clock.now,
                providerID: "test.catalog",
                modelName: "replacement-catalog-model"
            )
        )
        let modelCatalogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.GenerationCatalog.\(UUID().uuidString).json")
        addTeardownBlock {
            firstProvider.release()
            replacementProvider.release()
            try? FileManager.default.removeItem(at: modelCatalogURL)
        }

        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [StubSourceChangeWatcher(isRunning: true)],
            automaticPricingRefresh: true,
            modelCatalogStore: ModelCatalogStore(fileURL: modelCatalogURL),
            baseModelCatalogProviders: [firstProvider],
            // Far longer than every wait below: the replacement must start
            // because the host abandons the cancelled fetch, not because the
            // per-provider deadline expired. A short deadline would also race
            // the replacement fetch itself on slow CI runners.
            modelCatalogProviderTimeout: 30
        )

        waitForModelCatalogFetch(firstProvider, count: 1)
        store.replaceModelCatalogProvidersForTesting([replacementProvider])
        let replacementDeadline = Date().addingTimeInterval(5)
        while replacementProvider.fetchCountForTesting < 1, Date() < replacementDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(
            replacementProvider.fetchCountForTesting,
            1,
            "the replacement should start without waiting for the old provider, which ignores cancellation"
        )

        replacementProvider.release()

        let deadline = Date().addingTimeInterval(2)
        while (
            store.modelCatalogStatus.phase != .ready
                || store.modelCatalogEntries.map(\.modelName) != ["replacement-catalog-model"]
        ), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(store.modelCatalogStatus.phase, .ready)
        XCTAssertEqual(store.modelCatalogEntries.map(\.modelName), ["replacement-catalog-model"])
        XCTAssertEqual(
            ModelCatalogStore(fileURL: modelCatalogURL).entries.map(\.modelName),
            ["replacement-catalog-model"],
            "the replacement generation must be the only persisted catalog"
        )

        // The first provider deliberately ignores cancellation. Its late result
        // must not overwrite the replacement that has already been committed.
        firstProvider.release()
        let lateResultDeadline = Date().addingTimeInterval(0.25)
        while Date() < lateResultDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(store.modelCatalogEntries.map(\.modelName), ["replacement-catalog-model"])
        XCTAssertEqual(
            ModelCatalogStore(fileURL: modelCatalogURL).entries.map(\.modelName),
            ["replacement-catalog-model"],
            "a late result from the invalidated generation must not overwrite disk"
        )
        XCTAssertEqual(replacementProvider.fetchCountForTesting, 1)
    }

    func testPricingQueuedDuringCatalogRefreshRunsAfterCatalogPublishes() throws {
        let clock = try makeStableMiddayClock()
        let catalogEntry = ModelCatalogEntry(
            id: "catalog-model",
            modelName: "catalog-model",
            pricing: CustomModelPricing(
                inputCostPerToken: 0.000001,
                outputCostPerToken: 0.000002,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            ),
            metadata: ModelCatalogMetadata(
                modelInfo: ["id": .string("catalog-model")],
                litellmParams: [:]
            ),
            source: .remote,
            providerID: "test.catalog",
            recordIdentity: "catalog-model",
            enabled: true,
            pricingSchedule: CanonicalModelPricing(
                modelName: "catalog-model",
                base: PricingRates(
                    input: 0.000001,
                    output: 0.000002,
                    cacheCreation: nil,
                    cacheRead: nil
                ),
                tiers: [],
                maxInputTokens: nil,
                fastMultiplier: nil
            )
        )
        let catalog = ModelCatalogSnapshot(
            providerID: "test.catalog",
            fetchedAt: clock.now,
            entries: [catalogEntry]
        )
        let provider = PendingModelCatalogProvider(snapshot: catalog)
        let scope = CCUsageRunner.queryScope(for: 30, now: clock.now)
        var expectedCatalogStore = ModelCatalogStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.ExpectedCatalog.\(UUID().uuidString).json"))
        _ = try expectedCatalogStore.applySuccess(catalog, at: clock.now)
        let activeCatalogRevision = try XCTUnwrap(
            expectedCatalogStore.revision(for: Set([catalog.providerID]))
        )
        let runner = CatalogPendingRunner(
            snapshot: makeScopedSnapshot(
                scope: scope,
                cost: 1,
                pricingUpdatedAt: clock.now,
                modelCatalogRevision: activeCatalogRevision
            )
        )
        let modelCatalogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.ModelCatalog.\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: modelCatalogURL) }
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [StubSourceChangeWatcher(isRunning: true)],
            runner: runner,
            automaticPricingRefresh: true,
            modelCatalogStore: ModelCatalogStore(fileURL: modelCatalogURL),
            baseModelCatalogProviders: [provider]
        )

        waitForModelCatalogStart(provider)
        store.updatePricingNow()
        XCTAssertTrue(runner.modesForTesting.isEmpty, "pricing must wait for the catalog fetch")

        provider.release()
        waitForRunnerModes(runner, count: 1)

        XCTAssertEqual(runner.modesForTesting, [.onlinePricing])
        XCTAssertEqual(store.snapshot.modelCatalogRevision, activeCatalogRevision)
    }

    func testPricingRunsWhenCatalogRevisionIsUnchangedButSnapshotIsStale() throws {
        let clock = try makeStableMiddayClock()
        let catalog = makeCatalogSnapshot(at: clock.now)
        let modelCatalogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.UnchangedCatalog.\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: modelCatalogURL) }

        var seededCatalogStore = ModelCatalogStore(fileURL: modelCatalogURL)
        _ = try seededCatalogStore.applySuccess(catalog, at: clock.now)
        try seededCatalogStore.save()
        let activeCatalogRevision = try XCTUnwrap(
            seededCatalogStore.revision(for: Set([catalog.providerID]))
        )

        let scope = CCUsageRunner.queryScope(for: 30, now: clock.now)
        let initialSnapshot = makeScopedSnapshot(
            scope: scope,
            cost: 99,
            pricingUpdatedAt: clock.now.addingTimeInterval(-86_400),
            modelCatalogRevision: "old-catalog-revision"
        )
        let runner = CatalogPendingRunner(
            snapshot: makeScopedSnapshot(
                scope: scope,
                cost: 1,
                pricingUpdatedAt: clock.now,
                modelCatalogRevision: activeCatalogRevision
            )
        )
        let provider = PendingModelCatalogProvider(snapshot: catalog)
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [StubSourceChangeWatcher(isRunning: true)],
            runner: runner,
            initialSnapshot: initialSnapshot,
            automaticPricingRefresh: false,
            modelCatalogStore: ModelCatalogStore(fileURL: modelCatalogURL),
            baseModelCatalogProviders: [provider]
        )

        store.updatePricingNow()
        waitForModelCatalogStart(provider)
        XCTAssertTrue(store.pricingIsStale(relativeTo: clock.now))
        XCTAssertFalse(
            store.pricingStatusIsStale(relativeTo: clock.now),
            "the stale snapshot should not show a warning while catalog refresh and repricing are pending"
        )

        provider.release()
        waitForRunnerModes(runner, count: 1)
        waitForPricingCompletion(store)

        XCTAssertEqual(runner.modesForTesting, [.onlinePricing])
        XCTAssertEqual(store.snapshot.modelCatalogRevision, activeCatalogRevision)
        XCTAssertFalse(store.pricingIsStale(relativeTo: clock.now))
        XCTAssertFalse(store.pricingStatusIsStale(relativeTo: clock.now))
    }

    func testRejectedCatalogPricingAttemptDoesNotLoopButManualUpdateRemainsForced() throws {
        let clock = try makeStableMiddayClock()
        let catalog = makeCatalogSnapshot(at: clock.now)
        let modelCatalogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.RejectedCatalog.\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: modelCatalogURL) }

        var expectedCatalogStore = ModelCatalogStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.ExpectedRejectedCatalog.\(UUID().uuidString).json"))
        _ = try expectedCatalogStore.applySuccess(catalog, at: clock.now)
        let activeCatalogRevision = try XCTUnwrap(
            expectedCatalogStore.revision(for: Set([catalog.providerID]))
        )
        let scope = CCUsageRunner.queryScope(for: 30, now: clock.now)
        let initialSnapshot = makeScopedSnapshot(
            scope: scope,
            cost: 99,
            pricingUpdatedAt: clock.now,
            modelCatalogRevision: "old-catalog-revision",
            tokens: TokenTotals(inputTokens: 20)
        )
        let runner = CatalogPendingRunner(
            snapshot: makeScopedSnapshot(
                scope: scope,
                cost: 1,
                pricingUpdatedAt: clock.now,
                modelCatalogRevision: activeCatalogRevision
            )
        )
        let provider = PendingModelCatalogProvider(snapshot: catalog)
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [StubSourceChangeWatcher(isRunning: true)],
            runner: runner,
            initialSnapshot: initialSnapshot,
            automaticPricingRefresh: true,
            modelCatalogStore: ModelCatalogStore(fileURL: modelCatalogURL),
            baseModelCatalogProviders: [provider]
        )

        waitForModelCatalogFetch(provider, count: 1)
        provider.release()
        waitForRunnerModes(runner, count: 1)
        waitForPricingCompletion(store)

        XCTAssertEqual(runner.modesForTesting, [.onlinePricing])
        XCTAssertEqual(store.snapshot.modelCatalogRevision, "old-catalog-revision")

        store.updatePricingNow()
        waitForModelCatalogFetch(provider, count: 2)
        provider.release()
        waitForRunnerModes(runner, count: 2)
        waitForPricingCompletion(store)

        XCTAssertEqual(runner.modesForTesting, [.onlinePricing, .onlinePricing])
        XCTAssertEqual(store.snapshot.modelCatalogRevision, "old-catalog-revision")
    }

    func testManualUsageRefreshQueuesPricingWhenAutomaticPricingIsDisabled() throws {
        let clock = try makeStableMiddayClock()
        let scope = CCUsageRunner.queryScope(for: 30, now: clock.now)
        let initialSnapshot = makeScopedSnapshot(
            scope: scope,
            cost: 99,
            pricingUpdatedAt: clock.now.addingTimeInterval(-86_400)
        )
        let runner = CatalogPendingRunner(
            snapshot: makeScopedSnapshot(
                scope: scope,
                cost: 1,
                pricingUpdatedAt: clock.now
            )
        )
        let store = try makeStore(
            clock: clock,
            interval: 60,
            watchers: [StubSourceChangeWatcher(isRunning: true)],
            runner: runner,
            initialSnapshot: initialSnapshot,
            automaticPricingRefresh: false
        )

        XCTAssertTrue(store.pricingIsStale(relativeTo: clock.now))
        XCTAssertTrue(store.pricingStatusIsStale(relativeTo: clock.now))
        store.refreshNow()
        XCTAssertFalse(
            store.pricingStatusIsStale(relativeTo: clock.now),
            "a manually requested pricing repair should suppress the stale warning while queued"
        )
        waitForRunnerModes(runner, count: 2)
        waitForRefreshCompletion(store)
        waitForPricingCompletion(store)

        XCTAssertEqual(runner.modesForTesting, [.usage, .onlinePricing])
        XCTAssertFalse(store.pricingIsStale(relativeTo: clock.now))
    }

    private func makeStore(
        clock: TestClock,
        interval: TimeInterval,
        watchers: [StubSourceChangeWatcher],
        fingerprintError: TestFingerprintError? = nil,
        developerMode: Bool = false,
        verificationMode: SourceVerificationMode = .eventDriven,
        fingerprintCheckInterval: TimeInterval? = nil,
        fingerprintReader: (@Sendable () throws -> [SourceFingerprint])? = nil,
        runner: CCUsageRunnerProtocol? = nil,
        customPricingPath: String = "",
        generatedPricingDirectory: URL? = nil,
        initialSnapshot: UsageSnapshot? = nil,
        automaticPricingRefresh: Bool = false,
        modelCatalogStore: ModelCatalogStore? = nil,
        baseModelCatalogProviders: [any ModelCatalogPluginProvider] = [],
        modelCatalogProviderTimeout: TimeInterval = ModelCatalogFetchBatch.defaultProviderTimeout
    ) throws -> MonitorStore {
        let suiteName = "Meterlark.RuntimeSchedulingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(interval, forKey: "Meterlark.refreshInterval")
        // Keep automatic pricing off by default so usage/fallback scheduling
        // tests do not start an independent pricing refresh.
        defaults.set(automaticPricingRefresh, forKey: "Meterlark.automaticPricingRefresh")
        defaults.set(developerMode, forKey: "Meterlark.developerMode")
        defaults.set(verificationMode.rawValue, forKey: "Meterlark.sourceVerificationMode")
        defaults.set(customPricingPath, forKey: "Meterlark.customPricingPath")
        if let fingerprintCheckInterval {
            defaults.set(fingerprintCheckInterval, forKey: "Meterlark.fingerprintCheckInterval")
        }

        let settings = SettingsStore(defaults: defaults).load()
        let usageRunner = runner ?? StubRunner(settings: settings, snapshot: .empty)
        var watcherIndex = 0
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sourceRoot) }

        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.Snapshot.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: snapshotDirectory) }
        if let initialSnapshot {
            try SnapshotStore(baseURL: snapshotDirectory).save(initialSnapshot)
        }

        let pricingDirectory: URL
        if let generatedPricingDirectory {
            pricingDirectory = generatedPricingDirectory
        } else {
            pricingDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Meterlark.RuntimeSchedulingTests.Pricing.\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: pricingDirectory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: pricingDirectory) }
        }

        return MonitorStore(
            snapshotStore: SnapshotStore(baseURL: snapshotDirectory),
            settingsStore: SettingsStore(defaults: defaults),
            runner: usageRunner,
            sourceRootsProvider: { [sourceRoot] },
            watcherFactory: { _, handler in
                let watcher: StubSourceChangeWatcher
                if watcherIndex < watchers.count {
                    watcher = watchers[watcherIndex]
                    watcherIndex += 1
                } else {
                    watcher = StubSourceChangeWatcher()
                }
                watcher.handler = handler
                return watcher
            },
            nowProvider: { clock.now },
            fingerprintReader: fingerprintReader ?? {
                if let fingerprintError { throw fingerprintError }
                return []
            },
            generatedPricingDirectory: pricingDirectory,
            modelCatalogStore: modelCatalogStore ?? ModelCatalogStore(
                fileURL: snapshotDirectory.appendingPathComponent("ModelCatalog.json")
            ),
            baseModelCatalogProviders: baseModelCatalogProviders,
            modelCatalogProviderTimeout: modelCatalogProviderTimeout
        )
    }

    private func makeStableMiddayClock() throws -> TestClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 12))
        )
        return TestClock(now: date)
    }

    private func makeCatalogSnapshot(at date: Date) -> ModelCatalogSnapshot {
        makeCatalogSnapshot(at: date, providerID: "test.catalog")
    }

    private func makeCatalogSnapshot(
        at date: Date,
        providerID: String,
        modelName: String = "catalog-model"
    ) -> ModelCatalogSnapshot {
        let entry = makeCatalogEntry(
            id: modelName,
            modelName: modelName,
            providerID: providerID,
            input: 0.000001,
            output: 0.000002
        )
        return ModelCatalogSnapshot(
            providerID: providerID,
            fetchedAt: date,
            entries: [entry]
        )
    }

    private func makeCatalogEntry(
        id: String,
        modelName: String,
        providerID: String,
        input: Double?,
        output: Double?
    ) -> ModelCatalogEntry {
        ModelCatalogEntry(
            id: id,
            modelName: modelName,
            pricing: CustomModelPricing(
                inputCostPerToken: input,
                outputCostPerToken: output,
                cacheCreationInputTokenCost: nil,
                cacheReadInputTokenCost: nil
            ),
            metadata: ModelCatalogMetadata(
                modelInfo: ["id": .string(id)],
                litellmParams: [:]
            ),
            source: .remote,
            providerID: providerID,
            recordIdentity: id,
            enabled: true,
            pricingSchedule: CanonicalModelPricing(
                modelName: modelName,
                base: PricingRates(
                    input: input,
                    output: output,
                    cacheCreation: nil,
                    cacheRead: nil
                ),
                tiers: [],
                maxInputTokens: nil,
                fastMultiplier: nil
            )
        )
    }

    private func pricingArtifacts(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasPrefix("ccusage-pricing-") } ?? []
    }

    private func makeBudgetStore(
        clock: TestClock,
        runner: CCUsageRunnerProtocol,
        watcher: StubSourceChangeWatcher,
        monthlySnapshot: MonthlyBudgetSnapshot? = nil,
        fingerprintReader: (@Sendable () throws -> [SourceFingerprint])? = nil,
        developerMode: Bool = false,
        automaticPricingRefresh: Bool = false,
        modelCatalogStore: ModelCatalogStore? = nil,
        baseModelCatalogProviders: [any ModelCatalogPluginProvider] = []
    ) throws -> MonitorStore {
        let suiteName = "Meterlark.RuntimeSchedulingTests.MonthlyBudget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(60.0, forKey: "Meterlark.refreshInterval")
        defaults.set(10.0, forKey: "Meterlark.monthlyCostLimit")
        defaults.set(automaticPricingRefresh, forKey: "Meterlark.automaticPricingRefresh")
        defaults.set(developerMode, forKey: "Meterlark.developerMode")

        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.MonthlyBudget.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: snapshotDirectory) }

        if let monthlySnapshot {
            try BudgetSnapshotStore(baseURL: snapshotDirectory).save(monthlySnapshot)
        }

        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.RuntimeSchedulingTests.MonthlyBudgetSource.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sourceRoot) }

        return MonitorStore(
            snapshotStore: SnapshotStore(baseURL: snapshotDirectory),
            budgetSnapshotStore: BudgetSnapshotStore(baseURL: snapshotDirectory),
            settingsStore: SettingsStore(defaults: defaults),
            runner: runner,
            sourceRootsProvider: { [sourceRoot] },
            watcherFactory: { _, handler in
                watcher.handler = handler
                return watcher
            },
            nowProvider: { clock.now },
            fingerprintReader: fingerprintReader ?? { [] },
            modelCatalogStore: modelCatalogStore ?? ModelCatalogStore(
                fileURL: snapshotDirectory.appendingPathComponent("ModelCatalog.json")
            ),
            baseModelCatalogProviders: baseModelCatalogProviders
        )
    }

    private func waitForFallbackCompletion(_ store: MonitorStore) {
        let deadline = Date().addingTimeInterval(2)
        while store.fallbackCheckInFlightForTesting, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(store.fallbackCheckInFlightForTesting)
    }

    private func waitForFallbackScanCount(_ store: MonitorStore, count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while store.fallbackScanCountForTesting < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(store.fallbackScanCountForTesting, count)
    }

    private func waitForWatcherEvent(_ store: MonitorStore, count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while store.watcherEventCountForTesting < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(store.watcherEventCountForTesting, count)
    }

    private func waitForRefreshCompletion(_ store: MonitorStore) {
        let deadline = Date().addingTimeInterval(2)
        while store.refreshInFlightForTesting, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(store.refreshInFlightForTesting)
    }

    private func waitForPricingCompletion(_ store: MonitorStore) {
        let deadline = Date().addingTimeInterval(2)
        while store.pricingRefreshInFlightForTesting, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(store.pricingRefreshInFlightForTesting)
    }

    private func waitForHealthProbeCompletion(_ store: MonitorStore) {
        let deadline = Date().addingTimeInterval(2)
        while store.developerDiagnostics.healthProbeInFlight, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(store.developerDiagnostics.healthProbeInFlight)
    }

    private func waitForMonthlyBudgetCompletion(_ store: MonitorStore) {
        let deadline = Date().addingTimeInterval(2)
        while store.monthlyBudgetRefreshInFlightForTesting, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(store.monthlyBudgetRefreshInFlightForTesting)
    }

    private func waitForMonthlyBudgetCall(_ runner: MonthlyBudgetStubRunner, count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while runner.monthlyCallCount < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(runner.monthlyCallCount, count)
    }

    private func waitForMonthlyBudgetCall(_ runner: CatalogGapMonthlyRunner, count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while runner.monthlyCallCount < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(runner.monthlyCallCount, count)
    }

    private func waitForFailingMonthlyBudgetCall(_ runner: FailingMonthlyBudgetRunner, count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while runner.monthlyCallCount < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(runner.monthlyCallCount, count)
    }

    private func waitForRunnerCall(_ runner: FailingUsageRunner, count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while runner.callCount < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(runner.callCount, count)
    }

    private func waitForUsageCall(_ runner: BlockingUsageRunner, count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while runner.callCount < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(runner.callCount, count)
    }

    private func waitForRunnerModes(_ runner: ModeRecordingRunner, count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while runner.modesForTesting.count < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(runner.modesForTesting.count, count)
    }

    private func waitForRunnerModes(_ runner: CatalogPendingRunner, count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while runner.modesForTesting.count < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(runner.modesForTesting.count, count)
    }

    private func waitForModelCatalogStart(_ provider: PendingModelCatalogProvider) {
        waitForModelCatalogFetch(provider, count: 1)
    }

    private func waitForModelCatalogFetch(_ provider: PendingModelCatalogProvider, count: Int) {
        let deadline = Date().addingTimeInterval(2)
        while provider.fetchCountForTesting < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(provider.fetchCountForTesting, count, "model catalog refresh did not start")
    }

    private func makeMonthlyBudgetSnapshot(
        now: Date,
        cost: Double,
        pricingUpdatedAt: Date? = nil
    ) -> MonthlyBudgetSnapshot {
        MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: now),
            generatedAt: now,
            pricingUpdatedAt: pricingUpdatedAt,
            customPricingRevision: nil,
            models: [],
            totalTokens: 1,
            estimatedCost: cost,
            unknownPricingModels: [],
            realtimeAnchorDay: MonthlyBudgetSnapshot.dayPeriod(for: now),
            realtimeAnchorTodayCost: 0
        )
    }

    private func makeScopedSnapshot(scope: UsageQueryScope, cost: Double) -> UsageSnapshot {
        makeScopedSnapshot(scope: scope, cost: cost, pricingUpdatedAt: nil)
    }

    private func makeScopedSnapshot(
        scope: UsageQueryScope,
        cost: Double,
        pricingUpdatedAt: Date?,
        customPricingRevision: String? = nil,
        modelCatalogRevision: String? = nil,
        tokens: TokenTotals = TokenTotals(inputTokens: 10)
    ) -> UsageSnapshot {
        let model = ModelUsage(agent: "codex", name: "model", tokens: tokens, estimatedCost: cost, hasKnownPricing: true)
        let dailyModel = DailyModelUsage(period: scope.until, agent: model.agent, name: model.name, tokens: tokens, estimatedCost: cost, hasKnownPricing: true)
        return UsageSnapshot(
            schemaVersion: UsageSnapshot.currentSchemaVersion,
            generatedAt: Date(),
            pricingUpdatedAt: pricingUpdatedAt,
            queryScope: scope,
            customPricingRevision: customPricingRevision,
            modelCatalogRevision: modelCatalogRevision,
            days: [DailyUsage(period: scope.until, tokens: tokens, estimatedCost: cost)],
            dailyModels: [dailyModel],
            agents: [AgentUsage(name: model.agent, tokens: tokens, estimatedCost: cost)],
            models: [model],
            totalTokens: tokens,
            estimatedCost: cost,
            unknownPricingModels: [],
            pricingSource: .ccusage
        )
    }
}

@MainActor
private final class TestClock {
    var now: Date

    init() {
        self.now = Date()
    }

    init(now: Date) {
        self.now = now
    }
}

private final class StubRunner: CCUsageRunnerProtocol {
    private let settings: MonitorSettings
    private let snapshot: UsageSnapshot

    init(settings: MonitorSettings, snapshot: UsageSnapshot) {
        self.settings = settings
        self.snapshot = snapshot
    }

    func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot {
        XCTAssertEqual(settings, self.settings)
        return snapshot
    }
}

private final class BlockingEveryUsageRunner: @unchecked Sendable, CCUsageRunnerProtocol {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let snapshots: [UsageSnapshot]
    private var calls = 0

    init(snapshots: [UsageSnapshot]) {
        self.snapshots = snapshots
    }

    func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot {
        let snapshot = snapshots[min(calls, snapshots.count - 1)]
        calls += 1
        started.signal()
        _ = release.wait(timeout: .now() + 2)
        return snapshot
    }
}

private final class BlockingUsageRunner: @unchecked Sendable, CCUsageRunnerProtocol {
    let firstStarted = DispatchSemaphore(value: 0)
    private let firstRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let snapshot: UsageSnapshot
    private let blockCall: Int
    private var calls = 0

    init(snapshot: UsageSnapshot, blockCall: Int = 1) {
        self.snapshot = snapshot
        self.blockCall = blockCall
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func releaseFirst() {
        firstRelease.signal()
    }

    func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot {
        _ = settings
        _ = mode
        _ = previousPricingDate
        lock.lock()
        calls += 1
        let call = calls
        lock.unlock()
        if call == blockCall {
            firstStarted.signal()
            _ = firstRelease.wait(timeout: .now() + 2)
        }
        return snapshot
    }
}

private final class ModeRecordingRunner: @unchecked Sendable, CCUsageRunnerProtocol {
    let firstStarted = DispatchSemaphore(value: 0)
    private let firstRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let snapshot: UsageSnapshot
    private var recordedModes: [CCUsageRunMode] = []

    init(snapshot: UsageSnapshot) {
        self.snapshot = snapshot
    }

    var modesForTesting: [CCUsageRunMode] {
        lock.lock()
        defer { lock.unlock() }
        return recordedModes
    }

    func releaseFirst() {
        firstRelease.signal()
    }

    func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot {
        _ = settings
        _ = previousPricingDate
        lock.lock()
        recordedModes.append(mode)
        let callNumber = recordedModes.count
        lock.unlock()
        if callNumber == 1 {
            firstStarted.signal()
            _ = firstRelease.wait(timeout: .now() + 2)
        }
        return snapshot
    }
}

private final class CatalogPendingRunner: @unchecked Sendable, CCUsageRunnerProtocol {
    private let lock = NSLock()
    private let snapshot: UsageSnapshot
    private var recordedModes: [CCUsageRunMode] = []

    init(snapshot: UsageSnapshot) {
        self.snapshot = snapshot
    }

    var modesForTesting: [CCUsageRunMode] {
        lock.lock()
        defer { lock.unlock() }
        return recordedModes
    }

    func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot {
        _ = settings
        _ = previousPricingDate
        lock.lock()
        recordedModes.append(mode)
        lock.unlock()
        return snapshot
    }
}

private final class CatalogGapMonthlyRunner: @unchecked Sendable, CCUsageRunnerProtocol {
    private let lock = NSLock()
    private let usageSnapshot: UsageSnapshot
    private let pricingDate: Date
    private var monthlyCalls = 0

    init(usageSnapshot: UsageSnapshot, pricingDate: Date) {
        self.usageSnapshot = usageSnapshot
        self.pricingDate = pricingDate
    }

    var monthlyCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return monthlyCalls
    }

    func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot {
        _ = settings
        _ = mode
        _ = previousPricingDate
        return usageSnapshot
    }

    func runWithPricingContext(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?,
        pricingContext: PricingResolutionContext
    ) throws -> UsageSnapshotBuildResult {
        _ = settings
        _ = mode
        _ = previousPricingDate
        _ = pricingConfigURL
        let snapshot = UsageSnapshot(
            schemaVersion: usageSnapshot.schemaVersion,
            generatedAt: usageSnapshot.generatedAt,
            pricingUpdatedAt: pricingDate,
            queryScope: usageSnapshot.queryScope,
            customPricingRevision: pricingContext.table.revision,
            modelCatalogRevision: pricingContext.remoteCatalogRevision,
            days: usageSnapshot.days,
            dailyModels: usageSnapshot.dailyModels,
            agents: usageSnapshot.agents,
            models: usageSnapshot.models,
            totalTokens: usageSnapshot.totalTokens,
            estimatedCost: usageSnapshot.estimatedCost,
            unknownPricingModels: usageSnapshot.unknownPricingModels,
            pricingSource: usageSnapshot.pricingSource
        )
        return UsageSnapshotBuildResult(snapshot: snapshot, pricingAssessment: .empty)
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
        _ = settings
        _ = mode
        _ = pricingConfigURL
        lock.lock()
        monthlyCalls += 1
        lock.unlock()

        var assessment = PricingAssessmentContext.empty
        assessment.record(
            modelName: "catalog-gap-model",
            outcome: .intentionalUnknown,
            catalogGap: .ambiguous
        )
        let snapshot = MonthlyBudgetSnapshot(
            month: MonthlyBudgetSnapshot.monthPeriod(for: now),
            generatedAt: now,
            pricingUpdatedAt: previousPricingDate ?? pricingDate,
            customPricingRevision: customPricingRevision,
            modelCatalogRevision: pricingContext.remoteCatalogRevision,
            models: [MonthlyBudgetModel(
                agent: "codex",
                name: "catalog-gap-model",
                tokens: TokenTotals(inputTokens: 10),
                estimatedCost: 0,
                hasKnownPricing: false
            )],
            totalTokens: 10,
            estimatedCost: 0,
            unknownPricingModels: ["catalog-gap-model"]
        )
        return MonthlyBudgetBuildResult(snapshot: snapshot, pricingAssessment: assessment)
    }
}

private final class PendingModelCatalogProvider: @unchecked Sendable, ModelCatalogPluginProvider {
    let manifest: PluginManifest
    let snapshot: ModelCatalogSnapshot

    private let lock = NSLock()
    private var continuation: CheckedContinuation<ModelCatalogSnapshot, Never>?
    private var fetchCount = 0

    init(snapshot: ModelCatalogSnapshot) {
        self.snapshot = snapshot
        self.manifest = PluginManifest(
            manifestVersion: PluginManifest.currentManifestVersion,
            id: snapshot.providerID,
            displayName: "Test model catalog",
            version: "1.0.0",
            protocolVersion: PluginManifest.currentProtocolVersion,
            capabilities: [.modelCatalog]
        )
    }

    var fetchCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return fetchCount
    }

    func fetchModelCatalog() async throws -> ModelCatalogSnapshot {
        await withCheckedContinuation { (continuation: CheckedContinuation<ModelCatalogSnapshot, Never>) in
            lock.lock()
            self.fetchCount += 1
            self.continuation = continuation
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: snapshot)
    }
}

private final class FailingUsageRunner: @unchecked Sendable, CCUsageRunnerProtocol {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot {
        _ = settings
        _ = mode
        _ = previousPricingDate
        lock.lock()
        calls += 1
        lock.unlock()
        throw CCUsageRunnerError.failed(status: 1, message: "test failure")
    }
}

private final class MonthlyBudgetStubRunner: @unchecked Sendable, CCUsageRunnerProtocol {
    let usageSnapshot: UsageSnapshot
    let monthlySnapshot: (Date) -> MonthlyBudgetSnapshot
    private let lock = NSLock()
    private var callCount = 0
    private let monthlyStarted: DispatchSemaphore?
    private let monthlyRelease: DispatchSemaphore?
    private let usageStarted: DispatchSemaphore?
    private let usageRelease: DispatchSemaphore?

    var monthlyCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    init(
        usageSnapshot: UsageSnapshot,
        monthlySnapshot: @escaping (Date) -> MonthlyBudgetSnapshot,
        monthlyStarted: DispatchSemaphore? = nil,
        monthlyRelease: DispatchSemaphore? = nil,
        usageStarted: DispatchSemaphore? = nil,
        usageRelease: DispatchSemaphore? = nil
    ) {
        self.usageSnapshot = usageSnapshot
        self.monthlySnapshot = monthlySnapshot
        self.monthlyStarted = monthlyStarted
        self.monthlyRelease = monthlyRelease
        self.usageStarted = usageStarted
        self.usageRelease = usageRelease
    }

    func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot {
        usageStarted?.signal()
        if let usageRelease {
            _ = usageRelease.wait(timeout: .now() + 2)
        }
        return usageSnapshot
    }

    func runMonthlyBudget(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?,
        customPricingRevision: String?,
        now: Date
    ) throws -> MonthlyBudgetSnapshot {
        lock.lock()
        callCount += 1
        lock.unlock()
        monthlyStarted?.signal()
        if let monthlyRelease {
            _ = monthlyRelease.wait(timeout: .now() + 2)
        }
        return monthlySnapshot(now)
    }
}

private final class FailingMonthlyBudgetRunner: @unchecked Sendable, CCUsageRunnerProtocol {
    let usageSnapshot: UsageSnapshot
    private let lock = NSLock()
    private var calls = 0

    init(usageSnapshot: UsageSnapshot) {
        self.usageSnapshot = usageSnapshot
    }

    var monthlyCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot {
        usageSnapshot
    }

    func runMonthlyBudget(
        settings: MonitorSettings,
        mode: CCUsageRunMode,
        previousPricingDate: Date?,
        pricingConfigURL: URL?,
        customPricingRevision: String?,
        now: Date
    ) throws -> MonthlyBudgetSnapshot {
        lock.lock()
        calls += 1
        lock.unlock()
        throw CCUsageRunnerError.failed(status: 1, message: "test monthly failure")
    }
}

private final class ScopeRaceRunner: CCUsageRunnerProtocol, @unchecked Sendable {
    let firstStarted = DispatchSemaphore(value: 0)
    private let firstRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let first: UsageSnapshot
    private let second: UsageSnapshot
    private var calls = 0

    init(first: UsageSnapshot, second: UsageSnapshot) {
        self.first = first
        self.second = second
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func releaseFirst() {
        firstRelease.signal()
    }

    func run(settings: MonitorSettings, mode: CCUsageRunMode, previousPricingDate: Date?) throws -> UsageSnapshot {
        _ = settings
        _ = mode
        _ = previousPricingDate
        lock.lock()
        calls += 1
        let call = calls
        lock.unlock()
        if call == 1 {
            firstStarted.signal()
            firstRelease.wait()
            return first
        }
        return second
    }
}

private final class FingerprintSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[SourceFingerprint]]

    init(values: [[SourceFingerprint]]) {
        self.values = values
    }

    func next() -> [SourceFingerprint] {
        lock.lock()
        defer { lock.unlock() }
        if values.count > 1 {
            return values.removeFirst()
        }
        return values.first ?? []
    }
}

private final class InFlightFingerprintSequence: @unchecked Sendable {
    let secondScanStarted = DispatchSemaphore(value: 0)
    private let secondScanRelease = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let values: [[SourceFingerprint]]
    private var callCount = 0

    init(values: [[SourceFingerprint]]) {
        self.values = values
    }

    func next() -> [SourceFingerprint] {
        lock.lock()
        let index = min(callCount, max(values.count - 1, 0))
        callCount += 1
        lock.unlock()

        if index == 1 {
            secondScanStarted.signal()
            _ = secondScanRelease.wait(timeout: .now() + 2)
        }
        return values[index]
    }

    func releaseSecondScan() {
        secondScanRelease.signal()
    }
}
