import AppKit
import CalendarDomain
import SwiftUI
import Testing
@testable import CalendarApp

@Suite("DayCellInteractionTests")
@MainActor
struct DayCellInteractionTests {
    @Test func emptyCellSurfaceUsesQuickCreateWithoutStealingControls() {
        let date = CalendarDate(year: 2026, month: 8, day: 10)!

        #expect(DayCellSurfaceInteraction.backgroundAction(for: date) == .quickCreate(date))
        #expect(DayCellSurfaceInteraction.controlAction(for: .dateNumber, date: date) == .openDay(date))
        #expect(DayCellSurfaceInteraction.controlAction(for: .overflow, date: date) == .openDay(date))
        #expect(DayCellSurfaceInteraction.controlAction(for: .item("item-1"), date: date) == .openItem("item-1"))
    }

    @Test func emptyDragGestureIsAttachedSeparatelyFromControlTargets() {
        #expect(WeekRowRangeGesture.target(for: .emptyArea) == .emptyCell)
        #expect(WeekRowRangeGesture.target(for: .dateNumber) == .dateNumber)
        #expect(WeekRowRangeGesture.target(for: .overflow) == .overflow)
        #expect(WeekRowRangeGesture.target(for: .item("item-1")) == .barBody)
    }

    @Test func onlyDedicatedEmptySurfaceCanDispatchRangeSelection() {
        #expect(WeekRowHitRouting.selectionTarget(for: .emptySurface) == .emptyCell)
        #expect(WeekRowHitRouting.selectionTarget(for: .dateNumber) == nil)
        #expect(WeekRowHitRouting.selectionTarget(for: .overflow) == nil)
        #expect(WeekRowHitRouting.selectionTarget(for: .item) == nil)
        #expect(WeekRowHitRouting.selectionTarget(for: .completion) == nil)
        #expect(WeekRowHitRouting.selectionTarget(for: .scroll) == nil)
    }

    @Test func weekRowHitRoutingKeepsDayControlsOutOfRangeSelection() {
        let date = CalendarDate(year: 2026, month: 8, day: 10)!

        #expect(WeekRowHitRouting.dayAction(for: .dateNumber, date: date) == .openDay(date))
        #expect(WeekRowHitRouting.dayAction(for: .overflow, date: date) == .openDay(date))
        #expect(WeekRowHitRouting.dayAction(for: .item, date: date) == nil)
        #expect(WeekRowHitRouting.dayAction(for: .completion, date: date) == nil)
        #expect(WeekRowHitRouting.dayAction(for: .scroll, date: date) == nil)
    }

