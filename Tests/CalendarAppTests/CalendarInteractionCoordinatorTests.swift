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
