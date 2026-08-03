import AppKit
import CalendarDomain
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
