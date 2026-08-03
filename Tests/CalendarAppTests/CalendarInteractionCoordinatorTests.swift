import CalendarDomain
import CoreGraphics
import Foundation
import Testing
@testable import CalendarApp

@Suite("CalendarInteractionCoordinatorTests")
@MainActor
struct CalendarInteractionCoordinatorTests {
    @Test func emptyPressBelowSevenPointsStaysAClick() {
        let day = date(6)
        let coordinator = CalendarInteractionCoordinator()

        coordinator.pointerDown(on: day, target: .emptyCell, point: .zero)
        let action = coordinator.pointerUp(at: CGPoint(x: 6, y: 0), over: day)

        #expect(action == .openCreate(.init(start: day, end: day), anchor: day))
        #expect(coordinator.state == .idle)
    }

    @Test func reverseRangeDragNormalizesDatesAndAnchorsReleaseDate() {
        let coordinator = CalendarInteractionCoordinator()
        coordinator.beginRange(on: date(8), point: .zero)

        _ = coordinator.updatePointer(point: CGPoint(x: 20, y: 0), over: date(6))

        #expect(coordinator.previewRange == .init(start: date(6), end: date(8)))
        #expect(coordinator.endInteraction() == .openCreate(
            .init(start: date(6), end: date(8)),
            anchor: date(6)
        ))
    }

    @Test func onlyEmptyCellCanStartSelectionAndControlsKeepTheirOwnAction() {
        let day = date(6)
        let protectedTargets: [CalendarInteractionHitTarget] = [
            .completionButton,
            .leadingHandle,
            .trailingHandle,
            .barBody,
            .dateNumber,
            .overflow
        ]

        for target in protectedTargets {
            let coordinator = CalendarInteractionCoordinator()
            coordinator.pointerDown(on: day, target: target, point: .zero)
            _ = coordinator.updatePointer(point: CGPoint(x: 20, y: 0), over: date(8))
            #expect(coordinator.previewRange == nil)
            #expect(coordinator.pointerUp(at: CGPoint(x: 20, y: 0), over: date(8)) == nil)
        }

        #expect(DayCellSurfaceInteraction.controlAction(for: .dateNumber, date: day) == .openDay(day))
        #expect(DayCellSurfaceInteraction.controlAction(for: .overflow, date: day) == .openDay(day))
    }

    @Test func edgeAutoScrollIsThrottledAndSelectionKeepsUpdatingAfterScroll() {
        var now: TimeInterval = 100
        let coordinator = CalendarInteractionCoordinator(now: { now })
        let viewport = CGRect(x: 0, y: 0, width: 700, height: 240)
        coordinator.beginRange(on: date(6), point: CGPoint(x: 100, y: 120))

        #expect(coordinator.updatePointer(
            point: CGPoint(x: 100, y: 20), over: date(5), viewportBounds: viewport
        ) == [.scrollEarlier])
        #expect(coordinator.previewRange == .init(start: date(5), end: date(6)))

        now += 0.179
        #expect(coordinator.updatePointer(
            point: CGPoint(x: 100, y: 20), over: date(4), viewportBounds: viewport
        ).isEmpty)

        now += 0.001
        #expect(coordinator.updatePointer(
            point: CGPoint(x: 100, y: 20), over: date(3), viewportBounds: viewport
        ) == [.scrollEarlier])
        #expect(coordinator.previewRange == .init(start: date(3), end: date(6)))
    }

    @Test func selectionAtAnEdgeStartsWithoutDateFrameAndKeepsReleaseDateAsAnchor() {
        let coordinator = CalendarInteractionCoordinator()
        let viewport = CGRect(x: 0, y: 0, width: 700, height: 240)
        coordinator.beginRange(on: date(8), point: CGPoint(x: 100, y: 120))

        _ = coordinator.updatePointer(
            point: CGPoint(x: 100, y: 20),
            over: nil,
            viewportBounds: viewport
        )
        coordinator.refreshSelection(over: date(4))

        #expect(coordinator.autoScrollDirection == .earlier)
        #expect(coordinator.previewRange == .init(start: date(4), end: date(8)))
        #expect(coordinator.pointerUp(at: CGPoint(x: 100, y: 20), over: date(3)) == .openCreate(
            .init(start: date(3), end: date(8)),
            anchor: date(3)
        ))
    }

    @Test func autoScrollDriverTicksAcrossWeeksUntilCancelled() {
        let scheduler = ManualAutoScrollScheduler()
        let driver = CalendarInteractionAutoScrollDriver(scheduler: scheduler)

        driver.update(direction: .earlier)
        #expect(driver.latestTick == .init(sequence: 1, direction: .earlier))

        scheduler.advance(by: 0.18)
        #expect(driver.latestTick == .init(sequence: 2, direction: .earlier))
        scheduler.advance(by: 0.18)
        #expect(driver.latestTick == .init(sequence: 3, direction: .earlier))

        driver.cancel()
        scheduler.advance(by: 1)
        #expect(driver.latestTick == .init(sequence: 3, direction: .earlier))
    }

    @Test func autoScrollDriverChangesDirectionWithoutLeakingThePreviousSchedule() {
        let scheduler = ManualAutoScrollScheduler()
        let driver = CalendarInteractionAutoScrollDriver(scheduler: scheduler)

        driver.update(direction: .earlier)
        driver.update(direction: .later)
        scheduler.advance(by: 0.18)

        #expect(driver.latestTick == .init(sequence: 3, direction: .later))
    }

    @Test func autoScrollAtLoadedWindowEdgePlansExtensionBeforeScrollingTheTargetWeek() {
        let cursor = date(3)
        let targetWeek = WeekStreamModel.weekStart(containing: cursor).addingDays(-7)
        let plan = WeekStreamAutoScrollRouting.plan(
            cursorDate: cursor,
            direction: .earlier,
            loadedWeekStarts: [WeekStreamModel.weekStart(containing: cursor)]
        )

        #expect(plan == .extendEarlier(thenScrollTo: targetWeek))
    }

    @Test func autoScrollExecutionExtendsTheLoadedWindowBeforeScrollingTheNewlyLoadedWeek() {
        let cursorDate = date(3)
        let cursorWeek = WeekStreamModel.weekStart(containing: cursorDate)
        let targetWeek = cursorWeek.addingDays(-7)
        let plan = WeekStreamAutoScrollRouting.plan(
            cursorDate: cursorDate,
            direction: .earlier,
            loadedWeekStarts: [cursorWeek]
        )
        let deferrer = ManualWeekStreamAutoScrollDeferrer()
        let driver = WeekStreamAutoScrollExecutionDriver(deferrer: deferrer)
        let spy = WeekStreamAutoScrollExecutionSpy(
            loadedWeekStarts: [cursorWeek],
            targetWeekToLoad: targetWeek,
            loadsTargetWhenExtended: true
        )

        driver.execute(
            plan: plan,
            visibleWeek: cursorWeek,
            direction: .earlier,
            loadedWeekStarts: { spy.loadedWeekStarts },
            extend: spy.extend,
            scroll: spy.scroll
        )

        #expect(spy.operations == [.extendEarlier(cursorWeek)])
        deferrer.performNext()
        #expect(spy.operations == [.extendEarlier(cursorWeek), .scroll(targetWeek)])
    }

    @Test func autoScrollExecutionNeverScrollsAnIdentifierThatTheExtensionDidNotLoad() {
        let cursorDate = date(3)
        let cursorWeek = WeekStreamModel.weekStart(containing: cursorDate)
        let targetWeek = cursorWeek.addingDays(7)
        let plan = WeekStreamAutoScrollRouting.plan(
            cursorDate: cursorDate,
            direction: .later,
            loadedWeekStarts: [cursorWeek]
        )
        let deferrer = ManualWeekStreamAutoScrollDeferrer()
        let driver = WeekStreamAutoScrollExecutionDriver(deferrer: deferrer)
        let spy = WeekStreamAutoScrollExecutionSpy(
            loadedWeekStarts: [cursorWeek],
            targetWeekToLoad: targetWeek,
            loadsTargetWhenExtended: false
        )

        driver.execute(
            plan: plan,
            visibleWeek: cursorWeek,
            direction: .later,
            loadedWeekStarts: { spy.loadedWeekStarts },
            extend: spy.extend,
            scroll: spy.scroll
        )
        deferrer.performNext()

        #expect(spy.operations == [.extendLater(cursorWeek)])
    }

    @Test func cancellingAutoScrollExecutionPreventsItsDeferredScrollCall() {
        let cursorDate = date(3)
        let cursorWeek = WeekStreamModel.weekStart(containing: cursorDate)
        let targetWeek = cursorWeek.addingDays(-7)
        let deferrer = ManualWeekStreamAutoScrollDeferrer()
        let driver = WeekStreamAutoScrollExecutionDriver(deferrer: deferrer)
        let spy = WeekStreamAutoScrollExecutionSpy(
            loadedWeekStarts: [cursorWeek],
            targetWeekToLoad: targetWeek,
            loadsTargetWhenExtended: true
        )

        driver.execute(
            plan: .extendEarlier(thenScrollTo: targetWeek),
            visibleWeek: cursorWeek,
            direction: .earlier,
            loadedWeekStarts: { spy.loadedWeekStarts },
            extend: spy.extend,
            scroll: spy.scroll
        )
        driver.cancel()
        deferrer.performNext()

        #expect(spy.operations == [.extendEarlier(cursorWeek)])
    }

    @Test func escapeCancelAndSuccessfulSaveClearEditingRange() {
        let coordinator = CalendarInteractionCoordinator()
        let selectedRange = CalendarDateRange(start: date(6), end: date(8))
        coordinator.openEditor(for: selectedRange, anchor: date(8))

        #expect(coordinator.previewRange == selectedRange)
        coordinator.cancel()
        #expect(coordinator.state == .idle)
        #expect(coordinator.previewRange == nil)

        coordinator.openEditor(for: selectedRange, anchor: date(8))
        coordinator.completeEditing()
        #expect(coordinator.state == .idle)
        #expect(coordinator.previewRange == nil)
    }

    @Test func frameMapUsesVisibleCellFramesForPointToDateResolution() {
        let frames = CalendarDateFrameMap(frames: [
            .init(date: date(6), frame: CGRect(x: 0, y: 0, width: 100, height: 120)),
            .init(date: date(7), frame: CGRect(x: 100, y: 0, width: 100, height: 120))
        ])

        #expect(frames.date(at: CGPoint(x: 150, y: 60)) == date(7))
        #expect(frames.date(at: CGPoint(x: 210, y: 60)) == nil)
        #expect(frames.nearestDate(to: CGPoint(x: 250, y: 60)) == date(7))
    }

    @Test func monthQuickCreateRoutingSeedsTheExplicitQuickCreateRange() throws {
        let selection = CalendarDateRange(start: date(6), end: date(8))
        let presentation = MonthQuickCreateRouting.presentation(for: .openCreate(
            selection,
            anchor: date(8)
        ))
        let quickCreate = try #require(presentation)
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000888")!

        #expect(quickCreate.range == selection)
        #expect(quickCreate.anchorDate == date(8))
        #expect(quickCreate.initialDraft(categoryID: categoryID).startDate == date(6))
        #expect(quickCreate.initialDraft(categoryID: categoryID).endDate == date(8))
    }

    private func date(_ day: Int) -> CalendarDate {
        CalendarDate(year: 2026, month: 8, day: day)!
    }
}

