import SwiftUI

enum CalendarAppWindow {
    case mainCalendar
    case categoryManager
    case recoveryCenter
}

enum CalendarAppWindowID {
    static let recoveryCenter = "recovery-center"
}

enum CalendarAppCommandPolicy {
    static func installsBackupCommands(in window: CalendarAppWindow) -> Bool {
        window == .mainCalendar
    }
}

@MainActor
@main
struct PersonalCalendarApp: App {
    @NSApplicationDelegateAdaptor(NotesApplicationTerminationCoordinator.self)
    private var terminationCoordinator
    @State private var environment: AppEnvironment
    @StateObject private var routeState: WorkspaceRouteState
    @StateObject private var newItemRouter: WorkspaceNewItemRouter
    @StateObject private var editorFocusRegistry: EditorFocusRegistry
    @StateObject private var transitionCoordinator: WorkspaceRouteTransitionCoordinator
    @AppStorage(CalendarAppearancePreference.storageKey)
    private var appearancePreferenceRaw = CalendarAppearancePreference.light.rawValue

    init() {
        let initialEnvironment = AppEnvironment.liveOrTerminate()
        _environment = State(initialValue: initialEnvironment)
        let routeState = WorkspaceRouteState(features: initialEnvironment.features)
        _routeState = StateObject(wrappedValue: routeState)
        _newItemRouter = StateObject(wrappedValue: WorkspaceNewItemRouter())
        _editorFocusRegistry = StateObject(wrappedValue: EditorFocusRegistry())
        _transitionCoordinator = StateObject(wrappedValue: WorkspaceRouteTransitionCoordinator(
            routeState: routeState,
            features: initialEnvironment.features
        ))
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
                focusRegistry: editorFocusRegistry,
                transitionCoordinator: transitionCoordinator,
                terminationCoordinator: terminationCoordinator
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
                transitionCoordinator: transitionCoordinator,
                features: environment.features
            )
            CalendarUndoCommands(store: environment.store, focusRegistry: editorFocusRegistry)
            if CalendarAppCommandPolicy.installsBackupCommands(in: .mainCalendar) {
                BackupCommands(store: environment.store, rollbackDirectory: environment.dataURLs.rollbackDirectory)
            }
        }

        Window("恢复中心", id: CalendarAppWindowID.recoveryCenter) {
            RecoveryCenterView(store: environment.store)
                .preferredColorScheme(appearancePreference.preferredColorScheme)
        }
        .defaultSize(width: 560, height: 440)

        // Category manager is presented as a sheet on the main calendar window so it
        // always appears on the same display (separate Window scenes often restore to
        // another monitor on multi-display Macs).
    }
}
