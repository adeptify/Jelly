import SwiftUI

enum CalendarAppWindow {
    case mainCalendar
    case categoryManager
}

enum CalendarAppCommandPolicy {
    static func installsBackupCommands(in window: CalendarAppWindow) -> Bool {
        window == .mainCalendar
    }
}

@MainActor
@main
struct PersonalCalendarApp: App {
    @State private var environment: AppEnvironment
    @StateObject private var routeState: WorkspaceRouteState
    @StateObject private var newItemRouter: WorkspaceNewItemRouter
    @StateObject private var editorFocusRegistry: EditorFocusRegistry
    @AppStorage(CalendarAppearancePreference.storageKey)
    private var appearancePreferenceRaw = CalendarAppearancePreference.light.rawValue

    init() {
        let initialEnvironment = AppEnvironment.liveOrTerminate()
        _environment = State(initialValue: initialEnvironment)
        _routeState = StateObject(wrappedValue: WorkspaceRouteState(
            features: initialEnvironment.features
        ))
        _newItemRouter = StateObject(wrappedValue: WorkspaceNewItemRouter())
        _editorFocusRegistry = StateObject(wrappedValue: EditorFocusRegistry())
    }

    private var appearancePreference: CalendarAppearancePreference {
        CalendarAppearancePreference(rawValue: appearancePreferenceRaw) ?? .light
    }

    var body: some Scene {
        Window("Jelly", id: "main-calendar") {
            AppShellView(
                store: environment.store,
                features: environment.features,
                routeState: routeState,
                newItemRouter: newItemRouter,
                focusRegistry: editorFocusRegistry
            )
                .preferredColorScheme(appearancePreference.preferredColorScheme)
                .task { await environment.store.load() }
                .onAppear { CalendarAppearancePreference.applyToApplication(appearancePreference) }
                .onChange(of: appearancePreferenceRaw) { _, newValue in
                    let preference = CalendarAppearancePreference(rawValue: newValue) ?? .light
                    CalendarAppearancePreference.applyToApplication(preference)
                }
        }
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            WorkspaceCommands(
                routeState: routeState,
                newItemRouter: newItemRouter,
                features: environment.features
            )
            CalendarUndoCommands(store: environment.store, focusRegistry: editorFocusRegistry)
            if CalendarAppCommandPolicy.installsBackupCommands(in: .mainCalendar) {
                BackupCommands(store: environment.store, rollbackDirectory: environment.dataURLs.rollbackDirectory)
            }
        }

        // Category manager is presented as a sheet on the main calendar window so it
        // always appears on the same display (separate Window scenes often restore to
        // another monitor on multi-display Macs).
    }
}