@MainActor
private final class ManualAutoScrollScheduler: CalendarInteractionAutoScrollScheduler {
    private final class Token: CalendarInteractionAutoScrollCancellation {
        var cancelled = false

        func cancel() {
            cancelled = true
        }
    }

    private struct ScheduledAction {
        let dueAt: TimeInterval
        let token: Token
        let action: () -> Void
    }

    private var now: TimeInterval = 0
    private var actions: [ScheduledAction] = []

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> any CalendarInteractionAutoScrollCancellation {
        let token = Token()
        actions.append(.init(dueAt: now + delay, token: token, action: action))
        return token
    }

    func advance(by interval: TimeInterval) {
        now += interval
        let due = actions.filter { $0.dueAt <= now }
        actions.removeAll { $0.dueAt <= now }
        due.filter { !$0.token.cancelled }.forEach { $0.action() }
    }
}

@MainActor
private final class ManualWeekStreamAutoScrollDeferrer: WeekStreamAutoScrollDeferrer {
    private final class Token: WeekStreamAutoScrollDeferredCancellation {
        var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    private struct DeferredAction {
        let token: Token
        let action: () -> Void
    }

    private var actions: [DeferredAction] = []

    func deferToNextLayout(
        _ action: @escaping () -> Void
    ) -> any WeekStreamAutoScrollDeferredCancellation {
        let token = Token()
        actions.append(.init(token: token, action: action))
        return token
    }

