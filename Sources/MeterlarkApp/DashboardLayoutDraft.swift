import Combine
import Foundation

/// One editing session shared by the preview and the settings window.
@MainActor
final class DashboardLayoutDraft: ObservableObject {
    @Published var layout: DashboardLayout
    @Published var popoverHeight: Double

    init(layout: DashboardLayout, popoverHeight: Double) {
        self.layout = layout
        self.popoverHeight = popoverHeight
    }

    var visibleComponentIDs: [String] {
        layout.componentOrder.filter { layout.isVisible($0) }
    }

    func setVisible(_ visible: Bool, componentID: String) {
        guard layout.componentOrder.contains(componentID) else { return }
        var updated = layout
        updated.hiddenComponentIDs.removeAll { $0 == componentID }
        if !visible {
            updated.hiddenComponentIDs.append(componentID)
        }
        layout = updated
    }

    @discardableResult
    func move(_ componentID: String, to targetID: String) -> Bool {
        guard componentID != targetID,
              let source = layout.componentOrder.firstIndex(of: componentID),
              let target = layout.componentOrder.firstIndex(of: targetID) else { return false }
        var updated = layout
        updated.componentOrder.remove(at: source)
        updated.componentOrder.insert(componentID, at: target)
        layout = updated
        return true
    }

    func moveVisible(_ componentID: String, offset: Int) {
        let visible = visibleComponentIDs
        guard let index = visible.firstIndex(of: componentID),
              visible.indices.contains(index + offset) else { return }
        move(componentID, to: visible[index + offset])
    }
}
