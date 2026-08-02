import SwiftUI

@MainActor
@main
struct PersonalCalendarApp: App {
    @State private var environment: AppEnvironment

    init() {
        _environment = State(initialValue: .live())
    }

    var body: some Scene {
        Window("个人月历", id: "main-calendar") {
            MonthView(store: environment.store)
                .frame(minWidth: 980, minHeight: 680)
                .task { await environment.store.load() }
        }
        .defaultSize(width: 1180, height: 820)
    }
}
