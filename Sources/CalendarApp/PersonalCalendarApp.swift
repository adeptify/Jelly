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
    @AppStorage(CalendarAppearancePreference.storageKey)
    private var appearancePreferenceRaw = CalendarAppearancePreference.light.rawValue

    init() {
        _environment = State(initialValue: .liveOrTerminate())
    }

    private var appearancePreference: CalendarAppearancePreference {
        CalendarAppearancePreference(rawValue: appearancePreferenceRaw) ?? .light
    }

    var body: some Scene {
        Window("Jelly", id: "main-calendar") {
            MonthView(store: environment.store)
                .frame(minWidth: 1044, minHeight: 680)
                .preferredColorScheme(appearancePreference.preferredColorScheme)
                .task { await environment.store.load() }
                .onAppear { CalendarAppearancePreference.applyToApplication(appearancePreference) }
                .onChange(of: appearancePreferenceRaw) { _, newValue in
                    let preference = CalendarAppearancePreference(rawValue: newValue) ?? .light
                    CalendarAppearancePreference.applyToApplication(preference)
                }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CalendarUndoCommands(store: environment.store)
            if CalendarAppCommandPolicy.installsBackupCommands(in: .mainCalendar) {
                BackupCommands(store: environment.store, rollbackDirectory: environment.dataURLs.rollbackDirectory)
            }
        }

        // Category manager is presented as a sheet on the main calendar window so it
        // always appears on the same display (separate Window scenes often restore to
        // another monitor on multi-display Macs).
    }
}
