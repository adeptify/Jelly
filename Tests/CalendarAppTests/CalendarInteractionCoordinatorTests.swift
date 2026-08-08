import CalendarDomain
import CoreGraphics
import Foundation
import Testing
@testable import CalendarApp

@Suite("CalendarInteractionCoordinatorTests")
@MainActor
struct CalendarInteractionCoordinatorTests {
    @Test func bodyMovePreservesDurationAcrossWeeksWithoutPublishingMutation() throws {
        let item = try makeProjectedItem(startDay: 6, endDay: 8)
        let coordinator = CalendarInteractionCoordinator()

        coordinator.pointerDown(
            on: date(6),
            target: .barBody,
            source: .item(item),
            point: .zero
        )
        _ = coordinator.updatePointer(point: CGPoint(x: 20, y: 0), over: date(11))
        let expected = try schedule(11, 13)

        #expect(coordinator.previewSchedule == expected)
        #expect(coordinator.previewRange == .init(start: date(11), end: date(13)))
        #expect(coordinator.state == .movingItem(
            source: .item(item.id),
            previewSchedule: try schedule(11, 13)
        ))
        #expect(coordinator.isDraggingItem)
        #expect(coordinator.draggingSourceID == .item(item.id))
        #expect(coordinator.dragSourceEntry == .item(item))
        #expect(coordinator.dragPreviewPointer == CGPoint(x: 20, y: 0))
        #expect(coordinator.latestPointer == CGPoint(x: 20, y: 0))
    }

    @Test func leadingAndTrailingResizeClampToOneDay() throws {
        let item = try makeProjectedItem(startDay: 6, endDay: 8)

        let leading = CalendarInteractionCoordinator()
        leading.pointerDown(
            on: date(6),
            target: .leadingHandle,
            source: .item(item),
            point: .zero
        )
        _ = leading.updatePointer(point: CGPoint(x: 20, y: 0), over: date(10))
        let expectedLeading = try schedule(8, 8)
        #expect(leading.previewSchedule == expectedLeading)

        let trailing = CalendarInteractionCoordinator()
        trailing.pointerDown(
            on: date(8),
            target: .trailingHandle,
            source: .item(item),
            point: .zero
        )
        _ = trailing.updatePointer(point: CGPoint(x: 20, y: 0), over: date(4))
        let expectedTrailing = try schedule(6, 6)
        #expect(trailing.previewSchedule == expectedTrailing)
    }

    @Test func overnightLeadingResizeDirectJumpAndSampledPathClampIdentically() throws {
        let overnight = try timedProjectedItem(
            startDay: 6,
            endDay: 8,
            startHour: 23,
            endHour: 1
        )
        let direct = CalendarInteractionCoordinator()
        direct.pointerDown(
            on: date(6),
            target: .leadingHandle,
            source: .item(overnight),
            point: .zero
        )
        _ = direct.updatePointer(point: CGPoint(x: 20, y: 0), over: date(10))

        let sampled = CalendarInteractionCoordinator()
        sampled.pointerDown(
            on: date(6),
            target: .leadingHandle,
            source: .item(overnight),
            point: .zero
        )
        _ = sampled.updatePointer(point: CGPoint(x: 10, y: 0), over: date(7))
        _ = sampled.updatePointer(point: CGPoint(x: 20, y: 0), over: date(10))

        let expected = try timedSchedule(7, 8, startHour: 23, endHour: 1)
        #expect(direct.previewSchedule == expected)
        #expect(sampled.previewSchedule == expected)
        #expect(direct.pointerUp(at: CGPoint(x: 20, y: 0), over: date(10))?.pendingSchedule == expected)
        #expect(sampled.pointerUp(at: CGPoint(x: 20, y: 0), over: date(10))?.pendingSchedule == expected)
    }

    @Test func overnightTrailingResizeDirectJumpAndSampledPathClampIdentically() throws {
        let overnight = try timedProjectedItem(
            startDay: 6,
            endDay: 8,
            startHour: 23,
            endHour: 1
        )
        let direct = CalendarInteractionCoordinator()
        direct.pointerDown(
            on: date(8),
            target: .trailingHandle,
            source: .item(overnight),
            point: .zero
        )
        _ = direct.updatePointer(point: CGPoint(x: 20, y: 0), over: date(4))

        let sampled = CalendarInteractionCoordinator()
        sampled.pointerDown(
            on: date(8),
            target: .trailingHandle,
            source: .item(overnight),
            point: .zero
        )
        _ = sampled.updatePointer(point: CGPoint(x: 10, y: 0), over: date(7))
        _ = sampled.updatePointer(point: CGPoint(x: 20, y: 0), over: date(4))

        let expected = try timedSchedule(6, 7, startHour: 23, endHour: 1)
        #expect(direct.previewSchedule == expected)
        #expect(sampled.previewSchedule == expected)
        #expect(direct.pointerUp(at: CGPoint(x: 20, y: 0), over: date(4))?.pendingSchedule == expected)
        #expect(sampled.pointerUp(at: CGPoint(x: 20, y: 0), over: date(4))?.pendingSchedule == expected)
    }

    @Test func forwardSameDayTimesStillAllowResizeToOneCalendarDay() throws {
        let daytime = try timedProjectedItem(
            startDay: 6,
            endDay: 8,
            startHour: 9,
            endHour: 10
        )
        let coordinator = CalendarInteractionCoordinator()
        coordinator.pointerDown(
            on: date(6),
            target: .leadingHandle,
            source: .item(daytime),
            point: .zero
        )

        _ = coordinator.updatePointer(point: CGPoint(x: 20, y: 0), over: date(10))

        let expected = try timedSchedule(8, 8, startHour: 9, endHour: 10)
        #expect(coordinator.previewSchedule == expected)
    }

    @Test func equalClockTimesRequireAtLeastTwoCalendarDays() throws {
        let equalClock = try timedProjectedItem(
            startDay: 6,
            endDay: 8,
            startHour: 23,
            endHour: 23
        )
        let coordinator = CalendarInteractionCoordinator()
        coordinator.pointerDown(
            on: date(8),
            target: .trailingHandle,
            source: .item(equalClock),
            point: .zero
        )

        _ = coordinator.updatePointer(point: CGPoint(x: 20, y: 0), over: date(4))

        let expected = try timedSchedule(6, 7, startHour: 23, endHour: 23)
        #expect(coordinator.previewSchedule == expected)
    }

    @Test func oneDayItemCanMoveAndResizeWithoutBecomingInvalid() throws {
        let item = try makeProjectedItem(startDay: 6, endDay: 6)
        let coordinator = CalendarInteractionCoordinator()
        coordinator.pointerDown(
            on: date(6),
            target: .trailingHandle,
            source: .item(item),
            point: .zero
        )

        _ = coordinator.updatePointer(point: CGPoint(x: 20, y: 0), over: date(3))
        let expected = try schedule(6, 6)

        #expect(coordinator.previewSchedule == expected)
    }

    @Test func itemInteractionDoesNotCommitBeforePointerUpAndReturnsCapturedMutation() throws {
        let item = try makeProjectedItem(startDay: 6, endDay: 8)
        let coordinator = CalendarInteractionCoordinator()
        coordinator.pointerDown(
            on: date(6),
            target: .barBody,
            source: .item(item),
            point: .zero
        )

        _ = coordinator.updatePointer(point: CGPoint(x: 20, y: 0), over: date(11))
        let action = coordinator.pointerUp(at: CGPoint(x: 20, y: 0), over: date(11))

        guard case let .submitMutation(pending) = action else {
            Issue.record("Expected a captured pending mutation")
            return
        }
        let originalSchedule = try schedule(6, 8)
        let previewSchedule = try schedule(11, 13)
        #expect(pending.source == .item(item))
        #expect(pending.operation == .move)
        #expect(pending.originalSchedule == originalSchedule)
        #expect(pending.previewSchedule == previewSchedule)
        #expect(coordinator.state == .idle)
    }

    @Test func itemPointerUpWithoutPreviewNeverFallsThroughToQuickCreate() throws {
        let item = try makeProjectedItem(startDay: 6, endDay: 8)
        let coordinator = CalendarInteractionCoordinator()
        coordinator.pointerDown(
            on: date(6),
            target: .barBody,
            source: .item(item),
            point: .zero
        )

        let action = coordinator.pointerUp(at: CGPoint(x: 20, y: 0), over: date(11))

        #expect(action == nil)
        #expect(coordinator.state == .idle)
    }

    @Test func controlsHandlesBodyAndEmptyCellHaveFixedHitPriority() {
        #expect(CalendarInteractionHitTarget.completionButton.priority > CalendarInteractionHitTarget.leadingHandle.priority)
        #expect(CalendarInteractionHitTarget.trailingHandle.priority > CalendarInteractionHitTarget.barBody.priority)
        #expect(CalendarInteractionHitTarget.barBody.priority > CalendarInteractionHitTarget.emptyCell.priority)
    }

    @Test func recurringScopePendingBlocksNewGesturesUntilResolvedOrCancelled() {
        let coordinator = CalendarInteractionCoordinator()
        coordinator.beginPendingRecurrenceScope()

        #expect(coordinator.state == .pendingRecurrenceScope)
        coordinator.beginRange(on: date(6), point: .zero)
        _ = coordinator.updatePointer(point: CGPoint(x: 20, y: 0), over: date(8))
        #expect(coordinator.state == .pendingRecurrenceScope)

        coordinator.completePendingMutation()
        #expect(coordinator.state == .idle)
    }

    @Test func emptyPressBelowSevenPointsStaysAClick() {
        let day = date(6)
        let coordinator = CalendarInteractionCoordinator()

        coordinator.pointerDown(on: day, target: .emptyCell, point: .zero)
        let action = coordinator.pointerUp(at: CGPoint(x: 6, y: 0), over: day)

        #expect(action == .openCreate(.init(start: day, end: day), anchor: day))
        #expect(coordinator.state == .idle)
    }

    @Test func secondEmptyClickWorksAfterCreateEditorDismiss() {
        let day = date(6)
        let coordinator = CalendarInteractionCoordinator()

        coordinator.pointerDown(on: day, target: .emptyCell, point: .zero)
        #expect(coordinator.pointerUp(at: .zero, over: day) == .openCreate(
            .init(start: day, end: day),
            anchor: day
        ))
        coordinator.openEditor(for: .init(start: day, end: day), anchor: day)
        #expect(coordinator.state == .editing(draft: .init(start: day, end: day), anchorDate: day))

        // Simulate dismiss that failed to cancel (stale .editing) — next click must still work.
        coordinator.pointerDown(on: day, target: .emptyCell, point: CGPoint(x: 4, y: 0))
        let second = coordinator.pointerUp(at: CGPoint(x: 4, y: 0), over: day)
        #expect(second == .openCreate(.init(start: day, end: day), anchor: day))
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
        #expect(quickCreate.initialDraft(categoryID: categoryID).usesTime == false)
    }

    @Test func weekHourSlotCreateSeedsTimedDraft() {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000888")!
        let day = date(6)
        let start = MinuteOfDay(hour: 14, minute: 0)!
        let presentation = QuickCreatePresentation.forDay(day, startTime: start)
        let draft = presentation.initialDraft(categoryID: categoryID)

        #expect(presentation.anchorDate == day)
        #expect(draft.startDate == day)
        #expect(draft.endDate == day)
        #expect(draft.usesTime)
        #expect(draft.startTime == start)
        #expect(draft.endTime == MinuteOfDay(hour: 15, minute: 0)!)
    }

    @Test func weekHourSlotCreateAt23SeedsOvernightEnd() {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000888")!
        let day = date(6)
        let start = MinuteOfDay(hour: 23, minute: 0)!
        let presentation = QuickCreatePresentation.forDay(day, startTime: start)
        let draft = presentation.initialDraft(categoryID: categoryID)

        #expect(draft.usesTime)
        #expect(draft.startDate == day)
        #expect(draft.endDate == date(7))
        #expect(draft.startTime == start)
        #expect(draft.endTime == MinuteOfDay(hour: 0, minute: 0)!)
    }

    @Test func weekAllDayCreateRemainsUntimed() {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000888")!
        let presentation = QuickCreatePresentation.forDay(date(6), startTime: nil)
        let draft = presentation.initialDraft(categoryID: categoryID)

        #expect(draft.usesTime == false)
        #expect(draft.startDate == date(6))
        #expect(draft.endDate == date(6))
    }

    private func date(_ day: Int) -> CalendarDate {
        CalendarDate(year: 2026, month: 8, day: day)!
    }

    private func schedule(_ startDay: Int, _ endDay: Int) throws -> CalendarSchedule {
        try CalendarSchedule(
            startDate: date(startDay),
            endDate: date(endDay),
            startTime: nil,
            endTime: nil
        )
    }

    private func makeProjectedItem(startDay: Int, endDay: Int) throws -> CalendarItem {
        try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "跨日事项",
            categoryID: UUID(),
            schedule: schedule(startDay, endDay),
            creationTimeZoneIdentifier: "Asia/Shanghai",
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func timedProjectedItem(
        startDay: Int,
        endDay: Int,
        startHour: Int,
        endHour: Int
    ) throws -> CalendarItem {
        try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "定时跨日事项",
            categoryID: UUID(),
            schedule: timedSchedule(
                startDay,
                endDay,
                startHour: startHour,
                endHour: endHour
            ),
            creationTimeZoneIdentifier: "Asia/Shanghai",
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func timedSchedule(
        _ startDay: Int,
        _ endDay: Int,
        startHour: Int,
        endHour: Int
    ) throws -> CalendarSchedule {
        try CalendarSchedule(
            startDate: date(startDay),
            endDate: date(endDay),
            startTime: MinuteOfDay(hour: startHour, minute: 0)!,
            endTime: MinuteOfDay(hour: endHour, minute: 0)!
        )
    }
}

private extension CalendarInteractionAction {
    var pendingSchedule: CalendarSchedule? {
        guard case let .submitMutation(pending) = self else { return nil }
        return pending.previewSchedule
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
