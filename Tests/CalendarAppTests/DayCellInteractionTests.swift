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

    @Test func itemHitRoutingExposesOnlyTrueOuterHandlesAndCompletionWinsOverlap() {
        #expect(WeekRowItemHitRouting.target(
            atX: 2,
            width: 140,
            kind: .event,
            showsLeadingHandle: true,
            showsTrailingHandle: false
        ) == .leadingHandle)
        #expect(WeekRowItemHitRouting.target(
            atX: 2,
            width: 140,
            kind: .event,
            showsLeadingHandle: false,
            showsTrailingHandle: true
        ) == .barBody)
        #expect(WeekRowItemHitRouting.target(
            atX: 138,
            width: 140,
            kind: .event,
            showsLeadingHandle: false,
            showsTrailingHandle: true
        ) == .trailingHandle)
        #expect(WeekRowItemHitRouting.target(
            atX: 12,
            width: 140,
            kind: .task,
            showsLeadingHandle: true,
            showsTrailingHandle: false
        ) == .completionButton)
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

    @Test func hostedWeekRowRoutesEmptyBodyToRangeSurfaceWithoutCoveringHeaderOrItem() throws {
        let weekStart = CalendarDate(year: 2026, month: 8, day: 3)!
        var state = makeEmptyState()
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "前景事项",
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
        state.items[item.id] = item

        let store = CalendarStore(
            initialState: state,
            repository: InMemoryCalendarRepository(initialState: state)
        )
        let rangeRecorder = RangeGestureRecorder()
        let itemRecorder = ItemGestureRecorder()
        let layout = try #require(WeekSegmentLayout.make(
            entries: [.item(item)],
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

        let emptySurface = try #require(
            descendants(of: host, as: WeekRowRangeGestureSurfaceView.self).first
        )
        let itemSurface = try #require(
            descendants(of: host, as: WeekRowItemGestureSurfaceView.self).first
        )
        let emptyBodyPoint = emptySurface.convert(
            CGPoint(x: emptySurface.bounds.midX, y: emptySurface.bounds.midY),
            to: host
        )
        let headerPoint = emptySurface.convert(
            CGPoint(x: emptySurface.bounds.midX, y: -1),
            to: host
        )
        let itemPoint = itemSurface.convert(
            CGPoint(x: itemSurface.bounds.midX, y: itemSurface.bounds.midY),
            to: host
        )
        let completionPoint = itemSurface.convert(
            CGPoint(x: 12, y: itemSurface.bounds.midY),
            to: host
        )
        let leadingHandlePoint = itemSurface.convert(
            CGPoint(x: 2, y: itemSurface.bounds.midY),
            to: host
        )
        let trailingHandlePoint = itemSurface.convert(
            CGPoint(x: itemSurface.bounds.maxX - 2, y: itemSurface.bounds.midY),
            to: host
        )

        #expect(host.hitTest(emptyBodyPoint) === emptySurface)
        #expect(host.hitTest(headerPoint) !== emptySurface)
        #expect(!(host.hitTest(itemPoint) is WeekRowRangeGestureSurfaceView))
        #expect(!(host.hitTest(completionPoint) is WeekRowRangeGestureSurfaceView))
        #expect(!(host.hitTest(leadingHandlePoint) is WeekRowRangeGestureSurfaceView))
        #expect(!(host.hitTest(trailingHandlePoint) is WeekRowRangeGestureSurfaceView))

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

    @Test func appKitItemSurfaceDispatchesProductionTargetDateDragAndClickRouting() throws {
        let weekStart = CalendarDate(year: 2026, month: 8, day: 3)!
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "可拖动事项",
            categoryID: UUID(),
            schedule: try CalendarSchedule(
                startDate: weekStart.addingDays(1),
                endDate: weekStart.addingDays(3),
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let recorder = ItemGestureRecorder()
        let surface = WeekRowItemGestureSurfaceView(
            source: .item(item),
            weekStart: weekStart,
            startColumn: 1,
            endColumn: 3,
            columnWidth: 40,
            rootOrigin: CGPoint(x: 100, y: 150),
            showsLeadingHandle: true,
            showsTrailingHandle: false,
            onItemGesture: recorder.record,
            onClick: recorder.click
        )
        surface.frame = CGRect(x: 0, y: 0, width: 120, height: 20)

        try sendMouseSequence(to: surface)

        #expect(recorder.kinds == [.began, .changed, .ended])
        #expect(recorder.beganDate == weekStart.addingDays(1))
        #expect(recorder.beganTarget == .completionButton)
        #expect(recorder.clicks.isEmpty)

        try sendMouseClick(to: surface, atWindowLocation: CGPoint(x: 12, y: 10))
        #expect(recorder.clicks == [.completionButton])
    }

    @Test func appKitItemSurfaceDirectOvernightJumpUsesDeterministicCoordinatorClamp() throws {
        let weekStart = CalendarDate(year: 2026, month: 8, day: 3)!
        let source = try CalendarItem(
            id: UUID(),
            kind: .event,
            title: "跨夜",
            categoryID: UUID(),
            schedule: try CalendarSchedule(
                startDate: weekStart.addingDays(3),
                endDate: weekStart.addingDays(5),
                startTime: MinuteOfDay(hour: 23, minute: 0)!,
                endTime: MinuteOfDay(hour: 1, minute: 0)!
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let coordinator = CalendarInteractionCoordinator()
        var submitted: PendingCalendarMutation?
        let directTarget = CalendarDate(year: 2026, month: 8, day: 10)!
        let surface = WeekRowItemGestureSurfaceView(
            source: .item(source),
            weekStart: weekStart,
            startColumn: 3,
            endColumn: 5,
            columnWidth: 40,
            rootOrigin: .zero,
            showsLeadingHandle: true,
            showsTrailingHandle: false,
            onItemGesture: { gesture in
                switch gesture {
                case let .began(date, target, entry, point):
                    coordinator.pointerDown(on: date, target: target, source: entry, point: point)
                case let .changed(point):
                    _ = coordinator.updatePointer(point: point, over: directTarget)
                case let .ended(point):
                    if case let .submitMutation(pending) = coordinator.pointerUp(
                        at: point,
                        over: directTarget
                    ) {
                        submitted = pending
                    }
                }
            },
            onClick: { _ in }
        )
        surface.frame = CGRect(x: 0, y: 0, width: 120, height: 20)

        try sendMouseDrag(
            to: surface,
            from: CGPoint(x: 2, y: 10),
            through: CGPoint(x: 100, y: 10)
        )

        let expected = try CalendarSchedule(
            startDate: CalendarDate(year: 2026, month: 8, day: 7)!,
            endDate: CalendarDate(year: 2026, month: 8, day: 8)!,
            startTime: MinuteOfDay(hour: 23, minute: 0)!,
            endTime: MinuteOfDay(hour: 1, minute: 0)!
        )
        #expect(submitted?.previewSchedule == expected)
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

    private func sendMouseDrag(
        to view: NSView,
        from start: CGPoint,
        through end: CGPoint
    ) throws {
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: start,
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
            location: end,
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
            location: end,
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
    var beganDate: CalendarDate?
    var beganTarget: CalendarInteractionHitTarget?
    var clicks: [CalendarInteractionHitTarget] = []

    func record(_ gesture: WeekRowItemGesture) {
        switch gesture {
        case let .began(date, target, _, _):
            kinds.append(.began)
            beganDate = date
            beganTarget = target
        case .changed:
            kinds.append(.changed)
        case .ended:
            kinds.append(.ended)
        }
    }

    func click(_ target: CalendarInteractionHitTarget) {
        clicks.append(target)
    }
}

private enum ItemGestureRecordKind: Equatable {
    case began
    case changed
    case ended
}
