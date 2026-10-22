import Foundation

/// Developer-only notification producer used to exercise the real feed UI.
///
/// This intentionally publishes through the host-owned sink instead of
/// reaching into MonitorStore or a view. It models the boundary an eventual
/// notification-capable external plugin can use without adding that wire
/// contract before its payload is finalized.
@MainActor
final class MockNotificationFeedPlugin {
    static let sourceID = "com.xingyu.meterlark.mock-notifications"

    private let sink: any NotificationFeedSink
    private var emittedBatchCount = 0

    init(sink: any NotificationFeedSink) {
        self.sink = sink
    }

    @discardableResult
    func publishSampleBatch(
        language: AppLanguage,
        now: Date = Date()
    ) -> [NotificationFeedEvent] {
        emittedBatchCount += 1
        let batchID = "batch-\(emittedBatchCount)-\(UUID().uuidString)"
        let copy = L10n(language: language)

        let events = [
            makeEvent(
                type: .modelAdded,
                severity: .info,
                title: copy.text("Model catalog updated", "模型目录已更新"),
                body: copy.text(
                    "A new model, example-gateway-demo-reasoner, is now available.",
                    "新增模型 example-gateway-demo-reasoner，现已可用。"
                ),
                occurrenceKey: "model-added",
                batchID: batchID,
                createdAt: now
            ),
            makeEvent(
                type: .pricingChanged,
                severity: .warning,
                title: copy.text("Pricing changed", "价格已调整"),
                body: copy.text(
                    "The demo catalog changed the output price for example-gateway-demo-reasoner.",
                    "演示目录调整了 example-gateway-demo-reasoner 的输出价格。"
                ),
                occurrenceKey: "pricing-changed",
                batchID: batchID,
                createdAt: now.addingTimeInterval(-0.25)
            ),
            makeEvent(
                type: .modelRemoved,
                severity: .error,
                title: copy.text("Model removed", "模型已下架"),
                body: copy.text(
                    "example-gateway-demo-legacy is no longer returned by the demo catalog.",
                    "演示目录不再返回 example-gateway-demo-legacy。"
                ),
                occurrenceKey: "model-removed",
                batchID: batchID,
                createdAt: now.addingTimeInterval(-0.5)
            ),
            makeEvent(
                type: NotificationEventType("mock.notification-feed-test"),
                severity: .success,
                title: copy.text("Catalog sync completed", "目录同步完成"),
                body: copy.text(
                    "This is a generic namespaced event from the mock notification plugin.",
                    "这是一条来自 mock notification plugin 的通用命名空间事件。"
                ),
                occurrenceKey: "sync-completed",
                batchID: batchID,
                createdAt: now.addingTimeInterval(-0.75)
            )
        ]

        sink.publish(events)
        return events
    }

    private func makeEvent(
        type: NotificationEventType,
        severity: NotificationSeverity,
        title: String,
        body: String,
        occurrenceKey: String,
        batchID: String,
        createdAt: Date
    ) -> NotificationFeedEvent {
        NotificationFeedEvent(
            id: NotificationFeedEvent.stableID(
                sourceKind: .plugin,
                sourceID: Self.sourceID,
                type: type,
                occurrenceKey: "\(batchID):\(occurrenceKey)"
            ),
            sourceID: Self.sourceID,
            sourceKind: .plugin,
            type: type,
            severity: severity,
            title: title,
            body: body,
            createdAt: createdAt,
            isRead: false,
            isDismissed: false
        )
    }
}
