import SwiftUI

private enum NotificationFeedFilter: String, CaseIterable, Identifiable {
    case all
    case unread

    var id: String { rawValue }
}

struct NotificationBellButton: View {
    @ObservedObject var store: MonitorStore
    @Binding var isPresented: Bool

    @State private var isHovering = false

    private var copy: L10n { L10n(language: store.settings.language) }
    private var unreadCount: Int {
        store.notificationUnreadCount
    }

    private var notificationFeedWidth: CGFloat {
        max(300, CGFloat(store.settings.interfaceTextSize.popoverWidth) - 32)
    }

    private var notificationFeedHeight: CGFloat {
        let count = store.notificationEvents.count
        guard count > 0 else { return 260 }
        return min(440, max(300, CGFloat(104 + min(count, 5) * 74)))
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                isPresented.toggle()
            }
        } label: {
            Image(systemName: unreadCount > 0 ? "bell.badge.fill" : "bell")
                .appFont(.icon)
                .foregroundStyle(unreadCount > 0 ? AppWindowTheme.primary : AppWindowTheme.secondary)
                .frame(width: 28, height: 26)
                .overlay(alignment: .topTrailing) {
                    if unreadCount > 0 {
                        Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                            .appFont(.metadataEmphasis)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(AppWindowTheme.accent, in: Capsule())
                            .overlay(Capsule().stroke(AppWindowTheme.panel, lineWidth: 1.5))
                            .offset(x: 4, y: -4)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? AppWindowTheme.accent.opacity(0.11) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.borderless)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $isPresented, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
            NotificationFeedPopoverView(
                store: store,
                onClose: {
                    withAnimation(.easeOut(duration: 0.16)) {
                        isPresented = false
                    }
                }
            )
            .frame(width: notificationFeedWidth, height: notificationFeedHeight)
            .animation(.spring(response: 0.42, dampingFraction: 0.84), value: notificationFeedHeight)
        }
        .help(copy.notificationFeedOpen)
        .accessibilityLabel(copy.notificationFeedAccessibilityLabel(unreadCount))
        .accessibilityValue(isPresented ? copy.notificationFeedOpen : copy.notificationFeedClosed)
    }
}

struct NotificationFeedPopoverView: View {
    @ObservedObject var store: MonitorStore
    let onClose: () -> Void

    @State private var filter: NotificationFeedFilter = .all

