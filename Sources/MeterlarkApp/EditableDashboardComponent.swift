import SwiftUI

struct DashboardComponentFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
final class DashboardPreviewDragState: ObservableObject {
    static let coordinateSpace = "dashboardComponentEditor"
    static let animation = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.86)

    @Published var frames: [String: CGRect] = [:]
    @Published private(set) var draggingID: String?
    @Published private(set) var location: CGPoint = .zero
    private var startLocation: CGPoint = .zero
    private var startingTop: CGFloat = 0
    private var originalOrder: [String] = []

    func offset(for componentID: String) -> CGFloat {
        guard draggingID == componentID, let frame = frames[componentID] else { return 0 }
        return location.y - startLocation.y + startingTop - frame.minY
    }

    func update(componentID: String, start: CGPoint, location: CGPoint, draft: DashboardLayoutDraft) {
        if draggingID == nil {
            guard let frame = frames[componentID], draft.visibleComponentIDs.contains(componentID) else { return }
            originalOrder = draft.layout.componentOrder
            startLocation = start
            startingTop = frame.minY
            draggingID = componentID
        }
        guard draggingID == componentID else { return }
        self.location = location

        let visible = draft.visibleComponentIDs
        guard let source = visible.firstIndex(of: componentID) else { return }
        var targetID: String?
        for (index, id) in visible.enumerated() where id != componentID {
            guard let frame = frames[id] else { continue }
            if index < source, location.y < frame.midY {
                targetID = id
                break
            }
            if index > source, location.y > frame.midY {
                targetID = id
            }
        }
        if let targetID {
            withAnimation(Self.animation) { _ = draft.move(componentID, to: targetID) }
        }
    }

    func end(draft: DashboardLayoutDraft, cancelled: Bool = false) {
        guard draggingID != nil else { return }
        withAnimation(Self.animation) {
            if cancelled {
                let current = Set(draft.layout.componentOrder)
                let original = Set(originalOrder)
                draft.layout.componentOrder = originalOrder.filter { current.contains($0) }
                    + draft.layout.componentOrder.filter { !original.contains($0) }
            }
            draggingID = nil
            originalOrder = []
        }
    }
}

struct EditableDashboardComponent<Content: View>: View {
    let component: DashboardLayoutComponent
    @ObservedObject var draft: DashboardLayoutDraft
    @ObservedObject var drag: DashboardPreviewDragState
    let copy: L10n
    @ViewBuilder let content: Content
    @GestureState private var isDragging = false

    private var visibleIDs: [String] { draft.visibleComponentIDs }
    private var isLifted: Bool { drag.draggingID == component.id }

    var body: some View {
        ZStack {
            if isLifted {
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppWindowTheme.accent.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(AppWindowTheme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
            }
            card
                .scaleEffect(isLifted ? 1.015 : 1)
                .offset(y: drag.offset(for: component.id))
                .shadow(color: .black.opacity(isLifted ? 0.16 : 0), radius: 14, y: 5)
                .transaction { if isLifted { $0.animation = nil } }
                .gesture(
                    DragGesture(minimumDistance: 5, coordinateSpace: .named(DashboardPreviewDragState.coordinateSpace))
                        .updating($isDragging) { _, active, _ in active = true }
                        .onChanged { value in
                            drag.update(componentID: component.id, start: value.startLocation,
                                        location: value.location, draft: draft)
                        }
                        .onEnded { _ in drag.end(draft: draft) }
                )
                .onChange(of: isDragging) { active in
                    if !active, isLifted { drag.end(draft: draft, cancelled: true) }
                }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: DashboardComponentFramesKey.self, value: [
                    component.id: geometry.frame(in: .named(DashboardPreviewDragState.coordinateSpace))
                ])
            }
        }
        .zIndex(isLifted ? 1 : 0)
        .onDisappear {
            if isLifted { drag.end(draft: draft, cancelled: true) }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 24, height: 24)
                    .help(copy.layoutDragToMove)
                    .accessibilityLabel(copy.layoutDragToMove)
                Text(component.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    withAnimation(DashboardPreviewDragState.animation) { draft.moveVisible(component.id, offset: -1) }
                } label: { Image(systemName: "chevron.up") }
                    .disabled(visibleIDs.first == component.id)
                    .help(copy.layoutMoveUp)
                    .accessibilityLabel(copy.layoutMoveUp)
                Button {
                    withAnimation(DashboardPreviewDragState.animation) { draft.moveVisible(component.id, offset: 1) }
                } label: { Image(systemName: "chevron.down") }
                    .disabled(visibleIDs.last == component.id)
                    .help(copy.layoutMoveDown)
                    .accessibilityLabel(copy.layoutMoveDown)
                Button {
                    withAnimation(DashboardPreviewDragState.animation) { draft.setVisible(false, componentID: component.id) }
                } label: { Image(systemName: "xmark") }
                    .help(copy.layoutRemoveComponent)
                    .accessibilityLabel(copy.layoutRemoveComponent)
            }
            .buttonStyle(.borderless)
            .appFont(.caption)
            .foregroundStyle(AppWindowTheme.secondary)
            content.allowsHitTesting(false)
        }
        .padding(8)
        .background(AppSurfacePanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isLifted ? AppWindowTheme.accent : AppWindowTheme.separator,
                              lineWidth: isLifted ? 1.5 : 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
    }
}