    @Test func itemHitRoutingKeepsCompletionFirstAndAssignsRightPaddingToTrailingResize() {
        #expect(WeekRowItemHitRouting.target(
            atX: 12,
            width: 140,
            showsLeadingHandle: true,
            showsTrailingHandle: false
        ) == .completionButton)
        #expect(WeekRowItemHitRouting.target(
            atX: 21,
            width: 140,
            showsLeadingHandle: true,
            showsTrailingHandle: false
        ) == .completionButton)
        #expect(WeekRowItemHitRouting.target(
            atX: 26,
            width: 140,
            showsLeadingHandle: true,
            showsTrailingHandle: false
        ) == .completionButton)
        #expect(WeekRowItemHitRouting.target(
            atX: 31,
            width: 140,
            showsLeadingHandle: true,
            showsTrailingHandle: false
        ) == .leadingHandle)
        #expect(WeekRowItemHitRouting.target(
            atX: 31,
            width: 140,
            showsLeadingHandle: false,
            showsTrailingHandle: false
        ) == .barBody)
        #expect(WeekRowItemHitRouting.target(
            atX: 123,
            width: 140,
            showsLeadingHandle: false,
            showsTrailingHandle: true
        ) == .barBody)
        #expect(WeekRowItemHitRouting.target(
            atX: 124,
            width: 140,
            showsLeadingHandle: false,
            showsTrailingHandle: true
        ) == .trailingHandle)
        #expect(WeekRowItemHitRouting.target(
            atX: 134,
            width: 140,
            showsLeadingHandle: false,
            showsTrailingHandle: true
        ) == .trailingHandle)
        #expect(WeekRowItemHitRouting.target(
            atX: 139,
            width: 140,
            showsLeadingHandle: false,
            showsTrailingHandle: true
        ) == .trailingHandle)
        #expect(WeekRowItemHitRouting.target(
            atX: 139,
            width: 140,
            showsLeadingHandle: false,
            showsTrailingHandle: false
        ) == .barBody)
        #expect(WeekRowItemHitRouting.target(
            atX: 70,
            width: 140,
            showsLeadingHandle: true,
            showsTrailingHandle: true
        ) == .barBody)

        // Leading checkbox is still a click; a drag that starts there resizes.
        #expect(WeekRowItemHitRouting.dragTarget(
            atX: 12,
            width: 140,
            showsLeadingHandle: true,
            showsTrailingHandle: false
        ) == .leadingHandle)
        #expect(WeekRowItemHitRouting.dragTarget(
            atX: 31,
            width: 140,
            showsLeadingHandle: true,
            showsTrailingHandle: false
        ) == .leadingHandle)
        #expect(WeekRowItemHitRouting.dragTarget(
            atX: 70,
            width: 140,
            showsLeadingHandle: true,
            showsTrailingHandle: true
        ) == .barBody)
        #expect(WeekRowItemHitRouting.dragTarget(
            atX: 138,
            width: 140,
            showsLeadingHandle: false,
            showsTrailingHandle: true
        ) == .trailingHandle)

        #expect(WeekRowItemHitRouting.dragTarget(
            atX: 115,
            width: 140,
            showsLeadingHandle: true,
            showsTrailingHandle: true,
            generousEdges: true
        ) == .trailingHandle)
        #expect(WeekRowItemHitRouting.target(
            atX: 50,
            width: 140,
            showsLeadingHandle: true,
            showsTrailingHandle: true,
            generousEdges: true
        ) == .leadingHandle)
    }

    @Test func appKitRangeGestureSurfaceEmitsOnlyForTheDedicatedEmptySurface() throws {
        let date = CalendarDate(year: 2026, month: 8, day: 10)!
        let recorder = RangeGestureRecorder()
        let emptySurface = WeekRowRangeGestureSurfaceView(
            date: date,
            hitSurface: .emptySurface,
            rootOrigin: CGPoint(x: 100, y: 150),
            onRangeGesture: recorder.record
        )
        emptySurface.frame = CGRect(x: 0, y: 0, width: 200, height: 120)

        try sendMouseSequence(to: emptySurface)

        #expect(recorder.records.map(\.kind) == [.began, .changed, .ended])
        #expect(recorder.records.first?.date == date)
        #expect(recorder.records.first?.target == .emptyCell)
        for hitSurface in [
            WeekRowHitSurface.dateNumber,
            .overflow,
            .item,
            .completion
        ] {
            let blockedRecorder = RangeGestureRecorder()
            let blocked = WeekRowRangeGestureSurfaceView(
                date: date,
                hitSurface: hitSurface,
                rootOrigin: .zero,
                onRangeGesture: blockedRecorder.record
            )
            blocked.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
            try sendMouseSequence(to: blocked)
            #expect(blockedRecorder.records.isEmpty)
        }

        let scrollRecorder = RangeGestureRecorder()
        let scrollSurface = WeekRowRangeGestureSurfaceView(
            date: date,
            hitSurface: .scroll,
            rootOrigin: .zero,
            onRangeGesture: scrollRecorder.record
        )
        scrollSurface.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        guard let wheelEvent = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ).flatMap(NSEvent.init(cgEvent:)) else {
            Issue.record("Unable to construct the AppKit wheel event.")
            return
        }
        scrollSurface.scrollWheel(with: wheelEvent)

        #expect(scrollRecorder.records.isEmpty)
    }

    @Test func bodyRangeSurfaceAcceptsEntireBodyIncludingOccupiedLaneBands() {
        // Chips sit above this surface in the ZStack; the empty surface must stay hittable
        // for margins beside chips and any free body area (full-cell create).
        let date = CalendarDate(year: 2026, month: 8, day: 10)!
        let surface = WeekRowRangeGestureSurfaceView(
            date: date,
            hitSurface: .emptySurface,
            rootOrigin: .zero,
            onRangeGesture: { _ in }
        )
        surface.frame = CGRect(x: 0, y: 0, width: 100, height: 228)

        #expect(surface.hitTest(CGPoint(x: 50, y: 1)) === surface)
        #expect(surface.hitTest(CGPoint(x: 2, y: 1)) === surface) // left margin
        #expect(surface.hitTest(CGPoint(x: 50, y: 24)) === surface) // mid body
        #expect(surface.hitTest(CGPoint(x: 50, y: 220)) === surface) // bottom
        #expect(surface.hitTest(CGPoint(x: 50, y: 230)) == nil) // outside bounds
    }

    @Test func hostedWeekRowRoutesEmptyBodyToRangeSurfaceWithoutCoveringHeaderOrItem() throws {
        let weekStart = CalendarDate(year: 2026, month: 8, day: 3)!
        var state = makeEmptyState()
        let items = try (0..<3).map { lane in
            try CalendarItem(
                id: UUID(),
                kind: .task,
                title: "前景事项 (lane)",
                categoryID: state.uncategorizedID,
                schedule: try CalendarSchedule(
                    startDate: weekStart.addingDays(1),
                    endDate: weekStart.addingDays(2),
                    startTime: nil,
                    endTime: nil
                ),
                completedAt: nil,
                createdAt: .distantPast,
                updatedAt: .distantPast
            )
        }
        for item in items {
            state.items[item.id] = item
        }

        let store = WorkspaceStore(
            initialState: state,
            repository: InMemoryWorkspaceRepository(initialState: state)
        )
        let rangeRecorder = RangeGestureRecorder()
        let itemRecorder = ItemGestureRecorder()
        let layout = try #require(WeekSegmentLayout.make(
            entries: items.map(ProjectedEntry.item),
            weekStarts: [weekStart],
            laneCapacity: 10
        ).first)
        let host = NSHostingView(rootView: WeekRowView(
            layout: layout,
            today: weekStart,
            selectedDate: nil,
            categories: state.categories,
            dropCoordinator: CalendarDropCoordinator(store: store),
            onAction: { _ in },
            onCompletion: { _ in },
            selectionRange: nil,
            onRangeGesture: rangeRecorder.record,
            onItemGesture: itemRecorder.record,
            height: WeekRowMetrics.defaultHeight
        ))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: WeekRowMetrics.defaultHeight)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil as Any?)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let rangeSurfaces = descendants(of: host, as: WeekRowRangeGestureSurfaceView.self)
            .sorted {
                $0.convert(CGPoint(x: $0.bounds.midX, y: 1), to: host).x
                    < $1.convert(CGPoint(x: $1.bounds.midX, y: 1), to: host).x
            }
        let emptySurface = try #require(rangeSurfaces.first)
        let itemCellSurface = try #require(rangeSurfaces.dropFirst().first)
        func hitPoint(from surface: NSView, _ localPoint: CGPoint) -> CGPoint {
            let renderedPoint = surface.convert(localPoint, to: host)
            // NSHostingView's AppKit hit-test coordinates mirror the SwiftUI render tree.
            return CGPoint(x: renderedPoint.x, y: host.bounds.maxY - renderedPoint.y)
        }
        let topEmptyBodyPoint = hitPoint(
            from: emptySurface,
            CGPoint(x: emptySurface.bounds.midX, y: 1)
        )
        let emptyBodyPoint = hitPoint(
            from: emptySurface,
            CGPoint(x: emptySurface.bounds.midX, y: emptySurface.bounds.midY)
        )
        let headerPoint = hitPoint(
            from: emptySurface,
            CGPoint(x: emptySurface.bounds.midX, y: -5)
        )
        // The segment begins in this date cell. Its chip is inset two points and lane zero
        // begins at the top of the body. Probe rendered chip controls without relying on the
        // retired AppKit overlay implementation.
        let itemPoint = hitPoint(
            from: itemCellSurface,
            CGPoint(x: 70, y: WeekRowMetrics.laneHeight / 2)
        )
        let completionPoint = hitPoint(
            from: itemCellSurface,
            CGPoint(x: 14, y: WeekRowMetrics.laneHeight / 2)
        )
        let leadingHandlePoint = hitPoint(
            from: itemCellSurface,
            CGPoint(x: 33, y: WeekRowMetrics.laneHeight / 2)
        )
        let trailingHandlePoint = hitPoint(
            from: itemCellSurface,
            CGPoint(x: itemCellSurface.bounds.width + 95, y: WeekRowMetrics.laneHeight / 2)
        )
        // Margins of an occupied lane (beside the chip) should still reach the empty surface.
        let occupiedLaneLeftMargin = hitPoint(
            from: itemCellSurface,
            CGPoint(x: 1, y: 1)
        )
        let occupiedLaneBottomFree = hitPoint(
            from: itemCellSurface,
            CGPoint(
                x: itemCellSurface.bounds.midX,
                y: itemCellSurface.bounds.maxY - 4
            )
        )

        #expect(host.hitTest(topEmptyBodyPoint) === emptySurface)
        #expect(host.hitTest(emptyBodyPoint) === emptySurface)
        #expect(host.hitTest(headerPoint) !== emptySurface)
        #expect(!(host.hitTest(itemPoint) is WeekRowRangeGestureSurfaceView))
        #expect(!(host.hitTest(completionPoint) is WeekRowRangeGestureSurfaceView))
        #expect(!(host.hitTest(leadingHandlePoint) is WeekRowRangeGestureSurfaceView))
        #expect(!(host.hitTest(trailingHandlePoint) is WeekRowRangeGestureSurfaceView))
        #expect(host.hitTest(occupiedLaneLeftMargin) is WeekRowRangeGestureSurfaceView)
        #expect(host.hitTest(occupiedLaneBottomFree) is WeekRowRangeGestureSurfaceView)

        try sendMouseClick(
            to: try #require(host.hitTest(emptyBodyPoint) as? WeekRowRangeGestureSurfaceView),
            atWindowLocation: emptySurface.convert(
                CGPoint(x: emptySurface.bounds.midX, y: emptySurface.bounds.midY),
                to: nil as NSView?
            )
        )
        #expect(rangeRecorder.records.map(\.kind) == [.began, .ended])
        #expect(itemRecorder.kinds.isEmpty)
    }

    @Test func flippedParentMapsTopAndBottomMouseLocationsIntoTheSwiftUIRootCoordinateSystem() throws {
        let date = CalendarDate(year: 2026, month: 8, day: 10)!
        let recorder = RangeGestureRecorder()
        let surface = WeekRowRangeGestureSurfaceView(
            date: date,
            hitSurface: .emptySurface,
            rootOrigin: CGPoint(x: 100, y: 150),
            onRangeGesture: recorder.record
        )
        let flippedParent = FlippedEventContainer(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        flippedParent.addSubview(surface)
        surface.frame = flippedParent.bounds

        try sendMouseClick(to: surface, atWindowLocation: CGPoint(x: 10, y: 110))
        try sendMouseClick(to: surface, atWindowLocation: CGPoint(x: 10, y: 10))

        #expect(recorder.records == [
            .began(date, .emptyCell, CGPoint(x: 110, y: 160)),
            .ended(CGPoint(x: 110, y: 160)),
            .began(date, .emptyCell, CGPoint(x: 110, y: 260)),
            .ended(CGPoint(x: 110, y: 260))
        ])
    }

    private func sendMouseSequence(to view: NSView) throws {
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let dragged = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: CGPoint(x: 30, y: 30),
            modifierFlags: [],
            timestamp: 0.1,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: CGPoint(x: 30, y: 30),
            modifierFlags: [],
            timestamp: 0.2,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        view.mouseDown(with: down)
        view.mouseDragged(with: dragged)
        view.mouseUp(with: up)
    }

    private func descendants<View: NSView>(of root: NSView, as _: View.Type) -> [View] {
        root.subviews.flatMap { child in
            let match = (child as? View).map { [$0] } ?? []
            return match + descendants(of: child, as: View.self)
        }
    }

    private func sendMouseClick(to view: NSView, atWindowLocation location: CGPoint) throws {
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: 0.1,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }

}

