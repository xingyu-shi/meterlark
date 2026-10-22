import SwiftUI
import UniformTypeIdentifiers

struct DashboardComponentDrag: Codable, Transferable {
    let componentID: String
    static let contentType = UTType(exportedAs: "com.xingyu.meterlark.dashboard-component", conformingTo: .json)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}

struct EditableDashboardComponent<Content: View>: View {
    let component: DashboardLayoutComponent
    @ObservedObject var draft: DashboardLayoutDraft
    let copy: L10n
    @ViewBuilder let content: Content
    @State private var isDropTargeted = false

    private var visibleIDs: [String] { draft.visibleComponentIDs }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .draggable(DashboardComponentDrag(componentID: component.id)) {
                        Label(component.title, systemImage: "line.3.horizontal")
                            .padding(10)
                            .background(AppSurfacePanelBackground())
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .help(copy.layoutDragToMove)
                    .accessibilityLabel(copy.layoutDragToMove)
                Text(component.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    draft.moveVisible(component.id, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(visibleIDs.first == component.id)
                .help(copy.layoutMoveUp)
                .accessibilityLabel(copy.layoutMoveUp)
                Button {
                    draft.moveVisible(component.id, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(visibleIDs.last == component.id)
                .help(copy.layoutMoveDown)
                .accessibilityLabel(copy.layoutMoveDown)
                Button {
                    draft.setVisible(false, componentID: component.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .help(copy.layoutRemoveComponent)
                .accessibilityLabel(copy.layoutRemoveComponent)
            }
            .buttonStyle(.borderless)
            .appFont(.caption)
            .foregroundStyle(AppWindowTheme.secondary)
            content
        }
        .padding(8)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDropTargeted ? AppWindowTheme.accent : AppWindowTheme.separator,
                              lineWidth: isDropTargeted ? 2 : 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .dropDestination(for: DashboardComponentDrag.self) { items, _ in
            guard items.count == 1,
                  let source = items.first?.componentID,
                  visibleIDs.contains(source), visibleIDs.contains(component.id) else { return false }
            return draft.move(source, to: component.id)
        } isTargeted: { isDropTargeted = $0 }
    }
}
