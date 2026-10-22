import CoreServices
import Foundation

/// Coalesces watcher callbacks while a delivery is queued or being handled on
/// the main actor. Every callback still contributes to the diagnostic count,
/// but source invalidation itself is level-triggered: one delivery is enough
/// to mark the input dirty, followed by trailing delivery windows for callbacks
/// that arrived during or immediately after handling.
final class SourceEventGate: @unchecked Sendable {
    typealias Delivery = (_ callbackCount: Int, _ completion: @escaping () -> Void) -> Void
    // Source refreshes already wait for a two-second quiet period. A quarter
    // second here materially reduces main-actor wakeups during an FSEvents
    // storm without changing the user-visible refresh latency.
    private static let deliveryCoalescingWindow: TimeInterval = 0.25

    private let lock = NSLock()
    private let delivery: Delivery
    private var deliveryInFlight = false
    private var pendingCallbackCount = 0
    private var completionWorkItem: DispatchWorkItem?

    init(delivery: @escaping Delivery) {
        self.delivery = delivery
    }

    deinit {
        lock.lock()
        completionWorkItem?.cancel()
        completionWorkItem = nil
        lock.unlock()
    }

    func submit() {
        let callbackCount: Int?
        lock.lock()
        pendingCallbackCount += 1
        if deliveryInFlight {
            callbackCount = nil
        } else {
            deliveryInFlight = true
            callbackCount = pendingCallbackCount
            pendingCallbackCount = 0
        }
        lock.unlock()

        guard let callbackCount else { return }
        startDelivery(callbackCount: callbackCount)
    }

    private func startDelivery(callbackCount: Int) {
        delivery(callbackCount) { [weak self] in
            self?.completeDelivery()
        }
    }

    private func completeDelivery() {
        let workItem: DispatchWorkItem
        lock.lock()
        guard completionWorkItem == nil else {
            lock.unlock()
            return
        }
        workItem = DispatchWorkItem { [weak self] in
            self?.finishDeliveryWindow()
        }
        completionWorkItem = workItem
        lock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.deliveryCoalescingWindow,
            execute: workItem
        )
    }

    private func finishDeliveryWindow() {
        let callbackCount: Int?
        lock.lock()
        completionWorkItem = nil
        if pendingCallbackCount > 0 {
            callbackCount = pendingCallbackCount
            pendingCallbackCount = 0
        } else {
            deliveryInFlight = false
            callbackCount = nil
        }
        lock.unlock()

        guard let callbackCount else { return }
        startDelivery(callbackCount: callbackCount)
    }
}

final class SourceChangeWatcher {
    private let paths: [String]
    private let queue: DispatchQueue
    private let handler: () -> Void
    private let stateLock = NSLock()
    private var stream: FSEventStreamRef?
    private var streamHealthy = false

    var isRunning: Bool {
        guard stream != nil else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        return streamHealthy
    }

    /// A dropped or wrapped event ID means the stream can no longer be used as
    /// a complete source of invalidation events. Recreate it and let the
    /// fingerprint fallback cover anything that was missed.
    static func eventRequiresRecovery(_ flags: FSEventStreamEventFlags) -> Bool {
        let recoveryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        return flags & recoveryFlags != 0
    }

    static func eventBatchRequiresRecovery(
        _ flags: UnsafeBufferPointer<FSEventStreamEventFlags>
    ) -> Bool {
        flags.contains { eventRequiresRecovery($0) }
    }

    init(paths: [URL], handler: @escaping () -> Void) {
        self.paths = paths.map(\.path)
        self.queue = DispatchQueue(label: "com.xingyu.meterlark.source-watcher", qos: .utility)
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, numEvents, _, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<SourceChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            let batchFlags = UnsafeBufferPointer(
                start: eventFlags,
                count: max(Int(numEvents), 0)
            )
            watcher.handleEvent(requiresRecovery: SourceChangeWatcher.eventBatchRequiresRecovery(batchFlags))
        }
        let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
        guard let created else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        stream = created
        setStreamHealthy(false)
        guard FSEventStreamStart(created) else {
            stream = nil
            setStreamHealthy(false)
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        setStreamHealthy(true)
    }

    func stop() {
        setStreamHealthy(false)
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func setStreamHealthy(_ healthy: Bool) {
        stateLock.lock()
        streamHealthy = healthy
        stateLock.unlock()
    }

    private func handleEvent(requiresRecovery: Bool) {
        if requiresRecovery {
            setStreamHealthy(false)
        }
        handler()
    }
}