    private var copy: L10n { L10n(language: store.settings.language) }
    private var events: [NotificationFeedEvent] { store.notificationEvents }
    private var unreadCount: Int { events.filter { !$0.isRead }.count }
    private var filteredEvents: [NotificationFeedEvent] {
        switch filter {
        case .all:
            return events
        case .unread:
            return events.filter { !$0.isRead }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !store.settings.notificationFeedEnabled {
                disabledState
            } else if events.isEmpty {
                emptyState(
                    icon: "checkmark.circle",
                    title: copy.notificationFeedEmpty,
                    subtitle: copy.notificationFeedEmptySubtitle
                )
            } else {
                filterBar
                Divider()
                    .overlay(AppWindowTheme.separator.opacity(0.7))
                notificationList
            }
        }
        .background(AppSurfacePanelBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppWindowTheme.separator.opacity(0.8), lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .animation(.easeInOut(duration: 0.24), value: filteredEvents.map(\.scopedID))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(unreadCount > 0 ? AppWindowTheme.accent.opacity(0.14) : AppWindowTheme.signal.opacity(0.12))
                Image(systemName: unreadCount > 0 ? "bell.badge.fill" : "bell")
                    .appFont(.icon)
                    .foregroundStyle(unreadCount > 0 ? AppWindowTheme.accent : AppWindowTheme.signal)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(copy.notificationFeedTitle)
                        .appFont(.section)
                        .foregroundStyle(AppWindowTheme.primary)
                    if unreadCount > 0 {
                        Text(copy.notificationFeedUnreadCount(unreadCount))
                            .appFont(.metadataEmphasis)
                            .foregroundStyle(AppWindowTheme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(AppWindowTheme.accent.opacity(0.11), in: Capsule())
                    }
                }
                Text(headerSubtitle)
                    .appFont(.metadata)
                    .foregroundStyle(AppWindowTheme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                if unreadCount > 0 {
                    NotificationIconButton(
                        systemImage: "checkmark.circle",
                        help: copy.notificationFeedMarkAllRead,
                        tint: AppWindowTheme.accent
                    ) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                            store.markAllNotificationsRead()
                        }
                    }
                }
                NotificationIconButton(
                    systemImage: "xmark",
                    help: copy.notificationFeedClose,
                    tint: AppWindowTheme.secondary,
                    action: onClose
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    private var filterBar: some View {
        HStack(spacing: 3) {
            filterButton(
                .all,
                title: copy.notificationFeedAll,
                count: events.count
            )
            filterButton(
                .unread,
                title: copy.notificationFeedUnread,
                count: unreadCount
            )
            Spacer(minLength: 0)
            if !events.isEmpty {
                Button(copy.notificationFeedClearAll) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                        store.dismissAllNotifications()
                    }
                }
                .buttonStyle(.plain)
                .appFont(.metadataEmphasis)
                .foregroundStyle(AppWindowTheme.secondary)
                .help(copy.notificationFeedClearAllHelp)
                .accessibilityLabel(copy.notificationFeedClearAll)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func filterButton(
        _ selection: NotificationFeedFilter,
        title: String,
        count: Int
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                filter = selection
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)")
                    .foregroundStyle(filter == selection ? AppWindowTheme.accent : AppWindowTheme.tertiary)
            }
            .appFont(.metadataEmphasis)
            .foregroundStyle(filter == selection ? AppWindowTheme.primary : AppWindowTheme.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(filter == selection ? AppWindowTheme.primary.opacity(0.09) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var notificationList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 8) {
                if filteredEvents.isEmpty {
                    emptyState(
                        icon: "checkmark.circle",
                        title: copy.notificationFeedNoUnread,
                        subtitle: copy.notificationFeedEmptySubtitle
                    )
                    .padding(.vertical, 26)
                } else {
                    ForEach(filteredEvents, id: \.scopedID) { event in
                        NotificationEventRow(
                            event: event,
                            title: copy.notificationFeedEventTitle(event.type, fallback: event.title),
                            sourceLabel: sourceLabel(for: event),
                            eventTypeLabel: copy.notificationFeedEventType(event.type),
                            displayBody: event.catalogChangeSummary.map(copy.notificationFeedCatalogSummary) ?? event.body,
                            timestamp: relativeTime(for: event.createdAt),
                            markReadLabel: copy.notificationFeedMarkRead,
                            dismissLabel: copy.notificationFeedDismiss,
                            onMarkRead: {
                                withAnimation(.easeInOut(duration: 0.24)) {
                                    store.markNotificationRead(event.scopedID)
                                }
                            },
                            onDismiss: {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                                    store.dismissNotification(event.scopedID)
                                }
                            }
                        )
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing))
                            )
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    private var disabledState: some View {
        emptyState(
            icon: "bell.slash",
            title: copy.notificationFeedEnabled,
            subtitle: copy.notificationFeedDisabled
        )
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .appFont(.icon)
                .foregroundStyle(AppWindowTheme.secondary)
                .frame(width: 42, height: 42)
                .background(AppWindowTheme.primary.opacity(0.07), in: Circle())
            Text(title)
                .appFont(.bodyEmphasis)
                .foregroundStyle(AppWindowTheme.primary)
            Text(subtitle)
                .appFont(.metadata)
                .foregroundStyle(AppWindowTheme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
    }

    private var headerSubtitle: String {
        if unreadCount > 0 {
            return copy.notificationFeedUnreadCount(unreadCount)
        }
        return copy.notificationFeedEmptySubtitle
    }

    private func sourceLabel(for event: NotificationFeedEvent) -> String {
        if event.sourceID == MockNotificationFeedPlugin.sourceID {
            return copy.notificationFeedSourceTestPlugin
        }
        if event.type.rawValue.hasPrefix("model-catalog.") {
            return copy.notificationFeedSourceModelCatalog
        }
        switch event.sourceKind {
        case .internalSource, .hostModule:
            return copy.notificationFeedSourceInternal
        case .plugin:
            return copy.notificationFeedSourcePlugin
        }
    }

    private func relativeTime(for date: Date) -> String {
        RelativeTime.localizedString(
            for: date,
            relativeTo: Date(),
            language: store.settings.language
        )
    }
}

private struct NotificationEventRow: View {
    let event: NotificationFeedEvent
    let title: String
    let sourceLabel: String
    let eventTypeLabel: String
    let displayBody: String
    let timestamp: String
    let markReadLabel: String
    let dismissLabel: String
    let onMarkRead: () -> Void
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: severityIcon)
                .appFont(.icon)
                .foregroundStyle(severityColor)
                .frame(width: 23, height: 23)
                .background(severityColor.opacity(event.isRead ? 0.08 : 0.14), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(title)
                        .appFont(.bodyEmphasis)
                        .foregroundStyle(AppWindowTheme.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    HStack(spacing: 4) {
                        Text(timestamp)
                            .appFont(.metadata)
                            .foregroundStyle(AppWindowTheme.tertiary)
                            .lineLimit(1)
                        actionButtons
                    }
                }

                HStack(spacing: 5) {
                    Text(sourceLabel)
                    Text("·")
                        .foregroundStyle(AppWindowTheme.tertiary)
                    Text(eventTypeLabel)
                }
                .appFont(.metadataEmphasis)
                .foregroundStyle(AppWindowTheme.secondary)

                Text(displayBody)
                    .appFont(.metadata)
                    .foregroundStyle(AppWindowTheme.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(severityColor.opacity(event.isRead ? 0.035 : 0.075))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    severityColor.opacity(event.isRead ? 0.08 : 0.2),
                    lineWidth: 0.7
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            if !event.isRead {
                Button(action: onMarkRead) {
                    Label(markReadLabel, systemImage: "checkmark")
                }
            }
            Button(action: onDismiss) {
                Label(dismissLabel, systemImage: "xmark")
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 2) {
            if !event.isRead {
                NotificationIconButton(
                    systemImage: "checkmark",
                    help: markReadLabel,
                    tint: AppWindowTheme.accent,
                    action: onMarkRead
                )
            }
            NotificationIconButton(
                systemImage: "xmark",
                help: dismissLabel,
                tint: AppWindowTheme.alert,
                action: onDismiss
            )
        }
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
        .accessibilityHidden(!isHovering)
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    private var severityIcon: String {
        switch event.severity {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.octagon.fill"
        }
    }

    private var severityColor: Color {
        switch event.severity {
        case .info: return AppWindowTheme.accent
        case .success: return AppWindowTheme.signal
        case .warning: return .orange
        case .error: return AppWindowTheme.alert
        }
    }
}

private struct NotificationIconButton: View {
    let systemImage: String
    let help: String
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .appFont(.metadataEmphasis)
                .foregroundStyle(isHovering ? tint : AppWindowTheme.secondary)
                .frame(width: 25, height: 25)
                .background(
                    Circle()
                        .fill(isHovering ? tint.opacity(0.12) : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}