    func performNext() {
        guard !actions.isEmpty else { return }
        let next = actions.removeFirst()
        guard !next.token.isCancelled else { return }
        next.action()
    }
}

@MainActor
private final class WeekStreamAutoScrollExecutionSpy {
    enum Operation: Equatable {
        case extendEarlier(CalendarDate)
        case extendLater(CalendarDate)
        case scroll(CalendarDate)
    }

    var loadedWeekStarts: [CalendarDate]
    var operations: [Operation] = []
    private let targetWeekToLoad: CalendarDate
    private let loadsTargetWhenExtended: Bool

    init(
        loadedWeekStarts: [CalendarDate],
        targetWeekToLoad: CalendarDate,
        loadsTargetWhenExtended: Bool
    ) {
        self.loadedWeekStarts = loadedWeekStarts
        self.targetWeekToLoad = targetWeekToLoad
        self.loadsTargetWhenExtended = loadsTargetWhenExtended
    }

    func extend(
        direction: CalendarInteractionAutoScrollDirection,
        visibleWeek: CalendarDate
    ) {
        switch direction {
        case .earlier: operations.append(.extendEarlier(visibleWeek))
        case .later: operations.append(.extendLater(visibleWeek))
        }
        if loadsTargetWhenExtended {
            loadedWeekStarts.append(targetWeekToLoad)
        }
    }

    func scroll(to weekStart: CalendarDate, direction _: CalendarInteractionAutoScrollDirection) {
        operations.append(.scroll(weekStart))
    }
}
