import SwiftUI

/// One atomic sheet request. The caller context travels with the presentation
/// identity, so SwiftUI cannot present the sheet from an older category value.
struct CategoryManagerPresentation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let initialCategoryID: UUID?
}

/// Opens category management as a sheet on the main calendar window (same display).
/// Avoids a separate `Window` scene that multi-monitor setups often restore to another screen.
struct OpenCategoryManagerAction: Sendable {
    private let handler: @MainActor @Sendable (UUID?) -> Void

    init(_ handler: @escaping @MainActor @Sendable (UUID?) -> Void = { _ in }) {
        self.handler = handler
    }

    @MainActor
    func callAsFunction(categoryID: UUID? = nil) {
        handler(categoryID)
    }
}

private struct OpenCategoryManagerKey: EnvironmentKey {
    static let defaultValue = OpenCategoryManagerAction()
}

extension EnvironmentValues {
    var openCategoryManager: OpenCategoryManagerAction {
        get { self[OpenCategoryManagerKey.self] }
        set { self[OpenCategoryManagerKey.self] = newValue }
    }
}
