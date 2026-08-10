import Testing
import SwiftUI
@testable import CalendarApp

@Suite("WorkspaceNavigationTests")
@MainActor
struct WorkspaceNavigationTests {
    @Test func routesKeepCalendarNotesAndInspirationInStableOrder() {
        #expect(WorkspaceRoute.visibleRoutes(.calendarOnly) == [.calendar])
        #expect(WorkspaceRoute.visibleRoutes(.init(notes: true, inspiration: false)) == [
            .calendar, .notes
        ])
        #expect(WorkspaceRoute.visibleRoutes(.init(notes: true, inspiration: true)) == [
            .calendar, .notes, .inspiration
        ])
    }

    @Test func railMetadataUsesChineseLabelsAndWarmThemeTokens() {
        let calendar = WorkspaceRoute.calendar.railMetadata
        let notes = WorkspaceRoute.notes.railMetadata
        let inspiration = WorkspaceRoute.inspiration.railMetadata

        #expect([calendar.name, notes.name, inspiration.name] == ["日历", "笔记", "灵感"])
        #expect([calendar.help, notes.help, inspiration.help] == ["日历", "笔记", "灵感"])
        #expect([calendar.accessibilityLabel, notes.accessibilityLabel, inspiration.accessibilityLabel] == [
            "日历", "笔记", "灵感"
        ])
        #expect(WorkspaceRailAppearance(theme: .light).backgroundHex == CalendarTheme.light.elevatedSurfaceHex)
        #expect(WorkspaceRailAppearance(theme: .light).selectedTileFillHex == CalendarTheme.light.rangePreviewFillHex)
        #expect(WorkspaceRailAppearance(theme: .light).inactiveIconHex == CalendarTheme.light.secondaryTextHex)
        #expect(WorkspaceRailAppearance.selectedAccessibilityValue == "当前页面")
    }

    @Test func disabledOrUnknownPersistedRouteNormalizesAndWritesCalendarOnce() {
        let preferences = SpyWorkspaceRoutePreferenceStore(initial: "notes")
        let state = WorkspaceRouteState(features: .calendarOnly, preferences: preferences)

        #expect(state.route == .calendar)
        #expect(preferences.writes == ["calendar"])
    }

    @Test func initializationFallbackWritesCalendarForAnUnknownRoute() {
        let preferences = SpyWorkspaceRoutePreferenceStore(initial: "not-a-route")
        let state = WorkspaceRouteState(features: .calendarOnly, preferences: preferences)

        #expect(state.route == .calendar)
        #expect(preferences.writes == ["calendar"])
    }

    @Test func acceptedActivationWritesOnceAndRejectedActivationDoesNotWrite() {
        let preferences = SpyWorkspaceRoutePreferenceStore(initial: "calendar")
        let state = WorkspaceRouteState(
            features: .init(notes: true, inspiration: false),
            preferences: preferences
        )

        #expect(state.activate(.notes, features: .init(notes: true, inspiration: false)))
        #expect(state.route == .notes)
        #expect(preferences.writes == ["notes"])
        #expect(state.activate(.inspiration, features: .init(notes: true, inspiration: false)) == false)
        #expect(state.route == .notes)
        #expect(preferences.writes == ["notes"])
    }

    @Test func routeSelectionStateIsIndependentPerWindowSession() {
        let first = WorkspaceRouteState(
            features: .init(notes: true, inspiration: false),
            preferences: SpyWorkspaceRoutePreferenceStore(initial: "calendar")
        )
        let second = WorkspaceRouteState(
            features: .init(notes: true, inspiration: false),
            preferences: SpyWorkspaceRoutePreferenceStore(initial: "calendar")
        )

        #expect(first.activate(.notes, features: .init(notes: true, inspiration: false)))
        #expect(first.route == .notes)
        #expect(second.route == .calendar)
    }

    @Test func productionFeaturesEnableNotesAndInspiration() {
        #expect(WorkspaceFeatures.production == .init(notes: true, inspiration: true))
        #expect(WorkspaceRoute.visibleRoutes(.production) == [.calendar, .notes, .inspiration])
    }

    @Test func disabledModuleBuildersAreNeverInvoked() {
        let counter = WorkspaceModuleBuildCounter()
        let hosts = WorkspaceModuleHostStore(features: .calendarOnly) { route in
            counter.record(route)
            return WorkspaceModuleHost(
                route: route,
                content: AnyView(EmptyView()),
                lifetimeToken: WorkspaceModuleSentinel()
            )
        }

        #expect(counter.routes == [.calendar])
        #expect(hosts.host(for: .calendar) != nil)
        #expect(hosts.host(for: .notes) == nil)
        #expect(hosts.host(for: .inspiration) == nil)
    }

    @Test func enabledModuleHostsKeepIdentityAndStateAcrossRouteRoundTrips() {
        let sentinels = Dictionary(uniqueKeysWithValues: WorkspaceRoute.allCases.map { route in
            (route, WorkspaceModuleSentinel())
        })
        let hosts = WorkspaceModuleHostStore(
            features: .init(notes: true, inspiration: true)
        ) { route in
            WorkspaceModuleHost(
                route: route,
                content: AnyView(EmptyView()),
                lifetimeToken: sentinels[route]!
            )
        }
        let calendarHost = try! #require(hosts.host(for: .calendar))
        let notesHost = try! #require(hosts.host(for: .notes))
        let calendarSentinel = calendarHost.lifetimeToken as! WorkspaceModuleSentinel
        calendarSentinel.selectionToken = "2026-08-10"
        calendarSentinel.scrollToken = "week-32"

        _ = hosts.presentation(for: .calendar, activeRoute: .calendar)
        _ = hosts.presentation(for: .notes, activeRoute: .notes)
        _ = hosts.presentation(for: .calendar, activeRoute: .calendar)

        #expect(hosts.host(for: .calendar) === calendarHost)
        #expect(hosts.host(for: .notes) === notesHost)
        #expect((hosts.host(for: .calendar)?.lifetimeToken as? WorkspaceModuleSentinel) === calendarSentinel)
        #expect(calendarSentinel.selectionToken == "2026-08-10")
        #expect(calendarSentinel.scrollToken == "week-32")
    }

    @Test func inactiveModuleHostsRejectHitsAndHideFromAccessibility() {
        let hosts = WorkspaceModuleHostStore(
            features: .init(notes: true, inspiration: false)
        ) { route in
            WorkspaceModuleHost(
                route: route,
                content: AnyView(EmptyView()),
                lifetimeToken: WorkspaceModuleSentinel()
            )
        }

        #expect(hosts.presentation(for: .calendar, activeRoute: .calendar) == .active)
        #expect(hosts.presentation(for: .notes, activeRoute: .calendar) == .inactive)
        #expect(hosts.presentation(for: .notes, activeRoute: .calendar).allowsHitTesting == false)
        #expect(hosts.presentation(for: .notes, activeRoute: .calendar).accessibilityHidden)
    }
}

@MainActor
final class SpyWorkspaceRoutePreferenceStore: WorkspaceRoutePreferenceStore {
    private let initial: String?
    private(set) var writes: [String] = []

    init(initial: String?) {
        self.initial = initial
    }

    var selectedRouteRawValue: String? {
        writes.last ?? initial
    }

    func writeSelectedRouteRawValue(_ rawValue: String) {
        writes.append(rawValue)
    }
}

@MainActor
private final class WorkspaceModuleBuildCounter {
    private(set) var routes: [WorkspaceRoute] = []

    func record(_ route: WorkspaceRoute) {
        routes.append(route)
    }
}

@MainActor
private final class WorkspaceModuleSentinel {
    var selectionToken = ""
    var scrollToken = ""
}
