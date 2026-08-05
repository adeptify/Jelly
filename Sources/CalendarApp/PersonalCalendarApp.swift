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
    private var appearancePreferenceRaw = CalendarAppearancePreference.system.rawValue

    init() {
        _environment = State(initialValue: .live())
    }

    private var appearancePreference: CalendarAppearancePreference {
        CalendarAppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    var body: some Scene {
        Window("个人月历", id: "main-calendar") {
            MonthView(store: environment.store)
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(appearancePreference.preferredColorScheme)
                .task { await environment.store.load() }
                .onAppear { CalendarAppearancePreference.applyToApplication(appearancePreference) }
                .onChange(of: appearancePreferenceRaw) { _, newValue in
                    let preference = CalendarAppearancePreference(rawValue: newValue) ?? .system
                    CalendarAppearancePreference.applyToApplication(preference)
                }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CalendarUndoCommands(store: environment.store)
            if CalendarAppCommandPolicy.installsBackupCommands(in: .mainCalendar) {
                BackupCommands(store: environment.store, backupService: environment.backupService)
            }
        }

        Window("分类管理", id: "category-manager") {
            CategoryManagerView(store: environment.store)
                .frame(minWidth: 440, minHeight: 520)
                .preferredColorScheme(appearancePreference.preferredColorScheme)
                .onAppear { CalendarAppearancePreference.applyToApplication(appearancePreference) }
        }
        .commands {
            CalendarUndoCommands(store: environment.store)
            if CalendarAppCommandPolicy.installsBackupCommands(in: .categoryManager) {
                BackupCommands(store: environment.store, backupService: environment.backupService)
            }
        }
    }
}
