import SwiftUI

/// Opens category management as a sheet on the main calendar window (same display).
/// Avoids a separate `Window` scene that multi-monitor setups often restore to another screen.
struct OpenCategoryManagerAction: Sendable {
    private let handler: @MainActor @Sendable () -> Void

    init(_ handler: @escaping @MainActor @Sendable () -> Void = {}) {
        self.handler = handler
    }

    @MainActor
    func callAsFunction() {
        handler()
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
