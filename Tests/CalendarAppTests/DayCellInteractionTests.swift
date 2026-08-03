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
}
