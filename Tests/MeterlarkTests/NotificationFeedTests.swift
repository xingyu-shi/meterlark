import Foundation
import XCTest
@testable import MeterlarkApp

final class NotificationFeedTests: XCTestCase {
    func testLegacyKindPayloadDecodesIntoNamespacedEventType() throws {
        let event = try JSONDecoder().decode(
            NotificationFeedEvent.self,
            from: Data("""
            {
              "id": "legacy-event",
              "source": "legacy-provider",
              "kind": "modelAdded",
              "title": "Model added",
              "body": "new-model",
              "createdAt": 1,
              "isRead": false,
              "isDismissed": false
            }
            """.utf8)
        )

        XCTAssertEqual(event.sourceKind, .plugin)
        XCTAssertEqual(event.sourceID, "legacy-provider")
        XCTAssertEqual(event.type, .modelAdded)
        XCTAssertEqual(event.kind, .modelAdded)
    }

    func testUnknownLegacyKindIsPreservedUnderLegacyNamespace() throws {
        let event = try JSONDecoder().decode(
            NotificationFeedEvent.self,
            from: Data("""
            {
              "id": "legacy-event",
              "source": "legacy-provider",
              "kind": "vendor/changed",
              "title": "Changed",
              "body": "payload",
              "createdAt": 1
            }
            """.utf8)
        )

        XCTAssertEqual(event.type.rawValue, "legacy.vendor_changed")
        XCTAssertTrue(NotificationEventType.isValid(event.type.rawValue))
    }

    func testArbitraryNamespacedPluginEventIsPersisted() throws {
        let url = temporaryURL("NotificationFeed.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let event = makeEvent(
            id: "plugin-event",
            sourceKind: .hostModule,
            sourceID: "future-module",
            type: NotificationEventType("future-module.catalog-updated")
        )

        var feed = NotificationFeedStore(fileURL: url)
        feed.append([event])

        let reloaded = NotificationFeedStore(fileURL: url)
        XCTAssertEqual(reloaded.events, [event])
        XCTAssertEqual(reloaded.visibleEvents.first?.type.rawValue, "future-module.catalog-updated")
    }

    func testSameEventIDFromDifferentSourcesDoesNotDeduplicate() {
        var feed = NotificationFeedStore(fileURL: temporaryURL("NotificationFeed.json"))
        let first = makeEvent(id: "same-id", sourceID: "source-a")
        let second = makeEvent(id: "same-id", sourceID: "source-b")

        feed.append([first, second])

        XCTAssertEqual(feed.events.count, 2)
        XCTAssertEqual(Set(feed.events.map(\.scopedID)).count, 2)
    }

    func testIndistinguishableSameBatchPricingEventsDeduplicateButLaterOccurrencesRemain() {
        var feed = NotificationFeedStore(fileURL: temporaryURL("NotificationFeed.json"))
        let first = makeEvent(id: "pricing-1", type: .pricingChanged)
        let second = makeEvent(id: "pricing-2", type: .pricingChanged)

        feed.append([first, second])

        XCTAssertEqual(feed.events.count, 1)
        XCTAssertEqual(feed.events.first?.id, first.id)

        let later = makeEvent(
            id: "pricing-3",
            type: .pricingChanged,
            createdAt: Date(timeIntervalSince1970: 101)
        )
        feed.append([later])

        XCTAssertEqual(feed.events.count, 2)
    }

