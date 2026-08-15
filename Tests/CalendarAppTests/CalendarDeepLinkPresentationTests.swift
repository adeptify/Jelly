import AppKit
import CalendarDomain
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("CalendarDeepLinkPresentationTests")
@MainActor
struct CalendarDeepLinkPresentationTests {
    @Test func creatingCalendarItemFocusesTheTitleAfterTheOverlayMounts() async throws {
        _ = NSApplication.shared
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let router = WorkspaceNewItemRouter()
        let host = NSHostingView(rootView: CalendarNewItemHarness(store: store, router: router))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        _ = router.requestNewItem(route: .calendar, features: .production)

        #expect(await waitForCalendarDeepLink {
            host.layoutSubtreeIfNeeded()
            guard let title = calendarDeepLinkDescendants(of: host, as: NSTextField.self).first(where: {
                $0.placeholderString == "标题"
            }) else {
                return false
            }
            guard let fieldEditor = title.currentEditor() else { return false }
            return window.firstResponder === fieldEditor
        })
    }

    @Test func deepLinkingToAnotherItemReplacesTheAlreadyOpenEditorModel() async throws {
        _ = NSApplication.shared
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let day = CalendarDate(year: 2026, month: 8, day: 14)!
        let first = try makeDeepLinkItem(
            title: "First calendar item",
            categoryID: calendar.uncategorizedID,
            day: day
        )
        let second = try makeDeepLinkItem(
            title: "Second calendar item",
            categoryID: calendar.uncategorizedID,
            day: day
        )
        _ = try await store.sendWorkspace(.calendar(.createItem(first)))
        _ = try await store.sendWorkspace(.calendar(.createItem(second)))
        let router = WorkspaceDeepLinkRouter()
        let host = NSHostingView(rootView: CalendarDeepLinkHarness(store: store, router: router))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        _ = router.request(.calendarItem(first.id))
        #expect(await waitForCalendarDeepLink {
            host.layoutSubtreeIfNeeded()
            return calendarDeepLinkDescendants(of: host, as: NSTextField.self).contains {
                $0.stringValue == "First calendar item"
            }
        })

        _ = router.request(.calendarItem(second.id))

        #expect(await waitForCalendarDeepLink {
            host.layoutSubtreeIfNeeded()
            return calendarDeepLinkDescendants(of: host, as: NSTextField.self).contains {
                $0.stringValue == "Second calendar item"
            }
        })
    }

    @Test func deepLinkingToAnOccurrenceOpensThatExactOccurrenceWithoutAScopePrompt() async throws {
        _ = NSApplication.shared
        var calendar = makeEmptyState()
        let day = try #require(CalendarDate(year: 2026, month: 8, day: 17))
        let series = try WeeklySeries(
            id: UUID(),
            kind: .task,
            title: "Exact recurring occurrence",
            categoryID: calendar.uncategorizedID,
            ruleStartDate: day,
            recurrenceEndDate: nil,
            weekdays: [day.weekday],
            durationDays: 1,
            startTime: nil,
            endTime: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        calendar.recurrence.series[series.id] = series
        let key = OccurrenceKey(seriesID: series.id, originalDate: day)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let router = WorkspaceDeepLinkRouter()
        let host = NSHostingView(rootView: CalendarDeepLinkHarness(store: store, router: router))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        _ = router.request(.calendarOccurrence(key))

        #expect(await waitForCalendarDeepLink {
            host.layoutSubtreeIfNeeded()
            return calendarDeepLinkDescendants(of: host, as: NSTextField.self).contains {
                $0.stringValue == "Exact recurring occurrence"
            }
        })
        #expect(router.pendingRequest == nil)
    }
}

private struct CalendarNewItemHarness: View {
    let store: WorkspaceStore
    @ObservedObject var router: WorkspaceNewItemRouter

    var body: some View {
        MonthView(
            store: store,
            todayRefreshPolicy: .init(
                now: { Date(timeIntervalSince1970: 1_786_636_800) },
                calendar: Calendar(identifier: .gregorian)
            ),
            newItemRequest: router.pendingRequest,
            consumeNewItemRequest: router.consume
        )
    }
}

private struct CalendarDeepLinkHarness: View {
    let store: WorkspaceStore
    @ObservedObject var router: WorkspaceDeepLinkRouter

    var body: some View {
        MonthView(
            store: store,
            todayRefreshPolicy: .init(
                now: { Date(timeIntervalSince1970: 1_786_636_800) },
                calendar: Calendar(identifier: .gregorian)
            ),
            deepLinkRequest: router.pendingRequest,
            consumeDeepLinkRequest: router.consume
        )
    }
}

private func makeDeepLinkItem(
    title: String,
    categoryID: UUID,
    day: CalendarDate
) throws -> CalendarItem {
    try CalendarItem(
        id: UUID(),
        kind: .task,
        title: title,
        categoryID: categoryID,
        schedule: .init(startDate: day, endDate: day, startTime: nil, endTime: nil),
        completedAt: nil,
        createdAt: .distantPast,
        updatedAt: .distantPast
    )
}

@MainActor
private func waitForCalendarDeepLink(
    timeout: Duration = .seconds(1),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
private func calendarDeepLinkDescendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    var result = (view as? T).map { [$0] } ?? []
    for child in view.subviews {
        result.append(contentsOf: calendarDeepLinkDescendants(of: child, as: type))
    }
    return result
}