@MainActor
private final class RangeGestureRecorder {
    var records: [RangeGestureRecord] = []

    func record(_ gesture: WeekRowRangeGesture) {
        switch gesture {
        case let .began(date, target, point):
            records.append(.began(date, target, point))
        case let .changed(point):
            records.append(.changed(point))
        case let .ended(point):
            records.append(.ended(point))
        }
    }
}

private enum RangeGestureRecord: Equatable {
    case began(CalendarDate, CalendarInteractionHitTarget, CGPoint)
    case changed(CGPoint)
    case ended(CGPoint)

    var kind: RangeGestureRecordKind {
        switch self {
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        }
    }

    var date: CalendarDate? {
        guard case let .began(date, _, _) = self else { return nil }
        return date
    }

    var target: CalendarInteractionHitTarget? {
        guard case let .began(_, target, _) = self else { return nil }
        return target
    }
}

private enum RangeGestureRecordKind: Equatable {
    case began
    case changed
    case ended
}

private final class FlippedEventContainer: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class ItemGestureRecorder {
    var kinds: [ItemGestureRecordKind] = []

    func record(_ gesture: WeekRowItemGesture) {
        switch gesture {
        case .began:
            kinds.append(.began)
        case .changed:
            kinds.append(.changed)
        case .ended:
            kinds.append(.ended)
        }
    }
}

private enum ItemGestureRecordKind: Equatable {
    case began
    case changed
    case ended
}