    func testCorruptedExistingFileIsNeverOverwrittenByMutation() throws {
        let url = temporaryURL("NotificationFeed.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = Data("not-json".utf8)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try original.write(to: url)

        var feed = NotificationFeedStore(fileURL: url)
        XCTAssertEqual(feed.loadState, .invalidExistingData)
        feed.append([makeEvent(id: "new-event")])
        feed.markAllRead()
        feed.dismiss("new-event")

        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertThrowsError(try feed.save()) { error in
            XCTAssertEqual(error as? NotificationFeedStoreError, .existingDataUnreadable)
        }
    }

    @MainActor
    func testCoordinatorPublishesAndProjectsReadAndDismissState() {
        let url = temporaryURL("NotificationFeed.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let event = makeEvent(id: "coordinator-event")
        let coordinator = NotificationFeedCoordinator(store: NotificationFeedStore(fileURL: url))

        coordinator.publish([event])
        XCTAssertEqual(coordinator.visibleEvents, [event])
        XCTAssertEqual(coordinator.unreadCount, 1)

        coordinator.markRead(event.scopedID)
        XCTAssertEqual(coordinator.unreadCount, 0)
        XCTAssertEqual(coordinator.visibleEvents.first?.isRead, true)

        coordinator.dismiss(event.scopedID)
        XCTAssertTrue(coordinator.visibleEvents.isEmpty)
    }

    @MainActor
    func testCoordinatorCanDismissAllNotificationsAndPersistAnEmptyFeed() {
        let url = temporaryURL("NotificationFeed.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = NotificationFeedCoordinator(store: NotificationFeedStore(fileURL: url))

        coordinator.publish([
            makeEvent(id: "first-event"),
            makeEvent(id: "second-event", sourceID: "another-provider")
        ])
        XCTAssertEqual(coordinator.visibleEvents.count, 2)

        coordinator.dismissAll()

        XCTAssertTrue(coordinator.visibleEvents.isEmpty)
        XCTAssertTrue(NotificationFeedStore(fileURL: url).visibleEvents.isEmpty)
    }

    @MainActor
    func testMockNotificationPluginPublishesACompleteSampleBatchThroughTheSink() {
        let sink = RecordingNotificationFeedSink()
        let plugin = MockNotificationFeedPlugin(sink: sink)
        let now = Date(timeIntervalSince1970: 1_000)

        let firstBatch = plugin.publishSampleBatch(language: .chinese, now: now)
        let secondBatch = plugin.publishSampleBatch(language: .english, now: now)

        XCTAssertEqual(firstBatch.count, 4)
        XCTAssertEqual(secondBatch.count, 4)
        XCTAssertEqual(sink.events.count, 8)
        XCTAssertEqual(Set(sink.events.map(\.scopedID)).count, 8)
        XCTAssertEqual(
            Set(firstBatch.map(\.type)),
            Set([.modelAdded, .pricingChanged, .modelRemoved, NotificationEventType("mock.notification-feed-test")])
        )
        XCTAssertEqual(Set(firstBatch.map(\.sourceID)), [MockNotificationFeedPlugin.sourceID])
        XCTAssertEqual(firstBatch.first?.title, "模型目录已更新")
        XCTAssertEqual(secondBatch.first?.title, "Model catalog updated")
        XCTAssertTrue(firstBatch.allSatisfy { !$0.isRead && !$0.isDismissed })
    }

    func testStableEventIdentityIncludesSourceTypeAndOccurrence() {
        let base = NotificationFeedEvent.stableID(
            sourceKind: .plugin,
            sourceID: "provider-a",
            type: .modelAdded,
            occurrenceKey: "revision-1|record-1"
        )
        let differentSource = NotificationFeedEvent.stableID(
            sourceKind: .plugin,
            sourceID: "provider-b",
            type: .modelAdded,
            occurrenceKey: "revision-1|record-1"
        )
        let differentType = NotificationFeedEvent.stableID(
            sourceKind: .plugin,
            sourceID: "provider-a",
            type: .modelRemoved,
            occurrenceKey: "revision-1|record-1"
        )
        let differentOccurrence = NotificationFeedEvent.stableID(
            sourceKind: .plugin,
            sourceID: "provider-a",
            type: .modelAdded,
            occurrenceKey: "revision-2|record-1"
        )

        XCTAssertEqual(base.count, 64)
        XCTAssertEqual(Set([base, differentSource, differentType, differentOccurrence]).count, 4)
    }

    private func makeEvent(
        id: String,
        sourceKind: NotificationSourceKind = .plugin,
        sourceID: String = "provider",
        type: NotificationEventType = .modelAdded,
        createdAt: Date = Date(timeIntervalSince1970: 100)
    ) -> NotificationFeedEvent {
        NotificationFeedEvent(
            id: id,
            sourceID: sourceID,
            sourceKind: sourceKind,
            type: type,
            title: "Model changed",
            body: "model",
            createdAt: createdAt,
            isRead: false,
            isDismissed: false
        )
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MeterlarkTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    @MainActor
    private final class RecordingNotificationFeedSink: NotificationFeedSink {
        private(set) var events: [NotificationFeedEvent] = []

        func publish(_ events: [NotificationFeedEvent]) {
            self.events.append(contentsOf: events)
        }
    }
}
